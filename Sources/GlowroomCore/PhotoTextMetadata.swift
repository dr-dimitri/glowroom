import Foundation

// Shared editorial metadata values. Persistence/JSON boundaries validate all
// direct and decoded values identically before granting write authority.
// Every initializer constructs values only. Repository/JSON boundaries validate
// direct and decoded DTOs identically; Codable never grants write authority.

public enum PhotoMetadataLimits {
    public static let maximumTitleCharacters = 120
    public static let maximumTitleBytes = 1_024
    public static let maximumDescriptionCharacters = 2_000
    public static let maximumDescriptionBytes = 16_384
    public static let maximumTags = 20
    public static let maximumTagCharacters = 60
    public static let maximumTagBytes = 512
    public static let maximumTextFieldsBytes = 24_576
    public static let maximumLanguageBytes = 64
    public static let maximumAssetIDBytes = 4_096
    public static let maximumSourcePathBytes = 4_096
    public static let maximumSourceRevisionBytes = 512
    public static let maximumProviderIdentifierBytes = 256
    public static let maximumProfileLabelBytes = 256
    public static let maximumOrientationBytes = 128
    public static let maximumRasterPixelSize = 1_024
    public static let maximumRasterBytes = 16 * 1_024 * 1_024
    public static let maximumModelResponseBytes = 65_536
    public static let maximumModelJSONDepth = 8
    public static let maximumModelJSONValues = 1_024
    public static let maximumStoredRecordBlobBytes = 262_144
    public static let maximumJSONDocumentBytes = 64 * 1_024 * 1_024
    public static let maximumJSONEntries = 25_000
    public static let maximumJSONEntryBytes = 128 * 1_024
    public static let maximumJSONDepth = 16
    public static let maximumJSONValues = 2_000_000
    public static let maximumRetainedImportReviews = 1
    public static let maximumRetainedImportCost = 128 * 1_024 * 1_024
    public static let maximumImportReviewIdleSeconds = 15 * 60
    public static let maximumSearchEntries = 100_000
    public static let maximumSearchUTF8Bytes = 64 * 1_024 * 1_024
    public static let maximumSearchAccountedCost = 96 * 1_024 * 1_024
    public static let metadataPageSize = 256
    public static let maximumMetadataPageSize = 512
    public static let maximumPendingCatalogChanges = 1
    public static let maximumCatalogAssets = 1_000_000
    public static let maximumRelocationsPerChange = 1_000_000
    public static let maximumJournalBytes = 64 * 1_024 * 1_024
}

public enum PhotoMetadataField: String, Codable, CaseIterable, Hashable, Sendable {
    case title, description, tags, language
}
public enum MetadataTagPolicy: String, Codable, Hashable, Sendable { case append, replace }
public enum MetadataDraftState: String, Codable, Hashable, Sendable { case pending, accepted, edited, rejected, outdated }
public enum MetadataLimit: String, Codable, Hashable, Sendable {
    case titleCharacters, titleBytes, descriptionCharacters, descriptionBytes
    case tagCount, tagCharacters, tagBytes, textFieldsBytes, languageBytes
    case modelResponse, jsonDocument, jsonEntries, jsonEntry, jsonDepth, jsonValues
    case detailRecord, importReview, searchSnapshot, catalogChange, pageSize, revisionExhausted
}
public enum MetadataValidationFailure: String, Codable, Hashable, Sendable {
    case invalidControlCharacter, emptyTag, emptySuggestion, invalidLanguage
    case invalidIdentifier, invalidSource, invalidProvenance, invalidRevision
    case invalidFieldSelection, invalidDraftTransition, malformedJSON, duplicateKey, unknownField
    case invalidRelocation, duplicateIdentity, invalidDigest, invalidDecision
}
public enum PhotoMetadataError: Error, Equatable, Sendable {
    case validation(MetadataValidationFailure)
    case limitExceeded(MetadataLimit)
    case unsupportedVersion, corruptStore, recoveryRequired, readOnly, catalogReadOnly, closing
    case revisionConflict, sourceChanged, operationIDCollision, staleCatalog
    case relocationInProgress, catalogConflict, reviewMissingOrExpired, importConflict
    case protectedPath, storageFailure, exportFailure, cancelled
}

public struct PhotoTextFields: Codable, Equatable, Sendable {
    public var title: String
    public var description: String
    public var tags: [String]
    public var language: String
    public init(title: String = "", description: String = "", tags: [String] = [], language: String = "de_DE") {
        self.title = title
        self.description = description
        self.tags = tags
        self.language = language
    }
    public static let empty = PhotoTextFields()
}

public struct PhotoMetadataVersion: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public init(sessionID: UUID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
    public static let initial = Self(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, generation: 0)
}

/// All counters persist after draft deletion. Zero means no corresponding committed mutation; never wrap.
public struct MetadataRecordVersion: Codable, Hashable, Sendable {
    public let recordRevision: Int64
    public let confirmedRevision: Int64
    public let aiDraftRevision: Int64
    public let manualDraftRevision: Int64
    public init(recordRevision: Int64 = 0, confirmedRevision: Int64 = 0, aiDraftRevision: Int64 = 0, manualDraftRevision: Int64 = 0) {
        self.recordRevision = recordRevision
        self.confirmedRevision = confirmedRevision
        self.aiDraftRevision = aiDraftRevision
        self.manualDraftRevision = manualDraftRevision
    }
    public static let absent = Self()
}

