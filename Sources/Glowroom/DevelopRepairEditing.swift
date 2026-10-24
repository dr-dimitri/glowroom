import CoreGraphics
import Foundation
import GlowroomCore

enum DevelopRepairEditHandle: Equatable, Sendable {
    case target, source
}

/// Geometry for existing repairs. A drag always translates its original stroke;
/// raster work runs once on the workspace worker, never for pointer updates.
enum DevelopRepairEditing {
    static func hit(at point: CGPoint, strokes: [DevelopRetouchStroke], imageRect: CGRect,
                    handleRadius: CGFloat) -> (id: UUID, handle: DevelopRepairEditHandle)? {
        guard imageRect.width > 0, imageRect.height > 0, point.x.isFinite, point.y.isFinite,
              handleRadius.isFinite, handleRadius >= 0 else { return nil }
        // Handles remain reachable even when another repair covers their area.
        for stroke in strokes.reversed() {
            if distance(point, canvas(stroke.target, in: imageRect)) <= handleRadius {
                return (stroke.id, .target)
            }
            if stroke.replacement == nil,
               distance(point, canvas(stroke.source, in: imageRect)) <= handleRadius {
                return (stroke.id, .source)
            }
        }
        let x = (point.x - imageRect.minX) / imageRect.width
        let y = (point.y - imageRect.minY) / imageRect.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        for stroke in strokes.reversed() {
            if let mask = stroke.mask {
                let column = min(mask.width - 1, Int(x * CGFloat(mask.width)))
                let row = min(mask.height - 1, Int(y * CGFloat(mask.height)))
                if mask.bytes[row * mask.width + column] > 0 { return (stroke.id, .target) }
            } else {
                let radius = stroke.radius * min(imageRect.width, imageRect.height)
                var previous = canvas(stroke.target, in: imageRect)
                if distance(point, previous) <= radius { return (stroke.id, .target) }
                for vertex in stroke.path {
                    let next = canvas(vertex, in: imageRect)
                    if segmentDistance(point, previous, next) <= radius { return (stroke.id, .target) }
                    previous = next
                }
            }
        }
        return nil
    }

