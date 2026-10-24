import Foundation
import GlowroomCore

/// Independent experiment inspired by multiscale regularization, not a port of
/// darktable's GPL implementation. No production entry point uses this type.
enum DarktableSharpenReference {
    typealias Raster = AlgorithmEvaluationRaster
    typealias Plane = LightcraftToneFilters.Plane
    enum Variant: String, CaseIterable, Codable, Sendable { case multiscale, diffusion }
    enum Failure: Error { case invalid }
    struct Prepared: Sendable {
        let input: Raster
        let signal: [Float]
        let residual: [Float]
        let mask: [Float]
        let detail: Float
    }

    static func prepare(_ input: Raster, variant: Variant, radius: Double = 1,
                        detail: Double = 25, masking: Double = 0, scale: Double = 1) throws -> Prepared {
        guard radius.isFinite, (0.5...3).contains(radius), detail.isFinite, (0...100).contains(detail),
              masking.isFinite, (0...100).contains(masking), scale.isFinite, (0...1).contains(scale), scale > 0 else { throw Failure.invalid }
        // Raster's public pixel storage can be changed after initialization.
        let input = try Raster(width: input.width, height: input.height, pixels: input.pixels)
        let w = input.width, h = input.height
        let signal = try LightcraftToneFilters.rows(width: w, height: h) { y, row in
            for x in 0..<w {
                let p = (y * w + x) * 4
                if input.pixels[p + 3] > 0 {
                    let v = 0.2126 * input.pixels[p] + 0.7152 * input.pixels[p + 1] + 0.0722 * input.pixels[p + 2]
                    row[x] = log2(max(v, 0.0001))
                }
            }
        }
        let alpha = (0..<(w * h)).map { input.pixels[$0 * 4 + 3] }
        let sigma = Float(radius * scale)
        let fine = try blur(signal, width: w, height: h, sigma: sigma, alpha: alpha)
        let coarse = try blur(signal, width: w, height: h, sigma: 2 * sigma, alpha: alpha)
        var residual: [Float]
        switch variant {
        case .multiscale:
            residual = try LightcraftToneFilters.rows(width: w, height: h) { y, row in
                for x in 0..<w {
                    let i = y * w + x, band = fine[i] - coarse[i]
                    row[x] = (signal[i] - fine[i] + 0.35 * band) / (1 + abs(band) / 0.15)
                }
            }
        case .diffusion:
            // Three explicit inverse Gaussian diffusion steps. Fixed guide
            // regularization is independent of strength; no noise estimator or
            // denoising stage can silently contribute to the comparison.
            var current = signal
            for _ in 0..<3 {
                try Task.checkCancellation()
                let smoothed = try blur(current, width: w, height: h, sigma: sigma, alpha: alpha)
                let previous = current
                current = try LightcraftToneFilters.rows(width: w, height: h) { y, row in
                    for x in 0..<w {
                        let i = y * w + x
                        let dx = coarse[y * w + min(w - 1, x + 1)] - coarse[y * w + max(0, x - 1)]
                        let dy = coarse[min(h - 1, y + 1) * w + x] - coarse[max(0, y - 1) * w + x]
                        let conductance = 1 / (1 + (dx * dx + dy * dy) / (0.4 * 0.4))
                        row[x] = previous[i] + min(0.125, max(-0.125, 0.25 * conductance * (previous[i] - smoothed[i])))
                    }
                }
            }
            residual = zip(current, signal).map { $0.0 - $0.1 }
        }
        var mask = [Float](repeating: 1, count: w * h)
        if masking > 0 {
            let guide = try blur(signal, width: w, height: h, sigma: Float(0.5 * scale), alpha: alpha)
            // Source-pixel offsets become fractional at preview resolutions.
            // Bilinear interpolation keeps the candidate's mask scale contract.
            mask = try LightcraftToneFilters.rows(width: w, height: h) { y, row in
                for x in 0..<w {
                    let dx = sample(guide, width: w, height: h, x: Double(x) + scale, y: Double(y)) - sample(guide, width: w, height: h, x: Double(x) - scale, y: Double(y))
                    let dy = sample(guide, width: w, height: h, x: Double(x), y: Double(y) + scale) - sample(guide, width: w, height: h, x: Double(x), y: Double(y) - scale)
                    row[x] = smooth(Float(masking / 100 * 0.8), Float(masking / 100 * 0.8 + 0.15), 0.5 * sqrt(dx * dx + dy * dy))
                }
            }
        }
        return Prepared(input: input, signal: signal, residual: residual, mask: mask, detail: Float(detail / 100))
    }

