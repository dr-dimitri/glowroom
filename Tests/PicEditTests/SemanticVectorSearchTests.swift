import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Bounded semantic cosine ranking")
struct SemanticVectorSearchTests {
    private func source(_ id: String, changed: Bool = false) -> AIOriginalSourceFingerprint {
        AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/synthetic/" + id + ".png"),
            modifiedAt: Date(timeIntervalSince1970: changed ? 2 : 1), fileSize: 10)
    }
    private func record(_ id: String, _ vector: [Float], revision: String = "current", changed: Bool = false) -> SemanticIndexRecord {
        SemanticIndexRecord(assetID: id, source: source(id, changed: changed), sourceRevision: revision,
            inputRasterSHA256: String(repeating: "a", count: 64), vector: vector)
    }
    private func worker(_ ids: [String], topK: Int = 100) throws -> SemanticVectorSearch {
        try SemanticVectorSearch(query: [1, 0], dimension: 2,
            candidates: ids.map { SemanticIndexCandidate(assetID: $0, source: source($0)) },
            sourceRevisions: Dictionary(ids.map { ($0, "current") }, uniquingKeysWith: { _, new in new }), topK: topK)
    }

    @Test func actualAccelerateProductsIncludeNegativeSimilarity() throws {
        var search = try worker(["middle", "negative", "best"])
        try search.consume([record("middle", [0.6, 0.8]), record("negative", [-1, 0]), record("best", [1, 0])])
        #expect(search.hits.map(\.assetID) == ["best", "middle", "negative"])
        #expect(abs(search.hits[1].score - 0.6) < 0.00001)
        #expect(search.hits[2].score == -1)
    }

    @Test func pageBoundaryTiesKeepProjectionOrderAtTopK() throws {
        let ids = (0..<600).reversed().map { String(format: "%04d", $0) }
        var search = try worker(ids, topK: 100)
        for start in stride(from: 0, to: 600, by: 128) {
            let page = (start..<min(start + 128, 600)).map { record(String(format: "%04d", $0), [1, 0]) }
            try search.consume(page)
            #expect(search.hits.count <= 100)
        }
        #expect(search.hits.map(\.assetID) == Array(ids.prefix(100)))
    }

    @Test func removedAndChangedSourcesCannotBecomeHits() throws {
        var search = try worker(["good", "changed", "stamp"])
        try search.consume([record("good", [0, 1]), record("removed", [1, 0]),
            record("changed", [1, 0], changed: true), record("stamp", [1, 0], revision: "old")])
        #expect(search.hits.map(\.assetID) == ["good"])
    }

    @Test(arguments: [[Float.nan, 0], [Float.infinity, 0], [0, 0], [2, 0], [1]])
    func invalidVectorsAreRejectedBeforeAnyRanking(_ vector: [Float]) throws {
        #expect(throws: SemanticEmbeddingError.invalidVector) {
            _ = try SemanticVectorSearch(query: vector, dimension: 2, candidates: [], sourceRevisions: [:], topK: 1)
        }
        var search = try worker(["good"])
        #expect(throws: SemanticEmbeddingError.invalidVector) {
            try search.consume([record("removed-but-corrupt", vector)])
        }
        #expect(search.hits.isEmpty)
    }

    @Test func topKAndPageBoundsAndUniqueCandidateIdentity() throws {
        for limit in [0, 501] {
            #expect(throws: SemanticEmbeddingError.invalidInput) { _ = try worker(["a"], topK: limit) }
        }
        #expect(throws: SemanticEmbeddingError.invalidInput) { _ = try worker(["a", "a"]) }
        var search = try worker(["a"], topK: 500)
        #expect(throws: SemanticEmbeddingError.invalidInput) {
            try search.consume((0..<513).map { record(String($0), [1, 0]) })
        }
    }
}

@Suite("Shared semantic inference priority", .timeLimit(.minutes(1)))
struct SemanticBudgetPriorityTests {
    @Test func interactiveWorkPassesQueuedIndexWorkWithoutPreemptingActiveLease() async throws {
        let budget = AIResourceBudget()
        let active = try await budget.acquireLocalInference()
        let events = SemanticBudgetEvents()
        let background = Task {
            let lease = try await budget.acquireLocalInference(priority: .background)
            await events.record("index", lease)
        }
        var states = await budget.stateUpdates().makeAsyncIterator()
        while let state = await states.next(), state.waitingInferences < 1 { }
        let interactive = Task {
            let lease = try await budget.acquireLocalInference(priority: .interactive)
            await events.record("query", lease)
        }
        while let state = await states.next(), state.waitingInferences < 2 { }
        #expect(await events.values.isEmpty)
        await budget.release(active)
        for _ in 0..<1_000 {
            if await events.values.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let first = try #require(await events.values.first)
        #expect(first.0 == "query")
        await budget.release(first.1)
        for _ in 0..<1_000 {
            if await events.values.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = try #require(await events.values.last)
        #expect(second.0 == "index")
        await budget.release(second.1)
        try await background.value; try await interactive.value
    }
}

private actor SemanticBudgetEvents {
    private(set) var values: [(String, AIResourceBudget.Lease)] = []
    func record(_ name: String, _ lease: AIResourceBudget.Lease) { values.append((name, lease)) }
}
