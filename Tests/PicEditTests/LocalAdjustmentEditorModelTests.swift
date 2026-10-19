import AppKit
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Local adjustment editor")
@MainActor
struct LocalAdjustmentEditorModelTests {
    @Test func masksGroupSlidersUndoAndKeepGlobalSettings() async throws {
        let bitmap = try bitmap()
        let model = LocalAdjustmentEditorModel(settings: EditSettings(exposure: 0.5), loader: { _ in bitmap })
        await model.load(source: source("A"))
        model.add(.linear)
        let layer = try #require(model.selected)
        model.beginChange()
        for value in 1...20 { model.updateSelected { $0.settings.exposure = Double(value) / 10 } }
        model.endChange()
        #expect(model.selected?.settings.exposure == 2)
        #expect(model.settings.exposure == 0.5)
        model.undo()
        #expect(model.selected == layer)
        model.undo()
        #expect(model.settings.localAdjustments.isEmpty)
        model.redo(); model.redo()
        #expect(model.selected?.id == layer.id)
        #expect(model.selected?.settings.exposure == 2)
        model.duplicateSelected()
        #expect(model.settings.localAdjustments.count == 2)
        #expect(model.selected?.id != layer.id)
        model.deleteSelected()
        #expect(model.settings.localAdjustments.count == 1)
        model.undo()
        #expect(model.settings.localAdjustments.count == 2)
        model.close()
    }

    @Test func switchingMasksEndsThePreviousCorrectionGroup() async throws {
        let bitmap = try bitmap()
        let model = LocalAdjustmentEditorModel(settings: .neutral, loader: { _ in bitmap })
        await model.load(source: source("A"))
        model.add(.linear)
        let firstID = try #require(model.selectedID)
        model.add(.radial)
        let secondID = try #require(model.selectedID)
        model.selectedID = firstID
        model.beginChange()
        model.updateSelected { $0.settings.exposure = 1 }
        model.selectedID = secondID
        model.beginChange()
        model.updateSelected { $0.settings.contrast = 20 }
        model.endChange()
        model.undo()
        #expect(model.selected?.settings.contrast == 0)
        #expect(model.settings.localAdjustments.first?.settings.exposure == 1)
        model.undo()
        #expect(model.settings.localAdjustments.allSatisfy { $0.settings == .neutral })
        model.close()
    }

    @Test func inputContextChangesAcrossReselectionUndoAndReopeningSavedMasks() async throws {
        let bitmap = try bitmap()
        let model = LocalAdjustmentEditorModel(settings: .neutral, loader: { _ in bitmap })
        await model.load(source: source("A"))
        model.add(.linear)
        let saved = model.settings
        let firstID = try #require(model.selectedID)
        let beforeSwitch = model.inputContextID
        model.add(.radial)
        model.selectedID = firstID
        #expect(model.inputContextID != beforeSwitch)
        let beforeUndo = model.inputContextID
        model.undo()
        #expect(model.selectedID == firstID)
        #expect(model.inputContextID != beforeUndo)
        let beforeReset = model.inputContextID
        model.reset(settings: saved)
        #expect(model.selectedID == firstID)
        #expect(model.inputContextID != beforeReset)
        let beforeLoad = model.inputContextID
        await model.load(source: source("A"))
        #expect(model.selectedID == firstID)
        #expect(model.inputContextID != beforeLoad)
        model.close()
    }

    @Test(arguments: [LocalMaskCreation.subject, .sky, .background])
    func automaticMasksCannotPublishAfterSameSourceSessionWasReopened(_ kind: LocalMaskCreation) async throws {
        let gate = LocalMaskInferenceGate()
        let bitmap = try bitmap()
        let model = LocalAdjustmentEditorModel(settings: .neutral, loader: { _ in bitmap }, generator: { _, _, _ in await gate.generate() })
        await model.load(source: source("A"))
        model.add(kind)
        await gate.waitForStart()
        await model.load(source: source("B"))
        await model.load(source: source("A"))
        await gate.release()
        await gate.waitForReturn()
        #expect(model.settings.localAdjustments.isEmpty)
        #expect(!model.isGenerating)
        model.close()
    }

