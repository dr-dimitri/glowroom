import CryptoKit
import Foundation
import GlowroomCore

enum CatalogWriteCheckpoint: Equatable, Sendable { case afterMetadataStage, afterCatalogPublish, afterMetadataComplete }
struct CatalogWriteMetadata: Sendable {
    let reference: MetadataCatalogFileReference
    let reconciliation: MetadataReconciliationResult?
    let error: PhotoMetadataError?
    let changes: [MetadataCatalogChangeReceipt]
    let sequence: UInt64
    let blockedAssetIDs: Set<String>
    let protectedSourceURLs: [URL]
    var cleanupError: String?
    var editingPruned = false
    init(reference: MetadataCatalogFileReference, reconciliation: MetadataReconciliationResult?,
         error: PhotoMetadataError?, changes: [MetadataCatalogChangeReceipt] = [], sequence: UInt64) {
        self.reference = reference; self.reconciliation = reconciliation; self.error = error
        self.changes = changes; self.sequence = sequence
        blockedAssetIDs = Set(changes.flatMap(\.blockedAssetIDs))
        protectedSourceURLs = changes.flatMap(\.protectedSourceURLs)
    }
}

/// The sole catalog writer serializes entire stage/publish/complete operations
/// across metadata awaits. Actor isolation alone would permit later ratings to
/// publish between a relocation journal and its exact expected bytes.
actor CatalogWriter {
    typealias FolderResolver = @Sendable (LibraryFolder) async -> (LibraryFolder, URL?)
    typealias Cleanup = @Sendable (LibraryCatalog, MetadataCatalogFileReference) async throws -> Bool
    let repository: CatalogRepository
    private let lifecycle: CatalogLifecycleGate?
    private let coordinatorLoader: (@Sendable () async throws -> any CatalogMutationCoordinating)?
    private let editingDependencies: (@Sendable () async throws -> EditingModelDependencies)?
    private let verifier = AssetRemapVerifier()
    private let metadata: (any PhotoMetadataStoring)?
    private let sessionID: UUID
    private let resolver: FolderResolver
    private let checkpoint: @Sendable (CatalogWriteCheckpoint) throws -> Void
    private let cleanup: Cleanup?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastRevision = -1
    private var persisted: StoredLibraryCatalog?
    private var changes: [MetadataCatalogChangeReceipt] = []
    private var generation = 0
    private var resultSequence: UInt64 = 0

    init(repository: CatalogRepository, metadataStore: (any PhotoMetadataStoring)? = nil,
         sessionID: UUID = UUID(), folderResolver: FolderResolver? = nil,
         checkpoint: @escaping @Sendable (CatalogWriteCheckpoint) throws -> Void = { _ in },
         lifecycle: CatalogLifecycleGate? = nil,
         coordinator: (@Sendable () async throws -> any CatalogMutationCoordinating)? = nil,
         editingDependencies: (@Sendable () async throws -> EditingModelDependencies)? = nil,
         cleanup: Cleanup? = nil) {
        self.lifecycle = lifecycle; self.coordinatorLoader = coordinator; self.editingDependencies = editingDependencies
        self.repository = repository; metadata = metadataStore; self.sessionID = sessionID
        self.cleanup = cleanup
        resolver = folderResolver ?? { await Self.resolve($0) }; self.checkpoint = checkpoint
    }
    struct LoadedCatalog: Sendable {
        let catalog: LibraryCatalog
        let scopes: [UUID: URL]
        let updated: Bool
        var metadata: CatalogWriteMetadata
        var editingRemapped = false
    }
    func recoveryCatalog() throws -> StoredLibraryCatalog { try repository.loadStored() }
    private func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    private var hasPendingChange: Bool { changes.contains { $0.state == .staged || $0.state == .conflicted } }

    func cleanupCurrentCatalog() async throws -> CatalogWriteMetadata {
        if let lifecycle {
            return try await lifecycle.withRepositoryAccess(domain: .catalog) { try await self.cleanupCurrentImpl() }
        }
        return try await cleanupCurrentImpl()
    }
    private func cleanupCurrentImpl() async throws -> CatalogWriteMetadata {
        await enter(); defer { leave() }
        guard !hasPendingChange else { throw PhotoMetadataError.relocationInProgress }
        let current = try repository.loadStored()
        if let persisted, persisted.reference != current.reference { throw CatalogRepositoryError.concurrentModification }
        var result = metadataResult(reference: current.reference, reconciliation: nil, error: nil)
        if let cleanup {
            do { result.editingPruned = try await cleanup(current.catalog, current.reference) }
            catch { result.cleanupError = error.localizedDescription }
        }
        return result
    }

    func load() async throws -> LoadedCatalog {
        if let lifecycle { return try await lifecycle.withRepositoryAccess(domain: .catalog) { try await self.loadAndClean() } }
        return try await loadAndClean()
    }
    private func loadAndClean() async throws -> LoadedCatalog {
        await enter(); defer { leave() }
        var loaded = try await loadImpl()
        guard !loaded.metadata.changes.contains(where: { $0.state == .staged || $0.state == .conflicted }), let cleanup else { return loaded }
        let current = try repository.loadStored()
        guard current.reference == loaded.metadata.reference else { throw CatalogRepositoryError.concurrentModification }
        do {
            loaded.metadata.editingPruned = try await cleanup(current.catalog, current.reference)
        } catch { loaded.metadata.cleanupError = error.localizedDescription }
        return loaded
    }
    private func loadImpl() async throws -> LoadedCatalog {
        let stored = try repository.loadStored(); persisted = stored
        let resolved = await withTaskGroup(of: (Int, LibraryFolder, URL?).self) { group in
            var next = 0; var output: [(Int, LibraryFolder, URL?)] = []
            func enqueue() {
                guard next < stored.catalog.folders.count else { return }
                let index = next, folder = stored.catalog.folders[index], resolver = self.resolver; next += 1
                group.addTask { let value = await resolver(folder); return (index, value.0, value.1) }
            }
            for _ in 0..<min(2, stored.catalog.folders.count) { enqueue() }
            while let value = await group.next() { output.append(value); enqueue() }
            return output.sorted { $0.0 < $1.0 }
        }
        var catalog = stored.catalog; var scopes: [UUID: URL] = [:]
        var moved: [UUID: (LibraryFolder, LibraryFolder)] = [:]
        for (index, folder, scope) in resolved {
            let old = stored.catalog.folders[index]
            catalog.folders[index] = folder
            if let scope { scopes[folder.id] = scope }
            if LibraryProjectionWorker.filePath(folder.url) != LibraryProjectionWorker.filePath(old.url) {
                moved[folder.id] = (old, folder)
            }
        }
        var movedAssets: [(PhotoAsset, PhotoAsset, LibraryFolder, LibraryFolder, String)] = []
        for index in catalog.assets.indices {
            let asset = catalog.assets[index]
            if let (old, destination) = moved[asset.folderID] {
                let prefix = LibraryProjectionWorker.directoryPrefix(old.url)
                let path = LibraryProjectionWorker.filePath(asset.fileURL)
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                let url = destination.url.appendingPathComponent(relative)
                var changed = asset
                changed.fileURL = url; changed.id = url.resolvingSymlinksInPath().standardizedFileURL.path
                catalog.assets[index] = changed
                if changed.id != asset.id { movedAssets.append((asset, changed, old, destination, relative)) }
            }
        }
        var historical: [String: PhotoMetadataRecord] = [:]
        var metadataError: PhotoMetadataError?
        if let metadata {
            do {
                // Capture historical native/raster evidence before a missing old
                // path is observed by normal source reconciliation.
                for (old, _, _, _, _) in movedAssets {
                    if let record = try await metadata.record(assetID: old.id) { historical[old.id] = record }
                }
            } catch { metadataError = Self.metadataError(error) }
        }
        if coordinatorLoader != nil, !movedAssets.isEmpty {
            return try await loadCoordinated(stored: stored, resolvedCatalog: catalog, scopes: scopes, movedAssets: movedAssets)
        }
        let before = await snapshot(stored.catalog, reference: stored.reference)
        var reconciliation: MetadataReconciliationResult?
        if let metadata {
            do {
                let recovered = try await metadata.recoverCatalogChanges(persistedCatalog: before)
                reconciliation = recovered; changes = recovered.changes
                if !hasPendingChange {
                    let value = try await metadata.reconcile(before)
                    reconciliation = value; changes = value.changes
                }
            } catch { metadataError = Self.metadataError(error) }
        }
        if !movedAssets.isEmpty {
            guard let metadata, metadataError == nil, !hasPendingChange else {
                return LoadedCatalog(catalog: stored.catalog, scopes: scopes, updated: false,
                    metadata: metadataResult(reference: stored.reference, reconciliation: reconciliation,
                                    error: metadataError ?? (metadata == nil ? .storageFailure : .catalogConflict)))
            }
            do {
                var relocations: [MetadataRelocation] = [], expected: [String: MetadataRecordVersion] = [:]
                for (old, new, oldFolder, newFolder, relative) in movedAssets {
                    let oldRecord = historical[old.id]
                    let currentOldRecord = try await metadata.record(assetID: old.id)
                    let newRecord = try await metadata.record(assetID: new.id)
                    let previous = oldRecord?.associationSource ?? oldRecord?.confirmedSource ?? oldRecord?.draft?.source ?? MetadataCatalogSources.source(old)
                    let fresh = MetadataCatalogSources.source(new)
                    relocations.append(.init(oldAssetID: old.id, newAssetID: new.id, oldSource: previous, newSource: fresh,
                        proof: .init(folderID: oldFolder.id, bookmarkSHA256: Self.digest(oldFolder.bookmarkData ?? Data()),
                            oldRoot: oldFolder.url, newRoot: newFolder.url, relativePath: relative,
                            verification: MetadataCatalogSources.verification(before: previous, after: fresh))))
                    expected[old.id] = currentOldRecord?.version ?? .absent
                    expected[new.id] = newRecord?.version ?? .absent
                }
                let prepared = try repository.prepare(catalog)
                let id = UUID(); let stage = try repository.stage(prepared, id: id)
                defer { repository.discard(stage) }
                let change = MetadataCatalogChange(id: id, before: stored.reference, after: prepared.reference,
                    relocations: relocations, expectedRecords: expected.keys.sorted().map { .init(assetID: $0, version: expected[$0]!) })
                let receipt = try await metadata.stageCatalogChange(change); changes = [receipt]
                try checkpoint(.afterMetadataStage)
                try repository.publish(stage, expected: stored.reference)
                persisted = StoredLibraryCatalog(catalog: catalog, reference: prepared.reference)
                try checkpoint(.afterCatalogPublish)
                let after = await snapshot(catalog, reference: prepared.reference)
                reconciliation = try await metadata.completeCatalogChange(id: id, persistedCatalog: after)
                changes = reconciliation?.changes ?? []
                try checkpoint(.afterMetadataComplete)
                return LoadedCatalog(catalog: catalog, scopes: scopes, updated: false,
                    metadata: metadataResult(reference: prepared.reference, reconciliation: reconciliation, error: nil))
            } catch {
                // The actual byte reference decides whether publication happened;
                // never silently put the precommit catalog back in front of a
                // durable postcommit catalog after a completion/journal failure.
                let actual = try repository.loadStored(); persisted = actual
                return LoadedCatalog(catalog: actual.catalog, scopes: scopes, updated: false,
                    metadata: metadataResult(reference: actual.reference, reconciliation: reconciliation, error: Self.metadataError(error)))
            }
        }
        return LoadedCatalog(catalog: catalog, scopes: scopes, updated: catalog != stored.catalog,
            metadata: metadataResult(reference: stored.reference, reconciliation: reconciliation, error: metadataError))
    }

    func save(_ catalog: LibraryCatalog, revision: Int) async throws -> CatalogWriteMetadata {
        if let lifecycle { return try await lifecycle.withRepositoryAccess(domain: .catalog) { try await self.saveImpl(catalog, revision: revision) } }
        return try await saveImpl(catalog, revision: revision)
    }
    private func saveImpl(_ catalog: LibraryCatalog, revision: Int) async throws -> CatalogWriteMetadata {
        await enter(); defer { leave() }
        if revision <= lastRevision {
            return metadataResult(reference: persisted?.reference ?? .absent, reconciliation: nil, error: nil)
        }
        if hasPendingChange {
            // Closing may drain an already durable unresolved mapping. It must
            // not manufacture another catalog write or force a user decision.
            guard let persisted, persisted.catalog == catalog else { throw PhotoMetadataError.relocationInProgress }
            lastRevision = max(lastRevision, revision)
            return metadataResult(reference: persisted.reference, reconciliation: nil, error: nil)
        }
        let before = try persisted ?? repository.loadStored()
        let beforeIDs = Set(before.catalog.assets.map(\.id)), afterIDs = Set(catalog.assets.map(\.id))
        var editingPruned = false
        // Clean the durable BEFORE membership before accepting new identities.
        // This also retries cleanup interrupted after a previous publication.
        if !afterIDs.isSubset(of: beforeIDs), let cleanup {
            editingPruned = try await cleanup(before.catalog, before.reference)
        }
        let prepared = try repository.prepare(catalog)
        if prepared.reference != before.reference {
            let stage = try repository.stage(prepared)
            defer { repository.discard(stage) }
            try repository.publish(stage, expected: before.reference)
        }
        persisted = StoredLibraryCatalog(catalog: catalog, reference: prepared.reference)
        lastRevision = revision
        var result: CatalogWriteMetadata
        if let metadata {
            do {
                let value = try await metadata.reconcile(await snapshot(catalog, reference: prepared.reference))
                changes = value.changes
                result = metadataResult(reference: prepared.reference, reconciliation: value, error: nil)
            } catch { result = metadataResult(reference: prepared.reference, reconciliation: nil, error: Self.metadataError(error)) }
        } else { result = metadataResult(reference: prepared.reference, reconciliation: nil, error: nil) }
        if !beforeIDs.isSubset(of: afterIDs), let cleanup {
            do { editingPruned = try await cleanup(catalog, prepared.reference) || editingPruned }
            catch { result.cleanupError = error.localizedDescription }
        }
        result.editingPruned = editingPruned
        return result
    }

    func retryMetadataReconciliation() async throws -> CatalogWriteMetadata {
        if let lifecycle { return try await lifecycle.withRepositoryAccess(domain: .catalog) { try await self.retryMetadataReconciliationImpl() } }
        return try await retryMetadataReconciliationImpl()
    }
    private func retryMetadataReconciliationImpl() async throws -> CatalogWriteMetadata {
        await enter(); defer { leave() }
        let current = try repository.loadStored()
        // Retry repairs metadata only. It cannot rebase an older in-memory
        // catalog onto externally changed bytes and authorize a later overwrite.
        if let persisted, persisted.reference != current.reference { throw CatalogRepositoryError.concurrentModification }
        persisted = current
        guard let metadata else { return metadataResult(reference: current.reference, reconciliation: nil, error: .storageFailure) }
        let value = await snapshot(current.catalog, reference: current.reference)
        let recovery = try await metadata.recoverCatalogChanges(persistedCatalog: value); changes = recovery.changes
        if hasPendingChange { return metadataResult(reference: current.reference, reconciliation: recovery, error: .catalogConflict) }
        let result = try await metadata.reconcile(value); changes = result.changes
        return metadataResult(reference: current.reference, reconciliation: result, error: nil)
    }

    func resolve(_ operation: MetadataCatalogResolutionOperation) async throws -> CatalogWriteMetadata {
        if let lifecycle { return try await lifecycle.withRepositoryAccess(domain: .catalog) { try await self.resolveImpl(operation) } }
        return try await resolveImpl(operation)
    }
    private func resolveImpl(_ operation: MetadataCatalogResolutionOperation) async throws -> CatalogWriteMetadata {
        await enter(); defer { leave() }
        guard let metadata else { throw PhotoMetadataError.storageFailure }
        let current = try repository.loadStored()
        guard operation.persistedReference == current.reference else { throw PhotoMetadataError.staleCatalog }
        let result = try await metadata.resolveCatalogChange(operation)
        changes = result.changes; persisted = current
        return metadataResult(reference: current.reference, reconciliation: result, error: nil)
    }

    private func metadataResult(reference: MetadataCatalogFileReference, reconciliation: MetadataReconciliationResult?,
                        error: PhotoMetadataError?) -> CatalogWriteMetadata {
        if resultSequence < .max { resultSequence += 1 }
        return CatalogWriteMetadata(reference: reference, reconciliation: reconciliation, error: error, changes: changes, sequence: resultSequence)
    }

    private func snapshot(_ catalog: LibraryCatalog, reference: MetadataCatalogFileReference) async -> MetadataCatalogSnapshot {
        generation += 1
        return MetadataCatalogSnapshot(catalogSessionID: sessionID, catalogGeneration: generation,
            persistedReference: reference, assets: await MetadataCatalogSources.assets(catalog.assets))
    }
    private nonisolated static func metadataError(_ error: Error) -> PhotoMetadataError {
        (error as? PhotoMetadataError) ?? .storageFailure
    }
    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func resolve(_ original: LibraryFolder) async -> (LibraryFolder, URL?) {
        var folder = original
        if let data = folder.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                folder.url = url
                if stale { folder.bookmarkData = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data }
            }
        }
        let scope = folder.url.startAccessingSecurityScopedResource() ? folder.url : nil
        if folder.subdirectoryPaths.isEmpty,
           let paths = try? await FolderScanner().scanSubdirectories(folder: folder), !paths.isEmpty { folder.subdirectoryPaths = paths }
        return (folder, scope)
    }
}

