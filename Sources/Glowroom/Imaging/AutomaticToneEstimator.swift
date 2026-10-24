import CoreImage
import Foundation
import GlowroomCore

enum AutomaticToneControl: String, CaseIterable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks

    var keyPath: WritableKeyPath<EditSettings, Double> {
        switch self {
        case .exposure: \.exposure
        case .contrast: \.contrast
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .whites: \.whites
        case .blacks: \.blacks
        }
    }

    var range: ClosedRange<Double> { self == .exposure ? -5...5 : -100...100 }
    var step: Double { self == .exposure ? 0.05 : 1 }

    fileprivate var target: Double {
        switch self {
        case .exposure: 0.46
        case .contrast: 0.65
        case .highlights: 0.80
        case .shadows: 0.20
        case .whites: 0.99
        case .blacks: 0.01
        }
    }

    fileprivate func measurement(in histogram: AutomaticToneHistogram) -> Double {
        switch self {
        case .exposure: histogram.percentile(0.5)
        case .contrast: histogram.percentile(0.9) - histogram.percentile(0.1)
        case .highlights: histogram.percentile(0.8)
        case .shadows: histogram.percentile(0.2)
        case .whites: histogram.percentile(0.995)
        case .blacks: histogram.percentile(0.005)
        }
    }

    fileprivate func measurement(in histogram: FloatToneHistogram) -> Double {
        switch self {
        case .exposure: histogram.percentile(0.5)
        case .contrast: histogram.percentile(0.9) - histogram.percentile(0.1)
        case .highlights: histogram.percentile(0.8)
        case .shadows: histogram.percentile(0.2)
        case .whites: histogram.percentile(0.995)
        case .blacks: histogram.percentile(0.005)
        }
    }
}

