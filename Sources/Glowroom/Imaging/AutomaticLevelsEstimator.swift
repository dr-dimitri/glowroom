import CoreImage
import Foundation
import GlowroomCore

enum AutomaticLevelsNoProposalReason: Equatable, Sendable, LocalizedError {
    case unknownSourceRange, unsupportedDomain, hdrSource, hdrOutput, legacyOutputLimits
    case insufficientSamples, insufficientRange, lowKey, highKey, noUsefulImprovement, clippingLimited

    init(_ reason: AutomaticLevelsProposalReason) {
        switch reason {
        case .insufficientSamples: self = .insufficientSamples
        case .insufficientRange: self = .insufficientRange
        case .lowKey: self = .lowKey
        case .highKey: self = .highKey
        case .noUsefulImprovement: self = .noUsefulImprovement
        }
    }

    var explanation: String {
        let message: String
        switch self {
        case .unknownSourceRange: message = "Der Helligkeitsbereich dieser Bildquelle ist nicht zuverlässig bekannt."
        case .unsupportedDomain: message = "Das Farbprofil dieser Bildquelle erlaubt noch keine sichere SDR-Tonwertspreizung."
        case .hdrSource: message = "Die bereits decodierte Bildquelle enthält echte HDR-Helligkeiten oberhalb von SDR-Weiß."
        case .hdrOutput: message = "Die automatische Tonwertspreizung ist bei aktiver HDR-Ausgabe nicht verfügbar."
        case .legacyOutputLimits:
            message = "Die eingefrorene ältere Verarbeitung begrenzt Präsenz oder Schärfung vor dem Zielprofil. Dafür kann keine sichere Tonwertspreizung geprüft werden; die Verarbeitungsversion wird nicht automatisch geändert."
        case .insufficientSamples: message = "Das Bild enthält zu wenig sichtbare Bildfläche für eine verlässliche Tonwertspreizung."
        case .insufficientRange: message = "Das Bild enthält zu wenig verlässliche Tonwertunterschiede für eine Tonwertspreizung."
        case .lowKey, .highKey:
            message = "Für diese Tonwertverteilung wird vorsichtshalber keine automatische Spreizung vorgeschlagen."
        case .noUsefulImprovement: message = "Innerhalb der Qualitätsgrenzen wurde keine sinnvolle Tonwertspreizung gefunden."
        case .clippingLimited: message = "Die Tonwertspreizung würde zusätzliche Bildflächen an eine Ausgabegrenze drücken."
        }
        return message + " Die bisherigen Levels bleiben erhalten."
    }

    var errorDescription: String? { explanation }
}

enum AutomaticLevelsEstimate: Equatable, Sendable {
    case value(LevelsSettings)
    case noProposal(AutomaticLevelsNoProposalReason)
}

struct AutomaticLevelsSourceProof: Equatable, Sendable {
    let sourceIdentity: UUID
    let width: Int
    let height: Int
    let rangeProvenance: PreviewRangeProvenance
    let nominalSDRWhite: Double?
    let maximumLuminance: Double?
}

struct AutomaticLevelsDomain: Equatable, Sendable {
    let toneProcessingVersion: ToneProcessingVersion
    let transferFunction: LevelsTransferFunction
    let levelsVersion: LevelsVersion
    let sourceProfile: String
    let targetProfile: String
    let targetLinearProfile: String
    let workingSpace = "extended-linear-sRGB"
    let histogramTransfer = "signed-sRGB"
}

enum AutomaticLevelsNativeGate: String, Equatable, Sendable {
    case candidatePolicy, unrepresentableGraph
    case newAnyLower, newAnyUpper, newAllBlack, newAllWhite
}

struct AutomaticLevelsAttempt: Equatable, Sendable {
    let candidate: AutomaticLevelsCandidate
    let clipping: PairedLevelsClipping.Result?
    let gateFailures: [AutomaticLevelsNativeGate]
}

struct AutomaticLevelsDiagnostics: Sendable {
    var sourceProof: AutomaticLevelsSourceProof
    let inputWidth: Int
    let inputHeight: Int
    var domain: AutomaticLevelsDomain?
    var reference: AutomaticLevelsRGBEndpoints?
    var common: AutomaticLevelsEndpoints?
    var statistics: AutomaticLevelsRGBStatistics?
    var visibleEquivalent = 0.0
    var acceptedStrength: Double?
    var attempts: [AutomaticLevelsAttempt] = []
}

struct AutomaticLevelsAnalysis: Sendable {
    let estimate: AutomaticLevelsEstimate
    let diagnostics: AutomaticLevelsDiagnostics
}

