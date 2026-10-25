import CoreImage
import Foundation

// Developer evaluation only. The app never imports or invokes this candidate.
// The existing bounded render graph may use a qualified successor in the future.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
guard CommandLine.arguments.count == 4, let version = Int(CommandLine.arguments[3]), (1...2).contains(version) else {
    fatalError("Usage: swift ColorMixerCandidate.swift fixtures.json native-output.json 1|2")
}
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let inputData = try Data(contentsOf: inputURL)
guard inputData.count <= 64 * 1024 * 1024,
      let document = try JSONSerialization.jsonObject(with: inputData) as? [String: Any],
      document["version"] as? Int == 1,
      let fixtures = document["fixtures"] as? [[String: Any]], !fixtures.isEmpty, fixtures.count <= 16_384,
      let cases = document["settings"] as? [[String: Any]], !cases.isEmpty, cases.count <= 16 else {
    fatalError("Invalid evaluation fixture document")
}
let bands = ["red", "orange", "yellow", "green", "aqua", "blue", "violet", "magenta"]
let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf,
                                 .cacheIntermediates: false])
let extent = CGRect(x: 0, y: 0, width: fixtures.count, height: 1)
var input: [Float] = []
for fixture in fixtures {
    guard let rgba = fixture["rgba"] as? [Double], rgba.count == 4,
          rgba.allSatisfy({ $0.isFinite && Float($0).isFinite }), (0...1).contains(rgba[3]) else {
        fatalError("Invalid RGBAf fixture")
    }
    let alpha = Float(rgba[3])
    input += rgba.prefix(3).map { Float($0) * alpha } + [alpha]
}
let image = CIImage(bitmapData: input.withUnsafeBytes { Data($0) }, bytesPerRow: fixtures.count * 16,
                    size: extent.size, format: .RGBAf, colorSpace: space)
let source = try String(contentsOf: root.appendingPathComponent("candidate-v\(version).cikernel"), encoding: .utf8)
guard let kernel = CIColorKernel(source: source) else { fatalError("Candidate CI kernel compilation failed") }
var records: [[String: Any]] = []
for item in cases {
    guard let name = item["id"] as? String, let settings = item["value"] as? [String: Any],
          Set(settings.keys) == ["version", "bands"], settings["version"] as? Int == 1,
          let values = settings["bands"] as? [String: [String: Double]], Set(values.keys).isSubset(of: Set(bands)) else {
        fatalError("Invalid candidate settings")
    }
    var parameters = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 3)
    for (index, band) in bands.enumerated() {
        guard let value = values[band] else { continue }
        guard Set(value.keys) == ["hue", "saturation", "lightness"],
              value.values.allSatisfy({ $0.isFinite && (-100...100).contains($0) }),
              value.values.contains(where: { $0 != 0 }) else { fatalError("Invalid band parameters") }
        for (parameter, key) in ["hue", "saturation", "lightness"].enumerated() {
            parameters[parameter][index] = value[key]! / 100
        }
    }
    var arguments: [Any] = [image]
    for half in 0..<2 {
        for parameter in parameters {
            let p = Array(parameter[(half * 4)..<(half * 4 + 4)])
            arguments.append(CIVector(x: p[0], y: p[1], z: p[2], w: p[3]))
        }
    }
    // Neutral bypass preserves the actual historical graph exactly, including
    // any hidden RGB. It is not a round-trip through rounded OkLab matrices.
    let output: CIImage
    if values.isEmpty { output = image }
    else if let candidate = kernel.apply(extent: extent, arguments: arguments) { output = candidate }
    else { fatalError("Candidate CI kernel application failed") }
    var pixels = [Float](repeating: 0, count: input.count)
    pixels.withUnsafeMutableBytes {
        context.render(output, toBitmap: $0.baseAddress!, rowBytes: fixtures.count * 16,
                       bounds: extent, format: .RGBAf, colorSpace: space)
    }
    let encoded: [Any] = pixels.map { $0.isFinite ? Double($0) as Any : NSNull() }
    records.append(["settings": name, "pixels": encoded])
}
let result: [String: Any] = ["version": version, "backend": "Core Image native RGBAf (execution device unspecified)",
                           "os": ProcessInfo.processInfo.operatingSystemVersionString,
                           "fixtureCount": fixtures.count, "records": records]
try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
