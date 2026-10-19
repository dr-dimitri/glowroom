// Durable backup and cross-store catalog coordination contracts. Concrete
// stores mint ownership evidence only after native/SQL validation.
import Foundation

public struct EditingPackageLimits: Hashable, Sendable {
    public let maximumArtifacts: Int
    public let maximumFiles: Int
    public let maximumTotalBytes: Int64
    public let maximumPayloadBytes: Int64
    public let maximumManifestBytes: Int
    public let maximumArtifactManifestBytes: Int
    public init(maximumArtifacts: Int = 4_096, maximumFiles: Int = 16_384,
                maximumTotalBytes: Int64 = 21_474_836_480, maximumPayloadBytes: Int64 = 536_870_912,
                maximumManifestBytes: Int = EditSettings.maximumEncodedBytes, maximumArtifactManifestBytes: Int = EditSettings.maximumEncodedBytes) throws {
        guard (1...4_096).contains(maximumArtifacts), (1...16_384).contains(maximumFiles),
              maximumTotalBytes > 0, maximumTotalBytes <= 21_474_836_480,
              maximumPayloadBytes > 0, maximumPayloadBytes <= 536_870_912,
              (1...EditSettings.maximumEncodedBytes).contains(maximumManifestBytes), (1...EditSettings.maximumEncodedBytes).contains(maximumArtifactManifestBytes) else {
            throw ArtifactContractError.limitExceeded
        }
        self.maximumArtifacts = maximumArtifacts; self.maximumFiles = maximumFiles
        self.maximumTotalBytes = maximumTotalBytes; self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumManifestBytes = maximumManifestBytes; self.maximumArtifactManifestBytes = maximumArtifactManifestBytes
    }
    // Injection may tighten production limits, never silently widen a file format.
}
public enum EditingBackupKind: String, Codable, Hashable, Sendable { case automatic, manual, safety }

/// Exact TRANSITIVE reference closure from the CLOSED SQL copy: active sources,
/// persisted variants, their artifact provenance parents and all mask resources.
/// No live-store re-query after copying, no independent caller-constructed list.
public final class ClosedEditingSQLSnapshot: Sendable {
    public let sourceStoreEpoch: UUID
    public let database: ArtifactFileReadHandle
    public let referencedArtifacts: [GeneratedArtifact]
    internal let snapshotID: UUID
    internal init(sourceStoreEpoch: UUID, database: ArtifactFileReadHandle,
                  referencedArtifacts: [GeneratedArtifact], snapshotID: UUID) {
        self.sourceStoreEpoch = sourceStoreEpoch; self.database = database
        self.referencedArtifacts = referencedArtifacts; self.snapshotID = snapshotID
    }
}

/// A creates this under its mutation gate, after online SQLite copy, closed-copy
/// validation/closure derivation and B's lease covering that exact closure.
/// B reads immutable handles outside the gate; source keeps SQL staging alive.
public final class EditingBackupSource: Sendable {
    public let snapshot: ClosedEditingSQLSnapshot
    public let kind: EditingBackupKind
    internal let lease: ArtifactLease
    internal let artifactStore: any GeneratedArtifactStoring
    internal init(snapshot: ClosedEditingSQLSnapshot, kind: EditingBackupKind,
                  lease: ArtifactLease, artifactStore: any GeneratedArtifactStoring) {
        self.snapshot = snapshot; self.kind = kind; self.lease = lease; self.artifactStore = artifactStore
    }
}

/// Freely serializable main manifest: fixed database filename and typed IDs.
/// Physical relative names derive from IDs, not arbitrary user path strings.
public struct EditingBackupManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let kind: EditingBackupKind
    public let createdAt: Date
    public let sourceStoreEpoch: UUID
    public let database: ArtifactFileDescriptor
    public let artifacts: [GeneratedArtifact]
    public init(kind: EditingBackupKind, createdAt: Date, sourceStoreEpoch: UUID,
                database: ArtifactFileDescriptor, artifacts: [GeneratedArtifact]) {
        schemaVersion = 1; self.kind = kind; self.createdAt = createdAt
        self.sourceStoreEpoch = sourceStoreEpoch; self.database = database; self.artifacts = artifacts
    }
}
public final class PublishedEditingBackup: Sendable {
    public let url: URL
    public let manifest: EditingBackupManifest
    internal init(url: URL, manifest: EditingBackupManifest) { self.url = url; self.manifest = manifest }
}

