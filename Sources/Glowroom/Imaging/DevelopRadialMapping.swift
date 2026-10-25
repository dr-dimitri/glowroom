import CoreGraphics
import Foundation
import GlowroomCore

/// Shared source/warp contract. Coordinates here use absolute CI pixel edges;
/// top-left UI conversion belongs to DevelopGeometryPlan. This scalar solve is
/// deliberately serial; spawning work for 64 bounded bisections costs more.
struct DevelopRadialMapping: Hashable, Sendable {
    let coefficient: Double
    let centerX: Double
    let centerY: Double
    let radiusSquared: Double

    init(extent: CGRect, optics: DevelopOpticsSettings) throws {
        let width = Double(extent.width), height = Double(extent.height)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 131_072, height <= 131_072, width * height <= 268_435_456,
              extent.minX.isFinite, extent.minY.isFinite,
              abs(extent.minX) <= 1_048_576, abs(extent.minY) <= 1_048_576 else {
            throw EditRenderError.unavailable
        }
        coefficient = optics.coefficient
        centerX = Double(extent.midX); centerY = Double(extent.midY)
        radiusSquared = (width * width + height * height) / 4
        // Every output is restricted to the original canvas, hence r <= 1.
        guard radiusSquared.isFinite, radiusSquared > 0,
              1 + 3 * min(0, coefficient) > 0 else { throw EditRenderError.unavailable }
    }

    func source(fromWarp point: CGPoint) -> CGPoint {
        let dx = Double(point.x) - centerX, dy = Double(point.y) - centerY
        let scale = 1 + coefficient * (dx * dx + dy * dy) / radiusSquared
        return CGPoint(x: centerX + dx * scale, y: centerY + dy * scale)
    }

    func warp(fromSource point: CGPoint) -> CGPoint? {
        let dx = Double(point.x) - centerX, dy = Double(point.y) - centerY
        let radius = sqrt((dx * dx + dy * dy) / radiusSquared)
        guard radius.isFinite else { return nil }
        if radius == 0 { return CGPoint(x: centerX, y: centerY) }
        guard radius <= 1 + coefficient + 1e-12 else { return nil }
        var low = 0.0, high = 1.0
        for _ in 0..<64 {
            let middle = (low + high) / 2
            if middle * (1 + coefficient * middle * middle) < radius { low = middle }
            else { high = middle }
        }
        let scale = (low + high) / (2 * radius)
        return CGPoint(x: centerX + dx * scale, y: centerY + dy * scale)
    }

    /// Conservative centered rectangle with the source's aspect ratio. For
    /// k>0 its corners exactly meet the source rectangle, and all inner points
    /// map inside it. Round inward so no transparent border is admitted.
    func validRect(in extent: CGRect) -> CGRect {
        guard coefficient > 0 else { return extent }
        var low = 0.0, high = 1.0
        for _ in 0..<64 {
            let s = (low + high) / 2
            if s * (1 + coefficient * s * s) <= 1 { low = s } else { high = s }
        }
        let halfWidth = extent.width * low / 2, halfHeight = extent.height * low / 2
        let left = ceil(extent.midX - halfWidth), right = floor(extent.midX + halfWidth)
        let bottom = ceil(extent.midY - halfHeight), top = floor(extent.midY + halfHeight)
        return CGRect(x: left, y: bottom, width: max(0, right - left), height: max(0, top - bottom))
    }
}
