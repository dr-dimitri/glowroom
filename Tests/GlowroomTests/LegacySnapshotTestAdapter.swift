import Foundation
import GlowroomCore

/// Test-only bridge for the existing slider/failure schedules. Production has
/// no synthesized epoch or legacy EditDatabase-to-new-protocol conformance.
protocol LegacySnapshotTestStore: Actor {
    func loadAll() async throws -> [String: EditSettings]
    func revisions() async throws -> [String: Int64]
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) async throws
    func createBackup(automatic: Bool) async throws -> URL
    func restoreBackup(from url: URL) async throws -> [String: EditSettings]
}

actor LegacySnapshotTestAdapter: EditingPersistence {
    let legacy: any LegacySnapshotTestStore
    private var epoch = UUID()
    init(_ legacy: any LegacySnapshotTestStore) { self.legacy = legacy }
    func loadState() async throws -> EditingStoreState {
        let values = try await legacy.loadAll(), revisions = try await legacy.revisions()
        var stored: [String: StoredEditingState] = [:], tombstones: [String: Int64] = [:]
        for (id, revision) in revisions {
            if let value = values[id] {
                stored[id] = StoredEditingState(snapshot: try EditingSnapshot(settings: value), version: try EditingStoreVersion(storeEpoch: epoch, revision: revision))
            } else { tombstones[id] = revision }
        }
        // Several original fakes omit a zero revision for a seeded value.
        for (id, value) in values where stored[id] == nil {
            stored[id] = StoredEditingState(snapshot: try EditingSnapshot(settings: value), version: try EditingStoreVersion(storeEpoch: epoch, revision: revisions[id] ?? 0))
        }
        return try EditingStoreState(storeEpoch: epoch, byAsset: stored, tombstones: tombstones)
    }
    func saveSnapshot(_ snapshot: EditingSnapshot, for assetID: String, expected: EditingExpectedState, revision: Int64) async throws -> StoredEditingState {
        let state = try await loadState()
        let actual = try state.byAsset[assetID].map { EditingExpectedState($0) } ?? EditingExpectedState(storeEpoch: epoch, revision: state.tombstones[assetID], snapshot: nil)
        guard expected == actual, snapshot.source == .original else { throw ArtifactContractError.staleSnapshot }
        try await legacy.save(snapshot.settings, for: assetID, revision: revision)
        return StoredEditingState(snapshot: snapshot, version: try EditingStoreVersion(storeEpoch: epoch, revision: revision))
    }
    func createBackup(automatic: Bool) async throws -> URL { try await legacy.createBackup(automatic: automatic) }
    func restoreBackup(from url: URL) async throws -> EditingStoreState { _ = try await legacy.restoreBackup(from: url); epoch = UUID(); return try await loadState() }
    func commitGenerated(_ request: GenerationCommitRequest) async throws -> ArtifactCommitReceipt { throw ArtifactContractError.unsupportedFormat }
    func committed(_ id: EditingCommitID) async throws -> ArtifactCommitReceipt? { nil }
    func variants(for assetID: String) async throws -> [EditingVariant] { [] }
    func prepareAssetRemap(_ plan: VerifiedAssetRemap, preparingBy: CatalogParticipantPreparation) async throws -> PreparedAssetRemap { throw ArtifactContractError.unsupportedFormat }
    func inspectAssetRemap(_ id: EditingRemapID, expectedRequestSHA256: ArtifactDigest) async throws -> AssetRemapInspection? { nil }
    func remapAssets(_ prepared: PreparedAssetRemap, armedBy: ArmedCatalogCoordination) async throws -> AssetRemapReceipt { throw ArtifactContractError.unsupportedFormat }
    func confirmCatalogRemap(_ prepared: PreparedAssetRemap, publication: CatalogPublicationEvidence) async throws { throw ArtifactContractError.unsupportedFormat }
    func completeAssetRemap(_ prepared: PreparedAssetRemap, publication: CatalogPublicationEvidence) async throws -> AssetRemapReceipt { throw ArtifactContractError.unsupportedFormat }
    func cancelPreparedAssetRemap(_ prepared: PreparedAssetRemap, abortedBy: CatalogCoordinationAbort) async throws { throw ArtifactContractError.unsupportedFormat }
}
