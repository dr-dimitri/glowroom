// Shared #10 App contract compile checkpoint; implementation follows interface review.
import Foundation
import GlowroomCore

/// Ephemeral app token: never Codable/model-facing. Carries local and persisted
/// versions separately, so pending slider writes cannot be blessed by reloading.
public struct GenerationSnapshotToken: Hashable, Sendable {
    public let assetID: String
    public let snapshot: EditingSnapshot
    public let source: EditingSourceFingerprint
    public let persistedAtCapture: EditingExpectedState
    public let localRevision: Int64
    public let uiToken: AIEditingToken
    public init(assetID: String, snapshot: EditingSnapshot, source: EditingSourceFingerprint,
                persistedAtCapture: EditingExpectedState, localRevision: Int64, uiToken: AIEditingToken) {
        self.assetID = assetID; self.snapshot = snapshot; self.source = source
        self.persistedAtCapture = persistedAtCapture; self.localRevision = localRevision; self.uiToken = uiToken
    }
}

/// EditingModel retains this strongly until completion. A caller only observes
/// value; canceling that wait, changing selection or dropping the view cannot
/// cancel the accepted persistence task. No public arbitrary receipt initializer.
@MainActor public final class AcceptedArtifactCommit {
    public let id: EditingCommitID
    private let task: Task<ArtifactCommitReceipt, Error>
    internal init(id: EditingCommitID, task: Task<ArtifactCommitReceipt, Error>) { self.id = id; self.task = task }
    public func result() async throws -> ArtifactCommitReceipt { try await task.value }
}
public enum ArtifactCommitAdmission {
    case rejected(ArtifactContractError)
    case accepted(AcceptedArtifactCommit)
}
@MainActor public protocol GeneratedArtifactAccepting: AnyObject {
    /// Synchronous MainActor gate: compare full source/settings/localRevision,
    /// persisted epoch/baseline and UI epochs before registering owned commit task.
    /// No suspension before ownership and isCommitting publication.
    func applyGeneratedArtifact(_ draft: ArtifactDraft,
                                expectedSnapshotToken: GenerationSnapshotToken) -> ArtifactCommitAdmission
    /// Retry the retained SAME request/commitID after an error; never mint a new
    /// commitID or undo entry. Resolve a possible durable receipt before writing.
    func retryAcceptedArtifactCommit(_ id: EditingCommitID) -> ArtifactCommitAdmission
    func awaitAcceptedCommits() async -> Bool
}

public enum EditingRenderIntent: Hashable, Sendable {
    case currentEditing
    case currentSourceWithoutSettings
    case importedOriginal
}

/// C supplies this to existing PreviewRequest using sourceRevision derived from
/// typed identity. Artifact branch MUST never expose a file URL as an Original.
public enum ResolvedEditingSource: Sendable {
    case original(fingerprint: AIOriginalSourceFingerprint, nativeRevision: OriginalSourceRevision?, settings: EditSettings)
    case artifact(fingerprint: ArtifactSourceFingerprint, settings: EditSettings)
}
public protocol EditingSourceResolving: Sendable {
    /// Metadata selection only; opening/verified decode occurs after admission
    /// to existing preview workers. No FD per cell merely to build a grid request.
    func resolve(asset: PhotoAsset, snapshot: EditingSnapshot,
                 intent: EditingRenderIntent) async throws -> ResolvedEditingSource
}

// C extends existing AISourceIdentity with artifact(ArtifactSourceFingerprint),
// and existing AIEditingSnapshot with persistedVersion:EditingExpectedState?; nil only for original-only analysis.
// Existing AIEditingToken stays intact. Original analysis binds importedOriginal
// identity + selection/lifecycle; edited analysis binds full active snapshot.
// No new text/model DTO contains source paths, artifact IDs or store epochs.
