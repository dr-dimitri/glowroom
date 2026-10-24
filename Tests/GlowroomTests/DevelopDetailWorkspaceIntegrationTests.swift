import AppKit
import Darwin
import Foundation
import GlowroomCore
import QuartzCore
import SwiftUI
import Testing
@testable import Glowroom

/// Exercise the complete workspace, including the real photo NSImageView,
/// viewport overlays, inspector scroll view, and accepted-preview sink. Native
/// window state and cursor assertions stay ordered on the main actor. The
/// offscreen host simulates key-window eligibility so these event-dispatch and
/// rendered-pixel checks never activate the process or steal desktop focus.
@Suite("Detail picker workspace integration", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct DevelopDetailWorkspaceIntegrationTests {
    @Test
    func redEyeDragUsesActualImageCoordinatesInTheLowerZoomedViewport() async throws {
        let fixture = try await DetailWorkspaceFixture.make()
        let workspace = DevelopWorkspace()
        let host = DetailWorkspaceHost()
        defer { workspace.clear(); host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture, workspace: workspace)
        let asset = try #require(fixture.library.selectedAsset)
        fixture.editor.selectEditingFunction(EditingFunction(.redEye), assetID: asset.id)
        workspace.tool = .redEye
        try await host.wait { workspace.isOriginalCanvasReady && host.inputIfPresent("develop.interactive-canvas")?.inputEnabled == true }
        let before = fixture.editor.settings(for: asset.id).developGeometry.redEyeCorrections
        workspace.photoViewport.toggleZoom()
        let canvas = try host.input("develop.interactive-canvas")
        let scroll = try #require(canvas.enclosingScrollView)
        try await host.wait { scroll.magnification > 1.999 }
        try await host.settle()
        let image = DevelopCropCanvasPresentation.imageRect(sourceSize: fixture.imageSize, viewport: canvas.bounds.size)
        let visible = image.intersection(canvas.visibleRect)
        let start = CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.8)
        let end = CGPoint(x: start.x + 15, y: start.y + 10)
        try host.drag(canvas, from: start, to: end)
        let corrections = fixture.editor.settings(for: asset.id).developGeometry.redEyeCorrections
        let correction = try #require(corrections.last)
        #expect(corrections.count == before.count + 1)
        #expect(abs(correction.center.x - ((start.x + end.x) / 2 - image.minX) / image.width) < 0.000_001)
        #expect(abs(correction.center.y - ((start.y + end.y) / 2 - image.minY) / image.height) < 0.000_001)
        try host.drag(canvas, from: start, to: end,
            afterMouseDown: { fixture.editor.undo(assetID: asset.id) })
        #expect(fixture.editor.settings(for: asset.id).developGeometry.redEyeCorrections == before,
            "Undo must remove one red-eye transaction and reject the held drag's later release")
        #expect(await fixture.editor.flush())
        #expect(await fixture.library.finishSaving())
    }

    @Test(arguments: [0.0, 27.0])
    func zoomedCropHandlesKeepFourteenWindowPointHitTargets(angle: Double) async throws {
        let fixture = try await DetailWorkspaceFixture.make()
        let workspace = DevelopWorkspace()
        let host = DetailWorkspaceHost()
        defer { workspace.clear(); host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture, workspace: workspace)
        let asset = try #require(fixture.library.selectedAsset)
        fixture.editor.selectEditingFunction(EditingFunction(.crop), assetID: asset.id)
        workspace.tool = .crop
        var settings = fixture.editor.settings(for: asset.id)
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        settings.developGeometry.crop = crop
        settings.developGeometry.straightenAngle = angle
        fixture.editor.setSettings(settings, for: asset.id)
        try await host.wait { workspace.isOriginalCanvasReady && host.inputIfPresent("develop.interactive-canvas")?.inputEnabled == true }
        workspace.photoViewport.toggleZoom(at: CGPoint(x: 0.25, y: 0.5))
        let canvas = try host.input("develop.interactive-canvas")
        let scroll = try #require(canvas.enclosingScrollView)
        try await host.wait { scroll.magnification > 1.999 }
        try await host.settle()

        let size = canvas.bounds.size
        let rect = DevelopCropCanvasPresentation.imageRect(sourceSize: fixture.imageSize, viewport: size)
        let box = DevelopCropInteraction.box(crop: crop, imageRect: rect)
        let scale = DevelopCropCanvasPresentation.fittingScale(sourceSize: fixture.imageSize, viewport: size, angle: angle)
        let radians = angle * .pi / 180
        let cosine = CGFloat(cos(radians)), sine = CGFloat(sin(radians))
        let x = box.minX - size.width / 2, y = box.midY - size.height / 2
        let handle = CGPoint(x: size.width / 2 + scale * (x * cosine - y * sine),
                             y: size.height / 2 + scale * (x * sine + y * cosine))
        // Crop tools keep their own click routing. Pan the native viewport so
        // the tested handle and its entire physical hit area are visible.
        let clip = scroll.contentView
        let document = try #require(scroll.documentView)
        let documentHandle = canvas.convert(handle, to: document)
        var visible = clip.bounds
        visible.origin = CGPoint(x: documentHandle.x - visible.width / 2,
                                 y: documentHandle.y - visible.height / 2)
        clip.scroll(to: clip.constrainBoundsRect(visible).origin)
        scroll.reflectScrolledClipView(clip)
        try await host.settle()
        let windowHandle = canvas.convert(handle, to: nil)
        let outward = canvas.convert(CGPoint(x: handle.x - cosine, y: handle.y - sine), to: nil)
        let length = hypot(outward.x - windowHandle.x, outward.y - windowHandle.y)
        func point(at distance: CGFloat) -> CGPoint {
            canvas.convert(CGPoint(x: windowHandle.x + (outward.x - windowHandle.x) * distance / length,
                                   y: windowHandle.y + (outward.y - windowHandle.y) * distance / length), from: nil)
        }
        #expect(canvas.cursor(point(at: 13.9)) === DevelopCropCursor.cursor(for: .left, angle: angle))
        #expect(canvas.cursor(point(at: 14.1)) === NSCursor.crosshair,
            "Native magnification must not double a crop handle's physical hit radius")
        try host.drag(canvas, from: point(at: 13.9), to: point(at: 21.9))
        let resized = try #require(fixture.editor.settings(for: asset.id).developGeometry.crop)
        #expect(resized.x < crop.x)
        #expect(abs(resized.x + resized.width - crop.x - crop.width) < 0.000_01)
        workspace.photoViewport.toggleZoom()
        try await host.settle()
        try #require(scroll.magnification > 1 && scroll.magnification < 2)
        let fittingCanvas = try host.input("develop.interactive-canvas")
        try host.click(fittingCanvas, at: host.photoPoint(x: 0.5, y: 0.5, on: fittingCanvas))
        #expect(scroll.magnification == 1,
            "A tool click must finish zoom-out before capturing its local coordinates, even after panning mode ends")
        #expect(await fixture.editor.flush())
        #expect(await fixture.library.finishSaving())
    }

    @Test(arguments: [false, true], [false, true])
    func photoClickAndNavigatorDragShareTheActualViewportWithoutEditing(portrait: Bool, developing: Bool) async throws {
        let fixture = try await DetailWorkspaceFixture.make(pixelWidth: portrait ? 800 : 1_200,
            pixelHeight: portrait ? 1_200 : 800, withAlternateAsset: true)
        fixture.library.isDeveloping = developing
        fixture.layout.update(developing: developing) {
            $0.showsLibrary = true
            $0.showsFilmstrip = false
        }
        let workspace = DevelopWorkspace()
        let host = DetailWorkspaceHost()
        defer { workspace.clear(); host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture, workspace: workspace)
        if !developing {
            host.window.setContentSize(NSSize(width: 1_000, height: 660))
            try await host.settle()
        }
        let asset = try #require(fixture.library.selectedAsset)
        let snapshot = fixture.editor.snapshot(for: asset.id)
        let canvas = try host.input("workspace.photo-navigation")
        let anchor = CGPoint(x: 0.75, y: 0.7)
        let point = host.photoPoint(x: anchor.x, y: anchor.y, on: canvas)
        #expect(canvas.cursor(point) === PhotoCanvasCursors.zoomIn)
        try host.click(canvas, at: point)
        let scroll = try #require(canvas.enclosingScrollView)
        try await host.wait { workspace.photoViewport.isZoomed && scroll.magnification > 1.999 }
        try await host.settle()
        let visible = workspace.photoViewport.normalizedVisibleRect
        #expect(visible.width < 0.99 || visible.height < 0.99)
        #expect(visible.contains(anchor), "The clicked image location must be visible after the animated zoom")
        #expect(visible.midX > 0.5 || visible.midY > 0.5,
            "An off-center click must select a different viewport from a centered click")
        #expect(try host.input("workspace.photo-navigation").cursor(point) === NSCursor.openHand)
        if !portrait, let path = ProcessInfo.processInfo.environment["GLOWROOM_ZOOM_CAPTURE"] {
            let url = URL(fileURLWithPath: path)
            try host.capture(to: developing ? url : url.deletingPathExtension()
                .appendingPathExtension("library.png"))
        }

        // Exercise native dispatch in the lower visible image too: SwiftUI's
        // hosting hit graph can otherwise clip this region at magnification.
        let zoomedCanvas = try host.input("workspace.photo-navigation")
        let photoRect = DevelopCropCanvasPresentation.imageRect(sourceSize: fixture.imageSize,
            viewport: zoomedCanvas.bounds.size)
        let visiblePhoto = zoomedCanvas.visibleRect.intersection(photoRect)
        let panStart = CGPoint(x: visiblePhoto.midX, y: visiblePhoto.minY + visiblePhoto.height * 0.8)
        try host.drag(zoomedCanvas, from: panStart,
            to: CGPoint(x: panStart.x + 15, y: panStart.y + 10))
        try await host.settle()
        let beforeNavigator = workspace.photoViewport.normalizedVisibleRect
        #expect(beforeNavigator != visible, "Dragging the lower zoomed photo must pan the actual viewport")

        let navigator = try host.input("workspace.navigator-input")
        try host.drag(navigator,
            from: CGPoint(x: beforeNavigator.midX * navigator.bounds.width, y: beforeNavigator.midY * navigator.bounds.height),
            to: CGPoint(x: 0, y: 0))
        try await host.settle()
        let moved = workspace.photoViewport.normalizedVisibleRect
        #expect(moved.minX <= beforeNavigator.minX && moved.minY <= beforeNavigator.minY)
        #expect(moved != beforeNavigator, "Dragging the white navigator rectangle must move the real photo")
        #expect(abs(moved.width - beforeNavigator.width) < 0.001 && abs(moved.height - beforeNavigator.height) < 0.001)
        #expect(fixture.editor.snapshot(for: asset.id) == snapshot)
        #expect(!fixture.editor.canUndo(assetID: asset.id))

        if !developing {
            let sidebar = try #require(navigator.enclosingScrollView)
            let document = try #require(sidebar.documentView)
            let clip = sidebar.contentView
            #expect(clip.bounds.height > 100)
            #expect(document.bounds.height > clip.bounds.height,
                "At minimum window height, the navigator and folders must share scrollable space")
            clip.scroll(to: CGPoint(x: 0, y: document.bounds.height - clip.bounds.height))
            sidebar.reflectScrolledClipView(clip)
            try await host.settle()
            #expect(navigator.visibleRect.intersection(navigator.bounds).height < navigator.bounds.height,
                "The navigator must scroll away so every folder remains reachable")
        }

        let alternate = try #require(fixture.library.visibleAssets.first { $0.id != asset.id })
        fixture.library.select(alternate)
        try await host.wait { !workspace.photoViewport.isZoomed && scroll.magnification < 1.001 }
        #expect(workspace.photoViewport.normalizedVisibleRect == PhotoViewportGeometry.unitRect)
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.flush())
    }

    @Test func capturedLevelsSelectionRejectsSynchronousLibraryABAWithoutAnyViewCallback() async throws {
        let fixture = try await DetailWorkspaceFixture.make(withAlternateAsset: true)
        defer { fixture.removeTemporaryFiles() }
        let first = try #require(fixture.library.selectedAsset)
        let second = try #require(fixture.library.visibleAssets.first { $0.id != first.id })
        let captured = DevelopSelectionIdentity(sessionID: fixture.library.aiSelectionSessionID,
                                                generation: fixture.library.aiSelectionGeneration)
        let editGeneration = fixture.editor.aiEditGeneration
        let snapshot = fixture.editor.snapshot(for: first.id)
        #expect(captured.matches(fixture.library))

        // No host is mounted and no suspension occurs between the two real
        // selection actions and the checks. View teardown/pending callbacks
        // therefore cannot be the mechanism that makes the old token stale.
        fixture.library.select(second)
        fixture.library.select(first)
        #expect(fixture.library.selectedID == first.id)
        #expect(fixture.library.aiSelectionGeneration == captured.generation + 2)
        #expect(fixture.editor.aiEditGeneration == editGeneration)
        #expect(fixture.editor.snapshot(for: first.id) == snapshot)
        #expect(!captured.matches(fixture.library),
            "Returning to the same asset and source must not revive an earlier automatic Levels request")
        let fresh = DevelopSelectionIdentity(sessionID: fixture.library.aiSelectionSessionID,
                                             generation: fixture.library.aiSelectionGeneration)
        #expect(fresh.matches(fixture.library))
        #expect(!DevelopSelectionIdentity(sessionID: UUID(), generation: fresh.generation).matches(fixture.library))
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [false, true])
    func actualAutomaticLevelsButtonRejectsLateSuccessAndFailureAfterLibraryABA(fails: Bool) async throws {
        let latch = TestAsyncLatch()
        let workspace = DevelopWorkspace(validateLevels: { _, _, _ in }, estimateLevels: { _, _, _ in
            await latch.wait() // Native work may finish after cancellation.
            if fails { throw EditRenderError.unavailable }
            return .value(LevelsSettings(master: .init(inputBlack: 0.2, inputWhite: 0.8)))
        })
        let fixture = try await DetailWorkspaceFixture.make(withAlternateAsset: true)
        fixture.layout.update(developing: true) {
            $0.openGroups = [.edit, .details]
            $0.openAdjustmentGroups.insert("tone")
        }
        let host = DetailWorkspaceHost()
        defer { latch.releaseAll(); workspace.clear(); host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture, workspace: workspace)
        let first = try #require(fixture.library.selectedAsset)
        let second = try #require(fixture.library.visibleAssets.first { $0.id != first.id })
        let captured = DevelopSelectionIdentity(sessionID: fixture.library.aiSelectionSessionID,
                                                generation: fixture.library.aiSelectionGeneration)
        try await host.wait { workspace.matchesLevelsDisplay(assetID: first.id, editor: fixture.editor, selection: captured) }
        let snapshot = fixture.editor.snapshot(for: first.id)
        let revision = fixture.editor.localRevision(for: first.id)
        let persisted = fixture.editor.persistedState(for: first.id)
        let editGeneration = fixture.editor.aiEditGeneration
        let button = try host.element("develop.levels.automatic")
        try #require(button.isAccessibilityEnabled())
        try #require(button.accessibilityPerformPress(), "Start the production automatic Levels action through its native AX button")
        try await host.wait { latch.waitingCount == 1 }
        let operation = try #require(workspace.levelsTask)
        let request = workspace.levelsRequest
        let display = try #require(workspace.levelsDisplay)

        // Keep A → B → A in one MainActor turn. The asset/source values and
        // accepted frame still match; only the live selection token differs.
        // The separate unmounted test above proves this guard independently
        // of any subsequent SwiftUI cancellation or render callback.
        fixture.library.select(second)
        fixture.library.select(first)
        #expect(fixture.library.selectedID == first.id)
        #expect(!captured.matches(fixture.library))
        #expect(workspace.levelsRequest == request)
        #expect(workspace.levelsDisplay?.identity == display.identity)
        #expect(fixture.editor.aiEditGeneration == editGeneration)
        workspace.errorMessage = "Rückmeldung der neueren Auswahl"
        latch.releaseAll()
        await operation.value

        #expect(fixture.editor.snapshot(for: first.id) == snapshot)
        #expect(fixture.editor.localRevision(for: first.id) == revision)
        #expect(!fixture.editor.canUndo(assetID: first.id))
        #expect(workspace.errorMessage == "Rückmeldung der neueren Auswahl")
        #expect(workspace.levelsSampleDescription == nil && !workspace.automaticLevelsBusy)
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.flush())
        #expect(fixture.editor.persistedState(for: first.id) == persisted)
    }

    @Test(arguments: [false, true], [0, 1, 2])
    func escapeCancelsAutomaticLevelsThroughTheRealWorkspaceKeyboardWithoutNavigating(focused: Bool, responder: Int) async throws {
        let latch = TestAsyncLatch()
        let workspace = DevelopWorkspace(estimateLevels: { _, _, _ in
            // Deliberately ignores cancellation until released, like an
            // already executing native operation. Late success must be inert.
            await latch.wait()
            return .value(LevelsSettings(master: .init(inputBlack: 0.2, inputWhite: 0.8)))
        })
        let fixture = try await DetailWorkspaceFixture.make()
        if focused {
            WorkspaceActions.toggleFocus(fixture.layout, library: fixture.library)
            fixture.layout.update(developing: true) { $0.showsTools = true; $0.openGroups = [.details] }
        }
        let host = DetailWorkspaceHost()
        defer { latch.releaseAll(); workspace.clear(); host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture, workspace: workspace)
        let assetID = try #require(fixture.library.selectedID)
        let selection = DevelopSelectionIdentity(sessionID: fixture.library.aiSelectionSessionID,
                                                 generation: fixture.library.aiSelectionGeneration)
        try await host.wait { workspace.matchesLevelsDisplay(assetID: assetID, editor: fixture.editor, selection: selection) }
        let snapshot = fixture.editor.snapshot(for: assetID)
        let revision = fixture.editor.localRevision(for: assetID)
        let task = try #require(workspace.applyAutomaticLevels(assetID: assetID, editor: fixture.editor,
            selection: selection, isCurrent: { fixture.library.selectedID == assetID }))
        try await host.wait { latch.waitingCount == 1 }
        try #require(workspace.automaticLevelsBusy && workspace.levelsPicker == nil)
        let request = workspace.levelsRequest
        let detail = fixture.library.showsDetail
        let input = try host.keyboardInput()
        let button = AutomaticLevelsEscapeTestButton(title: "Automatic Levels", target: nil, action: nil)
        if responder == 1 {
            host.window.contentView?.addSubview(button)
            try #require(host.window.makeFirstResponder(button))
            try #require(host.window.firstResponder === button)
        } else if responder == 2 {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            text.string = "Active native text input"
            host.window.contentView?.addSubview(text)
            try #require(host.window.makeFirstResponder(text))
            try #require(host.window.firstResponder === text)
        } else {
            try #require(host.window.makeFirstResponder(nil))
            try #require(!(host.window.firstResponder is NSControl))
        }
        try #require(input.process(try host.escapeEvent()) == nil,
            "The mounted production keyboard route must consume Escape for automatic Levels even without a picker")
        // Check synchronously: later View teardown must not be what cancels it.
        #expect(workspace.levelsRequest != request && !workspace.automaticLevelsBusy && workspace.levelsTask == nil)
        #expect(fixture.layout.isFocused == focused && fixture.library.showsDetail == detail)
        #expect(fixture.library.selectedID == assetID)
        latch.releaseAll(); await task.value
        #expect(fixture.editor.snapshot(for: assetID) == snapshot)
        #expect(fixture.editor.localRevision(for: assetID) == revision)
        #expect(!fixture.editor.canUndo(assetID: assetID))
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.flush())
    }

    @Test func comparisonPausesDirectInputAndSingleButtonRestoresThePicker() async throws {
        let fixture = try await DetailWorkspaceFixture.make()
        let host = DetailWorkspaceHost()
        defer { host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture)
        try await host.activatePicker()
        let assetID = try #require(fixture.library.selectedID)
        let snapshot = fixture.editor.snapshot(for: assetID)

        for layout in [PreviewComparisonLayout.leftRight, .splitLeftRight, .topBottom, .splitTopBottom] {
            fixture.library.showPreviewComparison(layout)
            try await host.wait {
                host.inputIfPresent("workspace.comparison-navigation") != nil
                    && host.inputIfPresent("develop.detail-canvas") == nil
            }
            #expect(host.inputIfPresent("workspace.photo-navigation") == nil)
            #expect(try host.element("workspace.compare").accessibilityValue() as? String == layout.title)
            #expect(try host.element("develop.detail-picker").accessibilityValue() as? String == "Inaktiv")
            #expect(fixture.editor.snapshot(for: assetID) == snapshot)
            let navigation = try host.input("workspace.comparison-navigation")
            let fittedSize = navigation.bounds.size
            let zoom = try host.element("workspace.zoom")
            try #require(zoom.accessibilityPerformPress())
            try await host.settle()
            #expect(try host.input("workspace.comparison-navigation").bounds.size == fittedSize,
                "Zoom must enlarge the photographs inside fixed comparison panes")
            #expect(try host.element("workspace.zoom").accessibilityLabel() == "Einpassen")
            try #require(zoom.accessibilityPerformPress())
            try await host.settle()
        }

        let single = try host.element("workspace.single-preview")
        try #require(single.accessibilityPerformPress())
        try await host.wait { host.inputIfPresent("workspace.photo-navigation") != nil }
        #expect(fixture.library.previewComparisonLayout == .single)
        try await host.activatePicker()
        #expect(fixture.editor.snapshot(for: assetID) == snapshot)
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.finishSaving())
    }

    @Test(arguments: [false, true], [false, true])
    func escapeInTheRealZoomPopupOnlyDismissesTheMenu(focused: Bool, pickingDetail: Bool) async throws {
        // AppKit menu tracking owns a process-wide run loop. Run each native
        // case in its own Swift Testing process while other suites stay parallel.
        try await runNativeZoomMenuChild(focused: focused, pickingDetail: pickingDetail)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment[nativeZoomChildResult] != nil))
    func nativeZoomMenuChildOnly() async throws {
        let environment = ProcessInfo.processInfo.environment
        let result = try #require(environment[nativeZoomChildResult])
        let token = try #require(environment[nativeZoomChildToken])
        let focused = try #require(environment[nativeZoomChildFocus]) == "true"
        let pickingDetail = try #require(environment[nativeZoomChildPicker]) == "true"
        // Required assertions throw before the completion marker on failure.
        try await verifyNativeZoomEscape(focused: focused, pickingDetail: pickingDetail)
        // Exit status alone is insufficient: AppKit can stop SwiftPM's root
        // loop and exit 0 before the test returns. Only this final checkpoint
        // proves that every native menu/workspace assertion was reached.
        try token.write(to: URL(fileURLWithPath: result), atomically: true, encoding: .utf8)
    }

    private func verifyNativeZoomEscape(focused: Bool, pickingDetail: Bool) async throws {
        let fixture = try await DetailWorkspaceFixture.make()
        if focused {
            WorkspaceActions.toggleFocus(fixture.layout, library: fixture.library)
            fixture.layout.update(developing: true) { $0.showsTools = true; $0.openGroups = [.details] }
        }
        let host = DetailWorkspaceHost()
        defer { host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture)
        if pickingDetail { try await host.activatePicker() }
        let canvas = pickingDetail ? try host.input("develop.detail-canvas") : nil
        let input = try host.keyboardInput()
        let zoom = try host.element("develop.detail-zoom")
        let previousZoom = try #require(zoom.accessibilityValue() as? String)
        let selection = fixture.library.selectedID
        // Native menu tracking does not necessarily move first responder. Keep
        // this regression independent of the existing NSControl/text guards.
        try #require(host.window.makeFirstResponder(nil))
        try #require(!(host.window.firstResponder is NSControl))

        let probe = NativeZoomMenuProbe(input: input, canvas: canvas, escape: try host.escapeEvent())
        try probe.openAndDismiss(zoom)
        try #require(!probe.timedOut, "The posted Escape must dismiss the native zoom menu")
        try #require(probe.escapeStayedWithMenu)
        try #require(fixture.library.showsDetail && fixture.library.isDeveloping)
        try #require(fixture.layout.isFocused == focused)
        try #require(fixture.library.selectedID == selection)
        try #require(try host.element("develop.detail-zoom").accessibilityValue() as? String == previousZoom)
        if let canvas {
            try #require(probe.pickerStayedActive)
            try #require(try host.element("develop.detail-picker").accessibilityValue() as? String == "Aktiv")
            try #require(canvas.cancelForEscape(), "The first Escape after menu dismissal must cancel the active picker")
            try await host.wait { host.inputIfPresent("develop.detail-canvas") == nil }
            try #require(fixture.library.showsDetail && fixture.layout.isFocused == focused)
        }

        try #require(host.window.makeFirstResponder(nil))
        try #require(input.process(try host.escapeEvent()) == nil,
            "Once native menu/picker handling finishes, Escape must reach the workspace again")
        try #require(!fixture.layout.isFocused)
        try #require(fixture.library.showsDetail == focused,
            "Ordinary workspace Escape leaves focus first, or leaves detail in the classic workspace")
        try #require(await fixture.library.finishSaving())
        try #require(await fixture.editor.flush())
    }

    @Test func realWorkspaceHeaderActivatesPickerAndPhotoClickChangesTheLoupe() async throws {
        let fixture = try await DetailWorkspaceFixture.make()
        let host = DetailWorkspaceHost()
        defer { host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture)

        try await host.activatePicker()
        let canvas = try host.input("develop.detail-canvas")
        #expect(canvas.inputEnabled)
        let right = host.photoPoint(x: 0.75, y: 0.5, on: canvas)
        try host.click(canvas, at: right)
        try await host.wait { host.inputIfPresent("develop.detail-canvas") == nil }
        let rightRed = try await host.loupeRed()

        try await host.activatePicker()
        let nextCanvas = try host.input("develop.detail-canvas")
        try host.click(nextCanvas, at: host.photoPoint(x: 0.25, y: 0.5, on: nextCanvas))
        try await host.wait { host.inputIfPresent("develop.detail-canvas") == nil }
        let leftRed = try await host.loupeRed()
        #expect(rightRed > leftRed + 0.4,
            "Selecting different photograph regions must change the pixels shown by the actual inspector loupe")
        #expect(try host.element("develop.detail-picker").accessibilityValue() as? String == "Inaktiv")
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.flush())
    }

    @Test func mountedWorkspaceFollowsApplicationMouseEventsAndRestoresTheCursorOutsideThePhoto() async throws {
        let fixture = try await DetailWorkspaceFixture.make()
        let host = DetailWorkspaceHost()
        defer { host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture)
        try await host.activatePicker()
        let canvas = try host.input("develop.detail-canvas")
        #expect(host.window.isKeyWindow, "The offscreen host supplies simulated key-window eligibility")
        #expect(host.window.acceptsMouseMovedEvents)
        let originalResponder = host.window.firstResponder

        try host.move(canvas, to: host.photoPoint(x: 0.25, y: 0.5, on: canvas))
        // Cursor state is process-wide; assert the event's immediate result
        // before yielding to unrelated tracking callbacks or other UI tests.
        #expect(NSCursor.current == .crosshair)
        let leftRed = try await host.loupeRed()
        try host.move(canvas, to: host.photoPoint(x: 0.75, y: 0.5, on: canvas))
        #expect(NSCursor.current == .crosshair)
        let rightRed = try await host.loupeRed()
        #expect(rightRed > leftRed + 0.4,
            "An application mouseMoved event must update the real loupe without a click")
        #expect(try host.element("develop.detail-picker").accessibilityValue() as? String == "Aktiv")
        #expect(host.window.firstResponder === originalResponder)

        let photoRect = DevelopCropCanvasPresentation.imageRect(
            sourceSize: CGSize(width: 1_200, height: 800), viewport: canvas.bounds.size)
        let margin = photoRect.minX > 1
            ? CGPoint(x: 0, y: canvas.bounds.midY) : CGPoint(x: canvas.bounds.midX, y: 0)
        #expect(!photoRect.contains(margin), "The real canvas must have a letterbox margin for this assertion")
        try host.move(canvas, to: margin)
        #expect(NSCursor.current == .arrow)
        #expect(abs(try await host.loupeRed() - rightRed) < 0.02,
            "Moving across a canvas margin must preserve the last selected detail")

        let lockedPoint = host.photoPoint(x: 0.25, y: 0.5, on: canvas)
        try host.click(canvas, at: lockedPoint)
        #expect(NSCursor.current == .arrow)
        try await host.wait { host.inputIfPresent("develop.detail-canvas") == nil }
        #expect(try host.element("develop.detail-picker").accessibilityValue() as? String == "Inaktiv")
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.flush())
    }

    /// This measures already-decoded preview interaction, not source loading
    /// or physical input/key-focus/WindowServer presentation behavior. The
    /// simulated key eligibility is identical before and after optimization.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_DETAIL_WORKSPACE_BENCHMARK"] == "1"))
    func benchmarkFullWorkspacePointerUpdates() async throws {
        let fixture = try await DetailWorkspaceFixture.make(pixelWidth: 2_400, pixelHeight: 1_600)
        let host = DetailWorkspaceHost()
        defer { host.close(); fixture.removeTemporaryFiles() }
        try await host.mount(fixture)
        try await host.activatePicker()
        let canvas = try host.input("develop.detail-canvas")
        try #require(host.window.isKeyWindow && host.window.acceptsMouseMovedEvents && canvas.inputEnabled)

        // No awaits, artificial delays, or source/cache resets between the
        // series. Force the pending native layout/display for every movement.
        let initial = try host.measurePointerSeries(canvas: canvas, count: 120)
        let warm = try host.measurePointerSeries(canvas: canvas, count: 120)
        let report: [String: Any] = [
            "benchmark": "detail-picker-full-workspace",
            "preview_pixels": [2_400, 1_600],
            "window_points": [1_200, 800],
            "movements_per_series": 120,
            "key_window_eligibility": "simulated by offscreen test-window override; test does not activate the process",
            "initial": initial.summary,
            "warm": warm.summary,
            "scope": "NSApplication.sendEvent plus synchronous native layout/display and CATransaction.flush; loaded source; no per-step sleep",
            "initial_cache_state": "accepted full-resolution preview; first measured pointer series; OS/GPU caches not cleared",
            "warm_cache_state": "immediately following series in the same workspace and process",
            "excluded": "source decoding, setup, two pixel-validation snapshots per series, physical input, actual key-focus acquisition and WindowServer presentation latency"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("GLOWROOM_DETAIL_WORKSPACE_BENCHMARK \(String(decoding: data, as: UTF8.self))")
        #expect(try host.element("develop.detail-picker").accessibilityValue() as? String == "Aktiv")
        #expect(await fixture.library.finishSaving())
        #expect(await fixture.editor.flush())
    }
}

