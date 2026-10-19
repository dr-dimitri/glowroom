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
    let onDoubleClickBegan: (() -> Void)?
    let pansWithPointer: Bool

    init(onInput: @escaping (DevelopCropInputEvent) -> Void,
         onHover: @escaping (CGPoint?) -> Void, isEnabled: Bool,
         inputIdentity: AnyHashable, cursor: @escaping (CGPoint) -> NSCursor,
         onDoubleClick: (() -> Void)? = nil, canvasLabel: String = "Zuschneiden und Drehen auf dem Bild",
         onCancel: (() -> Void)? = nil, onDoubleClickBegan: (() -> Void)? = nil,
         pansWithPointer: Bool = false, canvasIdentifier: String = "develop.interactive-canvas") {
        self.onInput = onInput
        self.onHover = onHover
        self.isEnabled = isEnabled
        self.inputIdentity = inputIdentity
        self.cursor = cursor
        self.onDoubleClick = onDoubleClick
        self.canvasLabel = canvasLabel
        self.canvasIdentifier = canvasIdentifier
        self.onCancel = onCancel
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
                       pansEnclosingScrollView: photoCanvasPanning, pansWithPointer: pansWithPointer)
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
    private var cancellationMonitor: Any?
    private var windowObserver: NSObjectProtocol?
    private var isInvalidated = false
    private var pansEnclosingScrollView = false
    private var pansWithPointer = false
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
                   pansEnclosingScrollView: Bool = false, pansWithPointer: Bool = false) {
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
        inputEnabled = isEnabled
        refreshCursorAtCurrentPointer()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelInput() }
        stopMonitoring()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !isInvalidated else { return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelInput() }
            }
        cancellationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53,
                  self.onCancel != nil || self.pointerStart != nil || self.touchStart != nil || self.pendingDoubleClick != nil else { return event }
            self.cancelInput()
            return nil
        }
        refreshCursorAtCurrentPointer()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
        refreshCursorAtCurrentPointer()
    }

    override func mouseEntered(with event: NSEvent) { publishHover(event) }
    override func mouseMoved(with event: NSEvent) { publishHover(event) }
    override func mouseExited(with event: NSEvent) { onHover(nil); NSCursor.arrow.set() }
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
        NSCursor.arrow.set()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        cancelInput()
        stopMonitoring()
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
        if pansWithPointer && panSession.isActive { NSCursor.closedHand.set() }
        else { cursor(point).set() }
    }

    private func refreshCursorAtCurrentPointer() {
        guard inputEnabled, !isInvalidated, let window, window.isKeyWindow,
              let content = window.contentView else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // Configuration also changes while the pointer is stationary. Refresh
        // only when this surface is the actual target, preserving panel cursors.
        guard visibleRect.contains(point), content.hitTest(convert(point, to: content.superview)) === self else { return }
        cursor(point).set()
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
        cursor(point).set()
    }

    private func stopMonitoring() {
        if let cancellationMonitor { NSEvent.removeMonitor(cancellationMonitor); self.cancellationMonitor = nil }
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
