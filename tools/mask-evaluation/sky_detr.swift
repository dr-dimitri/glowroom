// Native comparison harness for Glowroom's CURRENT approved sky model.
// Build with sky_detr_build.sh; actual production refiner and converter are linked.
// Benchmark inference is deliberately serial: Core ML schedules parallel device
// work, and concurrent models would contaminate latency and peak-memory results.
import CoreGraphics
import CoreML
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import GlowroomCore
import ImageIO
import UniformTypeIdentifiers

enum HarnessFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HarnessFailure.message(message) }
}
private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func peakRSS() -> Int64 {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss) // Darwin reports bytes, not Linux kilobytes.
}
private func json(_ value: Any, to url: URL? = nil) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    if let url { try data.write(to: url, options: .atomic) }
    else { print(String(decoding: data, as: UTF8.self)); fflush(stdout) }
}
private func url(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL }
private func freshDirectory(_ path: URL) throws {
    try require(!FileManager.default.fileExists(atPath: path.path), "Output already exists: \(path.path)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
}
private func verifyPackage(_ package: URL) throws -> [String: Any] {
    let start = now()
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
    let rootValues = try package.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    try require(rootValues.isSymbolicLink != true && rootValues.isDirectory == true, "Expected real model package directory")
    guard let enumerator = fm.enumerator(atPath: package.path) else {
        throw HarnessFailure.message("Cannot enumerate package")
    }
    var actual = Set<String>()
    for case let relative as String in enumerator {
        let file = package.appendingPathComponent(relative)
        let values = try file.resourceValues(forKeys: keys)
        try require(values.isSymbolicLink != true, "Symlink in model package: \(file.path)")
        if values.isRegularFile == true { actual.insert(relative) }
    }
    try require(actual == Set(HarnessSource.files.map(\.path)), "Model package contains missing or unexpected files")
    for pin in HarnessSource.files {
        let file = package.appendingPathComponent(pin.path)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256(), bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            digest.update(data: chunk); bytes += Int64(chunk.count)
        }
        let sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        try require(bytes == pin.bytes && sha256 == pin.sha256, "Approved pin mismatch: \(pin.path)")
    }
    return ["verified": true, "revision": HarnessSource.revision,
            "packageBytes": HarnessSource.files.reduce(Int64(0)) { $0 + $1.bytes },
            "verificationSeconds": now() - start, "productionSourceSHA256": HarnessSource.sourceSHA256]
}
private func configuration(_ name: String) throws -> MLModelConfiguration {
    try require(["all", "cpu"].contains(name), "Compute units must be all or cpu")
    let config = MLModelConfiguration()
    config.computeUnits = name == "all" ? .all : .cpuOnly
    return config
}
private func checkInterface(_ model: MLModel) throws -> Int {
    guard let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
          input.pixelsWide == 448, input.pixelsHigh == 448,
          model.modelDescription.outputDescriptionsByName["semanticPredictions"]?.multiArrayConstraint?.dataType == .int32
    else { throw HarnessFailure.message("DETR interface mismatch") }
    return try AutomaticMaskRasterConverter.skyClass(in: model)
}
private func image(_ path: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(path as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
          let result = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { throw HarnessFailure.message("Cannot decode oriented PNG: \(path.path)") }
    return result
}
private func preflight(_ inputs: URL) throws -> [URL] {
    let files = (1...7).map { inputs.appendingPathComponent("test_picture\($0).png") }
    for file in files {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= LocalMaskRaster.maximumDimension,
              height <= LocalMaskRaster.maximumDimension,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        else { throw HarnessFailure.message("Missing or invalid prepared PNG: \(file.path)") }
    }
    return files
}
private func writePNG(_ raster: LocalMaskRaster, _ file: URL) throws {
    guard let provider = CGDataProvider(data: raster.bytes as CFData),
          let mask = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 8,
              bytesPerRow: raster.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
              decode: nil, shouldInterpolate: true, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw HarnessFailure.message("Cannot create Gray8 PNG") }
    CGImageDestinationAddImage(destination, mask, nil)
    try require(CGImageDestinationFinalize(destination), "Cannot write \(file.path)")
}
private func readMask(_ file: URL) throws -> LocalMaskRaster {
    let mask = try image(file)
    try require(mask.bitsPerComponent == 8 && mask.bitsPerPixel == 8 && mask.colorSpace?.numberOfComponents == 1,
                "Mask must be tightly interpreted Gray8, no RGB/color conversion")
    guard let data = mask.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
        throw HarnessFailure.message("Cannot read mask bytes")
    }
    var packed = Data(capacity: mask.width * mask.height)
    for y in 0..<mask.height { packed.append(pointer.advanced(by: y * mask.bytesPerRow), count: mask.width) }
    return try LocalMaskRaster(width: mask.width, height: mask.height, bytes: packed)
}
private func stats(_ mask: LocalMaskRaster) -> [String: Any] {
    let sum = mask.bytes.reduce(Int64(0)) { $0 + Int64($1) }
    return ["minimum": mask.bytes.min() ?? 0, "maximum": mask.bytes.max() ?? 0,
            "coverage": Double(sum) / Double(mask.bytes.count * 255),
            "pixelsAbove127": mask.bytes.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }]
}