/// Static native work for the existing AutomaticToneEstimator actor. No actor,
/// queue, decoder or nested worker pool is introduced. Its caller owns the
/// resource lease and passes the same session used by other tone analyses.
enum AutomaticLevelsEstimator {
    static let maximumCachedRasterBytes = 256 * 256 * 4 * MemoryLayout<Float>.stride

    struct CacheState: Equatable, Sendable {
        let entries: Int
        let rasterBytes: Int
        let histogramBytes: Int
        let sourceMeasurements: Int
        let histogramMeasurements: Int
        let baselineMeasurements: Int
        let sourceHits: Int
        let histogramHits: Int
        let baselineHits: Int
    }

    /// One normal-source entry, at most one MiB of baseline pixels plus three
    /// fixed histograms. Scalars/UUIDs never retain a CGImage or resource owner.
    /// Artifact inputs clear/disable this cache; their arrays cannot outlive the
    /// admitted phase without an explicit ownership reservation.
    struct Cache: Sendable {
        fileprivate var entry: Entry?
        fileprivate var sourceMeasurements = 0, histogramMeasurements = 0, baselineMeasurements = 0
        fileprivate var sourceHits = 0, histogramHits = 0, baselineHits = 0

        init() {}
        mutating func clear() { entry = nil }
        func state() -> CacheState {
            CacheState(entries: entry == nil ? 0 : 1,
                rasterBytes: (entry?.baseline?.pixels.count ?? 0) * MemoryLayout<Float>.stride,
                histogramBytes: entry?.histogram == nil ? 0 : AutomaticLevelsPolicy.maximumHistogramBytes,
                sourceMeasurements: sourceMeasurements, histogramMeasurements: histogramMeasurements,
                baselineMeasurements: baselineMeasurements, sourceHits: sourceHits,
                histogramHits: histogramHits, baselineHits: baselineHits)
        }
    }

    fileprivate struct SourceKey: Equatable, Sendable {
        let identity: SourceAnalysisIdentity
        let range: PreviewRangeProvenance
        let sourceLongEdge: Int
        init(_ bitmap: PreviewBitmap) {
            identity = SourceAnalysisIdentity(bitmap: bitmap)
            range = bitmap.rangeProvenance; sourceLongEdge = bitmap.sourceLongEdge
        }
    }

    fileprivate struct HistogramKey: Equatable, Sendable {
        let input: SourceKey
        let upstream: EditSettings
        init(_ bitmap: PreviewBitmap, global: EditSettings) {
            input = SourceKey(bitmap)
            var upstream = global
            upstream.texture = 0; upstream.clarity = 0
            upstream.sharpeningAmount = 0; upstream.sharpeningRadius = 1
            upstream.sharpeningDetail = 25; upstream.sharpeningMasking = 0
            upstream.developColor.isMonochrome = false
            if upstream.naturalBalanceAmount == 0 { upstream.naturalBalanceColorAmount = 50 }
            self.upstream = upstream
        }
    }

    fileprivate struct BaselineKey: Equatable, Sendable {
        let input: SourceKey
        let global: EditSettings
        let targetProfile: String
    }

    fileprivate struct Entry: Sendable {
        let source: SourceKey
        let proof: AutomaticLevelsSourceProof
        var histogramKey: HistogramKey?
        var histogram: AutomaticLevelsHistogram?
        var baselineKey: BaselineKey?
        var baseline: FloatAnalysisRaster?
    }

