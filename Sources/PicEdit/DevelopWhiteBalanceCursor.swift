import AppKit

@MainActor
enum DevelopWhiteBalanceCursor {
    static func cursor(at point: CGPoint, in imageRect: CGRect, isEnabled: Bool) -> NSCursor {
        guard isEnabled, point.x.isFinite, point.y.isFinite,
              imageRect.width > 0, imageRect.height > 0, imageRect.contains(point) else { return .arrow }
        return eyedropper
    }

    // Use the inspector button's SF Symbol. A white fill with a dark halo stays
    // visible on both bright and dark photos; cache this tiny UI asset once.
    static let eyedropper: NSCursor = {
        guard let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil) else { return .crosshair }
        let configured = symbol.withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) ?? symbol
        let icon = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            configured.draw(in: rect)
            NSColor.white.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        let image = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let halo = NSShadow()
            halo.shadowColor = .black
            halo.shadowBlurRadius = 1.5
            halo.shadowOffset = .zero
            halo.set()
            icon.draw(in: NSRect(x: 3, y: 3, width: 22, height: 22))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        // NSCursor measures its hotspot from the image's top-left; the
        // diagonal eyedropper samples at its lower-left tip.
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 24))
    }()
}
