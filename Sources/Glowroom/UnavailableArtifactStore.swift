import Foundation
import GlowroomCore

/// Allows the real SQL/journal coordinator to inspect its independent state.
/// No method accesses files, invents an empty success or mints a capability.
actor UnavailableArtifactStore: GeneratedArtifactStoring {
    // Ephemeral routing sentinel only. Bootstrap never registers it for views
    // and never persists it as the damaged store's ownership identity.
    nonisolated let storeID = ArtifactStoreID()
    private let failure: Failure
    init(reason: String) { failure = Failure(reason: reason) }
    struct Failure: LocalizedError, Sendable {
        let reason: String
        var errorDescription: String? { reason }
    }
    func stageRaster(_ input: ArtifactRasterInput, provenance: GenerationProvenance, masks: [ArtifactMaskInput]) async throws -> ArtifactDraft { throw failure }
    func publish(_ draft: ArtifactDraft, commitID: EditingCommitID) async throws -> PublishedArtifact { throw failure }
    func validatePublication(_ publication: PublishedArtifact) async throws { throw failure }
    func descriptor(_ id: GeneratedArtifactID) async throws -> GeneratedArtifact { throw failure }
    func acquireLease(ids: Set<GeneratedArtifactID>, purpose: ArtifactLeasePurpose) async throws -> ArtifactLease { throw failure }
    func openVerifiedRaster(_ id: GeneratedArtifactID) async throws -> ArtifactReadHandle { throw failure }
    func openVerifiedFile(_ id: GeneratedArtifactID, role: ArtifactPayloadRole) async throws -> ArtifactFileReadHandle { throw failure }
    func openVerifiedDraft(_ draft: ArtifactDraft) async throws -> ArtifactReadHandle { throw failure }
    func materialize(_ backup: ValidatedEditingBackup) async throws -> PublishedArtifactSet { throw failure }
    func recoverStagingAndReportOrphans(referenced: Set<GeneratedArtifactID>) async throws -> ArtifactRecoveryReport { throw failure }
}
