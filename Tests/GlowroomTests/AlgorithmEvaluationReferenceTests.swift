import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Algorithm evaluation reference controls")
struct AlgorithmEvaluationReferenceTests {
    @Test func identityRetainsExactSharedInputIncludingAlphaAndExtendedRGB() throws {
        let input = try extendedInput()
        let output = try AlgorithmEvaluationIdentity().render(input, settings: .neutral)
        #expect(output.pixels == input.pixels)
        #expect(output.sha256 == input.sha256)
    }

    @Test func rec2020BridgePreservesWhiteAndSignedExtendedPrimaries() {
        let white = AlgorithmEvaluationColorBridge.toRec2020(1, 1, 1)
        #expect(abs(white.0 - 1) < 1e-12)
        #expect(abs(white.1 - 1) < 1e-12)
        #expect(abs(white.2 - 1) < 1e-12)
        let red = AlgorithmEvaluationColorBridge.toRec2020(1, 0, 0)
        #expect(abs(red.0 - 0.627403895934699) < 1e-12)
        #expect(abs(red.1 - 0.069097289358232) < 1e-12)
        #expect(abs(red.2 - 0.016391438875150) < 1e-12)
        let samples: [(Double, Double, Double)] = [(-0.25, 0.4, 1.3), (8, -2, 0.3),
                                                   (0.04, 0.04, 0.04), (1, 0, 0), (0, 1, 0), (0, 0, 1)]
        for source in samples {
            let rec2020 = AlgorithmEvaluationColorBridge.toRec2020(source.0, source.1, source.2)
            let result = AlgorithmEvaluationColorBridge.fromRec2020(rec2020.0, rec2020.1, rec2020.2)
            #expect(abs(result.0 - source.0) < 1e-12)
            #expect(abs(result.1 - source.1) < 1e-12)
            #expect(abs(result.2 - source.2) < 1e-12)
        }
    }

    @Test func neutralRGBReferenceMeetsCPUToleranceAndPreservesAlphaSeparately() throws {
        let input = try extendedInput()
        let before = input.sha256
        var output = try AlgorithmEvaluationNeutralRec2020().render(input, settings: .neutral)
        let measured = try AlgorithmEvaluationMetrics.measure(reference: input, candidate: output)
        #expect(measured.values["max_rgb_error", default: .infinity] <= 0.000005)
        #expect(measured.values["alpha_error", default: .infinity] == 0)
        #expect(output.pixels[4] > 1)
        #expect(output.pixels[5] < 0)
        #expect(output.pixels[7] == 0.03125)
        #expect(Array(output.pixels.prefix(4)) == [0, 0, 0, 0])
        output.pixels[4] = 0.1
        #expect(input.sha256 == before, "Candidates cannot mutate the common input through their result value")
    }

    @Test(arguments: [8, 16], [false, true])
    func nonneutralProductionRenderPreservesSourceProfileDepthAndFrozenOrientation(bits: Int, p3: Bool) throws {
        let source = try profiledImage(bits: bits, p3: p3)
        var settings = EditSettings.neutral
        settings.exposure = 0.25
        let rendered = try EditRenderer.render(PreviewBitmap(image: source), settings: settings).image
        #expect(rendered.bitsPerComponent == bits)
        #expect(rendered.width == source.width)
        #expect(rendered.height == source.height)
        #expect(rendered.colorSpace?.name == source.colorSpace?.name)
        for orientation in UInt32(1)...8 {
            let input = try AlgorithmEvaluationRaster.freeze(source, orientation: orientation)
            let output = try AlgorithmEvaluationRaster.freeze(rendered, orientation: orientation)
            #expect(output.width == input.width)
            #expect(output.height == input.height)
            for offset in stride(from: 0, to: input.pixels.count, by: 4) {
                #expect(abs(output.pixels[offset + 3] - input.pixels[offset + 3]) < 1.0 / 255)
                guard input.pixels[offset + 3] > 0 else { continue }
                // These moderate positive RGB samples avoid gamut clipping;
                // exposure must increase each channel after profile conversion.
                for channel in 0..<3 { #expect(output.pixels[offset + channel] > input.pixels[offset + channel]) }
            }
        }
    }

    private func extendedInput() throws -> AlgorithmEvaluationRaster {
        try .init(width: 4, height: 1, pixels: [1, 0.4, 0.2, 0,
                                               1.4, -0.25, 0.7, 0.03125,
                                               -0.1, 0.6, 1.2, 0.5,
                                               0.2, 0.3, 0.4, 1])
    }

    private func profiledImage(bits: Int, p3: Bool) throws -> CGImage {
        let samples: [UInt16] = [65, 80, 90, 255, 80, 100, 110, 128, 100, 110, 120, 255,
                                 55, 65, 75, 255, 75, 85, 95, 192, 90, 100, 110, 0]
        var bytes = Data()
        for sample in samples {
            if bits == 8 { bytes.append(UInt8(sample)) }
            else {
                let value = sample * 257
                bytes.append(UInt8(truncatingIfNeeded: value >> 8))
                bytes.append(UInt8(truncatingIfNeeded: value))
            }
        }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try #require(CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
        return try #require(CGImage(width: 3, height: 2, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: 3 * 4 * (bits / 8), space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(bits == 16 ? .byteOrder16Big : []),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
    }
}
