import CoreImage
import Foundation
import PicEditCore

enum EditRenderError: LocalizedError, Equatable {
    case unavailable
    case oversizedPreview
    case insufficientMaskMemory

    var errorDescription: String? {
        switch self {
        case .unavailable: "Die Bildbearbeitung konnte nicht gerendert werden."
        case .oversizedPreview: "Die Vorschau ist für die Bildbearbeitung zu groß."
        case .insufficientMaskMemory: "Die Vorschau mit Masken oder Retusche überschreitet das verfügbare Speicherbudget. Verkleinere die Vorschau oder reduziere vorübergehend die Korrekturen."
        }
    }
}

/// Synchronous, thread-safe rendering for a bounded background worker. CIContext
/// and kernels are reusable; the mutable filter objects are local to each call.
/// The preview adapter is bounded to 4096 pixels. The same lazy filter graph is
/// also used by the separately budgeted full-resolution JPEG exporter.
enum EditRenderer {
    /// Reuse the selected photo's unchanged filter prefix across slider values.
    /// Core Image still chooses its available GPU/CPU implementation. A single
    /// retained source (up to 64 MiB) bounds decoded-image retention. Core Image
    /// manages its temporary texture budget; render concurrency is bounded above.
    final class Session: @unchecked Sendable {
        let context: CIContext
        private let cachesPrefix: Bool
        private let lock = NSLock()
        private var original: CGImage?
        private var base: CIImage?
        private var denoised: CIImage?
        private var balanced: CIImage?
        private var noise: NoiseKey?
        private var balanceKey: BalanceKey?
        fileprivate let localMaskCache = LocalMaskImageCache()

        private struct BalanceKey: Equatable {
            let legacy: Double
            let amount: Double
            let color: Double
        }
        private let sourceByteLimit = 64 * 1_024 * 1_024

        private struct NoiseKey: Equatable {
            let luminance: Double
            let color: Double
            let hdr: Bool
        }

        init(cacheIntermediates: Bool = false, lowPriority: Bool, softwareRenderer: Bool = false) {
            cachesPrefix = cacheIntermediates
            var options: [CIContextOption: Any] = [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .workingFormat: CIFormat.RGBAh,
                .cacheIntermediates: cacheIntermediates,
                .priorityRequestLow: lowPriority,
                .name: lowPriority ? "PicEdit background" : "PicEdit interactive"
            ]
            // Diagnostic preference only: some platforms ignore this option.
            // The automatic production path retains Core Image's own fallback.
            if softwareRenderer { options[.useSoftwareRenderer] = true }
            context = CIContext(options: options)
        }

        fileprivate func prefix(_ bitmap: PreviewBitmap, settings: EditSettings, extent: CGRect, scale: Double) throws -> CIImage {
            guard cachesPrefix, bitmap.resourceOwner == nil, bitmap.byteCost <= sourceByteLimit else {
                if cachesPrefix {
                    lock.lock()
                    original = nil
                    base = nil
                    denoised = nil
                    balanced = nil
                    noise = nil
                    balanceKey = nil
                    context.clearCaches()
                    lock.unlock()
                }
                return try EditRenderer.prefix(CIImage(cgImage: bitmap.image), original: bitmap.image,
                                               settings: settings, extent: extent, scale: scale)
            }
            // Only immutable graph construction and the small cached histogram
            // analysis are serialized. GPU rendering runs after releasing the lock.
            lock.lock()
            defer { lock.unlock() }
            try Task.checkCancellation()
            if original !== bitmap.image {
                original = bitmap.image
                base = CIImage(cgImage: bitmap.image)
                denoised = nil
                balanced = nil
                noise = nil
                balanceKey = nil
                // Old-photo intermediates cannot help this source. This is a
                // thread-safe cache hint; in-flight renders keep their resources.
                context.clearCaches()
            }
            let noiseKey = NoiseKey(luminance: settings.luminanceNoiseReduction, color: settings.colorNoiseReduction,
                                    hdr: settings.developColor.hdrEnabled)
            if noise != noiseKey {
                denoised = try EditRenderer.denoise(base!, settings: settings, extent: extent, scale: scale)
                noise = noiseKey
                balanced = nil
                balanceKey = nil
            }
            let key = BalanceKey(legacy: settings.autoToneAmount, amount: settings.naturalBalanceAmount,
                                 color: settings.naturalBalanceColorAmount)
            if balanceKey != key {
                balanced = try EditRenderer.balance(denoised!, original: bitmap.image, settings: settings, extent: extent)
                balanceKey = key
            }
            try Task.checkCancellation()
            return balanced!
        }
    }

