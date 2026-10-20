import Foundation

enum AlgorithmEvaluationMetricError: Error {
    case invalid(String)
}

/// Evaluation-only scalar references. These deterministic reductions run after
/// timed rendering. The small acceptance fixtures do not justify a worker pool;
/// independent fixtures may be scheduled by the harness, without nested pools.
enum AlgorithmEvaluationMetrics {
    struct Measurement: Codable, Sendable {
        let values: [String: Double]
    }

    static let metricNames: Set<String> = [
        "max_rgb_error", "mean_rgb_error", "halo_overshoot", "halo_undershoot",
        "fine_line_loss", "texture_loss", "mean_luminance_drift", "hue_deviation_degrees",
        "chroma_deviation", "gamut_fraction_increase", "clipping_fraction_increase",
        "luma_noise_rmse", "chroma_noise_rmse", "edge_loss", "alpha_error",
        "transparent_edge_light_error", "transparent_edge_dark_error"
    ]

    /// `reference` is the common clean target for absolute quality, or Glowroom's
    /// output for pairwise regressions. Noise always uses the explicit clean
    /// `groundTruth`, falling back to reference only for non-noise controls.
    static func measure(reference: AlgorithmEvaluationRaster, candidate: AlgorithmEvaluationRaster,
                        groundTruth: AlgorithmEvaluationRaster? = nil) throws -> Measurement {
        try validate(reference)
        try validate(candidate)
        guard reference.width == candidate.width, reference.height == candidate.height else {
            throw AlgorithmEvaluationMetricError.invalid("Mismatched raster dimensions")
        }
        let truth = groundTruth ?? reference
        try validate(truth)
        guard truth.width == reference.width, truth.height == reference.height else {
            throw AlgorithmEvaluationMetricError.invalid("Mismatched ground-truth dimensions")
        }
        let width = reference.width, height = reference.height
        var maxRGB = 0.0, sumRGB = 0.0, weight = 0.0, drift = 0.0
        var overshoot = 0.0, undershoot = 0.0, alphaError = 0.0
        var light = 0.0, dark = 0.0, alphaPixels = 0.0
        var hue = 0.0, hueCount = 0.0, chroma = 0.0
        var referenceGamut = 0.0, candidateGamut = 0.0, referenceClip = 0.0, candidateClip = 0.0
        var referenceGradient = 0.0, candidateGradient = 0.0, referenceEdge = 0.0, candidateEdge = 0.0
        var referenceTexture = 0.0, candidateTexture = 0.0, edgePairs = 0.0
        var noiseLuma = 0.0, noiseChroma = 0.0, noiseCount = 0.0
        for y in 0..<height { for x in 0..<width {
            let p = (y * width + x) * 4
            let a = Double(reference.pixels[p + 3]), b = Double(candidate.pixels[p + 3])
            alphaError = max(alphaError, abs(a - b))
            let neighbors = neighborOffsets(x: x, y: y, width: width, height: height)
            let boundary = a < 1 || b < 1 || neighbors.contains {
                reference.pixels[$0 + 3] < 1 || candidate.pixels[$0 + 3] < 1
            }
            if boundary {
                alphaPixels += 1
                for channel in 0..<3 {
                    // Multiplication by alpha deliberately discards invisible
                    // RGB, including arbitrary values in an untrusted result.
                    let first = Double(reference.pixels[p + channel]) * a
                    let second = Double(candidate.pixels[p + channel]) * b
                    dark = max(dark, abs(first - second))
                    light = max(light, abs((first + 1 - a) - (second + 1 - b)))
                }
            }
            guard a > 0, b > 0 else { continue }
            let pixelWeight = min(a, b)
            let refY = luminance(reference, p), outY = luminance(candidate, p)
            weight += pixelWeight
            drift += (outY - refY) * pixelWeight
            for channel in 0..<3 {
                let first = Double(reference.pixels[p + channel]), second = Double(candidate.pixels[p + channel])
                let error = abs(first - second)
                maxRGB = max(maxRGB, error)
                sumRGB += error * pixelWeight
                referenceGamut += (first < -0.00001 || first > 1.00001 ? pixelWeight : 0)
                candidateGamut += (second < -0.00001 || second > 1.00001 ? pixelWeight : 0)
                referenceClip += (first <= 0 || first >= 1 ? pixelWeight : 0)
                candidateClip += (second <= 0 || second >= 1 ? pixelWeight : 0)
            }
            var low = refY, high = refY
            for ny in max(0, y - 1)...min(height - 1, y + 1) {
                for nx in max(0, x - 1)...min(width - 1, x + 1) {
                    let q = (ny * width + nx) * 4
                    guard reference.pixels[q + 3] > 0 else { continue }
                    let value = luminance(reference, q)
                    low = min(low, value); high = max(high, value)
                }
            }
            overshoot = max(overshoot, outY - high)
            undershoot = max(undershoot, low - outY)
            let labA = oklab(reference, p), labB = oklab(candidate, p)
            let ca = hypot(labA.1, labA.2), cb = hypot(labB.1, labB.2)
            chroma += abs(cb - ca) * pixelWeight
            // Hue is undefined near the neutral axis; report the eligible count
            // so a gray image cannot be passed off as hue preservation evidence.
            if ca > 0.02, cb > 0.02 {
                let angle = abs(atan2(labA.2, labA.1) - atan2(labB.2, labB.1))
                hue = max(hue, min(angle, 2 * .pi - angle) * 180 / .pi)
                hueCount += 1
            }
            for q in [x + 1 < width ? p + 4 : -1, y + 1 < height ? p + width * 4 : -1] where q >= 0 {
                guard reference.pixels[q + 3] > 0, candidate.pixels[q + 3] > 0 else { continue }
                let first = luminance(reference, q) - refY, second = luminance(candidate, q) - outY
                let pairWeight = min(pixelWeight, Double(min(reference.pixels[q + 3], candidate.pixels[q + 3])))
                referenceGradient += first * first * pairWeight
                candidateGradient += second * second * pairWeight
                if abs(first) >= 0.05 {
                    referenceEdge += first * first * pairWeight
                    candidateEdge += second * second * pairWeight
                    edgePairs += 1
                }
            }
            if neighbors.count == 4, neighbors.allSatisfy({ reference.pixels[$0 + 3] > 0 && candidate.pixels[$0 + 3] > 0 }) {
                let first = neighbors.reduce(-4 * refY) { $0 + luminance(reference, $1) }
                let second = neighbors.reduce(-4 * outY) { $0 + luminance(candidate, $1) }
                referenceTexture += first * first * pixelWeight
                candidateTexture += second * second * pixelWeight
            }
            if truth.pixels[p + 3] > 0,
               neighbors.allSatisfy({ truth.pixels[$0 + 3] > 0 && abs(luminance(truth, $0) - luminance(truth, p)) <= 0.02 }) {
                let trueY = luminance(truth, p), errorY = outY - trueY
                noiseLuma += errorY * errorY
                for channel in 0..<3 {
                    let error = Double(candidate.pixels[p + channel] - truth.pixels[p + channel]) - errorY
                    noiseChroma += error * error
                }
                noiseCount += 1
            }
        } }
        let denominator = max(weight, 1e-20)
        return Measurement(values: [
            "max_rgb_error": maxRGB, "mean_rgb_error": sumRGB / (3 * denominator),
            "halo_overshoot": max(0, overshoot), "halo_undershoot": max(0, undershoot),
            "fine_line_loss": energyLoss(referenceGradient, candidateGradient),
            "texture_loss": energyLoss(referenceTexture, candidateTexture),
            "mean_luminance_drift": abs(drift / denominator),
            "hue_deviation_degrees": hue, "chroma_deviation": chroma / denominator,
            "gamut_fraction_increase": max(0, candidateGamut - referenceGamut) / (3 * denominator),
            "clipping_fraction_increase": max(0, candidateClip - referenceClip) / (3 * denominator),
            "luma_noise_rmse": sqrt(noiseLuma / max(1, noiseCount)),
            "chroma_noise_rmse": sqrt(noiseChroma / max(1, noiseCount * 3)),
            "edge_loss": energyLoss(referenceEdge, candidateEdge), "alpha_error": alphaError,
            "transparent_edge_light_error": light, "transparent_edge_dark_error": dark,
            "visible_weight": weight, "hue_evaluated_pixels": hueCount, "noise_roi_pixels": noiseCount,
            "edge_pairs": edgePairs, "alpha_boundary_pixels": alphaPixels,
            "reference_gradient_energy": referenceGradient, "reference_texture_energy": referenceTexture
        ])
    }

