import AppKit
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("AI development review transactions", .timeLimit(.minutes(2)))
@MainActor
struct AIDevelopmentModelTests {
    @Test func slidersAndProposalDoNotWriteUntilExplicitAcceptance() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        f.model.intent.brightness = 0.8
        #expect(await f.probe.calls == 0)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        let task = try #require(f.start())
        await task.value
        #expect(f.model.proposal?.settings.exposure == 0.5)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
        #expect(f.editor.settings(for: f.assetID).exposure == 0.5)
        #expect(f.editor.canUndo(assetID: f.assetID))
        f.editor.undo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        f.editor.redo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID).exposure == 0.5)
        #expect(await f.probe.calls == 1)
        #expect(await f.editor.flush())
        #expect(await f.store.loadAll()[f.assetID]?.exposure == 0.5)
    }

    @Test(arguments: ["editUndo", "selection", "workspace", "intent", "cancel", "bitmap"])
    func staleOrCancelledInferenceNeverPublishes(change: String) async throws {
        let latch = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(latch: latch)
        defer { latch.releaseAll(); f.remove() }
        let task = try #require(f.start())
        try await waitForTestState("Qwen fake entered", state: { await f.probe.calls }, until: { $0 == 1 })
        switch change {
        case "editUndo":
            f.editor.setSettings(EditSettings(exposure: 2), for: f.assetID)
            f.editor.undo(assetID: f.assetID)
        case "selection":
            let id = f.library.selectedID; f.library.selectedID = nil; f.library.selectedID = id
        case "workspace": f.library.workspaceMode = .develop
        case "intent": f.model.intent.warmth = 0.3
        case "cancel": f.model.cancel()
        default: f.workspace.clear()
        }
        #expect(f.start() == nil, "A cancelled native call keeps admission until it actually returns")
        latch.releaseAll(); await task.value
        #expect(f.model.proposal == nil && !f.model.isRunning)
        #expect(f.editor.settings(for: f.assetID) == .neutral)
        #expect(await f.editor.flush())
    }

    @Test func readyProposalCannotOverwriteLaterManualEditAndSupportsRetry() async throws {
        let f = try await AIDevelopmentFixture.make()
        defer { f.remove() }
        await (try #require(f.start())).value
        f.editor.setSettings(EditSettings(shadows: 30), for: f.assetID)
        f.model.apply(library: f.library, editor: f.editor)
        #expect(f.editor.settings(for: f.assetID) == EditSettings(shadows: 30))
        await (try #require(f.start())).value
        #expect(f.model.proposal != nil)
        f.model.discard()
        #expect(f.model.proposal == nil && f.model.status == nil)
        #expect(await f.editor.flush())
    }

    @Test func changedNativeSourceRejectsReadyProposal() async throws {
        let f = try await AIDevelopmentFixture.make(validateSource: { _, _ in throw AIDevelopmentError.staleContext })
        defer { f.remove() }
        await (try #require(f.start())).value
        await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
        #expect(f.editor.settings(for: f.assetID) == .neutral && f.model.proposal == nil)
        #expect(f.model.status == AIDevelopmentError.staleContext.localizedDescription)
        #expect(!f.editor.canUndo(assetID: f.assetID))
    }

    @Test func manualEditAndUndoDuringSourceValidationRejectsApply() async throws {
        let latch = TestAsyncLatch(), entered = TestAsyncLatch()
        let f = try await AIDevelopmentFixture.make(validateSource: { _, _ in
            entered.releaseAll(); await latch.wait()
        })
        defer { latch.releaseAll(); f.remove() }
        await (try #require(f.start())).value
        let task = try #require(f.model.apply(library: f.library, editor: f.editor))
        await entered.wait()
        f.editor.setSettings(EditSettings(exposure: 3), for: f.assetID)
        f.editor.undo(assetID: f.assetID)
        latch.releaseAll(); await task.value
        #expect(f.editor.settings(for: f.assetID) == .neutral && f.model.proposal == nil)
        #expect(await f.editor.flush())
    }
}

@MainActor private struct AIDevelopmentFixture {
    let directory: URL
    let library: LibraryModel
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let store: AIDevelopmentTestStore
    let probe: AIDevelopmentTestProbe
    let model: AIDevelopmentModel
    var assetID: String { library.assets[0].id }
    func start() -> Task<Void, Never>? { model.start(library: library, editor: editor, workspace: workspace) }
    func remove() { model.discard(); workspace.clear(); try? FileManager.default.removeItem(at: directory) }

    static func make(latch: TestAsyncLatch = TestAsyncLatch(open: true),
                     validateSource: @escaping AIDevelopmentModel.ValidateSource = { _, _ in }) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-AIDevelopment-\(UUID())")
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: directory.appendingPathComponent("photo.png"))
        let repository = CatalogRepository(directory: directory.appendingPathComponent("catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let store = AIDevelopmentTestStore(assetID: asset.id)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitForTestState("AI development fixture", state: { @MainActor in
            !library.isLoading && !library.isProjecting && !editor.isLoading
        }, until: { $0 })
        library.selectedID = asset.id; library.workspaceMode = .aiDevelop
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        })
        let snapshot = try #require(editor.aiSnapshot(in: library))
        workspace.bind(source: snapshot.source)
        let bitmap = PreviewBitmap(image: try aiDevelopmentTestImage())
        workspace.receive(bitmap, sourceBitmap: bitmap)
        let probe = AIDevelopmentTestProbe(latch: latch)
        let model = AIDevelopmentModel(propose: { snapshot, _, intent in try await probe.propose(snapshot, intent) },
                                     validateSource: validateSource)
        return Self(directory: directory, library: library, editor: editor, workspace: workspace, store: store, probe: probe, model: model)
    }
}

