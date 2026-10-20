import AppKit
import Testing
@testable import PicEdit

/// The adapter's window registration is shared AppKit state. Keep each
/// attach/disable/detach sequence ordered while using separate fixture windows.
@Suite("Canvas mouse movement delivery", .serialized)
@MainActor
struct DevelopCanvasMouseDeliveryTests {
    @Test(arguments: [false, true])
    func overlappingSurfacesKeepDeliveryUntilTheLastConsumerEnds(initiallyEnabled: Bool) {
        let fixture = CanvasMouseDeliveryFixture(initiallyEnabled: initiallyEnabled)
        defer { fixture.close() }
        let photo = fixture.addInput(at: .zero)
        let loupe = fixture.addInput(at: CGPoint(x: 210, y: 0))
        #expect(fixture.window.acceptsMouseMovedEvents,
            "An attached active canvas must request mouse-moved events")

        photo.inputEnabled = false
        #expect(fixture.window.acceptsMouseMovedEvents,
            "Disabling the photo must keep delivery for the loupe")
        photo.removeFromSuperview()
        #expect(fixture.window.acceptsMouseMovedEvents)
        loupe.invalidate()
        #expect(fixture.window.acceptsMouseMovedEvents == initiallyEnabled,
            "The last canvas must restore the window's previous preference")
        loupe.removeFromSuperview()
        #expect(fixture.window.acceptsMouseMovedEvents == initiallyEnabled,
            "Detaching an invalidated canvas must not release another registration")
    }

    @Test func disablingAndReenablingAStillMountedCanvasUpdatesWindowDelivery() {
        let fixture = CanvasMouseDeliveryFixture(initiallyEnabled: false)
        defer { fixture.close() }
        let photo = fixture.addInput(at: .zero)
        #expect(fixture.window.acceptsMouseMovedEvents)
        photo.inputEnabled = false
        #expect(!fixture.window.acceptsMouseMovedEvents)
        photo.inputEnabled = true
        #expect(fixture.window.acceptsMouseMovedEvents)
        photo.removeFromSuperview()
        #expect(!fixture.window.acceptsMouseMovedEvents)
    }

    @Test func movingASurfaceBetweenWindowsRestoresEachWindowsOwnPreference() {
        let original = CanvasMouseDeliveryFixture(initiallyEnabled: false)
        let replacement = CanvasMouseDeliveryFixture(initiallyEnabled: true)
        defer { original.close(); replacement.close() }
        let photo = original.addInput(at: .zero)
        #expect(original.window.acceptsMouseMovedEvents)

        photo.removeFromSuperview()
        #expect(!original.window.acceptsMouseMovedEvents)
        replacement.content.addSubview(photo)
        #expect(replacement.window.acceptsMouseMovedEvents)
        photo.invalidate()
        #expect(replacement.window.acceptsMouseMovedEvents,
            "A canvas must preserve a window that already requested movement")
        #expect(!original.window.acceptsMouseMovedEvents)
    }
}

@MainActor
private final class CanvasMouseDeliveryFixture {
    let window: NSWindow
    let content = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 200))
    private var inputs: [DevelopCropNativeInputView] = []

    init(initiallyEnabled: Bool) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = initiallyEnabled
        window.contentView = content
    }

    func addInput(at origin: CGPoint) -> DevelopCropNativeInputView {
        let input = DevelopCropNativeInputView(frame: CGRect(origin: origin,
            size: CGSize(width: 200, height: 200)))
        input.configure(onInput: { _ in }, onHover: { _ in }, isEnabled: true,
            inputIdentity: inputs.count, cursor: { _ in .crosshair })
        inputs.append(input)
        content.addSubview(input)
        return input
    }

    func close() {
        for input in inputs { input.invalidate(); input.removeFromSuperview() }
        window.close()
    }
}