    /// Rectangle edges are inclusive lower/upper bounds for normalized deltas.
    /// Compute once at gesture start; a frozen mask has at most 65,536 cells.
    static func translationBounds(for stroke: DevelopRetouchStroke, handle: DevelopRepairEditHandle) -> CGRect {
        if handle == .source {
            guard stroke.replacement == nil else { return .zero }
            return CGRect(x: -stroke.source.x, y: -stroke.source.y, width: 1, height: 1)
        }
        var left = stroke.target.x, right = left, top = stroke.target.y, bottom = top
        for point in stroke.path {
            left = min(left, point.x); right = max(right, point.x)
            top = min(top, point.y); bottom = max(bottom, point.y)
        }
        if let mask = stroke.mask {
            mask.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for row in 0..<mask.height { for column in 0..<mask.width where bytes[row * mask.width + column] > 0 {
                    left = min(left, Double(column) / Double(mask.width))
                    right = max(right, Double(column + 1) / Double(mask.width))
                    top = min(top, Double(row) / Double(mask.height))
                    bottom = max(bottom, Double(row + 1) / Double(mask.height))
                } }
            }
        }
        // With a frozen mask, the ROI also contains unselected model context.
        // Only coverage constrains movement; spare context may leave the image.
        if stroke.mask == nil, let replacement = stroke.replacement {
            let bounds = replacement.bounds
            let x = bounds.x + replacement.offsetX, y = bounds.y + replacement.offsetY
            left = min(left, x); right = max(right, x + bounds.width)
            top = min(top, y); bottom = max(bottom, y + bounds.height)
        }
        // The original region always remains admissible, including tolerated
        // floating-point roundoff in historical replacement rectangles.
        var minX = min(0, -left), minY = min(0, -top)
        var maxX = max(0, 1 - right), maxY = max(0, 1 - bottom)
        if let mask = stroke.mask {
            minX = ceil(minX * Double(mask.width) - 1e-9) / Double(mask.width)
            minY = ceil(minY * Double(mask.height) - 1e-9) / Double(mask.height)
            maxX = floor(maxX * Double(mask.width) + 1e-9) / Double(mask.width)
            maxY = floor(maxY * Double(mask.height) + 1e-9) / Double(mask.height)
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Snapping all related geometry to the frozen mask grid keeps repeated
    /// moves lossless. The canvas uses this same delta for its drag overlay.
    static func translation(for stroke: DevelopRetouchStroke, handle: DevelopRepairEditHandle,
                            requested: CGSize) -> CGSize {
        guard requested.width.isFinite, requested.height.isFinite else { return .zero }
        let bounds = translationBounds(for: stroke, handle: handle)
        var dx = min(bounds.maxX, max(bounds.minX, requested.width))
        var dy = min(bounds.maxY, max(bounds.minY, requested.height))
        if handle == .target, let mask = stroke.mask {
            dx = (dx * Double(mask.width)).rounded() / Double(mask.width)
            dy = (dy * Double(mask.height)).rounded() / Double(mask.height)
        }
        return CGSize(width: min(bounds.maxX, max(bounds.minX, dx)), height: min(bounds.maxY, max(bounds.minY, dy)))
    }

    static func moved(_ stroke: DevelopRetouchStroke, handle: DevelopRepairEditHandle,
                      translation: CGSize) throws -> DevelopRetouchStroke {
        guard translation.width.isFinite, translation.height.isFinite else {
            throw ArtifactContractError.invalidValue("develop retouch translation")
        }
        let delta = Self.translation(for: stroke, handle: handle, requested: translation)
        let dx = delta.width, dy = delta.height
        guard dx != 0 || dy != 0 else { return stroke }
        if handle == .source {
            return try copy(stroke, source: shifted(stroke.source, dx, dy), target: stroke.target,
                            path: stroke.path, mask: stroke.mask, replacement: stroke.replacement)
        }
        let replacement = try stroke.replacement.map { try translated($0, dx: dx, dy: dy) }
        return try copy(stroke, source: stroke.replacement == nil ? stroke.source : shifted(stroke.source, dx, dy),
                        target: shifted(stroke.target, dx, dy),
                        path: stroke.path.map { try shifted($0, dx, dy) },
                        mask: stroke.mask.map { try translated($0, dx: dx, dy: dy) }, replacement: replacement)
    }

    private static func translated(_ mask: LocalMaskRaster, dx: Double, dy: Double) throws -> LocalMaskRaster {
        let offsetX = Int((dx * Double(mask.width)).rounded())
        let offsetY = Int((dy * Double(mask.height)).rounded())
        var output = Data(count: mask.bytes.count)
        try mask.bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            try output.withUnsafeMutableBytes { (result: UnsafeMutableRawBufferPointer) in
                // One bounded raster is smaller than a worker-pool handoff.
                // Whole-cell copies preserve every coverage byte across moves.
                for row in 0..<mask.height {
                    if row.isMultiple(of: 16) { try Task.checkCancellation() }
                    for column in 0..<mask.width {
                        let x = column - offsetX, y = row - offsetY
                        if (0..<mask.width).contains(x), (0..<mask.height).contains(y) {
                            result[row * mask.width + column] = input[y * mask.width + x]
                        }
                    }
                }
            }
        }
        return try LocalMaskRaster(width: mask.width, height: mask.height, bytes: output)
    }

    private static func translated(_ original: DevelopRetouchReplacement, dx: Double, dy: Double) throws -> DevelopRetouchReplacement {
        // Keep every model byte and its sampling grid. The renderer clips
        // off-image context while the durable offset makes round trips lossless.
        try DevelopRetouchReplacement(bounds: original.bounds, width: original.width, height: original.height,
            rgba: original.rgba, offsetX: original.offsetX + dx, offsetY: original.offsetY + dy)
    }

    private static func copy(_ stroke: DevelopRetouchStroke, source: LocalMaskPoint, target: LocalMaskPoint,
                             path: [LocalMaskPoint], mask: LocalMaskRaster?,
                             replacement: DevelopRetouchReplacement?) throws -> DevelopRetouchStroke {
        try DevelopRetouchStroke(id: stroke.id, mode: stroke.mode, source: source, target: target,
            radius: stroke.radius, feather: stroke.feather, opacity: stroke.opacity,
            path: path, mask: mask, replacement: replacement)
    }

    private static func shifted(_ point: LocalMaskPoint, _ dx: Double, _ dy: Double) throws -> LocalMaskPoint {
        try LocalMaskPoint(x: min(1, max(0, point.x + dx)), y: min(1, max(0, point.y + dy)))
    }
    private static func canvas(_ point: LocalMaskPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func segmentDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, square = dx * dx + dy * dy
        let t = square > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / square)) : 0
        return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
    }
}
