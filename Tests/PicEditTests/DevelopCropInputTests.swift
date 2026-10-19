import AppKit
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Crop move routing")
struct DevelopCropMoveRoutingTests {
    private let image = CGRect(x: 20, y: 40, width: 600, height: 400)

    @Test func interiorMovesHandlesResizeAndOutsideStartsANewSelection() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let box = DevelopCropInteraction.box(crop: crop, imageRect: image)
        #expect(DevelopCropInteraction.dragAction(at: CGPoint(x: box.midX, y: box.midY), crop: crop, imageRect: image) == .move)
        for handle in DevelopCropHandle.allCases {
            let point = handle.position(in: box)
            #expect(DevelopCropInteraction.dragAction(at: point, crop: crop, imageRect: image) == .resize(handle))
            #expect(DevelopCropInteraction.dragAction(at: point, crop: crop, imageRect: image, forceMove: true) == .move)
        }
        #expect(DevelopCropInteraction.dragAction(at: CGPoint(x: 40, y: 60), crop: crop, imageRect: image) == .create)
        #expect(DevelopCropInteraction.dragAction(at: CGPoint(x: image.midX, y: image.midY), crop: nil, imageRect: image) == .create)
        // Native three-finger input on an uncropped source must not create a
        // rectangle; moving the full-source selection simply has no effect.
        #expect(DevelopCropInteraction.dragAction(at: CGPoint(x: image.midX, y: image.midY), crop: nil, imageRect: image, forceMove: true) == .move)
    }

    @Test func handleToleranceCanRemainConstantAfterTheCanvasFitTransform() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let top = DevelopCropHandle.top.position(in: DevelopCropInteraction.box(crop: crop, imageRect: image))
        let point = CGPoint(x: top.x, y: top.y - 20)
        #expect(DevelopCropInteraction.dragAction(at: point, crop: crop, imageRect: image) == .create)
        #expect(DevelopCropInteraction.dragAction(at: point, crop: crop, imageRect: image, hitRadius: 28) == .resize(.top))
    }

    @Test func movementClampsTheWholeRectangleAndNeverChangesItsDimensions() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let moved = try #require(DevelopCropInteraction.moved(crop: crop, translation: CGSize(width: 0.08, height: -0.12)))
        expect(moved.x, 0.28); expect(moved.y, 0.18)
        #expect(moved.width == crop.width && moved.height == crop.height)
        for delta in [CGSize(width: -10, height: -10), CGSize(width: 10, height: 10)] {
            let bounded = try #require(DevelopCropInteraction.moved(crop: crop, translation: delta))
            #expect(bounded.x >= 0 && bounded.y >= 0)
            #expect(bounded.x + bounded.width <= 1 && bounded.y + bounded.height <= 1)
            #expect(bounded.width == crop.width && bounded.height == crop.height)
        }
        // Every update uses the initial rectangle, so returning from a boundary
        // to zero translation restores the precise original position.
        #expect(DevelopCropInteraction.moved(crop: crop, translation: .zero) == crop)
        #expect(DevelopCropInteraction.moved(crop: crop, translation: CGSize(width: CGFloat.infinity, height: 0)) == crop)
        #expect(DevelopCropInteraction.moved(crop: nil, translation: CGSize(width: 0.1, height: 0.1)) == nil)
    }

    private func expect(_ actual: Double, _ expected: Double) { #expect(abs(actual - expected) < 0.000_000_001) }
}

