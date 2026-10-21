import Foundation
import Testing
@testable import Glowroom
import GlowroomCore

private final class SemanticCompilerControl: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocks = false
    func blockNext() { lock.lock(); blocks = true; lock.unlock() }
    // Deliberately block only the detached test worker, never an async caller.
    func waitUntilEntered() -> DispatchTimeoutResult { entered.wait(timeout: .now() + 10) }
    func compile(_ url: URL) throws -> URL {
        lock.lock(); let shouldBlock = blocks; blocks = false; lock.unlock()
        if shouldBlock { entered.signal(); proceed.wait() }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-fake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        try Data(url.lastPathComponent.utf8).write(to: out.appendingPathComponent("model.bin"))
        return out
    }
}

private struct SemanticInstallFixture {
    let root: URL
    let source: URL
    let directory: URL
    let manifest: SemanticPackageManifest
    let control = SemanticCompilerControl()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-install-test-" + UUID().uuidString)
        source = root.appendingPathComponent("source")
        directory = root.appendingPathComponent("installed")
        let names = ["models/text.mlpackage/model.bin", "models/image.mlpackage/model.bin",
                     "tokenizer/tokenizer.json", "licenses/LICENSE.txt"]
        var files: [SemanticManifestFile] = []
        for name in names {
            let data = Data(("trusted synthetic " + name).utf8)
            let url = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            files.append(.init(path: name, bytes: Int64(data.count), sha256: SemanticInstallationIO.digest(data)))
        }
        manifest = .init(schemaVersion: 1, descriptor: SemanticLocalProviderFactory.descriptor, files: files)
        try SemanticInstallationIO.json(manifest).write(to: source.appendingPathComponent("manifest.json"))
    }
    func installer(capacity: Int64 = .max) -> SemanticModelInstaller {
        SemanticModelInstaller(directory: directory, approved: manifest, compiler: { [control] in try control.compile($0) },
                               capacity: { _ in capacity })
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Semantic model installation", .serialized)
struct SemanticModelInstallerTests {
    @Test func verifiesImportsReopensAndDeletesOnlyModel() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let installer = fixture.installer()
        #expect(try await installer.installedModel() == nil)
        let review = try await installer.inspect(source: fixture.source)
        #expect(review.descriptor == fixture.manifest.descriptor)
        #expect(review.licenseTexts.count == 1)
        #expect(review.sourceBytes > 0 && review.stagingBytesRequired == 3_221_225_472)
        let model = try await installer.install(review)
        #expect(model.installedBytes > 0 && model.installedBytes <= review.maximumInstalledBytes)
        #expect(try await fixture.installer().installedModel() == model)
        #expect(!FileManager.default.fileExists(atPath: model.directory.appendingPathComponent("models").path))
        #expect(FileManager.default.fileExists(atPath: model.directory.appendingPathComponent("text.mlmodelc/model.bin").path))
        try await installer.remove()
        #expect(try await installer.installedModel() == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("manifest.json").path))
    }

    @Test func tamperingAndSelfDeclaredManifestsAreRejected() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let installer = fixture.installer()
        let file = fixture.source.appendingPathComponent("tokenizer/tokenizer.json")
        let original = try Data(contentsOf: file)
        try Data(repeating: 0, count: original.count).write(to: file)
        await #expect(throws: SemanticEmbeddingError.invalidInstallation) { try await installer.inspect(source: fixture.source) }
        let modified = SemanticPackageManifest(schemaVersion: 1, descriptor: fixture.manifest.descriptor,
                                               files: fixture.manifest.files.map {
            $0.path == "tokenizer/tokenizer.json" ? .init(path: $0.path, bytes: $0.bytes,
                sha256: SemanticInstallationIO.digest(Data(repeating: 0, count: original.count))) : $0
        })
        try SemanticInstallationIO.json(modified).write(to: fixture.source.appendingPathComponent("manifest.json"))
        await #expect(throws: SemanticEmbeddingError.invalidInstallation) { try await installer.inspect(source: fixture.source) }
    }

    @Test func extraCheckpointLinksAndTraversalAreRejected() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let installer = fixture.installer()
        let extra = fixture.source.appendingPathComponent("model.safetensors")
        try Data([1]).write(to: extra)
        await #expect(throws: SemanticEmbeddingError.invalidInstallation) { try await installer.inspect(source: fixture.source) }
        try FileManager.default.removeItem(at: extra)
        let file = fixture.source.appendingPathComponent("tokenizer/tokenizer.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.source.appendingPathComponent("manifest.json"))
        await #expect(throws: SemanticEmbeddingError.invalidInstallation) { try await installer.inspect(source: fixture.source) }
        for path in ["../weights", "/weights", "a//b", "a/./b", "a\\b", "a\0b"] {
            let bad = SemanticPackageManifest(schemaVersion: 1, descriptor: fixture.manifest.descriptor,
                files: [.init(path: path, bytes: 1, sha256: String(repeating: "a", count: 64))])
            #expect(throws: SemanticEmbeddingError.invalidInstallation) { try bad.validate() }
        }
    }

    @Test func sourceHardlinksAreRejectedWithoutChangingTheirTargets() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let source = fixture.source.appendingPathComponent("tokenizer/tokenizer.json")
        let foreign = fixture.root.appendingPathComponent("foreign-original.json")
        let original = try Data(contentsOf: source)
        try FileManager.default.linkItem(at: source, to: foreign)
        await #expect(throws: SemanticEmbeddingError.invalidInstallation) {
            try await fixture.installer().inspect(source: fixture.source)
        }
        #expect(try Data(contentsOf: foreign) == original)
    }

    @Test func compilerCacheHardlinksBecomePrivateRuntimeFiles() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let foreign = fixture.root.appendingPathComponent("compiler-cache.bin")
        let original = Data("trusted synthetic compiled bytes".utf8)
        try original.write(to: foreign)
        let installer = SemanticModelInstaller(directory: fixture.directory, approved: fixture.manifest, compiler: { _ in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-linked-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try FileManager.default.linkItem(at: foreign, to: output.appendingPathComponent("model.bin"))
            return output
        }, capacity: { _ in Int64.max })
        let review = try await installer.inspect(source: fixture.source)
        let model = try await installer.install(review)
        let runtime = model.directory.appendingPathComponent("text.mlmodelc/model.bin")
        #expect(try Data(contentsOf: runtime) == original)
        _ = try SemanticInstallationIO.stamp(runtime) // Strictly requires nlink == 1.
        try await installer.remove()
        #expect(try Data(contentsOf: foreign) == original)
    }

    @Test func changedReviewOrDiskShortagePreservesPreviousGeneration() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let installer = fixture.installer()
        let review = try await installer.inspect(source: fixture.source)
        let first = try await installer.install(review)
        await #expect(throws: SemanticEmbeddingError.insufficientDiskSpace) { try await fixture.installer(capacity: 1).install(review) }
        #expect(try await installer.installedModel() == first)
        try Data([1]).write(to: fixture.source.appendingPathComponent("tokenizer/tokenizer.json"))
        await #expect(throws: SemanticEmbeddingError.invalidInstallation) { try await installer.install(review) }
        #expect(try await installer.installedModel() == first)
    }

    @Test func cancellationDuringNoncooperativeCompilePreservesPreviousModel() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let installer = fixture.installer()
        let review = try await installer.inspect(source: fixture.source)
        let first = try await installer.install(review)
        fixture.control.blockNext()
        let task = Task { try await installer.install(review) }
        let entered = await Task.detached { fixture.control.waitUntilEntered() }.value
        #expect(entered == .success)
        task.cancel()
        fixture.control.proceed.signal()
        do { _ = try await task.value; Issue.record("Cancelled compile unexpectedly published") }
        catch { #expect(error is CancellationError) }
        #expect(try await installer.installedModel() == first)
        let folders = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(!folders.contains { $0.hasPrefix(".staging-") })
    }

    @Test func unrelatedUUIDGenerationIsNeverRemoved() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let unknown = fixture.directory.appendingPathComponent("generations/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let sentinel = unknown.appendingPathComponent("user-original.txt")
        try Data("keep me".utf8).write(to: sentinel)
        let installer = fixture.installer()
        let review = try await installer.inspect(source: fixture.source)
        _ = try await installer.install(review)
        _ = try await installer.install(review)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep me")
        try await installer.remove()
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep me")
    }

    @Test func mutationOfEarlierVerifiedFileIsRejectedAfterWholeTreeVerification() throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let files = fixture.manifest.files
        let first = fixture.source.appendingPathComponent(files[0].path)
        let firstBytes = try Data(contentsOf: first)
        #expect(throws: SemanticEmbeddingError.installationChanged) {
            try SemanticInstallationIO.verifiedTree(fixture.source,
                files: files + [.init(path: "manifest.json",
                    bytes: Int64(try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json")).count),
                    sha256: SemanticInstallationIO.digest(try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json"))))]) { url in
                if url.lastPathComponent == "tokenizer.json" {
                    try firstBytes.write(to: first, options: .atomic)
                }
            }
        }
    }

    @Test func boundedMetadataReadRejectsOversizedRegularFiles() throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let file = fixture.source.appendingPathComponent("oversized.json")
        try Data(repeating: 65, count: 129).write(to: file)
        #expect(throws: SemanticEmbeddingError.invalidInstallation) { try SemanticInstallationIO.read(file, limit: 128) }
    }

    @Test func explicitReimportRepairsMetadataAndPreservesUnvalidatedGeneration() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let installer = fixture.installer()
        let review = try await installer.inspect(source: fixture.source)
        let first = try await installer.install(review)
        let broken = first.directory.appendingPathComponent("installation.json")
        try Data("{}".utf8).write(to: broken)
        let second = try await installer.install(review)
        #expect(second.directory != first.directory)
        #expect(try await installer.installedModel() == second)
        #expect(try String(contentsOf: broken, encoding: .utf8) == "{}")
    }

    @Test func pointerAliasesNeverModifyForeignTargetOrUnknownGeneration() async throws {
        for symlink in [false, true] {
            let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
            let unknown = fixture.directory.appendingPathComponent("generations/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
            let sentinel = unknown.appendingPathComponent("original.txt")
            let original = Data("foreign original bytes".utf8)
            try original.write(to: sentinel)
            let pointer = fixture.directory.appendingPathComponent("current.json")
            if symlink { try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: sentinel) }
            else { try FileManager.default.linkItem(at: sentinel, to: pointer) }
            let installer = fixture.installer()
            let review = try await installer.inspect(source: fixture.source)
            let installed = try await installer.install(review)
            #expect(try Data(contentsOf: sentinel) == original)
            try FileManager.default.removeItem(at: pointer)
            if symlink { try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: sentinel) }
            else { try FileManager.default.linkItem(at: sentinel, to: pointer) }
            try await installer.remove()
            #expect(try Data(contentsOf: sentinel) == original)
            #expect(FileManager.default.fileExists(atPath: installed.directory.path))
            #expect(FileManager.default.fileExists(atPath: unknown.path))
        }
    }

    @Test func cancellationAfterPublicationStillReturnsCommittedGeneration() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let installer = fixture.installer()
        let review = try await installer.inspect(source: fixture.source)
        _ = try await installer.install(review)
        let task = Task {
            try await installer.install(review, progress: { value in
                if value.phase == .publishing && value.completedBytes == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        let committed = try await task.value
        #expect(try await installer.installedModel() == committed)
    }

    @Test func modifiedInstallationMetadataFailsClosedOnReopen() async throws {
        let fixture = try SemanticInstallFixture(); defer { fixture.clean() }
        let installer = fixture.installer()
        let review = try await installer.inspect(source: fixture.source)
        let first = try await installer.install(review)
        try Data("{}".utf8).write(to: first.directory.appendingPathComponent("installation.json"))
        await #expect(throws: SemanticEmbeddingError.installationChanged) { try await installer.installedModel() }
    }
}
