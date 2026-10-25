import CoreGraphics
import GlowroomCore

/// Every canvas access names its displayed geometry. Source-editing canvases
/// use .neutral; the finished canvas uses the full accepted frame's geometry.
/// This keeps stored brush/retouch points in the original normalized source.
struct DevelopCanvasCoordinateMapping {
    let plan: DevelopGeometryPlan

    init(sourceSize: CGSize, geometry: DevelopGeometry = .neutral) throws {
        plan = try DevelopGeometryPlan(sourceExtent: CGRect(origin: .zero, size: sourceSize), geometry: geometry)
    }

    func sourcePoint(at location: CGPoint, in imageRect: CGRect, clamp: Bool = false) -> LocalMaskPoint? {
        guard imageRect.width > 0, imageRect.height > 0, location.x.isFinite, location.y.isFinite,
              clamp || (location.x >= imageRect.minX && location.x <= imageRect.maxX &&
                        location.y >= imageRect.minY && location.y <= imageRect.maxY) else { return nil }
        let x = min(1, max(0, (location.x - imageRect.minX) / imageRect.width))
        let y = min(1, max(0, (location.y - imageRect.minY) / imageRect.height))
        guard let source = plan.inputPoint(fromOutputTopLeft: CGPoint(
            x: x * plan.outputExtent.width, y: y * plan.outputExtent.height)) else { return nil }
        return try? LocalMaskPoint(x: source.x / plan.sourceExtent.width, y: source.y / plan.sourceExtent.height)
    }

    func viewPoint(for source: LocalMaskPoint, in imageRect: CGRect) -> CGPoint? {
        guard let output = plan.outputPoint(fromInputTopLeft: CGPoint(
            x: source.x * plan.sourceExtent.width, y: source.y * plan.sourceExtent.height)) else { return nil }
        return CGPoint(x: imageRect.minX + output.x / plan.outputExtent.width * imageRect.width,
                       y: imageRect.minY + output.y / plan.outputExtent.height * imageRect.height)
    }
}
