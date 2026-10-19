import AppKit
import Foundation
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

@Suite("Inline mask workspace", .serialized)
@MainActor
struct InlineMaskWorkspaceTests {
    @Test func draftAndCanvasShareOneSessionAndAcceptOneUndoStep() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.editor.setSettings(EditSettings(exposure: 0.5), for: f.asset.id)
        let workspace = InlineMaskWorkspace()
        let model = try model(settings: f.editor.settings(for: f.asset.id))
        #expect(workspace.open(asset: f.asset, source: f.source, settings: model.settings, editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        model.add(.linear)
        model.beginChange()
        model.updateSelected { $0.settings.exposure = 1.5 }
        model.updateSelected { $0.mask.feather = 0.2 }
        model.endChange()
        #expect(workspace.previewSettings?.localAdjustments.count == 1)
        #expect(f.editor.settings(for: f.asset.id).localAdjustments.isEmpty)
        #expect(workspace.isCurrent)
        let accepted = model.settings
        workspace.comparesBefore = true
        #expect(workspace.previewSettings == EditSettings(exposure: 0.5))
        workspace.comparesBefore = false
        #expect(workspace.apply())
        #expect(!workspace.isPresented && workspace.model == nil)
        #expect(f.editor.settings(for: f.asset.id) == accepted)
        f.editor.undo(assetID: f.asset.id)
        #expect(f.editor.settings(for: f.asset.id) == EditSettings(exposure: 0.5))
        f.editor.redo(assetID: f.asset.id)
        #expect(f.editor.settings(for: f.asset.id) == accepted)
        #expect(await f.editor.flush())
        #expect(await f.library.finishSaving())
    }

    @Test func strokeAndRefinementUndoStaySynchronizedWithTheSharedCanvas() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let workspace = InlineMaskWorkspace(), model = try model()
        #expect(workspace.open(asset: f.asset, source: f.source, settings: .neutral, editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        model.add(.brush)
        workspace.brush.appendPoint(try MaskPoint(x: 4, y: 5))
        workspace.brush.appendPoint(try MaskPoint(x: 12, y: 10))
        workspace.finishGesture()
        guard case .brush(let document)? = workspace.selected?.mask.shape else { Issue.record("Pinsel fehlt"); return }
        #expect(document.strokes.count == 1)
        #expect(workspace.brush.document == document)
        workspace.undo()
        #expect(workspace.brush.document?.strokes.isEmpty == true)
        workspace.redo()
        #expect(workspace.brush.document == document)
        model.add(.linear)
        workspace.refines = true
        workspace.brush.appendPoint(try MaskPoint(x: 8, y: 8))
        workspace.finishGesture()
        #expect(workspace.selected?.mask.refinement?.strokes.count == 1)
        workspace.undo()
        #expect(workspace.selected?.mask.refinement == nil)
        #expect(workspace.brush.document?.strokes.isEmpty == true)
        workspace.cancel()
        #expect(model.settings.isNeutral && model.source == nil)
        #expect(workspace.brush.document == nil)
        #expect(!f.editor.hasPendingChanges)
        #expect(await f.library.finishSaving())
    }

    @Test func localCorrectionsHideTheOverlayAndSelectingOrReshapingAMaskRestoresIt() async throws {
        let f = try await fixture(nativeStore: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let workspace = InlineMaskWorkspace(), model = try model()
        #expect(workspace.open(asset: f.asset, source: f.source, settings: .neutral,
            editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        model.add(.linear)
        let firstID = try #require(model.selectedID)
        #expect(workspace.showsOverlay)
        model.beginChange()
        model.updateSelected { $0.settings.exposure = 1.5 }
        #expect(!workspace.showsOverlay)
        model.updateSelected { $0.settings.contrast = 15 }
        model.endChange()
        #expect(!workspace.showsOverlay)
        workspace.select(firstID)
        #expect(workspace.showsOverlay, "Clicking the selected row inspects its area again")
        model.updateSelected { $0.settings.saturation = 20 }
        #expect(!workspace.showsOverlay)
        model.updateSelected { $0.name = "Hintergrund" }
        #expect(!workspace.showsOverlay, "Renaming must preserve the correction preview")
        model.updateSelected { $0.mask.feather = 0.25 }
        #expect(workspace.showsOverlay)
        model.updateSelected { $0.mask.opacity = 0.5 }
        #expect(!workspace.showsOverlay)
        workspace.select(firstID)
        model.updateSelected { $0.isEnabled = false }
        #expect(!workspace.showsOverlay)
        model.add(.radial)
        #expect(workspace.showsOverlay)
        workspace.select(firstID)
        #expect(workspace.showsOverlay)
        model.updateSelected { $0.settings = .neutral }
        #expect(!workspace.showsOverlay, "Resetting corrections must show the resulting photo")
        workspace.cancel()
        #expect(await f.library.finishSaving())
    }

    @Test func paintingShowsTheMaskAgainWithoutChangingCorrectionUndoGrouping() async throws {
        let f = try await fixture(nativeStore: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let workspace = InlineMaskWorkspace(), model = try model()
        #expect(workspace.open(asset: f.asset, source: f.source, settings: .neutral,
            editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        model.add(.brush)
        model.beginChange()
        model.updateSelected { $0.settings.exposure = 1 }
        model.updateSelected { $0.settings.exposure = 2 }
        model.endChange()
        #expect(!workspace.showsOverlay)
        workspace.brush.appendPoint(try MaskPoint(x: 4, y: 5))
        #expect(workspace.showsOverlay, "The area must be visible while the first stroke is still active")
        workspace.finishGesture()
        workspace.undo()
        #expect(workspace.selected?.settings.exposure == 2)
        #expect(workspace.brush.document?.strokes.isEmpty == true)
        workspace.undo()
        #expect(workspace.selected?.settings.exposure == 0)
        #expect(!workspace.showsOverlay)
        workspace.redo()
        #expect(workspace.selected?.settings.exposure == 2)
        #expect(!workspace.showsOverlay)
        workspace.cancel()
        #expect(await f.library.finishSaving())
    }

    @Test func deletingListRowsKeepsOtherSelectionAndSynchronizesRestoredBrushes() async throws {
        let f = try await fixture(nativeStore: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let workspace = InlineMaskWorkspace(), model = try model()
        #expect(workspace.open(asset: f.asset, source: f.source, settings: .neutral,
            editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        model.add(.brush)
        let firstID = try #require(model.selectedID)
        workspace.brush.appendPoint(try MaskPoint(x: 4, y: 5))
        workspace.finishGesture()
        let painted = try #require(workspace.brush.document)
        model.add(.radial)
        let secondID = try #require(model.selectedID)
        model.add(.linear)
        let thirdID = try #require(model.selectedID)
        workspace.select(secondID)
        workspace.delete(thirdID)
        #expect(model.selectedID == secondID)
        #expect(model.settings.localAdjustments.map(\.id) == [firstID, secondID])
        workspace.undo()
        #expect(model.selectedID == secondID)
        #expect(model.settings.localAdjustments.map(\.id) == [firstID, secondID, thirdID])
        workspace.delete(secondID)
        #expect(model.selectedID == thirdID, "Removing the selected row picks its next neighbor")
        #expect(workspace.brush.document?.strokes.isEmpty == true)
        workspace.select(firstID)
        #expect(workspace.brush.document == painted)
        workspace.delete(firstID)
        #expect(model.selectedID == thirdID)
        #expect(workspace.brush.document?.strokes.isEmpty == true)
        workspace.undo()
        workspace.select(firstID)
        #expect(workspace.brush.document == painted)
        workspace.delete(firstID)
        workspace.delete(thirdID)
        #expect(workspace.selected == nil && workspace.brush.document == nil)
        workspace.undo()
        #expect(model.selectedID == thirdID)
        #expect(workspace.brush.document?.strokes.isEmpty == true)
        workspace.cancel()
        #expect(await f.library.finishSaving())
    }

    @Test func equalSettingsAfterUndoAndSelectionRoundTripCannotReviveDraft() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let workspace = InlineMaskWorkspace(), model = try model()
        #expect(workspace.open(asset: f.asset, source: f.source, settings: .neutral, editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        model.add(.radial)
        f.editor.setSettings(EditSettings(contrast: 10), for: f.asset.id)
        f.editor.undo(assetID: f.asset.id)
        #expect(f.editor.settings(for: f.asset.id).isNeutral)
        try await wait { !workspace.isPresented }
        #expect(model.settings.isNeutral)
        #expect(!workspace.apply())
        #expect(workspace.open(asset: f.asset, source: f.source, settings: .neutral, editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        model.add(.brush)
        f.library.selectedID = f.library.assets[1].id
        f.library.selectedID = f.asset.id
        try await wait { !workspace.isPresented }
        #expect(f.editor.settings(for: f.asset.id).localAdjustments.isEmpty)
        #expect(await f.editor.flush())
        #expect(await f.library.finishSaving())
    }

    @Test func acceptedOpeningSaveCanFinishAndReopeningUsesCurrentAcceptedSettings() async throws {
        // This schedule verifies the draft anchor, independently of the native
        // automatic-backup maintenance gate tested by controller tests.
        let f = try await fixture(nativeStore: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let workspace = InlineMaskWorkspace(), model = try model()
        f.editor.setSettings(EditSettings(contrast: 7), for: f.asset.id)
        #expect(workspace.open(asset: f.asset, source: f.source, settings: EditSettings(contrast: 7), editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        #expect(await f.editor.flush())
        await Task.yield()
        #expect(workspace.isPresented && workspace.isCurrent)
        model.add(.radial)
        #expect(workspace.apply())
        let accepted = f.editor.settings(for: f.asset.id)
        #expect(workspace.open(asset: f.asset, source: f.source, settings: accepted, editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        #expect(model.settings == accepted)
        #expect(!model.canUndo)
        workspace.cancel()
        #expect(f.editor.settings(for: f.asset.id) == accepted)
        #expect(await f.editor.flush())
        #expect(await f.library.finishSaving())
    }

    @Test func localLayerOrderingIsUndoableAndKeepsTheSelection() async throws {
        let model = try model()
        await model.load(source: source())
        model.add(.linear); let first = try #require(model.selectedID)
        model.add(.radial); let second = try #require(model.selectedID)
        model.moveSelected(by: -1)
        #expect(model.settings.localAdjustments.map(\.id) == [second, first])
        #expect(model.selectedID == second)
        model.undo()
        #expect(model.settings.localAdjustments.map(\.id) == [first, second])
        #expect(model.selectedID == second)
        model.close()
    }

    @Test func bufferedSliderClickCannotWriteIntoAnotherMaskBeforeViewTeardown() async throws {
        let model = try model()
        await model.load(source: source())
        model.add(.linear)
        let firstID = try #require(model.selectedID)
        let input = LocalMaskSliderInput(value: Binding(get: { model.selected?.settings.exposure ?? 0 },
            set: { value in model.updateSelected { $0.settings.exposure = value } }), model: model)
        let slider = ResettableSliderInteraction()
        slider.readValue = { input.value.wrappedValue }
        slider.writeValue = { input.value.wrappedValue = $0 }
        slider.onEditingChanged = input.onEditingChanged
        slider.beginPointer(); slider.nativeValueChanged(2); slider.endPointer()
        #expect(slider.hasUncommittedClick)
        model.add(.radial)
        let secondID = try #require(model.selectedID)
        #expect(secondID != firstID)
        // The old native timer can fire before SwiftUI processes the new .id.
        slider.commitClick()
        #expect(model.settings.localAdjustments.allSatisfy { $0.settings.exposure == 0 })
        slider.reset(to: 1)
        #expect(model.selected?.settings.exposure == 0)
        model.undo()
        #expect(model.settings.localAdjustments.map(\.id) == [firstID], "A discarded stale click must not add an undo step")
        model.close()
    }

    @Test func bufferedSliderInputStaysStaleAfterReturningToTheSameMask() async throws {
        let model = try model()
        await model.load(source: source())
        model.add(.linear)
        let firstID = try #require(model.selectedID)
        let input = LocalMaskSliderInput(value: Binding(get: { model.selected?.settings.exposure ?? 0 },
            set: { value in model.updateSelected { $0.settings.exposure = value } }), model: model)
        let slider = ResettableSliderInteraction()
        slider.readValue = { input.value.wrappedValue }
        slider.writeValue = { input.value.wrappedValue = $0 }
        slider.onEditingChanged = input.onEditingChanged
        slider.beginPointer(); slider.nativeValueChanged(2); slider.endPointer()
        model.add(.radial)
        model.selectedID = firstID
        slider.commitClick()
        #expect(model.selected?.settings.exposure == 0)

        // A stale control's end event must not close the newly selected group's
        // undo boundary, even if SwiftUI has not dismantled the old native view.
        model.beginChange()
        model.updateSelected { $0.settings.exposure = 0.5 }
        input.onEditingChanged(false)
        model.updateSelected { $0.settings.exposure = 1 }
        model.endChange()
        model.undo()
        #expect(model.selected?.settings.exposure == 0)
        model.close()
    }

    @Test func deletedAndRestoredMaskCannotAcceptItsOldBufferedSliderClick() async throws {
        let model = try model()
        await model.load(source: source())
        model.add(.linear)
        let firstID = try #require(model.selectedID)
        let input = LocalMaskSliderInput(value: Binding(get: { model.selected?.settings.exposure ?? 0 },
            set: { value in model.updateSelected { $0.settings.exposure = value } }), model: model)
        model.delete(firstID)
        model.undo()
        #expect(model.selectedID == firstID)
        input.onEditingChanged(true)
        input.value.wrappedValue = 2
        input.onEditingChanged(false)
        #expect(model.selected?.settings.exposure == 0)
        model.undo()
        #expect(model.settings.localAdjustments.isEmpty)
        model.close()
    }

    @Test func canvasGestureAdmissionIsBoundToItsLayerAndStopsDuringAutomaticSelection() async throws {
        let f = try await fixture(nativeStore: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let workspace = InlineMaskWorkspace(), model = try model()
        #expect(workspace.open(asset: f.asset, source: f.source, settings: .neutral,
            editor: f.editor, library: f.library, model: model))
        try await wait { workspace.canvasSize != nil }
        model.add(.linear)
        let firstID = try #require(model.selectedID)
        #expect(workspace.acceptsCanvasInput(source: f.source, layerID: firstID))
        model.add(.radial)
        let secondID = try #require(model.selectedID)
        #expect(!workspace.acceptsCanvasInput(source: f.source, layerID: firstID))
        #expect(workspace.acceptsCanvasInput(source: f.source, layerID: secondID))
        #expect(!workspace.acceptsCanvasInput(source: source(), layerID: secondID))
        model.add(.subject)
        #expect(model.isGenerating)
        #expect(!workspace.acceptsCanvasInput(source: f.source, layerID: secondID))
        model.cancelInference()
        workspace.cancel()
        #expect(!workspace.acceptsCanvasInput(source: f.source, layerID: secondID))
        #expect(await f.library.finishSaving())
    }

    private func model(settings: EditSettings = .neutral) throws -> LocalAdjustmentEditorModel {
        let data = Data(repeating: 100, count: 40 * 20 * 4)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 40, height: 20, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bitmap = PreviewBitmap(image: image)
        return LocalAdjustmentEditorModel(settings: settings, loader: { _ in bitmap })
    }
    private func source() -> AISourceIdentity {
        .original(.init(fileURL: URL(fileURLWithPath: "/tmp/inline-mask.jpg"), modifiedAt: .distantPast, fileSize: 0))
    }
    private func fixture(nativeStore: Bool = true) async throws -> (directory: URL, library: LibraryModel, editor: EditingModel, asset: PhotoAsset, source: AISourceIdentity) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-InlineMasks-\(UUID())")
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: photos)
        let assets = ["A.jpg", "B.jpg"].map { PhotoAsset(folderID: folder.id, fileURL: photos.appendingPathComponent($0)) }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let editor = nativeStore ? EditingModel(directory: directory.appendingPathComponent("Edits"))
            : EditingModel(database: LegacySnapshotTestAdapter(InlineMaskSnapshotStore()))
        try await wait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = assets[0].id
        let source = try editor.resolvedSource(for: assets[0]).identity
        return (directory, library, editor, assets[0], source)
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
}

private actor InlineMaskSnapshotStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) {
        values[assetID] = settings; versions[assetID] = revision
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/inline-mask-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
}
