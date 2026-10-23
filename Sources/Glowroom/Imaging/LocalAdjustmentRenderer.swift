import CoreImage
import Foundation
import GlowroomCore

/// Local edits join the same lazy, linear-light graph for previews and export.
/// Geometry stays independent of the current preview size and display scale.
enum LocalAdjustmentRenderer {
    /// Each of the existing two preview lanes may reserve this much additional
    /// local-edit work. Source decoding and base/global filters retain their own
    /// bounds; this is a conservative allocation plan, not measured GPU memory.
    static let previewWorkingMemoryBudget = min(UInt64(512 * 1_024 * 1_024),
                                                ProcessInfo.processInfo.physicalMemory / 16)

    /// Use the largest aspect-preserving proxy that fits the combined local-mask
    /// and geometry/spot-correction plan. The original decoded base is reused.
    static func previewSize(width: Int, height: Int, adjustments: [LocalAdjustment],
                            geometry: DevelopGeometry = .neutral, fixedBytes: UInt64 = 0, outputBytesPerPixel: UInt64 = 0,
                            totalMemoryBudget: UInt64 = .max,
                            replacementColorBytesPerPixel: UInt64 = 0,
                            globalBytesPerPixel: UInt64 = 0) throws -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { throw EditRenderError.unavailable }
        func additionalBytes(_ width: Int, _ height: Int) -> UInt64? {
            guard let local = estimatedAdditionalBytes(adjustments: adjustments, width: width, height: height,
                additionalRenderCount: DevelopGeometryRenderer.replacementCount(in: geometry)),
                  let geometryBytes = DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: geometry, width: width, height: height,
                    replacementColorBytesPerPixel: replacementColorBytesPerPixel) else { return nil }
            let sum = local.addingReportingOverflow(geometryBytes)
            let pixels = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
            let global = pixels.partialValue.multipliedReportingOverflow(by: globalBytesPerPixel)
            let total = sum.partialValue.addingReportingOverflow(global.partialValue)
            return sum.overflow || pixels.overflow || global.overflow || total.overflow ? nil : total.partialValue
        }
        // A dormant mask or crop transform alone adds no spatial buffers. Keep
        // the existing resolution policy when no additional work is needed.
        if additionalBytes(width, height) == 0 { return (width, height) }
        func fits(_ width: Int, _ height: Int) -> Bool {
            guard let bytes = additionalBytes(width, height), bytes <= previewWorkingMemoryBudget else { return false }
            let pixels = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
            let output = pixels.partialValue.multipliedReportingOverflow(by: outputBytesPerPixel)
            let base = fixedBytes.addingReportingOverflow(output.partialValue)
            let total = base.partialValue.addingReportingOverflow(bytes)
            return !pixels.overflow && !output.overflow && !base.overflow && !total.overflow && total.partialValue <= totalMemoryBudget
        }
        if fits(width, height) { return (width, height) }
        let longest = max(width, height)
        func size(_ edge: Int) -> (width: Int, height: Int) {
            let factor = Double(edge) / Double(longest)
            return (max(1, Int((Double(width) * factor).rounded())),
                    max(1, Int((Double(height) * factor).rounded())))
        }
        var lower = min(64, longest), upper = longest
        let minimum = size(lower)
        guard fits(minimum.width, minimum.height) else { throw EditRenderError.insufficientMaskMemory }
        // Only bounded integer planning is serial. Pixel downsampling occupies
        // the existing worker after admission, without creating another pool.
        while lower < upper {
            let midpoint = lower + (upper - lower + 1) / 2
            let candidate = size(midpoint)
            if fits(candidate.width, candidate.height) { lower = midpoint }
            else { upper = midpoint - 1 }
        }
        return size(lower)
    }

    /// Conservative allocation plan, not a measured Core Image peak or process
    /// memory limit. Native backends may tile/reuse these buffers. Count every
    /// saved effective layer so large exports and artifact previews are admitted
    /// before any mask raster or spatial intermediate is allocated.
    static func estimatedAdditionalBytes(adjustments: [LocalAdjustment], width: Int, height: Int,
                                         additionalRenderCount: Int = 0) -> UInt64? {
        guard width > 0, height > 0, (0...DevelopGeometry.maximumRetouchStrokes).contains(additionalRenderCount) else { return nil }
        let pixels = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !pixels.overflow else { return nil }
        var total: UInt64 = 0
        func add(_ amount: UInt64) -> Bool {
            let sum = total.addingReportingOverflow(amount)
            guard !sum.overflow else { return false }
            total = sum.partialValue
            return true
        }
        for original in adjustments {
            let layer = original.normalized
            guard layer.isEffective else { continue }
            // RGBAh candidate + blend + scalar coverage/strength intermediates.
            var bytesPerPixel: UInt64 = 32
            if layer.settings.temperature != 6_500 || layer.settings.tint != 0 { bytesPerPixel += 16 }
            if layer.settings.texture != 0 { bytesPerPixel += 8 }
            if layer.settings.clarity != 0 { bytesPerPixel += 8 }
            var rasterPlanes: UInt64 = 0
            switch layer.mask.shape {
            case .brush:
                rasterPlanes += 1
                if layer.mask.feather > 0 { bytesPerPixel += 8 }
            case .subject(let raster), .sky(let raster):
                guard add(UInt64(raster.bytes.count)) else { return nil }
                if layer.mask.feather > 0 { bytesPerPixel += 8 }
            case .linear, .radial: break
            }
            if let refinement = layer.mask.refinement, !refinement.strokes.isEmpty {
                rasterPlanes += 2
                bytesPerPixel += 24 // Two clamp planes and their composed coverage.
            }
            let intermediates = pixels.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
            guard !intermediates.overflow, add(intermediates.partialValue) else { return nil }
            if rasterPlanes > 0 {
                guard let size = try? brushSize(CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
                let rasters = UInt64(size.width * size.height).multipliedReportingOverflow(by: rasterPlanes)
                guard !rasters.overflow, add(rasters.partialValue) else { return nil }
            }
        }
        // Frozen model ROIs run through the same local layers before ordered
        // repair composition. Their immutable filter graphs remain live too.
        let repeated = total.multipliedReportingOverflow(by: UInt64(additionalRenderCount + 1))
        return repeated.overflow ? nil : repeated.partialValue
    }

    static func apply(to input: CIImage, adjustments: [LocalAdjustment], extent: CGRect,
                      scale: Double, cache: LocalMaskImageCache? = nil,
                      preservesExtendedRange: Bool = false) throws -> CIImage {
        var image = input
        // Layer order is observable where masks overlap. The admitted renderer
        // serializes this graph construction; Core Image parallelizes its pixels.
        for adjustment in adjustments where adjustment.isEffective {
            try Task.checkCancellation()
            let candidate = try EditRenderer.manualAdjustments(image, settings: adjustment.settings.editSettings,
                extent: extent, scale: scale, preservesExtendedRange: preservesExtendedRange)
            let mask = try maskImage(adjustment.mask, extent: extent, cache: cache)
            guard let blended = blendKernel?.apply(extent: extent, arguments: [image, candidate, mask]) else {
                throw EditRenderError.unavailable
            }
            image = blended
        }
        try Task.checkCancellation()
        return image
    }

    /// Also used by the editor's off-main overlay renderer. Scalar mask inputs
    /// have no color space: converting coverage through an ICC profile would
    /// change feathering and the strength of local corrections.
    static func maskImage(_ mask: LocalAdjustmentMask, extent: CGRect) throws -> CIImage {
        try maskImage(mask, extent: extent, cache: nil)
    }

    static func maskImage(_ mask: LocalAdjustmentMask, extent: CGRect,
                          cache: LocalMaskImageCache?) throws -> CIImage {
        try Task.checkCancellation()
        let mask = mask.normalized
        try mask.shape.validate()
        let size = CIVector(x: extent.width, y: extent.height)
        let image: CIImage
        let usesGaussianFeather: Bool
        switch mask.shape {
        case let .linear(start, end):
            guard let result = linearKernel?.apply(extent: extent, arguments: [
                CIVector(x: start.x, y: start.y), CIVector(x: end.x, y: end.y), size, mask.feather
            ]) else { throw EditRenderError.unavailable }
            image = result
            usesGaussianFeather = false
        case let .radial(center, radiusX, radiusY, rotation):
            guard let result = radialKernel?.apply(extent: extent, arguments: [
                CIVector(x: center.x, y: center.y), CIVector(x: radiusX, y: radiusY),
                size, rotation, mask.feather
            ]) else { throw EditRenderError.unavailable }
            image = result
            usesGaussianFeather = false
        case let .brush(document):
            let raster = try cache?.image(document, extent: extent) ?? brushImage(document, extent: extent)
            image = raster
            usesGaussianFeather = true
        case let .subject(raster), let .sky(raster):
            let source = try scalarImage(bytes: raster.bytes, width: raster.width, height: raster.height)
            let scaled = source.clampedToExtent().transformed(by: CGAffineTransform(
                scaleX: extent.width / CGFloat(raster.width), y: extent.height / CGFloat(raster.height)))
                .cropped(to: extent)
            image = scaled
            usesGaussianFeather = true
        }
        var coverage = image
        if let refinement = mask.refinement, !refinement.strokes.isEmpty {
            // Max/min brush composition is a monotone clamp. Rasterize the same
            // ordered canonical operations from zero and one; never rewrite
            // their modes here. The editor maps new visible paint/erase input
            // through mask.isInverted; final inversion still flips old strokes.
            // This applies paint/erase exactly to an arbitrary automatic/gradient
            // base without retaining one graph node for every pointer segment.
            let lowerDocument = try MaskDocument(canvasSize: refinement.canvasSize, strokes: refinement.strokes)
            let upperDocument = try MaskDocument(canvasSize: refinement.canvasSize, strokes: refinement.strokes, isInverted: true)
            let lower = try cache?.image(lowerDocument, extent: extent) ?? brushImage(lowerDocument, extent: extent)
            let upper = try cache?.image(upperDocument, extent: extent) ?? brushImage(upperDocument, extent: extent)
            guard let result = refinementKernel?.apply(extent: extent, arguments: [coverage, lower, upper]) else {
                throw EditRenderError.unavailable
            }
            coverage = result
        }
        if usesGaussianFeather { coverage = feather(coverage, amount: mask.feather, extent: extent) }
        guard let result = strengthKernel?.apply(extent: extent, arguments: [
            coverage, mask.isInverted ? 1.0 : 0.0, mask.opacity
        ]) else { throw EditRenderError.unavailable }
        try Task.checkCancellation()
        return result
    }

    fileprivate static func brushImage(_ document: MaskDocument, extent: CGRect) throws -> CIImage {
        let size = try brushSize(extent)
        let raster = try PipelineTrace.measure(.maskRasterization) {
            try MaskRasterizer.rasterize(document, outputSize: size)
        }
        return try brushImage(raster, extent: extent)
    }

    fileprivate static func brushImage(_ raster: MaskRaster, extent: CGRect) throws -> CIImage {
        let size = raster.size
        let image = try scalarImage(bytes: raster.bytes, width: size.width, height: size.height)
        return image.clampedToExtent().transformed(by: CGAffineTransform(
            scaleX: extent.width / CGFloat(size.width), y: extent.height / CGFloat(size.height)))
            .cropped(to: extent)
    }

    fileprivate static func brushSize(_ extent: CGRect) throws -> ArtifactPixelSize {
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw EditRenderError.unavailable
        }
        // Retaining a full-resolution raster for each exported layer would grow
        // with photo size and layer count. Only brush weights are capped; their
        // normalized geometry and all adjustment filters still use output pixels.
        let factor = min(1, 2_048 / max(extent.width, extent.height))
        return try ArtifactPixelSize(width: max(1, Int((extent.width * factor).rounded())),
                                     height: max(1, Int((extent.height * factor).rounded())))
    }

    private static func scalarImage(bytes: Data, width: Int, height: Int) throws -> CIImage {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw EditRenderError.unavailable
        }
        // CGImage applies the same top-row convention as the developed source.
        // Analytic kernels below cross the top-left/CI y boundary exactly once.
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    private static func feather(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        guard amount > 0 else { return image.cropped(to: extent) }
        return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: 0.025 * min(extent.width, extent.height) * amount
        ]).cropped(to: extent)
    }

    private static let blendKernel = CIColorKernel(source: """
        kernel vec4 glowroomLocalBlend(__sample base, __sample candidate, __sample mask) {
            // Both inputs use the original alpha. Preserve it explicitly so a
            // local correction never fills transparent edges or hidden RGB.
            return vec4(mix(base.rgb, candidate.rgb, clamp(mask.r, 0.0, 1.0)), base.a);
        }
        """)

    private static let strengthKernel = CIColorKernel(source: """
        kernel vec4 glowroomLocalStrength(__sample mask, float inverted, float opacity) {
            float weight = mix(clamp(mask.r, 0.0, 1.0), 1.0 - clamp(mask.r, 0.0, 1.0), inverted) * opacity;
            return vec4(vec3(weight), 1.0);
        }
        """)

    private static let refinementKernel = CIColorKernel(source: """
        kernel vec4 glowroomLocalRefinement(__sample base, __sample lower, __sample upper) {
            float weight = min(max(base.r, lower.r), upper.r);
            return vec4(vec3(weight), 1.0);
        }
        """)

    private static let linearKernel = CIColorKernel(source: """
        kernel vec4 glowroomLocalLinear(vec2 start, vec2 end, vec2 size, float feather) {
            vec2 point = vec2(destCoord().x, size.y - destCoord().y);
            vec2 axis = (end - start) * size;
            float lengthSquared = max(dot(axis, axis), 0.00000001);
            float ramp = clamp(dot(point - start * size, axis) / lengthSquared, 0.0, 1.0);
            float weight = 1.0 - mix(ramp, smoothstep(0.0, 1.0, ramp), feather);
            return vec4(vec3(weight), 1.0);
        }
        """)

    private static let radialKernel = CIColorKernel(source: """
        kernel vec4 glowroomLocalRadial(vec2 center, vec2 radius, vec2 size, float rotation, float feather) {
            vec2 point = vec2(destCoord().x, size.y - destCoord().y) - center * size;
            float c = cos(rotation);
            float s = sin(rotation);
            vec2 local = vec2(c * point.x + s * point.y, -s * point.x + c * point.y);
            float distance = length(local / max(radius * size, vec2(0.000001)));
            float weight = 1.0 - smoothstep(1.0 - max(feather, 0.000001), 1.0, distance);
            return vec4(vec3(weight), 1.0);
        }
        """)
}