/// B owns verified private staging + native read handles, not just an external
/// URL previously checked. No mutable SQLite connection remains open in it.
/// Private stage files open on demand under the two-transfer limit, never one
/// native FD per resource in the entire package.
public final class ValidatedEditingBackup: Sendable {
    public let manifest: EditingBackupManifest
    public let snapshot: ClosedEditingSQLSnapshot
    internal let openArtifactFile: @Sendable (GeneratedArtifactID, ArtifactPayloadRole) async throws -> ArtifactFileReadHandle
    internal let stagingOwnership: ArtifactLease
    internal init(manifest: EditingBackupManifest, snapshot: ClosedEditingSQLSnapshot,
                  openArtifactFile: @escaping @Sendable (GeneratedArtifactID, ArtifactPayloadRole) async throws -> ArtifactFileReadHandle,
                  stagingOwnership: ArtifactLease) {
        self.manifest = manifest; self.snapshot = snapshot; self.openArtifactFile = openArtifactFile
        self.stagingOwnership = stagingOwnership
    }
}
public final class PublishedArtifactSet: Sendable {
    public let artifacts: [GeneratedArtifact]
    internal let ownerID: ArtifactStoreID
    internal let nonce: UUID
    internal let ownership: ArtifactLease
    internal init(artifacts: [GeneratedArtifact], ownerID: ArtifactStoreID, nonce: UUID, ownership: ArtifactLease) {
        self.artifacts = artifacts; self.ownerID = ownerID; self.nonce = nonce; self.ownership = ownership
    }
}
public protocol EditingBackupPackageIO: Sendable {
    /// Destination must be new .piceditbackup directory entry. Never delete the
    /// previous target. B verifies completed stage, exclusive-renames then returns.
    func write(_ source: EditingBackupSource, toNew destination: URL,
               limits: EditingPackageLimits) async throws -> PublishedEditingBackup
    /// Full no-follow tree, byte/hash/codec/schema/closure validation in private
    /// stage. Legacy .sqlite is accepted only when it has no artifact references.
    func validate(from url: URL, limits: EditingPackageLimits) async throws -> ValidatedEditingBackup
    /// Validate and stream an immutable private copy to a NEW target. Native
    /// publication is protected by the same fresh catalog-original boundary.
    func export(from source: URL, toNew destination: URL, limits: EditingPackageLimits) async throws -> PublishedEditingBackup
    /// Only positively owned, unchanged automatic packages are eligible. The
    /// day uses yyyy-MM-dd in the same local time zone as backup creation.
    func reusableAutomaticBackup(in directory: URL, day: String) async throws -> URL?
    func pruneAutomaticBackups(in directory: URL, keepingNewest: Int) async throws
}
public extension EditingBackupPackageIO {
    func export(from source: URL, toNew destination: URL, limits: EditingPackageLimits) async throws -> PublishedEditingBackup {
        throw ArtifactContractError.unsupportedFormat
    }
    // Non-filesystem test adapters need not invent package ownership.
    func reusableAutomaticBackup(in directory: URL, day: String) async throws -> URL? { nil }
    func pruneAutomaticBackups(in directory: URL, keepingNewest: Int) async throws {}
}

// MARK: Exact catalog/participant commands retained before preparation