    static func apply(_ prepared: Prepared, amount: Double) throws -> Raster {
        guard amount.isFinite, (0...6).contains(amount) else { throw Failure.invalid }
        try Task.checkCancellation()
        if amount == 0 { return prepared.input }
        let input = prepared.input, w = input.width
        let output = try LightcraftToneFilters.rows(width: w * 4, height: input.height) { y, row in
            for x in 0..<w {
                let i = y * w + x, p = i * 4, o = x * 4
                row[o + 3] = input.pixels[p + 3]
                guard row[o + 3] > 0 else { continue }
                let r = prepared.residual[i]
                let threshold = max(0.000001, 0.12 * pow(1 - prepared.detail, 2))
                let gain = exp2(min(0.5, max(-0.5, Float(amount) * r * smooth(0, threshold, abs(r)) * prepared.mask[i])))
                for c in 0..<3 { row[o + c] = input.pixels[p + c] * gain }
            }
        }
        return try Raster(width: w, height: input.height, pixels: output)
    }

    private static func sample(_ values: [Float], width w: Int, height h: Int, x: Double, y: Double) -> Float {
        let xx = min(Double(w - 1), max(0, x)), yy = min(Double(h - 1), max(0, y))
        let x0 = Int(xx), y0 = Int(yy), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
        let fx = Float(xx - Double(x0)), fy = Float(yy - Double(y0))
        return (1 - fy) * ((1 - fx) * values[y0 * w + x0] + fx * values[y0 * w + x1])
            + fy * ((1 - fx) * values[y1 * w + x0] + fx * values[y1 * w + x1])
    }
    static func smooth(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    /// Own exact separable Gaussian; no copied GPL taps/implementation. Only
    /// the existing MIT bounded row scheduler is shared with other experiments.
    static func blur(_ values: [Float], width: Int, height: Int, sigma: Float, alpha: [Float]) throws -> [Float] {
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000,
              values.count == width * height, alpha.count == values.count, sigma.isFinite, sigma > 0, sigma <= 6,
              values.allSatisfy(\.isFinite), alpha.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalid }
        let radius = max(1, Int(ceil(3.5 * sigma)))
        let weights = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +), taps = weights.map { $0 / total }
        func convolution(_ source: [Float]) throws -> [Float] {
            let horizontal = try LightcraftToneFilters.rows(width: width, height: height) { y, row in
                for x in 0..<width {
                    var sum: Float = 0
                    for k in -radius...radius { sum += taps[k + radius] * source[y * width + min(width - 1, max(0, x + k))] }
                    row[x] = sum
                }
            }
            return try LightcraftToneFilters.rows(width: width, height: height) { y, row in
                for x in 0..<width {
                    var sum: Float = 0
                    for k in -radius...radius { sum += taps[k + radius] * horizontal[min(height - 1, max(0, y + k)) * width + x] }
                    row[x] = sum
                }
            }
        }
        if alpha.allSatisfy({ $0 == 1 }) { return try convolution(values) }
        let coverage = try convolution(alpha)
        let weighted = try convolution(zip(values, alpha).map { $0.0 * $0.1 })
        return zip(weighted, coverage).map { $0.1 > 1e-12 ? $0.0 / $0.1 : 0 }
    }
}
