import Foundation
import GlowroomCore

/// Developer-only LC-05 reference for ColorOps' saturation/vibrance subset at
/// Lightcraft f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15. The explicit output policy
/// either preserves raw signed RGB or applies the upstream destination gamut
/// mapper for SDR sRGB. No tone map, mixer, grading, profiles or app graph changes.
/// Provenance: tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt.
struct LightcraftColorReference: AlgorithmEvaluationReference, Sendable {
    enum OutputPolicy: String, CaseIterable, Codable, Sendable {
        case gamutMappedSRGB, unbounded
    }
    enum Failure: Error { case invalid(String) }

    let outputPolicy: OutputPolicy
    var id: String { "lightcraft-color-\(outputPolicy.rawValue)" }

    init(outputPolicy: OutputPolicy = .gamutMappedSRGB) { self.outputPolicy = outputPolicy }

    func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        let (vibrance, saturation) = try validatedControls(settings)
        try validate(input)
        if vibrance == 0, saturation == 0 {
            // A round trip or destination gamut map would alter signed/P3 input
            // at zero. Both policies retain the existing exact identity branch.
            return try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: input.pixels)
        }
        let output = try LightcraftToneFilters.rows(width: input.width * 4, height: input.height) { y, row in
            for x in 0..<input.width {
                let p = (y * input.width + x) * 4, out = x * 4, alpha = input.pixels[p + 3]
                row[out + 3] = alpha
                guard alpha > 0 else { continue }
                let working = AlgorithmEvaluationColorBridge.toRec2020(Double(input.pixels[p]), Double(input.pixels[p + 1]), Double(input.pixels[p + 2]))
                let adjusted = Self.applyRec2020(SIMD3(Float(working.0), Float(working.1), Float(working.2)), vibrance: vibrance, saturation: saturation)
                let destination = AlgorithmEvaluationColorBridge.fromRec2020(Double(adjusted.x), Double(adjusted.y), Double(adjusted.z))
                var rgb = SIMD3(Float(destination.0), Float(destination.1), Float(destination.2))
                if outputPolicy == .gamutMappedSRGB { rgb = Self.gamutMapSRGB(rgb).rgb }
                row[out] = rgb.x; row[out + 1] = rgb.y; row[out + 2] = rgb.z
            }
        }
        try Task.checkCancellation()
        return try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: output)
    }

    /// Normalized finite controls, matching the original chroma-only fast path.
    /// Signed cube roots deliberately preserve negative LMS. No implicit max(0)
    /// occurs at the Rec.2020/OkLab boundaries, including near black.
    static func applyRec2020(_ rgb: SIMD3<Float>, vibrance: Float, saturation: Float) -> SIMD3<Float> {
        if vibrance == 0, saturation == 0 { return rgb }
        var lab = rec2020ToOKLab(rgb)
        let initialChroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var chroma = initialChroma
        if vibrance != 0 {
            let low = 1 - min(1, max(0, chroma / 0.22))
            var skin: Float = 1
            if vibrance > 0 {
                let hueDistance = wrap(atan2(lab.z, lab.y) - skinHue) / 0.35
                skin = 1 - 0.6 * exp(-(hueDistance * hueDistance))
            }
            chroma *= max(0, 1 + vibrance * low * low * skin * 1.2)
        }
        if saturation != 0 { chroma *= max(0, 1 + saturation) }
        if initialChroma > 0 {
            let gain = chroma / initialChroma
            lab.y *= gain; lab.z *= gain
        }
        return oklabToRec2020(lab)
    }

    static func rec2020ToOKLab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let lms = toLMS.apply(rgb)
        return toLab.apply(SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z)))
    }

    static func oklabToRec2020(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let lms = fromLab.apply(lab)
        return fromLMS.apply(SIMD3(lms.x * lms.x * lms.x, lms.y * lms.y * lms.y, lms.z * lms.z * lms.z))
    }

    /// Original finish::gamut_map_to with OutputSpace::Srgb luma and peak=1.
    /// This explicit output operation reduces chroma toward clamped luminance;
    /// it is not a per-channel clamp and is not part of raw ColorOps::apply.
    /// Float rounding may leave an endpoint a few ULP outside [0,1], as upstream.
    static func gamutMapSRGB(_ rgb: SIMD3<Float>) -> (rgb: SIMD3<Float>, chromaScale: Float) {
        let luminance = min(1, max(0, 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z))
        var scale: Float = 1
        for index in 0..<3 {
            let channel = rgb[index]
            if channel < 0 { scale = min(scale, luminance / max(1e-9, luminance - channel)) }
            else if channel > 1 { scale = min(scale, (1 - luminance) / max(1e-9, channel - luminance)) }
        }
        if scale < 1 {
            return (SIMD3(luminance + (rgb.x - luminance) * scale,
                          luminance + (rgb.y - luminance) * scale,
                          luminance + (rgb.z - luminance) * scale), scale)
        }
        return (rgb, 1)
    }

    private static func wrap(_ angle: Float) -> Float {
        let tau = Float.pi * 2
        var result = (angle + .pi).truncatingRemainder(dividingBy: tau)
        if result < 0 { result += tau }
        return result - .pi
    }

    private func validatedControls(_ s: EditSettings) throws -> (Float, Float) {
        guard s.vibrance.isFinite, s.saturation.isFinite,
              [s.exposure, s.contrast, s.highlights, s.shadows, s.whites, s.blacks,
               s.texture, s.clarity, s.dehaze, s.luminanceNoiseReduction,
               s.colorNoiseReduction, s.autoToneAmount, s.naturalBalanceAmount].allSatisfy({ $0 == 0 }) else {
            throw Failure.invalid("Colour reference accepts only finite Vibrance/Saturation controls")
        }
        return (Float(min(100, max(-100, s.vibrance)) / 100), Float(min(100, max(-100, s.saturation)) / 100))
    }

    private func validate(_ input: AlgorithmEvaluationRaster) throws {
        guard input.width > 0, input.height > 0, input.width <= 16_384, input.height <= 16_384,
              input.width * input.height <= 32 * 1_024 * 1_024,
              input.pixels.count == input.width * input.height * 4, input.pixels.allSatisfy(\.isFinite),
              stride(from: 3, to: input.pixels.count, by: 4).allSatisfy({ (0...1).contains(input.pixels[$0]) }) else {
            throw Failure.invalid("Invalid colour raster")
        }
        try Task.checkCancellation()
    }

    private struct Matrix: Sendable {
        let a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>
        func apply(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(a.x * v.x + a.y * v.y + a.z * v.z,
                  b.x * v.x + b.y * v.y + b.z * v.z,
                  c.x * v.x + c.y * v.y + c.z * v.z)
        }
    }

    // Original oklab_matrices() Float32 values from its D65/Rec.2020 primary
    // derivation; skin is oklch_hue_of_srgb_hue(25). Frozen Rust vectors verify
    // these constants. Their approximate gray axis is retained, not corrected.
    static let skinHue: Float = 0.7826612
    private static let toLMS = Matrix(a: SIMD3(0.61668843, 0.36015907, 0.023043294),
                                      b: SIMD3(0.2651402, 0.6358565, 0.099030234),
                                      c: SIMD3(0.100150645, 0.20400432, 0.6963247))
    private static let fromLMS = Matrix(a: SIMD3(2.1401403, -1.2463559, 0.10643172),
                                        b: SIMD3(-0.88483244, 2.1631727, -0.2783616),
                                        c: SIMD3(-0.04857906, -0.4544909, 1.5023563))
    private static let toLab = Matrix(a: SIMD3(0.21045426, 0.7936178, -0.004072047),
                                      b: SIMD3(1.9779985, -2.4285922, 0.4505937),
                                      c: SIMD3(0.025904037, 0.78277177, -0.80867577))
    private static let fromLab = Matrix(a: SIMD3(1, 0.39633778, 0.21580376),
                                        b: SIMD3(1, -0.105561346, -0.06385417),
                                        c: SIMD3(1, -0.089484185, -1.2914855))
}
