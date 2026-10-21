// Shared immutable artifact values and capabilities for schema-2 editing.
// Persistence and App owners validate these at their durable boundaries.
import Foundation

public enum ArtifactContractError: Error, Equatable, Sendable {
    case invalidValue(String)
    case staleEpoch
    case staleSnapshot
    case conflictingCommit
    case sourceChanged
    case missingArtifact
    case corruptArtifact
    case invalidCapability
    case unsupportedFormat
    case limitExceeded
    case ambiguousCommit
    case unsupportedVersion(Int)
}

public protocol ArtifactUUIDTag: Sendable {}
public enum GeneratedArtifactTag: ArtifactUUIDTag {}
public enum ArtifactResourceTag: ArtifactUUIDTag {}
public enum ArtifactDraftTag: ArtifactUUIDTag {}
public enum ArtifactStoreTag: ArtifactUUIDTag {}
public enum EditingCommitTag: ArtifactUUIDTag {}
public enum EditingVariantTag: ArtifactUUIDTag {}
public enum EditingRemapTag: ArtifactUUIDTag {}

/// UUID identity only: never a relative filename. Wire form is canonical lowercase.
public struct ArtifactUUID<Tag: ArtifactUUIDTag>: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public var canonicalString: String { rawValue.uuidString.lowercased() }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uuid = UUID(uuidString: text), text == uuid.uuidString.lowercased() else {
            throw ArtifactContractError.invalidValue("noncanonical UUID")
        }
        rawValue = uuid
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(canonicalString)
    }
}
public typealias GeneratedArtifactID = ArtifactUUID<GeneratedArtifactTag>
public typealias ArtifactResourceID = ArtifactUUID<ArtifactResourceTag>
public typealias ArtifactDraftID = ArtifactUUID<ArtifactDraftTag>
public typealias ArtifactStoreID = ArtifactUUID<ArtifactStoreTag>
public typealias EditingCommitID = ArtifactUUID<EditingCommitTag>
public typealias EditingVariantID = ArtifactUUID<EditingVariantTag>
public typealias EditingRemapID = ArtifactUUID<EditingRemapTag>

public struct ArtifactDigest: Codable, Hashable, Sendable {
    public let sha256: String
    public init(sha256: String) throws {
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ArtifactContractError.invalidValue("SHA256")
        }
        self.sha256 = sha256
    }
    public init(from decoder: Decoder) throws {
        try self.init(sha256: decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(sha256)
    }
}

public enum EditableSourceRef: Hashable, Sendable, Codable {
    case original
    case artifact(GeneratedArtifactID)
    private enum CodingKeys: String, CodingKey { case kind, artifactID }
    private enum Kind: String, Codable { case original, artifact }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .original:
            guard !values.contains(.artifactID) else { throw ArtifactContractError.invalidValue("original artifactID") }
            self = .original
        case .artifact: self = .artifact(try values.decode(GeneratedArtifactID.self, forKey: .artifactID))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .original: try values.encode(Kind.original, forKey: .kind)
        case .artifact(let id):
            try values.encode(Kind.artifact, forKey: .kind); try values.encode(id, forKey: .artifactID)
        }
    }
}

public struct EditingSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let source: EditableSourceRef
    public let settings: EditSettings
    // Preserve the wire shape of older snapshots. Adding a defaulted control
    // must not invalidate strict JSON checks or change signed manifest/journal
    // bytes merely because a saved snapshot was read by a newer application.
    private var omittedDefaultSettings: Set<EditParameter> = []
    private static let defaultedSettings: Set<EditParameter> = [
        .autoToneAmount, .naturalBalanceAmount, .naturalBalanceColorAmount,
        .sharpeningAmount, .sharpeningRadius, .sharpeningDetail, .sharpeningMasking
    ]
    public init(source: EditableSourceRef = .original, settings: EditSettings = .neutral) throws {
        guard settings == settings.normalized else { throw ArtifactContractError.invalidValue("settings") }
        try settings.validateLocalAdjustments()
        try settings.developGeometry.validate()
        schemaVersion = 2; self.source = source; self.settings = settings
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, source, settings }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 2 else { throw ArtifactContractError.unsupportedVersion(version) }
        try self.init(source: values.decode(EditableSourceRef.self, forKey: .source),
                      settings: values.decode(EditSettings.self, forKey: .settings))
        let controls = try values.nestedContainer(keyedBy: SettingKey.self, forKey: .settings)
        omittedDefaultSettings = Set(Self.defaultedSettings.filter { !controls.contains(SettingKey($0)) })
    }
    private struct SettingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ parameter: EditParameter) { stringValue = parameter.rawValue }
        static let localAdjustments = SettingKey(stringValue: "localAdjustments")!
        static let developColor = SettingKey(stringValue: "developColor")!
        static let developGeometry = SettingKey(stringValue: "developGeometry")!
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(source, forKey: .source)
        var controls = values.nestedContainer(keyedBy: SettingKey.self, forKey: .settings)
        for parameter in EditParameter.allCases where !omittedDefaultSettings.contains(parameter) {
            try controls.encode(parameter.value(in: settings), forKey: SettingKey(parameter))
        }
        if !settings.localAdjustments.isEmpty { try controls.encode(settings.localAdjustments, forKey: .localAdjustments) }
        if !settings.developColor.isNeutral { try controls.encode(settings.developColor, forKey: .developColor) }
        if !settings.developGeometry.isNeutral { try controls.encode(settings.developGeometry, forKey: .developGeometry) }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.source == rhs.source && lhs.settings == rhs.settings
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion); hasher.combine(source); hasher.combine(settings)
    }
}

