import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PicEditCore
import UniformTypeIdentifiers

/// Replays immutable, genuinely inferred historical outputs through today's
/// product compositor. This is a compositor regression/quality inspection;
/// neither inference timing nor model support is inferred from a replay.
enum ImageGenerationReplay {
    struct CaseReport: Codable, Sendable {
        let caseID: String
        let width: Int
        let height: Int
        let inputFileSHA256: [String: String]
        let normalizedSourceRGBA8SHA256: String
        let normalizedCandidateRGBA8SHA256: String
        let finalRGBA8SHA256: String
        let finalPNGFileSHA256: String
        let maskCanonicalSHA256: String
        let outsidePixelsChecked: Int
        let outsideRGBABytesChanged: Int
        let sourceAlphaBytesChanged: Int
        let nativeROIPixelsChecked: Int?
        let nativeROIRGBABytesChanged: Int?
        let outputProfile: String
        let outputAlpha: String
        let pngRoundTripIdentical: Bool
        let alphaPolicy: String
        let comparisonFile: String
        let qualitativeReview: String
    }

    struct Report: Codable, Sendable {
        let schemaVersion: Int
        let createdAt: String
        let purpose: String
        let inference: String
        let compositor: String
        let compositorSourceSHA256: String
        let compositorParameters: [String: String]
        let normalization: String
        let cases: [CaseReport]
        let qualitativeReview: String
    }

    enum Failure: LocalizedError {
        case invalidInput(String), preservationFailed(String), outputChangedOnPNGWrite(String)
        var errorDescription: String? {
            switch self {
            case .invalidInput(let detail): return "Ungültige Replay-Eingabe: \(detail)"
            case .preservationFailed(let detail): return "Replay verletzt die native Erhaltung: \(detail)"
            case .outputChangedOnPNGWrite(let detail): return "Replay-PNG verändert die kanonischen Pixel: \(detail)"
            }
        }
    }

    static let distinctCaseIDs = ["01-structured-removal-hard", "02-edge-object-hard", "03-mask-edge-hard",
        "03-mask-edge-soft", "04-partial-alpha-hard", "05-fine-motif-edges-hard", "06-nonsquare-canvas-hard"]

