// Standalone, image-only SAM 2.1 Tiny evaluation; never linked into PicEdit.
// Reference interfaces: huggingface/sam2-studio @ 0dd708d0162e8e0b8c1e447123465b4b027e8b12.
// swiftc -O tools/mask-evaluation/sam2.swift -o /tmp/picedit-sam2-evaluation
// compile: BINARY compile MODEL_DIRECTORY COMPILED_DIRECTORY
// run: BINARY run COMPILED_DIRECTORY MANIFEST.json OUTPUT_DIRECTORY gpu|cpu
// Manifest: {"iterations":2,"images":[{"id":"photo1","path":"/absolute/image.png",
//   "prompts":[{"id":"subject","box":[0.1,0.1,0.9,0.9],
//   "points":[{"x":0.5,"y":0.5,"label":1}]}]}]}
// Coordinates use a top-left origin and [0,1] range. Boxes are xyxy; point labels
// are 1=foreground and 0=background. A box is represented by SAM labels 2 and 3.
import CoreGraphics
import CoreML
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct EvaluationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Point: Decodable { let x: Float; let y: Float; let label: Int }
struct Prompt: Decodable { let id: String; let box: [Float]?; let points: [Point]? }
struct InputImage: Decodable {
    let id: String
    let path: String
    let prompts: [Prompt]
    let target: String?
    let automaticForegroundAmbiguous: Bool?
}
struct Manifest: Decodable {
    let iterations: Int?
    let images: [InputImage]
    let coordinateConvention: String?
}

func time() -> Double { ProcessInfo.processInfo.systemUptime }
func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}
func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}
func identifierIsSafe(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }
}
func requireArray(_ prediction: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
    guard let array = prediction.featureValue(for: name)?.multiArrayValue else {
        throw EvaluationFailure("Missing model tensor: \(name)")
    }
    return array
}
func values(_ array: MLMultiArray) -> [Float] {
    // MLMultiArray subscripts respect dtype/strides, including Float16 outputs.
    (0..<array.count).map { array[$0].floatValue }
}

let modelNames = ["ImageEncoder", "PromptEncoder", "MaskDecoder"]
func modelURL(_ directory: URL, _ name: String, extension suffix: String) -> URL {
    directory.appendingPathComponent("SAM2_1Tiny\(name)FLOAT16.\(suffix)")
}

func compileModels(source: URL, destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    var report: [String: Any] = [:]
    // Compile sequentially to avoid disturbing another model's memory/timing run.
    for name in modelNames {
        let started = time()
        let compiled = try MLModel.compileModel(at: modelURL(source, name, extension: "mlpackage"))
        try FileManager.default.copyItem(at: compiled, to: modelURL(destination, name, extension: "mlmodelc"))
        report[name] = ["compileSeconds": time() - started]
    }
    report["processPeakResidentBytes"] = peakRSS()
    try writeJSON(report, to: destination.appendingPathComponent("compile.json"))
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
}

func pixelBuffer(image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
    var optional: CVPixelBuffer?
    let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                      kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                              attributes, &optional) == kCVReturnSuccess, let buffer = optional else {
        throw EvaluationFailure("Cannot allocate input pixel buffer")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
        throw EvaluationFailure("Cannot create input bitmap context")
    }
    context.interpolationQuality = .high
    // Match the public Core ML reference's square image input. No letterboxing:
    // normalized prompt coordinates still map directly to the source image.
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

func promptFeatures(_ prompt: Prompt, side: Int) throws -> MLFeatureProvider {
    var coordinates: [(Float, Float)] = []
    var labels: [Int32] = []
    if let box = prompt.box {
        guard box.count == 4, box.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              box[0] < box[2], box[1] < box[3] else {
            throw EvaluationFailure("Invalid normalized xyxy box: \(prompt.id)")
        }
        coordinates += [(box[0], box[1]), (box[2], box[3])]
        labels += [2, 3]
    }
    for point in prompt.points ?? [] {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x),
              (0...1).contains(point.y), [0, 1].contains(point.label) else {
            throw EvaluationFailure("Invalid normalized point: \(prompt.id)")
        }
        coordinates.append((point.x, point.y))
        labels.append(Int32(point.label))
    }
    guard !coordinates.isEmpty else { throw EvaluationFailure("Prompt has no points or box: \(prompt.id)") }
    let count = coordinates.count
    let points = try MLMultiArray(shape: [1, NSNumber(value: count), 2], dataType: .float32)
    let labelArray = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
    for index in 0..<count {
        points[[0, NSNumber(value: index), 0]] = NSNumber(value: coordinates[index].0 * Float(side))
        points[[0, NSNumber(value: index), 1]] = NSNumber(value: coordinates[index].1 * Float(side))
        labelArray[[0, NSNumber(value: index)]] = NSNumber(value: labels[index])
    }
    return try MLDictionaryFeatureProvider(dictionary: ["points": points, "labels": labelArray])
}

