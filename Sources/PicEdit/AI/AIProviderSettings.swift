import Combine
import Foundation
import PicEditCore

/// Nonsecret preferences only. Authorization and the secure entry field are
/// ephemeral; a saved configuration is never an upload grant.
@MainActor
final class AIProviderSettings: ObservableObject {
    enum Selection: String, CaseIterable, Identifiable {
        case local, anthropic
        var id: Self { self }
        var label: String { self == .local ? "Lokal · Apple" : "Cloud · Anthropic" }
    }
    @Published private(set) var selection: Selection
    @Published private(set) var enabled: Bool
    @Published var requestLimit: Int
    @Published var budgetDollars: Int
    @Published var workspaceInput: String
    @Published private(set) var workspaceID: String?
    @Published var keyInput = ""
    @Published private(set) var keyBusy = false
    @Published private(set) var message: String?
    @Published private(set) var pendingConsent: AICloudConsent?
    @Published private(set) var keyStorageDescription = "Der lokale macOS-Keychain wird beim ersten Schlüsselzugriff verwendet."
    @Published private(set) var usageText = "Noch keine Nutzungsabfrage."
    let keychain: any AICloudKeychain
    let cloud: CloudAIProvider?
    private let local: any AIEditingProvider
    private let defaults: UserDefaults
    private weak var assistant: AIAssistantModel?
    private struct ConsentWaiter {
        let consentID: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var consentWaiter: ConsentWaiter?
    private var configurationID = UUID()
    private var configurationRevision: UInt64 = 0

