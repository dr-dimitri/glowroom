import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PicEdit

@Suite("Algorithm evaluation fixtures")
struct AlgorithmEvaluationFixtureTests {
    @Test func deterministicScenesHaveSeparateTuningAndAcceptanceSeeds() throws {
        let tuning = try AlgorithmEvaluationFixtures.make(split: .tuning, width: 48, height: 32)
        let repeated = try AlgorithmEvaluationFixtures.make(split: .tuning, width: 48, height: 32)
        let acceptance = try AlgorithmEvaluationFixtures.make(split: .acceptance, width: 48, height: 32)
        #expect(tuning.count == 9)
        #expect(tuning.map(\.sceneClass) == AlgorithmEvaluationFixtures.sceneClasses)
        #expect(tuning.map(\.input.sha256) == repeated.map(\.input.sha256))
        #expect(Set(tuning.map(\.seed)).isDisjoint(with: Set(acceptance.map(\.seed))))
        for (a, b) in zip(tuning, acceptance) { #expect(a.input.sha256 != b.input.sha256) }
        let noise = try #require(tuning.first { $0.sceneClass == "noise" })
        let clean = try #require(noise.groundTruth)
        #expect(noise.input.sha256 != clean.sha256)
        #expect(clean.pixels.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 1 })
    }

    @Test func alphaZeroIsCanonicalAndDimensionsBelongToTheHash() throws {
        let a = try AlgorithmEvaluationRaster(width: 2, height: 1, pixels: [1, 0.2, 0.3, 0, 0.2, 0.4, 0.6, 1])
        let b = try AlgorithmEvaluationRaster(width: 2, height: 1, pixels: [-2, 4, 7, 0, 0.2, 0.4, 0.6, 1])
        #expect(a.sha256 == b.sha256)
        #expect(Array(a.pixels.prefix(4)) == [0, 0, 0, 0])
        let rotatedShape = try AlgorithmEvaluationRaster(width: 1, height: 2, pixels: a.pixels)
        #expect(a.sha256 != rotatedShape.sha256)
        #expect(throws: AlgorithmEvaluationFixtureError.self) {
            try AlgorithmEvaluationRaster(width: 1, height: 1, pixels: [0, 0, 0, 1.1])
        }
        #expect(throws: AlgorithmEvaluationFixtureError.self) {
            try AlgorithmEvaluationRaster(width: 1, height: 1, pixels: [.nan, 0, 0, 1])
        }
    }

    @Test func floatRoundTripExplicitlyPreservesStraightAlphaAndExtendedGamut() throws {
        let source = try AlgorithmEvaluationRaster(width: 3, height: 1,
            pixels: [1.2, -0.1, 0.5, 0.25, 0.2, 0.4, 0.7, 0.5, 0.9, 0.2, 0.1, 0])
        let image = try source.cgImage()
        #expect(image.bitsPerComponent == 32)
        #expect(image.alphaInfo == .premultipliedLast)
        let frozen = try AlgorithmEvaluationRaster.freeze(image)
        for (actual, expected) in zip(frozen.pixels, source.pixels) { #expect(abs(actual - expected) < 0.00001) }
    }

    @Test func diagnosticCompositesUseLinearLightAndRetainNoHiddenRGB() throws {
        let source = try AlgorithmEvaluationRaster(width: 2, height: 1,
            pixels: [0.8, 0.4, 0.2, 0.5, 0.9, 0.9, 0.9, 0])
        for background in [Float(0.05), 0.95] {
            let composite = try AlgorithmEvaluationRaster.freeze(source.previewImage(background: background))
            for channel in 0..<3 {
                #expect(abs(composite.pixels[channel] - (source.pixels[channel] * 0.5 + background * 0.5)) < 0.006)
                #expect(abs(composite.pixels[4 + channel] - background) < 0.006)
            }
            #expect(composite.pixels[3] == 1)
            #expect(composite.pixels[7] == 1)
        }
        let retainedAlpha = try AlgorithmEvaluationRaster.freeze(source.previewImage())
        #expect(abs(retainedAlpha.pixels[3] - 0.5) < 1.0 / 255)
        #expect(Array(retainedAlpha.pixels.suffix(4)) == [0, 0, 0, 0])
    }

    @Test(arguments: [8, 16], [false, true])
    func imageIOProfilesBitDepthsAndAllEXIFOrientations(bits: Int, p3: Bool) throws {
        // TIFF preserves 16-bit channels and embeds a real profile and EXIF tag.
        // The expected color conversion is independent of CGContext/CI output.
        let colors: [[UInt16]] = [[48, 80, 128], [140, 65, 95], [80, 130, 100],
                                  [130, 135, 55], [100, 70, 145], [165, 145, 100]]
        let image = try encodedGrid(bits: bits, p3: p3, colors: colors)
        for orientation in 1...8 {
            let encoded = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            let source = try #require(CGImageSourceCreateWithData(encoded, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let exif = try #require(properties[kCGImagePropertyOrientation] as? NSNumber)
            #expect(decoded.bitsPerComponent == bits)
            #expect(exif.intValue == orientation)
            let frozen = try AlgorithmEvaluationRaster.freeze(decoded, orientation: exif.uint32Value)
            let expectedOrder: [Int]
            switch orientation {
            case 1: expectedOrder = [0, 1, 2, 3, 4, 5]
            case 2: expectedOrder = [2, 1, 0, 5, 4, 3]
            case 3: expectedOrder = [5, 4, 3, 2, 1, 0]
            case 4: expectedOrder = [3, 4, 5, 0, 1, 2]
            case 5: expectedOrder = [0, 3, 1, 4, 2, 5]
            case 6: expectedOrder = [3, 0, 4, 1, 5, 2]
            case 7: expectedOrder = [5, 2, 4, 1, 3, 0]
            default: expectedOrder = [2, 5, 1, 4, 0, 3]
            }
            #expect(frozen.width == (orientation >= 5 ? 2 : 3))
            #expect(frozen.height == (orientation >= 5 ? 3 : 2))
            for (index, sourceIndex) in expectedOrder.enumerated() {
                let expected = linearSRGB(colors[sourceIndex], p3: p3)
                for channel in 0..<3 { #expect(abs(frozen.pixels[index * 4 + channel] - expected[channel]) < 0.002) }
                #expect(frozen.pixels[index * 4 + 3] == 1)
            }
        }
    }

    @Test func cancelledFixtureGenerationCannotProduceAResult() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AlgorithmEvaluationFixtures.make(sceneClass: "noise", split: .tuning)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func encodedGrid(bits: Int, p3: Bool, colors: [[UInt16]]) throws -> CGImage {
        var bytes = Data()
        for color in colors {
            for sample in color + [255] {
                if bits == 8 { bytes.append(UInt8(sample)) }
                else {
                    let value = sample * 257
                    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
                    bytes.append(UInt8(truncatingIfNeeded: value))
                }
            }
        }
        let space = try #require(CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(CGImage(width: 3, height: 2, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: 3 * 4 * (bits / 8), space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(bits == 16 ? .byteOrder16Big : []),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
    }

    private func linearSRGB(_ color: [UInt16], p3: Bool) -> [Float] {
        let linear = color.map { value -> Float in
            let encoded = Float(value) / 255
            return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
        }
        guard p3 else { return linear }
        // Display P3 and sRGB share D65 and the sRGB transfer curve. These are
        // the standard linear primaries conversion, not Lightcraft constants.
        return [1.224745 * linear[0] - 0.224904 * linear[1],
                -0.042058 * linear[0] + 1.042081 * linear[1],
                -0.019642 * linear[0] - 0.078655 * linear[1] + 1.098537 * linear[2]]
    }
}