/// The fixed retained-payload name derives from operationID, never a supplied
/// path. This BODY is part of the coordinator request hash. Its descriptor below
/// adds that hash afterwards, avoiding a recursive self-hash.
public struct CatalogPreparedPayloadIdentity: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let operationID: UUID
    public let rootOwnerID: UUID
    public let before: MetadataCatalogFileReference
    public let after: MetadataCatalogFileReference
    public init(operationID:UUID, rootOwnerID:UUID, before:MetadataCatalogFileReference,
                after:MetadataCatalogFileReference) {
        schemaVersion = 1; self.operationID = operationID; self.rootOwnerID = rootOwnerID
        self.before = before; self.after = after
    }
}
public struct DurableCatalogStageDescriptor: Codable, Hashable, Sendable {
    public let payload: CatalogPreparedPayloadIdentity
    public let coordinatorRequestSHA256: ArtifactDigest
    public init(payload:CatalogPreparedPayloadIdentity,coordinatorRequestSHA256:ArtifactDigest) {
        self.payload = payload; self.coordinatorRequestSHA256 = coordinatorRequestSHA256
    }
}
public enum CatalogParticipantKind: String, Codable, Hashable, Sendable { case editing, photoMetadata }
public struct CatalogParticipantStoreIdentity: Codable, Hashable, Sendable {
    public let kind: CatalogParticipantKind
    public let durableStoreID: UUID
    public init(kind:CatalogParticipantKind,durableStoreID:UUID) { self.kind = kind; self.durableStoreID = durableStoreID }
}
/// Canonical ORIGINAL command bytes live in a separate immutable fixed-role
/// payload. The small journal records their hash/size, not a rebuilt command.
/// Editing command includes epoch/full expected snapshots/revisions/tombstones;
/// metadata command includes ALL original expected MetadataRecordVersions.
public struct CatalogParticipantCommandDescriptor: Codable, Hashable, Sendable {
    public let store: CatalogParticipantStoreIdentity
    public let operationID: UUID
    public let requestSchemaVersion: Int
    public let requestSHA256: ArtifactDigest
    public let canonicalByteCount: Int64
    public init(store:CatalogParticipantStoreIdentity,operationID:UUID,requestSchemaVersion:Int,
                requestSHA256:ArtifactDigest,canonicalByteCount:Int64) {
        self.store = store; self.operationID = operationID; self.requestSchemaVersion = requestSchemaVersion
        self.requestSHA256 = requestSHA256; self.canonicalByteCount = canonicalByteCount
    }
}
/// Freely decodable value; never authority to arm, publish, replay or delete.
/// Canonical sorted participant kinds + exact payload identity + their original
/// request digests form requestSHA256; transient sessions/generations are not CAS.
public struct CatalogCoordinationRequestBody: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let operationID: UUID
    public let catalog: CatalogPreparedPayloadIdentity
    public let requiredParticipants: [CatalogParticipantCommandDescriptor]
    public init(operationID:UUID,catalog:CatalogPreparedPayloadIdentity,
                requiredParticipants:[CatalogParticipantCommandDescriptor]) {
        schemaVersion = 1; self.operationID = operationID; self.catalog = catalog
        self.requiredParticipants = requiredParticipants
    }
}
public enum CatalogCoordinationError: Error, Equatable, Sendable {
    case requiredParticipantMissing(CatalogParticipantKind)
    case participantIdentityMismatch(CatalogParticipantKind)
    case originalRequestMismatch(CatalogParticipantKind)
    case missingPreparedPayload, unknownJournal, externallyModifiedCatalog
    case invalidPhase, invalidCapability, recoveryRequired, maintenanceAlreadyPending
}
public enum CatalogCoordinationPhase: String, Codable, Sendable {
    case prepared, armed, editingCommitted, catalogPublished, completed
}
public enum CatalogCoordinationDisposition: String, Codable, Sendable { case active, aborted, completed }
public struct CatalogCoordinationJournalValue: Codable, Sendable {
    public let body: CatalogCoordinationRequestBody
    public let requestSHA256: ArtifactDigest
    public let revision: Int64
    public let phase: CatalogCoordinationPhase
    public let disposition: CatalogCoordinationDisposition
    public init(body:CatalogCoordinationRequestBody,requestSHA256:ArtifactDigest,revision:Int64,
                phase:CatalogCoordinationPhase,disposition:CatalogCoordinationDisposition) {
        self.body = body; self.requestSHA256 = requestSHA256; self.revision = revision
        self.phase = phase; self.disposition = disposition
    }
}

