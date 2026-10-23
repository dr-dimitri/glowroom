import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Before and after preview modes", .timeLimit(.minutes(1)))
@MainActor
struct PreviewComparisonModelTests {
    @Test
    func comparisonUsesCurrentEditsAndLeavesSnapshotsSelectionAndUndoIntact() async throws {
        try await withFixture { fixture in
            let model = fixture.library, editor = fixture.editor, asset = fixture.asset
            model.workspaceMode = .develop
            var settings = EditSettings.neutral
            settings.exposure = 0.7
            settings.shadows = 28
            editor.setSettings(settings, for: asset.id)
            #expect(await editor.finishSaving())
            let snapshot = editor.snapshot(for: asset.id)
            let revision = editor.localRevision(for: asset.id)
            let selectionGeneration = model.aiSelectionGeneration

            for layout in [PreviewComparisonLayout.leftRight, .splitLeftRight, .topBottom, .splitTopBottom] {
                model.showPreviewComparison(layout)
                let before = try editor.resolvedSource(for: asset, intent: .importedOriginal)
                let after = try editor.resolvedSource(for: asset, intent: model.editingRenderIntent)
                #expect(before.settings.isNeutral)
                #expect(after.settings == settings,
                    "The After pane must keep every edit while both panes are visible")
                #expect(model.editingRenderIntent == .currentEditing)
                #expect(model.selectedID == asset.id && model.aiSelectionGeneration == selectionGeneration)
                #expect(model.workspaceMode == .develop)
                #expect(editor.snapshot(for: asset.id) == snapshot)
                #expect(editor.localRevision(for: asset.id) == revision)
                #expect(editor.canUndo(assetID: asset.id) && !editor.canRedo(assetID: asset.id))
                #expect(!editor.hasPendingChanges)
            }

            model.showPreviewComparison(.single)
            #expect(model.editingRenderIntent == .currentEditing)
            editor.undo(assetID: asset.id)
            #expect(editor.settings(for: asset.id).isNeutral,
                "Changing comparison layouts must not add undo steps")
            #expect(!editor.canUndo(assetID: asset.id))
            editor.redo(assetID: asset.id)
            #expect(editor.snapshot(for: asset.id) == snapshot)
        }
    }

    @Test(arguments: [PreviewComparisonLayout.leftRight, .splitLeftRight, .topBottom, .splitTopBottom, .single])
    func selectingALayoutClearsBothSingleSourceComparisons(_ layout: PreviewComparisonLayout) async throws {
        try await withFixture { fixture in
            let model = fixture.library
            model.comparesOriginal = true
            #expect(model.editingRenderIntent == .importedOriginal)
            model.showPreviewComparison(layout)
            #expect(model.previewComparisonLayout == layout)
            #expect(!model.comparesOriginal && !model.comparesCurrentSourceWithoutSettings)
            #expect(model.editingRenderIntent == .currentEditing)

            model.comparesCurrentSourceWithoutSettings = true
            #expect(model.editingRenderIntent == .currentSourceWithoutSettings)
            model.showPreviewComparison(layout)
            #expect(model.previewComparisonLayout == layout)
            #expect(!model.comparesOriginal && !model.comparesCurrentSourceWithoutSettings)
            #expect(model.editingRenderIntent == .currentEditing)
        }
    }

    @Test(arguments: [true, false])
    func selectingASingleSourceLeavesSimultaneousComparison(_ original: Bool) async throws {
        try await withFixture { fixture in
            let model = fixture.library
            for layout in [PreviewComparisonLayout.leftRight, .splitLeftRight, .topBottom, .splitTopBottom] {
                model.showPreviewComparison(layout)
                if original { model.comparesOriginal = true }
                else { model.comparesCurrentSourceWithoutSettings = true }
                #expect(model.previewComparisonLayout == .single)
                #expect(model.comparesOriginal == original)
                #expect(model.comparesCurrentSourceWithoutSettings == !original)
                #expect(model.editingRenderIntent == (original ? .importedOriginal : .currentSourceWithoutSettings))
            }
        }
    }

    @Test
    func returningToSingleImageRemembersTheChosenComparisonLayout() async throws {
        try await withFixture { fixture in
            let model = fixture.library
            #expect(model.previewComparisonLayout == .single)
            #expect(model.lastPreviewComparisonLayout == .leftRight)
            for layout in [PreviewComparisonLayout.splitLeftRight, .topBottom, .splitTopBottom] {
                model.showPreviewComparison(layout)
                model.showPreviewComparison(.single)
                #expect(model.lastPreviewComparisonLayout == layout)
                model.showPreviewComparison(model.lastPreviewComparisonLayout)
                #expect(model.previewComparisonLayout == layout)
                model.comparesOriginal = true
                #expect(model.lastPreviewComparisonLayout == layout,
                    "The separate original-only view must not replace the last two-pane layout")
            }
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let asset: PhotoAsset
        let library: LibraryModel
        let editor: EditingModel

        func close() async {
            library.beginTermination()
            editor.beginTermination()
            _ = await editor.finishSaving()
            _ = await library.finishSaving()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func withFixture(_ operation: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glowroom-PreviewComparison-\(UUID().uuidString)", isDirectory: true)
        let photos = directory.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: photos)
        // Source resolution reads captured metadata only. These state tests do
        // not decode a photo or depend on the ignored local image fixtures.
        let asset = PhotoAsset(folderID: folder.id, fileURL: photos.appendingPathComponent("comparison.raw"))
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog", isDirectory: true))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: directory.appendingPathComponent("Editing", isDirectory: true))
        let fixture = Fixture(directory: directory, asset: asset, library: library, editor: editor)
        do {
            // Startup and each model's isolated storage can progress independently.
            async let loadedLibrary = library.finishSaving()
            async let loadedEditor = editor.finishSaving()
            let loaded = await (loadedLibrary, loadedEditor)
            try #require(loaded.0 && loaded.1)
            try #require(!library.isLoading && !editor.isLoading && editor.canEdit)
            await library.waitForProjection()
            library.selectedID = asset.id
            editor.library = library
            try await operation(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}

@Suite("Before and after preview geometry")
struct PreviewComparisonGeometryTests {
    @Test(arguments: [PreviewComparisonLayout.leftRight, .topBottom])
    func wholeImagePanesFitIndependentlyAndKeepEqualSpace(_ layout: PreviewComparisonLayout) {
        let full = CGRect(x: 0, y: 0, width: 800, height: 600)
        let geometry = PreviewComparisonGeometry(layout: layout, size: full.size, fraction: 0.8)
        #expect(geometry.beforeFrame.size == geometry.afterFrame.size)
        #expect(geometry.beforeFrame.union(geometry.afterFrame) == full)
        #expect(geometry.beforeFrame.intersection(geometry.afterFrame).isEmpty)
        #expect(geometry.beforeContentFrame == CGRect(origin: .zero, size: geometry.beforeFrame.size))
        #expect(geometry.afterContentFrame == CGRect(origin: .zero, size: geometry.afterFrame.size))
        #expect(geometry.dividerPosition == (layout == .leftRight ? 400 : 300),
            "A divider position from a split layout must not resize whole-image panes")
    }

    @Test(arguments: [PreviewComparisonLayout.splitLeftRight, .splitTopBottom])
    func splitPanesRevealTheSameFullCanvasWithoutRescaling(_ layout: PreviewComparisonLayout) {
        let full = CGRect(x: 0, y: 0, width: 800, height: 600)
        let geometry = PreviewComparisonGeometry(layout: layout, size: full.size, fraction: 0.25)
        #expect(geometry.beforeFrame.union(geometry.afterFrame) == full)
        #expect(geometry.beforeFrame.intersection(geometry.afterFrame).isEmpty)
        #expect(geometry.beforeContentFrame == full)
        #expect(geometry.afterContentFrame.offsetBy(dx: geometry.afterFrame.minX, dy: geometry.afterFrame.minY) == full,
            "A pixel must remain at the same global canvas coordinate on either side of the split")
        #expect(geometry.dividerPosition == (layout == .splitLeftRight ? 200 : 150))
    }

    @Test
    func singleImageUsesTheEntireCanvasWithoutABeforePane() {
        let full = CGRect(x: 0, y: 0, width: 800, height: 600)
        let geometry = PreviewComparisonGeometry(layout: .single, size: full.size)
        #expect(geometry.beforeFrame.isEmpty && geometry.beforeContentFrame.isEmpty)
        #expect(geometry.afterFrame == full && geometry.afterContentFrame == full)
        #expect(geometry.dividerPosition == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -2, 0, 0.1, 0.4, 0.9, 1, 2])
    func dividerClampingKeepsBothSidesReachable(_ fraction: Double) {
        let clamped = PreviewComparisonGeometry.clampedFraction(fraction)
        #expect(clamped.isFinite && (0.1...0.9).contains(clamped))
        if !fraction.isFinite { #expect(clamped == 0.5) }
        else if (0.1...0.9).contains(fraction) { #expect(clamped == fraction) }
        let geometry = PreviewComparisonGeometry(layout: .splitLeftRight,
            size: CGSize(width: 800, height: 600), fraction: fraction)
        #expect(geometry.beforeFrame.width >= 80 && geometry.afterFrame.width >= 80)
    }

    @Test
    func transientInvalidViewportSizesNeverProduceInvalidFrames() {
        for size in [CGSize.zero, CGSize(width: -1, height: 600),
                     CGSize(width: CGFloat.nan, height: CGFloat.infinity)] {
            for layout in PreviewComparisonLayout.allCases {
                let geometry = PreviewComparisonGeometry(layout: layout, size: size)
                for frame in [geometry.beforeFrame, geometry.afterFrame,
                              geometry.beforeContentFrame, geometry.afterContentFrame] {
                    #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
                    #expect(frame.width.isFinite && frame.width >= 0)
                    #expect(frame.height.isFinite && frame.height >= 0)
                }
            }
        }
    }
}
