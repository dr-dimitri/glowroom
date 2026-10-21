import Foundation
import GlowroomCore

/// Streaming exact cosine search. Retains a single bounded page plus at
/// most 500 winners; the original candidate order supplies PhotoSort tie breaks.
struct SemanticVectorSearch: Sendable {
    private let query: [Double]
    private let dimension: Int
    private let sources: [String: AIOriginalSourceFingerprint]
    private let ordinals: [String: Int]
    private let sourceRevisions: [String: String]
    private let topK: Int
    private(set) var hits: [SemanticSearchHit] = []

    init(query: [Float], dimension: Int, candidates: [SemanticIndexCandidate],
         sourceRevisions: [String: String], topK: Int) throws {
        guard (1...4_096).contains(dimension), (1...500).contains(topK),
              candidates.count <= 1_000_000,
              Set(candidates.map(\.assetID)).count == candidates.count else {
            throw SemanticEmbeddingError.invalidInput
        }
        try Self.validateVector(query, dimension: dimension)
        self.query = query.map(Double.init); self.dimension = dimension; self.topK = topK
        self.sources = Dictionary(uniqueKeysWithValues: candidates.map { ($0.assetID, $0.source) })
        self.ordinals = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($0.element.assetID, $0.offset) })
        self.sourceRevisions = sourceRevisions
    }

    mutating func consume(_ records: [SemanticIndexRecord]) throws {
        try Task.checkCancellation()
        guard records.count <= SemanticIndexStore.maximumPageSize,
              Set(records.map(\.assetID)).count == records.count else {
            throw SemanticEmbeddingError.invalidInput
        }
        var scored: [SemanticSearchHit] = []
        scored.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            if index % 32 == 0 { try Task.checkCancellation() }
            // Corrupt persisted vectors are errors, even when their row would
            // currently be excluded by a folder or source filter.
            try Self.validateVector(record.vector, dimension: dimension)
            guard let source = sources[record.assetID], source == record.source,
                  let revision = sourceRevisions[record.assetID], revision == record.sourceRevision else { continue }
            // GEMM may choose different Float32 reduction orders for a row
            // depending on page size/position. That noise must not outrank the
            // user's PhotoSort when two embeddings are byte-identical. A fixed
            // four-lane Double reduction has a fixed order per vector, keeps
            // SIMD parallelism, and needs no approximate comparator or pool.
            var lanes = SIMD4<Double>(repeating: 0)
            let alignedEnd = dimension - dimension % 4
            for component in stride(from: 0, to: alignedEnd, by: 4) {
                let values = SIMD4<Double>(Double(record.vector[component]), Double(record.vector[component + 1]),
                    Double(record.vector[component + 2]), Double(record.vector[component + 3]))
                let weights = SIMD4<Double>(query[component], query[component + 1], query[component + 2], query[component + 3])
                lanes += values * weights
            }
            var dot = ((lanes.x + lanes.y) + lanes.z) + lanes.w
            for component in alignedEnd..<dimension {
                dot += Double(record.vector[component]) * query[component]
            }
            let score = Float(dot)
            guard score.isFinite, abs(score) <= 1.003 else { throw SemanticEmbeddingError.invalidVector }
            // Scores are similarities, never probabilities or confidence bins.
            scored.append(SemanticSearchHit(assetID: record.assetID, score: score))
        }
        try Task.checkCancellation()
        var byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.assetID, $0) })
        for hit in scored { byID[hit.assetID] = hit }
        hits = byID.values.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            let l = ordinals[left.assetID]!, r = ordinals[right.assetID]!
            return l == r ? left.assetID < right.assetID : l < r
        }.prefix(topK).map { $0 }
    }

    static func validateVector(_ vector: [Float], dimension: Int) throws {
        guard vector.count == dimension, vector.allSatisfy(\.isFinite) else {
            throw SemanticEmbeddingError.invalidVector
        }
        let squaredNorm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squaredNorm.isFinite, squaredNorm > 0,
              abs(sqrt(squaredNorm) - 1) <= SemanticIndexStore.normalizationNormTolerance else {
            throw SemanticEmbeddingError.invalidVector
        }
    }
}
