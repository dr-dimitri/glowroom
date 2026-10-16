import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Optional Cloud provider", .serialized, .timeLimit(.minutes(2)))
struct CloudAIProviderTests {
    @Test func defaultOffAndNoConsentNeverReadKeyOrSend() async throws {
        let f = try CloudFixture()
        await expectCloud(.disabled) { _ = try await f.provider.proposal(for: f.request) }
        await f.enable()
        await expectCloud(.consentRequired) { _ = try await f.provider.proposal(for: f.request) }
        #expect(await f.keychain.readCount == 0)
        #expect(f.transport.requests.isEmpty)
        #expect(try await f.usage.summary().requestCount == 0)
    }
    @Test func actualSentBytesAreTextOnlySanitizedAndFixedAPI() async throws {
        let f = try CloudFixture()
        await f.enable(); try await f.authorize()
        let data = try await f.provider.proposal(for: f.request)
        #expect(try EditProposalValidator().validate(data, against: .neutral) != .noChange)
        let sent = try #require(f.transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-secret")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let bytes = try #require(sent.httpBody)
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in ["/private/synthetic-catalog", "private-photo.RAW", "synthetic-asset-id", "GPSLatitude", "Exif", "synthetic-secret"] { #expect(!text.contains(secret)) }
        #expect(bytes.count < CloudAIProvider.maximumRequestBytes)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["model"] as? String == "claude-haiku-5-5")
        #expect(object["max_tokens"] as? Int == 1_200)
        #expect(object["temperature"] == nil && object["tools"] == nil)
        let messages = try #require(object["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(messages.count == 1 && content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(!text.contains("base64") && !text.contains("image_url"))
        let userData = try #require(content[0]["text"] as? String)
        #expect(userData.contains("Kontrast"))
        let used = try await f.usage.summary()
        #expect(used.requestCount == 1 && used.dispatchedCount == 1)
        #expect(used.inputTokens == 100 && used.outputTokens == 20)
        #expect(used.chargedNanodollars == 20_000 && used.uncertainCount == 0)
        let ledger = try Data(contentsOf: f.directory.appendingPathComponent("cloud-usage.sqlite"))
        let ledgerText = String(decoding: ledger, as: UTF8.self)
        #expect(!ledgerText.contains("synthetic-secret") && !ledgerText.contains("synthetic-asset-id") && !ledgerText.contains("Kontrast"))
    }
    @Test func exactFrozenRequestAndOneShotGrant() async throws {
        let f = try CloudFixture(); await f.enable(); try await f.authorize()
        let changed = AIEditingRequest(id: f.request.id, prompt: "Mehr Schatten", snapshot: f.request.snapshot)
        await expectCloud(.consentRequired) { _ = try await f.provider.proposal(for: changed) }
        _ = try await f.provider.proposal(for: f.request)
        await expectCloud(.consentRequired) { _ = try await f.provider.proposal(for: f.request) }
        #expect(f.transport.requests.count == 1)
    }
    @Test func revocationAndConfigurationInvalidateConsent() async throws {
        let f = try CloudFixture(); await f.enable()
        let consent = try await f.provider.prepareConsent(for: f.request)
        await f.provider.revoke()
        await expectCloud(.revoked) { try await f.provider.grant(consent) }
        try await f.authorize()
        await f.provider.updateConfiguration(enabled: true, requestLimit: 1, monthlyBudgetNanodollars: 1_000_000_000)
        await expectCloud(.consentRequired) { _ = try await f.provider.proposal(for: f.request) }
        #expect(f.transport.requests.isEmpty)
    }
    @Test func withdrawingOldConsentCannotRevokeNewPrompt() async throws {
        let f = try CloudFixture(); await f.enable()
        let old = try await f.provider.prepareConsent(for: f.request)
        let current = try await f.provider.prepareConsent(for: f.request)
        await f.provider.withdraw(old)
        try await f.provider.grant(current)
        _ = try await f.provider.proposal(for: f.request)
        #expect(f.transport.requests.count == 1)
    }
    @Test func staleSettingsMutationAndRevokeCannotReplaceNewConfiguration() async throws {
        let f = try CloudFixture()
        await f.provider.updateConfiguration(enabled: true, requestLimit: 1, monthlyBudgetNanodollars: 1_000_000_000, revision: 20)
        await f.provider.updateConfiguration(enabled: false, requestLimit: 100, monthlyBudgetNanodollars: 100_000_000_000, revision: 19)
        #expect(await f.provider.availability() == .available)
        let current = try await f.provider.prepareConsent(for: f.request)
        try await f.provider.grant(current)
        await f.provider.revoke(revision: 18)
        _ = try await f.provider.proposal(for: f.request)
        // An older relaxed count limit must not overwrite the current limit 1.
        await f.provider.updateConfiguration(enabled: true, requestLimit: 100, monthlyBudgetNanodollars: 100_000_000_000, revision: 17)
        try await f.authorize()
        await expectCloud(.limitExceeded) { _ = try await f.provider.proposal(for: f.request) }
        #expect(f.transport.requests.count == 1)
        await f.provider.updateConfiguration(enabled: false, requestLimit: 1, monthlyBudgetNanodollars: 1_000_000_000, revision: 21)
        await f.provider.updateConfiguration(enabled: true, requestLimit: 100, monthlyBudgetNanodollars: 100_000_000_000, revision: 20)
        #expect(await f.provider.availability() == .unavailable(.disabled))
    }
    @Test func missingKeyReleasesReservationWithoutUpload() async throws {
        let f = try CloudFixture(); await f.keychain.set(nil); await f.enable(); try await f.authorize()
        await expectCloud(.missingKey) { _ = try await f.provider.proposal(for: f.request) }
        #expect(f.transport.requests.isEmpty)
        #expect(try await f.usage.summary().requestCount == 0)
    }
    @Test func revokeWhileKeyReadBlocksPreventsResumeAndReleases() async throws {
        let f = try CloudFixture(); await f.enable(); try await f.authorize(); await f.keychain.blockReads()
        let task = Task { try await f.provider.proposal(for: f.request) }
        try await waitCloud { await f.keychain.readCount == 1 }
        await f.provider.revoke(); await f.keychain.releaseRead()
        await expectCloud(.revoked) { _ = try await task.value }
        #expect(f.transport.requests.isEmpty)
        #expect(try await f.usage.summary().requestCount == 0)
    }
    @Test func cancelAndRevokeAfterDispatchRetainUnknownCosts() async throws {
        let f = try CloudFixture(blocked: true); await f.enable(); try await f.authorize()
        let task = Task { try await f.provider.proposal(for: f.request) }
        try await waitCloud { f.transport.operations.first?.started == true }
        await f.provider.revoke()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        let summary = try await f.usage.summary()
        #expect(summary.requestCount == 1 && summary.uncertainCount == 1)
        #expect(summary.chargedNanodollars == 600_000_000)
        #expect(f.transport.requests.count == 1)
    }
    @Test(arguments: [401,402,403,404,413,429,500,529])
    func HTTPFailuresAreTypedAndNeverRetried(_ status: Int) async throws {
        let f = try CloudFixture(response: .init(statusCode: status, data: Data("private-server-error".utf8)))
        await f.enable(); try await f.authorize()
        await expectCloud(CloudAIProvider.error(for: status)) { _ = try await f.provider.proposal(for: f.request) }
        #expect(f.transport.requests.count == 1)
        #expect(try await f.usage.summary().chargedNanodollars == 600_000_000)
    }
    @Test func strictPatchInvalidRefusedAndTruncatedStillSettleUsage() async throws {
        for response in [cloudEnvelope(payload: "{\"schemaVersion\":1,\"changes\":[{\"parameter\":\"exposure\",\"value\":100}]}"),
                         cloudEnvelope(payload: "{\"schemaVersion\":1,\"schemaVersion\":1,\"changes\":[]}"),
                         cloudEnvelope(stop: "refusal"), cloudEnvelope(stop: "max_tokens"),
                         cloudEnvelope(payload: String(repeating: "A", count: 65_537))] {
            let f = try CloudFixture(response: .init(statusCode: 200, data: response))
            await f.enable(); try await f.authorize()
            do { _ = try await f.provider.proposal(for: f.request); Issue.record("Expected invalid/refused response") } catch {}
            #expect(try await f.usage.summary().chargedNanodollars == 20_000)
            #expect(f.transport.requests.count == 1)
        }
    }
    @Test func malformedAndOversizedResponseUnknownCost() async throws {
        for data in [Data("malformed-private-output".utf8), Data(repeating: 65, count: 256 * 1_024 + 1)] {
            let f = try CloudFixture(response: .init(statusCode: 200, data: data)); await f.enable(); try await f.authorize()
            do { _ = try await f.provider.proposal(for: f.request); Issue.record("Expected bounded parse failure") } catch {}
            #expect(try await f.usage.summary().uncertainCount == 1)
            #expect(try await f.usage.summary().chargedNanodollars == 600_000_000)
        }
    }
    @Test func noVisionNoCloudLooksAndTextInputBound() async throws {
        let f = try CloudFixture(); await f.enable()
        #expect(f.provider.capabilities == [.textEditing])
        let looks = AIEditingRequest(prompt: "", snapshot: f.request.snapshot, mode: .lookGroup)
        do { _ = try await f.provider.prepareConsent(for: looks); Issue.record("Expected unsupported") } catch { #expect(error as? AIEditingError == .unsupportedCapability) }
        let huge = AIEditingRequest(prompt: String(repeating: "ä", count: 1_025), snapshot: f.request.snapshot)
        do { _ = try await f.provider.prepareConsent(for: huge); Issue.record("Expected text limit") } catch { #expect(error as? AIEditingError == .inputLimitExceeded) }
        #expect(f.transport.requests.isEmpty)
    }
}

func cloudEnvelope(payload: String = "{\"schemaVersion\":1,\"changes\":[{\"parameter\":\"contrast\",\"value\":20}],\"explanation\":\"Kontrast erhöhen.\"}", stop: String = "end_turn") -> Data {
    try! JSONSerialization.data(withJSONObject: ["stop_reason":stop,"usage":["input_tokens":100,"output_tokens":20],"content":[["type":"text","text":payload]]])
}
struct CloudFixture {
    let directory: URL
    let usage: CloudUsageStore
    let keychain = FakeCloudKeychain()
    let transport: FakeCloudTransport
    let provider: CloudAIProvider
    let request: AIEditingRequest
    init(response: CloudHTTPResponse = .init(statusCode: 200, data: cloudEnvelope()), blocked: Bool = false, ignoresCancellation: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Cloud-\(UUID().uuidString)")
        usage = try CloudUsageStore(url: directory.appendingPathComponent("cloud-usage.sqlite"))
        transport = FakeCloudTransport(response: blocked ? nil : .success(response), ignoresCancellation: ignoresCancellation)
        provider = CloudAIProvider(keychain: keychain, usage: usage, transport: transport)
        request = AIEditingRequest(prompt: "Erhöhe nur den Kontrast.", snapshot: AIEditingSnapshot(assetID: "synthetic-asset-id", source: .original(AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/private/synthetic-catalog/private-photo.RAW"), modifiedAt: Date(timeIntervalSince1970: 123), fileSize: 42)), settings: .neutral, token: AIEditingToken(editSessionID: UUID(), editGeneration: 1, selectionSessionID: UUID(), selectionGeneration: 1)))
    }
    func enable() async { await provider.updateConfiguration(enabled: true, requestLimit: 50, monthlyBudgetNanodollars: 5_000_000_000) }
    func authorize() async throws { let c = try await provider.prepareConsent(for: request); try await provider.grant(c) }
}
actor FakeCloudKeychain: AICloudKeychain {
    var key: String? = "synthetic-secret"
    var readCount = 0
    var saves = 0
    var deletions = 0
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    func read() async -> String? {
        readCount += 1
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return key
    }
    func save(_ key: String) { self.key = key; saves += 1 }
    func delete() { key = nil; deletions += 1 }
    func set(_ key: String?) { self.key = key }
    func blockReads() { blocked = true }
    func releaseRead() { blocked = false; continuation?.resume(); continuation = nil }
}
final class FakeCloudTransport: CloudHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var created: [FakeCloudOperation] = []
    let response: Result<CloudHTTPResponse, Error>?
    let ignoresCancellation: Bool
    init(response: Result<CloudHTTPResponse, Error>?, ignoresCancellation: Bool = false) { self.response = response; self.ignoresCancellation = ignoresCancellation }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var operations: [FakeCloudOperation] { lock.withLock { created } }
    func operation(for request: URLRequest) -> any CloudHTTPOperation {
        let operation = FakeCloudOperation(response: response, ignoresCancellation: ignoresCancellation)
        lock.withLock { recorded.append(request); created.append(operation) }
        return operation
    }
}
final class FakeCloudOperation: CloudHTTPOperation, @unchecked Sendable {
    private let lock = NSLock()
    private let initial: Result<CloudHTTPResponse, Error>?
    private var result: Result<CloudHTTPResponse, Error>?
    private var waiter: CheckedContinuation<CloudHTTPResponse, Error>?
    private var didStart = false
    private let ignoresCancellation: Bool
    var started: Bool { lock.withLock { didStart } }
    init(response: Result<CloudHTTPResponse, Error>?, ignoresCancellation: Bool = false) { initial = response; self.ignoresCancellation = ignoresCancellation }
    func resume() { lock.withLock { didStart = true }; if let initial { complete(initial) } }
    func cancel() { if !ignoresCancellation { complete(.failure(CancellationError())) } }
    func complete(_ value: Result<CloudHTTPResponse, Error>) {
        lock.lock(); guard result == nil else { lock.unlock(); return }; result = value; let c = waiter; waiter = nil; lock.unlock(); c?.resume(with: value)
    }
    func value() async throws -> CloudHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); if let result { lock.unlock(); continuation.resume(with: result) } else { waiter = continuation; lock.unlock() }
            }
        } onCancel: { self.cancel() }
    }
}
func expectCloud(_ expected: AICloudError, _ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected \(expected)") } catch { #expect(error as? AICloudError == expected) }
}
func waitCloud(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw AICloudError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}
