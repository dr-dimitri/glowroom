import Foundation
import Darwin
import CSQLite
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Cloud usage reservations", .serialized)
struct CloudUsageStoreTests {
    @Test func concurrencyAcrossStoresCannotExceedCountOrBudget() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-ledger-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try CloudUsageStore(url: url), b = try CloudUsageStore(url: url)
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<20 {
                group.addTask { do { _ = try await (i % 2 == 0 ? a : b).reserve(requestLimit: 2, budgetNanodollars: 1_200_000_000, maximumOutputTokens: 1_200); return true } catch { return false } }
            }
            var result = 0; for await success in group { if success { result += 1 } }; return result
        }
        #expect(succeeded == 2)
        #expect(try await a.summary().requestCount == 2)
        #expect(try await a.summary().chargedNanodollars == 1_200_000_000)
    }
    @Test func dispatchedCrashUncertaintySurvivesReopenAndNoZeroUnknownCosts() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-restart-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try CloudUsageStore(url: url)
        let r = try await a.reserve(requestLimit: 5, budgetNanodollars: 1_000_000_000, maximumOutputTokens: 1_200)
        try await a.markDispatched(id: r.id)
        let b = try CloudUsageStore(url: url)
        #expect(try await b.summary().uncertainCount == 1)
        #expect(try await b.summary().chargedNanodollars == 600_000_000)
        await expectCloud(.limitExceeded) { _ = try await b.reserve(requestLimit: 5, budgetNanodollars: 1_000_000_000, maximumOutputTokens: 1_200) }
        try await b.releaseUndispatched(id: r.id)
        #expect(try await b.summary().chargedNanodollars == 600_000_000)
    }
    @Test func predispatchReleaseAndReportedPriceReconciliation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-release-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CloudUsageStore(url: url)
        let a = try await store.reserve(requestLimit: 1, budgetNanodollars: 600_000_000, maximumOutputTokens: 1_200)
        try await store.releaseUndispatched(id: a.id)
        #expect(try await store.summary().requestCount == 0)
        let b = try await store.reserve(requestLimit: 1, budgetNanodollars: 600_000_000, maximumOutputTokens: 1_200)
        try await store.markDispatched(id: b.id)
        await expectCloud(.invalidResponse) { try await store.settle(id: b.id, inputTokens: -1, outputTokens: 20) }
        #expect(try await store.summary().chargedNanodollars == 600_000_000)
        try await store.settle(id: b.id, inputTokens: 100_001, outputTokens: 1_200)
        #expect(try await store.summary().chargedNanodollars == 53_000_500)
        #expect(try await store.summary().outputTokens == 1_200)
        await expectCloud(.limitExceeded) { _ = try await store.reserve(requestLimit: 1, budgetNanodollars: 600_000_000, maximumOutputTokens: 1_200) }
    }
    @Test func ledgerFailurePreventsPaidDispatch() async throws {
        let f = try CloudFixture()
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        try Data("synthetic-not-a-database".utf8).write(to: f.directory.appendingPathComponent("cloud-usage.sqlite"))
        await f.enable(); try await f.authorize()
        await expectCloud(.persistence) { _ = try await f.provider.proposal(for: f.request) }
        #expect(f.transport.requests.isEmpty)
        #expect(await f.keychain.readCount == 0)
    }
    @Test(arguments: [true, false])
    func foreignEditDatabaseSymlinkOrHardlinkNeverMutatesOrUploads(_ symbolic: Bool) async throws {
        let f = try CloudFixture()
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let foreign = try EditDatabase(directory: f.directory.appendingPathComponent("foreign"))
        try await foreign.save(EditSettings(exposure: 1.25), for: "synthetic-photo", revision: 7)
        let target = foreign.fileURL
        let ledger = f.directory.appendingPathComponent("cloud-usage.sqlite")
        if symbolic { try FileManager.default.createSymbolicLink(at: ledger, withDestinationURL: target) }
        else { #expect(Darwin.link(target.path, ledger.path) == 0) }
        let before = try ledgerFileBytes(target)
        await f.enable(); try await f.authorize()
        await expectCloud(.persistence) { _ = try await f.provider.proposal(for: f.request) }
        #expect(try ledgerFileBytes(target) == before)
        // Apple SQLite invalidates its existing handle after a hardlink
        // changes the vnode, even when that link is removed. Exact database
        // and sidecar bytes above are the preservation proof in that case.
        if symbolic { #expect(try await foreign.loadAll()["synthetic-photo"]?.exposure == 1.25) }
        #expect(f.transport.requests.isEmpty)
        #expect(await f.keychain.readCount == 0)
    }
    @Test func foreignRegularSQLiteAndExistingEmptyFileAreNeverInitialized() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-foreign-\(UUID())")
        let foreign = try EditDatabase(directory: directory.appendingPathComponent("foreign"))
        try await foreign.save(EditSettings(contrast: 11), for: "synthetic", revision: 4)
        let standalone = try await foreign.createBackup()
        let url = directory.appendingPathComponent("cloud-usage.sqlite")
        try FileManager.default.copyItem(at: standalone, to: url)
        let before = try ledgerFileBytes(url)
        let store = try CloudUsageStore(url: url)
        await expectCloud(.persistence) { _ = try await store.summary() }
        #expect(try ledgerFileBytes(url) == before)
        let empty = directory.appendingPathComponent("empty.sqlite")
        try Data().write(to: empty)
        let rejected = try CloudUsageStore(url: empty)
        await expectCloud(.persistence) { _ = try await rejected.summary() }
        #expect(try Data(contentsOf: empty).isEmpty)
    }
    @Test(arguments: ["PRAGMA user_version=99", "PRAGMA application_id=0", "CREATE TABLE foreign_table(secret TEXT)", "CREATE TABLE sqliteXforeign(secret TEXT)"])
    func unknownOwnedSchemaOrVersionRejectedWithoutMutation(_ modification: String) async throws {
        let f = try CloudFixture()
        _ = try await f.usage.summary()
        try mutateLedgerFixture(f.usage.url, sql: modification)
        let before = try ledgerFileBytes(f.usage.url)
        let reopened = try CloudUsageStore(url: f.usage.url)
        await expectCloud(.persistence) { _ = try await reopened.summary() }
        #expect(try ledgerFileBytes(f.usage.url) == before)
    }
    @Test(arguments: ["amount=-1", "amount=0", "amount=9223372036854775807", "state='unknown'", "input_tokens=-1", "output_tokens=2401", "pricing='unknown'", "maximum_output=0"])
    func invalidPersistedRowsCannotReleaseBudget(_ modification: String) async throws {
        let f = try CloudFixture()
        _ = try await f.usage.reserve(requestLimit: 2, budgetNanodollars: 1_200_000_000, maximumOutputTokens: 1_200)
        try mutateLedgerFixture(f.usage.url, sql: "UPDATE cloud_usage SET " + modification)
        let before = try ledgerFileBytes(f.usage.url)
        let reopened = try CloudUsageStore(url: f.usage.url)
        await expectCloud(.persistence) { _ = try await reopened.summary() }
        // Also reject corruption observed by a connection that was already open.
        await expectCloud(.persistence) { _ = try await f.usage.reserve(requestLimit: 2, budgetNanodollars: 1_200_000_000, maximumOutputTokens: 1_200) }
        #expect(try ledgerFileBytes(f.usage.url) == before)
    }
    @Test func hotJournalIsPreservedAndNeverReinitializesLedger() async throws {
        let f = try CloudFixture()
        _ = try await f.usage.summary()
        let journal = URL(fileURLWithPath: f.usage.url.path + "-journal")
        try Data("synthetic-unresolved-journal".utf8).write(to: journal)
        let before = try ledgerFileBytes(f.usage.url)
        let reopened = try CloudUsageStore(url: f.usage.url)
        await expectCloud(.persistence) { _ = try await reopened.summary() }
        await expectCloud(.persistence) { _ = try await f.usage.summary() }
        #expect(try ledgerFileBytes(f.usage.url) == before)
    }
    @Test func orphanJournalDoesNotInitializeNewLedger() async throws {
        let f = try CloudFixture()
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let journal = URL(fileURLWithPath: f.usage.url.path + "-journal")
        let bytes = Data("synthetic-orphan-journal".utf8)
        try bytes.write(to: journal)
        await expectCloud(.persistence) { _ = try await f.usage.summary() }
        #expect(!FileManager.default.fileExists(atPath: f.usage.url.path))
        #expect(try Data(contentsOf: journal) == bytes)
    }
    @Test func failedInitializationRemovesOnlyItsNewEmptyFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-initialization-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cloud-usage.sqlite")
        let failed = try CloudUsageStore(url: url, beforeInitialization: { throw AICloudError.persistence })
        await expectCloud(.persistence) { _ = try await failed.summary() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let retry = try CloudUsageStore(url: url)
        #expect(try await retry.summary().requestCount == 0)
    }
    @Test func laterHardlinkIsRejectedByAlreadyOpenStore() async throws {
        let f = try CloudFixture()
        _ = try await f.usage.summary()
        let alias = f.directory.appendingPathComponent("alias.sqlite")
        #expect(Darwin.link(f.usage.url.path, alias.path) == 0)
        let before = try ledgerFileBytes(f.usage.url)
        await expectCloud(.persistence) { _ = try await f.usage.summary() }
        #expect(try ledgerFileBytes(f.usage.url) == before)
    }

}


/// Isolated fixture inspection only, never called on a user's ledger.
private func ledgerFileBytes(_ url: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for suffix in ["", "-journal", "-wal", "-shm"] {
        let item = URL(fileURLWithPath: url.path + suffix)
        if FileManager.default.fileExists(atPath: item.path) { result[suffix] = try Data(contentsOf: item) }
    }
    return result
}
private func mutateLedgerFixture(_ url: URL, sql: String) throws {
    var connection: OpaquePointer?
    guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw AICloudError.persistence }
    defer { free(parent) }
    let path = URL(fileURLWithPath: String(cString: parent), isDirectory: true).appendingPathComponent(url.lastPathComponent).path
    guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
        sqlite3_close(connection); throw AICloudError.persistence
    }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw AICloudError.persistence }
}
