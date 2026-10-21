import AppKit
import SwiftUI

struct DevelopCropInputEvent {
    enum Phase: Equatable { case began, changed, ended, cancelled }
    enum Kind: Equatable { case pointer, threeFinger }

    let phase: Phase
    let kind: Kind
    let startLocation: CGPoint
    let location: CGPoint
    var translation: CGSize {
        CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
    }
}

/// The photo canvas owns a native surface so it can receive indirect NSTouch
/// events as well as the mouse drags synthesized by Accessibility. The small,
/// bounded event bookkeeping stays on the main actor; rendering stays separate.
struct DevelopCropInputSurface: NSViewRepresentable {
    @Environment(\.photoCanvasPanning) private var photoCanvasPanning
    let onInput: (DevelopCropInputEvent) -> Void
    let onHover: (CGPoint?) -> Void
    let isEnabled: Bool
    let inputIdentity: AnyHashable
    let cursor: (CGPoint) -> NSCursor
    let onDoubleClick: (() -> Void)?
    let canvasLabel: String
    let canvasIdentifier: String
    let onCancel: (() -> Void)?
    let capturesEscapeWhileIdle: Bool
    let onDoubleClickBegan: (() -> Void)?
    let pansWithPointer: Bool

    init(onInput: @escaping (DevelopCropInputEvent) -> Void,
         onHover: @escaping (CGPoint?) -> Void, isEnabled: Bool,
         inputIdentity: AnyHashable, cursor: @escaping (CGPoint) -> NSCursor,
         onDoubleClick: (() -> Void)? = nil, canvasLabel: String = "Zuschneiden und Drehen auf dem Bild",
         onCancel: (() -> Void)? = nil, onDoubleClickBegan: (() -> Void)? = nil,
         pansWithPointer: Bool = false, canvasIdentifier: String = "develop.interactive-canvas",
         capturesEscapeWhileIdle: Bool = true) {
        self.onInput = onInput
        self.onHover = onHover
        self.isEnabled = isEnabled
        self.inputIdentity = inputIdentity
        self.cursor = cursor
        self.onDoubleClick = onDoubleClick
        self.canvasLabel = canvasLabel
        self.canvasIdentifier = canvasIdentifier
        self.onCancel = onCancel
        self.capturesEscapeWhileIdle = capturesEscapeWhileIdle
        self.onDoubleClickBegan = onDoubleClickBegan
        self.pansWithPointer = pansWithPointer
    }

    func makeNSView(context: Context) -> DevelopCropNativeInputView {
        let view = DevelopCropNativeInputView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DevelopCropNativeInputView, context: Context) {
        view.configure(onInput: onInput, onHover: onHover, isEnabled: isEnabled,
                       inputIdentity: inputIdentity, cursor: cursor, onDoubleClick: onDoubleClick, onCancel: onCancel,
                       onDoubleClickBegan: onDoubleClickBegan,
                       pansEnclosingScrollView: photoCanvasPanning, pansWithPointer: pansWithPointer,
                       capturesEscapeWhileIdle: capturesEscapeWhileIdle)
        view.setAccessibilityLabel(canvasLabel)
        view.setAccessibilityIdentifier(canvasIdentifier)
    }

    static func dismantleNSView(_ view: DevelopCropNativeInputView, coordinator: ()) {
        view.invalidate()
    }
}

/// Value-only touch samples keep the public AppKit adapter small and let tests
/// exercise identity replacement, cancellation and multi-device rejection.
struct DevelopCropThreeFingerTracker {
    struct Touch {
        let identity: AnyHashable
        let device: AnyHashable
        let position: CGPoint
    }

    struct Update {
        let phase: DevelopCropInputEvent.Phase
        let translation: CGSize
    }

    private var identities: Set<AnyHashable> = []
    private var initialCentroid: CGPoint?
    private var lastTranslation = CGSize.zero
    private var waitsForAllTouchesToEnd = false
    private(set) var hasTouches = false
    var isTracking: Bool { initialCentroid != nil }