/// Geometry is a pure function of document and output size; it has no source or
/// editor-session input. The existing preview token checks guard UI publication.
/// One incremental raster basis and exact images together retain at most 16 MiB
/// per lane. Ordered brush writes use the existing bounded render workers.
final class LocalMaskImageCache: @unchecked Sendable {
    static let maximumEntries = 64
    private struct Key: Hashable {
        let document: MaskDocument
        let size: ArtifactPixelSize
        var retentionCost: Int {
            // Count document arrays independently for every historical entry.
            // Swift may share their immutable storage, making this conservative.
            size.width * size.height + MemoryLayout<Self>.stride + 128 +
                document.strokes.reduce(0) {
                    $0 + MemoryLayout<MaskStroke>.stride + $1.points.count * MemoryLayout<MaskPoint>.stride
                }
        }
    }
    private struct Entry {
        let image: CIImage
        let retentionCost: Int
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var retainedBytes = 0
    private let byteLimit: Int
    private let incrementalEnabled: Bool
    private let maximumSampleEvaluations: Int
    private var rasterizationCache = MaskRasterizationCache()
    private var basisBytes = 0
    private var lastReuse: MaskRasterizationReuse?

    init(incrementalEnabled: Bool = true, byteLimit: Int = 16 * 1_024 * 1_024,
         maximumSampleEvaluations: Int = 268_435_456) {
        self.incrementalEnabled = incrementalEnabled
        self.byteLimit = max(0, byteLimit)
        self.maximumSampleEvaluations = maximumSampleEvaluations
    }