/// Native timespec, nanoseconds 0..<1_000_000_000. Zero birthtime/generation means unknown, not proof.
public struct MetadataTimestamp: Codable, Hashable, Sendable {
    public let seconds: Int64
    public let nanoseconds: Int32
    public init(seconds: Int64, nanoseconds: Int32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

public struct MetadataFileIdentity: Codable, Hashable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Locally observed only; same dev/inode alone is never a historical relocation proof.
public struct MetadataNativeSourceStamp: Codable, Hashable, Sendable {
    public let identity: MetadataFileIdentity
    public let byteCount: Int64
    public let modifiedAt: MetadataTimestamp
    public let changedAt: MetadataTimestamp
    public let birthTime: MetadataTimestamp?
    public let fileGeneration: UInt64?
    public init(identity: MetadataFileIdentity, byteCount: Int64, modifiedAt: MetadataTimestamp, changedAt: MetadataTimestamp, birthTime: MetadataTimestamp? = nil, fileGeneration: UInt64? = nil) {
        self.identity = identity
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.changedAt = changedAt
        self.birthTime = birthTime
        self.fileGeneration = fileGeneration
    }
}

public struct MetadataSourceFingerprint: Codable, Hashable, Sendable {
    public let standardizedPath: String
    public let isFileURL: Bool
    public let modifiedAt: Date
    public let fileSize: Int64
    public init(standardizedPath: String, isFileURL: Bool = true, modifiedAt: Date, fileSize: Int64) {
        self.standardizedPath = standardizedPath
        self.isFileURL = isFileURL
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
    }
}

/// Exact analyzed raster contract, not proof of equality of full camera originals.
public struct MetadataRasterIdentity: Codable, Hashable, Sendable {
    public let sha256: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
    public let colorProfile: String
    public let colorProfileSHA256: String?
    public let orientation: String
    public let preprocessingVersion: Int
    public init(sha256: String, pixelWidth: Int, pixelHeight: Int, byteCount: Int, colorProfile: String, colorProfileSHA256: String? = nil, orientation: String, preprocessingVersion: Int) {
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.colorProfile = colorProfile
        self.colorProfileSHA256 = colorProfileSHA256
        self.orientation = orientation
        self.preprocessingVersion = preprocessingVersion
    }
}

public enum MetadataAnalysisInputKind: String, Codable, Hashable, Sendable { case originalPreview }

public struct MetadataAnalysisProvenance: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let modelVersion: String?
    public let analyzedAt: Date
    public let source: MetadataSourceFingerprint
    public let inputKind: MetadataAnalysisInputKind
    public let raster: MetadataRasterIdentity
    public let analysisTaskVersion: Int
    public let analysisSchemaVersion: Int
    public let metadataPromptVersion: Int
    public let metadataSchemaVersion: Int
    public init(providerID: String, modelID: String, modelVersion: String? = nil, analyzedAt: Date, source: MetadataSourceFingerprint, inputKind: MetadataAnalysisInputKind = .originalPreview, raster: MetadataRasterIdentity, analysisTaskVersion: Int, analysisSchemaVersion: Int, metadataPromptVersion: Int, metadataSchemaVersion: Int) {
        self.providerID = providerID
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.analyzedAt = analyzedAt
        self.source = source
        self.inputKind = inputKind
        self.raster = raster
        self.analysisTaskVersion = analysisTaskVersion
        self.analysisSchemaVersion = analysisSchemaVersion
        self.metadataPromptVersion = metadataPromptVersion
        self.metadataSchemaVersion = metadataSchemaVersion
    }
}

public struct MetadataSourceReference: Codable, Hashable, Sendable {
    public let original: MetadataSourceFingerprint
    public let nativeStamp: MetadataNativeSourceStamp?
    public let analyzedRaster: MetadataAnalysisProvenance?
    public init(original: MetadataSourceFingerprint, nativeStamp: MetadataNativeSourceStamp? = nil, analyzedRaster: MetadataAnalysisProvenance? = nil) {
        self.original = original
        self.nativeStamp = nativeStamp
        self.analyzedRaster = analyzedRaster
    }
}

public struct MetadataAIFieldOrigin: Codable, Hashable, Sendable {
    public let draftID: UUID
    public let analysis: MetadataAnalysisProvenance
    public let wasHumanEdited: Bool
    public init(draftID: UUID, analysis: MetadataAnalysisProvenance, wasHumanEdited: Bool) {
        self.draftID = draftID
        self.analysis = analysis
        self.wasHumanEdited = wasHumanEdited
    }
}

/// Flatten repeated imports: no recursive imported(imported(...)) chain.
public struct MetadataImportFieldOrigin: Codable, Hashable, Sendable {
    public let exportID: UUID
    public let originalRevision: Int64
    public let originalAI: MetadataAIFieldOrigin?
    public init(exportID: UUID, originalRevision: Int64, originalAI: MetadataAIFieldOrigin? = nil) {
        self.exportID = exportID
        self.originalRevision = originalRevision
        self.originalAI = originalAI
    }
}

public enum MetadataFieldOrigin: Hashable, Sendable {
    case manual
    case confirmedAI(MetadataAIFieldOrigin)
    case imported(MetadataImportFieldOrigin)
}

// Fixed wire shape {kind, ai?, imported?}. The bounded JSON scanner rejects
// duplicate/unknown keys before Codable and checks the exact active fields.
extension MetadataFieldOrigin: Codable {
    private enum Keys: String, CodingKey { case kind, ai, imported }
    private enum Kind: String, Codable { case manual, confirmedAI, imported }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .manual: self = .manual
        case .confirmedAI: self = .confirmedAI(try values.decode(MetadataAIFieldOrigin.self, forKey: .ai))
        case .imported: self = .imported(try values.decode(MetadataImportFieldOrigin.self, forKey: .imported))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch self {
        case .manual: try values.encode(Kind.manual, forKey: .kind)
        case .confirmedAI(let origin):
            try values.encode(Kind.confirmedAI, forKey: .kind); try values.encode(origin, forKey: .ai)
        case .imported(let origin):
            try values.encode(Kind.imported, forKey: .kind); try values.encode(origin, forKey: .imported)
        }
    }
}

