import Foundation
import Testing
@testable import Glowroom

@Suite("Direct LaMa download and installation", .timeLimit(.minutes(1)))
struct DevelopRepairAIModelDownloadStoreTests {
    @Test func immutableDownloadMatchesEvaluatedPackage() {
        #expect(DevelopRepairAIApprovedDownload.baseURL.absoluteString == "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/5ed76e3799ab4cad31381750d29880c267477e18/LaMa.mlpackage/")
        #expect(DevelopRepairAIApprovedDownload.files.count == 3)
        #expect(DevelopRepairAIApprovedDownload.totalBytes == 216_647_386)
        #expect(DevelopRepairAIApprovedDownload.files.first { $0.path.hasSuffix("weight.bin") }?.sha256 == "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184")
    }

    @Test func verifiedPackageInstallsWithoutRequiringLocalFileSelection() async throws {
        let fixture = try RepairAIDownloadFixture(); defer { fixture.remove() }
        let progress = TestStateSignal<[Double]>([])
        let installed = try await fixture.store().downloadAndInstall { update in
            if update.text == "LaMa wird heruntergeladen …", let fraction = update.fraction {
                progress.update { $0.append(fraction) }
            }
        }
        #expect(installed.displayName == "LaMa")
        #expect(try await fixture.runtime.installedModel() == installed)
        #expect(try DevelopRepairAIModelStore.verifyInstallation(installed).count == 2)
        #expect(progress.value.first == 0)
        #expect(progress.value.last == 1)
        #expect(progress.value == progress.value.sorted())
        try fixture.expectNoStaging()
    }

    @Test func downloadsOverlapWithAtMostTwoTransfers() async throws {
        let fixture = try RepairAIDownloadFixture(); defer { fixture.remove() }
        let state = TestStateSignal((active: 0, peak: 0, completed: 0))
        let gate = TestAsyncLatch(); defer { gate.releaseAll() }
        let store = fixture.store(downloader: { source, destination, maximum, progress in
            state.update { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            defer { state.update { $0.active -= 1; $0.completed += 1 } }
            await gate.wait()
            try Task.checkCancellation()
            try fixture.write(source: source, destination: destination, maximum: maximum, progress: progress)
        })
        let pending = Task { try await store.downloadAndInstall() }
        do {
            try await state.wait("two concurrent LaMa transfers", until: { $0.active == 2 })
            #expect(state.value.completed == 0)
            gate.releaseAll()
            _ = try await pending.value
            #expect(state.value.peak == 2)
            #expect(state.value.completed == 3)
        } catch {
            pending.cancel(); gate.releaseAll(); _ = await pending.result
            throw error
        }
    }

    @Test(arguments: [false, true])
    func corruptOrTruncatedDownloadKeepsPreviousModelAndCleansStage(truncated: Bool) async throws {
        let fixture = try RepairAIDownloadFixture(); defer { fixture.remove() }
        let previous = try await fixture.store().downloadAndInstall()
        let pointer = fixture.runtimeDirectory.appendingPathComponent("current.json")
        let previousPointer = try Data(contentsOf: pointer)
        let store = fixture.store(downloader: { source, destination, maximum, progress in
            try fixture.write(source: source, destination: destination, maximum: maximum, progress: progress)
            if destination.lastPathComponent == "weight.bin" {
                var data = try Data(contentsOf: destination)
                if truncated { data.removeLast() } else { data[0] ^= 1 }
                try data.write(to: destination)
            }
        })
        await #expect(throws: DevelopRepairAIDownloadError.invalidDownload) { try await store.downloadAndInstall() }
        #expect(try await fixture.runtime.installedModel() == previous)
        #expect(try Data(contentsOf: pointer) == previousPointer)
        #expect(try DevelopRepairAIModelStore.verifyInstallation(previous).count == 2)
        try fixture.expectNoStaging()
    }

    @Test func failedTransferOrNativeImportDoesNotReplacePreviousModel() async throws {
        let fixture = try RepairAIDownloadFixture(); defer { fixture.remove() }
        let previous = try await fixture.store().downloadAndInstall()
        let failedTransfer = fixture.store(downloader: { _, destination, _, _ in
            try Data([1, 2, 3]).write(to: destination)
            throw URLError(.networkConnectionLost)
        })
        await #expect(throws: URLError.self) { try await failedTransfer.downloadAndInstall() }
        #expect(try await fixture.runtime.installedModel() == previous)
        try fixture.expectNoStaging()
        let failedImport = fixture.store(importer: { _ in throw DevelopRepairAIError.invalidModel })
        await #expect(throws: DevelopRepairAIError.invalidModel) { try await failedImport.downloadAndInstall() }
        #expect(try await fixture.runtime.installedModel() == previous)
        try fixture.expectNoStaging()
    }

    @Test func cancellationWaitsForTransportAndRejectsConcurrentSetup() async throws {
        let fixture = try RepairAIDownloadFixture(); defer { fixture.remove() }
        let previous = try await fixture.store().downloadAndInstall()
        let entered = TestStateSignal(false), imported = TestStateSignal(false)
        let gate = TestAsyncLatch(); defer { gate.releaseAll() }
        let store = fixture.store(downloader: { source, destination, maximum, progress in
            try Data([0]).write(to: destination)
            entered.update { $0 = true }
            await gate.wait() // Native transport deliberately ignores cancellation.
            try fixture.write(source: source, destination: destination, maximum: maximum, progress: progress)
        }, importer: { package in
            imported.update { $0 = true }
            return try await fixture.runtime.importModel(from: package)
        })
        let pending = Task { try await store.downloadAndInstall() }
        do {
            try await entered.wait("LaMa transfer entered", until: { $0 })
            pending.cancel()
            await #expect(throws: DevelopRepairAIDownloadError.downloadInProgress) { try await store.downloadAndInstall() }
            gate.releaseAll()
            await #expect(throws: CancellationError.self) { try await pending.value }
            #expect(!imported.value)
            #expect(try await fixture.runtime.installedModel() == previous)
            try fixture.expectNoStaging()
            _ = try await store.downloadAndInstall() // The completed cancellation releases the guard.
        } catch {
            pending.cancel(); gate.releaseAll(); _ = await pending.result
            throw error
        }
    }

    @Test func cancellationAfterAtomicImportStillReturnsCommittedInstallation() async throws {
        let fixture = try RepairAIDownloadFixture(); defer { fixture.remove() }
        let committed = TestStateSignal(false), gate = TestAsyncLatch()
        defer { gate.releaseAll() }
        let store = fixture.store(importer: { package in
            let installation = try await fixture.runtime.importModel(from: package)
            committed.update { $0 = true }
            await gate.wait()
            return installation
        })
        let pending = Task { try await store.downloadAndInstall() }
        do {
            try await committed.wait("LaMa installation committed", until: { $0 })
            pending.cancel(); gate.releaseAll()
            let installed = try await pending.value
            #expect(try await fixture.runtime.installedModel() == installed)
            try fixture.expectNoStaging()
        } catch {
            pending.cancel(); gate.releaseAll(); _ = await pending.result
            throw error
        }
    }
}

private struct RepairAIDownloadFixture: Sendable {
    let root: URL
    let runtime: DevelopRepairAIModelStore
    var downloadDirectory: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    var runtimeDirectory: URL { root.appendingPathComponent("Runtime", isDirectory: true) }
    let payloads = ["Manifest.json": Data("synthetic manifest".utf8),
        "Data/com.apple.CoreML/model.mlmodel": Data("synthetic graph".utf8),
        "Data/com.apple.CoreML/weights/weight.bin": Data("synthetic weights".utf8)]
    var files: [SemanticManifestFile] {
        payloads.map { .init(path: $0.key, bytes: Int64($0.value.count), sha256: SemanticInstallationIO.digest($0.value)) }
            .sorted { $0.path < $1.path }
    }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-RepairAI-Download-" + UUID().uuidString)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        runtime = DevelopRepairAIModelStore(directory: root.appendingPathComponent("Runtime"), budget: AIResourceBudget(),
            compiler: { _ in
                let compiled = root.appendingPathComponent("Compiled-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: false)
                try Data("synthetic native weights".utf8).write(to: compiled.appendingPathComponent("weights.bin"))
                return compiled
            }, validator: { _ in })
    }

