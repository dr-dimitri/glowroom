// Standalone native benchmark: no Python/PyTorch process or app background work.
// swiftc tools/subject-matting/benchmark.swift -o /tmp/picedit-subject-benchmark
// /tmp/picedit-subject-benchmark model.mlpackage image.png gpu|cpu output-directory
import CoreGraphics
import CoreML
import CoreVideo
import Darwin
import Foundation
import ImageIO

enum Failure: Error { case invalidArguments, invalidImage, invalidAlpha }

let arguments = CommandLine.arguments
func monotonicTime() -> Double { ProcessInfo.processInfo.systemUptime }
if arguments.count == 4, arguments[2] == "compile" {
    let start = monotonicTime()
    let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: arguments[1]))
    try FileManager.default.copyItem(at: compiled, to: URL(fileURLWithPath: arguments[3]))
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("{\"compileSeconds\":\(monotonicTime() - start),\"processPeakResidentBytes\":\(usage.ru_maxrss)}")
    exit(0)
}
guard [5, 6].contains(arguments.count), ["cpu", "gpu"].contains(arguments[3]) else { throw Failure.invalidArguments }
let iterations = arguments.count == 6 ? Int(arguments[5]) ?? 0 : (arguments[3] == "cpu" ? 1 : 2)
guard (1...2).contains(iterations) else { throw Failure.invalidArguments }
let directory = URL(fileURLWithPath: arguments[4], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
let source = URL(fileURLWithPath: arguments[1])
let started = monotonicTime()
let compiled = source.pathExtension == "mlmodelc" ? source : try MLModel.compileModel(at: source)
let compileSeconds = monotonicTime() - started
let configuration = MLModelConfiguration()
configuration.computeUnits = arguments[3] == "cpu" ? .cpuOnly : .cpuAndGPU
configuration.allowLowPrecisionAccumulationOnGPU = false
let requestStarted = monotonicTime()
let loading = monotonicTime()
let model = try MLModel(contentsOf: compiled, configuration: configuration)
let loadSeconds = monotonicTime() - loading
guard let sourceImage = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(sourceImage, 0, nil) else { throw Failure.invalidImage }
guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
      constraint.pixelsWide == constraint.pixelsHigh,
      (256...2048).contains(constraint.pixelsWide), constraint.pixelsWide.isMultiple(of: 32) else { throw Failure.invalidImage }
let side = constraint.pixelsWide
var optionalBuffer: CVPixelBuffer?
guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
    &optionalBuffer) == kCVReturnSuccess, let buffer = optionalBuffer else { throw Failure.invalidImage }
CVPixelBufferLockBaseAddress(buffer, [])
guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw Failure.invalidImage }
context.interpolationQuality = .high
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))
context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
CVPixelBufferUnlockBaseAddress(buffer, [])
let features = try MLDictionaryFeatureProvider(dictionary: ["image": buffer])
var seconds = [Double]()
var output = [Float]()
var requestSecondsToFirstValidatedAlpha = 0.0
for iteration in 0..<iterations {
    let predicting = monotonicTime()
    let prediction = try model.prediction(from: features)
    seconds.append(monotonicTime() - predicting)
    guard let alpha = prediction.featureValue(for: "alpha")?.multiArrayValue,
        alpha.dataType == .float32, alpha.shape.map(\.intValue) == [1, 1, side, side] else { throw Failure.invalidAlpha }
    let sy = alpha.strides[2].intValue, sx = alpha.strides[3].intValue
    let values = alpha.dataPointer.assumingMemoryBound(to: Float.self)
    output = [Float](repeating: 0, count: side * side)
    for y in 0..<side {
        for x in 0..<side {
            let value = values[y * sy + x * sx]
            guard value.isFinite, value >= 0, value <= 1 else { throw Failure.invalidAlpha }
            output[y * side + x] = value
        }
    }
    if iteration == 0 { requestSecondsToFirstValidatedAlpha = monotonicTime() - requestStarted }
    try output.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("alpha-\(iteration + 1).f32")) }
}
var usage = rusage()
guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.invalidAlpha }
try output.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("alpha.f32")) }
let report: [String: Any] = [
    "computeUnits": arguments[3] == "cpu" ? "cpuOnly" : "cpuAndGPU", "side": side,
    "compileSeconds": compileSeconds, "loadSeconds": loadSeconds, "inferenceSeconds": seconds,
    "requestSecondsToFirstValidatedAlpha": requestSecondsToFirstValidatedAlpha,
    "processPeakResidentBytes": usage.ru_maxrss, "alphaMinimum": output.min()!, "alphaMaximum": output.max()!,
    "limitations": "Fresh native process; OS/Core ML/GPU caches not purged. Request uses monotonic time from MLModel load through image decode/resize, first prediction and validated alpha copy, excluding compilation and output writes. App installation integrity hashing, RAW development and final aspect-restoration raster are excluded. Process RSS excludes some GPU/driver allocations. CoreGraphics high-quality resize."
]
let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try json.write(to: directory.appendingPathComponent("benchmark.json"))
print(String(decoding: json, as: UTF8.self))