public struct OriginalAssetRemapEntry: Codable, Sendable {
    public let oldAssetID: String
    public let newAssetID: String
    public let relativePath: String
    public let previous: OriginalSourceFingerprint
    public let relocated: OriginalSourceFingerprint
    public init(oldAssetID: String, newAssetID: String, relativePath: String,
                previous: OriginalSourceFingerprint, relocated: OriginalSourceFingerprint) {
        self.oldAssetID = oldAssetID; self.newAssetID = newAssetID; self.relativePath = relativePath
        self.previous = previous; self.relocated = relocated
    }
}
public struct AssetRemapProposal: Codable, Sendable {
    public let schemaVersion: Int
    public let operationID: EditingRemapID
    public let catalog: CatalogPreparedPayloadIdentity
    public let folderID: UUID
    public let bookmarkSHA256: ArtifactDigest
    public let bookmarkData: Data
    public let resolvedBookmarkData: Data?
    public let resolvedFolderURL: URL
    /// Ephemeral UI admission only; never the restart/persisted-before authority.
    public let catalogSessionID: UUID
    public let catalogGeneration: UInt64
    public let expectedStoreEpoch: UUID
    public let expectedByAsset: [String: EditingExpectedState]
    public let entries: [OriginalAssetRemapEntry]
    public init(operationID: EditingRemapID = .init(), catalog:CatalogPreparedPayloadIdentity,
                folderID: UUID, bookmarkSHA256: ArtifactDigest, bookmarkData: Data,
                resolvedFolderURL: URL, catalogSessionID: UUID, catalogGeneration: UInt64,
                expectedStoreEpoch: UUID, expectedByAsset: [String: EditingExpectedState],
                entries: [OriginalAssetRemapEntry], resolvedBookmarkData:Data? = nil) throws {
        guard bookmarkData.count <= 1_048_576, (resolvedBookmarkData?.count ?? 0) <= 1_048_576, resolvedFolderURL.isFileURL,
              operationID.rawValue == catalog.operationID else { throw ArtifactContractError.invalidValue("remap bookmark/catalog") }
        schemaVersion = 1; self.operationID = operationID; self.catalog = catalog
        self.folderID = folderID; self.bookmarkSHA256 = bookmarkSHA256; self.bookmarkData = bookmarkData
        self.resolvedBookmarkData = resolvedBookmarkData
        self.resolvedFolderURL = resolvedFolderURL; self.catalogSessionID = catalogSessionID
        self.catalogGeneration = catalogGeneration; self.expectedStoreEpoch = expectedStoreEpoch
        self.expectedByAsset = expectedByAsset; self.entries = entries
    }
}
/// Native verifier mints only after real evidence validation. This is not a
/// replacement for each participant's fresh pre-write source comparison.
public final class VerifiedAssetRemap: Sendable {
    public let proposal: AssetRemapProposal
    internal let verifiedFileEvidenceSHA256: ArtifactDigest
    internal init(proposal: AssetRemapProposal, verifiedFileEvidenceSHA256: ArtifactDigest) {
        self.proposal = proposal; self.verifiedFileEvidenceSHA256 = verifiedFileEvidenceSHA256
    }
}
public protocol AssetRemapVerifying: Sendable {
    func verify(_ proposal: AssetRemapProposal) async throws -> VerifiedAssetRemap
}
public final class AssetRemapReceipt: Sendable {
    public let operationID: EditingRemapID
    public let requestSHA256: ArtifactDigest
    public let state: EditingStoreState
    internal init(operationID: EditingRemapID, requestSHA256: ArtifactDigest, state: EditingStoreState) {
        self.operationID = operationID; self.requestSHA256 = requestSHA256; self.state = state
    }
}
public enum AssetRemapPhase: String, Codable, Sendable {
    case prepared, databaseCommitted, catalogCommitted, completed, aborted
}
/// Historical original command + participant ownership, not fresh native proof.
/// Recovery reconstructs only after validating its original durable journal.
public final class PreparedAssetRemap: Sendable {
    public let operationID: EditingRemapID
    public let proposal: AssetRemapProposal
    public let requestSHA256: ArtifactDigest
    public let coordinatorRequestSHA256: ArtifactDigest
    internal let nonce: UUID
    internal init(proposal:AssetRemapProposal,requestSHA256:ArtifactDigest,
                  coordinatorRequestSHA256:ArtifactDigest,nonce:UUID) {
        operationID = proposal.operationID; self.proposal = proposal; self.requestSHA256 = requestSHA256
        self.coordinatorRequestSHA256 = coordinatorRequestSHA256; self.nonce = nonce
    }
}
/// Read-only lookup result. It cannot create missing evidence or silently run
/// standalone metadata recovery. Receipts remain retained after completion.
public final class AssetRemapInspection: Sendable {
    public let prepared: PreparedAssetRemap
    public let phase: AssetRemapPhase
    public let databaseReceipt: AssetRemapReceipt?
    internal init(prepared:PreparedAssetRemap,phase:AssetRemapPhase,databaseReceipt:AssetRemapReceipt?) {
        self.prepared = prepared; self.phase = phase; self.databaseReceipt = databaseReceipt
    }
}
public final class MetadataCatalogParticipantInspection: Sendable {
    public let store: CatalogParticipantStoreIdentity
    public let originalChange: MetadataCatalogChange
    public let receipt: MetadataCatalogChangeReceipt
    public let coordinatorRequestSHA256: ArtifactDigest
    internal init(store:CatalogParticipantStoreIdentity,originalChange:MetadataCatalogChange,
                  receipt:MetadataCatalogChangeReceipt,coordinatorRequestSHA256:ArtifactDigest) {
        self.store = store; self.originalChange = originalChange; self.receipt = receipt
        self.coordinatorRequestSHA256 = coordinatorRequestSHA256
    }
}

