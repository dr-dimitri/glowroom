import Foundation
import Testing
@testable import PicEditCore
@testable import PicEdit

@Suite("Semantic service scheduling, source identity and maintenance")
struct SemanticSearchServiceTests {
    @Test(.timeLimit(.minutes(1))) func catalogRemovalDrainsNativeIndexWorkAndReaddingCannotRestoreCachedVectors() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(image:true)
        let indexing = Task { try await f.service.prepareIndex(scope:f.photos,rebuild:true) }
        // An async event is the precondition. A loaded test executor must not
        // continue merely because a short polling deadline elapsed.
        defer { indexing.cancel(); Task { await f.provider.unblock() } }
        try await f.provider.waitForFirstImageCall()
        let updates = await f.service.updates()
        let removing = Task { try await f.service.purgeRemovedAssets(retaining:[f.photos[1].id]) }
        var maintenanceEntered = false
        for await state in updates {
            if state.availability == .unavailable(.busy) { maintenanceEntered = true; break }
        }
        try #require(maintenanceEntered,"Catalog cleanup must enter maintenance before assertions")
        // Cancellation cannot release a running encoder or delete its SQL rows
        // until the native call has actually returned.
        #expect(await searchBudgetState(f.budget).activeInferences == 1)
        #expect(await f.provider.unloads == 0)
        #expect(try await f.store.records(in:f.generation!).map(\.assetID) == ["a","b"])
        await f.provider.unblock()
        await searchErrorAny([.cancelled,.superseded]) { try await indexing.value }
        try await removing.value
        #expect(await searchBudgetState(f.budget).activeInferences == 0)
        #expect(await f.provider.unloads == 1)
        #expect(try await f.store.records(in:f.generation!).map(\.assetID) == ["b"])
        await searchError(.superseded) {
            _ = try await f.service.search(query:"removed",candidates:[f.photos[0]],topK:1)
        }

