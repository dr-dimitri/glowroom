import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

private struct SubjectMattingStoreFixture: Sendable {
    let root: URL
    let directory: URL
    let source: URL
    let files: [SemanticManifestFile]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-subject-install-test-" + UUID().uuidString)
        directory = root.appendingPathComponent("installed")
        source = root.appendingPathComponent("Subject.mlpackage")
        let data = ["Manifest.json": Data("synthetic package manifest".utf8),
                    "Data/com.apple.CoreML/model.mlmodel": Data("synthetic matting graph".utf8),
                    "Data/com.apple.CoreML/weights/weight.bin": Data("synthetic matting weights".utf8)]
        files = data.sorted { $0.key < $1.key }.map {
            .init(path: $0.key, bytes: Int64($0.value.count), sha256: SemanticInstallationIO.digest($0.value))
        }
        for (path, bytes) in data {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
    }

    func store(budget: AIResourceBudget = AIResourceBudget(),
               sourceValidator: SubjectMattingModelStore.SourceValidator? = nil,
               compiler: SubjectMattingModelStore.Compiler? = nil,
               asyncCompiler: SubjectMattingModelStore.AsyncCompiler? = nil,
               validator: @escaping SubjectMattingModelStore.Validator = { _ in },
               sourceClassifier: @escaping SubjectMattingModelStore.SourceClassifier = { _ in .current }) -> SubjectMattingModelStore {
        SubjectMattingModelStore(directory: directory, budget: budget, sourceValidator: sourceValidator ?? { _ in files },
            compiler: compiler ?? { _ in
                let out = root.appendingPathComponent("compiled-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try Data("synthetic compiled matting weights".utf8).write(to: out.appendingPathComponent("model.bin"))
                return out
            }, validator: validator, sourceClassifier: sourceClassifier, asyncCompiler: asyncCompiler)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct SubjectMattingUpgradeFixture: Sendable {
    let previous: SubjectMattingStoreFixture
    let source: URL
    let files: [SemanticManifestFile]

    init() throws {
        previous = try SubjectMattingStoreFixture()
        source = previous.root.appendingPathComponent("Current.mlpackage")
        try FileManager.default.copyItem(at: previous.source, to: source)
        try Data("updated synthetic matting graph".utf8).write(
            to: source.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"))
        files = try SemanticInstallationIO.inventory(source, maximumBytes: SubjectMattingModelStore.maximumInstalledBytes)
    }

    func store(compiler: SubjectMattingModelStore.Compiler? = nil,
               asyncCompiler: SubjectMattingModelStore.AsyncCompiler? = nil,
               validator: @escaping SubjectMattingModelStore.Validator = { _ in },
               recognizesLegacy: Bool = true) -> SubjectMattingModelStore {
        previous.store(sourceValidator: { _ in files }, compiler: compiler, asyncCompiler: asyncCompiler, validator: validator,
            sourceClassifier: { candidate in
                if Set(candidate) == Set(files) { return .current }
                if recognizesLegacy, Set(candidate) == Set(previous.files) { return .legacy }
                throw SubjectMattingError.invalidModel
            })
    }
}

@Suite("Subject matting model lifecycle", .timeLimit(.minutes(1)))
struct SubjectMattingModelStoreTests {
    @Test func knownLegacyInstallationRequiresUpdateAndRemainsRemovable() async throws {
        let fixture = try SubjectMattingUpgradeFixture(); defer { fixture.previous.clean() }
        let previous = try await fixture.previous.store().install(from: fixture.previous.source)
        let store = fixture.store()
        let pointer = fixture.previous.directory.appendingPathComponent("current.json")
        let originalPointer = try Data(contentsOf: pointer)
        await #expect(throws: SubjectMattingError.updateRequired) { try await store.installedModel() }
        #expect(try Data(contentsOf: pointer) == originalPointer)
        #expect(try SubjectMattingModelStore.verifyInstallation(previous).count == 2)
        try await store.remove()
        #expect(try await store.installedModel() == nil)
        #expect(!FileManager.default.fileExists(atPath: previous.directory.path))
        #expect(FileManager.default.fileExists(atPath: fixture.previous.source.path))
    }

    @Test func successfulUpgradePublishesCurrentBeforeRemovingVerifiedLegacy() async throws {
        let fixture = try SubjectMattingUpgradeFixture(); defer { fixture.previous.clean() }
        let previous = try await fixture.previous.store().install(from: fixture.previous.source)
        let store = fixture.store()
        let installed = try await store.install(from: fixture.source)
        #expect(try await store.installedModel() == installed)
        #expect(installed.directory != previous.directory)
        #expect(!FileManager.default.fileExists(atPath: previous.directory.path))
        #expect(try SubjectMattingModelStore.verifyInstallation(installed).count == 2)
    }

    @Test func failedUpgradeKeepsLegacyPointerAndPrivateFiles() async throws {
        let fixture = try SubjectMattingUpgradeFixture(); defer { fixture.previous.clean() }
        let previous = try await fixture.previous.store().install(from: fixture.previous.source)
        let pointer = fixture.previous.directory.appendingPathComponent("current.json")
        let originalPointer = try Data(contentsOf: pointer)
        let store = fixture.store(validator: { _ in throw SubjectMattingError.invalidModel })
        await #expect(throws: SubjectMattingError.invalidModel) { try await store.install(from: fixture.source) }
        #expect(try Data(contentsOf: pointer) == originalPointer)
        #expect(try SubjectMattingModelStore.verifyInstallation(previous).count == 2)
        await #expect(throws: SubjectMattingError.updateRequired) { try await store.installedModel() }
    }

    @Test func canceledUpgradeCannotPublishOrDeleteLegacy() async throws {
        let fixture = try SubjectMattingUpgradeFixture(); defer { fixture.previous.clean() }
        let previous = try await fixture.previous.store().install(from: fixture.previous.source)
        let pointer = fixture.previous.directory.appendingPathComponent("current.json")
        let originalPointer = try Data(contentsOf: pointer)
        let entered = TestStateSignal(false)
        let release = TestAsyncLatch()
        defer { release.releaseAll() }
        let store = fixture.store(asyncCompiler: { _ in
            entered.update { $0 = true }
            await release.wait()
            let output = fixture.previous.root.appendingPathComponent("cancelled-upgrade")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try Data("compiled replacement".utf8).write(to: output.appendingPathComponent("model.bin"))
            return output
        })
        let pending = Task { try await store.install(from: fixture.source) }
        do {
            try await entered.wait("legacy replacement compiler", until: { $0 })
            pending.cancel(); release.releaseAll()
            do { _ = try await pending.value; Issue.record("Canceled upgrade was published") }
            catch { #expect(error is CancellationError) }
            #expect(try Data(contentsOf: pointer) == originalPointer)
            #expect(try SubjectMattingModelStore.verifyInstallation(previous).count == 2)
            await #expect(throws: SubjectMattingError.updateRequired) { try await store.installedModel() }
            #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.previous.directory.path).contains { $0.hasPrefix(".staging-") })
        } catch {
            // A failed prerequisite/assertion must not race fixture removal
            // against a still-running, cancellation-ignoring native compiler.
            pending.cancel()
            release.releaseAll()
            _ = await pending.result
            throw error
        }
    }

    @Test func unknownAndMutatedLegacyGenerationsAreNeverRemovedDuringUpgrade() async throws {
        for mutated in [false, true] {
            let fixture = try SubjectMattingUpgradeFixture(); defer { fixture.previous.clean() }
            let previous = try await fixture.previous.store().install(from: fixture.previous.source)
            let model = previous.directory.appendingPathComponent("model.mlmodelc/model.bin")
            if mutated {
                let size = try Data(contentsOf: model).count
                try Data(repeating: 0, count: size).write(to: model)
            }
            let preservedBytes = try Data(contentsOf: model)
            let pointer = fixture.previous.directory.appendingPathComponent("current.json")
            let originalPointer = try Data(contentsOf: pointer)
            let store = fixture.store(recognizesLegacy: mutated)
            await #expect(throws: SubjectMattingError.invalidModel) { try await store.installedModel() }
            await #expect(throws: SubjectMattingError.invalidModel) { try await store.remove() }
            #expect(try Data(contentsOf: pointer) == originalPointer)
            let installed = try await store.install(from: fixture.source)
            #expect(try await store.installedModel() == installed)
            #expect(try Data(contentsOf: model) == preservedBytes)
            #expect(FileManager.default.fileExists(atPath: previous.directory.path))
        }
    }

    @Test func workerReusesPredictionAndStillRejectsTamperingOnACacheHit() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let installed = try await store.install(from: fixture.source)
        let calls = TestStateSignal(0)
        let worker = AutomaticMaskWorker(subjectModelStore: store, subjectGenerator: { _, _ in
            calls.update { $0 += 1 }
            return try LocalMaskRaster(width: 1, height: 1, bytes: Data([128]))
        })
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let first = PreviewBitmap(image: try #require(context.makeImage()))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let second = PreviewBitmap(image: try #require(context.makeImage()))
        #expect(try await worker.generate(first, kind: .subject, sourceURL: nil).bytes == Data([128]))
        #expect(try await worker.generate(first, kind: .subject, sourceURL: nil).bytes == Data([128]))
        #expect(calls.value == 1)
        _ = try await worker.generate(second, kind: .subject, sourceURL: nil)
        #expect(calls.value == 2)
        _ = try await worker.generate(first, kind: .subject, sourceURL: nil)
        #expect(calls.value == 3, "Only one source image remains cached")
        let model = installed.directory.appendingPathComponent("model.mlmodelc/model.bin")
        let size = try Data(contentsOf: model).count
        try Data(repeating: 0, count: size).write(to: model)
        await #expect(throws: SubjectMattingError.invalidModel) {
            try await worker.generate(first, kind: .subject, sourceURL: nil)
        }
        #expect(calls.value == 3)
    }

    @Test func productionReopenRejectsAnUnapprovedSourceReceipt() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        _ = try await fixture.store().install(from: fixture.source)
        let production = SubjectMattingModelStore(directory: fixture.directory)
        await #expect(throws: SubjectMattingError.invalidModel) { try await production.installedModel() }
    }

    @Test func importReopensVerifiesAndRemovesOnlyOwnedGeneration() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let store = fixture.store()
        #expect(try await store.installedModel() == nil)
        let installed = try await store.install(from: fixture.source)
        #expect(try await fixture.store().installedModel() == installed)
        #expect(try SubjectMattingModelStore.verifyInstallation(installed).count == 2)
        let unknown = fixture.directory.appendingPathComponent("generations/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let sentinel = unknown.appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: sentinel)
        try await store.remove()
        #expect(try await store.installedModel() == nil)
        #expect(!FileManager.default.fileExists(atPath: installed.directory.path))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test func changedSourceBytesCannotReplaceInstalledModel() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let first = try await fixture.store().install(from: fixture.source)
        let weight = fixture.source.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let original = try Data(contentsOf: weight)
        try Data(repeating: 0, count: original.count).write(to: weight)
        await #expect(throws: SubjectMattingError.invalidModel) { try await fixture.store().install(from: fixture.source) }
        #expect(try await fixture.store().installedModel() == first)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasPrefix(".staging-") })
    }

    @Test func rejectedNativeInterfacePreservesPreviousGeneration() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let first = try await fixture.store().install(from: fixture.source)
        let replacement = fixture.store(validator: { _ in throw SubjectMattingError.invalidModel })
        await #expect(throws: SubjectMattingError.invalidModel) { try await replacement.install(from: fixture.source) }
        #expect(try await fixture.store().installedModel() == first)
        #expect(try SubjectMattingModelStore.verifyInstallation(first).count == 2)
    }

    @Test func sourcePackageSymlinksAndHardlinksAreRejected() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let link = fixture.root.appendingPathComponent("Linked.mlpackage")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        await #expect(throws: SubjectMattingError.invalidModel) { try await fixture.store().install(from: link) }
        let weight = fixture.source.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let hardlink = fixture.root.appendingPathComponent("external-weight.bin")
        try FileManager.default.linkItem(at: weight, to: hardlink)
        await #expect(throws: SubjectMattingError.invalidModel) { try await fixture.store().install(from: fixture.source) }
        #expect(FileManager.default.fileExists(atPath: hardlink.path))
        #expect(try await fixture.store().installedModel() == nil)
    }

    @Test func changedCompiledBytesAndSymlinksCannotBeLoadedOrRemoved() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let installed = try await store.install(from: fixture.source)
        let file = installed.directory.appendingPathComponent("model.mlmodelc/model.bin")
        let original = try Data(contentsOf: file)
        try Data(repeating: 0, count: original.count).write(to: file)
        #expect(throws: SubjectMattingError.invalidModel) { try SubjectMattingModelStore.verifyInstallation(installed) }
        await #expect(throws: SubjectMattingError.invalidModel) { try await store.remove() }
        #expect(try await store.installedModel() == installed)
        try FileManager.default.removeItem(at: file)
        let external = fixture.root.appendingPathComponent("external-model.bin")
        try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        #expect(throws: SubjectMattingError.invalidModel) { try SubjectMattingModelStore.verifyInstallation(installed) }
        await #expect(throws: SubjectMattingError.invalidModel) { try await store.remove() }
        #expect(try Data(contentsOf: external) == original)
    }