// MARK: Closed coordinator/catalog capabilities, not public JSON authority

public final class ValidatedCatalogCoordinatorJournal: Sendable {
    public let value: CatalogCoordinationJournalValue
    internal let ownerID: UUID
    internal let nonce: UUID
    internal init(value:CatalogCoordinationJournalValue,ownerID:UUID,nonce:UUID) {
        self.value = value; self.ownerID = ownerID; self.nonce = nonce
    }
}
/// Private root/stage/payload handles and ownership retained by the closure.
/// deinit only closes FDs. It NEVER deletes an armed durable stage.
public final class DurableCatalogStage: Sendable {
    public let descriptor: DurableCatalogStageDescriptor
    internal let openOriginalBytes: @Sendable () throws -> ArtifactFileReadHandle
    internal let publicationPayload: (@Sendable () throws -> StagedLibraryCatalog)?
    internal init(descriptor:DurableCatalogStageDescriptor,
                  publicationPayload:(@Sendable () throws -> StagedLibraryCatalog)? = nil,
                  openOriginalBytes:@escaping @Sendable () throws -> ArtifactFileReadHandle) {
        self.descriptor = descriptor; self.openOriginalBytes = openOriginalBytes
        self.publicationPayload = publicationPayload
    }
}
public final class CatalogParticipantPreparation: Sendable {
    public let journal: ValidatedCatalogCoordinatorJournal
    internal let nonce: UUID
    internal init(journal:ValidatedCatalogCoordinatorJournal,nonce:UUID) { self.journal = journal; self.nonce = nonce }
}
public final class ArmedCatalogCoordination: Sendable {
    public let journal: ValidatedCatalogCoordinatorJournal
    internal let nonce: UUID
    internal init(journal:ValidatedCatalogCoordinatorJournal,nonce:UUID) { self.journal = journal; self.nonce = nonce }
}
public final class CatalogPublicationEvidence: Sendable {
    public let journal: ValidatedCatalogCoordinatorJournal
    public let published: MetadataCatalogFileReference
    internal let nonce: UUID
    internal init(journal:ValidatedCatalogCoordinatorJournal,published:MetadataCatalogFileReference,nonce:UUID) {
        self.journal = journal; self.published = published; self.nonce = nonce
    }
}
public final class CatalogCoordinationAbort: Sendable {
    public let journal: ValidatedCatalogCoordinatorJournal
    internal let nonce: UUID
    internal init(journal:ValidatedCatalogCoordinatorJournal,nonce:UUID) { self.journal = journal; self.nonce = nonce }
}
public enum CatalogRecoveryEvidence: Sendable {
    case exactBefore(stage:DurableCatalogStage)
    case exactAfter(CatalogPublicationEvidence)
    /// Preserve actual bytes and journals; never rebase or synthesize success.
    case conflict(actual:MetadataCatalogFileReference)
}
public struct CatalogCoordinationOutcome: Sendable {
    public let publication: CatalogPublicationEvidence?
    public let metadata: MetadataReconciliationResult?
    public let editing: AssetRemapReceipt?
    public let disposition: CatalogCoordinationDisposition
    internal init(publication:CatalogPublicationEvidence?,metadata:MetadataReconciliationResult?,
                  editing:AssetRemapReceipt?,disposition:CatalogCoordinationDisposition) {
        self.publication = publication; self.metadata = metadata; self.editing = editing; self.disposition = disposition
    }
}
public final class CatalogStartupAdmission: Sendable {
    public let sessionID: UUID
    internal let ownerID: UUID
    internal let nonce: UUID
    internal init(sessionID:UUID,ownerID:UUID,nonce:UUID) { self.sessionID = sessionID; self.ownerID = ownerID; self.nonce = nonce }
}

