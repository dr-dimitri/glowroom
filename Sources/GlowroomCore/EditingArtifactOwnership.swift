// Shared immutable artifact values and capabilities for schema-2 editing.
// Persistence and App owners validate these at their durable boundaries.
import Foundation
import CoreGraphics
import CryptoKit

public enum ArtifactPayloadRole: Hashable, Sendable {
    case manifest, raster, mask(ArtifactResourceID), maskDocument(ArtifactResourceID)
}

public enum ArtifactLeasePurpose: String, Sendable {
    case activeEditing, undoRedo, draft, nativeRead, acceptedCommit, backup, restore
}

/// A strong lifetime capability. No public initializer, Codable, raw nonce,
/// filesystem URL or public cancel/release method. B creates it and validates
/// its private owner identity against the receiving store, not only visible IDs.
public final class ArtifactLease: @unchecked Sendable {
    public let storeID: ArtifactStoreID
    public let artifactIDs: Set<GeneratedArtifactID>
    public let purpose: ArtifactLeasePurpose
    internal let nonce: UUID
    private let releaseOwnership: @Sendable () -> Void
    internal init(storeID: ArtifactStoreID, artifactIDs: Set<GeneratedArtifactID>, purpose: ArtifactLeasePurpose,
                  nonce: UUID, releaseOwnership: @escaping @Sendable () -> Void) {
        self.storeID = storeID; self.artifactIDs = artifactIDs; self.purpose = purpose
        self.nonce = nonce; self.releaseOwnership = releaseOwnership
    }
    deinit { releaseOwnership() } // B enqueues actor cleanup; never block deinit.
}

/// B pins a validated native FD/identity and an ownership object inside reader.
/// Consumers cannot close/reopen a path or substitute a different FD. The read
/// closure must allow at most 64 KiB per call, validate offset/overflow and pread.
/// Its capture keeps the actual FD and relevant lease alive until actual return.
public final class ArtifactFileReadHandle: @unchecked Sendable {
    public let bytes: Int64
    public let sha256: ArtifactDigest
    private let reader: @Sendable (Int64, Int) throws -> Data
    private let ownership: ArtifactLease?
    internal init(bytes: Int64, sha256: ArtifactDigest, ownership: ArtifactLease?,
                  reader: @escaping @Sendable (Int64, Int) throws -> Data) {
        self.bytes = bytes; self.sha256 = sha256; self.ownership = ownership; self.reader = reader
    }
    public func read(offset: Int64, maximumCount: Int = 65_536) throws -> Data {
        guard offset >= 0, offset <= bytes, maximumCount > 0, maximumCount <= 65_536 else {
            throw ArtifactContractError.invalidValue("bounded read")
        }
        return try reader(offset, maximumCount)
    }
}
public final class ArtifactReadHandle: Sendable {
    public let artifact: GeneratedArtifact
    public let file: ArtifactFileReadHandle
    internal init(artifact: GeneratedArtifact, file: ArtifactFileReadHandle) {
        self.artifact = artifact; self.file = file
    }
}
public final class ArtifactDraft: Sendable {
    public let id: ArtifactDraftID
    public let artifact: GeneratedArtifact
    internal let ownerID: ArtifactStoreID
    internal let nonce: UUID
    private let ownership: ArtifactLease
    internal init(id: ArtifactDraftID, artifact: GeneratedArtifact, ownerID: ArtifactStoreID,
                  nonce: UUID, ownership: ArtifactLease) {
        self.id = id; self.artifact = artifact; self.ownerID = ownerID
        self.nonce = nonce; self.ownership = ownership
    }
}
public final class PublishedArtifact: Sendable {
    public let artifact: GeneratedArtifact
    public let commitID: EditingCommitID
    internal let ownerID: ArtifactStoreID
    internal let nonce: UUID
    private let ownership: ArtifactLease
    internal init(artifact: GeneratedArtifact, commitID: EditingCommitID, ownerID: ArtifactStoreID,
                  nonce: UUID, ownership: ArtifactLease) {
        self.artifact = artifact; self.commitID = commitID; self.ownerID = ownerID
        self.nonce = nonce; self.ownership = ownership
    }
}

