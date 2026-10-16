import Foundation

/// These errors intentionally contain no underlying provider message or payload.
enum AICloudError: Error, Equatable, Sendable, LocalizedError {
    case disabled, consentRequired, revoked, missingKey, invalidKey, keychain
    case unsupportedModel, forbidden, paymentRequired, rateLimited, limitExceeded
    case invalidWorkspace, invalidConfiguration
    case network, timeout, responseTooLarge, requestTooLarge, redirect, invalidResponse, refusal, persistence, busy
    var errorDescription: String? {
        switch self {
        case .disabled: return "Cloud ist deaktiviert. Aktiviere Anthropic bewusst in den KI-Einstellungen."
        case .consentRequired: return "Für diesen eingefrorenen Textauftrag fehlt die Freigabe."
        case .revoked: return "Die Cloud-Freigabe wurde widerrufen oder die Konfiguration geändert. Bereits entstandene Kosten sind möglich."
        case .missingKey: return "Im Keychain fehlt der Anthropic-API-Schlüssel."
        case .invalidKey: return "Anthropic hat den API-Schlüssel abgelehnt. Ersetze ihn in den KI-Einstellungen."
        case .keychain: return "Der API-Schlüssel konnte im macOS-Keychain nicht verarbeitet werden."
        case .unsupportedModel: return "Das fest konfigurierte Anthropic-Modell ist für dieses Konto nicht verfügbar."
        case .forbidden: return "Das Anthropic-Konto erlaubt diese Anfrage nicht."
        case .paymentRequired: return "Anthropic meldet ein Zahlungs- oder Guthabenproblem."
        case .rateLimited: return "Anthropic begrenzt die Anfragen. Es wird nicht automatisch wiederholt; mögliche Kosten bleiben vorgemerkt."
        case .limitExceeded: return "Das lokale Cloud-Mengen- oder Modellpreisbudget ist ausgeschöpft."
        case .invalidWorkspace: return "Die Workspace-ID muss mit wrkspc_ beginnen und danach ausschließlich Buchstaben oder Ziffern enthalten (höchstens 128 Zeichen)."
        case .invalidConfiguration: return "Anthropic hat die Anfragekonfiguration abgelehnt. Prüfe insbesondere die Workspace-ID: Schlüssel für mehrere Workspaces benötigen diese Angabe."
        case .network: return "Die Cloud-Anfrage ist fehlgeschlagen. Ab Versand bleiben mögliche Kosten vorgemerkt; keine automatische Wiederholung."
        case .timeout: return "Die Cloud-Anfrage hat das Zeitlimit erreicht. Mögliche Kosten bleiben vorgemerkt."
        case .responseTooLarge: return "Die Cloud-Antwort überschreitet das Empfangslimit. Mögliche Kosten bleiben vorgemerkt."
        case .requestTooLarge: return "Der vorbereitete Cloud-Auftrag überschreitet das Größenlimit."
        case .redirect: return "Die Cloud-Verbindung verlangte eine nicht erlaubte Weiterleitung."
        case .invalidResponse: return "Die Cloud-Antwort ist unvollständig oder entspricht nicht dem erlaubten Reglerformat."
        case .refusal: return "Anthropic hat diesen Auftrag abgelehnt. Gemeldete Nutzung wird trotzdem gezählt."
        case .persistence: return "Der lokale Cloud-Nutzungszähler ist nicht verfügbar. Es wird nichts hochgeladen."
        case .busy: return "Eine Cloud-Anfrage läuft noch. Warte auf deren Abschluss."
        }
    }
}

struct AICloudConsent: Identifiable, Equatable, Sendable {
    let id: UUID
    let requestID: UUID
    let model: String
    let bodyByteCount: Int
    let maximumOutputTokens: Int
    let reservationNanodollars: Int64
    let workspaceID: String?
}

/// Workspace IDs enter an HTTP header, so only the documented ASCII identifier
/// form is accepted. Whitespace around a pasted identifier is harmless.
enum AICloudWorkspaceID {
    static func normalized(_ input: String?) throws -> String? {
        let value = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard value.hasPrefix("wrkspc_"), value.utf8.count > 7, value.utf8.count <= 128,
              value.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { throw AICloudError.invalidWorkspace }
        return value
    }
}

protocol AICloudKeychain: Sendable {
    func read() async throws -> String?
    func save(_ key: String) async throws
    func delete() async throws
    func storageDescription() async -> String
}

extension AICloudKeychain {
    func storageDescription() async -> String { "Schlüssel werden im macOS-Keychain gespeichert; kein Lesen beim Appstart." }
}
