import AppKit
import SwiftUI
import Testing
@testable import Glowroom

/// The native adapter and clip-view share AppKit state, so each check keeps its
/// event sequence ordered. Independent fixtures own their scroll positions.
@Suite("Photo canvas navigation input", .serialized)
@MainActor
struct PhotoCanvasNavigationInputTests {
    @Test func singleClicksPublishLocalImageCoordinatesAndTakePrecedenceOverDoubleClicks() throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var clicks: [CGPoint] = []
        var doubleClicks = 0
        fixture.configure(onInput: { _ in }, pansWithPointer: true, onClick: { clicks.append($0) },
                          onDoubleClick: { doubleClicks += 1 })
        let point = CGPoint(x: 200, y: 180)
        let expected = fixture.input.convert(point, from: nil)
        for count in 1...2 {
            try fixture.send(.leftMouseDown, at: point, clickCount: count)
            #expect(clicks.count == count - 1, "Zoom waits until release so a drag can take precedence")
            try fixture.send(.leftMouseUp, at: point, clickCount: count)
        }
        try fixture.send(.leftMouseUp, at: point)
        #expect(clicks == [expected, expected])
        #expect(expected != point, "A scrolled image's local anchor must differ from window coordinates")
        #expect(doubleClicks == 0)
    }

    @Test func pointerDragsNeverClickEvenWhenTheyReturnToTheirStartingPoint() throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var clickCount = 0
        fixture.configure(onInput: { _ in }, pansWithPointer: true, onClick: { _ in clickCount += 1 })
        let point = CGPoint(x: 200, y: 180)
        try fixture.send(.leftMouseDown, at: point)
        try fixture.send(.leftMouseDragged, at: CGPoint(x: point.x + 40, y: point.y))
        try fixture.send(.leftMouseDragged, at: point)
        try fixture.send(.leftMouseUp, at: point)
        #expect(clickCount == 0)
        // Accessibility can synthesize a moved release without drag events.
        try fixture.send(.leftMouseDown, at: point)
        try fixture.send(.leftMouseUp, at: CGPoint(x: point.x + 10, y: point.y))
        #expect(clickCount == 0)
    }

    @Test(arguments: PhotoCanvasClickCancellation.allCases)
    func cancelledClicksCannotZoomAnotherPhotoOrWindow(cancellation: PhotoCanvasClickCancellation) throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var clickCount = 0
        fixture.configure(onInput: { _ in }, onClick: { _ in clickCount += 1 })
        let point = CGPoint(x: 200, y: 180)
        try fixture.send(.leftMouseDown, at: point)
        switch cancellation {
        case .identity:
            fixture.configure(onInput: { _ in }, identity: "second", onClick: { _ in clickCount += 1 })
        case .disable: fixture.input.inputEnabled = false
        case .windowResign:
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        case .detach: fixture.input.removeFromSuperview()
        case .escape: #expect(fixture.input.cancelForEscape())
        }
        try fixture.send(.leftMouseUp, at: point)
        #expect(clickCount == 0)
    }

    @Test func magnifiedPointerPanConvertsWindowTravelToDocumentPoints() throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        fixture.scrollView.allowsMagnification = true
        fixture.scrollView.magnification = 2
        fixture.scrollView.contentView.scroll(to: CGPoint(x: 200, y: 120))
        fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
        let initial = fixture.origin
        fixture.configure(onInput: { _ in }, pansWithPointer: true)
        try fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 200))
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 140, y: 230))
        try fixture.send(.leftMouseUp, at: CGPoint(x: 140, y: 230))
        #expect(fixture.origin == CGPoint(x: initial.x - 20, y: initial.y + 15))
    }

    @Test func pointerPanningUsesStableWindowCoordinatesWhileTheDocumentMoves() throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var toolEvents: [DevelopCropInputEvent] = []
        fixture.configure(onInput: { toolEvents.append($0) }, pansWithPointer: true)

        try fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 200))
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 140, y: 230))
        #expect(fixture.origin == CGPoint(x: 160, y: 150))
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 140, y: 230))
        #expect(fixture.origin == CGPoint(x: 160, y: 150), "A stationary pointer must not feed the scroll offset back into its translation")
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 150, y: 240))
        #expect(fixture.origin == CGPoint(x: 150, y: 160))
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 120, y: 210))
        try fixture.send(.leftMouseUp, at: CGPoint(x: 120, y: 210))
        #expect(fixture.origin == CGPoint(x: 180, y: 130), "Every update uses total travel from the same window position")
        #expect(toolEvents.isEmpty)
    }

    @Test func zoomedThreeFingerInputPansWhileOrdinaryPointerInputKeepsEditing() throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var toolEvents: [DevelopCropInputEvent] = []
        fixture.configure(onInput: { toolEvents.append($0) })

        fixture.input.publishInput(touch(.began))
        fixture.input.publishInput(touch(.changed, translation: CGSize(width: 40, height: -30)))
        fixture.input.publishInput(touch(.ended, translation: CGSize(width: 50, height: -40)))
        #expect(fixture.origin == CGPoint(x: 150, y: 160))
        #expect(toolEvents.isEmpty, "Navigation must not start, update or finish an active editing tool")

        try fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 200))
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 130, y: 220))
        try fixture.send(.leftMouseUp, at: CGPoint(x: 130, y: 220))
        #expect(toolEvents.map(\.phase) == [.began, .changed, .ended])
        #expect(toolEvents.allSatisfy { $0.kind == .pointer })
        #expect(toolEvents.last?.translation == CGSize(width: 30, height: -20))
        #expect(fixture.origin == CGPoint(x: 150, y: 160))
    }

    @Test func fittedThreeFingerInputKeepsItsToolRouting() {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var toolEvents: [DevelopCropInputEvent] = []
        fixture.configure(onInput: { toolEvents.append($0) }, pansEnclosingScrollView: false)

        fixture.input.publishInput(touch(.began))
        fixture.input.publishInput(touch(.changed, translation: CGSize(width: 40, height: -30)))
        fixture.input.publishInput(touch(.ended, translation: CGSize(width: 50, height: -40)))
        #expect(toolEvents.map(\.phase) == [.began, .changed, .ended])
        #expect(toolEvents.allSatisfy { $0.kind == .threeFinger })
        #expect(toolEvents.last?.translation == CGSize(width: 50, height: -40))
        #expect(fixture.origin == CGPoint(x: 200, y: 120))
    }

    @Test func doubleClickRunsExactlyOnceAndTheNextPointerDragStillPans() throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var zoomCount = 0
        var toolEvents: [DevelopCropInputEvent] = []
        fixture.configure(onInput: { toolEvents.append($0) }, pansWithPointer: true,
                          onDoubleClick: { zoomCount += 1 })
        let point = CGPoint(x: 200, y: 180)
        try fixture.send(.leftMouseDown, at: point)
        try fixture.send(.leftMouseUp, at: point)
        try fixture.send(.leftMouseDown, at: point, clickCount: 2)
        #expect(zoomCount == 0)
        try fixture.send(.leftMouseUp, at: point, clickCount: 2)
        try fixture.send(.leftMouseUp, at: point, clickCount: 2)
        #expect(zoomCount == 1)
        #expect(fixture.origin == CGPoint(x: 200, y: 120))

        // AppKit keeps counting clicks when two double-clicks follow quickly.
        try fixture.send(.leftMouseDown, at: point, clickCount: 3)
        try fixture.send(.leftMouseUp, at: point, clickCount: 3)
        #expect(zoomCount == 1)
        try fixture.send(.leftMouseDown, at: point, clickCount: 4)
        #expect(zoomCount == 1)
        try fixture.send(.leftMouseUp, at: point, clickCount: 4)
        try fixture.send(.leftMouseUp, at: point, clickCount: 4)
        #expect(zoomCount == 2, "The fourth click must invoke the parent's zoom toggle exactly once again")
        #expect(fixture.origin == CGPoint(x: 200, y: 120))

        try fixture.send(.leftMouseDown, at: point)
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 230, y: 200))
        try fixture.send(.leftMouseUp, at: CGPoint(x: 230, y: 200))
        #expect(fixture.origin == CGPoint(x: 170, y: 140))
        #expect(toolEvents.isEmpty)
    }

    @Test(arguments: PhotoCanvasNavigationCancellation.allCases)
    func viewportResizeDisablingAndWindowCancellationDiscardAHeldPan(cancellation: PhotoCanvasNavigationCancellation) throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var toolEvents: [DevelopCropInputEvent] = []
        fixture.configure(onInput: { toolEvents.append($0) }, pansWithPointer: true)
        try fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 200))
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 140, y: 230))
        #expect(fixture.origin == CGPoint(x: 160, y: 150))

        switch cancellation {
        case .resize:
            fixture.scrollView.setFrameSize(CGSize(width: 540, height: 360))
            fixture.scrollView.tile()
        case .disable:
            fixture.input.inputEnabled = false
        case .windowCancel:
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        }
        let acceptedOrigin = fixture.origin
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 180, y: 260))
        try fixture.send(.leftMouseUp, at: CGPoint(x: 180, y: 260))
        #expect(fixture.origin == acceptedOrigin, "A cancelled or resized gesture must preserve its last accepted position")

        fixture.input.inputEnabled = true
        try fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 200))
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 110, y: 210))
        try fixture.send(.leftMouseUp, at: CGPoint(x: 110, y: 210))
        #expect(fixture.origin == CGPoint(x: acceptedOrigin.x - 10, y: acceptedOrigin.y + 10))
        #expect(toolEvents.isEmpty)
    }

    @Test func changingContextCancelsAHeldPanAndPendingDoubleClick() throws {
        let fixture = PhotoCanvasNavigationInputFixture(origin: CGPoint(x: 200, y: 120))
        defer { fixture.close() }
        var toolEvents: [DevelopCropInputEvent] = []
        var zoomCount = 0
        fixture.configure(onInput: { toolEvents.append($0) }, identity: "first", pansWithPointer: true,
                          onDoubleClick: { zoomCount += 1 })
        try fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 200))
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 140, y: 230))
        #expect(fixture.origin == CGPoint(x: 160, y: 150))

        fixture.configure(onInput: { toolEvents.append($0) }, identity: "second", pansWithPointer: true,
                          onDoubleClick: { zoomCount += 1 })
        try fixture.send(.leftMouseDragged, at: CGPoint(x: 180, y: 260))
        try fixture.send(.leftMouseDown, at: CGPoint(x: 180, y: 260))
        try fixture.send(.leftMouseUp, at: CGPoint(x: 180, y: 260))
        #expect(fixture.origin == CGPoint(x: 160, y: 150), "The held gesture cannot restart for another photo or tool")

        try fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 200))
        try fixture.send(.leftMouseUp, at: CGPoint(x: 120, y: 210))
        #expect(fixture.origin == CGPoint(x: 140, y: 160), "Fresh input must work after the held gesture is released")
        try fixture.send(.leftMouseDown, at: CGPoint(x: 200, y: 180), clickCount: 2)
        fixture.configure(onInput: { toolEvents.append($0) }, identity: "third", pansWithPointer: true,
                          onDoubleClick: { zoomCount += 1 })
        try fixture.send(.leftMouseUp, at: CGPoint(x: 200, y: 180), clickCount: 2)
        #expect(zoomCount == 0)
        try fixture.send(.leftMouseDown, at: CGPoint(x: 200, y: 180), clickCount: 2)
        try fixture.send(.leftMouseUp, at: CGPoint(x: 200, y: 180), clickCount: 2)
        #expect(zoomCount == 1)
        #expect(toolEvents.isEmpty)
    }

    @Test func swiftUIEnvironmentConnectsTheInputSurfaceToItsActualScrollView() async throws {
        _ = NSApplication.shared
        var toolEventCount = 0
        let hosting = NSHostingView(rootView: ScrollView([.horizontal, .vertical]) {
            DevelopCropInputSurface(onInput: { _ in toolEventCount += 1 }, onHover: { _ in },
                isEnabled: true, inputIdentity: "hosted-photo", cursor: { _ in .openHand },
                pansWithPointer: true)
                .frame(width: 1_200, height: 800)
        }.environment(\.photoCanvasPanning, true))
        let window = photoCanvasNavigationWindow(content: hosting)
        defer { window.close() }
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        var pending: [NSView] = [hosting]
        var nativeInput: DevelopCropNativeInputView?
        while let view = pending.popLast() {
            if let input = view as? DevelopCropNativeInputView { nativeInput = input; break }
            pending.append(contentsOf: view.subviews)
        }
        let input = try #require(nativeInput, "The SwiftUI canvas must mount its native input surface")
        defer { input.invalidate() }
        let scrollView = try #require(input.enclosingScrollView)
        let document = try #require(scrollView.documentView)
        #expect(input.bounds.size == CGSize(width: 1_200, height: 800))
        #expect(document.bounds.width > scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: CGPoint(x: 200, y: 120))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let initial = scrollView.contentView.bounds.origin

        input.mouseDown(with: try navigationMouse(.leftMouseDown, at: CGPoint(x: 200, y: 180), window: window))
        input.mouseDragged(with: try navigationMouse(.leftMouseDragged, at: CGPoint(x: 230, y: 200), window: window))
        input.mouseUp(with: try navigationMouse(.leftMouseUp, at: CGPoint(x: 230, y: 200), window: window))
        #expect(scrollView.contentView.bounds.origin == CGPoint(x: initial.x - 30, y: initial.y + 20))
        #expect(toolEventCount == 0)
    }

    private func touch(_ phase: DevelopCropInputEvent.Phase, translation: CGSize = .zero) -> DevelopCropInputEvent {
        let start = CGPoint(x: 160, y: 120)
        return DevelopCropInputEvent(phase: phase, kind: .threeFinger, startLocation: start,
            location: CGPoint(x: start.x + translation.width, y: start.y + translation.height))
    }
}

