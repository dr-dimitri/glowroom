import Foundation
import Testing
@testable import PicEdit

@Suite("LC-03 preregistered comparison controls")
struct LightcraftToneComparisonTests {
    @Test func strengthUsesInputDefinedROIAlphaWeightsAndSignedChanges() throws {
        let manifest = try loadManifest()
        let input = try gray([0.1, 0.2, 0.8, 0.9, 0.25, 0.5], alpha: [1, 0.5, 1, 0, 1, 1])
        let output = try gray([0.14, 0.18, 0.7, 3, 2, 3], alpha: [1, 0.5, 1, 0, 1, 1])
        let shadow = LightcraftToneComparison.strength(input: input, output: output,
            direction: direction("shadows", 20), manifest: manifest)
        let highlight = LightcraftToneComparison.strength(input: input, output: output,
            direction: direction("highlights", -20), manifest: manifest)
        // The exact ROI boundaries (.25/.5) are excluded; alpha-zero is excluded,
        // and the two shadow samples carry weights 1 and .5, not equal counts.
        #expect(abs(try #require(shadow) - 0.02) < 0.0000001)
        #expect(abs(try #require(highlight) + 0.1) < 0.0000001)
        #expect(LightcraftToneComparison.strength(input: input, output: input,
            direction: direction("shadows", 20), manifest: manifest) == 0)
    }

    @Test func absentOrNonfiniteStrengthIsMissingEvidence() throws {
        let manifest = try loadManifest()
        let input = try gray([0.4, 0.4])
        #expect(LightcraftToneComparison.strength(input: input, output: input,
            direction: direction("shadows", 20), manifest: manifest) == nil)
        let dark = try gray([0.1, 0.2])
        var invalid = dark
        invalid.pixels[0] = .nan
        #expect(LightcraftToneComparison.strength(input: dark, output: invalid,
            direction: direction("shadows", 20), manifest: manifest) == nil)
    }

    @Test func matchingRejectsMissingNonfiniteNegligibleOrOppositeSignedEffects() throws {
        let m = try loadManifest()
        #expect(LightcraftToneComparison.matched(0.04, 0.042, manifest: m))
        #expect(LightcraftToneComparison.matched(-0.1, -0.104, manifest: m))
        #expect(!LightcraftToneComparison.matched(0.04, 0.044, manifest: m))
        #expect(!LightcraftToneComparison.matched(-0.1, -0.107, manifest: m))
        #expect(!LightcraftToneComparison.matched(0.002, -0.0005, manifest: m))
        #expect(!LightcraftToneComparison.matched(-0.002, 0.0005, manifest: m))
        #expect(!LightcraftToneComparison.matched(0.001, 0.001, manifest: m))
        #expect(!LightcraftToneComparison.matched(nil, 0.03, manifest: m))
        #expect(!LightcraftToneComparison.matched(0.03, nil, manifest: m))
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(!LightcraftToneComparison.matched(value, 0.03, manifest: m))
            #expect(!LightcraftToneComparison.matched(0.03, value, manifest: m))
        }
    }

    @Test func lineContrastIsInvariantToCommonExposureButDetectsCompression() throws {
        let input = try lineScene()
        var exposed = input, compressed = input
        for p in stride(from: 0, to: input.pixels.count, by: 4) { for channel in 0..<3 {
            exposed.pixels[p + channel] *= 2
            compressed.pixels[p + channel] = sqrt(input.pixels[p + channel])
        } }
        let common = LightcraftToneComparison.lineContrast(input: input, output: exposed, minimumContrastEV: 0.05)
        #expect(try #require(common["bright_line_count"]) > 0)
        #expect(try #require(common["dark_line_count"]) > 0)
        #expect(abs(try #require(common["log_line_contrast_error"])) < 0.0000001)
        let changed = LightcraftToneComparison.lineContrast(input: input, output: compressed, minimumContrastEV: 0.05)
        #expect(abs(try #require(changed["bright_line_error"]) - 0.5) < 0.0000001)
        #expect(abs(try #require(changed["dark_line_error"]) - 0.5) < 0.0000001)
        #expect(abs(try #require(changed["log_line_contrast_error"]) - 0.5) < 0.0000001)
    }

    @Test func brightAndDarkRegionsHaveEqualWeightDespiteDifferentLineCounts() throws {
        let input = try lineScene()
        var output = input
        for row in 0..<(input.height / 2) { for x in 0..<input.width {
            let offset = (row * input.width + x) * 4
            for channel in 0..<3 { output.pixels[offset + channel] = sqrt(input.pixels[offset + channel]) }
        } }
        let measured = LightcraftToneComparison.lineContrast(input: input, output: output, minimumContrastEV: 0.05)
        let bright = try #require(measured["bright_line_error"]), dark = try #require(measured["dark_line_error"])
        let brightCount = try #require(measured["bright_line_count"]), darkCount = try #require(measured["dark_line_count"])
        #expect(brightCount > darkCount * 2, "This fixture must distinguish equal-half weighting from equal-pixel weighting")
        #expect(abs(bright - 0.5) < 0.0000001 && abs(dark) < 0.0000001)
        #expect(abs(try #require(measured["log_line_contrast_error"]) - (bright + dark) / 2) < 0.0000001)
    }

    @Test func emptyLineRegionsExposeMissingSupport() throws {
        let input = try raster(width: 20, height: 20) { _, _ in 0.4 }
        let measured = LightcraftToneComparison.lineContrast(input: input, output: input, minimumContrastEV: 0.05)
        #expect(measured["bright_line_count"] == 0)
        #expect(measured["dark_line_count"] == 0)
    }

    @Test func haloIgnoresSameSidePlateauShiftsAndDetectsBothRingSigns() throws {
        let input = try raster(width: 40, height: 10) { x, _ in x < 20 ? 0.04 : 0.86 }
        let shifted = try raster(width: 40, height: 10) { x, _ in x < 20 ? 0.09 : 0.66 }
        let clean = LightcraftToneComparison.halo(input: input, output: shifted)
        #expect(abs(try #require(clean["halo_overshoot"])) < 0.0000001)
        #expect(abs(try #require(clean["halo_undershoot"])) < 0.0000001)
        #expect(try #require(clean["edge_support"]) > 0.8)
        var ring = shifted
        for channel in 0..<3 {
            ring.pixels[(5 * 40 + 19) * 4 + channel] += 0.04
            ring.pixels[(5 * 40 + 20) * 4 + channel] -= 0.03
        }
        let bad = LightcraftToneComparison.halo(input: input, output: ring)
        #expect(abs(try #require(bad["halo_overshoot"]) - 0.04) < 0.0000001)
        #expect(abs(try #require(bad["halo_undershoot"]) - 0.03) < 0.0000001)
        let flat = try raster(width: 40, height: 10) { _, _ in 0.4 }
        #expect(LightcraftToneComparison.halo(input: flat, output: flat)["edge_support"] == 0)
    }

    @Test func manifestLoadsTheFrozenCompleteDirectionSet() throws {
        let m = try loadManifest()
        #expect(m.directions.count == 8)
        #expect(m.directions.filter(\.primary).count == 4)
        for item in m.directions {
            let settings = item.settings()
            #expect((item.control == "shadows" ? settings.shadows : settings.highlights) == item.value)
            #expect((item.control == "shadows" ? settings.highlights : settings.shadows) == 0)
        }
    }

    @Test func invalidManifestsCannotSilentlyChangeThePreregisteredGate() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 2 },
            { $0["sourceCommit"] = "wrong-source" },
            { $0["qualityWidth"] = 400 },
            { $0["performanceSceneClass"] = "unknown" },
            { value in
                var directions = value["directions"] as! [[String: Any]]
                directions[0]["id"] = "../../outside-output"
                value["directions"] = directions
            },
            { value in
                var directions = value["directions"] as! [[String: Any]]
                directions[1]["control"] = directions[0]["control"]
                directions[1]["value"] = directions[0]["value"]
                value["directions"] = directions
            },
            { value in
                var directions = value["directions"] as! [[String: Any]]
                directions[4]["primary"] = true
                value["directions"] = directions
            },
            { value in var field = value["matching"] as! [String: Any]; field["minimumAbsoluteTarget"] = -0.1; value["matching"] = field },
            { value in var field = value["matching"] as! [String: Any]; field["maximumRelativeDeltaError"] = -0.1; value["matching"] = field },
            { value in var field = value["matching"] as! [String: Any]; field["shadowMaximumInputY"] = 0.9; value["matching"] = field },
            { value in var field = value["primary"] as! [String: Any]; field["minimumInputContrastEV"] = 0; value["primary"] = field },
            { value in var field = value["primary"] as! [String: Any]; field["minimumRelativeImprovement"] = -0.1; value["primary"] = field },
            { value in var field = value["criticalLimits"] as! [String: Any]; field.removeValue(forKey: "alphaError"); value["criticalLimits"] = field },
        ]
        for mutate in mutations {
            var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            mutate(&value)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("picedit-invalid-lc03-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
            #expect(throws: (any Error).self) { _ = try LightcraftToneComparison.Manifest.load(url) }
        }
    }

    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/lightcraft-evaluation/lc03-manifest.json")
    }

    private func loadManifest() throws -> LightcraftToneComparison.Manifest { try .load(manifestURL) }

    private func direction(_ control: String, _ value: Double) -> LightcraftToneComparison.Direction {
        .init(id: "test-\(control)", control: control, value: value, primary: true)
    }

    private func gray(_ values: [Float], alpha: [Float]? = nil) throws -> AlgorithmEvaluationRaster {
        let pixels: [Float] = values.enumerated().flatMap { index, value -> [Float] in
            let coverage: Float = alpha?[index] ?? 1
            return [value, value, value, coverage]
        }
        return try .init(width: values.count, height: 1, pixels: pixels)
    }

    private func lineScene() throws -> AlgorithmEvaluationRaster {
        try raster(width: 32, height: 24) { x, y in
            if y < 12 { return x.isMultiple(of: 4) ? 0.92 : 0.035 }
            return x == 7 ? 0.035 : 0.92
        }
    }

    private func raster(width: Int, height: Int, value: (Int, Int) -> Float) throws -> AlgorithmEvaluationRaster {
        let pixels = (0..<(width * height)).flatMap { index in
            let v = value(index % width, index / width)
            return [v, v, v, Float(1)]
        }
        return try .init(width: width, height: height, pixels: pixels)
    }
}