public struct EditingStoreVersion: Codable, Hashable, Sendable {
    public let storeEpoch: UUID
    public let revision: Int64
    public init(storeEpoch: UUID, revision: Int64) throws {
        guard revision >= 0 else { throw ArtifactContractError.invalidValue("revision") }
        self.storeEpoch = storeEpoch; self.revision = revision
    }
    private enum CodingKeys: String, CodingKey { case storeEpoch, revision }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(storeEpoch: values.decode(UUID.self, forKey: .storeEpoch),
                      revision: values.decode(Int64.self, forKey: .revision))
    }
}
public struct StoredEditingState: Hashable, Sendable {
    public let snapshot: EditingSnapshot
    public let version: EditingStoreVersion
    public init(snapshot: EditingSnapshot, version: EditingStoreVersion) {
        self.snapshot = snapshot; self.version = version
    }
}

/// snapshot+revision = stored value; nil snapshot+revision = tombstone;
/// both nil = never stored. Epoch is required in every case.
public struct EditingExpectedState: Codable, Hashable, Sendable {
    public let storeEpoch: UUID
    public let revision: Int64?
    public let snapshot: EditingSnapshot?
    public init(storeEpoch: UUID, revision: Int64?, snapshot: EditingSnapshot?) throws {
        guard revision.map({ $0 >= 0 }) != false, snapshot == nil || revision != nil else {
            throw ArtifactContractError.invalidValue("CAS baseline")
        }
        self.storeEpoch = storeEpoch; self.revision = revision; self.snapshot = snapshot
    }
    public init(_ stored: StoredEditingState) {
        storeEpoch = stored.version.storeEpoch; revision = stored.version.revision; snapshot = stored.snapshot
    }
}
public struct EditingStoreState: Sendable {
    public let storeEpoch: UUID
    public let byAsset: [String: StoredEditingState]
    public let tombstones: [String: Int64]
    public init(storeEpoch: UUID, byAsset: [String: StoredEditingState], tombstones: [String: Int64]) throws {
        guard byAsset.values.allSatisfy({ $0.version.storeEpoch == storeEpoch }),
              tombstones.values.allSatisfy({ $0 >= 0 }), Set(byAsset.keys).isDisjoint(with: tombstones.keys) else {
            throw ArtifactContractError.invalidValue("store state")
        }
        self.storeEpoch = storeEpoch; self.byAsset = byAsset; self.tombstones = tombstones
    }
    // loadState() supplies all three fields from ONE SQLite read transaction.
}

public struct ArtifactPixelSize: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 16_777_216 / height else { throw ArtifactContractError.limitExceeded }
        self.width = width; self.height = height
    }
    private enum CodingKeys: String, CodingKey { case width, height }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: values.decode(Int.self, forKey: .width), height: values.decode(Int.self, forKey: .height))
    }
}
public struct ArtifactPixelRect: Codable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let size: ArtifactPixelSize
    public init(x: Int, y: Int, size: ArtifactPixelSize) throws {
        guard x >= 0, y >= 0, x <= 16_384 - size.width, y <= 16_384 - size.height else {
            throw ArtifactContractError.invalidValue("pixel rectangle")
        }
        self.x = x; self.y = y; self.size = size
    }
}
public enum ArtifactBitDepth: Int, Codable, Hashable, Sendable { case eight = 8, sixteen = 16 }
public enum ArtifactChannels: String, Codable, Hashable, Sendable { case rgb, rgba }
/// Stored PNG samples are straight alpha. Premultiplication is a decode-buffer
/// detail and is never silently reinterpreted as the persistent sample contract.
public enum ArtifactAlpha: String, Codable, Hashable, Sendable { case none, straight }
public enum ArtifactColorProfile: String, Codable, Hashable, Sendable { case sRGB, displayP3 }
public enum ArtifactOrientation: String, Codable, Hashable, Sendable { case up }
public enum ArtifactCodec: String, Codable, Hashable, Sendable { case png }

