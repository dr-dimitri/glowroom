import AppKit
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Native before/after comparison", .serialized)
@MainActor
struct PreviewComparisonViewTests {
    @Test(arguments: [PreviewComparisonLayout.leftRight, .splitLeftRight, .topBottom, .splitTopBottom])
    func singleClickZoomUsesTheClickedPaneAndRetainsItsImageCoordinates(layout: PreviewComparisonLayout) async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        var clicks: [CGPoint] = []
        var doubleClickCount = 0
        host.mount(PreviewComparisonView(layout: layout, onClick: { clicks.append($0) },
            onDoubleClick: { doubleClickCount += 1 }, before: { Color.red }, after: { Color.blue }))
        try await host.settle()
        let input = try host.navigation()
        let geometry = PreviewComparisonGeometry(layout: layout, size: CGSize(width: 400, height: 240))
        let point = CGPoint(x: geometry.afterFrame.midX, y: geometry.afterFrame.midY)
        let expected = try #require(geometry.normalizedImagePoint(at: point, aspectRatio: nil))
        #expect(input.cursor(point) === PhotoCanvasCursors.zoomIn)
        let location = input.convert(point, to: nil)
        input.mouseDown(with: try host.event(.leftMouseDown, at: location))
        #expect(clicks.isEmpty)
        input.mouseUp(with: try host.event(.leftMouseUp, at: location))
        #expect(clicks == [expected])
        #expect(doubleClickCount == 0)
    }

    @Test func imageFitGeometryIgnoresLetterboxingAndCentersTheSelectedZoomAnchor() {
        let horizontal = PreviewComparisonGeometry(layout: .leftRight, size: CGSize(width: 400, height: 240))
        #expect(horizontal.normalizedImagePoint(at: CGPoint(x: 250, y: 120), aspectRatio: 5 / 3) == CGPoint(x: 0.25, y: 0.5))
        #expect(horizontal.normalizedImagePoint(at: CGPoint(x: 250, y: 20), aspectRatio: 5 / 3) == nil)
        #expect(horizontal.initialZoomPan(anchor: CGPoint(x: 0.75, y: 0.5), aspectRatio: 5 / 3) == CGSize(width: -100, height: 0))
        #expect(horizontal.initialZoomPan(anchor: CGPoint(x: 1, y: 1), aspectRatio: 5 / 3) == CGSize(width: -100, height: 0))
        let split = PreviewComparisonGeometry(layout: .splitLeftRight, size: CGSize(width: 400, height: 240), fraction: 0.3)
        #expect(split.normalizedImagePoint(at: CGPoint(x: 300, y: 120), aspectRatio: 5 / 3) == CGPoint(x: 0.75, y: 0.5))
        #expect(split.initialZoomPan(anchor: CGPoint(x: 0.75, y: 0.25), aspectRatio: 5 / 3) == CGSize(width: -200, height: 120))
    }

    @Test func originalAndCroppedPanesUseTheirOwnImageFitsAndShareTheTighterPanBound() async throws {
        let geometry = PreviewComparisonGeometry(layout: .leftRight, size: CGSize(width: 400, height: 240))
        let beforePoint = CGPoint(x: 50, y: 95)
        #expect(geometry.normalizedImagePoint(at: beforePoint, aspectRatio: 1, beforeAspectRatio: 2)
                == CGPoint(x: 0.25, y: 0.25))
        #expect(geometry.normalizedImagePoint(at: CGPoint(x: 250, y: 95), aspectRatio: 1, beforeAspectRatio: 2)
                == CGPoint(x: 0.25, y: 0.375))
        #expect(geometry.normalizedImagePoint(at: CGPoint(x: 50, y: 30), aspectRatio: 1, beforeAspectRatio: 2) == nil)
        #expect(geometry.clampedPan(CGSize(width: 150, height: 80), aspectRatio: 1, beforeAspectRatio: 2)
                == CGSize(width: 100, height: 0))
        #expect(geometry.initialZoomPan(anchor: CGPoint(x: 0.75, y: 0.25), aspectRatio: 1, beforeAspectRatio: 2)
                == CGSize(width: -100, height: 0))
        let host = ComparisonViewTestHost()
        defer { host.close() }
        var clicks: [CGPoint] = []
        host.mount(PreviewComparisonView(layout: .leftRight, imageAspectRatio: 1, beforeImageAspectRatio: 2,
            onClick: { clicks.append($0) }, before: { Color.red }, after: { Color.blue }))
        try await host.settle()
        let input = try host.navigation()
        #expect(input.cursor(CGPoint(x: 50, y: 30)) === NSCursor.arrow)
        let location = input.convert(beforePoint, to: nil)
        input.mouseDown(with: try host.event(.leftMouseDown, at: location))
        input.mouseUp(with: try host.event(.leftMouseUp, at: location))
        #expect(clicks == [CGPoint(x: 0.25, y: 0.25)])
    }

    @Test(arguments: PreviewComparisonLayout.allCases)
    func nativePhotosStayInsideTheirVisiblePane(layout: PreviewComparisonLayout) async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        let before = try comparisonTestImage(left: .red, right: layout == .splitLeftRight ? .green : .red)
        let after = try comparisonTestImage(left: .blue, right: layout == .splitLeftRight ? .yellow : .blue)
        host.mount(PreviewComparisonView(layout: layout,
            before: { ComparisonNativeTestPhoto(image: before) },
            after: { ComparisonNativeTestPhoto(image: after) }).background(.black))
        try await host.settle()
        let snapshot = try host.snapshot()
        // Native snapshots use the host display's profile. Render independent
        // reference image views through the same AppKit capture path instead
        // of assuming their captured RGB components remain ideal sRGB primaries.
        host.mount(ComparisonNativeTestPhoto(image: before).background(.black))
        try await host.settle()
        let beforeColor = try pixelColor(host.snapshot(), at: CGPoint(x: 100, y: 120))
        host.mount(ComparisonNativeTestPhoto(image: after).background(.black))
        try await host.settle()
        let afterColor = try pixelColor(host.snapshot(),
            at: CGPoint(x: layout == .splitLeftRight ? 300 : 100, y: 120))
        #expect(beforeColor.redComponent > beforeColor.blueComponent + 0.5)
        if layout == .splitLeftRight {
            #expect(afterColor.redComponent > 0.5 && afterColor.greenComponent > 0.5)
        } else {
            #expect(afterColor.blueComponent > afterColor.redComponent + 0.5)
        }
        switch layout {
        case .single:
            try expectColor(snapshot, at: CGPoint(x: 200, y: 120), matches: afterColor)
        case .leftRight:
            try expectColor(snapshot, at: CGPoint(x: 170, y: 120), matches: beforeColor)
            try expectColor(snapshot, at: CGPoint(x: 230, y: 120), matches: afterColor)
        case .splitLeftRight:
            // Both samples lie close to the seam but retain the full source's
            // coordinates. Fitting either image to its half would change them.
            try expectColor(snapshot, at: CGPoint(x: 170, y: 120), matches: beforeColor)
            try expectColor(snapshot, at: CGPoint(x: 230, y: 120), matches: afterColor)
            try #require(snapshot.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/glowroom-before-after-preview.png"))
        case .topBottom:
            try expectColor(snapshot, at: CGPoint(x: 200, y: 60), matches: beforeColor)
            try expectColor(snapshot, at: CGPoint(x: 200, y: 180), matches: afterColor)
        case .splitTopBottom:
            try expectColor(snapshot, at: CGPoint(x: 200, y: 90), matches: beforeColor)
            try expectColor(snapshot, at: CGPoint(x: 200, y: 150), matches: afterColor)
        }
    }

    @Test(arguments: PreviewComparisonLayout.allCases)
    func onlyTheAfterPaneReceivesTheAnalysisSink(layout: PreviewComparisonLayout) async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        var observations: [String: Bool] = [:]
        host.mount(PreviewComparisonView(layout: layout,
            before: { ComparisonSinkReader { observations["before"] = $0 } },
            after: { ComparisonSinkReader { observations["after"] = $0 } })
            .environment(\.developPreviewSink, { _ in }))
        try await host.settle()
        #expect(observations["after"] == true)
        #expect(observations["before"] == (layout == .single ? nil : false))
    }

    @Test(arguments: PreviewComparisonLayout.allCases)
    func onlyTheAfterPaneCanInvalidateTheAcceptedLevelsDisplay(layout: PreviewComparisonLayout) async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        var pending: [String] = []
        host.mount(PreviewComparisonView(layout: layout,
            before: { ComparisonPendingReader(name: "before") },
            after: { ComparisonPendingReader(name: "after") })
            .environment(\.developPreviewPending, { pending.append($0.request.displayName) }))
        try await host.settle()
        #expect(pending == ["after"])
    }

    @Test(arguments: [PreviewComparisonLayout.splitLeftRight, .splitTopBottom])
    func movingHandleUsesStableWindowCoordinatesAndOwnsItsHitTarget(layout: PreviewComparisonLayout) async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        host.mount(PreviewComparisonView(layout: layout, before: { Color.red }, after: { Color.blue }))
        try await host.settle()
        let divider = try host.divider()
        let start = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        let content = try #require(host.window.contentView)
        #expect(content.hitTest(content.superview?.convert(start, from: nil) ?? start) === divider,
                "The divider must receive pointer events before the navigation surface")
        let target = CGPoint(x: start.x + (layout.isHorizontal ? 80 : 0),
                             y: start.y - (layout.isHorizontal ? 0 : 48))
        divider.mouseDown(with: try host.event(.leftMouseDown, at: start))
        divider.mouseDragged(with: try host.event(.leftMouseDragged, at: target))
        try await host.settle()
        let firstCenter = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        #expect(abs(firstCenter.x - target.x) < 1)
        #expect(abs(firstCenter.y - target.y) < 1)
        // A second event at the same window point arrives after the handle has
        // moved. Measuring local coordinates would jump back to the midpoint.
        divider.mouseDragged(with: try host.event(.leftMouseDragged, at: target))
        try await host.settle()
        let secondCenter = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        #expect(abs(secondCenter.x - firstCenter.x) < 1)
        #expect(abs(secondCenter.y - firstCenter.y) < 1)
        divider.mouseUp(with: try host.event(.leftMouseUp, at: target))
    }

    @Test
    func identityReplacementWindowResignationAndTeardownCancelDrags() async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        let presentation = ComparisonTestPresentation()
        host.mount(ComparisonPresentationView(presentation: presentation))
        try await host.settle()
        var divider = try host.divider()
        var start = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        divider.mouseDown(with: try host.event(.leftMouseDown, at: start))
        presentation.identity = "second-photo"
        try await host.settle()
        divider.mouseDragged(with: try host.event(.leftMouseDragged, at: CGPoint(x: start.x + 80, y: start.y)))
        try await host.settle()
        #expect(abs(divider.convert(.zero, to: nil).x - (start.x - divider.bounds.midX)) < 1)

        divider.mouseDown(with: try host.event(.leftMouseDown, at: start))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: host.window)
        divider.mouseDragged(with: try host.event(.leftMouseDragged, at: CGPoint(x: start.x + 80, y: start.y)))
        try await host.settle()
        #expect(abs(divider.convert(.zero, to: nil).x - (start.x - divider.bounds.midX)) < 1)

        divider.mouseDown(with: try host.event(.leftMouseDown, at: start))
        presentation.layout = .splitTopBottom
        try await host.settle()
        divider = try host.divider()
        #expect(divider.horizontal == false)
        start = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        divider.mouseDragged(with: try host.event(.leftMouseDragged, at: CGPoint(x: start.x, y: start.y - 48)))
        try await host.settle()
        #expect(abs(divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil).y - start.y) < 1)

        var phases: [DevelopCropInputEvent.Phase] = []
        divider.onInput = { phases.append($0.phase) }
        divider.mouseDown(with: try host.event(.leftMouseDown, at: start))
        host.mount(Color.clear)
        try await host.settle()
        #expect(phases == [.began, .cancelled])
    }

    @Test(arguments: [PreviewComparisonLayout.splitLeftRight, .splitTopBottom])
    func nativeAccessibilityCanAdjustAndClampTheDivider(layout: PreviewComparisonLayout) async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        host.mount(PreviewComparisonView(layout: layout, before: { Color.red }, after: { Color.blue }))
        try await host.settle()
        let divider = try host.divider()
        #expect(divider.accessibilityPerformIncrement())
        try await host.settle()
        #expect(divider.accessibilityValue() as? Int == 55)
        for _ in 0..<20 { _ = divider.accessibilityPerformIncrement() }
        try await host.settle()
        #expect(divider.accessibilityValue() as? Int == 90)
        for _ in 0..<30 { _ = divider.accessibilityPerformDecrement() }
        try await host.settle()
        #expect(divider.accessibilityValue() as? Int == 10)
    }

    @Test
    func escapeCancelsAnActiveDividerDragAndPassesThroughWhileIdleOrTrackingAMenu() async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        host.mount(PreviewComparisonView(layout: .splitLeftRight, before: { Color.red }, after: { Color.blue }))
        try await host.settle()
        let divider = try host.divider()
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: host.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(divider.processKeyEvent(escape) === escape)
        let start = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        divider.mouseDown(with: try host.event(.leftMouseDown, at: start))
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(divider.processKeyEvent(escape) === escape)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        // Exercise AppKit's local monitor rather than calling only its helper.
        NSApp.sendEvent(escape)
        divider.mouseDragged(with: try host.event(.leftMouseDragged, at: CGPoint(x: start.x + 80, y: start.y)))
        try await host.settle()
        let end = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        #expect(abs(end.x - start.x) < 1)
        #expect(divider.processKeyEvent(escape) === escape)
    }

    @Test(arguments: [PreviewComparisonLayout.leftRight, .splitLeftRight, .topBottom, .splitTopBottom])
    func zoomKeepsBothPanesVisibleAndPansTheirNativeImagesTogether(layout: PreviewComparisonLayout) async throws {
        let host = ComparisonViewTestHost()
        defer { host.close() }
        let before = try comparisonTestImage(left: .red, right: .green)
        let after = try comparisonTestImage(left: .blue, right: .yellow)
        host.mount(ComparisonNativeTestPhoto(image: before).background(.black))
        try await host.settle()
        let beforeReference = try host.snapshot()
        let red = try pixelColor(beforeReference, at: CGPoint(x: 100, y: 120))
        let green = try pixelColor(beforeReference, at: CGPoint(x: 300, y: 120))
        host.mount(ComparisonNativeTestPhoto(image: after).background(.black))
        try await host.settle()
        let afterReference = try host.snapshot()
        let blue = try pixelColor(afterReference, at: CGPoint(x: 100, y: 120))
        let yellow = try pixelColor(afterReference, at: CGPoint(x: 300, y: 120))

        let presentation = ComparisonTestPresentation()
        presentation.layout = layout
        host.mount(ComparisonZoomPresentationView(presentation: presentation, before: before, after: after)
            .background(.black))
        try await host.settle()
        let navigation = try host.navigation()
        #expect(navigation.bounds.size == CGSize(width: 400, height: 240))
        #expect(navigation.enclosingScrollView == nil)
        let beforePoint: CGPoint
        let afterPoint: CGPoint
        switch layout {
        case .leftRight: beforePoint = CGPoint(x: 120, y: 120); afterPoint = CGPoint(x: 310, y: 120)
        case .splitLeftRight: beforePoint = CGPoint(x: 170, y: 120); afterPoint = CGPoint(x: 230, y: 120)
        case .topBottom: beforePoint = CGPoint(x: 210, y: 60); afterPoint = CGPoint(x: 210, y: 180)
        default: beforePoint = CGPoint(x: 210, y: 90); afterPoint = CGPoint(x: 210, y: 150)
        }
        let initial = try host.snapshot()
        try expectColor(initial, at: beforePoint, matches: layout == .splitLeftRight ? red : green)
        try expectColor(initial, at: afterPoint, matches: yellow)
        let initialDivider = layout.isSplit ? try host.divider().frame : nil
        let start = navigation.convert(CGPoint(x: 70, y: 100), to: nil)
        let target = CGPoint(x: start.x + 40, y: start.y)
        navigation.mouseDown(with: try host.event(.leftMouseDown, at: start))
        navigation.mouseDragged(with: try host.event(.leftMouseDragged, at: target))
        navigation.mouseUp(with: try host.event(.leftMouseUp, at: target))
        try await host.settle()
        let panned = try host.snapshot()
        try expectColor(panned, at: beforePoint, matches: red)
        try expectColor(panned, at: afterPoint, matches: blue)
        #expect(navigation.bounds.size == CGSize(width: 400, height: 240))
        if let initialDivider { #expect(try host.divider().frame == initialDivider) }
        if layout == .leftRight {
            try #require(panned.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/glowroom-before-after-zoom-preview.png"))
        }

        let scroll = try host.scroll(horizontal: -40)
        #expect(scroll.scrollingDeltaX == -40)
        navigation.scrollWheel(with: scroll)
        try await host.settle()
        let scrolled = try host.snapshot()
        try expectColor(scrolled, at: beforePoint, matches: layout == .splitLeftRight ? red : green)
        try expectColor(scrolled, at: afterPoint, matches: yellow)

        navigation.scrollWheel(with: try host.scroll(horizontal: 40))
        try await host.settle()
        presentation.zoomed = false
        try await Task.sleep(for: .milliseconds(260))
        try await host.settle()
        presentation.zoomed = true
        try await Task.sleep(for: .milliseconds(260))
        try await host.settle()
        let reset = try host.snapshot()
        try expectColor(reset, at: beforePoint, matches: layout == .splitLeftRight ? red : green)
        try expectColor(reset, at: afterPoint, matches: yellow)
    }

    @Test
    func zoomPanBoundsUseTheCurrentSmallestContentFrame() {
        let horizontal = PreviewComparisonGeometry(layout: .leftRight, size: CGSize(width: 400, height: 240))
        #expect(horizontal.zoomPanLimit == CGSize(width: 100, height: 120))
        #expect(horizontal.clampedPan(CGSize(width: 1_000, height: -1_000)) == CGSize(width: 100, height: -120))
        let vertical = PreviewComparisonGeometry(layout: .topBottom, size: CGSize(width: 400, height: 240))
        #expect(vertical.zoomPanLimit == CGSize(width: 200, height: 60))
        let split = PreviewComparisonGeometry(layout: .splitLeftRight, size: CGSize(width: 400, height: 240), fraction: 0.1)
        #expect(split.zoomPanLimit == CGSize(width: 200, height: 120))
        let resized = PreviewComparisonGeometry(layout: .leftRight, size: CGSize(width: 200, height: 120))
        #expect(resized.clampedPan(CGSize(width: 100, height: -120)) == CGSize(width: 50, height: -60))
        #expect(resized.clampedPan(CGSize(width: CGFloat.nan, height: CGFloat.infinity)) == .zero)
    }

    @Test
    func nativeScrollCallbackRemainsOptIn() throws {
        let parent = ComparisonScrollTestParent(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        let input = DevelopCropNativeInputView(frame: parent.bounds)
        parent.addSubview(input)
        defer { input.invalidate() }
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 12, wheel2: 8, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        var received: CGSize?
        input.configure(onInput: { _ in }, onHover: { _ in }, isEnabled: true,
            inputIdentity: "comparison", cursor: { _ in .arrow }, onScroll: { received = $0 })
        input.scrollWheel(with: event)
        #expect(received == CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        #expect(parent.scrollCount == 0)
        input.configure(onInput: { _ in }, onHover: { _ in }, isEnabled: true,
            inputIdentity: "comparison", cursor: { _ in .arrow })
        input.scrollWheel(with: event)
        #expect(parent.scrollCount == 1)
    }

    private func pixelColor(_ bitmap: NSBitmapImageRep, at point: CGPoint) throws -> NSColor {
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / 400)
        let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / 240)
        return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
    private func expectColor(_ bitmap: NSBitmapImageRep, at point: CGPoint, matches reference: NSColor) throws {
        let color = try pixelColor(bitmap, at: point)
        #expect(abs(color.redComponent - reference.redComponent) < 0.01)
        #expect(abs(color.greenComponent - reference.greenComponent) < 0.01)
        #expect(abs(color.blueComponent - reference.blueComponent) < 0.01)
        #expect(abs(color.alphaComponent - reference.alphaComponent) < 0.01)
    }
}

