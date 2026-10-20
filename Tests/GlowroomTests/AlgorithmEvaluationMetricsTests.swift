import Foundation
import Testing
@testable import Glowroom

@Suite("Frozen algorithm evaluation metrics and decision gates")
struct AlgorithmEvaluationMetricsTests {
    @Test func unchangedFixturesAndNeutralHiddenRGBPassControl() throws {
        let manifest = try loadManifest()
        for fixture in try AlgorithmEvaluationFixtures.make(split: .acceptance, width: 32, height: 24) {
            let measurement = try AlgorithmEvaluationMetrics.measure(reference: fixture.input, candidate: fixture.input,
                                                                      groundTruth: fixture.groundTruth)
            #expect(manifest.checkControl(sceneClass: fixture.sceneClass, measurement: measurement).isEmpty)
        }
        let input = try raster(width: 2, rgba: [0.2, 0.3, 0.4, 1, 0, 0, 0, 0])
        var hidden = input
        hidden.pixels[4] = 99; hidden.pixels[5] = -12; hidden.pixels[6] = 3
        let measurement = try AlgorithmEvaluationMetrics.measure(reference: input, candidate: hidden)
        #expect(measurement.values["max_rgb_error"] == 0)
        #expect(measurement.values["transparent_edge_light_error"] == 0)
        #expect(measurement.values["transparent_edge_dark_error"] == 0)
        #expect(manifest.checkControl(sceneClass: "transparency", measurement: measurement).isEmpty)
    }

    @Test func alphaAndLinearCompositesExposeVisibleFringes() throws {
        let input = try raster(width: 1, rgba: [0.8, 0.4, 0.2, 0.5])
        let fringe = try raster(width: 1, rgba: [1, 0.4, 0.2, 0.5])
        let result = try AlgorithmEvaluationMetrics.measure(reference: input, candidate: fringe)
        #expect(abs(result.values["transparent_edge_light_error", default: 0] - 0.1) < 1e-6)
        #expect(abs(result.values["transparent_edge_dark_error", default: 0] - 0.1) < 1e-6)
        let opaque = try raster(width: 1, rgba: [0.8, 0.4, 0.2, 1])
        let alpha = try AlgorithmEvaluationMetrics.measure(reference: input, candidate: opaque)
        #expect(alpha.values["alpha_error"] == 0.5)
        #expect(alpha.values["transparent_edge_light_error", default: 0] > 0.39)
        #expect(alpha.values["transparent_edge_dark_error", default: 0] > 0.39)
    }

    @Test func localHaloEnvelopeAndStructuralLossDetectDifferentRegressions() throws {
        let input = try gray(width: 6, values: [0.2, 0.2, 0.2, 0.8, 0.8, 0.8])
        let halo = try gray(width: 6, values: [0.2, 0.2, 0, 1, 0.8, 0.8])
        let result = try AlgorithmEvaluationMetrics.measure(reference: input, candidate: halo)
        #expect(abs(result.values["halo_overshoot", default: 0] - 0.2) < 1e-6)
        #expect(abs(result.values["halo_undershoot", default: 0] - 0.2) < 1e-6)
        let lines = try gray(width: 5, values: [
            0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0
        ])
        let flat = try gray(width: 5, values: Array(repeating: 0.5, count: 15))
        let blurred = try AlgorithmEvaluationMetrics.measure(reference: lines, candidate: flat)
        #expect(blurred.values["fine_line_loss"] == 1)
        #expect(blurred.values["texture_loss"] == 1)
        #expect(blurred.values["edge_loss"] == 1)
    }