/// Additional exact-byte retention/reopen surface on the EXISTING repository.
/// CatalogRepository implements this through CatalogCoordinationFiles and the
/// existing catalog-write.lock/publication CAS, without a second writer.
public protocol CoordinatedCatalogPayloads: Sendable {
    func prepareDurableCatalogStage(_ prepared:PreparedLibraryCatalog,
                                   descriptor:DurableCatalogStageDescriptor) throws -> DurableCatalogStage
    func inspectCatalogRecovery(_ journal:ValidatedCatalogCoordinatorJournal) throws -> CatalogRecoveryEvidence
    func publishDurableCatalogStage(_ stage:DurableCatalogStage,
                                   armedBy:ArmedCatalogCoordination) throws -> CatalogPublicationEvidence
    func abortPreparedCatalogStage(_ stage:DurableCatalogStage,
                                   decision:CatalogCoordinationAbort) throws
    func cleanupCompletedCatalogStage(_ journal:ValidatedCatalogCoordinatorJournal) throws
}
/// No hard runtime dependency on metadata: injection may be nil for NEW plans.
/// Current #7 public standalone API stays, but every recovery/retry/mutation
/// consults the shared gate, so it cannot abandon an armed joint participant.
public protocol CoordinatedPhotoMetadataStoring: PhotoMetadataStoring, CatalogParticipantIdentifying {
    /// Nil means absent ID only; mismatching original digest throws conflict.
    func inspectCatalogChange(id:UUID,expectedRequestSHA256:String) async throws -> MetadataCatalogParticipantInspection?
    func stageCoordinatedCatalogChange(_ change:MetadataCatalogChange,
                                      preparingBy:CatalogParticipantPreparation) async throws -> MetadataCatalogChangeReceipt
    func completeCoordinatedCatalogChange(id:UUID,publication:CatalogPublicationEvidence,
                                         persistedCatalog:MetadataCatalogSnapshot) async throws -> MetadataReconciliationResult
    func abortCoordinatedCatalogChange(id:UUID,decision:CatalogCoordinationAbort) async throws
    /// Explicit recovery decision is a NEW separately receipted command. It
    /// never changes the original staged command/digest/expected versions.
    func resolveCoordinatedCatalogChange(_ operation:MetadataCatalogResolutionOperation,
                                        publication:CatalogPublicationEvidence) async throws -> MetadataReconciliationResult
}
public struct CatalogMetadataConflictRecords: Sendable {
    public let receipt: MetadataCatalogChangeReceipt
    public let conflict: MetadataRelocationConflict
    public let source: PhotoMetadataRecord?
    public let destination: PhotoMetadataRecord?
    public init(receipt: MetadataCatalogChangeReceipt, conflict: MetadataRelocationConflict,
                source: PhotoMetadataRecord?, destination: PhotoMetadataRecord?) {
        self.receipt = receipt; self.conflict = conflict; self.source = source; self.destination = destination
    }
}
public protocol CatalogMutationCoordinating: Actor {
    func recoverEditingDatabase(from url: URL) async throws -> EditingStoreState
    /// Retain exact bytes and both ORIGINAL canonical commands, fsync all payloads
    /// and then commit prepared journal. Common UUID + exact before/after required.
    func prepare(catalog:PreparedLibraryCatalog,expected:MetadataCatalogFileReference,
                 editing:VerifiedAssetRemap?,metadata:MetadataCatalogChange?,
                 maintenance:CatalogMaintenanceAdmission) async throws -> CatalogParticipantPreparation
    /// Read-only participant lookup must find every required original journal in
    /// its prepared phase before the coordinator durably commits armed.
    func arm(_ prepared:CatalogParticipantPreparation) async throws -> ArmedCatalogCoordination
    func finish(_ armed:ArmedCatalogCoordination) async throws -> CatalogCoordinationOutcome
    func abort(_ prepared:CatalogParticipantPreparation) async throws -> CatalogCoordinationOutcome
    /// Recovery UI may read conflict details while normal editing stays fenced.
    /// This path checks current resolution CAS + original after-catalog evidence,
    /// durably receipts the distinct user decision, then resumes completion.
    func inspectMetadataConflict(coordinationID: UUID, conflictID: UUID) async throws -> CatalogMetadataConflictRecords
    func resolveMetadataConflict(_ operation:MetadataCatalogResolutionOperation,
                                 coordinationID:UUID) async throws -> CatalogCoordinationOutcome
    /// Pure inspection; never stage/recover/abort a participant as a side effect.
    func pending() async throws -> [ValidatedCatalogCoordinatorJournal]
    /// One shared initial/warm recovery barrier for both Editor and Library.
    /// No ready admission while any required participant/phase is ambiguous.
    func recoverAndOpen() async throws -> CatalogStartupAdmission
}

