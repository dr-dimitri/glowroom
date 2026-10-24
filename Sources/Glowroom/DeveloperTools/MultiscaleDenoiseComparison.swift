import Foundation

/// Reuses LC-06's clean truth, masks, alpha weighting and noise units. The old
/// extended-sRGB cube statistics remain diagnostics; qualification uses the
/// explicitly declared target profile and provenance-backed SDR/HDR range.
enum MultiscaleDenoiseComparison {
    typealias Raster = AlgorithmEvaluationRaster
    static let sceneClasses = LightcraftDenoiseFixtures.sceneClasses + ["skin", "hdr"]
    static let primaryScenes = ["dark-edges", "fine-lines", "color-lines", "texture", "skin"]
    static func make(_ scene: String, split: AlgorithmEvaluationFixtures.Split, width: Int, height: Int) throws -> AlgorithmEvaluationFixtures.Fixture {
        if LightcraftDenoiseFixtures.sceneClasses.contains(scene) {
            return try LightcraftDenoiseFixtures.make(sceneClass: scene, split: split, width: width, height: height)
        }
        guard ["skin", "hdr"].contains(scene) else { throw AlgorithmEvaluationFixtureError.unknownScene }
        let base = try LightcraftDenoiseFixtures.make(sceneClass: "texture", split: split, width: width, height: height)
        guard var clean = base.groundTruth else { throw AlgorithmEvaluationFixtureError.invalidRaster }
        for p in stride(from: 0, to: clean.pixels.count, by: 4) {
            if scene == "hdr" { for c in 0..<3 { clean.pixels[p + c] += 1.4 } }
            else { clean.pixels[p] += 0.22; clean.pixels[p + 1] += 0.07; clean.pixels[p + 2] += 0.025 }
        }
        var noisy = clean
        let seed = base.seed ^ (scene == "hdr" ? 0xD8C2_734A_6285_29B1 : 0x5BC9_7142_A4E8_91F3)
        for p in stride(from: 0, to: noisy.pixels.count, by: 4) {
            if p.isMultiple(of: 65_536) { try Task.checkCancellation() }
            func noise(_ counter: UInt64) -> Float {
                var value = seed &+ counter &* 0x9E37_79B9_7F4A_7C15
                value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
                value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB; value ^= value >> 31
                return Float((Double(value >> 11) / 9_007_199_254_740_992 * 2 - 1) * sqrt(3))
            }
            let y = noise(UInt64(p + 1)) * 0.012, red = noise(UInt64(p + 2)) * 0.010, blue = noise(UInt64(p + 3)) * 0.010
            noisy.pixels[p] += y + red; noisy.pixels[p + 1] += y - (0.2126 * red + 0.0722 * blue) / 0.7152; noisy.pixels[p + 2] += y + blue
        }
        return .init(id: "\(split.rawValue)-\(scene)", sceneClass: scene, split: split, seed: seed, input: noisy, groundTruth: clean)
    }
    static func target(_ rgb: SIMD3<Double>, scene: String) -> SIMD3<Double> {
        guard scene == "p3-dark" else { return rgb }
        // Inverse of LC-06's D65 linear Display-P3 -> extended-linear-sRGB
        // fixture matrix, explicitly evaluated before output limitation.
        return SIMD3(0.8224619687143624 * rgb.x + 0.17753803128563753 * rgb.y,
                     0.033194198850963016 * rgb.x + 0.9668058011490369 * rgb.y,
                     0.017082630721116855 * rgb.x + 0.0723974406639614 * rgb.y + 0.9105199286149217 * rgb.z)
    }
    static func measure(noisy: Raster, clean: Raster, output: Raster, scene: String) throws -> [String: Double] {
        var result = try LightcraftDenoiseComparison.measurement(noisy: noisy, clean: clean, output: output)
        // Keep historical LC-06 stats visibly distinct from target gates.
        for key in ["gamut_fraction", "clipping_fraction", "input_gamut_fraction", "input_clipping_fraction"] {
            result["extended_srgb_cube_diagnostic_" + key] = result.removeValue(forKey: key)
        }
        let upper = scene == "hdr" ? 4.0 : 1.0
        var inputOutside = 0.0, outputOutside = 0.0, inputBoundary = 0.0, outputBoundary = 0.0, newlyOutside = 0.0, weight = 0.0
        for p in stride(from: 0, to: clean.pixels.count, by: 4) {
            if p.isMultiple(of: 65_536) { try Task.checkCancellation() }
            let alpha = Double(clean.pixels[p + 3]); guard alpha > 0 else { continue }; weight += alpha * 3
            let a = target(SIMD3(Double(noisy.pixels[p]), Double(noisy.pixels[p + 1]), Double(noisy.pixels[p + 2])), scene: scene)
            let b = target(SIMD3(Double(output.pixels[p]), Double(output.pixels[p + 1]), Double(output.pixels[p + 2])), scene: scene)
            for c in 0..<3 {
                let outsideA = a[c] < -0.00001 || a[c] > upper + 0.00001, outsideB = b[c] < -0.00001 || b[c] > upper + 0.00001
                inputOutside += outsideA ? alpha : 0; outputOutside += outsideB ? alpha : 0
                newlyOutside += !outsideA && outsideB ? alpha : 0
                inputBoundary += a[c] <= 0 || a[c] >= upper ? alpha : 0; outputBoundary += b[c] <= 0 || b[c] >= upper ? alpha : 0
            }
        }
        result["target_input_outside_fraction"] = inputOutside / weight; result["target_outside_fraction"] = outputOutside / weight
        result["target_input_boundary_fraction"] = inputBoundary / weight; result["target_boundary_fraction"] = outputBoundary / weight
        result["target_new_outside_fraction"] = newlyOutside / weight
        return result
    }
}
