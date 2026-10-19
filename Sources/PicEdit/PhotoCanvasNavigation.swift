import AppKit
import SwiftUI

private struct PhotoCanvasPanningKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var photoCanvasPanning: Bool {
        get { self[PhotoCanvasPanningKey.self] }
        set { self[PhotoCanvasPanningKey.self] = newValue }
    }
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
        proposed.origin = CGPoint(x: startOrigin.x - event.translation.width,
                                  y: startOrigin.y - event.translation.height)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
        if event.phase == .ended { cancel() }
    }

    func cancel() { startOrigin = nil; scrollView = nil }
}
