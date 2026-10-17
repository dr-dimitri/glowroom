import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PicEditCore
import UniformTypeIdentifiers

/// Self-authored procedural contract fixtures, not model-quality evidence. A
/// successful write produces inputs and masks only; it never invents a model
/// result or marks an operation supported. No weights or network are required.
enum ImageGenerationFixtures {
    struct Fixture: Sendable {
        let id: String
        let title: String
        let prompt: String
        let operation: String
        let input: ArtifactRasterInput
        let rgba: Data
        let mask: FrozenGenerationMask
        /// Non-nil for the padded outpainting input; the rest is transparent.
        let preservedContent: ArtifactPixelRect?

        func request(sourceURL: URL? = nil) throws -> GenerationRequest {
            let identity = mask.binding.resourceID.rawValue
            let snapshot = AIEditingSnapshot(assetID: "image-generation-fixture/\(id)",
                source: .original(.init(fileURL: sourceURL ?? URL(fileURLWithPath: "/picedit-contract-fixtures/\(id)/input.png"),
                    modifiedAt: Date(timeIntervalSince1970: 0), fileSize: Int64(rgba.count))), settings: .neutral,
                token: .init(editSessionID: identity, editGeneration: 1, selectionSessionID: identity, selectionGeneration: 1))
            return try GenerationRequest(id: identity, snapshot: snapshot, immutableInput: input, mask: mask,
                                         pipelineVersion: ImageGenerationPreprocessing.version)
        }
    }

    struct Descriptor: Codable, Sendable {
        let schemaVersion: Int
        let fixtureID: String
        let title: String
        let authorship: String
        let purpose: String
        let operation: String
        let prompt: String
        let seed: UInt64
        let steps: Int
        let guidanceScale: Double
        let inputFile: String
        let replacementMaskFile: String
        let maskDocumentFile: String
        let inputRGBA8SHA256: String
        let maskCanonicalSHA256: String
        let inputFormat: String
        let maskConvention: String
        let transform: MaskRasterTransform
        let preservedContent: ArtifactPixelRect?
        let modelResultFile: String?
    }

    /// Six tiny independent inputs can be called from a bounded background
    /// worker. Their total native allocation is below 1 MiB; dispatching a worker
    /// pool per image would cost more than the simple deterministic pixel loops.
    static func make() throws -> [Fixture] {
        try (0..<6).map(makeFixture)
    }

    @discardableResult
    static func write(to directory: URL) throws -> [Descriptor] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let descriptors = try make().map { fixture in
            try Task.checkCancellation()
            let folder = directory.appendingPathComponent(fixture.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writePNG(fixture.input.image, to: folder.appendingPathComponent("input.png"))
            try writePNG(fixture.mask.artifactInput().image, to: folder.appendingPathComponent("replace-mask.png"))
            try fixture.mask.document.canonicalData().write(to: folder.appendingPathComponent("mask.json"), options: .atomic)
            let descriptor = try descriptor(fixture)
            try encoder.encode(descriptor).write(to: folder.appendingPathComponent("fixture.json"), options: .atomic)
            return descriptor
        }
        try encoder.encode(descriptors).write(to: directory.appendingPathComponent("fixtures.json"), options: .atomic)
        return descriptors
    }

    static func descriptor(_ fixture: Fixture) throws -> Descriptor {
        Descriptor(schemaVersion: 1, fixtureID: fixture.id, title: fixture.title,
            authorship: "PicEdit procedural source, repository license; no external photographs",
            purpose: "Deterministic contract/geometry input only; no generated model result or capability evidence",
            operation: fixture.operation, prompt: fixture.prompt, seed: 42, steps: 20, guidanceScale: 7.5,
            inputFile: "\(fixture.id)/input.png", replacementMaskFile: "\(fixture.id)/replace-mask.png",
            maskDocumentFile: "\(fixture.id)/mask.json", inputRGBA8SHA256: digest(fixture.rgba),
            maskCanonicalSHA256: try fixture.mask.raster.canonicalSHA256().sha256,
            inputFormat: "RGBA8, straight alpha, sRGB, orientation up, top-left rows",
            maskConvention: "Gray8: 0 preserves native source; 255 authorizes replacement; top-left rows",
            transform: fixture.mask.binding.transform, preservedContent: fixture.preservedContent, modelResultFile: nil)
    }

    /// An asymmetric coordinate grid is deliberately independent of a model:
    /// red = x * 16, green = y * 16, blue = (x * 7 + y * 11) modulo 256. It makes an axis
    /// swap, vertical flip, offset crop or a one-pixel error immediately visible.
    static func goldenGrid(size: ArtifactPixelSize) throws -> ArtifactRasterInput {
        guard size.width <= 16, size.height <= 16 else { throw ArtifactContractError.limitExceeded }
        var bytes = Data(capacity: size.width * size.height * 4)
        for y in 0..<size.height { for x in 0..<size.width {
            bytes.append(contentsOf: [UInt8(x * 16), UInt8(y * 16), UInt8((x * 7 + y * 11) % 256), 255])
        } }
        return .init(immutableImage: try image(size: size, rgba: bytes))
    }

