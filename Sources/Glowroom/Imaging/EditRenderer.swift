import CoreImage
import Foundation
import GlowroomCore

enum EditRenderError: LocalizedError, Equatable {
    case unavailable
    case oversizedPreview
    case insufficientMaskMemory
    case unsupportedSpatialRadius
    case unrepresentableLevels

    var errorDescription: String? {
        switch self {
        case .unavailable: "Die Bildbearbeitung konnte nicht gerendert werden."
        case .oversizedPreview: "Die Vorschau ist für die Bildbearbeitung zu groß."
        case .insufficientMaskMemory: "Die Vorschau mit Schärfung, Masken oder Retusche überschreitet das verfügbare Speicherbudget. Verkleinere die Vorschau oder reduziere vorübergehend die Korrekturen."
        case .unsupportedSpatialRadius: "Dieses Bild benötigt einen zu großen räumlichen Float-Filter. Deaktiviere Präsenz, Entrauschen und Schärfen oder verwende eine kleinere Bildquelle."
        case .unrepresentableLevels: "Diese Tonwertkorrektur überschreitet den darstellbaren Float-Bereich oder erhält ungültige Bildwerte. Der bisherige Bildstand bleibt erhalten."
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
        private let preciseContext: CIContext
        func context(for version: ToneProcessingVersion) -> CIContext {
            version == .consistentV2 ? preciseContext : context
        }
        func context(for settings: EditSettings) -> CIContext {
            settings.usesFloatWorkingGraph ? preciseContext : context
        }
        private let cachesPrefix: Bool
        private let lock = NSLock()
        private var original: CGImage?
        private var base: CIImage?
        private var denoised: CIImage?
        private var balanced: CIImage?
        private var noise: NoiseKey?
        private var balanceKey: BalanceKey?
        private var levelsRangeKey: LevelsRangeKey?
        private var levelsRange: LevelsRenderer.InputRange?
        private var rangeMeasurements = 0
        private var rangeCacheHits = 0
        fileprivate let localMaskCache = LocalMaskImageCache()

        private struct LevelsRangeKey: Equatable {
            let source: UUID
            let width: Int
            let height: Int
            let sourceLongEdge: Int
            let upstream: EditSettings
            let precise: Bool

            init(bitmap: PreviewBitmap, settings: EditSettings) {
                source = bitmap.rangeSourceIdentity
                width = bitmap.image.width; height = bitmap.image.height
                sourceLongEdge = bitmap.sourceLongEdge
                precise = settings.usesFloatWorkingGraph
                var upstream = settings
                // The node's input cannot depend on its own curve, or anything
                // after it. Keep version, profiles, WB, noise, balance and tone.
                upstream.levels = .neutral
                upstream.texture = 0; upstream.clarity = 0
                upstream.sharpeningAmount = 0; upstream.sharpeningRadius = 1
                upstream.sharpeningDetail = 25; upstream.sharpeningMasking = 0
                upstream.developColor.isMonochrome = false
                upstream.localAdjustments = []; upstream.developGeometry = .neutral
                if upstream.naturalBalanceAmount == 0 { upstream.naturalBalanceColorAmount = 50 }
                self.upstream = upstream
            }
        }

        struct LevelsRangeDiagnostics: Equatable, Sendable {
            let measurements: Int
            let cacheHits: Int
        }
        func levelsRangeDiagnostics() -> LevelsRangeDiagnostics {
            lock.lock(); defer { lock.unlock() }
            return LevelsRangeDiagnostics(measurements: rangeMeasurements, cacheHits: rangeCacheHits)
        }

        fileprivate func levelsInputRange(_ image: CIImage, bitmap: PreviewBitmap,
                                          settings: EditSettings, extent: CGRect) throws -> LevelsRenderer.InputRange {
            // A stable decoded-source revision survives deterministic adaptive
            // resizes. This bounded one-entry proof retains only UUID/settings
            // and six Doubles, never a CGImage, decoded source or artifact owner.
            let key = LevelsRangeKey(bitmap: bitmap, settings: settings)
            lock.lock(); defer { lock.unlock() }
            if cachesPrefix, levelsRangeKey == key, let levelsRange {
                rangeCacheHits += 1
                return levelsRange
            }
            rangeMeasurements += 1
            // Serialize the tiny cached proof with its source identity. Each
            // session already belongs to one bounded render lane, so no extra
            // queue or concurrent full-image reduction is introduced here.
            let range = try LevelsRenderer.inputRange(of: image, extent: extent, context: context(for: settings))
            if cachesPrefix { levelsRangeKey = key; levelsRange = range }
            return range
        }

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
            let version: ToneProcessingVersion
        }

        init(cacheIntermediates: Bool = false, lowPriority: Bool, softwareRenderer: Bool = false) {
            cachesPrefix = cacheIntermediates
            var options: [CIContextOption: Any] = [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .workingFormat: CIFormat.RGBAh,
                .cacheIntermediates: cacheIntermediates,
                .priorityRequestLow: lowPriority,
                .name: lowPriority ? "Glowroom background" : "Glowroom interactive"
            ]
            // Diagnostic preference only: some platforms ignore this option.
            // The automatic production path retains Core Image's own fallback.
            if softwareRenderer { options[.useSoftwareRenderer] = true }
            context = CIContext(options: options)
            options[.workingFormat] = CIFormat.RGBAf
            options[.name] = lowPriority ? "Glowroom precise background" : "Glowroom precise interactive"
            preciseContext = CIContext(options: options)
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
                    preciseContext.clearCaches()
                    lock.unlock()
                }
                return try EditRenderer.prefix(CIImage(cgImage: bitmap.image), original: bitmap.image,
                    settings: settings, extent: extent, scale: scale,
                    analysisIdentity: SourceAnalysisIdentity(bitmap: bitmap))
            }
            // Prefix construction is serialized. The final raster render runs
            // after releasing the lock; the separately cached range proof below
            // serializes its tiny readback with this same source identity.
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
                preciseContext.clearCaches()
            }
            let noiseKey = NoiseKey(luminance: settings.luminanceNoiseReduction, color: settings.colorNoiseReduction,
                                    hdr: settings.developColor.hdrEnabled, version: settings.toneProcessingVersion)
            if noise != noiseKey {
                denoised = try EditRenderer.denoise(base!, settings: settings, extent: extent, scale: scale)
                noise = noiseKey
                balanced = nil
                balanceKey = nil
            }
            let key = BalanceKey(legacy: settings.autoToneAmount, amount: settings.naturalBalanceAmount,
                                 color: settings.naturalBalanceColorAmount)
            if balanceKey != key {
                balanced = try EditRenderer.balance(denoised!, original: bitmap.image, settings: settings, extent: extent,
                    analysisIdentity: SourceAnalysisIdentity(bitmap: bitmap))
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

    private struct RasterOutput {
        let colorSpace: CGColorSpace
        let format: CIFormat
    }

    /// Analysis must measure clipping in the same developed destination as
    /// preview/export, before integer quantization constrains its RGB values.
    /// In particular, a gray input develops into sRGB rather than gray output.
    static func developedOutputColorSpace(for original: CGImage, hdrEnabled: Bool = false) throws -> CGColorSpace {
        try rasterOutput(for: original, developing: true, hdrEnabled: hdrEnabled).colorSpace
    }

    /// A monochrome source profile describes the input, not the developed
    /// result: white balance and other color edits can separate RGB channels.
    /// Core Image converts from the tagged source into the chosen RGB profile.
    /// A resize alone keeps the source format; the neutral render stays a no-op.
    private static func rasterOutput(for original: CGImage, developing: Bool,
                                     hdrEnabled: Bool = false, requiresFloat: Bool = false) throws -> RasterOutput {
        let sourceSpace = original.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let colorSpace = hdrEnabled ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            : developing && sourceSpace.model == .monochrome ? CGColorSpace(name: CGColorSpace.sRGB)! : sourceSpace
        let highPrecision = original.bitsPerComponent > 8
        let floatingPoint = hdrEnabled || (!developing && original.bitmapInfo.contains(.floatComponents))
        // A certified Float graph can exceed half-float's 65,504 ceiling. HDR
        // output must retain the graph's precision instead of quantizing it to
        // infinity. Legacy V1 without levels keeps its historical output path.
        let floatingFormat: CIFormat = requiresFloat ? .RGBAf : .RGBAh
        let format: CIFormat
        switch colorSpace.model {
        case .rgb: format = floatingPoint ? floatingFormat : highPrecision ? .RGBA16 : .RGBA8
        case .monochrome: format = floatingPoint ? floatingFormat : highPrecision ? .LA16 : .LA8
        default: throw EditRenderError.unavailable
        }
        return RasterOutput(colorSpace: colorSpace, format: format)
    }

    /// Add the RGB readback expansion to the existing global preview budget.
    /// Row padding is already covered by the retained source's actual byte cost.
    static func additionalColorOutputBytesPerPixel(for original: CGImage, settings: EditSettings) -> UInt64 {
        guard !settings.isNeutral else { return 0 }
        // Float HDR output expands the former half-float plane by eight bytes.
        if settings.developColor.hdrEnabled { return settings.usesFloatWorkingGraph ? 8 : 0 }
        guard original.colorSpace?.model == .monochrome else { return 0 }
        let outputBytes = (original.bitsPerComponent > 8 ? 2 : 1) * 4
        return UInt64(max(0, outputBytes - (original.bitsPerPixel + 7) / 8))
    }

    /// Runs only inside AdjustedPreviewPipeline's existing worker. Reuses the
    /// lane's CIContext and preserves the developed base's profile and alpha.
    static func resized(_ bitmap: PreviewBitmap, width: Int, height: Int,
                        priority: PreviewPriority,
                        toneProcessingVersion: ToneProcessingVersion = .legacyV1) throws -> PreviewBitmap {
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
            let output = try rasterOutput(for: original, developing: false)
            let session = priority == .selected ? interactive : background
            let context = session.context(for: toneProcessingVersion)
            let format: CIFormat = toneProcessingVersion == .consistentV2 ? .RGBAf : output.format
            let colorSpace = toneProcessingVersion == .consistentV2 && output.colorSpace.model == .monochrome
                ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! : output.colorSpace
            let renderSpan = PipelineTrace.begin(.render)
            defer { renderSpan.end() }
            guard let result = context.createCGImage(image.cropped(to: extent), from: extent,
                                                             format: format, colorSpace: colorSpace, deferred: false)
            else { throw EditRenderError.unavailable }
            try Task.checkCancellation()
            return PreviewBitmap(image: result, sourceLongEdge: bitmap.sourceLongEdge, rangeProvenance: bitmap.rangeProvenance,
                                 rangeSourceIdentity: bitmap.rangeIdentityForResize(width: width, height: height,
                                    format: format, precise: toneProcessingVersion == .consistentV2))
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
        let globalBytes = UInt64(original.width) * UInt64(original.height)
            * (DevelopSharpening.additionalBytesPerPixel(settings: settings)
                + additionalColorOutputBytesPerPixel(for: original, settings: settings)
                + LocalAdjustmentRenderer.additionalToneWorkingBytesPerPixel(version: settings.workingMemoryVersion)
                + settings.additionalLevelsBytesPerPixel)
        guard let localBytes = LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: settings.localAdjustments,
            width: original.width, height: original.height,
            additionalRenderCount: DevelopGeometryRenderer.replacementCount(in: settings.developGeometry),
            toneProcessingVersion: settings.workingMemoryVersion),
              let geometryBytes = DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: settings.developGeometry,
                width: original.width, height: original.height,
                replacementColorBytesPerPixel: replacementColorBytesPerPixel(settings: settings)),
              globalBytes <= LocalAdjustmentRenderer.previewWorkingMemoryBudget,
              geometryBytes <= LocalAdjustmentRenderer.previewWorkingMemoryBudget - globalBytes,
              localBytes <= LocalAdjustmentRenderer.previewWorkingMemoryBudget - globalBytes - geometryBytes else {
            throw EditRenderError.insufficientMaskMemory
        }

        return try autoreleasepool {
            let graphSpan = PipelineTrace.begin(.filterGraph)
            var graphEnded = false
            defer { if !graphEnded { graphSpan.end() } }
            let extent = CGRect(x: 0, y: 0, width: original.width, height: original.height)
            // Keep spatial effects comparable at progressive preview sizes.
            let scale = max(0.25, Double(max(original.width, original.height)) / 1_600)
            let prefix = try session.prefix(bitmap, settings: settings, extent: extent, scale: scale)
            let context = session.context(for: settings)
            let global = try manualAdjustments(prefix, settings: settings, extent: extent, scale: scale,
                sourcePixelScale: bitmap.sourcePixelScale, context: context,
                levelsInputRange: { image in
                    try session.levelsInputRange(image, bitmap: bitmap, settings: settings, extent: extent)
                }, validatesLevelsOutput: false)
            // Artifact mask allocations belong to this render's admitted phase;
            // retaining their CPU rasters in a global cache would outlive it.
            let maskCache = bitmap.resourceOwner == nil ? session.localMaskCache : nil
            let image = try LocalAdjustmentRenderer.apply(to: global, adjustments: settings.localAdjustments,
                                                          extent: extent, scale: scale, cache: maskCache,
                                                          preservesExtendedRange: settings.developColor.hdrEnabled,
            toneProcessingVersion: settings.toneProcessingVersion)
            let replacements = try replacementImages(original, settings: settings, extent: extent,
                scale: scale, maskCache: maskCache, sourcePixelScale: bitmap.sourcePixelScale, context: context,
                analysisIdentity: SourceAnalysisIdentity(bitmap: bitmap))
            let developed = try DevelopGeometryRenderer.apply(to: image,
                geometry: settings.developGeometry, extent: extent, replacementImages: replacements)
            if needsLevelsOutputValidation(settings, includingDocumentStages: true) {
                try LevelsRenderer.validateFiniteOutput(developed, context: context)
            }

            let output = try rasterOutput(for: original, developing: true, hdrEnabled: settings.developColor.hdrEnabled,
                requiresFloat: settings.usesFloatWorkingGraph)
            let outputExtent = developed.extent
            graphSpan.end(); graphEnded = true
            let renderSpan = PipelineTrace.begin(.render)
            defer { renderSpan.end() }
            guard let rendered = context.createCGImage(developed, from: outputExtent,
                format: output.format, colorSpace: output.colorSpace, deferred: false) else {
                throw EditRenderError.unavailable
            }
            try Task.checkCancellation()
            return PreviewBitmap(image: rendered, sourceLongEdge: bitmap.sourceLongEdge, rangeProvenance: bitmap.rangeProvenance)
        }
    }

    /// Builds the full-size graph without converting to a preview or imposing
    /// preview dimensions. The exporter validates its own memory/format limits.
    static func filterGraph(_ original: CGImage, settings: EditSettings, context: CIContext? = nil,
                            sourcePixelScale: Double = 1) throws -> CIImage {
        try Task.checkCancellation()
        let settings = settings.normalized
        let image = CIImage(cgImage: original)
        guard !settings.isNeutral else { return image }
        let extent = image.extent
        let context = context ?? background.context(for: settings)
        let scale = max(0.25, Double(max(original.width, original.height)) / 1_600)
        let prefix = try prefix(image, original: original, settings: settings, extent: extent, scale: scale)
        let global = try manualAdjustments(prefix, settings: settings, extent: extent, scale: scale,
            sourcePixelScale: sourcePixelScale, context: context, validatesLevelsOutput: false)
        let local = try LocalAdjustmentRenderer.apply(to: global, adjustments: settings.localAdjustments,
            extent: extent, scale: scale, preservesExtendedRange: settings.developColor.hdrEnabled,
            toneProcessingVersion: settings.toneProcessingVersion)
        let replacements = try replacementImages(original, settings: settings, extent: extent, scale: scale,
            maskCache: nil, sourcePixelScale: sourcePixelScale, context: context)
        let developed = try DevelopGeometryRenderer.apply(to: local, geometry: settings.developGeometry, extent: extent,
                                                          replacementImages: replacements)
        if needsLevelsOutputValidation(settings, includingDocumentStages: true) {
            try LevelsRenderer.validateFiniteOutput(developed, context: context)
        }
        return developed
    }

    /// Shared precision analysis graph. Reuses the decoded source and cached
    /// prefix, retaining every active global setting before output quantization.
    /// Source masks, retouch and geometry are deliberately excluded.
    static func globalGraph(_ bitmap: PreviewBitmap, settings: EditSettings, session: Session) throws -> CIImage {
        try Task.checkCancellation()
        let settings = settings.normalized
        let extent = CGRect(x: 0, y: 0, width: bitmap.image.width, height: bitmap.image.height)
        let scale = max(0.25, Double(max(bitmap.image.width, bitmap.image.height)) / 1_600)
        let base = try session.prefix(bitmap, settings: settings, extent: extent, scale: scale)
        let context = session.context(for: settings)
        let image = try manualAdjustments(base, settings: settings, extent: extent, scale: scale,
            sourcePixelScale: bitmap.sourcePixelScale, context: context,
            levelsInputRange: { image in
                try session.levelsInputRange(image, bitmap: bitmap, settings: settings, extent: extent)
            }, validatesLevelsOutput: false)
        if needsLevelsOutputValidation(settings, includingDocumentStages: false) {
            try LevelsRenderer.validateFiniteOutput(image, context: context)
        }
        return image
    }

    /// Exact global input of the whole levels node: denoise/balance, input
    /// profile/white balance, then the existing versioned tone controls. No
    /// levels, presence, output monochrome, sharpening, local masks, retouch or
    /// geometry. The graph is premultiplied extended-linear sRGB, with original
    /// alpha. A measuring consumer must unpremultiply each visible pixel and
    /// apply signed-sRGB encoding before averaging encoded straight samples.
    static func globalLevelsInputGraph(_ bitmap: PreviewBitmap, settings: EditSettings,
                                       session: Session) throws -> CIImage {
        try Task.checkCancellation()
        let settings = settings.normalized
        let extent = CGRect(x: 0, y: 0, width: bitmap.image.width, height: bitmap.image.height)
        let scale = max(0.25, Double(max(bitmap.image.width, bitmap.image.height)) / 1_600)
        let base = try session.prefix(bitmap, settings: settings, extent: extent, scale: scale)
        return try beforeLevels(base, settings: settings, extent: extent,
                                preservesExtendedRange: settings.developColor.hdrEnabled)
    }

    /// A fully covered frozen repair has one unambiguous Levels input. Match
    /// replacementImages' original-canvas balance analysis and prefix exactly;
    /// the replacement pixels must never become their own balance reference.
    static func globalLevelsReplacementInputGraph(_ bitmap: PreviewBitmap, settings: EditSettings,
                                                  session: Session,
                                                  replacement: DevelopRetouchReplacement) throws -> CIImage {
        try Task.checkCancellation()
        let settings = settings.normalized
        let extent = CGRect(x: 0, y: 0, width: bitmap.image.width, height: bitmap.image.height)
        let scale = max(0.25, Double(max(bitmap.image.width, bitmap.image.height)) / 1_600)
        let candidate = try DevelopGeometryRenderer.replacementInput(replacement,
            original: CIImage(cgImage: bitmap.image), extent: extent)
        let base = try prefix(candidate, original: bitmap.image, settings: settings, extent: extent, scale: scale,
                              analysisIdentity: SourceAnalysisIdentity(bitmap: bitmap))
        return try beforeLevels(base, settings: settings, extent: extent,
                                preservesExtendedRange: settings.developColor.hdrEnabled)
    }

    static func manualAdjustments(_ input: CIImage, settings: EditSettings,
                                  extent: CGRect, scale: Double, preservesExtendedRange: Bool = false,
                                  sourcePixelScale: Double = 1, levelsScope: LevelsScope = .global,
                                  context: CIContext? = nil,
                                  levelsInputRange: ((CIImage) throws -> LevelsRenderer.InputRange)? = nil,
                                  validatesLevelsOutput: Bool = true) throws -> CIImage {
        try Task.checkCancellation()
        let extended = preservesExtendedRange || settings.developColor.hdrEnabled
        var image = try beforeLevels(input, settings: settings, extent: extent, preservesExtendedRange: extended)
        if levelsScope == .global, !settings.levels.isNeutral {
            let context = context ?? background.context(for: settings)
            let range = try levelsInputRange?(image)
            image = try LevelsRenderer.apply(to: image, settings: settings.levels, extent: extent,
                context: context, inputRange: range)
        }
        try Task.checkCancellation()
        if settings.texture != 0 || settings.clarity != 0 {
            let fine = settings.texture != 0 ? try blur(image, radius: 2.5 * scale, extent: extent, version: settings.toneProcessingVersion) : image
            let broad = settings.clarity != 0 ? try blur(image, radius: 18 * scale, extent: extent, version: settings.toneProcessingVersion) : image
            if settings.toneProcessingVersion == .consistentV2 {
                image = try TonePipelineV2.presence(image, fine: fine, broad: broad, settings: settings, extent: extent)
            } else {
                guard let result = presenceKernel?.apply(extent: extent, arguments: [
                    image, fine, broad, settings.texture / 100, settings.clarity / 100, extended ? 1.0 : 0.0
                ]) else { throw EditRenderError.unavailable }
                image = result
            }
        }
        try Task.checkCancellation()
        image = try DevelopColorAdjustments.output(image, settings: settings.developColor, extent: extent)
        image = try DevelopSharpening.apply(to: image, settings: settings, extent: extent,
                                           sourcePixelScale: sourcePixelScale)
        if validatesLevelsOutput, levelsScope == .global,
           needsLevelsOutputValidation(settings, includingDocumentStages: false) {
            try LevelsRenderer.validateFiniteOutput(image, context: context ?? background.context(for: settings))
        }
        return image
    }

    private static func needsLevelsOutputValidation(_ settings: EditSettings, includingDocumentStages: Bool) -> Bool {
        guard !settings.levels.isNeutral else { return false }
        if settings.texture != 0 || settings.clarity != 0 || settings.developColor.isMonochrome ||
            settings.sharpeningAmount > 0 { return true }
        return includingDocumentStages && (settings.localAdjustments.contains { $0.isEffective } ||
            !settings.developGeometry.isNeutral)
    }

    private static func beforeLevels(_ input: CIImage, settings: EditSettings, extent: CGRect,
                                     preservesExtendedRange: Bool) throws -> CIImage {
        let extended = preservesExtendedRange || settings.developColor.hdrEnabled
        var image = try DevelopColorAdjustments.input(input, settings: settings.developColor, extent: extent)
        if settings.exposure != 0 || settings.contrast != 0 || settings.highlights != 0 || settings.shadows != 0 ||
            settings.whites != 0 || settings.blacks != 0 || settings.dehaze != 0 || settings.vibrance != 0 || settings.saturation != 0 {
            if settings.toneProcessingVersion == .consistentV2 {
                image = try TonePipelineV2.tone(image, settings: settings, extent: extent)
            } else {
                guard let result = toneKernel?.apply(extent: extent, arguments: [
                    image, settings.exposure, settings.contrast / 100,
                    settings.highlights / 100, settings.shadows / 100,
                    settings.whites / 100, settings.blacks / 100,
                    settings.dehaze / 100, settings.vibrance / 100, settings.saturation / 100, extended ? 1.0 : 0.0
                ]) else { throw EditRenderError.unavailable }
                image = result
            }
        }
        try Task.checkCancellation()
        return image
    }

    private static func prefix(_ image: CIImage, original: CGImage, settings: EditSettings,
                               extent: CGRect, scale: Double, analysisIdentity: SourceAnalysisIdentity? = nil) throws -> CIImage {
        let denoised = try denoise(image, settings: settings, extent: extent, scale: scale)
        try Task.checkCancellation()
        return try balance(denoised, original: original, settings: settings, extent: extent,
                           analysisIdentity: analysisIdentity)
    }

    private static func replacementImages(_ original: CGImage, settings: EditSettings, extent: CGRect,
                                          scale: Double, maskCache: LocalMaskImageCache?,
                                          sourcePixelScale: Double = 1, context: CIContext,
                                          analysisIdentity: SourceAnalysisIdentity? = nil) throws -> [UUID: CIImage] {
        var result: [UUID: CIImage] = [:]
        let input = CIImage(cgImage: original)
        // Each frozen ROI gets the identical source color pipeline. The actual
        // retouch pass keeps stored order and applies its mask/opacity once;
        // neither future repairs nor changed color filters alter old donors.
        for stroke in settings.developGeometry.retouchStrokes where stroke.opacity > 0 {
            guard let replacement = stroke.replacement else { continue }
            try Task.checkCancellation()
            let candidate = try DevelopGeometryRenderer.replacementInput(replacement, original: input, extent: extent)
            // Existing balance semantics analyze the original canvas, not the
            // replacement ROI. Share that original's analysis identity only.
            let base = try prefix(candidate, original: original, settings: settings, extent: extent, scale: scale,
                                  analysisIdentity: analysisIdentity)
            let global = try manualAdjustments(base, settings: settings, extent: extent, scale: scale,
                sourcePixelScale: sourcePixelScale, context: context, validatesLevelsOutput: false)
            result[stroke.id] = try LocalAdjustmentRenderer.apply(to: global, adjustments: settings.localAdjustments,
                extent: extent, scale: scale, cache: maskCache, preservesExtendedRange: settings.developColor.hdrEnabled,
            toneProcessingVersion: settings.toneProcessingVersion)
        }
        return result
    }

    /// Extra global candidate planes per frozen ROI, shared by preview and
    /// export admission. Local-adjustment planes are counted separately for
    /// every candidate. These are conservative working buffers, not measured
    /// GPU residency or a performance claim.
    static func replacementColorBytesPerPixel(settings: EditSettings) -> UInt64 {
        guard DevelopGeometryRenderer.replacementCount(in: settings.developGeometry) > 0 else { return 0 }
        var bytes: UInt64 = 16 + settings.additionalLevelsBytesPerPixel // Raw ROI/source and Levels proof planes.
        if settings.luminanceNoiseReduction > 0 || settings.colorNoiseReduction > 0 {
            bytes += 16
            if settings.luminanceNoiseReduction > 0 { bytes += 16 }
            if settings.colorNoiseReduction > 0 { bytes += 16 }
        }
        if settings.naturalBalanceAmount > 0 || settings.autoToneAmount > 0 { bytes += 16 }
        let color = settings.developColor
        if color.temperature != 6_500 || color.tint != 0 || color.profile != .neutral { bytes += 16 }
        if settings.exposure != 0 || settings.contrast != 0 || settings.highlights != 0 || settings.shadows != 0 ||
            settings.whites != 0 || settings.blacks != 0 || settings.dehaze != 0 || settings.vibrance != 0 || settings.saturation != 0 { bytes += 16 }
        if settings.texture != 0 || settings.clarity != 0 {
            bytes += 16
            if settings.texture != 0 { bytes += 16 }
            if settings.clarity != 0 { bytes += 16 }
        }
        if color.isMonochrome { bytes += 16 }
        bytes += DevelopSharpening.additionalBytesPerPixel(settings: settings)
        return bytes
    }

    private static func balance(_ image: CIImage, original: CGImage, settings: EditSettings, extent: CGRect,
                                analysisIdentity: SourceAnalysisIdentity? = nil) throws -> CIImage {
        // New user-selected balancing replaces, rather than stacks with, the
        // legacy curve. Previously saved edits keep their original renderer.
        if settings.naturalBalanceAmount > 0 {
            return try NaturalBalanceRenderer.apply(to: image, original: original,
                amount: settings.naturalBalanceAmount, colorAmount: settings.naturalBalanceColorAmount, extent: extent,
                analysisIdentity: analysisIdentity)
        }
        return settings.autoToneAmount > 0
            ? try AutoToneRenderer.apply(to: image, original: original, amount: settings.autoToneAmount, extent: extent,
                                         analysisIdentity: analysisIdentity)
            : image
    }

    private static func denoise(_ image: CIImage, settings: EditSettings, extent: CGRect, scale: Double) throws -> CIImage {
        guard settings.luminanceNoiseReduction > 0 || settings.colorNoiseReduction > 0 else { return image }
        let luminance = settings.luminanceNoiseReduction / 100
        let chroma = settings.colorNoiseReduction / 100
        let lumaBlur = luminance > 0 ? try blur(image, radius: (1 + 2 * luminance) * scale, extent: extent, version: settings.toneProcessingVersion) : image
        let chromaBlur = chroma > 0 ? try blur(image, radius: (2 + 4 * chroma) * scale, extent: extent, version: settings.toneProcessingVersion) : image
        if settings.toneProcessingVersion == .consistentV2 {
            return try TonePipelineV2.denoise(image, luma: lumaBlur, chroma: chromaBlur,
                luminance: luminance, color: chroma, extent: extent)
        }
        guard let result = denoiseKernel?.apply(extent: extent, arguments: [image, lumaBlur, chromaBlur, luminance, chroma,
            settings.developColor.hdrEnabled ? 1.0 : 0.0]) else {
            throw EditRenderError.unavailable
        }
        return result
    }

    private static func blur(_ image: CIImage, radius: Double, extent: CGRect,
                             version: ToneProcessingVersion) throws -> CIImage {
        if version == .consistentV2 {
            return try PreciseGaussianBlur.apply(image: image, radius: radius, extent: extent)
        }
        return image.clampedToExtent()
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
            vec3 rgb = pow(max(o.rgb, vec3(0.0)), vec3(1.0 / 2.2));
            // Keep black/white fixed: an affine compression toward midgray
            // otherwise adds a gray floor after strong negative exposure.
            // For c in [-1, 1], the derivative 1+c*(-6u*u+6u-1) is >= 0.
            // Clamp only the curve's domain so extended HDR values survive.
            vec3 u = clamp(rgb, 0.0, 1.0);
            rgb += contrast * u * (vec3(1.0) - u) * (2.0 * u - vec3(1.0));
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = clamp(dot(rgb, weights), 0.0, 1.0);
            float shift = shadows * 0.22 * (1.0 - smoothstep(0.05, 0.65, y));
            shift += highlights * 0.22 * smoothstep(0.35, 0.95, y);
            // Limit endpoint strength so combining maximum shadow/black or
            // highlight/white changes does not reverse the tonal ordering.
            shift += blacks * 0.11 * (1.0 - smoothstep(0.0, 0.25, y));
            shift += whites * 0.11 * smoothstep(0.75, 1.0, y);
            rgb += vec3(shift);
            // Select and adjust tone ranges before exposure: at -5 EV even
            // source white would otherwise fall below the highlights gate.
            // Scale the entire corrected signal to retain tonal ordering;
            // frozen weights with an unscaled post-exposure shift can invert it.
            // In this gamma domain the gain still equals 2^EV in linear light.
            // Keep HDR headroom until the final output clamp below.
            rgb *= exp2(exposure / 2.2);
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
