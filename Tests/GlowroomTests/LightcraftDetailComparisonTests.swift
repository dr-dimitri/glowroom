import Foundation
import Testing
@testable import Glowroom

@Suite("LC-04 independent detail and artifact measurements")
struct LightcraftDetailComparisonTests {
    typealias Comparison = LightcraftDetailComparison
    @Test func fixturesAreDeterministicAndSeparatedWithPrimarySupport() throws {
        for scene in LightcraftDetailFixtures.sceneClasses {
            let first = try LightcraftDetailFixtures.make(sceneClass: scene, split: .tuning)
            let repeatFixture = try LightcraftDetailFixtures.make(sceneClass: scene, split: .tuning)
            let acceptance = try LightcraftDetailFixtures.make(sceneClass: scene, split: .acceptance)
            #expect(first.input.sha256 == repeatFixture.input.sha256)
            #expect(first.input.sha256 != acceptance.input.sha256)
            if ["masonry-textiles", "lowlight-noise", "skin-pores"].contains(scene) {
                let signal = first.groundTruth ?? first.input
                for control in ["clarity", "texture"] {
                    let detail = Comparison.detail(input: signal, output: signal, control: control)
                    #expect(try #require(detail["detail_sample_count"]) > 100)
                    #expect(try #require(detail["detail_contrast_input"]) > 0)
                }
            }
            if ["hard-edge", "sky-branches"].contains(scene) {
                let halo = Comparison.halo(input: first.input, output: first.input)
                for key in ["halo_sample_count", "halo_dark_sample_count", "halo_bright_sample_count"] {
                    #expect(try #require(halo[key]) > 0)
                }
                for control in ["clarity", "texture"] {
                    let detail = Comparison.detail(input: first.input, output: first.input, control: control, sceneClass: scene)
                    #expect(try #require(detail["detail_sample_count"]) > 100)
                    #expect(detail["detail_contrast_delta"] == 0)
                }
            }
        }
    }
    @Test func v2PrimaryProbesHaveEqualWholePeriodContrastAndSupportAcrossSplits() throws {
        for scene in ["hard-edge", "sky-branches"] {
            let tuning = try LightcraftDetailFixtures.make(sceneClass: scene, split: .tuning).input
            let acceptance = try LightcraftDetailFixtures.make(sceneClass: scene, split: .acceptance).input
            let region = try #require(Comparison.probeRegion(width: 512, height: 320, sceneClass: scene))
            #expect(region.columns == 64..<448 && region.rows == 48..<112)
            for control in ["clarity", "texture"] {
                let first = Comparison.detail(input: tuning, output: tuning, control: control, sceneClass: scene)
                let second = Comparison.detail(input: acceptance, output: acceptance, control: control, sceneClass: scene)
                #expect(try #require(first["detail_sample_count"]) > 40_000)
                #expect(first["detail_sample_count"] == second["detail_sample_count"])
                #expect(abs(try #require(first["detail_contrast_input"]) - #require(second["detail_contrast_input"])) < 0.000000001)
                #expect(first["detail_contrast_delta"] == 0 && second["detail_contrast_delta"] == 0)
            }
            let excluded = Comparison.edgeExclusion(tuning)
            // Both endpoints retain the original strong-edge guard; the panel
            // also supplies a four-pixel margin beyond the whole-period starts.
            let supported = region.rows.allSatisfy { row in region.columns.allSatisfy { x in
                !excluded[row * 512 + x] && !excluded[row * 512 + x + 4] && !excluded[(row + 4) * 512 + x]
            } }
            #expect(supported)
        }
        let scaled = try #require(Comparison.probeRegion(width: 1024, height: 640, sceneClass: "hard-edge"))
        #expect(scaled.columns == 128..<896 && scaled.rows == 96..<224)
        #expect(Comparison.probeRegion(width: 512, height: 320, sceneClass: "masonry-textiles") == nil)
    }
    @Test func v2ProbeLeavesAllLowerHalfPixelsUntouchedAndCannotMatchHaloChanges() throws {
        let width = 512, height = 320
        let original = (0..<(width * height * 4)).map { Float($0 % 257) / 256 }
        for split in AlgorithmEvaluationFixtures.Split.allCases {
            var panel = original
            try LightcraftDetailFixtures.addDetailProbe(to: &panel, width: width, height: height, split: split)
            #expect(Array(panel[(width * height * 2)...]) == Array(original[(width * height * 2)...]))
        }
        for scene in ["hard-edge", "sky-branches"] {
            let input = try LightcraftDetailFixtures.make(sceneClass: scene, split: .acceptance).input
            var output = input
            for p in stride(from: width * height * 2, to: output.pixels.count, by: 4) {
                for c in 0..<3 { output.pixels[p + c] += 0.1 }
            }
            for control in ["clarity", "texture"] {
                let detail = Comparison.detail(input: input, output: output, control: control, sceneClass: scene)
                #expect(detail["detail_contrast_delta"] == 0)
            }
        }
    }
    @Test func contrastRejectsGlobalShiftAndRetainsSignedGain() throws {
        let input = try LightcraftDetailFixtures.make(sceneClass: "skin-pores", split: .tuning, width: 96, height: 64).input
        var shifted = input, increased = input, reduced = input
        for p in stride(from: 0, to: input.pixels.count, by: 4) { for c in 0..<3 {
            shifted.pixels[p + c] += 0.2
            increased.pixels[p + c] *= 1.2
            reduced.pixels[p + c] *= 0.8
        } }
        for control in ["clarity", "texture"] {
            let constant = Comparison.detail(input: input, output: shifted, control: control)
            #expect(abs(try #require(constant["detail_contrast_delta"])) < 0.000001)
            #expect(try #require(Comparison.detail(input: input, output: increased, control: control)["detail_contrast_delta"]) > 0)
            #expect(try #require(Comparison.detail(input: input, output: reduced, control: control)["detail_contrast_delta"]) < 0)
        }
    }
    @Test func inputDefinedMarginPreventsHaloGradientFromFakingDetail() throws {
        let input = try raster { x, row in x < 32 ? 0.3 + Float((x + row) % 7) * 0.001 : 0.8 }
        var ring = input
        for row in 0..<input.height { for x in 29...34 { for channel in 0..<3 {
            ring.pixels[(row * input.width + x) * 4 + channel] += x < 32 ? -0.08 : 0.08
        } } }
        for control in ["clarity", "texture"] {
            let metrics = Comparison.detail(input: input, output: ring, control: control)
            #expect(try #require(metrics["detail_sample_count"]) > 0)
            #expect(abs(try #require(metrics["detail_contrast_delta"])) < 0.000001)
        }
    }
    @Test func absentOrInvalidPixelsAreMissingEvidence() throws {
        let input = try raster { _, _ in 0.3 }
        #expect(Comparison.detail(input: input, output: input, control: "texture")["detail_sample_count"] == 0)
        var bad = input; bad.pixels[0] = .nan
        #expect(Comparison.detail(input: input, output: bad, control: "texture").isEmpty)
        #expect(Comparison.halo(input: input, output: bad).isEmpty)
        #expect(Comparison.noise(input: input, cleanInput: input, output: bad, cleanOutput: input).isEmpty)
        bad = input; bad.pixels.removeLast()
        #expect(Comparison.detail(input: input, output: bad, control: "texture").isEmpty)
    }
    @Test func haloUsesFarPlateauAndIndependentLowerRegion() throws {
        let input = try raster { x, _ in x < 32 ? 0.04 : 0.86 }
        let shifted = try raster { x, _ in x < 32 ? 0.09 : 0.66 }
        let clean = Comparison.halo(input: input, output: shifted)
        #expect(try #require(clean["halo_sample_count"]) > 0)
        #expect(abs(try #require(clean["halo_area"])) < 0.000001)
        var ring = shifted
        for row in 24..<32 { for c in 0..<3 { ring.pixels[(row * 64 + 31) * 4 + c] += 0.04 } }
        let artifact = Comparison.halo(input: input, output: ring)
        #expect(try #require(artifact["halo_area"]) > 0)
        #expect(abs(try #require(artifact["edge_overshoot"]) - 0.04) < 0.000001)
        #expect(artifact["halo_extent"] == 1)
        // Bottom-quarter artifacts must not alter the independently matched detail.
        #expect(Comparison.detail(input: input, output: ring, control: "texture")["detail_sample_count"] == 0)
    }
    @Test func noiseSubtractsRenderedCleanCounterpartAndIgnoresOffsets() throws {
        let fixture = try LightcraftDetailFixtures.make(sceneClass: "lowlight-noise", split: .tuning, width: 96, height: 64)
        let clean = try #require(fixture.groundTruth)
        var output = fixture.input, cleanOutput = clean
        for p in stride(from: 0, to: output.pixels.count, by: 4) { for c in 0..<3 {
            output.pixels[p + c] = 2 * fixture.input.pixels[p + c] + 0.1
            cleanOutput.pixels[p + c] = 2 * clean.pixels[p + c] + 0.1
        } }
        let metrics = Comparison.noise(input: fixture.input, cleanInput: clean, output: output, cleanOutput: cleanOutput)
        #expect(try #require(metrics["noise_sample_count"]) > 100)
        #expect(abs(try #require(metrics["noise_amplification"]) - 2) < 0.00001)
    }
    @Test func manifestAndSignedMatchingAreStrict() throws {
        let manifest = try Comparison.Manifest.load(manifestURL)
        #expect(manifest.directions.count == 8)
        #expect(Comparison.matched(0.01, 0.0104, manifest: manifest))
        #expect(Comparison.matched(-0.01, -0.0104, manifest: manifest))
        for pair in [(0.01, -0.01), (0.01, 0.011), (0.0001, 0.0001), (Double.nan, 0.01), (0.01, Double.infinity)] {
            #expect(!Comparison.matched(pair.0, pair.1, manifest: manifest))
        }
        #expect(!Comparison.matched(nil, 0.01, manifest: manifest))
        #expect(!Comparison.matched(0.01, nil, manifest: manifest))
    }
    @Test func specializedRegistryCannotClaimGenericAcceptance() throws {
        let root = manifestURL.deletingLastPathComponent()
        let registry = try AlgorithmEvaluationCandidateRegistry.load(from: root.appendingPathComponent("candidate-registry.json"))
        let candidate = try #require(registry.candidates.first { $0.id == "LC-04" })
        #expect(candidate.implemented)
        #expect(candidate.primaryMetric == "halo_area")
        let manifest = try AlgorithmEvaluationManifest.load(from: root.appendingPathComponent("measurement-manifest.json"))
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: []).status == "blocked")
    }
    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/lightcraft-evaluation/lc04-manifest.json")
    }
    private func raster(value: (Int, Int) -> Float) throws -> AlgorithmEvaluationRaster {
        let pixels = (0..<(64 * 32)).flatMap { p -> [Float] in let v = value(p % 64, p / 64); return [v, v, v, 1] }
        return try .init(width: 64, height: 32, pixels: pixels)
    }
}