/// One bounded analysis at a time off MainActor. Core Image chooses CPU/GPU
/// execution and reuses the unchanged color/balance prefix between candidates.
actor AutomaticToneEstimator {
    static let shared = AutomaticToneEstimator()
    private lazy var session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
    private var cachedSource: CGImage?
    private var cachedDomain: FloatAnalysisDomain?
    private var cachedSourceHistogram: FloatToneHistogram?
    private var cachedSourceMaximum: Double?

    /// Reuses this actor's analysis lane and Float context. Only a 5×5 region
    /// reaches the CPU; admission conservatively covers the native input graph.
    func sampleLevels(bitmap: PreviewBitmap, settings: EditSettings,
                      normalizedTopLeft: CGPoint) async throws -> LevelsSampleReport {
        try Task.checkCancellation()
        var phase: ArtifactResourceLease?
        if let resources = bitmap.resourceOwner {
            let bytes = try Self.levelsAnalysisAdditionalBytes(bitmap: bitmap, settings: settings, validating: false)
            phase = try await resources.acquire(kind: .codec, bytes: bytes, priority: .interactive,
                retaining: bitmap.memoryOwnership.map { [$0] } ?? [])
        }
        defer { withExtendedLifetime((phase, bitmap)) {} }
        // Admission may suspend. No further await occurs during graph work;
        // cancellation keeps the lease/source alive until native work returns.
        try Task.checkCancellation()
        return try LevelsRetouchSampling.sample(bitmap: bitmap, settings: settings,
            normalizedTopLeft: normalizedTopLeft, session: session, context: session.context(for: .consistentV2))
    }

    func validateLevels(bitmap: PreviewBitmap, settings: EditSettings,
                        neutralGraySample: LevelsPickerSample? = nil) async throws {
        try Task.checkCancellation()
        var phase: ArtifactResourceLease?
        if let resources = bitmap.resourceOwner {
            let bytes = try Self.levelsAnalysisAdditionalBytes(bitmap: bitmap, settings: settings, validating: true)
            phase = try await resources.acquire(kind: .codec, bytes: bytes, priority: .interactive,
                retaining: bitmap.memoryOwnership.map { [$0] } ?? [])
        }
        defer { withExtendedLifetime((phase, bitmap)) {} }
        try Task.checkCancellation()
        if let neutralGraySample {
            try LevelsRenderer.validateNeutralGray(sample: neutralGraySample, settings: settings.levels,
                                                    context: session.context(for: settings))
        }
        // filterGraph invokes the full-input interval certificate and finite
        // suffix proof, including masks/geometry, without rasterizing a CGImage.
        _ = try EditRenderer.filterGraph(bitmap.image, settings: settings,
                                        context: session.context(for: settings), sourcePixelScale: bitmap.sourcePixelScale)
        try Task.checkCancellation()
    }

    static func levelsAnalysisAdditionalBytes(bitmap: PreviewBitmap, settings: EditSettings, validating: Bool) throws -> Int64 {
        let base = try Self.estimatedAdditionalBytes(sourceBytes: Int64(bitmap.byteCost),
            width: bitmap.image.width, height: bitmap.image.height, version: .consistentV2,
            ownsSource: bitmap.memoryOwnership != nil, levelsActive: validating && !settings.levels.isNeutral)
        // Retouch sampling can use the same frozen replacement prefix; final
        // validation additionally includes local compositing and geometry.
        guard let local = LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: validating ? settings.localAdjustments : [],
            width: bitmap.image.width, height: bitmap.image.height,
            additionalRenderCount: DevelopGeometryRenderer.replacementCount(in: settings.developGeometry),
            toneProcessingVersion: settings.workingMemoryVersion),
            let geometry = DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: settings.developGeometry,
                width: bitmap.image.width, height: bitmap.image.height,
                replacementColorBytesPerPixel: EditRenderer.replacementColorBytesPerPixel(settings: settings)) else {
            throw ArtifactResourceError.capacityExceeded
        }
        let extra = local.addingReportingOverflow(geometry)
        guard !extra.overflow, extra.partialValue <= UInt64(Int64.max) else { throw ArtifactResourceError.capacityExceeded }
        let pixels = UInt64(bitmap.image.width).multipliedReportingOverflow(by: UInt64(bitmap.image.height))
        let sharpening = pixels.partialValue.multipliedReportingOverflow(
            by: validating ? DevelopSharpening.additionalBytesPerPixel(settings: settings) : 0)
        let native = extra.partialValue.addingReportingOverflow(sharpening.partialValue)
        guard !pixels.overflow, !sharpening.overflow, !native.overflow,
              native.partialValue <= UInt64(Int64.max) else { throw ArtifactResourceError.capacityExceeded }
        let total = base.addingReportingOverflow(Int64(native.partialValue))
        guard !total.overflow else { throw ArtifactResourceError.capacityExceeded }
        return total.partialValue
    }

    /// V1 retains its historical estimator. V2 distinguishes a valid absolute
    /// zero from unavailable evidence so the latter never resets a saved value.
    func estimate(for control: AutomaticToneControl, bitmap: PreviewBitmap,
                  settings: EditSettings) async throws -> AutomaticToneEstimate {
        try Task.checkCancellation()
        if settings.toneProcessingVersion == .consistentV2 {
            guard !settings.developColor.hdrEnabled else { return .noProposal(.hdrOutput) }
            guard bitmap.rangeProvenance != .unknown else { return .noProposal(.unknownSourceRange) }
            guard FloatAnalysisDomain(bitmap: bitmap, version: .consistentV2) != nil else { return .noProposal(.unsupportedDomain) }
        }
        var phase: ArtifactResourceLease?
        if let resources = bitmap.resourceOwner {
            let planned = try Self.estimatedAdditionalBytes(sourceBytes: Int64(bitmap.byteCost),
                width: bitmap.image.width, height: bitmap.image.height,
                version: settings.toneProcessingVersion, ownsSource: bitmap.memoryOwnership != nil,
                levelsActive: !settings.levels.isNeutral)
            phase = try await resources.acquire(kind: .codec, bytes: planned, priority: .interactive,
                                                retaining: bitmap.memoryOwnership.map { [$0] } ?? [])
        }
        // Admission can suspend and let another actor request enter. After it
        // resumes, no await occurs until all native work and reductions finish;
        // the lease and decoded source survive cancellation until that return.
        defer { withExtendedLifetime((phase, bitmap)) {} }
        try Task.checkCancellation()
        return try estimateAdmitted(for: control, bitmap: bitmap, settings: settings)
    }

    /// Admission follows the actual versioned allocation graph. V1 first makes
    /// a <=256-pixel raster, then renders all candidates at that bounded size;
    /// V2 retains the full source graph until its Float readback is downsampled.
    /// This is a conservative allocation plan, not a process/GPU memory limit.
    static func estimatedAdditionalBytes(sourceBytes: Int64, width: Int, height: Int,
                                         version: ToneProcessingVersion, ownsSource: Bool, levelsActive: Bool = false) throws -> Int64 {
        guard sourceBytes >= 0, width > 0, height > 0 else { throw ArtifactResourceError.invalidRequest }
        let scratch: Int64
        let buffers: Int64
        switch version {
        case .legacyV1:
            // Match the existing preview lane's source import/resize allowance.
            // The retained input is separately charged by its ownership token.
            let sourceImport = sourceBytes.multipliedReportingOverflow(by: 4)
            let scale = min(1, 256 / Double(max(width, height)))
            let proxyWidth = max(1, min(256, Int((Double(width) * scale).rounded())))
            let proxyHeight = max(1, min(256, Int((Double(height) * scale).rounded())))
            guard !sourceImport.overflow else { throw ArtifactResourceError.capacityExceeded }
            scratch = sourceImport.partialValue
            // Proxy, candidate/output, RGBA8 histogram buffers and bounded
            // native half-float scratch; no full-source Float analysis exists.
            buffers = Int64(proxyWidth * proxyHeight) * (levelsActive ? 144 : 64) + 3 * 1_024 * 8
        case .consistentV2:
            let pixels = Int64(width).multipliedReportingOverflow(by: Int64(height))
            let native = pixels.partialValue.multipliedReportingOverflow(by: levelsActive ? 128 : 96)
            guard !pixels.overflow, !native.overflow else { throw ArtifactResourceError.capacityExceeded }
            scratch = native.partialValue
            buffers = Int64(FloatAnalysis.maximumWorkingBytes)
        }
        let working = scratch.addingReportingOverflow(buffers)
        let total = working.partialValue.addingReportingOverflow(ownsSource ? 0 : sourceBytes)
        guard !working.overflow, !total.overflow else { throw ArtifactResourceError.capacityExceeded }
        return total.partialValue
    }

    private func estimateAdmitted(for control: AutomaticToneControl, bitmap: PreviewBitmap,
                                  settings: EditSettings) throws -> AutomaticToneEstimate {
        try Task.checkCancellation()
        guard settings.toneProcessingVersion == .consistentV2 else {
            return .value(try value(for: control, bitmap: bitmap, settings: settings))
        }
        guard !settings.developColor.hdrEnabled else { return .noProposal(.hdrOutput) }
        guard bitmap.rangeProvenance != .unknown else { return .noProposal(.unknownSourceRange) }
        guard let domain = FloatAnalysisDomain(bitmap: bitmap, version: .consistentV2),
              let target = bitmap.image.colorSpace.flatMap(FloatAnalysis.extendedTargetSpace) else {
            return .noProposal(.unsupportedDomain)
        }
        let context = session.context(for: .consistentV2)
        let source: FloatToneHistogram
        let maximum: Double
        if cachedSource === bitmap.image, cachedDomain == domain,
           let histogram = cachedSourceHistogram, let peak = cachedSourceMaximum {
            source = histogram; maximum = peak
        } else {
            maximum = try FloatAnalysis.maximumSourceLuminance(bitmap, context: context)
            source = try FloatAnalysis.histogram(CIImage(cgImage: bitmap.image), context: context,
                                                 targetSpace: target, domain: domain)
            // Match the renderer's single-source decoded-image retention bound.
            if bitmap.resourceOwner == nil, bitmap.byteCost <= 64 * 1_024 * 1_024 {
                cachedSource = bitmap.image; cachedDomain = domain
                cachedSourceHistogram = source; cachedSourceMaximum = maximum
            } else {
                cachedSource = nil; cachedDomain = nil
                cachedSourceHistogram = nil; cachedSourceMaximum = nil
            }
        }
        // Source-range evidence is independent of the selected slider and of
        // other saved exposure corrections. A P3 gamut coordinate is not HDR.
        guard maximum / domain.nominalSDRWhite <= 1.000_01 else { return .noProposal(.hdrSource) }
        guard source.hasUsefulRange else { return .noProposal(.insufficientRange) }
        var global = settings
        global.localAdjustments = []; global.developGeometry = .neutral
        global[keyPath: control.keyPath] = 0
        global = global.normalized
        func histogram(_ candidate: EditSettings) throws -> FloatToneHistogram {
            try Task.checkCancellation()
            let graph = try EditRenderer.globalGraph(bitmap, settings: candidate, session: session)
            return try FloatAnalysis.histogram(graph, context: context, targetSpace: target, domain: domain)
        }
        let baseline = try histogram(global)
        guard baseline.hasUsefulRange else { return .noProposal(.insufficientRange) }
        let initial = control.measurement(in: baseline), targetValue = control.target
        let tolerance = 2.0 / 1_023
        guard abs(initial - targetValue) > tolerance else { return .value(0) }
        if control == .shadows && initial >= targetValue { return .value(0) }
        if control == .highlights && initial <= targetValue { return .value(0) }
        let direction = initial < targetValue ? 1.0 : -1.0
        var lower = 1, upper = Int((control.range.upperBound / control.step).rounded())
        var best = 0.0, bestError = abs(initial - targetValue), firstCandidate = true
        while lower <= upper {
            try Task.checkCancellation()
            let units = firstCandidate ? upper : (lower + upper) / 2
            firstCandidate = false
            let candidate = direction * Double(units) * control.step
            var proposed = global
            proposed[keyPath: control.keyPath] = candidate
            let result = try histogram(proposed)
            let measured = control.measurement(in: result), error = abs(measured - targetValue)
            let safe = result.preservesClipping(of: baseline)
            if safe && (error < bestError - 0.000_001 ||
                (abs(error - bestError) <= 0.000_001 && abs(candidate) < abs(best))) {
                best = candidate; bestError = error
            }
            if !safe || direction * (measured - targetValue) >= 0 { upper = units - 1 }
            else { lower = units + 1 }
        }
        try Task.checkCancellation()
        guard abs(initial - targetValue) - bestError > tolerance else { return .noProposal(.noUsefulImprovement) }
        return .value(min(control.range.upperBound, max(control.range.lowerBound, best)))
    }

    /// Estimates one absolute slider value from an already decoded source.
    /// Other global adjustments, profiles and natural balance remain active.
    /// Local masks, crop and retouch are deliberately excluded: this is a
    /// global source estimate, with no mask allocations or replacement renders.
    func value(for control: AutomaticToneControl, bitmap: PreviewBitmap, settings: EditSettings) throws -> Double {
        try Task.checkCancellation()
        let size = try EditRenderer.outputSize(bitmap, maximumPixelSize: 256)
        let proxy = try EditRenderer.resized(bitmap, width: size.width, height: size.height, priority: .thumbnail,
                                             toneProcessingVersion: settings.workingMemoryVersion)
        let source = try AutomaticToneHistogram(proxy.image)
        // A flat field, nearly uniform noise or isolated specular outliers do
        // not provide enough tonal evidence to justify an automatic change.
        guard source.hasUsefulRange else { return 0 }

        var global = settings
        global.localAdjustments = []
        global.developGeometry = .neutral
        global[keyPath: control.keyPath] = 0
        global = global.normalized
        let baseline = try histogram(proxy, settings: global)
        guard baseline.hasUsefulRange else { return 0 }
        let initial = control.measurement(in: baseline)
        let target = control.target
        let tolerance = 2.0 / 1_023
        guard abs(initial - target) > tolerance else { return 0 }
        // Shadow/highlight recovery only opens blocked shadows or restrains
        // bright highlights; it does not force an already suitable tail.
        if control == .shadows && initial >= target { return 0 }
        if control == .highlights && initial <= target { return 0 }

        let direction = initial < target ? 1.0 : -1.0
        var lower = 1
        var upper = Int((control.range.upperBound / control.step).rounded())
        var best = 0.0
        var bestError = abs(initial - target)
        var firstCandidate = true

        // Search on the UI's exact step grid. At most nine small candidate
        // renders are needed; accepted results never depend on the old value
        // of the selected control, so repeated invocation is idempotent.
        while lower <= upper {
            try Task.checkCancellation()
            let units = firstCandidate ? upper : (lower + upper) / 2
            firstCandidate = false
            let candidate = direction * Double(units) * control.step
            var proposed = global
            proposed[keyPath: control.keyPath] = candidate
            let result = try histogram(proxy, settings: proposed)
            let measured = control.measurement(in: result)
            let error = abs(measured - target)
            // Do not trade a substantial newly clipped region for a better
            // percentile. Existing clipping and tiny specular points are kept.
            let safe = result.blackClipping <= baseline.blackClipping + 0.005 &&
                result.whiteClipping <= baseline.whiteClipping + 0.005
            if safe && (error < bestError - 0.000_001 ||
                (abs(error - bestError) <= 0.000_001 && abs(candidate) < abs(best))) {
                best = candidate
                bestError = error
            }
            let passedTarget = direction * (measured - target) >= 0
            if !safe || passedTarget {
                upper = units - 1
            } else {
                lower = units + 1
            }
        }
        try Task.checkCancellation()
        // Avoid jumping to a limit when that control has no useful influence
        // on the sampled tonal region (for example whites in a dark scene).
        guard abs(initial - target) - bestError > tolerance else { return 0 }
        return min(control.range.upperBound, max(control.range.lowerBound, best))
    }

    private func histogram(_ bitmap: PreviewBitmap, settings: EditSettings) throws -> AutomaticToneHistogram {
        try Task.checkCancellation()
        let rendered = try EditRenderer.render(bitmap, settings: settings, session: session)
        return try AutomaticToneHistogram(rendered.image)
    }
}

