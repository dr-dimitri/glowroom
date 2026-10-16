import Foundation
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

@Suite("Cloud consent presentation identity", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AIProviderSettingsTests {
    @Test(arguments: [false, true])
    func delayedAnswerFromPreviousSheetCannotAnswerNewConsent(_ oldAnswer: Bool) async throws {
        let fixture = try CloudFixture()
        let suite = "PicEdit-ConsentIdentity-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let local = CloudTestLocalProvider()
        let assistant = AIAssistantModel(provider: local, coordinator: AIRequestCoordinator(provider: local),
            snapshot: { fixture.request.snapshot }, accept: { _ in true }, sourceReadable: { _ in true })
        let settings = AIProviderSettings(directory: fixture.directory, defaults: preferences,
            keychain: fixture.keychain, local: local, transport: fixture.transport)
        settings.attach(assistant)
        settings.setEnabled(true)
        settings.select(.anthropic)
        try await waitCloud { assistant.availability == .available && !assistant.supportsLooks }

        assistant.prompt = "Erhöhe nur den Kontrast auf 7."
        assistant.generate()
        try await waitCloud { settings.pendingConsent != nil }
        let oldConsent = try #require(settings.pendingConsent)
        let oldPresentation = AICloudConsentPresentation(settings: settings, consent: oldConsent)
        let oldBinding = oldPresentation.binding
        #expect(oldBinding.wrappedValue == oldConsent)
        assistant.discard()
        try await waitCloud { settings.pendingConsent == nil }

        assistant.prompt = "Erhöhe nur den Kontrast auf 9."
        assistant.generate()
        try await waitCloud { settings.pendingConsent != nil }
        let newConsent = try #require(settings.pendingConsent)
        #expect(newConsent.id != oldConsent.id && newConsent.requestID != oldConsent.requestID)
        #expect(oldBinding.wrappedValue == nil)
        oldPresentation.answer(oldAnswer)
        #expect(settings.pendingConsent == newConsent)
        #expect(assistant.state == .generating)
        #expect(fixture.transport.requests.isEmpty)
        #expect(await fixture.keychain.readCount == 0)

        let newPresentation = AICloudConsentPresentation(settings: settings, consent: newConsent)
        newPresentation.answer(true)
        try await waitCloud { assistant.state == .previewing }
        #expect(fixture.transport.requests.count == 1)
        #expect(await fixture.keychain.readCount == 1)
        let body = try #require(fixture.transport.requests.first?.httpBody)
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(envelope["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let prompt = try #require(content.first?["text"] as? String)
        #expect(prompt.contains("Kontrast auf 9") && !prompt.contains("Kontrast auf 7"))
    }

    @Test
    func delayedNilSetterCannotDismissNewConsentButItsOwnDismissalCan() async throws {
        let fixture = try CloudFixture()
        let suite = "PicEdit-ConsentDismissal-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let local = CloudTestLocalProvider()
        let assistant = AIAssistantModel(provider: local, coordinator: AIRequestCoordinator(provider: local),
            snapshot: { fixture.request.snapshot }, accept: { _ in true }, sourceReadable: { _ in true })
        let settings = AIProviderSettings(directory: fixture.directory, defaults: preferences,
            keychain: fixture.keychain, local: local, transport: fixture.transport)
        settings.attach(assistant)
        settings.setEnabled(true)
        settings.select(.anthropic)
        try await waitCloud { assistant.availability == .available && !assistant.supportsLooks }
        assistant.prompt = fixture.request.prompt
        assistant.generate()
        try await waitCloud { settings.pendingConsent != nil }
        let oldConsent = try #require(settings.pendingConsent)
        let oldBinding = AICloudConsentPresentation(settings: settings, consent: oldConsent).binding

        // Provider policy invalidates A, then the new request installs B. The
        // retained binding models SwiftUI delivering A's dismissal afterward.
        settings.revoke()
        try await waitCloud { settings.pendingConsent == nil && assistant.availability == .available }
        assistant.generate()
        try await waitCloud { settings.pendingConsent != nil }
        let newConsent = try #require(settings.pendingConsent)
        #expect(newConsent.id != oldConsent.id)
        oldBinding.wrappedValue = nil
        #expect(settings.pendingConsent == newConsent)
        #expect(assistant.state == .generating)
        #expect(fixture.transport.requests.isEmpty)

        let newBinding = AICloudConsentPresentation(settings: settings, consent: newConsent).binding
        newBinding.wrappedValue = nil
        #expect(settings.pendingConsent == nil)
        try await waitCloud { assistant.state != .generating }
        #expect(fixture.transport.requests.isEmpty)
        #expect(await fixture.keychain.readCount == 0)
    }
}
