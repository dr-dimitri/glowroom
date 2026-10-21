#if GLOWROOM_IMAGE_GENERATION_EVALUATION
import CoreML
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import GlowroomCore

/// Separate, opt-in technical candidate. It never installs a product backend.
/// The uploader's model-card measurements and conversion recipe are not assumed
/// to describe the downloaded package: inspect its actual Core ML interface.
enum LaMaEvaluation {
    private typealias JSON = [String: Any]
    private static let revision = "5ed76e3799ab4cad31381750d29880c267477e18"
    private static let limit: UInt64 = 6 * 1024 * 1024 * 1024
    private struct Fixtures: Decodable { let fixtures: [Fixture] }
    private struct Fixture: Decodable {
        let id: String, source: String, sourceFileSHA256: String
        let masks: [Mask]
        struct Mask: Decodable { let kind: String, path: String, fileSHA256: String }
    }
    private enum Failure: Error { case invalid(String) }
    private static func check(_ condition: Bool, _ detail: String) throws {
        if !condition { throw Failure.invalid(detail) }
    }
    private static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func clock() -> Double {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1e9
    }
    private static func memory() -> JSON {
        var r = rusage(); getrusage(RUSAGE_SELF, &r)
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ["peakRSSBytes": Int64(r.ru_maxrss), "footprintAvailable": status == KERN_SUCCESS,
                "peakFootprintBytes": Int64(vm.ledger_phys_footprint_peak)]
    }
    private static func write(_ value: JSON, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    static func run(root: URL, repository: URL, fixtureArchive: URL?, output: URL, inspectOnly: Bool) throws {
        try check(!FileManager.default.fileExists(atPath: output.path), "report directory already exists")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: JSON = ["schemaVersion": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
            "modelRevision": revision, "productCapabilities": "unchanged-unavailable",
            "scope": "technical candidate only; no text conditioning; no distribution or product-adapter Go"]
        defer { try? write(report, to: output.appendingPathComponent("lama-report.json")) }
        do {
            let tools = repository.appendingPathComponent("tools/lama-evaluation")
            let packageBytes = try Data(contentsOf: tools.appendingPathComponent("package.json"))
            try check(sha(packageBytes) == "f0d76abd55c49ab77177491e1c3e6bafea0d346ef2adc512af7382d4e88e75ed", "package hash")
            let package = try JSONSerialization.jsonObject(with: packageBytes) as! JSON
            try check(package["revision"] as? String == revision, "model revision")
            let installed = root.appendingPathComponent("model")
            for entry in package["files"] as! [JSON] {
                let relative = entry["path"] as! String
                try check(!relative.hasPrefix("/") && !relative.split(separator: "/").contains(".."), "model path")
                let url = installed.appendingPathComponent(relative)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                try check(values.isRegularFile == true && values.isSymbolicLink != true, "model file")
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                try check(data.count == entry["bytes"] as? Int && sha(data) == entry["sha256"] as? String, "model hash")
            }
            let criteria = try Data(contentsOf: tools.appendingPathComponent("criteria.json"))
            let criteriaObject = try JSONSerialization.jsonObject(with: criteria) as! JSON
            try check(criteriaObject["schemaVersion"] as? Int == 2, "preprocessing criteria version")
            report["preprocessingVersion"] = 2
            report["criteriaSHA256"] = sha(criteria)
            report["packageSHA256"] = sha(packageBytes)
            try criteria.write(to: output.appendingPathComponent("criteria.json"))
            report["hardware"] = ["physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString]
            try check(ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024, "minimum memory")
            let compileStart = clock()
            let compiled = try MLModel.compileModel(at: installed.appendingPathComponent("LaMa.mlpackage"))
            defer { try? FileManager.default.removeItem(at: compiled) }
            report["compilationSeconds"] = clock() - compileStart
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            configuration.allowLowPrecisionAccumulationOnGPU = false
            let loadStart = clock()
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            report["loadSeconds"] = clock() - loadStart
            try check((report["loadSeconds"] as! Double) <= 45, "model load time gate")
            report["description"] = String(describing: model.modelDescription)
            try check(model.modelDescription.inputDescriptionsByName.count == 2,
                      "unexpected model inputs")
            let inputs = model.modelDescription.inputDescriptionsByName
            guard let image = inputs["image"]?.imageConstraint, let mask = inputs["mask"]?.imageConstraint,
                  let result = model.modelDescription.outputDescriptionsByName.values.first,
                  let resultImage = result.imageConstraint else { throw Failure.invalid("image/mask/output interface") }
            try check([image, mask, resultImage].allSatisfy { $0.pixelsWide == 800 && $0.pixelsHigh == 800 }, "native canvas")
            try check(mask.pixelFormatType == kCVPixelFormatType_OneComponent8, "Gray8 mask interface")
            try check([kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB].contains(image.pixelFormatType) &&
                      [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB].contains(resultImage.pixelFormatType), "RGB8 interface")
            report["interface"] = ["imagePixelFormat": image.pixelFormatType, "maskPixelFormat": mask.pixelFormatType,
                "outputPixelFormat": resultImage.pixelFormatType, "outputName": result.name]
            if inspectOnly { report["status"] = "interface-inspected-no-inference"; return }

            guard let historical = fixtureArchive else { throw Failure.invalid("missing --fixture-archive") }
            let manifest = try Data(contentsOf: historical.appendingPathComponent("provenance/fixtures-manifest.json"))
            try check(sha(manifest) == "799d51e22631500e9caa2fbdd2c09403788d55d4248ddeacc9cc0db0c4a7a2d5", "fixture manifest hash")
            let fixtures = try JSONDecoder().decode(Fixtures.self, from: manifest).fixtures
            var runs: [JSON] = []
            // One native model context and the enclosing AI-01 inference lease.
            // Serial calls avoid duplicate model memory and invalid benchmarks.
            for fixture in fixtures {
                for item in fixture.masks {
                    let id = fixture.id + "-" + item.kind
                    let sourceURL = historical.appendingPathComponent(fixture.source)
                    let maskURL = historical.appendingPathComponent(item.path)
                    let sourceData = try Data(contentsOf: sourceURL), maskData = try Data(contentsOf: maskURL)
                    try check(sha(sourceData) == fixture.sourceFileSHA256 && sha(maskData) == item.fileSHA256, "fixture hash")
                    let source = try ImageGenerationReplay.loadCanonicalRGBA8(sourceURL)
                    let weights = try ImageGenerationReplay.loadGrayMask(maskURL)
                    let w = source.image.width, h = source.image.height
                    try check(w <= 800 && h <= 800 && w == weights.size.width && h == weights.size.height, "fixture dimensions")
                    let pixels = try ImageGenerationReplay.rgba8Bytes(source.image)
                    let mapping = try LaMaEvaluationMapping(width: w, height: h)
                    let imageBuffer = try LaMaEvaluationPixels.buffer(format: image.pixelFormatType)
                    let maskBuffer = try LaMaEvaluationPixels.buffer(format: mask.pixelFormatType)
                    try LaMaEvaluationPixels.fill(imageBuffer, maskBuffer, pixels: pixels, weights: weights.bytes, mapping: mapping)
                    let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: imageBuffer), "mask": MLFeatureValue(pixelBuffer: maskBuffer)])
                    let repeats = id == "01-structured-removal-hard" ? 4 : 1
                    for repeatIndex in 0..<repeats {
                        let runID = repeatIndex == 0 ? id : "warm-\(repeatIndex)"
                        let folder = output.appendingPathComponent("artifacts/\(runID)")
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let began = clock()
                        let (bytes, seconds) = try autoreleasepool {
                            let predicted = try model.prediction(from: input)
                            let seconds = clock() - began
                            guard let outputBuffer = predicted.featureValue(for: result.name)?.imageBufferValue else { throw Failure.invalid("output buffer") }
                            return (try LaMaEvaluationPixels.crop(outputBuffer, mapping: mapping), seconds)
                        }
                        let bitmap = try ImageGenerationReplay.rgba8Image(size: weights.size, bytes: bytes)
                        try ImageGenerationReplay.writePNG(bitmap, to: folder.appendingPathComponent("raw.png"))
                        try sourceData.write(to: folder.appendingPathComponent("source.png"))
                        try maskData.write(to: folder.appendingPathComponent("replace-mask.png"))
                        let stats = memory()
                        runs.append(["id": runID, "fixture": id, "predictionSeconds": seconds,
                            "memory": stats, "pixelSHA256": sha(bytes), "width": w, "height": h,
                            "modelOffset": [mapping.offsetX, mapping.offsetY], "modelCanvas": [800, 800]])
                        report["runs"] = runs
                        try write(report, to: output.appendingPathComponent("lama-report.json"))
                        print("LaMa \(runID): \(seconds)s")
                        try check(seconds <= 180, "prediction time gate")
                        let rss = stats["peakRSSBytes"] as! Int64, footprint = stats["peakFootprintBytes"] as! Int64
                        try check(rss > 0 && rss <= Int64(limit), "resident memory gate")
                        try check(stats["footprintAvailable"] as? Bool == true && footprint > 0 && footprint <= Int64(limit), "footprint gate")
                    }
                }
            }
            let fixturesOut = output.appendingPathComponent("fixtures")
            try FileManager.default.createDirectory(at: fixturesOut, withIntermediateDirectories: true)
            try Data(contentsOf: historical.appendingPathComponent("fixtures/06-canvas-original.png"))
                .write(to: fixturesOut.appendingPathComponent("06-canvas-original.png"))
            report["status"] = "technical-inference-complete-awaiting-compositor-visual-review-and-provenance"
            report["memory"] = memory()
        } catch {
            report["status"] = "technical-probe-failed"
            report["error"] = String(describing: error)
            throw error
        }
    }

}
#endif