    mutating func update(_ touches: [Touch], cancelled: Bool = false) -> Update? {
        hasTouches = !touches.isEmpty
        if cancelled {
            let result = finish(phase: .cancelled)
            waitsForAllTouchesToEnd = !touches.isEmpty
            return result
        }
        if waitsForAllTouchesToEnd {
            if touches.isEmpty { waitsForAllTouchesToEnd = false }
            return nil
        }
        guard touches.count == 3, let centroid = centroid(touches) else {
            let result = finish(phase: touches.count < 3 ? .ended : .cancelled)
            // A fourth finger or a partial lift must not restart a gesture when
            // the remaining fingers later happen to number three again.
            if result != nil || touches.count >= 3 { waitsForAllTouchesToEnd = !touches.isEmpty }
            return result
        }
        let currentIdentities = Set(touches.map(\.identity))
        guard currentIdentities.count == 3 else { return cancel(untilAllTouchesEnd: true) }
        guard let initialCentroid else {
            identities = currentIdentities
            self.initialCentroid = centroid
            lastTranslation = .zero
            return Update(phase: .began, translation: .zero)
        }
        guard currentIdentities == identities else { return cancel(untilAllTouchesEnd: true) }
        // NSTouch coordinates start at the lower left. Canvas coordinates start
        // at the upper left, so a physical upward gesture moves the crop upward.
        lastTranslation = CGSize(width: centroid.x - initialCentroid.x, height: initialCentroid.y - centroid.y)
        return Update(phase: .changed, translation: lastTranslation)
    }

    mutating func reset() {
        identities = []; initialCentroid = nil; lastTranslation = .zero
        waitsForAllTouchesToEnd = false; hasTouches = false
    }

    mutating func suspendUntilAllTouchesEnd() {
        _ = finish(phase: .cancelled)
        waitsForAllTouchesToEnd = hasTouches
    }

    private mutating func cancel(untilAllTouchesEnd: Bool) -> Update? {
        let result = finish(phase: .cancelled)
        waitsForAllTouchesToEnd = untilAllTouchesEnd
        return result
    }

    private mutating func finish(phase: DevelopCropInputEvent.Phase) -> Update? {
        guard initialCentroid != nil else { return nil }
        let update = Update(phase: phase, translation: lastTranslation)
        identities = []; initialCentroid = nil; lastTranslation = .zero
        return update
    }

    private func centroid(_ touches: [Touch]) -> CGPoint? {
        guard let device = touches.first?.device,
              touches.allSatisfy({ touch in
                  touch.device == device && touch.position.x.isFinite && touch.position.y.isFinite
              }) else { return nil }
        return CGPoint(x: touches.reduce(0) { $0 + $1.position.x } / 3,
                       y: touches.reduce(0) { $0 + $1.position.y } / 3)
    }
}

