import Foundation

/// LC-06 ground-truth metrics in extended linear sRGB. Chroma is the stable
/// opponent pair (R-Y, B-Y), Y=.2126R+.7152G+.0722B, in linear RGB units.
/// Matching uses only a flat upper ROI; detail/edges use the lower half.
enum LightcraftDenoiseComparison {
    typealias Raster = AlgorithmEvaluationRaster
    static func validate(_ input: Raster) throws {
        guard input.width > 0, input.height > 0, input.width <= 16_384, input.height <= 16_384,
              input.width * input.height <= 32 * 1_024 * 1_024,
              input.pixels.count == input.width * input.height * 4,
              input.pixels.allSatisfy({ $0.isFinite }),
              stride(from: 3, to: input.pixels.count, by: 4).allSatisfy({ (0...1).contains(input.pixels[$0]) }) else {
            throw AlgorithmEvaluationMetricError.invalid("Invalid LC-06 raster")
        }
        try Task.checkCancellation()
    }
    private static func validate(_ a: Raster, _ b: Raster) throws {
        try validate(a); try validate(b)
        guard a.width == b.width, a.height == b.height else {
            throw AlgorithmEvaluationMetricError.invalid("LC-06 dimensions differ")
        }
    }
    private static func rgb(_ input: Raster, _ p: Int) -> SIMD3<Double> {
        .init(Double(input.pixels[p]), Double(input.pixels[p + 1]), Double(input.pixels[p + 2]))
    }
    static func luma(_ rgb: SIMD3<Double>) -> Double { 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z }
    private static func rgbSquared(_ rgb: SIMD3<Double>) -> Double { (rgb.x * rgb.x + rgb.y * rgb.y + rgb.z * rgb.z) / 3 }
    private static func chromaSquared(_ rgb: SIMD3<Double>) -> Double {
        let y = luma(rgb), red = rgb.x - y, blue = rgb.z - y
        return (red * red + blue * blue) / 2
    }
    static func isNoisePixel(x: Int, y: Int, width: Int, height: Int) -> Bool {
        x >= width / 8 && x < width * 7 / 8 && y >= height / 16 && y < height * 3 / 16
    }
    static func isDetailPixel(x: Int, y: Int, width: Int, height: Int) -> Bool {
        x >= 1 && x < width - 1 && y >= height / 2 && y < height - 1
    }
    private struct Noise {
        var lumaSquared = 0.0, chromaSquared = 0.0, weight = 0.0, count = 0.0
        var lumaRMSE: Double { sqrt(lumaSquared / max(1e-30, weight)) }
        var chromaRMSE: Double { sqrt(chromaSquared / max(1e-30, weight)) }
    }
    private static func noise(clean: Raster, output: Raster) throws -> Noise {
        var result = Noise()
        for y in 0..<clean.height {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<clean.width where isNoisePixel(x: x, y: y, width: clean.width, height: clean.height) {
                let p = (y * clean.width + x) * 4, alpha = Double(clean.pixels[p + 3])
                guard alpha > 0 else { continue }
                let delta = rgb(output, p) - rgb(clean, p), luminance = luma(delta)
                result.lumaSquared += luminance * luminance * alpha
                result.chromaSquared += chromaSquared(delta) * alpha
                result.weight += alpha; result.count += 1
            }
        }
        guard result.weight > 0 else { throw AlgorithmEvaluationMetricError.invalid("LC-06 noise ROI is empty") }
        return result
    }

    /// Positive actual noise reduction; a no-op is exactly zero. Comparing
    /// residual ratios near one would falsely match ineffectual operations.
    static func strength(noisy: Raster, clean: Raster, output: Raster, control: String) throws -> Double {
        try validate(noisy, clean); try validate(clean, output)
        guard ["luminance", "chroma"].contains(control) else {
            throw AlgorithmEvaluationMetricError.invalid("Unknown LC-06 control")
        }
        let original = try noise(clean: clean, output: noisy), result = try noise(clean: clean, output: output)
        let before = control == "luminance" ? original.lumaRMSE : original.chromaRMSE
        let after = control == "luminance" ? result.lumaRMSE : result.chromaRMSE
        guard before > 1e-12 else { throw AlgorithmEvaluationMetricError.invalid("LC-06 matching has no input noise") }
        return 1 - after / before
    }

