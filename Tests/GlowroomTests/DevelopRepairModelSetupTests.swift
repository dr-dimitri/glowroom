import Foundation
import Testing
@testable import Glowroom

@Suite("Repair model setup lifecycle")
@MainActor
struct DevelopRepairModelSetupTests {
    @Test func successfulDownloadPublishesProgressAndEnablesRemovalOnce() async throws {
        let entered = TestStateSignal(0), gate = TestAsyncLatch()
        let installed = installation()
        let workspace = makeWorkspace { progress in
            entered.update { $0 += 1 }
            progress(.init(text: "Gewichte werden geladen", fraction: 0.25))
            await gate.wait()
            return installed
        }
        defer { gate.releaseAll(); workspace.clear() }
        workspace.repairMode = .heal
        workspace.downloadRepairAIModel()
        let operation = try #require(workspace.repairTask)
        workspace.downloadRepairAIModel()
        try await entered.wait("repair model download entered", until: { $0 == 1 })
        try await waitUntil("repair model progress published") { workspace.repairAISetupProgress?.fraction == 0.25 }
        #expect(workspace.repairBusy && !workspace.repairAIReady)
        gate.releaseAll(); await operation.value

        #expect(entered.value == 1)
        #expect(workspace.repairAIReady && workspace.repairUsesAI)
        #expect(workspace.repairAIModelName == installed.displayName)
        #expect(workspace.repairMode == .remove)
        #expect(workspace.repairStatus?.contains("heruntergeladen und eingerichtet") == true)
        #expect(workspace.repairAISetupProgress == nil)
        #expect(!workspace.repairBusy && workspace.repairTask == nil)
        #expect(workspace.errorMessage == nil)
    }

