import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import zlib

// Standalone synthetic preflight only. This is not a production artifact codec.
// Keep the earlier unmodified eight-case report as the historical ImageIO baseline.
enum ProbeFailure: Error { case failed(String) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProbeFailure.failed(message) }
}
func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
let maximumICCBytes = 1_048_576
let maximumPNGBytes = 8_388_608
let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
func crc(_ bytes: Data) -> UInt32 {
    var value: UInt32 = .max
    for byte in bytes {
        value ^= UInt32(byte)
        for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xedb8_8320) }
    }
    return ~value
}
func u32(_ bytes: Data, at offset: Int) -> UInt32 {
    bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}
func append32(_ value: UInt32, to bytes: inout Data) {
    bytes.append(UInt8(truncatingIfNeeded: value >> 24)); bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8)); bytes.append(UInt8(truncatingIfNeeded: value))
}
struct Chunk { let type: String; let body: Data }
func parse(_ png: Data) throws -> [Chunk] {
    try require(png.count <= maximumPNGBytes && png.starts(with: pngSignature), "PNG size/signature")
    var offset = 8; var chunks: [Chunk] = []
    while offset < png.count {
        try require(png.count - offset >= 12, "truncated PNG chunk")
        let count = Int(u32(png, at: offset))
        try require(count <= png.count - offset - 12, "chunk length exceeds bounded PNG")
        let name = png.subdata(in: offset + 4..<offset + 8)
        try require(name.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }, "chunk type")
        let body = png.subdata(in: offset + 8..<offset + 8 + count)
        try require(crc(name + body) == u32(png, at: offset + 8 + count), "chunk CRC")
        chunks.append(.init(type: String(decoding: name, as: UTF8.self), body: body))
        offset += count + 12
    }
    try require(chunks.first?.type == "IHDR" && chunks.first?.body.count == 13, "IHDR must be first")
    try require(chunks.filter { $0.type == "IHDR" }.count == 1, "duplicate IHDR")
    try require(chunks.last?.type == "IEND" && chunks.last?.body.isEmpty == true, "IEND must be last")
    try require(chunks.filter { $0.type == "IEND" }.count == 1 && chunks.contains { $0.type == "IDAT" }, "IDAT/IEND")
    return chunks
}
func append(_ chunk: Chunk, to png: inout Data) throws {
    try require(chunk.body.count <= maximumPNGBytes, "bounded chunk")
    let name = Data(chunk.type.utf8)
    try require(name.count == 4, "chunk name")
    append32(UInt32(chunk.body.count), to: &png)
    png.append(name); png.append(chunk.body); append32(crc(name + chunk.body), to: &png)
    try require(png.count <= maximumPNGBytes, "bounded encoded PNG")
}
func compressICC(_ icc: Data) throws -> Data {
    try require(!icc.isEmpty && icc.count <= maximumICCBytes, "bounded source ICC")
    let capacity = compressBound(uLong(icc.count))
    try require(capacity <= maximumICCBytes * 2, "bounded compressed ICC")
    var output = Data(count: Int(capacity)); var count = uLongf(capacity)
    let status = output.withUnsafeMutableBytes { target in
        icc.withUnsafeBytes { source in
            compress2(target.bindMemory(to: Bytef.self).baseAddress!, &count,
                      source.bindMemory(to: Bytef.self).baseAddress!, uLong(icc.count), Z_BEST_COMPRESSION)
        }
    }
    try require(status == Z_OK, "zlib ICC compression")
    output.count = Int(count); return output
}
func embeddedICC(_ chunks: [Chunk]) throws -> Data {
    let profile = chunks.filter { $0.type == "iCCP" }
    try require(profile.count == 1, "exactly one iCCP")
    let body = profile[0].body
    guard let nul = body.firstIndex(of: 0) else { throw ProbeFailure.failed("iCCP profile name") }
    try require((1...79).contains(nul) && nul + 2 < body.count && body[nul + 1] == 0, "iCCP name/method")
    let compressed = body.subdata(in: nul + 2..<body.count)
    var output = Data(count: maximumICCBytes); var count = uLongf(maximumICCBytes)
    let status = output.withUnsafeMutableBytes { target in
        compressed.withUnsafeBytes { source in
            uncompress(target.bindMemory(to: Bytef.self).baseAddress!, &count,
                       source.bindMemory(to: Bytef.self).baseAddress!, uLong(compressed.count))
        }
    }
    try require(status == Z_OK && count > 0 && count <= maximumICCBytes, "bounded ICC decompression")
    output.count = Int(count); return output
}
let conflictingColorChunks: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP"]
func explicitICC(_ source: Data, icc: Data) throws -> Data {
    let original = try parse(source)
    var profile = Data("PicEdit ICC".utf8); profile.append(0); profile.append(0)
    profile.append(try compressICC(icc))
    var result = pngSignature
    try append(original[0], to: &result)
    try append(.init(type: "iCCP", body: profile), to: &result)
    for chunk in original.dropFirst() where !conflictingColorChunks.contains(chunk.type) { try append(chunk, to: &result) }
    let checked = try parse(result)
    try require(checked[1].type == "iCCP", "ICC must precede PLTE/IDAT")
    try require(!checked.contains { ["sRGB", "gAMA", "cHRM", "cICP"].contains($0.type) }, "competing color metadata")
    let checkedICC = try embeddedICC(checked)
    try require(checkedICC == icc, "literal embedded ICC equality")
    return result
}

