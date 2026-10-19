import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Cloud settings and assistant lifecycle", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct CloudSettingsIntegrationTests {
    @Test func defaultLocalKeyOperationsNeverPutSecretIntoPreferences() async throws {
        let suite = "PicEdit-CloudPrefs-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let keychain = FakeCloudKeychain()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let settings = AIProviderSettings(directory: directory, defaults: preferences, keychain: keychain, local: CloudTestLocalProvider())
        #expect(!settings.enabled && settings.selection == .local)
        #expect(await keychain.readCount == 0)
        settings.keyInput = "synthetic-only-never-persist"
        settings.saveKey()
        #expect(settings.keyInput.isEmpty)
        try await waitCloud { await MainActor.run { !settings.keyBusy } }
        #expect(await keychain.saves == 1)
        #expect(!String(describing: preferences.dictionaryRepresentation()).contains("synthetic-only-never-persist"))
        settings.deleteKey()
        try await waitCloud { await MainActor.run { !settings.keyBusy } }
        #expect(await keychain.deletions == 1)
        #expect(await keychain.readCount == 0)
        let reopened = AIProviderSettings(directory: directory, defaults: preferences, keychain: keychain, local: CloudTestLocalProvider())
        #expect(!reopened.enabled && reopened.selection == .local)
        #expect(await keychain.readCount == 0)
    }
    @Test func localFailureNeverFallsBackEvenWhenCloudEnabledAndKeySaved() async throws {
        let suite = "PicEdit-NoFallback-\(UUID())", f = try CloudFixture()
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "ai.cloud.enabled")
        let local = CloudTestFailingLocalProvider()
        let assistant = AIAssistantModel(provider: local, coordinator: AIRequestCoordinator(provider: local), snapshot: { f.request.snapshot }, accept: { _ in true }, sourceReadable: { _ in true })
        let settings = AIProviderSettings(directory: f.directory, defaults: preferences, keychain: f.keychain, local: local, transport: f.transport)
        settings.attach(assistant)
        try await waitCloud { await MainActor.run { assistant.availability == .available } }
        assistant.prompt = f.request.prompt; assistant.generate()
        try await waitCloud { await MainActor.run { if case .failed = assistant.state { return true }; return false } }
        #expect(f.transport.requests.isEmpty && settings.selection == .local)
        #expect(await f.keychain.readCount == 0)
    }
    @Test func activeLedgerCannotBeOverwrittenByBackupDestination() async throws {
        let f = try CloudFixture()
        _ = try await f.usage.summary()
        let original = try Data(contentsOf: f.directory.appendingPathComponent("cloud-usage.sqlite"))
        let editor = EditingModel(directory: f.directory)
        try await waitCloud { await MainActor.run { !editor.isLoading } }
        let exported = await editor.createBackup(exportTo: f.directory.appendingPathComponent("cloud-usage.sqlite"))
        #expect(exported == nil)
        #expect(try Data(contentsOf: f.directory.appendingPathComponent("cloud-usage.sqlite")) == original)
        #expect(editor.cloudProtectedURLs.contains(f.directory.appendingPathComponent("cloud-usage.sqlite")))
    }
    @Test func rapidSettingsChangesLeaveLatestCloudPolicyAndNoUpload() async throws {
        let suite = "PicEdit-RapidCloudSettings-\(UUID())", f = try CloudFixture()
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let local = CloudTestLocalProvider()
        let assistant = AIAssistantModel(provider: local, coordinator: AIRequestCoordinator(provider: local), snapshot: { f.request.snapshot }, accept: { _ in true }, sourceReadable: { _ in true })
        let settings = AIProviderSettings(directory: f.directory, defaults: preferences, keychain: f.keychain, local: local, transport: f.transport)
        settings.attach(assistant)
        for i in 0..<20 {
            settings.setEnabled(i % 2 == 0)
            settings.select(i % 3 == 0 ? .local : .anthropic)
            settings.requestLimit = i + 1; settings.saveLimits()
            if i % 4 == 0 { settings.revoke() }
        }
        settings.select(.anthropic); settings.setEnabled(false)
        try await waitCloud { await MainActor.run { assistant.availability == .unavailable(.disabled) && !assistant.supportsLooks } }
        #expect(await settings.cloud?.availability() == .unavailable(.disabled))
        #expect(!assistant.canGenerate && f.transport.requests.isEmpty)
        #expect(await f.keychain.readCount == 0)
    }
    @Test func providerChangesDiscardPreviewAndCloudDisablesLooks() async throws {
        let f = try CloudFixture()
        let local = CloudTestLocalProvider()
        let assistant = AIAssistantModel(provider: local, coordinator: AIRequestCoordinator(provider: local), snapshot: { f.request.snapshot }, accept: { _ in true }, sourceReadable: { _ in true })
        await assistant.refreshAvailability(); assistant.prompt = f.request.prompt; assistant.generate()
        try await waitCloud { await MainActor.run { assistant.state == .previewing } }
        #expect(assistant.hasAppliedChanges && assistant.canGenerateLooks)
        assistant.suspendProvider()
        await assistant.refreshAvailability()
        #expect(assistant.availability == nil && !assistant.canGenerate)
        assistant.replaceProvider(f.provider)
        #expect(assistant.result == nil && assistant.lookGroup == nil && !assistant.canAccept)
        #expect(!assistant.supportsLooks && !assistant.canGenerateLooks)
        #expect(f.transport.requests.isEmpty)
    }
    @Test func settingsConsentRefusalRevokeAndSingleApprovalAreBoundToSnapshot() async throws {
        let suite = "PicEdit-CloudConsent-\(UUID())", f = try CloudFixture()
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let local = CloudTestLocalProvider()
        let assistant = AIAssistantModel(provider: local, coordinator: AIRequestCoordinator(provider: local), snapshot: { f.request.snapshot }, accept: { _ in true }, sourceReadable: { _ in true })
        let settings = AIProviderSettings(directory: f.directory, defaults: preferences, keychain: f.keychain, local: local, transport: f.transport)
        settings.attach(assistant); settings.setEnabled(true); settings.select(.anthropic)
        try await waitCloud { await MainActor.run { assistant.availability == .available && !assistant.supportsLooks } }
        assistant.prompt = f.request.prompt; assistant.generate()
        try await waitCloud { await MainActor.run { settings.pendingConsent != nil } }
        #expect(f.transport.requests.isEmpty && !assistant.canAccept)
        settings.respondToConsent(false, for: try #require(settings.pendingConsent).id)
        try await waitCloud { await MainActor.run { assistant.state != .generating } }
        #expect(f.transport.requests.isEmpty)
        assistant.generate()
        try await waitCloud { await MainActor.run { settings.pendingConsent != nil } }
        settings.revoke()
        try await waitCloud { await MainActor.run { assistant.state != .generating } }
        #expect(settings.pendingConsent == nil && f.transport.requests.isEmpty)
        try await waitCloud { await MainActor.run { assistant.availability == .available } }
        assistant.generate()
        try await waitCloud { await MainActor.run { settings.pendingConsent != nil } }
        settings.respondToConsent(true, for: try #require(settings.pendingConsent).id)
        try await waitCloud { await MainActor.run { assistant.state == .previewing } }
        #expect(f.transport.requests.count == 1 && assistant.hasAppliedChanges)
        settings.select(.local)
        #expect(!assistant.canAccept && assistant.result == nil)
        try await waitCloud { await MainActor.run { assistant.supportsLooks && assistant.availability == .available } }
        #expect(await f.keychain.readCount == 1)
    }
    @Test(arguments: [true,false]) func lateCloudReplyAfterImageRevisionChangeCannotBecomePreview(_ image: Bool) async throws {
        let f = try CloudFixture(blocked: true, ignoresCancellation: true)
        await f.enable()
        var snapshot = f.request.snapshot
        let assistant = AIAssistantModel(provider: CloudTestLocalProvider(), coordinator: AIRequestCoordinator(provider: CloudTestLocalProvider()), snapshot: { snapshot }, accept: { _ in true }, sourceReadable: { _ in true })
        assistant.replaceProvider(f.provider, authorization: { request in
            let consent = try await f.provider.prepareConsent(for: request); try await f.provider.grant(consent); return true
        })
        try await waitCloud { await MainActor.run { assistant.availability == .available } }
        assistant.prompt = f.request.prompt; assistant.generate()
        try await waitCloud { f.transport.operations.first?.started == true }
        snapshot = AIEditingSnapshot(assetID: image ? "new-image" : snapshot.assetID, source: snapshot.source, settings: image ? .neutral : EditSettings(contrast: 5), token: AIEditingToken(editSessionID: snapshot.token.editSessionID, editGeneration: snapshot.token.editGeneration + 1, selectionSessionID: snapshot.token.selectionSessionID, selectionGeneration: snapshot.token.selectionGeneration))
        assistant.contextDidChange()
        f.transport.operations.first?.complete(.success(.init(statusCode: 200, data: cloudEnvelope())))
        try await waitCloud { (try? await f.usage.summary().chargedNanodollars) == 20_000 }
        #expect(assistant.result == nil && !assistant.canAccept && assistant.state != .previewing)
    }
}
struct CloudTestLocalProvider: AIEditingProvider {
    let id = "test.local"
    let capabilities: AIProviderCapabilities = [.textEditing,.lookSuggestions]
    func availability() async -> AIAvailability { .available }
    func proposal(for request: AIEditingRequest) async throws -> Data {
        try JSONEncoder().encode(EditProposal(changes: [.init(parameter: .contrast, value: 20)]))
    }
}

struct CloudTestFailingLocalProvider: AIEditingProvider {
    let id = "test.failing.local"
    let capabilities: AIProviderCapabilities = [.textEditing]
    func availability() async -> AIAvailability { .available }
    func proposal(for request: AIEditingRequest) async throws -> Data { throw AIEditingError.temporaryModelFailure }
}