    struct Diagnostics: Sendable {
        let retainedBytes: Int
        let imageCount: Int
        let basisBytes: Int
        let lastRasterReuse: MaskRasterizationReuse?
    }

    func diagnostics() -> Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return Diagnostics(retainedBytes: retainedBytes + basisBytes, imageCount: entries.count,
                           basisBytes: basisBytes, lastRasterReuse: lastReuse)
    }

    func image(_ document: MaskDocument, extent: CGRect) throws -> CIImage {
        let key = Key(document: document, size: try LocalAdjustmentRenderer.brushSize(extent))
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        if let entry = entries[key] {
            order.removeAll { $0 == key }
            order.append(key)
            lastReuse = .unchanged
            return entry.image.clampedToExtent().transformed(by: CGAffineTransform(
                scaleX: extent.width / CGFloat(key.size.width), y: extent.height / CGFloat(key.size.height)))
                .cropped(to: extent)
        }
        let (raster, update) = try PipelineTrace.measure(.maskRasterization) { () throws -> (MaskRaster, MaskRasterizationUpdate?) in
            if incrementalEnabled {
                let update = try rasterizationCache.rasterize(document, outputSize: key.size,
                    maximumSampleEvaluations: maximumSampleEvaluations)
                return (update.raster, update)
            }
            return (try MaskRasterizer.rasterize(document, outputSize: key.size,
                maximumSampleEvaluations: maximumSampleEvaluations), nil)
        }
        let image = try LocalAdjustmentRenderer.brushImage(raster,
            extent: CGRect(x: 0, y: 0, width: key.size.width, height: key.size.height))
        try Task.checkCancellation()
        let cost = key.retentionCost
        // Account the basis separately even when its immutable bytes are shared
        // with a CI provider. This conservatively bounds retained cache payloads.
        let nextBasisBytes = update == nil ? 0 : cost
        while retainedBytes + cost + nextBasisBytes > byteLimit || entries.count >= Self.maximumEntries,
              let oldest = order.first {
            if let removed = entries.removeValue(forKey: oldest) { retainedBytes -= removed.retentionCost }
            order.removeFirst()
        }
        if cost + nextBasisBytes <= byteLimit {
            entries[key] = Entry(image: image, retentionCost: cost)
            order.append(key)
            retainedBytes += cost
            if let update { rasterizationCache = update.cache }
            basisBytes = nextBasisBytes
        } else {
            // A small custom budget must not silently retain an oversized basis.
            rasterizationCache = MaskRasterizationCache(); basisBytes = 0
        }
        lastReuse = update?.reuse ?? .full
        return image.clampedToExtent().transformed(by: CGAffineTransform(
            scaleX: extent.width / CGFloat(key.size.width), y: extent.height / CGFloat(key.size.height)))
            .cropped(to: extent)
    }
}