    static func measurement(noisy: Raster, clean: Raster, output: Raster) throws -> [String: Double] {
        try validate(noisy, clean); try validate(clean, output)
        let originalNoise = try noise(clean: clean, output: noisy), outputNoise = try noise(clean: clean, output: output)
        var detailError = 0.0, detailWeight = 0.0, detailCount = 0.0
        var edgeError = 0.0, edgeWeight = 0.0, edgeCount = 0.0, fringing = 0.0
        var visibleWeight = 0.0, signedDrift = 0.0, absoluteDrift = 0.0
        var alphaError = 0.0, hiddenError = 0.0, gamut = 0.0, clipping = 0.0, inputGamut = 0.0, inputClipping = 0.0
        for y in 0..<clean.height {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<clean.width {
                let p = (y * clean.width + x) * 4, alpha = Double(clean.pixels[p + 3])
                alphaError = max(alphaError, abs(Double(output.pixels[p + 3]) - alpha))
                guard alpha > 0 else {
                    for c in 0..<3 { hiddenError = max(hiddenError, abs(Double(output.pixels[p + c]))) }
                    continue
                }
                let delta = rgb(output, p) - rgb(clean, p), drift = luma(delta)
                visibleWeight += alpha; signedDrift += drift * alpha; absoluteDrift += abs(drift) * alpha
                for c in 0..<3 {
                    let value = output.pixels[p + c], initial = noisy.pixels[p + c]
                    gamut += value < -0.00001 || value > 1.00001 ? alpha : 0
                    clipping += value <= 0 || value >= 1 ? alpha : 0
                    inputGamut += initial < -0.00001 || initial > 1.00001 ? alpha : 0
                    inputClipping += initial <= 0 || initial >= 1 ? alpha : 0
                }
                guard isDetailPixel(x: x, y: y, width: clean.width, height: clean.height) else { continue }
                detailError += rgbSquared(delta) * alpha; detailWeight += alpha; detailCount += 1
                for q in [p + 4, p + clean.width * 4] {
                    let weight = min(alpha, Double(clean.pixels[q + 3]))
                    guard weight > 0 else { continue }
                    let expected = rgb(clean, q) - rgb(clean, p)
                    // The mask depends solely on clean RGB, including purely
                    // chromatic edges. Extra residual noise can only add error.
                    guard rgbSquared(expected) > 0.01 * 0.01 else { continue }
                    let actual = rgb(output, q) - rgb(output, p)
                    edgeError += rgbSquared(actual - expected) * weight
                    fringing += (chromaSquared(delta) + chromaSquared(rgb(output, q) - rgb(clean, q))) * 0.5 * weight
                    edgeWeight += weight; edgeCount += 1
                }
            }
        }
        guard visibleWeight > 0, detailWeight > 0 else {
            throw AlgorithmEvaluationMetricError.invalid("LC-06 visible detail ROI is empty")
        }
        return ["noise_luma_rmse": outputNoise.lumaRMSE, "noise_chroma_rmse": outputNoise.chromaRMSE,
                "input_noise_luma_rmse": originalNoise.lumaRMSE, "input_noise_chroma_rmse": originalNoise.chromaRMSE,
                "noise_luma_reduction": originalNoise.lumaRMSE > 1e-12 ? 1 - outputNoise.lumaRMSE / originalNoise.lumaRMSE : 0,
                "noise_chroma_reduction": originalNoise.chromaRMSE > 1e-12 ? 1 - outputNoise.chromaRMSE / originalNoise.chromaRMSE : 0,
                "noise_sample_count": outputNoise.count, "noise_visible_weight": outputNoise.weight,
                "detail_rgb_rmse": sqrt(detailError / detailWeight), "detail_sample_count": detailCount, "detail_visible_weight": detailWeight,
                "edge_gradient_rmse": sqrt(edgeError / max(1e-30, edgeWeight)), "edge_sample_count": edgeCount, "edge_visible_weight": edgeWeight,
                "chroma_fringing_rmse": sqrt(fringing / max(1e-30, edgeWeight)),
                "luma_drift_mean": absoluteDrift / visibleWeight, "luma_drift_signed": signedDrift / visibleWeight,
                "visible_weight": visibleWeight, "alpha_error": alphaError, "hidden_rgb_error": hiddenError,
                "gamut_fraction": gamut / (visibleWeight * 3), "clipping_fraction": clipping / (visibleWeight * 3),
                "input_gamut_fraction": inputGamut / (visibleWeight * 3), "input_clipping_fraction": inputClipping / (visibleWeight * 3)]
    }

    /// Direct preview versus area-averaged full output: fixed reference alpha
    /// support, the same opponent units as matching, no output-derived mask.
    static func scaleDistance(reference: Raster, candidate: Raster) throws -> [String: Double] {
        try validate(reference, candidate)
        var luminance = 0.0, chroma = 0.0, color = 0.0, weight = 0.0, alphaError = 0.0
        for p in stride(from: 0, to: reference.pixels.count, by: 4) {
            if p.isMultiple(of: 65_536) { try Task.checkCancellation() }
            let alpha = Double(reference.pixels[p + 3])
            alphaError = max(alphaError, abs(alpha - Double(candidate.pixels[p + 3])))
            guard alpha > 0 else { continue }
            let delta = rgb(candidate, p) - rgb(reference, p), y = luma(delta)
            luminance += y * y * alpha; chroma += chromaSquared(delta) * alpha; color += rgbSquared(delta) * alpha; weight += alpha
        }
        guard weight > 0 else { throw AlgorithmEvaluationMetricError.invalid("LC-06 scale comparison has no visible support") }
        return ["distance_luma_rmse": sqrt(luminance / weight), "distance_chroma_rmse": sqrt(chroma / weight),
                "distance_rgb_rmse": sqrt(color / weight), "alpha_error": alphaError, "visible_weight": weight]
    }
}
