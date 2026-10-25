import Foundation
import CSQLite

extension EditingRepository {
    static func variantMetadata(_ id: EditingVariantID, on db: OpaquePointer) throws -> (String?, EditingVariantCreationKind) {
        guard try EditingSQLite.hasVariantMetadata(db) else { return (nil, .automatic) }
        return try EditingSQLite.statement(db, "SELECT name,creation_kind FROM editing_variant_metadata WHERE variant_id=?") { statement in
            try EditingSQLite.bind(id.canonicalString, 1, statement)
            var result: (String?, EditingVariantCreationKind) = (nil, .automatic)
            try EditingSQLite.consume(statement) { row in
                let name = try EditingSQLite.text(row, 0, maximum: 512)
                guard try EditingVariantName.validated(name) == name,
                      let kind = EditingVariantCreationKind(rawValue: try EditingSQLite.text(row, 1, maximum: 16)) else { throw EditingRepositoryError.invalidDatabase }
                result = (name, kind)
            }
            return result
        }
    }
    static func writeVariantMetadata(_ variant: EditingVariant, on db: OpaquePointer) throws {
        guard let name = variant.name else { return }
        guard try EditingVariantName.validated(name) == name else { throw EditingRepositoryError.invalidDatabase }
        try EditingSQLite.statement(db, "INSERT OR REPLACE INTO editing_variant_metadata(variant_id,name,creation_kind) VALUES(?,?,?)") { statement in
            try EditingSQLite.bind(variant.id.canonicalString, 1, statement)
            try EditingSQLite.bind(name, 2, statement)
            try EditingSQLite.bind(variant.creationKind.rawValue, 3, statement)
            try EditingSQLite.done(statement)
        }
    }
    static func validateVariantMetadata(on db: OpaquePointer) throws {
        guard try EditingSQLite.hasVariantMetadata(db) else { return }
        var count = 0
        try EditingSQLite.rows(db, "SELECT m.variant_id FROM editing_variant_metadata m LEFT JOIN editing_variants v ON v.id=m.variant_id WHERE v.id IS NULL") { _ in throw EditingRepositoryError.invalidDatabase }
        try EditingSQLite.rows(db, "SELECT variant_id FROM editing_variant_metadata") { row in
            guard count < 100_000, let raw = UUID(uuidString: try EditingSQLite.text(row, 0, maximum: 36)) else { throw EditingRepositoryError.invalidDatabase }
            _ = try variantMetadata(.init(rawValue: raw), on: db); count += 1
        }
    }
    public func saveNamedVariant(id: EditingVariantID, name: String, for assetID: String, snapshot: EditingSnapshot, expected: EditingExpectedState) async throws -> EditingVariant {
        let name = try EditingVariantName.validated(name)
        try ArtifactValueValidation.identifier(assetID); try ArtifactValueValidation.snapshot(snapshot); try ArtifactValueValidation.expected(expected)
        return try await gate.withRepositoryAccess(domain: .editing) {
            try await self.insertNamedVariant(id: id, name: name, assetID: assetID, snapshot: snapshot, expected: expected)
        }
    }
    private func insertNamedVariant(id: EditingVariantID, name: String, assetID: String, snapshot: EditingSnapshot, expected: EditingExpectedState) async throws -> EditingVariant {
        try await acquireMutation(); defer { releaseMutation() }
        let db = try connection()
        return try sql.transaction(db, beforeCommit: hooks.beforeCommit) {
            try Self.require(expected, id: assetID, on: db); try ensureNoRemap(assetID, on: db)
            if let stored = expected.snapshot { guard stored == snapshot else { throw ArtifactContractError.staleSnapshot } }
            else { guard snapshot.source == .original, snapshot.settings == .newEditingSettings else { throw ArtifactContractError.staleSnapshot } }
            if let prior = try Self.readVariants(assetID, on: db).first(where: { $0.id == id }) {
                guard prior.snapshot == snapshot, prior.name == name, prior.creationKind == .named else { throw ArtifactContractError.conflictingCommit }
                return prior
            }
            guard try EditingSQLite.scalar(db, "SELECT count(*) FROM editing_variants") < 100_000 else { throw ArtifactContractError.limitExceeded }
            let variant = EditingVariant(id: id, assetID: assetID, snapshot: snapshot, createdAt: Date(), name: name, creationKind: .named)
            try EditingSQLite.statement(db, "INSERT INTO editing_variants(id,asset_id,snapshot,created_at) VALUES(?,?,?,?)") { row in
                try EditingSQLite.bind(id.canonicalString, 1, row); try EditingSQLite.bind(assetID, 2, row)
                try EditingSQLite.bind(ArtifactJSONCodec.encode(snapshot), 3, row)
                guard sqlite3_bind_double(row, 4, variant.createdAt.timeIntervalSinceReferenceDate) == SQLITE_OK else { throw EditingRepositoryError.storageFailure }
                try EditingSQLite.done(row)
            }
            try Self.writeVariantMetadata(variant, on: db)
            return variant
        }
    }
    public func renameVariant(_ id: EditingVariantID, for assetID: String, name: String) async throws {
        let name = try EditingVariantName.validated(name)
        try await gate.withRepositoryAccess(domain: .editing) { try await self.mutateVariant(id, assetID: assetID, name: name) }
    }
    public func removeNamedVariant(_ id: EditingVariantID, for assetID: String) async throws {
        try await gate.withRepositoryAccess(domain: .editing) { try await self.mutateVariant(id, assetID: assetID, name: nil) }
    }
    private func mutateVariant(_ id: EditingVariantID, assetID: String, name: String?) async throws {
        try ArtifactValueValidation.identifier(assetID)
        try await acquireMutation(); defer { releaseMutation() }
        let db = try connection()
        try sql.transaction(db, beforeCommit: hooks.beforeCommit) {
            try ensureNoRemap(assetID, on: db)
            guard let variant = try Self.readVariants(assetID, on: db).first(where: { $0.id == id }) else { throw ArtifactContractError.staleSnapshot }
            if let name {
                try Self.writeVariantMetadata(.init(id: id, assetID: assetID, snapshot: variant.snapshot, createdAt: variant.createdAt, name: name, creationKind: variant.creationKind), on: db)
            } else {
                guard variant.creationKind == .named else { throw ArtifactContractError.invalidCapability }
                // Deleting a reference never directly removes raster files. Existing
                // artifact closure/lease maintenance owns eventual reclamation.
                try EditingSQLite.statement(db, "DELETE FROM editing_variants WHERE id=? AND asset_id=?") { row in
                    try EditingSQLite.bind(id.canonicalString, 1, row); try EditingSQLite.bind(assetID, 2, row); try EditingSQLite.done(row)
                }
            }
        }
    }
}