@Suite("Native crop input")
@MainActor
struct DevelopCropNativeInputTests {
    @Test func nativeCanvasExposesItsAccessibilityIdentityAndEnabledState() {
        let view = DevelopCropNativeInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.invalidate() }
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .group)
        #expect(view.accessibilityIdentifier() == "develop.interactive-canvas")
        #expect(view.accessibilityLabel() == "Zuschneiden und Drehen auf dem Bild")
        view.inputEnabled = false
        #expect(!view.isAccessibilityEnabled())
        view.inputEnabled = true
        #expect(view.isAccessibilityEnabled())
    }

    @Test func synthesizedPrimaryDragPublishesOneGestureWithTotalLocalTranslation() throws {
        let view = DevelopCropNativeInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.invalidate() }
        var events: [DevelopCropInputEvent] = []
        view.onInput = { events.append($0) }
        let down = try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 200))
        let drag = try mouse(.leftMouseDragged, at: CGPoint(x: 180, y: 170))
        let up = try mouse(.leftMouseUp, at: CGPoint(x: 190, y: 160))
        view.mouseDown(with: down); view.mouseDragged(with: drag); view.mouseUp(with: up)
        #expect(events.map(\.phase) == [.began, .changed, .ended])
        #expect(events.allSatisfy { $0.kind == .pointer })
        let first = try #require(events.first)
        let changed = try #require(events.dropFirst().first)
        #expect(first.startLocation == view.convert(down.locationInWindow, from: nil))
        #expect(changed.startLocation == first.startLocation)
        #expect(changed.location == view.convert(drag.locationInWindow, from: nil))
        #expect(changed.translation == CGSize(width: changed.location.x - first.location.x,
                                              height: changed.location.y - first.location.y))
    }

    @Test func disablingCancelsOnceAndIgnoresRemainingPointerEvents() throws {
        let view = DevelopCropNativeInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.invalidate() }
        var phases: [DevelopCropInputEvent.Phase] = []
        view.onInput = { phases.append($0.phase) }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.inputEnabled = false
        view.inputEnabled = false
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 200)))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 200, y: 200)))
        #expect(phases == [.began, .cancelled])
        view.inputEnabled = true
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 110, y: 100)))
        #expect(phases == [.began, .cancelled, .began, .ended])
    }

    @Test func newContextClosesTheOldCallbackAndDoesNotRestartAHeldDrag() throws {
        let view = DevelopCropNativeInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.invalidate() }
        var oldPhases: [DevelopCropInputEvent.Phase] = []
        var newPhases: [DevelopCropInputEvent.Phase] = []
        view.configure(onInput: { oldPhases.append($0.phase) }, onHover: { _ in },
                       isEnabled: true, inputIdentity: "old", cursor: { _ in .arrow })
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.configure(onInput: { newPhases.append($0.phase) }, onHover: { _ in },
                       isEnabled: true, inputIdentity: "new", cursor: { _ in .arrow })
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 200)))
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        #expect(oldPhases == [.began, .cancelled])
        #expect(newPhases.isEmpty)
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 200, y: 200)))
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 220, y: 200)))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 240, y: 200)))
        #expect(newPhases == [.began, .ended])
    }

    @Test func teardownCancelsAndRejectsNewInput() throws {
        let view = DevelopCropNativeInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var phases: [DevelopCropInputEvent.Phase] = []
        view.onInput = { phases.append($0.phase) }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.invalidate(); view.invalidate()
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 110, y: 100)))
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 120, y: 100)))
        #expect(phases == [.began, .cancelled])
    }

    @Test func doubleClickZoomsOnceWithoutStartingASecondCropEditOrLeavingAHeldGesture() throws {
        let view = DevelopCropNativeInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.invalidate() }
        var phases: [DevelopCropInputEvent.Phase] = []
        var zoomCount = 0
        view.configure(onInput: { phases.append($0.phase) }, onHover: { _ in },
                       isEnabled: true, inputIdentity: "photo", cursor: { _ in .arrow },
                       onDoubleClick: { zoomCount += 1 })
        let point = CGPoint(x: 200, y: 180)
        view.mouseDown(with: try mouse(.leftMouseDown, at: point))
        view.mouseUp(with: try mouse(.leftMouseUp, at: point))
        view.mouseDown(with: try mouse(.leftMouseDown, at: point, clickCount: 2))
        #expect(phases == [.began, .ended])
        #expect(zoomCount == 0)
        view.mouseUp(with: try mouse(.leftMouseUp, at: point, clickCount: 2))
        view.mouseUp(with: try mouse(.leftMouseUp, at: point, clickCount: 2))
        #expect(zoomCount == 1)
        #expect(phases == [.began, .ended])
        view.mouseDown(with: try mouse(.leftMouseDown, at: point))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 230, y: 200)))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 230, y: 200)))
        #expect(phases == [.began, .ended, .began, .changed, .ended])
    }

    @Test func pendingDoubleClickIsCancelledWhenDisabledOrContextChangesOrWindowInputIsCancelled() throws {
        for cancellation in 0..<3 {
            let view = DevelopCropNativeInputView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            defer { view.invalidate() }
            var zoomCount = 0
            view.configure(onInput: { _ in }, onHover: { _ in }, isEnabled: true,
                           inputIdentity: "old", cursor: { _ in .arrow }, onDoubleClick: { zoomCount += 1 })
            let point = CGPoint(x: 200, y: 180)
            view.mouseDown(with: try mouse(.leftMouseDown, at: point, clickCount: 2))
            switch cancellation {
            case 0: view.inputEnabled = false
            case 1:
                view.configure(onInput: { _ in }, onHover: { _ in }, isEnabled: true,
                               inputIdentity: "new", cursor: { _ in .arrow }, onDoubleClick: { zoomCount += 1 })
            default: view.cancelInput()
            }
            view.mouseUp(with: try mouse(.leftMouseUp, at: point, clickCount: 2))
            #expect(zoomCount == 0)
            view.inputEnabled = true
            view.mouseDown(with: try mouse(.leftMouseDown, at: point, clickCount: 2))
            view.mouseUp(with: try mouse(.leftMouseUp, at: point, clickCount: 2))
            #expect(zoomCount == 1)
        }
    }

    @Test func scrollInputContinuesToTheParentResponder() throws {
        let parent = CropScrollTestParent(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let view = DevelopCropNativeInputView(frame: parent.bounds)
        parent.addSubview(view)
        defer { view.invalidate() }
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                           wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        view.scrollWheel(with: event)
        #expect(parent.scrollCount == 1)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: 1, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: clickCount, pressure: 1))
    }
}

