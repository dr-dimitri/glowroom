#if GLOWROOM_EDITING_BENCHMARK
import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore

/// #175 uses LC-06 fixtures and masks, never the rejected #55 filter. The
/// candidate is CPU-only evaluation code; the production baseline is V2 CI.
enum MultiscaleDenoiseEvaluation {
    typealias Raster = AlgorithmEvaluationRaster
    typealias Evaluation = AlgorithmEvaluation
    typealias Comparison = MultiscaleDenoiseComparison
    typealias Metrics = LightcraftDenoiseComparison
    struct Manifest: Decodable {
        struct Matching: Decodable { let minimumTarget: Double; let absoluteTolerance: Double; let relativeTolerance: Double; let coarseSteps: Int; let refinementSteps: Int }
        struct Scaling: Decodable { let nativeSize: [Int]; let previewSizes: [[Int]] }
        let schemaVersion: Int; let protocolID: String; let qualitySize: [Int]; let scenes: [String]; let values: [Double]; let controls: [String]
        let matching: Matching; let scaling: Scaling
        static func load(_ data: Data) throws -> Self {
            let m = try JSONDecoder().decode(Self.self, from: data)
            guard m.schemaVersion == 1, m.protocolID == "multiscale-denoise-175-v1", m.qualitySize == [256, 160],
                  m.scenes == Comparison.sceneClasses, m.controls == ["luminance", "chroma", "joint"], m.values == [20, 60, 100],
                  m.matching.minimumTarget == 0.0002, m.matching.absoluteTolerance == 0.00001, m.matching.relativeTolerance == 0.05,
                  m.matching.coarseSteps == 33, m.matching.refinementSteps == 17,
                  m.scaling.nativeSize == [4608, 3072], m.scaling.previewSizes == [[512,341],[2400,1600],[4096,2731]] else { throw Benchmark.failure("Invalid #175 frozen protocol") }
            return m
        }
    }
    struct Calibration: Codable {
        let scene: String; let control: String; let value: Double; let luminance: Double; let chroma: Double
        let inputSHA256: String; let truthSHA256: String; let targets: [String: Double]; let measured: [String: Double]; let matched: Bool
    }
    struct CalibrationFile: Codable { let manifestSHA256: String; let records: [Calibration] }
    static func settings(_ control: String, value: Double, scene: String) -> EditSettings {
        var s = EditSettings.neutral; s.toneProcessingVersion = .consistentV2
        if control != "chroma" { s.luminanceNoiseReduction = value }
        if control != "luminance" { s.colorNoiseReduction = value }
        s.developColor.hdrEnabled = scene == "hdr"
        return s
    }
    static func context(software: Bool = false) -> CIContext {
        CIContext(options: [.workingColorSpace: Evaluation.space, .workingFormat: CIFormat.RGBAf,
                            .useSoftwareRenderer: software, .cacheIntermediates: true, .name: "Glowroom #175 V2 float comparison"])
    }
    static func components(_ control: String) -> [String] { control == "joint" ? ["luminance", "chroma"] : [control] }
    static func matches(_ target: Double, _ actual: Double, _ m: Manifest) -> Bool {
        target.isFinite && actual.isFinite && target >= m.matching.minimumTarget && actual > 0 && abs(target - actual) <= max(m.matching.absoluteTolerance, target * m.matching.relativeTolerance)
    }
    static func reductions(_ input: Raster, _ clean: Raster, _ output: Raster, _ control: String) throws -> [String: Double] {
        try Dictionary(uniqueKeysWithValues: components(control).map { ($0, try Metrics.strength(noisy: input, clean: clean, output: output, control: $0)) })
    }
    static func calibration(_ records: [Calibration], scene: String, control: String, value: Double) throws -> Calibration {
        guard let row = records.first(where: { $0.scene == scene && $0.control == control && $0.value == value }) else { throw Benchmark.failure("Missing #175 calibration") }; return row
    }
    static func run(_ options: Benchmark.Options) throws {
        guard !options.output.isEmpty, !options.manifest.isEmpty, options.workers == 1, options.backend == "default",
              ["multiscale-denoise-tune", "multiscale-denoise-quality", "multiscale-denoise-timing", "multiscale-denoise-scale", "multiscale-denoise-photo"].contains(options.evaluationMode) else { throw Benchmark.failure("Invalid #175 options") }
        let manifestURL = URL(fileURLWithPath: options.manifest), bytes = try Data(contentsOf: manifestURL), m = try Manifest.load(bytes), hash = Evaluation.sha(bytes)
        let folder = URL(fileURLWithPath: options.output)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw Benchmark.failure("Refusing to overwrite #175 evidence") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if options.evaluationMode == "multiscale-denoise-tune" { try tune(m, hash: hash, output: folder) }
        else {
            guard !options.calibration.isEmpty else { throw Benchmark.failure("Frozen #175 calibration required") }
            let data = try Data(contentsOf: URL(fileURLWithPath: options.calibration)), c = try JSONDecoder().decode(CalibrationFile.self, from: data)
            guard c.manifestSHA256 == hash, c.records.count == m.scenes.count * m.controls.count * m.values.count,
                  Set(c.records.map { "\($0.scene):\($0.control):\($0.value)" }).count == c.records.count else { throw Benchmark.failure("Invalid #175 calibration matrix") }
            for scene in m.scenes {
                let fixture = try Comparison.make(scene, split: .tuning, width: m.qualitySize[0], height: m.qualitySize[1]), truth = try truth(fixture)
                for control in m.controls { for value in m.values {
                    let r = try calibration(c.records, scene: scene, control: control, value: value)
                    guard r.inputSHA256 == fixture.input.sha256, r.truthSHA256 == truth.sha256,
                          r.luminance.isFinite, r.chroma.isFinite, (0...100).contains(r.luminance), (0...100).contains(r.chroma),
                          Set(r.targets.keys) == Set(components(control)), Set(r.measured.keys) == Set(components(control)),
                          r.matched == components(control).allSatisfy({ matches(r.targets[$0]!, r.measured[$0]!, m) }) else { throw Benchmark.failure("Invalid #175 calibration provenance") }
                } }
            }
            switch options.evaluationMode {
            case "multiscale-denoise-quality": try quality(m, c: c, hash: hash, calibrationHash: Evaluation.sha(data), output: folder)
            case "multiscale-denoise-timing": try timing(options, m: m, c: c, output: folder)
            case "multiscale-denoise-photo": try photo(options, m: m, c: c, output: folder)
            default: try scale(m, c: c, output: folder)
            }
        }
        guard try Data(contentsOf: manifestURL) == bytes else { throw Benchmark.failure("#175 protocol changed during run") }
    }
    static func truth(_ f: AlgorithmEvaluationFixtures.Fixture) throws -> Raster {
        guard let truth = f.groundTruth else { throw Benchmark.failure("#175 requires clean ground truth") }; return truth
    }
    static func candidate(_ input: Raster, _ r: Calibration) throws -> Raster {
        try MultiscaleDenoiseCandidate.render(input, luminance: r.luminance, chroma: r.chroma)
    }
    static func tune(_ m: Manifest, hash: String, output: URL) throws {
        let ci = context(); var records: [Calibration] = []
        for scene in m.scenes { try autoreleasepool {
            let f = try Comparison.make(scene, split: .tuning, width: m.qualitySize[0], height: m.qualitySize[1]), clean = try truth(f)
            for control in m.controls { for value in m.values { try autoreleasepool {
                let baseline = try Evaluation.render(f.input, settings: settings(control, value: value, scene: scene), context: ci)
                let targets = try reductions(f.input, clean, baseline, control)
                var parameters: [String: Double] = ["luminance": 0, "chroma": 0], measured: [String: Double] = [:]
                for component in components(control) {
                    let target = targets[component]!, input = f.input
                    var best = 0.0, error = Double.infinity, actual = 0.0
                    func search(_ low: Double, _ high: Double, _ count: Int) throws {
                        for step in 0..<count { try autoreleasepool {
                            let amount = low + (high - low) * Double(step) / Double(count - 1)
                            let result = try MultiscaleDenoiseCandidate.render(input, luminance: component == "luminance" ? amount : 0, chroma: component == "chroma" ? amount : 0)
                            let strength = try Metrics.strength(noisy: input, clean: clean, output: result, control: component)
                            if abs(strength - target) < error { best = amount; actual = strength; error = abs(strength - target) }
                        } }
                    }
                    if target >= m.matching.minimumTarget {
                        try search(0, 100, m.matching.coarseSteps)
                        let interval = 100 / Double(m.matching.coarseSteps - 1)
                        try search(max(0, best - interval), min(100, best + interval), m.matching.refinementSteps)
                    }
                    parameters[component] = best; measured[component] = actual
                }
                records.append(Calibration(scene: scene, control: control, value: value, luminance: parameters["luminance"]!, chroma: parameters["chroma"]!,
                                           inputSHA256: f.input.sha256, truthSHA256: clean.sha256, targets: targets, measured: measured,
                                           matched: components(control).allSatisfy { matches(targets[$0]!, measured[$0]!, m) }))
            } } }
        } }
        try Evaluation.writeJSON(Evaluation.object(CalibrationFile(manifestSHA256: hash, records: records)), output.appendingPathComponent("calibration.json"))
    }
    static func quality(_ m: Manifest, c: CalibrationFile, hash: String, calibrationHash: String, output: URL) throws {
        let ci = context(), software = context(software: true); var rows: [[String: Any]] = [], zero: [[String: Any]] = [], parity: [[String: Any]] = []
        for scene in m.scenes { try autoreleasepool {
            let f = try Comparison.make(scene, split: .acceptance, width: m.qualitySize[0], height: m.qualitySize[1]), input = f.input, clean = try truth(f)
            for control in m.controls {
                let unchanged = try MultiscaleDenoiseCandidate.render(input, luminance: 0, chroma: 0)
                zero.append(["scene": scene, "control": control, "inputSHA256": input.sha256, "outputSHA256": unchanged.sha256, "identity": unchanged.sha256 == input.sha256])
                for value in m.values { try autoreleasepool {
                    let r = try calibration(c.records, scene: scene, control: control, value: value), s = settings(control, value: value, scene: scene)
                    let baseline = try Evaluation.render(input, settings: s, context: ci), candidate = try candidate(input, r)
                    let targets = try reductions(input, clean, baseline, control), measured = try reductions(input, clean, candidate, control)
                    let name = "\(scene)-\(control)-\(Int(value))"
                    for (label, raster) in [("clean", clean), ("noisy", input), ("baseline", baseline), ("candidate", candidate)] {
                        try Evaluation.png(raster.previewImage(), output.appendingPathComponent("\(name)-\(label).png"))
                    }
                    rows.append(["scene": scene, "control": control, "value": value, "luminance": r.luminance, "chroma": r.chroma,
                                 "inputSHA256": input.sha256, "truthSHA256": clean.sha256, "outputSHA256": candidate.sha256,
                                 "tuningMatched": r.matched, "targets": targets, "measured": measured,
                                 "matched": r.matched && components(control).allSatisfy { matches(targets[$0]!, measured[$0]!, m) },
                                 "baseline": try Comparison.measure(noisy: input, clean: clean, output: baseline, scene: scene),
                                 "candidate": try Comparison.measure(noisy: input, clean: clean, output: candidate, scene: scene),
                                 "directory": name, "targetProfile": scene == "p3-dark" ? "linear Display-P3 D65" : "linear sRGB D65", "targetUpper": scene == "hdr" ? 4 : 1])
                    if value == 20 && control == "joint" {
                        let cpuRequested = try Evaluation.render(input, settings: s, context: software)
                        parity.append(["scene": scene, "baselineDistance": try Metrics.scaleDistance(reference: baseline, candidate: cpuRequested),
                                       "candidateCPUOnly": true, "softwareRequested": true, "executionAttributed": false])
                    }
                } }
            }
        } }
        try Evaluation.writeJSON(["manifestSHA256": hash, "calibrationSHA256": calibrationHash, "records": rows, "zero": zero, "backendDiagnostics": parity,
                                  "evidence": ["real RAW-developed photographs": false, "independent matched-pair visual acceptance": false,
                                               "matched cold/warm/RSS performance at every size": false, "CPU/GPU execution attribution and equivalence": false,
                                               "preview/native scale matrix": false, "production cache/version/undo/cancellation integration": false],
                                  "productionChanged": false], output.appendingPathComponent("quality.json"))
    }
    static func timing(_ options: Benchmark.Options, m: Manifest, c: CalibrationFile, output: URL) throws {
        guard ["glowroom-luminance", "glowroom-chroma", "multiscale-luminance", "multiscale-chroma"].contains(options.adapter), options.iterations >= 5,
              options.width > 0, options.height > 0, options.width <= 16_384, options.height <= 16_384, options.width * options.height <= 32_000_000 else { throw Benchmark.failure("Invalid #175 timing matrix") }
        let control = options.adapter.hasSuffix("luminance") ? "luminance" : "chroma", baseline = options.adapter.hasPrefix("glowroom")
        let f = try Comparison.make("texture", split: .acceptance, width: options.width, height: options.height), clean = try truth(f)
        let r = try calibration(c.records, scene: "texture", control: control, value: 20)
        var ci: CIContext?, samples: [[String: Any]] = []
        for step in -1...options.iterations { try autoreleasepool {
            let start = ContinuousClock.now
            let result: Raster
            if baseline { if ci == nil { ci = context() }; result = try Evaluation.render(f.input, settings: settings(control, value: 20, scene: "texture"), context: ci!) }
            else { result = try candidate(f.input, r) }
            let elapsed = Benchmark.milliseconds(start.duration(to: .now)), rss = Benchmark.peakRSS()
            samples.append(["phase": step < 0 ? "cold" : (step == 0 ? "warmup" : "warm"), "milliseconds": elapsed, "rss": rss,
                            "reduction": try Metrics.strength(noisy: f.input, clean: clean, output: result, control: control), "outputSHA256": result.sha256])
        } }
        try Evaluation.writeJSON(["adapter": options.adapter, "width": options.width, "height": options.height, "inputSHA256": f.input.sha256, "samples": samples,
                                  "scope": "Full adapter including input conversion, ordered bands and readback, decoded raster reused; process cold, OS caches retained; RSS whole process including fixtures. Mapping from quality-size tuning is rechecked, never presumed matched."], output.appendingPathComponent("timing.json"))
    }
    static func photo(_ options: Benchmark.Options, m: Manifest, c: CalibrationFile, output: URL) throws {
        guard !options.input.isEmpty else { throw Benchmark.failure("#175 photo mode requires a local source") }
        let url = URL(fileURLWithPath: options.input), attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let request = PreviewRequest(url: url, modifiedAt: attrs[.modificationDate] as? Date ?? .distantPast,
                                     pixelSize: 4096, fileSize: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                                     allowsEmbeddedPreview: false, allowsHDR: false)
        // One actual ImageIO developed decode; never a copied embedded preview,
        // and never a sensor-linear or synthetic-ground-truth claim.
        let bitmap = try PreviewDecoder.decode(request), input = try Raster.freeze(bitmap.image), ci = context()
        var records: [[String: Any]] = []
        for control in m.controls { for value in m.values { try autoreleasepool {
            let r = try calibration(c.records, scene: "texture", control: control, value: value)
            let baseline = try Evaluation.render(input, settings: settings(control, value: value, scene: "photo"), context: ci), result = try candidate(input, r)
            let name = "\(control)-\(Int(value))"
            for (label,raster) in [("input",input),("baseline",baseline),("candidate",result)] {
                try Evaluation.png(Evaluation.downsample(raster, context: ci).previewImage(), output.appendingPathComponent("\(name)-\(label).png"))
            }
            records.append(["control":control,"value":value,"luminance":r.luminance,"chroma":r.chroma,"inputSHA256":input.sha256,"baselineSHA256":baseline.sha256,"candidateSHA256":result.sha256,
                            "pairDistance":try Metrics.scaleDistance(reference:baseline,candidate:result),"matched":false,
                            "scope":"Frozen synthetic texture calibration only; no clean photo ground truth, noise mask or equal-effect measurement. Images are SDR display thumbnails, not HDR/full-raster quality proof."])
        } } }
        try Evaluation.writeJSON(["sourceFileSHA256":Evaluation.sha(try Data(contentsOf:url)),"decodedWidth":input.width,"decodedHeight":input.height,"nativeLongEdge":bitmap.sourceLongEdge,
                                  "sampling":"ImageIO developed 4096 thumbnail, no embedded preview; decoder resampling kernel unknown", "rangeProvenance":"sdrDecoded", "records":records,"productionChanged":false],output.appendingPathComponent("photo.json"))
    }
    static func scale(_ m: Manifest, c: CalibrationFile, output: URL) throws {
        let size = m.scaling.nativeSize, f = try Comparison.make("texture", split: .acceptance, width: size[0], height: size[1]), clean = try truth(f), ci = context()
        var rows: [[String: Any]] = []
        for control in m.controls { for value in m.values { try autoreleasepool {
            let r = try calibration(c.records, scene: "texture", control: control, value: value)
            for variant in ["glowroom", "multiscale"] { try autoreleasepool {
                let full = try variant == "glowroom" ? Evaluation.render(f.input, settings: settings(control, value: value, scene: "texture"), context: ci) : candidate(f.input, r)
                for size in m.scaling.previewSizes { try autoreleasepool {
                    let small = try LightcraftDenoiseFixtures.areaAverage(f.input, width: size[0], height: size[1]), smallClean = try LightcraftDenoiseFixtures.areaAverage(clean, width: size[0], height: size[1])
                    let down = try LightcraftDenoiseFixtures.areaAverage(full, width: size[0], height: size[1])
                    let direct = try variant == "glowroom" ? Evaluation.render(small, settings: settings(control, value: value, scene: "texture"), context: ci) : candidate(small, r)
                    rows.append(["control": control, "value": value, "variant": variant, "width": size[0], "height": size[1], "distance": try Metrics.scaleDistance(reference: down, candidate: direct),
                                 "directReduction": try reductions(small, smallClean, direct, control), "nativeReduction": try reductions(small, smallClean, down, control),
                                 "directQuality": try Comparison.measure(noisy: small, clean: smallClean, output: direct, scene: "texture"), "nativeQuality": try Comparison.measure(noisy: small, clean: smallClean, output: down, scene: "texture"),
                                 "fullInputSHA256": f.input.sha256, "fullOutputSHA256": full.sha256, "inputSHA256": small.sha256,
                                 "scope": "Native 4608x3072; exact noninteger area-overlap averaging, straight RGB with premultiplied integration; fixed strides, no scale-squared assumption. Decoder sampling unknown in production, not inferred."])
                } }
            } }
        } } }
        try Evaluation.writeJSON(["records": rows], output.appendingPathComponent("scale.json"))
    }
}
#endif
