import AppKit
import Testing
@testable import Glowroom

/// These windows share AppKit state, so their presentation checks stay ordered.
@Suite("Delayed tooltips", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct DelayedTooltipTests {
    @Test func twoSecondDwellRestartsAfterExitAndKeepsMouseInput() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let view = fixture.view
        #expect(DelayedTooltipAnchorView.delay == .seconds(2))
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil, "The tooltip anchor cannot steal button clicks")
        let originalResponder = fixture.window.firstResponder
        view.mouseEntered(with: fixture.event(.mouseEntered))
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(view.tooltipPanel == nil)
        view.mouseExited(with: fixture.event(.mouseExited))
        view.mouseEntered(with: fixture.event(.mouseEntered))
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(view.tooltipPanel == nil, "The cancelled first hover must not publish during the second dwell")
        try await fixture.waitForBubble()
        let bubble = try #require(view.tooltipPanel)
        #expect(bubble.isVisible)
        #expect(!bubble.isKeyWindow)
        #expect(bubble.ignoresMouseEvents)
        #expect(fixture.window.firstResponder === originalResponder)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(view.process(click) === click, "The toolbar action must still receive its original event")
        #expect(view.tooltipPanel == nil)
        #expect(!bubble.isVisible)
    }

    @Test func changedTextAndRemovedAnchorCannotPublishStaleBubble() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.view.mouseEntered(with: fixture.event(.mouseEntered))
        fixture.view.text = "Zuschneiden"
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(fixture.view.tooltipPanel == nil)
        fixture.view.mouseEntered(with: fixture.event(.mouseEntered))
        fixture.view.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(fixture.view.tooltipPanel == nil)
    }

    @MainActor private final class Fixture {
        let window: NSWindow
        let view = DelayedTooltipAnchorView(frame: NSRect(x: 0, y: 0, width: 60, height: 38))

        init() throws {
            _ = NSApplication.shared
            let screen = try #require(NSScreen.main)
            window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 30,
                y: screen.visibleFrame.maxY - 100, width: 60, height: 38),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.contentView = view
            view.text = "Reparieren"
            window.orderBack(nil)
        }

        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }

        func waitForBubble() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while view.tooltipPanel == nil {
                try #require(ContinuousClock.now < deadline, "The tooltip should appear after a complete dwell")
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func close() { view.dismiss(); window.close() }
    }
}
