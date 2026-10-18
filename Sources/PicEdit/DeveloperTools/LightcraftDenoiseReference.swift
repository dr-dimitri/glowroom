import Foundation
import PicEditCore

/// Isolated LC-06 CPU reference, adapted from Lightcraft local::{detail_scale,
/// nr_radius,nr_params,apply_nr,log_lum,guided} at f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15.
/// Provenance and intentional alpha/sampling adaptations are in
/// tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt. No production renderer calls this.
struct LightcraftDenoiseReference: AlgorithmEvaluationReference, Sendable {
    enum Control: String, CaseIterable, Codable, Sendable { case luminance, chroma }
    enum InputSampling: String, CaseIterable, Codable, Sendable { case native, areaAveraged, unknown }
    enum Scaling: String, CaseIterable, Codable, Sendable { case nativePixels, unscaled }
    enum Failure: Error { case invalid(String) }
    struct Geometry: Codable, Equatable, Sendable {
        let nativeLong: Int
        /// Output pixels covering the WHOLE original long edge, not tile/crop width.
        let pixelsPerLongEdge: Double
        let inputSampling: InputSampling
    }
    struct Parameters: Codable, Equatable, Sendable {
        let radiusScale: Float
        let epsilonScale: Float
        let sigma: Float?
        let epsilon: Float?
        let blend: Float
    }

    let control: Control
    let geometry: Geometry
    let scaling: Scaling
    var id: String { "lightcraft-denoise-\(control.rawValue)-\(scaling.rawValue)" }

    init(control: Control, geometry: Geometry, scaling: Scaling = .nativePixels) {
        self.control = control; self.geometry = geometry; self.scaling = scaling
    }

    /// The three unexposed upstream controls nr_detail, nr_color_detail and
    /// nr_color_smoothness are fixed at 50. nr_contrast has no effect upstream
    /// and is neither exposed nor invented here.
    func parameters(amount: Double) throws -> Parameters {
        guard amount.isFinite, geometry.nativeLong > 0, geometry.nativeLong <= 1_000_000,
              geometry.pixelsPerLongEdge.isFinite, geometry.pixelsPerLongEdge > 0,
              geometry.pixelsPerLongEdge <= 1_000_000 else {
            throw Failure.invalid("Invalid denoise amount or full-image geometry")
        }
        let geometric = Self.detailScale(pixelsPerLongEdge: geometry.pixelsPerLongEdge, nativeLong: geometry.nativeLong)
        guard geometry.inputSampling != .native || geometric == 1 else {
            throw Failure.invalid("Native samples require one output pixel per native pixel; crop size is not full-image scale")
        }
        let scale: Float = scaling == .unscaled ? 1 : geometric
        // Radius has a geometric meaning even for unknown decoder sampling.
        // Variance scaling assumes area averaging; unknown inputs must not
        // silently claim the associated reduction of noise variance.
        let epsilonScale: Float = scaling == .nativePixels && geometry.inputSampling == .areaAveraged ? scale : 1
        let amount = Float(min(100, max(0, amount)) / 100)
        guard amount > 0 else { return .init(radiusScale: scale, epsilonScale: epsilonScale, sigma: nil, epsilon: nil, blend: 0) }
        let rawSigma: Float = control == .luminance ? (1 + 2.5 * amount) * scale : (1.5 + 6 * amount) * scale * 1.5
        let (sigma, weight) = Self.nrRadius(rawSigma)
        guard weight >= 0.01 else { return .init(radiusScale: scale, epsilonScale: epsilonScale, sigma: nil, epsilon: nil, blend: 0) }
        if control == .luminance {
            let epsilon = max(1e-7, (0.002 + amount * amount * 0.25 * (1 - 0.7 * 0.5)) * epsilonScale * epsilonScale)
            return .init(radiusScale: scale, epsilonScale: epsilonScale, sigma: sigma, epsilon: epsilon, blend: amount.squareRoot() * weight)
        }
        return .init(radiusScale: scale, epsilonScale: epsilonScale, sigma: sigma, epsilon: nil, blend: amount * (1 - 0.5 * 0.5) * weight)
    }

    static func detailScale(pixelsPerLongEdge: Double, nativeLong: Int) -> Float {
        let value = Float(pixelsPerLongEdge / Double(max(1, nativeLong)))
        return value.isFinite ? min(1, max(0, value)) : 1
    }

