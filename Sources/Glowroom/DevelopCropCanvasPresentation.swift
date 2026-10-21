import CoreGraphics
import Foundation

/// Geometry for presenting the decoded source while cropping. Rotating the
/// common image/overlay parent gives immediate feedback without another pixel
/// render or RAW decode. These few scalar operations stay on the UI thread;
/// starting background work would cost more than the calculation.
enum DevelopCropCanvasPresentation {
    static func imageRect(sourceSize: CGSize, viewport: CGSize) -> CGRect {
        guard valid(sourceSize), valid(viewport) else { return .zero }
        let scale = min(viewport.width / sourceSize.width, viewport.height / sourceSize.height)
        guard scale.isFinite, scale > 0 else { return .zero }
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2,
                      y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// An additional scale for an already fitted source. The bounds come from
    /// the image, rather than its letterboxed viewport, so every source corner
    /// and crop handle remains reachable as the straightening angle changes.
    static func fittingScale(sourceSize: CGSize, viewport: CGSize, angle: Double) -> CGFloat {
        let rect = imageRect(sourceSize: sourceSize, viewport: viewport)
        guard !rect.isEmpty, angle.isFinite else { return 1 }
        let radians = radians(angle)
        let cosine = abs(cos(radians)), sine = abs(sin(radians))
        let width = rect.width * cosine + rect.height * sine
        let height = rect.width * sine + rect.height * cosine
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 1 }
        return min(1, viewport.width / width, viewport.height / height)
    }

    /// Inverse of the common parent's centered rotation and uniform scale.
    /// Native event overlays can use this when their events are measured in the
    /// untransformed viewport; SwiftUI gestures in the rotated parent already
    /// receive local canvas coordinates and must not apply it again.
    static func canvasPoint(from point: CGPoint, viewport: CGSize, angle: Double, scale: CGFloat) -> CGPoint? {
        guard valid(viewport), point.x.isFinite, point.y.isFinite,
              angle.isFinite, scale.isFinite, scale > 0 else { return nil }
        let x = (point.x - viewport.width / 2) / scale
        let y = (point.y - viewport.height / 2) / scale
        let radians = radians(angle)
        let cosine = cos(radians), sine = sin(radians)
        return CGPoint(x: viewport.width / 2 + x * cosine + y * sine,
                       y: viewport.height / 2 - x * sine + y * cosine)
    }

    /// The line uses normalized top-left source coordinates. Account for its
    /// pixel aspect before finding the nearest horizontal or vertical axis.
    /// The result has the renderer's clockwise sign, independent of which end
    /// the user draws first. A view-level distance threshold rejects accidental
    /// clicks in screen points, independently of image dimensions and zoom.
    static func straighteningAngle(from start: CGPoint, to end: CGPoint, sourceSize: CGSize) -> Double? {
        guard valid(sourceSize), normalized(start), normalized(end) else { return nil }
        let x = (end.x - start.x) * sourceSize.width
        let y = (end.y - start.y) * sourceSize.height
        guard hypot(x, y) > 0 else { return nil }
        var correction = -Double(atan2(y, x)) * 180 / .pi
        // Use a half-open range to resolve exactly diagonal/reversed lines in
        // the same direction instead of switching between -45 and +45.
        correction -= floor((correction + 45) / 90) * 90
        return correction == 0 ? 0 : correction
    }

    private static func radians(_ angle: Double) -> CGFloat {
        CGFloat(angle.truncatingRemainder(dividingBy: 360) * .pi / 180)
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func normalized(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }
}
