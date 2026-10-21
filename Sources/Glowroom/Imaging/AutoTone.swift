import CoreGraphics
import CoreImage
import Foundation

/// A conservative, image-dependent global tone curve. Fixed black/white anchors
/// retain the available range; a monotone interpolant cannot reverse gradients.
/// Analysis always uses the original preview, before the manual edit controls.
struct AutoToneCurve: Sendable {
    static let abscissae: [Double] = [0, 0.06, 0.25, 0.50, 0.75, 0.94, 1]
    let ordinates: [Double]
    let coefficients: [[Double]]

    init(ordinates: [Double]) {
        self.ordinates = ordinates
        let x = Self.abscissae
        let h = (0..<6).map { x[$0 + 1] - x[$0] }
        let delta = (0..<6).map { (ordinates[$0 + 1] - ordinates[$0]) / h[$0] }
        var slopes = [Double](repeating: 0, count: 7)
        for i in 1..<6 where delta[i - 1] > 0 && delta[i] > 0 {
            let w1 = 2 * h[i] + h[i - 1]
            let w2 = h[i] + 2 * h[i - 1]
            slopes[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
        }
        slopes[0] = max(0, min(3 * delta[0], ((2 * h[0] + h[1]) * delta[0] - h[0] * delta[1]) / (h[0] + h[1])))
        slopes[6] = max(0, min(3 * delta[5], ((2 * h[5] + h[4]) * delta[5] - h[5] * delta[4]) / (h[5] + h[4])))
        coefficients = (0..<6).map { i in
            let y0 = ordinates[i], y1 = ordinates[i + 1]
            return [2 * y0 - 2 * y1 + h[i] * (slopes[i] + slopes[i + 1]),
                    -3 * y0 + 3 * y1 - h[i] * (2 * slopes[i] + slopes[i + 1]),
                    h[i] * slopes[i], y0]
        }
    }

    var isIdentity: Bool { zip(ordinates, Self.abscissae).allSatisfy { abs($0 - $1) < 0.000_001 } }

    func value(at luminance: Double) -> Double {
        let x = min(1, max(0, luminance))
        let i = (0..<5).first { x < Self.abscissae[$0 + 1] } ?? 5
        let t = (x - Self.abscissae[i]) / (Self.abscissae[i + 1] - Self.abscissae[i])
        let c = coefficients[i]
        return min(1, max(0, ((c[0] * t + c[1]) * t + c[2]) * t + c[3]))
    }

    static func analyze(_ image: CGImage, amount: Double) throws -> Self {
        try Task.checkCancellation()
        let amount = amount.isFinite ? min(1, max(0, amount / 100)) : 0
        guard amount > 0 else { return Self(ordinates: abscissae) }
        let analysis = try AutoToneAnalysisCache.shared.analysis(for: image)
        try Task.checkCancellation()
        return Self(ordinates: zip(abscissae, analysis.offsets).map { $0 + amount * $1 })
    }
}

/// Scene analysis does not depend on any edit slider, including auto-tone amount.
/// Keep the offsets rather than a full-strength curve so all amounts use exactly
/// the same arithmetic as an uncached analysis.
struct AutoToneAnalysis: Sendable {
    let offsets: [Double]

