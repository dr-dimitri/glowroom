import CryptoKit
import Foundation
import PicEditCore

enum CatalogWriteCheckpoint: Equatable, Sendable { case afterMetadataStage, afterCatalogPublish, afterMetadataComplete }
struct CatalogWriteMetadata: Sendable {
    let reference: MetadataCatalogFileReference
    let reconciliation: MetadataReconciliationResult?
    let error: PhotoMetadataError?
    let changes: [MetadataCatalogChangeReceipt]
    let sequence: UInt64
    let blockedAssetIDs: Set<String>
    let protectedSourceURLs: [URL]
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
    let repository: CatalogRepository
    private let metadata: (any PhotoMetadataStoring)?
    private let sessionID: UUID
    private let resolver: FolderResolver
    private let checkpoint: @Sendable (CatalogWriteCheckpoint) throws -> Void
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastRevision = -1
    private var persisted: StoredLibraryCatalog?
    private var changes: [MetadataCatalogChangeReceipt] = []
    private var generation = 0
    private var resultSequence: UInt64 = 0

    init(repository: CatalogRepository, metadataStore: (any PhotoMetadataStoring)? = nil,
         sessionID: UUID = UUID(), folderResolver: FolderResolver? = nil,
         checkpoint: @escaping @Sendable (CatalogWriteCheckpoint) throws -> Void = { _ in }) {
        self.repository = repository; metadata = metadataStore; self.sessionID = sessionID
        resolver = folderResolver ?? { await Self.resolve($0) }; self.checkpoint = checkpoint
    }
    struct LoadedCatalog: Sendable {
        let catalog: LibraryCatalog
        let scopes: [UUID: URL]
        let updated: Bool
        let metadata: CatalogWriteMetadata
    }
    private func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    private var hasPendingChange: Bool { changes.contains { $0.state == .staged || $0.state == .conflicted } }

    func load() async throws -> LoadedCatalog {
        await enter(); defer { leave() }
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
            if folder.url != old.url { moved[folder.id] = (old, folder) }
        }
        var movedAssets: [(PhotoAsset, PhotoAsset, LibraryFolder, LibraryFolder, String)] = []
        for index in catalog.assets.indices {
            let asset = catalog.assets[index]
            if let (old, destination) = moved[asset.folderID] {
                let prefix = LibraryProjectionWorker.directoryPrefix(old.url)
                guard asset.fileURL.path.hasPrefix(prefix) else { continue }
                let relative = String(asset.fileURL.path.dropFirst(prefix.count))
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
        let prepared = try repository.prepare(catalog)
        if prepared.reference != before.reference {
            let stage = try repository.stage(prepared)
            defer { repository.discard(stage) }
            try repository.publish(stage, expected: before.reference)
        }
        persisted = StoredLibraryCatalog(catalog: catalog, reference: prepared.reference)
        lastRevision = revision
        guard let metadata else { return metadataResult(reference: prepared.reference, reconciliation: nil, error: nil) }
        do {
            let result = try await metadata.reconcile(await snapshot(catalog, reference: prepared.reference))
            changes = result.changes
            return metadataResult(reference: prepared.reference, reconciliation: result, error: nil)
        } catch { return metadataResult(reference: prepared.reference, reconciliation: nil, error: Self.metadataError(error)) }
    }

    func retryMetadataReconciliation() async throws -> CatalogWriteMetadata {
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