enum PhotoCanvasNavigationCancellation: CaseIterable {
    case resize, disable, windowCancel
}

enum PhotoCanvasClickCancellation: CaseIterable {
    case identity, disable, windowResign, detach, escape
}

@MainActor
private struct PhotoCanvasNavigationInputFixture {
    let scrollView: NSScrollView
    let input: DevelopCropNativeInputView
    let window: NSWindow
    var origin: CGPoint { scrollView.contentView.bounds.origin }

    init(origin: CGPoint) {
        _ = NSApplication.shared
        scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        let document = PhotoCanvasNavigationInputDocument(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800))
        input = DevelopCropNativeInputView(frame: document.bounds)
        document.addSubview(input)
        scrollView.documentView = document
        window = photoCanvasNavigationWindow(content: scrollView)
        scrollView.tile()
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func configure(onInput: @escaping (DevelopCropInputEvent) -> Void, identity: String = "photo",
                   pansEnclosingScrollView: Bool = true, pansWithPointer: Bool = false,
                   onClick: ((CGPoint) -> Void)? = nil,
                   onDoubleClick: (() -> Void)? = nil) {
        input.configure(onInput: onInput, onHover: { _ in }, isEnabled: true,
            inputIdentity: identity, cursor: { _ in .arrow }, onClick: onClick, onDoubleClick: onDoubleClick,
            pansEnclosingScrollView: pansEnclosingScrollView, pansWithPointer: pansWithPointer)
    }

    func send(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws {
        let event = try navigationMouse(type, at: point, clickCount: clickCount, window: window)
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseDragged: input.mouseDragged(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unsupported navigation mouse event: \(type)")
        }
    }

    func close() { input.invalidate(); window.close() }
}

@MainActor
private final class PhotoCanvasNavigationInputDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func photoCanvasNavigationWindow(content: NSView) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 600, height: 400),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    window.contentView = content
    return window
}

@MainActor
private func navigationMouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1,
                             window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
}
