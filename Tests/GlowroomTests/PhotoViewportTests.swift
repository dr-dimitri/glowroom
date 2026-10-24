import AppKit
import Combine
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Photo viewport geometry")
struct PhotoViewportGeometryTests {
    @Test
    func visibleRectangleExcludesLetterboxingAndUsesTopLeftCoordinates() {
        let image = PhotoViewportGeometry.fittedImage(in: CGSize(width: 1000, height: 600), aspectRatio: 2, padding: 0)
        #expect(image == CGRect(x: 0, y: 50, width: 1000, height: 500))
        let rect = PhotoViewportGeometry.normalizedVisibleRect(image: image,
            viewport: CGRect(x: 250, y: 0, width: 500, height: 300))
        #expect(rect == CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5))
    }

    @Test
    func panningClampsEdgesAndCentersAnAxisThatAlreadyFits() {
        let image = CGRect(x: 300, y: 20, width: 200, height: 600)
        #expect(PhotoViewportGeometry.constrainedOrigin(CGPoint(x: 999, y: -999),
            viewport: CGSize(width: 400, height: 300), image: image) == CGPoint(x: 200, y: 20))
        #expect(PhotoViewportGeometry.constrainedOrigin(CGPoint(x: -999, y: 999),
            viewport: CGSize(width: 400, height: 300), image: image) == CGPoint(x: 200, y: 320))
    }

    @Test
    func invalidAnchorsCannotProduceNonfiniteScrollPositions() {
        #expect(PhotoViewportGeometry.clampedPoint(CGPoint(x: CGFloat.nan, y: CGFloat.infinity)) == CGPoint(x: 0.5, y: 0.5))
        #expect(PhotoViewportGeometry.clampedPoint(CGPoint(x: -4, y: 9)) == CGPoint(x: 0, y: 1))
    }
}

/// Native windows share AppKit state. Keep these integration checks ordered,
/// while the independent geometry cases can run alongside other test suites.
@Suite("Photo viewport native integration", .serialized)
@MainActor
struct PhotoViewportTests {
    @Test
    func zoomCentersTheClickedRegionReportsPansAndKeepsMagnificationOnResize() async throws {
        let state = PhotoViewportState()
        let fixture = PhotoViewportHost(state: state)
        defer { fixture.close() }
        try await fixture.settle()
        let scroll = try fixture.scrollView()
        #expect(scroll.magnification == 1)
        #expect(state.normalizedVisibleRect == PhotoViewportGeometry.unitRect)

        var commandChanges = 0
        let commandSubscription = state.objectWillChange.sink { commandChanges += 1 }
        defer { commandSubscription.cancel() }
        state.toggleZoom(at: CGPoint(x: 0.9, y: 0.7))
        try await fixture.settle(milliseconds: 350)
        #expect(scroll.magnification == 2)
        #expect(state.normalizedVisibleRect.width > 0 && state.normalizedVisibleRect.width < 1)
        #expect(abs(state.normalizedVisibleRect.maxX - 1) < 0.000_001,
                "A click near the right edge should reveal the right side, clamped to the image")
        let documentSize = try #require(scroll.documentView).frame.size
        let changesAfterZoom = commandChanges

        state.moveVisibleCenter(to: CGPoint(x: 0.25, y: 0.3))
        try await fixture.settle()
        #expect(state.normalizedVisibleRect.minX == 0)
        #expect(state.normalizedVisibleRect.midY < 0.5)
        #expect(commandChanges == changesAfterZoom, "Position updates must not rebuild the whole photo workspace")

