import Foundation

/// LC-04 self-authored, deterministic stress scenes. Their names describe the
/// structures simulated, not photographic evidence. One owned buffer at a time
/// keeps large timing fixtures bounded; no nested scene worker pool is started.
enum LightcraftDetailFixtures {
    typealias Split = AlgorithmEvaluationFixtures.Split
    typealias Fixture = AlgorithmEvaluationFixtures.Fixture
    static let sceneClasses = ["hard-edge", "sky-branches", "skin-pores", "masonry-textiles", "lowlight-noise", "colors", "transparency"]

    static func make(sceneClass: String, split: Split, width: Int = 512, height: Int = 320) throws -> Fixture {
        guard let index = sceneClasses.firstIndex(of: sceneClass), width >= 16, height >= 16,
              width <= 16_384, height <= 16_384, width * height <= 32 * 1_024 * 1_024 else {
            throw AlgorithmEvaluationFixtureError.invalidRaster
        }
        if ["colors", "transparency"].contains(sceneClass) {
            return try AlgorithmEvaluationFixtures.make(sceneClass: sceneClass, split: split, width: width, height: height)
        }
        let seed = split.seed ^ (UInt64(index + 11) &* 0x9E37_79B9_7F4A_7C15)
        var state = seed
        func noise() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return Float(value >> 40) / 8_388_608 - 1
        }
        let phase = split == .tuning ? 0.13 : 0.71
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            if row.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<width {
                let u = Double(x) / Double(width), v = Double(row) / Double(height)
                let p = (row * width + x) * 4
                var rgb: (Double, Double, Double)
                switch sceneClass {
                case "hard-edge":
                    let edge = split == .tuning ? 0.5 : 0.59
                    let base = u < edge ? 0.04 : 0.86
                    let detail = v < 0.68 && abs(u - edge) > 0.09 ? 0.007 * sin((u * 37 + phase) * .pi * 2) * cos(v * 29 * .pi * 2) : 0
                    rgb = (base + detail, base + detail, base + detail)
                case "sky-branches":
                    let trunk = abs(u - (0.41 + phase * 0.15)) < 0.085
                    let branch = abs(v - (0.2 + 0.42 * u + phase * 0.08)) < 0.009 || abs(v - (0.8 - 0.57 * u)) < 0.006
                    let detail = v < 0.68 ? 0.008 * sin((u * 33 + phase) * .pi * 2) * cos(v * 27 * .pi * 2) : 0
                    rgb = trunk || branch ? (0.035, 0.043, 0.025) : (0.48 + detail, 0.68 + detail, 0.9 + detail)
                case "skin-pores":
                    let broad = 0.08 * sin((u * 3 + phase) * .pi) * cos(v * .pi)
                    let pores = 0.018 * sin((u * 47 + phase) * .pi * 2) * cos((v * 39 + phase) * .pi * 2)
                    let crease = 0.028 * exp(-pow((v - 0.38 - 0.05 * sin(u * 5)) / 0.015, 2))
                    rgb = (0.49 + broad + pores - crease, 0.265 + broad * 0.7 + pores - crease, 0.17 + broad * 0.5 + pores - crease)
                case "masonry-textiles":
                    let mortar = abs(sin((v * 12 + phase) * .pi)) < 0.14 || abs(sin((u * 9 + floor(v * 12) * 0.5 + phase) * .pi)) < 0.08
                    let weave = 0.022 * sin((u * 69 + phase) * .pi * 2) * cos((v * 61 + phase) * .pi * 2)
                    let base = u > 0.57 ? 0.28 : (mortar ? 0.14 : 0.34 + 0.06 * sin(u * 21 + v * 15))
                    rgb = (base + weave, base * 0.76 + weave, base * 0.59 + weave)
                default:
                    // Bottom quarter is flat ground truth for noise measurement;
                    // the upper region supplies independently visible detail.
                    let structure = v < 0.75 ? 0.017 * sin((u * 31 + phase) * .pi * 2) + 0.009 * cos(v * 43 * .pi * 2) : 0
                    let base = (x < width / 2 ? 0.045 : 0.095) + structure
                    rgb = (base, base * 0.83, base * 0.64)
                }
                pixels[p] = Float(rgb.0); pixels[p + 1] = Float(rgb.1); pixels[p + 2] = Float(rgb.2); pixels[p + 3] = 1
            }
        }
        let clean = try AlgorithmEvaluationRaster(width: width, height: height, pixels: pixels)
        if sceneClass == "lowlight-noise" {
            for p in stride(from: 0, to: pixels.count, by: 4) {
                let shared = noise() * 0.004
                for c in 0..<3 { pixels[p + c] += shared + noise() * 0.002 }
            }
        }
        return Fixture(id: "\(split.rawValue)-\(sceneClass)", sceneClass: sceneClass, split: split, seed: seed,
                       input: try .init(width: width, height: height, pixels: pixels), groundTruth: sceneClass == "lowlight-noise" ? clean : nil)
    }
}
