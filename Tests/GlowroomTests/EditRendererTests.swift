import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Edit rendering")
struct EditRendererTests {
    @Test
    func testNeutralReturnsIdenticalBitmap() throws {
        let input = try fixture()
        let output = try EditRenderer.render(input, settings: .neutral)
        #expect(input.image === output.image)
    }

    @Test
    func testExposureAndTonalControlsHaveCorrectDirections() throws {
        for (key, level) in [
            (\EditSettings.exposure, UInt8(90)),
            (\EditSettings.highlights, UInt8(190)),
            (\EditSettings.shadows, UInt8(60)),
            (\EditSettings.whites, UInt8(225)),
            (\EditSettings.blacks, UInt8(28))
        ] {
            let input = try fixture { _, _ in (level, level, level, 255) }
            var brighter = EditSettings.neutral
            brighter[keyPath: key] = key == \EditSettings.exposure ? 1 : 60
            var darker = EditSettings.neutral
            darker[keyPath: key] = key == \EditSettings.exposure ? -1 : -60
            let baseline = luminanceMean(try pixels(input.image))
            #expect((luminanceMean(try pixels(EditRenderer.render(input, settings: brighter).image))) > (baseline + 1))
            #expect((luminanceMean(try pixels(EditRenderer.render(input, settings: darker).image))) < (baseline - 1))
        }
    }

    @Test
    func testContrastChangesTonalSpreadInBothDirections() throws {
        let input = try fixture { x, _ in
            let value: UInt8 = x < 32 ? 65 : 190
            return (value, value, value, 255)
        }
        var positive = EditSettings.neutral
        positive.contrast = 70
        var negative = EditSettings.neutral
        negative.contrast = -70
        let baseline = lumaVariance(try pixels(input.image))
        #expect((lumaVariance(try pixels(EditRenderer.render(input, settings: positive).image))) > (baseline))
        #expect((lumaVariance(try pixels(EditRenderer.render(input, settings: negative).image))) < (baseline))
    }