public struct ArtifactRasterFormat: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let size: ArtifactPixelSize
    public let bitDepth: ArtifactBitDepth
    public let channels: ArtifactChannels
    public let alpha: ArtifactAlpha
    public let profile: ArtifactColorProfile
    public let iccSHA256: ArtifactDigest
    public let orientation: ArtifactOrientation
    public init(size: ArtifactPixelSize, bitDepth: ArtifactBitDepth, channels: ArtifactChannels,
                profile: ArtifactColorProfile, iccSHA256: ArtifactDigest) {
        schemaVersion = 1; self.size = size; self.bitDepth = bitDepth; self.channels = channels
        alpha = channels == .rgba ? .straight : .none
        self.profile = profile; self.iccSHA256 = iccSHA256; orientation = .up
    }
}
public struct ArtifactFileDescriptor: Codable, Hashable, Sendable {
    public let sha256: ArtifactDigest
    public let bytes: Int64
    public init(sha256: ArtifactDigest, bytes: Int64) throws {
        guard bytes > 0, bytes <= 536_870_912 else { throw ArtifactContractError.limitExceeded }
        self.sha256 = sha256; self.bytes = bytes
    }
}
public struct RasterDescriptor: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let codec: ArtifactCodec
    public let codecVersion: Int
    public let format: ArtifactRasterFormat
    public let file: ArtifactFileDescriptor
    public init(format: ArtifactRasterFormat, file: ArtifactFileDescriptor) {
        schemaVersion = 1; codec = .png; codecVersion = 1; self.format = format; self.file = file
    }
}
public struct RenderedInputFingerprint: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let format: ArtifactRasterFormat
    public let canonicalPixelSHA256: ArtifactDigest
    public let pipelineVersion: Int
    public init(format: ArtifactRasterFormat, canonicalPixelSHA256: ArtifactDigest, pipelineVersion: Int) throws {
        guard pipelineVersion > 0 else { throw ArtifactContractError.invalidValue("input pipeline version") }
        schemaVersion = 1; self.format = format; self.canonicalPixelSHA256 = canonicalPixelSHA256
        self.pipelineVersion = pipelineVersion
    }
}

/// Exact native revision for coherent current-file access, including same-size
/// in-place changes with restored mtime. Never use this as cross-volume identity.
public struct OriginalSourceRevision: Codable, Hashable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let fileSize: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int32
    public let changedSeconds: Int64
    public let changedNanoseconds: Int32
    public init(device: Int64, inode: UInt64, fileSize: Int64, modifiedSeconds: Int64,
                modifiedNanoseconds: Int32, changedSeconds: Int64, changedNanoseconds: Int32) throws {
        guard fileSize >= 0, (0..<1_000_000_000).contains(modifiedNanoseconds),
              (0..<1_000_000_000).contains(changedNanoseconds) else {
            throw ArtifactContractError.invalidValue("native source revision")
        }
        self.device = device; self.inode = inode; self.fileSize = fileSize
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds
    }
}