@main struct SkyDETRHarness {
    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) }
        catch { fputs("sky-detr: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    private static func run(_ args: [String]) throws {
        guard let command = args.first else { throw HarnessFailure.message(usage) }
        switch command {
        case "selftest":
            try require(args.count == 1, usage); try selftest()
        case "verify":
            try require(args.count == 2, usage); try json(verifyPackage(url(args[1])))
        case "compile":
            try require(args.count == 3, usage)
            var report = try verifyPackage(url(args[1]))
            let destination = url(args[2])
            try require(!FileManager.default.fileExists(atPath: destination.path), "Compiled output already exists")
            let start = now(), compiled = try MLModel.compileModel(at: url(args[1]))
            defer { try? FileManager.default.removeItem(at: compiled) }
            try FileManager.default.copyItem(at: compiled, to: destination)
            report["compileSeconds"] = now() - start
            report["compiledPath"] = destination.path
            try json(report, to: destination.appendingPathExtension("provenance.json")); try json(report)
        case "info":
            try require(args.count == 3, usage)
            let start = now(), model = try MLModel(contentsOf: url(args[1]), configuration: configuration(args[2]))
            let load = now() - start, skyClass = try checkInterface(model)
            try json(["input": model.modelDescription.inputDescriptionsByName.mapValues { $0.description },
                      "output": model.modelDescription.outputDescriptionsByName.mapValues { $0.description },
                      "skyClass": skyClass, "loadSeconds": load, "computeUnits": args[2],
                      "processPeakResidentBytes": peakRSS(), "productionSourceSHA256": HarnessSource.sourceSHA256])
        case "run":
            try require((5...7).contains(args.count), usage)
            let passes = args.count > 5 ? Int(args[5]) ?? 0 : 2
            let mode = args.count > 6 ? args[6] : "resident"
            try require((1...10).contains(passes) && ["resident", "oneshot"].contains(mode), usage)
            try benchmark(modelURL: url(args[1]), inputs: url(args[2]), output: url(args[3]), compute: args[4], passes: passes, mode: mode)
        case "refine":
            try require((4...5).contains(args.count), usage)
            let software = args.count == 5
            if software { try require(args[4] == "software", usage) }
            try require(!FileManager.default.fileExists(atPath: url(args[3]).path), "Refined output already exists")
            let decodeStart = now(), guide = try image(url(args[1])), mask = try readMask(url(args[2]))
            let expected = AutomaticMaskRasterConverter.outputSize(width: guide.width, height: guide.height)
            try require(mask.width == expected.width && mask.height == expected.height, "Mask/guide canvas mismatch")
            let refineStart = now(), refined = try AutomaticMaskRefiner.refine(mask, guide: guide, softwareRenderer: software)
            let encodeStart = now(); try writePNG(refined, url(args[3]))
            try json(["decodeSeconds": refineStart - decodeStart, "refineSeconds": encodeStart - refineStart,
                      "encodeSeconds": now() - encodeStart, "softwareRenderer": software,
                      "processPeakResidentBytes": peakRSS(), "productionSourceSHA256": HarnessSource.sourceSHA256])
        case "refine-batch":
            try require((5...6).contains(args.count), usage)
            let passes = args.count > 5 ? Int(args[5]) ?? 0 : 2
            try require((1...10).contains(passes), usage)
            try refineBatch(inputs: url(args[1]), masks: url(args[2]), output: url(args[3]), pattern: args[4], passes: passes)
        default: throw HarnessFailure.message(usage)
        }
    }
    private static func refineBatch(inputs: URL, masks: URL, output: URL, pattern: String, passes: Int) throws {
        let files = try preflight(inputs)
        // Validate the whole inventory before opening the fresh result directory.
        try require(!pattern.contains("/") && pattern.contains("{id}") && pattern.contains("{pass}"),
                    "Mask pattern must be a basename containing {id} and {pass}")
        func maskURL(_ id: String, _ pass: Int) -> URL {
            masks.appendingPathComponent(pattern.replacingOccurrences(of: "{id}", with: id)
                .replacingOccurrences(of: "{pass}", with: String(pass)))
        }
        for pass in 1...passes { for file in files {
            let mask = maskURL(file.deletingPathExtension().lastPathComponent, pass)
            try require(FileManager.default.fileExists(atPath: mask.path), "Missing input mask: \(mask.path)")
        }}
        try freshDirectory(output)
        var records = [[String: Any]]()
        func save(_ status: String, error: String? = nil) throws {
            var report: [String: Any] = ["mode": "refine-batch", "passes": passes, "pattern": pattern, "records": records,
                "status": status, "expectedRecords": files.count * passes, "completedRecords": records.count,
                "processPeakResidentBytes": peakRSS(), "productionSourceSHA256": HarnessSource.sourceSHA256,
                "scope": "Independent Core Image process with production AutomaticMaskRefiner and resident CIContext; prepared PNG image and Gray8 mask decode, guided filter and PNG encoding measured separately. Inference, logits restore and interprocess I/O belong to the upstream model measurement; no cache purge. Empty masks are retained for evaluation."]
            if let error { report["error"] = error }
            try json(report, to: output.appendingPathComponent("results.json"))
        }
        try save("running")
        do {
        for pass in 1...passes { for file in files {
            try autoreleasepool {
                let start = now(), id = file.deletingPathExtension().lastPathComponent
                let guide = try image(file), raw = try readMask(maskURL(id, pass))
                let size = AutomaticMaskRasterConverter.outputSize(width: guide.width, height: guide.height)
                try require(raw.width == size.width && raw.height == size.height, "Mask/guide canvas mismatch: \(id)")
                let refineStart = now(), refined = try AutomaticMaskRefiner.refine(raw, guide: guide)
                let encodeStart = now()
                try writePNG(refined, output.appendingPathComponent("\(id)-pass\(pass)-refined.png"))
                let finish = now()
                let record: [String: Any] = ["id": id, "pass": pass, "width": size.width, "height": size.height,
                    "decodeSeconds": refineStart - start, "refineSeconds": encodeStart - refineStart,
                    "encodeSeconds": finish - encodeStart, "totalSeconds": finish - start,
                    "raw": stats(raw), "refined": stats(refined), "processPeakResidentBytes": peakRSS()]
                records.append(record); try json(record)
                try save("running")
            }
        }}
        try save("complete")
        } catch {
            try? save("failed", error: error.localizedDescription)
            throw error
        }
    }
    private static func benchmark(modelURL: URL, inputs: URL, output: URL, compute: String, passes: Int, mode: String) throws {
        let config = try configuration(compute), files = try preflight(inputs)
        try freshDirectory(output)
        var records = [[String: Any]](), initialLoad = 0.0
        try json(report(records, initialLoad: initialLoad, compute: compute, mode: mode, passes: passes),
                 to: output.appendingPathComponent("results.json"))
        do {
        let loadStart = now()
        let resident: MLModel? = mode == "resident" ? try MLModel(contentsOf: modelURL, configuration: config) : nil
        initialLoad = now() - loadStart
        if let resident { _ = try checkInterface(resident) }
        for pass in 1...passes {
            for file in files {
                try autoreleasepool {
                    let start = now()
                    let guide = try image(file)
                    let preStart = now(), buffer = try NativeDETRInput.squarePixelBuffer(guide, side: 448)
                    let features = try MLDictionaryFeatureProvider(dictionary: ["image": buffer])
                    let size = AutomaticMaskRasterConverter.outputSize(width: guide.width, height: guide.height)
                    let modelStart = now()
                    // Production releases the one-shot model/prediction BEFORE
                    // refinement. Resident mode intentionally retains only its
                    // shared model outside this nested native autorelease pool.
                    let inference: (raw: LocalMaskRaster, inferStart: Double, restoreStart: Double) = try autoreleasepool {
                        let model = try resident ?? MLModel(contentsOf: modelURL, configuration: config)
                        let skyClass = try checkInterface(model)
                        let inferStart = now(), prediction = try model.prediction(from: features)
                        let restoreStart = now()
                        guard let labels = prediction.featureValue(for: "semanticPredictions")?.multiArrayValue else {
                            throw HarnessFailure.message("Missing semanticPredictions")
                        }
                        let raw = try AutomaticMaskRasterConverter.skyRaster(labels, skyClass: skyClass, outputSize: size)
                        return (raw, inferStart, restoreStart)
                    }
                    let refineStart = now(), raw = inference.raw
                    // Unlike app noSky, keep empty masks for fair negative-image evaluation.
                    let refined = try AutomaticMaskRefiner.refine(raw, guide: guide)
                    let encodeStart = now(), id = file.deletingPathExtension().lastPathComponent
                    let stem = "\(id)-pass\(pass)"
                    try writePNG(raw, output.appendingPathComponent(stem + "-raw.png"))
                    try writePNG(refined, output.appendingPathComponent(stem + "-refined.png"))
                    let finish = now()
                    let record: [String: Any] = ["id": id, "pass": pass, "width": size.width, "height": size.height,
                        "decodeSeconds": preStart - start, "preprocessSeconds": modelStart - preStart,
                        "modelLoadSeconds": mode == "oneshot" ? inference.inferStart - modelStart : 0,
                        "inferenceSeconds": inference.restoreStart - inference.inferStart,
                        "restoreSeconds": refineStart - inference.restoreStart,
                        "refineSeconds": encodeStart - refineStart, "encodeSeconds": finish - encodeStart,
                        "requestSeconds": encodeStart - start, "totalSeconds": finish - start,
                        "raw": stats(raw), "refined": stats(refined), "appWouldReportNoSky": !raw.bytes.contains { $0 != 0 },
                        "processPeakResidentBytes": peakRSS()]
                    records.append(record); try json(record)
                    try json(report(records, initialLoad: initialLoad, compute: compute, mode: mode, passes: passes),
                             to: output.appendingPathComponent("results.json"))
                }
            }
        }
        try json(report(records, initialLoad: initialLoad, compute: compute, mode: mode, passes: passes, status: "complete"),
                 to: output.appendingPathComponent("results.json"))
        } catch {
            var failed = report(records, initialLoad: initialLoad, compute: compute, mode: mode, passes: passes, status: "failed")
            failed["error"] = error.localizedDescription
            try? json(failed, to: output.appendingPathComponent("results.json"))
            throw error
        }
    }
    private static func report(_ records: [[String: Any]], initialLoad: Double, compute: String, mode: String, passes: Int,
                               status: String = "running") -> [String: Any] {
        ["model": "Apple DETRResnet50SemanticSegmentationF16", "revision": HarnessSource.revision,
         "inputSide": 448, "maximumOutputDimension": LocalMaskRaster.maximumDimension,
         "computeUnits": compute, "mode": mode, "passes": passes,
         "status": status, "expectedRecords": 7 * passes, "completedRecords": records.count,
         "initialModelLoadSeconds": initialLoad, "processPeakResidentBytes": peakRSS(), "records": records,
         "productionSourceSHA256": HarnessSource.sourceSHA256,
         "scope": "Production .all or explicit CPU control; real production square ARGB input, raster converter and guided filter. Resident batch retains model, unlike production which reloads per mask; oneshot reloads each image. Prepared oriented PNG decode excludes editor preview creation and installed-receipt verification. No cache purge; process RSS does not capture every driver allocation. Empty raw masks retained for negative images; app would return noSky before refinement."]
    }
    private static func selftest() throws {
        let size = AutomaticMaskRasterConverter.outputSize(width: 6_000, height: 4_000)
        try require(size.width == 2_048 && size.height == 1_365, "Output size regression")
        let classes = try MLMultiArray(shape: [448, 448], dataType: .int32)
        let ptr = classes.dataPointer.assumingMemoryBound(to: Int32.self)
        for y in 0..<448 { for x in 0..<448 { ptr[y * 448 + x] = x < 224 ? 7 : 0 } }
        let raw = try AutomaticMaskRasterConverter.skyRaster(classes, skyClass: 7, outputSize: (448, 448))
        try require(raw.bytes[0] == 255 && raw.bytes[223] == 255 && raw.bytes[224] == 0 && raw.bytes.last == 0,
                    "Class mapping/identity restore regression")
        let reduced = try AutomaticMaskRasterConverter.skyRaster(classes, skyClass: 7, outputSize: (3, 1))
        try require(Array(reduced.bytes) == [255, 128, 0], "Bilinear class restore regression")
        let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 24 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let guide = context.makeImage()!
        let buffer = try NativeDETRInput.squarePixelBuffer(guide, side: 448)
        try require(CVPixelBufferGetWidth(buffer) == 448 && CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32ARGB,
                    "Production input format regression")
        let mask = try AutomaticMaskRasterConverter.skyRaster(classes, skyClass: 7, outputSize: (24, 16))
        let refined = try AutomaticMaskRefiner.refine(mask, guide: guide)
        try require(refined.bytes.count == mask.bytes.count && zip(refined.bytes, mask.bytes).allSatisfy { $0.0 <= $0.1 },
                    "Production refinement support regression")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try freshDirectory(folder); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("roundtrip.png")
        try writePNG(refined, file); let roundtrip = try readMask(file)
        try require(roundtrip == refined, "Gray8 PNG roundtrip regression")
        try json(["selftest": "passed", "checks": ["output cap", "class mapping", "bilinear restore", "ARGB input", "real guided filter", "Gray8 roundtrip"],
                  "productionSourceSHA256": HarnessSource.sourceSHA256])
    }
    private static let usage = """
    Usage: sky-detr selftest
           sky-detr verify APPROVED.mlpackage
           sky-detr compile APPROVED.mlpackage FRESH.mlmodelc
           sky-detr info MODEL.mlmodelc all|cpu
           sky-detr run MODEL.mlmodelc INPUT_PNG_DIR FRESH_OUT all|cpu [PASSES=2] [resident|oneshot]
           sky-detr refine GUIDE.png RAW_GRAY8.png FRESH_REFINED.png [software]
           sky-detr refine-batch INPUT_PNG_DIR MASK_DIR FRESH_OUT '{id}-pass{pass}-native-bilinear.png' [PASSES=2]
    """
}
