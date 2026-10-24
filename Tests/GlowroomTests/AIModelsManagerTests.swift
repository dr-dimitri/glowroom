import Foundation
import Testing
@testable import Glowroom

@Suite("Central model manager lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct AIModelsManagerTests {
    @Test
    func inspectionDoesNotDownloadAndCanceledProgressCannotOverwriteRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-ModelManager-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DevelopRepairAIModelStore(directory: root, budget: AIResourceBudget(),
            compiler: { $0 }, validator: { _ in })
        let gate = TestAsyncLatch()
        defer { gate.releaseAll() }
        let attempts = TestStateSignal(0)
        let callbacks = TestStateSignal<[@Sendable (SkyMaskSetupProgress) -> Void]>([])
        let installed = DevelopRepairAIInstallation(directory: root.appendingPathComponent("synthetic"),
            displayName: "Controlled test model", identity: String(repeating: "a", count: 64))
        let model = RepairModelManagerModel(store: store, download: { progress in
            attempts.update { $0 += 1 }
            callbacks.update { $0.append(progress) }
            if attempts.value == 1 {
                await gate.wait()
                try Task.checkCancellation()
            } else if attempts.value == 2 {
                throw DevelopRepairAIDownloadError.invalidDownload
            }
            return installed
        })
        model.refresh()
        try await waitForTestState("read-only model inspection", state: { await MainActor.run { model.isBusy } }, until: { !$0 })
        #expect(attempts.value == 0)
        #expect(model.installation == nil)
        model.download()
        try await waitForTestState("download entered", state: { attempts.value }, until: { $0 == 1 })
        callbacks.value[0](.init(text: "Controlled download", fraction: 0.25))
        try await waitForTestState("progress visible", state: { await MainActor.run { model.progress?.text } }, until: { $0 == "Controlled download" })
        model.cancel(); gate.releaseAll()
        try await waitForTestState("canceled download finished", state: { await MainActor.run { model.isBusy } }, until: { !$0 })
        #expect(model.installation == nil && model.errorMessage == nil && model.progress == nil)
        model.download()
        try await waitForTestState("failed retry finished", state: { await MainActor.run { model.isBusy } }, until: { !$0 })
        #expect(model.errorMessage == DevelopRepairAIDownloadError.invalidDownload.localizedDescription)
        model.download()
        try await waitForTestState("successful retry finished", state: { await MainActor.run { model.isBusy } }, until: { !$0 })
        #expect(attempts.value == 3 && model.installation == installed && model.errorMessage == nil)
        callbacks.value[0](.init(text: "Outdated progress", fraction: 0.75))
        await Task.yield()
        #expect(model.progress?.text == "Reparaturmodell ist bereit.")
    }
}