    /// Metrics used to match effect strength on the tuning split only. Positive
    /// values mean stronger shadow lift, detail/chroma addition or noise removal.
    static func effectStrength(domain: String, input: AlgorithmEvaluationRaster, output: AlgorithmEvaluationRaster,
                               groundTruth: AlgorithmEvaluationRaster? = nil) throws -> Double {
        let measurement = try measure(reference: input, candidate: output, groundTruth: groundTruth)
        if domain == "denoise" {
            guard let groundTruth else { throw AlgorithmEvaluationMetricError.invalid("Denoise matching requires clean truth") }
            let original = try measure(reference: groundTruth, candidate: input, groundTruth: groundTruth)
            guard original.values["noise_roi_pixels", default: 0] > 0 else {
                throw AlgorithmEvaluationMetricError.invalid("Denoise matching has no eligible truth ROI")
            }
            return original.values["luma_noise_rmse", default: 0] - measurement.values["luma_noise_rmse", default: 0]
        }
        var sum = 0.0, count = 0.0
        for p in stride(from: 0, to: input.pixels.count, by: 4) {
            guard input.pixels[p + 3] > 0, output.pixels[p + 3] > 0 else { continue }
            let y = luminance(input, p)
            if domain == "tone", y < 0.25 { sum += luminance(output, p) - y; count += 1 }
            if domain == "color" {
                let a = oklab(input, p), b = oklab(output, p)
                sum += hypot(b.1, b.2) - hypot(a.1, a.2); count += 1
            }
            if domain == "detail" {
                let x = (p / 4) % input.width, row = (p / 4) / input.width
                let neighbors = neighborOffsets(x: x, y: row, width: input.width, height: input.height)
                guard neighbors.count == 4, neighbors.allSatisfy({ input.pixels[$0 + 3] > 0 && output.pixels[$0 + 3] > 0 }) else { continue }
                let first = abs(neighbors.reduce(-4 * y) { $0 + luminance(input, $1) })
                let second = abs(neighbors.reduce(-4 * luminance(output, p)) { $0 + luminance(output, $1) })
                sum += second - first; count += 1
            }
        }
        guard ["tone", "color", "detail"].contains(domain), count > 0 else {
            throw AlgorithmEvaluationMetricError.invalid("Unknown effect domain or empty eligible ROI: \(domain)")
        }
        return sum / count
    }

