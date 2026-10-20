import Combine
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Semantic library projection and explicit actions", .serialized, .timeLimit(.minutes(2)))
@MainActor
final class SemanticLibraryTests {
    private let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-SemanticLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func literalAndEmptySemanticQueriesNeverRequestEmbeddingsOrIndex() async throws {
        let (model, service, _, photos) = try await fixture()
        #expect(model.searchMode == .literal)
        model.search = "Nikon"
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[1].id])
        model.searchMode = .semantic
        model.semanticQuery = "   "
        model.semanticLiteralFilter = "Canon"
        await model.waitForProjection()
        #expect(Set(model.visibleAssets.map(\.id)) == Set([photos[0].id, photos[2].id, photos[3].id]))
        #expect(await service.calls.isEmpty)
        #expect(await service.preparedScopes.isEmpty)
        #expect(await service.inspectCount == 0)
        #expect(await service.installCount == 0)
        model.searchMode = .literal
        await model.waitForProjection()
        #expect(model.search == "Nikon" && model.visibleAssets.map(\.id) == [photos[1].id])
        #expect(await model.finishSaving())
    }

    @Test func everyANDFilterRunsBeforeTopKAndRemovedAssetsCannotBeHits() async throws {
        let (model, service, folders, photos) = try await fixture()
        await service.setScores([photos[0].id: 1, photos[1].id: 100, photos[2].id: 90, photos[3].id: 80])
        model.selection = .subfolder(folders[0].id, "Trip")
        model.minimumRating = 4
        model.semanticLiteralFilter = "Canon"
        model.semanticTopK = 1
        model.semanticQuery = "rotes Haus im Schnee"
        model.searchMode = .semantic
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[0].id])
        #expect(await service.calls.last?.candidateIDs == [photos[0].id])
        model.selection = .favorites
        model.semanticLiteralFilter = ""
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[1].id])
        #expect(await service.calls.last?.candidateIDs.count == 2)
        model.removeFolder(folders[0].id)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[3].id])
        #expect(await service.calls.last?.candidateIDs == [photos[3].id])
        #expect(await model.finishSaving())
    }

    @Test func relevanceTiesRespectExistingSortAtTheTopKBoundary() async throws {
        let (model, service, _, photos) = try await fixture()
        model.searchMode = .semantic
        model.semanticQuery = "red house in snow"
        model.semanticTopK = 1
        for sort in PhotoSort.allCases {
            model.sort = sort
            await model.waitForProjection()
            let worker = LibraryProjectionWorker()
            let normal = try await worker.project(model.catalog, generation: 1,
                key: LibraryProjectionKey(selection: .all, query: "", sort: sort, minimumRating: 0), date: Date(), overrides: [:])
            #expect(model.visibleAssets.first?.id == normal.assets.first?.id)
            #expect(await service.calls.last?.candidateIDs == normal.assets.map(\.id))
        }
        model.semanticTopK = 5_000
        await model.waitForProjection()
        #expect(await service.calls.last?.topK == 500)
        #expect(model.visibleAssets.count == photos.count)
        #expect(await model.finishSaving())
    }

    @Test func rapidQueryRoundTripRejectsNoncooperativeEarlierReplies() async throws {
        let (model, service, _, photos) = try await fixture(blocked: true)
        model.searchMode = .semantic
        model.semanticQuery = "rot"
        try await wait { await service.calls.count >= 1 }
        let a = try #require(await service.calls.last)
        model.semanticQuery = "blue"
        try await wait { await service.calls.count >= 2 }
        let b = try #require(await service.calls.last)
        model.semanticQuery = "rot"
        try await wait { await service.calls.count >= 3 }
        let current = try #require(await service.calls.last)
        await service.complete(a.id, only: photos[0].id)
        await service.complete(b.id, only: photos[1].id)
        #expect(model.isProjecting)
        await service.complete(current.id, only: photos[2].id)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[2].id])
        #expect(model.semanticQuery == "rot")
        #expect(await model.finishSaving())
    }

    @Test func catalogChangeDuringSearchCannotPublishRemovedSource() async throws {
        let (model, service, folders, photos) = try await fixture(blocked: true)
        model.searchMode = .semantic; model.semanticQuery = "Haus"
        try await wait { await service.calls.count >= 1 }
        let old = try #require(await service.calls.last)
        model.removeFolder(folders[0].id)
        try await wait { await service.calls.count >= 2 }
        let current = try #require(await service.calls.last)
        #expect(current.candidateIDs == [photos[3].id])
        await service.complete(current.id, only: photos[3].id)
        await model.waitForProjection()
        await service.complete(old.id, only: photos[0].id)
        await Task.yield()
        #expect(model.visibleAssets.map(\.id) == [photos[3].id])
        #expect(await model.finishSaving())
    }

    @Test func confirmedMetadataChangesReplaceCandidatesAndRejectAnOldSemanticReply() async throws {
        let folder = LibraryFolder(url: directory.appendingPathComponent("MetadataPhotos"), subdirectoryPaths: ["Empty"])
        let photos = [PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent("first.raw")),
                      PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent("second.raw"))]
        let repository = CatalogRepository(directory: directory.appendingPathComponent("MetadataCatalog"))
        try repository.save(.init(folders: [folder], assets: photos))
        let metadata = PhotoMetadataRepository(directory: repository.directory)
        let service = SemanticLibraryFake(blocked: true)
        let model = LibraryModel(repository: repository, semanticSearch: service, metadataStore: metadata)
        try await wait { !model.isLoading && !model.isProjecting }
        func confirm(_ asset: PhotoAsset, title: String) async throws {
            let version = try await metadata.record(assetID: asset.id)?.version ?? .absent
            _ = try await metadata.confirm(.init(header: .init(assetID: asset.id, expectedVersion: version),
                values: .init(title: title), fields: [.title], source: MetadataCatalogSources.source(asset),
                origin: .manual(expectedManualDraftRevision: nil, reviewedConfirmedRevision: version.confirmedRevision)))
        }
        try await confirm(photos[0], title: "Wald")
        try await confirm(photos[1], title: "Meer")
        let initial = await metadata.searchState().version
        try await wait { model.metadataGeneration == initial }
        model.semanticLiteralFilter = "Wald"; model.semanticQuery = "trees"; model.searchMode = .semantic
        try await wait { await service.calls.last?.candidateIDs == [photos[0].id] }
        let old = try #require(await service.calls.last)
        let catalog = model.catalog
        try await confirm(photos[0], title: "Meer")
        try await confirm(photos[1], title: "Wald")
        try await wait { await service.calls.last?.candidateIDs == [photos[1].id] }
        let current = try #require(await service.calls.last)
        #expect(current.id != old.id)
        #expect(model.catalog == catalog, "A text generation does not mutate the image catalog or request an index rebuild")
        #expect(await service.preparedScopes.isEmpty)
        await service.complete(current.id, only: photos[1].id)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[1].id])
        await service.complete(old.id, only: photos[0].id)
        await Task.yield()
        #expect(model.visibleAssets.map(\.id) == [photos[1].id], "An uncooperative reply cannot restore former metadata candidates")
        model.beginTermination()
        #expect(await model.finishSaving())
    }

    @Test func explicitIndexScopeUsesFullCandidatesAndImportRequiresOwnConfirmation() async throws {
        let (model, service, folders, _) = try await fixture()
        model.selection = .folder(folders[0].id)
        model.searchMode = .semantic; model.semanticQuery = "snow"; model.semanticTopK = 1
        await model.waitForProjection()
        #expect(model.visibleAssets.count == 1)
        #expect(await service.preparedScopes.isEmpty)
        model.prepareSemanticIndex()
        try await wait { await service.preparedScopes.count == 1 && model.semanticOperationLabel == nil }
        #expect(await service.preparedScopes.first?.count == 3)
        #expect(model.semanticActiveScopeLabel?.contains("3 Bilder") == true)
        model.semanticScope = .all
        model.prepareSemanticIndex(rebuild: true)
        try await wait { await service.preparedScopes.count == 2 && model.semanticOperationLabel == nil }
        #expect(await service.preparedScopes.last?.count == 4)
        #expect(await service.rebuilds.last == true)
        let source = directory.appendingPathComponent("approved-local-package")
        model.inspectSemanticModel(source: source)
        try await wait { model.semanticImportReview != nil }
        let review = try #require(model.semanticImportReview)
        #expect(await service.installCount == 0)
        model.installSemanticModel(reviewID: UUID())
        #expect(model.semanticImportReview == review)
        model.dismissSemanticImport(id: UUID())
        #expect(model.semanticImportReview == review)
        model.installSemanticModel(reviewID: review.id)
        try await wait { await service.installCount == 1 && model.semanticOperationLabel == nil }
        #expect(model.semanticImportReview == nil)
        model.deleteSemanticIndex()
        try await wait { await service.deleteCount == 1 && model.semanticOperationLabel == nil }
        #expect(await model.finishSaving())
    }

    @Test func unavailableSearchIsHonestAndLiteralReturnStillWorks() async throws {
        let (model, service, _, photos) = try await fixture()
        await service.setUnavailable()
        model.searchMode = .semantic; model.semanticQuery = "blue"
        await model.waitForProjection()
        #expect(model.visibleAssets.isEmpty)
        #expect(model.semanticError == SemanticEmbeddingError.unavailable(.modelNotInstalled).localizedDescription)
        model.searchMode = .literal
        await model.waitForProjection()
        #expect(model.visibleAssets.count == photos.count)
        #expect(model.semanticError == nil)
        #expect(await model.finishSaving())
    }

    @Test func terminationCancelsQueriesAndQuiescesServiceWithoutBreakingCanceledExit() async throws {
        let (model, service, _, _) = try await fixture(blocked: true)
        model.searchMode = .semantic; model.semanticQuery = "Haus"
        try await wait { await service.calls.count >= 1 }
        model.beginTermination()
        #expect(await model.finishSaving())
        #expect(await service.shutdownCount == 1)
        #expect(!model.isProjecting && model.isClosing)
        await service.setBlocked(false)
        model.cancelTermination()
        await model.waitForProjection()
        #expect(!model.visibleAssets.isEmpty && !model.isClosing)
        #expect(await model.finishSaving())
    }

    @Test func canceledExitKeepsASettledLiteralProjectionImmediatelyAvailable() async throws {
        let (model, service, _, _) = try await fixture(opensControls: false)
        let visible = model.visibleAssets.map(\.id)
        model.beginTermination()
        model.beginTermination()
        model.cancelTermination()
        // Do not yield: synchronous AI snapshot admission must work immediately.
        #expect(!model.isClosing && !model.isProjecting)
        #expect(model.visibleAssets.map(\.id) == visible)
        #expect(await service.calls.isEmpty)
        #expect(await service.statusCount == 0)
        #expect(await model.finishSaving())
    }

    @Test func canceledExitResumesAnInterruptedLiteralProjectionEvenAfterRepeatedClosing() async throws {
        let (model, _, _, photos) = try await fixture(opensControls: false)
        model.search = "Nikon"
        #expect(model.isProjecting)
        model.beginTermination()
        model.beginTermination()
        #expect(!model.isProjecting)
        model.cancelTermination()
        #expect(model.isProjecting)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[1].id])
        #expect(await model.finishSaving())
    }

    @Test func canceledExitProjectsFilterChangesMadeWhileClosing() async throws {
        let (model, _, _, photos) = try await fixture(opensControls: false)
        model.beginTermination()
        model.search = "Nikon"
        model.beginTermination()
        #expect(model.isClosing && !model.isProjecting)
        model.cancelTermination()
        #expect(model.isProjecting)
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[1].id])
        #expect(await model.finishSaving())
    }

    @Test func canceledExitResumesADeferredRecentExpiration() async throws {
        let initial = Date(timeIntervalSince1970: 2_000_000_000)
        var date = initial
        let folder = LibraryFolder(url: directory.appendingPathComponent("DeferredRecent"),
            addedAt: initial.addingTimeInterval(-7 * 86_400 + 10), subdirectoryPaths: ["Empty"])
        let photo = PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent("recent.png"))
        let repository = CatalogRepository(directory: directory.appendingPathComponent("DeferredCatalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [photo]))
        let model = LibraryModel(repository: repository, now: { date })
        try await wait { !model.isLoading && !model.isProjecting }
        model.selection = .recent
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photo.id])
        date = initial.addingTimeInterval(11)
        _ = model.visibleAssets // Schedules deferred work without starting it.
        #expect(!model.isProjecting)
        model.beginTermination()
        model.beginTermination()
        await Task.yield()
        #expect(model.isClosing && !model.isProjecting)
        model.cancelTermination()
        #expect(model.isProjecting)
        await model.waitForProjection()
        #expect(model.visibleAssets.isEmpty)
        #expect(await model.finishSaving())
    }

    @Test func recentSemanticCandidatesExpireAndRecoverOnClockReversal() async throws {
        let initial = Date(timeIntervalSince1970: 2_000_000_000)
        var date = initial
        let expiring = LibraryFolder(url: directory.appendingPathComponent("Recent"),
            addedAt: initial.addingTimeInterval(-7 * 86_400 + 10), subdirectoryPaths: ["Empty"])
        let old = LibraryFolder(url: directory.appendingPathComponent("Old"),
            addedAt: initial.addingTimeInterval(-7 * 86_400 - 1), subdirectoryPaths: ["Empty"])
        let photos = [PhotoAsset(folderID: expiring.id, fileURL: expiring.url.appendingPathComponent("a.png")),
                      PhotoAsset(folderID: old.id, fileURL: old.url.appendingPathComponent("b.png"))]
        let repository = CatalogRepository(directory: directory.appendingPathComponent("RecentCatalog"))
        try repository.save(LibraryCatalog(folders: [expiring, old], assets: photos))
        let service = SemanticLibraryFake(blocked: false)
        let model = LibraryModel(repository: repository, now: { date }, semanticSearch: service)
        try await wait { !model.isLoading && !model.isProjecting }
        model.selection = .recent; model.searchMode = .semantic; model.semanticQuery = "rotes Haus"
        await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [photos[0].id])
        date = initial.addingTimeInterval(10)
        await model.waitForProjection()
        #expect(model.visibleAssets.isEmpty)
        #expect(await service.calls.last?.candidateIDs.isEmpty == true)
        date = initial.addingTimeInterval(-2)
        await model.waitForProjection()
        #expect(Set(model.visibleAssets.map(\.id)) == Set(photos.map(\.id)))
        #expect(await model.finishSaving())
    }

    @Test func readOnlyCatalogCannotStartIndexOrImportAndExistingFileSurvives() async throws {
        let repository = CatalogRepository(directory: directory.appendingPathComponent("ReadOnlyCatalog"))
        try FileManager.default.createDirectory(at: repository.directory, withIntermediateDirectories: true)
        let original = Data("unrecognized-catalog".utf8)
        try original.write(to: repository.fileURL)
        let service = SemanticLibraryFake(blocked: false)
        let model = LibraryModel(repository: repository, semanticSearch: service)
        try await wait { !model.isLoading }
        #expect(model.isReadOnly && !model.canManageSemanticSearch)
        model.prepareSemanticIndex(); model.deleteSemanticIndex()
        model.inspectSemanticModel(source: directory.appendingPathComponent("package"))
        await Task.yield()
        #expect(await service.preparedScopes.isEmpty)
        #expect(await service.inspectCount == 0)
        #expect(await service.deleteCount == 0)
        #expect(try Data(contentsOf: repository.fileURL) == original)
        #expect(await model.finishSaving())
    }

    @Test func workerRejectsForeignAndNonfiniteResultsRatherThanExpandingCandidates() async throws {
        let (model, _, _, photos) = try await fixture()
        let worker = LibraryProjectionWorker(), session = UUID()
        let candidates = try await worker.candidates(model.catalog, snapshotSessionID: session, generation: 3,
            key: LibraryProjectionKey(selection: .all, query: "Canon", sort: .name, minimumRating: 0), date: Date(), overrides: [:])
        let descriptor = SemanticLibraryFake.descriptorValue
        for hit in [SemanticSearchHit(assetID: photos[1].id, score: 1), SemanticSearchHit(assetID: photos[0].id, score: .nan)] {
            let result = SemanticSearchResult(catalogSessionID: session, catalogGeneration: 3, indexGenerationID: UUID(),
                modelDescriptor: descriptor, candidateAssetIDs: candidates.assets.map(\.id), hits: [hit])
            do { _ = try await worker.rank(candidates, result: result, topK: 100); Issue.record("Invalid hit accepted") }
            catch { #expect(error as? SemanticEmbeddingError == .invalidVector) }
        }
        #expect(await model.finishSaving())
    }

    @Test func literalTypingWithCollapsedControlsDoesNotScanTheSemanticIndex() async throws {
        let (model, service, _, _) = try await fixture(opensControls: false)
        for term in ["N", "Ni", "Nik", "Niko", "Nikon", "Canon", ""] {
            model.search = term
            await model.waitForProjection()
        }
        #expect(await service.statusCount == 0)
        #expect(await service.calls.isEmpty)
        model.semanticControlsExpanded = true
        try await wait { model.semanticScopeIsReady }
        #expect(await service.statusCount > 0)
        let count = await service.statusCount
        model.semanticControlsExpanded = false
        model.search = "Nikon"
        await model.waitForProjection()
        #expect(await service.statusCount == count)
        #expect(await model.finishSaving())
    }

    private func fixture(blocked: Bool = false, opensControls: Bool = true) async throws -> (LibraryModel, SemanticLibraryFake, [LibraryFolder], [PhotoAsset]) {
        let a = LibraryFolder(url: directory.appendingPathComponent("A"), subdirectoryPaths: ["Trip"])
        let b = LibraryFolder(url: directory.appendingPathComponent("B"), subdirectoryPaths: ["Empty"])
        let photos = [
            PhotoAsset(folderID: a.id, fileURL: a.url.appendingPathComponent("Trip/Zebra.png"), createdAt: Date(timeIntervalSince1970: 1), cameraModel: "Canon", rating: 4),
            PhotoAsset(folderID: a.id, fileURL: a.url.appendingPathComponent("Trip/Alpha.png"), createdAt: Date(timeIntervalSince1970: 3), cameraModel: "Nikon", rating: 5, isFavorite: true),
            PhotoAsset(folderID: a.id, fileURL: a.url.appendingPathComponent("Beta.png"), createdAt: Date(timeIntervalSince1970: 2), cameraModel: "Canon", rating: 2),
            PhotoAsset(folderID: b.id, fileURL: b.url.appendingPathComponent("Gamma.png"), createdAt: Date(timeIntervalSince1970: 4), cameraModel: "Canon", rating: 5, isFavorite: true)
        ]
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [a,b], assets: photos))
        let service = SemanticLibraryFake(blocked: blocked)
        let model = LibraryModel(repository: repository, semanticSearch: service)
        let readiness = TestStateSignal(SemanticFixtureReadiness(ready: false, detail: "awaiting model publishers"))
        let observation = Publishers.CombineLatest4(model.$isLoading, model.$isProjecting,
                                                    model.$semanticState, model.$semanticScopeIsReady)
            .sink { loading, projecting, semantic, scopeReady in
                readiness.update { $0 = SemanticFixtureReadiness(
                    ready: !loading && !projecting && (!opensControls || (semantic.version == 1 && scopeReady)),
                    detail: "loading=\(loading), projecting=\(projecting), version=\(semantic.version), scopeReady=\(scopeReady)") }
            }
        defer { observation.cancel() }
        model.semanticControlsExpanded = opensControls
        try await readiness.wait("semantic library fixture ready", timeout: .seconds(5), until: { $0.ready })
        return (model, service, [a,b], photos)
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "semantic library state transition", lastState: "condition remains false")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct SemanticFixtureReadiness: Sendable {
    let ready: Bool
    let detail: String
}