public struct MetadataTagOrigin: Codable, Hashable, Sendable {
    public let value: String
    public let origin: MetadataFieldOrigin
    public init(value: String, origin: MetadataFieldOrigin) {
        self.value = value
        self.origin = origin
    }
}

public struct MetadataConfirmedProvenance: Codable, Equatable, Sendable {
    public let title: MetadataFieldOrigin
    public let description: MetadataFieldOrigin
    public let tags: [MetadataTagOrigin]
    public let language: MetadataFieldOrigin
    public init(title: MetadataFieldOrigin = .manual, description: MetadataFieldOrigin = .manual, tags: [MetadataTagOrigin] = [], language: MetadataFieldOrigin = .manual) {
        self.title = title
        self.description = description
        self.tags = tags
        self.language = language
    }
}

/// Output only: store owns state/revisions/times. First partial confirm consumes this proposal once.
public struct PhotoMetadataDraft: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int64
    public let baseConfirmedRevision: Int64
    public let fields: PhotoTextFields
    public let source: MetadataSourceReference
    public let state: MetadataDraftState
    public let createdAt: Date
    public let modifiedAt: Date
    public let appliedFields: Set<PhotoMetadataField>
    public let editedFields: Set<PhotoMetadataField>
    public init(id: UUID, revision: Int64, baseConfirmedRevision: Int64, fields: PhotoTextFields, source: MetadataSourceReference, state: MetadataDraftState, createdAt: Date, modifiedAt: Date, appliedFields: Set<PhotoMetadataField> = [], editedFields: Set<PhotoMetadataField> = []) {
        self.id = id
        self.revision = revision
        self.baseConfirmedRevision = baseConfirmedRevision
        self.fields = fields
        self.source = source
        self.state = state
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.appliedFields = appliedFields
        self.editedFields = editedFields
    }
    public var wasHumanEdited: Bool { !editedFields.isEmpty }
}

public struct PhotoMetadataManualDraft: Codable, Equatable, Sendable {
    public let revision: Int64
    public let baseConfirmedRevision: Int64
    public let fields: PhotoTextFields
    public let modifiedAt: Date
    public init(revision: Int64, baseConfirmedRevision: Int64, fields: PhotoTextFields, modifiedAt: Date) {
        self.revision = revision
        self.baseConfirmedRevision = baseConfirmedRevision
        self.fields = fields
        self.modifiedAt = modifiedAt
    }
}

public struct PhotoMetadataRecord: Codable, Equatable, Sendable {
    public let assetID: String
    public let version: MetadataRecordVersion
    public let confirmed: PhotoTextFields
    public let confirmedAt: Date?
    public let confirmedSource: MetadataSourceReference?
    public let confirmedProvenance: MetadataConfirmedProvenance
    public let draft: PhotoMetadataDraft?
    public let manualDraft: PhotoMetadataManualDraft?
    public let isOrphaned: Bool
    public let sourceChanged: Bool
    /// Current locally verified association; historical confirmedSource stays unchanged.
    public let associationSource: MetadataSourceReference?
    public init(assetID: String, version: MetadataRecordVersion, confirmed: PhotoTextFields, confirmedAt: Date? = nil, confirmedSource: MetadataSourceReference? = nil, confirmedProvenance: MetadataConfirmedProvenance, draft: PhotoMetadataDraft? = nil, manualDraft: PhotoMetadataManualDraft? = nil, isOrphaned: Bool, sourceChanged: Bool, associationSource: MetadataSourceReference? = nil) {
        self.assetID = assetID
        self.version = version
        self.confirmed = confirmed
        self.confirmedAt = confirmedAt
        self.confirmedSource = confirmedSource
        self.confirmedProvenance = confirmedProvenance
        self.draft = draft
        self.manualDraft = manualDraft
        self.isOrphaned = isOrphaned
        self.sourceChanged = sourceChanged
        self.associationSource = associationSource
    }
    public var confirmedRevision: Int64 { version.confirmedRevision }
}

