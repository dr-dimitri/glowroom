import Foundation
import Testing
@testable import PicEdit

@Suite("Straight RGB transport for SDXL evaluation", .serialized)
struct SDXLEvaluationRasterTests {
    @Test func asymmetricOddCanvasHasFixedTopLeftAnchorsAndMatchingMaskPadding() throws {
        let raster = try SDXLEvaluationRaster(width: 3, height: 5)
        #expect(SDXLEvaluationRaster.edge == 1024)
        #expect(raster.width == 3 && raster.height == 5)
        #expect(raster.offsetX == 510 && raster.offsetY == 509)
        var pixels = Data()
        for index in 0..<15 { pixels.append(contentsOf: [UInt8(index + 1), UInt8(index + 31), UInt8(index + 61), UInt8(index)]) }
        let prepared = try raster.prepare(pixels: pixels,
            mask: Data([0, 127, 128, 129, 255, 1, 128, 0, 255, 127, 128, 0, 255, 127, 128]))
        #expect(prepared.pixels.count == 1024 * 1024 * 4)
        #expect(prepared.mask.count == 1024 * 1024)
        // These golden positions do not use the implementation's offsets.
        let anchors: [(Int, Int, [UInt8], UInt8)] = [
            (510, 509, [1, 31, 61, 255], 0),
            (511, 509, [2, 32, 62, 255], 0), // 127 preserves.
            (512, 509, [3, 33, 63, 255], 255), // 128 replaces.
            (510, 513, [13, 43, 73, 255], 255),
            (512, 513, [15, 45, 75, 255], 255),
            (511, 511, [8, 38, 68, 255], 0),
            (509, 510, [4, 34, 64, 255], 255), // Marked left edge extends.
            (513, 510, [6, 36, 66, 255], 0), // Unmarked right edge extends.
            (511, 508, [2, 32, 62, 255], 0),
            (511, 514, [14, 44, 74, 255], 0),
            (0, 0, [1, 31, 61, 255], 0),
            (1023, 0, [3, 33, 63, 255], 255),
            (0, 1023, [13, 43, 73, 255], 255),
            (1023, 1023, [15, 45, 75, 255], 255)
        ]
        for (x, y, expectedPixel, expectedMask) in anchors {
            #expect(pixel(prepared.pixels, x: x, y: y) == expectedPixel)
            #expect(prepared.mask[y * 1024 + x] == expectedMask)
        }
    }

