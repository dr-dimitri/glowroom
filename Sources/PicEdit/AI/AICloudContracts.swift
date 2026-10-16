import Foundation
import Security

/// These errors intentionally contain no underlying provider message or payload.
enum AICloudError: Error, Equatable, Sendable, LocalizedError {
    case disabled, consentRequired, revoked, missingKey, invalidKey, keychain
    case unsupportedModel, forbidden, paymentRequired, rateLimited, limitExceeded
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
}

protocol AICloudKeychain: Sendable {
    func read() async throws -> String?
    func save(_ key: String) async throws
    func delete() async throws
}

/// No key is read at app startup. The sole fixed account is queried only by an
/// explicitly authorized job. Data Protection makes accessibility apply on macOS.
actor SystemAICloudKeychain: AICloudKeychain {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "de.wolfgangbauer.picedit.anthropic",
         kSecAttrAccount as String: "user-api-key",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AICloudError.keychain }
        return value
    }
    func save(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4_096,
              key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw AICloudError.invalidKey }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let created = query.merging(attributes) { _, new in new }
            guard SecItemAdd(created as CFDictionary, nil) == errSecSuccess else { throw AICloudError.keychain }
        } else if status != errSecSuccess { throw AICloudError.keychain }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AICloudError.keychain }
    }
}
