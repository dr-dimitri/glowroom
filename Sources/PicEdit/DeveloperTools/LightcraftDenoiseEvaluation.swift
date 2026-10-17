#if PICEDIT_EDITING_BENCHMARK
import CoreImage
import Foundation
import PicEditCore

/// Measurements stay serial; each CPU filter uses the common bounded row pool.
enum LightcraftDenoiseEvaluation {
    typealias Raster = AlgorithmEvaluationRaster
    typealias Evaluation = AlgorithmEvaluation
    typealias Reference = LightcraftDenoiseReference
    typealias Fixtures = LightcraftDenoiseFixtures
    typealias Comparison = LightcraftDenoiseComparison
    struct Direction: Codable {
        let id: String
        let control: String
        let value: Double
        let primary: Bool
        func settings(_ amount: Double? = nil) -> EditSettings {
            var s = EditSettings.neutral
            if control == "luminance" { s.luminanceNoiseReduction = amount ?? value }
            else { s.colorNoiseReduction = amount ?? value }
            return s
        }
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
        struct Contracts: Codable { let neutralValues: [Double]; let alphaTolerance: Double }
        struct Scaling: Codable { let sceneClass: String; let nativeSize: [Int]; let previewSizes: [[Int]] }
        let schemaVersion: Int
        let protocolID: String
        let sourceCommit: String
        let qualityWidth: Int
        let qualityHeight: Int
        let directions: [Direction]
        let matching: Matching
        let contracts: Contracts
        let criticalLimits: [String: Double]
        let performanceSceneClass: String
        let scaling: Scaling
        static func load(_ url: URL) throws -> Self {
            let m = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard m.schemaVersion == 1, m.protocolID == "LC06-denoise-v1",
                  m.sourceCommit == "f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15",
                  m.qualityWidth == 256, m.qualityHeight == 160,
                  m.matching.sceneClasses == Fixtures.sceneClasses,
                  m.performanceSceneClass == "texture", m.scaling.sceneClass == "texture",
                  m.scaling.nativeSize == [4608, 3072], m.scaling.previewSizes == [[512, 341], [2400, 1600], [4096, 2731]],
                  m.directions.count == 6, Set(m.directions.map(\.id)).count == 6,
                  m.directions.allSatisfy({ ["luminance", "chroma"].contains($0.control) && [20.0, 60, 100].contains($0.value) && $0.primary == ($0.value < 100) && $0.id == "\($0.control)-\(Int($0.value))" }),
                  m.matching.coarseSteps == 33, m.matching.refinementSteps == 17,
                  m.contracts.neutralValues == [0, 1],
                  [m.matching.minimumAbsoluteTarget, m.matching.maximumAbsoluteDeltaError, m.matching.maximumRelativeDeltaError, m.contracts.alphaTolerance].allSatisfy({ $0.isFinite && $0 > 0 }),
                  Set(m.criticalLimits.keys) == Set(["lumaDriftMeanIncrease", "chromaFringingIncrease", "gamutFractionIncrease", "clippingFractionIncrease", "alphaError"]),
                  m.criticalLimits.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw Benchmark.failure("Invalid LC-06 manifest") }
            return m
        }
    }
    struct Calibration: Codable {
        let sceneClass: String
        let directionID: String
        let inputSHA256: String
        let groundTruthSHA256: String
        let parameter: Double
        let target: Double
        let measured: Double
        let matched: Bool
    }
    struct CalibrationFile: Codable { let manifestSHA256: String; let records: [Calibration] }
    static func matches(_ target: Double, _ measured: Double, _ m: Manifest) -> Bool {
        target.isFinite && measured.isFinite && target >= m.matching.minimumAbsoluteTarget && measured > 0 && abs(target - measured) <= max(m.matching.maximumAbsoluteDeltaError, abs(target) * m.matching.maximumRelativeDeltaError)
    }
    static func reference(_ control: String, input: Raster, native: Int? = nil,
                          sampling: Reference.InputSampling = .native, scaling: Reference.Scaling = .nativePixels) -> Reference {
        Reference(control: control == "luminance" ? .luminance : .chroma,
                  geometry: .init(nativeLong: native ?? max(input.width, input.height), pixelsPerLongEdge: Double(max(input.width, input.height)), inputSampling: sampling), scaling: scaling)
    }
    static func truth(_ fixture: AlgorithmEvaluationFixtures.Fixture) throws -> Raster {
        guard let clean = fixture.groundTruth else { throw Benchmark.failure("LC-06 requires clean ground truth") }
        return clean
    }
    static func fit(_ c: CalibrationFile, _ scene: String, _ direction: Direction) throws -> Calibration {
        guard let row = c.records.first(where: { $0.sceneClass == scene && $0.directionID == direction.id }) else { throw Benchmark.failure("Missing LC-06 calibration") }
        return row
    }
    static func run(_ options: Benchmark.Options) throws {
        guard !options.output.isEmpty, !options.manifest.isEmpty, options.backend == "default", options.workers == 1,
              options.width * options.height <= 32_000_000,
              ["denoise-tune", "denoise-quality", "denoise-timing", "denoise-scale"].contains(options.evaluationMode),
              ["picedit", "lightcraft", "picedit-luminance", "lightcraft-luminance", "picedit-chroma", "lightcraft-chroma"].contains(options.adapter) else { throw Benchmark.failure("Invalid LC-06 options") }
        let url = URL(fileURLWithPath: options.manifest), m = try Manifest.load(url), hash = Evaluation.sha(try Data(contentsOf: url))
        let output = URL(fileURLWithPath: options.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Benchmark.failure("Refusing to overwrite LC-06 output") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if options.evaluationMode == "denoise-tune" { try tune(m, hash: hash, output: output) }
        else {
            guard !options.calibration.isEmpty else { throw Benchmark.failure("LC-06 requires frozen calibration") }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: options.calibration)), c = try JSONDecoder().decode(CalibrationFile.self, from: bytes)
            guard c.manifestSHA256 == hash, c.records.count == 48,
                  Set(c.records.map { "\($0.sceneClass):\($0.directionID)" }).count == 48 else { throw Benchmark.failure("Invalid LC-06 calibration matrix") }
            for scene in Fixtures.sceneClasses {
                let f = try Fixtures.make(sceneClass: scene, split: .tuning, width: m.qualityWidth, height: m.qualityHeight), clean = try truth(f)
                for d in m.directions {
                    let r = try fit(c, scene, d)
                    guard r.inputSHA256 == f.input.sha256, r.groundTruthSHA256 == clean.sha256, r.parameter.isFinite, (0...100).contains(r.parameter),
                          r.target.isFinite, r.measured.isFinite, r.matched == matches(r.target, r.measured, m) else { throw Benchmark.failure("Invalid LC-06 calibration provenance") }
                }
            }
            switch options.evaluationMode {
            case "denoise-quality": try quality(m, calibration: c, hash: hash, calibrationHash: Evaluation.sha(bytes), output: output)
            case "denoise-timing": try timing(options, m: m, calibration: c, output: output)
            default: try scale(m, calibration: c, output: output)
            }
        }
        guard Evaluation.sha(try Data(contentsOf: url)) == hash else { throw Benchmark.failure("LC-06 protocol changed") }
    }
    static func tune(_ m: Manifest, hash: String, output: URL) throws {
        let ci = Evaluation.context()
        var records: [Calibration] = []
        for scene in Fixtures.sceneClasses { try autoreleasepool {
            let f = try Fixtures.make(sceneClass: scene, split: .tuning, width: m.qualityWidth, height: m.qualityHeight), input = f.input, clean = try truth(f)
            for d in m.directions {
                let baseline = try Evaluation.render(input, settings: d.settings(), context: ci)
                let target = try Comparison.strength(noisy: input, clean: clean, output: baseline, control: d.control), ref = reference(d.control, input: input)
                var parameter = 0.0, measured = 0.0, error = Double.infinity
                func search(_ low: Double, _ high: Double, _ count: Int) throws {
                    for step in 0..<count { try autoreleasepool {
                        let amount = low + (high - low) * Double(step) / Double(count - 1)
                        let result = try ref.render(input, settings: d.settings(amount))
                        let value = try Comparison.strength(noisy: input, clean: clean, output: result, control: d.control)
                        if abs(value - target) < error { parameter = amount; measured = value; error = abs(value - target) }
                    } }
                }
                if target >= m.matching.minimumAbsoluteTarget {
                    try search(0, 100, m.matching.coarseSteps)
                    let interval = 100 / Double(m.matching.coarseSteps - 1)
                    try search(max(0, parameter - interval), min(100, parameter + interval), m.matching.refinementSteps)
                }
                records.append(.init(sceneClass: scene, directionID: d.id, inputSHA256: input.sha256, groundTruthSHA256: clean.sha256,
                                     parameter: parameter, target: target, measured: measured, matched: matches(target, measured, m)))
            }
        } }
        try Evaluation.writeJSON(Evaluation.object(CalibrationFile(manifestSHA256: hash, records: records)), output.appendingPathComponent("calibration.json"))
    }
    static func contracts(_ values: [String: Double], m: Manifest) -> [String] {
        var failures: [String] = []
        if values.values.contains(where: { !$0.isFinite }) { failures.append("nonfinite_metrics") }
        if values["alpha_error", default: .infinity] > m.contracts.alphaTolerance { failures.append("alpha_error") }
        if values["hidden_rgb_error", default: .infinity] > 0 { failures.append("hidden_rgb_error") }
        return failures
    }
    static func critical(_ before: [String: Double], _ after: [String: Double], m: Manifest) -> [String] {
        var result = [("luma_drift_mean", "lumaDriftMeanIncrease"), ("chroma_fringing_rmse", "chromaFringingIncrease"),
                      ("gamut_fraction", "gamutFractionIncrease"), ("clipping_fraction", "clippingFractionIncrease")].compactMap { key, limit -> String? in
            guard let a = after[key], let b = before[key], let cap = m.criticalLimits[limit] else { return nil }
            return a - b > cap ? key : nil
        }
        if after["alpha_error", default: .infinity] > m.criticalLimits["alphaError"]! { result.append("alpha_error") }
        return result
    }
    static func quality(_ m: Manifest, calibration: CalibrationFile, hash: String, calibrationHash: String, output: URL) throws {
        let ci = Evaluation.context()
        var rows: [[String: Any]] = [], zero: [[String: Any]] = []
        for scene in Fixtures.sceneClasses { try autoreleasepool {
            let f = try Fixtures.make(sceneClass: scene, split: .acceptance, width: m.qualityWidth, height: m.qualityHeight), input = f.input, clean = try truth(f)
            for d in m.directions { try autoreleasepool {
                let tuning = try fit(calibration, scene, d), ref = reference(d.control, input: input)
                let baseline = try Evaluation.render(input, settings: d.settings(), context: ci), candidate = try ref.render(input, settings: d.settings(tuning.parameter))
                let before = try Comparison.measurement(noisy: input, clean: clean, output: baseline), after = try Comparison.measurement(noisy: input, clean: clean, output: candidate)
                let target = try Comparison.strength(noisy: input, clean: clean, output: baseline, control: d.control)
                let measured = try Comparison.strength(noisy: input, clean: clean, output: candidate, control: d.control)
                let matched = tuning.matched && matches(target, measured, m), name = "\(f.id)-\(d.id)", folder = output.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, raster) in [("input", input), ("ground-truth", clean), ("picedit", baseline), ("lightcraft", candidate),
                                       ("same-values", try ref.render(input, settings: d.settings())), ("difference", try Evaluation.difference(baseline, candidate))] {
                    try Evaluation.png(raster.previewImage(), folder.appendingPathComponent("\(name).png"))
                }
                try Evaluation.png(candidate.previewImage(background: 0), folder.appendingPathComponent("dark.png"))
                try Evaluation.png(candidate.previewImage(background: 1), folder.appendingPathComponent("light.png"))
                rows.append(["fixture": f.id, "scene_class": scene, "direction": d.id, "control": d.control, "primary": d.primary,
                             "parameter": tuning.parameter, "matched": matched, "tuning_matched": tuning.matched, "effect_target": target, "effect_measured": measured,
                             "baseline_metrics": before, "candidate_metrics": after, "baseline_settings": try Evaluation.object(d.settings()), "candidate_settings": try Evaluation.object(d.settings(tuning.parameter)),
                             "parameters": try Evaluation.object(ref.parameters(amount: tuning.parameter)), "critical_failures": matched ? critical(before, after, m: m) : [],
                             "contract_failures": contracts(after, m: m), "finite": true, "input_sha256": input.sha256, "ground_truth_sha256": clean.sha256, "output_sha256": candidate.sha256, "directory": name])
            } }
            for control in Reference.Control.allCases {
                let d = m.directions.first { $0.control == control.rawValue }!, ref = reference(d.control, input: input)
                for value in m.contracts.neutralValues {
                    let candidate = try ref.render(input, settings: d.settings(value)), metrics = try Comparison.measurement(noisy: input, clean: clean, output: candidate)
                    zero.append(["scene_class": scene, "control": d.control, "value": value, "metrics": metrics, "finite": true,
                                 "input_sha256": input.sha256, "ground_truth_sha256": clean.sha256, "output_sha256": candidate.sha256,
                                 "identity": input.sha256 == candidate.sha256, "contract_failures": contracts(metrics, m: m)])
                }
            }
        } }
        try Evaluation.writeJSON(["manifest_sha256": hash, "calibration_sha256": calibrationHash, "records": rows, "zero_diagnostics": zero,
                                  "stages": try stages(m, calibration: calibration, ci: ci)], output.appendingPathComponent("quality.json"))
    }
    static func timing(_ options: Benchmark.Options, m: Manifest, calibration: CalibrationFile, output: URL) throws {
        guard options.iterations >= 5, options.adapter.contains("-") else { throw Benchmark.failure("LC-06 timing requires a control and five warm samples") }
        let control = options.adapter.hasSuffix("luminance") ? "luminance" : "chroma", baseline = options.adapter.hasPrefix("picedit")
        let f = try Fixtures.make(sceneClass: m.performanceSceneClass, split: .acceptance, width: options.width, height: options.height), input = f.input, clean = try truth(f)
        let d = m.directions.first { $0.control == control && $0.value == 20 }!, tuning = try fit(calibration, m.performanceSceneClass, d), ref = reference(control, input: input)
        var ci: CIContext?, samples: [[String: Any]] = []
        for step in -1...options.iterations { try autoreleasepool {
            let value = step <= 0 ? 20.0 : Double(18 + (step - 1) % 5), settings = d.settings(baseline ? value : tuning.parameter * value / 20)
            let start = ContinuousClock.now
            let result: Raster
            if baseline { if ci == nil { ci = Evaluation.context() }; result = try Evaluation.render(input, settings: settings, context: ci!) }
            else { result = try ref.render(input, settings: settings) }
            let elapsed = Benchmark.milliseconds(start.duration(to: .now)), rss = Benchmark.peakRSS()
            samples.append(["phase": step < 0 ? "process-cold" : (step == 0 ? "warmup" : "warm"), "sample": step, "total_ms": elapsed, "peak_rss_bytes": rss,
                            "settings": try Evaluation.object(settings), "effect_strength": try Comparison.strength(noisy: input, clean: clean, output: result, control: control), "output_sha256": result.sha256])
        } }
        try Evaluation.writeJSON(["adapter": options.adapter, "control": control, "width": input.width, "height": input.height,
                                  "input_sha256": input.sha256, "ground_truth_sha256": clean.sha256, "samples": samples, "peak_rss_bytes": Benchmark.peakRSS(),
                                  "tuning_matched": tuning.matched, "geometry": try Evaluation.object(ref.geometry),
                                  "scope": "Full adapter including conversion and all spatial planes, no decoder. Native sampling at each measured size; scaling is a separate experiment.",
                                  "cold_scope": "Fresh process, OS/driver caches not cleared", "rss_scope": "Whole process high-water including clean/noisy input and validation/metric reductions"], output.appendingPathComponent("timing.json"))
    }
    static func scale(_ m: Manifest, calibration: CalibrationFile, output: URL) throws {
        let f = try Fixtures.make(sceneClass: m.scaling.sceneClass, split: .acceptance, width: m.scaling.nativeSize[0], height: m.scaling.nativeSize[1]), input = f.input, clean = try truth(f)
        let inputHash = input.sha256, cleanHash = clean.sha256, ci = Evaluation.context()
        var rows: [[String: Any]] = []
        for d in m.directions { try autoreleasepool {
            let tuning = try fit(calibration, m.scaling.sceneClass, d)
            // Full output is shared within each formula/amount. Both scaling
            // variants use the identical formula and full-resolution result.
            for baseline in [true, false] { try autoreleasepool {
                let settings = d.settings(baseline ? d.value : tuning.parameter)
                let full = try baseline ? Evaluation.render(input, settings: settings, context: ci) : reference(d.control, input: input).render(input, settings: settings)
                let fullHash = full.sha256
                for size in m.scaling.previewSizes { try autoreleasepool {
                    let small = try Fixtures.areaAverage(input, width: size[0], height: size[1]), smallClean = try Fixtures.areaAverage(clean, width: size[0], height: size[1])
                    let down = try Fixtures.areaAverage(full, width: size[0], height: size[1])
                    let fullQuality = try Comparison.measurement(noisy: small, clean: smallClean, output: down), identity = try Comparison.scaleDistance(reference: down, candidate: small)
                    for variant in baseline ? ["picedit"] : ["nativePixels", "unscaled"] { try autoreleasepool {
                        let ref = reference(d.control, input: small, native: m.scaling.nativeSize[0], sampling: .areaAveraged, scaling: variant == "unscaled" ? .unscaled : .nativePixels)
                        let direct = try baseline ? Evaluation.render(small, settings: settings, context: ci) : ref.render(small, settings: settings)
                        let name = "\(d.id)-\(size[0])-\(variant)"
                        try Evaluation.png(Evaluation.downsample(direct, context: ci).previewImage(), output.appendingPathComponent("\(name)-direct.png"))
                        try Evaluation.png(Evaluation.downsample(down, context: ci).previewImage(), output.appendingPathComponent("\(name)-scaled-full.png"))
                        rows.append(["control": d.control, "direction": d.id, "width": size[0], "height": size[1], "variant": variant,
                                     "metrics": try Comparison.scaleDistance(reference: down, candidate: direct), "quality_metrics": try Comparison.measurement(noisy: small, clean: smallClean, output: direct),
                                     "full_quality_metrics": fullQuality, "identity_metrics": identity, "input_sha256": small.sha256, "ground_truth_sha256": smallClean.sha256,
                                     "full_input_sha256": inputHash, "full_ground_truth_sha256": cleanHash, "full_output_sha256": fullHash, "output_sha256": direct.sha256,
                                     "settings": try Evaluation.object(settings), "sampling": "areaAveraged", "native_long": m.scaling.nativeSize[0], "pixels_per_long_edge": size[0],
                                     "parameter": baseline ? d.value : tuning.parameter, "finite": true, "directory": name])
                    } }
                } }
            } }
        } }
        try Evaluation.writeJSON(["full_size": m.scaling.nativeSize, "records": rows,
                                  "scope": "Explicit area averaging BEFORE preview NR and AFTER native NR; frozen formula mapping. Unknown decoder sampling is not modeled; PNGs are display thumbnails."], output.appendingPathComponent("scale.json"))
    }
    static func stages(_ m: Manifest, calibration: CalibrationFile, ci: CIContext) throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for scene in ["dark-edges", "color-lines", "transparency", "p3-dark"] {
            let f = try Fixtures.make(sceneClass: scene, split: .acceptance, width: m.qualityWidth, height: m.qualityHeight), input = f.input
            for sign in [-1.0, 1] { for auto in [0.0, 100] {
                var suffix = EditSettings.neutral; suffix.exposure = sign * 0.7; suffix.shadows = sign * 20; suffix.highlights = sign * -20; suffix.dehaze = sign * 30; suffix.autoToneAmount = auto
                for d in m.directions where d.value == 20 {
                    let tuning = try fit(calibration, scene, d), ref = reference(d.control, input: input)
                    var combined = suffix
                    if d.control == "luminance" { combined.luminanceNoiseReduction = d.value } else { combined.colorNoiseReduction = d.value }
                    let baseline = try Evaluation.render(input, settings: combined, context: ci)
                    let early = try Evaluation.render(ref.render(input, settings: d.settings(tuning.parameter)), settings: suffix, context: ci)
                    let late = try ref.render(Evaluation.render(input, settings: suffix, context: ci), settings: d.settings(tuning.parameter))
                    rows.append(["scene_class": scene, "direction": d.id, "control": d.control, "suffix_settings": try Evaluation.object(suffix),
                                 "early_compatibility": try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: early).values,
                                 "order_difference": try AlgorithmEvaluationMetrics.measure(reference: early, candidate: late).values,
                                 "scope": "Diagnostic only: intermediate clamp/roundtrip and changed AutoTone analysis accompany order differences; not fixed-tone ordering or production integration parity."])
                }
            } }
        }
        return rows
    }
}
#endif
