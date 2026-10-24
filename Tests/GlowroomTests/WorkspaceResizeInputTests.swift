import AppKit
import Combine
import SwiftUI
import Testing
@testable import Glowroom

/// AppKit event delivery and mounted SwiftUI windows share main-thread state.
/// The windows stay offscreen and never activate the user's application.
@Suite("Workspace resize native input", .serialized)
@MainActor
struct WorkspaceResizeInputTests {
    @Test(arguments: ["library", "tools", "filmstrip"])
    func movingHandlesFollowWindowCoordinatesAndIncludeTheReleasePosition(column: String) throws {
        let host = WorkspaceResizeTestHost()
        defer { host.close() }
        let input = WorkspaceResizeInputView(frame: NSRect(x: 300, y: 180, width: 7, height: 100))
        host.attach(input)
        input.horizontal = column != "filmstrip"
        input.step = column == "tools" ? -1 : 1
        input.value = 220
        var events: [ResizeInputEvent] = []
        input.begin = { events.append(.begin) }
        input.change = { [weak input] value in
            events.append(.change(value))
            // SwiftUI reconfigures the same native view as its frame changes.
            // A held drag must retain its original value and window origin.
            input?.value = value
        }
        input.end = { events.append(.end($0)) }
        let origin = CGPoint(x: 303, y: 200)
        func point(_ delta: CGFloat) -> CGPoint {
            input.horizontal ? CGPoint(x: origin.x + delta, y: origin.y)
                : CGPoint(x: origin.x, y: origin.y + delta)
        }

        try host.send(.leftMouseDown, to: input, at: origin)
        try host.send(.leftMouseDragged, to: input, at: point(40))
        input.setFrameOrigin(CGPoint(x: input.horizontal ? 340 : 300, y: input.horizontal ? 180 : 220))
        try host.send(.leftMouseDragged, to: input, at: point(70))
        input.setFrameOrigin(CGPoint(x: input.horizontal ? 370 : 300, y: input.horizontal ? 180 : 250))
        // No dragged event was sent at 95: mouseUp must apply its final position.
        try host.send(.leftMouseUp, to: input, at: point(95))
        let direction = column == "tools" ? -1.0 : 1.0
        #expect(events == [.begin, .change(220 + 40 * direction), .change(220 + 70 * direction),
                           .change(220 + 95 * direction), .end(true)])
    }

    @Test
    func escapeCancelsOnceAndRejectsTheRemainingHeldDrag() throws {
        let host = WorkspaceResizeTestHost()
        defer { host.close() }
        let input = WorkspaceResizeInputView(frame: NSRect(x: 200, y: 50, width: 7, height: 200))
        host.attach(input)
        input.value = 200
        var events: [ResizeInputEvent] = []
        input.begin = { events.append(.begin) }
        input.change = { events.append(.change($0)) }
        input.end = { events.append(.end($0)) }
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 203, y: 100))
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 233, y: 100))
        try host.escape(input)
        try host.escape(input)
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 263, y: 100))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 283, y: 100))
        #expect(events == [.begin, .change(230), .end(false)])
    }

    @Test
    func workspaceKeyboardRoutingConsumesEscapeBeforeWorkspaceCommands() throws {
        let host = WorkspaceResizeTestHost()
        defer { host.close() }
        let input = WorkspaceResizeInputView(frame: NSRect(x: 200, y: 50, width: 7, height: 200))
        let keyboard = WorkspaceKeyboardInputView(frame: .zero)
        host.attach(input)
        host.attach(keyboard)
        input.value = 200
        var events: [ResizeInputEvent] = []
        input.begin = { events.append(.begin) }
        input.change = { events.append(.change($0)) }
        input.end = { events.append(.end($0)) }
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 203, y: 100))
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 233, y: 100))
        #expect(host.window.firstResponder === input)
        let escape = try host.escapeEvent()
        #expect(escape.window === host.window)
        // The application's local monitor delegates to this same method. An
        // unhandled event would pass through because no workspace callback is set.
        #expect(keyboard.process(escape) == nil)
        #expect(events == [.begin, .change(230), .end(false)])
        #expect(keyboard.process(escape) === escape, "Only an active resize consumes Escape here")
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 263, y: 100))
        #expect(events == [.begin, .change(230), .end(false)])
    }

    @Test
    func menuTrackingAndModifiedEscapeLeaveTheHeldResizeActive() throws {
        let host = WorkspaceResizeTestHost()
        defer { host.close() }
        let input = WorkspaceResizeInputView(frame: NSRect(x: 200, y: 50, width: 7, height: 200))
        host.attach(input)
        input.value = 200
        var events: [ResizeInputEvent] = []
        input.begin = { events.append(.begin) }
        input.change = { events.append(.change($0)) }
        input.end = { events.append(.end($0)) }
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 203, y: 100))
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 233, y: 100))
        let escape = try host.escapeEvent()
        let menu = NSMenu(title: "Resize input test")
        do {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) }
            #expect(!input.processKeyEvent(escape), "Escape must remain with the open native menu")
            #expect(events == [.begin, .change(230)])
        }
        for modifier in [NSEvent.ModifierFlags.command, .control, .option] {
            #expect(!input.processKeyEvent(try host.escapeEvent(modifiers: modifier)))
            #expect(events == [.begin, .change(230)])
        }
        #expect(input.processKeyEvent(escape))
        #expect(!input.processKeyEvent(escape))
        #expect(events == [.begin, .change(230), .end(false)])
    }

    @Test
    func removingTheNativeInputRejectsStaleEventsAndCommitCallbacks() throws {
        let host = WorkspaceResizeTestHost()
        defer { host.close() }
        let input = WorkspaceResizeInputView(frame: NSRect(x: 200, y: 50, width: 7, height: 200))
        host.attach(input)
        input.value = 200
        var events: [ResizeInputEvent] = []
        input.begin = { events.append(.begin) }
        input.change = { events.append(.change($0)) }
        input.end = { events.append(.end($0)) }
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 203, y: 100))
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 223, y: 100))
        input.removeFromSuperview()
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 243, y: 100))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 263, y: 100))
        #expect(events == [.begin, .change(220)])
    }

    @Test
    func losingTheWindowCancelsACollectedDragBeforeAnyLateRelease() throws {
        let host = WorkspaceResizeTestHost()
        defer { host.close() }
        let input = WorkspaceResizeInputView(frame: NSRect(x: 200, y: 50, width: 7, height: 200))
        host.attach(input)
        input.value = 200
        var events: [ResizeInputEvent] = []
        input.begin = { events.append(.begin) }
        input.change = { events.append(.change($0)) }
        input.end = { events.append(.end($0)) }
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 203, y: 100))
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 223, y: 100))
        // Deliver the real notification without activating a test window or
        // stealing focus from the user's application.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: host.window)
        try host.send(.leftMouseDragged, to: input, at: CGPoint(x: 243, y: 100))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 263, y: 100))
        #expect(events == [.begin, .change(220), .end(false)])
        // A lost release must not leave the native input stuck for a new drag.
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 203, y: 100))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 213, y: 100))
        #expect(Array(events.suffix(3)) == [.begin, .change(210), .end(true)])
    }

    @Test
    func mountedColumnsKeepAcceptedPixelsAndPreferencesUntilOneReleaseCommit() async throws {
        let fixture = try ResizeColumnsFixture()
        defer { fixture.removePreferences() }
        let host = WorkspaceResizeTestHost()
        defer { host.close() }
        host.mount(ResizeColumnsRoot(layout: fixture.layout, probe: fixture.probe))
        try await host.settle()
        let input = try #require(host.inputs.first)
        let acceptedView = try #require(fixture.probe.imageView)
        let originalFrame = input.convert(input.bounds, to: nil)
        let origin = CGPoint(x: originalFrame.midX, y: originalFrame.midY)
        let previous = fixture.layout.library
        let preferences = fixture.defaults.data(forKey: WorkspaceLayoutModel.preferencesKey)
        let observation = fixture.observePublications()
        defer { observation.cancel() }

        try host.send(.leftMouseDown, to: input, at: origin)
        for delta in [20.0, 40.0] {
            try host.send(.leftMouseDragged, to: input, at: CGPoint(x: origin.x + delta, y: origin.y))
            try await host.settle()
            #expect(fixture.probe.commits == 0 && fixture.probe.publications == 0)
            #expect(fixture.layout.library == previous)
            #expect(fixture.defaults.data(forKey: WorkspaceLayoutModel.preferencesKey) == preferences)
            #expect(host.inputs.first === input)
            #expect(abs(input.convert(input.bounds, to: nil).midX - originalFrame.midX - delta) < 0.01)
            #expect(fixture.probe.imageView === acceptedView)
            #expect(acceptedView.image === fixture.probe.image)
        }
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: origin.x + 60, y: origin.y))
        try await host.settle()
        #expect(fixture.probe.commits == 1 && fixture.probe.publications == 1)
        #expect(fixture.layout.library.libraryWidth == previous.libraryWidth + 60)
        #expect(fixture.layout.library.toolsWidth == previous.toolsWidth)
        #expect(fixture.defaults.data(forKey: WorkspaceLayoutModel.preferencesKey) != preferences)
        #expect(WorkspaceLayoutModel(defaults: fixture.defaults).library == fixture.layout.library)
        #expect(fixture.probe.imageView === acceptedView)
        #expect(acceptedView.image === fixture.probe.image)
    }

    @Test(arguments: [false, true])
    func cancelledAndUnchangedColumnDragsDoNotPersist(cancelled: Bool) async throws {
        let fixture = try ResizeColumnsFixture()
        defer { fixture.removePreferences() }
        let host = WorkspaceResizeTestHost()
        defer { host.close() }
        host.mount(ResizeColumnsRoot(layout: fixture.layout, probe: fixture.probe))
        try await host.settle()
        let input = try #require(host.inputs.first)
        let rect = input.convert(input.bounds, to: nil)
        let origin = CGPoint(x: rect.midX, y: rect.midY)
        let previous = fixture.layout.library
        let preferences = fixture.defaults.data(forKey: WorkspaceLayoutModel.preferencesKey)
        let observation = fixture.observePublications()
        defer { observation.cancel() }
        try host.send(.leftMouseDown, to: input, at: origin)
        if cancelled {
            try host.send(.leftMouseDragged, to: input, at: CGPoint(x: origin.x + 35, y: origin.y))
            try await host.settle()
            try host.escape(input)
            try host.send(.leftMouseUp, to: input, at: CGPoint(x: origin.x + 60, y: origin.y))
        } else {
            try host.send(.leftMouseUp, to: input, at: origin)
        }
        try await host.settle()
        #expect(fixture.probe.commits == 0 && fixture.probe.publications == 0)
        #expect(fixture.layout.library == previous)
        #expect(fixture.defaults.data(forKey: WorkspaceLayoutModel.preferencesKey) == preferences)
        #expect(abs(input.convert(input.bounds, to: nil).midX - rect.midX) < 0.01)
    }
}

