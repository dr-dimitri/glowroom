import Foundation
import Darwin
import CSQLite
import Testing
@testable import PicEditCore

@Suite("Semantic index persistence and generation isolation")
struct SemanticIndexStoreTests {
    @Test func catalogRemovalPurgesEveryGenerationAndReaddingStartsWithoutVectors() async throws {
        let f = try IndexFixture(), retired = try await f.prepare()
        for id in ["removed","kept"] { try await f.store.upsert(f.record(id),in:retired) }
        try await f.store.activate(retired)
        let active = try await f.store.prepareGeneration(for:indexDescriptor(model:"active"),installationFingerprint:f.installation)
        for id in ["removed","kept"] { try await f.store.upsert(f.record(id),in:active) }
        try await f.store.activate(active)
        let superseded = try await f.store.prepareGeneration(for:indexDescriptor(model:"superseded"),installationFingerprint:f.installation)
        try await f.store.upsert(f.record("removed"),in:superseded)
        let building = try await f.store.prepareGeneration(for:indexDescriptor(model:"building"),installationFingerprint:f.installation)
        for id in ["removed","kept"] { try await f.store.upsert(f.record(id),in:building) }
        #expect(try await f.store.retainOnlyCatalogAssets(["kept"]) == 4)
        #expect(try indexScalar(f.store.fileURL,sql:"SELECT COUNT(*) FROM semantic_entries WHERE asset_id='removed'") == "0")
        #expect(try indexScalar(f.store.fileURL,sql:"SELECT COUNT(*) FROM semantic_entries WHERE asset_id='kept'") == "3")
        #expect(try await f.store.activeGeneration() == active)
        for generation in [retired,active,building] {
            #expect(try await f.store.records(in:generation) == [f.record("kept")])
        }
        #expect(try await f.store.retainOnlyCatalogAssets(["kept","removed"]) == 0)
        #expect(try await f.store.metadata(in:active,assetIDs:["removed"]).isEmpty)
        let restarted = try SemanticIndexStore(directory:f.directory)
        #expect(try await restarted.records(in:active) == [f.record("kept")])
        #expect(try await restarted.retainOnlyCatalogAssets([]) == 3)
        #expect(try await restarted.records(in:active).isEmpty)
    }

    @Test func catalogPruningRollsBackAllGenerationsOnCommitFailure() async throws {
        let failure = IndexFailureSwitch(),f = try IndexFixture(beforeCommit:{ try failure.check() })
        let active = try await f.prepare()
        try await f.store.upsert(f.record("removed"),in:active); try await f.store.activate(active)
        let building = try await f.store.prepareGeneration(for:indexDescriptor(model:"next"),installationFingerprint:f.installation)
        try await f.store.upsert(f.record("removed"),in:building)
        failure.arm()
        await indexError(.indexUnavailable) { _ = try await f.store.retainOnlyCatalogAssets([]) }
        #expect(try await f.store.records(in:active) == [f.record("removed")])
        #expect(try await f.store.records(in:building) == [f.record("removed")])
        await indexError(.invalidInput) { _ = try await f.store.retainOnlyCatalogAssets([""]) }
        #expect(try await f.store.retainOnlyCatalogAssets([]) == 2)
    }

    @Test func lazyInitializationRoundtripLittleEndianAndRestart() async throws {
        let f = try IndexFixture()
        #expect(!FileManager.default.fileExists(atPath: f.directory.path))
        let generation = try await f.prepare()
        let record = f.record("a")
        try await f.store.upsert(record, in: generation)
        try await f.store.activate(generation)
        #expect(try indexScalar(f.store.fileURL, sql: "SELECT hex(vector) FROM semantic_entries") == "9A99193FCDCC4C3F00000000")
        let restarted = try SemanticIndexStore(directory: f.directory)
        #expect(try await restarted.activeGeneration() == generation)
        #expect(try await restarted.records(in: generation) == [record])
        #expect(try await restarted.metadata(in: generation, assetIDs: ["a"]) == [SemanticIndexMetadata(assetID: record.assetID, source: record.source, sourceRevision: record.sourceRevision, inputRasterSHA256: record.inputRasterSHA256)])
        #expect(try await restarted.prepareGeneration(for: f.descriptor, installationFingerprint: f.installation) == generation)
    }

