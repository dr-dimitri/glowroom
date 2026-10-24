#if GLOWROOM_EDITING_BENCHMARK
import CoreImage
import Foundation
import GlowroomCore
import ImageIO
import UniformTypeIdentifiers

/// Serial measurement orchestration; statistical CPU passes themselves use the
/// existing bounded row executor. No application catalogue or RAW decoder.
enum EIGFToneEvaluation {
    typealias C = EIGFToneComparison
    typealias LC = LightcraftToneComparison
    typealias E = AlgorithmEvaluation

    static func run(_ options: Benchmark.Options) throws {
        guard !options.output.isEmpty, !options.manifest.isEmpty,
              options.backend == "default", options.workers == 1,
              ["eigf-tune", "eigf-quality", "eigf-timing", "eigf-scale", "eigf-photo"].contains(options.evaluationMode),
              ["glowroom", "simple", "eigf"].contains(options.adapter) else {
            throw Benchmark.failure("Invalid EIGF evaluation options")
        }
        let url = URL(fileURLWithPath: options.manifest)
        let manifest = try C.Manifest.load(url), hash = E.sha(try Data(contentsOf: url))
        let output = URL(fileURLWithPath: options.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Benchmark.failure("Refusing to overwrite EIGF output") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if options.evaluationMode == "eigf-tune" { try tune(manifest, hash: hash, output: output) }
        else {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: options.calibration))
            let calibration = try JSONDecoder().decode(C.Calibration.self, from: bytes)
            try validateCalibration(calibration, manifest: manifest, hash: hash)
            switch options.evaluationMode {
            case "eigf-quality": try quality(manifest, calibration: calibration, hash: hash,
                calibrationHash: E.sha(bytes), output: output)
            case "eigf-timing": try timing(options, manifest: manifest, calibration: calibration, output: output)
            case "eigf-photo": try photo(options, manifest: manifest, calibration: calibration, output: output)
            default: try scale(options, manifest: manifest, calibration: calibration, output: output)
            }
        }
        guard E.sha(try Data(contentsOf: url)) == hash else { throw Benchmark.failure("EIGF manifest changed during run") }
    }

    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: E.space, .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: true, .name: "Glowroom EIGF V2 Float evaluation"])
    }

    static func fixture(_ scene: String, _ split: AlgorithmEvaluationFixtures.Split, _ m: C.Manifest,
                        width: Int? = nil, height: Int? = nil) throws -> AlgorithmEvaluationFixtures.Fixture {
        try C.fixture(scene, split: split, width: width ?? m.comparison.qualityWidth, height: height ?? m.comparison.qualityHeight)
    }

    static func fit(_ calibration: C.Calibration, _ basis: EIGFToneReference.Basis, _ scene: String,
                    _ direction: LC.Direction) throws -> LC.Calibration {
        guard let record = calibration.records.first(where: {
            $0.basis == basis && $0.fit.sceneClass == scene && $0.fit.directionID == direction.id
        }) else { throw Benchmark.failure("Missing EIGF calibration") }
        return record.fit
    }

    static func validateCalibration(_ c: C.Calibration, manifest m: C.Manifest, hash: String) throws {
        let count = m.sceneClasses.count * m.comparison.directions.count * 2
        guard c.manifestSHA256 == hash, c.records.count == count,
              Set(c.records.map { "\($0.basis.rawValue)/\($0.fit.sceneClass)/\($0.fit.directionID)" }).count == count else {
            throw Benchmark.failure("Invalid EIGF calibration matrix/hash")
        }
        for scene in m.sceneClasses {
            let source = try fixture(scene, .tuning, m).input.sha256
            for basis in EIGFToneReference.Basis.allCases { for direction in m.comparison.directions {
                let r = try fit(c, basis, scene, direction)
                guard r.inputSHA256 == source, [r.parameter, r.target, r.measured].allSatisfy(\.isFinite),
                      abs(r.parameter) <= 100, r.parameter == 0 || r.parameter.sign == direction.value.sign,
                      r.matched == LC.matched(r.target, r.measured, manifest: m.comparison) else {
                    throw Benchmark.failure("Invalid EIGF tuning provenance or effect matching")
                }
            } }
        }
    }

    static func tune(_ m: C.Manifest, hash: String, output: URL) throws {
        let ci = context()
        var records: [C.Calibration.Record] = []
        for scene in m.sceneClasses {
            try autoreleasepool {
                let input = try fixture(scene, .tuning, m).input
                for basis in EIGFToneReference.Basis.allCases {
                    let reference = EIGFToneReference(basis: basis), prepared = try reference.prepare(input)
                    for direction in m.comparison.directions {
                        let baseline = try E.render(input, settings: C.settings(direction), context: ci)
                        let target = LC.strength(input: input, output: baseline, direction: direction, manifest: m.comparison)
                        var parameter = 0.0, measured = 0.0, error = Double.infinity
                        let sign = direction.value < 0 ? -1.0 : 1.0
                        func search(_ low: Double, _ high: Double) throws {
                            for i in 0..<33 {
                                let value = sign * (low + (high - low) * Double(i) / 32)
                                let result = try reference.apply(prepared, settings: C.settings(direction, value: value))
                                if let valueMeasured = LC.strength(input: input, output: result, direction: direction, manifest: m.comparison),
                                   let target, abs(valueMeasured - target) < error {
                                    error = abs(valueMeasured - target); parameter = value; measured = valueMeasured
                                }
                            }
                        }
                        if let target, abs(target) >= m.comparison.matching.minimumAbsoluteTarget {
                            try search(0, 100)
                            try search(max(0, abs(parameter) - 3.125), min(100, abs(parameter) + 3.125))
                        }
                        records.append(.init(basis: basis, fit: .init(sceneClass: scene, directionID: direction.id,
                            inputSHA256: input.sha256, parameter: parameter, target: target ?? 0, measured: measured,
                            matched: LC.matched(target, measured, manifest: m.comparison))))
                    }
                }
            }
        }
        try E.writeJSON(E.object(C.Calibration(manifestSHA256: hash, records: records)), output.appendingPathComponent("calibration.json"))
    }

    static func quality(_ m: C.Manifest, calibration: C.Calibration, hash: String,
                        calibrationHash: String, output: URL) throws {
        let ci = context()
        var records: [[String: Any]] = []
        for scene in m.sceneClasses {
            try autoreleasepool {
                let f = try fixture(scene, .acceptance, m), input = f.input
                for basis in EIGFToneReference.Basis.allCases {
                    let reference = EIGFToneReference(basis: basis), prepared = try reference.prepare(input)
                    for direction in m.comparison.directions {
                        try autoreleasepool {
                            let r = try fit(calibration, basis, scene, direction)
                            let baseline = try E.render(input, settings: C.settings(direction), context: ci)
                            let candidateSettings = C.settings(direction, value: r.parameter)
                            let candidate = try reference.apply(prepared, settings: candidateSettings)
                            let same = try reference.apply(prepared, settings: C.settings(direction))
                            let target = LC.strength(input: input, output: baseline, direction: direction, manifest: m.comparison)
                            let measured = LC.strength(input: input, output: candidate, direction: direction, manifest: m.comparison)
                            let matched = r.matched && LC.matched(target, measured, manifest: m.comparison)
                            var metrics = try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: candidate).values
                            let gamut = C.targetGamutIncrease(baseline: baseline, candidate: candidate, p3: scene == "p3")
                            let clipping = C.targetGamutIncrease(baseline: baseline, candidate: candidate, p3: scene == "p3", clipping: true)
                            let newGamut = C.targetGamutIncrease(baseline: baseline, candidate: candidate, p3: scene == "p3", newOnly: true)
                            let newClipping = C.targetGamutIncrease(baseline: baseline, candidate: candidate, p3: scene == "p3", clipping: true, newOnly: true)
                            metrics["target_gamut_fraction_increase"] = gamut
                            metrics["target_clipping_fraction_increase"] = clipping
                            metrics["target_new_gamut_fraction"] = newGamut
                            metrics["target_new_clipping_fraction"] = newClipping
                            var failures: [String] = []
                            var before: [String: Double] = [:], after: [String: Double] = [:]
                            if scene == "fine-lines" || scene == "branches" {
                                before = LC.lineContrast(input: input, output: baseline, minimumContrastEV: 0.05)
                                after = LC.lineContrast(input: input, output: candidate, minimumContrastEV: 0.05)
                            }
                            if scene == "hard-edge" { before = LC.halo(input: input, output: baseline); after = LC.halo(input: input, output: candidate) }
                            if let clean = f.groundTruth {
                                let cleanBaseline = try E.render(clean, settings: C.settings(direction), context: ci)
                                let cleanCandidate = try reference.render(clean, settings: candidateSettings)
                                let baseNoise = C.noiseRMSE(baseline, clean: cleanBaseline)
                                let candidateNoise = C.noiseRMSE(candidate, clean: cleanCandidate)
                                metrics["noise_gain_ratio"] = candidateNoise / max(1e-20, baseNoise)
                            }
                            if matched {
                                if metrics["alpha_error", default: .infinity] > 0.001 { failures.append("alpha_error") }
                                if metrics["hue_deviation_degrees", default: .infinity] > 3 { failures.append("hue_deviation_degrees") }
                                if scene != "hdr" {
                                    if gamut > 0.02 { failures.append("target_gamut_fraction_increase") }
                                    if clipping > 0.02 { failures.append("target_clipping_fraction_increase") }
                                    if newGamut > 0.02 { failures.append("target_new_gamut_fraction") }
                                    if newClipping > 0.02 { failures.append("target_new_clipping_fraction") }
                                }
                                if scene == "hard-edge" {
                                    for key in ["halo_overshoot", "halo_undershoot"] where after[key, default: .infinity] > 0.02 { failures.append(key) }
                                }
                                if metrics["noise_gain_ratio", default: 1] > m.maximumNoiseGainRatio { failures.append("noise_gain_ratio") }
                            }
                            let directory = "\(scene)-\(direction.id)-\(basis.rawValue)"
                            let folder = output.appendingPathComponent(directory)
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            for (name, raster) in [("input", input), ("glowroom", baseline), ("candidate", candidate), ("same-values", same)] {
                                try E.png(raster.previewImage(), folder.appendingPathComponent("\(name).png"))
                            }
                            try E.png(E.difference(baseline, candidate).previewImage(), folder.appendingPathComponent("difference.png"))
                            for (name, background) in [("dark", Float(0)), ("light", Float(1))] {
                                try E.png(candidate.previewImage(background: background), folder.appendingPathComponent("\(name).png"))
                            }
                            records.append(["scene_class": scene, "direction": direction.id, "basis": basis.rawValue,
                                "matched": matched, "target": target as Any? ?? NSNull(), "measured": measured as Any? ?? NSNull(),
                                "parameter": r.parameter, "input_sha256": input.sha256, "output_sha256": candidate.sha256,
                                "baseline_metrics": before, "candidate_metrics": after, "comparison_metrics": metrics,
                                "critical_failures": failures, "directory": directory, "planned_peak_bytes": prepared.plannedPeakBytes,
                                "target_profile": scene == "p3" ? "Display-P3 SDR" : (scene == "hdr" ? "unbounded linear HDR" : "sRGB SDR")])
                        }
                    }
                }
            }
        }
        try E.writeJSON(["manifest_sha256": hash, "calibration_sha256": calibrationHash, "records": records], output.appendingPathComponent("quality.json"))
    }

    static func timing(_ o: Benchmark.Options, manifest m: C.Manifest, calibration: C.Calibration, output: URL) throws {
        guard o.iterations >= 5 else { throw Benchmark.failure("EIGF timing requires five warm samples") }
        let input = try fixture("fine-lines", .acceptance, m, width: o.width, height: o.height).input
        let direction = m.comparison.directions.first { $0.control == "shadows" && $0.value == 20 }!
        let basis = EIGFToneReference.Basis(rawValue: o.adapter) ?? .eigf
        let fit = try fit(calibration, basis, "fine-lines", direction)
        let reference = EIGFToneReference(basis: basis)
        var ci: CIContext?
        var prepared: EIGFToneReference.Prepared?
        var samples: [[String: Any]] = []
        for step in -1...o.iterations {
            try autoreleasepool {
                let amount = step <= 0 ? 20.0 : Double(18 + (step - 1) % 5)
                var settings = C.settings(direction, value: o.adapter == "glowroom" ? amount : fit.parameter * amount / 20)
                settings.exposure = step <= 0 ? 0 : [-0.1, 0, 0.1, 0, -0.1][(step - 1) % 5]
                let started = ContinuousClock.now
                let result: AlgorithmEvaluationRaster
                if o.adapter == "glowroom" {
                    if ci == nil { ci = context() }
                    result = try E.render(input, settings: settings, context: ci!)
                }
                else {
                    if prepared == nil { prepared = try reference.prepare(input) }
                    result = try reference.apply(prepared!, settings: settings)
                }
                let elapsed = Benchmark.milliseconds(started.duration(to: .now))
                samples.append(["phase": step == -1 ? "process-cold" : (step == 0 ? "warmup" : "warm"),
                    "total_ms": elapsed, "effect_strength": LC.strength(input: input, output: result, direction: direction, manifest: m.comparison) as Any? ?? NSNull(),
                    "output_sha256": result.sha256])
            }
        }
        try E.writeJSON(["adapter": o.adapter, "width": o.width, "height": o.height, "samples": samples,
            "input_sha256": input.sha256, "peak_rss_bytes": Benchmark.peakRSS(),
            "boundary": "Developed Float source through scalar CPU base/gain or V2 CI graph, conversions and Float readback; no RAW decode/UI",
            "cold_scope": "New process; OS/driver/shader caches not cleared"], output.appendingPathComponent("timing.json"))
    }

    static func scale(_ o: Benchmark.Options, manifest m: C.Manifest, calibration: C.Calibration, output: URL) throws {
        let input = try fixture("fine-lines", .acceptance, m, width: o.width, height: o.height).input
        let ci = context(), small = try E.downsample(input, context: ci)
        var records: [[String: Any]] = []
        for basis in EIGFToneReference.Basis.allCases {
            let native = max(input.width, input.height)
            let full = EIGFToneReference(basis: basis, nativeLong: native)
            let preview = EIGFToneReference(basis: basis, nativeLong: native, outputLong: Double(max(small.width, small.height)))
            for direction in m.comparison.directions where direction.primary {
                let r = try fit(calibration, basis, "fine-lines", direction), settings = C.settings(direction, value: r.parameter)
                let resized = try E.downsample(full.render(input, settings: settings), context: ci)
                let direct = try preview.render(small, settings: settings)
                records.append(["basis": basis.rawValue, "direction": direction.id,
                    "metrics": try AlgorithmEvaluationMetrics.measure(reference: resized, candidate: direct).values])
            }
        }
        try E.writeJSON(["records": records, "scope": "Geometry/resampling diagnostic; not equality or export approval"], output.appendingPathComponent("scale.json"))
    }

    /// Optional explicitly named developed raster; native camera RAW decoding
    /// remains the caller's documented step. This mode never qualifies a photo
    /// as an acceptance scene or generalizes a synthetic per-scene slider fit.
    static func photo(_ o: Benchmark.Options, manifest m: C.Manifest, calibration: C.Calibration, output: URL) throws {
        let url = URL(fileURLWithPath: o.input)
        guard !o.input.isEmpty, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].contains(type as String) else {
            throw Benchmark.failure("EIGF photo mode accepts explicitly named developed PNG/JPEG/TIFF, never camera RAW")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EditRenderError.oversizedPreview }
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let input = try AlgorithmEvaluationRaster.freeze(image, orientation: orientation), ci = context()
        try E.png(input.previewImage(), output.appendingPathComponent("input.png"))
        var records: [[String: Any]] = []
        for basis in EIGFToneReference.Basis.allCases {
            let reference = EIGFToneReference(basis: basis), prepared = try reference.prepare(input)
            for direction in m.comparison.directions where direction.primary {
                let fit = try fit(calibration, basis, "fine-lines", direction)
                let baseline = try E.render(input, settings: C.settings(direction), context: ci)
                let candidate = try reference.apply(prepared, settings: C.settings(direction, value: fit.parameter))
                let name = "\(basis.rawValue)-\(direction.id)"
                try E.png(baseline.previewImage(), output.appendingPathComponent("\(name)-glowroom.png"))
                try E.png(candidate.previewImage(), output.appendingPathComponent("\(name)-candidate.png"))
                records.append(["basis": basis.rawValue, "direction": direction.id, "parameter": fit.parameter,
                    "calibration_scene": "fine-lines tuning; not a photographic mapping", "output_sha256": candidate.sha256,
                    "baseline_delta_y_diagnostic": LC.strength(input: input, output: baseline, direction: direction, manifest: m.comparison) as Any? ?? NSNull(),
                    "candidate_delta_y_diagnostic": LC.strength(input: input, output: candidate, direction: direction, manifest: m.comparison) as Any? ?? NSNull(),
                    "comparison_metrics_diagnostic": try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: candidate).values])
            }
        }
        try E.writeJSON(["input_file_sha256": E.sha(try Data(contentsOf: url)), "input_sha256": input.sha256,
            "width": input.width, "height": input.height, "source_bits_per_component": image.bitsPerComponent,
            "source_color_space": image.colorSpace?.name as String? ?? "unspecified", "source_orientation": orientation,
            "records": records, "acceptance": false,
            "scope": "Optional unqualified developed photo diagnostics; no registered ROI/ground truth, range provenance or visual sign-off; original file unchanged"],
            output.appendingPathComponent("photo.json"))
    }
}
#endif
