import AppKit
import SwiftUI

private struct PhotoCanvasPanningKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PhotoCanvasMagnificationKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var photoCanvasPanning: Bool {
        get { self[PhotoCanvasPanningKey.self] }
        set { self[PhotoCanvasPanningKey.self] = newValue }
    }

    var photoCanvasMagnification: CGFloat {
        get { self[PhotoCanvasMagnificationKey.self] }
        set { self[PhotoCanvasMagnificationKey.self] = newValue }
    }
}

/// Reuse one bitmap cursor instead of redrawing it for every hover event.
@MainActor
enum PhotoCanvasCursors {
    static let zoomIn: NSCursor = {
        let image = NSImage(size: NSSize(width: 25, height: 25), flipped: true) { _ in
            let handle = NSBezierPath()
            handle.move(to: CGPoint(x: 14.5, y: 14.5))
            handle.line(to: CGPoint(x: 22, y: 22))
            handle.lineCapStyle = .round
            NSColor.white.setStroke(); handle.lineWidth = 6; handle.stroke()
            NSColor.black.setStroke(); handle.lineWidth = 3.5; handle.stroke()
            let lens = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 16, height: 16))
            NSColor.white.setFill(); lens.fill()
            NSColor.black.setStroke(); lens.lineWidth = 1.7; lens.stroke()
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: 6, y: 10)); plus.line(to: CGPoint(x: 14, y: 10))
            plus.move(to: CGPoint(x: 10, y: 6)); plus.line(to: CGPoint(x: 10, y: 14))
            plus.lineWidth = 1.6; plus.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 10, y: 10))
    }()
}

/// Only viewport state changes here. Decoded pixels and editing history are
/// untouched; this small, ordered UI operation needs no background worker.
@MainActor
final class PhotoCanvasPanSession {
    private var startOrigin: CGPoint?
    private weak var scrollView: NSScrollView?
    var isActive: Bool { startOrigin != nil }

    func handle(_ event: DevelopCropInputEvent, in scrollView: NSScrollView) {
        if event.phase == .cancelled { cancel(); return }
        if event.phase == .began {
            self.scrollView = scrollView
            startOrigin = scrollView.contentView.bounds.origin
            return
        }
        guard self.scrollView === scrollView, let startOrigin else { return }
        let clip = scrollView.contentView
        var proposed = clip.bounds
        // Pointer travel is measured in window points. Touch input is already
        // scaled to the logical clip bounds by the native input adapter.
        let magnification = scrollView.magnification
        let scale = event.kind == .pointer && magnification.isFinite && magnification > 0 ? magnification : 1
        proposed.origin = CGPoint(x: startOrigin.x - event.translation.width / scale,
                                  y: startOrigin.y - event.translation.height / scale)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
        if event.phase == .ended { cancel() }
    }

    func cancel() { startOrigin = nil; scrollView = nil }
}
