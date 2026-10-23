import CoreImage
import Foundation
import GlowroomCore

enum AutomaticToneNoProposalReason: Equatable, Sendable {
    case unknownSourceRange, unsupportedDomain, hdrSource, hdrOutput
    case insufficientRange, noUsefulImprovement

    var explanation: String {
        let reason: String
        switch self {
        case .unknownSourceRange: reason = "Der Helligkeitsbereich dieser Bildquelle ist nicht zuverlässig bekannt."
        case .unsupportedDomain: reason = "Das Farbprofil dieser Bildquelle wird von der SDR-Tonwertautomatik noch nicht unterstützt."
        case .hdrSource: reason = "Diese Bildquelle enthält Helligkeiten oberhalb von SDR-Weiß; dafür steht noch keine HDR-Tonwertautomatik bereit."
        case .hdrOutput: reason = "Die Tonwertautomatik berechnet SDR-Zielwerte und ist bei aktiver HDR-Ausgabe nicht verfügbar."
        case .insufficientRange: reason = "Das Bild enthält zu wenig verlässliche Tonwertunterschiede für einen automatischen Vorschlag."
        case .noUsefulImprovement: reason = "Für diesen Regler wurde keine sinnvolle Verbesserung innerhalb der Clippinggrenzen gefunden."
        }
        return reason + " Der bisherige Wert bleibt erhalten."
    }
}

enum AutomaticToneEstimate: Equatable, Sendable {
    case value(Double)
    case noProposal(AutomaticToneNoProposalReason)
}

/// Explicit metadata for the analysis buffer; display histograms have a separate
/// SDR/RGBA8 contract. SDR white is linear Y in the decoded source's range.
struct FloatAnalysisDomain: Hashable, Sendable {
    enum WorkingSpace: Hashable, Sendable { case extendedLinearSRGB }
    enum Transfer: Hashable, Sendable { case linear }
    let workingSpace = WorkingSpace.extendedLinearSRGB
    let transfer = Transfer.linear
    let version: ToneProcessingVersion
    let sourceRange: PreviewRangeProvenance
    let nominalSDRWhite: Double
    let targetProfile: String

    init?(bitmap: PreviewBitmap, version: ToneProcessingVersion) {
        guard let space = bitmap.image.colorSpace,
              FloatAnalysis.extendedTargetSpace(space) != nil, let name = space.name else { return nil }
        let white: Double
        switch bitmap.rangeProvenance {
        case .sdrDecoded: white = 1
        case .extended(let nominalSDRWhite): white = nominalSDRWhite
        case .unknown: return nil
        }
        guard white.isFinite, white > 0 else { return nil }
        self.version = version; sourceRange = bitmap.rangeProvenance
        nominalSDRWhite = white; targetProfile = name as String
    }
}

/// A bounded straight-RGB view of a color-managed Float readback. Core Image
/// writes premultiplied RGBA; consumers unpremultiply exactly once at reduction.
struct FloatAnalysisRaster: Sendable {
    let width: Int
    let height: Int
    let pixels: [Float]
}

enum FloatAnalysis {
    static let maximumPixelSize = 256
    /// Two 256² RGBAf buffers plus source, baseline and candidate histograms. The existing
    /// estimator actor serializes these small reductions; no worker pool is added.
    static let maximumWorkingBytes = 2 * 256 * 256 * 4 * MemoryLayout<Float>.stride + 3 * 4_096 * MemoryLayout<Double>.stride
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func extendedTargetSpace(_ space: CGColorSpace) -> CGColorSpace? {
        // Only known RGB matrix profiles have a supported SDR-white/gamut
        // interpretation here. Arbitrary LUT/gray profiles get no proposal.
        let supported = [CGColorSpace.sRGB, CGColorSpace.linearSRGB,
                         CGColorSpace.extendedSRGB, CGColorSpace.extendedLinearSRGB,
                         CGColorSpace.displayP3, CGColorSpace.linearDisplayP3,
                         CGColorSpace.extendedDisplayP3, CGColorSpace.extendedLinearDisplayP3,
                         CGColorSpace.adobeRGB1998]
        guard space.model == .rgb, let name = space.name,
              supported.contains(where: { $0 == name }) else { return nil }
        return CGColorSpaceCreateExtendedLinearized(space)
    }

    static func raster(_ graph: CIImage, context: CIContext, colorSpace: CGColorSpace) throws -> FloatAnalysisRaster {
        try Task.checkCancellation()
        let extent = graph.extent
        guard !extent.isEmpty, !extent.isInfinite,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite),
              extent.width > 0, extent.height > 0 else { throw EditRenderError.unavailable }
        let scale = min(1, Double(maximumPixelSize) / max(extent.width, extent.height))
        let width = max(1, min(maximumPixelSize, Int((extent.width * scale).rounded())))
        let height = max(1, min(maximumPixelSize, Int((extent.height * scale).rounded())))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let proxy = graph.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(proxy, toBitmap: buffer.baseAddress!, rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: colorSpace)
        }
        try Task.checkCancellation()
        guard pixels.allSatisfy(\.isFinite) else { throw EditRenderError.unavailable }
        return FloatAnalysisRaster(width: width, height: height, pixels: pixels)
    }

    static func histogram(_ graph: CIImage, context: CIContext, targetSpace: CGColorSpace,
                          domain: FloatAnalysisDomain) throws -> FloatToneHistogram {
        let linear = try raster(graph, context: context, colorSpace: workingSpace)
        let target = try raster(graph, context: context, colorSpace: targetSpace)
        return try FloatToneHistogram(linear: linear, target: target, domain: domain)
    }

    /// The full input graph is reduced to one pixel on the existing CI backend.
    /// Unlike a downsampled maximum, this does not miss a tiny HDR highlight.
    /// It reads the already decoded CGImage and never asks ImageIO for RAW again.
    static func maximumSourceLuminance(_ bitmap: PreviewBitmap, context: CIContext) throws -> Double {
        try Task.checkCancellation()
        guard let luminanceKernel else { throw EditRenderError.unavailable }
        let source = CIImage(cgImage: bitmap.image)
        guard let luminance = luminanceKernel.apply(extent: source.extent, arguments: [source]) else {
            throw EditRenderError.unavailable
        }
        let maximum = luminance.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: source.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(maximum, toBitmap: buffer.baseAddress!, rowBytes: 4 * MemoryLayout<Float>.stride,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: workingSpace)
        }
        try Task.checkCancellation()
        guard pixel.allSatisfy(\.isFinite) else { throw EditRenderError.unavailable }
        return Double(pixel[0])
    }

    private static let luminanceKernel = CIColorKernel(source: """
        kernel vec4 sourceLuminance(__sample pixel) {
            if (pixel.a <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
            vec3 rgb = pixel.rgb / pixel.a;
            float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            return vec4(y, y, y, 1.0);
        }
        """)
}