fileprivate struct AutomaticToneHistogram {
    private let bins: [Double]
    private let total: Double
    let blackClipping: Double
    let whiteClipping: Double

    var hasUsefulRange: Bool {
        total > 0 && percentile(0.95) - percentile(0.05) >= 0.04
    }

    init(_ image: CGImage) throws {
        try Task.checkCancellation()
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 256, height <= 256 else { throw EditRenderError.oversizedPreview }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditRenderError.unavailable }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var bins = [Double](repeating: 0, count: 1_024)
        var total = 0.0, black = 0.0, white = 0.0
        // At most 65,536 pixels: a serial alpha-weighted CPU histogram avoids
        // worker startup, synchronization and another GPU readback per bin.
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = Double(pixels[offset + 3])
                guard alpha > 0 else { continue }
                let luminance = min(1, (0.2126 * Double(pixels[offset]) +
                    0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])) / alpha)
                let weight = alpha / 255
                bins[Int((luminance * 1_023).rounded())] += weight
                total += weight
                let maximumChannel = Double(max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))) / alpha
                if maximumChannel <= 1.0 / 255 { black += weight }
                if maximumChannel >= 254.0 / 255 { white += weight }
            }
        }
        self.bins = bins
        self.total = total
        blackClipping = total > 0 ? black / total : 0
        whiteClipping = total > 0 ? white / total : 0
    }

    func percentile(_ fraction: Double) -> Double {
        guard total > 0 else { return 0 }
        let threshold = total * fraction
        var cumulative = 0.0
        for (index, count) in bins.enumerated() {
            cumulative += count
            if cumulative >= threshold { return Double(index) / 1_023 }
        }
        return 1
    }
}
