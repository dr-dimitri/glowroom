import Foundation
import Testing
@testable import PicEdit

@Suite("LC-06 independent noise and detail measurements")
struct LightcraftDenoiseComparisonTests {
    typealias Fixtures = LightcraftDenoiseFixtures
    typealias Comparison = LightcraftDenoiseComparison
    typealias Raster = AlgorithmEvaluationRaster

    @Test func splitSeedsChangeNoiseButNeverGroundTruthOrSupport() throws {
        for scene in Fixtures.sceneClasses {
            let tuning = try Fixtures.make(sceneClass: scene, split: .tuning, width: 128, height: 80)
            let repeated = try Fixtures.make(sceneClass: scene, split: .tuning, width: 128, height: 80)
            let acceptance = try Fixtures.make(sceneClass: scene, split: .acceptance, width: 128, height: 80)
            let clean = try #require(tuning.groundTruth), otherClean = try #require(acceptance.groundTruth)
            #expect(tuning.seed != acceptance.seed)
            #expect(tuning.input.sha256 == repeated.input.sha256)
            #expect(tuning.input.sha256 != acceptance.input.sha256)
            #expect(clean.sha256 == otherClean.sha256)
            for fixture in [tuning, acceptance] {
                let metrics = try Comparison.measurement(noisy: fixture.input, clean: clean, output: fixture.input)
                #expect(try #require(metrics["noise_sample_count"]) == Double(96 * 10))
                #expect(try #require(metrics["noise_luma_rmse"]) > 0)
                #expect(try #require(metrics["noise_chroma_rmse"]) > 0)
                #expect(try #require(metrics["detail_sample_count"]) > 0)
                if ["flat-dark", "flat-bright"].contains(scene) {
                    #expect(try #require(metrics["edge_sample_count"]) == 0)
                } else {
                    #expect(try #require(metrics["edge_sample_count"]) > 0)
                }
                #expect(metrics["alpha_error"] == 0 && metrics["hidden_rgb_error"] == 0)
            }
        }
    }

    @Test func knownNoiseReductionUsesBothComponentsAndCleanFixedAlpha() throws {
        let fixture = try Fixtures.make(sceneClass: "transparency", split: .tuning, width: 64, height: 48)
        let clean = try #require(fixture.groundTruth), noisy = fixture.input
        var half = noisy
        for p in stride(from: 0, to: noisy.pixels.count, by: 4) {
            for c in 0..<3 { half.pixels[p + c] = clean.pixels[p + c] + (noisy.pixels[p + c] - clean.pixels[p + c]) * 0.5 }
            half.pixels[p + 3] *= 0.5
        }
        for control in ["luminance", "chroma"] {
            #expect(try Comparison.strength(noisy: noisy, clean: clean, output: noisy, control: control) == 0)
            #expect(try Comparison.strength(noisy: noisy, clean: clean, output: clean, control: control) == 1)
            let strength = try Comparison.strength(noisy: noisy, clean: clean, output: half, control: control)
            #expect(abs(strength - 0.5) < 0.000001)
        }
        #expect(try Comparison.measurement(noisy: noisy, clean: clean, output: half)["alpha_error"] == 0.5)
    }

    @Test func matchingAndDetailRegionsAreIndependent() throws {
        let fixture = try Fixtures.make(sceneClass: "fine-lines", split: .acceptance, width: 64, height: 48)
        let noisy = fixture.input, clean = try #require(fixture.groundTruth)
        var perfectNoise = noisy, ruinedDetail = noisy
        for y in 0..<noisy.height {
            for x in 0..<noisy.width {
                let p = (y * noisy.width + x) * 4
                if Comparison.isNoisePixel(x: x, y: y, width: noisy.width, height: noisy.height) {
                    for c in 0..<3 { perfectNoise.pixels[p + c] = clean.pixels[p + c] }
                }
                if y >= noisy.height / 2 { for c in 0..<3 { ruinedDetail.pixels[p + c] = 0.18 } }
            }
        }
        #expect(try Comparison.strength(noisy: noisy, clean: clean, output: perfectNoise, control: "luminance") == 1)
        #expect(try Comparison.strength(noisy: noisy, clean: clean, output: ruinedDetail, control: "luminance") == 0)
        let original = try Comparison.measurement(noisy: noisy, clean: clean, output: noisy)
        let matchedOnly = try Comparison.measurement(noisy: noisy, clean: clean, output: perfectNoise)
        let damaged = try Comparison.measurement(noisy: noisy, clean: clean, output: ruinedDetail)
        #expect(original["detail_rgb_rmse"] == matchedOnly["detail_rgb_rmse"])
        #expect(original["edge_gradient_rmse"] == matchedOnly["edge_gradient_rmse"])
        #expect(try #require(damaged["detail_rgb_rmse"]) > #require(original["detail_rgb_rmse"]))
        #expect(try #require(damaged["edge_gradient_rmse"]) > #require(original["edge_gradient_rmse"]))
    }

