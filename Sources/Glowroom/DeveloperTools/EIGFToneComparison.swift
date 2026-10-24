import Foundation
import GlowroomCore

/// Reuses LC-03's signed effect matching, fine-line and plateau-halo metrics;
/// owns a separate immutable protocol so LC-03's No-Go remains unchanged.
enum EIGFToneComparison {
    struct Manifest: Codable {
        let protocolID: String
        let sourceCommit: String
        let comparison: LightcraftToneComparison.Manifest
        let sceneClasses: [String]
        let maximumNoiseGainRatio: Double
        static func load(_ url: URL) throws -> Self {
            let m = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            let c = m.comparison
            guard m.protocolID == EIGFToneReference.processID,
                  m.sourceCommit == "ff93cf64c5e393a903c57ebf9accf655091bf972",
                  m.sceneClasses == AlgorithmEvaluationFixtures.sceneClasses + ["branches", "p3", "hdr"],
                  m.maximumNoiseGainRatio == 1.1,
                  c.schemaVersion == 1, c.qualityWidth == 512, c.qualityHeight == 320,
                  c.directions.count == 8, Set(c.directions.map(\.id)).count == 8,
                  Set(c.directions.map { "\($0.control):\($0.value)" }).count == 8,
                  c.directions.allSatisfy({ ["shadows", "highlights"].contains($0.control)
                    && [-40.0, -20, 20, 40].contains($0.value) && $0.primary == (abs($0.value) == 20)
                    && $0.id == "\($0.control)-\($0.value > 0 ? "positive" : "negative")-\(Int(abs($0.value)))" }),
                  c.matching.shadowMaximumInputY == 0.25, c.matching.highlightMinimumInputY == 0.5,
                  c.matching.minimumAbsoluteTarget == 0.002,
                  c.matching.maximumAbsoluteDeltaError == 0.003, c.matching.maximumRelativeDeltaError == 0.05,
                  c.matching.coarseSteps == 33, c.matching.refinementSteps == 33,
                  c.primary.metric == "log_line_contrast_error", c.primary.minimumInputContrastEV == 0.05,
                  c.primary.minimumRelativeImprovement == 0.1, c.primary.maximumPerCaseRegression == 0.05,
                  c.criticalLimits == ["haloOvershoot": 0.02, "haloUndershoot": 0.02,
                    "hueDeviationDegrees": 3, "gamutFractionIncrease": 0.02,
                    "clippingFractionIncrease": 0.02, "alphaError": 0.001] else {
                throw EIGFToneReference.Failure.invalid("Invalid or changed preregistered EIGF protocol")
            }
            return m
        }
    }
    struct Calibration: Codable {
        let manifestSHA256: String
        let records: [Record]
        struct Record: Codable {
            let basis: EIGFToneReference.Basis
            let fit: LightcraftToneComparison.Calibration
        }
    }

    static func settings(_ direction: LightcraftToneComparison.Direction, value: Double? = nil) -> EditSettings {
        var result = direction.settings(value: value)
        result.toneProcessingVersion = .consistentV2
        return result
    }

