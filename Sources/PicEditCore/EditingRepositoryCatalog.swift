import Foundation
import CSQLite

extension EditingRepository {
    /// Forget removed catalog images instead of retaining revision tombstones.
    /// The caller fences catalog changes and drains accepted editor writes with
    /// the shared lifecycle gate before invoking this reconciliation.
    public func reconcileCatalog(_ catalog: LibraryCatalog,
                                 reference: MetadataCatalogFileReference) async throws -> EditingStoreState {
        try await gate.withRepositoryAccess(domain: .editing) {
            try await self.reconcileStoredCatalog(catalog, reference: reference)
        }
    }

    private func reconcileStoredCatalog(_ catalog: LibraryCatalog,
                                        reference: MetadataCatalogFileReference) async throws -> EditingStoreState {
        try await acquireMutation()
        defer { releaseMutation() }
        let repository = CatalogRepository(directory: fileURL.deletingLastPathComponent())
        let stored = try repository.loadStored()
        guard stored.reference == reference, stored.catalog == catalog else {
            throw CatalogRepositoryError.concurrentModification
        }
        let retained = Set(catalog.assets.map(\.id)), db = try connection()
        // Publication and this short SQL mutation stay ordered, including other
        // cooperating processes. There are no actor hops while either is held.
        return try CatalogFileIO.withSnapshotLock(directory: repository.directory) { contents, validateBoundary in
            guard contents.reference == reference else { throw CatalogRepositoryError.concurrentModification }
            return try sql.transaction(db, beforeCommit: {
                try self.hooks.beforeCommit()
                try validateBoundary()
            }) {
                try ensureNoRemap(nil, on: db)
                var removed = Set<String>()
                try EditingSQLite.rows(db, "SELECT asset_id FROM edit_revisions UNION SELECT asset_id FROM editing_variants") { row in
                    let id = try EditingSQLite.text(row, 0, maximum: 16_384)
                    if !retained.contains(id) { removed.insert(id) }
                }
                for id in removed.sorted() {
                    // Foreign keys require deleting snapshots before revisions.
                    for table in ["editing_snapshots", "editing_variants", "edit_revisions"] {
                        try Self.deleteCatalogRow(table, column: "asset_id", value: id, on: db)
                    }
                }

                var commits: [String] = [], receiptRoots = Set<GeneratedArtifactID>()
                func retainSource(_ snapshot: EditingSnapshot?) {
                    if let snapshot, case .artifact(let id) = snapshot.source { receiptRoots.insert(id) }
                }
                try EditingSQLite.rows(db, "SELECT id,request_sha,receipt FROM artifact_commits") { row in
                    let wire = try Self.decodeCommit(row)
                    if !retained.contains(wire.assetID) { commits.append(wire.commitID.canonicalString) }
                    else {
                        retainSource(wire.snapshot)
                        retainSource(wire.previous.snapshot)
                    }
                }
                for id in commits { try Self.deleteCatalogRow("artifact_commits", column: "id", value: id, on: db) }

                var remaps: [String] = []
                try EditingSQLite.rows(db, "SELECT id,phase,journal FROM editing_remaps") { row in
                    let wire = try Self.decodeRemap(row)
                    let historical = Set(wire.proposal.expectedByAsset.keys)
                        .union(wire.proposal.entries.flatMap { [$0.oldAssetID, $0.newAssetID] })
                        .union(wire.receipt?.byAsset.keys.map { $0 } ?? [])
                        .union(wire.receipt?.tombstones.keys.map { $0 } ?? [])
                    if !historical.isSubset(of: retained) { remaps.append(wire.proposal.operationID.canonicalString) }
                    else {
                        for expected in wire.proposal.expectedByAsset.values { retainSource(expected.snapshot) }
                        for entry in wire.receipt?.byAsset.values.map({ $0 }) ?? [] { retainSource(entry.snapshot) }
                    }
                }
                for id in remaps { try Self.deleteCatalogRow("editing_remaps", column: "id", value: id, on: db) }

                let state = try Self.readState(db, version: 2)
                var referenced = Set(try EditingClosedSQLValidator.closure(db, state: state).map(\.id))
                // Exact commit retries and terminal inspections may still return
                // historical sources even when no active variant uses them.
                for root in receiptRoots {
                    var next: GeneratedArtifactID? = root
                    while let id = next, !referenced.contains(id) {
                        guard referenced.count < 4_096,
                              let artifact = try Self.descriptor(id, on: db) else { throw ArtifactContractError.missingArtifact }
                        referenced.insert(id)
                        if case .artifact(let parent) = artifact.provenance.parentSource { next = parent.artifactID }
                        else { next = nil }
                    }
                }
                var artifacts: [String] = []
                try EditingSQLite.rows(db, "SELECT id FROM generated_artifacts") { row in
                    let id = try EditingSQLite.text(row, 0, maximum: 36)
                    guard let uuid = UUID(uuidString: id) else { throw EditingRepositoryError.invalidDatabase }
                    if !referenced.contains(.init(rawValue: uuid)) { artifacts.append(id) }
                }
                for id in artifacts { try Self.deleteCatalogRow("generated_artifacts", column: "id", value: id, on: db) }
                if !removed.isEmpty || !commits.isEmpty || !remaps.isEmpty || !artifacts.isEmpty {
                    // No per-image tombstone survives removal. A new epoch
                    // rejects delayed saves captured before the deletion.
                    try EditingSQLite.statement(db, "UPDATE editing_state SET store_epoch=? WHERE singleton=1") { row in
                        try EditingSQLite.bind(UUID().uuidString.lowercased(), 1, row)
                        try EditingSQLite.done(row)
                    }
                }
                try Self.validateRows(db, 2)
                // Published raster files are deliberately retained: v1 exposes
                // no deletion capability for immutable published artifacts.
                return try Self.readState(db, version: 2)
            }
        }
    }

    private static func deleteCatalogRow(_ table: String, column: String, value: String,
                                         on db: OpaquePointer) throws {
        try EditingSQLite.statement(db, "DELETE FROM \(table) WHERE \(column)=?") { row in
            try EditingSQLite.bind(value, 1, row)
            try EditingSQLite.done(row)
        }
    }
}
