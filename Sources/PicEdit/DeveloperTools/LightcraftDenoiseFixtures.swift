import Foundation

/// Self-authored LC-06 scenes with unchanged clean truth and independent
/// deterministic noise seeds. These are controlled signals, not photographs.
enum LightcraftDenoiseFixtures {
    typealias Raster = AlgorithmEvaluationRaster
    typealias Split = AlgorithmEvaluationFixtures.Split
    typealias Fixture = AlgorithmEvaluationFixtures.Fixture
    static let sceneClasses = ["flat-dark", "flat-bright", "dark-edges", "fine-lines",
                               "color-lines", "texture", "transparency", "p3-dark"]

    static func make(sceneClass: String, split: Split, width: Int = 256, height: Int = 160) throws -> Fixture {
        guard let scene = sceneClasses.firstIndex(of: sceneClass), width >= 16, height >= 16,
              width <= 16_384, height <= 16_384, width * height <= 32 * 1_024 * 1_024 else {
            throw AlgorithmEvaluationFixtureError.invalidRaster
        }
        let seed = split.seed ^ (UInt64(scene + 37) &* 0x9E37_79B9_7F4A_7C15)
        let clean = try Raster(width: width, height: height, pixels: LightcraftToneFilters.rows(width: width * 4, height: height) { y, row in
            for x in 0..<width {
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                let sx = Int(floor(u * 256)), sy = Int(floor(v * 160))
                let flat = sceneClass == "flat-bright" ? 0.62 : (sceneClass == "flat-dark" || sceneClass == "dark-edges" || sceneClass == "p3-dark" ? 0.035 : 0.18)
                var rgb = SIMD3<Double>(repeating: flat), alpha = 1.0
                // The upper third is constant, with a moat separating matching
                // support from lower-half structure. It is identical in splits.
                if v >= 0.5 {
                    switch sceneClass {
                    case "dark-edges":
                        let level = (sx / 32 + sy / 24).isMultiple(of: 2) ? 0.018 : 0.115
                        rgb = SIMD3(repeating: level)
                    case "fine-lines":
                        let line = sx % 16 < 2 || sy % 24 < 2
                        rgb = SIMD3(repeating: line ? 0.36 : 0.12)
                    case "color-lines":
                        let line = sx % 16 < 3 || sy % 24 < 2
                        // Opponent changes have approximately identical Y.
                        let red = line ? 0.24 : -0.08, blue = line ? -0.08 : 0.16
                        rgb = .init(0.18 + red, 0.18 - (0.2126 * red + 0.0722 * blue) / 0.7152, 0.18 + blue)
                    case "texture":
                        let weave = 0.055 * sin(u * 64 * .pi) * cos(v * 40 * .pi)
                        let small = 0.025 * sin(u * 128 * .pi + v * 32 * .pi)
                        // Coarse weave boundaries retain fixed edge support at
                        // native and preview sizes; sinusoids probe fine detail.
                        let seam = (sx / 64 + sy / 32).isMultiple(of: 2) ? 0.0 : 0.08
                        rgb = .init(0.24 + seam + weave + small, 0.18 + seam + weave, 0.12 + seam + weave - small)
                    case "transparency":
                        let line = sx % 24 < 3
                        rgb = line ? .init(0.5, 0.12, 0.055) : .init(0.08, 0.22, 0.38)
                        alpha = sx < 32 ? 0 : min(1, Double(sx - 32) / 64)
                    case "p3-dark":
                        let p3: SIMD3<Double> = (sx / 24 + sy / 20).isMultiple(of: 2) ? .init(0.2, 0.008, 0.004) : .init(0.004, 0.12, 0.025)
                        rgb = .init(1.22494017628056 * p3.x - 0.22494017628056 * p3.y,
                                    -0.04205695470969 * p3.x + 1.04205695470969 * p3.y,
                                    -0.01963755459033 * p3.x - 0.07863604555063 * p3.y + 1.09827360014096 * p3.z)
                    default: break
                    }
                }
                let p = x * 4
                row[p] = Float(rgb.x); row[p + 1] = Float(rgb.y); row[p + 2] = Float(rgb.z); row[p + 3] = Float(alpha)
            }
        })
        let lumaSigma = sceneClass == "flat-bright" ? 0.035 : 0.012
        let chromaSigma = sceneClass == "flat-bright" ? 0.025 : 0.010
        let noisyPixels = try LightcraftToneFilters.rows(width: width * 4, height: height) { y, row in
            for x in 0..<width {
                let source = (y * width + x) * 4, p = x * 4
                let alpha = clean.pixels[source + 3]
                row[p + 3] = alpha
                guard alpha > 0 else { continue }
                // Counter-based independent uniform samples have mean zero and
                // unit variance. No clipping biases dark or P3 noise statistics.
                let counter = UInt64(y * width + x) &* 3
                let luminance = noise(seed: seed, counter: counter) * lumaSigma
                let red = noise(seed: seed, counter: counter &+ 1) * chromaSigma
                let blue = noise(seed: seed, counter: counter &+ 2) * chromaSigma
                row[p] = clean.pixels[source] + Float(luminance + red)
                row[p + 1] = clean.pixels[source + 1] + Float(luminance - (0.2126 * red + 0.0722 * blue) / 0.7152)
                row[p + 2] = clean.pixels[source + 2] + Float(luminance + blue)
            }
        }
        return Fixture(id: "\(split.rawValue)-\(sceneClass)", sceneClass: sceneClass, split: split, seed: seed,
                       input: try Raster(width: width, height: height, pixels: noisyPixels), groundTruth: clean)
    }