    @Test func channelOrderAndHiddenStraightRGBSurviveIdentityPaddingAndCrop() throws {
        let raster = try SDXLEvaluationRaster(width: 4, height: 2)
        let original = Data([19, 43, 71, 0, 203, 61, 17, 1, 31, 173, 89, 64, 251, 101, 47, 128,
                             73, 37, 191, 192, 139, 211, 53, 254, 59, 107, 229, 255, 109, 157, 23, 0])
        let prepared = try raster.prepare(pixels: original, mask: Data([0, 127, 128, 129, 255, 1, 64, 192]))
        let cropped = try raster.crop(prepared.pixels)
        #expect(cropped == Data([19, 43, 71, 255, 203, 61, 17, 255, 31, 173, 89, 255, 251, 101, 47, 255,
                                73, 37, 191, 255, 139, 211, 53, 255, 59, 107, 229, 255, 109, 157, 23, 255]))
        #expect(original[3] == 0 && original[31] == 0, "Preparation must not mutate the native alpha")
        // A fake model changing alpha must not become an alpha-generation route.
        var model = prepared.pixels
        model[(511 * 1024 + 510) * 4 + 3] = 0
        #expect(try raster.crop(model) == cropped)
    }

    @Test(arguments: [(1, 1, 511, 511), (1023, 3, 0, 510), (640, 384, 192, 320), (1024, 1024, 0, 0)])
    func nativeRoundTripPreservesAnAsymmetricCoordinateGrid(size: (Int, Int, Int, Int)) throws {
        let (width, height, offsetX, offsetY) = size
        let raster = try SDXLEvaluationRaster(width: width, height: height)
        #expect(raster.offsetX == offsetX && raster.offsetY == offsetY)
        var original = Data(count: width * height * 4)
        // A bounded serial grid avoids nested pools and makes every row/column
        // distinguishable, including full-width and full-canvas boundaries.
        original.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<height { for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(truncatingIfNeeded: x)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: y)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: (x >> 8) * 16 + (y >> 8))
                bytes[offset + 3] = 255
            } }
        }
        let prepared = try raster.prepare(pixels: original, mask: Data(repeating: 128, count: width * height))
        #expect(try raster.crop(prepared.pixels) == original)
        #expect(prepared.mask.allSatisfy { $0 == 255 })
        #expect(pixel(prepared.pixels, x: offsetX, y: offsetY) == [0, 0, 0, 255])
        #expect(pixel(prepared.pixels, x: 1023, y: 1023) == Array(original.suffix(4)))
    }

    @Test func cropUsesTheRecordedNativeRectangleWithoutFlippingOrScaling() throws {
        let raster = try SDXLEvaluationRaster(width: 3, height: 5)
        var model = Data(repeating: 99, count: 1024 * 1024 * 4)
        for (x, y, rgba) in [(510, 509, [UInt8(11), 23, 37, 0]),
                              (512, 509, [UInt8(41), 53, 67, 17]),
                              (510, 513, [UInt8(71), 83, 97, 128]),
                              (512, 513, [UInt8(101), 113, 127, 254]),
                              (511, 511, [UInt8(131), 149, 157, 255])] {
            let index = (y * 1024 + x) * 4
            model.replaceSubrange(index..<index + 4, with: rgba)
        }
        let cropped = try raster.crop(model)
        #expect(cropped.count == 3 * 5 * 4)
        #expect(Array(cropped[0..<4]) == [11, 23, 37, 255])
        #expect(Array(cropped[8..<12]) == [41, 53, 67, 255])
        #expect(Array(cropped[48..<52]) == [71, 83, 97, 255])
        #expect(Array(cropped[56..<60]) == [101, 113, 127, 255])
        #expect(Array(cropped[28..<32]) == [131, 149, 157, 255])
    }

    @Test func invalidDimensionsAndLengthsThrowBeforeArithmeticOrPixelAccess() throws {
        for (width, height) in [(0, 1), (1, 0), (-1, 3), (3, -1), (1025, 1), (1, 1025),
                                (Int.min, 1), (1, Int.min), (Int.max, 1), (1, Int.max), (Int.max, Int.max)] {
            #expect(throws: SDXLEvaluationRaster.Failure.invalidDimensions) {
                _ = try SDXLEvaluationRaster(width: width, height: height)
            }
        }
        let raster = try SDXLEvaluationRaster(width: 1, height: 1)
        for pixels in [Data(), Data([1, 2, 3]), Data([1, 2, 3, 4, 5])] {
            #expect(throws: SDXLEvaluationRaster.Failure.invalidLength) {
                _ = try raster.prepare(pixels: pixels, mask: Data([255]))
            }
        }
        for mask in [Data(), Data([127, 128])] {
            #expect(throws: SDXLEvaluationRaster.Failure.invalidLength) {
                _ = try raster.prepare(pixels: Data([1, 2, 3, 4]), mask: mask)
            }
        }
        for count in [0, 4, 1024 * 1024 * 4 - 1, 1024 * 1024 * 4 + 1] {
            #expect(throws: SDXLEvaluationRaster.Failure.invalidLength) {
                _ = try raster.crop(Data(count: count))
            }
        }
    }

    @Test func dataSlicesUseTheirLogicalBytesRatherThanZeroBasedCollectionIndices() throws {
        let raster = try SDXLEvaluationRaster(width: 1, height: 1)
        let nativePixels = Data([99, 11, 23, 37, 0, 88])[1..<5]
        let nativeMask = Data([99, 128, 88])[1..<2]
        let prepared = try raster.prepare(pixels: nativePixels, mask: nativeMask)
        #expect(prepared.mask.allSatisfy { $0 == 255 })
        #expect(try raster.crop(prepared.pixels) == Data([11, 23, 37, 255]))
        var surrounding = Data([99]); surrounding.append(prepared.pixels); surrounding.append(88)
        #expect(try raster.crop(surrounding[1..<surrounding.count - 1]) == Data([11, 23, 37, 255]))
    }

    private func pixel(_ pixels: Data, x: Int, y: Int) -> [UInt8] {
        let index = (y * 1024 + x) * 4
        return Array(pixels[index..<index + 4])
    }
}
