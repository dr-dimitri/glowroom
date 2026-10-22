import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

@Suite("True grayscale source rendering", .serialized)
struct GrayscaleSourceRenderingTests {
    @Test(arguments: ["png", "tiff"])
    func whiteBalancePreviewMatchesTheActualJPEGExporter(ext: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try grayscaleFile(in: directory, ext: ext)
        let source = try decode(url)
        #expect(source.image.colorSpace?.model == .monochrome)
        let settings = EditSettings(developColor: .init(temperature: 9_000, tint: 70))
        let preview = try EditRenderer.render(source, settings: settings)
        let target = directory.appendingPathComponent("warm.jpg")
        _ = try await JPEGExporter().export(.init(sourceURL: url, destinationURL: target,
            settings: settings, options: .init(quality: 100)))
        let outputSource = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
        let exported = try #require(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        let actual = try pixel(preview.image), expected = try pixel(exported)
        #expect(abs(expected[0] - expected[1]) > 0.05, "The source and edits must produce visible color")
        #expect(preview.image.colorSpace?.model == .rgb)
        for channel in 0..<3 {
            // Includes the export's 8-bit quantization and JPEG color encoding.
            #expect(abs(actual[channel] - expected[channel]) < 0.02,
                "Grayscale-source edits must agree in extended linear sRGB")
        }
    }

    @Test(arguments: [8, 16], [false, true])
    func sourcePrecisionAlphaAndRenderModesSurvive(bits: Int, alpha: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for ext in ["png", "tiff"] {
            let source = try decode(grayscaleFile(in: directory, ext: ext, bits: bits, alpha: alpha))
            #expect(source.image.colorSpace?.model == .monochrome)
            #expect(source.image.bitsPerComponent == bits)
            let original = try pixel(source.image)
            let expectedAlpha: Float = alpha ? 0.5 : 1
            #expect(abs(original[3] - expectedAlpha) < 0.005)
            #expect(abs(original[0] / original[3] - 0.22) < 0.02,
                "The decoded fixture must contain a real midgray, not empty or transparent pixels")
            let neutral = try EditRenderer.render(source, settings: .neutral)
            #expect(neutral.image === source.image)
            let resizedSource = try EditRenderer.resized(source, width: 8, height: 8, priority: .selected)
            #expect(resizedSource.image.colorSpace?.model == .monochrome)
            #expect(resizedSource.image.bitsPerComponent == bits)

            var settings = EditSettings(developColor: .init(temperature: 9_000, tint: 70))
            let edited = try EditRenderer.render(source, settings: settings)
            #expect(edited.image.bitsPerComponent == bits)
            #expect(edited.image.colorSpace?.name == CGColorSpace.sRGB)
            let actual = try pixel(edited.image)
            #expect(actual[0] - actual[2] > 0.03)
            #expect(abs(actual[3] - original[3]) < 0.005)
            let smaller = try EditRenderer.resized(edited, width: 8, height: 8, priority: .selected)
            #expect(smaller.image.bitsPerComponent == bits && smaller.image.colorSpace?.model == .rgb)
            #expect(smaller.sourceLongEdge == source.sourceLongEdge)
            let reduced = try pixel(smaller.image)
            for channel in 0..<4 { #expect(abs(actual[channel] - reduced[channel]) < 0.005) }

            settings.developColor.isMonochrome = true
            let monochrome = try pixel(EditRenderer.render(source, settings: settings).image)
            #expect(abs(monochrome[0] - monochrome[1]) < 0.000_2)
            #expect(abs(monochrome[1] - monochrome[2]) < 0.000_2)
            #expect(abs(monochrome[3] - original[3]) < 0.005)

            settings.developColor.isMonochrome = false
            settings.developColor.hdrEnabled = true
            let hdr = try EditRenderer.render(source, settings: settings)
            #expect(hdr.image.bitmapInfo.contains(.floatComponents))
            #expect(hdr.image.colorSpace?.name == CGColorSpace.extendedLinearSRGB)
            let hdrPixel = try pixel(hdr.image)
            #expect(hdrPixel[0] - hdrPixel[2] > 0.03)
            #expect(abs(hdrPixel[3] - original[3]) < 0.005)
        }
    }

    @Test func grayscaleRGBExpansionParticipatesInTheBoundedPreviewPlan() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try decode(grayscaleFile(in: directory, ext: "png"))
        let settings = EditSettings(developColor: .init(temperature: 9_000))
        let expansion = EditRenderer.additionalColorOutputBytesPerPixel(for: source.image, settings: settings)
        #expect(expansion > 0)
        #expect(EditRenderer.additionalColorOutputBytesPerPixel(for: source.image, settings: .neutral) == 0)
        let size = try LocalAdjustmentRenderer.previewSize(width: 256, height: 256, adjustments: [],
            totalMemoryBudget: expansion * 128 * 128, globalBytesPerPixel: expansion)
        #expect(size.width == 128 && size.height == 128)
    }

    @Test func persistedGrayscaleBasisStillDevelopsInColorWithoutTheOriginal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try grayscaleFile(in: directory, ext: "png", bits: 16, alpha: true)
        let request = PreviewRequest(url: url, modifiedAt: Date(), pixelSize: 128, allowsEmbeddedPreview: false)
        let source = try PreviewDecoder.decode(request)
        let sourcePixel = try pixel(source.image)
        #expect(abs(sourcePixel[3] - 0.5) < 0.005 && sourcePixel[0] > 0.09)
        let cacheDirectory = directory.appendingPathComponent("Cache", isDirectory: true)
        await PreviewDiskCache(directory: cacheDirectory).store(source, for: request)
        try FileManager.default.removeItem(at: url)
        let cached = try #require(await PreviewDiskCache(directory: cacheDirectory).image(for: request))
        #expect(cached.image.colorSpace?.model == .monochrome && cached.image.bitsPerComponent == 16)
        let settings = EditSettings(developColor: .init(temperature: 9_000, tint: 70))
        let edited = try EditRenderer.render(cached, settings: settings)
        let expected = try pixel(EditRenderer.render(source, settings: settings).image), actual = try pixel(edited.image)
        #expect(edited.image.colorSpace?.model == .rgb)
        for channel in 0..<4 { #expect(abs(actual[channel] - expected[channel]) < 0.000_2) }
        #expect(actual[0] - actual[2] > 0.03)
    }

    private func decode(_ url: URL) throws -> PreviewBitmap {
        try PreviewDecoder.decode(.init(url: url, modifiedAt: Date(), pixelSize: 128, allowsEmbeddedPreview: false))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom Gray \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func grayscaleFile(in directory: URL, ext: String, bits: Int = 8, alpha: Bool = false) throws -> URL {
        let width = 32, components = alpha ? 2 : 1
        let data: Data
        if bits == 16 {
            // Explicit element typing prevents the mixed constructor/literal
            // array from becoming [Any] and exposing existential storage bytes.
            let sample: [UInt16] = alpha ? [16_435, 32_768] : [32_891]
            let values = Array(repeating: sample, count: width * width).flatMap { $0 }
            data = values.withUnsafeBytes { Data($0) }
        } else {
            let sample: [UInt8] = alpha ? [64, 128] : [128]
            data = Data(Array(repeating: sample, count: width * width).flatMap { $0 })
        }
        try #require(data.count == width * width * bits * components / 8)
        let provider = try #require(CGDataProvider(data: data as CFData))
        var bitmapInfo = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedLast : .none).rawValue)
        if bits == 16 { bitmapInfo.insert(.byteOrder16Little) }
        let gray = try #require(CGImage(width: width, height: width, bitsPerComponent: bits,
            bitsPerPixel: bits * components, bytesPerRow: width * bits * components / 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = directory.appendingPathComponent("gray.\(ext)")
        let type = ext == "png" ? UTType.png : UTType.tiff
        let encoder = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, gray, nil)
        #expect(CGImageDestinationFinalize(encoder))
        return url
    }

    private func pixel(_ image: CGImage) throws -> [Float] {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: colorSpace])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1),
                format: .RGBAf, colorSpace: colorSpace)
        }
        return pixel
    }
}
