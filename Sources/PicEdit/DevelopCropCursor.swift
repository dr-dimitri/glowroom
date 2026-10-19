import AppKit

@MainActor
enum DevelopCropCursor {
    static func cursor(for handle: DevelopCropHandle) -> NSCursor {
        switch handle {
        case .top, .bottom: .resizeUpDown
        case .left, .right: .resizeLeftRight
        case .topLeft, .bottomRight: descending
        case .topRight, .bottomLeft: ascending
        }
    }

    // AppKit's public diagonal resize cursors require newer macOS versions.
    // Cache two small vector cursors for the supported macOS 14 baseline.
    private static let descending = diagonal(descending: true)
    private static let ascending = diagonal(descending: false)

    private static func diagonal(descending: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath()
            let points: [(CGFloat, CGFloat)] = [(5, 5), (19, 19), (13, 19), (19, 19), (19, 13),
                                               (5, 11), (5, 5), (11, 5)]
            for (index, point) in points.enumerated() {
                let p = NSPoint(x: point.0, y: descending ? 24 - point.1 : point.1)
                if index == 0 || index == 2 || index == 5 { path.move(to: p) } else { path.line(to: p) }
            }
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.black.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 2; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }
}
