import AppKit
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Inline object mask proposal lifecycle", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct InlineObjectMaskWorkspaceTests {
    @Test func proposalIsTransientAndAcceptanceAddsOneExactMaskWithUndoAndRefinement() async throws {
        let response = try response()
        let object = InlineObjectMaskModel(propose: { _, instruction in
            #expect(instruction == "Roter Kreis")
            return response
        }, validateSource: { _, _ in }, checkModels: { nil })
        let f = try await fixture(object: object)
        defer { f.close() }
        f.model.add(.linear)
        let baseline = f.model.settings
        let previousID = try #require(f.model.selectedID)
        object.instruction = "Roter Kreis"
        f.workspace.showsOverlay = false; f.workspace.comparesBefore = true
        await object.refreshModels()
        await f.workspace.requestObjectMask()?.value
        #expect(f.workspace.showsOverlay && !f.workspace.comparesBefore)
        #expect(object.proposal?.layer == response.layer)
        #expect(f.model.settings == baseline && f.editor.settings(for: f.asset.id) == baseline)
        #expect(f.workspace.displayMask == response.layer.mask)
        #expect(f.workspace.displayMaskID == response.layer.id)
        #expect(!f.workspace.acceptsCanvasInput(source: f.source, layerID: previousID))
        f.workspace.discardObjectMask()
        #expect(object.proposal == nil && f.model.settings == baseline)
        #expect(f.model.selectedID == previousID)
        await f.workspace.requestObjectMask()?.value
        await f.workspace.applyObjectMask()?.value
        #expect(object.proposal == nil)
        #expect(f.model.settings.localAdjustments == baseline.localAdjustments + [response.layer])
        #expect(f.editor.settings(for: f.asset.id) == f.model.settings)
        #expect(f.model.selected == response.layer && f.workspace.usesBrush && f.workspace.showsOverlay)
        let accepted = f.model.settings
        await f.workspace.applyObjectMask()?.value
        #expect(f.model.settings == accepted, "Repeated acceptance must never add a second mask")
        f.workspace.undo()
        #expect(f.model.settings == baseline, "One undo removes exactly the accepted proposal")
        f.workspace.redo()
        #expect(f.model.settings == accepted && f.model.selectedID == response.layer.id)
        f.workspace.brush.appendPoint(try MaskPoint(x: 8, y: 4))
        f.workspace.finishGesture()
        #expect(f.model.selected?.mask.refinement?.strokes.count == 1)
        f.workspace.undo()
        #expect(f.model.selected == response.layer)
        #expect(await f.editor.flush()); #expect(await f.library.finishSaving())
    }

    @Test(arguments: ["cancel", "close", "photo", "photoABA", "settings", "undo", "newMask", "toolABA", "instruction"])
    func lateProposalCannotCrossCancellationOrContextChanges(change: String) async throws {
        let response = try response(), latch = TestAsyncLatch(), entered = TestStateSignal(false)
        let object = InlineObjectMaskModel(propose: { _, _ in
            entered.update { $0 = true }
            await latch.wait()
            return response
        }, validateSource: { _, _ in }, checkModels: { nil })
        let f = try await fixture(object: object)
        defer { latch.releaseAll(); f.close() }
        f.model.add(.linear)
        let baseline = f.model.settings
        object.instruction = "Roter Kreis"; await object.refreshModels()
        let task = f.workspace.requestObjectMask()
        try await entered.wait("object request entered", until: { $0 })
        switch change {
        case "cancel": f.workspace.discardObjectMask()
        case "close": f.workspace.close()
        case "photo": f.library.selectedID = f.second.id
        case "photoABA": f.library.selectedID = f.second.id; f.library.selectedID = f.asset.id
        case "settings": f.model.updateSelected { $0.settings.exposure = 0.5 }
        case "undo": f.workspace.undo()
        case "newMask": f.model.add(.radial)
        case "toolABA": f.develop.tool = .basic; f.develop.tool = .masks
        case "instruction": object.instruction = "Anderes Objekt"
        default: break
        }
        latch.releaseAll(); await task?.value
        #expect(object.proposal == nil && !object.isRunning)
        #expect(!f.editor.settings(for: f.asset.id).localAdjustments.contains { $0.id == response.layer.id })
        #expect(f.editor.settings(for: f.second.id).localAdjustments.isEmpty)
        if ["cancel", "close", "photo", "photoABA", "toolABA", "instruction"].contains(change) {
            #expect(f.editor.settings(for: f.asset.id) == baseline)
        }
        #expect(await f.editor.flush()); #expect(await f.library.finishSaving())
    }

    @Test func canceledOlderWorkerCannotReplaceOrClearANewerProposal() async throws {
        let old = try response(), newer = try response()
        let latch = TestAsyncLatch(), entered = TestStateSignal(false), calls = TestStateSignal(0)
        let object = InlineObjectMaskModel(propose: { _, _ in
            calls.update { $0 += 1 }
            let index = calls.value
            if index == 1 {
                entered.update { $0 = true }
                await latch.wait()
                return old
            }
            return newer
        }, validateSource: { _, _ in }, checkModels: { nil })
        let f = try await fixture(object: object)
        defer { latch.releaseAll(); f.close() }
        object.instruction = "Roter Kreis"
        let first = f.workspace.requestObjectMask()
        try await entered.wait("older object request owns its worker", until: { $0 })
        f.workspace.discardObjectMask()
        await f.workspace.requestObjectMask()?.value
        try #require(object.proposal?.layer == newer.layer)
        let status = object.status
        latch.releaseAll(); await first?.value
        #expect(object.proposal?.layer == newer.layer && object.status == status && !object.isRunning)
        #expect(f.workspace.displayMaskID == newer.layer.id)
        await f.workspace.applyObjectMask()?.value
        #expect(f.model.settings.localAdjustments == [newer.layer])
        #expect(!f.model.settings.localAdjustments.contains { $0.id == old.layer.id })
        #expect(await f.editor.flush()); #expect(await f.library.finishSaving())
    }

    @Test func sourceValidationDuringAcceptanceCannotWriteAfterPhotoRoundTrip() async throws {
        let response = try response(), latch = TestAsyncLatch(), entered = TestStateSignal(false)
        let validation = ObjectAcceptanceValidation(latch: latch, entered: entered)
        let object = InlineObjectMaskModel(propose: { _, _ in response }, validateSource: { _, _ in
            await validation.validate()
        }, checkModels: { nil })
        let f = try await fixture(object: object)
        defer { latch.releaseAll(); f.close() }
        object.instruction = "Roter Kreis"; await object.refreshModels()
        await f.workspace.requestObjectMask()?.value
        try #require(object.proposal != nil)
        await validation.block()
        let applying = f.workspace.applyObjectMask()
        try await entered.wait("object acceptance source validation", until: { $0 })
        f.library.selectedID = f.second.id; f.library.selectedID = f.asset.id
        latch.releaseAll(); await applying?.value
        #expect(f.editor.settings(for: f.asset.id).localAdjustments.isEmpty)
        #expect(f.editor.settings(for: f.second.id).localAdjustments.isEmpty)
        #expect(await f.editor.flush()); #expect(await f.library.finishSaving())
    }

    @Test func maskLimitAndFailedInferenceNeverSubstituteAnotherSelection() async throws {
        let calls = TestStateSignal(0)
        let object = InlineObjectMaskModel(propose: { _, _ in
            calls.update { $0 += 1 }
            throw AIObjectMaskError.emptyMask
        }, validateSource: { _, _ in }, checkModels: { nil })
        let f = try await fixture(object: object)
        defer { f.close() }
        object.instruction = "Roter Kreis"; await object.refreshModels()
        await f.workspace.requestObjectMask()?.value
        #expect(object.proposal == nil && object.status != nil)
        #expect(f.model.settings.localAdjustments.isEmpty)
        for _ in 0..<16 { f.model.add(.linear) }
        let full = f.model.settings
        #expect(full.localAdjustments.count == LocalAdjustment.maximumCount)
        #expect(!f.workspace.canCreateMask)
        await f.workspace.requestObjectMask()?.value
        #expect(calls.value == 1)
        #expect(f.model.settings == full && f.editor.settings(for: f.asset.id) == full)
        #expect(await f.editor.flush()); #expect(await f.library.finishSaving())
    }

    @Test func mismatchedSourceStampCannotDisplayOrAcceptAProposal() async throws {
        let correct = try response()
        let wrong = ImageAnalysisSourceStamp(device: 1, inode: 99, byteCount: 1,
            modifiedSeconds: 0, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0)
        let object = InlineObjectMaskModel(propose: { _, _ in
            AIObjectMaskResponse(layer: correct.layer, sourceStamp: wrong, summary: correct.summary, preview: nil)
        }, validateSource: { _, _ in }, checkModels: { nil })
        let f = try await fixture(object: object)
        defer { f.close() }
        object.instruction = "Roter Kreis"
        await f.workspace.requestObjectMask()?.value
        #expect(object.proposal == nil && object.status != nil)
        #expect(f.workspace.displayMask == nil)
        let previousReload = f.develop.previewReloadID
        f.workspace.reloadObjectMaskSource()
        #expect(f.develop.previewReloadID != previousReload)
        try await waitForTestState("local canvas reloaded with source", timeout: .seconds(10),
            state: { @MainActor in f.loadCount.value >= 2 && !f.model.isLoading && f.workspace.canvasSize != nil }, until: { $0 })
        #expect(object.proposal == nil)
        await f.workspace.applyObjectMask()?.value
        #expect(f.editor.settings(for: f.asset.id).localAdjustments.isEmpty)
        #expect(await f.editor.flush()); #expect(await f.library.finishSaving())
    }

    @Test func missingModelsExposeTheSpecificSetupAndDoNotInfer() async throws {
        for requirement in [InlineObjectMaskModel.SetupRequirement.languageModel, .subjectModel] {
            let object = InlineObjectMaskModel(propose: { _, _ in
                Issue.record("A missing model must not start inference")
                return try response()
            }, validateSource: { _, _ in }, checkModels: { requirement })
            let f = try await fixture(object: object)
            object.instruction = "Roter Kreis"; await object.refreshModels()
            #expect(object.setupRequirement == requirement && !object.modelsReady)
            await f.workspace.requestObjectMask()?.value
            #expect(object.proposal == nil && f.model.settings.localAdjustments.isEmpty)
            #expect(await f.editor.flush()); #expect(await f.library.finishSaving())
            f.close()
        }
    }

    private nonisolated static func responseValue() throws -> AIObjectMaskResponse {
        let raster = try LocalMaskRaster(width: 4, height: 2, bytes: Data([0, 255, 128, 0, 0, 0, 0, 0]))
        let layer = try LocalAdjustment(name: "Roter Kreis", mask: .init(shape: .subject(raster), feather: 0))
        return AIObjectMaskResponse(layer: layer, sourceStamp: ImageAnalysisSourceStamp(device: 1, inode: 2, byteCount: 1,
            modifiedSeconds: 0, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0), summary: "Roter Kreis ausgewählt.", preview: nil)
    }
    private nonisolated func response() throws -> AIObjectMaskResponse { try Self.responseValue() }

    private func fixture(object: InlineObjectMaskModel) async throws -> ObjectWorkspaceFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-InlineObject-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: directory)
        let first = PhotoAsset(folderID: folder.id, fileURL: directory.appendingPathComponent("A.png"))
        let second = PhotoAsset(folderID: folder.id, fileURL: directory.appendingPathComponent("B.png"))
        let catalog = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try catalog.save(LibraryCatalog(folders: [folder], assets: [first, second]))
        let library = LibraryModel(repository: catalog)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(ObjectWorkspaceSnapshotStore()))
        try await waitForTestState("object fixture", timeout: .seconds(10), state: {
            @MainActor in !library.isLoading && !library.isProjecting && !editor.isLoading
        }, until: { $0 })
        library.selectedID = first.id
        let source = try editor.resolvedSource(for: first).identity
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = PreviewBitmap(image: try #require(context.makeImage()))
        let loadCount = TestStateSignal(0)
        let model = LocalAdjustmentEditorModel(settings: editor.settings(for: first.id), loader: { _ in
            loadCount.update { $0 += 1 }
            return bitmap
        })
        let develop = DevelopWorkspace()
        develop.tool = .masks; develop.bind(source: source)
        develop.markDisplayed(source: source, settings: model.settings)
        develop.receive(bitmap, sourceBitmap: bitmap, sourceStamp: try response().sourceStamp)
        let workspace = InlineMaskWorkspace(objectMask: object)
        try #require(workspace.open(asset: first, source: source, settings: model.settings, editor: editor, library: library, model: model, developWorkspace: develop))
        try await waitForTestState("object canvas", timeout: .seconds(10), state: { @MainActor in workspace.canvasSize != nil }, until: { $0 })
        return ObjectWorkspaceFixture(directory: directory, asset: first, second: second, source: source,
            library: library, editor: editor, model: model, workspace: workspace, develop: develop, loadCount: loadCount)
    }
}

@MainActor
private struct ObjectWorkspaceFixture {
    let directory: URL
    let asset: PhotoAsset
    let second: PhotoAsset
    let source: AISourceIdentity
    let library: LibraryModel
    let editor: EditingModel
    let model: LocalAdjustmentEditorModel
    let workspace: InlineMaskWorkspace
    let develop: DevelopWorkspace
    let loadCount: TestStateSignal<Int>
    func close() { workspace.close(); develop.clear(); try? FileManager.default.removeItem(at: directory) }
}

private actor ObjectWorkspaceSnapshotStore: LegacySnapshotTestStore {
    func loadAll() -> [String: EditSettings] { [:] }
    func revisions() -> [String: Int64] { [:] }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) {}
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/inline-object-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { [:] }
}

private actor ObjectAcceptanceValidation {
    let latch: TestAsyncLatch
    let entered: TestStateSignal<Bool>
    var blocks = false
    init(latch: TestAsyncLatch, entered: TestStateSignal<Bool>) { self.latch = latch; self.entered = entered }
    func block() { blocks = true }
    func validate() async {
        if blocks { entered.update { $0 = true }; await latch.wait() }
    }
}