public enum MetadataCatalogFileReference: Codable, Hashable, Sendable {
    case absent
    case present(sha256: String, byteCount: Int64)
}

public struct PhotoMetadataSearchSnapshot: Equatable, Sendable {
    public let version: PhotoMetadataVersion
    public let catalogReference: MetadataCatalogFileReference
    public let confirmedByAssetID: [String: PhotoTextFields]
    public init(version: PhotoMetadataVersion, catalogReference: MetadataCatalogFileReference, confirmedByAssetID: [String: PhotoTextFields]) {
        self.version = version
        self.catalogReference = catalogReference
        self.confirmedByAssetID = confirmedByAssetID
    }
    public static let empty = Self(version: .initial, catalogReference: .absent, confirmedByAssetID: [:])
}

public enum PhotoMetadataSearchState: Equatable, Sendable {
    case loading(version: PhotoMetadataVersion)
    case available(PhotoMetadataSearchSnapshot)
    case unavailable(version: PhotoMetadataVersion, reason: PhotoMetadataError)
    public var version: PhotoMetadataVersion {
        switch self {
        case .loading(let version), .unavailable(let version, _): return version
        case .available(let snapshot): return snapshot.version
        }
    }
}

/// Freeze and retain this header across retries. Repository computes canonical payload hash, not caller.
public struct MetadataCommandHeader: Codable, Equatable, Sendable {
    public let id: UUID
    public let assetID: String
    public let expectedVersion: MetadataRecordVersion
    public init(id: UUID = UUID(), assetID: String, expectedVersion: MetadataRecordVersion) {
        self.id = id
        self.assetID = assetID
        self.expectedVersion = expectedVersion
    }
}

public enum MetadataManualDraftMutation: Codable, Equatable, Sendable {
    case save(fields: PhotoTextFields, baseConfirmedRevision: Int64)
    case discard
}
public enum MetadataAIDraftMutation: Codable, Equatable, Sendable {
    case createSuggested(draftID: UUID, fields: PhotoTextFields, source: MetadataSourceReference)
    case editExisting(draftID: UUID, fields: PhotoTextFields)
}
public enum MetadataDraftAction: String, Codable, Equatable, Sendable { case reject }
public enum MetadataConfirmOrigin: Codable, Equatable, Sendable {
    // nil requires no manual draft. Non-nil binds the exact stored draft; the
    // explicit reviewed revision allows a human to resolve an old base warning.
    case manual(expectedManualDraftRevision: Int64?, reviewedConfirmedRevision: Int64)
    case proposal(draftID: UUID, expectedDraftRevision: Int64)
}

public struct MetadataManualDraftOperation: Codable, Equatable, Sendable {
    public let header: MetadataCommandHeader
    public let mutation: MetadataManualDraftMutation
    public init(header: MetadataCommandHeader, mutation: MetadataManualDraftMutation) {
        self.header = header
        self.mutation = mutation
    }
}

public struct MetadataAIDraftOperation: Codable, Equatable, Sendable {
    public let header: MetadataCommandHeader
    public let mutation: MetadataAIDraftMutation
    public init(header: MetadataCommandHeader, mutation: MetadataAIDraftMutation) {
        self.header = header
        self.mutation = mutation
    }
}

public struct MetadataDraftStateOperation: Codable, Equatable, Sendable {
    public let header: MetadataCommandHeader
    public let draftID: UUID
    public let expectedDraftRevision: Int64
    public let action: MetadataDraftAction
    public init(header: MetadataCommandHeader, draftID: UUID, expectedDraftRevision: Int64, action: MetadataDraftAction = .reject) {
        self.header = header
        self.draftID = draftID
        self.expectedDraftRevision = expectedDraftRevision
        self.action = action
    }
}

/// Nonempty explicit field selection. Source/selection authority rechecked by app before admission.
public struct MetadataConfirmOperation: Codable, Equatable, Sendable {
    public let header: MetadataCommandHeader
    public let values: PhotoTextFields
    public let fields: Set<PhotoMetadataField>
    public let tagPolicy: MetadataTagPolicy
    public let source: MetadataSourceReference
    public let origin: MetadataConfirmOrigin
    public init(header: MetadataCommandHeader, values: PhotoTextFields, fields: Set<PhotoMetadataField>, tagPolicy: MetadataTagPolicy = .append, source: MetadataSourceReference, origin: MetadataConfirmOrigin) {
        self.header = header
        self.values = values
        self.fields = fields
        self.tagPolicy = tagPolicy
        self.source = source
        self.origin = origin
    }
}

public struct MetadataAffectedRecord: Codable, Hashable, Sendable {
    public let assetID: String
    public let version: MetadataRecordVersion
    public init(assetID: String, version: MetadataRecordVersion) {
        self.assetID = assetID
        self.version = version
    }
}

public enum MetadataReceiptDisposition: String, Codable, Equatable, Sendable { case applied, replayed }

