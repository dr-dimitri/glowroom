import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Reusable edit rendering sessions", .serialized)
struct EditRenderSessionTests {
    @Test
    func naturalBalancePrefixInvalidatesForStrengthColorNoiseAndLegacySwitches() throws {
        let cached = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let reference = EditRenderer.Session(lowPriority: true)
        let sources = try [fixture(seed: 19), fixture(seed: 113)]
        let cases: [(Double, Double, Double, Double)] = [
            (70, 50, 0, 0), (70, 0, 0, 0), (70, 100, 0, 0),
            (100, 100, 0, 0), (25, 100, 0, 0), (25, 50, 40, 0),
            (0, 50, 40, 65), (70, 50, 40, 65), (0, 50, 0, 65), (0, 50, 0, 0)
        ]
        // Consecutive requests reuse the selected image before a source change.
        // This detects missing color/strength keys as well as wrong-photo reuse.
        for (index, values) in cases.enumerated() {
            var settings = EditSettings.neutral
            settings.naturalBalanceAmount = values.0
            settings.naturalBalanceColorAmount = values.1
            settings.colorNoiseReduction = values.2
            settings.autoToneAmount = values.3
            settings.exposure = 0.1 + Double(index) * 0.01
            let source = sources[index < 5 ? 0 : 1]
            try equivalent(EditRenderer.render(source, settings: settings, session: cached),
                           EditRenderer.render(source, settings: settings, session: reference))
        }
    }

    @Test
    func naturalBalancePreservesSixteenBitWideGamutAcrossConcurrentSources() async throws {
        let cached = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let reference = EditRenderer.Session(lowPriority: true)
        let sources = try [fixture(seed: 7, sixteenBit: true), fixture(seed: 151, sixteenBit: true)]
        var settings = EditSettings.neutral
        settings.naturalBalanceAmount = 70
        settings.naturalBalanceColorAmount = 65
        settings.luminanceNoiseReduction = 20
        settings.exposure = 0.2
        let fixedSettings = settings
        let expected = try sources.map { try EditRenderer.render($0, settings: fixedSettings, session: reference) }
        try await withThrowingTaskGroup(of: (Int, PreviewBitmap).self) { group in
            for index in sources.indices {
                group.addTask { (index, try EditRenderer.render(sources[index], settings: fixedSettings, session: cached)) }
            }
            for try await (index, result) in group {
                #expect(result.image.bitsPerComponent == 16)
                try equivalent(result, expected[index])
                let original = try pixels16(sources[index].image), rendered = try pixels16(result.image)
                for offset in stride(from: 3, to: original.count, by: 4) {
                    #expect(abs(Int(original[offset]) - Int(rendered[offset])) <= 64)
                }
                #expect(rendered.enumerated().contains { $0.offset % 4 != 3 && $0.element % 257 != 0 })
            }
        }
    }

    @Test
    func cachedPrefixInvalidatesAcrossNoiseStrengthAutoAmountAndSourceChanges() throws {
        let interactive = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let reference = EditRenderer.Session(lowPriority: true)
        let first = try fixture(seed: 0)
        let second = try fixture(seed: 91)
        let originals = try [pixels(first.image), pixels(second.image)]
        var settings = EditSettings.neutral
        settings.exposure = 0.3
        for step in 0..<12 {
            settings.exposure += 0.05
            settings.autoToneAmount = step < 4 ? 40 : step < 8 ? 75 : 0
            settings.luminanceNoiseReduction = step < 3 ? 30 : step < 9 ? 70 : 0
            settings.colorNoiseReduction = step < 6 ? 60 : 0
            settings.texture = 15
            settings.clarity = -12
            let source = step.isMultiple(of: 3) ? second : first
            let output = try EditRenderer.render(source, settings: settings, session: interactive)
            let expected = try EditRenderer.render(source, settings: settings, session: reference)
            try equivalent(output, expected)
        }
        #expect(try pixels(first.image) == originals[0])
        #expect(try pixels(second.image) == originals[1])
    }

    @Test
    func concurrentSourcesProduceIndependentResults() async throws {
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let reference = EditRenderer.Session(lowPriority: true)
        let sources = try [fixture(seed: 3), fixture(seed: 137)]
        var settings = EditSettings.neutral
        settings.autoToneAmount = 60
        settings.colorNoiseReduction = 45
        settings.exposure = -0.2
        let fixedSettings = settings
        let expected = try sources.map { try EditRenderer.render($0, settings: fixedSettings, session: reference) }
        try await withThrowingTaskGroup(of: (Int, PreviewBitmap).self) { group in
            for index in sources.indices {
                group.addTask { (index, try EditRenderer.render(sources[index], settings: fixedSettings, session: session)) }
            }
            for try await (index, output) in group { try equivalent(output, expected[index]) }
        }
    }