/// Durable historical metadata. Native resource IDs are evidence where available,
/// not an assertion that dev/inode survive relocation to another volume.
public struct OriginalSourceFingerprint: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let standardizedPath: String
    public let fileSize: Int64
    public let modifiedAt: Date
    public let nativeRevision: OriginalSourceRevision
    public let resourceIdentifier: Data?
    public let volumeIdentifier: Data?
    public let contentSHA256: ArtifactDigest?
    public init(standardizedPath: String, fileSize: Int64, modifiedAt: Date,
                nativeRevision: OriginalSourceRevision, resourceIdentifier: Data? = nil, volumeIdentifier: Data? = nil,
                contentSHA256: ArtifactDigest? = nil) throws {
        guard standardizedPath.hasPrefix("/"), standardizedPath.utf8.count <= 16_384,
              fileSize >= 0, fileSize == nativeRevision.fileSize, modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              (resourceIdentifier?.count ?? 0) <= 4_096, (volumeIdentifier?.count ?? 0) <= 4_096 else {
            throw ArtifactContractError.invalidValue("original fingerprint")
        }
        schemaVersion = 1; self.standardizedPath = standardizedPath; self.fileSize = fileSize
        self.modifiedAt = modifiedAt; self.nativeRevision = nativeRevision; self.resourceIdentifier = resourceIdentifier
        self.volumeIdentifier = volumeIdentifier; self.contentSHA256 = contentSHA256
    }
}
public struct ArtifactSourceFingerprint: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let storeID: ArtifactStoreID
    public let artifactID: GeneratedArtifactID
    public let manifestSHA256: ArtifactDigest
    public let raster: RasterDescriptor
    public init(storeID: ArtifactStoreID, artifactID: GeneratedArtifactID,
                manifestSHA256: ArtifactDigest, raster: RasterDescriptor) {
        schemaVersion = 1; self.storeID = storeID; self.artifactID = artifactID
        self.manifestSHA256 = manifestSHA256; self.raster = raster
    }
}
public enum EditingSourceFingerprint: Hashable, Sendable {
    case original(OriginalSourceFingerprint)
    case artifact(ArtifactSourceFingerprint)
    // Explicit tagged wire form is defined below.
}