    struct EffectMatch: Codable, Sendable {
        let parameter: Double
        let measuredStrength: Double
        let absoluteError: Double
        let matched: Bool
    }

    /// A bounded deterministic grid makes no unproven monotonicity assumption.
    /// Candidate parameters and tolerances belong to the frozen tuning protocol.
    static func matchEffect(target: Double, parameters: [Double], absoluteTolerance: Double,
                            relativeTolerance: Double, measure: (Double) throws -> Double) throws -> EffectMatch {
        guard target.isFinite, absoluteTolerance.isFinite, relativeTolerance.isFinite,
              absoluteTolerance >= 0, relativeTolerance >= 0, (1...33).contains(parameters.count),
              parameters.allSatisfy(\.isFinite), Set(parameters).count == parameters.count else {
            throw AlgorithmEvaluationMetricError.invalid("Invalid bounded effect-matching grid")
        }
        var best: EffectMatch?
        for parameter in parameters {
            let strength = try measure(parameter)
            guard strength.isFinite else { throw AlgorithmEvaluationMetricError.invalid("Nonfinite effect strength") }
            let error = abs(strength - target)
            if best == nil || error < best!.absoluteError {
                best = EffectMatch(parameter: parameter, measuredStrength: strength, absoluteError: error,
                    matched: error <= max(absoluteTolerance, abs(target) * relativeTolerance))
            }
        }
        return best!
    }

    private static func validate(_ raster: AlgorithmEvaluationRaster) throws {
        let (count, overflow) = raster.width.multipliedReportingOverflow(by: raster.height)
        guard raster.width > 0, raster.height > 0, !overflow, count <= Int.max / 4,
              raster.pixels.count == count * 4, raster.pixels.allSatisfy(\.isFinite),
              stride(from: 3, to: raster.pixels.count, by: 4).allSatisfy({ (0...1).contains(raster.pixels[$0]) }) else {
            throw AlgorithmEvaluationMetricError.invalid("Invalid or nonfinite straight-alpha raster")
        }
    }

