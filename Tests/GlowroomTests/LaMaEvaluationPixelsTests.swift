import CoreGraphics
import CoreVideo
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Straight RGB transport for LaMa evaluation")
struct LaMaEvaluationPixelsTests {
    @Test(arguments: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB])
    func actualStridedBuffersKeepNativeRowsChannelsAndBinaryMask(format: OSType) throws {
        let mapping = try LaMaEvaluationMapping(width: 3, height: 2)
        let pixels = Data([11, 23, 37, 0, 41, 53, 67, 64, 71, 83, 97, 128,
                           101, 113, 127, 192, 131, 149, 157, 254, 163, 179, 191, 255])
        let image = try paddedBuffer(format: format)
        let mask = try paddedBuffer(format: kCVPixelFormatType_OneComponent8)
        #expect(CVPixelBufferGetBytesPerRow(image) > 800 * 4)
        #expect(CVPixelBufferGetBytesPerRow(mask) > 800)
        try LaMaEvaluationPixels.fill(image, mask, pixels: pixels, weights: Data([0, 127, 128, 129, 255, 1]), mapping: mapping)
        let cropped = try LaMaEvaluationPixels.crop(image, mapping: mapping)
        #expect(cropped == Data([11, 23, 37, 255, 41, 53, 67, 255, 71, 83, 97, 255,
                                101, 113, 127, 255, 131, 149, 157, 255, 163, 179, 191, 255]))
        // Fixed top-left native coordinates: the 3x2 source starts at 398/399.
        #expect(try readPixel(image, x: 398, y: 399) == (format == kCVPixelFormatType_32BGRA
            ? [37, 23, 11, 255] : [255, 11, 23, 37]))
        #expect(try readPixel(image, x: 400, y: 400) == (format == kCVPixelFormatType_32BGRA
            ? [191, 179, 163, 255] : [255, 163, 179, 191]))
        #expect(try readPixel(mask, x: 398, y: 399) == [0])
        #expect(try readPixel(mask, x: 399, y: 399) == [0]) // 127 preserves
        #expect(try readPixel(mask, x: 400, y: 399) == [255]) // 128 replaces
        #expect(try readPixel(mask, x: 398, y: 400) == [255])
        #expect(try readPixel(mask, x: 399, y: 400) == [255])
        #expect(try readPixel(mask, x: 400, y: 400) == [0])
        #expect(try readPixel(mask, x: 397, y: 399) == [0]) // unmarked edge extends as unmarked
        #expect(try readPixel(mask, x: 397, y: 400) == [255]) // marked edge extends with its RGB
        #expect(try readPixel(mask, x: 401, y: 400) == [0])
        #expect(try readPixel(mask, x: 799, y: 0) == [255])
        #expect(try readPixel(mask, x: 0, y: 799) == [255])
        #expect(try readPixel(mask, x: 799, y: 799) == [0])
    }

    @Test(arguments: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB])
    func identityModelAndSourceAlphaDoNotCreateAMatteHalo(format: OSType) async throws {
        let mapping = try LaMaEvaluationMapping(width: 4, height: 2)
        let original = Data([19, 43, 71, 64, 203, 61, 17, 128, 31, 173, 89, 192, 251, 101, 47, 255,
                             73, 37, 191, 1, 139, 211, 53, 32, 59, 107, 229, 254, 109, 157, 23, 0])
        let weights = Data([0, 64, 128, 255, 255, 127, 192, 0])
        let input = try LaMaEvaluationPixels.buffer(format: format)
        let mask = try LaMaEvaluationPixels.buffer(format: kCVPixelFormatType_OneComponent8)
        try LaMaEvaluationPixels.fill(input, mask, pixels: original, weights: weights, mapping: mapping)
        // The fake model returns the exact input CVPixelBuffer. Transport must
        // preserve straight RGB even for invisible and almost invisible pixels.
        var candidate = try LaMaEvaluationPixels.crop(input, mapping: mapping)
        for pixel in 0..<weights.count {
            for channel in 0..<3 { #expect(candidate[pixel * 4 + channel] == original[pixel * 4 + channel]) }
            candidate[pixel * 4 + 3] = original[pixel * 4 + 3]
        }
        let size = try ArtifactPixelSize(width: 4, height: 2)
        let composed = try await MaskCompositor.compose(base: .init(immutableImage: image(original, width: 4, height: 2)),
            candidate: .init(immutableImage: image(candidate, width: 4, height: 2)),
            mask: .init(size: size, bytes: weights), resources: ArtifactResourceOwner(limits: try .init()), backend: .cpu)
        let actual = try packedBytes(composed.image)
        for pixel in 0..<weights.count {
            let offset = pixel * 4
            #expect(actual[offset + 3] == original[offset + 3])
            for channel in 0..<3 {
                #expect(abs(Int(actual[offset + channel]) - Int(original[offset + channel])) <= 1)
            }
            if weights[pixel] == 0 { #expect(actual[offset..<offset + 4] == original[offset..<offset + 4]) }
        }
        // A white-matte transport would change the semitransparent green pixel
        // from 31/173/89 to 86/193/130 before its alpha was restored.
        #expect(candidate[8..<11] == Data([31, 173, 89]))
    }

    @Test func invalidLengthsDimensionsAndLaneTypesThrowBeforeAccessingMemory() throws {
        let mapping = try LaMaEvaluationMapping(width: 1, height: 1)
        let image = try LaMaEvaluationPixels.buffer(format: kCVPixelFormatType_32BGRA)
        let mask = try LaMaEvaluationPixels.buffer(format: kCVPixelFormatType_OneComponent8)
        for bytes in [Data(), Data([1, 2, 3]), Data([1, 2, 3, 4, 5])] {
            #expect(throws: LaMaEvaluationPixels.Failure.invalidLength) {
                try LaMaEvaluationPixels.fill(image, mask, pixels: bytes, weights: Data([255]), mapping: mapping)
            }
        }
        #expect(throws: LaMaEvaluationPixels.Failure.invalidLength) {
            try LaMaEvaluationPixels.fill(image, mask, pixels: Data([1, 2, 3, 4]), weights: Data(), mapping: mapping)
        }
        #expect(throws: LaMaEvaluationPixels.Failure.invalidFormat) { _ = try LaMaEvaluationPixels.buffer(format: kCVPixelFormatType_32RGBA) }
        #expect(throws: LaMaEvaluationPixels.Failure.invalidFormat) { _ = try LaMaEvaluationPixels.crop(mask, mapping: mapping) }
        #expect(throws: LaMaEvaluationPixels.Failure.invalidFormat) {
            try LaMaEvaluationPixels.fill(image, image, pixels: Data([1, 2, 3, 4]), weights: Data([255]), mapping: mapping)
        }
        let wrongSize = try paddedBuffer(format: kCVPixelFormatType_32BGRA, width: 799)
        #expect(throws: LaMaEvaluationPixels.Failure.invalidDimensions) { _ = try LaMaEvaluationPixels.crop(wrongSize, mapping: mapping) }
        #expect(throws: LaMaEvaluationPixels.Failure.invalidDimensions) {
            try LaMaEvaluationPixels.fill(wrongSize, mask, pixels: Data([1, 2, 3, 4]), weights: Data([255]), mapping: mapping)
        }
        // A nested mask validation failure must release the image lock.
        try LaMaEvaluationPixels.fill(image, mask, pixels: Data([1, 2, 3, 4]), weights: Data([255]), mapping: mapping)
        #expect(try LaMaEvaluationPixels.crop(image, mapping: mapping) == Data([1, 2, 3, 255]))
    }

    private func paddedBuffer(format: OSType, width: Int = 800) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, 800, format,
            [kCVPixelBufferBytesPerRowAlignmentKey: 4096] as CFDictionary, &buffer)
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    private func readPixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> [UInt8] {
        #expect(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let address = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let channels = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 ? 1 : 4
        let start = y * CVPixelBufferGetBytesPerRow(buffer) + x * channels
        return (0..<channels).map { address[start + $0] }
    }

    private func image(_ pixels: Data, width: Int, height: Int) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func packedBytes(_ image: CGImage) throws -> Data {
        let native = try #require(image.dataProvider?.data) as Data
        var result = Data()
        for row in 0..<image.height {
            let start = row * image.bytesPerRow
            result.append(native[start..<start + image.width * 4])
        }
        return result
    }
}