/// Lifetime wrapper only. The caller promises an immutable CGImage/provider;
/// B does all expensive validation/encode/read-back off MainActor. UI must show
/// the canonical draft reopened through B, not keep showing this input buffer.
public struct ArtifactRasterInput: @unchecked Sendable {
    public let image: CGImage
    /// Optional shared allocation ownership. B validates the same resource owner
    /// and actual stride*height before borrowing; nil is conservatively charged.
    public let memoryOwnership: ArtifactMemoryReservation?
    public init(immutableImage: CGImage, memoryOwnership: ArtifactMemoryReservation? = nil) {
        image = immutableImage; self.memoryOwnership = memoryOwnership
    }
}
public struct ArtifactMaskInput: @unchecked Sendable {
    public let id: ArtifactResourceID
    public let coordinateSpace: ArtifactCoordinateSpace
    public let image: CGImage
    public let memoryOwnership: ArtifactMemoryReservation?
    public let document: MaskDocument?
    public init(id: ArtifactResourceID = .init(), coordinateSpace: ArtifactCoordinateSpace, immutableImage: CGImage,
                memoryOwnership: ArtifactMemoryReservation? = nil, document: MaskDocument? = nil) {
        self.id = id; self.coordinateSpace = coordinateSpace; image = immutableImage
        self.memoryOwnership = memoryOwnership
        self.document = document
    }
}
public struct ArtifactRecoveryReport: Sendable {
    public let retainedOrphans: Set<GeneratedArtifactID>
    public let removedOwnedStagingCount: Int
    public let unrecognizedEntries: [String]
    public init(retainedOrphans: Set<GeneratedArtifactID>, removedOwnedStagingCount: Int,
                unrecognizedEntries: [String]) {
        self.retainedOrphans = retainedOrphans; self.removedOwnedStagingCount = removedOwnedStagingCount
        self.unrecognizedEntries = unrecognizedEntries
    }
}

public protocol GeneratedArtifactStoring: Actor {
    var storeID: ArtifactStoreID { get }
    /// B/Core validates parent SourceRef/fingerprint consistency, full snapshot,
    /// rendered input geometry and all mask-coordinate relationships. These
    /// checks are mandatory here even if C already validated the proposal.
    func stageRaster(_ input: ArtifactRasterInput, provenance: GenerationProvenance,
                     masks: [ArtifactMaskInput]) async throws -> ArtifactDraft
    /// Idempotent for same draft+commitID; a different commitID cannot claim a
    /// draft already assigned to another commit. Registry/owner checks mandatory.
    func publish(_ draft: ArtifactDraft, commitID: EditingCommitID) async throws -> PublishedArtifact
    func validatePublication(_ publication: PublishedArtifact) async throws
    func descriptor(_ id: GeneratedArtifactID) async throws -> GeneratedArtifact
    func acquireLease(ids: Set<GeneratedArtifactID>, purpose: ArtifactLeasePurpose) async throws -> ArtifactLease
    func openVerifiedRaster(_ id: GeneratedArtifactID) async throws -> ArtifactReadHandle
    /// Package IO opens at most its bounded transfer count, not the whole closure.
    /// Role maps to fixed managed names; arbitrary path strings never enter.
    func openVerifiedFile(_ id: GeneratedArtifactID, role: ArtifactPayloadRole) async throws -> ArtifactFileReadHandle
    func openVerifiedDraft(_ draft: ArtifactDraft) async throws -> ArtifactReadHandle
    /// Publishes only fully verified immutable backup payloads; identical IDs
    /// require byte-identical manifests/payloads, conflicting IDs reject all.
    func materialize(_ backup: ValidatedEditingBackup) async throws -> PublishedArtifactSet
    func recoverStagingAndReportOrphans(referenced: Set<GeneratedArtifactID>) async throws -> ArtifactRecoveryReport
    // No deletePublishedArtifact API in v1; published orphans are retained.
}

