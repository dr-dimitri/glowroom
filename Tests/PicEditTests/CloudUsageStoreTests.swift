import Foundation
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
}