private enum ResizeInputEvent: Equatable {
    case begin, change(Double), end(Bool)
}

@MainActor
private final class ResizeColumnsProbe {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    weak var imageView: NSImageView?
    var commits = 0
    var publications = 0
}

@MainActor
private struct ResizeColumnsFixture {
    let suite: String
    let defaults: UserDefaults
    let layout: WorkspaceLayoutModel
    let probe = ResizeColumnsProbe()

    init() throws {
        suite = "Glowroom-ResizeInput-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        layout = WorkspaceLayoutModel(defaults: defaults)
        layout.remember()
    }

    func observePublications() -> AnyCancellable {
        layout.objectWillChange.sink { [probe] _ in
            MainActor.assumeIsolated { probe.publications += 1 }
        }
    }

    func removePreferences() { defaults.removePersistentDomain(forName: suite) }
}

private struct ResizeColumnsRoot: View {
    @ObservedObject var layout: WorkspaceLayoutModel
    let probe: ResizeColumnsProbe

    var body: some View {
        WorkspaceColumns(panels: layout.library, navigation: false, libraryLabel: "Test navigation", commit: { widths in
            probe.commits += 1
            layout.update(developing: false) {
                $0.libraryWidth = widths.library
                $0.toolsWidth = widths.tools
            }
        }) {
            Color.gray
        } content: {
            ResizeAcceptedImage(probe: probe)
        } tools: {
            Color.gray
        }
    }
}

