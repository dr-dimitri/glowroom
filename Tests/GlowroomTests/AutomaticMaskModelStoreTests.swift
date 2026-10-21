import Foundation
import Testing
@testable import Glowroom

private struct SkyModelStoreFixture: Sendable {
    let root: URL
    let directory: URL
    let data: [String: Data]
    let files: [SemanticManifestFile]
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-sky-install-test-" + UUID().uuidString)
        directory = root.appendingPathComponent("installed")
        data = ["Manifest.json": Data("synthetic manifest".utf8), "Data/com.apple.CoreML/model.mlmodel": Data("synthetic graph".utf8),
                "Data/com.apple.CoreML/weights/weight.bin": Data("synthetic weights".utf8)]
        files = data.sorted { $0.key < $1.key }.map { .init(path: $0.key, bytes: Int64($0.value.count), sha256: SemanticInstallationIO.digest($0.value)) }
    }
    func store(corrupt: Bool = false, compiler: SkyMaskModelStore.Compiler? = nil,
               asyncCompiler: SkyMaskModelStore.AsyncCompiler? = nil, budget: AIResourceBudget = AIResourceBudget()) -> SkyMaskModelStore {
        SkyMaskModelStore(directory: directory, files: files, budget: budget, downloader: { url, destination, maximum, progress in
            let file = try #require(files.first { url.path.hasSuffix($0.path) })
            var bytes = try #require(data[file.path])
            if corrupt { bytes[0] ^= 1 }
            #expect(maximum == file.bytes)
            try bytes.write(to: destination)
            progress(Int64(bytes.count))
        }, compiler: compiler ?? { _ in
            let out = root.appendingPathComponent("compiled-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data("synthetic compiled weights".utf8).write(to: out.appendingPathComponent("model.bin"))
            return out
        }, asyncCompiler: asyncCompiler)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Sky mask model lifecycle", .timeLimit(.minutes(1)))
struct AutomaticMaskModelStoreTests {
    @Test func setupReopensVerifiesAndRemovesOnlyOwnedGeneration() async throws {
        let fixture = try SkyModelStoreFixture(); defer { fixture.clean() }
        let store = fixture.store()
        #expect(try await store.installedModel() == nil)
        let installed = try await store.install()
        let reopened = try await fixture.store().installedModel()
        #expect(reopened == installed)
        #expect(try SkyMaskModelStore.verifyInstallation(installed).count == 2)
        let unknown = fixture.directory.appendingPathComponent("generations/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let sentinel = unknown.appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: sentinel)
        try await store.remove()
        #expect(try await store.installedModel() == nil)
        #expect(!FileManager.default.fileExists(atPath: installed.directory.path))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
    }

    @Test func badDownloadedHashPreservesExistingModelAndCleansStaging() async throws {
        let fixture = try SkyModelStoreFixture(); defer { fixture.clean() }
        let first = try await fixture.store().install()
        await #expect(throws: AutomaticMaskError.invalidModel) { try await fixture.store(corrupt: true).install() }
        let preserved = try await fixture.store().installedModel()
        #expect(preserved == first)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasPrefix(".staging-") })
    }

    @Test func changedCompiledBytesAndSymlinkAreRejectedBeforeInference() async throws {
        let fixture = try SkyModelStoreFixture(); defer { fixture.clean() }
        let installed = try await fixture.store().install()
        let file = installed.directory.appendingPathComponent("model.mlmodelc/model.bin")
        let original = try Data(contentsOf: file)
        try Data(repeating: 0, count: original.count).write(to: file)
        #expect(throws: AutomaticMaskError.invalidModel) { try SkyMaskModelStore.verifyInstallation(installed) }
        try FileManager.default.removeItem(at: file)
        let external = fixture.root.appendingPathComponent("external-model.bin")
        try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        #expect(throws: AutomaticMaskError.invalidModel) { try SkyMaskModelStore.verifyInstallation(installed) }
        #expect(try Data(contentsOf: external) == original)
    }

    @Test func generationsSymlinkCannotRedirectVerificationOrRemoval() async throws {
        let fixture = try SkyModelStoreFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let installed = try await store.install()
        let generations = fixture.directory.appendingPathComponent("generations")
        let foreign = fixture.root.appendingPathComponent("foreign-generations")
        try FileManager.default.moveItem(at: generations, to: foreign)
        try FileManager.default.createSymbolicLink(at: generations, withDestinationURL: foreign)
        await #expect(throws: AutomaticMaskError.invalidModel) { try await store.installedModel() }
        #expect(throws: AutomaticMaskError.invalidModel) { try SkyMaskModelStore.verifyInstallation(installed) }
        await #expect(throws: AutomaticMaskError.invalidModel) { try await store.remove() }
        #expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent(installed.directory.lastPathComponent).path))
    }

    @Test func canceledNativeCompileCannotPublishReplacement() async throws {
        let fixture = try SkyModelStoreFixture(); defer { fixture.clean() }
        let original = try await fixture.store().install()
        let entered = TestStateSignal(false), returned = TestStateSignal(false)
        let release = TestAsyncLatch(), budget = AIResourceBudget()
        defer { release.releaseAll() }
        let store = fixture.store(asyncCompiler: { _ in
            entered.update { $0 = true }
            await release.wait() // Native compiler ignores cancellation until actual return.
            defer { returned.update { $0 = true } }
            let out = fixture.root.appendingPathComponent("cancelled-compiled")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: out.appendingPathComponent("model.bin"))
            return out
        }, budget: budget)
        let pending = Task { try await store.install() }
        do {
            try await entered.wait("native compiler", until: { $0 })
            try await waitForTestState("sky compiler held at native-return latch", state: { release.waitingCount }) { $0 == 1 }
            pending.cancel()
            #expect(!returned.value)
            var updates = await budget.stateUpdates().makeAsyncIterator()
            let busy = await updates.next()
            #expect(busy?.activeInferences == 1)
            #expect(busy?.residentModelBytes == SkyMaskModelStore.maximumInstalledBytes)
            await #expect(throws: AutomaticMaskError.setupInProgress) { try await store.remove() }
            release.releaseAll()
            await #expect(throws: CancellationError.self) { try await pending.value }
            #expect(returned.value)
            let preserved = try await fixture.store().installedModel()
            #expect(preserved == original)
            var finalUpdates = await budget.stateUpdates().makeAsyncIterator()
            let finalState = await finalUpdates.next()
            #expect(finalState?.activeInferences == 0)
            #expect(finalState?.residentModelBytes == 0)
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("cancelled-compiled").path))
            #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasPrefix(".staging-") })
        } catch {
            pending.cancel(); release.releaseAll()
            _ = await pending.result
            throw error
        }
        release.releaseAll()
        _ = await pending.result
    }
}