        // A newly composed service sees only retained vectors. Reintroducing
        // the same catalog asset requires fresh indexing, even after restart.
        let restartedStore = try SemanticIndexStore(directory:f.store.fileURL.deletingLastPathComponent())
        let restarted = SemanticSearchService(store:restartedStore,installer:f.installer,providerFactory:{ _ in f.provider },preparer:f.preparer,budget:f.budget)
        await restarted.updateCatalog(snapshotSessionID:f.session,generation:3,assets:f.photos)
        let status = try await restarted.status(scope:f.photos)
        #expect(status.indexedCount == 1 && status.missingCount == 1)
        #expect(try await restartedStore.metadata(in:f.generation!,assetIDs:["a"]).isEmpty)
        #expect(await f.provider.imageCalls == 1)
    }

    @Test func explicitIndexUsesOneImageJobAndFindsPairedGermanEnglishWithoutNames() async throws {
        let f = try await SearchFixture.make(seed: false)
        #expect(await f.provider.imageCalls == 0)
        try await f.service.prepareIndex(scope: f.photos, rebuild: false)
        #expect(await f.provider.imageCalls == 2)
        #expect(await f.provider.maximumActive == 1)
        let german = try await f.service.search(query: " rotes HAUS ", candidates: f.photos, topK: 1)
        let english = try await f.service.search(query: "red house", candidates: f.photos, topK: 1)
        #expect(german.hits.map(\.assetID) == ["a"])
        #expect(english.hits.map(\.assetID) == ["a"])
        #expect(await f.provider.texts == ["rotes haus", "red house"])
        #expect(german.candidateAssetIDs == ["a", "b"])
        #expect(german.catalogSessionID == f.session)
        #expect(german.catalogGeneration == 1)
        #expect(try await f.service.status(scope: f.photos).indexedCount == 2)
        #expect(await f.preparer.maximumStatJobs <= 2)
        // Resume skips both unchanged sources rather than decoding again.
        try await f.service.prepareIndex(scope: f.photos, rebuild: false)
        #expect(await f.provider.imageCalls == 2)
    }

    @Test func sourceStampChunksCoverEveryCandidateAndFreshFinalHit() async throws {
        let f = try await SearchFixture.make(photoCount: 257)
        await f.preparer.setMissing(f.photos[0].fileURL.path)
        let status = try await f.service.status(scope: f.photos)
        #expect(status.indexedCount == 256 && status.missingCount == 1)
        let initial = await f.preparer.takeStampBatches()
        #expect(initial.map(\.count).sorted() == [1, 64, 64, 64, 64])
        #expect(initial.flatMap { $0 }.sorted() == f.photos.map { $0.fileURL.path }.sorted())
        let result = try await f.service.search(query: "house", candidates: f.photos, topK: 100)
        #expect(result.hits.count == 100 && !result.hits.contains { $0.assetID == f.photos[0].id })
        let query = await f.preparer.takeStampBatches()
        #expect(query.count == 7 && query.allSatisfy { (1...64).contains($0.count) })
        #expect(query.flatMap { $0 }.count == 357) // 257 candidate and 100 final-hit checks.

        let small = try await SearchFixture.make()
        await small.preparer.changeAfterNextBatch(small.photos[0].fileURL.path)
        let changed = try await small.service.search(query: "house", candidates: small.photos, topK: 1)
        #expect(changed.hits.isEmpty)
        #expect(await small.preparer.takeStampBatches().map(\.count) == [2, 1])
    }

    @Test func malformedBatchCountCannotBecomeSearchResults() async throws {
        let f = try await SearchFixture.make()
        await f.preparer.malformNextBatch()
        await searchError(.providerFailure) { _ = try await f.service.search(query: "house", candidates: f.photos, topK: 1) }
    }

    @Test func batchesSinglesAndPreparationShareTwoSlotsUntilActualReturn() async throws {
        let base = SearchPreparationAdmissionProbe(), admission = SemanticPreparationAdmission(base)
        let source = AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/synthetic/source"), modifiedAt: Date(timeIntervalSince1970: 123), fileSize: 1)
        let batch = Task { try await admission.sourceStamps(sources: Array(repeating: source, count: 64)) }
        let preparation = Task { try await admission.prepare(source: source, priority: .thumbnail) }
        await searchEventually { await base.active == 2 }
        let single = Task { try await admission.sourceStamp(source: source) }
        await searchEventually { await admission.schedulingState().waiting == 1 }
        let cancelledPending = Task { try await admission.sourceStamps(sources: [source]) }
        await searchEventually { await admission.schedulingState().waiting == 2 }
        cancelledPending.cancel()
        await searchError(.cancelled) { _ = try await cancelledPending.value }
        #expect(await admission.schedulingState().waiting == 1)
        #expect(await base.started == 2)
        batch.cancel()
        #expect(await admission.schedulingState().active == 2)
        #expect(await admission.schedulingState().waiting == 1)
        #expect(await base.started == 2) // Cancellation cannot release a busy slot.
        await base.releaseBatch()
        await #expect(throws: CancellationError.self) { _ = try await batch.value }
        await searchEventually { await base.started == 3 }
        #expect(await base.maximumActive == 2)
        await base.releaseRemaining()
        _ = try await preparation.value; _ = try await single.value
        #expect(await admission.schedulingState().active == 0)
        #expect(await base.maximumActive == 2)
    }

    @Test func normalizedTextCacheIsBoundedAndIndependentOfCandidateOrder() async throws {
        let f = try await SearchFixture.make()
        _ = try await f.service.search(query: " HOUSE ", candidates: f.photos, topK: 1)
        let reversed = try await f.service.search(query: "house", candidates: Array(f.photos.reversed()), topK: 2)
        #expect(await f.provider.texts == ["house"])
        #expect(reversed.hits.map(\.assetID) == ["a", "b"])
        for index in 0..<64 { _ = try await f.service.search(query: "q\(index)", candidates: f.photos, topK: 1) }
        _ = try await f.service.search(query: "house", candidates: f.photos, topK: 1)
        #expect(await f.provider.texts.count == 66)
        _ = try await f.service.search(query: " Q63 ", candidates: f.photos, topK: 1)
        #expect(await f.provider.texts.count == 66)
    }

    @Test func invalidProviderVectorIsNeverCached() async throws {
        let f = try await SearchFixture.make(); await f.provider.failNextVector()
        await searchError(.invalidVector) { _ = try await f.service.search(query: "retry", candidates: f.photos, topK: 1) }
        #expect(try await f.service.search(query: "retry", candidates: f.photos, topK: 1).hits.map(\.assetID) == ["a"])
        #expect(await f.provider.texts == ["retry", "retry"])
    }

    @Test func committedActivationRegistersEvenWhenCancellationRacesCommitReturn() async throws {
        let cancellation = SearchCommitCancellation()
        let f = try await SearchFixture.make(beforeCommit: { cancellation.check() })
        // prepare generation, upsert one record, then activation. Cancellation
        // inside the final transaction must not turn its committed result into
        // an old service generation or a reported rollback.
        cancellation.arm(after: 3)
        try await f.service.prepareIndex(scope: [f.photos[0]], rebuild: true)
        let committed = try #require(await f.store.activeGeneration())
        #expect(committed.id != f.generation?.id)
        let stream = await f.service.updates(); var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.indexGenerationID == committed.id)
    }

    @Test func exactQueryDeduplicatesAndCancellingOneWaiterKeepsNativeLease() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(text: true)
        let first = Task { try await f.service.search(query: "same", candidates: f.photos, topK: 1) }
        await searchEventually { await f.provider.texts.count == 1 }
        let second = Task { try await f.service.search(query: "same", candidates: f.photos, topK: 1) }
        await searchEventually { await f.service.schedulingState().waiters == 2 }
        first.cancel()
        await searchError(.cancelled) { _ = try await first.value }
        #expect(await searchBudgetState(f.budget).activeInferences == 1)
        #expect(await f.provider.texts.count == 1)
        await f.provider.unblock()
        #expect(try await second.value.hits.map(\.assetID) == ["a"])
        #expect(await f.provider.maximumActive == 1)
        #expect(await searchBudgetState(f.budget).activeInferences == 0)
    }

    @Test func alreadyCancelledSearchCannotInvalidateActualQuery() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(text: true)
        let current = Task { try await f.service.search(query: "current", candidates: f.photos, topK: 1) }
        await searchEventually { await f.provider.texts.count == 1 }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.service.search(query: "cancelled", candidates: f.photos, topK: 1)
        }
        await searchError(.cancelled) { _ = try await cancelled.value }
        await f.provider.unblock()
        #expect(try await current.value.hits.map(\.assetID) == ["a"])
        #expect(await f.provider.texts == ["current"])
    }

    @Test func alreadyCancelledStatusCannotInvalidateLiveStatus() async throws {
        let f = try await SearchFixture.make()
        _ = try await f.service.status(scope: f.photos)
        await f.provider.blockOneAvailability()
        let current = Task { try await f.service.status(scope: f.photos) }
        await searchEventually { await f.provider.pendingAvailability == 1 }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.service.status(scope: [f.photos[1]])
        }
        await searchError(.cancelled) { _ = try await cancelled.value }
        await f.provider.releaseAvailability()
        #expect(try await current.value.indexedCount == 2)
    }

    @Test func staleAvailabilityCannotOverwriteNewInstallationState() async throws {
        let f = try await SearchFixture.make()
        _ = try await f.service.status(scope: f.photos)
        await f.provider.blockOneAvailability(returning: .unavailable(.invalidInstallation))
        let stale = Task { try await f.service.status(scope: f.photos) }
        await searchEventually { await f.provider.pendingAvailability == 1 }
        let review = try await f.service.inspectModel(source: URL(fileURLWithPath: "/synthetic/package"))
        try await f.service.installModel(review)
        await f.provider.releaseAvailability()
        await searchError(.superseded) { _ = try await stale.value }
        // Publishing a new catalog must retain the newer installation's
        // availability without first refreshing it through another status call.
        await f.service.updateCatalog(snapshotSessionID: f.session, generation: 2, assets: f.photos)
        let stream = await f.service.updates(); var iterator = stream.makeAsyncIterator()
        let current = try #require(await iterator.next())
        #expect(current.availability == .available)
        #expect(current.modelDescriptor == f.model.descriptor)
        #expect(current.installedBytes == f.model.installedBytes)
    }

    @Test func twentyRapidQueriesRetainActualAndOnlyLatestPending() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(text: true)
        var previous = Task { try await f.service.search(query: "actual", candidates: f.photos, topK: 1) }
        await searchEventually { await f.provider.texts.count == 1 }
        for index in 1...20 {
            let next = Task { try await f.service.search(query: "pending\(index)", candidates: f.photos, topK: 1) }
            await searchError(.superseded) { _ = try await previous.value }
            previous = next
        }
        #expect(await f.provider.texts == ["actual"])
        #expect(await searchBudgetState(f.budget).activeInferences == 1)
        await f.provider.unblock()
        #expect(try await previous.value.hits.map(\.assetID) == ["a"])
        #expect(await f.provider.texts == ["actual", "pending20"])
        #expect(await f.provider.maximumActive == 1)
    }

    @Test func cancelledOnlyWaiterDoesNotStartReplacementBeforeActualReturn() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(text: true)
        let first = Task { try await f.service.search(query: "first", candidates: f.photos, topK: 1) }
        await searchEventually { await f.provider.texts.count == 1 }
        first.cancel(); await searchError(.cancelled) { _ = try await first.value }
        let next = Task { try await f.service.search(query: "next", candidates: f.photos, topK: 1) }
        await searchEventually { await f.service.schedulingState().pending == 1 }
        #expect(await f.provider.texts == ["first"])
        #expect(await searchBudgetState(f.budget).activeInferences == 1)
        await f.provider.unblock(); _ = try await next.value
        #expect(await f.provider.texts == ["first", "next"])
    }

    @Test func strongSourceChangesAndRemovedCandidatesCannotAppear() async throws {
        let f = try await SearchFixture.make()
        await f.preparer.change(f.photos[0].fileURL.path)
        let result = try await f.service.search(query: "house", candidates: f.photos, topK: 2)
        #expect(result.hits.map(\.assetID) == ["b"])
        let status = try await f.service.status(scope: f.photos)
        #expect(status.staleCount == 1)
        #expect(status.indexedCount == 1)
        await f.service.updateCatalog(snapshotSessionID: f.session, generation: 2, assets: [f.photos[1]])
        let removed = try await f.service.search(query: "house", candidates: [f.photos[1]], topK: 2)
        #expect(removed.hits.map(\.assetID) == ["b"])
        #expect(removed.catalogGeneration == 2)
        // Original cached mapping remains available if its source is restored.
        #expect(try await f.store.records(in: f.generation!).count == 2)
    }

    @Test func catalogEpochRejectsLateQueriesAndOlderOrForeignSnapshots() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(text: true)
        let query = Task { try await f.service.search(query: "first", candidates: f.photos, topK: 1) }
        await searchEventually { await f.provider.texts.count == 1 }
        await f.service.updateCatalog(snapshotSessionID: f.session, generation: 2, assets: [f.photos[1]])
        await searchError(.superseded) { _ = try await query.value }
        await f.service.updateCatalog(snapshotSessionID: UUID(), generation: 999, assets: f.photos)
        await f.service.updateCatalog(snapshotSessionID: f.session, generation: 1, assets: f.photos)
        await f.provider.unblock()
        let current = try await f.service.search(query: "next", candidates: [f.photos[1]], topK: 1)
        #expect(current.catalogGeneration == 2)
        #expect(current.candidateAssetIDs == ["b"])
        await searchError(.superseded) { _ = try await f.service.search(query: "next", candidates: f.photos, topK: 1) }
    }

    @Test func scopeValidationKeepsEquivalentURLsAndRejectsEachChangedSourceField() async throws {
        let f = try await SearchFixture.make()
        let original = f.photos[0]
        func photo(url: URL, date: Date, size: Int64) -> PhotoAsset {
            PhotoAsset(id: original.id, folderID: original.folderID, fileURL: url, fileSize: size, modifiedAt: date)
        }
        // Decoded/imported values may retain a noncanonical spelling; the
        // regular PhotoAsset initializer itself already canonicalizes URLs.
        var equivalent = original
        equivalent.fileURL = URL(string: "file:///synthetic/unused/../opaque-a.png")!
        #expect(equivalent.fileURL != original.fileURL)
        #expect(try await f.service.search(query: "house", candidates: [equivalent], topK: 1).hits.map(\.assetID) == [original.id])
        let changed = [
            photo(url: original.fileURL, date: original.modifiedAt.addingTimeInterval(1), size: original.fileSize),
            photo(url: original.fileURL, date: original.modifiedAt, size: original.fileSize + 1),
            photo(url: URL(fileURLWithPath: "/synthetic/different.png", isDirectory: false), date: original.modifiedAt, size: original.fileSize)
        ]
        let calls = await f.provider.texts
        for candidate in changed {
            await searchError(.superseded) { _ = try await f.service.search(query: "changed", candidates: [candidate], topK: 1) }
        }
        #expect(await f.provider.texts == calls)
    }

    @Test func inputBoundsAndMissingIndexDoNotPerformInference() async throws {
        let f = try await SearchFixture.make(seed: false)
        for query in ["", "  \n ", String(repeating: "ä", count: 1_025)] {
            await searchError(.invalidInput) { _ = try await f.service.search(query: query, candidates: f.photos, topK: 100) }
        }
        await searchError(.invalidInput) { _ = try await f.service.search(query: "x", candidates: f.photos, topK: 501) }
        await searchError(.indexUnavailable) { _ = try await f.service.search(query: "x", candidates: f.photos, topK: 1) }
        #expect(await f.provider.texts.isEmpty)
        #expect(await f.provider.imageCalls == 0)
    }

    @Test func missingAndChangedSourcesPreserveRowsWithoutBecomingHits() async throws {
        let f = try await SearchFixture.make()
        await f.preparer.setMissing(f.photos[0].fileURL.path)
        let result = try await f.service.search(query: "house", candidates: f.photos, topK: 2)
        #expect(result.hits.map(\.assetID) == ["b"])
        #expect(try await f.service.status(scope: f.photos).missingCount == 1)
        try await f.service.prepareIndex(scope: f.photos, rebuild: false)
        #expect(try await f.store.records(in: f.generation!).count == 2)
    }

    @Test func changedDuringNativeImageWorkCannotCommit() async throws {
        let f = try await SearchFixture.make(seed: false); await f.provider.block(image: true)
        let indexing = Task { try await f.service.prepareIndex(scope: [f.photos[0]], rebuild: false) }
        await searchEventually { await f.provider.imageCalls == 1 }
        await f.preparer.change(f.photos[0].fileURL.path)
        await f.provider.unblock()
        try await indexing.value
        let active = try #require(await f.store.activeGeneration())
        #expect(try await f.store.records(in: active).isEmpty)
    }

    @Test func cancelledRebuildPreservesOldGenerationAndLeaseUntilNativeReturn() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(image: true)
        let indexing = Task { try await f.service.prepareIndex(scope: f.photos, rebuild: true) }
        await searchEventually { await f.provider.imageCalls == 1 }
        await f.service.cancelIndexing()
        #expect(await searchBudgetState(f.budget).activeInferences == 1)
        #expect(try await f.store.activeGeneration() == f.generation)
        await f.provider.unblock()
        await searchErrorAny([.cancelled, .superseded]) { try await indexing.value }
        #expect(try await f.store.activeGeneration() == f.generation)
        #expect(try await f.store.records(in: f.generation!).count == 2)
    }

    @Test func deleteAndShutdownWaitForNativeReturnAndShutdownIsReusable() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(text: true)
        let query = Task { try await f.service.search(query: "blocked", candidates: f.photos, topK: 1) }
        await searchEventually { await f.provider.texts.count == 1 }
        let closing = Task { await f.service.shutdown() }
        await searchError(.superseded) { _ = try await query.value }
        #expect(await f.provider.unloads == 0)
        #expect(await searchBudgetState(f.budget).activeInferences == 1)
        await f.provider.unblock(); await closing.value
        #expect(await f.provider.unloads == 1)
        _ = try await f.service.search(query: "again", candidates: f.photos, topK: 1)
        await f.provider.block(text: true)
        let second = Task { try await f.service.search(query: "delete", candidates: f.photos, topK: 1) }
        await searchEventually { await f.provider.texts.count == 3 }
        let deleting = Task { try await f.service.deleteIndex() }
        await searchError(.superseded) { _ = try await second.value }
        #expect(try await f.store.activeGeneration() == f.generation)
        #expect(await f.provider.unloads == 1)
        await f.provider.unblock(); try await deleting.value
        #expect(await f.provider.unloads == 2)
        #expect(try await f.store.activeGeneration() == nil)
    }

    @Test func installationFingerprintMismatchCannotReuseOldIndexOrCache() async throws {
        let f = try await SearchFixture.make()
        _ = try await f.service.search(query: "house", candidates: f.photos, topK: 1)
        let changed = SemanticInstalledModel(directory: f.model.directory, descriptor: f.model.descriptor, installationFingerprint: String(repeating: "b", count: 64), installedBytes: 42)
        await f.installer.setInstalled(changed)
        await searchError(.installationChanged) { _ = try await f.service.search(query: "house", candidates: f.photos, topK: 1) }
        #expect(await f.provider.texts == ["house"])
    }

    @Test(arguments: [SemanticEmbeddingError.invalidInstallation, .installationChanged])
    func imageEncoderIntegrityFailureRemainsUnavailableUntilReimport(_ failure: SemanticEmbeddingError) async throws {
        let f = try await SearchFixture.make()
        #expect(try await f.service.status(scope: f.photos).availability == .available)
        await f.provider.failNextImageInstallation(failure)
        await searchError(failure) { try await f.service.prepareIndex(scope: f.photos, rebuild: true) }
        let stream = await f.service.updates(); var iterator = stream.makeAsyncIterator()
        let failed = try #require(await iterator.next())
        #expect(failed.availability == .unavailable(.invalidInstallation))
        #expect(failed.modelDescriptor == nil && failed.installedBytes == nil)
        let refreshed = try await f.service.status(scope: f.photos)
        #expect(refreshed.availability == .unavailable(.invalidInstallation))
        #expect(refreshed.modelDescriptor == nil && refreshed.installedBytes == nil)
        #expect(try await f.store.activeGeneration() == f.generation)
        #expect(await f.provider.imageCalls == 1)
        await searchError(.invalidInstallation) { _ = try await f.service.search(query: "must not retry bad weights", candidates: f.photos, topK: 1) }
        #expect(await f.provider.texts.isEmpty)
        let review = try await f.service.inspectModel(source: URL(fileURLWithPath: "/synthetic/repaired-package"))
        try await f.service.installModel(review)
        let repaired = try await f.service.status(scope: f.photos)
        #expect(repaired.availability == .available)
        #expect(repaired.modelDescriptor == f.model.descriptor && repaired.installedBytes == f.model.installedBytes)
    }

    @Test func installationHoldsSharedLeaseUntilNoncooperativeCompilerReturns() async throws {
        let f = try await SearchFixture.make()
        _ = try await f.service.search(query: "prime", candidates: f.photos, topK: 1)
        let review = try await f.service.inspectModel(source: URL(fileURLWithPath: "/synthetic/package"))
        await f.installer.blockInstallation()
        let installing = Task { try await f.service.installModel(review) }
        await searchEventually { await f.installer.installs == 1 }
        let competing = Task { try await f.budget.acquireLocalInference() }
        await searchEventually { await searchBudgetState(f.budget).waitingInferences == 1 }
        installing.cancel()
        #expect(await searchBudgetState(f.budget).activeInferences == 1)
        #expect(await searchBudgetState(f.budget).waitingInferences == 1)
        await f.installer.unblockInstallation()
        await searchError(.cancelled) { try await installing.value }
        let lease = try await competing.value
        await f.budget.release(lease)
        #expect(await searchBudgetState(f.budget).activeInferences == 0)
    }

    @Test func statusImportAndRestartPublishOnlyUsableModelMetadata() async throws {
        let f = try await SearchFixture.make()
        let initial = try await f.service.status(scope: f.photos)
        #expect(initial.modelDescriptor == f.model.descriptor)
        #expect(initial.installedBytes == f.model.installedBytes)
        let review = try await f.service.inspectModel(source: URL(fileURLWithPath: "/synthetic/package"))
        try await f.service.installModel(review)
        let imported = try await f.service.status(scope: f.photos)
        #expect(imported.modelDescriptor == f.model.descriptor)
        #expect(imported.installedBytes == f.model.installedBytes)
        let restarted = SemanticSearchService(store: f.store, installer: f.installer, providerFactory: { _ in f.provider }, preparer: f.preparer, budget: f.budget)
        await restarted.updateCatalog(snapshotSessionID: UUID(), generation: 1, assets: f.photos)
        let reloaded = try await restarted.status(scope: f.photos)
        #expect(reloaded.modelDescriptor == f.model.descriptor)
        #expect(reloaded.installedBytes == f.model.installedBytes)
        await f.provider.failNextInstallation()
        await searchError(.invalidInstallation) { _ = try await restarted.search(query: "fail", candidates: f.photos, topK: 1) }
        let rejected = try await restarted.status(scope: f.photos)
        #expect(rejected.availability == .unavailable(.invalidInstallation))
        #expect(rejected.modelDescriptor == nil)
        #expect(rejected.installedBytes == nil)
    }

    @Test(arguments: [true, false])
    func damagedMiddlePhotoDoesNotBlockLaterValidPhotosOrMixSpaces(_ unavailable: Bool) async throws {
        let f = try await SearchFixture.make()
        let last = PhotoAsset(id: "c", folderID: f.photos[0].folderID, fileURL: URL(fileURLWithPath: "/synthetic/opaque-c.png"), fileSize: 42, modifiedAt: Date(timeIntervalSince1970: 123))
        let scope = f.photos + [last]
        await f.service.updateCatalog(snapshotSessionID: f.session, generation: 2, assets: scope)
        await f.preparer.damage(f.photos[1].fileURL.path, unavailable: unavailable)
        let oldSpace = SemanticModelDescriptor(modelID: "previous-paired-space", sourceRevision: "old", releaseID: "old", dimension: 2, maximumTextTokens: 64, tokenizerVersion: "old", preprocessingVersion: 1, normalizationVersion: 1)
        let old = try await f.store.prepareGeneration(for: oldSpace, installationFingerprint: String(repeating: "d", count: 64))
        for record in try await f.store.records(in: f.generation!) {
            try await f.store.upsert(SemanticIndexRecord(assetID: record.assetID, source: record.source, sourceRevision: record.sourceRevision, inputRasterSHA256: record.inputRasterSHA256, vector: Array(record.vector.prefix(2))), in: old)
        }
        try await f.store.activate(old)
        let oldRows = try await f.store.records(in: old)
        try await f.service.prepareIndex(scope: scope, rebuild: false)
        let active = try #require(await f.store.activeGeneration())
        #expect(active.id != old.id)
        #expect(active.descriptor.dimension == 3)
        #expect(active.installationFingerprint == f.model.installationFingerprint)
        #expect(try await f.store.records(in: active).map(\.assetID) == ["a", "c"])
        #expect(try await f.store.records(in: old) == oldRows)
        #expect(await f.provider.imageCalls == 2)
        let stream = await f.service.updates(); var iterator = stream.makeAsyncIterator()
        let finished = try #require(await iterator.next())
        #expect(finished.indexedCount == 2)
        #expect(finished.missingCount == 1)
        #expect(finished.notice?.contains("1 nicht lesbar") == true)
        let result = try await f.service.search(query: "house", candidates: scope, topK: 3)
        #expect(Set(result.hits.map(\.assetID)) == ["a", "c"])
        try await f.service.prepareIndex(scope: scope, rebuild: false)
        #expect(await f.provider.imageCalls == 2)
    }

    @Test func explicitCorruptIndexRebuildPreservesBytesAndReportsQuarantine() async throws {
        let f = try await SearchFixture.make()
        let bytes = Data("synthetic-corrupt-index".utf8)
        try bytes.write(to: f.store.fileURL)
        let rejected = try await f.service.status(scope: f.photos)
        #expect(rejected.availability == .available)
        #expect(rejected.notice?.contains("beschädigt") == true)
        try await f.service.prepareIndex(scope: f.photos, rebuild: true)
        let stream = await f.service.updates(); var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.notice?.contains("aufbewahrt") == true)
        let directory = f.store.fileURL.deletingLastPathComponent()
        let quarantine = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("semantic-index-quarantine-") })
        #expect(try Data(contentsOf: quarantine.appendingPathComponent("semantic-index.sqlite")) == bytes)
    }

    @Test func explicitModelRemoveUnloadsBeforeMutatingFiles() async throws {
        let f = try await SearchFixture.make(); await f.provider.block(text: true)
        let query = Task { try await f.service.search(query: "blocked", candidates: f.photos, topK: 1) }
        await searchEventually { await f.provider.texts.count == 1 }
        let removing = Task { try await f.service.removeModel() }
        await searchError(.superseded) { _ = try await query.value }
        #expect(await f.installer.removals == 0)
        #expect(await f.provider.unloads == 0)
        await f.provider.unblock(); try await removing.value
        #expect(await f.provider.unloads == 1)
        #expect(await f.installer.removals == 1)
        #expect(try await f.service.status(scope: f.photos).availability == .unavailable(.modelNotInstalled))
    }
}

