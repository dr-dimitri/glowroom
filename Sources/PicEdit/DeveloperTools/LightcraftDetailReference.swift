import Foundation
import PicEditCore

/// Isolated LC-04 CPU experiment. No app rendering path calls this adapter.
/// Adapted from Lightcraft local::{log_lum,plane_sigmas,guided_fast} and the
/// clarity/texture terms of finish::finish_with at
/// f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15. See the source/license inventory in
/// tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt.
struct LightcraftDetailReference: AlgorithmEvaluationReference, Sendable {
    enum Variant: String, CaseIterable, Codable, Sendable {
        case clarityGuidedLog, clarityGaussianLog
        case textureGaussianExistingDomain, textureGaussianLog, textureGaussianLogTamed

        var isClarity: Bool { self == .clarityGuidedLog || self == .clarityGaussianLog }
    }
    enum Failure: Error { case invalid(String) }

    let variant: Variant
    let nativeLong: Int?
    let pixelsPerLongEdge: Double?
    let sigmaOverride: Double?
    var id: String { "lightcraft-detail-\(variant.rawValue)" }

    init(variant: Variant = .clarityGuidedLog, nativeLong: Int? = nil,
         pixelsPerLongEdge: Double? = nil, sigmaOverride: Double? = nil) {
        self.variant = variant; self.nativeLong = nativeLong
        self.pixelsPerLongEdge = pixelsPerLongEdge; self.sigmaOverride = sigmaOverride
    }

    /// Immutable input snapshot, geometry and effect-specific planes. Strength
    /// never enters preparation. No decoder, mutable cache, UI state or second
    /// worker pool is introduced; the existing bounded LC-03 row pool is shared.
    struct Prepared: Sendable {
        let input: AlgorithmEvaluationRaster
        let signal: [Float]
        let base: [Float]
        let sigma: Float
        let pixelsPerLongEdge: Double
        let nativeLong: Int
        let variant: Variant
    }