    private static func neighborOffsets(x: Int, y: Int, width: Int, height: Int) -> [Int] {
        var result: [Int] = []
        if x > 0 { result.append((y * width + x - 1) * 4) }
        if x + 1 < width { result.append((y * width + x + 1) * 4) }
        if y > 0 { result.append(((y - 1) * width + x) * 4) }
        if y + 1 < height { result.append(((y + 1) * width + x) * 4) }
        return result
    }

    private static func luminance(_ raster: AlgorithmEvaluationRaster, _ p: Int) -> Double {
        0.2126 * Double(raster.pixels[p]) + 0.7152 * Double(raster.pixels[p + 1]) + 0.0722 * Double(raster.pixels[p + 2])
    }

    private static func energyLoss(_ reference: Double, _ candidate: Double) -> Double {
        reference > 1e-20 ? max(0, 1 - sqrt(candidate / reference)) : 0
    }

    /// Björn Ottosson's 2021 linear-sRGB -> OkLab matrices, explicitly scoped to
    /// extended linear sRGB, NOT Lightcraft's Rec.2020 buffer. Signed cube roots
    /// preserve negative extended-range channels. No Lightcraft code is copied.
    private static func oklab(_ raster: AlgorithmEvaluationRaster, _ p: Int) -> (Double, Double, Double) {
        let r = Double(raster.pixels[p]), g = Double(raster.pixels[p + 1]), b = Double(raster.pixels[p + 2])
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}

struct AlgorithmEvaluationManifest: Codable, Sendable {
    struct Scene: Codable, Sendable {
        let id: String
        let criticalLimits: [String: Double]
        let requiredEvidenceMetric: String?
    }
    struct Budgets: Codable, Sendable {
        let maximumColdLatencyRatio: Double
        let maximumWarmLatencyRatio: Double
        let maximumPeakRSSRatio: Double
    }
    let schemaVersion: Int
    let frozenBeforeAcceptance: Bool
    let measurementSpace: String
    let minimumRepetitions: Int
    let minimumP95Samples: Int
    let effectAbsoluteTolerance: Double
    let effectRelativeTolerance: Double
    let numericalTolerance: [String: Double]
    let controlLimits: [String: Double]
    let performanceBudgets: Budgets
    let scenes: [Scene]

    static func load(from url: URL) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try result.validate()
        return result
    }

