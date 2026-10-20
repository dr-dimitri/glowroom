import Foundation

/// Capabilities describe distinct operations; text editing never implies access to pixels.
public struct AIProviderCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let textEditing = Self(rawValue: 1 << 0)
    public static let imageUnderstanding = Self(rawValue: 1 << 1)
    public static let imageGeneration = Self(rawValue: 1 << 2)
    public static let lookSuggestions = Self(rawValue: 1 << 3)
}

public enum AIUnavailableReason: String, Hashable, Sendable {
    case unsupportedSystem, unsupportedHardware, modelUnavailable, disabled
    case sdkUnavailable, unsupportedLanguage, unknown
}

extension AIUnavailableReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem: return "Die lokale KI benötigt macOS 26 oder neuer."
        case .sdkUnavailable: return "Dieser PicEdit-Build enthält keine Unterstützung für das lokale Systemmodell."
        case .unsupportedHardware: return "Dieser Mac unterstützt das lokale Apple-Intelligence-Modell nicht."
        case .disabled: return "Apple Intelligence ist in den Systemeinstellungen deaktiviert."
        case .modelUnavailable: return "Das lokale Systemmodell ist noch nicht bereit oder noch nicht vollständig geladen."
        case .unsupportedLanguage: return "Das lokale Systemmodell unterstützt Deutsch auf diesem Mac derzeit nicht."
        case .unknown: return "Das lokale Systemmodell ist aus einem unbekannten Grund nicht verfügbar."
        }
    }
}

public enum AIUnsupportedTaskReason: String, Hashable, Sendable {
    case imageAnalysis, whiteBalance, unsupportedLanguage, other
}

extension AIUnsupportedTaskReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .imageAnalysis: return "Bildanalyse wird von diesem Anbieter nicht unterstützt. Er erhält keine Bildpixel."
        case .whiteBalance: return "Dieser KI-Anbieter steuert den Weißabgleich nicht. Verwende Temperatur, Tönung oder die Neutralpipette in den Grundeinstellungen."
        case .unsupportedLanguage: return "Das lokale Systemmodell unterstützt die Sprache dieser Anfrage nicht."
        case .other: return "Diese Aufgabe wird vom lokalen Bearbeitungsanbieter nicht unterstützt."
        }
    }
}

public enum AIAvailability: Hashable, Sendable {
    case available
    case unavailable(AIUnavailableReason)
}

/// Errors carry categories only, never prompts, source paths or model output.
public enum AIEditingError: Error, Hashable, Sendable {
    case cancelled
    case superseded
    case unavailable(AIUnavailableReason)
    case unsupportedCapability
    case unsupportedTask(AIUnsupportedTaskReason)
    case safetyRefusal
    case inputLimitExceeded
    case temporaryModelFailure
    case regionSelectionUnavailable
    case skyModelUnavailable
    case invalidRequest
    case staleSnapshot
    case invalidResponse(AIProposalValidationError)
    case providerFailure
}