    @discardableResult
    static func run(historicalRoot: URL, outputRoot: URL, caseIDs: [String] = distinctCaseIDs) async throws -> Report {
        let historical = historicalRoot.standardizedFileURL, output = outputRoot.standardizedFileURL
        guard historical.isFileURL, output.isFileURL, historical.path != output.path,
              !output.path.hasPrefix(historical.path + "/"), !historical.path.hasPrefix(output.path + "/") else {
            throw Failure.invalidInput("Historical and replay output directories must be separate")
        }
        guard !caseIDs.isEmpty, caseIDs.count <= 32, Set(caseIDs).count == caseIDs.count,
              caseIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              } }) else { throw Failure.invalidInput("case identifiers") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 134_217_728))
        var reports: [CaseReport] = []
        // The single admitted codec lane deliberately serializes these small
        // replays. Concurrent 512px composites would only compete for that lane
        // and unnecessarily multiply native decode/comparison allocations.
        for id in caseIDs {
            try Task.checkCancellation()
            let archived = historical.appendingPathComponent("artifacts/\(id)", isDirectory: true)
            let destination = output.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var files: [String: String] = [:]
            for file in ["source.png", "raw.png", "replace-mask.png"] {
                let bytes = try boundedFile(archived.appendingPathComponent(file))
                files[file] = sha256(bytes)
                try bytes.write(to: destination.appendingPathComponent(file), options: .atomic)
            }
            let source = try loadCanonicalRGBA8(archived.appendingPathComponent("source.png"))
            let raw = try loadCanonicalRGBA8(archived.appendingPathComponent("raw.png"))
            let mask = try loadGrayMask(archived.appendingPathComponent("replace-mask.png"))
            guard source.image.width == mask.size.width, source.image.height == mask.size.height,
                  raw.image.width == mask.size.width, raw.image.height == mask.size.height else {
                throw Failure.invalidInput("\(id): source/raw/mask dimensions differ")
            }
            let original = try rgba8Bytes(source.image), rawPixels = try rgba8Bytes(raw.image)
            // Historical fixture 04 explicitly declares preserve-source-alpha;
            // inference receives white-matted RGB. Reconstruct that declared
            // candidate alpha before using the unchanged current compositor.
            let partialAlpha = id == "04-partial-alpha-hard"
            let candidate = partialAlpha ? try replacingAlpha(of: raw, from: source) : raw
            let candidatePixels = try rgba8Bytes(candidate.image)
            let final = try await MaskCompositor.compose(base: source, candidate: candidate, mask: mask,
                                                        resources: resources, backend: .cpu)
            let result = try rgba8Bytes(final.image)
            var outsidePixels = 0, outsideBytesChanged = 0, alphaChanged = 0
            for pixel in 0..<mask.bytes.count {
                if pixel.isMultiple(of: 8_192) { try Task.checkCancellation() }
                let start = pixel * 4
                if result[start + 3] != original[start + 3] { alphaChanged += 1 }
                if mask.bytes[pixel] == 0 {
                    outsidePixels += 1
                    for channel in 0..<4 where result[start + channel] != original[start + channel] { outsideBytesChanged += 1 }
                }
            }
            guard outsideBytesChanged == 0, !partialAlpha || alphaChanged == 0 else {
                throw Failure.preservationFailed("\(id): outside RGBA changes=\(outsideBytesChanged), alpha changes=\(alphaChanged)")
            }
            var roiPixels: Int?, roiChanges: Int?
            if id == "06-nonsquare-canvas-hard" {
                let native = try loadCanonicalRGBA8(historical.appendingPathComponent("fixtures/06-canvas-original.png"))
                let expected = try rgba8Bytes(native.image)
                guard native.image.width == 384, native.image.height == 256, mask.size.width == 640, mask.size.height == 384 else {
                    throw Failure.invalidInput("native ROI expected 384x256 translated to x128/y64 on 640x384 canvas")
                }
                var changes = 0
                for y in 0..<256 { for x in 0..<384 {
                    let nativeStart = (y * 384 + x) * 4, pixel = (y + 64) * 640 + x + 128
                    guard mask.bytes[pixel] == 0 else { throw Failure.invalidInput("native ROI is not a preserve mask") }
                    for channel in 0..<4 where result[pixel * 4 + channel] != expected[nativeStart + channel] { changes += 1 }
                } }
                guard changes == 0 else { throw Failure.preservationFailed("\(id): native ROI changed \(changes) RGBA bytes") }
                roiPixels = 384 * 256; roiChanges = changes
            }
            let finalURL = destination.appendingPathComponent("current-final.png")
            try writePNG(final.image, to: finalURL)
            let roundTrip = try loadCanonicalRGBA8(finalURL)
            guard try rgba8Bytes(roundTrip.image) == result else { throw Failure.outputChangedOnPNGWrite(id) }
            guard final.image.colorSpace?.copyICCData() == source.image.colorSpace?.copyICCData(),
                  final.image.bitsPerComponent == 8, final.image.alphaInfo == .last else {
                throw Failure.preservationFailed("\(id): output profile, bit depth or straight alpha differs")
            }
            let comparisonName = "\(id)/current-comparison.png"
            try writePNG(comparison(source: source.image, raw: raw.image, mask: mask, final: final.image, title: id),
                         to: output.appendingPathComponent(comparisonName))
            // Include the actual interpreted candidate for alpha-policy audits;
            // the copied raw.png above remains the original model output.
            if partialAlpha { try writePNG(candidate.image, to: destination.appendingPathComponent("candidate-source-alpha.png")) }
            reports.append(CaseReport(caseID: id, width: mask.size.width, height: mask.size.height,
                inputFileSHA256: files, normalizedSourceRGBA8SHA256: sha256(original),
                normalizedCandidateRGBA8SHA256: sha256(candidatePixels), finalRGBA8SHA256: sha256(result),
                finalPNGFileSHA256: try sha256(boundedFile(finalURL)), maskCanonicalSHA256: try mask.canonicalSHA256().sha256,
                outsidePixelsChecked: outsidePixels, outsideRGBABytesChanged: outsideBytesChanged,
                sourceAlphaBytesChanged: alphaChanged, nativeROIPixelsChecked: roiPixels, nativeROIRGBABytesChanged: roiChanges,
                outputProfile: "sRGB", outputAlpha: "straight RGBA8", pngRoundTripIdentical: true,
                alphaPolicy: partialAlpha ? "Historical fixture policy: source alpha copied onto the white-matted RGB model candidate before composition" : "Model candidate alpha (opaque RGB input/output)",
                comparisonFile: comparisonName, qualitativeReview: "pending-manual-review-current-compositor"))
            withExtendedLifetime((rawPixels, final, candidate, source, raw)) {}
        }
        let compositorURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Imaging/MaskCompositor.swift")
        let report = Report(schemaVersion: 1, createdAt: ISO8601DateFormatter().string(from: Date()),
            purpose: "Current product compositor replay of existing real-model outputs; original generation times kept separately; manual quality judgment required",
            inference: "No inference performed by replay; raw.png bytes copied unchanged from the supplied artifacts root",
            compositor: "MaskCompositor.compose backend=.cpu", compositorSourceSHA256: try sha256(boundedFile(compositorURL)),
            compositorParameters: ["mask": "Original Gray8; zero preserves, 255 replaces; no threshold or feather changes",
                "blending": "Current linear-light, premultiplied-alpha product compositor; straight RGBA8 sRGB output",
                "geometry": "Native dimensions; no resize, crop, orientation transform or context-color correction",
                "outsidePreservation": "Every canonical RGBA byte at mask=0 must equal canonical source exactly"],
            normalization: "ImageIO decode; row padding/unused lanes removed; RGB sources receive alpha=255; declared historical untagged values interpreted as sRGB; encoded channels are not color-converted; premultiplied decode buffers are explicitly unassociated",
            cases: reports, qualitativeReview: "pending-manual-review-current-compositor; replay does not grant a backend capability")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output.appendingPathComponent("current-compositor-report.json"), options: .atomic)
        return report
    }

    /// Decodes native model/fixture PNGs without CGContext redraw or resize.
    /// Untagged PNG values require the caller's explicit sRGB input contract.
    static func loadCanonicalRGBA8(_ url: URL, declaredUntaggedSRGB: Bool = true) throws -> ArtifactRasterInput {
        let file = try boundedFile(url)
        guard let imageSource = CGImageSourceCreateWithData(file as CFData, nil),
              CGImageSourceGetCount(imageSource) == 1,
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.bitsPerComponent == 8, !image.bitmapInfo.contains(.floatComponents), image.decode == nil,
              image.colorSpace?.model == .rgb else { throw Failure.invalidInput("RGBA8 decode \(url.lastPathComponent)") }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 {
            throw Failure.invalidInput("input orientation must already be up")
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let hasExplicitProfile = try pngHasColorProfile(file)
        if hasExplicitProfile {
            guard image.colorSpace?.copyICCData() == space.copyICCData() else {
                throw Failure.invalidInput("tagged input is not canonical sRGB")
            }
        } else if !declaredUntaggedSRGB { throw Failure.invalidInput("untagged PNG has no declared sRGB interpretation") }
        let size = try ArtifactPixelSize(width: image.width, height: image.height)
        let channels = image.bitsPerPixel / 8
        let first = [.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
        let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        let premultiplied = [.premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard [3, 4].contains(channels), image.bitsPerPixel == channels * 8,
              [.none, .noneSkipFirst, .noneSkipLast, .first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo),
              channels == 4 || image.alphaInfo == .none,
              order == [] || order == .byteOrder32Big || (channels == 4 && order == .byteOrder32Little),
              image.bytesPerRow >= size.width * channels, image.bytesPerRow <= 134_217_728 / size.height,
              let provided = image.dataProvider?.data else { throw Failure.invalidInput("unsupported native PNG lanes") }
        let bytes = provided as Data
        guard bytes.count >= image.bytesPerRow * size.height else { throw Failure.invalidInput("truncated native raster") }
        var packed = Data(count: size.width * size.height * 4)
        for y in 0..<size.height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            for x in 0..<size.width {
                let start = y * image.bytesPerRow + x * channels, destination = (y * size.width + x) * 4
                func sample(_ logical: Int) -> UInt8 { bytes[start + (order == .byteOrder32Little ? 3 - logical : logical)] }
                let a = alpha ? sample(first ? 0 : 3) : 255, offset = first ? 1 : 0
                for c in 0..<3 {
                    let encoded = sample(c + offset)
                    packed[destination + c] = premultiplied
                        ? (a > 0 ? UInt8(min(255, (Double(encoded) * 255 / Double(a)).rounded())) : 0) : encoded
                }
                packed[destination + 3] = a
            }
        }
        return .init(immutableImage: try rgba8Image(size: size, bytes: packed))
    }

    static func loadGrayMask(_ url: URL) throws -> MaskRaster {
        guard let source = CGImageSourceCreateWithData(try boundedFile(url) as CFData, nil),
              CGImageSourceGetCount(source) == 1, let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerComponent == 8, image.bitsPerPixel == 8, image.alphaInfo == .none,
              image.colorSpace?.model == .monochrome, let data = image.dataProvider?.data else {
            throw Failure.invalidInput("mask must be canonical native Gray8")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 {
            throw Failure.invalidInput("mask orientation must already be up")
        }
        let size = try ArtifactPixelSize(width: image.width, height: image.height)
        let bytes = data as Data
        guard image.bytesPerRow >= size.width, image.bytesPerRow <= 134_217_728 / size.height,
              bytes.count >= image.bytesPerRow * size.height else { throw Failure.invalidInput("truncated mask") }
        var packed = Data(capacity: size.width * size.height)
        for y in 0..<size.height { packed.append(bytes[y * image.bytesPerRow..<y * image.bytesPerRow + size.width]) }
        return try MaskRaster(size: size, bytes: packed)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.invalidInput("PNG output destination")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidInput("PNG output write") }
    }

    static func rgba8Bytes(_ image: CGImage) throws -> Data {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .last,
              image.bytesPerRow >= image.width * 4, let source = image.dataProvider?.data else {
            throw Failure.invalidInput("expected canonical straight RGBA8")
        }
        let bytes = source as Data
        guard image.bytesPerRow <= 134_217_728 / image.height, bytes.count >= image.bytesPerRow * image.height else {
            throw Failure.invalidInput("truncated canonical raster")
        }
        var packed = Data(capacity: image.width * image.height * 4)
        for y in 0..<image.height { packed.append(bytes[y * image.bytesPerRow..<y * image.bytesPerRow + image.width * 4]) }
        return packed
    }

    static func rgba8Image(size: ArtifactPixelSize, bytes: Data) throws -> CGImage {
        guard bytes.count == size.width * size.height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size.width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.invalidInput("canonical RGBA8 creation")
        }
        return image
    }

    private static func replacingAlpha(of candidate: ArtifactRasterInput, from source: ArtifactRasterInput) throws -> ArtifactRasterInput {
        var target = try rgba8Bytes(candidate.image)
        let alpha = try rgba8Bytes(source.image)
        guard target.count == alpha.count else { throw Failure.invalidInput("candidate/source alpha geometry") }
        for offset in stride(from: 3, to: target.count, by: 4) { target[offset] = alpha[offset] }
        return .init(immutableImage: try rgba8Image(size: .init(width: candidate.image.width, height: candidate.image.height), bytes: target))
    }

    private static func comparison(source: CGImage, raw: CGImage, mask: MaskRaster, final: CGImage, title: String) throws -> CGImage {
        let width = source.width, height = source.height, banner = 54, gap = 8, totalWidth = width * 4 + gap * 3
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: totalWidth,
            height: height + banner, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let provider = CGDataProvider(data: mask.bytes as CFData),
              let maskImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.invalidInput("comparison canvas") }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: height + banner))
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for (index, item) in [source, raw, maskImage, final].enumerated() {
            let x = index * (width + gap)
            for row in stride(from: 0, to: height, by: 16) { for col in stride(from: 0, to: width, by: 16) {
                context.setFillColor(CGColor(gray: (row / 16 + col / 16).isMultiple(of: 2) ? 0.8 : 0.6, alpha: 1))
                context.fill(CGRect(x: x + col, y: row, width: min(16, width - col), height: min(16, height - row)))
            } }
            context.interpolationQuality = .none
            context.draw(item, in: CGRect(x: x, y: 0, width: width, height: height))
            let label = ["Source", "Real model raw", "Native Gray8 replacement mask", "Current MaskCompositor.cpu"][index]
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes) as CFAttributedString)
            context.textPosition = CGPoint(x: x + 8, y: height + 30); CTLineDraw(line, context)
            let smallFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            var small = attributes; small[NSAttributedString.Key(kCTFontAttributeName as String)] = smallFont
            let subtitle = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: small) as CFAttributedString)
            context.textPosition = CGPoint(x: x + 8, y: height + 11); CTLineDraw(subtitle, context)
        }
        guard let image = context.makeImage() else { throw Failure.invalidInput("comparison output") }
        return image
    }

    private static func boundedFile(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = (attributes[.size] as? NSNumber)?.intValue, bytes > 0, bytes <= 33_554_432,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalidInput("file size/type \(url.path)") }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
    private static func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func pngHasColorProfile(_ bytes: Data) throws -> Bool {
        guard bytes.count >= 20, bytes.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw Failure.invalidInput("PNG signature")
        }
        var offset = 8, tagged = false
        while offset <= bytes.count - 12 {
            let size = bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard Int(size) <= bytes.count - offset - 12 else { throw Failure.invalidInput("PNG chunk size") }
            let name = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            if name == "iCCP" || name == "sRGB" { tagged = true }
            offset += Int(size) + 12
            if name == "IEND" { return tagged }
        }
        throw Failure.invalidInput("PNG terminator")
    }
}
