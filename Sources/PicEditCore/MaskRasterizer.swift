import Foundation
import CryptoKit

/// Canonical, tightly packed Gray8 in oriented top-left row order. Zero preserves
/// the input and 255 replaces it. No premultiplication, color profile or alpha.
public struct MaskRaster: Hashable, Sendable {
    public let size: ArtifactPixelSize
    public let bytes: Data
    public init(size: ArtifactPixelSize, bytes: Data) throws {
        guard bytes.count == size.width * size.height else {
            throw ArtifactContractError.invalidValue("mask byte count")
        }
        self.size = size; self.bytes = Data(bytes)
    }
    /// Dimensions are part of identity; identical bytes with a different shape
    /// cannot alias. Hashing is linear work and belongs off the MainActor.
    public func canonicalSHA256() throws -> ArtifactDigest {
        try Task.checkCancellation()
        var hash = SHA256()
        hash.update(data: Data("PicEdit.Mask.Gray8.v1/\(size.width)/\(size.height)\n".utf8))
        let chunkSize = 65_536
        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            try Task.checkCancellation()
            hash.update(data: bytes[start..<min(start + chunkSize, bytes.count)])
        }
        return try .init(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Bilinear sampling at pixel centers. A crop is in this raster's native
    /// coordinates; no aspect-fit letterbox or display scale enters the mapping.
    public func resampled(to outputSize: ArtifactPixelSize, crop: ArtifactPixelRect? = nil,
                          cancellation: @Sendable () throws -> Void = {}) throws -> Self {
        let region = try MaskRasterizer.region(canvas: size, crop: crop)
        try Task.checkCancellation(); try cancellation()
        if region.x == 0, region.y == 0, region.size == size, outputSize == size { return self }
        var output = Data(count: outputSize.width * outputSize.height)
        try output.withUnsafeMutableBytes { destination in
            try bytes.withUnsafeBytes { source in
                let dst = destination.bindMemory(to: UInt8.self)
                let src = source.bindMemory(to: UInt8.self)
                let scaleX = Double(region.size.width) / Double(outputSize.width)
                let scaleY = Double(region.size.height) / Double(outputSize.height)
                for y in 0..<outputSize.height {
                    if y.isMultiple(of: 16) { try Task.checkCancellation(); try cancellation() }
                    let sy = max(Double(region.y), min(Double(region.y + region.size.height - 1), Double(region.y) + (Double(y) + 0.5) * scaleY - 0.5))
                    let y0 = Int(sy.rounded(.down)), y1 = min(y0 + 1, region.y + region.size.height - 1)
                    let fy = sy - Double(y0)
                    for x in 0..<outputSize.width {
                        let sx = max(Double(region.x), min(Double(region.x + region.size.width - 1), Double(region.x) + (Double(x) + 0.5) * scaleX - 0.5))
                        let x0 = Int(sx.rounded(.down)), x1 = min(x0 + 1, region.x + region.size.width - 1)
                        let fx = sx - Double(x0)
                        let top = Double(src[y0 * size.width + x0]) * (1 - fx) + Double(src[y0 * size.width + x1]) * fx
                        let bottom = Double(src[y1 * size.width + x0]) * (1 - fx) + Double(src[y1 * size.width + x1]) * fx
                        dst[y * outputSize.width + x] = UInt8((top * (1 - fy) + bottom * fy).rounded())
                    }
                }
            }
        }
        return try .init(size: outputSize, bytes: output)
    }
}

public enum MaskRasterizer {
    /// One UInt8 output allocation, with a bounded amount of serial work. Stroke
    /// compositing is ordered; parallel writes would race and change erase/paint
    /// semantics. Call from an admitted background worker, never the MainActor.
    public static func rasterize(_ document: MaskDocument, outputSize: ArtifactPixelSize? = nil,
                                 crop: ArtifactPixelRect? = nil,
                                 maximumSampleEvaluations: Int = 268_435_456,
                                 cancellation: @Sendable () throws -> Void = {}) throws -> MaskRaster {
        try document.validate(); try Task.checkCancellation(); try cancellation()
        let region = try region(canvas: document.canvasSize, crop: crop)
        let size = outputSize ?? region.size
        guard maximumSampleEvaluations > 0 else { throw ArtifactContractError.limitExceeded }
        let scaleX = Double(region.size.width) / Double(size.width)
        let scaleY = Double(region.size.height) / Double(size.height)
        var output = Data(repeating: document.isInverted ? 255 : 0, count: size.width * size.height)
        var remaining = maximumSampleEvaluations
        try output.withUnsafeMutableBytes { storage in
            let pixels = storage.bindMemory(to: UInt8.self)
            for stroke in document.strokes {
                try Task.checkCancellation(); try cancellation()
                for index in 0..<max(1, stroke.points.count - 1) {
                    let a = stroke.points[index], b = stroke.points[min(index + 1, stroke.points.count - 1)]
                    let radius = stroke.radius
                    let minX = max(0, min(size.width, Int(floor((min(a.x, b.x) - radius - Double(region.x)) / scaleX))))
                    let minY = max(0, min(size.height, Int(floor((min(a.y, b.y) - radius - Double(region.y)) / scaleY))))
                    let maxX = max(0, min(size.width, Int(ceil((max(a.x, b.x) + radius - Double(region.x)) / scaleX))))
                    let maxY = max(0, min(size.height, Int(ceil((max(a.y, b.y) + radius - Double(region.y)) / scaleY))))
                    let count = (maxX - minX) * (maxY - minY)
                    guard count <= remaining else { throw ArtifactContractError.limitExceeded }
                    remaining -= count
                    let dx = b.x - a.x, dy = b.y - a.y
                    let lengthSquared = dx * dx + dy * dy
                    let hardRadius = radius * stroke.hardness
                    for y in minY..<maxY {
                        if y.isMultiple(of: 16) { try Task.checkCancellation(); try cancellation() }
                        let py = Double(region.y) + (Double(y) + 0.5) * scaleY
                        for x in minX..<maxX {
                            let px = Double(region.x) + (Double(x) + 0.5) * scaleX
                            let t = lengthSquared == 0 ? 0 : max(0, min(1, ((px - a.x) * dx + (py - a.y) * dy) / lengthSquared))
                            let ox = px - (a.x + t * dx), oy = py - (a.y + t * dy)
                            let distanceSquared = ox * ox + oy * oy
                            guard distanceSquared < radius * radius else { continue }
                            let coverage: UInt8
                            if distanceSquared <= hardRadius * hardRadius || stroke.hardness == 1 { coverage = 255 }
                            else { coverage = UInt8((255 * (radius - distanceSquared.squareRoot()) / (radius - hardRadius)).rounded()) }
                            let offset = y * size.width + x
                            if stroke.mode == .brush { pixels[offset] = max(pixels[offset], coverage) }
                            else { pixels[offset] = min(pixels[offset], 255 - coverage) }
                        }
                    }
                }
            }
        }
        try Task.checkCancellation(); try cancellation()
        return try .init(size: size, bytes: output)
    }

    static func region(canvas: ArtifactPixelSize, crop: ArtifactPixelRect?) throws -> ArtifactPixelRect {
        let result = try crop ?? .init(x: 0, y: 0, size: canvas)
        guard result.x >= 0, result.y >= 0,
              result.x <= canvas.width - result.size.width,
              result.y <= canvas.height - result.size.height else {
            throw ArtifactContractError.invalidValue("mask crop")
        }
        return result
    }
}