    func validate() throws {
        let expectedScenes: Set<String> = ["ramp", "constants", "fine-lines", "hard-edge", "texture", "colors", "saturation", "transparency", "noise"]
        let evidenceMetrics: Set<String> = ["visible_weight", "reference_gradient_energy", "edge_pairs", "reference_texture_energy", "hue_evaluated_pixels", "alpha_boundary_pixels", "noise_roi_pixels"]
        let limits = [controlLimits] + scenes.map(\.criticalLimits)
        let budgets = [performanceBudgets.maximumColdLatencyRatio, performanceBudgets.maximumWarmLatencyRatio, performanceBudgets.maximumPeakRSSRatio]
        guard schemaVersion == 1, frozenBeforeAcceptance, measurementSpace == "extended-linear-sRGB-straight-RGBA",
              minimumRepetitions >= 5, minimumP95Samples >= 30, Set(scenes.map(\.id)) == expectedScenes,
              scenes.count == expectedScenes.count, !controlLimits.isEmpty,
              scenes.allSatisfy({ $0.requiredEvidenceMetric.map(evidenceMetrics.contains) == true }),
              limits.allSatisfy({ !$0.isEmpty && Set($0.keys).isSubset(of: AlgorithmEvaluationMetrics.metricNames) && $0.values.allSatisfy({ $0.isFinite && $0 >= 0 }) }),
              budgets.allSatisfy({ $0.isFinite && $0 > 0 }),
              effectAbsoluteTolerance.isFinite, effectAbsoluteTolerance >= 0,
              effectRelativeTolerance.isFinite, effectRelativeTolerance >= 0,
              Set(numericalTolerance.keys) == ["cpu_max_absolute_rgb", "ci_half_float_max_absolute_rgb", "ci_half_float_max_absolute_alpha"],
              numericalTolerance.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw AlgorithmEvaluationMetricError.invalid("Incomplete or invalid frozen measurement manifest")
        }
    }

    func checkControl(sceneClass: String, measurement: AlgorithmEvaluationMetrics.Measurement,
                      numericalBackend: String = "ci") -> [String] {
        guard scenes.contains(where: { $0.id == sceneClass }) else { return ["Unknown scene class: \(sceneClass)"] }
        guard ["cpu", "ci"].contains(numericalBackend) else { return ["Unknown numerical backend: \(numericalBackend)"] }
        guard measurement.values.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return ["Negative/nonfinite control metric"] }
        var limits = controlLimits
        let key = numericalBackend == "cpu" ? "cpu_max_absolute_rgb" : "ci_half_float_max_absolute_rgb"
        limits["max_rgb_error"] = min(limits["max_rgb_error", default: .infinity], numericalTolerance[key, default: 0])
        if numericalBackend == "ci" {
            limits["alpha_error"] = min(limits["alpha_error", default: .infinity], numericalTolerance["ci_half_float_max_absolute_alpha", default: 0])
        } else {
            limits["alpha_error"] = min(limits["alpha_error", default: .infinity], numericalTolerance["cpu_max_absolute_rgb", default: 0])
        }
        return violations(limits: limits, values: measurement.values)
    }

    func checkControl(sceneClass: String, measurement: AlgorithmEvaluationMetrics.Measurement,
                      adapterID: String) -> [String] {
        guard ["unchanged", "neutral-ci", "neutral-rec2020"].contains(adapterID) else { return ["Unknown control adapter: \(adapterID)"] }
        return checkControl(sceneClass: sceneClass, measurement: measurement,
                            numericalBackend: adapterID == "neutral-ci" ? "ci" : "cpu")
    }

    fileprivate func violations(limits: [String: Double], values: [String: Double]) -> [String] {
        limits.keys.sorted().compactMap { metric in
            guard let value = values[metric], value.isFinite else { return "Missing/nonfinite metric: \(metric)" }
            return value <= limits[metric]! ? nil : "\(metric)=\(value) exceeds \(limits[metric]!)"
        }
    }
}

struct AlgorithmEvaluationCandidateRegistry: Codable, Sendable {
    struct Candidate: Codable, Sendable {
        let id: String
        let kind: String
        let implemented: Bool
        let issue: Int?
        let sourceCommit: String?
        let domain: String?
        let primarySceneClass: String?
        let primaryMetric: String?
        let minimumRelativeImprovement: Double?
        var comparisonManifest: String? = nil
        let missingEvidence: [String]
    }
    let schemaVersion: Int
    let candidates: [Candidate]

    static func load(from url: URL) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.schemaVersion == 1, !result.candidates.isEmpty,
              Set(result.candidates.map(\.id)).count == result.candidates.count,
              result.candidates.allSatisfy({ candidate in
                  guard !candidate.id.isEmpty, ["control", "reference"].contains(candidate.kind) else { return false }
                  if candidate.kind == "control" { return candidate.implemented }
                  let specializedTone = candidate.id == "LC-03" && candidate.domain == "tone"
                      && candidate.primarySceneClass == "fine-lines"
                      && candidate.comparisonManifest == "lc03-manifest.json"
                  let specializedDetail = candidate.id == "LC-04" && candidate.domain == "detail"
                      && candidate.primarySceneClass == "hard-edge"
                      && candidate.comparisonManifest == "lc04-manifest.json"
                  let specializedColor = candidate.id == "LC-05" && candidate.domain == "color"
                      && candidate.primarySceneClass == "colors"
                      && candidate.comparisonManifest == "lc05-manifest.json"
                  let specializedDenoise = candidate.id == "LC-06" && candidate.domain == "denoise"
                      && candidate.primarySceneClass == "noise"
                      && candidate.comparisonManifest == "lc06-manifest.json"
                  guard let primary = candidate.primaryMetric,
                        AlgorithmEvaluationMetrics.metricNames.contains(primary)
                            || (specializedTone && primary == "log_line_contrast_error")
                            || (specializedDetail && primary == "halo_area")
                            || (specializedColor && primary == "hue_drift_mean_degrees")
                            || (specializedDenoise && primary == "detail_rgb_rmse"),
                        let improvement = candidate.minimumRelativeImprovement,
                        improvement.isFinite, improvement > 0, improvement < 1,
                        let domain = candidate.domain, ["tone", "detail", "color", "denoise"].contains(domain),
                        let scene = candidate.primarySceneClass,
                        ["ramp", "constants", "fine-lines", "hard-edge", "texture", "colors", "saturation", "transparency", "noise"].contains(scene),
                        let sha = candidate.sourceCommit, sha.count == 40,
                        sha.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
                  return true
              }) else {
            throw AlgorithmEvaluationMetricError.invalid("Invalid candidate registry")
        }
        return result
    }
}