/// Durable result contains original committed revisions. Never replay old UI/search snapshots.
public struct MetadataWriteReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let payloadSchemaVersion: Int
    public let payloadSHA256: String
    public let committedAt: Date
    public let affected: [MetadataAffectedRecord]
    public let disposition: MetadataReceiptDisposition
    public init(operationID: UUID, payloadSchemaVersion: Int = 1, payloadSHA256: String, committedAt: Date, affected: [MetadataAffectedRecord], disposition: MetadataReceiptDisposition) {
        self.operationID = operationID
        self.payloadSchemaVersion = payloadSchemaVersion
        self.payloadSHA256 = payloadSHA256
        self.committedAt = committedAt
        self.affected = affected
        self.disposition = disposition
    }
}

/// A returned receipt means committed even when searchState is unavailable. Single-asset commands may return currentRecord; import returns nil.
public struct MetadataCommitResult: Equatable, Sendable {
    public let receipt: MetadataWriteReceipt
    public let currentRecord: PhotoMetadataRecord?
    public let searchState: PhotoMetadataSearchState
    public init(receipt: MetadataWriteReceipt, currentRecord: PhotoMetadataRecord? = nil, searchState: PhotoMetadataSearchState) {
        self.receipt = receipt
        self.currentRecord = currentRecord
        self.searchState = searchState
    }
}

public struct MetadataCatalogAsset: Codable, Equatable, Sendable {
    public let assetID: String
    public let source: MetadataSourceReference
    public init(assetID: String, source: MetadataSourceReference) {
        self.assetID = assetID
        self.source = source
    }
}

public struct MetadataCatalogSnapshot: Codable, Equatable, Sendable {
    public let catalogSessionID: UUID
    public let catalogGeneration: Int
    public let persistedReference: MetadataCatalogFileReference
    public let assets: [MetadataCatalogAsset]
    public init(catalogSessionID: UUID, catalogGeneration: Int, persistedReference: MetadataCatalogFileReference, assets: [MetadataCatalogAsset]) {
        self.catalogSessionID = catalogSessionID
        self.catalogGeneration = catalogGeneration
        self.persistedReference = persistedReference
        self.assets = assets
    }
}

public enum MetadataRelocationVerification: Codable, Equatable, Sendable {
    case sameNativeIdentity(before: MetadataNativeSourceStamp, after: MetadataNativeSourceStamp)
    case sameAnalyzedRaster(before: MetadataRasterIdentity, after: MetadataRasterIdentity)
    case userConfirmed(operationID: UUID)
    case unresolved
}

public struct MetadataRelocationProof: Codable, Equatable, Sendable {
    public let folderID: UUID
    public let bookmarkSHA256: String
    public let oldRoot: URL
    public let newRoot: URL
    public let relativePath: String
    public let verification: MetadataRelocationVerification
    public init(folderID: UUID, bookmarkSHA256: String, oldRoot: URL, newRoot: URL, relativePath: String, verification: MetadataRelocationVerification) {
        self.folderID = folderID
        self.bookmarkSHA256 = bookmarkSHA256
        self.oldRoot = oldRoot
        self.newRoot = newRoot
        self.relativePath = relativePath
        self.verification = verification
    }
}

public struct MetadataRelocation: Codable, Equatable, Sendable {
    public let oldAssetID: String
    public let newAssetID: String
    public let oldSource: MetadataSourceReference
    public let newSource: MetadataSourceReference
    public let proof: MetadataRelocationProof
    public init(oldAssetID: String, newAssetID: String, oldSource: MetadataSourceReference, newSource: MetadataSourceReference, proof: MetadataRelocationProof) {
        self.oldAssetID = oldAssetID
        self.newAssetID = newAssetID
        self.oldSource = oldSource
        self.newSource = newSource
        self.proof = proof
    }
}

public struct MetadataRecordExpectation: Codable, Equatable, Sendable {
    public let assetID: String
    public let version: MetadataRecordVersion
    public init(assetID: String, version: MetadataRecordVersion) {
        self.assetID = assetID
        self.version = version
    }
}

/// Exactly one pending change; after must be present. Stage locks affected IDs and freezes metadata CAS.
public struct MetadataCatalogChange: Codable, Equatable, Sendable {
    public let id: UUID
    public let before: MetadataCatalogFileReference
    public let after: MetadataCatalogFileReference
    public let relocations: [MetadataRelocation]
    public let expectedRecords: [MetadataRecordExpectation]
    public init(id: UUID = UUID(), before: MetadataCatalogFileReference, after: MetadataCatalogFileReference, relocations: [MetadataRelocation], expectedRecords: [MetadataRecordExpectation]) {
        self.id = id
        self.before = before
        self.after = after
        self.relocations = relocations
        self.expectedRecords = expectedRecords
    }
}

public enum MetadataCatalogChangeState: String, Codable, Equatable, Sendable { case staged, conflicted, completed, abandoned }
public enum MetadataRelocationConflictReason: String, Codable, Equatable, Sendable {
    case destinationHasConfirmedContent, destinationHasDraft, unverifiedSource
    case recordRevisionChanged, catalogDigestMismatch
}

