import Foundation
import GlowroomCore

/// Isolated CPU experiment, never called by the app's image pipeline. Adapted
/// from Lightcraft's local::{log_lum,tone_base,plane_sigmas} and the highlights /
/// shadows terms in finish::finish_with, commit
/// f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15. No global tone map, camera profile,
/// highlight desaturation, gamut map, display transfer or other local effect is
/// included. Source/license inventory:
/// tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt.
struct LightcraftToneReference: AlgorithmEvaluationReference, Sendable {
    enum Process: String, Codable, Sendable { case v1, v2 }
    enum Failure: Error { case invalid(String) }

    let process: Process
    let nativeLong: Int?
    let pixelsPerLongEdge: Double?
    var id: String { "lightcraft-tone-\(process.rawValue)" }

    init(process: Process = .v2, nativeLong: Int? = nil, pixelsPerLongEdge: Double? = nil) {
        self.process = process; self.nativeLong = nativeLong; self.pixelsPerLongEdge = pixelsPerLongEdge
    }

    /// Immutable per-input preparation is the cache boundary. Slider strength
    /// and exposure are deliberately absent: a constant EV offset commutes with
    /// these spatial filters and is added by apply. Each object owns its input,
    /// dimensions, process and geometry, so it cannot attach an old plane to a
    /// new image. No mutable global cache or decoded image is retained.
    struct Prepared: Sendable {
        let input: AlgorithmEvaluationRaster
        let logLuminance: [Float]
        let base: [Float]
        let sigma: Float
        let detailRadius: Int
        let pixelsPerLongEdge: Double
        let nativeLong: Int
        let process: Process
    }

