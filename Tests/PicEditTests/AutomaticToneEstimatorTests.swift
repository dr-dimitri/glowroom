import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Individual automatic tone controls")
struct AutomaticToneEstimatorTests {
    @Test
    func exposureRespondsToDarkAndBrightScenes() async throws {
        let estimator = AutomaticToneEstimator()
        let dark = try gradient(from: 24, to: 124)
        let bright = try gradient(from: 120, to: 240)
        #expect(try await estimator.value(for: .exposure, bitmap: dark, settings: .neutral) > 0)
        #expect(try await estimator.value(for: .exposure, bitmap: bright, settings: .neutral) < 0)
    }

    @Test
    func contrastExpandsNarrowAndRestrainsWideTonalRanges() async throws {
        let estimator = AutomaticToneEstimator()
        let narrow = try gradient(from: 100, to: 156)
        let wide = try gradient(from: 0, to: 255)
        #expect(try await estimator.value(for: .contrast, bitmap: narrow, settings: .neutral) > 0)
        #expect(try await estimator.value(for: .contrast, bitmap: wide, settings: .neutral) < 0)
    }

    @Test
    func shadowsOnlyOpenARegionThatNeedsLifting() async throws {
        let estimator = AutomaticToneEstimator()
        let dark = try gradient(from: 8, to: 120)
        let lifted = try gradient(from: 70, to: 210)
        #expect(try await estimator.value(for: .shadows, bitmap: dark, settings: .neutral) > 0)
        #expect(try await estimator.value(for: .shadows, bitmap: lifted, settings: .neutral) == 0)
    }

    @Test
    func highlightsOnlyRestrainARegionThatNeedsRecovery() async throws {
        let estimator = AutomaticToneEstimator()
        let bright = try gradient(from: 96, to: 255)
        let dim = try gradient(from: 40, to: 160)
        #expect(try await estimator.value(for: .highlights, bitmap: bright, settings: .neutral) < 0)
        #expect(try await estimator.value(for: .highlights, bitmap: dim, settings: .neutral) == 0)
    }

    @Test
    func whitePointAdaptsToBrightEndpointsWithoutForcingDarkScenes() async throws {
        let estimator = AutomaticToneEstimator()
        let pale = try gradient(from: 48, to: 243)
        let dark = try gradient(from: 0, to: 180)
        #expect(try await estimator.value(for: .whites, bitmap: pale, settings: .neutral) > 0)
        #expect(try await estimator.value(for: .whites, bitmap: dark, settings: .neutral) == 0)
    }

    @Test
    func blackPointAdaptsToLiftedAndNearBlackEndpoints() async throws {
        let estimator = AutomaticToneEstimator()
        let lifted = try gradient(from: 10, to: 220)
        let deep = try gradient(from: 0, to: 210)
        #expect(try await estimator.value(for: .blacks, bitmap: lifted, settings: .neutral) < 0)
        #expect(try await estimator.value(for: .blacks, bitmap: deep, settings: .neutral) > 0)
    }

    @Test(arguments: AutomaticToneControl.allCases)
    func valuesUseTheSliderStepAndBounds(_ control: AutomaticToneControl) async throws {
        let input = try gradient(from: 16, to: 240)
        let value = try await AutomaticToneEstimator().value(for: control, bitmap: input, settings: .neutral)
        #expect(value.isFinite)
        #expect(control.range.contains(value))
        #expect(abs(value / control.step - (value / control.step).rounded()) < 0.000_001)
    }

    @Test(arguments: AutomaticToneControl.allCases)
    func currentTargetValueDoesNotInfluenceTheResult(_ control: AutomaticToneControl) async throws {
        let estimator = AutomaticToneEstimator()
        let input = try gradient(from: 16, to: 240)
        var before = EditSettings.neutral
        before[keyPath: control.keyPath] = control.range.lowerBound
        let first = try await estimator.value(for: control, bitmap: input, settings: before)
        before[keyPath: control.keyPath] = control.range.upperBound
        let second = try await estimator.value(for: control, bitmap: input, settings: before)
        before[keyPath: control.keyPath] = first
        let repeated = try await estimator.value(for: control, bitmap: input, settings: before)
        #expect(first == second)
        #expect(repeated == first)
    }

    @Test
    func otherGlobalExposureIsRespected() async throws {
        let estimator = AutomaticToneEstimator()
        let input = try gradient(from: 8, to: 120)
        let neutral = try await estimator.value(for: .shadows, bitmap: input, settings: .neutral)
        var raised = EditSettings.neutral
        raised.exposure = 2
        let exposed = try await estimator.value(for: .shadows, bitmap: input, settings: raised)
        #expect(neutral > exposed)
        #expect(exposed == 0)
    }