public struct MetadataRelocationConflict: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let changeID: UUID
    public let oldAssetID: String
    public let newAssetID: String
    public let reason: MetadataRelocationConflictReason
    public let sourceVersion: MetadataRecordVersion
    public let destinationVersion: MetadataRecordVersion
    public init(id: UUID, changeID: UUID, oldAssetID: String, newAssetID: String, reason: MetadataRelocationConflictReason, sourceVersion: MetadataRecordVersion, destinationVersion: MetadataRecordVersion) {
        self.id = id
        self.changeID = changeID
        self.oldAssetID = oldAssetID
        self.newAssetID = newAssetID
        self.reason = reason
        self.sourceVersion = sourceVersion
        self.destinationVersion = destinationVersion
    }
}

/// Durable stage/complete/recovery outcome; zero-timeout UI state is never proof that catalog bytes committed.
public struct MetadataCatalogChangeReceipt: Codable, Equatable, Sendable {
    public let changeID: UUID
    public let payloadSHA256: String
    public let revision: Int64
    public let state: MetadataCatalogChangeState
    public let blockedAssetIDs: [String]
    public let protectedSourceURLs: [URL]
    public let conflicts: [MetadataRelocationConflict]
    public init(changeID: UUID, payloadSHA256: String, revision: Int64, state: MetadataCatalogChangeState, blockedAssetIDs: [String], protectedSourceURLs: [URL], conflicts: [MetadataRelocationConflict]) {
        self.changeID = changeID
        self.payloadSHA256 = payloadSHA256
        self.revision = revision
        self.state = state
        self.blockedAssetIDs = blockedAssetIDs
        self.protectedSourceURLs = protectedSourceURLs
        self.conflicts = conflicts
    }
}

public struct MetadataReconciliationResult: Equatable, Sendable {
    public let receipt: MetadataWriteReceipt?
    public let searchState: PhotoMetadataSearchState
    public let changes: [MetadataCatalogChangeReceipt]
    public init(receipt: MetadataWriteReceipt? = nil, searchState: PhotoMetadataSearchState, changes: [MetadataCatalogChangeReceipt]) {
        self.receipt = receipt
        self.searchState = searchState
        self.changes = changes
    }
}

public enum MetadataRelocationResolutionAction: String, Codable, Equatable, Sendable {
    case keepSeparate
    // Fails if destination has any confirmed revision (including empty
    // tombstone), AI draft or manual draft. Never merges/overwrites fields.
    case assignIfDestinationVacant
}

public struct MetadataRelocationResolution: Codable, Equatable, Sendable {
    public let conflictID: UUID
    public let sourceVersion: MetadataRecordVersion
    public let destinationVersion: MetadataRecordVersion
    public let action: MetadataRelocationResolutionAction
    public init(conflictID: UUID, sourceVersion: MetadataRecordVersion, destinationVersion: MetadataRecordVersion, action: MetadataRelocationResolutionAction) {
        self.conflictID = conflictID
        self.sourceVersion = sourceVersion
        self.destinationVersion = destinationVersion
        self.action = action
    }
}

public struct MetadataCatalogResolutionOperation: Codable, Equatable, Sendable {
    public let id: UUID
    public let changeID: UUID
    public let expectedChangeRevision: Int64
    public let persistedReference: MetadataCatalogFileReference
    public let decisions: [MetadataRelocationResolution]
    public init(id: UUID = UUID(), changeID: UUID, expectedChangeRevision: Int64, persistedReference: MetadataCatalogFileReference, decisions: [MetadataRelocationResolution]) {
        self.id = id
        self.changeID = changeID
        self.expectedChangeRevision = expectedChangeRevision
        self.persistedReference = persistedReference
        self.decisions = decisions
    }
}

public struct MetadataProtectedDirectoryFamily: Equatable, Sendable {
    public let parent: URL
    public let childNamePrefix: String
    public init(parent: URL, childNamePrefix: String) {
        self.parent = parent
        self.childNamePrefix = childNamePrefix
    }
}

public struct MetadataFileProtectionSnapshot: Equatable, Sendable {
    public let originalURLs: [URL]
    public let managedFileURLs: [URL]
    public let managedDirectoryURLs: [URL]
    public let managedDirectoryFamilies: [MetadataProtectedDirectoryFamily]
    public init(originalURLs: [URL], managedFileURLs: [URL], managedDirectoryURLs: [URL], managedDirectoryFamilies: [MetadataProtectedDirectoryFamily] = []) {
        self.originalURLs = originalURLs
        self.managedFileURLs = managedFileURLs
        self.managedDirectoryURLs = managedDirectoryURLs
        self.managedDirectoryFamilies = managedDirectoryFamilies
    }
}

/// No local native-stamp authority, bookmarks or original pixel data in portable JSON.
public struct MetadataPortableSourceReference: Codable, Equatable, Sendable {
    public let original: MetadataSourceFingerprint
    public let analyzedRaster: MetadataAnalysisProvenance?
    public init(original: MetadataSourceFingerprint, analyzedRaster: MetadataAnalysisProvenance? = nil) {
        self.original = original
        self.analyzedRaster = analyzedRaster
    }
}

