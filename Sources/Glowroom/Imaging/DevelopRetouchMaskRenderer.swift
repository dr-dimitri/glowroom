import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore

/// Rasterize one vector gesture, then let Core Image compose its pixels. A
/// single mask avoids retaining a full-frame filter graph for every pointer
/// sample. Like local-adjustment brush masks, vector coverage is capped while
/// source texture and the final composite keep the admitted output resolution.
enum DevelopRetouchMaskRenderer {
    static let maximumPathRasterDimension = 2_048

    static func rasterSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let factor = min(1, Double(maximumPathRasterDimension) / Double(max(width, height)))
        return (max(1, Int((Double(width) * factor).rounded())),
                max(1, Int((Double(height) * factor).rounded())))
    }

    static func coverage(for stroke: DevelopRetouchStroke, extent: CGRect) throws -> CIImage {
        let bytes: Data, width: Int, height: Int
        if let mask = stroke.mask {
            bytes = mask.bytes; width = mask.width; height = mask.height
        } else {
            guard extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max),
                  let size = rasterSize(width: Int(extent.width), height: Int(extent.height)) else {
                throw EditRenderError.unavailable
            }
            width = size.width; height = size.height
            bytes = try pathCoverage(stroke, width: width, height: height)
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let bitmap = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw EditRenderError.unavailable
        }
        // CGImage's top-row convention matches the oriented source. Coverage
        // has no color profile; ICC conversion would alter its feather weights.
        return CIImage(cgImage: bitmap, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(a: extent.width / CGFloat(width), b: 0,
                c: 0, d: extent.height / CGFloat(height), tx: extent.minX, ty: extent.minY))
            .cropped(to: extent)
    }

    /// Bounds the nonzero coverage and the complete surrounding comparison
    /// ring. Both admission and rendering use this rectangle. Include raster
    /// antialiasing and reconstruction support before the morphology halo;
    /// clipping to mathematical path vertices or mask cells would lose color
    /// samples at feathered edges and at enlarged low-resolution mask cells.
    static func healingContextBounds(for stroke: DevelopRetouchStroke, extent: CGRect) -> CGRect? {
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite,
              extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max),
              extent.minX.isFinite, extent.minY.isFinite else { return nil }
        let selection: CGRect
        if let mask = stroke.mask {
            var left = mask.width, top = mask.height, right = 0, bottom = 0
            mask.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for y in 0..<mask.height { for x in 0..<mask.width where bytes[y * mask.width + x] > 0 {
                    left = min(left, x); top = min(top, y)
                    right = max(right, x + 1); bottom = max(bottom, y + 1)
                } }
            }
            guard right > left, bottom > top else { return .null }
            let stepX = extent.width / CGFloat(mask.width), stepY = extent.height / CGFloat(mask.height)
            // Two source-mask cells conservatively cover reconstruction around
            // the first/last active cell, including its half-pixel footprint.
            selection = CGRect(x: extent.minX + CGFloat(left) * stepX,
                y: extent.maxY - CGFloat(bottom) * stepY,
                width: CGFloat(right - left) * stepX, height: CGFloat(bottom - top) * stepY)
                .insetBy(dx: -2 * stepX - 2, dy: -2 * stepY - 2)
        } else {
            guard let size = rasterSize(width: Int(extent.width), height: Int(extent.height)) else { return nil }
            var left = stroke.target.x, right = left, top = stroke.target.y, bottom = top
            for point in stroke.path {
                left = min(left, point.x); right = max(right, point.x)
                top = min(top, point.y); bottom = max(bottom, point.y)
            }
            // The raster's rounded aspect can make its actual scaled radius
            // slightly wider on one axis than radius * source.shorterEdge.
            let rasterRadius = CGFloat(stroke.radius) * CGFloat(min(size.width, size.height))
            let stepX = extent.width / CGFloat(size.width), stepY = extent.height / CGFloat(size.height)
            selection = CGRect(x: extent.minX + left * extent.width,
                y: extent.maxY - bottom * extent.height,
                width: (right - left) * extent.width, height: (bottom - top) * extent.height)
                .insetBy(dx: -(rasterRadius + 2) * stepX - 2, dy: -(rasterRadius + 2) * stepY - 2)
        }
        let morphologyRadius = max(1, CGFloat(stroke.radius) * min(extent.width, extent.height) * 0.5)
        return selection.insetBy(dx: -ceil(morphologyRadius) - 2, dy: -ceil(morphologyRadius) - 2)
            .integral.intersection(extent)
    }

    static func replacement(_ replacement: DevelopRetouchReplacement, extent: CGRect) throws -> CIImage {
        guard let provider = CGDataProvider(data: replacement.rgba as CFData),
              let bitmap = CGImage(width: replacement.width, height: replacement.height, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: replacement.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw EditRenderError.unavailable
        }
        let rect = replacementBounds(replacement, extent: extent)
        return CIImage(cgImage: bitmap).clampedToExtent().transformed(by: CGAffineTransform(
            a: rect.width / CGFloat(replacement.width), b: 0, c: 0, d: rect.height / CGFloat(replacement.height),
            tx: rect.minX, ty: rect.minY)).cropped(to: rect)
    }

    static func replacementBounds(_ replacement: DevelopRetouchReplacement, extent: CGRect) -> CGRect {
        let bounds = replacement.bounds
        return CGRect(x: extent.minX + bounds.x * extent.width,
                      y: extent.maxY - (bounds.y + bounds.height) * extent.height,
                      width: bounds.width * extent.width, height: bounds.height * extent.height)
    }

    private static func pathCoverage(_ stroke: DevelopRetouchStroke, width: Int, height: Int) throws -> Data {
        var bytes = Data(count: width * height)
        try bytes.withUnsafeMutableBytes { storage in
            guard let base = storage.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
                throw EditRenderError.unavailable
            }
            let first = CGPoint(x: stroke.target.x * Double(width), y: stroke.target.y * Double(height))
            let path = CGMutablePath(); path.move(to: first)
            var hasSegment = false
            for point in stroke.path {
                let next = CGPoint(x: point.x * Double(width), y: point.y * Double(height))
                if next != path.currentPoint { path.addLine(to: next); hasSegment = true }
            }
            context.setLineCap(.round); context.setLineJoin(.round)
            context.setShouldAntialias(true)
            // Bitmap-context geometry starts at its bottom edge; the persisted
            // path and the CGImage provider both use top-left row coordinates.
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            let radius = stroke.radius * Double(min(width, height))
            // Nested complete path strokes approximate the same smoothstep
            // falloff as a historical dab, with one union for self-crossings.
            // These dependent writes stay serial; Core Graphics rasterizes the
            // vector and Core Image parallelizes the later image operations.
            let layers = stroke.feather > 0 ? 64 : 1
            for layer in 1...layers {
                try Task.checkCancellation()
                let t = Double(layer) / Double(layers)
                let coverage = t * t * (3 - 2 * t)
                let outerRadius = radius * (1 - stroke.feather * t)
                context.setFillColor(gray: coverage, alpha: 1)
                context.setStrokeColor(gray: coverage, alpha: 1)
                if hasSegment {
                    context.setLineWidth(max(0.000_001, outerRadius * 2))
                    context.addPath(path); context.strokePath()
                } else {
                    context.fillEllipse(in: CGRect(x: first.x - outerRadius, y: first.y - outerRadius,
                                                  width: outerRadius * 2, height: outerRadius * 2))
                }
            }
        }
        try Task.checkCancellation()
        return bytes
    }
}