    static func analyze(bitmap: PreviewBitmap, sourceBitmap: PreviewBitmap? = nil, settings: EditSettings,
                        session: EditRenderer.Session, cache: inout Cache) throws -> AutomaticLevelsAnalysis {
        try Task.checkCancellation()
        _ = try EditingSnapshot(settings: settings)
        let source = sourceBitmap ?? bitmap
        let sourceKey = SourceKey(source)
        let caches = bitmap.resourceOwner == nil && source.resourceOwner == nil &&
            bitmap.memoryOwnership == nil && source.memoryOwnership == nil
        if !caches || cache.entry?.source != sourceKey { cache.clear() }
        var diagnostics = AutomaticLevelsDiagnostics(sourceProof: proof(source, maximum: nil),
            inputWidth: bitmap.image.width, inputHeight: bitmap.image.height)
        func result(_ estimate: AutomaticLevelsEstimate) -> AutomaticLevelsAnalysis {
            AutomaticLevelsAnalysis(estimate: estimate, diagnostics: diagnostics)
        }
        guard !settings.developColor.hdrEnabled else { return result(.noProposal(.hdrOutput)) }
        // Frozen V1 presence and sharpening constrain working-sRGB before
        // target conversion. In P3 this can hide a newly limited component
        // inside the destination gamut, so target-boundary flags cannot prove
        // safety. Keep those saved algorithms and decline explicitly instead.
        guard settings.toneProcessingVersion != .legacyV1 ||
            (settings.texture == 0 && settings.clarity == 0 && settings.sharpeningAmount <= 0) else {
            return result(.noProposal(.legacyOutputLimits))
        }
        guard let white = source.rangeProvenance.nominalSDRWhite,
              let inputWhite = bitmap.rangeProvenance.nominalSDRWhite,
              white == inputWhite else { return result(.noProposal(.unknownSourceRange)) }
        guard supportedSource(source.image.colorSpace), supportedSource(bitmap.image.colorSpace),
              let target = try? EditRenderer.developedOutputColorSpace(for: bitmap.image),
              let targetLinear = FloatAnalysis.extendedTargetSpace(target) else {
            return result(.noProposal(.unsupportedDomain))
        }
        diagnostics.domain = AutomaticLevelsDomain(toneProcessingVersion: settings.toneProcessingVersion,
            transferFunction: settings.levels.transferFunction, levelsVersion: settings.levels.version,
            sourceProfile: profileName(bitmap.image.colorSpace), targetProfile: profileName(target),
            targetLinearProfile: profileName(targetLinear))
        // F32 is an allocation/readback choice, never an algorithm upgrade.
        // V1 still executes all frozen V1 tone/presence/noise kernels.
        let context = session.context(for: .consistentV2)
        let sourceProof: AutomaticLevelsSourceProof
        if caches, let cached = cache.entry, cached.source == sourceKey {
            sourceProof = cached.proof; cache.sourceHits += 1
        } else {
            cache.sourceMeasurements += 1
            let maximum = try FloatAnalysis.maximumSourceLuminance(source, context: context)
            sourceProof = proof(source, maximum: maximum)
            if caches { cache.entry = Entry(source: sourceKey, proof: sourceProof) }
        }
        diagnostics.sourceProof = sourceProof
        guard let maximum = sourceProof.maximumLuminance, maximum / white <= 1.000_01 else {
            return result(.noProposal(.hdrSource))
        }

        var global = settings.normalized
        // Complete replacement of old levels, masks, retouch and geometry for
        // both histogram and candidate comparison. All other globals survive.
        global.levels = LevelsSettings(transferFunction: settings.levels.transferFunction, version: settings.levels.version)
        global.localAdjustments = []; global.developGeometry = .neutral
        let expectedExtent = CGRect(x: 0, y: 0, width: bitmap.image.width, height: bitmap.image.height)
        let histogramKey = HistogramKey(bitmap, global: global)
        let histogram: AutomaticLevelsHistogram
        if caches, let cached = cache.entry, cached.histogramKey == histogramKey, let stored = cached.histogram {
            histogram = stored; cache.histogramHits += 1
        } else {
            cache.histogramMeasurements += 1
            // The temporary input raster dies before baseline/candidate arrays
            // are created. No second 65,536-element sample structure is built.
            histogram = try inputHistogram(bitmap: bitmap, global: global, extent: expectedExtent,
                                           session: session, context: context)
            if caches { cache.entry?.histogramKey = histogramKey; cache.entry?.histogram = histogram }
        }
        diagnostics.visibleEquivalent = histogram.visibleEquivalent
        diagnostics.statistics = histogram.statistics
        diagnostics.reference = AutomaticLevelsReference.estimate(histogram: histogram)
        let stencil: AutomaticLevelsProposalStencil
        switch AutomaticLevelsProposalStencil.make(histogram: histogram) {
        case .noProposal(let reason): return result(.noProposal(.init(reason)))
        case .stencil(let proposed): stencil = proposed
        }
        diagnostics.common = stencil.common

        let baselineKey = BaselineKey(input: SourceKey(bitmap), global: global, targetProfile: profileName(targetLinear))
        let baseline: FloatAnalysisRaster
        if caches, let cached = cache.entry, cached.baselineKey == baselineKey, let stored = cached.baseline {
            baseline = stored; cache.baselineHits += 1
        } else {
            cache.baselineMeasurements += 1
            baseline = try outputRaster(bitmap: bitmap, settings: global, extent: expectedExtent,
                                        session: session, context: context, target: targetLinear)
            if caches, baseline.pixels.count * MemoryLayout<Float>.stride <= maximumCachedRasterBytes {
                cache.entry?.baselineKey = baselineKey; cache.entry?.baseline = baseline
            }
        }
        var sawEligible = false
        // A fixed descending list, each checked against the SAME neutral
        // baseline. The active suffix can be nonmonotone; do not binary-search
        // a clipping verdict or interpolate an unrendered candidate afterward.
        for strength in AutomaticLevelsPolicy.strengths {
            try Task.checkCancellation()
            let candidate = try stencil.evaluate(at: strength, preserving: settings.levels)
            guard let levels = candidate.levels else {
                diagnostics.attempts.append(.init(candidate: candidate, clipping: nil, gateFailures: [.candidatePolicy]))
                continue
            }
            sawEligible = true
            var proposed = global; proposed.levels = levels
            do {
                let output = try outputRaster(bitmap: bitmap, settings: proposed, extent: expectedExtent,
                    session: session, context: context, target: targetLinear)
                let clipping = try PairedLevelsClipping.measure(baseline: baseline, candidate: output)
                let failures = clippingFailures(clipping)
                diagnostics.attempts.append(.init(candidate: candidate, clipping: clipping, gateFailures: failures))
                if failures.isEmpty, clipping.isWithinBudget {
                    diagnostics.acceptedStrength = strength
                    return result(.value(levels))
                }
            } catch EditRenderError.unrepresentableLevels {
                diagnostics.attempts.append(.init(candidate: candidate, clipping: nil, gateFailures: [.unrepresentableGraph]))
            }
        }
        return result(.noProposal(sawEligible ? .clippingLimited : .noUsefulImprovement))
    }

