import Foundation
import GlowroomCore

struct SemanticSearchHit: Equatable, Sendable {
    let assetID: String
    let score: Float
}

/// Candidate order is the projection worker's existing sort order. The search
/// preserves that ordinal at score ties, including the bounded top-K boundary.
struct SemanticSearchResult: Sendable {
    let catalogSessionID: UUID
    let catalogGeneration: Int
    let indexGenerationID: UUID
    let modelDescriptor: SemanticModelDescriptor
    let candidateAssetIDs: [String]
    let hits: [SemanticSearchHit]
}

struct SemanticSearchState: Equatable, Sendable {
    let version: UInt64
    let availability: SemanticAvailability
    let indexGenerationID: UUID?
    let indexedCount: Int
    let totalCount: Int
    let staleCount: Int
    let missingCount: Int
    let processedCount: Int
    let isIndexing: Bool
    let notice: String?
    let modelDescriptor: SemanticModelDescriptor?
    let installedBytes: Int64?

    init(version: UInt64, availability: SemanticAvailability, indexGenerationID: UUID?,
         indexedCount: Int, totalCount: Int, staleCount: Int, missingCount: Int,
         processedCount: Int, isIndexing: Bool, notice: String?,
         modelDescriptor: SemanticModelDescriptor? = nil, installedBytes: Int64? = nil) {
        self.version = version; self.availability = availability; self.indexGenerationID = indexGenerationID
        self.indexedCount = indexedCount; self.totalCount = totalCount; self.staleCount = staleCount
        self.missingCount = missingCount; self.processedCount = processedCount; self.isIndexing = isIndexing
        self.notice = notice; self.modelDescriptor = modelDescriptor; self.installedBytes = installedBytes
    }

    static let notInstalled = SemanticSearchState(version: 0,
        availability: .unavailable(.modelNotInstalled), indexGenerationID: nil,
        indexedCount: 0, totalCount: 0, staleCount: 0, missingCount: 0,
        processedCount: 0, isIndexing: false, notice: nil)
}

protocol SemanticSearchServing: Sendable {
    func updateCatalog(snapshotSessionID: UUID, generation: Int, assets: [PhotoAsset]) async
    func search(query: String, candidates: [PhotoAsset], topK: Int) async throws -> SemanticSearchResult
    func status(scope: [PhotoAsset]) async throws -> SemanticSearchState
    func updates() async -> AsyncStream<SemanticSearchState>
    /// Returns after the bounded indexing operation ends. Cancellation preserves
    /// individually committed entries and the last active model generation.
    func prepareIndex(scope: [PhotoAsset], rebuild: Bool) async throws
    func cancelIndexing() async
    func deleteIndex() async throws
    func inspectModel(source: URL) async throws -> SemanticModelImportReview
    func installModel(_ review: SemanticModelImportReview) async throws
    func removeModel() async throws
    func shutdown() async
}
