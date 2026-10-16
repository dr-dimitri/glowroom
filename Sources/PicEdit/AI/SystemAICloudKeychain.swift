import Foundation
import Security

/// Storage is selected once from the process's signing capabilities, before any
/// credential operation. An access failure never silently switches keychains.
/// Security calls stay serial on this background actor so save/read/delete of
/// the same entry cannot race; another worker would add no useful parallelism.
actor SystemAICloudKeychain: AICloudKeychain {
    enum Backend: String, Sendable {
        case dataProtection, localFile
    }
    private let service: String
    private let account = "user-api-key"
    private var selectedBackend: Backend?

    /// Test namespaces can only append a UUID, never address the production item.
    init(testNamespace: UUID? = nil) {
        service = "de.wolfgangbauer.picedit.anthropic" + (testNamespace.map { ".test." + $0.uuidString } ?? "")
    }

    func storageDescription() async -> String {
        do {
            switch try backend() {
            case .dataProtection:
                return "Gerätegebundener Data-Protection-Keychain, nicht synchronisiert. Kein Lesen beim Appstart."
            case .localFile:
                return "Lokaler macOS-Standardschlüsselbund, nicht synchronisiert; Zugriff für diese App geschützt. Nach einem neuen lokalen Build kann macOS erneut um Erlaubnis bitten. Kein Lesen beim Appstart."
            }
        } catch { return AICloudError.keychain.localizedDescription }
    }

    func read() throws -> String? {
        var query = try query(for: backend())
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AICloudError.keychain }
        return value
    }

    func save(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4_096,
              key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw AICloudError.invalidKey }
        let backend = try backend()
        var attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        if backend == .dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemUpdate(try query(for: backend) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var created = try query(for: backend, adding: true).merging(attributes) { _, new in new }
            if backend == .localFile { created[kSecAttrAccess as String] = try Self.applicationAccess() }
            guard SecItemAdd(created as CFDictionary, nil) == errSecSuccess else { throw AICloudError.keychain }
        } else if status != errSecSuccess { throw AICloudError.keychain }
    }

    func delete() throws {
        let status = SecItemDelete(try query(for: backend()) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AICloudError.keychain }
    }

    private func query(for backend: Backend, adding: Bool = false) throws -> [String: Any] {
        var query = Self.baseQuery(backend: backend, service: service, account: account)
        if backend == .localFile {
            // Restrict all operations to one explicitly chosen local keychain,
            // rather than searching/deleting matching items in every keychain.
            var keychain: SecKeychain?
            guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { throw AICloudError.keychain }
            if adding { query[kSecUseKeychain as String] = keychain }
            else { query[kSecMatchSearchList as String] = [keychain] }
        }
        return query
    }

    nonisolated static func baseQuery(backend: Backend, service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: backend == .dataProtection,
         kSecAttrSynchronizable as String: false]
    }

    private func backend() throws -> Backend {
        if let selectedBackend { return selectedBackend }
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { throw AICloudError.keychain }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { throw AICloudError.keychain }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let flags = information[kSecCodeInfoFlags as String] as? NSNumber else { throw AICloudError.keychain }
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let result = Self.selectBackend(signingFlags: flags.uint32Value, entitlements: entitlements)
        selectedBackend = result
        return result
    }

    nonisolated static func selectBackend(signingFlags: UInt32, entitlements: [String: Any]) -> Backend {
        let adHoc = signingFlags & SecCodeSignatureFlags.adhoc.rawValue != 0
        let applicationID = entitlements["com.apple.application-identifier"] as? String ?? ""
        let groups = entitlements["keychain-access-groups"] as? [String] ?? []
        // A bundle identifier alone grants no DP access. Retain the existing DP
        // item for signed applications claiming an app/keychain access group.
        let hasAccessGroup = !applicationID.isEmpty || groups.contains { !$0.isEmpty }
        return !adHoc && hasAccessGroup ? .dataProtection : .localFile
    }

    private static func applicationAccess() throws -> SecAccess {
        var application: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &application) == errSecSuccess,
              let application else { throw AICloudError.keychain }
        var access: SecAccess?
        // Explicitly trust only this application, preserving macOS confirmation
        // for other or changed binaries. Never grant access to all applications.
        guard SecAccessCreate("PicEdit Anthropic API-Schlüssel" as CFString, [application] as CFArray, &access) == errSecSuccess,
              let access else { throw AICloudError.keychain }
        return access
    }
}