    @Test
    func interactiveAndBackgroundPathsPreserveWideGamutAlphaAndSixteenBitOutput() throws {
        let source = try fixture(seed: 11, sixteenBit: true)
        var settings = EditSettings.neutral
        settings.autoToneAmount = 35
        settings.luminanceNoiseReduction = 30
        settings.exposure = 0.4
        let selected = try EditRenderer.render(source, settings: settings, priority: .selected)
        let background = try EditRenderer.render(source, settings: settings, priority: .thumbnail)
        #expect(selected.image.bitsPerComponent == 16)
        #expect(background.image.bitsPerComponent == 16)
        #expect(selected.image.colorSpace?.name == source.image.colorSpace?.name)
        let before = try pixels(source.image), after = try pixels(selected.image)
        for index in stride(from: 3, to: before.count, by: 4) {
            #expect(abs(Int(before[index]) - Int(after[index])) <= 1)
        }
        try equivalent(selected, background)
        let precise = try pixels16(selected.image), expected = try pixels16(background.image)
        let differences = zip(precise, expected).map { abs(Int($0) - Int($1)) }
        #expect(differences.max() ?? 0 <= 64)
        #expect(Double(differences.reduce(0, +)) / Double(differences.count) < 4)
        #expect(precise.enumerated().contains { $0.offset % 4 != 3 && $0.element % 257 != 0 },
                "The 16-bit result must retain color detail below an 8-bit code")
    }

    @Test
    func cancelledRenderDoesNotPoisonFollowingRequest() async throws {
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let source = try fixture(seed: 5)
        var settings = EditSettings.neutral
        settings.autoToneAmount = 70
        let fixedSettings = settings
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try EditRenderer.render(source, settings: fixedSettings, session: session)
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled render returned a result") }
        catch is CancellationError { }
        let recovered = try EditRenderer.render(source, settings: fixedSettings, session: session)
        let expected = try EditRenderer.render(source, settings: fixedSettings,
                                              session: EditRenderer.Session(lowPriority: true))
        try equivalent(recovered, expected)
    }

    private func equivalent(_ result: PreviewBitmap, _ expected: PreviewBitmap) throws {
        #expect(result.image.width == expected.image.width && result.image.height == expected.image.height)
        #expect(result.image.bitsPerComponent == expected.image.bitsPerComponent)
        #expect(result.image.colorSpace?.name == expected.image.colorSpace?.name)
        let lhs = try pixels(result.image), rhs = try pixels(expected.image)
        let differences = zip(lhs, rhs).map { abs(Int($0) - Int($1)) }
        #expect(differences.max() ?? 0 <= 1)
        #expect(Double(differences.reduce(0, +)) / Double(differences.count) < 0.1)
    }

    private func fixture(seed: Int, sixteenBit: Bool = false) throws -> PreviewBitmap {
        let width = 128, height = 80
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        var components: [UInt16] = []
        for y in 0..<height {
            for x in 0..<width {
                let alpha = y < 5 ? 0 : y < 20 ? 128 : 255
                let rgb = [(x * 3 + seed) % 256, (y * 5 + seed) % 256, (x + y + seed * 3) % 256]
                components.append(contentsOf: rgb.map {
                    let value = min(65_535, $0 * 257 + (sixteenBit ? (x * 17 + y + seed) % 257 : 0))
                    return UInt16(value * alpha / 255)
                })
                components.append(UInt16(alpha) * 257)
            }
        }
        let data: Data
        let info: CGBitmapInfo
        if sixteenBit {
            data = components.withUnsafeBytes { Data($0) }
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder16Little)
        } else {
            data = Data(components.map { UInt8($0 / 257) })
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let bits = sixteenBit ? 16 : 8
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: width * bits / 2, space: space, bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }

    private func pixels16(_ image: CGImage) throws -> [UInt16] {
        var values = [UInt16](repeating: 0, count: image.width * image.height * 4)
        try values.withUnsafeMutableBytes { raw in
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder16Little)
            let context = try #require(CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 16, bytesPerRow: image.width * 8, space: image.colorSpace!, bitmapInfo: info.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return values
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
