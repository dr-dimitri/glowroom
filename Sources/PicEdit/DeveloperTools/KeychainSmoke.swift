#if PICEDIT_KEYCHAIN_SMOKE
import Foundation

/// Explicit developer harness only; never compiled into the ordinary app.
/// Every operation uses a fresh UUID namespace, never the production item.
@main
struct KeychainSmoke {
    private enum Failure: Error { case unexpectedExistingItem, mismatchedRead, incompleteDelete }

    static func main() async throws {
        let namespace = UUID()
        let keychain = SystemAICloudKeychain(testNamespace: namespace)
        print("Keychain-Smoke: \(await keychain.storageDescription())")
        guard try await keychain.read() == nil else { throw Failure.unexpectedExistingItem }
        do {
            try await keychain.save("picedit-synthetic-keychain-smoke")
            guard try await keychain.read() == "picedit-synthetic-keychain-smoke" else { throw Failure.mismatchedRead }
            try await keychain.save("picedit-synthetic-keychain-replacement")
            guard try await keychain.read() == "picedit-synthetic-keychain-replacement" else { throw Failure.mismatchedRead }
            try await keychain.delete()
            guard try await keychain.read() == nil else { throw Failure.incompleteDelete }
            print("PASS: synthetischen Schlüssel gespeichert, gelesen, ersetzt und gelöscht.")
        } catch {
            // Await cleanup instead of dispatching an unstructured task that
            // could be lost when this short-lived executable terminates.
            do { try await keychain.delete() }
            catch { print("Cleanup fehlgeschlagen; eigener Test-Namespace: \(namespace.uuidString)") }
            throw error
        }
    }
}
#endif