    @Test
    func testCombinedToneExtremesDoNotReverseGradientOrdering() throws {
        let input = try fixture(width: 256, height: 16) { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
        var settings = EditSettings.neutral
        settings.shadows = 100
        settings.blacks = 100
        settings.highlights = -100
        settings.whites = -100
        let values = lumaValues(try pixels(EditRenderer.render(input, settings: settings).image))
        for x in 1..<256 { #expect(values[x] >= values[x - 1] - 1) }
    }

    @Test
    func testAllPresenceAndColorSlidersChangePixelsIndependently() throws {
        let input = try fixture { x, y in
            let stripe = ((x / 3 + y / 5) % 2) * 28
            return (UInt8(65 + x + stripe), UInt8(85 + y / 2), UInt8(95 + x / 3), 255)
        }
        let baseline = try pixels(input.image)
        var outputs: [[Double]] = []
        for key in [\EditSettings.texture, \.clarity, \.dehaze, \.vibrance, \.saturation] {
            var settings = EditSettings.neutral
            settings[keyPath: key] = 65
            let output = try pixels(EditRenderer.render(input, settings: settings).image)
            #expect((meanAbsoluteDifference(baseline, output)) > (0.15))
            outputs.append(output)
        }
        #expect((meanAbsoluteDifference(outputs[0], outputs[1])) > (0.15), "Texture and clarity need distinct spatial scales")
        #expect((meanAbsoluteDifference(outputs[3], outputs[4])) > (0.15), "Vibrance and saturation must differ")
        var desaturated = EditSettings.neutral
        desaturated.saturation = -100
        #expect((chromaVariance(try pixels(EditRenderer.render(input, settings: desaturated).image))) < (1))
    }

    @Test
    func testLuminanceNoiseReductionReducesLuminanceVariance() throws {
        let input = try fixture { x, y in
            let value = UInt8(110 + noise(x, y, seed: 17) % 53 - 26)
            return (value, value, value, 255)
        }
        var settings = EditSettings.neutral
        settings.luminanceNoiseReduction = 100
        let baseline = try pixels(input.image)
        let output = try pixels(EditRenderer.render(input, settings: settings).image)
        #expect((lumaVariance(output)) < (lumaVariance(baseline) * 0.75))
        #expect(abs((luminanceMean(output)) - (luminanceMean(baseline))) <= 4)
    }

    @Test
    func testColorNoiseReductionTargetsChromaSeparately() throws {
        let input = try fixture { x, y in
            let redNoise = noise(x, y, seed: 41) % 71 - 35
            let blueNoise = noise(x, y, seed: 93) % 71 - 35
            let greenNoise = Int((-0.2126 * Double(redNoise) - 0.0722 * Double(blueNoise)) / 0.7152)
            return (UInt8(125 + redNoise), UInt8(125 + greenNoise), UInt8(125 + blueNoise), 255)
        }
        var color = EditSettings.neutral
        color.colorNoiseReduction = 100
        var luminance = EditSettings.neutral
        luminance.luminanceNoiseReduction = 100
        let baseline = try pixels(input.image)
        let colorOutput = try pixels(EditRenderer.render(input, settings: color).image)
        let lumaOutput = try pixels(EditRenderer.render(input, settings: luminance).image)
        #expect((chromaVariance(colorOutput)) < (chromaVariance(baseline) * 0.6))
        #expect((chromaVariance(colorOutput)) < (chromaVariance(lumaOutput) * 0.7))
        #expect(abs((luminanceMean(colorOutput)) - (luminanceMean(baseline))) <= 4)
    }

    @Test
    func testExtentsProfileAndTransparentEdgesSurviveCombinedEdits() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let input = try fixture(width: 80, height: 48, space: space) { x, y in
            let alpha: UInt8 = x < 4 || y < 4 || x > 75 || y > 43 ? 0 : UInt8(80 + x * 2)
            return (UInt8(50 + x), UInt8(80 + y), 100, alpha)
        }
        var settings = EditSettings.neutral
        settings.exposure = 0.7
        settings.texture = 30
        settings.clarity = -20
        settings.dehaze = 20
        settings.luminanceNoiseReduction = 70
        settings.colorNoiseReduction = 80
        let output = try EditRenderer.render(input, settings: settings)
        #expect((output.image.width) == (input.image.width))
        #expect((output.image.height) == (input.image.height))
        #expect((output.image.colorSpace?.name) == (input.image.colorSpace?.name))
        let before = try pixels(input.image), after = try pixels(output.image)
        for index in stride(from: 3, to: before.count, by: 4) {
            #expect(abs((after[index]) - (before[index])) <= 1, "Alpha changed at pixel \(index / 4)")
            if before[index] == 0 {
                #expect((after[index - 3] + after[index - 2] + after[index - 1]) == (0))
            }
        }
    }

    @Test
    func testExtremeSettingsAreClampedAndRenderingStaysBounded() throws {
        let input = try fixture()
        var excessive = EditSettings.neutral
        excessive.exposure = 100
        excessive.contrast = -1_000
        excessive.saturation = .nan
        excessive.luminanceNoiseReduction = .infinity
        let output = try EditRenderer.render(input, settings: excessive)
        let expected = try EditRenderer.render(input, settings: excessive.normalized)
        #expect((try pixels(output.image)) == (try pixels(expected.image)))
        #expect((output.image.width) == (input.image.width))
        #expect((output.image.height) == (input.image.height))
    }

    private func fixture(
        width: Int = 64, height: Int = 64,
        space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, y in (UInt8(40 + x), UInt8(60 + y), 100, 255) }
    ) throws -> PreviewBitmap {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                bytes += [UInt8(Int(r) * Int(a) / 255), UInt8(Int(g) * Int(a) / 255), UInt8(Int(b) * Int(a) / 255), a]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }

    private func pixels(_ image: CGImage) throws -> [Double] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try #require(CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes.map(Double.init)
    }

    private func noise(_ x: Int, _ y: Int, seed: Int) -> Int {
        var value = UInt32(x &* 1_103 + y &* 19_097 + seed &* 811)
        value ^= value >> 13
        value = value &* 1_274_126_177
        return Int(value & 0x7fff_ffff)
    }

    private func lumaValues(_ values: [Double]) -> [Double] {
        stride(from: 0, to: values.count, by: 4).map { values[$0] * 0.2126 + values[$0 + 1] * 0.7152 + values[$0 + 2] * 0.0722 }
    }
    private func luminanceMean(_ values: [Double]) -> Double {
        let luma = lumaValues(values)
        return luma.reduce(0, +) / Double(luma.count)
    }
    private func lumaVariance(_ values: [Double]) -> Double {
        let luma = lumaValues(values), mean = luminanceMean(values)
        return luma.reduce(0) { $0 + pow($1 - mean, 2) } / Double(luma.count)
    }
    private func chromaVariance(_ values: [Double]) -> Double {
        var total = 0.0
        for index in stride(from: 0, to: values.count, by: 4) {
            let redDifference = values[index] - values[index + 1]
            let blueDifference = values[index + 2] - values[index + 1]
            total += redDifference * redDifference + blueDifference * blueDifference
        }
        return total / Double(values.count / 4)
    }
    private func meanAbsoluteDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }
}
