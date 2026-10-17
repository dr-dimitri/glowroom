import Foundation
import Testing
@testable import PicEdit

@Suite("LC-05 input-relative color measurements")
struct LightcraftColorComparisonTests {
    typealias Comparison = LightcraftColorComparison
    typealias Fixtures = LightcraftColorFixtures
    typealias Raster = AlgorithmEvaluationRaster

    @Test func splitsHaveExactlyIdenticalColorAndAlphaDistributions() throws {
        for scene in Fixtures.sceneClasses {
            let tuning = try Fixtures.make(sceneClass: scene, split: .tuning, width: 64, height: 40).input
            let acceptance = try Fixtures.make(sceneClass: scene, split: .acceptance, width: 64, height: 40).input
            let repeated = try Fixtures.make(sceneClass: scene, split: .tuning, width: 64, height: 40).input
            #expect(tuning.sha256 == repeated.sha256)
            #expect(tuning.sha256 != acceptance.sha256)
            let count = tuning.width * tuning.height
            var seen = Set<Int>()
            var identical = true
            for destination in 0..<count {
                let source = Fixtures.sourceIndex(destination: destination, count: count, split: .acceptance)
                seen.insert(source)
                identical = identical && Fixtures.destinationIndex(source: source, count: count, split: .acceptance) == destination
                for c in 0..<4 { identical = identical && tuning.pixels[source * 4 + c] == acceptance.pixels[destination * 4 + c] }
            }
            #expect(seen.count == count && identical)
        }
    }
    @Test func signedOklabMatchesIndependentKnownAxes() {
        let white = Comparison.lab(1, 1, 1), dark = Comparison.lab(-0.125, -0.125, -0.125)
        #expect(abs(white.x - 1) < 0.000001 && Comparison.chroma(white) < 0.000001)
        #expect(abs(dark.x + 0.5) < 0.000001 && Comparison.chroma(dark) < 0.000001)
        let red = Comparison.lab(1, 0, 0)
        #expect(abs(red.x - 0.62795536) < 0.000001)
        #expect(abs(red.y - 0.22486306) < 0.000001)
        #expect(abs(red.z - 0.12584630) < 0.000001)
        #expect(Comparison.lab(0, 0, 0) == SIMD3<Double>(repeating: 0))
    }
    @Test func matchingIncludesLowChromaAndUsesFixedInputAlpha() throws {
        let input = try raster([color(0.5, 0.001, 30), color(0.5, 0.1, 60), color(0.5, 0.1, 90)], alpha: [1, 0.5, 0])
        let output = try raster([color(0.5, 0.002, 30), color(0.5, 0.13, 60), color(0.8, 0.4, 120)], alpha: [1, 0.25, 0])
        let strength = try Comparison.strength(input: input, output: output)
        #expect(abs(strength - (0.001 + 0.5 * 0.03) / 1.5) < 0.000001)
        let metrics = try Comparison.measurement(input: input, output: output)
        #expect(abs(try #require(metrics["mean_chroma_delta"]) - strength) < 0.000000001)
        #expect(metrics["visible_weight"] == 1.5)
        #expect(metrics["alpha_error"] == 0.25)
        #expect(try Comparison.strength(input: input, output: input) == 0)
    }
    @Test func hueAndLightnessAreRelativeToInputWithCircularHueDistance() throws {
        let input = try raster([color(0.5, 0.08, 350), color(0.6, 0.08, 100)])
        let output = try raster([color(0.5, 0.08, 10), color(0.6, 0.08, 120)])
        let metrics = try Comparison.measurement(input: input, output: output)
        #expect(abs(try #require(metrics["hue_drift_mean_degrees"]) - 20) < 0.0001)
        #expect(abs(try #require(metrics["hue_drift_max_degrees"]) - 20) < 0.0001)
        #expect(try #require(metrics["lightness_drift_mean"]) < 0.000001)
        #expect(metrics["hue_sample_count"] == 2 && metrics["hue_missing_count"] == 0)
        let lifted = try raster([color(0.55, 0.08, 350), color(0.65, 0.08, 100)])
        #expect(abs(try #require(Comparison.measurement(input: input, output: lifted)["lightness_drift_mean"]) - 0.05) < 0.000001)
    }
    @Test func removingChromaCannotDisappearFromTheHueMask() throws {
        let input = try raster([color(0.5, 0.08, 60), color(0.5, 0.08, 120)])
        let output = try raster([SIMD3<Double>(repeating: 0.125), color(0.5, 0.08, 120)])
        let metrics = try Comparison.measurement(input: input, output: output)
        #expect(metrics["hue_sample_count"] == 2)
        #expect(metrics["hue_missing_count"] == 1)
        #expect(metrics["hue_loss_fraction"] == 0.5)
        #expect(metrics["hue_drift_max_degrees"] == 180)
        #expect(abs(try #require(metrics["hue_drift_mean_degrees"]) - 90) < 0.00001)
    }
    @Test func neutralGamutAndAlphaContractsDoNotDependOnEffectMatching() throws {
        let input = try raster([SIMD3<Double>(repeating: 0.18), .init(-0.1, 0.4, 1.2), .init(5, 2, -3)], alpha: [1, 1, 0])
        var changed = input
        changed.pixels[2] += 0.01
        changed.pixels[8] = 0.2
        let metrics = try Comparison.measurement(input: input, output: changed)
        #expect(metrics["neutral_sample_count"] == 1)
        #expect(try #require(metrics["neutral_chroma_max"]) > 0.001)
        #expect(abs(try #require(metrics["gamut_fraction"]) - 1.0 / 3) < 0.000001)
        #expect(abs(try #require(metrics["hidden_rgb_error"]) - 0.2) < 0.000001)
        #expect(metrics["hue_sample_count"] == 1)
        let p3 = try Fixtures.make(sceneClass: "p3-boundary", split: .tuning, width: 64, height: 40).input
        #expect(p3.pixels.contains { $0 < 0 } && p3.pixels.contains { $0 > 1 })
        let extended = try Fixtures.make(sceneClass: "extended-dark", split: .tuning, width: 64, height: 40).input
        #expect(try Comparison.measurement(input: extended, output: extended).values.allSatisfy { $0.isFinite })
    }
    @Test func gradationFollowsCanonicalRampAcrossSpatialPermutations() throws {
        for split in Fixtures.Split.allCases {
            let input = try Fixtures.make(sceneClass: "color-gradients", split: split, width: 64, height: 40).input
            let identity = try Comparison.measurement(input: input, output: input, sceneClass: "color-gradients", split: split)
            let measuredSupport = try #require(identity["gradation_sample_count"])
            #expect(measuredSupport == Double((input.width - 1) * input.height))
            #expect(identity["gradation_loss_fraction"] == 0)
            var collapsed = input, reversed = input
            let count = input.width * input.height
            for source in 0..<count {
                let target = Fixtures.destinationIndex(source: source, count: count, split: split)
                let opposite = source / input.width * input.width + input.width - 1 - source % input.width
                let oppositeTarget = Fixtures.destinationIndex(source: opposite, count: count, split: split)
                for c in 0..<3 {
                    collapsed.pixels[target * 4 + c] = 0.18
                    reversed.pixels[target * 4 + c] = input.pixels[oppositeTarget * 4 + c]
                }
            }
            let flat = try Comparison.gradation(input: input, output: collapsed, split: split)
            let backwards = try Comparison.gradation(input: input, output: reversed, split: split)
            #expect(flat["gradation_collapse_fraction"] == 1 && flat["gradation_reversal_fraction"] == 0)
            #expect(backwards["gradation_reversal_fraction"] == 1 && backwards["gradation_collapse_fraction"] == 0)
        }
    }
    @Test func redOrangeDiagnosticUsesTheInputHueAndMatchedLightnessChromaDistribution() throws {
        let input = try Fixtures.make(sceneClass: "red-orange", split: .tuning, width: 64, height: 40).input
        var output = input
        for p in stride(from: 0, to: input.pixels.count, by: 4) {
            let initial = Comparison.lab(input, p), hue = atan2(initial.z, initial.y) * 180 / .pi
            let factor = hue >= 10 && hue <= 75 ? 1.1 : 1.4
            let result = color(initial.x, Comparison.chroma(initial) * factor, hue)
            output.pixels[p] = Float(result.x); output.pixels[p + 1] = Float(result.y); output.pixels[p + 2] = Float(result.z)
        }
        let metrics = try Comparison.measurement(input: input, output: output, sceneClass: "red-orange")
        #expect(try #require(metrics["red_orange_sample_count"]) > 0)
        #expect(try #require(metrics["comparison_hue_sample_count"]) > 0)
        #expect(abs(try #require(metrics["red_orange_chroma_gain_mean"]) - 0.1) < 0.00001)
        #expect(abs(try #require(metrics["comparison_chroma_gain_mean"]) - 0.4) < 0.00001)
    }
    @Test func invalidOrEmptyMeasurementSupportIsRejected() throws {
        let input = try raster([color(0.5, 0.1, 60)])
        var bad = input; bad.pixels[0] = .nan
        #expect(throws: AlgorithmEvaluationMetricError.self) { _ = try Comparison.strength(input: input, output: bad) }
        #expect(throws: AlgorithmEvaluationMetricError.self) { _ = try Comparison.measurement(input: input, output: bad) }
        bad = input; bad.pixels.removeLast()
        #expect(throws: AlgorithmEvaluationMetricError.self) { _ = try Comparison.measurement(input: input, output: bad) }
        bad = input; bad.pixels[3] = -1
        #expect(throws: AlgorithmEvaluationMetricError.self) { _ = try Comparison.measurement(input: input, output: bad) }
        let hidden = try raster([color(0.5, 0.1, 60)], alpha: [0])
        #expect(throws: AlgorithmEvaluationMetricError.self) { _ = try Comparison.strength(input: hidden, output: hidden) }
    }

    private func color(_ lightness: Double, _ chroma: Double, _ hue: Double) -> SIMD3<Double> { Fixtures.lch(lightness, chroma, hue) }
    private func raster(_ colors: [SIMD3<Double>], alpha: [Float]? = nil) throws -> Raster {
        var pixels: [Float] = []
        for (index, color) in colors.enumerated() { pixels += [Float(color.x), Float(color.y), Float(color.z), alpha?[index] ?? 1] }
        return try .init(width: colors.count, height: 1, pixels: pixels)
    }
}
