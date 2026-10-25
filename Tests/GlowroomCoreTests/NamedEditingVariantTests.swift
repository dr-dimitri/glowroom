import Foundation
import CSQLite
import Testing
@testable import GlowroomCore

@Suite("Named editing variants")
struct NamedEditingVariantTests {
    @Test func validatesGraphemesAndBytesIndependently() throws {
        #expect(try EditingVariantName.validated("  Warme Druckfassung \n") == "Warme Druckfassung")
        #expect(try EditingVariantName.validated(String(repeating: "é", count: 120)).count == 120)
        for name in ["", " \n", String(repeating: "a", count: 121), String(repeating: "👨‍👩‍👧‍👦", count: 30), "x\0y"] {
            #expect(throws: ArtifactContractError.self) { try EditingVariantName.validated(name) }
        }
    }
    @Test func namedVariantsPreserveIdentitySnapshotAndRevisionAcrossBackup() async throws {
        let f = try EditingFixture(), saved = try await f.save(exposure: 0.75)
        let bytes = try ArtifactJSONCodec.encode(saved.snapshot)
        let first = try await f.repository.saveNamedVariant(id: .init(), name: "  Warm  ", for: f.id, snapshot: saved.snapshot, expected: .init(saved))
        let second = try await f.repository.saveNamedVariant(id: .init(), name: "Warm", for: f.id, snapshot: saved.snapshot, expected: .init(saved))
        #expect(first.id != second.id && first.name == "Warm" && first.creationKind == .named)
        #expect(try await f.reopen().variants(for: f.id) == [first, second])
        #expect(try await f.repository.loadState().byAsset[f.id] == saved)
        #expect(try snapshotBytes(f.repository.fileURL, assetID: f.id) == bytes)
        let backup = try await f.repository.createBackup(automatic: false)
        try await f.repository.renameVariant(first.id, for: f.id, name: "Umbenannt")
        try await f.repository.removeNamedVariant(second.id, for: f.id)
        #expect(try await f.repository.variants(for: f.id).map(\.name) == ["Umbenannt"])
        #expect(try await f.repository.loadState().byAsset[f.id] == saved)
        _ = try await f.repository.restoreBackup(from: backup)
        #expect(try await f.repository.variants(for: f.id) == [first, second])
        #expect(try snapshotBytes(f.repository.fileURL, assetID: f.id) == bytes)
    }
    @Test func staleOrFailedWritesNeverLeavePartialRows() async throws {
        let failure = EditingFailureSwitch()
        let f = try EditingFixture(hooks: .init(beforeCommit: { try failure.check() })), saved = try await f.save(exposure: 0.5)
        let replacement = try await f.repository.saveSnapshot(EditingSnapshot(settings: EditSettings(exposure: 1)), for: f.id, expected: .init(saved), revision: 2)
        await #expect(throws: ArtifactContractError.staleSnapshot) {
            try await f.repository.saveNamedVariant(id: .init(), name: "Alt", for: f.id, snapshot: saved.snapshot, expected: .init(saved))
        }
        failure.enabled = true
        await #expect(throws: EditingRepositoryError.storageFailure) {
            try await f.repository.saveNamedVariant(id: .init(), name: "Fehler", for: f.id, snapshot: replacement.snapshot, expected: .init(replacement))
        }
        failure.enabled = false
        #expect(try await f.repository.variants(for: f.id).isEmpty)
        #expect(try editingScalar(f.repository.fileURL, "SELECT count(*) FROM editing_variant_metadata") == 0)
        #expect(try await f.repository.loadState().byAsset[f.id] == replacement)
    }
    @Test func artifactVariantMetadataNeverRewritesManifestAndRemovalRetainsOtherOwners() async throws {
        let f = try EditingFixture(), saved = try await f.save(exposure: 0.25), draft = try await f.draft(parent: saved)
        let committed = try await f.repository.commitGenerated(.init(commitID: .init(), assetID: f.id, draft: draft, expected: .init(saved), expectedParentSource: draft.artifact.provenance.parentSource, nextRevision: 2))
        let variant = try await f.repository.saveNamedVariant(id: .init(), name: "Raster", for: f.id, snapshot: committed.stored.snapshot, expected: .init(committed.stored))
        let descriptor = try ArtifactJSONCodec.encode(try await f.artifacts.descriptor(draft.artifact.id))
        try await f.repository.renameVariant(variant.id, for: f.id, name: "Raster neu")
        try await f.repository.removeNamedVariant(variant.id, for: f.id)
        #expect(try ArtifactJSONCodec.encode(try await f.artifacts.descriptor(draft.artifact.id)) == descriptor)
        #expect(try await f.repository.loadState().byAsset[f.id] == committed.stored)
        #expect(try await f.repository.variants(for: f.id).count == 2)
        let backup = try await f.repository.createBackup(automatic: false)
        #expect(await f.packages.saved[backup]?.snapshot.referencedArtifacts.map(\.id) == [draft.artifact.id])
    }
    @Test func oldClosedV2SchemaMigratesWithoutChangingSnapshotBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-old-variants-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = EditingSQLite(directory: directory)
        let db = try old.open(validateRows: EditingRepository.validateRows)
        let snapshot = try EditingSnapshot(settings: EditSettings(exposure: 0.6)), bytes = try ArtifactJSONCodec.encode(snapshot)
        try old.transaction(db) {
            try EditingRepository.write(snapshot, id: "old", revision: 7, on: db)
            try EditingSQLite.exec(db, "DROP TABLE editing_variant_metadata")
        }
        try old.closeForReplacement()
        #expect(try EditingSQLite.readOnly(directory.appendingPathComponent("edits.sqlite")) { db, version in
            try EditingRepository.validateRows(db, version); return try !EditingSQLite.hasVariantMetadata(db)
        } == true)
        let migrated = EditingSQLite(directory: directory)
        let next = try migrated.open(validateRows: EditingRepository.validateRows)
        #expect(try EditingSQLite.hasVariantMetadata(next))
        #expect(try snapshotBytes(directory.appendingPathComponent("edits.sqlite"), assetID: "old") == bytes)
        try migrated.closeForReplacement()
    }
    private func snapshotBytes(_ url: URL, assetID: String) throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw EditingRepositoryError.storageFailure }
        defer { sqlite3_close(db) }
        return try EditingSQLite.statement(db, "SELECT snapshot FROM editing_snapshots WHERE asset_id=?") { row in
            try EditingSQLite.bind(assetID, 1, row)
            var result: Data?
            try EditingSQLite.consume(row) { result = try EditingSQLite.blob($0, 0, maximum: EditSettings.maximumEncodedBytes) }
            return try #require(result)
        }
    }
}