    func store(downloader: DevelopRepairAIModelDownloadStore.Downloader? = nil,
               importer: DevelopRepairAIModelDownloadStore.Importer? = nil) -> DevelopRepairAIModelDownloadStore {
        DevelopRepairAIModelDownloadStore(directory: downloadDirectory, files: files,
            downloader: downloader ?? { source, destination, maximum, progress in
                try write(source: source, destination: destination, maximum: maximum, progress: progress)
            }, importer: importer ?? { try await runtime.importModel(from: $0) })
    }

    func write(source: URL, destination: URL, maximum: Int64, progress: @Sendable (Int64) -> Void) throws {
        #expect(source.scheme == "https" && source.host == "huggingface.co")
        let relative = try #require(payloads.keys.first { source.path.hasSuffix("/" + $0) })
        let data = try #require(payloads[relative])
        #expect(maximum == Int64(data.count))
        try data.write(to: destination)
        progress(Int64(data.count)); progress(0) // A stale transport update must not move progress backward.
    }

    func expectNoStaging() throws {
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloadDirectory.path).isEmpty)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Explicit opt-in transfers the public model and compiles/loads the real Core
/// ML interface. It uses private temporary stores and never reads user photos.
@Suite("LaMa public download and native setup smoke", .timeLimit(.minutes(6)))
struct DevelopRepairAIModelDownloadSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_TEST_LAMA_DOWNLOAD"] == "1"))
    func productionDownloadCompilesAndInstallsPinnedCoreMLPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-LaMa-Network-Smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DevelopRepairAIModelStore(directory: root.appendingPathComponent("Runtime"), budget: AIResourceBudget())
        let download = DevelopRepairAIModelDownloadStore(directory: root.appendingPathComponent("Downloads"),
            importer: { try await runtime.importModel(from: $0) })
        let progress = TestStateSignal<Double?>(nil)
        let installation = try await download.downloadAndInstall { value in progress.update { $0 = value.fraction } }
        #expect(installation.displayName == "LaMa")
        #expect(try await runtime.installedModel() == installation)
        #expect(try !DevelopRepairAIModelStore.verifyInstallation(installation).isEmpty)
        #expect(progress.value == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Downloads").path).isEmpty)
    }
}