    static func fixture(_ scene: String, split: AlgorithmEvaluationFixtures.Split,
                        width: Int, height: Int) throws -> AlgorithmEvaluationFixtures.Fixture {
        if AlgorithmEvaluationFixtures.sceneClasses.contains(scene) {
            return try AlgorithmEvaluationFixtures.make(sceneClass: scene, split: split, width: width, height: height)
        }
        guard ["branches", "p3", "hdr"].contains(scene), width >= 8, height >= 8,
              width <= 8192, height <= 8192, width * height <= 32_000_000 else {
            throw AlgorithmEvaluationFixtureError.invalidRaster
        }
        let phase = split == .tuning ? 3 : 11
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let p = (y * width + x) * 4
            let rgb: (Float, Float, Float)
            switch scene {
            case "branches":
                let line = abs((x * 3 + y + phase) % 61 - 30) <= 1 || abs((x + y * 2 + phase) % 83 - 41) <= 1
                let v: Float = y < height / 2 ? (line ? 0.92 : 0.035) : (line ? 0.035 : 0.92)
                rgb = (v, v, v)
            case "p3":
                // Independently derived D65 Display-P3 -> linear sRGB matrix.
                // A P3 red can exceed the sRGB cube without being HDR.
                let splitScale: Float = split == .tuning ? 0.96 : 1
                let r: Float = (x < width / 2 ? 0.8 : 0.02) * splitScale
                let g: Float = (x < width / 2 ? 0.05 : 0.7) * splitScale
                let b: Float = (0.05 + Float(y) / Float(height) * 0.2) * splitScale
                rgb = (1.22494018 * r - 0.22494018 * g,
                       -0.04205695 * r + 1.04205695 * g,
                       -0.01963755 * r - 0.07863605 * g + 1.0982736 * b)
            default:
                let level: Float = [0, 1e-8, 0.01, 0.18, 0.9, 1, 2, 8][min(7, x * 8 / width)] * (split == .tuning ? 0.97 : 1)
                rgb = (level, level, level)
            }
            pixels[p] = rgb.0; pixels[p + 1] = rgb.1; pixels[p + 2] = rgb.2
            pixels[p + 3] = scene == "p3" && y < height / 4 ? (x < width / 4 ? 0 : 0.5) : 1
        } }
        return .init(id: "\(split.rawValue)-\(scene)", sceneClass: scene, split: split,
            seed: UInt64(phase), input: try .init(width: width, height: height, pixels: pixels), groundTruth: nil)
    }

    /// Bounded SDR target gamut crossings, independently of the extended-sRGB
    /// diagnostic metric. Existing excursions are subtracted. HDR is unbounded
    /// in this experiment and receives no SDR cube/clipping gate.
    static func targetGamutIncrease(baseline: AlgorithmEvaluationRaster, candidate: AlgorithmEvaluationRaster,
                                    p3: Bool, clipping: Bool = false, newOnly: Bool = false) -> Double {
        func channels(_ r: Double, _ g: Double, _ b: Double) -> [Double] {
            p3 ? [0.8224619687143624 * r + 0.17753803128563753 * g,
                0.033194198850963016 * r + 0.9668058011490369 * g,
                0.017082630721116855 * r + 0.0723974406639614 * g + 0.9105199286149217 * b] : [r, g, b]
        }
        func outside(_ x: Double) -> Bool { clipping ? (x <= 0 || x >= 1) : (x < -1e-5 || x > 1.00001) }
        var difference = 0.0, weight = 0.0
        for p in stride(from: 0, to: baseline.pixels.count, by: 4) {
            let a = Double(baseline.pixels[p + 3])
            guard a > 0 else { continue }
            let before = channels(Double(baseline.pixels[p]), Double(baseline.pixels[p + 1]), Double(baseline.pixels[p + 2]))
            let after = channels(Double(candidate.pixels[p]), Double(candidate.pixels[p + 1]), Double(candidate.pixels[p + 2]))
            if newOnly { difference += a * Double(zip(before, after).filter { !outside($0.0) && outside($0.1) }.count) }
            else { difference += a * Double(after.filter(outside).count - before.filter(outside).count) }
            weight += a
        }
        return max(0, difference) / max(1e-20, 3 * weight)
    }

    /// Noise standard deviation after subtracting the clean signal processed
    /// by the SAME operator/settings. Intended tone change earns no noise credit.
    static func noiseRMSE(_ noisy: AlgorithmEvaluationRaster, clean: AlgorithmEvaluationRaster) -> Double {
        var sum = 0.0, count = 0.0
        for p in stride(from: 0, to: noisy.pixels.count, by: 4) {
            let delta = LightcraftToneComparison.y(noisy, p) - LightcraftToneComparison.y(clean, p)
            let alpha = Double(clean.pixels[p + 3])
            sum += alpha * delta * delta; count += alpha
        }
        return sqrt(sum / max(1e-20, count))
    }
}