    /// Input is already developed and oriented, before manual exposure. The
    /// native long edge identifies source scale; pixelsPerLongEdge is the number
    /// of output pixels spanning the original long edge (including a crop's
    /// zoom). An uncropped preview defaults to max(output width, output height).
    /// The source's tone radii depend on that output geometry, not native pixels.
    func prepare(_ input: AlgorithmEvaluationRaster) throws -> Prepared {
        try validate(input)
        let input = try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: input.pixels)
        let (native, outputScale) = try geometry(for: input)
        let sigma = max(1, 0.015 * Float(outputScale))
        let detail = process == .v1 ? 0 : min(24, Int((0.0015 * outputScale).rounded(.toNearestOrAwayFromZero)))
        let log = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
            for x in 0..<input.width {
                let p = (y * input.width + x) * 4
                guard input.pixels[p + 3] > 0 else { row[x] = 0; continue }
                let rgb = AlgorithmEvaluationColorBridge.toRec2020(Double(input.pixels[p]), Double(input.pixels[p + 1]), Double(input.pixels[p + 2]))
                let r = Float(rgb.0), g = Float(rgb.1), b = Float(rgb.2)
                // Use the original Rec.2020 Float weights and EV floor. Signed
                // channels survive; the logarithm alone floors nonpositive Y.
                let luminance = 0.2627 * r + 0.6780 * g + 0.0593 * b
                row[x] = log2(max(luminance, 1e-7) / 0.18)
            }
        }
        let plane = LightcraftToneFilters.Plane(width: input.width, height: input.height, values: log)
        var coverage: LightcraftToneFilters.Plane?
        if stride(from: 3, to: input.pixels.count, by: 4).contains(where: { input.pixels[$0] < 1 }) {
            let alpha = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
                for x in 0..<input.width { row[x] = input.pixels[(y * input.width + x) * 4 + 3] }
            }
            coverage = LightcraftToneFilters.Plane(width: input.width, height: input.height, values: alpha)
        }
        // RGB-only upstream has no alpha semantics. Here every median is
        // coverage-weighted, means/correlations and resampling are normalized by
        // coverage, and absent support yields zero. Hidden RGB cannot contribute.
        let base = try LightcraftToneFilters.toneBase(plane, sigma: sigma, detail: detail, coverage: coverage)
        try LightcraftToneFilters.validate(base)
        return Prepared(input: input, logLuminance: log, base: base.values, sigma: sigma,
                        detailRadius: detail, pixelsPerLongEdge: outputScale, nativeLong: native, process: process)
    }

    func apply(_ prepared: Prepared, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        let normalized = try validatedSettings(settings)
        try Task.checkCancellation()
        guard prepared.process == process,
              nativeLong.map({ $0 == prepared.nativeLong }) ?? true,
              pixelsPerLongEdge.map({ $0 == prepared.pixelsPerLongEdge }) ?? true,
              prepared.base.count == prepared.input.width * prepared.input.height else {
            throw Failure.invalid("Prepared tone process/geometry does not match reference")
        }
        if normalized.exposure == 0, normalized.shadows == 0, normalized.highlights == 0 { return prepared.input }
        let input = prepared.input
        let shadow = Float(normalized.shadows / 100), highlight = Float(normalized.highlights / 100)
        let exposure = Float(normalized.exposure), exposureGain = exp2(exposure)
        let output = try LightcraftToneFilters.rows(width: input.width * 4, height: input.height) { y, row in
            for x in 0..<input.width {
                let i = y * input.width + x, p = i * 4, out = x * 4, alpha = input.pixels[p + 3]
                row[out + 3] = alpha
                guard alpha > 0 else { continue }
                let base = prepared.base[i] + exposure
                let ws = 1 - Self.smooth(-4.8, 0.3, base)
                let wh = Self.smooth(-1, 2.8, base)
                let delta = shadow * 1.7 * ws * ws.squareRoot() + highlight * 1.7 * wh
                let localGain = delta == 0 ? Float(1) : exp2(delta)
                for channel in 0..<3 {
                    // A scalar Rec.2020 gain commutes with the linear bridge;
                    // applying it to the original RGB avoids a needless inverse
                    // matrix and preserves signed and extended-range colour.
                    let exposed = exposureGain == 1 ? input.pixels[p + channel] : input.pixels[p + channel] * exposureGain
                    row[out + channel] = localGain == 1 ? exposed : exposed * localGain
                }
            }
        }
        try Task.checkCancellation()
        return try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: output)
    }

    func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        let normalized = try validatedSettings(settings)
        try validate(input)
        _ = try geometry(for: input)
        if normalized.isNeutral {
            // Neutral controls must remain exact and do not need any spatial
            // planes. Still canonicalize potentially mutated invisible RGB.
            return try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: input.pixels)
        }
        return try apply(prepare(input), settings: settings)
    }

    private func geometry(for input: AlgorithmEvaluationRaster) throws -> (Int, Double) {
        let native = nativeLong ?? max(input.width, input.height)
        let outputScale = pixelsPerLongEdge ?? Double(max(input.width, input.height))
        guard native > 0, native <= 1_000_000, outputScale.isFinite, outputScale > 0,
              outputScale <= 1_000_000 else { throw Failure.invalid("Invalid native/output tone geometry") }
        return (native, outputScale)
    }

    private static func smooth(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    private func validatedSettings(_ s: EditSettings) throws -> EditSettings {
        guard [s.exposure, s.shadows, s.highlights].allSatisfy(\.isFinite),
              [s.contrast, s.whites, s.blacks, s.texture, s.clarity, s.dehaze,
               s.vibrance, s.saturation, s.luminanceNoiseReduction, s.colorNoiseReduction,
               s.autoToneAmount, s.naturalBalanceAmount].allSatisfy({ $0 == 0 }) else {
            throw Failure.invalid("Tone reference accepts finite Exposure/Shadows/Highlights only")
        }
        return s.normalized
    }

    private func validate(_ input: AlgorithmEvaluationRaster) throws {
        // Raster pixels are mutable for existing evaluation helpers, so validate
        // again at this boundary instead of trusting their original initializer.
        guard input.width > 0, input.height > 0, input.width <= 16_384, input.height <= 16_384,
              input.width * input.height <= 32 * 1_024 * 1_024,
              input.pixels.count == input.width * input.height * 4,
              input.pixels.allSatisfy(\.isFinite),
              stride(from: 3, to: input.pixels.count, by: 4).allSatisfy({ (0...1).contains(input.pixels[$0]) }) else {
            throw Failure.invalid("Invalid tone raster")
        }
        try Task.checkCancellation()
    }
}