    @Test func extraNoiseCannotMasqueradeAsPreservedGroundTruthEdges() throws {
        for scene in ["dark-edges", "color-lines", "texture"] {
            let fixture = try Fixtures.make(sceneClass: scene, split: .acceptance, width: 128, height: 80)
            let noisy = fixture.input, clean = try #require(fixture.groundTruth)
            var doubled = noisy
            for p in stride(from: 0, to: noisy.pixels.count, by: 4) {
                for c in 0..<3 { doubled.pixels[p + c] = clean.pixels[p + c] + 2 * (noisy.pixels[p + c] - clean.pixels[p + c]) }
            }
            let exact = try Comparison.measurement(noisy: noisy, clean: clean, output: clean)
            let original = try Comparison.measurement(noisy: noisy, clean: clean, output: noisy)
            let extra = try Comparison.measurement(noisy: noisy, clean: clean, output: doubled)
            for key in ["detail_rgb_rmse", "edge_gradient_rmse", "chroma_fringing_rmse"] {
                #expect(exact[key] == 0)
                #expect(abs(try #require(extra[key]) / #require(original[key]) - 2) < 0.00001)
            }
            #expect(original["edge_sample_count"] == extra["edge_sample_count"])
        }
    }

    @Test func linearOpponentErrorsAreStableAtBlackAndSeparateLumaFromChroma() throws {
        let black = try Raster(width: 2, height: 1, pixels: [0, 0, 0, 1, -0.2, -0.1, -0.3, 0.5])
        var lighter = black
        for p in [0, 4] { for c in 0..<3 { lighter.pixels[p + c] += 0.025 } }
        let luma = try Comparison.scaleDistance(reference: black, candidate: lighter)
        #expect(abs(try #require(luma["distance_luma_rmse"]) - 0.025) < 0.000001)
        #expect(try #require(luma["distance_chroma_rmse"]) < 0.000001)
        var colored = black
        for p in [0, 4] {
            colored.pixels[p] += 0.03
            colored.pixels[p + 1] -= Float((0.2126 * 0.03 + 0.0722 * 0.04) / 0.7152)
            colored.pixels[p + 2] += 0.04
        }
        let chroma = try Comparison.scaleDistance(reference: black, candidate: colored)
        #expect(try #require(chroma["distance_luma_rmse"]) < 0.000001)
        #expect(abs(try #require(chroma["distance_chroma_rmse"]) - sqrt((0.03 * 0.03 + 0.04 * 0.04) / 2)) < 0.000001)
    }

