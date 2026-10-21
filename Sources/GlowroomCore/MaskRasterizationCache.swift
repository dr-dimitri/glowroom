import Foundation

public enum MaskRasterizationReuse: String, Equatable, Sendable {
    case full, unchanged, appended, inverted
}

/// A successful candidate. The caller publishes `cache` only after downstream
/// hashing/resampling succeeds and its source/session/revision is still current.
public struct MaskRasterizationUpdate: Sendable {
    public let raster: MaskRaster
    public let cache: MaskRasterizationCache
    public let reuse: MaskRasterizationReuse
}

/// One immutable raster/document pair, owned by an admitted serial worker.
/// Source/session/revision identity belongs to that worker, not the vector data.
/// Value semantics keep a cancelled candidate from modifying the previous entry.
public struct MaskRasterizationCache: Sendable {
    private struct Entry: Sendable {
        let document: MaskDocument
        let raster: MaskRaster
        let region: ArtifactPixelRect
    }
    private let entry: Entry?
    public init() { entry = nil }
    private init(document: MaskDocument, raster: MaskRaster, region: ArtifactPixelRect) {
        entry = Entry(document: document, raster: raster, region: region)
    }

    public func rasterize(_ document: MaskDocument,
                          outputSize: ArtifactPixelSize? = nil, crop: ArtifactPixelRect? = nil,
                          maximumSampleEvaluations: Int = 268_435_456,
                          cancellation: @Sendable () throws -> Void = {}) throws -> MaskRasterizationUpdate {
        try document.validate(); try Task.checkCancellation(); try cancellation()
        let region = try MaskRasterizer.region(canvas: document.canvasSize, crop: crop)
        let size = outputSize ?? region.size
        guard maximumSampleEvaluations > 0 else { throw ArtifactContractError.limitExceeded }
        guard let entry, entry.document.canvasSize == document.canvasSize,
              entry.region == region, entry.raster.size == size,
              let continuation = Self.continuation(from: entry.document, to: document) else {
            let raster = try MaskRasterizer.rasterize(document, outputSize: size, crop: region,
                maximumSampleEvaluations: maximumSampleEvaluations, cancellation: cancellation)
            return .init(raster: raster, cache: .init(document: document, raster: raster, region: region), reuse: .full)
        }

        // Admission is a property of the complete document, independent of cache
        // history. An unchanged entry cannot bypass a newly lowered work limit.
        try Self.validateWork(document, region: region, size: size,
                              maximum: maximumSampleEvaluations, cancellation: cancellation)
        if continuation.stroke == document.strokes.count, !continuation.invert {
            try Task.checkCancellation(); try cancellation()
            return .init(raster: entry.raster, cache: self, reuse: .unchanged)
        }

        var bytes = entry.raster.bytes
        try bytes.withUnsafeMutableBytes { storage in
            let pixels = storage.bindMemory(to: UInt8.self)
            if continuation.invert {
                for index in pixels.indices {
                    if index.isMultiple(of: 65_536) { try Task.checkCancellation(); try cancellation() }
                    pixels[index] = 255 - pixels[index]
                }
            }
            if continuation.replacesDot {
                let old = entry.document.strokes[continuation.stroke]
                let dirty = Self.bounds(old.points[0], old.points[0], radius: old.radius, region: region, size: size)
                // The reference replaces a standalone dot with a capsule. Undo
                // that dot exactly by rebuilding only its former output bounds;
                // geometric containment alone cannot prove identical feather
                // rounding. Parent coordinates/scales stay unchanged while prior
                // ordered strokes are clipped to this output rectangle.
                for y in dirty.minY..<dirty.maxY {
                    if y.isMultiple(of: 16) { try Task.checkCancellation(); try cancellation() }
                    for x in dirty.minX..<dirty.maxX {
                        pixels[y * size.width + x] = document.isInverted ? 255 : 0
                    }
                }
                for stroke in document.strokes[..<continuation.stroke] {
                    try Self.apply(stroke, startingAt: 0, pixels: pixels, region: region, size: size,
                                   clip: dirty, cancellation: cancellation)
                }
            }
            // Previously rendered capsule segments remain literally unchanged;
            // only new segments are applied with idempotent max/min. Different
            // stroke modes remain ordered, so parallel writes change semantics.
            for strokeIndex in continuation.stroke..<document.strokes.count {
                let stroke = document.strokes[strokeIndex]
                let start = strokeIndex == continuation.stroke ? continuation.segment : 0
                try Self.apply(stroke, startingAt: start, pixels: pixels, region: region, size: size,
                               cancellation: cancellation)
            }
        }
        try Task.checkCancellation(); try cancellation()
        let raster = try MaskRaster(size: size, bytes: bytes)
        return .init(raster: raster, cache: .init(document: document, raster: raster, region: region),
                     reuse: continuation.invert ? .inverted : .appended)
    }

    private struct Continuation {
        let stroke: Int
        let segment: Int
        let invert: Bool
        let replacesDot: Bool
    }