@MainActor
private final class ComparisonTestPresentation: ObservableObject {
    @Published var identity = "first-photo"
    @Published var layout = PreviewComparisonLayout.splitLeftRight
    @Published var zoomed = true
}

private struct ComparisonZoomPresentationView: View {
    @ObservedObject var presentation: ComparisonTestPresentation
    let before: NSImage
    let after: NSImage
    var body: some View {
        PreviewComparisonView(layout: presentation.layout, navigationIdentity: AnyHashable(presentation.identity),
            zoomed: presentation.zoomed,
            before: { ComparisonNativeTestPhoto(image: before) }, after: { ComparisonNativeTestPhoto(image: after) })
    }
}

private final class ComparisonScrollTestParent: NSView {
    var scrollCount = 0
    override func scrollWheel(with event: NSEvent) { scrollCount += 1 }
}

private struct ComparisonPresentationView: View {
    @ObservedObject var presentation: ComparisonTestPresentation
    var body: some View {
        PreviewComparisonView(layout: presentation.layout, navigationIdentity: AnyHashable(presentation.identity),
            before: { Color.red }, after: { Color.blue })
    }
}

private struct ComparisonSinkReader: View {
    @Environment(\.developPreviewSink) private var sink
    let appeared: (Bool) -> Void
    var body: some View { Color.clear.onAppear { appeared(sink != nil) } }
}

