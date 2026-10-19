import AppKit

@MainActor
enum DevelopCropCursor {
    static func cursor(for handle: DevelopCropHandle, angle: Double = 0) -> NSCursor {
        let axis: Double = switch handle {
        case .top, .bottom: 90
        case .left, .right: 0
        case .topLeft, .bottomRight: 45
        case .topRight, .bottomLeft: -45
        }
        // Cursor axes repeat every half turn. Reduce before integer conversion
        // so even an invalid caller's enormous angle cannot overflow. Reuse the
        // four cached shapes nearest to the visible, clockwise-rotated axis.
        let rotation = angle.isFinite ? angle.truncatingRemainder(dividingBy: 180) : 0
        let orientation = Int(((axis + rotation) / 45).rounded())
        switch ((orientation % 4) + 4) % 4 {
        case 0: return .resizeLeftRight
        case 1: return descending
        case 2: return .resizeUpDown
        default: return ascending
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
