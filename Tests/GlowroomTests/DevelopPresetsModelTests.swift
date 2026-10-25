import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Personal preset preview transactions", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct DevelopPresetsModelTests {
    @Test func previewDiscardAndAcceptanceUseOneDurableHistoryStep() async throws {
        let f = try await PresetFixture.make()
        defer { f.remove() }
        let baseline = f.editor.settings(for: f.assetID)
        await (try #require(f.preview())).value
        #expect(f.model.hasPreview && !f.model.isWorking)
        #expect(f.workspace.presetPreview?.settings.exposure == 1.25)
        #expect(f.editor.settings(for: f.assetID) == baseline)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        #expect(await f.editor.flush())
        f.model.discard()
        #expect(f.workspace.presetPreview == nil)
        #expect(f.editor.localRevision(for: f.assetID) == 0)
        await (try #require(f.preview())).value
        await (try #require(f.model.apply(library: f.library, editor: f.editor))).value
        #expect(!f.model.isWorking && !f.model.hasPreview)
        #expect(f.editor.settings(for: f.assetID).exposure == 1.25)
        #expect(f.editor.localRevision(for: f.assetID) == 1)
        f.editor.undo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID) == baseline)
        #expect(!f.editor.canUndo(assetID: f.assetID))
        f.editor.redo(assetID: f.assetID)
        #expect(f.editor.settings(for: f.assetID).exposure == 1.25)
        #expect(await f.editor.flush())
        let reopened = EditingModel(directory: f.editingDirectory)
        try await waitForTestState("preset persisted", state: { @MainActor in !reopened.isLoading }, until: { $0 })
        #expect(reopened.settings(for: f.assetID) == f.editor.settings(for: f.assetID))
        #expect(await reopened.finishSaving())
    }

    @Test(arguments: ["cancel", "selection", "editUndo", "groups"])
    func obsoletePreviewNeverPublishes(change: String) async throws {
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        let f = try await PresetFixture.make(render: { bitmap, _, _, _ in
            entered.releaseAll(); await release.wait(); return bitmap
        })
        defer { release.releaseAll(); f.remove() }
        let work = try #require(f.preview()); await entered.wait()
        switch change {
        case "cancel": f.model.discard()
        case "selection":
            f.library.selectedID = nil; f.library.selectedID = f.assetID
        case "editUndo":
            var value = f.editor.settings(for: f.assetID); value.exposure = 2
            f.editor.setSettings(value, for: f.assetID); f.editor.undo(assetID: f.assetID)
        default: f.model.groups = [.details]
        }
        release.releaseAll(); await work.value
        #expect(!f.model.hasPreview && !f.model.isWorking)
        #expect(f.workspace.presetPreview == nil)
        #expect(f.editor.settings(for: f.assetID) == .newEditingSettings)
        #expect(await f.editor.flush())
    }

    @Test(arguments: ["editUndo", "ai"])
    func delayedAcceptanceCannotCommitAfterContextOrPreviewChanges(change: String) async throws {
        let validation = PresetValidationGate()
        let f = try await PresetFixture.make(validate: { _, _ in await validation.validate() })
        defer { validation.release.releaseAll(); f.remove() }
        await (try #require(f.preview())).value
        let work = try #require(f.model.apply(library: f.library, editor: f.editor))
        await validation.entered.wait()
        if change == "editUndo" {
            var value = f.editor.settings(for: f.assetID); value.exposure = 2
            f.editor.setSettings(value, for: f.assetID); f.editor.undo(assetID: f.assetID)
        } else {
            let candidate = try #require(f.workspace.presetPreview)
            f.workspace.aiCorrectionPreview = candidate
        }
        validation.release.releaseAll(); await work.value
        #expect(!f.model.isWorking && !f.model.hasPreview)
        #expect(f.editor.settings(for: f.assetID) == .newEditingSettings)
        #expect(await f.editor.finishSaving())
    }

    @Test func incompatibleProcessBlocksPreviewWithoutChangingTarget() async throws {
        let f = try await PresetFixture.make(version: .legacyV1)
        defer { f.remove() }
        #expect(f.preview() == nil)
        #expect(f.model.status == DevelopPresetError.incompatibleToneProcessing.localizedDescription)
        #expect(!f.model.hasPreview && f.editor.localRevision(for: f.assetID) == 0)
        #expect(await f.editor.finishSaving())
    }

    @Test func aiAndPersonalPresetPreviewsHaveOneVisibleOwner() async throws {
        let f = try await PresetFixture.make()
        defer { f.remove() }
        await (try #require(f.preview())).value
        let personal = try #require(f.workspace.presetPreview)
        var settings = personal.settings; settings.exposure = -1
        let ai = AICorrectionPreview(snapshot: personal.snapshot, settings: settings, bitmap: personal.bitmap)
        f.workspace.aiCorrectionPreview = ai
        #expect(f.workspace.presetPreview == nil)
        f.model.invalidate(library: f.library, editor: f.editor)
        #expect(!f.model.hasPreview && f.workspace.aiCorrectionPreview?.settings == settings)
        #expect(f.model.apply(library: f.library, editor: f.editor) == nil)
        await (try #require(f.preview())).value
        #expect(f.workspace.aiCorrectionPreview == nil && f.workspace.presetPreview != nil)
        #expect(f.editor.localRevision(for: f.assetID) == 0)
        #expect(await f.editor.finishSaving())
    }

    @Test func mountedCompactPanelExposesPersonalAndSeriesActions() async throws {
        let f = try await PresetFixture.make()
        defer { f.remove() }
        let host = WorkspaceSectionTestHost(size: NSSize(width: 320, height: 900))
        defer { host.close() }
        try await host.mount(DevelopPresetsPanel(library: f.library, model: f.model)
            .environmentObject(f.editor).environmentObject(f.workspace).frame(width: 280))
        let disclosure = try #require(host.accessibilityElements.first {
            $0.accessibilityRole() == .disclosureTriangle
        })
        try #require(disclosure.accessibilityPerformPress())
        try await host.settle()
        for id in ["develop.presets.selection", "develop.presets.preview", "develop.presets.save",
                   "develop.transfer.copy", "develop.transfer.open"] {
            #expect(host.accessibilityElements.contains { $0.accessibilityIdentifier() == id })
        }
        for group in DevelopPresetGroup.allCases {
            let toggle = try #require(host.accessibilityElements.first {
                $0.accessibilityIdentifier() == "develop.groups.\(group.rawValue)"
            })
            #expect(toggle.accessibilityFrame().width > 0)
        }
        try await host.unmount()
    }
}

