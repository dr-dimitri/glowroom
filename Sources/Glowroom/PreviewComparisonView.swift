import AppKit
import SwiftUI

enum PreviewComparisonLayout: String, CaseIterable, Identifiable {
    case single, leftRight, splitLeftRight, topBottom, splitTopBottom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: "Einzelbild"
        case .leftRight: "Vorher/Nachher Links/Rechts"
        case .splitLeftRight: "Vorher/Nachher – Teilung links/rechts"
        case .topBottom: "Vorher/Nachher Oben/Unten"
        case .splitTopBottom: "Vorher/Nachher – Teilung oben/unten"
        }
    }
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .leftRight: "rectangle.split.2x1"
        case .splitLeftRight: "rectangle.lefthalf.filled"
        case .topBottom: "rectangle.split.1x2"
        case .splitTopBottom: "rectangle.tophalf.filled"
        }
    }
    var isSplit: Bool { self == .splitLeftRight || self == .splitTopBottom }
    var isHorizontal: Bool { self == .leftRight || self == .splitLeftRight }
}

/// Split views reveal two full-size, equally positioned canvases. Whole-image
/// comparisons instead fit each photo into its own half of the viewport.
struct PreviewComparisonGeometry {
    let beforeFrame: CGRect
    let afterFrame: CGRect
    let beforeContentFrame: CGRect
    let afterContentFrame: CGRect
    let dividerPosition: CGFloat?

    init(layout: PreviewComparisonLayout, size: CGSize, fraction: Double = 0.5) {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        if layout == .single {
            beforeFrame = .zero; beforeContentFrame = .zero
            afterFrame = full; afterContentFrame = full; dividerPosition = nil
            return
        }
        let amount = CGFloat(layout.isSplit ? Self.clampedFraction(fraction) : 0.5)
        let divider = (layout.isHorizontal ? width : height) * amount
        dividerPosition = divider
        beforeFrame = CGRect(x: 0, y: 0, width: layout.isHorizontal ? divider : width,
                             height: layout.isHorizontal ? height : divider)
        afterFrame = CGRect(x: layout.isHorizontal ? divider : 0,
                            y: layout.isHorizontal ? 0 : divider,
                            width: layout.isHorizontal ? width - divider : width,
                            height: layout.isHorizontal ? height : height - divider)
        if layout.isSplit {
            beforeContentFrame = full
            afterContentFrame = CGRect(x: -afterFrame.minX, y: -afterFrame.minY, width: width, height: height)
        } else {
            beforeContentFrame = CGRect(origin: .zero, size: beforeFrame.size)
            afterContentFrame = CGRect(origin: .zero, size: afterFrame.size)
        }
    }

    static func clampedFraction(_ value: Double) -> Double {
        value.isFinite ? min(0.9, max(0.1, value)) : 0.5
    }

    /// At 2× zoom, each canvas extends half its original size past its pane.
    /// One shared bound keeps both whole-image panes covered while panning.
    var zoomPanLimit: CGSize {
        CGSize(width: min(beforeContentFrame.width, afterContentFrame.width) / 2,
               height: min(beforeContentFrame.height, afterContentFrame.height) / 2)
    }
    func clampedPan(_ value: CGSize) -> CGSize {
        let limit = zoomPanLimit
        return CGSize(width: value.width.isFinite ? min(limit.width, max(-limit.width, value.width)) : 0,
                      height: value.height.isFinite ? min(limit.height, max(-limit.height, value.height)) : 0)
    }
}

/// Layout and divider movement only update a few UI scalars. The existing
/// bounded preview pipeline owns all decoding and image rendering, so adding
/// a worker for this constant-size geometry would add scheduling overhead.
struct PreviewComparisonView<Before: View, After: View>: View {
    let layout: PreviewComparisonLayout
    let navigationIdentity: AnyHashable
    let zoomed: Bool
    let onDoubleClick: () -> Void
    private let before: Before
    private let after: After
    @ViewState private var fraction = 0.5
    @ViewState private var dragStart: Double?
    @ViewState private var pan = CGSize.zero
    @ViewState private var panStart: CGSize?
    private struct DividerIdentity: Hashable {
        let layout: PreviewComparisonLayout
        let navigation: AnyHashable
    }
    private struct NavigationIdentity: Hashable {
        let layout: PreviewComparisonLayout
        let source: AnyHashable
        let zoomed: Bool
    }

    init(layout: PreviewComparisonLayout,
         navigationIdentity: AnyHashable = AnyHashable("comparison"),
         zoomed: Bool = false, onDoubleClick: @escaping () -> Void = {},
         @ViewBuilder before: () -> Before, @ViewBuilder after: () -> After) {
        self.layout = layout; self.navigationIdentity = navigationIdentity
        self.zoomed = zoomed; self.onDoubleClick = onDoubleClick
        self.before = before(); self.after = after()
    }