private actor AIDevelopmentTestProbe {
    private(set) var calls = 0
    let latch: TestAsyncLatch
    init(latch: TestAsyncLatch) { self.latch = latch }
    func propose(_ snapshot: AIEditingSnapshot, _ intent: AIDevelopmentIntent) async throws -> AIDevelopmentResponse {
        calls += 1
        await latch.wait() // Deliberately ignores cancellation like native GPU work.
        return AIDevelopmentResponse(proposal: AIDevelopmentProposal(summary: "Das Bild behutsam aufhellen.", adjustments: .init(exposure: 1)),
            sourceStamp: .init(device: 1, inode: 1, byteCount: 1, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0))
    }
}

private actor AIDevelopmentTestStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings]
    private var versions: [String: Int64] = [:]
    init(assetID: String) { values = [assetID: .neutral] }
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) { values[assetID] = settings; versions[assetID] = revision }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/unused-ai-test-backup") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
}

func aiDevelopmentTestImage() throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 128 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
    context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1)); context.fillEllipse(in: CGRect(x: 32, y: 24, width: 64, height: 48))
    return try #require(context.makeImage())
}

@Suite("Qwen native product route")
struct QwenNativeModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_QWEN_MODEL_PATH"] != nil), .timeLimit(.minutes(3)))
    func installedLocalModelProducesValidatedDevelopmentJSON() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GLOWROOM_QWEN_MODEL_PATH"])
        var intent = AIDevelopmentIntent(); intent.brightness = 0.6; intent.instruction = "Helle das Bild behutsam auf."
        let data = try await QwenDevelopmentBackend().propose(modelDirectory: URL(fileURLWithPath: path),
            image: aiDevelopmentTestImage(), prompt: intent.prompt(settings: .neutral), schema: AIDevelopmentProposal.schema)
        let response = try AIDevelopmentProposal.decode(data)
        #expect(!response.summary.isEmpty)
        print("Qwen product smoke: \(String(decoding: data, as: UTF8.self))")
    }
}
