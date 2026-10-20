import Foundation

/// Capabilities of the independent image analysis and generation services.
public struct AIProviderCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let imageUnderstanding = Self(rawValue: 1 << 1)
    public static let imageGeneration = Self(rawValue: 1 << 2)
}

/// Metadata captured by the app, without filesystem I/O in the value initializer.
/// This is a versioned-source fingerprint, not a cryptographic content hash.
public struct AIOriginalSourceFingerprint: Hashable, Sendable {
    public let standardizedPath: String
    public let isFileURL: Bool
    public let modifiedAt: Date
    public let fileSize: Int64

    public init(fileURL: URL, modifiedAt: Date, fileSize: Int64) {
        standardizedPath = fileURL.standardizedFileURL.path
        isFileURL = fileURL.isFileURL
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
    }
}

/// Future immutable generated sources can extend this contract in their own feature.
public enum AISourceIdentity: Hashable, Sendable {
    case original(AIOriginalSourceFingerprint)
    case artifact(ArtifactSourceFingerprint)
}

/// App-owned epochs distinguish equal settings after undo/restore or A→B→A selection.
/// A counter overflow must rotate its corresponding session UUID before resetting to zero.
/// Tokens intentionally have no model-facing Codable representation.
public struct AIEditingToken: Hashable, Sendable {
    public let editSessionID: UUID
    public let editGeneration: UInt64
    public let selectionSessionID: UUID
    public let selectionGeneration: UInt64

    public init(editSessionID: UUID, editGeneration: UInt64,
                selectionSessionID: UUID, selectionGeneration: UInt64) {
        self.editSessionID = editSessionID
        self.editGeneration = editGeneration
        self.selectionSessionID = selectionSessionID
        self.selectionGeneration = selectionGeneration
    }
}

/// Shared source and editing context for analysis, mask drafts and generated artifacts.
public struct AIEditingSnapshot: Hashable, Sendable {
    public let assetID: String
    public let source: AISourceIdentity
    public let settings: EditSettings
    public let token: AIEditingToken
    /// Absent only for imported-original analysis independent of the edit store.
    public let persistedVersion: EditingExpectedState?

    public init(assetID: String, source: AISourceIdentity, settings: EditSettings, token: AIEditingToken,
                persistedVersion: EditingExpectedState? = nil) {
        self.assetID = assetID
        self.source = source
        self.settings = settings
        self.token = token
        self.persistedVersion = persistedVersion
    }

    /// Constant-size checks validate app-owned metadata and numeric editing controls
    /// before any service resolves or reads the source.
    public func validate() throws {
        guard !assetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              EditParameter.allCases.allSatisfy({
                  let value = $0.value(in: settings)
                  return value.isFinite && $0.range.contains(value)
              }) else { throw ImageAnalysisError.invalidRequest }
        switch source {
        case .original(let fingerprint):
            guard fingerprint.isFileURL, fingerprint.standardizedPath.hasPrefix("/"),
                  fingerprint.fileSize >= 0, fingerprint.modifiedAt.timeIntervalSinceReferenceDate.isFinite
            else { throw ImageAnalysisError.invalidRequest }
        case .artifact(let fingerprint):
            guard fingerprint.schemaVersion == 1, fingerprint.raster.format.orientation == .up,
                  persistedVersion != nil else { throw ImageAnalysisError.invalidRequest }
        }
    }
}