/*
IMPLEMENTATION CONTRACT / RECOVERY RULES, 16 OCTOBER 2026

Recovery invariants for the concrete JointCatalogCoordinator, native retained
payload store and SQL participants. The independent participant/backup boundaries
preserve one closed SQL snapshot, its derived closure and strong payload leases.

Exact retained ownership:
- Introduce one positively owned CatalogCoordination directory under the existing
  CatalogRepository.directory. Fixed files derive from common UUID and typed
  roles: small coordinator journal, exact after-catalog bytes, original editing
  command and optional original metadata command. No arbitrary stored path.
- Retain catalog bytes once from PreparedLibraryCatalog; after restart reopen
  and verify THAT immutable payload. Never re-encode a current catalog to replay.
  Existing StagedLibraryCatalog defer/discard cannot own an armed stage. A durable
  stage closes handles on deinit only; explicit safe-abort/completed cleanup own
  deletion. Publication still uses the existing native CatalogFileIO CAS/lock.
- Journal body includes rootOwnerID, common operation UUID, exact before+after
  references INCLUDING byte counts, sorted explicit requiredParticipants, stable
  participant IDs and each ORIGINAL request digest/size/schema. Original command
  payloads contain full mappings, sources, Editing epoch+expected snapshots and
  Metadata expected record versions; preserve canonical Date reference bits.
  Descriptor BODY enters coordinator hash; outer coordinator hash is not hashed
  into itself. Participant own original command hash uses its OWN canonical codec
  (existing metadata catalogChange digest), not a newly invented re-encoding.
- Small coordinator envelope <=64KiB; catalog payload keeps existing
  <=512MiB bound; editing remap command <=32MiB; metadata command retains #7 <=64MiB
  bound. Streamhash files in64KiB reads; read/decode only bounded participant
  command being inspected. No claim of a new RSS cap or extra parallel worker.
- Metadata needs a durable store UUID (not current actor session). Add it through
  explicit owned-schema migration at #10 integration. Editing identity/epoch and
  metadata UUID are pinned in requiredParticipants. A replacement/omitted store
  cannot impersonate a required participant by returning a same-named operation.

Durable transition table (no cross-file atomicity claim):
1 prepared: exact catalog bytes + original commands + small journal durable.
  Stage each required participant using that immutable request. Checkpoint losses
  can be repaired by READ-ONLY lookup, never stage() disguised as lookup. If actual
  catalog is still before, missing participant preparation can either finish its
  original preparation or safely abort while no editing SQL committed. No remap
  is permitted before armed. Whole-state aborted disposition is retained.
2 armed: both required journals positively exist with exact own digests/expected
  versions and shared coordinator binding. Missing/abandoned/replaced/mismatching
  required evidence after this point is recovery-required, never recreated or
  downgraded to editing-only. Stage/root directory fsync precedes this checkpoint.
3 editingCommitted: perform or READ-ONLY resolve the exact Editing remap receipt.
  If no editing participant was chosen, this transition is an explicit no-op.
  A crash after SQL commit but before checkpoint resolves by receipt; no second
  revision. Metadata is still staged, never independently abandoned against before.
4 catalogPublished: existing short catalog-write.lock compares actual bytes with
  original before and renames exact retained after. Crash after rename but before
  checkpoint inspects actual==after and continues; stage may correctly be absent.
  Actual neither before nor after conflicts and preserves all state. A prepared
  (not armed) journal seeing after is not proof of legitimate publication: block.
  If Editing was required, actual-after also requires its positive original SQL
  receipt; never manufacture a missing remap merely because bytes happen to match.
  Never bless fresh before bytes or overwrite external changes on a retry.
5 completed: after actual-after evidence, finish metadata from original journal,
  confirm/complete Editing, and retain participant completion receipts. Then mark
  coordinator complete and release shared fence. If metadata returns explicit
  mapping conflicts, remain at catalogPublished with active disposition. Expose
  read-only recovery details, allow only the separately receipted user-resolution
  path under publication evidence, and continue after it completes. Do not mark
  complete merely because a search snapshot published or because conflicts exist.
  Cleanup failure cannot report that a published catalog did not commit. Unknown
  files remain intact.

Abort/recovery boundaries:
- Safe abort exists only from prepared when read-only participant evidence proves
  no editing commit and actual catalog==before. Cancel/disappear/timeout is not
  this proof. Aborting coordinated metadata is explicit; do not invoke generic
  recoverCatalogChanges(before) first. Retain aborted receipt for idempotency.
- Startup AND warm load/retry/resolve/save/shutdown paths first inspect the common
  journal and finish any armed operation. Only afterwards may legacy standalone
  metadata recovery inspect before and abandon its own unrelated prepared work.
- Fresh native source checks are compared to immutable original source evidence.
  Changed source/epoch/version blocks or enters explicit conflict; no recaptured
  current source/version rewrites the original command. Already committed data
  stays preserved while both relevant mutation domains remain fenced.
- A shared lifecycle gate (02) holds both LibraryModel and EditingModel startup,
  every writer path and maintenance. Root composition injects one gate. An
  already accepted CatalogWriter task explicitly promotes its own admission via
  the closed upgrade signature in02 before prepare; never drain its own lease.
  Competing promotions fail promptly so they cannot deadlock that drain. A new
  metadata-omitted operation works; a recorded joint operation with currently
  missing metadata adapter does not. A actor-only gate or Library-only loader
  is insufficient. No SQLite lock/flock spans await; no second CatalogWriter.

Failure boundaries for coordinator/participant regression fixtures:
- Kill/restart after prepared, after each participant prepare, armed, Editing SQL
  before checkpoint, catalog rename before checkpoint, metadata complete before
  coordinator complete; startup and warm retry must give the same result.
- Required receipt absent/abandoned/different digest; root owner mismatch; same-
  byte foreign stage inode; missing stage at before; absent stage at after.
- External catalog bytes change before publication: no overwrite/rebase, original
  requests remain frozen. Source/epoch change likewise never rebases CAS.
- Independently scheduled EditingModel load stays fenced until the same startup
  admission as Library. Accepted tasks drain; caller cancellation cannot delete
  armed payload or release maintenance. Nil metadata chosen initially works;
  missing metadata from a recorded joint operation remains visibly blocked.
*/