    @Test func failedDownloadKeepsPreviouslyAvailableModelAndReportsFailure() async throws {
        let workspace = makeWorkspace { _ in throw RepairModelSetupFailure.offline }
        defer { workspace.clear() }
        workspace.repairAIReady = true
        workspace.repairAIModelName = "Vorhandenes Modell"
        workspace.repairUsesAI = true
        workspace.repairMode = .remove
        workspace.downloadRepairAIModel()
        await (try #require(workspace.repairTask)).value

        #expect(workspace.repairAIReady && workspace.repairUsesAI)
        #expect(workspace.repairAIModelName == "Vorhandenes Modell")
        #expect(workspace.errorMessage == RepairModelSetupFailure.offline.localizedDescription)
        #expect(workspace.repairAISetupProgress == nil)
        #expect(!workspace.repairBusy && workspace.repairTask == nil)
    }

    @Test(arguments: RepairModelSetupCancellation.allCases)
    func publishedModelReturningAfterCancellationCannotReactivatePhotoOperation(_ cancellation: RepairModelSetupCancellation) async throws {
        let entered = TestStateSignal(false), gate = TestAsyncLatch()
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let installed = try await fixture.store.importModel(from: fixture.package)
        let workspace = makeWorkspace(store: fixture.store) { progress in
            progress(.init(text: "Erster Fortschritt", fraction: 0.2))
            entered.update { $0 = true }
            await gate.wait() // Native publication may win a cancellation race.
            progress(.init(text: "Verspäteter Fortschritt", fraction: 1))
            return installed
        }
        defer { gate.releaseAll(); workspace.clear() }
        workspace.downloadRepairAIModel()
        let operation = try #require(workspace.repairTask)
        try await entered.wait("repair model held before publication", until: { $0 })
        switch cancellation {
        case .cancel: workspace.cancelRepairWork()
        case .close: workspace.closeRepair()
        case .photoChange: workspace.clear()
        case .modeChange: workspace.selectRepairMode(.redEye)
        }
        workspace.repairMode = .clone
        workspace.errorMessage = "Hinweis der neueren Aktion"
        gate.releaseAll(); await operation.value

        #expect(workspace.repairAIReady)
        #expect(workspace.repairAIModelName == installed.displayName)
        #expect(!workspace.repairUsesAI && workspace.repairMode == .clone)
        #expect(workspace.repairStatus == nil)
        #expect(workspace.repairAISetupProgress == nil)
        #expect(!workspace.repairBusy && workspace.repairTask == nil)
        #expect(workspace.errorMessage == "Hinweis der neueren Aktion")
        if cancellation == .modeChange { #expect(workspace.tool == .redEye) }
        else if cancellation != .cancel { #expect(workspace.tool == .basic) }
    }

    @Test func canceledDownloadCannotReplaceMetadataFromANewerManualImport() async throws {
        let entered = TestStateSignal(false), gate = TestAsyncLatch()
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let previous = try await fixture.store.importModel(from: fixture.package)
        let workspace = makeWorkspace(store: fixture.store) { progress in
            entered.update { $0 = true }
            await gate.wait()
            progress(.init(text: "Verspäteter Downloadabschluss", fraction: 1))
            return previous
        }
        defer { gate.releaseAll(); workspace.clear() }
        workspace.downloadRepairAIModel()
        let operation = try #require(workspace.repairTask)
        try await entered.wait("old download held after native publication", until: { $0 })
        workspace.cancelRepairWork()

        let newerPackage = fixture.root.appendingPathComponent("NewerRepair.mlpackage", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.package, to: newerPackage)
        await workspace.importRepairAIModel(from: newerPackage)
        let newer = try #require(try await fixture.store.installedModel())
        #expect(newer.displayName == "NewerRepair" && newer.identity != previous.identity)
        #expect(workspace.repairAIModelName == newer.displayName)
        let newerStatus = workspace.repairStatus
        workspace.repairMode = .clone
        gate.releaseAll(); await operation.value

        #expect(try await fixture.store.installedModel() == newer)
        #expect(workspace.repairAIReady && workspace.repairUsesAI)
        #expect(workspace.repairAIModelName == newer.displayName)
        #expect(workspace.repairMode == .clone && workspace.repairStatus == newerStatus)
        #expect(workspace.errorMessage == nil)
        #expect(!workspace.repairBusy && workspace.repairAISetupProgress == nil)
    }

    @Test func errorReturningAfterCancellationCannotOverwriteNewerStatus() async throws {
        let entered = TestStateSignal(false), gate = TestAsyncLatch()
        let workspace = makeWorkspace { _ in
            entered.update { $0 = true }
            await gate.wait()
            throw RepairModelSetupFailure.offline
        }
        defer { gate.releaseAll(); workspace.clear() }
        workspace.downloadRepairAIModel()
        let operation = try #require(workspace.repairTask)
        try await entered.wait("repair model held before failure", until: { $0 })
        workspace.cancelRepairWork()
        workspace.errorMessage = "Neuere Aktion"
        gate.releaseAll(); await operation.value

        #expect(workspace.errorMessage == "Neuere Aktion")
        #expect(!workspace.repairAIReady && !workspace.repairUsesAI)
        #expect(!workspace.repairBusy && workspace.repairAISetupProgress == nil)
    }

    @Test func downloadRequiresRepairTool() {
        let workspace = makeWorkspace { _ in throw RepairModelSetupFailure.offline }
        defer { workspace.clear() }
        workspace.tool = .basic
        workspace.downloadRepairAIModel()
        #expect(workspace.repairTask == nil && !workspace.repairBusy)
        #expect(workspace.repairAISetupProgress == nil && workspace.errorMessage == nil)
    }

    private func makeWorkspace(store: DevelopRepairAIModelStore? = nil,
        download: @escaping @Sendable (@escaping @Sendable (SkyMaskSetupProgress) -> Void) async throws -> DevelopRepairAIInstallation) -> DevelopWorkspace {
        var services = DevelopRepairServices.live
        services.downloadModel = download
        let workspace = DevelopWorkspace(repairServices: services,
            repairAIStore: store ?? DevelopRepairAIModelStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("glowroom-repair-setup-test-" + UUID().uuidString)))
        workspace.tool = .repair
        return workspace
    }

    private func installation() -> DevelopRepairAIInstallation {
        .init(directory: URL(fileURLWithPath: "/tmp/glowroom-repair-setup-synthetic"),
            displayName: "LaMa-Test", identity: String(repeating: "a", count: 64))
    }

    private func waitUntil(_ operation: String, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: operation, lastState: "model setup has not published")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

enum RepairModelSetupCancellation: CaseIterable, Sendable { case cancel, close, photoChange, modeChange }
private enum RepairModelSetupFailure: Error, LocalizedError {
    case offline
    var errorDescription: String? { "Testdownload ist offline." }
}
