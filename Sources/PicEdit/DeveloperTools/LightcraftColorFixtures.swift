import Foundation

/// Self-authored LC-05 color diagnostics, not licensed photographic coverage.
/// Both splits contain exactly the same color/alpha multiset. A bijective pixel
/// permutation changes layout without changing this pointwise effect's target.
enum LightcraftColorFixtures {
    typealias Split = AlgorithmEvaluationFixtures.Split
    typealias Fixture = AlgorithmEvaluationFixtures.Fixture
    static let sceneClasses = ["skin-tones", "red-orange", "textiles-flowers", "color-gradients",
                               "primaries-secondaries", "p3-boundary", "grayscale", "transparency", "extended-dark"]

    static func sourceIndex(destination: Int, count: Int, split: Split) -> Int {
        split == .tuning ? destination : (count - 1 - destination + count / 3) % count
    }
    static func destinationIndex(source: Int, count: Int, split: Split) -> Int {
        split == .tuning ? source : (count - 1 - source + count / 3) % count
    }

    static func make(sceneClass: String, split: Split, width: Int = 256, height: Int = 160) throws -> Fixture {
        guard let scene = sceneClasses.firstIndex(of: sceneClass), width >= 16, height >= 16,
              width <= 16_384, height <= 16_384, width * height <= 32 * 1_024 * 1_024 else {
            throw AlgorithmEvaluationFixtureError.invalidRaster
        }
        let count = width * height
        let seed = split.seed ^ (UInt64(scene + 21) &* 0x9E37_79B9_7F4A_7C15)
        var pixels = [Float](repeating: 0, count: count * 4)
        for index in 0..<count {
            if index.isMultiple(of: 8_192) { try Task.checkCancellation() }
            let source = sourceIndex(destination: index, count: count, split: split)
            let x = source % width, row = source / width
            let u = Double(x) / Double(width - 1), v = Double(row) / Double(height - 1)
            var rgb: SIMD3<Double>, alpha = 1.0
            switch sceneClass {
            case "skin-tones":
                // Four lightness levels, multiple warm hues and low/moderate
                // chroma. These are color probes, not ethnic classifications.
                let lightness = [0.28, 0.44, 0.62, 0.78][row * 4 / height]
                let hue = [20.0, 35, 50, 65, 80, 95][x * 6 / width]
                let chroma = 0.018 + 0.085 * Double((x + row * 3) % 17) / 16 * min(1, lightness / 0.5)
                rgb = lch(lightness, chroma, hue)
            case "red-orange":
                // Every hue has the same L/C samples, making protected and
                // comparison-hue gain diagnostics comparable within the scene.
                let hues = [20.0, 40, 60, 140, 200, 260, 320, 350]
                let hue = hues[source % hues.count]
                let group = source / hues.count
                let lightness = [0.35, 0.5, 0.65, 0.8][group % 4]
                let chroma = [0.025, 0.05, 0.08, 0.11][(group / 4) % 4]
                rgb = lch(lightness, chroma, hue)
            case "textiles-flowers":
                let weave = sin(u * 38 * .pi) * cos(v * 32 * .pi)
                let dx = u - 0.72, dy = v - 0.48
                let petal = 0.5 + 0.5 * cos(atan2(dy, dx) * 7)
                let hue = u < 0.5 ? 205 + 40 * weave : 15 + 70 * petal
                let lightness = u < 0.5 ? 0.48 + 0.12 * weave : 0.55 + 0.15 * petal
                let chroma = u < 0.5 ? 0.025 + 0.08 * abs(weave) : 0.035 + 0.085 * petal
                rgb = lch(lightness, chroma, hue)
            case "color-gradients":
                let hue = [25.0, 70, 130, 200, 260, 320][row * 6 / height]
                let lightness = [0.4, 0.55, 0.7, 0.8][row % 4]
                rgb = lch(lightness, 0.005 + 0.15 * u, hue)
            case "primaries-secondaries":
                let colors: [SIMD3<Double>] = [.init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1),
                                              .init(1, 1, 0), .init(0, 1, 1), .init(1, 0, 1)]
                let color = colors[x * 6 / width]
                let amplitude = 0.08 + 0.72 * v
                rgb = SIMD3<Double>(repeating: 0.12) + color * amplitude
            case "p3-boundary":
                let colors: [SIMD3<Double>] = [.init(1, 0.02, 0.01), .init(0.01, 1, 0.03), .init(0.02, 0.01, 1),
                                              .init(1, 0.75, 0.01), .init(0.01, 0.85, 1), .init(1, 0.01, 0.75)]
                let p3 = colors[x * 6 / width] * (0.2 + 0.8 * v)
                // Display P3 and sRGB D65 primary matrices composed in Double.
                // Preserve signed/out-of-sRGB-gamut components in the source.
                rgb = .init(1.22494017628056 * p3.x - 0.22494017628056 * p3.y,
                            -0.04205695470969 * p3.x + 1.04205695470969 * p3.y,
                            -0.01963755459033 * p3.x - 0.07863604555063 * p3.y + 1.09827360014096 * p3.z)
            case "grayscale":
                if row < height / 2 { rgb = SIMD3<Double>(repeating: u) }
                else { rgb = lch(0.12 + 0.78 * u, 0.00001 + 0.001 * v, Double(x % 12) * 30) }
            case "transparency":
                rgb = lch(0.3 + 0.5 * v, 0.035 + 0.08 * u, Double((row / 8) % 6) * 60 + 25)
                alpha = x < width / 8 ? 0 : min(1, Double(x - width / 8) / Double(max(1, width / 4)))
            default:
                let values: [SIMD3<Double>] = [.init(-0.03, 0.005, 0.02), .init(0.01, -0.005, 0.025),
                    .init(-0.02, -0.02, -0.02), .init(0, 0, 0), .init(1e-9, 2e-9, 1e-9),
                    .init(0.0001, 0.0002, 0.0005), .init(1.2, 0.2, -0.1), .init(0.02, 0.001, 0.003)]
                rgb = values[x * values.count / width] * (0.5 + v)
            }
            let p = index * 4
            pixels[p] = Float(rgb.x); pixels[p + 1] = Float(rgb.y); pixels[p + 2] = Float(rgb.z); pixels[p + 3] = Float(alpha)
        }
        return Fixture(id: "\(split.rawValue)-\(sceneClass)", sceneClass: sceneClass, split: split, seed: seed,
                       input: try .init(width: width, height: height, pixels: pixels), groundTruth: nil)
    }

    /// Independent standard sRGB Oklab construction, not a Lightcraft adapter
    /// call. Extended components stay intact; output gamut is part of evaluation.
    static func lch(_ lightness: Double, _ chroma: Double, _ degrees: Double) -> SIMD3<Double> {
        let angle = degrees * .pi / 180
        let a = chroma * cos(angle), b = chroma * sin(angle)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return .init(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }
}