public enum ArtifactCoordinateSpace: String, Codable, Hashable, Sendable { case inputCanvas, outputCanvas }
public struct ArtifactCanvasPlacement: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let inputSize: ArtifactPixelSize
    public let outputSize: ArtifactPixelSize
    /// Where the already-rendered parent is placed in the new output canvas.
    public let inputOriginX: Int
    public let inputOriginY: Int
    public init(inputSize: ArtifactPixelSize, outputSize: ArtifactPixelSize, inputOriginX: Int, inputOriginY: Int) throws {
        guard inputOriginX >= 0, inputOriginY >= 0,
              inputOriginX <= outputSize.width - inputSize.width,
              inputOriginY <= outputSize.height - inputSize.height else {
            throw ArtifactContractError.invalidValue("canvas placement")
        }
        schemaVersion = 1; self.inputSize = inputSize; self.outputSize = outputSize
        self.inputOriginX = inputOriginX; self.inputOriginY = inputOriginY
    }
}
public enum ArtifactResourceKind: String, Codable, Hashable, Sendable { case maskGray8PNG }
public struct ArtifactMaskDescriptor: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: ArtifactResourceID
    public let kind: ArtifactResourceKind
    public let size: ArtifactPixelSize
    public let coordinateSpace: ArtifactCoordinateSpace
    public let file: ArtifactFileDescriptor
    public init(id: ArtifactResourceID, size: ArtifactPixelSize, coordinateSpace: ArtifactCoordinateSpace,
                file: ArtifactFileDescriptor) {
        schemaVersion = 1; self.id = id; kind = .maskGray8PNG; self.size = size
        self.coordinateSpace = coordinateSpace; self.file = file
    }
}
public enum GenerationExecution: String, Codable, Hashable, Sendable { case local, cloud }
public enum GenerationParameterKey: String, Codable, Hashable, Sendable {
    case strength, steps, guidanceScale, maskFeatherPixels, contextMarginPixels
}
public enum GenerationParameterValue: Hashable, Sendable {
    case boolean(Bool), integer(Int64), scalar(Double), text(String)
    // Explicit tagged wire form is defined below.
}
public struct GenerationParameter: Codable, Hashable, Sendable {
    public let key: GenerationParameterKey
    public let value: GenerationParameterValue
    public init(key: GenerationParameterKey, value: GenerationParameterValue) { self.key = key; self.value = value }
}
public struct GenerationParameters: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let values: [GenerationParameter]
    public init(values: [GenerationParameter]) throws {
        guard values.count <= 32, Set(values.map(\.key)).count == values.count else {
            throw ArtifactContractError.invalidValue("parameters")
        }
        for entry in values {
            switch entry.value {
            case .scalar(let number): guard number.isFinite else { throw ArtifactContractError.invalidValue("parameter number") }
            case .text(let text): guard text.utf8.count <= 1_024 else { throw ArtifactContractError.limitExceeded }
            case .boolean, .integer: break
            }
        }
        schemaVersion = 1; self.values = values
    }
}
public struct GenerationProviderIdentity: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String?
    public let modelRevision: String?
    public init(providerID: String, modelID: String? = nil, modelRevision: String? = nil) throws {
        guard !providerID.isEmpty, modelID?.isEmpty != true,
              providerID.utf8.count <= 256, (modelID?.utf8.count ?? 0) <= 512,
              (modelRevision?.utf8.count ?? 0) <= 256 else { throw ArtifactContractError.limitExceeded }
        self.providerID = providerID; self.modelID = modelID; self.modelRevision = modelRevision
    }
}
public struct GenerationProvenance: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let parentSource: EditingSourceFingerprint
    public let parentSnapshot: EditingSnapshot
    public let renderedInput: RenderedInputFingerprint
    public let placement: ArtifactCanvasPlacement
    public let pipelineVersion: Int
    public let parameterVersion: Int
    public let parameters: GenerationParameters
    public let provider: GenerationProviderIdentity
    public let seed: UInt64?
    public let prompt: String?
    public let createdAt: Date
    public let execution: GenerationExecution
    public let maskResourceIDs: [ArtifactResourceID]
    public let maskBindings: [GenerationMaskBinding]?
    public init(parentSource: EditingSourceFingerprint, parentSnapshot: EditingSnapshot,
                renderedInput: RenderedInputFingerprint, placement: ArtifactCanvasPlacement,
                pipelineVersion: Int, parameterVersion: Int, parameters: GenerationParameters,
                provider: GenerationProviderIdentity, seed: UInt64? = nil, prompt: String? = nil,
                createdAt: Date, execution: GenerationExecution, maskResourceIDs: [ArtifactResourceID] = [],
                maskBindings: [GenerationMaskBinding]? = nil) throws {
        guard pipelineVersion > 0, parameterVersion > 0, (prompt?.utf8.count ?? 0) <= 16_384,
              createdAt.timeIntervalSinceReferenceDate.isFinite, maskResourceIDs.count <= 16,
              Set(maskResourceIDs).count == maskResourceIDs.count, renderedInput.format.size == placement.inputSize else {
            throw ArtifactContractError.invalidValue("provenance")
        }
        schemaVersion = 1; self.parentSource = parentSource; self.parentSnapshot = parentSnapshot
        self.renderedInput = renderedInput; self.placement = placement; self.pipelineVersion = pipelineVersion
        self.parameterVersion = parameterVersion; self.parameters = parameters; self.provider = provider
        self.seed = seed; self.prompt = prompt; self.createdAt = createdAt; self.execution = execution; self.maskResourceIDs = maskResourceIDs
        guard (maskBindings?.count ?? 0) <= 16,
              Set((maskBindings ?? []).map(\.resourceID)).count == (maskBindings?.count ?? 0),
              Set((maskBindings ?? []).map(\.resourceID)).isSubset(of: Set(maskResourceIDs)) else {
            throw ArtifactContractError.invalidValue("Maskendokumentreferenzen")
        }
        for binding in maskBindings ?? [] {
            try binding.validate()
            guard binding.transform.canvasSize == placement.inputSize else { throw ArtifactContractError.invalidValue("Maskencanvas") }
        }
        self.maskBindings = maskBindings
    }
    // Persistence validator repeats all bounds/version/relationship checks after decoding.
    // The app validates parentSource matches parentSnapshot.source and mask sizes
    // match their declared input/output canvas before staging and after decoding.
}
public struct GeneratedArtifact: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: GeneratedArtifactID
    public let raster: RasterDescriptor
    public let provenance: GenerationProvenance
    public let resources: [ArtifactMaskDescriptor]
    public let manifestSHA256: ArtifactDigest
    public init(id: GeneratedArtifactID, raster: RasterDescriptor, provenance: GenerationProvenance,
                resources: [ArtifactMaskDescriptor] = [], manifestSHA256: ArtifactDigest) throws {
        guard raster.format.size == provenance.placement.outputSize,
              resources.count <= 16, Set(resources.map(\.id)).count == resources.count,
              Set(resources.map(\.id)) == Set(provenance.maskResourceIDs) else {
            throw ArtifactContractError.invalidValue("output geometry")
        }
        schemaVersion = 1; self.id = id; self.raster = raster; self.provenance = provenance
        self.resources = resources; self.manifestSHA256 = manifestSHA256
    }
    // Metadata is freely representable and is NOT evidence of file publication.
    // Manifest digest covers canonical {schemaVersion,id,raster,provenance,resources};
    // it is stored outside those bytes to avoid a recursive self-hash.
}
public struct EditingVariant: Sendable {
    public let id: EditingVariantID
    public let assetID: String
    public let snapshot: EditingSnapshot
    public let createdAt: Date
    public init(id: EditingVariantID, assetID: String, snapshot: EditingSnapshot, createdAt: Date) {
        self.id = id; self.assetID = assetID; self.snapshot = snapshot; self.createdAt = createdAt
    }
}