extension AIEditingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Die KI-Anfrage wurde abgebrochen."
        case .superseded: return "Eine neuere KI-Anfrage hat diese Anfrage ersetzt."
        case .unavailable(let reason): return reason.localizedDescription
        case .unsupportedCapability: return "Der KI-Anbieter unterstützt diese Bearbeitung nicht."
        case .unsupportedTask(let reason): return reason.localizedDescription
        case .safetyRefusal: return "Das lokale Systemmodell hat die Anfrage aus Sicherheitsgründen abgelehnt."
        case .inputLimitExceeded: return "Die Anfrage überschreitet das Eingabe- oder Kontextlimit der lokalen KI. Bitte kürzen."
        case .temporaryModelFailure: return "Das lokale Systemmodell ist vorübergehend beschäftigt. Bitte die Anfrage erneut starten."
        case .regionSelectionUnavailable: return "Der gewünschte Bildbereich konnte nicht zuverlässig ausgewählt werden. Verwende das Werkzeug Maskieren oder präzisiere deinen Auftrag. Es wurde nichts geändert."
        case .skyModelUnavailable: return "Für die Himmelskorrektur wird das lokale Himmelsmodell benötigt. Öffne Maskieren und prüfe dort „Himmelsmodell einrichten …“. Es wurde nichts geändert."
        case .invalidRequest: return "Die KI-Anfrage ist ungültig."
        case .staleSnapshot: return "Der Bild- oder Bearbeitungsstand hat sich inzwischen geändert."
        case .invalidResponse(let reason):
            switch reason {
            case .invalidLookCount, .invalidLookID:
                return "Die KI hat keine vollständige Gruppe mit den drei erwarteten Looks geliefert. Bitte erneut versuchen."
            case .invalidLookName: return "Ein KI-Look hat keinen gültigen kurzen Namen. Bitte erneut versuchen."
            case .ineffectiveLook: return "Ein KI-Look verändert den Ausgangsstand nicht. Bitte die drei Looks erneut erstellen."
            case .duplicateLookTargets: return "Zwei KI-Looks ergeben denselben Stand. Bitte die drei Looks erneut erstellen."
            default: return "Der KI-Vorschlag enthält ungültige oder nicht unterstützte Daten."
            }
        case .providerFailure: return "Der KI-Anbieter konnte keinen Vorschlag erstellen."
        }
    }
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

/// The app captures source plus settings and rechecks the complete snapshot at acceptance.
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

    /// Constant-size metadata/control checks also used at app acceptance. Prompt policy is
    /// request-specific and must not be reapplied with different limits during acceptance.
    public func validate() throws {
        guard !assetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              EditParameter.allCases.allSatisfy({
                  let value = $0.value(in: settings)
                  return value.isFinite && $0.range.contains(value)
              }) else { throw AIEditingError.invalidRequest }
        switch source {
        case .original(let fingerprint):
            guard fingerprint.isFileURL, fingerprint.standardizedPath.hasPrefix("/"),
                  fingerprint.fileSize >= 0, fingerprint.modifiedAt.timeIntervalSinceReferenceDate.isFinite
            else { throw AIEditingError.invalidRequest }
        case .artifact(let fingerprint):
            guard fingerprint.schemaVersion == 1, fingerprint.raster.format.orientation == .up,
                  persistedVersion != nil else { throw AIEditingError.invalidRequest }
        }
    }
}

/// IDs and context are generated exclusively by the app, never decoded from model output.
public enum AIEditingMode: String, Hashable, Sendable {
    case single, lookGroup
}

public struct AIEditingRequest: Hashable, Sendable {
    public let id: UUID
    public let prompt: String
    public let snapshot: AIEditingSnapshot
    public let mode: AIEditingMode

    public init(id: UUID = UUID(), prompt: String, snapshot: AIEditingSnapshot, mode: AIEditingMode = .single) {
        self.id = id
        self.prompt = prompt
        self.snapshot = snapshot
        self.mode = mode
    }

    /// Validate app inputs before availability checks or provider work. This is deliberately
    /// separate from proposal validation and never repairs an invalid source or baseline.
    public func validate(maximumPromptBytes: Int = 16_384) throws {
        guard maximumPromptBytes > 0,
              prompt.utf8.count <= maximumPromptBytes,
              mode == .lookGroup || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AIEditingError.invalidRequest }
        try snapshot.validate()
    }
}

/// Implementations must cooperate with cancellation where possible. A coordinator retains
/// the inference slot until an uninterruptible provider call has actually returned.
/// The raw response crosses the strict validator before any app state can be changed.
public protocol AIEditingProvider: Sendable {
    var id: String { get }
    var capabilities: AIProviderCapabilities { get }
    func availability() async -> AIAvailability
    func proposal(for request: AIEditingRequest) async throws -> Data
}