    static func analyze(_ image: CGImage) throws -> Self {
        let analysisSpan = PipelineTrace.begin(.analysis)
        defer { analysisSpan.end() }
        try Task.checkCancellation()
        // The workload is bounded independently of RAW dimensions. The same
        // sampling scale is used for the small and large progressive previews.
        let scale = min(1, 256 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw EditRenderError.unavailable
            }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        try Task.checkCancellation()
        var histogram = [Double](repeating: 0, count: 256)
        var weight = 0.0, luminanceSum = 0.0
        var shadowEvidence = 0.0, highlightEvidence = 0.0
        // At most 65,536 samples: a serial CPU reduction avoids another worker
        // pool and GPU readback while decoding other photos proceeds in parallel.
        for row in 0..<height {
            if row % 32 == 0 { try Task.checkCancellation() }
            for column in 0..<width {
                let index = (row * width + column) * 4
                let alpha = Double(pixels[index + 3])
                guard alpha > 0 else { continue }
                // Unpremultiply before analysis. Weight semi-transparent edges
                // by coverage so a large transparent margin cannot bias tones.
                let luminance = min(1, (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / alpha)
                let coverage = alpha / 255
                histogram[min(255, Int((luminance * 255).rounded()))] += coverage
                weight += coverage
                luminanceSum += luminance * coverage
                shadowEvidence += max(0, (0.25 - luminance) / 0.25) * coverage
                highlightEvidence += max(0, (luminance - 0.75) / 0.25) * coverage
            }
        }
        guard weight > 0 else { return Self(offsets: [Double](repeating: 0, count: 7)) }
        func percentile(_ fraction: Double) -> Double {
            var accumulated = 0.0
            for (index, frequency) in histogram.enumerated() {
                accumulated += frequency
                if accumulated >= weight * fraction { return Double(index) / 255 }
            }
            return 1
        }
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        let span = percentile(0.95) - percentile(0.05)
        // Flat fields and almost-flat sensor noise do not provide enough scene
        // information for automatic exposure or aggressive contrast expansion.
        let confidencePosition = clamp((span - 0.025) / 0.095)
        let confidence = confidencePosition * confidencePosition * (3 - 2 * confidencePosition)
        // Tail evidence also sees a small dark subject against a bright sky,
        // or a bright window in a dark room, which the robust percentiles alone
        // could miss. Tiny specular highlights contribute proportionally little.
        let mean = luminanceSum / weight
        // Ordinary, balanced gradients need only a light adjustment. Tail
        // evidence is strongest in a biased scene, where a percentile can miss
        // the small subject on the opposite end of the luminance distribution.
        let tailImportance = 0.35 + 0.65 * clamp(abs(mean - 0.5) / 0.25)
        let shadows = max(clamp((0.25 - percentile(0.20)) / 0.20), clamp(shadowEvidence / weight / 0.25) * tailImportance) * confidence
        let highlights = max(clamp((percentile(0.80) - 0.75) / 0.20), clamp(highlightEvidence / weight / 0.25) * tailImportance) * confidence
        let middle = (min(0.07, max(0, (0.38 - mean) * 0.35)) - min(0.07, max(0, (mean - 0.62) * 0.35))) * confidence
        let contrast = clamp((0.65 - span) / 0.40) * confidence * (1 - 0.65 * max(shadows, highlights))
        // Global balancing may never push an observed shadow lower, or an
        // observed highlight higher. This matters for unequal, bimodal scenes.
        let lowOuter = 0.045 * shadows + 0.25 * middle - 0.012 * contrast
        let lowInner = 0.070 * shadows + 0.65 * middle - 0.045 * contrast
        let highInner = -0.070 * highlights + 0.65 * middle + 0.045 * contrast
        let highOuter = -0.045 * highlights + 0.25 * middle + 0.012 * contrast
        let offsets = [0, shadows > 0 ? max(0.045 * shadows, lowOuter) : lowOuter,
                       shadows > 0 ? max(0.070 * shadows, lowInner) : lowInner, middle,
                       highlights > 0 ? min(-0.070 * highlights, highInner) : highInner,
                       highlights > 0 ? min(-0.045 * highlights, highOuter) : highOuter, 0]
        return Self(offsets: offsets)
    }
}

/// A small identity cache shares the original's analysis across slider changes.
/// Weak source references avoid extending the decoded preview's lifetime and
/// prevent a reused object address from matching a different image. The caller's
/// bounded render workers provide concurrency; this cache creates no worker pool.
final class AutoToneAnalysisCache: @unchecked Sendable {
    static let shared = AutoToneAnalysisCache()

    private final class Entry {
        weak var image: CGImage?
        var analysis: AutoToneAnalysis?
        var lastAccess: UInt64

        init(image: CGImage, lastAccess: UInt64) {
            self.image = image
            self.lastAccess = lastAccess
        }
    }

    private let condition = NSCondition()
    private let maximumEntries: Int
    private let analyzeImage: @Sendable (CGImage) throws -> AutoToneAnalysis
    // A short internal test observation, called under condition before the
    // first wait. It must not reenter the cache; production leaves it nil.
    private let didJoinInFlight: (@Sendable () -> Void)?
    // All mutable state, including each entry, is protected by condition.
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var access: UInt64 = 0

    init(maximumEntries: Int = 8,
         didJoinInFlight: (@Sendable () -> Void)? = nil,
         analyze: @escaping @Sendable (CGImage) throws -> AutoToneAnalysis = { try AutoToneAnalysis.analyze($0) }) {
        self.maximumEntries = max(1, maximumEntries)
        self.didJoinInFlight = didJoinInFlight
        self.analyzeImage = analyze
    }

