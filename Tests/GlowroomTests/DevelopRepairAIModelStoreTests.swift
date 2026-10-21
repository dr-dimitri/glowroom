import Foundation
import Testing
@testable import Glowroom

@Suite("Imported local repair model store")
struct DevelopRepairAIModelStoreTests {
    @Test
    func importPublishesPrivateVerifiedRuntimeAndNeverMutatesSource() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let sourceBytes = try Data(contentsOf: fixture.package.appendingPathComponent("model.mlmodel"))
        let installation = try await fixture.store.importModel(from: fixture.package)
        #expect(installation.displayName == "MyRepair")
        #expect(SemanticInstallationIO.validHash(installation.identity))
        #expect(try await fixture.store.installedModel() == installation)
        #expect(try Data(contentsOf: fixture.package.appendingPathComponent("model.mlmodel")) == sourceBytes)
        #expect(!installation.directory.path.hasPrefix(fixture.package.path))
        #expect(try DevelopRepairAIModelStore.verifyInstallation(installation).count == 2)

        try Data("changed source".utf8).write(to: fixture.package.appendingPathComponent("model.mlmodel"))
        #expect(try await fixture.store.installedModel() == installation)
        #expect(try DevelopRepairAIModelStore.verifyInstallation(installation).count == 2)
        try await fixture.store.remove()
        #expect(try await fixture.store.installedModel() == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.package.path))
    }

    @Test
    func sameSizeRuntimeCorruptionIsRejectedBeforeModelUse() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let installed = try await fixture.store.importModel(from: fixture.package)
        let runtime = installed.directory.appendingPathComponent("model.mlmodelc/weights.bin")
        let count = try Data(contentsOf: runtime).count
        try Data(repeating: 90, count: count).write(to: runtime)
        #expect(throws: DevelopRepairAIError.invalidModel) { try DevelopRepairAIModelStore.verifyInstallation(installed) }
    }

    @Test
    func invalidReplacementLeavesPreviousInstallationAndRemovesOnlyOwnStage() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let previous = try await fixture.store.importModel(from: fixture.package)
        let invalid = fixture.root.appendingPathComponent("Bad.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        try Data("not a package".utf8).write(to: invalid.appendingPathComponent("readme.txt"))
        await #expect(throws: DevelopRepairAIError.invalidModel) { try await fixture.store.importModel(from: invalid) }
        #expect(try await fixture.store.installedModel() == previous)
        #expect(FileManager.default.fileExists(atPath: invalid.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(!contents.contains { $0.hasPrefix(".staging-") })
    }

    @Test(arguments: [false, true])
    func linkedSourceFilesAreRejectedWithoutPublication(hardLink: Bool) async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let graph = fixture.package.appendingPathComponent("model.mlmodel")
        let outside = fixture.root.appendingPathComponent("outside.bin")
        try Data("outside bytes".utf8).write(to: outside)
        try FileManager.default.removeItem(at: graph)
        if hardLink { try FileManager.default.linkItem(at: outside, to: graph) }
        else { try FileManager.default.createSymbolicLink(at: graph, withDestinationURL: outside) }
        await #expect(throws: DevelopRepairAIError.invalidModel) { try await fixture.store.importModel(from: fixture.package) }
        #expect(try await fixture.store.installedModel() == nil)
        #expect(try Data(contentsOf: outside) == Data("outside bytes".utf8))
    }

    @Test
    func incompatibleNativeInterfaceCannotReplaceAnInstalledModel() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let previous = try await fixture.store.importModel(from: fixture.package)
        let rejected = DevelopRepairAIModelStore(directory: fixture.directory, budget: AIResourceBudget(),
            compiler: { try RepairAIStoreFixture.compile($0) }, validator: { _ in throw DevelopRepairAIError.invalidModel })
        await #expect(throws: DevelopRepairAIError.invalidModel) { try await rejected.importModel(from: fixture.package) }
        #expect(try await rejected.installedModel() == previous)
    }

    @Test
    func canceledCompilerRetainsAdmissionUntilNativeReturnAndDoesNotPublish() async throws {
        let fixture = try RepairAIStoreFixture()
        defer { fixture.remove() }
        let entered = TestStateSignal(false), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let budget = AIResourceBudget()
        let store = DevelopRepairAIModelStore(directory: fixture.directory, budget: budget, compiler: { package in
            entered.update { $0 = true }
            gate.wait()
            return try RepairAIStoreFixture.compile(package)
        }, validator: { _ in })
        let task = Task { try await store.importModel(from: fixture.package) }
        try await entered.wait("repair model compiler entered", until: { $0 })
        task.cancel()
        var updates = await budget.stateUpdates().makeAsyncIterator()
        let busy = await updates.next()
        #expect(busy?.activeInferences == 1)
        #expect(busy?.residentModelBytes == DevelopRepairAIService.residentBytes)
        gate.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.installedModel() == nil)
        var finalUpdates = await budget.stateUpdates().makeAsyncIterator()
        let finalState = await finalUpdates.next()
        #expect(finalState?.activeInferences == 0)
    }
}

struct RepairAIStoreFixture: Sendable {
    let root: URL
    let package: URL
    let directory: URL
    let store: DevelopRepairAIModelStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-RepairAI-Store-" + UUID().uuidString, isDirectory: true)
        package = root.appendingPathComponent("MyRepair.mlpackage", isDirectory: true)
        directory = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("synthetic manifest".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        try Data("synthetic graph".utf8).write(to: package.appendingPathComponent("model.mlmodel"))
        store = DevelopRepairAIModelStore(directory: directory, budget: AIResourceBudget(), compiler: { try Self.compile($0) }, validator: { _ in })
    }

    static func compile(_ package: URL) throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-RepairAI-Compiled-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try Data("synthetic native weights".utf8).write(to: output.appendingPathComponent("weights.bin"))
        return output
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
