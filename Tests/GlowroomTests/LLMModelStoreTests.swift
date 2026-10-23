import Foundation
import Testing
@testable import Glowroom

private struct LLMStoreFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-llm-test-" + UUID().uuidString)
    let contents = ["model.safetensors": Data("synthetic weights".utf8), "config.json": Data("{}".utf8), "tokenizer.json": Data("tokenizer".utf8)]
    var descriptor: LLMModelDescriptor {
        LLMModelDescriptor(id: "test", name: "Test", repository: "test/model", revision: String(repeating: "a", count: 40), files:
            contents.sorted { $0.key < $1.key }.map { .init(path: $0.key, bytes: Int64($0.value.count), sha256: SemanticInstallationIO.digest($0.value)) })
    }
    func store(downloader: LLMModelStore.Downloader? = nil, capacity: Int64 = 100_000_000) -> LLMModelStore {
        LLMModelStore(directory: root, descriptor: descriptor, downloader: downloader ?? { source, target, maximum, progress in
            let data = contents[source.lastPathComponent]!
            #expect(maximum == data.count)
            #expect(source.path.contains("/resolve/" + descriptor.revision + "/"))
            try data.write(to: target)
            progress(Int64(data.count))
        }, capacity: { _ in capacity })
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func expectNoStages() throws {
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".staging-") })
    }
}

@Suite("Local LLM model lifecycle", .timeLimit(.minutes(1)))
struct LLMModelStoreTests {
    @Test func immutableQwenManifestIncludesFullRuntimeData() {
        let model = LLMModelDescriptor.qwen35
        #expect(model.downloadBytes == 3_061_129_077)
        #expect(model.files.count == 10)
        #expect(model.files.contains { $0.path == "tokenizer_config.json" })
        #expect(model.files.contains { $0.path == "preprocessor_config.json" })
        #expect(model.downloadURL(for: model.files[0]).path.contains("/resolve/0e7ffd5c629ef7719d4cbc04069232580bfa9d9c/"))
    }

    @Test func downloadReopensReportsActualBytesAndDeletesOnlyOwnedFiles() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let store = f.store()
        #expect(try await store.installation() == nil)
        #expect(try await store.diskUsage() == 0)
        let progress = TestStateSignal<Int64>(0)
        let installed = try await store.download { p in progress.update { $0 = p.downloadedBytes } }
        #expect(progress.value == f.descriptor.downloadBytes)
        #expect(installed.installedBytes == f.descriptor.downloadBytes)
        #expect(try await f.store().installation() == installed)
        #expect(try await store.diskUsage() == f.descriptor.downloadBytes)
        let unrelated = installed.directory.appendingPathComponent("my-notes.txt")
        try Data("preserve".utf8).write(to: unrelated)
        try await store.remove()
        #expect(try await store.installation() == nil)
        #expect(try await store.diskUsage() == 0)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "preserve")
        for name in f.contents.keys { #expect(!FileManager.default.fileExists(atPath: installed.directory.appendingPathComponent(name).path)) }
        try await store.remove()
        try f.expectNoStages()
    }