    @Test(arguments: [LocalMaskCreation.subject, .sky, .background])
    func automaticSelectionUsesExpectedRasterAndSingleUndoStep(_ kind: LocalMaskCreation) async throws {
        let bitmap = try bitmap()
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([0, 64, 128, 255]))
        let backgroundRaster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 191, 127, 0]))
        let requests = TestStateSignal<[AutomaticMaskKind]>([])
        let sourceURL = URL(fileURLWithPath: "/tmp/A.jpg")
        let model = LocalAdjustmentEditorModel(settings: .neutral, loader: { _ in bitmap }, generator: { _, requestedKind, url in
            requests.update { $0.append(requestedKind) }
            #expect(url == sourceURL)
            return raster
        })
        await model.load(source: source("A"))
        model.add(kind)
        await model.waitForInference()
        let layer = try #require(model.selected)
        #expect(requests.value == [kind == .sky ? .sky : .subject])
        #expect(layer.name == (kind == .background ? "Hintergrund" : kind == .sky ? "Himmel" : "Motiv"))
        #expect(!layer.mask.isInverted)
        #expect(layer.mask.shape == (kind == .sky ? .sky(raster) : .subject(kind == .background ? backgroundRaster : raster)))
        #expect(!model.isGenerating)
        #expect(model.canUndo)
        model.undo()
        #expect(model.settings.localAdjustments.isEmpty)
        #expect(!model.canUndo)
        #expect(model.canRedo)
        model.redo()
        #expect(model.settings.localAdjustments == [layer])
        #expect(!model.canRedo)
        model.close()
    }

    @Test func automaticResultIsFrozenAndSliderChangesDoNotRepeatInference() async throws {
        let gate = LocalMaskInferenceGate()
        let bitmap = try bitmap()
        let model = LocalAdjustmentEditorModel(settings: .neutral, loader: { _ in bitmap }, generator: { _, _, _ in await gate.generate() })
        await model.load(source: source("A"))
        model.add(.sky)
        await gate.waitForStart(); await gate.release(); await model.waitForInference()
        guard let selected = model.selected, case .sky(let raster) = selected.mask.shape else { Issue.record("Sky selection was not preserved"); return }
        for value in 0...30 { model.updateSelected { $0.settings.exposure = Double(value) / 10 } }
        #expect(await gate.starts == 1)
        #expect(raster.bytes == Data([0, 255, 255, 0]))
        #expect(model.selected?.mask == selected.mask)
        model.close()
    }

    @Test func acceptedMaskEditSurvivesUndoResetRestartBackupAndRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-LocalMasks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditingModel(directory: directory)
        try await waitLoaded(editor)
        let mask = try LocalAdjustmentMask(shape: .radial(center: LocalMaskPoint(x: 0.25, y: 0.75), radiusX: 0.2, radiusY: 0.3, rotation: 0))
        let layer = try LocalAdjustment(name: "Gesicht", mask: mask, settings: LocalAdjustmentSettings(exposure: 1))
        let settings = EditSettings(contrast: 8, localAdjustments: [layer])
        editor.setSettings(settings, for: "A")
        editor.undo(assetID: "A"); #expect(editor.settings(for: "A").localAdjustments.isEmpty)
        editor.redo(assetID: "A"); #expect(editor.settings(for: "A") == settings)
        #expect(await editor.flush())
        let backup = try #require(await editor.createBackup())
        editor.reset(assetID: "A"); #expect(editor.settings(for: "A").isNeutral)
        #expect(await editor.flush())
        #expect(await editor.restoreBackup(from: backup))
        #expect(editor.settings(for: "A") == settings)
        let restarted = EditingModel(directory: directory)
        try await waitLoaded(restarted)
        #expect(restarted.settings(for: "A") == settings)
        #expect(await restarted.flush())
    }

    private func bitmap() throws -> PreviewBitmap {
        let data = Data(repeating: 100, count: 40 * 20 * 4)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 40, height: 20, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }
    private func source(_ name: String) -> AISourceIdentity {
        .original(.init(fileURL: URL(fileURLWithPath: "/tmp/\(name).jpg"), modifiedAt: .distantPast, fileSize: 0))
    }
    private func waitLoaded(_ model: EditingModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading)
        #expect(!model.isReadOnly, Comment(rawValue: model.errorMessage ?? ""))
    }
}

private actor LocalMaskInferenceGate {
    private var continuation: CheckedContinuation<LocalMaskRaster, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []
    private var returned = false
    private(set) var starts = 0
    func generate() async -> LocalMaskRaster {
        starts += 1
        let value = await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in startWaiters { waiter.resume() }; startWaiters = []
        }
        returned = true
        for waiter in returnWaiters { waiter.resume() }; returnWaiters = []
        return value
    }
    func waitForStart() async { if starts == 0 { await withCheckedContinuation { startWaiters.append($0) } } }
    func release() { continuation?.resume(returning: try! LocalMaskRaster(width: 2, height: 2, bytes: Data([0, 255, 255, 0]))); continuation = nil }
    func waitForReturn() async { if !returned { await withCheckedContinuation { returnWaiters.append($0) } } }
}