struct MaskResult {
    let logits: [Float]
    let width: Int
    let height: Int
    let scores: [Float]
    let selectedIndex: Int
}

func extractMask(_ prediction: MLFeatureProvider) throws -> MaskResult {
    let scores = values(try requireArray(prediction, "scores"))
    guard !scores.isEmpty, scores.allSatisfy(\.isFinite) else { throw EvaluationFailure("Invalid mask scores") }
    let selected = scores.indices.max(by: { scores[$0] < scores[$1] })!
    let array = try requireArray(prediction, "low_res_masks")
    let shape = array.shape.map(\.intValue)
    guard shape.count == 4, shape[0] == 1, shape[1] == scores.count,
          shape[2] > 0, shape[3] > 0 else { throw EvaluationFailure("Unexpected mask shape: \(shape)") }
    var logits = [Float](repeating: 0, count: shape[2] * shape[3])
    for y in 0..<shape[2] {
        for x in 0..<shape[3] {
            let value = array[[0, NSNumber(value: selected), NSNumber(value: y), NSNumber(value: x)]].floatValue
            guard value.isFinite else { throw EvaluationFailure("Nonfinite mask logit") }
            logits[y * shape[3] + x] = value
        }
    }
    return MaskResult(logits: logits, width: shape[3], height: shape[2], scores: scores, selectedIndex: selected)
}