@MainActor
private struct DetailWorkspaceFixture {
    let directory: URL
    let preferenceSuite: String
    let imageSize: CGSize
    let library: LibraryModel
    let editor: EditingModel
    let layout: WorkspaceLayoutModel
    let metadata: PhotoMetadataModel
    let exporter: JPEGExportModel

    static func make(pixelWidth: Int = 1_200, pixelHeight: Int = 800,
                     withAlternateAsset: Bool = false) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-DetailWorkspace-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferenceSuite = "Glowroom-DetailWorkspace-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: preferenceSuite))
        let layout = WorkspaceLayoutModel(defaults: defaults)
        layout.update(developing: true) {
            $0.showsLibrary = false
            $0.showsFilmstrip = false
            $0.showsTools = true
            $0.openGroups = [.details]
        }
        let imageURL = directory.appendingPathComponent("synthetic-detail.png")
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (x, red) in [(0, 0.1), (pixelWidth / 2, 0.9)] {
            context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: pixelWidth / 2, height: pixelHeight))
        }
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: imageURL)
        let modifiedAt = try #require(FileManager.default.attributesOfItem(atPath: imageURL.path)[.modificationDate] as? Date)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: imageURL, fileSize: Int64(png.count),
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, createdAt: modifiedAt, modifiedAt: modifiedAt)
        var assets = [asset]
        if withAlternateAsset {
            let alternateURL = directory.appendingPathComponent("synthetic-detail-alternate.png")
            try png.write(to: alternateURL)
            assets.append(PhotoAsset(folderID: folder.id, fileURL: alternateURL, fileSize: Int64(png.count),
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, createdAt: modifiedAt, modifiedAt: modifiedAt))
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: directory.appendingPathComponent("Editing"))
        let analysis = ImageAnalysisService(provider: UnavailableImageAnalysisProvider(reason: .sdkUnavailable),
            budget: AIResourceBudget())
        let metadata = PhotoMetadataModel(store: PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata")),
            suggestor: LocalPhotoMetadataSuggestor(service: analysis), library: library, editor: editor)
        try await waitForDetailWorkspace { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.select(asset)
        library.isDeveloping = true
        library.showsDetail = true
        return Self(directory: directory, preferenceSuite: preferenceSuite,
            imageSize: CGSize(width: pixelWidth, height: pixelHeight), library: library, editor: editor,
            layout: layout, metadata: metadata, exporter: JPEGExportModel(preferences: nil))
    }

    func removeTemporaryFiles() {
        UserDefaults(suiteName: preferenceSuite)?.removePersistentDomain(forName: preferenceSuite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class DetailWorkspaceHost {
    let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var imageSize = CGSize.zero

    init() {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        window = DetailWorkspaceTestWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1_200, height: 800),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    func mount(_ fixture: DetailWorkspaceFixture, workspace: DevelopWorkspace? = nil) async throws {
        imageSize = fixture.imageSize
        hosting.rootView = AnyView(LibraryView(model: fixture.library, dataDirectory: fixture.directory, developWorkspace: workspace)
            .environmentObject(fixture.editor).environmentObject(fixture.layout)
            .environmentObject(fixture.metadata).environmentObject(fixture.exporter)
            .environment(\.displayScale, 2).preferredColorScheme(.dark))
        try await wait {
            self.nativeViews.contains { ($0 as? NSImageView)?.image?.size == fixture.imageSize }
                && self.inputIfPresent(fixture.library.isDeveloping
                    ? "develop.detail-loupe" : "workspace.photo-navigation") != nil
        }
        try await settle()
    }

    func activatePicker() async throws {
        let button = try element("develop.detail-picker")
        try #require(button.isAccessibilityEnabled())
        try #require(button.accessibilityPerformPress(), "Activate the production inspector button through its AX action")
        try await wait { self.inputIfPresent("develop.detail-canvas")?.inputEnabled == true }
        try await settle()
        #expect(try element("develop.detail-picker").accessibilityValue() as? String == "Aktiv")
    }

    func photoPoint(x: CGFloat, y: CGFloat, on canvas: NSView) -> CGPoint {
        let rect = DevelopCropCanvasPresentation.imageRect(
            sourceSize: imageSize, viewport: canvas.bounds.size)
        return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    func click(_ canvas: DevelopCropNativeInputView, at point: CGPoint) throws {
        try requireHit(canvas, at: point)
        // A native mouseDown can finish zoom before mouseUp. Both events
        // still belong to the same physical window point.
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map {
            try mouseEvent($0, canvas: canvas, point: point)
        }
        for event in events { window.sendEvent(event) }
    }

    func drag(_ canvas: DevelopCropNativeInputView, from start: CGPoint, to end: CGPoint,
              afterMouseDown: (() -> Void)? = nil) throws {
        try requireHit(canvas, at: start)
        // The document moves during a pan; retain the original window-space
        // trajectory for every event in this physical mouse gesture.
        let events = try [mouseEvent(.leftMouseDown, canvas: canvas, point: start),
            mouseEvent(.leftMouseDragged, canvas: canvas, point: end),
            mouseEvent(.leftMouseUp, canvas: canvas, point: end)]
        for (index, event) in events.enumerated() {
            window.sendEvent(event)
            if index == 0 { afterMouseDown?() }
        }
    }

    func capture(to url: URL) throws {
        hosting.displayIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    func move(_ canvas: DevelopCropNativeInputView, to point: CGPoint) throws {
        try requireHit(canvas, at: point)
        NSApplication.shared.sendEvent(try mouseEvent(.mouseMoved, canvas: canvas, point: point))
    }

    private func requireHit(_ canvas: NSView, at point: CGPoint) throws {
        try #require(hosting.hitTest(canvas.convert(point, to: hosting.superview)) === canvas,
            "The full workspace's native hit target must be the detail surface")
    }

    private func mouseEvent(_ type: NSEvent.EventType, canvas: NSView, point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    func loupeRed() async throws -> CGFloat {
        try await settle()
        return try captureLoupeRed()
    }

    private func captureLoupeRed() throws -> CGFloat {
        let loupe = try input("develop.detail-loupe")
        // Capture the real image behind the transparent native loupe
        // surface, not the surface itself. Its center is away from all chrome.
        for view in nativeViews { view.needsDisplay = true }
        hosting.displayIfNeeded()
        let rect = loupe.convert(loupe.bounds, to: hosting)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: rect))
        hosting.cacheDisplay(in: rect, to: bitmap)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return color.redComponent
    }

    func measurePointerSeries(canvas: DevelopCropNativeInputView, count: Int) throws -> DetailPointerMeasurements {
        var elapsedMilliseconds: [Double] = []
        elapsedMilliseconds.reserveCapacity(count)
        var firstRed: CGFloat?
        var phaseTotals: [String: Double] = [:]
        func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: end).components
            return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        }
        for index in 0..<count {
            let point = photoPoint(x: index.isMultiple(of: 2) ? 0.75 : 0.25,
                y: 0.2 + CGFloat(index % 11) * 0.06, on: canvas)
            let started = ContinuousClock.now
            try requireHit(canvas, at: point)
            let hitChecked = ContinuousClock.now
            NSApplication.shared.sendEvent(try mouseEvent(.mouseMoved, canvas: canvas, point: point))
            let moved = ContinuousClock.now
            hosting.layoutSubtreeIfNeeded()
            let laidOut = ContinuousClock.now
            hosting.displayIfNeeded()
            let displayed = ContinuousClock.now
            CATransaction.flush()
            let flushed = ContinuousClock.now
            elapsedMilliseconds.append(milliseconds(from: started, to: flushed))
            phaseTotals["hit_check_mean_ms", default: 0] += milliseconds(from: started, to: hitChecked) / Double(count)
            phaseTotals["event_mean_ms", default: 0] += milliseconds(from: hitChecked, to: moved) / Double(count)
            phaseTotals["layout_mean_ms", default: 0] += milliseconds(from: moved, to: laidOut) / Double(count)
            phaseTotals["display_mean_ms", default: 0] += milliseconds(from: laidOut, to: displayed) / Double(count)
            phaseTotals["flush_mean_ms", default: 0] += milliseconds(from: displayed, to: flushed) / Double(count)
            // Validate actual rendered output at both ends without putting
            // screenshot allocation/copying in the reported event timings.
            if index == 0 { firstRed = try captureLoupeRed() }
            if index == count - 1 {
                let lastRed = try captureLoupeRed()
                let initialRed = try #require(firstRed)
                #expect(initialRed > lastRed + 0.4,
                    "The measured series must really update the full workspace's visible loupe")
            }
        }
        return DetailPointerMeasurements(milliseconds: elapsedMilliseconds, phaseMeans: phaseTotals)
    }

    func element(_ identifier: String) throws -> WorkspaceAccessibilityElement {
        try #require(WorkspaceAccessibilityElement.descendants(of: hosting).first {
            $0.accessibilityIdentifier() == identifier
        }, "Missing workspace control \(identifier)")
    }

    func keyboardInput() throws -> WorkspaceKeyboardInputView {
        try #require(nativeViews.compactMap { $0 as? WorkspaceKeyboardInputView }.first)
    }

    func escapeEvent() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    func input(_ identifier: String) throws -> DevelopCropNativeInputView {
        try #require(inputIfPresent(identifier), "Missing native workspace surface \(identifier)")
    }

    func inputIfPresent(_ identifier: String) -> DevelopCropNativeInputView? {
        nativeViews.compactMap { $0 as? DevelopCropNativeInputView }.first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    private var nativeViews: [NSView] {
        var pending: [NSView] = [hosting], result: [NSView] = []
        while let view = pending.popLast() { result.append(view); pending.append(contentsOf: view.subviews) }
        return result
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        try await waitForDetailWorkspace {
            self.hosting.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    func close() {
        hosting.rootView = AnyView(EmptyView())
        window.close()
    }
}

@MainActor
private final class AutomaticLevelsEscapeTestButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

private let nativeZoomChildResult = "GLOWROOM_TEST_ZOOM_MENU_RESULT"
private let nativeZoomChildToken = "GLOWROOM_TEST_ZOOM_MENU_TOKEN"
private let nativeZoomChildFocus = "GLOWROOM_TEST_ZOOM_MENU_FOCUS"
private let nativeZoomChildPicker = "GLOWROOM_TEST_ZOOM_MENU_PICKER"

/// Launch, timeout and kernel reaping are blocking OS operations. A single
/// bounded background wait leaves MainActor and Swift's executor available to
/// the other suites. The suite orders these four child cases to bound processes.
private func runNativeZoomMenuChild(focused: Bool, pickingDetail: Bool) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try launchNativeZoomMenuChild(focused: focused, pickingDetail: pickingDetail)
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
}

private func launchNativeZoomMenuChild(focused: Bool, pickingDetail: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-ZoomMenu-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = directory.appendingPathComponent("complete.txt")
    let log = directory.appendingPathComponent("child.log")
    try Data().write(to: log)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let token = UUID().uuidString
    let invocation = CommandLine.arguments
    let child = Process(), ended = DispatchSemaphore(value: 0)
    child.executableURL = URL(fileURLWithPath: invocation[0])
    var arguments: [String] = []
    if let index = invocation.firstIndex(of: "--test-bundle-path"), index + 1 < invocation.count {
        arguments = ["--test-bundle-path", invocation[index + 1]]
    }
    child.arguments = arguments + ["--testing-library", "swift-testing", "--filter", "nativeZoomMenuChildOnly"]
    var environment = ProcessInfo.processInfo.environment
    environment[nativeZoomChildResult] = result.path
    environment[nativeZoomChildToken] = token
    environment[nativeZoomChildFocus] = String(focused)
    environment[nativeZoomChildPicker] = String(pickingDetail)
    child.environment = environment
    child.standardOutput = output; child.standardError = output
    child.terminationHandler = { _ in ended.signal() }
    try child.run()
    let completed = ended.wait(timeout: .now() + 20) == .success
    if !completed {
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        let reaped = ended.wait(timeout: .now() + 2) == .success
        throw NativeZoomMenuChildFailure(focused: focused, pickingDetail: pickingDetail,
            reason: "timed out; SIGKILL reaped=\(reaped)", log: try nativeZoomChildLog(log))
    }
    let marker = try? String(contentsOf: result, encoding: .utf8)
    guard child.terminationReason == .exit, child.terminationStatus == 0, marker == token else {
        throw NativeZoomMenuChildFailure(focused: focused, pickingDetail: pickingDetail,
            reason: "status=\(child.terminationStatus), reason=\(child.terminationReason), completion=\(marker == token)",
            log: try nativeZoomChildLog(log))
    }
}

private func nativeZoomChildLog(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    try handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
    return String(decoding: try handle.read(upToCount: 65_536) ?? Data(), as: UTF8.self)
}

private struct NativeZoomMenuChildFailure: Error, CustomStringConvertible {
    let focused: Bool, pickingDetail: Bool
    let reason: String, log: String
    var description: String {
        "Native zoom menu child (focused=\(focused), picker=\(pickingDetail)) \(reason)\n\(log)"
    }
}

/// SwiftUI opens its native Picker menu asynchronously after the AX press.
/// Keep that tracking loop inside a bounded, nested run loop: yielding directly
/// to the SwiftPM host here lets AppKit stop the host's root run loop after menu
/// dismissal, which can exit with status 0 before Swift Testing reports results.
@MainActor
private final class NativeZoomMenuProbe {
    private let input: WorkspaceKeyboardInputView
    private let canvas: DevelopCropNativeInputView?
    private let escape: NSEvent
    private var menus: [ObjectIdentifier: NSMenu] = [:]
    private var observers: [NSObjectProtocol] = []
    private var timers: [Timer] = []
    private var started = false
    private(set) var escapeStayedWithMenu = false
    private(set) var pickerStayedActive = false
    private(set) var timedOut = false

    init(input: WorkspaceKeyboardInputView, canvas: DevelopCropNativeInputView?, escape: NSEvent) {
        self.input = input; self.canvas = canvas; self.escape = escape
    }

    func openAndDismiss(_ zoom: WorkspaceAccessibilityElement) throws {
        defer { stop() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                self?.begin(menu)
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                _ = self?.menus.removeValue(forKey: ObjectIdentifier(menu))
            }
        })
        try #require(zoom.accessibilityPerformPress(), "Open the production zoom Picker's actual native menu")
        let deadline = ContinuousClock.now + .seconds(3)
        while !started || !menus.isEmpty {
            try #require(ContinuousClock.now < deadline, "The native menu must finish tracking")
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func begin(_ menu: NSMenu) {
        started = true
        let id = ObjectIdentifier(menu)
        menus[id] = menu
        let timeout = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.menus[id] else { return }
                self.timedOut = true
                menu.cancelTrackingWithoutAnimation()
            }
        }
        let key = Timer(timeInterval: 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.menus[id] != nil else { return }
                // Notification observer order is unspecified. Wait until
                // every observer ran and the actual menu loop is active.
                // NSWindow.sendEvent bypasses local monitors in this host;
                // exercise both mounted production monitor paths explicitly.
                self.escapeStayedWithMenu = self.input.process(self.escape) === self.escape
                self.pickerStayedActive = self.canvas?.cancelForEscape() == false
                // AppKit must consume Escape and end its own tracking loop.
                NSApp.postEvent(self.escape, atStart: true)
            }
        }
        timers.append(contentsOf: [timeout, key])
        RunLoop.main.add(timeout, forMode: .eventTracking)
        RunLoop.main.add(key, forMode: .eventTracking)
    }

    private func stop() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        for menu in Array(menus.values) { menu.cancelTrackingWithoutAnimation() }
        menus.removeAll()
    }
}

@MainActor
private final class DetailWorkspaceTestWindow: NSWindow {
    // Match the existing offscreen native-input harness: exercise the complete
    // production hover path without activating this process. This represents
    // key eligibility, not proof of physical input delivery or desktop focus.
    override var isKeyWindow: Bool { true }
}

@MainActor
private func waitForDetailWorkspace(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw DetailWorkspaceTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct DetailWorkspaceTimeout: Error {}

private struct DetailPointerMeasurements {
    let milliseconds: [Double]
    let phaseMeans: [String: Double]
    var summary: [String: Double] {
        let sorted = milliseconds.sorted()
        let total = milliseconds.reduce(0, +)
        return [
            "total_ms": total,
            "mean_ms": total / Double(milliseconds.count),
            "p50_ms": sorted[Int((Double(sorted.count - 1) * 0.5).rounded())],
            "p95_ms": sorted[Int((Double(sorted.count - 1) * 0.95).rounded())],
            "max_ms": sorted.last ?? 0
        ].merging(phaseMeans, uniquingKeysWith: { current, _ in current })
    }
}