private actor SemanticLibraryFake: SemanticSearchServing {
    struct Call: Sendable { let id: UUID; let query: String; let candidateIDs: [String]; let topK: Int }
    nonisolated static let descriptorValue = SemanticModelDescriptor(modelID: "synthetic-paired", sourceRevision: "fixture-v1", releaseID: "fixture-v1", dimension: 2, maximumTextTokens: 64, tokenizerVersion: "v1", preprocessingVersion: 1, normalizationVersion: 1)
    private let indexID = UUID()
    private var session: UUID?
    private var generation = -1
    private var blocked: Bool
    private var available = true
    private var scores: [String: Float] = [:]
    private var pending: [UUID: (SemanticSearchResult, CheckedContinuation<SemanticSearchResult, Error>)] = [:]
    private(set) var calls: [Call] = []
    private(set) var preparedScopes: [[String]] = []
    private(set) var rebuilds: [Bool] = []
    private(set) var statusCount = 0
    private(set) var inspectCount = 0
    private(set) var installCount = 0
    private(set) var deleteCount = 0
    private(set) var shutdownCount = 0
    init(blocked: Bool) { self.blocked = blocked }
    func setScores(_ values: [String: Float]) { scores = values }
    func setUnavailable() { available = false }
    func setBlocked(_ value: Bool) { blocked = value }
    func updateCatalog(snapshotSessionID: UUID, generation: Int, assets: [PhotoAsset]) {
        if let session, session != snapshotSessionID { return }
        guard generation >= self.generation else { return }
        session = snapshotSessionID; self.generation = generation
    }
    func search(query: String, candidates: [PhotoAsset], topK: Int) async throws -> SemanticSearchResult {
        guard available else { throw SemanticEmbeddingError.unavailable(.modelNotInstalled) }
        let id = UUID()
        calls.append(Call(id: id, query: query, candidateIDs: candidates.map(\.id), topK: topK))
        let ordered = candidates.enumerated().sorted {
            let lhs = scores[$0.element.id, default: 1], rhs = scores[$1.element.id, default: 1]
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }
        let result = SemanticSearchResult(catalogSessionID: session!, catalogGeneration: generation, indexGenerationID: indexID,
            modelDescriptor: Self.descriptorValue, candidateAssetIDs: candidates.map(\.id),
            hits: ordered.prefix(topK).map { .init(assetID: $0.element.id, score: scores[$0.element.id, default: 1]) })
        if !blocked { return result }
        return try await withCheckedThrowingContinuation { pending[id] = (result,$0) }
    }
    func complete(_ id: UUID, only assetID: String) {
        guard let (result, continuation) = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: SemanticSearchResult(catalogSessionID: result.catalogSessionID,
            catalogGeneration: result.catalogGeneration, indexGenerationID: result.indexGenerationID,
            modelDescriptor: result.modelDescriptor, candidateAssetIDs: result.candidateAssetIDs,
            hits: [.init(assetID: assetID, score: 1)]))
    }
    func status(scope: [PhotoAsset]) -> SemanticSearchState {
        statusCount += 1
        return SemanticSearchState(version: 1, availability: available ? .available : .unavailable(.modelNotInstalled),
            indexGenerationID: indexID, indexedCount: scope.count, totalCount: scope.count, staleCount: 0,
            missingCount: 0, processedCount: 0, isIndexing: false, notice: nil,
            modelDescriptor: Self.descriptorValue, installedBytes: 100)
    }
    func updates() -> AsyncStream<SemanticSearchState> { AsyncStream { $0.finish() } }
    func prepareIndex(scope: [PhotoAsset], rebuild: Bool) { preparedScopes.append(scope.map(\.id)); rebuilds.append(rebuild) }
    func cancelIndexing() {}
    func deleteIndex() { deleteCount += 1 }
    func inspectModel(source: URL) -> SemanticModelImportReview {
        inspectCount += 1
        return SemanticModelImportReview(id: UUID(), sourceURL: source, descriptor: Self.descriptorValue,
            sourceBytes: 100, maximumInstalledBytes: 1_073_741_824, stagingBytesRequired: 3_221_225_472,
            licenses: [.init(title: "Synthetic fixture", text: "No downloaded model")])
    }
    func installModel(_ review: SemanticModelImportReview) { installCount += 1 }
    func removeModel() {}
    func shutdown() {
        shutdownCount += 1
        for (_, continuation) in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
}