    @Test func fractionalNativeDatesRoundtripWithoutFingerprintLoss() async throws {
        let f = try IndexFixture(), generation = try await f.prepare()
        let base = Date(timeIntervalSince1970: 1_792_158_000).timeIntervalSinceReferenceDate
        var originals: [SemanticIndexRecord] = []
        for (index, value) in [base.nextUp, base.nextDown].enumerated() {
            let date = Date(timeIntervalSinceReferenceDate: value)
            #expect(Date(timeIntervalSince1970: date.timeIntervalSince1970) != date)
            let template = f.record("fractional-\(index)")
            let source = AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: template.source.standardizedPath),
                modifiedAt: date, fileSize: template.source.fileSize)
            let record = SemanticIndexRecord(assetID: template.assetID, source: source, sourceRevision: template.sourceRevision,
                inputRasterSHA256: template.inputRasterSHA256, vector: template.vector)
            originals.append(record); try await f.store.upsert(record, in: generation)
        }
        try await f.store.activate(generation)
        let restarted = try SemanticIndexStore(directory: f.directory)
        #expect(try await restarted.records(in: generation) == originals)
        let metadata = try await restarted.metadata(in: generation, assetIDs: originals.map(\.assetID))
        #expect(metadata.map(\.source) == originals.map(\.source))
    }

    @Test func partialBuildResumesAndModelChangePreservesLastActive() async throws {
        let f = try IndexFixture(), old = try await f.prepare()
        try await f.store.upsert(f.record("old"), in: old); try await f.store.activate(old)
        let changed = indexDescriptor(model: "second-model")
        let building = try await f.store.prepareGeneration(for: changed, installationFingerprint: f.installation)
        try await f.store.upsert(f.record("new"), in: building)
        #expect(try await f.store.activeGeneration() == old)
        let restarted = try SemanticIndexStore(directory: f.directory)
        #expect(try await restarted.prepareGeneration(for: changed, installationFingerprint: f.installation) == building)
        #expect(try await restarted.records(in: building).map(\.assetID) == ["new"])
        try await restarted.activate(building)
        #expect(try await f.store.activeGeneration() == building)
        #expect(try await f.store.records(in: old).map(\.assetID) == ["old"])
        await indexError(.superseded) { try await f.store.upsert(f.record("late"), in: old) }
    }

    @Test func forceNewAndInstallationChangesSupersedeBuildingHandles() async throws {
        let f = try IndexFixture(), first = try await f.prepare()
        try await f.store.upsert(f.record("partial"), in: first)
        let second = try await f.store.prepareGeneration(for: f.descriptor, installationFingerprint: f.installation, forceNew: true)
        #expect(first.id != second.id)
        await indexError(.superseded) { try await f.store.activate(first) }
        await indexError(.superseded) { try await f.store.upsert(f.record("late"), in: first) }
        let changed = try await f.store.prepareGeneration(for: f.descriptor, installationFingerprint: String(repeating: "b", count: 64))
        #expect(changed.id != second.id)
        await indexError(.superseded) { try await f.store.activate(second) }
        let forged = SemanticIndexGeneration(id: changed.id, descriptor: f.descriptor, installationFingerprint: f.installation)
        await indexError(.superseded) { _ = try await f.store.records(in: forged) }
        #expect(try await f.store.activeGeneration() == nil)
    }

    @Test func returningToActiveSpaceSupersedesOtherPendingSpace() async throws {
        let f = try IndexFixture(), active = try await f.prepare()
        try await f.store.activate(active)
        let pending = try await f.store.prepareGeneration(for: indexDescriptor(model: "other"), installationFingerprint: f.installation)
        #expect(try await f.prepare() == active)
        await indexError(.superseded) { try await f.store.activate(pending) }
        #expect(try await f.store.activeGeneration() == active)
    }

    @Test func failedCommitRollsBackPointerAndEntries() async throws {
        let failure = IndexFailureSwitch()
        let f = try IndexFixture(beforeCommit: { try failure.check() }), active = try await f.prepare()
        try await f.store.activate(active)
        let building = try await f.store.prepareGeneration(for: indexDescriptor(model: "changed"), installationFingerprint: f.installation)
        failure.arm()
        await indexError(.indexUnavailable) { try await f.store.activate(building) }
        #expect(try await f.store.activeGeneration() == active)
        failure.arm()
        await indexError(.indexUnavailable) { try await f.store.upsert(f.record("failed"), in: building) }
        #expect(try await f.store.records(in: building).isEmpty)
        try await f.store.upsert(f.record("good"), in: building)
        try await f.store.activate(building)
        #expect(try await f.store.activeGeneration() == building)
    }

    @Test func cancellationQueuedBehindCommitCannotActivate() async throws {
        let gate = IndexCommitGate()
        let f = try IndexFixture(beforeCommit: { gate.waitIfArmed() }), active = try await f.prepare()
        try await f.store.activate(active)
        let building = try await f.store.prepareGeneration(for: indexDescriptor(model: "next"), installationFingerprint: f.installation)
        gate.arm()
        let writing = Task { try await f.store.upsert(f.record("complete"), in: building) }
        await Task.detached { gate.waitUntilEntered() }.value
        let cancelled = Task { try await f.store.activate(building) }
        cancelled.cancel(); gate.release.signal()
        try await writing.value
        await indexError(.cancelled) { try await cancelled.value }
        #expect(try await f.store.activeGeneration() == active)
        #expect(try await f.store.records(in: building).map(\.assetID) == ["complete"])
    }

    @Test func metadataTracksStrongRevisionWithoutErasingOldSourceOnMissingOrRelocation() async throws {
        let f = try IndexFixture(), generation = try await f.prepare()
        let original = f.record("old")
        try await f.store.upsert(original, in: generation)
        #expect(try await f.store.metadata(in: generation, assetIDs: ["relocated"]).isEmpty)
        let preserved = try await f.store.metadata(in: generation, assetIDs: ["old"])
        #expect(preserved.first?.sourceRevision == "inode1:ctime1:mtime1")
        let updated = f.record("old", revision: "inode1:ctime2:mtime2")
        try await f.store.upsert(updated, in: generation)
        #expect(try await f.store.metadata(in: generation, assetIDs: ["old"]).first?.sourceRevision == updated.sourceRevision)
        // A scope removal excludes IDs in the App; explicit removal can reclaim
        // the cached entry without assigning its vector to a different photo.
        try await f.store.remove(assetIDs: ["old"], in: generation)
        #expect(try await f.store.records(in: generation).isEmpty)
    }

    @Test func boundedPagesUseStableBinaryAssetOrder() async throws {
        let f = try IndexFixture(), generation = try await f.prepare()
        for id in ["z", "a", "c", "b"] { try await f.store.upsert(f.record(id), in: generation) }
        let first = try await f.store.records(in: generation, limit: 2)
        let second = try await f.store.records(in: generation, afterAssetID: first.last?.assetID, limit: 2)
        #expect(first.map(\.assetID) == ["a", "b"])
        #expect(second.map(\.assetID) == ["c", "z"])
        await indexError(.invalidInput) { _ = try await f.store.records(in: generation, limit: 513) }
        await indexError(.invalidInput) { _ = try await f.store.records(in: generation, limit: 0) }
        await indexError(.invalidInput) { _ = try await f.store.metadata(in: generation, assetIDs: Array(repeating: "a", count: 513)) }
    }

    @Test(arguments: [[Float](repeating: 0, count: 3), [1, 0], [2, 0, 0], [.nan, 0, 1], [.infinity, 0, 1]])
    func invalidVectorsNeverPersist(_ vector: [Float]) async throws {
        let f = try IndexFixture(), generation = try await f.prepare()
        await indexError(.invalidVector) { try await f.store.upsert(f.record("invalid", vector: vector), in: generation) }
        #expect(try await f.store.records(in: generation).isEmpty)
    }

    @Test func metadataAndInstallationBoundsAreStrict() async throws {
        let f = try IndexFixture(), generation = try await f.prepare()
        for installation in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 65), String(repeating: "g", count: 64)] {
            await indexError(.invalidInput) { _ = try await f.store.prepareGeneration(for: f.descriptor, installationFingerprint: installation) }
        }
        await indexError(.invalidInput) { try await f.store.upsert(f.record("a", revision: String(repeating: "ä", count: 257)), in: generation) }
        await indexError(.invalidInput) { try await f.store.upsert(f.record("a", revision: ""), in: generation) }
        let bad = SemanticIndexRecord(assetID: "bad", source: f.record("a").source, sourceRevision: "stamp", inputRasterSHA256: "not-sha", vector: [0.6, 0.8, 0])
        await indexError(.invalidInput) { try await f.store.upsert(bad, in: generation) }
    }

    @Test(arguments: ["UPDATE semantic_entries SET vector=x'0000'", "UPDATE semantic_entries SET vector=x'0000C07F0000000000000000'", "UPDATE semantic_entries SET vector=zeroblob(12)", "UPDATE semantic_entries SET source_revision=''", "UPDATE semantic_entries SET raster_digest='bad'"])
    func corruptPersistedRowsAreRejected(_ sql: String) async throws {
        let f = try IndexFixture(), generation = try await f.prepare()
        try await f.store.upsert(f.record("a"), in: generation)
        try indexMutate(f.store.fileURL, sql: sql)
        let before = try indexBytes(f.store.fileURL)
        let restarted = try SemanticIndexStore(directory: f.directory)
        await indexError(.corruptIndex) { _ = try await restarted.activeGeneration() }
        await indexError(.corruptIndex) { _ = try await f.store.records(in: generation) }
        #expect(try indexBytes(f.store.fileURL) == before)
    }

    @Test(arguments: ["PRAGMA user_version=99", "PRAGMA application_id=0", "CREATE TABLE sqliteXforeign(secret TEXT)"])
    func unknownSchemaIsNotMutated(_ sql: String) async throws {
        let f = try IndexFixture(); _ = try await f.prepare()
        try indexMutate(f.store.fileURL, sql: sql)
        let before = try indexBytes(f.store.fileURL)
        let restarted = try SemanticIndexStore(directory: f.directory)
        await indexError(sql.contains("user_version") ? .unsupportedVersion : .corruptIndex) { _ = try await restarted.activeGeneration() }
        #expect(try indexBytes(f.store.fileURL) == before)
    }

    @Test(arguments: [true, false])
    func finalSymlinkAndHardlinkDoNotChangeForeignBytes(_ symbolic: Bool) async throws {
        let f = try IndexFixture()
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let foreign = f.directory.appendingPathComponent("edits.sqlite")
        let bytes = Data("synthetic-foreign-edit-database".utf8); try bytes.write(to: foreign)
        if symbolic { try FileManager.default.createSymbolicLink(at: f.store.fileURL, withDestinationURL: foreign) }
        else { #expect(Darwin.link(foreign.path, f.store.fileURL.path) == 0) }
        await indexError(.corruptIndex) { _ = try await f.store.activeGeneration() }
        #expect(try Data(contentsOf: foreign) == bytes)
    }

    @Test func unknownAndOrphanFilesRemainUntilExplicitQuarantine() async throws {
        let f = try IndexFixture()
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let bytes = Data("synthetic-rejected-index".utf8), journal = Data("synthetic-unresolved-journal".utf8)
        try bytes.write(to: f.store.fileURL)
        try journal.write(to: URL(fileURLWithPath: f.store.fileURL.path + "-journal"))
        await indexError(.corruptIndex) { _ = try await f.store.activeGeneration() }
        #expect(try Data(contentsOf: f.store.fileURL) == bytes)
        let quarantine = try #require(await f.store.rebuildAfterExplicitUserAction())
        #expect(try Data(contentsOf: quarantine.appendingPathComponent("semantic-index.sqlite")) == bytes)
        #expect(try Data(contentsOf: quarantine.appendingPathComponent("semantic-index.sqlite-journal")) == journal)
        #expect(try await f.store.activeGeneration() == nil)
    }

    @Test func explicitDeletionClearsOnlyOwnedIndexAndInvalidatesHandles() async throws {
        let f = try IndexFixture(), generation = try await f.prepare()
        try await f.store.upsert(f.record("a"), in: generation); try await f.store.activate(generation)
        let unrelated = f.directory.appendingPathComponent("photo-metadata.sqlite"), bytes = Data("synthetic-editorial-texts".utf8)
        try bytes.write(to: unrelated)
        #expect(try await f.store.deleteAfterExplicitUserAction() == nil)
        #expect(try await f.store.activeGeneration() == nil)
        await indexError(.superseded) { _ = try await f.store.records(in: generation) }
        #expect(try Data(contentsOf: unrelated) == bytes)
        let replacement = try await f.prepare(); #expect(replacement.id != generation.id)
    }

    @Test func explicitDeletionQuarantinesUnknownExistingIndex() async throws {
        let f = try IndexFixture()
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let bytes = Data(); try bytes.write(to: f.store.fileURL)
        await indexError(.corruptIndex) { _ = try await f.store.activeGeneration() }
        #expect(try Data(contentsOf: f.store.fileURL) == bytes)
        let quarantine = try #require(await f.store.deleteAfterExplicitUserAction())
        #expect(try Data(contentsOf: quarantine.appendingPathComponent("semantic-index.sqlite")) == bytes)
        #expect(try await f.store.activeGeneration() == nil)
    }
}