public struct GenerationCommitRequest: Sendable {
    public let commitID: EditingCommitID
    public let assetID: String
    public let draft: ArtifactDraft
    public let expected: EditingExpectedState
    public let expectedParentSource: EditingSourceFingerprint
    public let nextRevision: Int64
    public let requestSHA256: ArtifactDigest
    public init(commitID: EditingCommitID, assetID: String, draft: ArtifactDraft,
                expected: EditingExpectedState, expectedParentSource: EditingSourceFingerprint,
                nextRevision: Int64) throws {
        guard !assetID.isEmpty, assetID.utf8.count <= 16_384, nextRevision >= 0,
              expected.revision.map({ nextRevision > $0 }) != false else {
            throw ArtifactContractError.invalidValue("generated commit request")
        }
        self.commitID = commitID; self.assetID = assetID; self.draft = draft
        self.expected = expected; self.expectedParentSource = expectedParentSource; self.nextRevision = nextRevision
        let identity = GenerationCommitIdentity(schemaVersion: 1, commitID: commitID, assetID: assetID,
            artifactID: draft.artifact.id, manifestSHA256: draft.artifact.manifestSHA256,
            expected: expected, expectedParentSource: expectedParentSource, nextRevision: nextRevision)
        requestSHA256 = try ArtifactDigest(sha256: SHA256.hash(data: EditingContractJSON.encoder().encode(identity))
            .map { String(format: "%02x", $0) }.joined())
    }
}

private struct GenerationCommitIdentity: Encodable {
    let schemaVersion: Int
    let commitID: EditingCommitID
    let assetID: String
    let artifactID: GeneratedArtifactID
    let manifestSHA256: ArtifactDigest
    let expected: EditingExpectedState
    let expectedParentSource: EditingSourceFingerprint
    let nextRevision: Int64
}

/// Success evidence minted only by A after durable SQL commit, or reconstructed
/// internally by A's exact same-commitID lookup. Not Codable/model-decodable.
public final class ArtifactCommitReceipt: Sendable {
    public let commitID: EditingCommitID
    public let assetID: String
    public let requestSHA256: ArtifactDigest
    public let previous: EditingExpectedState
    public let stored: StoredEditingState
    public let artifactID: GeneratedArtifactID
    internal init(commitID: EditingCommitID, assetID: String, requestSHA256: ArtifactDigest, previous: EditingExpectedState,
                  stored: StoredEditingState, artifactID: GeneratedArtifactID) {
        self.commitID = commitID; self.assetID = assetID; self.requestSHA256 = requestSHA256; self.previous = previous
        self.stored = stored; self.artifactID = artifactID
    }
}

/// Move the EXISTING App EditingPersistence name here. Delete the App duplicate;
/// replace EditDatabase:EditingPersistence with EditingRepository conformance.
/// DB legacy loadAll/revisions/save remain separate Original-only conveniences.
public protocol EditingPersistence: Actor {
    func loadState() async throws -> EditingStoreState
    func saveSnapshot(_ snapshot: EditingSnapshot, for assetID: String,
                      expected: EditingExpectedState, revision: Int64) async throws -> StoredEditingState
    /// Store and compare requestSHA256 with the durable commitID receipt. Same
    /// ID+different identity MUST throw conflictingCommit, never replay success.
    func commitGenerated(_ request: GenerationCommitRequest) async throws -> ArtifactCommitReceipt
    func committed(_ commitID: EditingCommitID) async throws -> ArtifactCommitReceipt?
    func variants(for assetID: String) async throws -> [EditingVariant]
    func createBackup(automatic: Bool) async throws -> URL
    /// Stores with exclusive backup maintenance must await `maintenance(true)`
    /// before closing gate admission and `maintenance(false)` after finishing or
    /// safely aborting that phase, including errors. A failed true acknowledgement
    /// aborts before promotion. Immutable package copy stays editable. Stores
    /// without exclusive phases may use the forwarding default implementation.
    func createAutomaticBackup(maintenance: @escaping @Sendable (Bool) async throws -> Void) async throws -> URL
    func exportBackup(from source: URL, toNew destination: URL) async throws -> URL
    /// A backup warning never changes an already durable SQL-save result.
    func backupWarning() async -> String?
    func restoreBackup(from url: URL) async throws -> EditingStoreState
    /// Participant preparation only. The joint coordinator has already durably
    /// retained the original commands and exact prepared catalog bytes. A stores
    /// their immutable original digest/expected states, never current-row rebases.
    func prepareAssetRemap(_ plan: VerifiedAssetRemap,
                           preparingBy: CatalogParticipantPreparation) async throws -> PreparedAssetRemap
    /// Pure lookup: validates existing durable evidence without creating a
    /// journal, replaying SQL, abandoning a phase or rewriting a receipt. Nil only
    /// means this operation ID is absent; a digest mismatch is an explicit error.
    func inspectAssetRemap(_ id: EditingRemapID,
                           expectedRequestSHA256: ArtifactDigest) async throws -> AssetRemapInspection?
    /// Validated durable armed evidence is mandatory. Fresh filesystem checks
    /// compare against the ORIGINAL command; never substitute new source/CAS.
    func remapAssets(_ prepared: PreparedAssetRemap,
                     armedBy: ArmedCatalogCoordination) async throws -> AssetRemapReceipt
    /// Only the existing CatalogRepository publication boundary mints this
    /// evidence after exact-before CAS or verified actual-after recovery.
    func confirmCatalogRemap(_ prepared: PreparedAssetRemap,
                             publication: CatalogPublicationEvidence) async throws
    func completeAssetRemap(_ prepared: PreparedAssetRemap,
                            publication: CatalogPublicationEvidence) async throws -> AssetRemapReceipt
    /// Safe pre-arm abort only; participant and coordinator both prove that no
    /// editing mutation committed. Losing an observer/capability is not abort.
    func cancelPreparedAssetRemap(_ prepared: PreparedAssetRemap,
                                 abortedBy: CatalogCoordinationAbort) async throws
    /// A serializes whole dependent mutations across awaits. Every ordinary
    /// public mutation/load also consults the injected shared lifecycle gate;
    /// only closed coordinator recovery capabilities enter its fenced branch.
}

