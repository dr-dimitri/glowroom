// Native batch baseline, matching Glowroom's approved 1920 Core ML input.
// Usage: executable compiled.mlmodelc inputs-directory output-directory gpu|cpu
import CoreGraphics
import CoreML
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Failure: Error { case arguments, image, alpha }
let args = CommandLine.arguments
guard args.count == 5, ["gpu", "cpu"].contains(args[4]) else { throw Failure.arguments }
let inputs = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
let config = MLModelConfiguration()
config.computeUnits = args[4] == "gpu" ? .cpuAndGPU : .cpuOnly
config.allowLowPrecisionAccumulationOnGPU = false
let now = { ProcessInfo.processInfo.systemUptime }
let start = now()
let model = try MLModel(contentsOf: URL(fileURLWithPath: args[1]), configuration: config)
let loadSeconds = now() - start
guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
      constraint.pixelsWide == 1920, constraint.pixelsHigh == 1920 else { throw Failure.image }
let side = 1920
var records = [[String: Any]]()
for number in 1...7 {
    let id = "test_picture\(number)"
    // First-image repeat separates initial and warm inference without another pool.
    for iteration in 1...(number == 1 ? 2 : 1) {
        try autoreleasepool {
            let requestStart = now()
            guard let source = CGImageSourceCreateWithURL(inputs.appendingPathComponent(id + ".png") as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.image }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                &optionalBuffer) == kCVReturnSuccess, let buffer = optionalBuffer else { throw Failure.image }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw Failure.image }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let features = try MLDictionaryFeatureProvider(dictionary: ["image": buffer])
            let preprocessed = now()
            let prediction = try model.prediction(from: features)
            let predicted = now()
            guard let alpha = prediction.featureValue(for: "alpha")?.multiArrayValue,
                  alpha.dataType == .float32, alpha.shape.map(\.intValue) == [1, 1, side, side] else { throw Failure.alpha }
            let values = alpha.dataPointer.assumingMemoryBound(to: Float.self)
            let sy = alpha.strides[2].intValue, sx = alpha.strides[3].intValue
            var bytes = [UInt8](repeating: 0, count: side * side)
            for y in 0..<side { for x in 0..<side {
                let value = values[y * sy + x * sx]
                guard value.isFinite, value >= 0, value <= 1 else { throw Failure.alpha }
                bytes[y * side + x] = UInt8((value * 255).rounded())
            }}
            let validated = now()
            let data = Data(bytes)
            guard let provider = CGDataProvider(data: data as CFData),
                  let mask = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
                    bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                  let resized = CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
            else { throw Failure.alpha }
            resized.interpolationQuality = .high
            resized.draw(mask, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let restored = resized.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(
                    output.appendingPathComponent("\(id)-\(iteration)-alpha.png") as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else { throw Failure.alpha }
            CGImageDestinationAddImage(destination, restored, nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure.alpha }
            let record: [String: Any] = ["id": id, "iteration": iteration,
                "preprocessSeconds": preprocessed - requestStart, "inferenceSeconds": predicted - preprocessed,
                "validateSeconds": validated - predicted, "requestSeconds": validated - requestStart,
                "outputSeconds": now() - validated, "alphaMinimum": bytes.min()!, "alphaMaximum": bytes.max()!]
            records.append(record)
            print(String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!)
            fflush(stdout)
        }
    }
}
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
let report: [String: Any] = ["model": "BiRefNet_HR-matting", "inputSide": side,
    "computeUnits": args[4], "loadSeconds": loadSeconds, "records": records,
    "processPeakResidentBytes": usage.ru_maxrss,
    "scope": "Native Core ML batch; first-image repeat; model retained across seven images. OS/GPU caches not purged. Request excludes model loading and output encoding; RSS omits some driver allocations."]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("results.json"))
