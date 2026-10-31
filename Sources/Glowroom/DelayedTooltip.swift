import AppKit
import SwiftUI

extension View {
    /// Unlike native `help`, this uses the same two-second dwell for every tool.
    func delayedTooltip(_ text: String) -> some View {
        background(DelayedTooltipAnchor(text: text).accessibilityHidden(true))
    }
}

private struct DelayedTooltipAnchor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> DelayedTooltipAnchorView {
        let view = DelayedTooltipAnchorView(frame: .zero)
        view.text = text
        return view
    }

    func updateNSView(_ view: DelayedTooltipAnchorView, context: Context) { view.text = text }

    static func dismantleNSView(_ view: DelayedTooltipAnchorView, coordinator: ()) { view.dismiss() }
}

/// A non-interactive anchor leaves button hit testing and accessibility intact.
/// The bubble has its own nonactivating window so a scrolling inspector cannot
/// clip it, and waiting suspends instead of blocking AppKit's main thread.
@MainActor
final class DelayedTooltipAnchorView: NSView {
    static let delay: Duration = .seconds(2)
    var text = "" { didSet { if text != oldValue { dismiss() } } }
    private(set) var tooltipPanel: NSPanel?
    private var hoverArea: NSTrackingArea?
    private var pending: Task<Void, Never>?
    private var requestID: UUID?
    private var eventMonitor: Any?
    private var windowObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        dismiss()
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        dismiss()
        guard let window, !text.isEmpty else { return }
        let request = UUID()
        requestID = request
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.process(event) ?? event
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.delay) } catch { return }
            guard !Task.isCancelled, let self, self.requestID == request else { return }
            self.pending = nil
            self.present()
        }
    }

    override func mouseExited(with event: NSEvent) { dismiss() }

    /// The passive monitor must preserve the original button/key/scroll event.
    func process(_ event: NSEvent) -> NSEvent {
        dismiss()
        return event
    }

    func dismiss() {
        requestID = nil
        pending?.cancel(); pending = nil
        tooltipPanel?.orderOut(nil); tooltipPanel = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
    }

    private func present() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
              !visibleRect.isEmpty, let screen = window.screen else { dismiss(); return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let textSize = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        let size = NSSize(width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 12)
        let available = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        origin.x = min(max(origin.x, available.minX), available.maxX - size.width)
        if origin.y < available.minY { origin.y = anchor.maxY + 6 }
        origin.y = min(max(origin.y, available.minY), available.maxY - size.height)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
                .accessibilityHidden(true))
        tooltipPanel = panel
        panel.orderFront(nil)
    }
}