private struct ResizeAcceptedImage: NSViewRepresentable {
    let probe: ResizeColumnsProbe

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = probe.image
        probe.imageView = view
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

@MainActor
private final class WorkspaceResizeTestHost {
    let window: NSWindow
    private let content = NSView()
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1_440, height: 700),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = content
    }

    func attach(_ view: NSView) { content.addSubview(view) }

    func mount(_ root: some View) {
        hosting.rootView = AnyView(root.frame(width: 1_440, height: 700))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.orderBack(nil)
    }

    var inputs: [WorkspaceResizeInputView] {
        var pending: [NSView] = [hosting]
        var result: [WorkspaceResizeInputView] = []
        while let view = pending.popLast() {
            if let input = view as? WorkspaceResizeInputView { result.append(input) }
            pending.append(contentsOf: view.subviews)
        }
        return result.sorted { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
    }

    func send(_ type: NSEvent.EventType, to input: WorkspaceResizeInputView, at point: CGPoint) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseDragged: input.mouseDragged(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unexpected resize event \(type)")
        }
    }

    func escape(_ input: WorkspaceResizeInputView) throws {
        input.keyDown(with: try escapeEvent())
    }

    func escapeEvent(modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func close() { hosting.rootView = AnyView(EmptyView()); window.close() }
}
