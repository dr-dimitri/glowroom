import Foundation
import Testing
@testable import GlowroomCore

@Suite("Editing remap participant journals and immutable commands")
struct EditingRemapTests {
    @Test func prepareIsReadOnlyForSourcesAndInspectionNeverCreatesMissingEvidence() async throws {
        let f = try await EditingRemapFixture()
        let prepared = try await f.fixture.repository.prepareAssetRemap(f.verified,preparingBy:f.preparation)
        let before = try Data(contentsOf:f.fixture.repository.fileURL)
        let inspection = try #require(try await f.fixture.repository.inspectAssetRemap(prepared.operationID,expectedRequestSHA256:prepared.requestSHA256))
        #expect(inspection.phase == .prepared && inspection.databaseReceipt == nil)
        #expect(try Data(contentsOf:f.fixture.repository.fileURL) == before)
        #expect(try await f.fixture.repository.inspectAssetRemap(.init(),expectedRequestSHA256:prepared.requestSHA256) == nil)
        #expect(try Data(contentsOf:f.fixture.repository.fileURL) == before)
        #expect(try await f.fixture.repository.loadState().byAsset[f.oldID] == f.stored)
        await editingError(.conflictingCommit) {_ = try await f.fixture.repository.inspectAssetRemap(prepared.operationID,expectedRequestSHA256:.init(sha256:String(repeating:"f",count:64)))}
    }
    @Test func remapCommitAndCatalogCompletionReplayExactOriginalStateAfterRestart() async throws {
        let f = try await EditingRemapFixture()
        let prepared = try await f.fixture.repository.prepareAssetRemap(f.verified,preparingBy:f.preparation)
        let receipt = try await f.fixture.repository.remapAssets(prepared,armedBy:f.armed())
        #expect(receipt.state.byAsset[f.oldID] == nil)
        #expect(receipt.state.byAsset[f.newID]?.snapshot == f.stored.snapshot)
        #expect(receipt.state.tombstones[f.oldID]! > f.stored.version.revision)
        #expect(receipt.state.byAsset[f.newID]!.version.revision > f.stored.version.revision)
        let restarted = f.fixture.reopen()
        let recovered = try #require(try await restarted.inspectAssetRemap(prepared.operationID,expectedRequestSHA256:prepared.requestSHA256))
        #expect(recovered.phase == .databaseCommitted)
        #expect(recovered.databaseReceipt?.state.byAsset == receipt.state.byAsset)
        let publication = f.publication()
        try await restarted.confirmCatalogRemap(recovered.prepared,publication:publication)
        let completed = try await restarted.completeAssetRemap(recovered.prepared,publication:publication)
        #expect(completed.state.byAsset == receipt.state.byAsset)
        #expect(try await restarted.completeAssetRemap(recovered.prepared,publication:publication).state.tombstones == receipt.state.tombstones)
        let stored = try #require(receipt.state.byAsset[f.newID])
        _ = try await restarted.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:2)),for:f.newID,expected:.init(stored),revision:9)
        let replay = try await restarted.remapAssets(recovered.prepared,armedBy:f.armed())
        #expect(replay.state.byAsset[f.newID] == stored)
        #expect(try await restarted.loadState().byAsset[f.newID]?.version.revision == 9)
    }
    @Test func preparedAbortRequiresPositivePrearmEvidenceAndReleasesSourceFence() async throws {
        let f = try await EditingRemapFixture(),repo = f.fixture.repository
        let prepared = try await repo.prepareAssetRemap(f.verified,preparingBy:f.preparation)
        do {_ = try await repo.saveSnapshot(EditingSnapshot(),for:f.oldID,expected:.init(f.stored),revision:2);Issue.record("Prepared source must be fenced")}catch{}
        let decision = CatalogCoordinationAbort(journal:f.journal(phase:.prepared,disposition:.aborted),nonce:UUID())
        try await repo.cancelPreparedAssetRemap(prepared,abortedBy:decision)
        #expect(try await repo.inspectAssetRemap(prepared.operationID,expectedRequestSHA256:prepared.requestSHA256)?.phase == .aborted)
        _ = try await repo.saveSnapshot(EditingSnapshot(),for:f.oldID,expected:.init(f.stored),revision:2)
        do {_ = try await repo.remapAssets(prepared,armedBy:f.armed());Issue.record("Aborted command must never execute")}catch{}
    }
    @Test func changedDestinationAndSourceAfterPreparedNeverOverwriteEdits() async throws {
        let f = try await EditingRemapFixture(),repo = f.fixture.repository
        let prepared = try await repo.prepareAssetRemap(f.verified,preparingBy:f.preparation)
        try Data([8,7,6,5]).write(to:f.newURL)
        do {_ = try await repo.remapAssets(prepared,armedBy:f.armed());Issue.record("Fresh source proof must reject changed pixels")}catch{}
        #expect(try await repo.loadState().byAsset[f.oldID] == f.stored)
        #expect(try await repo.loadState().byAsset[f.newID] == nil)
        #expect(try await repo.inspectAssetRemap(prepared.operationID,expectedRequestSHA256:prepared.requestSHA256)?.databaseReceipt == nil)
    }
    @Test func legacyParticipantInspectionDoesNotMigrateOrRecreate() async throws {
        let f = try EditingFixture();try editingLegacy(f.directory)
        let before = try Data(contentsOf:f.repository.fileURL)
        do {_ = try await f.repository.inspectParticipantIdentity();Issue.record("Legacy identity is not yet established")}
        catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
        #expect(try Data(contentsOf:f.repository.fileURL) == before)
        do {_ = try await f.repository.inspectAssetRemap(.init(),expectedRequestSHA256:ArtifactDigest(sha256:String(repeating:"a",count:64)));Issue.record("Legacy inspection must not create a journal")}
        catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
        #expect(try Data(contentsOf:f.repository.fileURL) == before)
    }
}

