import Foundation
import Darwin
import CSQLite
import Testing
@testable import GlowroomCore

@Suite("Durable photo metadata commands and CAS")
struct PhotoMetadataRepositoryTests {
    @Test func initializationIsLazyAndInvalidLocationKeepsPreciseReason() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-lazy-\(UUID())")
        let repository = PhotoMetadataRepository(directory:url)
        #expect(!FileManager.default.fileExists(atPath:url.path))
        #expect(await repository.searchState() == .available(.init(version:await repository.searchState().version,catalogReference:.absent,confirmedByAssetID:[:])))
        let invalid = PhotoMetadataRepository(directory:URL(string:"https://example.invalid/catalog")!)
        if case .unavailable(_,let reason) = await invalid.searchState() { #expect(reason == .validation(.invalidSource)) } else { Issue.record("Expected invalid local source") }
    }
    @Test func manualRoundtripUsesExactDateAndEmptyConfirmationIsTombstone() async throws {
        let f = try MetadataFixture(); let source = try f.source()
        let date = Date(timeIntervalSinceReferenceDate:source.original.modifiedAt.timeIntervalSinceReferenceDate.nextUp)
        let precise = MetadataSourceReference(original:.init(standardizedPath:source.original.standardizedPath,modifiedAt:date,fileSize:source.original.fileSize),nativeStamp:source.nativeStamp)
        try await f.bind(source:precise)
        let saved = try await f.confirm(.init(title:"  Haus\n  am Feld ",description:"Absatz\r\n\r\nZwei",tags:["Gru\u{308}n","GRÜN","grun"]))
        #expect(saved.currentRecord?.confirmed.title == "Haus am Feld")
        #expect(saved.currentRecord?.confirmed.tags == ["Grün","grun"])
        let restarted = PhotoMetadataRepository(directory:f.directory)
        let row = try #require(try await restarted.record(assetID:f.id))
        #expect(row.confirmedSource?.original.modifiedAt.timeIntervalSinceReferenceDate.bitPattern == date.timeIntervalSinceReferenceDate.bitPattern)
        #expect(row.confirmed == saved.currentRecord?.confirmed)
        let empty = try await f.confirm(.empty,tagPolicy:.replace)
        #expect(empty.currentRecord?.confirmedRevision == 2)
        #expect(empty.currentRecord?.confirmed == .empty)
        #expect(empty.currentRecord?.confirmedAt != nil)
        #expect(await f.repository.finishSaving())
    }
    @Test func normalizedReplaySurvivesLaterWritesAndRejectsIDCollision() async throws {
        let f = try MetadataFixture(); try await f.bind()
        let id = UUID(), source = try f.source()
        let op = MetadataConfirmOperation(header:.init(id:id,assetID:f.id,expectedVersion:.absent),values:.init(title:"A  house"),fields:[.title],source:source,origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:0))
        let first = try await f.repository.confirm(op)
        let equivalent = MetadataConfirmOperation(header:op.header,values:.init(title:" A\nhouse "),fields:[.title],source:source,origin:op.origin)
        #expect(try await f.repository.confirm(equivalent).receipt.disposition == .replayed)
        _ = try await f.confirm(.init(title:"Newer"))
        let retry = try await f.repository.confirm(op)
        #expect(retry.receipt.affected == first.receipt.affected)
        #expect(retry.currentRecord?.confirmed.title == "Newer")
        let collision = MetadataConfirmOperation(header:op.header,values:.init(title:"Different"),fields:[.title],source:source,origin:op.origin)
        await metadataError(.operationIDCollision) { _ = try await f.repository.confirm(collision) }
    }
    @Test func competingExpectedVersionsAllowExactlyOneWinner() async throws {
        let f = try MetadataFixture(); try await f.bind(); let source = try f.source()
        let values = try await withThrowingTaskGroup(of:Bool.self) { group in
            for title in ["First","Second"] {
                group.addTask {
                    do { _ = try await f.repository.confirm(.init(header:.init(assetID:f.id,expectedVersion:.absent),values:.init(title:title),fields:[.title],source:source,origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:0))); return true }
                    catch PhotoMetadataError.revisionConflict { return false }
                }
            }
            var results:[Bool] = []; for try await result in group { results.append(result) }; return results
        }
        #expect(values.filter { $0 }.count == 1)
        #expect(try await f.repository.record(assetID:f.id)?.confirmedRevision == 1)
    }
    @Test func manualAndAIDraftsHaveIndependentMonotoneCountersAndNoSearchText() async throws {
        let f = try MetadataFixture(); try await f.bind()
        let manual = try await f.repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:.absent),mutation:.save(fields:.init(title:"Not confirmed"),baseConfirmedRevision:0)))
        let draft = try await f.repository.saveAIDraft(.init(header:.init(assetID:f.id,expectedVersion:manual.currentRecord!.version),mutation:.createSuggested(draftID:UUID(),fields:.init(title:"AI draft"),source:try f.analysisSource())))
        #expect(draft.currentRecord?.manualDraft?.fields.title == "Not confirmed")
        #expect(draft.currentRecord?.confirmed.title == "")
        if case .available(let s) = draft.searchState { #expect(s.confirmedByAssetID.isEmpty) } else { Issue.record("Expected valid empty search") }
        let rejected = try await f.repository.setDraftState(.init(header:.init(assetID:f.id,expectedVersion:draft.currentRecord!.version),draftID:draft.currentRecord!.draft!.id,expectedDraftRevision:draft.currentRecord!.draft!.revision))
        #expect(rejected.currentRecord?.draft?.state == .rejected)
        let discarded = try await f.repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:rejected.currentRecord!.version),mutation:.discard))
        #expect(discarded.currentRecord?.manualDraft == nil)
        #expect(discarded.currentRecord!.version.manualDraftRevision > manual.currentRecord!.version.manualDraftRevision)
    }
    @Test func lateAIAnswerCannotOverwriteEditedManualDraft() async throws {
        let f = try MetadataFixture(); try await f.bind(); let captured = MetadataRecordVersion.absent
        _ = try await f.repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:captured),mutation:.save(fields:.init(title:"Human"),baseConfirmedRevision:0)))
        await metadataError(.revisionConflict) { _ = try await f.repository.saveAIDraft(.init(header:.init(assetID:f.id,expectedVersion:captured),mutation:.createSuggested(draftID:UUID(),fields:.init(title:"Late"),source:try f.analysisSource()))) }
        #expect(try await f.repository.record(assetID:f.id)?.manualDraft?.fields.title == "Human")
    }
    @Test func partialAIConfirmKeepsLanguageAndMarksOneConsumedProposal() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Old",description:"Keep",tags:["Old"],language:"en_US"))
        let old = try #require(try await f.repository.record(assetID:f.id))
        let draft = try await f.repository.saveAIDraft(.init(header:.init(assetID:f.id,expectedVersion:old.version),mutation:.createSuggested(draftID:UUID(),fields:.init(title:"New",description:"AI",tags:["New"]),source:try f.analysisSource())))
        let d = draft.currentRecord!.draft!
        let op = MetadataConfirmOperation(header:.init(assetID:f.id,expectedVersion:draft.currentRecord!.version),values:d.fields,fields:[.title],source:d.source,origin:.proposal(draftID:d.id,expectedDraftRevision:d.revision))
        let accepted = try await f.repository.confirm(op)
        #expect(accepted.currentRecord?.confirmed == .init(title:"New",description:"Keep",tags:["Old"],language:"en_US"))
        #expect(accepted.currentRecord?.draft?.state == .accepted)
        #expect(accepted.currentRecord?.draft?.appliedFields == [.title])
        if case .confirmedAI(let origin) = accepted.currentRecord?.confirmedProvenance.title { #expect(!origin.wasHumanEdited) } else { Issue.record("Missing AI provenance") }
        await metadataError(.validation(.invalidDraftTransition)) { _ = try await f.repository.setDraftState(.init(header:.init(assetID:f.id,expectedVersion:accepted.currentRecord!.version),draftID:d.id,expectedDraftRevision:accepted.currentRecord!.draft!.revision)) }
    }
    @Test(arguments: [false, true], [false, true])
    func manualConfirmationInvalidatesOpenProposalAtomically(edited: Bool, partial: Bool) async throws {
        let f = try MetadataFixture(); try await f.bind()
        var saved = try await f.repository.saveAIDraft(.init(header: .init(assetID: f.id, expectedVersion: .absent),
            mutation: .createSuggested(draftID: UUID(), fields: .init(title: "AI title", description: "AI description", tags: ["AI"]), source: try f.analysisSource())))
        if edited {
            saved = try await f.repository.saveAIDraft(.init(header: .init(assetID: f.id, expectedVersion: saved.currentRecord!.version),
                mutation: .editExisting(draftID: saved.currentRecord!.draft!.id, fields: .init(title: "Corrected AI title", description: "AI description", tags: ["AI"]))))
        }
        let original = try #require(saved.currentRecord?.draft)
        let manual = try await f.repository.saveManualDraft(.init(header: .init(assetID: f.id, expectedVersion: saved.currentRecord!.version),
            mutation: .save(fields: .init(title: "Manual title", description: "Manual description"), baseConfirmedRevision: 0)))
        let before = try #require(manual.currentRecord)
        let operation = MetadataConfirmOperation(header: .init(assetID: f.id, expectedVersion: before.version),
            values: before.manualDraft!.fields, fields: partial ? [.title] : Set(PhotoMetadataField.allCases), source: try f.source(),
            origin: .manual(expectedManualDraftRevision: before.manualDraft!.revision, reviewedConfirmedRevision: 0))
        let result = try await f.repository.confirm(operation)
        let after = try #require(result.currentRecord), draft = try #require(after.draft)
        #expect(after.confirmed.title == "Manual title")
        #expect(after.confirmed.description == (partial ? "" : "Manual description"))
        #expect(after.confirmedProvenance.title == .manual)
        #expect(draft.state == .outdated && draft.baseConfirmedRevision == 0)
        #expect(draft.id == original.id && draft.fields == original.fields && draft.source == original.source)
        #expect(draft.createdAt == original.createdAt && draft.editedFields == original.editedFields)
        #expect(after.version.recordRevision == before.version.recordRevision + 1)
        #expect(after.confirmedRevision == 1 && after.version.aiDraftRevision == before.version.aiDraftRevision + 1)
        #expect(after.version.manualDraftRevision == before.version.manualDraftRevision + (partial ? 0 : 1))
        #expect((after.manualDraft != nil) == partial)
        let replay = try await f.repository.confirm(operation)
        #expect(replay.receipt.disposition == .replayed && replay.currentRecord == after)
        let restart = PhotoMetadataRepository(directory: f.directory)
        #expect(try await restart.record(assetID: f.id) == after)
        await metadataError(.revisionConflict) {
            _ = try await f.repository.confirm(.init(header: .init(assetID: f.id, expectedVersion: after.version),
                values: draft.fields, fields: [.title], source: draft.source,
                origin: .proposal(draftID: draft.id, expectedDraftRevision: draft.revision)))
        }
        await metadataError(.revisionConflict) {
            _ = try await f.repository.saveAIDraft(.init(header: .init(assetID: f.id, expectedVersion: before.version),
                mutation: .editExisting(draftID: original.id, fields: original.fields)))
        }
        let fresh = try await f.repository.saveAIDraft(.init(header: .init(assetID: f.id, expectedVersion: after.version),
            mutation: .createSuggested(draftID: UUID(), fields: .init(title: "Fresh analysis"), source: try f.analysisSource())))
        let newDraft = try #require(fresh.currentRecord?.draft)
        #expect(newDraft.baseConfirmedRevision == after.confirmedRevision)
        let accepted = try await f.repository.confirm(.init(header: .init(assetID: f.id, expectedVersion: fresh.currentRecord!.version),
            values: newDraft.fields, fields: [.title], source: newDraft.source,
            origin: .proposal(draftID: newDraft.id, expectedDraftRevision: newDraft.revision)))
        #expect(accepted.currentRecord?.confirmed.title == "Fresh analysis")
        #expect(accepted.currentRecord?.draft?.state == .accepted)
    }
    @Test(arguments: [MetadataDraftState.accepted, .rejected, .outdated])
    func laterManualConfirmationPreservesClosedProposal(state: MetadataDraftState) async throws {
        let f = try MetadataFixture(); try await f.bind()
        let saved = try await f.repository.saveAIDraft(.init(header: .init(assetID: f.id, expectedVersion: .absent),
            mutation: .createSuggested(draftID: UUID(), fields: .init(title: "AI title"), source: try f.analysisSource())))
        let draft = try #require(saved.currentRecord?.draft)
        if state == .accepted {
            _ = try await f.repository.confirm(.init(header: .init(assetID: f.id, expectedVersion: saved.currentRecord!.version),
                values: draft.fields, fields: [.title], source: draft.source,
                origin: .proposal(draftID: draft.id, expectedDraftRevision: draft.revision)))
        } else if state == .rejected {
            _ = try await f.repository.setDraftState(.init(header: .init(assetID: f.id, expectedVersion: saved.currentRecord!.version),
                draftID: draft.id, expectedDraftRevision: draft.revision))
        } else { _ = try await f.confirm(.init(title: "First manual confirmation")) }
        let before = try #require(try await f.repository.record(assetID: f.id))
        let after = try #require(try await f.confirm(.init(title: "Later manual confirmation")).currentRecord)
        #expect(before.draft?.state == state && after.draft == before.draft)
        #expect(after.version.aiDraftRevision == before.version.aiDraftRevision)
        #expect(after.confirmedRevision == before.confirmedRevision + 1)
    }
    @Test func failedManualConfirmationRollsBackProposalInvalidation() async throws {
        let failure = MetadataFailureSwitch(), directory = MetadataFixture.directory()
        var hooks = PhotoMetadataRepositoryHooks(); hooks.beforeCommit = { try failure.check() }
        let repository = PhotoMetadataRepository(directory: directory, hooks: hooks)
        let f = try MetadataFixture(directory: directory, repository: repository); try await f.bind()
        let saved = try await repository.saveAIDraft(.init(header: .init(assetID: f.id, expectedVersion: .absent),
            mutation: .createSuggested(draftID: UUID(), fields: .init(title: "AI title"), source: try f.analysisSource())))
        failure.enabled = true
        await metadataError(.storageFailure) { _ = try await f.confirm(.init(title: "Uncommitted manual title")) }
        #expect(try await repository.record(assetID: f.id) == saved.currentRecord)
    }
    @Test func optionalCatalogBirthEvidenceDoesNotRejectSuggestorSource() async throws {
        let f = try MetadataFixture(); let full = try f.source(); try await f.bind(source:full)
        let draftSource = try f.analysisSource(includeExtendedNative:false)
        let draft = try await f.repository.saveAIDraft(.init(header:.init(assetID:f.id,expectedVersion:.absent),mutation:.createSuggested(draftID:UUID(),fields:.init(title:"Real source"),source:draftSource)))
        let d = draft.currentRecord!.draft!
        let result = try await f.repository.confirm(.init(header:.init(assetID:f.id,expectedVersion:draft.currentRecord!.version),values:d.fields,fields:[.title],source:draftSource,origin:.proposal(draftID:d.id,expectedDraftRevision:d.revision)))
        #expect(result.currentRecord?.sourceChanged == false)
        #expect(result.currentRecord?.confirmedSource == draftSource)
        #expect(full.nativeStamp?.birthTime != nil)
    }
    @Test func newerConfirmationRequiresExplicitManualReviewAndDraftCAS() async throws {
        let f = try MetadataFixture(); try await f.bind()
        let manual = try await f.repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:.absent),mutation:.save(fields:.init(title:"Manual"),baseConfirmedRevision:0)))
        let v = manual.currentRecord!.version
        await metadataError(.revisionConflict) { _ = try await f.repository.confirm(.init(header:.init(assetID:f.id,expectedVersion:v),values:.init(title:"Manual"),fields:[.title],source:try f.source(),origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:0))) }
        let result = try await f.repository.confirm(.init(header:.init(assetID:f.id,expectedVersion:v),values:.init(title:"Manual"),fields:Set(PhotoMetadataField.allCases),source:try f.source(),origin:.manual(expectedManualDraftRevision:v.manualDraftRevision,reviewedConfirmedRevision:0)))
        #expect(result.currentRecord?.manualDraft == nil)
        #expect(result.currentRecord?.confirmed.title == "Manual")
    }
    @Test func rollbackAndSearchFailureAreDifferentOutcomes() async throws {
        let failure = MetadataFailureSwitch(), directory = MetadataFixture.directory()
        var hooks = PhotoMetadataRepositoryHooks(); hooks.beforeCommit = { try failure.check() }; hooks.searchEntryLimit = 0
        let repository = PhotoMetadataRepository(directory:directory,hooks:hooks)
        let f = try MetadataFixture(directory:directory,repository:repository); try await f.bind()
        failure.enabled = true
        await metadataError(.storageFailure) { _ = try await f.confirm(.init(title:"Rolled back")) }
        #expect(try await repository.record(assetID:f.id) == nil)
        failure.enabled = false
        let committed = try await f.confirm(.init(title:"Committed"))
        #expect(committed.receipt.disposition == .applied)
        if case .unavailable(_,let reason) = committed.searchState { #expect(reason == .limitExceeded(.searchSnapshot)) } else { Issue.record("Expected visible search failure") }
        #expect(try await repository.record(assetID:f.id)?.confirmed.title == "Committed")
    }
    @Test func repeatedRefreshAndRestartPreserveOverwriteWarning() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Keep forever"))
        try Data("a different source".utf8).write(to:f.original)
        let changed = try f.source(); try await f.bind(source:changed,generation:2)
        #expect(try await f.repository.record(assetID:f.id)?.sourceChanged == true)
        try await f.bind(source:changed,generation:3)
        let restarted = PhotoMetadataRepository(directory:f.directory)
        _ = try await restarted.recoverCatalogChanges(persistedCatalog:f.snapshot(source:changed,generation:4))
        #expect(try await restarted.record(assetID:f.id)?.sourceChanged == true)
        #expect(try await restarted.record(assetID:f.id)?.confirmed.title == "Keep forever")
        let version = try await restarted.record(assetID:f.id)!.version
        _ = try await restarted.confirm(.init(header:.init(assetID:f.id,expectedVersion:version),values:.init(title:"Reviewed"),fields:[.title],source:changed,origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:version.confirmedRevision)))
        #expect(try await restarted.record(assetID:f.id)?.sourceChanged == false)
    }
    @Test func manualOriginalOnlyConfirmRetainsCatalogNativeAndOverwriteWarningIsSticky() async throws {
        let f = try MetadataFixture(), before = try f.source(); try await f.bind(source:before)
        _ = try await f.repository.confirm(.init(header:.init(assetID:f.id,expectedVersion:.absent),values:.init(title:"Historical"),fields:[.title],source:.init(original:before.original),origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:0)))
        try Data("synthetic sourcX".utf8).write(to:f.original)
        let fd = open(f.original.path,O_RDWR); #expect(fd >= 0); defer { close(fd) }
        var info = stat(); #expect(fstat(fd,&info) == 0)
        var times = [info.st_atimespec,timespec(tv_sec:Int(before.nativeStamp!.modifiedAt.seconds),tv_nsec:Int(before.nativeStamp!.modifiedAt.nanoseconds))]
        #expect(futimens(fd,&times) == 0)
        let changed = try f.source(); #expect(changed.original == before.original)
        #expect(changed.nativeStamp?.changedAt != before.nativeStamp?.changedAt)
        try await f.bind(source:changed,generation:2)
        #expect(try await f.repository.record(assetID:f.id)?.sourceChanged == true)
        try await f.bind(source:.init(original:before.original),generation:3)
        #expect(try await f.repository.record(assetID:f.id)?.sourceChanged == true)
        let restart = PhotoMetadataRepository(directory:f.directory)
        _ = try await restart.recoverCatalogChanges(persistedCatalog:f.snapshot(source:changed,generation:4))
        #expect(try await restart.record(assetID:f.id)?.sourceChanged == true)
    }
    @Test func staleActorManualDraftPreservesAnExternallyReconciledOrphanAndSearchState() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Confirmed searchable title"))
        try Data("{\"removedByOtherActor\":true}".utf8).write(to:f.directory.appendingPathComponent("catalog.json"))
        let removed = MetadataCatalogSnapshot(catalogSessionID:f.session,catalogGeneration:2,
            persistedReference:try PhotoMetadataFiles.reference(f.directory.appendingPathComponent("catalog.json")),assets:[])
        let other = PhotoMetadataRepository(directory:f.directory)
        _ = try await other.reconcile(removed)
        let before = try #require(try await f.repository.record(assetID:f.id))
        #expect(before.isOrphaned)
        let search = await f.repository.searchState()
        _ = try await f.repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:before.version),
            mutation:.save(fields:.init(title:"Only this draft changes"),baseConfirmedRevision:before.confirmedRevision)))
        let after = try #require(try await other.record(assetID:f.id))
        #expect(after.isOrphaned && after.confirmed == before.confirmed)
        #expect(after.manualDraft?.fields.title == "Only this draft changes")
        #expect(after.confirmedRevision == before.confirmedRevision)
        #expect(await f.repository.searchState() == search)
        if case .available(let snapshot) = await f.repository.searchState() { #expect(snapshot.confirmedByAssetID[f.id] == nil) }
        else { Issue.record("Expected valid search snapshot without orphan") }
    }
    @Test func draftTypingDoesNotRebuildUnchangedConfirmedSearchSnapshot() async throws {
        let counter = MetadataCounter(); var hooks = PhotoMetadataRepositoryHooks()
        hooks.beforeSearchSnapshot = { counter.increment() }
        let directory = MetadataFixture.directory(), repository = PhotoMetadataRepository(directory:directory,hooks:hooks)
        let f = try MetadataFixture(directory:directory,repository:repository); try await f.bind()
        let before = counter.value
        for index in 0..<20 {
            let v = try await repository.record(assetID:f.id)?.version ?? .absent
            _ = try await repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:v),mutation:.save(fields:.init(title:"Typing \(index)"),baseConfirmedRevision:0)))
        }
        #expect(counter.value == before)
        _ = try await f.confirm(.init(title:"Confirmed")); #expect(counter.value == before+1)
    }

}