    private static func inputHistogram(bitmap: PreviewBitmap, global: EditSettings, extent: CGRect,
                                       session: EditRenderer.Session, context: CIContext) throws -> AutomaticLevelsHistogram {
        let graph = try EditRenderer.globalLevelsInputGraph(bitmap, settings: global, session: session)
        guard graph.extent == extent else { throw PairedLevelsClipping.ValidationError.incompatibleRaster }
        let raster = try FloatAnalysis.raster(graph, context: context, colorSpace: FloatAnalysis.workingSpace)
        var builder = AutomaticLevelsHistogramBuilder()
        for row in 0..<raster.height {
            try Task.checkCancellation()
            for column in 0..<raster.width {
                let offset = (row * raster.width + column) * 4
                let alpha = Double(raster.pixels[offset + 3])
                let red = alpha > 0 ? SignedSRGB.encode(Double(raster.pixels[offset]) / alpha) : 0
                let green = alpha > 0 ? SignedSRGB.encode(Double(raster.pixels[offset + 1]) / alpha) : 0
                let blue = alpha > 0 ? SignedSRGB.encode(Double(raster.pixels[offset + 2]) / alpha) : 0
                builder.add(encodedRed: red, green: green, blue: blue, alpha: alpha)
            }
        }
        return builder.finish()
    }

    private static func outputRaster(bitmap: PreviewBitmap, settings: EditSettings, extent: CGRect,
                                     session: EditRenderer.Session, context: CIContext,
                                     target: CGColorSpace) throws -> FloatAnalysisRaster {
        let graph = try EditRenderer.globalGraph(bitmap, settings: settings, session: session)
        guard graph.extent == extent else { throw PairedLevelsClipping.ValidationError.incompatibleRaster }
        return try FloatAnalysis.raster(graph, context: context, colorSpace: target)
    }

    private static func proof(_ bitmap: PreviewBitmap, maximum: Double?) -> AutomaticLevelsSourceProof {
        AutomaticLevelsSourceProof(sourceIdentity: bitmap.rangeSourceIdentity,
            width: bitmap.image.width, height: bitmap.image.height, rangeProvenance: bitmap.rangeProvenance,
            nominalSDRWhite: bitmap.rangeProvenance.nominalSDRWhite, maximumLuminance: maximum)
    }

    private static func supportedSource(_ space: CGColorSpace?) -> Bool {
        guard let space else { return false }
        // Gray ICC input is converted by Core Image into the RGB working
        // space. Its developed output is sRGB; it is not a gray target domain.
        return space.model == .monochrome || FloatAnalysis.extendedTargetSpace(space) != nil
    }

    private static func profileName(_ space: CGColorSpace?) -> String {
        guard let space else { return "unknown" }
        return space.name.map { $0 as String } ?? (space.model == .monochrome ? "ICC-gray" : "ICC-RGB")
    }

    private static func clippingFailures(_ clipping: PairedLevelsClipping.Result) -> [AutomaticLevelsNativeGate] {
        var failures: [AutomaticLevelsNativeGate] = []
        if clipping.newlyClipped.anyLower > clipping.limit { failures.append(.newAnyLower) }
        if clipping.newlyClipped.anyUpper > clipping.limit { failures.append(.newAnyUpper) }
        if clipping.newlyClipped.allBlack > clipping.limit { failures.append(.newAllBlack) }
        if clipping.newlyClipped.allWhite > clipping.limit { failures.append(.newAllWhite) }
        return failures
    }
}
