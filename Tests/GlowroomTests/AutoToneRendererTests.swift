import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Automatic tone balancing")
struct AutoToneRendererTests {
    @Test
    func zeroAmountKeepsOriginalPixelsAndManualSettings() throws {
        let input = try gray { x, _ in UInt8(x) }
        let unchanged = try EditRenderer.render(input, settings: .neutral)
        #expect(unchanged.image === input.image)
        var manual = EditSettings.neutral
        manual.exposure = 0.7
        manual.contrast = 15
        var explicitOff = manual
        explicitOff.autoToneAmount = 0
        #expect(try bytes(EditRenderer.render(input, settings: manual).image) == bytes(EditRenderer.render(input, settings: explicitOff).image))
    }

    @Test
    func highDynamicRangeRevealsBothTailsWithoutFlatteningOrClipping() throws {
        let levels: [UInt8] = [0, 5, 12, 24, 40, 60, 90, 128, 165, 195, 218, 232, 244, 250, 255]
        let input = try gray(width: levels.count, height: 40) { x, _ in levels[x] }
        let output = try redRow(render(input))
        #expect(output[3] > Int(levels[3]) + 3)
        #expect(output[11] < Int(levels[11]) - 3)
        #expect(output[0] == 0)
        #expect(output[14] == 255)
        #expect(output[11] - output[3] > 175, "The image must retain a broad tonal range")
        #expect(abs(output[7] - 128) <= 5)
        for x in 1..<levels.count {
            #expect(output[x] > output[x - 1])
            if x < levels.count - 1 { #expect(output[x] > 0 && output[x] < 255) }
        }
    }

    @Test
    func dominantDarkAndBrightScenesKeepTheOppositeTailSafe() throws {
        let dark = try gray(width: 100, height: 30) { x, _ in x < 90 ? 30 : 230 }
        let bright = try gray(width: 100, height: 30) { x, _ in x < 10 ? 30 : 230 }
        let darkOutput = try redRow(render(dark))
        let brightOutput = try redRow(render(bright))
        for output in [darkOutput, brightOutput] {
            #expect(output.first! >= 32, "A bright-dominant scene must not crush its small dark subject")
            #expect(output.last! <= 228, "A dark-dominant scene must not blow out its bright window")
            #expect(output.last! - output.first! > 140)
        }
        #expect(darkOutput[0] > brightOutput[0], "Correction must adapt to the scene distribution")
        #expect(brightOutput[99] < darkOutput[99])

        let nearShadowBoundary = try gray(width: 100) { x, _ in x < 10 ? 61 : 230 }
        let nearHighlightBoundary = try gray(width: 100) { x, _ in x < 90 ? 30 : 194 }
        #expect(try redRow(render(nearShadowBoundary))[0] >= 61)
        #expect(try redRow(render(nearHighlightBoundary))[99] <= 194)
    }

    @Test
    func balancedGradientChangesSubtlyAndLowContrastSceneGainsSeparation() throws {
        let balanced = try gray { x, _ in UInt8(x) }
        let balancedOutput = try redRow(render(balanced))
        let meanDifference = zip(balancedOutput, 0..<256).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / 256
        #expect(meanDifference < 5)
        #expect(abs(balancedOutput[128] - 128) <= 2)

        let lowContrast = try gray(width: 65) { x, _ in UInt8(96 + x) }
        let output = try redRow(render(lowContrast))
        #expect(output.last! - output.first! >= 72, "A narrow middle-tone range should gain useful contrast")
        #expect(output.first! > 75 && output.last! < 180)
    }

    @Test
    func flatBlackWhiteAndAlmostFlatNoiseStayStable() throws {
        for value: UInt8 in [0, 2, 64, 128, 250, 255] {
            let input = try gray(width: 32) { _, _ in value }
            let output = try redRow(render(input))
            #expect(output.allSatisfy { abs($0 - Int(value)) <= 1 })
        }
        let noisy = try gray(width: 32) { x, y in UInt8(126 + (x + y) % 4) }
        let before = try bytes(noisy.image), after = try bytes(render(noisy).image)
        #expect(zip(before, after).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    @Test
    func gradientsStayMonotoneAndDoNotAcquireNewClippedPixels() throws {
        for bright in [false, true] {
            let input = try gray { x, _ in
                let dark = Int((255 * pow(Double(x) / 255, 2)).rounded())
                return UInt8(bright ? 255 - dark : dark)
            }
            let before = try redRow(input), after = try redRow(render(input))
            for i in 1..<after.count {
                #expect(bright ? after[i] <= after[i - 1] : after[i] >= after[i - 1])
            }
            for i in before.indices where before[i] > 0 && before[i] < 255 {
                #expect(after[i] > 0 && after[i] < 255)
            }
            let curve = try AutoToneCurve.analyze(input.image, amount: 100)
            var previous = 0.0
            for step in 0...10_000 {
                let value = curve.value(at: Double(step) / 10_000)
                #expect(value >= previous)
                #expect(value.isFinite && value >= 0 && value <= 1)
                previous = value
            }
        }
    }

    @Test
    func intermediateStrengthIsConservativeAndManualExposureFollowsAuto() throws {
        let input = try gray(width: 128) { x, _ in x < 64 ? 30 : 230 }
        let gentle = try redRow(render(input, amount: 25))
        let full = try redRow(render(input, amount: 100))
        #expect(gentle[0] > 30 && gentle[0] < full[0])
        #expect(gentle[127] < 230 && gentle[127] > full[127])
        var settings = EditSettings.neutral
        settings.autoToneAmount = 100
        settings.exposure = 0.5
        let manual = try redRow(EditRenderer.render(input, settings: settings))
        #expect(manual[0] > full[0] + 5)
        #expect(manual[127] > full[127] + 5)
        #expect(try bytes(render(input).image) == bytes(render(input).image), "Automatic analysis must be reproducible")
    }

    @Test
    func colorHueAlphaDimensionsAndProfileSurvive() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let input = try fixture(width: 128, height: 48, space: space) { x, y in
            let colors: [(UInt8, UInt8, UInt8)] = [(18, 32, 24), (210, 240, 220), (180, 24, 42), (22, 165, 38), (26, 40, 170)]
            let color = colors[(x / 16) % colors.count]
            return (color.0, color.1, color.2, y < 4 ? 0 : y < 12 ? 128 : 255)
        }
        let output = try render(input)
        #expect(output.image.width == input.image.width && output.image.height == input.image.height)
        #expect(output.image.colorSpace?.name == input.image.colorSpace?.name)
        // Inspect in the original profile; an sRGB readback could itself clip P3.
        let before = try bytes(input.image, space: space), after = try bytes(output.image, space: space)
        var changed = false
        for i in stride(from: 0, to: before.count, by: 4) {
            #expect(abs(Int(before[i + 3]) - Int(after[i + 3])) <= 1)
            if before[i + 3] == 0 { #expect(after[i] == 0 && after[i + 1] == 0 && after[i + 2] == 0) }
            guard before[i + 3] == 255 else { continue }
            let a = (0..<3).map { Double(before[i + $0]) }
            let b = (0..<3).map { Double(after[i + $0]) }
            changed = changed || zip(a, b).contains { abs($0 - $1) > 2 }
            #expect(b.allSatisfy { $0 > 0 && $0 < 255 })
            let ac = [a[0] - a[1], a[2] - a[1]], bc = [b[0] - b[1], b[2] - b[1]]
            let norm = sqrt((ac[0] * ac[0] + ac[1] * ac[1]) * (bc[0] * bc[0] + bc[1] * bc[1]))
            if norm > 100 { #expect((ac[0] * bc[0] + ac[1] * bc[1]) / norm > 0.98) }
        }
        #expect(changed)
    }

    @Test
    func liftingSaturatedSubjectsDoesNotClipPreviouslyUnclippedChannels() throws {
        for color: (UInt8, UInt8, UInt8) in [(250, 8, 20), (15, 10, 250), (20, 250, 30)] {
            let input = try fixture(width: 100, height: 32) { x, _ in
                x < 80 ? (30, 30, 30, 255) : (color.0, color.1, color.2, 255)
            }
            let output = try bytes(render(input).image)
            #expect((0..<3).allSatisfy { output[99 * 4 + $0] > 0 && output[99 * 4 + $0] < 255 })
        }
    }

    @Test
    func transparentMarginsDoNotBiasTheHistogram() throws {
        let original = try gray(width: 128, height: 64) { x, _ in x < 64 ? 24 : 220 }
        let padded = try fixture(width: 256, height: 128) { x, y in
            guard (64..<192).contains(x), (32..<96).contains(y) else { return (0, 0, 0, 0) }
            let value: UInt8 = x < 128 ? 24 : 220
            return (value, value, value, 255)
        }
        let before = try AutoToneCurve.analyze(original.image, amount: 100)
        let after = try AutoToneCurve.analyze(padded.image, amount: 100)
        #expect(zip(before.ordinates, after.ordinates).allSatisfy { abs($0 - $1) < 0.000_001 })
        let transparent = try fixture(width: 64, height: 64) { _, _ in (0, 0, 0, 0) }
        #expect(try AutoToneCurve.analyze(transparent.image, amount: 100).isIdentity)
    }

    @Test
    func boundedSamplingKeepsProgressivePreviewCurvesConsistent() throws {
        func sample(_ x: Int) -> UInt8 { x < 80 ? UInt8(12 + x / 2) : x < 170 ? UInt8(100 + (x - 80)) : UInt8(220 + (x - 170) / 3) }
        let small = try gray(width: 256, height: 128) { x, _ in sample(x) }
        let large = try gray(width: 1024, height: 512) { x, _ in sample(x / 4) }
        let smallCurve = try AutoToneCurve.analyze(small.image, amount: 100)
        let largeCurve = try AutoToneCurve.analyze(large.image, amount: 100)
        #expect(zip(smallCurve.ordinates, largeCurve.ordinates).allSatisfy { abs($0 - $1) < 0.004 })
    }

    @Test
    func canceledAnalysisStopsBeforeWorkingOnTheBitmap() async throws {
        let input = try gray { x, _ in UInt8(x) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AutoToneCurve.analyze(input.image, amount: 100)
        }
        do { _ = try await task.value; Issue.record("Canceled analysis unexpectedly succeeded") }
        catch is CancellationError { }
    }

    private func render(_ bitmap: PreviewBitmap, amount: Double = 100) throws -> PreviewBitmap {
        var settings = EditSettings.neutral
        settings.autoToneAmount = amount
        return try EditRenderer.render(bitmap, settings: settings)
    }

    private func gray(width: Int = 256, height: Int = 32, pixel: (Int, Int) -> UInt8) throws -> PreviewBitmap {
        try fixture(width: width, height: height) { x, y in
            let value = pixel(x, y)
            return (value, value, value, 255)
        }
    }

    private func fixture(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                         pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> PreviewBitmap {
        var values = [UInt8]()
        values.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                values += [UInt8(Int(r) * Int(a) / 255), UInt8(Int(g) * Int(a) / 255), UInt8(Int(b) * Int(a) / 255), a]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(values) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }

    private func redRow(_ bitmap: PreviewBitmap) throws -> [Int] {
        let values = try bytes(bitmap.image)
        return (0..<bitmap.image.width).map { Int(values[$0 * 4]) }
    }

    private func bytes(_ image: CGImage, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> [UInt8] {
        var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try values.withUnsafeMutableBytes { data in
            let context = try #require(CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return values
    }
}