private struct SearchFixture: Sendable {
    let service: SemanticSearchService
    let store: SemanticIndexStore
    let provider: SearchProviderFake
    let installer: SearchInstallerFake
    let preparer: SearchPreparerFake
    let budget: AIResourceBudget
    let session: UUID
    let photos: [PhotoAsset]
    let generation: SemanticIndexGeneration?
    let model: SemanticInstalledModel
    static func make(seed: Bool = true, photoCount: Int = 2, beforeCommit: (@Sendable () throws -> Void)? = nil) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picedit-semantic-service-\(UUID())")
        let descriptor = SemanticModelDescriptor(modelID: "synthetic-paired", sourceRevision: "1", releaseID: "1", dimension: 3, maximumTextTokens: 64, tokenizerVersion: "1", preprocessingVersion: 1, normalizationVersion: 1)
        let model = SemanticInstalledModel(directory: root.appendingPathComponent("fake-model"), descriptor: descriptor, installationFingerprint: String(repeating: "a", count: 64), installedBytes: 42)
        let store: SemanticIndexStore
        if let beforeCommit { store = try SemanticIndexStore(directory: root, beforeCommit: beforeCommit) }
        else { store = try SemanticIndexStore(directory: root) }
        let provider = SearchProviderFake(descriptor: descriptor)
        let installer = SearchInstallerFake(model: model), preparer = SearchPreparerFake(), budget = AIResourceBudget()
        let service = SemanticSearchService(store: store, installer: installer, providerFactory: { _ in provider }, preparer: preparer, budget: budget)
        let session = UUID(), folder = UUID()
        let ids = photoCount == 2 ? ["a", "b"] : (0..<photoCount).map { String(format: "photo-%04d", $0) }
        let photos = ids.map { (id: String) in PhotoAsset(id: id, folderID: folder, fileURL: URL(fileURLWithPath: "/synthetic/opaque-\(id).png"), fileSize: 42, modifiedAt: Date(timeIntervalSince1970: 123)) }
        var generation: SemanticIndexGeneration?
        if seed {
            let g = try await store.prepareGeneration(for: descriptor, installationFingerprint: model.installationFingerprint)
            for (index, photo) in photos.enumerated() {
                let source = AIOriginalSourceFingerprint(fileURL: photo.fileURL, modifiedAt: photo.modifiedAt, fileSize: photo.fileSize)
                try await store.upsert(SemanticIndexRecord(assetID: photo.id, source: source, sourceRevision: "stamp0", inputRasterSHA256: String(repeating: "c", count: 64), vector: index == 0 ? [1, 0, 0] : [0, 1, 0]), in: g)
            }
            try await store.activate(g); generation = g
        }
        await service.updateCatalog(snapshotSessionID: session, generation: 1, assets: photos)
        return Self(service: service, store: store, provider: provider, installer: installer, preparer: preparer, budget: budget, session: session, photos: photos, generation: generation, model: model)
    }
}
private actor SearchProviderFake: SemanticEmbeddingProviding {
    nonisolated let descriptor: SemanticModelDescriptor
    var texts: [String] = [], imageCalls = 0, maximumActive = 0, unloads = 0
    private var active = 0, blockText = false, blockImage = false, invalidNextVector = false, invalidNextInstallation = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var firstImageCallWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var nextImageInstallationFailure: SemanticEmbeddingError?
    private var nextAvailability: SemanticAvailability?
    private var availabilityWaiters: [CheckedContinuation<Void, Never>] = []
    var pendingAvailability: Int { availabilityWaiters.count }
    init(descriptor: SemanticModelDescriptor) { self.descriptor = descriptor }
    func availability() async -> SemanticAvailability {
        let result = nextAvailability ?? .available
        if nextAvailability != nil {
            nextAvailability = nil
            await withCheckedContinuation { availabilityWaiters.append($0) }
        }
        return result
    }
    func blockOneAvailability(returning result: SemanticAvailability = .available) { nextAvailability = result }
    func releaseAvailability() {
        let values = availabilityWaiters; availabilityWaiters.removeAll()
        for value in values { value.resume() }
    }
    func encodeText(_ text: String) async throws -> [Float] {
        texts.append(text); active += 1; maximumActive = max(maximumActive, active)
        if blockText { await withCheckedContinuation { waiting.append($0) } }
        active -= 1
        if invalidNextInstallation { invalidNextInstallation = false; throw SemanticEmbeddingError.invalidInstallation }
        if invalidNextVector { invalidNextVector = false; return [0, 0, 0] }
        return [1, 0, 0]
    }
    func encodeImage(_ input: SemanticImageInput) async throws -> [Float] {
        imageCalls += 1; active += 1; maximumActive = max(maximumActive, active)
        let entered = firstImageCallWaiters; firstImageCallWaiters.removeAll()
        for waiter in entered.values { waiter.resume() }
        if blockImage { await withCheckedContinuation { waiting.append($0) } }
        active -= 1
        if let failure = nextImageInstallationFailure { nextImageInstallationFailure = nil; throw failure }
        return input.values.first == 1 ? [0, 1, 0] : [1, 0, 0]
    }
    func waitForFirstImageCall() async throws {
        try Task.checkCancellation()
        if imageCalls > 0 { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                if Task.isCancelled { continuation.resume(throwing:CancellationError()) }
                else { firstImageCallWaiters[id] = continuation }
            }
        } onCancel:{ Task { await self.cancelFirstImageCallWaiter(id) } }
        try Task.checkCancellation()
    }
    private func cancelFirstImageCallWaiter(_ id:UUID) {
        firstImageCallWaiters.removeValue(forKey:id)?.resume(throwing:CancellationError())
    }
    func unload() async { unloads += 1 }
    func failNextVector() { invalidNextVector = true }
    func failNextInstallation() { invalidNextInstallation = true }
    func failNextImageInstallation(_ failure: SemanticEmbeddingError) { nextImageInstallationFailure = failure }
    func block(text: Bool = false, image: Bool = false) { blockText = text; blockImage = image }
    func unblock() { blockText = false; blockImage = false; let values = waiting; waiting.removeAll(); for value in values { value.resume() } }
}
private actor SearchPreparerFake: SemanticImagePreprocessing {
    private var changed = Set<String>(), missing = Set<String>()
    private var damaged: [String: PreviewFailure] = [:]
    private var statJobs = 0
    var maximumStatJobs = 0
    private var stampBatches: [[String]] = []
    private var changeAfterBatch: String?
    private var malformedBatch = false
    func sourceStamps(sources: [AIOriginalSourceFingerprint]) async throws -> [String?] {
        guard sources.count <= SemanticSourceStampBatch.maximumCount else { throw SemanticEmbeddingError.invalidInput }
        stampBatches.append(sources.map(\.standardizedPath))
        var values: [String?] = []
        for source in sources {
            try Task.checkCancellation()
            do { values.append(try await sourceStamp(source: source)) }
            catch {
                guard error as? SemanticEmbeddingError == .staleSource else { throw error }
                values.append(nil)
            }
        }
        if let path = changeAfterBatch { changed.insert(path); changeAfterBatch = nil }
        if malformedBatch { malformedBatch = false; return [] }
        return values
    }
    func takeStampBatches() -> [[String]] { let result = stampBatches; stampBatches.removeAll(); return result }
    func changeAfterNextBatch(_ path: String) { changeAfterBatch = path }
    func malformNextBatch() { malformedBatch = true }
    func sourceStamp(source: AIOriginalSourceFingerprint) async throws -> String {
        statJobs += 1; maximumStatJobs = max(maximumStatJobs, statJobs)
        await Task.yield(); statJobs -= 1
        if missing.contains(source.standardizedPath) { throw SemanticEmbeddingError.staleSource }
        return changed.contains(source.standardizedPath) ? "stamp1" : "stamp0"
    }
    func prepare(source: AIOriginalSourceFingerprint, priority: PreviewPriority) async throws -> SemanticImageInput {
        if let failure = damaged[source.standardizedPath] { throw failure }
        return SemanticImageInput(values: [source.standardizedPath.contains("opaque-b") ? 1 : 0], rasterSHA256: String(repeating: "c", count: 64), sourceRevision: try await sourceStamp(source: source))
    }
    func change(_ path: String) { changed.insert(path) }
    func setMissing(_ path: String) { missing.insert(path) }
    func damage(_ path: String, unavailable: Bool) { damaged[path] = unavailable ? .unavailable : .unsupportedOrDamaged; changed.insert(path) }
}
private actor SearchInstallerFake: SemanticModelInstalling {
    private var model: SemanticInstalledModel?
    var removals = 0, installs = 0
    private var blocked = false
    private var installWaiter: CheckedContinuation<Void, Never>?
    init(model: SemanticInstalledModel?) { self.model = model }
    func installedModel() async throws -> SemanticInstalledModel? { model }
    func inspect(source: URL) async throws -> SemanticModelImportReview {
        guard let model else { throw SemanticEmbeddingError.invalidInstallation }
        return SemanticModelImportReview(id: UUID(), sourceURL: source, descriptor: model.descriptor, sourceBytes: 42, maximumInstalledBytes: 42, stagingBytesRequired: 42, licenses: [.init(title: "Synthetic license", text: "Fake-only test fixture")])
    }
    func install(_ review: SemanticModelImportReview, progress: @escaping @Sendable (SemanticInstallProgress) -> Void) async throws -> SemanticInstalledModel {
        installs += 1
        if blocked { await withCheckedContinuation { installWaiter = $0 } }
        try Task.checkCancellation()
        guard let model else { throw SemanticEmbeddingError.invalidInstallation }
        return model
    }
    func blockInstallation() { blocked = true }
    func unblockInstallation() { blocked = false; installWaiter?.resume(); installWaiter = nil }
    func remove() async throws { removals += 1; model = nil }
    func setInstalled(_ model: SemanticInstalledModel?) { self.model = model }
}
private func searchError(_ expected: SemanticEmbeddingError, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected \(expected)") } catch { #expect(error as? SemanticEmbeddingError == expected) }
}
private func searchErrorAny(_ expected: Set<SemanticEmbeddingError>, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected failure") } catch { #expect((error as? SemanticEmbeddingError).map(expected.contains) == true) }
}
private func searchEventually(_ condition: () async -> Bool) async {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline { if await condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for deterministic fake operation")
}
private func searchBudgetState(_ budget: AIResourceBudget) async -> AIResourceBudget.State {
    let stream = await budget.stateUpdates(); var iterator = stream.makeAsyncIterator()
    return await iterator.next()!
}

private final class SearchCommitCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var remaining: Int?
    func arm(after count: Int) { lock.withLock { remaining = count } }
    func check() {
        let cancel = lock.withLock {
            guard let count = remaining else { return false }
            remaining = count - 1
            if remaining == 0 { remaining = nil; return true }
            return false
        }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

/// Deliberately noncooperative fake: all three APIs retain their actual slot
/// through cancellation until the test releases the underlying operation.
private actor SearchPreparationAdmissionProbe: SemanticImagePreprocessing {
    private(set) var active = 0, maximumActive = 0, started = 0
    private var batch: CheckedContinuation<Void, Never>?
    private var remaining: [CheckedContinuation<Void, Never>] = []
    private func enter(batch isBatch: Bool) async {
        active += 1; started += 1; maximumActive = max(maximumActive, active)
        await withCheckedContinuation { continuation in
            if isBatch { batch = continuation } else { remaining.append(continuation) }
        }
        active -= 1
    }
    func sourceStamps(sources: [AIOriginalSourceFingerprint]) async throws -> [String?] {
        await enter(batch: true); return sources.map { _ in "stamp" }
    }
    func sourceStamp(source: AIOriginalSourceFingerprint) async throws -> String {
        await enter(batch: false); return "stamp"
    }
    func prepare(source: AIOriginalSourceFingerprint, priority: PreviewPriority) async throws -> SemanticImageInput {
        await enter(batch: false)
        return SemanticImageInput(values: [], rasterSHA256: String(repeating: "c", count: 64), sourceRevision: "stamp")
    }
    func releaseBatch() { batch?.resume(); batch = nil }
    func releaseRemaining() { let values = remaining; remaining.removeAll(); for value in values { value.resume() } }
}
