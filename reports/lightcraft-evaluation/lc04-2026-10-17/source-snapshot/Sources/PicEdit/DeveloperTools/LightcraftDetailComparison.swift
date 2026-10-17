import Foundation
import PicEditCore

enum LightcraftDetailComparison {
    typealias Raster = AlgorithmEvaluationRaster
    typealias Variant = LightcraftDetailReference.Variant
    struct Direction: Codable {
        let id: String
        let control: String
        let value: Double
        let primary: Bool
        func settings(value override: Double? = nil) -> EditSettings {
            var result = EditSettings.neutral
            if control == "clarity" { result.clarity = override ?? value }
            else { result.texture = override ?? value }
            return result
        }
        var variants: [Variant] {
            control == "clarity" ? [.clarityGuidedLog, .clarityGaussianLog] : [.textureGaussianExistingDomain, .textureGaussianLog, .textureGaussianLogTamed]
        }
        var candidate: Variant { control == "clarity" ? .clarityGuidedLog : .textureGaussianLogTamed }
    }
    struct Manifest: Codable {
        struct Matching: Codable {
            let sceneClasses: [String]
            let minimumAbsoluteTarget: Double
            let maximumAbsoluteDeltaError: Double
            let maximumRelativeDeltaError: Double
            let coarseSteps: Int
            let refinementSteps: Int
        }
        struct Primary: Codable {
            let metric: String
            let sceneClasses: [String]
            let minimumRelativeImprovement: Double
            let maximumPerCaseRegression: Double
        }
        let schemaVersion: Int
        let sourceCommit: String
        let qualityWidth: Int
        let qualityHeight: Int
        let performanceSceneClass: String
        let directions: [Direction]
        let matching: Matching
        let primary: Primary
        let criticalLimits: [String: Double]
        static func load(_ url: URL) throws -> Self {
            let m = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard m.schemaVersion == 1, m.sourceCommit == "f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15",
                  m.qualityWidth == 512, m.qualityHeight == 320, m.performanceSceneClass == "masonry-textiles",
                  m.directions.count == 8, Set(m.directions.map(\.id)).count == 8,
                  Set(m.directions.map { "\($0.control):\($0.value)" }).count == 8,
                  m.directions.allSatisfy({ ["clarity", "texture"].contains($0.control) && [-60.0, -20, 20, 60].contains($0.value) && $0.primary == (abs($0.value) == 20) && $0.id == "\($0.control)-\($0.value > 0 ? "positive" : "negative")-\(Int(abs($0.value)))" }),
                  m.matching.sceneClasses == LightcraftDetailFixtures.sceneClasses,
                  m.matching.coarseSteps == 33, m.matching.refinementSteps == 33,
                  [m.matching.minimumAbsoluteTarget, m.matching.maximumAbsoluteDeltaError, m.matching.maximumRelativeDeltaError,
                   m.primary.minimumRelativeImprovement, m.primary.maximumPerCaseRegression].allSatisfy({ $0.isFinite && $0 > 0 }),
                  m.primary.metric == "halo_area", Set(m.primary.sceneClasses) == Set(["hard-edge", "sky-branches"]),
                  Set(m.criticalLimits.keys) == Set(["hueDeviationDegrees", "gamutFractionIncrease", "clippingFractionIncrease", "alphaError", "edgeOvershootIncrease", "noiseAmplificationRelativeIncrease"]),
                  m.criticalLimits.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw AlgorithmEvaluationMetricError.invalid("Invalid LC-04 manifest")
            }
            return m
        }
    }
    struct Calibration: Codable {
        let sceneClass: String
        let directionID: String
        let variant: String
        let inputSHA256: String
        let parameter: Double
        let target: Double
        let measured: Double
        let matched: Bool
    }
    struct CalibrationFile: Codable {
        let manifestSHA256: String
        let records: [Calibration]
    }
    static func valid(_ rasters: Raster...) -> Bool {
        guard let first = rasters.first else { return false }
        return rasters.allSatisfy { $0.width == first.width && $0.height == first.height && $0.pixels.count == first.width * first.height * 4 && $0.pixels.allSatisfy(\.isFinite) }
    }
    static func y(_ r: Raster, _ p: Int) -> Double {
        0.2126 * Double(r.pixels[p]) + 0.7152 * Double(r.pixels[p + 1]) + 0.0722 * Double(r.pixels[p + 2])
    }
    /// Signed CHANGE in local RMS contrast relative to unchanged pixels. A
    /// global additive luminance shift contributes zero. Masks use only INPUT,
    /// exclude strong boundaries and the independent lower-quarter noise ROI.
    /// Both endpoints have visible alpha; transparent edges cannot fake detail.
    static func detail(input: Raster, output: Raster, control: String, exclusion: [Bool]? = nil) -> [String: Double] {
        guard valid(input, output), input.width >= 8, input.height >= 8 else { return [:] }
        let distance = control == "clarity" ? 4 : 1
        let excluded = exclusion ?? edgeExclusion(input)
        guard excluded.count == input.width * input.height else { return [:] }
        var before = 0.0, after = 0.0, weight = 0.0, count = 0.0
        for row in 2..<max(2, input.height * 3 / 4 - distance) {
            for x in 2..<max(2, input.width - distance - 2) {
                let p = (row * input.width + x) * 4
                for q in [p + distance * 4, p + distance * input.width * 4] {
                    guard !excluded[p / 4], !excluded[q / 4] else { continue }
                    let a = min(Double(input.pixels[p + 3]), Double(input.pixels[q + 3]))
                    let delta = y(input, p) - y(input, q)
                    guard a > 0.1, abs(delta) > 0.00001, abs(delta) < 0.08 else { continue }
                    let changed = y(output, p) - y(output, q)
                    before += delta * delta * a; after += changed * changed * a; weight += a; count += 1
                }
            }
        }
        guard weight > 0 else { return ["detail_sample_count": 0] }
        let initial = sqrt(before / weight), final = sqrt(after / weight)
        return ["detail_contrast_delta": final - initial, "detail_contrast_input": initial,
                "detail_contrast_output": final, "detail_sample_count": count]
    }
    /// A separable square dilation excludes fine pixels that merely happen to
    /// sit beside a strong boundary. Two byte masks keep the cost bounded at
    /// large sizes; this diagnostic runs outside the timed adapter boundary.
    static func edgeExclusion(_ input: Raster) -> [Bool] {
        let width = input.width, height = input.height
        let margin = max(4, Int(ceil(Double(width) * 0.05)))
        var horizontal = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            var prefix = [Int](repeating: 0, count: width + 1)
            for x in 0..<width {
                let p = (row * width + x) * 4
                let strongX = x + 1 < width && abs(y(input, p) - y(input, p + 4)) > 0.1
                let strongY = row + 1 < height && abs(y(input, p) - y(input, p + width * 4)) > 0.1
                prefix[x + 1] = prefix[x] + (strongX || strongY ? 1 : 0)
            }
            for x in 0..<width {
                horizontal[row * width + x] = prefix[min(width, x + margin + 1)] > prefix[max(0, x - margin)] ? 1 : 0
            }
        }
        var excluded = [Bool](repeating: false, count: width * height)
        var sums = [Int](repeating: 0, count: width)
        for row in 0..<min(height, margin + 1) { for x in 0..<width { sums[x] += Int(horizontal[row * width + x]) } }
        for row in 0..<height {
            for x in 0..<width { excluded[row * width + x] = sums[x] > 0 }
            let leaving = row - margin, entering = row + margin + 1
            if leaving >= 0 { for x in 0..<width { sums[x] -= Int(horizontal[leaving * width + x]) } }
            if entering < height { for x in 0..<width { sums[x] += Int(horizontal[entering * width + x]) } }
        }
        return excluded
    }
    static func strength(input: Raster, output: Raster, direction: Direction, exclusion: [Bool]? = nil) -> Double? {
        detail(input: input, output: output, control: direction.control, exclusion: exclusion)["detail_contrast_delta"]
    }
    static func matched(_ target: Double?, _ measured: Double?, manifest: Manifest) -> Bool {
        guard let target, let measured, target.isFinite, measured.isFinite,
              abs(target) >= manifest.matching.minimumAbsoluteTarget, measured != 0,
              target.sign == measured.sign else { return false }
        return abs(target - measured) <= max(manifest.matching.maximumAbsoluteDeltaError, abs(target) * manifest.matching.maximumRelativeDeltaError)
    }
    /// Flat pixels in the lower quarter near a strong INPUT edge, independently
    /// of the detail-matching ROI. Subtract each side's far-plateau change, so a
    /// global offset is not called a halo. Distances/ROI counts accompany area.
    static func halo(input: Raster, output: Raster) -> [String: Double] {
        guard valid(input, output), input.width >= 32, input.height >= 8 else { return [:] }
        let band = max(4, Int(ceil(Double(input.width) * 0.025)))
        var total = 0.0, count = 0.0, overshoot = 0.0, extent = 0.0, darkCount = 0.0, brightCount = 0.0
        for row in (input.height * 3 / 4)..<input.height {
            for edge in 1..<input.width {
                let left = (row * input.width + edge - 1) * 4, right = left + 4
                guard abs(y(input, left) - y(input, right)) > 0.1 else { continue }
                for side in [-1, 1] {
                    let anchorX = edge + side * (band * 2 + 1)
                    guard anchorX >= 0, anchorX < input.width else { continue }
                    let anchor = (row * input.width + anchorX) * 4
                    let shift = y(output, anchor) - y(input, anchor)
                    for distance in 0..<band {
                        let x = edge + (side < 0 ? -1 - distance : distance)
                        guard x >= 0, x < input.width else { continue }
                        let p = (row * input.width + x) * 4
                        guard input.pixels[p + 3] > 0.99, abs(y(input, p) - y(input, anchor)) < 0.0001 else { continue }
                        let residual = abs(y(output, p) - y(input, p) - shift)
                        if y(input, p) < max(y(input, left), y(input, right)) { darkCount += 1 } else { brightCount += 1 }
                        total += residual; count += 1; overshoot = max(overshoot, residual)
                        if residual > 0.005 { extent = max(extent, Double(distance + 1)) }
                    }
                }
            }
        }
        return ["halo_area": total / max(1, count), "halo_extent": extent, "edge_overshoot": overshoot, "halo_sample_count": count,
                "halo_dark_sample_count": darkCount, "halo_bright_sample_count": brightCount]
    }
    /// Difference of noisy/clean renders with identical settings removes intended
    /// detail changes. Independent lower-quarter ROI excludes the step boundary.
    static func noise(input: Raster, cleanInput: Raster, output: Raster, cleanOutput: Raster) -> [String: Double] {
        guard valid(input, cleanInput, output, cleanOutput), input.width >= 8, input.height >= 16 else { return [:] }
        var before: [Double] = [], after: [Double] = []
        for row in (input.height * 4 / 5)..<(input.height - 2) {
            for x in 2..<(input.width - 2) where abs(x - input.width / 2) > input.width / 10 {
                let p = (row * input.width + x) * 4
                before.append(y(input, p) - y(cleanInput, p)); after.append(y(output, p) - y(cleanOutput, p))
            }
        }
        func deviation(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(max(1, values.count))
            return sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(1, values.count)))
        }
        let initial = deviation(before), final = deviation(after)
        return ["noise_amplification": initial > 0 ? final / initial : 0, "noise_sample_count": Double(before.count)]
    }
}
