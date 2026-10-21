import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

// Synthetic preflight for Issue 10. No original files or personal catalog.
let run = URL(fileURLWithPath: "/private/tmp/glowroom-artifact-codec-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
var reports: [[String: Any]] = []
for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
    for bits in [8, 16] {
        for alpha in [false, true] {
            let space = CGColorSpace(name: name)!
            let components = alpha ? 4 : 3
            let count = 3 * 2 * components
            var samples = (0..<count).map { UInt16(($0 * 3907 + 137) % 65536) }
            if alpha { for i in 0..<6 { samples[i * 4 + 3] = [0, 16384, 32768, 49152, 65535, 255][i] } }
            var bytes = Data()
            for value in samples {
                if bits == 8 { bytes.append(UInt8(value >> 8)) }
                else { bytes.append(UInt8(value & 255)); bytes.append(UInt8(value >> 8)) }
            }
            let alphaInfo: CGImageAlphaInfo = alpha ? .last : .none
            var info = CGBitmapInfo(rawValue: alphaInfo.rawValue)
            if bits == 16 { info.insert(.byteOrder16Little) }
            let image = CGImage(width: 3, height: 2, bitsPerComponent: bits,
                bitsPerPixel: bits * components, bytesPerRow: 3 * components * bits / 8,
                space: space, bitmapInfo: info, provider: CGDataProvider(data: bytes as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let label = "\(name)-\(bits)-\(alpha ? "rgba" : "rgb")"
            let file = run.appendingPathComponent(label + ".png")
            let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { fatalError("encode: \(label)") }
            let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)!
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
            let actual = decoded.dataProvider!.data! as Data
            let decodedComponents = decoded.bitsPerPixel / decoded.bitsPerComponent
            let order = decoded.bitmapInfo.intersection(.byteOrderMask)
            var differences = 0
            for y in 0..<2 { for x in 0..<3 { for channel in 0..<components {
                let index = y * decoded.bytesPerRow + (x * decodedComponents + channel) * bits / 8
                let got: UInt16
                if bits == 8 { got = UInt16(actual[index]) }
                else if order == .byteOrder16Little { got = UInt16(actual[index]) | (UInt16(actual[index + 1]) << 8) }
                else { got = (UInt16(actual[index]) << 8) | UInt16(actual[index + 1]) }
                let expected = samples[(y * 3 + x) * components + channel]
                if got != (bits == 8 ? expected >> 8 : expected) { differences += 1 }
            } } }
            func icc(_ value: CGColorSpace?) -> String? {
                guard let data = value?.copyICCData() else { return nil }
                return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
            }
            let report: [String: Any] = ["case": label, "bits": decoded.bitsPerComponent,
                "bitsPerPixel": decoded.bitsPerPixel, "bytesPerRow": decoded.bytesPerRow,
                "alpha": decoded.alphaInfo.rawValue, "byteOrder": order.rawValue,
                "sampleDifferences": differences, "sourceICC": icc(space) ?? "missing",
                "decodedICC": icc(decoded.colorSpace) ?? "missing",
                "profileName": properties[kCGImagePropertyProfileName] ?? "missing",
                "pngDepth": properties[kCGImagePropertyDepth] ?? "missing"]
            reports.append(report)
            print(label, "depth", decoded.bitsPerComponent, "alpha", decoded.alphaInfo.rawValue,
                "differences", differences, "ICC equal", icc(space) == icc(decoded.colorSpace))
        }
    }
}
let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
try data.write(to: run.appendingPathComponent("report.json"), options: .withoutOverwriting)
print("Results:", run.path)

let passed = reports.allSatisfy { ($0["sampleDifferences"] as? Int) == 0 && ($0["sourceICC"] as? String) == ($0["decodedICC"] as? String) && ($0["sourceICC"] as? String) != "missing" }
if !passed { exit(1) }