public extension EditingPersistence {
    func createAutomaticBackup(maintenance: @escaping @Sendable (Bool) async throws -> Void) async throws -> URL {
        try await createBackup(automatic: true)
    }
    func exportBackup(from source: URL, toNew destination: URL) async throws -> URL { throw ArtifactContractError.unsupportedFormat }
    func backupWarning() async -> String? { nil }
}

public protocol CatalogParticipantIdentifying: Actor {
    /// No create, migration, recovery or mutation; nil only for absent file.
    func inspectParticipantIdentity() async throws -> CatalogParticipantStoreIdentity?
    /// Normal gated initialization, or true coordinator maintenance at startup.
    func participantStoreIdentity() async throws -> CatalogParticipantStoreIdentity
}
public protocol CoordinatedEditingStoring: EditingPersistence, CatalogParticipantIdentifying {
    func recoverDamagedDatabase(from url: URL, authorizedBy: CatalogEditingRecoveryPermit) async throws -> EditingStoreState
}

// Gate surface shared by all injected repositories and App owners.
public enum CatalogWriterDomain: String, Sendable {
    case catalog, editing, photoMetadata, artifactPublication, backupRestore
}
public enum CatalogMaintenancePurpose: Sendable {
    case coordination(UUID), backup(UUID), restore(UUID), shutdown(UUID)
}
public final class CatalogAcceptedWriteAdmission: Sendable {
    public let domain: CatalogWriterDomain
    public let sessionID: UUID
    internal let ownerID: UUID
    internal let nonce: UUID
    private let releaseOwnership: @Sendable () -> Void
    internal init(domain:CatalogWriterDomain,sessionID:UUID,ownerID:UUID,nonce:UUID,
                  releaseOwnership:@escaping @Sendable () -> Void) {
        self.domain = domain; self.sessionID = sessionID; self.ownerID = ownerID
        self.nonce = nonce; self.releaseOwnership = releaseOwnership
    }
    deinit { releaseOwnership() }
}
public final class CatalogMaintenanceAdmission: Sendable {
    public let purpose: CatalogMaintenancePurpose
    internal let ownerID: UUID
    internal let nonce: UUID
    internal init(purpose:CatalogMaintenancePurpose,ownerID:UUID,nonce:UUID) {
        self.purpose = purpose; self.ownerID = ownerID; self.nonce = nonce
    }
    // No public unlock/cancel. Coordinator owns it independently of observers.
}
public protocol CatalogLifecycleGating: Sendable {
    func waitForStartup() async throws -> CatalogStartupAdmission
    /// Synchronous registration before App launches an accepted task; implement
    /// with one small synchronized registry, not actor-await-before-registration.
    func registerAcceptedWrite(domain:CatalogWriterDomain,
                               session:CatalogStartupAdmission) throws -> CatalogAcceptedWriteAdmission
    /// Retains admission until actual operation return. A TaskLocal/private
    /// context carries it across existing actor hops; every repository validates
    /// its private owner/domain/session. It is not a general permission closure
    /// allowing unregistered calls to bypass repository checks.
    func withAcceptedWrite<Result:Sendable>(_ admission:CatalogAcceptedWriteAdmission,
                        operation:@Sendable () async throws -> Result) async throws -> Result
    /// Blocks NEW admission, drains registered work, then grants exclusive state.
    /// Never hold a native flock or SQL transaction while awaiting the drain.
    func beginMaintenance(_ purpose:CatalogMaintenancePurpose) async throws -> CatalogMaintenanceAdmission
    /// Explicit upgrade for a CatalogWriter/backup/restore operation already
    /// running in withAcceptedWrite. Atomically close new admission and transfer
    /// ONLY this validated running nonce out of the normal drain count. Drain
    /// every OTHER accepted writer before returning exclusive ownership.
    /// A second concurrent promotion fails maintenanceAlreadyPending; it must
    /// return/unwind its admission rather than wait while the first drains it.
    /// An ordinary beginMaintenance from an accepted execution rejects instead
    /// of waiting on itself. No implicit TaskLocal exclusion or bypass.
    func promoteAcceptedWrite(_ admission:CatalogAcceptedWriteAdmission,
                             to purpose:CatalogMaintenancePurpose) async throws -> CatalogMaintenanceAdmission
    /// Validates the exact owner/nonce and that durable coordinator work is
    /// completed/safely aborted. For backup this may finish after closed SQL
    /// snapshot+lease derivation; package file copy continues under its own lease.
    func finishMaintenance(_ admission:CatalogMaintenanceAdmission) async throws
}