    func prepare(_ input: AlgorithmEvaluationRaster) throws -> Prepared {
        try validate(input)
        let input = try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: input.pixels)
        let (native, scale, sigma) = try geometry(for: input)
        let signal = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
            for x in 0..<input.width {
                let p = (y * input.width + x) * 4
                guard input.pixels[p + 3] > 0 else { continue }
                if variant == .textureGaussianExistingDomain {
                    row[x] = min(1, max(0, Self.displayLuminance(input.pixels[p], input.pixels[p + 1], input.pixels[p + 2])))
                } else {
                    let rgb = AlgorithmEvaluationColorBridge.toRec2020(Double(input.pixels[p]), Double(input.pixels[p + 1]), Double(input.pixels[p + 2]))
                    let luminance = 0.2627 * Float(rgb.0) + 0.6780 * Float(rgb.1) + 0.0593 * Float(rgb.2)
                    row[x] = log2(max(luminance, 1e-7) / 0.18)
                }
            }
        }
        let plane = LightcraftToneFilters.Plane(width: input.width, height: input.height, values: signal)
        var coverage: LightcraftToneFilters.Plane?
        if stride(from: 3, to: input.pixels.count, by: 4).contains(where: { input.pixels[$0] < 1 }) {
            let alpha = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
                for x in 0..<input.width { row[x] = input.pixels[(y * input.width + x) * 4 + 3] }
            }
            coverage = .init(width: input.width, height: input.height, values: alpha)
        }
        let base: LightcraftToneFilters.Plane
        switch variant {
        case .clarityGuidedLog:
            base = try LightcraftToneFilters.guidedFast(plane, sigma: sigma, epsilon: 0.8, coverage: coverage)
        case .clarityGaussianLog, .textureGaussianLog, .textureGaussianLogTamed:
            base = try LightcraftToneFilters.gaussian(plane, sigma: sigma, coverage: coverage)
        case .textureGaussianExistingDomain:
            // The production kernel takes gamma-domain luminance AFTER blurring
            // linear RGB. Blurring luminance or gamma RGB would confound the
            // domain ablation. Channels remain serial because each Gaussian
            // already uses the bounded shared row pool; extra pools add memory.
            var values = [Float](repeating: 0, count: input.width * input.height)
            for (channel, weight) in [Float(0.2126), 0.7152, 0.0722].enumerated() {
                let channelValues = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
                    for x in 0..<input.width { row[x] = input.pixels[(y * input.width + x) * 4 + channel] }
                }
                let blurred = try LightcraftToneFilters.gaussian(.init(width: input.width, height: input.height, values: channelValues), sigma: sigma, coverage: coverage)
                let previous = values
                values = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
                    for x in 0..<input.width {
                        let i = y * input.width + x
                        row[x] = previous[i] + weight * pow(max(0, blurred.values[i]), 1 / 2.2)
                    }
                }
            }
            base = .init(width: input.width, height: input.height, values: values)
        }
        try LightcraftToneFilters.validate(base)
        return Prepared(input: input, signal: signal, base: base.values, sigma: sigma,
                        pixelsPerLongEdge: scale, nativeLong: native, variant: variant)
    }

    func apply(_ prepared: Prepared, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        let strength = try validatedStrength(settings)
        try Task.checkCancellation()
        let (native, scale, sigma) = try geometry(for: prepared.input)
        guard prepared.variant == variant, prepared.nativeLong == native,
              prepared.pixelsPerLongEdge == scale, prepared.sigma == sigma,
              prepared.signal.count == prepared.input.width * prepared.input.height,
              prepared.base.count == prepared.signal.count else {
            throw Failure.invalid("Prepared detail variant/geometry does not match reference")
        }
        if strength == 0 { return prepared.input }
        let input = prepared.input
        let output = try LightcraftToneFilters.rows(width: input.width * 4, height: input.height) { y, row in
            for x in 0..<input.width {
                let i = y * input.width + x, p = i * 4, out = x * 4, alpha = input.pixels[p + 3]
                row[out + 3] = alpha
                guard alpha > 0 else { continue }
                let detail = prepared.signal[i] - prepared.base[i]
                if variant == .textureGaussianExistingDomain {
                    let delta = strength * 0.90 * detail
                    for channel in 0..<3 {
                        let display = pow(max(0, input.pixels[p + channel]), 1 / Float(2.2))
                        row[out + channel] = pow(min(1, max(0, display + delta)), 2.2)
                    }
                } else {
                    let delta: Float
                    if variant.isClarity {
                        // With isolated clarity, upstream has no tone-base
                        // plane: local::prepare falls back to log_l. Its mid
                        // weight therefore uses the original signal, not the
                        // guided clarity blur. External tone changes require a
                        // new prepared input in the stage-order experiment.
                        let mid = exp(-pow(prepared.signal[i] / 3.2, 2))
                        delta = strength * 0.85 * min(2.5, max(-2.5, detail)) * (0.35 + 0.65 * mid)
                    } else if variant == .textureGaussianLogTamed {
                        let tame = 1 - 0.6 * Self.smooth(0.4, 1.6, abs(detail))
                        delta = strength * 1.1 * min(1, max(-1, detail)) * tame
                    } else {
                        delta = strength * 1.1 * detail
                    }
                    let gain = delta == 0 ? Float(1) : exp2(delta)
                    for channel in 0..<3 { row[out + channel] = input.pixels[p + channel] * gain }
                }
            }
        }
        try Task.checkCancellation()
        return try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: output)
    }

    func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        let strength = try validatedStrength(settings)
        try validate(input)
        _ = try geometry(for: input)
        if strength == 0 {
            // Both signs of zero are exactly neutral, with no spatial planes.
            return try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: input.pixels)
        }
        return try apply(prepare(input), settings: settings)
    }

    private func geometry(for input: AlgorithmEvaluationRaster) throws -> (Int, Double, Float) {
        let native = nativeLong ?? max(input.width, input.height)
        let scale = pixelsPerLongEdge ?? Double(max(input.width, input.height))
        guard native > 0, native <= 1_000_000, scale.isFinite, scale > 0, scale <= 1_000_000,
              sigmaOverride.map({ $0.isFinite && $0 > 0 && $0 <= 65_536 }) ?? true else {
            throw Failure.invalid("Invalid native/output detail geometry")
        }
        // Upstream converts px_per_long to f32 before radius multiplication;
        // keep that order because one ULP may change a box/subsampling boundary.
        let sigma = sigmaOverride.map(Float.init)
            ?? (variant.isClarity ? max(1, 0.012 * Float(scale)) : max(0.6, 0.0018 * Float(scale)))
        guard sigma > 0 else { throw Failure.invalid("Detail sigma underflows Float32") }
        return (native, scale, sigma)
    }

    private func validatedStrength(_ s: EditSettings) throws -> Float {
        let active = variant.isClarity ? s.clarity : s.texture
        let inactive = variant.isClarity ? s.texture : s.clarity
        guard active.isFinite,
              [inactive, s.exposure, s.contrast, s.highlights, s.shadows, s.whites, s.blacks,
               s.dehaze, s.vibrance, s.saturation, s.luminanceNoiseReduction,
               s.colorNoiseReduction, s.autoToneAmount].allSatisfy({ $0 == 0 }) else {
            throw Failure.invalid("Detail reference accepts only its finite Clarity or Texture control")
        }
        return Float(min(100, max(-100, active)) / 100)
    }

    private func validate(_ input: AlgorithmEvaluationRaster) throws {
        guard input.width > 0, input.height > 0, input.width <= 16_384, input.height <= 16_384,
              input.width * input.height <= 32 * 1_024 * 1_024,
              input.pixels.count == input.width * input.height * 4, input.pixels.allSatisfy(\.isFinite),
              stride(from: 3, to: input.pixels.count, by: 4).allSatisfy({ (0...1).contains(input.pixels[$0]) }) else {
            throw Failure.invalid("Invalid detail raster")
        }
        try Task.checkCancellation()
    }

    private static func displayLuminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * pow(max(0, r), 1 / Float(2.2)) + 0.7152 * pow(max(0, g), 1 / Float(2.2)) + 0.0722 * pow(max(0, b), 1 / Float(2.2))
    }

    private static func smooth(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}