    @Test func generationsSymlinkCannotRedirectVerificationOrRemoval() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let store = fixture.store()
        let installed = try await store.install(from: fixture.source)
        let generations = fixture.directory.appendingPathComponent("generations")
        let foreign = fixture.root.appendingPathComponent("foreign-generations")
        try FileManager.default.moveItem(at: generations, to: foreign)
        try FileManager.default.createSymbolicLink(at: generations, withDestinationURL: foreign)
        await #expect(throws: SubjectMattingError.invalidModel) { try await store.installedModel() }
        #expect(throws: SubjectMattingError.invalidModel) { try SubjectMattingModelStore.verifyInstallation(installed) }
        await #expect(throws: SubjectMattingError.invalidModel) { try await store.remove() }
        #expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent(installed.directory.lastPathComponent).path))
    }

    @Test func malformedSourceInventoryIsRejectedBeforeCompilation() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let badFiles = fixture.files + [.init(path: "../outside", bytes: 1, sha256: String(repeating: "0", count: 64))]
        let store = fixture.store(sourceValidator: { _ in badFiles }, compiler: { _ in
            Issue.record("An invalid package reached native compilation")
            throw SubjectMattingError.invalidModel
        })
        await #expect(throws: SubjectMattingError.invalidModel) { try await store.install(from: fixture.source) }
        #expect(try await store.installedModel() == nil)
    }

    @Test func canceledNativeCompileRetainsAdmissionAndCannotPublishReplacement() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let original = try await fixture.store().install(from: fixture.source)
        let entered = TestStateSignal(false)
        let release = TestAsyncLatch()
        defer { release.releaseAll() }
        let budget = AIResourceBudget()
        let store = fixture.store(budget: budget, asyncCompiler: { _ in
            entered.update { $0 = true }
            await release.wait() // Native compiler may ignore task cancellation.
            let out = fixture.root.appendingPathComponent("cancelled-compiled")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: out.appendingPathComponent("model.bin"))
            return out
        })
        let pending = Task { try await store.install(from: fixture.source) }
        do {
            try await entered.wait("native matting compiler", until: { $0 })
            pending.cancel()
            var states = await budget.stateUpdates().makeAsyncIterator()
            let beforeReturn = try #require(await states.next())
            #expect(beforeReturn.activeInferences == 1)
            #expect(beforeReturn.residentModelBytes == SubjectMattingModelStore.residentMemoryEstimate)
            await #expect(throws: SubjectMattingError.setupInProgress) { try await store.remove() }
            release.releaseAll()
            do { _ = try await pending.value; Issue.record("Canceled compilation was published") }
            catch { #expect(error is CancellationError) }
            #expect(try await fixture.store().installedModel() == original)
            let afterReturn = try #require(await states.next())
            #expect(afterReturn.activeInferences == 0)
            #expect(afterReturn.residentModelBytes == 0)
        } catch {
            // A failed prerequisite/assertion must not race fixture removal
            // against a still-running, cancellation-ignoring native compiler.
            pending.cancel()
            release.releaseAll()
            _ = await pending.result
            throw error
        }
    }

    @Test func queuedSetupRejectsConcurrentRemovalAndCancellationReleasesGuard() async throws {
        let fixture = try SubjectMattingStoreFixture(); defer { fixture.clean() }
        let budget = AIResourceBudget()
        let held = try await budget.acquireLocalInference()
        let store = fixture.store(budget: budget)
        var states = await budget.stateUpdates().makeAsyncIterator()
        _ = await states.next()
        let pending = Task { try await store.install(from: fixture.source) }
        while let state = await states.next(), state.waitingInferences == 0 {}
        await #expect(throws: SubjectMattingError.setupInProgress) { try await store.remove() }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Canceled queued setup was accepted") }
        catch { #expect(error is CancellationError) }
        await budget.release(held)
        let installed = try await store.install(from: fixture.source)
        #expect(try await store.installedModel() == installed)
    }
}