let run = URL(fileURLWithPath: "/private/tmp/picedit-artifact-explicit-icc-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
var reports: [[String: Any]] = []
for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
    for bits in [8, 16] {
        for hasAlpha in [false, true] {
            let label = "\(name)-\(bits)-\(hasAlpha ? "rgba" : "rgb")"
            let space = CGColorSpace(name: name)!
            guard let sourceICC = space.copyICCData() as Data? else { throw ProbeFailure.failed("source ICC") }
            let components = hasAlpha ? 4 : 3
            var samples = (0..<6 * components).map { UInt16(($0 * 3907 + 137) % 65536) }
            if hasAlpha { for i in 0..<6 { samples[i * 4 + 3] = [0, 16384, 32768, 49152, 65535, 255][i] } }
            var bytes = Data()
            for sample in samples {
                if bits == 8 { bytes.append(UInt8(sample >> 8)) }
                else { bytes.append(UInt8(truncatingIfNeeded: sample)); bytes.append(UInt8(sample >> 8)) }
            }
            var info = CGBitmapInfo(rawValue: (hasAlpha ? CGImageAlphaInfo.last : .none).rawValue)
            if bits == 16 { info.insert(.byteOrder16Little) }
            let image = CGImage(width: 3, height: 2, bitsPerComponent: bits, bitsPerPixel: bits * components,
                bytesPerRow: 3 * components * bits / 8, space: space, bitmapInfo: info,
                provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let originalURL = run.appendingPathComponent(label + "-imageio.png")
            let destination = CGImageDestinationCreateWithURL(originalURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
            try require(CGImageDestinationFinalize(destination), "ImageIO encode \(label)")
            let originalPNG = try Data(contentsOf: originalURL)
            let rewrittenPNG = try explicitICC(originalPNG, icc: sourceICC)
            let outputURL = run.appendingPathComponent(label + "-explicit-icc.png")
            try rewrittenPNG.write(to: outputURL, options: .withoutOverwriting)
            let source = CGImageSourceCreateWithURL(outputURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)!
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)!
            try require(decoded.width == 3 && decoded.height == 2 && decoded.bitsPerComponent == bits, "decoded geometry/depth")
            try require(hasAlpha ? decoded.alphaInfo == .last : [.none, .noneSkipLast].contains(decoded.alphaInfo), "straight alpha/layout")
            let order = decoded.bitmapInfo.intersection(.byteOrderMask)
            try require(bits == 16 || order == [], "known 8-bit channel order")
            let actual = decoded.dataProvider!.data! as Data
            let decodedComponents = decoded.bitsPerPixel / bits
            try require(decodedComponents >= components && actual.count >= decoded.bytesPerRow * 2, "decoded byte extent")
            var colorDifferences = 0; var alphaDifferences = 0; var transparentPixels = 0; var hiddenComponents = 0
            for y in 0..<2 { for x in 0..<3 {
                let pixel = y * 3 + x
                let expectedAlpha = hasAlpha ? (bits == 8 ? samples[pixel * 4 + 3] >> 8 : samples[pixel * 4 + 3]) : UInt16.max
                if hasAlpha && expectedAlpha == 0 { transparentPixels += 1 }
                for channel in 0..<components {
                    let offset = y * decoded.bytesPerRow + (x * decodedComponents + channel) * bits / 8
                    let got: UInt16
                    if bits == 8 { got = UInt16(actual[offset]) }
                    else if order == .byteOrder16Little { got = UInt16(actual[offset]) | (UInt16(actual[offset + 1]) << 8) }
                    else { got = (UInt16(actual[offset]) << 8) | UInt16(actual[offset + 1]) }
                    let expected = bits == 8 ? samples[pixel * components + channel] >> 8 : samples[pixel * components + channel]
                    if channel < 3 {
                        if got != expected { colorDifferences += 1 }
                        if hasAlpha && expectedAlpha == 0 && expected != 0 { hiddenComponents += 1 }
                    } else if got != expected { alphaDifferences += 1 }
                }
            } }
            guard let decodedICC = decoded.colorSpace?.copyICCData() as Data? else { throw ProbeFailure.failed("decoded ICC") }
            let chunks = try parse(rewrittenPNG)
            let literalICC = try embeddedICC(chunks)
            try require(colorDifferences == 0 && alphaDifferences == 0, "exact RGB/alpha samples \(label)")
            try require(literalICC == sourceICC && decodedICC == sourceICC, "exact physical/decoded ICC \(label)")
            try require(!hasAlpha || (transparentPixels > 0 && hiddenComponents > 0), "transparent hidden RGB fixture")
            let header = chunks[0].body
            try require(u32(header, at: 0) == 3 && u32(header, at: 4) == 2 && header[8] == bits && header[9] == (hasAlpha ? 6 : 2), "PNG IHDR")
            reports.append(["case": label, "width": 3, "height": 2, "bits": bits,
                "requestedChannels": components, "decodedBitsPerPixel": decoded.bitsPerPixel, "decodedAlpha": decoded.alphaInfo.rawValue,
                "decodedByteOrder": order.rawValue, "decodedBytesPerRow": decoded.bytesPerRow,
                "colorSampleDifferences": colorDifferences, "alphaSampleDifferences": alphaDifferences,
                "transparentPixelsChecked": transparentPixels, "nonzeroHiddenRGBComponentsChecked": hiddenComponents,
                "sourceICC": sha(sourceICC), "literalEmbeddedICC": sha(literalICC), "decodedICC": sha(decodedICC),
                "iccBytes": sourceICC.count, "pngBytes": rewrittenPNG.count, "pngSHA256": sha(rewrittenPNG),
                "originalImageIOSHA256": sha(originalPNG), "pngChunks": chunks.map(\.type),
                "removedOriginalChunks": try parse(originalPNG).filter { conflictingColorChunks.contains($0.type) }.map(\.type)])
            print(label, "RGB differences", colorDifferences, "alpha differences", alphaDifferences,
                  "literal/decoded ICC equal", literalICC == sourceICC && decodedICC == sourceICC,
                  "hidden RGB components checked", hiddenComponents)
        }
    }
}
try require(reports.count == 8 && Set(reports.compactMap { $0["case"] as? String }).count == 8, "all eight unique cases")
let report: [String: Any] = ["status": "PASS", "scope": "Standalone synthetic 3x2 literal-iCCP PNG preflight only; no product storage/backup/memory claim.",
    "iccPolicy": "Replace ImageIO profile metadata with exactly one iCCP immediately after IHDR; remove previous iCCP, sRGB, gAMA, cHRM and cICP. Source ICC bytes remain exact.",
    "maximumICCBytes": maximumICCBytes, "maximumPNGBytes": maximumPNGBytes,
    "zlibCompileVersion": ZLIB_VERSION, "zlibRuntimeVersion": String(cString: zlibVersion()),
    "cases": reports]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: run.appendingPathComponent("report.json"), options: .withoutOverwriting)
print("PASS: 8 cases, exact straight RGB/alpha/hidden-RGB and literal/decoded ICC; Results:", run.path)