@MainActor
final class DevelopCropNativeInputView: NSView {
    var onInput: (DevelopCropInputEvent) -> Void = { _ in }
    var onHover: (CGPoint?) -> Void = { _ in }
    var cursor: (CGPoint) -> NSCursor = { _ in .arrow }
    var onDoubleClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDoubleClickBegan: (() -> Void)?
    var inputIdentity: AnyHashable?
    var inputEnabled = true {
        didSet {
            setAccessibilityEnabled(inputEnabled)
            if oldValue && !inputEnabled { cancelInput() }
            updateMouseMovementRegistration()
        }
    }
    private var pointerStart: CGPoint?
    private var pointerLocation: CGPoint?
    private var suppressesPointerUntilMouseUp = false
    private var pendingDoubleClick: CGPoint?
    private var touchStart: CGPoint?
    private var touchLocation: CGPoint?
    private var touchTracker = DevelopCropThreeFingerTracker()
    private var hoverTrackingArea: NSTrackingArea?
    private var inputMonitor: Any?
    private var windowObserver: NSObjectProtocol?
    private weak var mouseMovementWindow: NSWindow?
    private final class MouseMovementRegistration {
        let previousValue: Bool
        var consumers = Set<ObjectIdentifier>()
        init(window: NSWindow) { previousValue = window.acceptsMouseMovedEvents }
    }
    private static let mouseMovementWindows = NSMapTable<NSWindow, MouseMovementRegistration>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var isInvalidated = false
    private var pansEnclosingScrollView = false
    private var pansWithPointer = false
    private var capturesEscapeWhileIdle = true
    private let panSession = PhotoCanvasPanSession()
    private var panViewportSize: CGSize?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        // SwiftUI accessibility modifiers do not expose this native surface's
        // own element; keep the canvas discoverable to VoiceOver and UI tests.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("develop.interactive-canvas")
        setAccessibilityLabel("Zuschneiden und Drehen auf dem Bild")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(onInput: @escaping (DevelopCropInputEvent) -> Void,
                   onHover: @escaping (CGPoint?) -> Void, isEnabled: Bool,
                   inputIdentity: AnyHashable, cursor: @escaping (CGPoint) -> NSCursor,
                   onDoubleClick: (() -> Void)? = nil, onCancel: (() -> Void)? = nil,
                   onDoubleClickBegan: (() -> Void)? = nil,
                   pansEnclosingScrollView: Bool = false, pansWithPointer: Bool = false,
                   capturesEscapeWhileIdle: Bool = true) {
        // End an old asset/tool transaction using its old callback before a new
        // identity's closures replace it.
        if self.inputIdentity != inputIdentity || (!isEnabled && inputEnabled)
            || self.pansEnclosingScrollView != pansEnclosingScrollView || self.pansWithPointer != pansWithPointer {
            cancelInput()
        }
        self.onInput = onInput
        self.onHover = onHover
        self.cursor = cursor
        self.onDoubleClick = onDoubleClick
        self.onCancel = onCancel
        self.onDoubleClickBegan = onDoubleClickBegan
        self.inputIdentity = inputIdentity
        self.pansEnclosingScrollView = pansEnclosingScrollView
        self.pansWithPointer = pansWithPointer
        self.capturesEscapeWhileIdle = capturesEscapeWhileIdle
        inputEnabled = isEnabled
        refreshCursorAtCurrentPointer()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Initial attachment has no active input to cancel. In particular, a
        // one-shot picker must not close just because its surface was mounted.
        if window != nil, window !== newWindow { cancelInput() }
        releaseMouseMovementRegistration()
        stopMonitoring()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !isInvalidated else { return }
        updateMouseMovementRegistration()
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelInput() }
            }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .mouseMoved {
                // SwiftUI's canvas wrappers can own AppKit's hover dispatch.
                // Observe the window queue without taking keyboard focus or
                // consuming the event, and only update its actual hit target.
                if self.window?.isKeyWindow == true, self.ownsPointer(at: event.locationInWindow) {
                    self.publishHover(event)
                }
                return event
            }
            return event.keyCode == 53 && self.cancelForEscape() ? nil : event
        }
        refreshCursorAtCurrentPointer()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
        refreshCursorAtCurrentPointer()
    }

    override func mouseEntered(with event: NSEvent) { publishHover(event) }
    override func mouseMoved(with event: NSEvent) { publishHover(event) }
    override func mouseExited(with event: NSEvent) {
        onHover(nil)
        restoreCursor(at: event.locationInWindow)
    }
    override func cursorUpdate(with event: NSEvent) { publishHover(event) }

    override func mouseDown(with event: NSEvent) {
        guard inputEnabled, !isInvalidated, touchStart == nil, !suppressesPointerUntilMouseUp else { return }
        cancelPointer()
        let point = pointerPoint(event)
        if event.clickCount > 0, event.clickCount.isMultiple(of: 2), onDoubleClick != nil {
            // The first click has already ended with zero translation. Reserve
            // the second click for the parent canvas's established zoom action.
            onDoubleClickBegan?()
            pendingDoubleClick = point
            return
        }
        pendingDoubleClick = nil
        pointerStart = point; pointerLocation = point
        publishInput(DevelopCropInputEvent(phase: .began, kind: .pointer, startLocation: point, location: point))
        publishHover(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let initial = pendingDoubleClick {
            let point = pointerPoint(event)
            if hypot(point.x - initial.x, point.y - initial.y) > 4 {
                pendingDoubleClick = nil
                suppressesPointerUntilMouseUp = true
            }
            return
        }
        guard inputEnabled, !isInvalidated, let start = pointerStart else { return }
        let point = pointerPoint(event)
        pointerLocation = point
        publishInput(DevelopCropInputEvent(phase: .changed, kind: .pointer, startLocation: start, location: point))
        publishHover(event)
    }

    override func mouseUp(with event: NSEvent) {
        suppressesPointerUntilMouseUp = false
        if pendingDoubleClick != nil {
            pendingDoubleClick = nil
            if inputEnabled, !isInvalidated { onDoubleClick?() }
            publishHover(event)
            return
        }
        guard let start = pointerStart else { return }
        let point = pointerPoint(event)
        pointerStart = nil; pointerLocation = nil
        publishInput(DevelopCropInputEvent(phase: .ended, kind: .pointer, startLocation: start, location: point))
        publishHover(event)
    }

    override func touchesBegan(with event: NSEvent) { receiveTouches(event) }
    override func touchesMoved(with event: NSEvent) { receiveTouches(event) }
    override func touchesEnded(with event: NSEvent) { receiveTouches(event) }
    override func touchesCancelled(with event: NSEvent) { receiveTouches(event, cancelled: true) }

    func cancelInput() {
        onCancel?()
        if pointerStart != nil || pendingDoubleClick != nil { suppressesPointerUntilMouseUp = true }
        pendingDoubleClick = nil
        cancelPointer()
        if let start = touchStart {
            let location = touchLocation ?? start
            touchStart = nil; touchLocation = nil
            publishInput(DevelopCropInputEvent(phase: .cancelled, kind: .threeFinger, startLocation: start, location: location))
        }
        panSession.cancel()
        panViewportSize = nil
        touchTracker.suspendUntilAllTouchesEnd()
        onHover(nil)
        restoreCursor()
    }

    /// Passive preview controls must not consume the workspace's Escape key.
    /// A one-shot canvas picker can opt in even before a pointer gesture starts.
    @discardableResult
    func cancelForEscape() -> Bool {
        guard (capturesEscapeWhileIdle && onCancel != nil)
            || pointerStart != nil || touchStart != nil || pendingDoubleClick != nil else { return false }
        cancelInput()
        return true
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        releaseMouseMovementRegistration()
        cancelInput()
        stopMonitoring()
    }

    // A photo and its loupe can share a window. Keep AppKit movement delivery
    // enabled until the last active surface leaves, then restore its owner’s
    // preference. This small shared UI registration stays on the main actor.
    private func updateMouseMovementRegistration() {
        let target = inputEnabled && !isInvalidated ? window : nil
        guard target !== mouseMovementWindow else { return }
        releaseMouseMovementRegistration()
        guard let target else { return }
        let registration = Self.mouseMovementWindows.object(forKey: target)
            ?? MouseMovementRegistration(window: target)
        registration.consumers.insert(ObjectIdentifier(self))
        Self.mouseMovementWindows.setObject(registration, forKey: target)
        target.acceptsMouseMovedEvents = true
        mouseMovementWindow = target
    }

    private func releaseMouseMovementRegistration() {
        guard let window = mouseMovementWindow else { return }
        mouseMovementWindow = nil
        guard let registration = Self.mouseMovementWindows.object(forKey: window) else { return }
        registration.consumers.remove(ObjectIdentifier(self))
        if registration.consumers.isEmpty {
            window.acceptsMouseMovedEvents = registration.previousValue
            Self.mouseMovementWindows.removeObject(forKey: window)
        }
    }

    private func cancelPointer() {
        guard let start = pointerStart else { return }
        let location = pointerLocation ?? start
        pointerStart = nil; pointerLocation = nil
        publishInput(DevelopCropInputEvent(phase: .cancelled, kind: .pointer, startLocation: start, location: location))
    }

    private func pointerPoint(_ event: NSEvent) -> CGPoint {
        // The document moves under the pointer while panning. Window points
        // remain stable and prevent scroll-offset feedback on subsequent drags.
        if pansEnclosingScrollView && pansWithPointer {
            return CGPoint(x: event.locationInWindow.x, y: -event.locationInWindow.y)
        }
        return convert(event.locationInWindow, from: nil)
    }

    func publishInput(_ event: DevelopCropInputEvent) {
        guard event.phase == .cancelled || (inputEnabled && !isInvalidated) else { return }
        if pansEnclosingScrollView, event.kind == .threeFinger || pansWithPointer,
           let scrollView = enclosingScrollView {
            if event.phase == .began { panViewportSize = scrollView.contentView.bounds.size }
            if event.phase != .began, panViewportSize != scrollView.contentView.bounds.size {
                panSession.cancel()
                return
            }
            panSession.handle(event, in: scrollView)
        } else {
            onInput(event)
        }
    }

    private func publishHover(_ event: NSEvent) {
        guard inputEnabled, !isInvalidated else { return }
        let point = convert(event.locationInWindow, from: nil)
        onHover(point)
        let nextCursor = pansWithPointer && panSession.isActive ? NSCursor.closedHand : cursor(point)
        setCursorIfNeeded(nextCursor)
    }

    private func setCursorIfNeeded(_ nextCursor: NSCursor) {
        // Cursor changes can synchronize with the window server. Hover and
        // tracking refreshes need no update while the tool cursor is unchanged.
        if NSCursor.current != nextCursor { nextCursor.set() }
    }

    private func refreshCursorAtCurrentPointer() {
        guard let window, window.isKeyWindow,
              ownsPointer(at: window.mouseLocationOutsideOfEventStream) else { return }
        // Configuration also changes while the pointer is stationary. Refresh
        // only when this surface is the actual target, preserving panel cursors.
        setCursorIfNeeded(cursor(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func ownsPointer(at location: CGPoint) -> Bool {
        guard inputEnabled, !isInvalidated, let content = window?.contentView else { return false }
        let point = convert(location, from: nil)
        return visibleRect.contains(point) && content.hitTest(convert(point, to: content.superview)) === self
    }

    private func restoreCursor(at location: CGPoint? = nil) {
        guard let window, window.isKeyWindow, let content = window.contentView else {
            setCursorIfNeeded(.arrow)
            return
        }
        let location = location ?? window.mouseLocationOutsideOfEventStream
        let target = content.hitTest(content.superview?.convert(location, from: nil) ?? location)
        // Tracking-area exits can arrive after the next surface's entry. Do
        // not let the loupe or a removed canvas overwrite the active picker.
        if let target = target as? DevelopCropNativeInputView, target.ownsPointer(at: location) {
            setCursorIfNeeded(target.cursor(target.convert(location, from: nil)))
        } else {
            setCursorIfNeeded(.arrow)
        }
    }

    private func receiveTouches(_ event: NSEvent, cancelled: Bool = false) {
        guard !isInvalidated, pointerStart == nil, pendingDoubleClick == nil else { return }
        let touches = event.touches(matching: .touching, in: self).filter { $0.type == .indirect && !$0.isResting }
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            cancelInput()
            return
        }
        let viewportSize = pansEnclosingScrollView ? enclosingScrollView?.contentView.bounds.size : nil
        if panSession.isActive, panViewportSize != viewportSize { cancelInput(); return }
        if !panSession.isActive { panViewportSize = viewportSize }
        let travelSize = viewportSize ?? bounds.size
        // Scale normalized pad travel to this viewport. A ten-percent movement
        // across the pad moves the selection ten percent across the canvas.
        let samples = touches.map {
            DevelopCropThreeFingerTracker.Touch(identity: AnyHashable(TouchIdentity($0.identity)),
                device: AnyHashable(TouchIdentity($0.device as? NSObjectProtocol)),
                position: CGPoint(x: $0.normalizedPosition.x * travelSize.width,
                                  y: $0.normalizedPosition.y * travelSize.height))
        }
        guard let update = touchTracker.update(samples, cancelled: cancelled || !inputEnabled), inputEnabled else { return }
        if update.phase == .began { touchStart = convert(event.locationInWindow, from: nil) }
        guard let start = touchStart else { return }
        let point = CGPoint(x: start.x + update.translation.width, y: start.y + update.translation.height)
        touchLocation = point
        if update.phase == .ended || update.phase == .cancelled { touchStart = nil; touchLocation = nil }
        publishInput(DevelopCropInputEvent(phase: update.phase, kind: .threeFinger, startLocation: start, location: point))
        setCursorIfNeeded(cursor(point))
    }

    private func stopMonitoring() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
    }

    /// NSTouch identities are Objective-C value objects, not stable NSTouch
    /// instances; compare them with isEqual as required by the public API.
    private struct TouchIdentity: Hashable {
        let value: NSObjectProtocol?
        init(_ value: NSObjectProtocol?) { self.value = value }
        static func == (lhs: Self, rhs: Self) -> Bool {
            guard let left = lhs.value, let right = rhs.value else { return lhs.value == nil && rhs.value == nil }
            return left.isEqual(right)
        }
        func hash(into hasher: inout Hasher) { hasher.combine(value?.hash ?? 0) }
    }
}
