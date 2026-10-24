import AppKit
import SwiftUI
import Testing
@testable import Glowroom

/// Exercise AppKit's actual event routing, including the lower visible region
/// that SwiftUI can omit from a natively magnified document's hit graph.
@Suite("Magnified photo native hit routing", .serialized)
@MainActor
struct PhotoViewportHitTests {
    @Test
    func lowerVisibleInputReceivesRealWindowEvents() async throws {
        let fixture = PhotoViewportHitHost()
        defer { fixture.close() }
        try await fixture.zoom()
        let input = try fixture.input()
        let point = CGPoint(x: input.bounds.midX, y: input.bounds.height * 0.6)
        #expect(input.visibleRect.contains(point))
        #expect(fixture.hit(input, at: point) === input)
        try fixture.sendDrag(input, at: point)
        #expect(fixture.probe.phases == [.began, .changed, .ended])
    }

    @Test
    func foregroundNativeControlsAreNeverReroutedIntoPhotoInput() async throws {
        let fixture = PhotoViewportHitHost()
        defer { fixture.close() }
        try await fixture.zoom()
        fixture.probe.showsControl = true
        try await fixture.settle()
        let button = try fixture.button()
        let point = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        let input = try fixture.input()
        #expect(button.hitTest(button.convert(point, to: button.superview)) === button)
        #expect(fixture.hit(button, at: point) !== input,
                "An unresolved foreground control must keep its SwiftUI gate instead of editing the photo underneath")
    }

    @Test
    func fallbackRespectsExplicitSwiftUIGateDisabledEnvironmentAndHiddenInput() async throws {
        let fixture = PhotoViewportHitHost()
        defer { fixture.close() }
        try await fixture.zoom()
        for mode in [PhotoViewportHitProbe.Mode.closedGate, .disabledEnvironment, .disabledInput, .hiddenInput] {
            fixture.probe.mode = mode
            try await fixture.settle()
            let input = try fixture.input()
            let point = CGPoint(x: input.bounds.midX, y: input.bounds.height * 0.6)
            #expect(fixture.hit(input, at: point) !== input, "An ineligible input must retain its containing hit gate: \(mode)")
            fixture.probe.phases.removeAll()
            try fixture.sendDrag(input, at: point)
            #expect(fixture.probe.phases.isEmpty)
            fixture.probe.mode = .enabled
            try await fixture.settle()
        }
    }
}

@MainActor
private final class PhotoViewportHitProbe: ObservableObject {
    enum Mode { case enabled, closedGate, disabledEnvironment, disabledInput, hiddenInput }
    @Published var mode = Mode.enabled
    @Published var showsControl = false
    var phases: [DevelopCropInputEvent.Phase] = []
}

private struct PhotoViewportHitContent: View {
    @ObservedObject var probe: PhotoViewportHitProbe
    var body: some View {
        GeometryReader { canvas in
            ZStack {
                Color.blue
                DevelopCropInputSurface(onInput: { probe.phases.append($0.phase) },
                    onHover: { _ in }, isEnabled: probe.mode != .disabledInput,
                    inputIdentity: AnyHashable("native-hit-probe"), cursor: { _ in .crosshair },
                    allowsViewportHitFallback: probe.mode != .closedGate)
                    .allowsHitTesting(probe.mode != .closedGate)
                    .disabled(probe.mode == .disabledEnvironment)
                    .opacity(probe.mode == .hiddenInput ? 0 : 1)
                if probe.showsControl {
                    PhotoViewportHitControl().frame(width: 100, height: 30)
                        .position(x: canvas.size.width / 2, y: canvas.size.height * 0.33)
                }
            }
        }
    }
}

private struct PhotoViewportHitControl: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton { NSButton(title: "Overlay", target: nil, action: nil) }
    func updateNSView(_ view: NSButton, context: Context) { }
}

@MainActor
private final class PhotoViewportHitHost {
    let probe = PhotoViewportHitProbe()
    private let viewport = PhotoViewportState()
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>

    init() {
        _ = NSApplication.shared
        window = PhotoViewportHitWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 873, height: 644),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let probeModel = probe
        hosting = NSHostingView(rootView: AnyView(PhotoCanvasViewport(state: viewport, imageAspectRatio: 1.5) {
            PhotoViewportHitContent(probe: probeModel)
        }))
        window.contentView = hosting
        window.orderBack(nil)
    }

    func zoom() async throws {
        try await settle()
        viewport.toggleZoom()
        try await Task.sleep(for: .milliseconds(350))
        try await settle()
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func input() throws -> DevelopCropNativeInputView {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let input = view as? DevelopCropNativeInputView { return input }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as DevelopCropNativeInputView?, "Missing hit-probe input")
    }

    func button() throws -> NSButton {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let button = view as? NSButton { return button }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as NSButton?, "Missing native overlay control")
    }

    func hit(_ input: NSView, at point: CGPoint) -> NSView? {
        hosting.hitTest(input.convert(point, to: hosting.superview))
    }

    func sendDrag(_ input: NSView, at point: CGPoint) throws {
        let location = input.convert(point, to: nil)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].map {
            try #require(NSEvent.mouseEvent(with: $0, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        for event in events { window.sendEvent(event) }
    }

    func close() { hosting.rootView = AnyView(EmptyView()); window.close() }
}

@MainActor
private final class PhotoViewportHitWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
