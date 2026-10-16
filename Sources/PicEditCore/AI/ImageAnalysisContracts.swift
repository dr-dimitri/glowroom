import Foundation

public enum ImageAnalysisCachePolicy: String, Hashable, Sendable { case reuseValidated, refreshRaster }

public enum ImageAnalysisInputKind: String, Codable, Hashable, Sendable {
    case originalPreview, editedPreview
}

public enum ImageAnalysisUnavailableReason: String, Hashable, Sendable {
    case unsupportedSystem, sdkUnavailable, unsupportedHardware, disabled, modelUnavailable
    case unsupportedLanguage, unsupportedCapability, temporaryFailure, unknown
}

extension ImageAnalysisUnavailableReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSystem: return "Die lokale Bildanalyse benötigt macOS 27 oder neuer."
        case .sdkUnavailable: return "Dieser Build enthält kein SDK für native Bildattachments."
        case .unsupportedHardware: return "Dieser Mac unterstützt das lokale Systemmodell nicht."
        case .disabled: return "Apple Intelligence ist in den Systemeinstellungen deaktiviert."
        case .modelUnavailable: return "Das lokale Bildmodell ist noch nicht bereit."
        case .unsupportedLanguage: return "Das lokale Bildmodell unterstützt Deutsch derzeit nicht."
        case .unsupportedCapability: return "Das gewählte lokale Systemmodell unterstützt keine Bildanalyse."
        case .temporaryFailure: return "Der lokale Bildanalysedienst ist vorübergehend nicht erreichbar."
        case .unknown: return "Die lokale Bildanalyse ist aus einem unbekannten Grund nicht verfügbar."
        }
    }
}

public enum ImageAnalysisAvailability: Hashable, Sendable {
    case available
    case unavailable(ImageAnalysisUnavailableReason)
}

public enum ImageAnalysisError: Error, Hashable, Sendable {
    case cancelled, superseded, staleSource, invalidRequest, invalidResponse, inputLimitExceeded
    case safetyRefusal, temporaryModelFailure, providerFailure
    case unavailable(ImageAnalysisUnavailableReason)
}

extension ImageAnalysisError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Die Bildanalyse wurde abgebrochen."
        case .superseded: return "Eine neuere Bildanalyse hat diese Anfrage ersetzt."
        case .staleSource: return "Die Originaldatei hat sich während der Analyse geändert. Bitte den Ordner aktualisieren."
        case .invalidRequest: return "Die Bildanalyse-Anfrage ist ungültig."
        case .invalidResponse: return "Das Modell hat keine gültigen begrenzten Analysevorschläge geliefert."
        case .inputLimitExceeded: return "Die Bildanalyse überschreitet das Eingabe- oder Größenlimit."
        case .safetyRefusal: return "Das lokale Systemmodell hat die Bildanalyse aus Sicherheitsgründen abgelehnt."
        case .temporaryModelFailure: return "Das lokale Bildmodell ist vorübergehend beschäftigt. Bitte erneut versuchen."
        case .providerFailure: return "Die lokale Bildanalyse konnte nicht abgeschlossen werden."
        case .unavailable(let reason): return reason.localizedDescription
        }
    }
}

/// Identity remains app-side. Original analysis ignores normal slider generations,
/// while selection epochs and restore/lifecycle boundaries remain observable.
public struct ImageAnalysisRequest: Hashable, Sendable {
    public static let taskVersion = 1
    public static let schemaVersion = 1
    public let id: UUID
    public let snapshot: AIEditingSnapshot
    public let inputKind: ImageAnalysisInputKind
    public let language: String
    public let lifecycleID: UUID
    public let cachePolicy: ImageAnalysisCachePolicy

    public init(id: UUID = UUID(), snapshot: AIEditingSnapshot,
                inputKind: ImageAnalysisInputKind = .originalPreview, language: String = "de_DE", lifecycleID: UUID,
                cachePolicy: ImageAnalysisCachePolicy = .reuseValidated) {
        self.id = id
        self.snapshot = snapshot
        self.inputKind = inputKind
        self.language = language
        self.lifecycleID = lifecycleID
        self.cachePolicy = cachePolicy
    }

    public func validate() throws {
        guard language == "de_DE" else { throw ImageAnalysisError.unavailable(.unsupportedLanguage) }
        do { try snapshot.validate() } catch { throw ImageAnalysisError.invalidRequest }
    }

    public func matches(current: AIEditingSnapshot, lifecycleID: UUID) -> Bool {
        guard self.lifecycleID == lifecycleID else { return false }
        if inputKind == .editedPreview { return snapshot == current }
        return snapshot.assetID == current.assetID && snapshot.source == current.source
            && snapshot.token.editSessionID == current.token.editSessionID
            && snapshot.token.selectionSessionID == current.token.selectionSessionID
            && snapshot.token.selectionGeneration == current.token.selectionGeneration
    }
}

public enum ImageAnalysisAttributeCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case subject, color, composition, lighting, style
    public var label: String {
        switch self {
        case .subject: return "Motiv"
        case .color: return "Farben"
        case .composition: return "Komposition"
        case .lighting: return "Licht"
        case .style: return "Stil"
        }
    }
}

public struct ImageAnalysisAttribute: Codable, Hashable, Sendable {
    public let category: ImageAnalysisAttributeCategory
    public let value: String
    public init(category: ImageAnalysisAttributeCategory, value: String) { self.category = category; self.value = value }
}

/// Model statements are suggestions, never confirmed metadata or editing commands.
public struct ImageAnalysisSuggestions: Codable, Hashable, Sendable {
    public let description: String
    public let attributes: [ImageAnalysisAttribute]
    public init(description: String, attributes: [ImageAnalysisAttribute]) { self.description = description; self.attributes = attributes }

    public func validate() throws {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              description.utf8.count <= 2_048, attributes.count <= 12,
              attributes.allSatisfy({ !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.utf8.count <= 256 }),
              Set(attributes).count == attributes.count else { throw ImageAnalysisError.invalidResponse }
    }
}

public struct ImageAnalysisProviderDescriptor: Hashable, Sendable {
    public let capabilities: AIProviderCapabilities = [.imageUnderstanding]
    public let providerID: String
    public let modelID: String
    public let modelVersion: String?
    public let executionLocation: String
    public init(providerID: String, modelID: String, modelVersion: String? = nil, executionLocation: String = "Auf diesem Mac") {
        self.providerID = providerID; self.modelID = modelID; self.modelVersion = modelVersion; self.executionLocation = executionLocation
    }
}

/// Hash/profile describe the exact native CGImage supplied to Attachment, before
/// the framework's own private tensor conversion. No model output defines provenance.
public struct ImageAnalysisProvenance: Hashable, Sendable {
    public static let currentPreprocessingVersion = 1
    public let providerID: String
    public let modelID: String
    public let modelVersion: String?
    public let analyzedAt: Date
    public let rasterSHA256: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
    public let colorProfile: String
    public let colorProfileSHA256: String?
    public let orientation: String
    public let preprocessingVersion: Int
    public let taskVersion: Int
    public let schemaVersion: Int
    public let source: AISourceIdentity
    public let inputKind: ImageAnalysisInputKind
    public let editToken: AIEditingToken?

    public init(descriptor: ImageAnalysisProviderDescriptor, analyzedAt: Date, rasterSHA256: String,
                pixelWidth: Int, pixelHeight: Int, byteCount: Int, colorProfile: String, colorProfileSHA256: String?,
                source: AISourceIdentity, inputKind: ImageAnalysisInputKind, editToken: AIEditingToken?) {
        providerID = descriptor.providerID; modelID = descriptor.modelID; modelVersion = descriptor.modelVersion
        self.analyzedAt = analyzedAt; self.rasterSHA256 = rasterSHA256
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.byteCount = byteCount
        self.colorProfile = colorProfile; self.colorProfileSHA256 = colorProfileSHA256
        orientation = "up (EXIF orientation applied by ImageIO)"
        preprocessingVersion = Self.currentPreprocessingVersion
        taskVersion = ImageAnalysisRequest.taskVersion; schemaVersion = ImageAnalysisRequest.schemaVersion
        self.source = source; self.inputKind = inputKind; self.editToken = editToken
    }
    /// Original-only compatibility for existing analysis clients. No edit-store
    /// baseline is invented by this provenance convenience initializer.
    public init(descriptor: ImageAnalysisProviderDescriptor, analyzedAt: Date, rasterSHA256: String,
                pixelWidth: Int, pixelHeight: Int, byteCount: Int, colorProfile: String, colorProfileSHA256: String?,
                source: AIOriginalSourceFingerprint, inputKind: ImageAnalysisInputKind, editToken: AIEditingToken?) {
        self.init(descriptor: descriptor, analyzedAt: analyzedAt, rasterSHA256: rasterSHA256,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, byteCount: byteCount,
            colorProfile: colorProfile, colorProfileSHA256: colorProfileSHA256,
            source: .original(source), inputKind: inputKind, editToken: editToken)
    }

}

public struct ImageAnalysisResult: Hashable, Sendable {
    public let request: ImageAnalysisRequest
    public let suggestions: ImageAnalysisSuggestions
    public let provenance: ImageAnalysisProvenance
    public init(request: ImageAnalysisRequest, suggestions: ImageAnalysisSuggestions, provenance: ImageAnalysisProvenance) {
        self.request = request; self.suggestions = suggestions; self.provenance = provenance
    }
}
