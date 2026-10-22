import Foundation
import Testing
@testable import GlowroomCore
@testable import Glowroom

@Suite("Photo metadata proposal review with durable SQLite", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct PhotoMetadataProposalIntegrationTests {
    @Test(arguments: [false, true], [false, true])
    func manualConfirmationClosesProposalWithoutAdmittingAFailedRetry(edited: Bool, partial: Bool) async throws {
        let fixture = try await ProposalFixture.make(edited: edited)
        defer { fixture.remove() }
        let model = fixture.model()
        try await proposalWait { model.canEditManual }
        let original = try #require(model.record?.draft)
        #expect(model.canConfirmProposal && model.canEditProposal)
        model.editManualFields(.init(title: "Manually confirmed title", description: "Manually confirmed description"))
        try await proposalWait { !model.isSaving }
        model.manualSelection = partial ? [.title] : Set(PhotoMetadataField.allCases)
        model.acceptManualFields()
        try await proposalWait { !model.isSaving }
        #expect(model.record?.confirmed.title == "Manually confirmed title")
        #expect(model.record?.confirmed.description == (partial ? "" : "Manually confirmed description"))
        #expect(model.record?.draft?.state == .outdated && model.proposalState == .outdated)
        #expect(model.record?.draft?.fields == original.fields && model.record?.draft?.source == original.source)
        #expect(!model.canConfirmProposal && !model.canEditProposal)
        #expect(model.canUseProposalAsManual && model.canRejectProposal)
        let version = model.record?.version
        model.acceptProposal()
        #expect(!model.isSaving && !model.hasPendingRetry && model.errorMessage == nil)
        #expect(try await fixture.store.record(assetID: fixture.context.assetID)?.version == version)
        #expect(await model.finishSaving())
    }

    @Test(arguments: [false, true])
    func historicalOpenProposalCannotConfirmAndCanBeExplicitlyReused(edited: Bool) async throws {
        let fixture = try await ProposalFixture.make(edited: edited)
        defer { fixture.remove() }
        let before = try #require(try await fixture.store.record(assetID: fixture.context.assetID))
        _ = try await fixture.store.confirm(.init(header: .init(assetID: before.assetID, expectedVersion: before.version),
            values: .init(title: "New manual confirmation"), fields: [.title], source: .init(original: fixture.source.original),
            origin: .manual(expectedManualDraftRevision: nil, reviewedConfirmedRevision: before.confirmedRevision)))
        // Simulate an older on-disk record, then start a separate repository and
        // UI model. The real repository still enforces its reviewed-basis CAS.
        try await fixture.store.restoreHistoricalOpenProposal(assetID: before.assetID, state: edited ? .edited : .pending)
        let restarted = PhotoMetadataRepository(directory: fixture.directory)
        _ = try await restarted.recoverCatalogChanges(persistedCatalog: fixture.snapshot())
        let model = fixture.model(store: restarted)
        try await proposalWait { model.canEditManual }
        let old = try #require(model.record), draft = try #require(old.draft)
        #expect(draft.state == (edited ? .edited : .pending))
        #expect(draft.baseConfirmedRevision < old.confirmedRevision && model.proposalState == .outdated)
        #expect(!model.canConfirmProposal && !model.canEditProposal)
        #expect(model.canUseProposalAsManual && model.canRejectProposal)
        model.acceptProposal()
        model.editProposalFields(.init(title: "Must not edit a stale proposal"))
        #expect(!model.isSaving && !model.hasPendingRetry)
        #expect(try await restarted.record(assetID: old.assetID) == old)

        model.useProposalAsManual()
        try await proposalWait { !model.isSaving }
        #expect(model.manualFields == draft.fields && model.record?.confirmed.title == "New manual confirmation")
        #expect(model.canConfirmManual)
        model.acceptManualFields()
        try await proposalWait { !model.isSaving }
        #expect(model.record?.confirmed == draft.fields)
        #expect(model.record?.confirmedProvenance.title == .manual)
        #expect(model.record?.confirmedProvenance.description == .manual)
        #expect(model.record?.confirmedProvenance.tags.allSatisfy { $0.origin == .manual } == true)
        #expect(model.record?.draft?.source == draft.source)
        #expect(model.record?.draft?.editedFields == draft.editedFields)
        #expect(model.proposalState == .outdated && !model.hasPendingRetry && model.errorMessage == nil)
        #expect(await model.finishSaving())
    }

    @Test func newlyRequestedProposalUsesCurrentConfirmationAndCanBeConfirmed() async throws {
        let fixture = try await ProposalFixture.make(edited: false)
        defer { fixture.remove() }
        let suggestor = ProposalIntegrationSuggestor(source: fixture.source)
        let model = fixture.model(suggestor: suggestor)
        try await proposalWait { model.canEditManual }
        let oldID = model.record?.draft?.id
        model.editManualFields(.init(title: "Manual first"))
        try await proposalWait { !model.isSaving }
        model.acceptManualFields()
        try await proposalWait { !model.isSaving }
        await model.refreshAvailability()
        #expect(model.canSuggest)
        model.suggest(refresh: true)
        try await proposalWait { !model.isAnalyzing && !model.isSaving }
        let draft = try #require(model.record?.draft)
        #expect(draft.id != oldID && draft.baseConfirmedRevision == model.record?.confirmedRevision)
        #expect(draft.state == .pending && model.canConfirmProposal)
        #expect(await suggestor.requests.count == 1)
        #expect(await suggestor.requests.first?.expectedVersion.confirmedRevision == 1)
        #expect(await suggestor.requests.first?.rasterPolicy == .refreshRaster)
        model.acceptProposal()
        try await proposalWait { !model.isSaving }
        #expect(model.record?.confirmed.title == "Fresh local suggestion")
        #expect(model.record?.draft?.state == .accepted && !model.hasPendingRetry)
        if case .confirmedAI(let origin) = model.record?.confirmedProvenance.title {
            #expect(origin.draftID == draft.id && origin.analysis == fixture.source.analyzedRaster)
        } else { Issue.record("Missing newly confirmed AI provenance") }
        #expect(await model.finishSaving())
    }
}

private enum ProposalIntegrationFailure: Error { case timeout }
@MainActor private func proposalWait(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw ProposalIntegrationFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct ProposalFixture: Sendable {
    let directory: URL
    let store: PhotoMetadataRepository
    let source: MetadataSourceReference
    let context: PhotoMetadataSelectionContext

    static func make(edited: Bool) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Proposal-Integration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original.png")
        let bytes = Data("synthetic source; no image model required".utf8)
        try bytes.write(to: original)
        let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
        let modifiedAt = try #require(attributes[.modificationDate] as? Date)
        let fingerprint = MetadataSourceFingerprint(standardizedPath: original.path, modifiedAt: modifiedAt, fileSize: Int64(bytes.count))
        let analysis = MetadataAnalysisProvenance(providerID: "synthetic-vision", modelID: "synthetic", analyzedAt: Date(), source: fingerprint,
            raster: .init(sha256: String(repeating: "a", count: 64), pixelWidth: 16, pixelHeight: 16, byteCount: 1024,
                colorProfile: "sRGB", orientation: "up", preprocessingVersion: 1),
            analysisTaskVersion: 1, analysisSchemaVersion: 1, metadataPromptVersion: 1, metadataSchemaVersion: 1)
        let source = MetadataSourceReference(original: fingerprint, analyzedRaster: analysis)
        let store = PhotoMetadataRepository(directory: directory)
        let context = PhotoMetadataSelectionContext(assetID: "photo", source: .init(fileURL: original, modifiedAt: modifiedAt, fileSize: Int64(bytes.count)),
            selectionSessionID: UUID(), selectionGeneration: 1, catalogSessionID: UUID(), catalogGeneration: 1, canModify: true, isClosing: false)
        let catalogURL = directory.appendingPathComponent("catalog.json")
        try Data("{}".utf8).write(to: catalogURL)
        _ = try await store.reconcile(.init(catalogSessionID: context.catalogSessionID, catalogGeneration: 1,
            persistedReference: try PhotoMetadataFiles.reference(catalogURL), assets: [.init(assetID: context.assetID, source: .init(original: fingerprint))]))
        let saved = try await store.saveAIDraft(.init(header: .init(assetID: context.assetID, expectedVersion: .absent),
            mutation: .createSuggested(draftID: UUID(), fields: .init(title: "AI proposal", description: "AI description", tags: ["AI"]), source: source)))
        if edited {
            _ = try await store.saveAIDraft(.init(header: .init(assetID: context.assetID, expectedVersion: saved.currentRecord!.version),
                mutation: .editExisting(draftID: saved.currentRecord!.draft!.id,
                    fields: .init(title: "Human-corrected AI proposal", description: "AI description", tags: ["AI"]))))
        }
        return Self(directory: directory, store: store, source: source, context: context)
    }

    @MainActor func model(store: PhotoMetadataRepository? = nil, suggestor: (any PhotoMetadataSuggesting)? = nil) -> PhotoMetadataModel {
        PhotoMetadataModel(store: store ?? self.store, suggestor: suggestor ?? ProposalIntegrationSuggestor(source: source),
            currentContext: { context }, canModifyLibrary: { true },
            protection: { .init(originalURLs: [], managedFileURLs: [], managedDirectoryURLs: []) })
    }
    func snapshot() throws -> MetadataCatalogSnapshot {
        .init(catalogSessionID: context.catalogSessionID, catalogGeneration: context.catalogGeneration,
            persistedReference: try PhotoMetadataFiles.reference(directory.appendingPathComponent("catalog.json")),
            assets: [.init(assetID: context.assetID, source: .init(original: source.original))])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor ProposalIntegrationSuggestor: PhotoMetadataSuggesting {
    let source: MetadataSourceReference
    private(set) var requests: [PhotoMetadataSuggestionRequest] = []
    init(source: MetadataSourceReference) { self.source = source }
    func availability() async -> ImageAnalysisAvailability { .available }
    func suggest(_ request: PhotoMetadataSuggestionRequest) async throws -> PhotoMetadataSuggestionResult {
        requests.append(request)
        return .init(request: request, fields: .init(title: "Fresh local suggestion"), source: source)
    }
}

private extension PhotoMetadataRepository {
    func restoreHistoricalOpenProposal(assetID: String, state: MetadataDraftState) throws {
        let db = try connection()
        var row = try #require(try readRow(assetID, on: db))
        let draft = try #require(row.draft)
        row.draft = .init(id: draft.id, revision: draft.revision, baseConfirmedRevision: draft.baseConfirmedRevision,
            fields: draft.fields, source: draft.source, state: state, createdAt: draft.createdAt,
            modifiedAt: draft.modifiedAt, editedFields: draft.editedFields)
        try saveRow(row, on: db)
    }
}
