import Foundation

/// One paired text/image space; every preprocessing/tokenizer change creates a
/// new index identity, even when the public model name stays the same.
public struct SemanticModelDescriptor: Codable, Hashable, Sendable {
    public let modelID: String
    public let sourceRevision: String
    public let releaseID: String
    public let dimension: Int
    public let maximumTextTokens: Int
    public let tokenizerVersion: String
    public let preprocessingVersion: Int
    public let normalizationVersion: Int

    public init(modelID: String, sourceRevision: String, releaseID: String, dimension: Int,
                maximumTextTokens: Int, tokenizerVersion: String, preprocessingVersion: Int,
                normalizationVersion: Int) {
        self.modelID = modelID; self.sourceRevision = sourceRevision; self.releaseID = releaseID
        self.dimension = dimension; self.maximumTextTokens = maximumTextTokens
        self.tokenizerVersion = tokenizerVersion; self.preprocessingVersion = preprocessingVersion
        self.normalizationVersion = normalizationVersion
    }

    public func validate() throws {
        let identifiers = [modelID, sourceRevision, releaseID, tokenizerVersion]
        guard identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              (1...4_096).contains(dimension), (1...512).contains(maximumTextTokens),
              preprocessingVersion > 0, normalizationVersion > 0 else {
            throw SemanticEmbeddingError.invalidInput
        }
    }
}

public enum SemanticUnavailableReason: String, Codable, Hashable, Sendable {
    case modelNotInstalled, unsupportedSystem, unsupportedHardware, invalidInstallation
    case insufficientMemory, busy, unknown
}

extension SemanticUnavailableReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled: return "Für die semantische Suche ist noch kein geprüftes lokales Modell installiert."
        case .unsupportedSystem: return "Dieser macOS-Stand unterstützt das lokale Suchmodell nicht."
        case .unsupportedHardware: return "Dieser Mac unterstützt das lokale Suchmodell nicht."
        case .invalidInstallation: return "Die lokale Modellinstallation ist unvollständig oder verändert. Bitte erneut installieren."
        case .insufficientMemory: return "Für das lokale Suchmodell steht nicht genügend Arbeitsspeicher bereit."
        case .busy: return "Das lokale Suchmodell ist noch beschäftigt."
        case .unknown: return "Das lokale Suchmodell ist derzeit nicht verfügbar."
        }
    }
}

public enum SemanticAvailability: Hashable, Sendable {
    case available
    case unavailable(SemanticUnavailableReason)
}

public enum SemanticEmbeddingError: Error, Hashable, Sendable {
    case cancelled, superseded, staleSource, invalidInput, invalidVector
    case invalidInstallation, installationChanged, insufficientDiskSpace, unsupportedVersion
    case indexUnavailable, corruptIndex, providerFailure
    case unavailable(SemanticUnavailableReason)
}

extension SemanticEmbeddingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Die semantische Suche wurde abgebrochen."
        case .superseded: return "Eine neuere Suchanfrage hat diese Anfrage ersetzt."
        case .staleSource: return "Die Bildquelle hat sich geändert. Bitte den Ordner aktualisieren und den Index fortsetzen."
        case .invalidInput: return "Die Eingabe für das lokale Suchmodell ist ungültig."
        case .invalidVector: return "Das lokale Suchmodell hat keinen gültigen normalisierten Suchvektor geliefert."
        case .invalidInstallation: return SemanticUnavailableReason.invalidInstallation.localizedDescription
        case .installationChanged: return "Das lokale Suchmodell wurde zwischenzeitlich ersetzt. Bitte den Suchindex neu vorbereiten."
        case .insufficientDiskSpace: return "Für die geprüfte Modellinstallation und ihre temporären Dateien fehlt freier Speicherplatz."
        case .unsupportedVersion: return "Diese Suchindex- oder Modellversion wird nicht unterstützt. Die vorhandenen Daten bleiben erhalten."
        case .indexUnavailable: return "Für diesen Umfang ist noch kein passender Suchindex vorbereitet."
        case .corruptIndex: return "Der Suchindex ist beschädigt. Er bleibt bis zum bewussten Neuaufbau erhalten."
        case .providerFailure: return "Das lokale Suchmodell konnte die Anfrage nicht abschließen."
        case .unavailable(let reason): return reason.localizedDescription
        }
    }
}