    private static let interactive = Session(cacheIntermediates: true, lowPriority: false)
    private static let background = Session(cacheIntermediates: false, lowPriority: true)
    private static let maskSoftware = Session(lowPriority: true, softwareRenderer: true)

    /// Mask composition shares the renderer's linear working-space contract.
    /// The caller holds the artifact owner's bounded native-work admission.
    static func maskCompositingContext(softwareRenderer: Bool = false) -> CIContext {
        softwareRenderer ? maskSoftware.context : background.context
    }

    /// The preview decoder may return a larger cached base than requested.
    /// Callers requiring a hard output limit must use these actual raster sizes.
    static func outputSize(_ bitmap: PreviewBitmap, maximumPixelSize: Int?) throws -> (width: Int, height: Int) {
        let width = bitmap.image.width
        let height = bitmap.image.height
        guard width > 0, height > 0 else { throw EditRenderError.unavailable }
        guard let maximumPixelSize else { return (width, height) }
        guard maximumPixelSize > 0, maximumPixelSize <= 4_096 else { throw EditRenderError.oversizedPreview }
        let longest = max(width, height)
        guard longest > maximumPixelSize else { return (width, height) }
        let scale = Double(maximumPixelSize) / Double(longest)
        return (max(1, min(maximumPixelSize, Int((Double(width) * scale).rounded()))),
                max(1, min(maximumPixelSize, Int((Double(height) * scale).rounded()))))
    }

    /// Runs only inside AdjustedPreviewPipeline's existing worker. Reuses the
    /// lane's CIContext and preserves the developed base's profile and alpha.
    static func resized(_ bitmap: PreviewBitmap, width: Int, height: Int,
                        priority: PreviewPriority) throws -> PreviewBitmap {
        try Task.checkCancellation()
        let original = bitmap.image
        guard width > 0, height > 0, width <= original.width, height <= original.height,
              width <= 4_096, height <= 4_096 else { throw EditRenderError.oversizedPreview }
        guard width != original.width || height != original.height else { return bitmap }
        return try autoreleasepool {
            let transform = CGAffineTransform(scaleX: CGFloat(width) / CGFloat(original.width),
                                              y: CGFloat(height) / CGFloat(original.height))
            let image = CIImage(cgImage: original).transformed(by: transform, highQualityDownsample: true)
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let colorSpace = original.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let highPrecision = original.bitsPerComponent > 8
            let floatingPoint = original.bitmapInfo.contains(.floatComponents)
            let format: CIFormat
            switch colorSpace.model {
            case .rgb: format = floatingPoint ? .RGBAh : highPrecision ? .RGBA16 : .RGBA8
            case .monochrome: format = floatingPoint ? .RGBAh : highPrecision ? .LA16 : .LA8
            default: throw EditRenderError.unavailable
            }
            let session = priority == .selected ? interactive : background
            guard let result = session.context.createCGImage(image.cropped(to: extent), from: extent,
                                                             format: format, colorSpace: colorSpace, deferred: false)
            else { throw EditRenderError.unavailable }
            try Task.checkCancellation()
            return PreviewBitmap(image: result)
        }
    }

    static func render(_ bitmap: PreviewBitmap, settings: EditSettings,
                       priority: PreviewPriority = .selected) throws -> PreviewBitmap {
        try Task.checkCancellation()
        let settings = settings.normalized
        guard !settings.isNeutral else { return bitmap }
        return try render(bitmap, settings: settings, session: priority == .selected ? interactive : background)
    }

