import Foundation
import GlowroomCore

/// Preregistered LC-03 measurements. The generic LC-01 gradient-energy proxy
/// cannot distinguish tonal compression from loss of fine-line contrast.
enum LightcraftToneComparison {
    struct Direction: Codable {
        let id: String
        let control: String
        let value: Double
        let primary: Bool
        func settings(value override: Double? = nil) -> EditSettings {
            var result = EditSettings.neutral
            if control == "shadows" { result.shadows = override ?? value }
            else { result.highlights = override ?? value }
            return result
        }
    }
    struct Manifest: Codable {
        struct Matching: Codable {
            let shadowMaximumInputY: Double
            let highlightMinimumInputY: Double
            let minimumAbsoluteTarget: Double
            let maximumAbsoluteDeltaError: Double
            let maximumRelativeDeltaError: Double
            let coarseSteps: Int
            let refinementSteps: Int
        }
        struct Primary: Codable {
            let metric: String
            let minimumRelativeImprovement: Double
            let maximumPerCaseRegression: Double
            let minimumInputContrastEV: Double
        }
        let schemaVersion: Int
        let sourceCommit: String
        let qualityWidth: Int
        let qualityHeight: Int
        /// v1 used texture, which turned out to have no matched tone response.
        /// A separate v2 experiment selects fine-lines without changing quality gates.
        let performanceSceneClass: String?
        let directions: [Direction]
        let matching: Matching
        let primary: Primary
        let criticalLimits: [String: Double]
        static func load(_ url: URL) throws -> Self {
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard value.schemaVersion == 1, value.sourceCommit == "f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15",
                  value.qualityWidth == 512, value.qualityHeight == 320,
                  value.performanceSceneClass.map({ ["texture", "fine-lines"].contains($0) }) ?? true,
                  value.directions.count == 8, Set(value.directions.map(\.id)).count == 8,
                  Set(value.directions.map { "\($0.control):\($0.value)" }).count == 8,
                  value.directions.allSatisfy({ ["shadows", "highlights"].contains($0.control) && [-40.0, -20, 20, 40].contains($0.value) && $0.primary == (abs($0.value) == 20) }),
                  value.directions.allSatisfy({ $0.id == "\($0.control)-\($0.value > 0 ? "positive" : "negative")-\(Int(abs($0.value)))" }),
                  value.matching.coarseSteps == 33, value.matching.refinementSteps == 33,
                  value.matching.shadowMaximumInputY < value.matching.highlightMinimumInputY,
                  value.matching.highlightMinimumInputY < 1,
                  [value.matching.shadowMaximumInputY, value.matching.highlightMinimumInputY,
                   value.matching.minimumAbsoluteTarget, value.matching.maximumAbsoluteDeltaError,
                   value.matching.maximumRelativeDeltaError, value.primary.minimumRelativeImprovement,
                   value.primary.maximumPerCaseRegression, value.primary.minimumInputContrastEV].allSatisfy({ $0.isFinite && $0 > 0 }),
                  value.primary.metric == "log_line_contrast_error",
                  Set(value.criticalLimits.keys) == Set(["haloOvershoot", "haloUndershoot", "hueDeviationDegrees", "gamutFractionIncrease", "clippingFractionIncrease", "alphaError"]),
                  value.criticalLimits.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw AlgorithmEvaluationMetricError.invalid("Invalid LC-03 manifest")
            }
            return value
        }
    }
    struct Calibration: Codable {
        let sceneClass: String
        let directionID: String
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

    static func y(_ raster: AlgorithmEvaluationRaster, _ offset: Int) -> Double {
        0.2126 * Double(raster.pixels[offset]) + 0.7152 * Double(raster.pixels[offset + 1]) + 0.0722 * Double(raster.pixels[offset + 2])
    }
    static func strength(input: AlgorithmEvaluationRaster, output: AlgorithmEvaluationRaster,
                         direction: Direction, manifest: Manifest) -> Double? {
        guard input.width == output.width, input.height == output.height,
              input.pixels.count == output.pixels.count,
              input.pixels.allSatisfy(\.isFinite), output.pixels.allSatisfy(\.isFinite) else { return nil }
        var total = 0.0, weight = 0.0
        for p in stride(from: 0, to: input.pixels.count, by: 4) {
            let a = Double(input.pixels[p + 3]), luminance = y(input, p)
            guard a > 0, direction.control == "shadows" ? luminance < manifest.matching.shadowMaximumInputY : luminance > manifest.matching.highlightMinimumInputY else { continue }
            total += (y(output, p) - luminance) * a
            weight += a
        }
        return weight > 0 ? total / weight : nil
    }
    static func matched(_ target: Double?, _ measured: Double?, manifest: Manifest) -> Bool {
        guard let target, let measured, target.isFinite, measured.isFinite,
              abs(target) >= manifest.matching.minimumAbsoluteTarget,
              measured != 0, target.sign == measured.sign else { return false }
        return abs(target - measured) <= max(manifest.matching.maximumAbsoluteDeltaError,
                                             abs(target) * manifest.matching.maximumRelativeDeltaError)
    }

    /// Each known thin-line pixel is compared to a nearby background pixel on
    /// the same half of the synthetic scene. The ratio is invariant to a common
    /// multiplicative EV shift. Both bright-on-dark and dark-on-bright are
    /// reported, so improvements cannot cancel regressions between the halves.
    static func lineContrast(input: AlgorithmEvaluationRaster, output: AlgorithmEvaluationRaster,
                             minimumContrastEV: Double) -> [String: Double] {
        guard input.width >= 5, input.height >= 5, input.width == output.width,
              input.height == output.height else { return [:] }
        var sums = [0.0, 0.0], counts = [0.0, 0.0]
        for row in 2..<(input.height - 2) {
            let half = row < input.height / 2 ? 0 : 1
            guard abs(row - input.height / 2) > 2 else { continue }
            for x in 2..<(input.width - 2) {
                let p = (row * input.width + x) * 4, value = y(input, p)
                let isLine = half == 0 ? value > 0.8 : value < 0.1
                guard isLine else { continue }
                let neighbors = [-2, -1, 1, 2].map { p + $0 * 4 }
                guard let q = neighbors.first(where: { half == 0 ? y(input, $0) < 0.1 : y(input, $0) > 0.8 }) else { continue }
                let before = log2(max(1e-7, value) / max(1e-7, y(input, q)))
                let after = log2(max(1e-7, y(output, p)) / max(1e-7, y(output, q)))
                guard abs(before) >= minimumContrastEV else { continue }
                sums[half] += abs(after - before) / abs(before)
                counts[half] += 1
            }
        }
        guard counts.allSatisfy({ $0 > 0 }) else { return ["bright_line_count": counts[0], "dark_line_count": counts[1]] }
        return ["bright_line_error": sums[0] / counts[0], "dark_line_error": sums[1] / counts[1],
                "bright_line_count": counts[0], "dark_line_count": counts[1],
                "log_line_contrast_error": (sums[0] / counts[0] + sums[1] / counts[1]) / 2]
    }

    /// Edge residual after subtracting the SAME side's far-plateau tone shift.
    /// Intended global lift/compression is not mislabeled a halo.
    static func halo(input: AlgorithmEvaluationRaster, output: AlgorithmEvaluationRaster) -> [String: Double] {
        guard input.width > 1, input.width == output.width, input.height == output.height else { return [:] }
        let width = input.width, row = input.height / 2
        var edge = 1, gradient = 0.0
        for x in 1..<width {
            let delta = abs(y(input, (row * width + x) * 4) - y(input, (row * width + x - 1) * 4))
            if delta > gradient { gradient = delta; edge = x }
        }
        guard gradient > 0.1 else { return ["halo_overshoot": 0, "halo_undershoot": 0, "edge_support": 0] }
        var over = 0.0, under = 0.0
        let band = max(4, Int(ceil(Double(width) * 0.06)))
        for side in 0...1 {
            let plateau = side == 0 ? 0..<max(1, edge / 3) : (edge + (width - edge) * 2 / 3)..<width
            var shift = 0.0, count = 0.0
            for x in plateau {
                let p = (row * width + x) * 4
                shift += y(output, p) - y(input, p); count += 1
            }
            shift /= max(1, count)
            let near = side == 0 ? max(0, edge - band)..<edge : edge..<min(width, edge + band)
            for x in near {
                let p = (row * width + x) * 4
                let residual = y(output, p) - y(input, p) - shift
                over = max(over, residual); under = max(under, -residual)
            }
        }
        return ["halo_overshoot": over, "halo_undershoot": under, "edge_support": gradient]
    }
}
