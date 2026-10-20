import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PicEdit

@Suite("Preview source pixel scale")
struct PreviewSourceScaleTests {
    @Test
    func inMemoryBitmapDefaultsToNativePixels() throws {
        let image = try image()
        let bitmap = PreviewBitmap(image: image)
        #expect(bitmap.sourceLongEdge == 320)
        #expect(bitmap.sourcePixelScale == 1)
        let reduced = PreviewBitmap(image: image, sourceLongEdge: 3_200)
        #expect(reduced.sourcePixelScale == 0.1)
    }

    @Test(arguments: [1, 6])
    func originalDimensionsSurviveReducedAndRotatedDecode(orientation: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-SourceScale-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let bitmap = try PreviewDecoder.decode(PreviewRequest(url: url, modifiedAt: .distantPast, pixelSize: 64, allowsEmbeddedPreview: false))
        #expect(bitmap.sourceLongEdge == 320)
        #expect(max(bitmap.image.width, bitmap.image.height) == 64)
        #expect(bitmap.sourcePixelScale == 0.2)
        #expect((orientation == 6) == (bitmap.image.height > bitmap.image.width))
    }

    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 1_280,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try #require(context.makeImage())
    }
}