enum AlgorithmEvaluationGate {
    struct SceneComparison: Sendable {
        let sceneClass: String
        let baselineQuality: AlgorithmEvaluationMetrics.Measurement
        let candidateQuality: AlgorithmEvaluationMetrics.Measurement
        let difference: AlgorithmEvaluationMetrics.Measurement
    }
    struct Evidence: Sendable {
        var identicalInputHashes = false
        var effectStrengthMatched = false
        var baselineEffectStrength: Double? = nil
        var candidateEffectStrength: Double? = nil
        var tuningFixtureIDs: [String] = []
        var acceptanceFixtureIDs: [String] = []
        var manifestSHA256BeforeAcceptance = ""
        var manifestSHA256AfterAcceptance = ""
        var visualApprovalReference: String? = nil
        var realPhotoCoverageApprovalReference: String? = nil
        var coldRepetitions = 0
        var warmRepetitions = 0
        var coldLatencyRatio: Double? = nil
        var warmLatencyRatio: Double? = nil
        var peakRSSRatio: Double? = nil
    }
    struct Decision: Codable, Sendable {
        let candidateID: String
        let status: String
        let reasons: [String]
    }

    static func evaluate(candidate: AlgorithmEvaluationCandidateRegistry.Candidate,
                         manifest: AlgorithmEvaluationManifest, scenes: [SceneComparison],
                         evidence: Evidence = Evidence()) -> Decision {
        func decision(_ status: String, _ reasons: [String]) -> Decision {
            Decision(candidateID: candidate.id, status: status, reasons: reasons)
        }
        guard (try? manifest.validate()) != nil else { return decision("blocked", ["Invalid measurement manifest"]) }
        guard candidate.implemented else {
            return decision("blocked", ["Reference adapter is not implemented"] + candidate.missingEvidence)
        }
        let required = Set(manifest.scenes.map(\.id))
        guard Set(scenes.map(\.sceneClass)) == required, scenes.count == required.count else {
            return decision("blocked", ["Missing or duplicate acceptance scene classes"])
        }
        if candidate.kind == "control" {
            let failures = scenes.flatMap { scene in
                manifest.checkControl(sceneClass: scene.sceneClass, measurement: scene.difference,
                                      adapterID: candidate.id).map { "\(scene.sceneClass): \($0)" }
            }
            return decision(failures.isEmpty ? "control-pass" : "no-go", failures.isEmpty ? ["Harness integrity only; no algorithm-quality claim"] : failures)
        }
        var missing = candidate.missingEvidence
        if !evidence.identicalInputHashes { missing.append("Identical developed-input hashes are unproven") }
        if !evidence.effectStrengthMatched { missing.append("Effect strength is not matched on tuning fixtures") }
        if let first = evidence.baselineEffectStrength, let second = evidence.candidateEffectStrength,
           first.isFinite, second.isFinite {
            // A neutral target cannot establish equivalence of a visible edit;
            // a weaker/no-effect candidate must not win by avoiding the effect.
            if abs(first) <= manifest.effectAbsoluteTolerance {
                missing.append("Baseline effect strength is indistinguishable from a neutral target")
            }
            if abs(first - second) > max(manifest.effectAbsoluteTolerance, abs(first) * manifest.effectRelativeTolerance) {
                missing.append("Measured tuning effect strengths exceed the matching tolerance")
            }
        } else {
            missing.append("Missing/nonfinite measured tuning effect strengths")
        }
        let fixtureIDs = evidence.tuningFixtureIDs + evidence.acceptanceFixtureIDs
        if evidence.tuningFixtureIDs.isEmpty || evidence.acceptanceFixtureIDs.isEmpty ||
            fixtureIDs.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ||
            Set(fixtureIDs).count != fixtureIDs.count ||
            !Set(evidence.tuningFixtureIDs).isDisjoint(with: evidence.acceptanceFixtureIDs) {
            missing.append("Separate tuning and acceptance fixtures are unproven")
        }
        let hash = evidence.manifestSHA256BeforeAcceptance
        if hash.count != 64 || !hash.allSatisfy({ "0123456789abcdef".contains($0) }) || hash != evidence.manifestSHA256AfterAcceptance {
            missing.append("Manifest was not frozen unchanged before acceptance")
        }
        if evidence.visualApprovalReference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missing.append("Missing blinded visual approval") }
        if evidence.realPhotoCoverageApprovalReference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missing.append("Missing licensed real-photo coverage approval") }
        if evidence.coldRepetitions < manifest.minimumRepetitions || evidence.warmRepetitions < manifest.minimumRepetitions {
            missing.append("Insufficient controlled cold/warm repetitions")
        }
        let ratios = [evidence.coldLatencyRatio, evidence.warmLatencyRatio, evidence.peakRSSRatio]
        if ratios.contains(where: { $0 == nil || !$0!.isFinite || $0! <= 0 }) { missing.append("Missing/invalid end-to-end time or RSS ratios") }
        var failures: [String] = []
        for scene in scenes {
            let spec = manifest.scenes.first { $0.id == scene.sceneClass }!
            for (label, measurement) in [("baseline", scene.baselineQuality), ("candidate", scene.candidateQuality), ("difference", scene.difference)] {
                if !AlgorithmEvaluationMetrics.metricNames.isSubset(of: Set(measurement.values.keys)) ||
                    measurement.values.values.contains(where: { !$0.isFinite || $0 < 0 }) {
                    missing.append("\(scene.sceneClass): incomplete/nonfinite/negative \(label) measurement")
                }
            }
            for metric in spec.criticalLimits.keys {
                guard let value = scene.difference.values[metric], value.isFinite else {
                    missing.append("\(scene.sceneClass): missing/nonfinite critical metric \(metric)"); continue
                }
            }
            if let requiredMetric = spec.requiredEvidenceMetric,
               scene.candidateQuality.values[requiredMetric, default: 0] <= 0 || !(scene.candidateQuality.values[requiredMetric]?.isFinite ?? false) {
                missing.append("\(scene.sceneClass): missing eligible ROI evidence \(requiredMetric)")
            }
            failures += manifest.violations(limits: spec.criticalLimits, values: scene.difference.values).map { "\(scene.sceneClass): \($0)" }
        }
        guard let primaryScene = candidate.primarySceneClass, let metric = candidate.primaryMetric,
              let improvement = candidate.minimumRelativeImprovement, improvement.isFinite, improvement > 0, improvement < 1,
              let primary = scenes.first(where: { $0.sceneClass == primaryScene }),
              let baseline = primary.baselineQuality.values[metric], baseline.isFinite,
              let output = primary.candidateQuality.values[metric], output.isFinite, baseline >= 0, output >= 0 else {
            return decision("blocked", missing + ["Missing/invalid predeclared primary quality evidence"])
        }
        guard missing.isEmpty else { return decision("blocked", missing) }
        if baseline <= 1e-12 || output > baseline * (1 - improvement) {
            failures.append("Primary \(primaryScene)/\(metric) does not improve by \(improvement * 100)%")
        }
        if evidence.coldLatencyRatio! > manifest.performanceBudgets.maximumColdLatencyRatio { failures.append("Cold end-to-end latency budget exceeded") }
        if evidence.warmLatencyRatio! > manifest.performanceBudgets.maximumWarmLatencyRatio { failures.append("Warm end-to-end latency budget exceeded") }
        if evidence.peakRSSRatio! > manifest.performanceBudgets.maximumPeakRSSRatio { failures.append("Peak RSS budget exceeded") }
        return decision(failures.isEmpty ? "go" : "no-go", failures.isEmpty ? ["Predeclared primary improvement, critical cases, visual approval and budgets passed"] : failures)
    }
}