struct FloatToneHistogram: Sendable {
    let domain: FloatAnalysisDomain
    private let bins: [Double]
    let total: Double
    let belowSDRBlack: Double
    let aboveSDRWhite: Double
    let blackClipping: Double
    let whiteClipping: Double
    let lowerGamutExcursion: Double
    let upperGamutExcursion: Double
    let lowerExcursionMagnitude: Double
    let upperExcursionMagnitude: Double

    var hasUsefulRange: Bool { total > 0 && percentile(0.95) - percentile(0.05) >= 0.04 }

    init(linear: FloatAnalysisRaster, target: FloatAnalysisRaster, domain: FloatAnalysisDomain) throws {
        guard linear.width == target.width, linear.height == target.height,
              linear.pixels.count == linear.width * linear.height * 4,
              target.pixels.count == linear.pixels.count else { throw EditRenderError.unavailable }
        var bins = [Double](repeating: 0, count: 4_096)
        var total = 0.0, below = 0.0, above = 0.0, black = 0.0, white = 0.0
        var lower = 0.0, upper = 0.0, lowerMagnitude = 0.0, upperMagnitude = 0.0
        // <=65,536 pixels and two small buffers: CPU reduction stays serial to
        // avoid extra scheduling, synchronization or one GPU readback per bin.
        for row in 0..<linear.height {
            try Task.checkCancellation()
            for column in 0..<linear.width {
                let offset = (row * linear.width + column) * 4
                let alpha = Double(linear.pixels[offset + 3])
                guard alpha.isFinite, (0...1.000_01).contains(alpha),
                      abs(alpha - Double(target.pixels[offset + 3])) <= 0.000_01 else { throw EditRenderError.unavailable }
                guard alpha > 0 else { continue }
                let red = Double(linear.pixels[offset]) / alpha
                let green = Double(linear.pixels[offset + 1]) / alpha
                let blue = Double(linear.pixels[offset + 2]) / alpha
                let targetScale = alpha * domain.nominalSDRWhite
                let targetRed = Double(target.pixels[offset]) / targetScale
                let targetGreen = Double(target.pixels[offset + 1]) / targetScale
                let targetBlue = Double(target.pixels[offset + 2]) / targetScale
                guard red.isFinite, green.isFinite, blue.isFinite,
                      targetRed.isFinite, targetGreen.isFinite, targetBlue.isFinite else { throw EditRenderError.unavailable }
                let y = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / domain.nominalSDRWhite
                let perceptual = SignedSRGB.encode(y)
                guard perceptual.isFinite else { throw EditRenderError.unavailable }
                bins[Int((min(max(perceptual, 0), 1) * 4_095).rounded())] += alpha
                total += alpha
                if y < 0 { below += alpha }
                if y > 1.000_01 { above += alpha }
                let minimum = min(targetRed, targetGreen, targetBlue), maximum = max(targetRed, targetGreen, targetBlue)
                if maximum <= 0.000_01 { black += alpha }
                if maximum >= 0.999_99 { white += alpha }
                if minimum < -0.000_01 { lower += alpha }
                if maximum > 1.000_01 { upper += alpha }
                lowerMagnitude += max(0, -minimum) * alpha
                upperMagnitude += max(0, maximum - 1) * alpha
            }
        }
        self.domain = domain; self.bins = bins; self.total = total
        func fraction(_ amount: Double) -> Double { total > 0 ? amount / total : 0 }
        belowSDRBlack = fraction(below); aboveSDRWhite = fraction(above)
        blackClipping = fraction(black); whiteClipping = fraction(white)
        lowerGamutExcursion = fraction(lower); upperGamutExcursion = fraction(upper)
        lowerExcursionMagnitude = fraction(lowerMagnitude); upperExcursionMagnitude = fraction(upperMagnitude)
    }

    func percentile(_ fraction: Double) -> Double {
        guard total > 0 else { return 0 }
        let threshold = total * fraction
        var cumulative = 0.0
        for (index, count) in bins.enumerated() {
            cumulative += count
            if cumulative >= threshold { return Double(index) / 4_095 }
        }
        return 1
    }

    func preservesClipping(of baseline: Self) -> Bool {
        blackClipping <= baseline.blackClipping + 0.005 && whiteClipping <= baseline.whiteClipping + 0.005 &&
        lowerGamutExcursion <= baseline.lowerGamutExcursion + 0.005 && upperGamutExcursion <= baseline.upperGamutExcursion + 0.005 &&
        lowerExcursionMagnitude <= baseline.lowerExcursionMagnitude + 0.000_5 &&
        upperExcursionMagnitude <= baseline.upperExcursionMagnitude + 0.000_5
    }
}
