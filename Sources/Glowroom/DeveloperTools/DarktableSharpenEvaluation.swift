#if GLOWROOM_EDITING_BENCHMARK
import CoreImage
import Foundation
import GlowroomCore
import ImageIO
import UniformTypeIdentifiers

enum DarktableSharpenEvaluation {
    typealias E = AlgorithmEvaluation
    typealias R = DarktableSharpenReference
    typealias F = DarktableSharpenFixtures
    struct Case: Codable, Equatable {
        let id: String
        let amount: Double
        let radius: Double
        let detail: Double
        let masking: Double
        var settings: EditSettings {
            var s = EditSettings.neutral
            s.toneProcessingVersion = .consistentV2; s.sharpeningAmount = amount
            s.sharpeningRadius = radius; s.sharpeningDetail = detail; s.sharpeningMasking = masking
            return s
        }
    }
    struct Manifest: Decodable {
        let protocolID: String
        let qualityWidth: Int
        let qualityHeight: Int
        let scenes: [String]
        let cases: [Case]
    }
    struct Calibration: Codable {
        let variant: R.Variant
        let caseID: String
        let parameter: Double
        let target: Double
        let measured: Double
        let inputSHA256: String
    }
    struct CalibrationFile: Codable {
        let manifestSHA256: String
        let records: [Calibration]
    }
    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: E.space, .workingFormat: CIFormat.RGBAf,
                            .cacheIntermediates: true, .name: "DT174 isolated actual USM"])
    }
    static func baseline(_ input: R.Raster, c: Case, context: CIContext, scale: Double = 1) throws -> R.Raster {
        let source = try CIImage(cgImage: input.cgImage())
        let graph = try DevelopSharpening.apply(to: source, settings: c.settings, extent: source.extent, sourcePixelScale: scale)
        guard let image = context.createCGImage(graph, from: graph.extent, format: .RGBAf, colorSpace: E.space, deferred: false) else { throw EditRenderError.unavailable }
        return try R.Raster.freeze(image)
    }
    static func prepared(_ input: R.Raster, c: Case, variant: R.Variant, scale: Double = 1) throws -> R.Prepared {
        try R.prepare(input, variant: variant, radius: c.radius, detail: c.detail, masking: c.masking, scale: scale)
    }
    static func run(_ options: Benchmark.Options) throws {
        guard !options.output.isEmpty, !options.manifest.isEmpty, options.backend == "default", options.workers == 1,
              options.width * options.height <= 32_000_000,
              ["sharpen-tune", "sharpen-quality", "sharpen-timing", "sharpen-scale", "sharpen-photo"].contains(options.evaluationMode),
              ["glowroom", "multiscale", "diffusion"].contains(options.adapter) else { throw Benchmark.failure("Invalid DT174 options") }
        let manifestBytes = try Data(contentsOf: URL(fileURLWithPath: options.manifest))
        let m = try JSONDecoder().decode(Manifest.self, from: manifestBytes), hash = E.sha(manifestBytes)
        guard m.protocolID == "DT174-sharpen-v1", m.qualityWidth == 256, m.qualityHeight == 160, m.scenes == F.scenes,
              m.cases == [Case(id: "fine-50", amount: 50, radius: 1, detail: 25, masking: 0),
                          Case(id: "fine-100", amount: 100, radius: 1, detail: 25, masking: 0),
                          Case(id: "wide-100", amount: 100, radius: 2, detail: 25, masking: 0),
                          Case(id: "masked-100", amount: 100, radius: 2, detail: 25, masking: 40)],
              m.cases.allSatisfy({ $0.amount.isFinite && (0...150).contains($0.amount) && $0.radius.isFinite && (0.5...3).contains($0.radius) && $0.detail.isFinite && (0...100).contains($0.detail) && $0.masking.isFinite && (0...100).contains($0.masking) }) else { throw Benchmark.failure("Invalid frozen DT174 protocol") }
        let out = URL(fileURLWithPath: options.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: out.path) else { throw Benchmark.failure("Refusing to overwrite DT174 output") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if options.evaluationMode == "sharpen-tune" { try tune(m, hash: hash, out: out) }
        else {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: options.calibration))
            let calibration = try JSONDecoder().decode(CalibrationFile.self, from: bytes)
            let input = try F.make(scene: "slanted-edge", acceptance: false).input
            guard calibration.manifestSHA256 == hash, calibration.records.count == 8,
                  Set(calibration.records.map { "\($0.variant.rawValue):\($0.caseID)" }).count == 8,
                  calibration.records.allSatisfy({ row in row.inputSHA256 == input.sha256 && row.parameter.isFinite && (0...6).contains(row.parameter)
                      && row.target.isFinite && row.target > 0 && row.measured.isFinite && row.measured >= 0
                      && m.cases.contains(where: { c in c.id == row.caseID }) }) else { throw Benchmark.failure("Invalid DT174 calibration provenance") }
            switch options.evaluationMode {
            case "sharpen-quality": try quality(m, calibration: calibration, hash: hash, calibrationHash: E.sha(bytes), out: out)
            case "sharpen-scale": try scale(options, m: m, calibration: calibration, out: out)
            case "sharpen-photo": try photo(options, m: m, calibration: calibration, out: out)
            default: try timing(options, m: m, calibration: calibration, out: out)
            }
        }
        guard E.sha(try Data(contentsOf: URL(fileURLWithPath: options.manifest))) == hash else { throw Benchmark.failure("DT174 manifest changed during evaluation") }
    }
    static func fit(_ calibration: CalibrationFile, c: Case, variant: R.Variant) throws -> Calibration {
        guard let row = calibration.records.first(where: { $0.caseID == c.id && $0.variant == variant }) else { throw Benchmark.failure("Missing DT174 calibration") }
        return row
    }
    static func tune(_ m: Manifest, hash: String, out: URL) throws {
        let ci = context(), fixture = try F.make(scene: "slanted-edge", acceptance: false)
        var rows: [Calibration] = []
        for c in m.cases {
            let target = try DarktableSharpenMetrics.measure(baseline(fixture.input, c: c, context: ci), fixture: fixture)["edge_slope"]!
            for variant in R.Variant.allCases {
                let p = try prepared(fixture.input, c: c, variant: variant)
                var amount = 0.0, measured = 0.0, error = Double.infinity
                func search(_ low: Double, _ high: Double, _ steps: Int) throws {
                    for i in 0..<steps {
                        let trial = low + (high - low) * Double(i) / Double(steps - 1)
                        let achieved = try DarktableSharpenMetrics.measure(R.apply(p, amount: trial), fixture: fixture)["edge_slope"]!
                        if abs(achieved - target) < error { amount = trial; measured = achieved; error = abs(achieved - target) }
                    }
                }
                try search(0, 6, 49); try search(max(0, amount - 0.125), min(6, amount + 0.125), 25)
                rows.append(Calibration(variant: variant, caseID: c.id, parameter: amount, target: target, measured: measured, inputSHA256: fixture.input.sha256))
            }
        }
        try E.writeJSON(E.object(CalibrationFile(manifestSHA256: hash, records: rows)), out.appendingPathComponent("calibration.json"))
    }
    static func quality(_ m: Manifest, calibration: CalibrationFile, hash: String, calibrationHash: String, out: URL) throws {
        let ci = context()
        var rows: [[String: Any]] = []
        for scene in m.scenes {
            try autoreleasepool {
                let fixture = try F.make(scene: scene, acceptance: true)
                let unchanged = try DarktableSharpenMetrics.measure(fixture.input, fixture: fixture)
                for c in m.cases {
                    let usm = try baseline(fixture.input, c: c, context: ci)
                    let before = try DarktableSharpenMetrics.measure(usm, fixture: fixture)
                    for variant in R.Variant.allCases {
                        let fit = try fit(calibration, c: c, variant: variant), p = try prepared(fixture.input, c: c, variant: variant)
                        let result = try R.apply(p, amount: fit.parameter), zero = try R.apply(p, amount: 0)
                        let after = try DarktableSharpenMetrics.measure(result, fixture: fixture)
                        let name = "\(scene)-\(c.id)-\(variant.rawValue)", directory = out.appendingPathComponent(name)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        for (name, raster) in [("input", fixture.input), ("truth", fixture.truth), ("glowroom", usm), ("candidate", result),
                                               ("same-values", try R.apply(p, amount: c.amount / 100))] {
                            try E.png(raster.previewImage(), directory.appendingPathComponent("\(name).png"))
                        }
                        try E.png(E.difference(usm, result).previewImage(), directory.appendingPathComponent("difference.png"))
                        try E.png(result.previewImage(background: 0), directory.appendingPathComponent("dark.png"))
                        try E.png(result.previewImage(background: 1), directory.appendingPathComponent("light.png"))
                        rows.append(["scene": scene, "case": c.id, "variant": variant.rawValue, "parameter": fit.parameter,
                                     "tuning_target": fit.target, "tuning_measured": fit.measured,
                                     "input_sha256": fixture.input.sha256, "truth_sha256": fixture.truth.sha256,
                                     "output_sha256": result.sha256, "zero_identity": zero.sha256 == fixture.input.sha256,
                                     "baseline_metrics": before, "candidate_metrics": after, "unchanged_metrics": unchanged,
                                     "finite": result.pixels.allSatisfy(\.isFinite), "directory": name])
                    }
                }
            }
        }
        try E.writeJSON(["protocol": m.protocolID, "manifest_sha256": hash, "calibration_sha256": calibrationHash,
                         "baseline": "actual DevelopSharpening.apply consistentV2 in RGBAf; no approximated CPU USM",
                         "candidate_backend": "bounded independent CPU reference; accelerated integration not implemented",
                         "records": rows, "production_changed": false], out.appendingPathComponent("quality.json"))
    }
    static func timing(_ options: Benchmark.Options, m: Manifest, calibration: CalibrationFile, out: URL) throws {
        guard options.iterations >= 5 else { throw Benchmark.failure("DT174 timing needs >=5 warm samples") }
        let fixture = try F.make(scene: "slanted-edge", acceptance: true, width: options.width, height: options.height)
        guard let c = m.cases.first(where: { $0.id == "wide-100" }) else { throw Benchmark.failure("Missing wide-100 case") }
        let variant = R.Variant(rawValue: options.adapter), fit = try variant.map { try fit(calibration, c: c, variant: $0) }
        var ci: CIContext?, samples: [[String: Any]] = []
        for step in -1...options.iterations {
            try autoreleasepool {
                let started = ContinuousClock.now
                let output: R.Raster
                if let variant, let fit { output = try R.apply(prepared(fixture.input, c: c, variant: variant), amount: fit.parameter) }
                else { if ci == nil { ci = context() }; output = try baseline(fixture.input, c: c, context: ci!) }
                let elapsed = Benchmark.milliseconds(started.duration(to: .now))
                samples.append(["phase": step == -1 ? "process-cold" : step == 0 ? "warmup" : "warm", "ms": elapsed,
                                "output_sha256": output.sha256, "peak_rss_bytes": Benchmark.peakRSS(),
                                "edge_slope": DarktableSharpenMetrics.edgeSlope(output, acceptance: true)])
            }
        }
        try E.writeJSON(["adapter": options.adapter, "width": options.width, "height": options.height,
                         "input_sha256": fixture.input.sha256, "samples": samples, "peak_rss_bytes": Benchmark.peakRSS(),
                         "scope": "isolated stage, preparation + conversions + materialization; fixture generation and PNG/hash excluded; no RAW decode/UI/production end-to-end evidence; process cold != cold system caches",
                         "backend": options.adapter == "glowroom" ? "Core Image automatic, physical backend unverified" : "CPU"], out.appendingPathComponent("timing.json"))
    }
    static func scale(_ options: Benchmark.Options, m: Manifest, calibration: CalibrationFile, out: URL) throws {
        guard options.width >= 2400, options.height >= 1600 else { throw Benchmark.failure("DT174 scale requires native region >=2400x1600") }
        let fixture = try F.make(scene: "fine-texture", acceptance: true, width: options.width, height: options.height)
        guard let c = m.cases.first(where: { $0.id == "wide-100" }) else { throw Benchmark.failure("Missing wide-100 case") }
        let ci = context()
        var rows: [[String: Any]] = []
        for adapter in ["glowroom", "multiscale", "diffusion"] {
            try autoreleasepool {
                let variant = R.Variant(rawValue: adapter), amount = try variant.map { try fit(calibration, c: c, variant: $0).parameter }
                let full = try variant.map { try R.apply(prepared(fixture.input, c: c, variant: $0), amount: amount!) }
                    ?? baseline(fixture.input, c: c, context: ci)
                for size in [(512, 341), (2400, 1600)] {
                    let small = try area(fixture.input, width: size.0, height: size.1)
                    let down = try area(full, width: size.0, height: size.1)
                    let scale = min(Double(size.0) / Double(options.width), Double(size.1) / Double(options.height))
                    let direct = try variant.map { try R.apply(prepared(small, c: c, variant: $0, scale: scale), amount: amount!) }
                        ?? baseline(small, c: c, context: ci, scale: scale)
                    let metrics = try AlgorithmEvaluationMetrics.measure(reference: down, candidate: direct, groundTruth: nil).values
                    var squaredError = 0.0
                    for p in stride(from: 0, to: down.pixels.count, by: 4) {
                        for channel in 0..<3 {
                            let delta = Double(down.pixels[p + channel] * down.pixels[p + 3] - direct.pixels[p + channel] * direct.pixels[p + 3])
                            squaredError += delta * delta
                        }
                    }
                    let scaleRMSE = sqrt(squaredError / Double(down.width * down.height * 3))
                    let name = "\(adapter)-\(size.0)"
                    try E.png(down.previewImage(), out.appendingPathComponent("\(name)-native.png"))
                    try E.png(direct.previewImage(), out.appendingPathComponent("\(name)-preview.png"))
                    rows.append(["adapter": adapter, "native_size": [options.width, options.height], "preview_size": [size.0, size.1],
                                 "source_pixel_scale": scale, "metrics": metrics, "scale_rgb_rmse": scaleRMSE,
                                 "native_input_sha256": fixture.input.sha256,
                                 "preview_input_sha256": small.sha256])
                }
            }
        }
        try E.writeJSON(["records": rows, "sampling": "exact fractional-area premultiplied RGBA averaging", "scope": "native synthetic full-resolution versus direct preview; not a 200% loupe claim"], out.appendingPathComponent("scale.json"))
    }
    static func photo(_ options: Benchmark.Options, m: Manifest, calibration: CalibrationFile, out: URL) throws {
        guard !options.input.isEmpty else { throw Benchmark.failure("sharpen-photo requires explicit developed PNG/TIFF/JPEG --input; no RAW decode") }
        let url = URL(fileURLWithPath: options.input)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].contains(type as String) else {
            throw Benchmark.failure("Only explicitly supplied developed PNG/TIFF/JPEG photo rasters are supported")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Benchmark.failure("Photo raster exceeds 32MP/8192 axis bounds or cannot decode") }
        let input = try R.Raster.freeze(image, orientation: (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1)
        let ci = context()
        var records: [[String: Any]] = []
        try E.png(input.previewImage(), out.appendingPathComponent("input.png"))
        for c in m.cases {
            let usm = try baseline(input, c: c, context: ci)
            try E.png(usm.previewImage(), out.appendingPathComponent("\(c.id)-glowroom.png"))
            for variant in R.Variant.allCases {
                let parameter = try fit(calibration, c: c, variant: variant).parameter
                let result = try R.apply(prepared(input, c: c, variant: variant), amount: parameter)
                let name = "\(c.id)-\(variant.rawValue)"
                try E.png(result.previewImage(), out.appendingPathComponent("\(name).png"))
                try E.png(E.difference(usm, result).previewImage(), out.appendingPathComponent("\(name)-difference.png"))
                records.append(["case": c.id, "variant": variant.rawValue, "parameter": parameter, "output_sha256": result.sha256,
                                "comparison_diagnostics": try AlgorithmEvaluationMetrics.measure(reference: usm, candidate: result, groundTruth: nil).values])
            }
        }
        try E.writeJSON(["source_sha256": E.sha(try Data(contentsOf: url)), "input_sha256": input.sha256,
                         "source_size": [width, height], "oriented_size": [input.width, input.height],
                         "profile": image.colorSpace?.name as String? ?? "unknown", "records": records,
                         "status": "private diagnostic-only; no ground truth, qualified scene ROI, equal-effect or independent visual acceptance"], out.appendingPathComponent("photo.json"))
    }
    static func area(_ input: R.Raster, width: Int, height: Int) throws -> R.Raster {
        guard width > 0, height > 0, width <= input.width, height <= input.height else { throw R.Failure.invalid }
        // Exact overlaps, unlike a center-tap box approximation. Independent
        // destination rows use the existing bounded pool, channels stay ordered.
        let sx = Double(input.width) / Double(width), sy = Double(input.height) / Double(height)
        let pixels = try LightcraftToneFilters.rows(width: width * 4, height: height) { y, row in
            let ya = Double(y) * sy, yb = Double(y + 1) * sy
            for x in 0..<width {
                let xa = Double(x) * sx, xb = Double(x + 1) * sx
                var sum = [Double](repeating: 0, count: 4)
                for yy in Int(ya)..<min(input.height, Int(ceil(yb))) {
                    let wy = min(yb, Double(yy + 1)) - max(ya, Double(yy))
                    for xx in Int(xa)..<min(input.width, Int(ceil(xb))) {
                        let weight = wy * (min(xb, Double(xx + 1)) - max(xa, Double(xx))), p = (yy * input.width + xx) * 4
                        let a = Double(input.pixels[p + 3])
                        for c in 0..<3 { sum[c] += Double(input.pixels[p + c]) * a * weight }
                        sum[3] += a * weight
                    }
                }
                for c in 0..<3 { row[x * 4 + c] = sum[3] > 1e-12 ? Float(sum[c] / sum[3]) : 0 }
                row[x * 4 + 3] = Float(min(1, max(0, sum[3] / (sx * sy))))
            }
        }
        return try R.Raster(width: width, height: height, pixels: pixels)
    }
}
#endif