public struct MetadataJSONEntry: Codable, Equatable, Sendable {
    public let assetID: String
    public let fields: PhotoTextFields
    public let originalRevision: Int64
    public let confirmedAt: Date
    public let source: MetadataPortableSourceReference?
    public let provenance: MetadataConfirmedProvenance
    public init(assetID: String, fields: PhotoTextFields, originalRevision: Int64, confirmedAt: Date, source: MetadataPortableSourceReference? = nil, provenance: MetadataConfirmedProvenance) {
        self.assetID = assetID
        self.fields = fields
        self.originalRevision = originalRevision
        self.confirmedAt = confirmedAt
        self.source = source
        self.provenance = provenance
    }
}

/// JSON codec uses finite secondsSince1970 dates, strict keys/types and complete validation before authoritative writes.
public struct MetadataJSONDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let normalizationVersion: Int
    public let exportID: UUID
    public let exportedAt: Date
    public let entries: [MetadataJSONEntry]
    public init(schemaVersion: Int = 1, normalizationVersion: Int = 1, exportID: UUID, exportedAt: Date, entries: [MetadataJSONEntry]) {
        self.schemaVersion = schemaVersion
        self.normalizationVersion = normalizationVersion
        self.exportID = exportID
        self.exportedAt = exportedAt
        self.entries = entries
    }
}

public struct MetadataImportConflict: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let assetID: String
    public let expectedVersion: MetadataRecordVersion
    public let existing: PhotoTextFields
    public let incoming: PhotoTextFields
    public init(id: UUID, assetID: String, expectedVersion: MetadataRecordVersion, existing: PhotoTextFields, incoming: PhotoTextFields) {
        self.id = id
        self.assetID = assetID
        self.expectedVersion = expectedVersion
        self.existing = existing
        self.incoming = incoming
    }
}

/// Only summary crosses to UI. Repository retains one immutable validated import and its full expected versions.
public struct MetadataImportReview: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let exportID: UUID
    public let contentSHA256: String
    public let sourceByteCount: Int64
    public let entryCount: Int
    public let missingCount: Int
    public let unassignedCount: Int
    public let conflicts: [MetadataImportConflict]
    public init(id: UUID, sourceURL: URL, exportID: UUID, contentSHA256: String, sourceByteCount: Int64, entryCount: Int, missingCount: Int, unassignedCount: Int, conflicts: [MetadataImportConflict]) {
        self.id = id
        self.sourceURL = sourceURL
        self.exportID = exportID
        self.contentSHA256 = contentSHA256
        self.sourceByteCount = sourceByteCount
        self.entryCount = entryCount
        self.missingCount = missingCount
        self.unassignedCount = unassignedCount
        self.conflicts = conflicts
    }
}

public enum MetadataImportAction: Codable, Equatable, Sendable {
    case keepExisting
    case replace(fields: Set<PhotoMetadataField>, tags: MetadataTagPolicy)
}

public struct MetadataImportDecision: Codable, Equatable, Sendable {
    public let conflictID: UUID
    public let expectedVersion: MetadataRecordVersion
    public let action: MetadataImportAction
    public init(conflictID: UUID, expectedVersion: MetadataRecordVersion, action: MetadataImportAction) {
        self.conflictID = conflictID
        self.expectedVersion = expectedVersion
        self.action = action
    }
}

/// Operation ID plus canonical review-content/decision hash provides retries after consuming the ephemeral review.
public struct MetadataImportOperation: Codable, Equatable, Sendable {
    public let id: UUID
    public let reviewID: UUID
    public let reviewContentSHA256: String
    public let decisions: [MetadataImportDecision]
    public init(id: UUID = UUID(), reviewID: UUID, reviewContentSHA256: String, decisions: [MetadataImportDecision]) {
        self.id = id
        self.reviewID = reviewID
        self.reviewContentSHA256 = reviewContentSHA256
        self.decisions = decisions
    }
}