    @Test func replacementFailurePreservesPreviousInstallation() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let previous = try await f.store().download()
        let bad = f.store(downloader: { _, target, maximum, _ in try Data(repeating: 0, count: Int(maximum)).write(to: target) })
        await #expect(throws: LLMModelError.invalidDownload) { try await bad.download() }
        #expect(try await f.store().installation() == previous)
        try f.expectNoStages()
        let replacement = try await f.store().download()
        #expect(replacement != previous)
        #expect(!FileManager.default.fileExists(atPath: previous.directory.path))
    }

    @Test func damagedWeightsAreRejectedButRemainRemovable() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let store = f.store()
        let installed = try await store.download()
        _ = try await store.installation() // Populate verified stamp cache.
        let weights = installed.directory.appendingPathComponent("model.safetensors")
        try Data("broken".utf8).write(to: weights)
        await #expect(throws: LLMModelError.invalidInstallation) { try await store.installation() }
        #expect(try await store.diskUsage() < f.descriptor.downloadBytes)
        try await store.remove()
        #expect(try await store.installation() == nil)
    }

    @Test func symlinkedWeightCannotBeLoadedAndRemovalPreservesTarget() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let store = f.store()
        let model = try await store.download()
        let weights = model.directory.appendingPathComponent("model.safetensors")
        let foreign = f.root.appendingPathComponent("foreign")
        try FileManager.default.moveItem(at: weights, to: foreign)
        try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: foreign)
        await #expect(throws: LLMModelError.invalidInstallation) { try await store.installation() }
        try await store.remove()
        #expect(try Data(contentsOf: foreign) == f.contents["model.safetensors"])
    }

    @Test func damagedPointerStillAllowsExplicitRemovalOfReceiptedPayload() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let store = f.store()
        let model = try await store.download()
        try Data("invalid json".utf8).write(to: f.root.appendingPathComponent("current.json"))
        await #expect(throws: LLMModelError.invalidInstallation) { try await store.installation() }
        #expect(try await store.diskUsage() == f.descriptor.downloadBytes)
        try await store.remove()
        #expect(try await store.installation() == nil)
        #expect(!FileManager.default.fileExists(atPath: model.directory.path))
    }

    @Test func extraModelShardCannotBypassPinnedManifest() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let store = f.store()
        let model = try await store.download()
        _ = try await store.installation()
        let injected = model.directory.appendingPathComponent("extra.safetensors")
        try Data("unapproved".utf8).write(to: injected)
        await #expect(throws: LLMModelError.invalidInstallation) { try await store.installation() }
        try await store.remove()
        #expect(try String(contentsOf: injected, encoding: .utf8) == "unapproved")
    }

    @Test func insufficientSpaceDoesNotStartNetwork() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let invoked = TestStateSignal(false)
        let store = f.store(downloader: { _, _, _, _ in invoked.update { $0 = true } }, capacity: 0)
        await #expect(throws: LLMModelError.insufficientDiskSpace) { try await store.download() }
        #expect(!invoked.value)
        #expect(try await store.installation() == nil)
        try f.expectNoStages()
    }

    @Test func inferenceRetainsLeaseAfterCancellationUntilNativeWorkReturns() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let store = f.store()
        let installed = try await store.download()
        let entered = TestStateSignal(false)
        let release = TestAsyncLatch(); defer { release.releaseAll() }
        let work = Task {
            try await store.withModel { model in
                #expect(model == installed)
                entered.update { $0 = true }
                await release.wait() // Deliberately model an uncancellable native call.
                return 7
            }
        }
        try await entered.wait("LLM acquired", until: { $0 })
        work.cancel()
        await #expect(throws: LLMModelError.modelInUse) { try await store.remove() }
        await #expect(throws: LLMModelError.modelInUse) { try await store.download() }
        await #expect(throws: LLMModelError.modelInUse) { try await f.store().remove() }
        release.releaseAll()
        #expect(try await work.value == 7)
        try await store.remove()
    }

    @Test func cancellationKeepsPreviousAndLimitsTransfersToTwo() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let previous = try await f.store().download()
        let active = TestStateSignal(0)
        let release = TestAsyncLatch(); defer { release.releaseAll() }
        let store = f.store(downloader: { source, destination, _, _ in
            active.update { $0 += 1 }
            await release.wait()
            try f.contents[source.lastPathComponent]!.write(to: destination)
        })
        let work = Task { try await store.download() }
        try await active.wait("Two overlapping model transfers", until: { $0 == 2 })
        #expect(active.value == 2)
        await #expect(throws: LLMModelError.operationInProgress) { try await store.remove() }
        work.cancel(); release.releaseAll()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try await f.store().installation() == previous)
        try f.expectNoStages()
    }

    @Test func startupReapsAbandonedPartialDownloadAndPreservesUnknownFiles() async throws {
        let f = LLMStoreFixture(); defer { f.clean() }
        let store = f.store()
        let installed = try await store.download()
        let stage = f.root.appendingPathComponent(".staging-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stage.appendingPathComponent("model.safetensors"))
        let notes = stage.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: notes)
        #expect(try await f.store().installation() == installed)
        #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("model.safetensors").path))
        #expect(try String(contentsOf: notes, encoding: .utf8) == "keep")
    }
}
