import Foundation

/// Input-relative color measurements use independent Double standard-sRGB
/// Oklab matrices and signed cube roots. No candidate transform is reused here.
enum LightcraftColorComparison {
    typealias Raster = AlgorithmEvaluationRaster
    typealias Split = AlgorithmEvaluationFixtures.Split
    static let hueMinimumChroma = 0.02
    static let lostHueChroma = 0.000001

    static func lab(_ r: Double, _ g: Double, _ b: Double) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return .init(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
    static func lab(_ raster: Raster, _ p: Int) -> SIMD3<Double> {
        lab(Double(raster.pixels[p]), Double(raster.pixels[p + 1]), Double(raster.pixels[p + 2]))
    }
    static func chroma(_ lab: SIMD3<Double>) -> Double { hypot(lab.y, lab.z) }

    static func validate(_ input: Raster, _ output: Raster) throws {
        guard input.width == output.width, input.height == output.height,
              input.width > 0, input.height > 0,
              input.pixels.count == input.width * input.height * 4,
              output.pixels.count == input.pixels.count,
              input.pixels.allSatisfy(\.isFinite), output.pixels.allSatisfy(\.isFinite),
              stride(from: 3, to: input.pixels.count, by: 4).allSatisfy({ (0...1).contains(input.pixels[$0]) && (0...1).contains(output.pixels[$0]) }) else {
            throw AlgorithmEvaluationMetricError.invalid("Invalid LC-05 measurement rasters")
        }
    }

    /// All visible input pixels contribute, including low-chroma colors. The
    /// signed target is never normalized by output alpha or a candidate mask.
    static func strength(input: Raster, output: Raster) throws -> Double {
        try validate(input, output)
        var sum = 0.0, weight = 0.0
        for p in stride(from: 0, to: input.pixels.count, by: 4) {
            if p.isMultiple(of: 65_536) { try Task.checkCancellation() }
            let alpha = Double(input.pixels[p + 3])
            guard alpha > 0 else { continue }
            sum += alpha * (chroma(lab(output, p)) - chroma(lab(input, p)))
            weight += alpha
        }
        guard weight > 0 else { throw AlgorithmEvaluationMetricError.invalid("LC-05 has no visible matching support") }
        return sum / weight
    }

    static func measurement(input: Raster, output: Raster, sceneClass: String? = nil,
                            split: Split? = nil) throws -> [String: Double] {
        try validate(input, output)
        var weight = 0.0, inputChroma = 0.0, outputChroma = 0.0, lightness = 0.0
        var hueWeight = 0.0, hueSum = 0.0, hueMax = 0.0, hueCount = 0.0, hueMissing = 0.0, hueLostWeight = 0.0
        var inputGamut = 0.0, outputGamut = 0.0, inputClip = 0.0, outputClip = 0.0
        var alphaError = 0.0, hiddenError = 0.0, chromaMax = 0.0, neutralMax = 0.0, neutralCount = 0.0
        var protectedGain = 0.0, protectedWeight = 0.0, protectedCount = 0.0
        var comparisonGain = 0.0, comparisonWeight = 0.0, comparisonCount = 0.0
        for p in stride(from: 0, to: input.pixels.count, by: 4) {
            if p.isMultiple(of: 65_536) { try Task.checkCancellation() }
            let alpha = Double(input.pixels[p + 3])
            alphaError = max(alphaError, abs(alpha - Double(output.pixels[p + 3])))
            if alpha == 0 {
                for c in 0..<3 { hiddenError = max(hiddenError, abs(Double(output.pixels[p + c]))) }
                continue
            }
            let before = lab(input, p), after = lab(output, p)
            let initial = chroma(before), final = chroma(after)
            weight += alpha; inputChroma += initial * alpha; outputChroma += final * alpha
            lightness += abs(after.x - before.x) * alpha; chromaMax = max(chromaMax, final)
            if initial <= lostHueChroma { neutralMax = max(neutralMax, final); neutralCount += 1 }
            for c in 0..<3 {
                let a = Double(input.pixels[p + c]), b = Double(output.pixels[p + c])
                inputGamut += a < -0.00001 || a > 1.00001 ? alpha : 0
                outputGamut += b < -0.00001 || b > 1.00001 ? alpha : 0
                inputClip += a <= 0 || a >= 1 ? alpha : 0
                outputClip += b <= 0 || b >= 1 ? alpha : 0
            }
            if initial >= hueMinimumChroma, before.x > 0.02, alpha > 0.1 {
                hueCount += 1; hueWeight += alpha
                let drift: Double
                if final < lostHueChroma {
                    // Color loss must never improve hue by removing the pixel
                    // from its fixed input-defined support. A conservative 180
                    // degree penalty accompanies an explicit missing-hue count.
                    hueMissing += 1; hueLostWeight += alpha; drift = 180
                } else {
                    let difference = abs(atan2(after.z, after.y) - atan2(before.z, before.y))
                    drift = min(difference, 2 * .pi - difference) * 180 / .pi
                }
                hueSum += drift * alpha; hueMax = max(hueMax, drift)
                if sceneClass == "red-orange" {
                    let hue = atan2(before.z, before.y) * 180 / .pi
                    if hue >= 10, hue <= 75 {
                        protectedGain += (final / initial - 1) * alpha; protectedWeight += alpha; protectedCount += 1
                    } else {
                        comparisonGain += (final / initial - 1) * alpha; comparisonWeight += alpha; comparisonCount += 1
                    }
                }
            }
        }
        guard weight > 0 else { throw AlgorithmEvaluationMetricError.invalid("LC-05 has no visible measurement support") }
        let denominator = weight * 3
        var result = ["mean_chroma_delta": (outputChroma - inputChroma) / weight,
                      "input_chroma_mean": inputChroma / weight, "output_chroma_mean": outputChroma / weight,
                      "visible_weight": weight, "hue_sample_count": hueCount, "hue_missing_count": hueMissing,
                      "hue_loss_fraction": hueLostWeight / max(1e-30, hueWeight),
                      "hue_drift_mean_degrees": hueSum / max(1e-30, hueWeight), "hue_drift_max_degrees": hueMax,
                      "lightness_drift_mean": lightness / weight, "gamut_fraction": outputGamut / denominator,
                      "clipping_fraction": outputClip / denominator, "input_gamut_fraction": inputGamut / denominator,
                      "input_clipping_fraction": inputClip / denominator,
                      "gamut_fraction_increase": max(0, outputGamut - inputGamut) / denominator,
                      "clipping_fraction_increase": max(0, outputClip - inputClip) / denominator,
                      "alpha_error": alphaError, "hidden_rgb_error": hiddenError,
                      "output_chroma_max": chromaMax, "neutral_chroma_max": neutralMax, "neutral_sample_count": neutralCount,
                      "red_orange_chroma_gain_mean": protectedGain / max(1e-30, protectedWeight),
                      "comparison_chroma_gain_mean": comparisonGain / max(1e-30, comparisonWeight),
                      "red_orange_sample_count": protectedCount, "comparison_hue_sample_count": comparisonCount]
        if sceneClass == "color-gradients", let split {
            result.merge(try gradation(input: input, output: output, split: split)) { _, new in new }
        } else {
            result.merge(["gradation_collapse_fraction": 0, "gradation_reversal_fraction": 0,
                          "gradation_loss_fraction": 0, "gradation_sample_count": 0]) { _, new in new }
        }
        return result
    }

    /// Compare consecutive source-chroma steps in the original procedural ramp,
    /// undoing each split's pixel permutation. Display adjacency in acceptance
    /// is intentionally irrelevant. Complete desaturation is interpreted by its
    /// separate contract, not falsely treated as an unexpected banding defect.
    static func gradation(input: Raster, output: Raster, split: Split) throws -> [String: Double] {
        try validate(input, output)
        var count = 0.0, collapsed = 0.0, reversed = 0.0
        let pixels = input.width * input.height
        for row in 0..<input.height {
            if row.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<(input.width - 1) {
                let first = row * input.width + x
                let p = LightcraftColorFixtures.destinationIndex(source: first, count: pixels, split: split) * 4
                let q = LightcraftColorFixtures.destinationIndex(source: first + 1, count: pixels, split: split) * 4
                guard input.pixels[p + 3] > 0.1, input.pixels[q + 3] > 0.1 else { continue }
                let initial = chroma(lab(input, q)) - chroma(lab(input, p))
                guard initial > 0.000001 else { continue }
                let final = chroma(lab(output, q)) - chroma(lab(output, p))
                count += 1
                if abs(final) <= 0.000001 { collapsed += 1 }
                else if final < -0.000001 { reversed += 1 }
            }
        }
        return ["gradation_collapse_fraction": collapsed / max(1, count),
                "gradation_reversal_fraction": reversed / max(1, count),
                "gradation_loss_fraction": (collapsed + reversed) / max(1, count), "gradation_sample_count": count]
    }
}