func writeMaskPNG(_ mask: MaskResult, width: Int, height: Int, url: URL) throws -> Double {
    let start = time()
    var bytes = [UInt8](repeating: 0, count: width * height)
    // Match torch bilinear upsampling (align_corners=false), then threshold at
    // zero. Soft SAM logits are not an alpha matte and are saved separately.
    for y in 0..<height {
        let fy = max(0, min(Double(mask.height - 1), (Double(y) + 0.5) * Double(mask.height) / Double(height) - 0.5))
        let y0 = Int(fy), y1 = min(y0 + 1, mask.height - 1)
        let wy = Float(fy - Double(y0))
        for x in 0..<width {
            let fx = max(0, min(Double(mask.width - 1), (Double(x) + 0.5) * Double(mask.width) / Double(width) - 0.5))
            let x0 = Int(fx), x1 = min(x0 + 1, mask.width - 1)
            let wx = Float(fx - Double(x0))
            let a = mask.logits[y0 * mask.width + x0] * (1 - wx) + mask.logits[y0 * mask.width + x1] * wx
            let b = mask.logits[y1 * mask.width + x0] * (1 - wx) + mask.logits[y1 * mask.width + x1] * wx
            bytes[y * width + x] = a * (1 - wy) + b * wy > 0 ? 255 : 0
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw EvaluationFailure("Cannot create mask PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw EvaluationFailure("Cannot write mask PNG") }
    return time() - start
}

func run(models directory: URL, manifestURL: URL, output: URL, useGPU: Bool) throws {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    let iterations = manifest.iterations ?? 2
    guard (1...3).contains(iterations), !manifest.images.isEmpty else {
        throw EvaluationFailure("Expected 1...3 iterations and at least one image")
    }
    var imageIDs = Set<String>()
    for image in manifest.images {
        guard identifierIsSafe(image.id), imageIDs.insert(image.id).inserted,
              image.path.hasPrefix("/"), !image.prompts.isEmpty else {
            throw EvaluationFailure("Invalid image ID, absolute path, or prompts")
        }
        var promptIDs = Set<String>()
        for prompt in image.prompts {
            guard identifierIsSafe(prompt.id), promptIDs.insert(prompt.id).inserted else {
                throw EvaluationFailure("Invalid or duplicate prompt ID")
            }
        }
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let requestStart = time()
    let config = MLModelConfiguration()
    config.computeUnits = useGPU ? .cpuAndGPU : .cpuOnly
    config.allowLowPrecisionAccumulationOnGPU = false
    var loaded: [String: MLModel] = [:]
    var loadSeconds: [String: Double] = [:]
    var descriptions: [String: Any] = [:]
    // Benchmark runs are serial so their resource usage and timings do not
    // overlap. Each image encoder result is reused by all prompts/iterations.
    for name in modelNames {
        let start = time()
        let model = try MLModel(contentsOf: modelURL(directory, name, extension: "mlmodelc"), configuration: config)
        loadSeconds[name] = time() - start
        loaded[name] = model
        descriptions[name] = [
            "inputs": model.modelDescription.inputDescriptionsByName.mapValues { $0.description },
            "outputs": model.modelDescription.outputDescriptionsByName.mapValues { $0.description }
        ]
    }
    let imageEncoder = loaded["ImageEncoder"]!
    let promptEncoder = loaded["PromptEncoder"]!
    let maskDecoder = loaded["MaskDecoder"]!
    guard let input = imageEncoder.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
          input.pixelsWide == input.pixelsHigh else { throw EvaluationFailure("Unexpected image input") }
    let side = input.pixelsWide
    var imageReports: [[String: Any]] = []
    for (imageIndex, item) in manifest.images.enumerated() {
        let report: [String: Any] = try autoreleasepool {
            let imageStart = time()
            let decodeStart = time()
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw EvaluationFailure("Cannot load image: \(item.id)")
            }
            let decodeSeconds = time() - decodeStart
            let preprocessStart = time()
            let buffer = try pixelBuffer(image: image, width: side, height: side)
            let imageInput = try MLDictionaryFeatureProvider(dictionary: ["image": buffer])
            let preprocessSeconds = time() - preprocessStart
            let encodeStart = time()
            let encoded = try imageEncoder.prediction(from: imageInput)
            let imageEncoderSeconds = time() - encodeStart
            let imageFeatures: [String: Any] = [
                "image_embedding": try requireArray(encoded, "image_embedding"),
                "feats_s0": try requireArray(encoded, "feats_s0"),
                "feats_s1": try requireArray(encoded, "feats_s1")
            ]
            let imageDirectory = output.appendingPathComponent(item.id)
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: false)
            var promptReports: [[String: Any]] = []
            for prompt in item.prompts {
                let features = try promptFeatures(prompt, side: side)
                var promptSeconds: [Double] = [], decoderSeconds: [Double] = [], extractionSeconds: [Double] = []
                var masks: [MaskResult] = []
                var firstMaskSeconds = 0.0
                for iteration in 0..<iterations {
                    let promptStart = time()
                    let promptOutput = try promptEncoder.prediction(from: features)
                    promptSeconds.append(time() - promptStart)
                    var decoderFeatures = imageFeatures
                    decoderFeatures["sparse_embedding"] = try requireArray(promptOutput, "sparse_embeddings")
                    decoderFeatures["dense_embedding"] = try requireArray(promptOutput, "dense_embeddings")
                    let decoderInput = try MLDictionaryFeatureProvider(dictionary: decoderFeatures)
                    let decoderStart = time()
                    let prediction = try maskDecoder.prediction(from: decoderInput)
                    decoderSeconds.append(time() - decoderStart)
                    let extractionStart = time()
                    masks.append(try extractMask(prediction))
                    extractionSeconds.append(time() - extractionStart)
                    if iteration == 0 { firstMaskSeconds = time() - imageStart }
                }
                let selected = masks[0]
                let exportSeconds = try writeMaskPNG(selected, width: image.width, height: image.height,
                    url: imageDirectory.appendingPathComponent("\(prompt.id)-mask.png"))
                try selected.logits.withUnsafeBytes {
                    try Data($0).write(to: imageDirectory.appendingPathComponent("\(prompt.id)-logits.f32"))
                }
                let maximumRepeatDelta = masks.dropFirst().map { repeatMask in
                    zip(selected.logits, repeatMask.logits).map { abs($0 - $1) }.max() ?? 0
                }.max() ?? 0
                var promptReport: [String: Any] = [
                    "id": prompt.id, "promptEncoderSeconds": promptSeconds, "decoderSeconds": decoderSeconds,
                    "extractionSeconds": extractionSeconds, "scores": selected.scores,
                    "selectedIndex": selected.selectedIndex, "logitsWidth": selected.width, "logitsHeight": selected.height,
                    "logitMinimum": selected.logits.min()!, "logitMaximum": selected.logits.max()!,
                    "maximumLogitDifferenceAcrossRepeats": maximumRepeatDelta,
                    "imageRequestToFirstValidatedMaskSeconds": firstMaskSeconds,
                    "maskExportSeconds": exportSeconds, "processPeakResidentBytes": peakRSS()
                ]
                if let box = prompt.box { promptReport["boxXYXYNormalized"] = box }
                promptReport["pointsXYLabelNormalized"] = (prompt.points ?? []).map {
                    ["x": Double($0.x), "y": Double($0.y), "label": Double($0.label)]
                }
                promptReports.append(promptReport)
            }
            return ["id": item.id, "width": image.width, "height": image.height,
                    "imageIndex": imageIndex, "decodeSeconds": decodeSeconds,
                    "preprocessingSeconds": preprocessSeconds, "imageEncoderSeconds": imageEncoderSeconds,
                    "prompts": promptReports, "processPeakResidentBytes": peakRSS(),
                    "target": item.target ?? "unspecified",
                    "automaticForegroundAmbiguous": item.automaticForegroundAmbiguous ?? false]
        }
        imageReports.append(report)
        try writeJSON(report, to: output.appendingPathComponent(item.id).appendingPathComponent("benchmark.json"))
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        fflush(stdout)
    }
    let report: [String: Any] = [
        "model": "SAM 2.1 Hiera Tiny", "sourceRepository": "apple/coreml-sam2.1-tiny",
        "sourceRevision": "39ae0a8a83e5e6cd196e804bf7cccc5f8171f306", "precision": "Float16",
        "coordinateConvention": manifest.coordinateConvention ?? "Normalized x/y, origin top left",
        "promptProvenance": "Manual test annotations; not model-generated grounding",
        "computeUnits": useGPU ? "cpuAndGPU" : "cpuOnly", "inputSide": side,
        "loadSeconds": loadSeconds, "images": imageReports, "iterationsPerPrompt": iterations,
        "elapsedSecondsIncludingOutputs": time() - requestStart, "processPeakResidentBytes": peakRSS(),
        "modelDescriptions": descriptions,
        "limitations": "Fresh native process; OS/Core ML/GPU caches not purged. Encoder runs once per image and is reused for all prompts and repeated mask decoding. First image measures first-use graph overhead; later image encodings use warmed models. Prompt repeats reuse the image embedding. Input images must already have EXIF orientation applied. Square sRGB CoreGraphics resize matches Core ML reference; raw decoding is excluded. Masks are bilinearly resized logits thresholded at zero, not alpha mattes. Low-resolution native-endian float32 logits are saved. ru_maxrss is process peak RSS in bytes on macOS; some GPU/driver memory is excluded. Compilation and downloads are excluded."
    ]
    try writeJSON(report, to: output.appendingPathComponent("benchmark.json"))
}

do {
    let args = CommandLine.arguments
    if args.count == 4, args[1] == "compile" {
        try compileModels(source: URL(fileURLWithPath: args[2]), destination: URL(fileURLWithPath: args[3]))
    } else if args.count == 6, args[1] == "run", ["gpu", "cpu"].contains(args[5]) {
        try run(models: URL(fileURLWithPath: args[2]), manifestURL: URL(fileURLWithPath: args[3]),
                output: URL(fileURLWithPath: args[4]), useGPU: args[5] == "gpu")
    } else {
        throw EvaluationFailure("usage: sam2 compile MODEL_DIRECTORY COMPILED_DIRECTORY | sam2 run COMPILED_DIRECTORY MANIFEST.json OUTPUT_DIRECTORY gpu|cpu")
    }
} catch {
    FileHandle.standardError.write(Data("SAM2 evaluation failed: \(error)\n".utf8))
    exit(1)
}