extension EditingSourceFingerprint: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case original, artifact }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .original: self = .original(try values.decode(OriginalSourceFingerprint.self, forKey: .value))
        case .artifact: self = .artifact(try values.decode(ArtifactSourceFingerprint.self, forKey: .value))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .original(let item):
            try values.encode(Kind.original, forKey: .kind); try values.encode(item, forKey: .value)
        case .artifact(let item):
            try values.encode(Kind.artifact, forKey: .kind); try values.encode(item, forKey: .value)
        }
    }
}
extension GenerationParameterValue: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case boolean, integer, scalar, text }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .boolean: self = .boolean(try values.decode(Bool.self, forKey: .value))
        case .integer: self = .integer(try values.decode(Int64.self, forKey: .value))
        case .scalar: self = .scalar(try values.decode(Double.self, forKey: .value))
        case .text: self = .text(try values.decode(String.self, forKey: .value))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean(let item): try values.encode(Kind.boolean, forKey: .kind); try values.encode(item, forKey: .value)
        case .integer(let item): try values.encode(Kind.integer, forKey: .kind); try values.encode(item, forKey: .value)
        case .scalar(let item): try values.encode(Kind.scalar, forKey: .kind); try values.encode(item, forKey: .value)
        case .text(let item): try values.encode(Kind.text, forKey: .kind); try values.encode(item, forKey: .value)
        }
    }
}

/// Actual artifact.json uses this body; the SHA256 of these canonical bytes is
/// stored in GeneratedArtifact/SQL/package closure, never inside its own input.
public struct GeneratedArtifactManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: GeneratedArtifactID
    public let raster: RasterDescriptor
    public let provenance: GenerationProvenance
    public let resources: [ArtifactMaskDescriptor]
    public init(id: GeneratedArtifactID, raster: RasterDescriptor, provenance: GenerationProvenance,
                resources: [ArtifactMaskDescriptor] = []) {
        schemaVersion = 1; self.id = id; self.raster = raster; self.provenance = provenance; self.resources = resources
    }
}


public struct ArtifactStorageLimits: Hashable, Sendable {
    public let maximumLongEdge: Int
    public let maximumPixels: Int
    public let maximumRasterWorkingBytes: Int64
    public let maximumPayloadBytes: Int64
    public let maximumRasterOperations: Int
    public let maximumFileTransfers: Int
    public let streamingChunkBytes: Int
    public init(maximumLongEdge: Int = 16_384, maximumPixels: Int = 16_777_216,
                maximumRasterWorkingBytes: Int64 = 536_870_912, maximumPayloadBytes: Int64 = 536_870_912) throws {
        guard (1...16_384).contains(maximumLongEdge), (1...16_777_216).contains(maximumPixels),
              maximumRasterWorkingBytes > 0, maximumRasterWorkingBytes <= 536_870_912,
              maximumPayloadBytes > 0, maximumPayloadBytes <= 536_870_912 else {
            throw ArtifactContractError.limitExceeded
        }
        self.maximumLongEdge = maximumLongEdge; self.maximumPixels = maximumPixels
        self.maximumRasterWorkingBytes = maximumRasterWorkingBytes; self.maximumPayloadBytes = maximumPayloadBytes
        maximumRasterOperations = 1; maximumFileTransfers = 2; streamingChunkBytes = 65_536
    }
}


/// Exact internal dates: hex of timeIntervalSinceReferenceDate.bitPattern.
/// Never milliseconds, ISO8601 rounding, or a conversion via the 1970 epoch.
public enum EditingContractJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let value = date.timeIntervalSinceReferenceDate
            guard value.isFinite else { throw ArtifactContractError.invalidValue("date") }
            var container = encoder.singleValueContainer()
            try container.encode(String(format: "%016llx", value.bitPattern))
        }
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard text.utf8.count == 16, let bits = UInt64(text, radix: 16),
                  text == String(format: "%016llx", bits), Double(bitPattern: bits).isFinite else {
                throw ArtifactContractError.invalidValue("date")
            }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        return decoder
    }
}