    var body: some View {
        GeometryReader { viewport in
            let geometry = PreviewComparisonGeometry(layout: layout, size: viewport.size, fraction: fraction)
            let visiblePan = geometry.clampedPan(pan)
            ZStack(alignment: .topLeading) {
                if layout == .single {
                    after
                } else {
                    pane(before.environment(\.developPreviewSink, nil).environment(\.developPreviewPending, nil), frame: geometry.beforeFrame,
                         contentFrame: geometry.beforeContentFrame, pan: visiblePan, label: "Vorher", isAfter: false)
                    pane(after, frame: geometry.afterFrame, contentFrame: geometry.afterContentFrame,
                         pan: visiblePan, label: "Nachher", isAfter: true)
                    // The native navigation surface sits below the divider's
                    // input surface so pointer drags cannot start a photo pan.
                    DevelopCropInputSurface(onInput: { movePhoto($0, size: viewport.size) }, onHover: { _ in }, isEnabled: true,
                        inputIdentity: AnyHashable(NavigationIdentity(layout: layout, source: navigationIdentity, zoomed: zoomed)),
                        cursor: { _ in zoomed ? (panStart != nil ? .closedHand : .openHand) : .arrow },
                        onDoubleClick: onDoubleClick,
                        canvasLabel: zoomed ? "Vergleich verschieben · Doppelklick zum Einpassen" : "Vergleich · Doppelklick zum Vergrößern",
                        onCancel: { panStart = nil }, pansWithPointer: false,
                        canvasIdentifier: "workspace.comparison-navigation", capturesEscapeWhileIdle: false,
                        onScroll: zoomed ? { scrollPhoto($0, size: viewport.size) } : nil)
                        .environment(\.photoCanvasPanning, false)
                    if let position = geometry.dividerPosition {
                        divider(position: position, size: viewport.size)
                    }
                }
            }.frame(width: viewport.size.width, height: viewport.size.height).clipped()
        }
        .onChange(of: layout) { _, _ in resetPan(); dragStart = nil }
        .onChange(of: navigationIdentity) { _, _ in resetPan(); dragStart = nil }
        .onChange(of: zoomed) { _, _ in resetPan() }
    }

    private func pane<Content: View>(_ content: Content, frame: CGRect, contentFrame: CGRect, pan: CGSize,
                                      label: String, isAfter: Bool) -> some View {
        content
            .frame(width: contentFrame.width, height: contentFrame.height)
            .scaleEffect(zoomed ? 2 : 1)
            .offset(x: contentFrame.minX + (zoomed ? pan.width : 0),
                    y: contentFrame.minY + (zoomed ? pan.height : 0))
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipped()
            .overlay(alignment: layout.isSplit && layout.isHorizontal && isAfter ? .topTrailing : .topLeading) {
                Text(label).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.canvas.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .padding(10).allowsHitTesting(false)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }

    private func divider(position: CGFloat, size: CGSize) -> some View {
        ZStack {
            Rectangle().fill(Theme.muted.opacity(0.7))
                .frame(width: layout.isHorizontal ? 1 : size.width,
                       height: layout.isHorizontal ? size.height : 1)
                .allowsHitTesting(false)
            if layout.isSplit {
                RoundedRectangle(cornerRadius: 5).fill(Theme.panel)
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.muted.opacity(0.7)) }
                    .overlay {
                        Image(systemName: layout.isHorizontal ? "arrow.left.and.right" : "arrow.up.and.down")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    .frame(width: layout.isHorizontal ? 26 : 36, height: layout.isHorizontal ? 36 : 26)
                    .allowsHitTesting(false)
                PreviewComparisonDividerInput(horizontal: layout.isHorizontal, fraction: fraction,
                    identity: AnyHashable(DividerIdentity(layout: layout, navigation: navigationIdentity)),
                    onInput: { event in moveDivider(event, size: size) },
                    onAdjust: { change in fraction = PreviewComparisonGeometry.clampedFraction(fraction + change) })
                    .frame(width: layout.isHorizontal ? 26 : size.width,
                           height: layout.isHorizontal ? size.height : 26)
            }
        }
        .frame(width: layout.isHorizontal ? 26 : size.width,
               height: layout.isHorizontal ? size.height : 26)
        .position(x: layout.isHorizontal ? position : size.width / 2,
                  y: layout.isHorizontal ? size.height / 2 : position)
    }