    static func nrRadius(_ sigma: Float) -> (sigma: Float, weight: Float) {
        if sigma >= 1 { return (sigma, 1) }
        let made = LightcraftToneFilters.boxRadii(sigma: 1).reduce(Float(0)) { sum, radius in
            let width = 2 * radius + 1
            return sum + Float(width * width - 1) / 12
        }.squareRoot()
        let ratio = sigma / made
        return (1, min(1, ratio * ratio))
    }

    func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        let amount = try validatedAmount(settings)
        let params = try parameters(amount: amount)
        try validate(input)
        if params.sigma == nil {
            // Both exact zero and the original <1% subpixel fade retain the
            // canonical raster, avoiding a needless colour-space round trip.
            return try .init(width: input.width, height: input.height, pixels: input.pixels)
        }
        let working = try LightcraftToneFilters.rows(width: input.width * 3, height: input.height) { y, row in
            for x in 0..<input.width {
                let p = (y * input.width + x) * 4
                guard input.pixels[p + 3] > 0 else { continue }
                let rgb = AlgorithmEvaluationColorBridge.toRec2020(Double(input.pixels[p]), Double(input.pixels[p + 1]), Double(input.pixels[p + 2]))
                row[x * 3] = Float(rgb.0); row[x * 3 + 1] = Float(rgb.1); row[x * 3 + 2] = Float(rgb.2)
            }
        }
        let coverage: [Float]?
        if stride(from: 3, to: input.pixels.count, by: 4).contains(where: { input.pixels[$0] < 1 }) {
            coverage = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
                for x in 0..<input.width { row[x] = input.pixels[(y * input.width + x) * 4 + 3] }
            }
        } else { coverage = nil }
        let filtered = try Self.applyRec2020(working, width: input.width, height: input.height,
                                            control: control, parameters: params, coverage: coverage)
        let result = try LightcraftToneFilters.rows(width: input.width * 4, height: input.height) { y, row in
            for x in 0..<input.width {
                let i = y * input.width + x, alpha = input.pixels[i * 4 + 3]
                row[x * 4 + 3] = alpha
                guard alpha > 0 else { continue }
                let rgb = AlgorithmEvaluationColorBridge.fromRec2020(Double(filtered[i * 3]), Double(filtered[i * 3 + 1]), Double(filtered[i * 3 + 2]))
                row[x * 4] = Float(rgb.0); row[x * 4 + 1] = Float(rgb.1); row[x * 4 + 2] = Float(rgb.2)
            }
        }
        try Task.checkCancellation()
        return try .init(width: input.width, height: input.height, pixels: result)
    }

    /// Original opaque Rec.2020 operation, exposed internally for independent
    /// source-oracle tests. The optional coverage is a PicEdit adaptation.
    /// Luma precedes chroma when composing the two isolated adapters.
    static func applyRec2020(_ input: [Float], width: Int, height: Int, control: Control,
                             parameters: Parameters, coverage: [Float]? = nil) throws -> [Float] {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 32 * 1_024 * 1_024,
              input.count == width * height * 3, input.allSatisfy(\.isFinite),
              coverage.map({ $0.count == width * height && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) ?? true,
              parameters.blend.isFinite, (0...1).contains(parameters.blend),
              parameters.sigma.map({ $0.isFinite && $0 >= 1 }) ?? (parameters.blend == 0) else {
            throw Failure.invalid("Invalid Rec.2020 denoise input/parameters")
        }
        try Task.checkCancellation()
        guard let sigma = parameters.sigma else { return input }
        let alpha = coverage.map { LightcraftToneFilters.Plane(width: width, height: height, values: $0) }
        let luminance = try LightcraftToneFilters.rows(width: width, height: height) { y, row in
            for x in 0..<width {
                let i = y * width + x
                guard coverage?[i] != 0 else { continue }
                row[x] = 0.2627 * input[i * 3] + 0.6780 * input[i * 3 + 1] + 0.0593 * input[i * 3 + 2]
            }
        }
        if control == .luminance {
            guard let epsilon = parameters.epsilon, epsilon.isFinite, epsilon > 0 else { throw Failure.invalid("Invalid NR epsilon") }
            let signal = try LightcraftToneFilters.rows(width: width, height: height) { y, row in
                for x in 0..<width {
                    let i = y * width + x
                    guard coverage?[i] != 0 else { continue }
                    row[x] = log2(max(luminance[i], 1e-7) / 0.18)
                }
            }
            let filtered = try guided(.init(width: width, height: height, values: signal), sigma: sigma, epsilon: epsilon, coverage: alpha)
            return try LightcraftToneFilters.rows(width: width * 3, height: height) { y, row in
                for x in 0..<width {
                    let i = y * width + x
                    guard coverage?[i] != 0 else { continue }
                    let gain = exp2((filtered.values[i] - signal[i]) * parameters.blend)
                    for channel in 0..<3 { row[x * 3 + channel] = input[i * 3 + channel] * gain }
                }
            }
        }
        // Channels stay serial: each Gaussian already uses the shared bounded
        // row pool. Extra outer workers would multiply planes and oversubscribe.
        var channels: [[Float]] = []
        for channel in 0..<3 {
            let chroma = try LightcraftToneFilters.rows(width: width, height: height) { y, row in
                for x in 0..<width {
                    let i = y * width + x
                    guard coverage?[i] != 0 else { continue }
                    row[x] = input[i * 3 + channel] / max(luminance[i], 1e-6)
                }
            }
            let blurred = try LightcraftToneFilters.gaussian(.init(width: width, height: height, values: chroma), sigma: sigma, coverage: alpha)
            let result = try LightcraftToneFilters.rows(width: width, height: height) { y, row in
                for x in 0..<width {
                    let i = y * width + x
                    guard coverage?[i] != 0 else { continue }
                    row[x] = max(0, (chroma[i] + (blurred.values[i] - chroma[i]) * parameters.blend) * luminance[i])
                }
            }
            channels.append(result)
        }
        let outputChannels = channels
        return try LightcraftToneFilters.rows(width: width * 3, height: height) { y, row in
            for x in 0..<width {
                let i = y * width + x
                for channel in 0..<3 { row[x * 3 + channel] = outputChannels[channel][i] }
            }
        }
    }

    /// Full-resolution self-guided filter. Never substitutes guided_fast:
    /// even its coefficient subsampling would change the NR edge response.
    private static func guided(_ p: LightcraftToneFilters.Plane, sigma: Float, epsilon: Float,
                               coverage: LightcraftToneFilters.Plane?) throws -> LightcraftToneFilters.Plane {
        typealias Filters = LightcraftToneFilters
        func plane(_ values: [Float]) -> Filters.Plane { .init(width: p.width, height: p.height, values: values) }
        let mean = try Filters.gaussian(p, sigma: sigma, coverage: coverage)
        let squared = try Filters.rows(width: p.width, height: p.height) { y, row in
            for x in 0..<p.width { let v = p.values[y * p.width + x]; row[x] = v * v }
        }
        let correlation = try Filters.gaussian(plane(squared), sigma: sigma, coverage: coverage)
        let a = try Filters.rows(width: p.width, height: p.height) { y, row in
            for x in 0..<p.width {
                let i = y * p.width + x, m = mean.values[i], variance = max(0, correlation.values[i] - m * m)
                row[x] = variance / (variance + epsilon)
            }
        }
        let b = try Filters.rows(width: p.width, height: p.height) { y, row in
            for x in 0..<p.width { let i = y * p.width + x; row[x] = mean.values[i] - a[i] * mean.values[i] }
        }
        let meanA = try Filters.gaussian(plane(a), sigma: sigma, coverage: coverage)
        let meanB = try Filters.gaussian(plane(b), sigma: sigma, coverage: coverage)
        let output = try Filters.rows(width: p.width, height: p.height) { y, row in
            for x in 0..<p.width { let i = y * p.width + x; row[x] = meanA.values[i] * p.values[i] + meanB.values[i] }
        }
        return plane(output)
    }

    private func validatedAmount(_ s: EditSettings) throws -> Double {
        let active = control == .luminance ? s.luminanceNoiseReduction : s.colorNoiseReduction
        let inactive = control == .luminance ? s.colorNoiseReduction : s.luminanceNoiseReduction
        guard active.isFinite, [inactive, s.exposure, s.contrast, s.highlights, s.shadows, s.whites, s.blacks,
            s.texture, s.clarity, s.dehaze, s.vibrance, s.saturation, s.autoToneAmount, s.naturalBalanceAmount].allSatisfy({ $0 == 0 }) else {
            throw Failure.invalid("Denoise reference accepts only its finite Luminance or Color NR control")
        }
        return active
    }
    private func validate(_ input: AlgorithmEvaluationRaster) throws {
        guard input.width > 0, input.height > 0, input.width <= 16_384, input.height <= 16_384,
              input.width * input.height <= 32 * 1_024 * 1_024,
              input.pixels.count == input.width * input.height * 4, input.pixels.allSatisfy(\.isFinite),
              stride(from: 3, to: input.pixels.count, by: 4).allSatisfy({ (0...1).contains(input.pixels[$0]) }) else {
            throw Failure.invalid("Invalid denoise raster")
        }
        try Task.checkCancellation()
    }
}