    private static func noise(seed: UInt64, counter: UInt64) -> Double {
        var value = seed &+ (counter &+ 1) &* 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return (Double(value >> 11) / 9_007_199_254_740_992 * 2 - 1) * sqrt(3)
    }

    /// Exact rectangular pixel-area overlap, separable and coverage weighted.
    /// Intermediate RGB is premultiplied; only the final pass unpremultiplies.
    /// The smaller intermediate orientation bounds scratch memory. Each pass
    /// uses the shared row pool; passes and source images are never nested.
    static func areaAverage(_ input: Raster, width: Int, height: Int) throws -> Raster {
        try LightcraftDenoiseComparison.validate(input)
        guard width > 0, height > 0, width <= input.width, height <= input.height else {
            throw AlgorithmEvaluationFixtureError.invalidRaster
        }
        if width == input.width, height == input.height {
            return try Raster(width: width, height: height, pixels: input.pixels)
        }
        let horizontalFirst = width * input.height <= input.width * height
        let middleWidth = horizontalFirst ? width : input.width
        let middleHeight = horizontalFirst ? input.height : height
        let intermediate = try areaPass(input.pixels, sourceWidth: input.width, sourceHeight: input.height,
                                        width: middleWidth, height: middleHeight, horizontal: horizontalFirst,
                                        premultiply: true, unpremultiply: false)
        let result = try areaPass(intermediate, sourceWidth: middleWidth, sourceHeight: middleHeight,
                                  width: width, height: height, horizontal: !horizontalFirst,
                                  premultiply: false, unpremultiply: true)
        return try Raster(width: width, height: height, pixels: result)
    }

    private struct Footprint: Sendable {
        let start: Double, end: Double
        let first: Int, last: Int
    }
    private static func areaPass(_ input: [Float], sourceWidth: Int, sourceHeight: Int,
                                 width: Int, height: Int, horizontal: Bool,
                                 premultiply: Bool, unpremultiply: Bool) throws -> [Float] {
        let sourceLength = horizontal ? sourceWidth : sourceHeight
        let targetLength = horizontal ? width : height
        let scale = Double(sourceLength) / Double(targetLength)
        let footprints = (0..<targetLength).map { index in
            let start = Double(index) * scale, end = min(Double(sourceLength), Double(index + 1) * scale)
            return Footprint(start: start, end: end, first: Int(floor(start)), last: min(sourceLength - 1, Int(ceil(end)) - 1))
        }
        return try LightcraftToneFilters.rows(width: width * 4, height: height) { y, row in
            for x in 0..<width {
                let span = footprints[horizontal ? x : y]
                var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
                for sample in span.first...span.last {
                    let weight = (min(span.end, Double(sample + 1)) - max(span.start, Double(sample))) / (span.end - span.start)
                    let p = horizontal ? (y * sourceWidth + sample) * 4 : (sample * sourceWidth + x) * 4
                    let coverage = Double(input[p + 3]), factor = premultiply ? coverage : 1
                    red += Double(input[p]) * factor * weight
                    green += Double(input[p + 1]) * factor * weight
                    blue += Double(input[p + 2]) * factor * weight
                    alpha += coverage * weight
                }
                let p = x * 4, denominator = unpremultiply && alpha > 0 ? alpha : 1
                if !unpremultiply || alpha > 0 {
                    row[p] = Float(red / denominator); row[p + 1] = Float(green / denominator); row[p + 2] = Float(blue / denominator)
                }
                row[p + 3] = Float(min(1, max(0, alpha)))
            }
        }
    }
}