private struct IndexFixture: Sendable {
    let directory: URL
    let store: SemanticIndexStore
    let descriptor = indexDescriptor()
    let installation = String(repeating: "a", count: 64)
    init(beforeCommit: (@Sendable () throws -> Void)? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("picedit-semantic-store-\(UUID())")
        if let beforeCommit { store = try SemanticIndexStore(directory: directory, beforeCommit: beforeCommit) }
        else { store = try SemanticIndexStore(directory: directory) }
    }
    func prepare() async throws -> SemanticIndexGeneration { try await store.prepareGeneration(for: descriptor, installationFingerprint: installation) }
    func record(_ id: String, revision: String = "inode1:ctime1:mtime1", vector: [Float] = [0.6, 0.8, 0]) -> SemanticIndexRecord {
        SemanticIndexRecord(assetID: id, source: AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/synthetic/\(id).png"), modifiedAt: Date(timeIntervalSince1970: 123), fileSize: 42), sourceRevision: revision, inputRasterSHA256: String(repeating: "c", count: 64), vector: vector)
    }
}
private func indexDescriptor(model: String = "synthetic-paired-model") -> SemanticModelDescriptor {
    SemanticModelDescriptor(modelID: model, sourceRevision: "revision1", releaseID: "release1", dimension: 3, maximumTextTokens: 64, tokenizerVersion: "tokenizer1", preprocessingVersion: 1, normalizationVersion: 1)
}
private func indexError(_ expected: SemanticEmbeddingError, _ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected \(expected)") } catch { #expect(error as? SemanticEmbeddingError == expected) }
}
private final class IndexFailureSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var armed = false
    func arm() { lock.withLock { armed = true } }
    func check() throws {
        let fail = lock.withLock { let result = armed; armed = false; return result }
        if fail { throw SemanticEmbeddingError.indexUnavailable }
    }
}
private final class IndexCommitGate: @unchecked Sendable {
    private let lock = NSLock(); private var armed = false
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { armed = true } }
    // Only the detached test waiter blocks, never the async test executor.
    func waitUntilEntered() { entered.wait() }
    func waitIfArmed() {
        let wait = lock.withLock { let result = armed; armed = false; return result }
        if wait { entered.signal(); release.wait() }
    }
}
private func indexPath(_ url: URL) throws -> String {
    guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw SemanticEmbeddingError.corruptIndex }
    defer { free(parent) }
    return URL(fileURLWithPath: String(cString: parent), isDirectory: true).appendingPathComponent(url.lastPathComponent).path
}
private func indexMutate(_ url: URL, sql: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(try indexPath(url), &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { sqlite3_close(connection); throw SemanticEmbeddingError.corruptIndex }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw SemanticEmbeddingError.corruptIndex }
}
private func indexScalar(_ url: URL, sql: String) throws -> String {
    var connection: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(try indexPath(url), &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { sqlite3_close(connection); throw SemanticEmbeddingError.corruptIndex }
    defer { sqlite3_finalize(statement); sqlite3_close(connection) }
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw SemanticEmbeddingError.corruptIndex }
    return String(cString: bytes)
}
private func indexBytes(_ url: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for suffix in ["", "-journal", "-wal", "-shm"] {
        let file = URL(fileURLWithPath: url.path + suffix)
        if FileManager.default.fileExists(atPath: file.path) { result[suffix] = try Data(contentsOf: file) }
    }
    return result
}