public struct MetadataExportResult: Equatable, Sendable {
    public let destination: URL
    public let exportID: UUID
    public let entryCount: Int
    public let byteCount: Int64
    public let sha256: String
    public init(destination: URL, exportID: UUID, entryCount: Int, byteCount: Int64, sha256: String) {
        self.destination = destination
        self.exportID = exportID
        self.entryCount = entryCount
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// All mutating methods have one serial writer. They validate first, atomically
/// commit receipts+data, then publish a search state independently. Once an
/// accepted transaction starts, UI/observer cancellation cannot undo its commit.
public protocol PhotoMetadataStoring: Sendable {
    func searchState() async -> PhotoMetadataSearchState
    func updates() async -> AsyncStream<PhotoMetadataSearchState>
    func record(assetID: String) async throws -> PhotoMetadataRecord?
    func saveManualDraft(_ operation: MetadataManualDraftOperation) async throws -> MetadataCommitResult
    func saveAIDraft(_ operation: MetadataAIDraftOperation) async throws -> MetadataCommitResult
    func setDraftState(_ operation: MetadataDraftStateOperation) async throws -> MetadataCommitResult
    func confirm(_ operation: MetadataConfirmOperation) async throws -> MetadataCommitResult
    func reconcile(_ snapshot: MetadataCatalogSnapshot) async throws -> MetadataReconciliationResult
    func stageCatalogChange(_ change: MetadataCatalogChange) async throws -> MetadataCatalogChangeReceipt
    func recoverCatalogChanges(persistedCatalog: MetadataCatalogSnapshot) async throws -> MetadataReconciliationResult
    func completeCatalogChange(id: UUID, persistedCatalog: MetadataCatalogSnapshot) async throws -> MetadataReconciliationResult
    func resolveCatalogChange(_ operation: MetadataCatalogResolutionOperation) async throws -> MetadataReconciliationResult
    func prepareImport(source: URL, protection: MetadataFileProtectionSnapshot) async throws -> MetadataImportReview
    func discardImport(reviewID: UUID) async
    func commitImport(_ operation: MetadataImportOperation) async throws -> MetadataCommitResult
    func exportConfirmed(destination: URL, protection: MetadataFileProtectionSnapshot) async throws -> MetadataExportResult
    func finishSaving() async -> Bool
}

/// Fixed normalization v1. Run on repository/validation workers, never View.body.
/// Byte checks precede normalization and grapheme counting. All limits apply
/// both before and after normalization; append validates the combined tag list.
public enum PhotoTextNormalization {
    public static let version = 1
    public static func normalize(_ input: PhotoTextFields, requireSuggestionContent: Bool = false) throws -> PhotoTextFields {
        guard input.title.utf8.count <= PhotoMetadataLimits.maximumTitleBytes else { throw PhotoMetadataError.limitExceeded(.titleBytes) }
        guard input.description.utf8.count <= PhotoMetadataLimits.maximumDescriptionBytes else { throw PhotoMetadataError.limitExceeded(.descriptionBytes) }
        guard input.tags.count <= PhotoMetadataLimits.maximumTags else { throw PhotoMetadataError.limitExceeded(.tagCount) }
        guard input.language.utf8.count <= PhotoMetadataLimits.maximumLanguageBytes else { throw PhotoMetadataError.limitExceeded(.languageBytes) }
        try checkControls(input.title); try checkControls(input.description); try checkControls(input.language)
        let title = inline(input.title)
        let description = input.description.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = input.language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty, language.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }) else { throw PhotoMetadataError.validation(.invalidLanguage) }
        guard title.count <= PhotoMetadataLimits.maximumTitleCharacters else { throw PhotoMetadataError.limitExceeded(.titleCharacters) }
        guard title.utf8.count <= PhotoMetadataLimits.maximumTitleBytes else { throw PhotoMetadataError.limitExceeded(.titleBytes) }
        guard description.count <= PhotoMetadataLimits.maximumDescriptionCharacters else { throw PhotoMetadataError.limitExceeded(.descriptionCharacters) }
        guard description.utf8.count <= PhotoMetadataLimits.maximumDescriptionBytes else { throw PhotoMetadataError.limitExceeded(.descriptionBytes) }
        var tags: [String] = [], seen = Set<String>()
        for raw in input.tags {
            guard raw.utf8.count <= PhotoMetadataLimits.maximumTagBytes else { throw PhotoMetadataError.limitExceeded(.tagBytes) }
            try checkControls(raw)
            let tag = inline(raw)
            guard !tag.isEmpty else { throw PhotoMetadataError.validation(.emptyTag) }
            guard tag.count <= PhotoMetadataLimits.maximumTagCharacters else { throw PhotoMetadataError.limitExceeded(.tagCharacters) }
            guard tag.utf8.count <= PhotoMetadataLimits.maximumTagBytes else { throw PhotoMetadataError.limitExceeded(.tagBytes) }
            if seen.insert(tagKey(tag)).inserted { tags.append(tag) }
        }
        let cost = title.utf8.count + description.utf8.count + language.utf8.count + tags.reduce(0) { $0 + $1.utf8.count }
        guard cost <= PhotoMetadataLimits.maximumTextFieldsBytes else { throw PhotoMetadataError.limitExceeded(.textFieldsBytes) }
        if requireSuggestionContent, title.isEmpty && description.isEmpty && tags.isEmpty {
            throw PhotoMetadataError.validation(.emptySuggestion)
        }
        return PhotoTextFields(title: title, description: description, tags: tags, language: language)
    }
    public static func tagKey(_ normalizedTag: String) -> String {
        normalizedTag.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
    /// Each side is bounded independently. Duplicate tags across two valid
    /// 20-tag lists do not make an otherwise valid append fail before dedup.
    /// Validate the complete resulting fields again for the aggregate byte cap.
    public static func mergingTags(existing: [String], incoming: [String], policy: MetadataTagPolicy) throws -> [String] {
        let old = try normalize(PhotoTextFields(tags: existing)).tags
        let new = try normalize(PhotoTextFields(tags: incoming)).tags
        if policy == .replace { return new }
        var result = old, seen = Set(old.map(tagKey))
        for tag in new where seen.insert(tagKey(tag)).inserted {
            guard result.count < PhotoMetadataLimits.maximumTags else { throw PhotoMetadataError.limitExceeded(.tagCount) }
            result.append(tag)
        }
        return result
    }
    private static func inline(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func checkControls(_ text: String) throws {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 32 && value != 9 && value != 10 && value != 13 || (127...159).contains(value) {
                throw PhotoMetadataError.validation(.invalidControlCharacter)
            }
        }
    }
}