@MainActor
private final class CropScrollTestParent: NSView {
    var scrollCount = 0
    override func scrollWheel(with event: NSEvent) { scrollCount += 1 }
}

@Suite("Three-finger crop touch tracking")
struct DevelopCropThreeFingerTests {
    @Test func exactlyThreeTouchesTrackTheCentroidAndEndAsASingleGesture() throws {
        var tracker = DevelopCropThreeFingerTracker()
        #expect(tracker.update(touches(count: 1)) == nil)
        #expect(tracker.update(touches(count: 2)) == nil)
        #expect(tracker.update(touches(count: 3))?.phase == .began)
        let movedUpdate = tracker.update(Array(touches(count: 3, translation: CGPoint(x: 40, y: 30)).reversed()))
        let moved = try #require(movedUpdate)
        #expect(moved.phase == .changed)
        #expect(moved.translation == CGSize(width: 40, height: -30))
        let endedUpdate = tracker.update(touches(count: 2))
        let ended = try #require(endedUpdate)
        #expect(ended.phase == .ended)
        #expect(ended.translation == moved.translation)
        #expect(tracker.update(touches(count: 3)) == nil)
        #expect(tracker.update([]) == nil)
        #expect(tracker.update(touches(count: 3))?.phase == .began)
    }

    @Test func fourthFingerCancelsAndRequiresAFullLiftBeforeRestarting() {
        var tracker = DevelopCropThreeFingerTracker()
        #expect(tracker.update(touches(count: 3))?.phase == .began)
        #expect(tracker.update(touches(count: 4))?.phase == .cancelled)
        #expect(tracker.update(touches(count: 3)) == nil)
        #expect(tracker.update([]) == nil)
        #expect(tracker.update(touches(count: 3))?.phase == .began)
    }

    @Test func replacedFingerCannotJumpTheSelectionOrRestartBeforeRelease() {
        var tracker = DevelopCropThreeFingerTracker()
        #expect(tracker.update(touches(count: 3))?.phase == .began)
        #expect(tracker.update(touches(count: 3, identityOffset: 1))?.phase == .cancelled)
        #expect(tracker.update(touches(count: 3, identityOffset: 1)) == nil)
        #expect(tracker.update([]) == nil)
        #expect(tracker.update(touches(count: 3, identityOffset: 1))?.phase == .began)
    }

    @Test func cancellationAndContextChangesSuppressRemainingFingers() {
        var tracker = DevelopCropThreeFingerTracker()
        #expect(tracker.update(touches(count: 3))?.phase == .began)
        #expect(tracker.update(touches(count: 3), cancelled: true)?.phase == .cancelled)
        #expect(tracker.update(touches(count: 3)) == nil)
        #expect(tracker.update([]) == nil)
        #expect(tracker.update(touches(count: 3))?.phase == .began)
        tracker.suspendUntilAllTouchesEnd()
        #expect(!tracker.isTracking)
        #expect(tracker.update(touches(count: 3)) == nil)
        #expect(tracker.update([]) == nil)
        #expect(tracker.update(touches(count: 3))?.phase == .began)
    }

    @Test func separateDevicesAndInvalidTouchCoordinatesDoNotStartAGesture() {
        var tracker = DevelopCropThreeFingerTracker()
        var samples = touches(count: 3)
        samples[2] = .init(identity: 2, device: "second", position: samples[2].position)
        #expect(tracker.update(samples) == nil)
        #expect(tracker.update([]) == nil)
        samples = touches(count: 3)
        samples[2] = .init(identity: 2, device: "trackpad", position: CGPoint(x: CGFloat.nan, y: 0))
        #expect(tracker.update(samples) == nil)
        #expect(!tracker.isTracking)
    }

    private func touches(count: Int, translation: CGPoint = .zero, identityOffset: Int = 0) -> [DevelopCropThreeFingerTracker.Touch] {
        (0..<count).map { index in
            .init(identity: index + identityOffset, device: "trackpad",
                  position: CGPoint(x: CGFloat(index) * 20 + translation.x, y: 100 + translation.y))
        }
    }
}
