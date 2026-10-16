import Accelerate
import Foundation
import PicEditCore

/// Streaming exact cosine search. Retains a single bounded matrix/page plus at
/// most 500 winners; the original candidate order supplies PhotoSort tie breaks.
struct SemanticVectorSearch: Sendable {
    private let query: [Float]
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
        self.query = query; self.dimension = dimension; self.topK = topK
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
        var identifiers: [String] = []
        var matrix: [Float] = []
        matrix.reserveCapacity(records.count * dimension)
        for (index, record) in records.enumerated() {
            if index % 32 == 0 { try Task.checkCancellation() }
            // Corrupt persisted vectors are errors, even when their row would
            // currently be excluded by a folder or source filter.
            try Self.validateVector(record.vector, dimension: dimension)
            guard let source = sources[record.assetID], source == record.source,
                  let revision = sourceRevisions[record.assetID], revision == record.sourceRevision else { continue }
            identifiers.append(record.assetID)
            matrix.append(contentsOf: record.vector)
        }
        guard !identifiers.isEmpty else { return }
        var scores = [Float](repeating: 0, count: identifiers.count)
        vDSP_mmul(matrix, 1, query, 1, &scores, 1,
                  vDSP_Length(identifiers.count), 1, vDSP_Length(dimension))
        try Task.checkCancellation()
        var byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.assetID, $0) })
        for (index, id) in identifiers.enumerated() {
            let score = scores[index]
            guard score.isFinite, abs(score) <= 1.003 else { throw SemanticEmbeddingError.invalidVector }
            // Scores are similarities, never probabilities. Keep the measured
            // dot product rather than inventing a universal confidence cutoff.
            byID[id] = SemanticSearchHit(assetID: id, score: score)
        }
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