/*
SHARED LIFECYCLE REQUIREMENT FOR REPOSITORY AND APP ENTRY POINTS:

The Core coordinator owns one injected gate used by CatalogWriter, EditingModel,
EditingRepository, PhotoMetadataRepository and artifact publication/package restore.
Both LibraryModel and EditingModel await the SAME successful recoverAndOpen()
admission before publishing editable catalog/edit state; an independent early
loadState() must not expose remapped SQL against a before catalog. Read-only
participant inspection remains available while fenced so recovery can proceed.

Normal catalog save/import/remove/refresh/bookmark resolution, warm metadata
retry/resolution, manual/AI metadata mutations, snapshot/generated/undo writes,
restore, mutable artifact publication and shutdown flush all use that gate.
There is no metadata-only shortcut around an editing-only pending operation.

Synchronous UI acceptance registers its strongly held write admission BEFORE
launching the task. A maintenance request closes admission for NEW writes, then
drains already admitted tasks and actual native/SQL work. Already admitted tasks
are allowed to enter/drain under their original lease; otherwise waiting for them
while blocking their repository admission would deadlock. The coordinator takes
exclusive maintenance only after the drain. A CatalogWriter relocation already
inside withAcceptedWrite first calls promoteAcceptedWrite(theExactAdmission,to:),
then passes the returned maintenance capability into coordinator.prepare. The
registry allows exactly one running execution per normal admission, validates
its explicit owner/nonce at promotion, and transfers it once; the outer wrapper
/deinit cannot double-release it or unlock the maintenance fence. Other accepted
writers still drain normally. Competing promotions fail promptly and unwind,
not queue while retaining a drain-counted lease. Only the shared gate mints the
closed upgrade; merely inheriting TaskLocal state never grants exclusive access. Observer cancellation never releases
an accepted task's lease early. Internal recovery/drain must not call public
flush or recursively await the same exclusive gate. No SQLite lock/flock spans
an actor await. The CatalogLifecycleGating surface above is used by the App admission layer
and concrete repository entry points. Normal
mutations without an inherited accepted admission must obtain a new registered
slot; fenced recovery instead uses closed coordinator capability. No extra pool.

A participant missing from a DURABLE requiredParticipants list after restart is
recovery-required, even if injection currently omits it. Only a NEW operation may
be prepared without the optional metadata participant. Metadata imports remain
outside editing backup packages; a coordinator fence is not backup content.
*/