    init(directory: URL, defaults: UserDefaults = .standard,
         keychain: any AICloudKeychain = SystemAICloudKeychain(),
         local: any AIEditingProvider = LocalAIEditingProviderFactory.makeAssistantProvider(),
         transport: any CloudHTTPTransport = BoundedCloudHTTPTransport()) {
        self.defaults = defaults; self.keychain = keychain; self.local = local
        let savedWorkspace = defaults.string(forKey: "ai.cloud.workspaceID") ?? ""
        workspaceInput = savedWorkspace
        workspaceID = savedWorkspace.isEmpty ? nil : savedWorkspace
        enabled = defaults.bool(forKey: "ai.cloud.enabled")
        selection = Selection(rawValue: defaults.string(forKey: "ai.provider.selection") ?? "") ?? .local
        requestLimit = defaults.object(forKey: "ai.cloud.requestLimit") == nil ? 50 : min(10_000, max(1, defaults.integer(forKey: "ai.cloud.requestLimit")))
        budgetDollars = defaults.object(forKey: "ai.cloud.budgetUSD") == nil ? 5 : min(1_000, max(1, defaults.integer(forKey: "ai.cloud.budgetUSD")))
        if let usage = try? CloudUsageStore(url: directory.appendingPathComponent("cloud-usage.sqlite")) {
            cloud = CloudAIProvider(keychain: keychain, usage: usage, transport: transport)
        } else { cloud = nil; message = AICloudError.persistence.localizedDescription }
    }
    func attach(_ assistant: AIAssistantModel) {
        self.assistant = assistant
        apply()
    }
    func select(_ selection: Selection) {
        self.selection = selection
        defaults.set(selection.rawValue, forKey: "ai.provider.selection")
        apply()
    }
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: "ai.cloud.enabled")
        apply()
    }
    func saveWorkspace() {
        do {
            let value = try AICloudWorkspaceID.normalized(workspaceInput)
            workspaceInput = value ?? ""
            guard value != workspaceID else { return }
            workspaceID = value
            defaults.set(value, forKey: "ai.cloud.workspaceID")
            apply()
            message = value == nil ? "Workspace-ID entfernt. Verwende einen auf einen Workspace beschränkten Schlüssel." : "Workspace-ID gespeichert; bisherige Freigaben wurden verworfen."
        } catch { message = AICloudError.invalidWorkspace.localizedDescription }
    }

    func saveLimits() {
        requestLimit = min(10_000, max(1, requestLimit)); budgetDollars = min(1_000, max(1, budgetDollars))
        defaults.set(requestLimit, forKey: "ai.cloud.requestLimit")
        defaults.set(budgetDollars, forKey: "ai.cloud.budgetUSD")
        apply()
    }
    private func invalidate() {
        configurationID = UUID()
        configurationRevision += 1
        cancelPendingConsent()
        assistant?.suspendProvider()
    }
    private func apply() {
        invalidate()
        let expected = configurationID, revision = configurationRevision
        let enabled = enabled, limit = requestLimit, budget = Int64(budgetDollars) * 1_000_000_000
        let workspaceID = workspaceID
        // Remove old capabilities and availability synchronously while the
        // actor changes configuration. No old proposal survives this boundary.
        assistant?.suspendProvider()
        Task { [weak self] in
            guard let self, self.configurationID == expected else { return }
            await self.cloud?.updateConfiguration(enabled: enabled, requestLimit: limit, monthlyBudgetNanodollars: budget, workspaceID: workspaceID, revision: revision)
            guard self.configurationID == expected else { return }
            self.bindSelectedProvider()
            await self.refreshUsage()
        }
    }
    private func bindSelectedProvider() {
        guard !keyBusy || selection == .local else { return }
        if selection == .anthropic, let cloud {
            assistant?.replaceProvider(cloud, authorization: { [weak self] request in
                guard let self else { return false }
                return try await self.authorize(request)
            })
        } else if selection == .local {
            assistant?.replaceProvider(local)
        } else { message = AICloudError.persistence.localizedDescription }
    }
    func revoke() {
        invalidate()
        let expected = configurationID, revision = configurationRevision
        Task { [weak self] in
            guard let self, self.configurationID == expected else { return }
            await self.cloud?.revoke(revision: revision)
            guard self.configurationID == expected else { return }
            self.bindSelectedProvider()
            self.message = "Freigaben widerrufen. Bereits versandte Aufträge können Kosten verursacht haben."
            await self.refreshUsage()
        }
    }
    func saveKey() {
        guard !keyBusy else { return }
        let key = keyInput
        keyInput = ""
        keyBusy = true
        invalidate()
        let revision = configurationRevision
        Task { [weak self] in
            guard let self else { return }
            await self.cloud?.revoke(revision: revision)
            do { try await self.keychain.save(key); self.message = "Schlüssel im macOS-Keychain gespeichert bzw. ersetzt." }
            catch { self.message = (error as? AICloudError)?.localizedDescription ?? AICloudError.keychain.localizedDescription }
            self.keyBusy = false
            self.apply()
        }
    }
    func deleteKey() {
        guard !keyBusy else { return }
        keyInput = ""; keyBusy = true
        invalidate()
        let revision = configurationRevision
        Task { [weak self] in
            guard let self else { return }
            await self.cloud?.revoke(revision: revision)
            do { try await self.keychain.delete(); self.message = "Anthropic-Schlüssel aus dem Keychain gelöscht." }
            catch { self.message = AICloudError.keychain.localizedDescription }
            self.keyBusy = false
            self.apply()
        }
    }
    private func authorize(_ request: AIEditingRequest) async throws -> Bool {
        guard selection == .anthropic, enabled, !keyBusy, let cloud else { throw AICloudError.disabled }
        let expected = configurationID
        let consent = try await cloud.prepareConsent(for: request)
        guard expected == configurationID, !Task.isCancelled else { throw CancellationError() }
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else {
                    // Cancellation delivery can lag behind a new request. Retire
                    // the old observer before replacing the single waiter slot.
                    cancelPendingConsent()
                    consentWaiter = ConsentWaiter(consentID: consent.id, continuation: continuation)
                    pendingConsent = consent
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.respondToConsent(false, for: consent.id)
            }
        }
        guard allowed, expected == configurationID, !Task.isCancelled else {
            await cloud.withdraw(consent)
            return false
        }
        try await cloud.grant(consent)
        guard expected == configurationID, !Task.isCancelled else { await cloud.withdraw(consent); return false }
        return true
    }
    func respondToConsent(_ allowed: Bool, for consentID: UUID) {
        // A dismissed sheet can still deliver an action after a newer request
        // became pending. Its immutable presentation ID must match the waiter.
        guard let waiter = consentWaiter, waiter.consentID == consentID else { return }
        consentWaiter = nil; pendingConsent = nil
        waiter.continuation.resume(returning: allowed)
    }
    private func cancelPendingConsent() {
        guard let consentID = consentWaiter?.consentID else { return }
        respondToConsent(false, for: consentID)
    }
    func refreshUsage() async {
        keyStorageDescription = await keychain.storageDescription()
        guard let cloud else { return }
        do {
            let summary = try await cloud.usage.summary()
            usageText = "UTC-Monat: \(summary.requestCount) Aufträge, \(summary.inputTokens) Input- und \(summary.outputTokens) Outputtokens. Modellpreis inkl. Vormerkungen: \(String(format: "%.9f", Double(summary.chargedNanodollars) / 1_000_000_000)) USD; \(summary.uncertainCount) Kostenstände ungewiss."
        } catch { usageText = AICloudError.persistence.localizedDescription }
    }
}
