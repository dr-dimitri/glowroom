import Foundation

/// One aspect-fit transform for both drawing and hit testing. Its units are
/// logical view points; Retina backing scale never changes persisted pixels.
public struct CanvasGeometry: Hashable, Sendable {
    public let canvasSize: ArtifactPixelSize
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let zoom: Double
    public let panX: Double
    public let panY: Double
    public let scale: Double
    public let originX: Double
    public let originY: Double
    public init(canvasSize: ArtifactPixelSize, viewportWidth: Double, viewportHeight: Double,
                zoom: Double = 1, panX: Double = 0, panY: Double = 0) throws {
        guard viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0, viewportWidth <= 1_048_576, viewportHeight <= 1_048_576,
              zoom.isFinite, (0.000_000_1...64).contains(zoom),
              panX.isFinite, panY.isFinite, abs(panX) <= 1_048_576, abs(panY) <= 1_048_576 else {
            throw ArtifactContractError.invalidValue("canvas geometry")
        }
        let fittedScale = min(viewportWidth / Double(canvasSize.width), viewportHeight / Double(canvasSize.height)) * zoom
        guard fittedScale.isFinite, fittedScale > 0 else { throw ArtifactContractError.invalidValue("canvas scale") }
        self.canvasSize = canvasSize; self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight
        self.zoom = zoom; self.panX = panX; self.panY = panY
        scale = fittedScale
        originX = (viewportWidth - Double(canvasSize.width) * scale) / 2 + panX
        originY = (viewportHeight - Double(canvasSize.height) * scale) / 2 + panY
    }
    public func canvasToView(_ point: MaskPoint) throws -> MaskPoint {
        guard point.x >= 0, point.y >= 0, point.x <= Double(canvasSize.width), point.y <= Double(canvasSize.height) else {
            throw ArtifactContractError.invalidValue("canvas point")
        }
        return try .init(x: originX + point.x * scale, y: originY + point.y * scale)
    }
    /// Letterbox and outside-image locations do not create strokes. Exact edge
    /// locations are valid, with a tiny tolerance for floating-point round trips.
    public func viewToCanvas(_ point: MaskPoint) -> MaskPoint? {
        let x = (point.x - originX) / scale, y = (point.y - originY) / scale
        let epsilon = 1e-9
        guard x >= -epsilon, y >= -epsilon,
              x <= Double(canvasSize.width) + epsilon, y <= Double(canvasSize.height) + epsilon else { return nil }
        return try? .init(x: min(Double(canvasSize.width), max(0, x)), y: min(Double(canvasSize.height), max(0, y)))
    }
}

/// EXIF/TIFF orientation values. The editing canvas is always orientation-up.
/// These mappings act on edge coordinates, so mirrored pixel centers remain
/// exact without a width-versus-width-minus-one ambiguity.
public enum MaskImageOrientation: Int, Codable, CaseIterable, Hashable, Sendable {
    case up = 1, upMirrored, down, downMirrored, leftMirrored, right, rightMirrored, left

    public func orientedSize(rawSize: ArtifactPixelSize) throws -> ArtifactPixelSize {
        if rawValue >= 5 { return try .init(width: rawSize.height, height: rawSize.width) }
        return rawSize
    }
    public func orientedPoint(_ point: MaskPoint, rawSize: ArtifactPixelSize) throws -> MaskPoint {
        try Self.validate(point, in: rawSize)
        let w = Double(rawSize.width), h = Double(rawSize.height)
        switch self {
        case .up: return point
        case .upMirrored: return try .init(x: w - point.x, y: point.y)
        case .down: return try .init(x: w - point.x, y: h - point.y)
        case .downMirrored: return try .init(x: point.x, y: h - point.y)
        case .leftMirrored: return try .init(x: point.y, y: point.x)
        case .right: return try .init(x: h - point.y, y: point.x)
        case .rightMirrored: return try .init(x: h - point.y, y: w - point.x)
        case .left: return try .init(x: point.y, y: w - point.x)
        }
    }
    public func rawPoint(_ point: MaskPoint, rawSize: ArtifactPixelSize) throws -> MaskPoint {
        try Self.validate(point, in: orientedSize(rawSize: rawSize))
        let w = Double(rawSize.width), h = Double(rawSize.height)
        switch self {
        case .up: return point
        case .upMirrored: return try .init(x: w - point.x, y: point.y)
        case .down: return try .init(x: w - point.x, y: h - point.y)
        case .downMirrored: return try .init(x: point.x, y: h - point.y)
        case .leftMirrored: return try .init(x: point.y, y: point.x)
        case .right: return try .init(x: point.y, y: h - point.x)
        case .rightMirrored: return try .init(x: w - point.y, y: h - point.x)
        case .left: return try .init(x: w - point.y, y: point.x)
        }
    }
    public func orient(_ raster: MaskRaster, cancellation: @Sendable () throws -> Void = {}) throws -> MaskRaster {
        try Task.checkCancellation(); try cancellation()
        if self == .up { return raster }
        let size = try orientedSize(rawSize: raster.size)
        var output = Data(count: raster.bytes.count)
        try output.withUnsafeMutableBytes { target in
            try raster.bytes.withUnsafeBytes { source in
                let dst = target.bindMemory(to: UInt8.self), src = source.bindMemory(to: UInt8.self)
                for y in 0..<size.height {
                    if y.isMultiple(of: 16) { try Task.checkCancellation(); try cancellation() }
                    for x in 0..<size.width {
                        // Integer forms of rawPoint at pixel centers avoid any
                        // per-pixel allocation or floating-point rounding.
                        let rx: Int, ry: Int
                        switch self {
                        case .up: rx = x; ry = y
                        case .upMirrored: rx = raster.size.width - 1 - x; ry = y
                        case .down: rx = raster.size.width - 1 - x; ry = raster.size.height - 1 - y
                        case .downMirrored: rx = x; ry = raster.size.height - 1 - y
                        case .leftMirrored: rx = y; ry = x
                        case .right: rx = y; ry = raster.size.height - 1 - x
                        case .rightMirrored: rx = raster.size.width - 1 - y; ry = raster.size.height - 1 - x
                        case .left: rx = raster.size.width - 1 - y; ry = x
                        }
                        dst[y * size.width + x] = src[ry * raster.size.width + rx]
                    }
                }
            }
        }
        return try .init(size: size, bytes: output)
    }
    private static func validate(_ point: MaskPoint, in size: ArtifactPixelSize) throws {
        guard point.x >= 0, point.y >= 0, point.x <= Double(size.width), point.y <= Double(size.height) else {
            throw ArtifactContractError.invalidValue("orientation point")
        }
    }
}