    @Test func driftAlphaHiddenRGBAndExtendedGamutRemainIndependentContracts() throws {
        let fixture = try Fixtures.make(sceneClass: "transparency", split: .tuning, width: 64, height: 48)
        let clean = try #require(fixture.groundTruth)
        var output = clean
        for p in stride(from: 0, to: output.pixels.count, by: 4) where clean.pixels[p + 3] > 0 {
            for c in 0..<3 { output.pixels[p + c] += 0.02 }
        }
        let hidden = try #require(stride(from: 0, to: output.pixels.count, by: 4).first { clean.pixels[$0 + 3] == 0 })
        output.pixels[hidden] = 0.7; output.pixels[3] = 0.75
        let metrics = try Comparison.measurement(noisy: fixture.input, clean: clean, output: output)
        #expect(abs(try #require(metrics["luma_drift_signed"]) - 0.02) < 0.000001)
        #expect(abs(try #require(metrics["luma_drift_mean"]) - 0.02) < 0.000001)
        #expect(metrics["alpha_error"] == 0.25)
        #expect(abs(try #require(metrics["hidden_rgb_error"]) - 0.7) < 0.000001)
        let p3 = try Fixtures.make(sceneClass: "p3-dark", split: .tuning, width: 32, height: 32)
        #expect(try #require(p3.groundTruth).pixels.contains { $0 < 0 })
        let exact = try Comparison.measurement(noisy: p3.input, clean: #require(p3.groundTruth), output: #require(p3.groundTruth))
        #expect(try #require(exact["gamut_fraction"]) > 0)
        #expect(exact["detail_rgb_rmse"] == 0)
    }

    @Test func areaAverageWeightsCoverageAndNonIntegerPixelFootprints() throws {
        // Three source columns become two: weights [2/3,1/3] and [1/3,2/3].
        // Hidden red is deliberately mutated after canonical initialization.
        var input = try Raster(width: 3, height: 2, pixels: [
            0, 0, 0, 0, 0, 2, 0, 0.5, 0, 0, 3, 1,
            0, 0, 0, 0, 0, 2, 0, 0.5, 0, 0, 3, 1])
        input.pixels[0] = 50; input.pixels[12] = 50
        let original = input.sha256
        let output = try Fixtures.areaAverage(input, width: 2, height: 1)
        let expected: [Float] = [0, 2, 0, 1.0 / 6, 0, 0.4, 2.4, 5.0 / 6]
        for index in expected.indices { #expect(abs(output.pixels[index] - expected[index]) < 0.000001) }
        #expect(input.sha256 == original)
        let tall = try Raster(width: 2, height: 3, pixels: [
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 2, 0, 0.5, 0, 2, 0, 0.5,
            0, 0, 3, 1, 0, 0, 3, 1])
        let vertical = try Fixtures.areaAverage(tall, width: 1, height: 2)
        for index in expected.indices { #expect(abs(vertical.pixels[index] - expected[index]) < 0.000001) }
    }

    @Test func areaAverageRetainsSignedConstantDataAndDoesNotReusePreviousSources() throws {
        for dimensions in [(128, 80, 32, 20), (16, 128, 8, 7), (128, 16, 7, 8)] {
            let (w, h, targetW, targetH) = dimensions
            let values: [Float] = [-0.2, 0.25, 1.4, 0.3]
            let first = try Raster(width: w, height: h, pixels: (0..<(w * h)).flatMap { _ in values })
            let second = try Raster(width: w, height: h, pixels: (0..<(w * h)).flatMap { _ in [Float(0.6), 0.1, 0.2, 1] })
            let a = try Fixtures.areaAverage(first, width: targetW, height: targetH)
            let b = try Fixtures.areaAverage(second, width: targetW, height: targetH)
            for p in stride(from: 0, to: a.pixels.count, by: 4) {
                for c in 0..<4 { #expect(abs(a.pixels[p + c] - values[c]) < 0.000001) }
            }
            #expect(a.sha256 != b.sha256)
            #expect(try Fixtures.areaAverage(first, width: targetW, height: targetH).sha256 == a.sha256)
        }
        let tiny = try Raster(width: 1, height: 1, pixels: [-0.1, 0.2, 1.1, 0.5])
        #expect(try Fixtures.areaAverage(tiny, width: 1, height: 1).sha256 == tiny.sha256)
    }

    @Test func areaAverageActuallyAveragesNoiseInsteadOfSelectingOrLanczosSampling() throws {
        let pixels = (0..<16).flatMap { i -> [Float] in
            let value: Float = (i % 4 + i / 4).isMultiple(of: 2) ? -1 : 1
            return [value, value, value, 1]
        }
        let input = try Raster(width: 4, height: 4, pixels: pixels)
        let output = try Fixtures.areaAverage(input, width: 2, height: 2)
        for p in stride(from: 0, to: output.pixels.count, by: 4) {
            #expect(output.pixels[p] == 0 && output.pixels[p + 1] == 0 && output.pixels[p + 2] == 0)
            #expect(output.pixels[p + 3] == 1)
        }
    }

    @Test func invalidAndUnsupportedInputsAreRejected() throws {
        let fixture = try Fixtures.make(sceneClass: "flat-dark", split: .tuning, width: 16, height: 16)
        let clean = try #require(fixture.groundTruth)
        var invalid = fixture.input; invalid.pixels[0] = .nan
        #expect(throws: Error.self) { _ = try Fixtures.areaAverage(invalid, width: 8, height: 8) }
        invalid = fixture.input; invalid.pixels.removeLast()
        #expect(throws: Error.self) { _ = try Comparison.measurement(noisy: invalid, clean: clean, output: clean) }
        #expect(throws: Error.self) { _ = try Fixtures.areaAverage(clean, width: 17, height: 16) }
        #expect(throws: Error.self) { _ = try Fixtures.areaAverage(clean, width: 0, height: 8) }
        #expect(throws: Error.self) { _ = try Comparison.strength(noisy: clean, clean: clean, output: clean, control: "luminance") }
        #expect(throws: Error.self) { _ = try Comparison.strength(noisy: fixture.input, clean: clean, output: clean, control: "unknown") }
        let hidden = try Raster(width: 16, height: 16, pixels: [Float](repeating: 0, count: 16 * 16 * 4))
        #expect(throws: Error.self) { _ = try Comparison.measurement(noisy: hidden, clean: hidden, output: hidden) }
        #expect(throws: Error.self) { _ = try Comparison.scaleDistance(reference: hidden, candidate: hidden) }
        let tiny = try Raster(width: 1, height: 1, pixels: [0, 0, 0, 1])
        #expect(throws: Error.self) { _ = try Comparison.measurement(noisy: tiny, clean: tiny, output: tiny) }
    }

    @Test func cancelledFixtureResamplingAndMeasurementsPublishNoResult() async throws {
        let fixture = try Fixtures.make(sceneClass: "texture", split: .tuning, width: 128, height: 80)
        let clean = try #require(fixture.groundTruth)
        let generation = Task { withUnsafeCurrentTask { $0?.cancel() }; return try Fixtures.make(sceneClass: "texture", split: .acceptance) }
        await #expect(throws: CancellationError.self) { _ = try await generation.value }
        let resampling = Task { withUnsafeCurrentTask { $0?.cancel() }; return try Fixtures.areaAverage(fixture.input, width: 32, height: 20) }
        await #expect(throws: CancellationError.self) { _ = try await resampling.value }
        let measurement = Task { withUnsafeCurrentTask { $0?.cancel() }; return try Comparison.measurement(noisy: fixture.input, clean: clean, output: clean) }
        await #expect(throws: CancellationError.self) { _ = try await measurement.value }
    }
}
