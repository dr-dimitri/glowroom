import AppKit
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
