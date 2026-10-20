import Foundation
import Testing
@testable import Glowroom
@testable import GlowroomCore

@Suite("Artifact editing controller", .serialized)
@MainActor
struct ArtifactEditingControllerTests {
    @Test func acceptedCommitSurvivesObserverCancelSelectionAndClosingAndIsOneUndo() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let token = try await f.editor.generationSnapshot(in: f.library)
        let draft = try controllerDraft(token: token, storeID: f.artifacts.storeID)
        await f.artifacts.add(draft.artifact)
        await f.store.blockCommit()
        guard case .accepted(let accepted) = f.editor.applyGeneratedArtifact(draft, expectedSnapshotToken: token) else { Issue.record("expected acceptance"); return }
        try await wait { await f.store.commitStarted }
        let observer = Task { try await accepted.result() }; observer.cancel()
        f.library.selectedID = f.assets[1].id
        f.editor.beginTermination(); f.library.beginTermination()
        await f.store.releaseCommit()
        let receipt = try await observer.value
        #expect(receipt.assetID == f.assets[0].id)
        #expect(await f.editor.flush())
        #expect(f.editor.snapshot(for: f.assets[0].id).source == .artifact(draft.artifact.id))
        #expect(f.editor.snapshot(for: f.assets[1].id).source == .original)
        f.editor.cancelTermination(); f.library.cancelTermination()
        f.library.selectedID = f.assets[0].id
        f.editor.undo(assetID: f.assets[0].id)
        #expect(f.editor.snapshot(for: f.assets[0].id) == token.snapshot)
        #expect(!f.editor.canUndo(assetID: f.assets[0].id))
        #expect(await f.editor.flush())
        f.editor.redo(assetID: f.assets[0].id)
        #expect(f.editor.snapshot(for: f.assets[0].id).source == .artifact(draft.artifact.id))
        #expect(await f.store.commitCount == 1)
    }
    @Test func pendingParentFlushIsExactAndArtifactDoesNotApplyItsSlidersTwice() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = f.assets[0].id
        f.editor.setSettings(EditSettings(exposure: 0.7), for: id)
        let token = try await f.editor.generationSnapshot(in: f.library)
        #expect(token.persistedAtCapture.snapshot == nil && token.localRevision == 1)
        let draft = try controllerDraft(token: token, storeID: f.artifacts.storeID); await f.artifacts.add(draft.artifact)
        guard case .accepted(let accepted) = f.editor.applyGeneratedArtifact(draft, expectedSnapshotToken: token) else { Issue.record("expected acceptance"); return }
        _ = try await accepted.result()
        let parent = try #require(await f.store.lastCommit?.expected)
        #expect(parent.snapshot == token.snapshot && parent.revision == token.localRevision)
        #expect(f.editor.settings(for: id).isNeutral)
        f.editor.setSettings(EditSettings(contrast: 5), for: id)
        #expect(f.editor.snapshot(for: id).source == .artifact(draft.artifact.id))
        f.editor.reset(assetID: id)
        #expect(f.editor.snapshot(for: id).source == .artifact(draft.artifact.id))
        #expect(f.editor.settings(for: id).isNeutral)
        f.editor.returnToOriginal(assetID: id)
        #expect(f.editor.snapshot(for: id).source == .original)
        f.editor.undo(assetID: id)
        #expect(f.editor.snapshot(for: id).source == .artifact(draft.artifact.id))
    }
    @Test func ambiguousReceiptRetryUsesSameCommitAndOnlyOneUndo() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let token = try await f.editor.generationSnapshot(in: f.library)
        let draft = try controllerDraft(token: token, storeID: f.artifacts.storeID); await f.artifacts.add(draft.artifact)
        await f.store.failAfterCommit()
        guard case .accepted(let first) = f.editor.applyGeneratedArtifact(draft, expectedSnapshotToken: token) else { Issue.record("expected acceptance"); return }
        do { _ = try await first.result(); Issue.record("injected error expected") } catch {}
        #expect(f.editor.failedArtifactCommitID == first.id)
        guard case .accepted(let retry) = f.editor.retryAcceptedArtifactCommit(first.id) else { Issue.record("expected retry"); return }
        let result = try await retry.result()
        #expect(result.commitID == first.id)
        #expect(await f.store.commitCount == 1)
        f.editor.undo(assetID: token.assetID)
        #expect(f.editor.snapshot(for: token.assetID) == token.snapshot)
        #expect(!f.editor.canUndo(assetID: token.assetID))
    }
    @Test func selectionABAAndManualChangeRejectUnacceptedDraftWithoutWrites() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let token = try await f.editor.generationSnapshot(in: f.library)
        let draft = try controllerDraft(token: token, storeID: f.artifacts.storeID)
        f.library.selectedID = f.assets[1].id; f.library.selectedID = token.assetID
        guard case .rejected = f.editor.applyGeneratedArtifact(draft, expectedSnapshotToken: token) else { Issue.record("stale ABA accepted"); return }
        let fresh = try await f.editor.generationSnapshot(in: f.library)
        let other = try controllerDraft(token: fresh, storeID: f.artifacts.storeID)
        f.editor.setSettings(EditSettings(exposure: 0.2), for: token.assetID)
        guard case .rejected = f.editor.applyGeneratedArtifact(other, expectedSnapshotToken: fresh) else { Issue.record("stale edit accepted"); return }
        #expect(await f.store.commitCount == 0)
    }
    @Test func typedSourceGeometryCacheIdentityAndOriginalOnlyAnalysisStayDistinct() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let token = try await f.editor.generationSnapshot(in: f.library)
        let draft = try controllerDraft(token: token, storeID: f.artifacts.storeID); await f.artifacts.add(draft.artifact)
        guard case .accepted(let accepted) = f.editor.applyGeneratedArtifact(draft, expectedSnapshotToken: token) else { Issue.record("expected acceptance"); return }
        _ = try await accepted.result()
        let edited = try #require(f.editor.aiSnapshot(in: f.library))
        let original = try #require(f.editor.aiSnapshot(in: f.library, intent: .importedOriginal))
        #expect(edited.persistedVersion != nil && original.persistedVersion == nil)
        if case .artifact = edited.source {} else { Issue.record("artifact source expected") }
        if case .original = original.source {} else { Issue.record("original source expected") }
        let request = PreviewRequest(source: edited.source, pixelSize: 2_400, sourceRevision: "fresh-fixed")
        #expect(request.url == nil && request.resized(to: 512).source == request.source)
        #expect(request.resized(to: 512).sourceRevision == "fresh-fixed")
        #expect(!request.hasSameOriginal(as: PreviewRequest(source: original.source, pixelSize: 2_400)))
        let neutral = try f.editor.resolvedSource(for: f.assets[0], intent: .currentSourceWithoutSettings)
        #expect(neutral.identity == edited.source && neutral.settings.isNeutral)
        try FileManager.default.removeItem(at: f.assets[0].fileURL)
        #expect(try f.editor.resolvedSource(for: f.assets[0]).identity == edited.source)
    }

    @Test func missingArtifactMetadataPreservesActiveSourceAndHasNoOriginalFallback() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let missing = GeneratedArtifactID()
        try await f.store.seed(try EditingSnapshot(source: .artifact(missing)), for: f.assets[0].id)
        do { try await f.editor.reloadAfterCatalogChange(); Issue.record("missing artifact must fail") } catch {}
        #expect(f.editor.snapshot(for: f.assets[0].id).source == .artifact(missing))
        #expect(f.editor.isReadOnly)
        #expect(throws: (any Error).self) { try f.editor.resolvedSource(for: f.assets[0]) }
        let explicitOriginal = try f.editor.resolvedSource(for: f.assets[0], intent: .importedOriginal)
        if case .original = explicitOriginal.identity {} else { Issue.record("explicit original unavailable") }
    }

    @Test func libraryQuitDrainsItsActualInitialLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Artifact-Startup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CatalogRepository(directory: directory)
        try repository.save(LibraryCatalog())
        let gate = CatalogLifecycleGate()
        let library = LibraryModel(repository: repository, lifecycle: gate)
        var entered = false, ended = false
        let drain = Task { entered = true; let result = await library.finishSaving(); ended = true; return result }
        try await wait { entered }
        #expect(!ended)
        _ = try gate.openAfterRecovery()
        #expect(await drain.value)
        #expect(!library.isLoading)
    }

    @Test func failedInitialLoadUsesOnlyExplicitClosedRecoveryAndCanRetry() async throws {
        let store = ControllerEditingStore()
        await store.failLoading(recoveryFailures: 1)
        let editor = EditingModel(loader: {
            EditingModelDependencies(database: store, recoverDatabase: { url in try await store.recoverFixture(from: url) })
        })
        try await wait { !editor.isLoading }
        #expect(editor.isReadOnly)
        #expect(!editor.canBackUp)
        #expect(editor.canRestore)
        #expect(editor.persistedState(for: "A") == nil)
        let backup = URL(fileURLWithPath: "/synthetic-recovery.glowroombackup")
        #expect(!(await editor.restoreBackup(from: backup)))
        #expect(editor.isReadOnly)
        #expect(editor.canRestore)
        #expect(await store.recoveryCount == 1)
        #expect(await store.restoreCount == 0)
        #expect(await editor.restoreBackup(from: backup))
        #expect(await store.recoveryCount == 2)
        #expect(await store.restoreCount == 0)
        #expect(editor.settings(for: "A").exposure == 2)
        #expect(editor.persistedState(for: "A")?.revision == 15)
        #expect(editor.canEdit && editor.canBackUp)
        #expect(editor.notice?.contains("Recovery") == true)
        editor.setSettings(EditSettings(exposure: 3), for: "A")
        #expect(await editor.flush())
        #expect(editor.persistedState(for: "A")?.revision == 16)
    }

    @Test func healthyRestoreKeepsOrdinarySafetyBackupPath() async throws {
        let store = ControllerEditingStore()
        let editor = EditingModel(loader: {
            EditingModelDependencies(database: store, recoverDatabase: { url in try await store.recoverFixture(from: url) })
        })
        try await wait { !editor.isLoading }
        #expect(await editor.restoreBackup(from: URL(fileURLWithPath: "/synthetic-healthy.glowroombackup")))
        #expect(await store.restoreCount == 1)
        #expect(await store.recoveryCount == 0)
    }

    @Test func automaticBackupReleasesFlushSlotAndDrainsLaterPendingSaveBeforePrune() async throws {
        let gate = CatalogLifecycleGate(requiresRecovery: false), store = ControllerEditingStore()
        await store.configureAutomaticBackup(gate: gate)
        let editor = EditingModel(loader: { EditingModelDependencies(database: store, gate: gate) })
        try await wait { !editor.isLoading }
        editor.setSettings(EditSettings(exposure: 1), for: "A")
        editor.setSettings(EditSettings(exposure: 2), for: "B")
        #expect(await editor.flush())
        try await wait { await store.automaticCopyStarted }
        #expect(!editor.isSaving)
        #expect(await store.automaticBackupCount == 1)
        #expect(try await store.loadState().byAsset.count == 2)
        await store.blockNextSnapshotSave()
        editor.setSettings(EditSettings(exposure: 3), for: "B")
        let laterFlush = Task { await editor.flush() }
        try await wait { await store.snapshotSaveWaiting }
        await store.releaseAutomaticCopy()
        try await wait { await store.automaticPruneRequested }
        #expect(!(await store.automaticPruneFinished))
        var finished = false
        let quit = Task { let result = await editor.finishSaving(); finished = true; return result }
        await Task.yield()
        #expect(!finished)
        await store.releaseSnapshotSave()
        #expect(await laterFlush.value)
        #expect(await quit.value)
        #expect(await store.automaticPruneFinished)
        #expect(await store.automaticBackupCount == 1)
        #expect(try await store.loadState().byAsset["B"]?.snapshot.settings.exposure == 3)
    }

    @Test func expandedVariantsReloadAfterRestoreAndIgnoreThePreviousEpochRead() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        defer { Task { await f.store.releaseVariantReads() } }
        let assetID = f.assets[0].id
        let original = try [controllerVariant(assetID: assetID, exposure: 1.25), controllerVariant(assetID: assetID, exposure: 0.5)]
        await f.store.setVariants(original, for: assetID)
        let opened = f.editor.variantsLoadIdentity(assetID: assetID, expanded: true)
        await f.editor.loadVariants(opened)
        #expect(f.editor.variants.map(\.id) == original.map(\.id))
        await f.store.blockNextVariantRead()
        let oldRead = Task { await f.editor.loadVariants(opened) }
        try await wait { await f.store.waitingVariantReads == 1 }
        let restored = try [controllerVariant(assetID: assetID, exposure: -1), controllerVariant(assetID: assetID, exposure: -0.5)]
        await f.store.setVariants(restored, for: assetID)
        await f.store.rotateEpochOnNextRestore()
        #expect(await f.editor.restoreBackup(from: URL(fileURLWithPath: "/synthetic-variants.glowroombackup")))
        let reopened = f.editor.variantsLoadIdentity(assetID: assetID, expanded: true)
        #expect(reopened != opened && reopened.generation != opened.generation && reopened.storeEpoch != opened.storeEpoch)
        #expect(reopened.expanded && reopened.isReady)
        #expect(f.editor.variants.isEmpty && !f.editor.isLoadingVariants)
        // The same still-expanded view now owns a different task key.
        await f.editor.loadVariants(reopened)
        #expect(f.editor.variants.map(\.id) == restored.map(\.id))
        await f.store.releaseVariantReads()
        await oldRead.value
        #expect(f.editor.variants.map(\.id) == restored.map(\.id))
        #expect(!f.editor.isLoadingVariants)
        let readCount = await f.store.variantReadCount
        await f.editor.loadVariants(f.editor.variantsLoadIdentity(assetID: assetID, expanded: false))
        #expect(await f.store.variantReadCount == readCount)
    }

    @Test func variantSelectionABARejectsTheOldReadWithoutBlockingTheNewAsset() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        defer { Task { await f.store.releaseVariantReads() } }
        let a = try controllerVariant(assetID: f.assets[0].id, exposure: 1)
        let b = try controllerVariant(assetID: f.assets[1].id, exposure: -1)
        await f.store.setVariants([a], for: a.assetID)
        await f.store.setVariants([b], for: b.assetID)
        await f.store.blockNextVariantRead()
        let initial = f.editor.variantsLoadIdentity(assetID: a.assetID, expanded: true)
        let oldRead = Task { await f.editor.loadVariants(initial) }
        try await wait { await f.store.waitingVariantReads == 1 }
        f.library.selectedID = b.assetID
        await f.editor.loadVariants(f.editor.variantsLoadIdentity(assetID: b.assetID, expanded: true))
        #expect(f.editor.variants.map(\.id) == [b.id])
        f.library.selectedID = a.assetID
        let returned = f.editor.variantsLoadIdentity(assetID: a.assetID, expanded: true)
        #expect(returned != initial && returned.selectionGeneration != initial.selectionGeneration)
        await f.store.releaseVariantReads()
        await oldRead.value
        #expect(f.editor.variants.map(\.id) == [b.id], "The delayed first A read cannot publish after A -> B -> A")
        await f.editor.loadVariants(returned)
        #expect(f.editor.variants.map(\.id) == [a.id])
        #expect(!f.editor.isLoadingVariants)
    }

    @Test func catalogReloadInvalidatesAnExpandedVariantKeyBeforeAnotherRead() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let assetID = f.assets[0].id
        let first = try controllerVariant(assetID: assetID, exposure: 1)
        await f.store.setVariants([first], for: assetID)
        let initial = f.editor.variantsLoadIdentity(assetID: assetID, expanded: true)
        await f.editor.loadVariants(initial)
        let next = try controllerVariant(assetID: assetID, exposure: 2)
        await f.store.setVariants([next], for: assetID)
        try await f.editor.reloadAfterCatalogChange()
        let refreshed = f.editor.variantsLoadIdentity(assetID: assetID, expanded: true)
        #expect(refreshed != initial && refreshed.generation != initial.generation)
        let reads = await f.store.variantReadCount
        await f.editor.loadVariants(initial)
        #expect(await f.store.variantReadCount == reads)
        await f.editor.loadVariants(refreshed)
        #expect(f.editor.variants.map(\.id) == [next.id])
    }

    private func fixture() async throws -> ControllerFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Artifact-Controller-" + UUID().uuidString)
        let photos = directory.appendingPathComponent("Photos"); try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: photos)
        let assets = try ["A", "B"].map { name in
            let url = photos.appendingPathComponent(name + ".png"); try Data([1]).write(to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return PhotoAsset(folderID: folder.id, fileURL: url, fileSize: 1, modifiedAt: attributes[.modificationDate] as! Date)
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog")); try repository.save(.init(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository), store = ControllerEditingStore(), artifacts = ControllerArtifactStore()
        let editor = EditingModel(loader: { EditingModelDependencies(database: store, artifacts: artifacts) })
        try await wait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = assets[0].id; editor.library = library
        return ControllerFixture(directory: directory, assets: assets, library: library, editor: editor, store: store, artifacts: artifacts)
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) { guard ContinuousClock.now < deadline else { throw ArtifactContractError.limitExceeded }; try await Task.sleep(for: .milliseconds(5)) }
    }
}