        fixture.resize(to: CGSize(width: 800, height: 500))
        try await fixture.settle()
        #expect(scroll.magnification == 2)
        #expect(scroll.documentView?.frame.size == documentSize,
                "Opening or resizing sidebars changes the viewport, not the captured photo scale")
        #expect(state.normalizedVisibleRect.width > 0.7)
        state.reset()
        try await fixture.settle()
        #expect(!state.isZoomed)
        #expect(scroll.magnification == 1)
        #expect(state.normalizedVisibleRect == PhotoViewportGeometry.unitRect)
    }

    @Test
    func mountingAnAlreadyZoomedStatePreservesItsPendingClickAnchor() async throws {
        let state = PhotoViewportState()
        state.toggleZoom(at: CGPoint(x: 0.9, y: 0.7))
        let fixture = PhotoViewportHost(state: state)
        defer { fixture.close() }
        try await fixture.settle()
        #expect(try fixture.scrollView().magnification == 2)
        #expect(abs(state.normalizedVisibleRect.maxX - 1) < 0.000_001)
        #expect(state.normalizedVisibleRect.midY > 0.6)
    }

    @Test
    func fittingAfterResizeInterpolatesTheCapturedCanvasWithoutAnInitialJump() async throws {
        let state = PhotoViewportState()
        let fixture = PhotoViewportHost(state: state)
        defer { fixture.close() }
        try await fixture.settle()
        let scroll = try fixture.scrollView()
        state.toggleZoom()
        try await fixture.settle(milliseconds: 350)
        let captured = try #require(scroll.documentView).frame.size
        fixture.resize(to: CGSize(width: 800, height: 500))
        try await fixture.settle()
        #expect(scroll.documentView?.frame.size == captured)
        state.toggleZoom()
        #expect(scroll.documentView?.frame.size == captured,
                "Starting zoom-out must not first resize the still-magnified image")
        try await fixture.settle(milliseconds: 50)
        let intermediate = try #require(scroll.documentView).frame.size
        #expect(intermediate.width > captured.width && intermediate.width < 800)
        try await fixture.settle(milliseconds: 350)
        #expect(scroll.magnification == 1)
        #expect(scroll.documentView?.frame.size == CGSize(width: 800, height: 500))
    }

    @Test
    func hostedContentInheritsEnvironmentObjectsAndPanningMode() async throws {
        let state = PhotoViewportState()
        let fixture = PhotoViewportHost(state: state)
        defer { fixture.close() }
        try await fixture.settle()
        #expect(fixture.probe.value == "inherited")
        #expect(fixture.probe.isPanning == false)
        state.toggleZoom()
        try await fixture.settle(milliseconds: 350)
        #expect(fixture.probe.isPanning == true)
    }

    @Test
    func navigatorAndManualPanDuringAnimationFinishTheRequestedScale() async throws {
        let state = PhotoViewportState()
        let fixture = PhotoViewportHost(state: state)
        defer { fixture.close() }
        try await fixture.settle()
        let scroll = try fixture.scrollView()
        state.toggleZoom(at: CGPoint(x: 0.8, y: 0.8))
        try await fixture.settle(milliseconds: 50)
        #expect(scroll.magnification > 1 && scroll.magnification < 2)
        state.moveVisibleCenter(to: CGPoint(x: 0.2, y: 0.2))
        try await fixture.settle()
        #expect(scroll.magnification == 2)
        #expect(state.normalizedVisibleRect.minX == 0)
        state.reset()
        state.toggleZoom()
        try await fixture.settle(milliseconds: 50)
        scroll.prepareForManualNavigation()
        #expect(scroll.magnification == 2)
        let document = try #require(scroll.documentView)
        let image = PhotoViewportGeometry.fittedImage(in: document.frame.size, aspectRatio: 1.5)
        let centerBeforePan = (scroll.contentView.bounds.midX - image.minX) / image.width
        // Real native input completes zoom before capturing its origin. A
        // thirty-point screen drag then moves fifteen document points at 2×.
        var proposed = scroll.contentView.bounds
        proposed.origin.x += 15
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        try await fixture.settle()
        #expect(scroll.magnification == 2)
        let expectedCenter = centerBeforePan + 15 / image.width
        #expect(abs(state.normalizedVisibleRect.midX - expectedCenter) < 0.000_001,
                "A pan begun during zoom must use the final magnification's coordinates")
    }

    @Test
    func rapidZoomReplacementAndResetDoNotPublishAStaleRegion() async throws {
        let state = PhotoViewportState()
        let fixture = PhotoViewportHost(state: state)
        defer { fixture.close() }
        try await fixture.settle()
        state.toggleZoom(at: CGPoint(x: 0, y: 1))
        try await fixture.settle(milliseconds: 50)
        state.toggleZoom()
        state.toggleZoom(at: CGPoint(x: 1, y: 0))
        state.reset()
        try await fixture.settle(milliseconds: 350)
        #expect(!state.isZoomed)
        #expect(state.normalizedVisibleRect == PhotoViewportGeometry.unitRect)
        #expect(try fixture.scrollView().magnification == 1)
    }
}

private struct PhotoViewportProbeKey: EnvironmentKey { static let defaultValue = "missing" }
private extension EnvironmentValues {
    var viewportProbe: String {
        get { self[PhotoViewportProbeKey.self] }
        set { self[PhotoViewportProbeKey.self] = newValue }
    }
}

@MainActor
private final class PhotoViewportProbe: ObservableObject {
    var value = "missing"
    var isPanning = false
}

private struct PhotoViewportProbeContent: View {
    @EnvironmentObject private var probe: PhotoViewportProbe
    @Environment(\.viewportProbe) private var value
    @Environment(\.photoCanvasPanning) private var panning
    var body: some View {
        Rectangle().fill(.blue)
            .onAppear { probe.value = value; probe.isPanning = panning }
            .onChange(of: panning) { _, enabled in probe.isPanning = enabled }
    }
}

@MainActor
private final class PhotoViewportHost {
    let probe = PhotoViewportProbe()
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>

    init(state: PhotoViewportState) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: AnyView(PhotoCanvasViewport(state: state, imageAspectRatio: 1.5) {
            PhotoViewportProbeContent()
        }.environmentObject(probe).environment(\.viewportProbe, "inherited")))
        window.contentView = hosting
        window.orderBack(nil)
    }

    func resize(to size: CGSize) { window.setContentSize(size); hosting.layoutSubtreeIfNeeded() }

    func settle(milliseconds: Int = 60) async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(milliseconds))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func scrollView() throws -> PhotoCanvasScrollView {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let scroll = view as? PhotoCanvasScrollView { return scroll }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as PhotoCanvasScrollView?, "Missing native photo viewport")
    }

    func close() { window.close() }
}