    private static func makeFixture(_ index: Int) throws -> Fixture {
        let ids = ["structured-background", "edge-object", "hard-soft-edge", "half-transparent", "fine-foreground", "non-square-outpaint"]
        let titles = ["Remove object on a brick/checker background", "Remove an object touching the left edge",
            "Two objects with hard and soft replacement edges", "Partly transparent source with hidden RGB",
            "Replace a background around thin foreground strands", "Extend a padded non-square canvas"]
        let prompts = ["Remove the red disk and continue the brick pattern.", "Remove the red disk at the left edge and continue the pattern.",
            "Replace the two colored disks with matching background.", "Remove the red disk while preserving the source transparency outside the mask.",
            "Replace the blue background with green while preserving the fine yellow foreground strands.",
            "Extend the existing brick pattern into the transparent padded canvas, retaining the center unchanged."]
        let size = try ArtifactPixelSize(width: index == 5 ? 240 : 192, height: index == 5 ? 160 : 128)
        let modelSize = try ArtifactPixelSize(width: size.width / 2, height: size.height / 2)
        var bytes = Data(count: size.width * size.height * 4)
        let centerX = index == 1 ? 2 : 92, centerY = 64
        let preserved = index == 5 ? try ArtifactPixelRect(x: 40, y: 40, size: .init(width: 160, height: 80)) : nil
        for y in 0..<size.height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            for x in 0..<size.width {
                let mortar = y.isMultiple(of: 16) || ((x + ((y / 16).isMultiple(of: 2) ? 16 : 0)) % 32 == 0)
                let shade = UInt8(145 + ((x * 3 + y * 5) % 35))
                var pixel: [UInt8] = mortar ? [75, 80, 88, 255] : [shade, shade / 2 + 20, 70, 255]
                let dx = x - centerX, dy = y - centerY
                if index < 2 || index == 3, dx * dx + dy * dy <= 18 * 18 { pixel = [225, 32, 45, 255] }
                if index == 2 {
                    for (cx, color) in [(56, [UInt8(230), 50, 30, 255]), (136, [UInt8(30), 215, 60, 255])] {
                        let ox = x - cx
                        if ox * ox + dy * dy <= 16 * 16 { pixel = color }
                    }
                }
                if index == 3 {
                    pixel[3] = ((x / 16 + y / 16) % 3 == 0) ? 0 : 128
                }
                if index == 4 {
                    pixel = [35, UInt8(80 + y / 2), 190, 255]
                    if isForeground(x, y) { pixel = [245, 218, 55, 255] }
                }
                if let preserved, !(preserved.x..<preserved.x + preserved.size.width).contains(x)
                    || !(preserved.y..<preserved.y + preserved.size.height).contains(y) {
                    pixel = [0, 0, 0, 0]
                }
                bytes.replaceSubrange((y * size.width + x) * 4..<(y * size.width + x) * 4 + 4, with: pixel)
            }
        }
        let document: MaskDocument
        if index == 4 {
            var erasers: [MaskStroke] = []
            // One ordered run per row faithfully protects the fine foreground;
            // strokes are not independently composited in parallel.
            for y in 0..<size.height {
                var runStart: Int?
                for x in 0...size.width {
                    if x < size.width, isForeground(x, y) { if runStart == nil { runStart = x } }
                    else if let start = runStart {
                        erasers.append(try stroke(x: Double(start) + 0.5, y: Double(y) + 0.5,
                            endX: Double(x) - 0.5, radius: 0.5, mode: .erase)); runStart = nil
                    }
                }
            }
            document = try .init(canvasSize: size, strokes: erasers, isInverted: true)
        } else if let preserved {
            let erasers = try (preserved.y..<preserved.y + preserved.size.height).map { y in
                try stroke(x: Double(preserved.x) + 0.5, y: Double(y) + 0.5,
                    endX: Double(preserved.x + preserved.size.width) - 0.5, radius: 0.5, mode: .erase)
            }
            document = try .init(canvasSize: size, strokes: erasers, isInverted: true)
        } else {
            let strokes = index == 2
                ? try [stroke(x: 56, y: 64, radius: 23), stroke(x: 136, y: 64, radius: 27, hardness: 0.35)]
                : try [stroke(x: Double(centerX), y: Double(centerY), radius: 25, hardness: index == 3 ? 0.5 : 1)]
            document = try .init(canvasSize: size, strokes: strokes)
        }
        let identity = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
        return Fixture(id: ids[index], title: titles[index], prompt: prompts[index],
            operation: index == 5 ? "outpaint" : index == 4 ? "backgroundEdit" : "inpaint",
            input: .init(immutableImage: try image(size: size, rgba: bytes)), rgba: bytes,
            mask: try .capture(document: document, modelSize: modelSize, resourceID: .init(rawValue: identity)),
            preservedContent: preserved)
    }

    private static func isForeground(_ x: Int, _ y: Int) -> Bool {
        let body = (78...113).contains(x) && (46...98).contains(y)
        let stem = (95...97).contains(x) && (20...114).contains(y)
        let diagonal = (20...110).contains(y) && abs(x - (y + 36)) <= 1
        let otherDiagonal = (22...105).contains(y) && abs(x - (150 - y)) <= 1
        return body || stem || diagonal || otherDiagonal
    }
    private static func stroke(x: Double, y: Double, endX: Double? = nil, radius: Double,
                               hardness: Double = 1, mode: MaskStrokeMode = .brush) throws -> MaskStroke {
        let a = try MaskPoint(x: x, y: y)
        let points = try endX.map { [a, try MaskPoint(x: $0, y: y)] } ?? [a]
        return try .init(points: points,
                         radius: radius, hardness: hardness, mode: mode)
    }
    private static func image(size: ArtifactPixelSize, rgba: Data) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size.width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ArtifactContractError.unsupportedFormat
        }
        return image
    }
    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ArtifactContractError.unsupportedFormat
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ArtifactContractError.corruptArtifact }
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