    static func render(_ bitmap: PreviewBitmap, settings: EditSettings, session: Session) throws -> PreviewBitmap {
        try Task.checkCancellation()
        let settings = settings.normalized
        guard !settings.isNeutral else { return bitmap }
        let original = bitmap.image
        guard original.width > 0, original.height > 0,
              original.width <= 4_096, original.height <= 4_096 else {
            throw EditRenderError.oversizedPreview
        }
        // Direct callers must honor the same local-work limit as the adaptive
        // preview pipeline. The export graph has its separate full-size budget.
        guard let localBytes = LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: settings.localAdjustments,
            width: original.width, height: original.height),
              let geometryBytes = DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: settings.developGeometry,
                width: original.width, height: original.height),
              geometryBytes <= LocalAdjustmentRenderer.previewWorkingMemoryBudget,
              localBytes <= LocalAdjustmentRenderer.previewWorkingMemoryBudget - geometryBytes else {
            throw EditRenderError.insufficientMaskMemory
        }

        return try autoreleasepool {
            let extent = CGRect(x: 0, y: 0, width: original.width, height: original.height)
            // Keep spatial effects comparable at progressive preview sizes.
            let scale = max(0.25, Double(max(original.width, original.height)) / 1_600)
            let prefix = try session.prefix(bitmap, settings: settings, extent: extent, scale: scale)
            let global = try manualAdjustments(prefix, settings: settings, extent: extent, scale: scale)
            // Artifact mask allocations belong to this render's admitted phase;
            // retaining their CPU rasters in a global cache would outlive it.
            let maskCache = bitmap.resourceOwner == nil ? session.localMaskCache : nil
            let image = try LocalAdjustmentRenderer.apply(to: global, adjustments: settings.localAdjustments,
                                                          extent: extent, scale: scale, cache: maskCache,
                                                          preservesExtendedRange: settings.developColor.hdrEnabled)
            let developed = try DevelopGeometryRenderer.apply(to: image, geometry: settings.developGeometry, extent: extent)

            let colorSpace = settings.developColor.hdrEnabled
                ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                : original.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let highPrecision = original.bitsPerComponent > 8
            let format: CIFormat
            switch colorSpace.model {
            case .rgb: format = settings.developColor.hdrEnabled ? .RGBAh : highPrecision ? .RGBA16 : .RGBA8
            case .monochrome: format = highPrecision ? .LA16 : .LA8
            default: throw EditRenderError.unavailable
            }
            let outputExtent = developed.extent
            guard let rendered = session.context.createCGImage(developed, from: outputExtent, format: format, colorSpace: colorSpace, deferred: false) else {
                throw EditRenderError.unavailable
            }
            try Task.checkCancellation()
            return PreviewBitmap(image: rendered)
        }
    }

    /// Builds the full-size graph without converting to a preview or imposing
    /// preview dimensions. The exporter validates its own memory/format limits.
    static func filterGraph(_ original: CGImage, settings: EditSettings) throws -> CIImage {
        try Task.checkCancellation()
        let settings = settings.normalized
        let image = CIImage(cgImage: original)
        guard !settings.isNeutral else { return image }
        let extent = image.extent
        let scale = max(0.25, Double(max(original.width, original.height)) / 1_600)
        let prefix = try prefix(image, original: original, settings: settings, extent: extent, scale: scale)
        let global = try manualAdjustments(prefix, settings: settings, extent: extent, scale: scale)
        let local = try LocalAdjustmentRenderer.apply(to: global, adjustments: settings.localAdjustments,
            extent: extent, scale: scale, preservesExtendedRange: settings.developColor.hdrEnabled)
        return try DevelopGeometryRenderer.apply(to: local, geometry: settings.developGeometry, extent: extent)
    }

    static func manualAdjustments(_ input: CIImage, settings: EditSettings,
                                  extent: CGRect, scale: Double, preservesExtendedRange: Bool = false) throws -> CIImage {
        try Task.checkCancellation()
        let extended = preservesExtendedRange || settings.developColor.hdrEnabled
        var image = try DevelopColorAdjustments.input(input, settings: settings.developColor, extent: extent)
        if settings.exposure != 0 || settings.contrast != 0 || settings.highlights != 0 || settings.shadows != 0 ||
            settings.whites != 0 || settings.blacks != 0 || settings.dehaze != 0 || settings.vibrance != 0 || settings.saturation != 0 {
            guard let result = toneKernel?.apply(extent: extent, arguments: [
                image, settings.exposure, settings.contrast / 100,
                settings.highlights / 100, settings.shadows / 100,
                settings.whites / 100, settings.blacks / 100,
                settings.dehaze / 100, settings.vibrance / 100, settings.saturation / 100, extended ? 1.0 : 0.0
            ]) else { throw EditRenderError.unavailable }
            image = result
        }
        try Task.checkCancellation()
        if settings.texture != 0 || settings.clarity != 0 {
            let fine = settings.texture != 0 ? blur(image, radius: 2.5 * scale, extent: extent) : image
            let broad = settings.clarity != 0 ? blur(image, radius: 18 * scale, extent: extent) : image
            guard let result = presenceKernel?.apply(extent: extent, arguments: [
                image, fine, broad, settings.texture / 100, settings.clarity / 100, extended ? 1.0 : 0.0
            ]) else { throw EditRenderError.unavailable }
            image = result
        }
        try Task.checkCancellation()
        return try DevelopColorAdjustments.output(image, settings: settings.developColor, extent: extent)
    }

    private static func prefix(_ image: CIImage, original: CGImage, settings: EditSettings,
                               extent: CGRect, scale: Double) throws -> CIImage {
        let denoised = try denoise(image, settings: settings, extent: extent, scale: scale)
        try Task.checkCancellation()
        return try balance(denoised, original: original, settings: settings, extent: extent)
    }

    private static func balance(_ image: CIImage, original: CGImage, settings: EditSettings, extent: CGRect) throws -> CIImage {
        // New user-selected balancing replaces, rather than stacks with, the
        // legacy curve. Previously saved edits keep their original renderer.
        if settings.naturalBalanceAmount > 0 {
            return try NaturalBalanceRenderer.apply(to: image, original: original,
                amount: settings.naturalBalanceAmount, colorAmount: settings.naturalBalanceColorAmount, extent: extent)
        }
        return settings.autoToneAmount > 0
            ? try AutoToneRenderer.apply(to: image, original: original, amount: settings.autoToneAmount, extent: extent)
            : image
    }

    private static func denoise(_ image: CIImage, settings: EditSettings, extent: CGRect, scale: Double) throws -> CIImage {
        guard settings.luminanceNoiseReduction > 0 || settings.colorNoiseReduction > 0 else { return image }
        let luminance = settings.luminanceNoiseReduction / 100
        let chroma = settings.colorNoiseReduction / 100
        let lumaBlur = luminance > 0 ? blur(image, radius: (1 + 2 * luminance) * scale, extent: extent) : image
        let chromaBlur = chroma > 0 ? blur(image, radius: (2 + 4 * chroma) * scale, extent: extent) : image
        guard let result = denoiseKernel?.apply(extent: extent, arguments: [image, lumaBlur, chromaBlur, luminance, chroma,
            settings.developColor.hdrEnabled ? 1.0 : 0.0]) else {
            throw EditRenderError.unavailable
        }
        return result
    }

    private static func blur(_ image: CIImage, radius: Double, extent: CGRect) -> CIImage {
        image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    // The compact Core Image kernel language runs on Core Image's available
    // renderer, including older Intel Macs. No external Metal compiler, model,
    // network service, or GPU-generation-specific shader library is required.
    private static let denoiseKernel = CIColorKernel(source: """
        kernel vec4 separateNoise(__sample original, __sample lumaBlur, __sample chromaBlur, float lumaAmount, float chromaAmount, float hdr) {
            vec4 o = unpremultiply(original);
            vec3 l = unpremultiply(lumaBlur).rgb;
            vec3 c = unpremultiply(chromaBlur).rgb;
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = dot(o.rgb, weights);
            float yl = dot(l, weights);
            float yc = dot(c, weights);
            // Preserve high-contrast edges while suppressing fine fluctuations.
            float lumaWeight = 0.90 * lumaAmount / (1.0 + 12.0 * abs(y - yl));
            float colorWeight = 0.98 * chromaAmount / (1.0 + 12.0 * abs(y - yc));
            float cleanY = mix(y, yl, lumaWeight);
            vec3 cleanChroma = mix(o.rgb - vec3(y), c - vec3(yc), colorWeight);
            vec3 rgb = vec3(cleanY) + cleanChroma;
            rgb = mix(clamp(rgb, 0.0, 1.0), max(rgb, vec3(0.0)), hdr);
            return premultiply(vec4(rgb, o.a));
        }
        """)

    private static let toneKernel = CIColorKernel(source: """
        kernel vec4 toneAndColor(__sample original, float exposure, float contrast, float highlights, float shadows, float whites, float blacks, float dehaze, float vibrance, float saturation, float hdr) {
            vec4 o = unpremultiply(original);
            vec3 rgb = pow(max(o.rgb * exp2(exposure), vec3(0.0)), vec3(1.0 / 2.2));
            rgb = (rgb - vec3(0.5)) * (1.0 + contrast * 0.65) + vec3(0.5);
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = clamp(dot(rgb, weights), 0.0, 1.0);
            float shift = shadows * 0.22 * (1.0 - smoothstep(0.05, 0.65, y));
            shift += highlights * 0.22 * smoothstep(0.35, 0.95, y);
            // Limit endpoint strength so combining maximum shadow/black or
            // highlight/white changes does not reverse the tonal ordering.
            shift += blacks * 0.11 * (1.0 - smoothstep(0.0, 0.25, y));
            shift += whites * 0.11 * smoothstep(0.75, 1.0, y);
            rgb += vec3(shift);
            // A practical veil/black-point approximation, not scene-depth
            // recovery: positive removes a light veil; negative adds one.
            float removeVeil = max(dehaze, 0.0) * 0.12;
            rgb = (rgb - vec3(removeVeil)) / (1.0 - removeVeil);
            rgb = mix(rgb, vec3(0.85), max(-dehaze, 0.0) * 0.18);
            y = dot(rgb, weights);
            float spread = clamp(max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b), 0.0, 1.0);
            float colorScale = (1.0 + saturation) * (1.0 + vibrance * 0.85 * (1.0 - spread));
            rgb = mix(vec3(y), rgb, colorScale);
            rgb = mix(clamp(rgb, 0.0, 1.0), max(rgb, vec3(0.0)), hdr);
            return premultiply(vec4(pow(rgb, vec3(2.2)), o.a));
        }
        """)

    private static let presenceKernel = CIColorKernel(source: """
        kernel vec4 localPresence(__sample original, __sample fineBlur, __sample broadBlur, float texture, float clarity, float hdr) {
            vec4 o = unpremultiply(original);
            vec3 rgb = pow(max(o.rgb, vec3(0.0)), vec3(1.0 / 2.2));
            vec3 fine = pow(max(unpremultiply(fineBlur).rgb, vec3(0.0)), vec3(1.0 / 2.2));
            vec3 broad = pow(max(unpremultiply(broadBlur).rgb, vec3(0.0)), vec3(1.0 / 2.2));
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = clamp(dot(rgb, weights), 0.0, 1.0);
            float midtones = 4.0 * y * (1.0 - y);
            float detail = texture * 0.90 * (y - dot(fine, weights));
            detail += clarity * 0.75 * midtones * (y - dot(broad, weights));
            rgb += vec3(detail);
            rgb = pow(mix(clamp(rgb, 0.0, 1.0), max(rgb, vec3(0.0)), hdr), vec3(2.2));
            return premultiply(vec4(rgb, o.a));
        }
        """)
}
