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

    static func make(pixelWidth: Int = 1_200, pixelHeight: Int = 800) async throws -> Self {
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
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
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

    func mount(_ fixture: DetailWorkspaceFixture) async throws {
        imageSize = fixture.imageSize
        hosting.rootView = AnyView(LibraryView(model: fixture.library, dataDirectory: fixture.directory)
            .environmentObject(fixture.editor).environmentObject(fixture.layout)
            .environmentObject(fixture.metadata).environmentObject(fixture.exporter)
            .environment(\.displayScale, 2).preferredColorScheme(.dark))
        try await wait {
            self.nativeViews.contains { ($0 as? NSImageView)?.image?.size == fixture.imageSize }
                && self.inputIfPresent("develop.detail-loupe") != nil
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
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try mouseEvent(type, canvas: canvas, point: point)
            window.sendEvent(event)
        }
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