final class MetadataFailureSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var enabled:Bool { get { lock.lock(); defer { lock.unlock() }; return flag } set { lock.lock(); flag = newValue; lock.unlock() } }
    func check() throws { if enabled { throw PhotoMetadataError.storageFailure } }
}
struct MetadataFixture: Sendable {
    let directory:URL, original:URL
    let repository:PhotoMetadataRepository
    let id = "photo-a", session = UUID()
    static func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("metadata-tests-\(UUID())",isDirectory:true) }
    init(directory:URL = MetadataFixture.directory(),repository:PhotoMetadataRepository? = nil) throws {
        self.directory = directory; self.repository = repository ?? PhotoMetadataRepository(directory:directory)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let originals = directory.appendingPathComponent("Originals",isDirectory:true)
        try FileManager.default.createDirectory(at:originals,withIntermediateDirectories:true)
        original = originals.appendingPathComponent("image.png")
        try Data("synthetic source".utf8).write(to:original)
    }
    func source(url:URL? = nil) throws -> MetadataSourceReference {
        let url = url ?? original, attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        let fp = MetadataSourceFingerprint(standardizedPath:url.path,modifiedAt:attributes[.modificationDate] as! Date,fileSize:(attributes[.size] as! NSNumber).int64Value)
        return .init(original:fp,nativeStamp:try PhotoMetadataFiles.nativeStamp(fp))
    }
    func analysisSource(includeExtendedNative:Bool = true) throws -> MetadataSourceReference {
        let source = try source(), native = source.nativeStamp!
        let stamp = includeExtendedNative ? native : .init(identity:native.identity,byteCount:native.byteCount,modifiedAt:native.modifiedAt,changedAt:native.changedAt)
        let raster = MetadataRasterIdentity(sha256:String(repeating:"a",count:64),pixelWidth:32,pixelHeight:32,byteCount:4_096,colorProfile:"sRGB",orientation:"up",preprocessingVersion:1)
        return .init(original:source.original,nativeStamp:stamp,analyzedRaster:.init(providerID:"fake-vision",modelID:"test",analyzedAt:Date(),source:source.original,raster:raster,analysisTaskVersion:1,analysisSchemaVersion:1,metadataPromptVersion:1,metadataSchemaVersion:1))
    }
    func snapshot(source:MetadataSourceReference,generation:Int,assetID:String? = nil) throws -> MetadataCatalogSnapshot {
        .init(catalogSessionID:session,catalogGeneration:generation,persistedReference:try PhotoMetadataFiles.reference(directory.appendingPathComponent("catalog.json")),assets:[.init(assetID:assetID ?? id,source:source)])
    }
    func bind(source:MetadataSourceReference? = nil,generation:Int = 1) async throws {
        try Data("{\"syntheticCatalogGeneration\":\(generation)}".utf8).write(to:directory.appendingPathComponent("catalog.json"))
        _ = try await repository.reconcile(snapshot(source:source ?? self.source(),generation:generation))
    }
    func confirm(_ fields:PhotoTextFields,tagPolicy:MetadataTagPolicy = .append) async throws -> MetadataCommitResult {
        let row = try await repository.record(assetID:id), version = row?.version ?? .absent
        let known = await repository.catalogByID[id]
        let source = try known ?? self.source()
        return try await repository.confirm(.init(header:.init(assetID:id,expectedVersion:version),values:fields,fields:Set(PhotoMetadataField.allCases),tagPolicy:tagPolicy,source:source,
            origin:.manual(expectedManualDraftRevision:row?.manualDraft?.revision,reviewedConfirmedRevision:version.confirmedRevision)))
    }
}
func metadataError(_ expected:PhotoMetadataError,_ body:() async throws -> Void) async {
    do { try await body(); Issue.record("Expected \(expected)") } catch { #expect(error as? PhotoMetadataError == expected) }
}

final class MetadataCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value:Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