    private func moveDivider(_ event: DevelopCropInputEvent, size: CGSize) {
        guard event.kind == .pointer else { return }
        if event.phase == .cancelled { dragStart = nil; return }
        let length = layout.isHorizontal ? size.width : size.height
        guard length.isFinite, length > 0 else { return }
        if event.phase == .began { dragStart = fraction }
        let translation = layout.isHorizontal ? event.translation.width : event.translation.height
        fraction = PreviewComparisonGeometry.clampedFraction((dragStart ?? fraction) + Double(translation / length))
        if event.phase == .ended { dragStart = nil }
    }
    private func movePhoto(_ event: DevelopCropInputEvent, size: CGSize) {
        guard zoomed else { panStart = nil; return }
        if event.phase == .cancelled { panStart = nil; return }
        let geometry = PreviewComparisonGeometry(layout: layout, size: size, fraction: fraction)
        if event.phase == .began { panStart = geometry.clampedPan(pan) }
        guard let panStart else { return }
        pan = geometry.clampedPan(CGSize(width: panStart.width + event.translation.width,
                                       height: panStart.height + event.translation.height))
        if event.phase == .ended { self.panStart = nil }
    }
    private func resetPan() { pan = .zero; panStart = nil }
    private func scrollPhoto(_ delta: CGSize, size: CGSize) {
        guard zoomed else { return }
        let geometry = PreviewComparisonGeometry(layout: layout, size: size, fraction: fraction)
        let current = geometry.clampedPan(pan)
        pan = geometry.clampedPan(CGSize(width: current.width + delta.width, height: current.height + delta.height))
    }
}

private struct PreviewComparisonDividerInput: NSViewRepresentable {
    let horizontal: Bool
    let fraction: Double
    let identity: AnyHashable
    let onInput: (DevelopCropInputEvent) -> Void
    let onAdjust: (Double) -> Void

    func makeNSView(context: Context) -> PreviewComparisonDividerNativeView {
        let view = PreviewComparisonDividerNativeView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: PreviewComparisonDividerNativeView, context: Context) {
        if view.inputIdentity != identity { view.cancelInput(); view.inputIdentity = identity }
        view.horizontal = horizontal; view.onInput = onInput; view.onAdjust = onAdjust
        view.setAccessibilityValue(Int((fraction * 100).rounded()))
        view.window?.invalidateCursorRects(for: view)
    }
    static func dismantleNSView(_ view: PreviewComparisonDividerNativeView, coordinator: ()) {
        view.cancelInput()
    }
}

/// The handle itself moves during a drag. Window coordinates keep accumulated
/// pointer movement stable as its native view receives a new frame from SwiftUI.
@MainActor
final class PreviewComparisonDividerNativeView: NSView {
    var horizontal = true
    var onInput: (DevelopCropInputEvent) -> Void = { _ in }
    var onAdjust: (Double) -> Void = { _ in }
    var inputIdentity: AnyHashable?
    private var pointerStart: CGPoint?
    private var pointerLocation: CGPoint?
    private var keyMonitor: Any?
    private let menus = WorkspaceMenuTracking()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel("Vorher/Nachher-Trennlinie")
        setAccessibilityIdentifier("workspace.comparison-divider")
        setAccessibilityMinValue(10); setAccessibilityMaxValue(90)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: horizontal ? .resizeLeftRight : .resizeUpDown)
    }
    override func mouseDown(with event: NSEvent) {
        let point = windowPoint(event)
        pointerStart = point; pointerLocation = point
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.processKeyEvent(event)
            }
        }
        onInput(.init(phase: .began, kind: .pointer, startLocation: point, location: point))
    }
    override func mouseDragged(with event: NSEvent) { emit(.changed, event: event) }
    override func mouseUp(with event: NSEvent) {
        emit(.ended, event: event); pointerStart = nil; pointerLocation = nil; stopKeyMonitoring()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            cancelInput()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { cancelInput(); onAdjust(0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { cancelInput(); onAdjust(-0.05); return true }

    func cancelInput() {
        stopKeyMonitoring()
        guard let start = pointerStart else { return }
        let point = pointerLocation ?? start
        pointerStart = nil; pointerLocation = nil
        onInput(.init(phase: .cancelled, kind: .pointer, startLocation: start, location: point))
    }
    func processKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown, event.keyCode == 53, event.window === window,
              pointerStart != nil, !menus.isTracking else { return event }
        cancelInput()
        return nil
    }
    private func emit(_ phase: DevelopCropInputEvent.Phase, event: NSEvent) {
        guard let start = pointerStart else { return }
        let point = windowPoint(event); pointerLocation = point
        onInput(.init(phase: phase, kind: .pointer, startLocation: start, location: point))
    }
    private func windowPoint(_ event: NSEvent) -> CGPoint {
        CGPoint(x: event.locationInWindow.x, y: -event.locationInWindow.y)
    }
    @objc private func windowResigned(_ notification: Notification) { cancelInput() }
    private func stopKeyMonitoring() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