    private static func continuation(from old: MaskDocument, to new: MaskDocument) -> Continuation? {
        guard new.strokes.count >= old.strokes.count else { return nil }
        let invert = old.isInverted != new.isInverted
        for index in old.strokes.indices {
            let a = old.strokes[index], b = new.strokes[index]
            guard a.radius == b.radius, a.hardness == b.hardness,
                  invert ? a.mode != b.mode : a.mode == b.mode else { return nil }
            if a.points == b.points { continue }
            guard index == old.strokes.count - 1,
                  b.points.count > a.points.count,
                  b.points.starts(with: a.points) else { return nil }
            return .init(stroke: index, segment: max(0, a.points.count - 1), invert: invert,
                         replacesDot: a.points.count == 1)
        }
        return .init(stroke: old.strokes.count, segment: 0, invert: invert, replacesDot: false)
    }

    private struct Bounds {
        let minX: Int, minY: Int, maxX: Int, maxY: Int
    }

    private static func apply(_ stroke: MaskStroke, startingAt start: Int,
                              pixels: UnsafeMutableBufferPointer<UInt8>, region: ArtifactPixelRect,
                              size: ArtifactPixelSize, clip: Bounds? = nil,
                              cancellation: @Sendable () throws -> Void) throws {
        try Task.checkCancellation(); try cancellation()
        let scaleX = Double(region.size.width) / Double(size.width)
        let scaleY = Double(region.size.height) / Double(size.height)
        for segment in start..<max(1, stroke.points.count - 1) {
            if segment.isMultiple(of: 64) { try Task.checkCancellation(); try cancellation() }
            let a = stroke.points[segment], b = stroke.points[min(segment + 1, stroke.points.count - 1)]
            let full = bounds(a, b, radius: stroke.radius, region: region, size: size)
            let minX = max(full.minX, clip?.minX ?? full.minX)
            let minY = max(full.minY, clip?.minY ?? full.minY)
            let maxX = min(full.maxX, clip?.maxX ?? full.maxX)
            let maxY = min(full.maxY, clip?.maxY ?? full.maxY)
            guard minX < maxX, minY < maxY else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let hardRadius = stroke.radius * stroke.hardness
            for y in minY..<maxY {
                if y.isMultiple(of: 16) { try Task.checkCancellation(); try cancellation() }
                let py = Double(region.y) + (Double(y) + 0.5) * scaleY
                for x in minX..<maxX {
                    let px = Double(region.x) + (Double(x) + 0.5) * scaleX
                    let t = lengthSquared == 0 ? 0 : max(0, min(1, ((px - a.x) * dx + (py - a.y) * dy) / lengthSquared))
                    let ox = px - (a.x + t * dx), oy = py - (a.y + t * dy)
                    let distanceSquared = ox * ox + oy * oy
                    guard distanceSquared < stroke.radius * stroke.radius else { continue }
                    let coverage: UInt8
                    if distanceSquared <= hardRadius * hardRadius || stroke.hardness == 1 { coverage = 255 }
                    else { coverage = UInt8((255 * (stroke.radius - distanceSquared.squareRoot()) / (stroke.radius - hardRadius)).rounded()) }
                    let offset = y * size.width + x
                    if stroke.mode == .brush { pixels[offset] = max(pixels[offset], coverage) }
                    else { pixels[offset] = min(pixels[offset], 255 - coverage) }
                }
            }
        }
    }

    private static func bounds(_ a: MaskPoint, _ b: MaskPoint, radius: Double,
                               region: ArtifactPixelRect, size: ArtifactPixelSize) -> Bounds {
        let scaleX = Double(region.size.width) / Double(size.width)
        let scaleY = Double(region.size.height) / Double(size.height)
        return .init(minX: max(0, min(size.width, Int(floor((min(a.x, b.x) - radius - Double(region.x)) / scaleX)))),
                     minY: max(0, min(size.height, Int(floor((min(a.y, b.y) - radius - Double(region.y)) / scaleY)))),
                     maxX: max(0, min(size.width, Int(ceil((max(a.x, b.x) + radius - Double(region.x)) / scaleX)))),
                     maxY: max(0, min(size.height, Int(ceil((max(a.y, b.y) + radius - Double(region.y)) / scaleY)))))
    }

    private static func validateWork(_ document: MaskDocument, region: ArtifactPixelRect,
                                     size: ArtifactPixelSize, maximum: Int,
                                     cancellation: @Sendable () throws -> Void) throws {
        var remaining = maximum
        for stroke in document.strokes {
            try Task.checkCancellation(); try cancellation()
            for index in 0..<max(1, stroke.points.count - 1) {
                if index.isMultiple(of: 64) { try Task.checkCancellation(); try cancellation() }
                let bounds = bounds(stroke.points[index], stroke.points[min(index + 1, stroke.points.count - 1)],
                                    radius: stroke.radius, region: region, size: size)
                let count = (bounds.maxX - bounds.minX) * (bounds.maxY - bounds.minY)
                guard count <= remaining else { throw ArtifactContractError.limitExceeded }
                remaining -= count
            }
        }
    }
}