private struct ControllerFixture {
    let directory: URL; let assets: [PhotoAsset]; let library: LibraryModel; let editor: EditingModel
    let store: ControllerEditingStore; let artifacts: ControllerArtifactStore
}
private func controllerVariant(assetID: String, exposure: Double) throws -> EditingVariant {
    EditingVariant(id: .init(), assetID: assetID, snapshot: try EditingSnapshot(settings: EditSettings(exposure: exposure)), createdAt: .distantPast)
}
private func controllerDraft(token: GenerationSnapshotToken, storeID: ArtifactStoreID) throws -> ArtifactDraft {
    let hash = try ArtifactDigest(sha256: String(repeating: "a", count: 64)), size = try ArtifactPixelSize(width: 2, height: 2)
    let format = ArtifactRasterFormat(size: size, bitDepth: .eight, channels: .rgba, profile: .sRGB, iccSHA256: hash)
    let provenance = try GenerationProvenance(parentSource: token.source, parentSnapshot: token.snapshot,
        renderedInput: .init(format: format, canonicalPixelSHA256: hash, pipelineVersion: 1),
        placement: .init(inputSize: size, outputSize: size, inputOriginX: 0, inputOriginY: 0),
        pipelineVersion: 1, parameterVersion: 1, parameters: .init(values: []), provider: .init(providerID: "synthetic-test"),
        createdAt: .distantPast, execution: .local)
    let artifact = try GeneratedArtifact(id: .init(), raster: .init(format: format, file: .init(sha256: hash, bytes: 64)), provenance: provenance, manifestSHA256: hash)
    let ownership = ArtifactLease(storeID: storeID, artifactIDs: [artifact.id], purpose: .draft, nonce: UUID(), releaseOwnership: {})
    return ArtifactDraft(id: .init(), artifact: artifact, ownerID: storeID, nonce: UUID(), ownership: ownership)
}