private actor PresetValidationGate {
    let entered = TestAsyncLatch(), release = TestAsyncLatch()
    private var calls = 0
    func validate() async {
        calls += 1
        if calls == 2 { entered.releaseAll(); await release.wait() }
    }
}

@MainActor private struct PresetFixture {
    let directory: URL
    let library: LibraryModel
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let model: DevelopPresetsModel
    let assetID: String
    var editingDirectory: URL { directory.appendingPathComponent("editing") }
    func preview() -> Task<Void, Never>? { model.showPreview(library: library, editor: editor, workspace: workspace) }
    func remove() { model.discard(); workspace.clear(); try? FileManager.default.removeItem(at: directory) }

    static func make(version: ToneProcessingVersion = .consistentV2,
                     render: @escaping DevelopPresetsModel.Render = { bitmap, _, _, _ in bitmap },
                     validate: @escaping DevelopPresetsModel.ValidateSource = { _, _ in }) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-PresetModel-\(UUID())")
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: directory.appendingPathComponent("photo.png"))
        let repository = CatalogRepository(directory: directory.appendingPathComponent("catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: directory.appendingPathComponent("editing"))
        try await waitForTestState("preset fixture", state: { @MainActor in
            !library.isLoading && !library.isProjecting && !editor.isLoading
        }, until: { $0 })
        library.selectedID = asset.id; library.workspaceMode = .develop
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [0], count: 3), shadows: 0, highlights: 0)
        })
        let snapshot = try #require(editor.aiSnapshot(in: library))
        workspace.bind(source: snapshot.source)
        let data = Data([128, 128, 128, 255])
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bitmap = PreviewBitmap(image: image)
        workspace.receive(bitmap, sourceBitmap: bitmap, sourceStamp: .init(device: 1, inode: 1, byteCount: 4,
            modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0))
        let store = DevelopPresetStore(directory: directory.appendingPathComponent("presets"))
        let preset = try DevelopPreset(name: "Licht und Details", patch: DevelopSettingsPatch(
            settings: EditSettings(exposure: 1.25, texture: 20, toneProcessingVersion: version), groups: [.light, .details]))
        try await store.save(preset)
        let model = DevelopPresetsModel(store: store, render: render, validateSource: validate)
        await model.load(); model.choose(preset.id)
        return Self(directory: directory, library: library, editor: editor, workspace: workspace, model: model, assetID: asset.id)
    }
}