struct EditingRemapFixture:Sendable {
    let fixture:EditingFixture,oldID:String,newID:String,newURL:URL,stored:StoredEditingState,verified:VerifiedAssetRemap
    let body:CatalogCoordinationRequestBody,coordinatorSHA:ArtifactDigest
    var preparation:CatalogParticipantPreparation {.init(journal:journal(phase:.prepared),nonce:UUID())}
    init(settings: EditSettings = EditSettings(exposure: 1)) async throws {
        let f = try EditingFixture();fixture = f
        oldID = f.original.standardizedFileURL.path
        let initial = try await f.repository.loadState()
        stored = try await f.repository.saveSnapshot(EditingSnapshot(settings:settings),for:oldID,expected:.init(storeEpoch:initial.storeEpoch,revision:nil,snapshot:nil),revision:1)
        let raw = try AssetRemapVerifier.capture(f.original,referenceDate:Date(timeIntervalSinceReferenceDate:750_000_000.123.nextUp))
        let previous = try OriginalSourceFingerprint(standardizedPath:raw.standardizedPath,fileSize:raw.fileSize,modifiedAt:raw.modifiedAt,nativeRevision:raw.nativeRevision,resourceIdentifier:raw.resourceIdentifier,volumeIdentifier:raw.volumeIdentifier,contentSHA256:ArtifactJSONCodec.digestBytes(Data([1,2,3,4])))
        let oldBookmark = try f.directory.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil)
        let next = f.directory.appendingPathComponent("Moved",isDirectory:true);try FileManager.default.createDirectory(at:next,withIntermediateDirectories:true)
        newURL = next.appendingPathComponent("original.bin");newID = newURL.standardizedFileURL.path
        try FileManager.default.moveItem(at:f.original,to:newURL)
        let relocated = try AssetRemapVerifier.capture(newURL,referenceDate:raw.modifiedAt)
        let id = EditingRemapID(),after = MetadataCatalogFileReference.present(sha256:String(repeating:"a",count:64),byteCount:4)
        let catalog = CatalogPreparedPayloadIdentity(operationID:id.rawValue,rootOwnerID:UUID(),before:.absent,after:after)
        let proposal = try AssetRemapProposal(operationID:id,catalog:catalog,folderID:UUID(),bookmarkSHA256:ArtifactJSONCodec.digestBytes(oldBookmark),bookmarkData:oldBookmark,resolvedFolderURL:next,catalogSessionID:UUID(),catalogGeneration:1,expectedStoreEpoch:initial.storeEpoch,expectedByAsset:[oldID:.init(stored),newID:try .init(storeEpoch:initial.storeEpoch,revision:nil,snapshot:nil)],entries:[.init(oldAssetID:oldID,newAssetID:newID,relativePath:"original.bin",previous:previous,relocated:relocated)],resolvedBookmarkData:next.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil))
        let digest = try ArtifactJSONCodec.digest(proposal)
        verified = .init(proposal:proposal,verifiedFileEvidenceSHA256:digest)
        let identity = try await f.repository.participantStoreIdentity()
        body = .init(operationID:id.rawValue,catalog:catalog,requiredParticipants:[.init(store:identity,operationID:id.rawValue,requestSchemaVersion:1,requestSHA256:digest,canonicalByteCount:Int64(try ArtifactJSONCodec.encode(proposal).count))])
        coordinatorSHA = try ArtifactJSONCodec.digest(body)
    }
    func journal(phase:CatalogCoordinationPhase,disposition:CatalogCoordinationDisposition = .active) -> ValidatedCatalogCoordinatorJournal {
        .init(value:.init(body:body,requestSHA256:coordinatorSHA,revision:1,phase:phase,disposition:disposition),ownerID:UUID(),nonce:UUID())
    }
    func armed() -> ArmedCatalogCoordination {.init(journal:journal(phase:.armed),nonce:UUID())}
    func publication() -> CatalogPublicationEvidence {.init(journal:journal(phase:.catalogPublished),published:body.catalog.after,nonce:UUID())}
}