private actor ControllerEditingStore: EditingPersistence {
    private var epoch = UUID(), values: [String: StoredEditingState] = [:]
    private var receipts: [EditingCommitID: ArtifactCommitReceipt] = [:]
    private var blocked = false, failAfter = false, loadFailure = false
    private var recoveryFailures = 0
    private(set) var recoveryCount = 0, restoreCount = 0
    private var automaticGate: CatalogLifecycleGate?
    private var automaticCopyContinuation: CheckedContinuation<Void, Never>?
    private var snapshotSaveContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockSnapshotSave = false
    private(set) var automaticCopyStarted = false, automaticPruneRequested = false, automaticPruneFinished = false
    private(set) var automaticBackupCount = 0, snapshotSaveWaiting = false
    private var variantsByAsset: [String: [EditingVariant]] = [:]
    private var shouldBlockVariantRead = false, shouldRotateRestoreEpoch = false
    private var variantReadContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var variantReadCount = 0
    var waitingVariantReads: Int { variantReadContinuations.count }
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var commitStarted = false
    private(set) var commitCount = 0
    private(set) var lastCommit: GenerationCommitRequest?
    func seed(_ snapshot: EditingSnapshot, for assetID: String) throws {
        values[assetID] = StoredEditingState(snapshot: snapshot, version: try .init(storeEpoch: epoch, revision: 1))
    }
    func blockCommit() { blocked = true }
    func releaseCommit() { blocked = false; continuation?.resume(); continuation = nil }
    func failAfterCommit() { failAfter = true }
    func failLoading(recoveryFailures: Int) { loadFailure = true; self.recoveryFailures = recoveryFailures }
    func loadState() throws -> EditingStoreState {
        guard !loadFailure else { throw ArtifactContractError.corruptArtifact }
        return try .init(storeEpoch: epoch, byAsset: values, tombstones: [:])
    }
    func recoverFixture(from url: URL) throws -> EditingStoreState {
        recoveryCount += 1
        guard recoveryCount > recoveryFailures else { throw ArtifactContractError.corruptArtifact }
        loadFailure = false; epoch = UUID()
        values = ["A": StoredEditingState(snapshot: try EditingSnapshot(settings: EditSettings(exposure: 2)),
            version: try .init(storeEpoch: epoch, revision: 15))]
        return try loadState()
    }
    func saveSnapshot(_ snapshot: EditingSnapshot, for assetID: String, expected: EditingExpectedState, revision: Int64) async throws -> StoredEditingState {
        if shouldBlockSnapshotSave {
            shouldBlockSnapshotSave = false; snapshotSaveWaiting = true
            await withCheckedContinuation { snapshotSaveContinuation = $0 }
            snapshotSaveWaiting = false
        }
        let actual = try values[assetID].map { EditingExpectedState($0) } ?? EditingExpectedState(storeEpoch: epoch, revision: nil, snapshot: nil)
        guard actual == expected else { throw ArtifactContractError.staleSnapshot }
        let stored = StoredEditingState(snapshot: snapshot, version: try .init(storeEpoch: epoch, revision: revision)); values[assetID] = stored; return stored
    }
    func commitGenerated(_ request: GenerationCommitRequest) async throws -> ArtifactCommitReceipt {
        commitStarted = true; lastCommit = request
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if let receipt = receipts[request.commitID] { return receipt }
        let snapshot = try EditingSnapshot(source: .artifact(request.draft.artifact.id), settings: .neutral)
        let stored = try await saveSnapshot(snapshot, for: request.assetID, expected: request.expected, revision: request.nextRevision)
        let receipt = ArtifactCommitReceipt(commitID: request.commitID, assetID: request.assetID, requestSHA256: request.requestSHA256,
            previous: request.expected, stored: stored, artifactID: request.draft.artifact.id)
        receipts[request.commitID] = receipt; commitCount += 1
        if failAfter { failAfter = false; throw ArtifactContractError.ambiguousCommit }
        return receipt
    }
    func committed(_ id: EditingCommitID) -> ArtifactCommitReceipt? { receipts[id] }
    func setVariants(_ variants: [EditingVariant], for assetID: String) { variantsByAsset[assetID] = variants }
    func blockNextVariantRead() { shouldBlockVariantRead = true }
    func releaseVariantReads() {
        let waiters = Array(variantReadContinuations.values)
        variantReadContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func rotateEpochOnNextRestore() { shouldRotateRestoreEpoch = true }
    func variants(for assetID: String) async -> [EditingVariant] {
        variantReadCount += 1
        let call = variantReadCount, result = variantsByAsset[assetID] ?? []
        if shouldBlockVariantRead {
            shouldBlockVariantRead = false
            await withCheckedContinuation { variantReadContinuations[call] = $0 }
        }
        return result
    }
    func configureAutomaticBackup(gate: CatalogLifecycleGate) { automaticGate = gate }
    func blockNextSnapshotSave() { shouldBlockSnapshotSave = true }
    func releaseSnapshotSave() { snapshotSaveContinuation?.resume(); snapshotSaveContinuation = nil }
    func releaseAutomaticCopy() { automaticCopyContinuation?.resume(); automaticCopyContinuation = nil }
    func createBackup(automatic: Bool) async throws -> URL {
        if automatic {
            automaticBackupCount += 1
            if let gate = automaticGate {
                // Model the real Core phase split: long immutable copy leaves
                // normal editing open; only the final prune promotes/drains.
                automaticCopyStarted = true
                await withCheckedContinuation { automaticCopyContinuation = $0 }
                automaticPruneRequested = true
                let maintenance = try await gate.promoteCurrentAcceptedWrite(to: .backup(UUID()))
                try await gate.withMaintenance(maintenance) { }
                automaticPruneFinished = true
                try await gate.finishMaintenance(maintenance)
            }
        }
        return URL(fileURLWithPath: "/synthetic-controller.glowroombackup")
    }
    func restoreBackup(from url: URL) throws -> EditingStoreState {
        restoreCount += 1
        if shouldRotateRestoreEpoch {
            shouldRotateRestoreEpoch = false; epoch = UUID()
            values = try values.mapValues { StoredEditingState(snapshot: $0.snapshot, version: try .init(storeEpoch: self.epoch, revision: $0.version.revision)) }
        }
        return try loadState()
    }
    func prepareAssetRemap(_ plan: VerifiedAssetRemap, preparingBy: CatalogParticipantPreparation) throws -> PreparedAssetRemap { throw ArtifactContractError.unsupportedFormat }
    func inspectAssetRemap(_ id: EditingRemapID, expectedRequestSHA256: ArtifactDigest) -> AssetRemapInspection? { nil }
    func remapAssets(_ prepared: PreparedAssetRemap, armedBy: ArmedCatalogCoordination) throws -> AssetRemapReceipt { throw ArtifactContractError.unsupportedFormat }
    func confirmCatalogRemap(_ prepared: PreparedAssetRemap, publication: CatalogPublicationEvidence) throws { throw ArtifactContractError.unsupportedFormat }
    func completeAssetRemap(_ prepared: PreparedAssetRemap, publication: CatalogPublicationEvidence) throws -> AssetRemapReceipt { throw ArtifactContractError.unsupportedFormat }
    func cancelPreparedAssetRemap(_ prepared: PreparedAssetRemap, abortedBy: CatalogCoordinationAbort) throws { throw ArtifactContractError.unsupportedFormat }
}
private actor ControllerArtifactStore: GeneratedArtifactStoring {
    nonisolated let storeID = ArtifactStoreID()
    private var values: [GeneratedArtifactID: GeneratedArtifact] = [:]
    func add(_ value: GeneratedArtifact) { values[value.id] = value }
    func descriptor(_ id: GeneratedArtifactID) throws -> GeneratedArtifact { guard let value = values[id] else { throw ArtifactContractError.missingArtifact }; return value }
    func acquireLease(ids: Set<GeneratedArtifactID>, purpose: ArtifactLeasePurpose) -> ArtifactLease { ArtifactLease(storeID: storeID, artifactIDs: ids, purpose: purpose, nonce: UUID(), releaseOwnership: {}) }
    func stageRaster(_ input: ArtifactRasterInput, provenance: GenerationProvenance, masks: [ArtifactMaskInput]) throws -> ArtifactDraft { throw ArtifactContractError.unsupportedFormat }
    func publish(_ draft: ArtifactDraft, commitID: EditingCommitID) throws -> PublishedArtifact { throw ArtifactContractError.unsupportedFormat }
    func validatePublication(_ publication: PublishedArtifact) throws { throw ArtifactContractError.unsupportedFormat }
    func openVerifiedRaster(_ id: GeneratedArtifactID) throws -> ArtifactReadHandle { throw ArtifactContractError.missingArtifact }
    func openVerifiedFile(_ id: GeneratedArtifactID, role: ArtifactPayloadRole) throws -> ArtifactFileReadHandle { throw ArtifactContractError.missingArtifact }
    func openVerifiedDraft(_ draft: ArtifactDraft) throws -> ArtifactReadHandle { throw ArtifactContractError.missingArtifact }
    func materialize(_ backup: ValidatedEditingBackup) throws -> PublishedArtifactSet { throw ArtifactContractError.unsupportedFormat }
    func recoverStagingAndReportOrphans(referenced: Set<GeneratedArtifactID>) -> ArtifactRecoveryReport { .init(retainedOrphans: [], removedOwnedStagingCount: 0, unrecognizedEntries: []) }
}
