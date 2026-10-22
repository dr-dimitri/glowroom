import Foundation
import Testing
@testable import Glowroom

private struct SkySegDownloadFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-skyseg-download-test-" + UUID().uuidString)
    let data = Data("synthetic skyseg weights".utf8)
    var directory: URL { root.appendingPathComponent("downloaded", isDirectory: true) }
    var file: SemanticManifestFile {
        .init(path: "skyseg.onnx", bytes: Int64(data.count), sha256: SemanticInstallationIO.digest(data))
    }

    func store(payload: Data? = nil) -> SkySegModelDownloadStore {
        SkySegModelDownloadStore(directory: directory, file: file, downloader: { source, destination, maximum, progress in
            #expect(source == SkySegApprovedDownload.url)
            #expect(maximum == file.bytes)
            let bytes = payload ?? data
            try bytes.write(to: destination)
            progress(Int64(bytes.count))
        })
    }

    func expectNoStaging() throws {
        #expect(try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".staging-") })
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Skyseg source download lifecycle", .timeLimit(.minutes(1)))
struct SkySegModelDownloadStoreTests {
    @Test func pinnedDownloadUsesImmutableSourceAndKnownONNXIdentity() {
        #expect(SkySegApprovedDownload.url.scheme == "https")
        #expect(SkySegApprovedDownload.url.host == "huggingface.co")
        #expect(SkySegApprovedDownload.url.path == "/JianyuanWang/skyseg/resolve/3ba8c6df1d9ba9ff26f637c7ba9568ac11a9aa7f/skyseg.onnx")
        #expect(SkySegApprovedDownload.file.path == "skyseg.onnx")
        #expect(SkySegApprovedDownload.file.bytes == 175_997_079)
        #expect(SkySegApprovedDownload.file.sha256 == "ab9c34c64c3d821220a2886a4a06da4642ffa14d5b30e8d5339056a089aa1d39")
    }

    @Test func downloadedFileReopensAndRemovalPreservesUnrelatedGeneration() async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let store = fixture.store()
        #expect(try await store.downloadedFile() == nil)
        let progress = TestStateSignal<(String, Double?)>(("", nil))
        let downloaded = try await store.download { update in
            progress.update { $0 = (update.text, update.fraction) }
        }
        #expect(try Data(contentsOf: downloaded) == fixture.data)
        #expect(try await fixture.store().downloadedFile() == downloaded)
        #expect(progress.value.1 == 1)
        try fixture.expectNoStaging()

        let unrelated = fixture.directory.appendingPathComponent("generations/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let sentinel = unrelated.appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: sentinel)
        try await store.remove()
        #expect(try await store.downloadedFile() == nil)
        #expect(!FileManager.default.fileExists(atPath: downloaded.deletingLastPathComponent().path))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
        try await store.remove() // Removing an already absent download is harmless.
    }

    @Test func verifiedReplacementRemovesOnlyPreviousOwnedFile() async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let first = try await store.download()
        let second = try await store.download()
        #expect(second != first)
        #expect(try await store.downloadedFile() == second)
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: second) == fixture.data)
        try fixture.expectNoStaging()
    }

    @Test(arguments: [false, true])
    func finderMetadataAndUserFilesSurviveRemovalOrReplacement(replacing: Bool) async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let downloaded = try await store.download()
        let generation = downloaded.deletingLastPathComponent()
        let metadata = generation.appendingPathComponent(".DS_Store")
        let sentinel = generation.appendingPathComponent("my-notes.txt")
        let metadataBytes = Data([0, 1, 2, 3, 4])
        let sentinelBytes = Data("preserve user file".utf8)
        try metadataBytes.write(to: metadata)
        try sentinelBytes.write(to: sentinel)
        #expect(try await fixture.store().downloadedFile() == downloaded)

        if replacing {
            let replacement = try await store.download()
            #expect(replacement != downloaded)
            #expect(try await fixture.store().downloadedFile() == replacement)
            #expect(try Data(contentsOf: replacement) == fixture.data)
        } else {
            try await store.remove()
            #expect(try await fixture.store().downloadedFile() == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: downloaded.path))
        #expect(try Data(contentsOf: metadata) == metadataBytes)
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
    }

    @Test func alreadyCancelledRemovalPreservesPointerAndModel() async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let downloaded = try await store.download()
        let pointer = fixture.directory.appendingPathComponent("current.json")
        let previousPointer = try Data(contentsOf: pointer)
        let release = TestAsyncLatch()
        defer { release.releaseAll() }
        let pending = Task {
            await release.wait()
            try await store.remove()
        }
        // The uncancellable latch establishes that cancellation predates the
        // actual actor call, independently of cooperative-pool scheduling.
        pending.cancel()
        release.releaseAll()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try Data(contentsOf: pointer) == previousPointer)
        #expect(try Data(contentsOf: downloaded) == fixture.data)
        #expect(try await fixture.store().downloadedFile() == downloaded)
    }

    @Test(arguments: [false, true])
    func wrongHashOrLengthPreservesPreviousAndCleansStage(wrongLength: Bool) async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let first = try await fixture.store().download()
        let pointer = fixture.directory.appendingPathComponent("current.json")
        let previousPointer = try Data(contentsOf: pointer)
        var wrong = fixture.data
        if wrongLength { wrong.removeLast() } else { wrong[0] ^= 1 }
        await #expect(throws: SkySegDownloadError.invalidDownload) { try await fixture.store(payload: wrong).download() }
        #expect(try await fixture.store().downloadedFile() == first)
        #expect(try Data(contentsOf: first) == fixture.data)
        #expect(try Data(contentsOf: pointer) == previousPointer)
        try fixture.expectNoStaging()
    }

    @Test func interruptedTransferPreservesPreviousAndCleansPartialFile() async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let first = try await fixture.store().download()
        let failing = SkySegModelDownloadStore(directory: fixture.directory, file: fixture.file, downloader: { _, destination, _, _ in
            try Data([1, 2, 3]).write(to: destination)
            throw URLError(.networkConnectionLost)
        })
        await #expect(throws: URLError.self) { try await failing.download() }
        #expect(try await fixture.store().downloadedFile() == first)
        try fixture.expectNoStaging()
    }

    @Test func cancelledTransferRejectsConcurrentMutationAndKeepsPrevious() async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let first = try await fixture.store().download()
        let entered = TestStateSignal(false)
        let release = TestAsyncLatch()
        defer { release.releaseAll() }
        let store = SkySegModelDownloadStore(directory: fixture.directory, file: fixture.file, downloader: { _, destination, _, progress in
            try Data(fixture.data.prefix(3)).write(to: destination)
            entered.update { $0 = true }
            // Deliberately ignore cancellation until the transport returns, so
            // the store must retain its mutation guard and reject publication.
            await release.wait()
            try fixture.data.write(to: destination)
            progress(Int64(fixture.data.count))
        })
        let pending = Task { try await store.download() }
        do {
            try await entered.wait("Skyseg download transport", until: { $0 })
            #expect(try await store.downloadedFile() == first)
            await #expect(throws: SkySegDownloadError.downloadInProgress) { try await store.download() }
            await #expect(throws: SkySegDownloadError.downloadInProgress) { try await store.remove() }
            pending.cancel()
            release.releaseAll()
            await #expect(throws: CancellationError.self) { try await pending.value }
            #expect(try await fixture.store().downloadedFile() == first)
            try fixture.expectNoStaging()
            // A cancelled operation releases its guard for a subsequent retry.
            let retried = try await store.download()
            #expect(try await store.downloadedFile() == retried)
        } catch {
            pending.cancel(); release.releaseAll()
            _ = await pending.result
            throw error
        }
    }

    @Test func alteredDownloadedBytesAreRejectedBeforeRevealOrRemoval() async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let downloaded = try await store.download()
        try Data(repeating: 0, count: fixture.data.count).write(to: downloaded)
        await #expect(throws: SkySegDownloadError.invalidDownload) { try await store.downloadedFile() }
        await #expect(throws: SkySegDownloadError.invalidDownload) { try await store.remove() }
        #expect(FileManager.default.fileExists(atPath: downloaded.path))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("current.json").path))
    }

    @Test func hardLinkedModelIsRejectedAndBothLinksRemainUntouched() async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let downloaded = try await store.download()
        let external = fixture.root.appendingPathComponent("external-model.onnx")
        try FileManager.default.linkItem(at: downloaded, to: external)
        let pointer = fixture.directory.appendingPathComponent("current.json")
        let previousPointer = try Data(contentsOf: pointer)
        await #expect(throws: SkySegDownloadError.invalidDownload) { try await store.downloadedFile() }
        await #expect(throws: SkySegDownloadError.invalidDownload) { try await store.remove() }
        #expect(try Data(contentsOf: pointer) == previousPointer)
        #expect(try Data(contentsOf: downloaded) == fixture.data)
        #expect(try Data(contentsOf: external) == fixture.data)
    }

    @Test(arguments: ["file", "generation", "generations"])
    func symbolicLinksCannotRedirectValidationOrRemoval(component: String) async throws {
        let fixture = SkySegDownloadFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let downloaded = try await store.download()
        let original: URL
        switch component {
        case "file": original = downloaded
        case "generation": original = downloaded.deletingLastPathComponent()
        default: original = fixture.directory.appendingPathComponent("generations")
        }
        let foreign = fixture.root.appendingPathComponent("foreign-" + component)
        try FileManager.default.moveItem(at: original, to: foreign)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: foreign)
        await #expect(throws: SkySegDownloadError.invalidDownload) { try await store.downloadedFile() }
        await #expect(throws: SkySegDownloadError.invalidDownload) { try await store.remove() }
        let foreignFile: URL
        switch component {
        case "file": foreignFile = foreign
        case "generation": foreignFile = foreign.appendingPathComponent("skyseg.onnx")
        default: foreignFile = foreign.appendingPathComponent(downloaded.deletingLastPathComponent().lastPathComponent + "/skyseg.onnx")
        }
        #expect(try Data(contentsOf: foreignFile) == fixture.data)
    }
}

/// Explicitly opt in: this transfers the public 176 MB model and is excluded
/// from ordinary tests and CI. It never reads the private local photographs.
@Suite("Skyseg public download smoke", .timeLimit(.minutes(6)))
struct SkySegModelDownloadSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_SKYSEG_DOWNLOAD_SMOKE"] == "1"))
    func productionDownloaderVerifiesReopensAndRemovesPinnedONNX() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-skyseg-network-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SkySegModelDownloadStore(directory: directory)
        let progress = TestStateSignal<Double?>(nil)
        let downloaded = try await store.download { update in progress.update { $0 = update.fraction } }
        #expect(downloaded.lastPathComponent == "skyseg.onnx")
        #expect(try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(SkySegApprovedDownload.file.bytes))
        #expect(progress.value == 1)
        // Reopening hashes the complete model file with the app-owned pin.
        let reopened = SkySegModelDownloadStore(directory: directory)
        #expect(try await reopened.downloadedFile() == downloaded)
        try await reopened.remove()
        #expect(try await store.downloadedFile() == nil)
        #expect(!FileManager.default.fileExists(atPath: downloaded.deletingLastPathComponent().path))
    }
}