private struct ComparisonPendingReader: View {
    @Environment(\.developPreviewPending) private var pending
    let name: String
    var body: some View {
        Color.clear.onAppear {
            let request = PreviewRequest(url: URL(fileURLWithPath: "/synthetic/\(name)"),
                modifiedAt: .distantPast, pixelSize: 512)
            pending?(DevelopPreviewRenderIdentity(request: request, settings: .neutral, revision: nil,
                sourceToken: UUID(), finalSourceReady: false))
        }
    }
}

private struct ComparisonNativeTestPhoto: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let view = ComparisonTestImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { view.image = image }
}

private final class ComparisonTestImageView: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

@MainActor
private func comparisonTestImage(left: NSColor, right: NSColor) throws -> NSImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8,
        bytesPerRow: 1_600, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(left.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 240))
    context.setFillColor(right.cgColor); context.fill(CGRect(x: 200, y: 0, width: 200, height: 240))
    return NSImage(cgImage: try #require(context.makeImage()), size: CGSize(width: 400, height: 240))
}

@MainActor
private final class ComparisonViewTestHost {
    let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 400, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = hosting; window.orderBack(nil)
    }
    func mount(_ view: some View) { hosting.rootView = AnyView(view.frame(width: 400, height: 240)) }
    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
    }
    func divider() throws -> PreviewComparisonDividerNativeView {
        var pending = [hosting as NSView]
        while let view = pending.popLast() {
            if let divider = view as? PreviewComparisonDividerNativeView { return divider }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as PreviewComparisonDividerNativeView?, "Missing native comparison divider")
    }
    func navigation() throws -> DevelopCropNativeInputView {
        var pending = [hosting as NSView]
        while let view = pending.popLast() {
            if let input = view as? DevelopCropNativeInputView,
               input.accessibilityIdentifier() == "workspace.comparison-navigation" { return input }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as DevelopCropNativeInputView?, "Missing native comparison navigation")
    }
    func scroll(horizontal: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: horizontal, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }
    func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
    func snapshot() throws -> NSBitmapImageRep {
        var pending = [hosting as NSView]
        while let view = pending.popLast() {
            view.needsDisplay = true; pending.append(contentsOf: view.subviews)
        }
        hosting.displayIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
    func close() { window.close() }
}