    @Test
    func exposureKeepsAnAlreadyBrightSaturatedSubjectFromClipping() async throws {
        let input = try colorFixture(width: 256, height: 32) { x, _ in
            if x >= 192 { return (240, 15, 15, 255) }
            let level = UInt8(24 + x * 66 / 191)
            return (level, level, level, 255)
        }
        let value = try await AutomaticToneEstimator().value(for: .exposure, bitmap: input, settings: .neutral)
        #expect(value >= 0 && value < 0.3, "Automatic exposure must respect channel headroom, even when luminance is dark")
        var settings = EditSettings.neutral
        settings.exposure = value
        let output = try EditRenderer.render(input, settings: settings)
        var pixels = [UInt8](repeating: 0, count: output.image.width * output.image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: output.image.width,
                height: output.image.height, bitsPerComponent: 8, bytesPerRow: output.image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(output.image, in: CGRect(x: 0, y: 0, width: output.image.width, height: output.image.height))
        }
        #expect((192..<256).allSatisfy { pixels[$0 * 4] < 254 })
    }

    @Test(arguments: AutomaticToneControl.allCases)
    func transparentMarginsDoNotChangeTheEstimate(_ control: AutomaticToneControl) async throws {
        let estimator = AutomaticToneEstimator()
        let source = try fixture(width: 128, height: 32) { x, _ in (UInt8(16 + x * 224 / 127), 255) }
        let padded = try fixture(width: 256, height: 64) { x, y in
            guard (64..<192).contains(x), (16..<48).contains(y) else { return (0, 0) }
            return (UInt8(16 + (x - 64) * 224 / 127), 255)
        }
        let original = try await estimator.value(for: control, bitmap: source, settings: .neutral)
        let withMargins = try await estimator.value(for: control, bitmap: padded, settings: .neutral)
        #expect(original == withMargins)
    }

    @Test
    func flatTransparentAndSparseSpecularFieldsStayNeutral() async throws {
        let estimator = AutomaticToneEstimator()
        for level: UInt8 in [0, 2, 64, 128, 250, 255] {
            let flat = try fixture(width: 32, height: 16) { _, _ in (level, 255) }
            for control in AutomaticToneControl.allCases {
                #expect(try await estimator.value(for: control, bitmap: flat, settings: .neutral) == 0)
            }
        }
        let transparent = try fixture(width: 64, height: 16) { _, _ in (0, 0) }
        let specular = try fixture(width: 256, height: 16) { x, _ in (x == 0 ? 255 : 128, 255) }
        let noise = try fixture(width: 32, height: 16) { x, y in (UInt8(126 + (x + y) % 4), 255) }
        for input in [transparent, specular, noise] {
            for control in AutomaticToneControl.allCases {
                #expect(try await estimator.value(for: control, bitmap: input, settings: .neutral) == 0)
            }
        }
    }

    @Test
    func largerDecodedPreviewIsSampledWithinTheBound() async throws {
        let small = try gradient(from: 24, to: 124)
        let large = try fixture(width: 1_024, height: 128) { x, _ in (UInt8(24 + (x / 4) * 100 / 255), 255) }
        let estimator = AutomaticToneEstimator()
        let smallValue = try await estimator.value(for: .exposure, bitmap: small, settings: .neutral)
        let largeValue = try await estimator.value(for: .exposure, bitmap: large, settings: .neutral)
        #expect(abs(smallValue - largeValue) <= AutomaticToneControl.exposure.step)
    }

    @Test
    func canceledAnalysisStopsBeforeRendering() async throws {
        let input = try gradient(from: 24, to: 124)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AutomaticToneEstimator().value(for: .exposure, bitmap: input, settings: .neutral)
        }
        do {
            _ = try await task.value
            Issue.record("Canceled tone estimation unexpectedly succeeded")
        } catch is CancellationError { }
    }

    private func gradient(from lower: Int, to upper: Int) throws -> PreviewBitmap {
        try fixture(width: 256, height: 32) { x, _ in (UInt8(lower + x * (upper - lower) / 255), 255) }
    }

    private func fixture(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8)) throws -> PreviewBitmap {
        try colorFixture(width: width, height: height) { x, y in
            let (gray, alpha) = pixel(x, y)
            return (gray, gray, gray, alpha)
        }
    }

    private func colorFixture(width: Int, height: Int,
                              pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> PreviewBitmap {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue, alpha) = pixel(x, y)
                pixels += [UInt8(Int(red) * Int(alpha) / 255), UInt8(Int(green) * Int(alpha) / 255),
                           UInt8(Int(blue) * Int(alpha) / 255), alpha]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }
}