extension CatalogWriter {
    private func loadCoordinated(stored: StoredLibraryCatalog, resolvedCatalog: LibraryCatalog, scopes: [UUID: URL],
        movedAssets: [(PhotoAsset, PhotoAsset, LibraryFolder, LibraryFolder, String)]) async throws -> LoadedCatalog {
        guard let lifecycle, let coordinatorLoader, let editingDependencies else { throw CatalogCoordinationError.recoveryRequired }
        let coordinator = try await coordinatorLoader()
        let dependencies = try await editingDependencies()
        let maintenance = try await lifecycle.promoteCurrentAcceptedWrite(to: .coordination(UUID()))
        do {
            let result = try await lifecycle.withMaintenance(maintenance) {
                try await self.finishCoordinatedMoves(stored: stored, resolvedCatalog: resolvedCatalog, scopes: scopes,
                    movedAssets: movedAssets, dependencies: dependencies, coordinator: coordinator, maintenance: maintenance)
            }
            try await lifecycle.finishMaintenance(maintenance)
            return result
        } catch {
            // The gate itself refuses to unlock any still-armed durable work.
            // A failed observer cannot release that recovery fence.
            try? await lifecycle.finishMaintenance(maintenance)
            throw error
        }
    }
    private func finishCoordinatedMoves(stored: StoredLibraryCatalog, resolvedCatalog: LibraryCatalog, scopes: [UUID: URL],
        movedAssets: [(PhotoAsset, PhotoAsset, LibraryFolder, LibraryFolder, String)],
        dependencies: EditingModelDependencies, coordinator: any CatalogMutationCoordinating,
        maintenance: CatalogMaintenanceAdmission) async throws -> LoadedCatalog {
        var current = stored
        var latest: MetadataReconciliationResult?
        var editingRemapped = false
        let folderIDs = Set(movedAssets.map { $0.2.id }).sorted { $0.uuidString < $1.uuidString }
        for folderID in folderIDs {
            let moves = movedAssets.filter { $0.2.id == folderID }
            guard let first = moves.first, let bookmark = first.2.bookmarkData else { throw ArtifactContractError.sourceChanged }
            var after = current.catalog
            if let index = after.folders.firstIndex(where: { $0.id == folderID }) { after.folders[index] = first.3 }
            let byOld = Dictionary(uniqueKeysWithValues: moves.map { ($0.0.id, $0.1) })
            for index in after.assets.indices { if let replacement = byOld[after.assets[index].id] { after.assets[index] = replacement } }
            let prepared = try repository.prepare(after)
            let operationID = UUID()
            let payload = CatalogPreparedPayloadIdentity(operationID: operationID, rootOwnerID: try repository.coordinationRootIdentity(),
                before: current.reference, after: prepared.reference)
            let state = try await dependencies.database.loadState()
            var editingEntries: [OriginalAssetRemapEntry] = []
            var expectedEditing: [String: EditingExpectedState] = [:]
            var metadataMoves: [MetadataRelocation] = []
            var expectedMetadata: [String: MetadataRecordVersion] = [:]
            for (old, new, oldFolder, newFolder, relative) in moves {
                let variants = try await dependencies.database.variants(for: old.id)
                if state.byAsset[old.id] != nil || !variants.isEmpty {
                    var original: OriginalSourceFingerprint?
                    let snapshots = state.byAsset[old.id].map { [$0.snapshot] } ?? []
                    if let artifacts = dependencies.artifacts {
                        for snapshot in snapshots + variants.map(\.snapshot) {
                            if case .artifact(let id) = snapshot.source,
                               let found = try await historicalOriginal(id, path: old.fileURL.standardizedFileURL.path, store: artifacts) {
                                original = found; break
                            }
                        }
                    }
                    // A reachable old file is independent native evidence. A
                    // missing legacy path with no historical proof is a conflict.
                    if original == nil { original = try? AssetRemapVerifier.capture(old.fileURL, referenceDate: old.modifiedAt) }
                    guard let original else { throw ArtifactContractError.sourceChanged }
                    let relocated = try AssetRemapVerifier.capture(new.fileURL, referenceDate: new.modifiedAt)
                    editingEntries.append(.init(oldAssetID: old.id, newAssetID: new.id, relativePath: relative,
                        previous: original, relocated: relocated))
                    for id in [old.id, new.id] {
                        expectedEditing[id] = try state.byAsset[id].map { EditingExpectedState($0) }
                            ?? EditingExpectedState(storeEpoch: state.storeEpoch, revision: state.tombstones[id], snapshot: nil)
                    }
                }
                if let metadata {
                    let oldRecord = try await metadata.record(assetID: old.id), newRecord = try await metadata.record(assetID: new.id)
                    let previous = oldRecord?.associationSource ?? oldRecord?.confirmedSource ?? oldRecord?.draft?.source ?? MetadataCatalogSources.source(old)
                    let fresh = MetadataCatalogSources.source(new)
                    metadataMoves.append(.init(oldAssetID: old.id, newAssetID: new.id, oldSource: previous, newSource: fresh,
                        proof: .init(folderID: folderID, bookmarkSHA256: Self.digest(oldFolder.bookmarkData ?? Data()),
                            oldRoot: oldFolder.url, newRoot: newFolder.url, relativePath: relative,
                            verification: MetadataCatalogSources.verification(before: previous, after: fresh))))
                    expectedMetadata[old.id] = oldRecord?.version ?? .absent
                    expectedMetadata[new.id] = newRecord?.version ?? .absent
                }
            }
            let editing: VerifiedAssetRemap?
            if editingEntries.isEmpty { editing = nil }
            else {
                let proposal = try AssetRemapProposal(operationID: .init(rawValue: operationID), catalog: payload,
                    folderID: folderID, bookmarkSHA256: .init(sha256: Self.digest(bookmark)), bookmarkData: bookmark,
                    resolvedFolderURL: first.3.url, catalogSessionID: sessionID, catalogGeneration: UInt64(generation),
                    expectedStoreEpoch: state.storeEpoch, expectedByAsset: expectedEditing, entries: editingEntries, resolvedBookmarkData: first.3.bookmarkData)
                editing = try await verifier.verify(proposal)
            }
            let command = metadata.map { _ in MetadataCatalogChange(id: operationID, before: current.reference, after: prepared.reference,
                relocations: metadataMoves, expectedRecords: expectedMetadata.keys.sorted().map { .init(assetID: $0, version: expectedMetadata[$0]!) }) }
            if editing == nil && command == nil {
                let stage = try repository.stage(prepared)
                defer { repository.discard(stage) }
                try repository.publish(stage, expected: current.reference)
                current = try repository.loadStored(); persisted = current
                continue
            }
            var participant: CatalogParticipantPreparation?
            do {
                let preparation = try await coordinator.prepare(catalog: prepared, expected: current.reference,
                    editing: editing, metadata: command, maintenance: maintenance)
                participant = preparation
                let armed = try await coordinator.arm(preparation)
                let outcome = try await coordinator.finish(armed)
                guard outcome.disposition == .completed else { throw CatalogCoordinationError.recoveryRequired }
                editingRemapped = editingRemapped || outcome.editing != nil
                latest = outcome.metadata
                if let latest { changes = latest.changes }
                current = try repository.loadStored(); persisted = current
            } catch {
                if let participant { _ = try? await coordinator.abort(participant) }
                throw error
            }
        }
        return LoadedCatalog(catalog: current.catalog, scopes: scopes, updated: false,
            metadata: metadataResult(reference: current.reference, reconciliation: latest, error: nil), editingRemapped: editingRemapped)
    }
    private func historicalOriginal(_ id: GeneratedArtifactID, path: String, store: any GeneratedArtifactStoring) async throws -> OriginalSourceFingerprint? {
        var next = id, seen = Set<GeneratedArtifactID>()
        while seen.count < 128, seen.insert(next).inserted {
            let artifact = try await store.descriptor(next)
            switch artifact.provenance.parentSource {
            case .original(let value): return value.standardizedPath == path ? value : nil
            case .artifact(let value): next = value.artifactID
            }
        }
        throw ArtifactContractError.corruptArtifact
    }
}
