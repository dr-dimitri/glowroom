import Foundation
import Security
import Testing
@testable import PicEdit

@Suite("System keychain signing policy")
struct SystemAICloudKeychainTests {
    @Test func ordinaryAdHocAppUsesLocalKeychainWithoutClaimingDeviceOnlyProtection() {
        #expect(SystemAICloudKeychain.selectBackend(signingFlags: SecCodeSignatureFlags.adhoc.rawValue, entitlements: [:]) == .localFile)
        // Merely embedding an entitlement in an ad-hoc signature cannot grant DP access.
        #expect(SystemAICloudKeychain.selectBackend(signingFlags: SecCodeSignatureFlags.adhoc.rawValue,
            entitlements: ["com.apple.application-identifier": "TESTTEAM.de.picedit"]) == .localFile)
        #expect(SystemAICloudKeychain.selectBackend(signingFlags: 0, entitlements: [:]) == .localFile)
        let query = SystemAICloudKeychain.baseQuery(backend: .localFile, service: "synthetic", account: "synthetic")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessible as String] == nil)
        #expect(query[kSecValueData as String] == nil)
    }

    @Test func signedApplicationWithAccessGroupRetainsDataProtectionStore() {
        for entitlements in [
            ["com.apple.application-identifier": "TESTTEAM.de.picedit"],
            ["keychain-access-groups": ["TESTTEAM.de.picedit"]]
        ] as [[String: Any]] {
            #expect(SystemAICloudKeychain.selectBackend(signingFlags: 0, entitlements: entitlements) == .dataProtection)
        }
        let query = SystemAICloudKeychain.baseQuery(backend: .dataProtection, service: "synthetic", account: "synthetic")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrService as String] as? String == "synthetic")
        #expect(query[kSecAttrAccount as String] as? String == "synthetic")
    }
}