    @Test func groundTruthResidualNoiseUsesItsOwnEligibleCount() throws {
        let truth = try gray(width: 4, values: Array(repeating: 0.5, count: 12))
        let noisy = try gray(width: 4, values: (0..<12).map { $0.isMultiple(of: 2) ? 0.52 : 0.48 })
        let original = try AlgorithmEvaluationMetrics.measure(reference: truth, candidate: noisy, groundTruth: truth)
        let restored = try AlgorithmEvaluationMetrics.measure(reference: truth, candidate: truth, groundTruth: truth)
        #expect(original.values["noise_roi_pixels"] == 12)
        #expect(abs(original.values["luma_noise_rmse", default: 0] - 0.02) < 1e-6)
        #expect(original.values["chroma_noise_rmse", default: 1] < 1e-6)
        #expect(restored.values["luma_noise_rmse"] == 0)
        #expect(abs(try AlgorithmEvaluationMetrics.effectStrength(domain: "denoise", input: noisy,
                                                                  output: truth, groundTruth: truth) - 0.02) < 1e-6)
        #expect(throws: AlgorithmEvaluationMetricError.self) {
            try AlgorithmEvaluationMetrics.effectStrength(domain: "denoise", input: noisy, output: truth)
        }
    }

    @Test func neutralHueIsExcludedAndInvalidPixelsFailClosed() throws {
        let grayImage = try gray(width: 1, values: [0.5])
        let neutral = try AlgorithmEvaluationMetrics.measure(reference: grayImage, candidate: grayImage)
        #expect(neutral.values["hue_evaluated_pixels"] == 0)
        let red = try raster(width: 1, rgba: [1, 0, 0, 1]), green = try raster(width: 1, rgba: [0, 1, 0, 1])
        let shifted = try AlgorithmEvaluationMetrics.measure(reference: red, candidate: green)
        #expect(shifted.values["hue_evaluated_pixels"] == 1)
        #expect(shifted.values["hue_deviation_degrees", default: 0] > 90)
        var invalid = grayImage
        invalid.pixels[0] = .nan
        #expect(throws: AlgorithmEvaluationMetricError.self) {
            try AlgorithmEvaluationMetrics.measure(reference: grayImage, candidate: invalid)
        }
        let extended = try raster(width: 1, rgba: [-0.2, 0.5, 1.2, 1])
        #expect(try AlgorithmEvaluationMetrics.measure(reference: extended, candidate: extended).values.values.allSatisfy(\.isFinite))
    }

    @Test func boundedMatchingDoesNotAssumeMonotonicResponse() throws {
        let match = try AlgorithmEvaluationMetrics.matchEffect(target: 1, parameters: [0, 1, 2, 3],
                                                               absoluteTolerance: 0.002, relativeTolerance: 0.05) {
            1 - ($0 - 2) * ($0 - 2)
        }
        #expect(match.parameter == 2)
        #expect(match.matched)
        let noMatch = try AlgorithmEvaluationMetrics.matchEffect(target: 10, parameters: [0, 1],
                                                                 absoluteTolerance: 0.01, relativeTolerance: 0.05) { $0 }
        #expect(!noMatch.matched)
        #expect(throws: AlgorithmEvaluationMetricError.self) {
            try AlgorithmEvaluationMetrics.matchEffect(target: 1, parameters: Array(0...33).map(Double.init),
                                                        absoluteTolerance: 0, relativeTolerance: 0) { $0 }
        }
    }

    @Test func registryBlocksEveryAbsentReferenceAndControlsCannotClaimGo() throws {
        let registry = try AlgorithmEvaluationCandidateRegistry.load(from: root.appendingPathComponent("candidate-registry.json"))
        let manifest = try loadManifest(), scenes = try comparisons()
        for candidate in registry.candidates {
            let decision = AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes)
            #expect(decision.status == (candidate.kind == "control" ? "control-pass" : "blocked"))
        }
        #expect(registry.candidates.filter { $0.kind == "reference" }.map(\.id) == ["LC-03", "LC-04", "LC-05", "LC-06"])
    }

    @Test func gateRequiresMatchedEffectSeparateAcceptanceHumanApprovalAndBudgets() throws {
        let manifest = try loadManifest(), scenes = try comparisons()
        let candidate = AlgorithmEvaluationCandidateRegistry.Candidate(id: "test-reference", kind: "reference", implemented: true,
            issue: 50, sourceCommit: String(repeating: "a", count: 40), domain: "tone", primarySceneClass: "hard-edge",
            primaryMetric: "halo_overshoot", minimumRelativeImprovement: 0.1, missingEvidence: [])
        let good = completeEvidence()
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes, evidence: good).status == "go")
        var unmatched = good
        unmatched.candidateEffectStrength = 0.2
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes, evidence: unmatched).status == "blocked")
        var shared = good
        shared.acceptanceFixtureIDs = shared.tuningFixtureIDs
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes, evidence: shared).status == "blocked")
        var unreviewed = good
        unreviewed.visualApprovalReference = nil
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes, evidence: unreviewed).status == "blocked")
        unreviewed.visualApprovalReference = " \n "
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes, evidence: unreviewed).status == "blocked")
        var neutralEffect = good
        neutralEffect.baselineEffectStrength = 0; neutralEffect.candidateEffectStrength = 0
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes, evidence: neutralEffect).status == "blocked")
        var expensive = good
        expensive.warmLatencyRatio = 1.21
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes, evidence: expensive).status == "no-go")
        var changedManifest = good
        changedManifest.manifestSHA256AfterAcceptance = String(repeating: "b", count: 64)
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: scenes, evidence: changedManifest).status == "blocked")
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: Array(scenes.dropLast()), evidence: good).status == "blocked")
        let noGain = scenes.map { scene in
            AlgorithmEvaluationGate.SceneComparison(sceneClass: scene.sceneClass, baselineQuality: scene.baselineQuality,
                                                      candidateQuality: scene.baselineQuality, difference: scene.difference)
        }
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: noGain, evidence: good).status == "no-go")
        let missing = scenes.map { scene in
            AlgorithmEvaluationGate.SceneComparison(sceneClass: scene.sceneClass, baselineQuality: scene.baselineQuality,
                                                      candidateQuality: .init(values: [:]), difference: scene.difference)
        }
        #expect(AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: missing, evidence: good).status == "blocked")
    }

    @Test func incompleteManifestAndMissingControlMetricAreRejected() throws {
        let manifest = try loadManifest()
        #expect(!manifest.checkControl(sceneClass: "noise", measurement: .init(values: [:])).isEmpty)
        #expect(!manifest.checkControl(sceneClass: "unknown", measurement: .init(values: [:])).isEmpty)
        let data = try Data(contentsOf: root.appendingPathComponent("measurement-manifest.json"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["minimumRepetitions"] = 4
        let invalid = try JSONDecoder().decode(AlgorithmEvaluationManifest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: AlgorithmEvaluationMetricError.self) { try invalid.validate() }
        let input = try gray(width: 2, values: [0.5, 0.5])
        let rounded = try gray(width: 2, values: [0.5005, 0.5005])
        let measurement = try AlgorithmEvaluationMetrics.measure(reference: input, candidate: rounded)
        #expect(manifest.checkControl(sceneClass: "constants", measurement: measurement, numericalBackend: "ci").isEmpty)
        #expect(!manifest.checkControl(sceneClass: "constants", measurement: measurement, numericalBackend: "cpu").isEmpty)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/lightcraft-evaluation", isDirectory: true)
    }

    private func loadManifest() throws -> AlgorithmEvaluationManifest {
        try AlgorithmEvaluationManifest.load(from: root.appendingPathComponent("measurement-manifest.json"))
    }

    private func raster(width: Int, rgba: [Float]) throws -> AlgorithmEvaluationRaster {
        try AlgorithmEvaluationRaster(width: width, height: rgba.count / 4 / width, pixels: rgba)
    }

    private func gray(width: Int, values: [Float]) throws -> AlgorithmEvaluationRaster {
        try raster(width: width, rgba: values.flatMap { [$0, $0, $0, 1] })
    }

    private func comparisons() throws -> [AlgorithmEvaluationGate.SceneComparison] {
        try AlgorithmEvaluationFixtures.make(split: .acceptance, width: 32, height: 24).map { fixture in
            let difference = try AlgorithmEvaluationMetrics.measure(reference: fixture.input, candidate: fixture.input,
                                                                     groundTruth: fixture.groundTruth)
            var baseline = difference.values, candidate = difference.values
            if fixture.sceneClass == "hard-edge" { baseline["halo_overshoot"] = 0.02; candidate["halo_overshoot"] = 0.01 }
            return .init(sceneClass: fixture.sceneClass, baselineQuality: .init(values: baseline),
                         candidateQuality: .init(values: candidate), difference: difference)
        }
    }

    private func completeEvidence() -> AlgorithmEvaluationGate.Evidence {
        var evidence = AlgorithmEvaluationGate.Evidence()
        evidence.identicalInputHashes = true
        evidence.effectStrengthMatched = true
        evidence.baselineEffectStrength = 0.1; evidence.candidateEffectStrength = 0.1
        evidence.tuningFixtureIDs = ["tuning-1"]; evidence.acceptanceFixtureIDs = ["acceptance-1"]
        evidence.manifestSHA256BeforeAcceptance = String(repeating: "a", count: 64)
        evidence.manifestSHA256AfterAcceptance = evidence.manifestSHA256BeforeAcceptance
        evidence.visualApprovalReference = "test-only-human-review-record"
        evidence.realPhotoCoverageApprovalReference = "test-only-licensed-real-coverage-record"
        evidence.coldRepetitions = 5; evidence.warmRepetitions = 5
        evidence.coldLatencyRatio = 1; evidence.warmLatencyRatio = 1; evidence.peakRSSRatio = 1
        return evidence
    }
}