    func analysis(for image: CGImage) throws -> AutoToneAnalysis {
        let identity = ObjectIdentifier(image)
        var reportedJoin = false
        while true {
            try Task.checkCancellation()
            condition.lock()
            entries = entries.filter { $0.value.image != nil }
            access &+= 1
            if let entry = entries[identity], entry.image === image {
                entry.lastAccess = access
                if let analysis = entry.analysis {
                    condition.unlock()
                    try Task.checkCancellation()
                    return analysis
                }
                // Joining a short CPU analysis does not schedule another worker.
                // A timed wait lets a canceled preview leave promptly even while
                // the shared producer is inside an uninterruptible bitmap draw.
                if !reportedJoin {
                    reportedJoin = true
                    didJoinInFlight?()
                }
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
                condition.unlock()
                continue
            }
            if entries.count >= maximumEntries,
               let oldest = entries.filter({ $0.value.analysis != nil })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                entries.removeValue(forKey: oldest)
            }
            guard entries.count < maximumEntries else {
                // Never evict an in-flight producer or grow beyond the bound.
                // Normally unreachable with the render pipeline's worker limit.
                condition.unlock()
                let result = try analyzeImage(image)
                try Task.checkCancellation()
                return result
            }
            let entry = Entry(image: image, lastAccess: access)
            entries[identity] = entry
            condition.unlock()
            do {
                let analysis = try analyzeImage(image)
                try Task.checkCancellation()
                condition.lock()
                if entries[identity] === entry { entry.analysis = analysis }
                condition.broadcast()
                condition.unlock()
                return analysis
            } catch {
                condition.lock()
                if entries[identity] === entry { entries.removeValue(forKey: identity) }
                condition.broadcast()
                condition.unlock()
                // A canceled or failed producer must not poison future requests;
                // remaining waiters can retry with their own cancellation state.
                throw error
            }
        }
    }
}

enum AutoToneRenderer {
    static func apply(to image: CIImage, original: CGImage, amount: Double, extent: CGRect) throws -> CIImage {
        let curve = try AutoToneCurve.analyze(original, amount: amount)
        guard !curve.isIdentity else { return image }
        let vectors = curve.coefficients.map { CIVector(x: $0[0], y: $0[1], z: $0[2], w: $0[3]) }
        guard let output = kernel?.apply(extent: extent, arguments: [image] + vectors) else {
            throw EditRenderError.unavailable
        }
        return output
    }

    private static let kernel = CIColorKernel(source: """
        kernel vec4 automaticTone(__sample original, vec4 c0, vec4 c1, vec4 c2, vec4 c3, vec4 c4, vec4 c5) {
            vec4 o = unpremultiply(original);
            // Signed sRGB transfer preserves wide-gamut channels outside the
            // sRGB cube while matching the perceptual histogram for normal RGB.
            vec3 magnitude = abs(o.rgb);
            vec3 rgb = sign(o.rgb) * mix(12.92 * magnitude, 1.055 * pow(magnitude, vec3(1.0 / 2.4)) - vec3(0.055), step(vec3(0.0031308), magnitude));
            float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            float x = clamp(y, 0.0, 1.0);
            vec4 c = c5;
            float t = (x - 0.94) / 0.06;
            if (x < 0.06) { c = c0; t = x / 0.06; }
            else if (x < 0.25) { c = c1; t = (x - 0.06) / 0.19; }
            else if (x < 0.50) { c = c2; t = (x - 0.25) / 0.25; }
            else if (x < 0.75) { c = c3; t = (x - 0.50) / 0.25; }
            else if (x < 0.94) { c = c4; t = (x - 0.75) / 0.19; }
            float target = clamp(((c.x * t + c.y) * t + c.z) * t + c.w, 0.0, 1.0);
            // Apply luminance without independently reshaping RGB channels.
            // Limit chroma to the available headroom instead of clipping a
            // channel. Existing extended-gamut colors retain their own bounds.
            float originalMinimum = min(min(rgb.r, rgb.g), rgb.b);
            float originalMaximum = max(max(rgb.r, rgb.g), rgb.b);
            // Keep one 8-bit code of headroom for previously unclipped RGB.
            // Otherwise a saturated subject lifted in a dark scene could hit
            // exactly white in one channel despite remaining inside the gamut.
            float lower = min(originalMinimum, 1.0 / 255.0);
            float upper = max(originalMaximum, 1.0 - 1.0 / 255.0);
            vec3 chroma = rgb - vec3(y);
            float gain = target / max(y, 0.000001);
            float maximum = max(max(chroma.r, chroma.g), chroma.b);
            float minimum = min(min(chroma.r, chroma.g), chroma.b);
            gain = min(gain, (upper - target) / max(maximum, 0.000001));
            gain = min(gain, (target - lower) / max(-minimum, 0.000001));
            vec3 adjusted = vec3(target) + max(gain, 0.0) * chroma;
            // A luminance already outside the display interval has no useful
            // histogram target; keep it instead of inventing clipped detail.
            if (y <= 0.0 || y >= 1.0) { adjusted = rgb; }
            magnitude = abs(adjusted);
            vec3 linear = sign(adjusted) * mix(magnitude / 12.92, pow((magnitude + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), magnitude));
            return premultiply(vec4(linear, o.a));
        }
        """)
}
