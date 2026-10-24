import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Versioned Float tone graph")
struct ToneProcessingV2Tests {
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    // CIContext is thread-safe; independent tests reuse one Float readback
    // context while the application's existing render workers stay bounded.
    private static let readback = CIContext(options: [
        .workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf
    ])

    @Test func neutralV2KeepsTheDecodedBitmapAndFineFloatDifferences() throws {
        let source = try fixture(width: 1_024) { x, _ in
            let value = Float(0.18 + Double(x) * 0.000_001)
            return (value, value, value, 1)
        }
        let settings = EditSettings(toneProcessingVersion: .consistentV2)
        let output = try EditRenderer.render(source, settings: settings)
        #expect(output.image === source.image)
        let graph = try graphValues(source, settings: settings)
        #expect(graph.allSatisfy { $0.isFinite })
        for x in 1..<1_024 { #expect(graph[x * 4] > graph[(x - 1) * 4]) }
        #expect(graph[4] - graph[0] < 1.0 / 255)
    }

    @Test func v2FloatResizeExpandsATrueMonochromeSourceIntoAnRGBProxy() throws {
        let bytes = Data(Array(repeating: [UInt8(64), UInt8(128)], count: 16 * 16).flatMap { $0 })
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 16,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = PreviewBitmap(image: image)
        let baseline = try read(CIImage(cgImage: image))
        let proxy = try EditRenderer.resized(source, width: 8, height: 8, priority: .selected,
                                            toneProcessingVersion: .consistentV2)
        #expect(proxy.image.colorSpace?.model == .rgb)
        #expect(proxy.image.bitmapInfo.contains(.floatComponents))
        #expect(proxy.image.bitsPerComponent == 32)
        let output = try read(CIImage(cgImage: proxy.image))
        for index in stride(from: 0, to: output.count, by: 4) {
            for channel in 0..<4 { expectClose(output[index + channel], Double(baseline[channel])) }
        }
    }

    @Test func perceptualContrastMatchesIndependentSignedSRGBAtTheTransferKnots() throws {
        let values = [-0.18, -0.003_131, -0.003_130_8, -0.003_130_6, -0.000_01,
                      0, 0.000_01, 0.003_130_6, 0.003_130_8, 0.003_131, 0.18, 1, 2]
        let source = try fixture(width: values.count) { x, _ in
            let value = Float(values[x]); return (value, value, value, 1)
        }
        let settings = EditSettings(contrast: 37, toneProcessingVersion: .consistentV2)
        let output = try graphValues(source, settings: settings)
        for (index, sample) in values.enumerated() {
            let expected = referenceRGB([Double(Float(sample)), Double(Float(sample)), Double(Float(sample))], settings: settings)
            for channel in 0..<3 { expectClose(output[index * 4 + channel], expected[channel]) }
        }
        #expect(output[0] < 0)
        #expect(output[(values.count - 1) * 4] > 1)
    }

    @Test(arguments: [-5.0, -1.5, 0.5, 2.0, 5.0])
    func exposureIsALinearGainForNegativeGamutAndHDRChannels(exposure: Double) throws {
        let source = try fixture(width: 8) { x, _ in
            let alpha: Float = x == 0 ? 0 : x == 1 ? 0.25 : 1
            return (-0.07, 0.003_130_8, 2, alpha)
        }
        let settings = EditSettings(exposure: exposure, developColor: .init(hdrEnabled: true), toneProcessingVersion: .consistentV2)
        let output = try graphValues(source, settings: settings)
        let gain = exp2(exposure)
        for x in 0..<8 {
            let alpha = x == 0 ? 0.0 : x == 1 ? 0.25 : 1.0
            for (channel, value) in [-0.07, 0.003_130_8, 2.0].enumerated() {
                expectClose(output[x * 4 + channel], Double(Float(value)) * gain * alpha)
            }
            expectClose(output[x * 4 + 3], alpha, absolute: 0.000_01)
        }
        #expect(Array(output.prefix(4)) == [0, 0, 0, 0])
    }

    @Test func toneRangesAreDeterminedBeforeLinearExposureAndRemainMonotone() throws {
        let source = try fixture(width: 1_024) { x, _ in
            let value = Float(x) / 1_023 * 2
            return (value, value, value, 1)
        }
        for exposure in [-5.0, 2.0] {
            for direction in [-1.0, 1.0] {
                let settings = EditSettings(exposure: exposure, contrast: 30,
                    highlights: 70 * direction, shadows: 60 * direction,
                    whites: 45 * direction, blacks: 25 * direction,
                    developColor: .init(hdrEnabled: true), toneProcessingVersion: .consistentV2)
                let output = try graphValues(source, settings: settings)
                for x in 0..<1_024 {
                    let input = Double(Float(x) / 1_023 * 2)
                    let expected = referenceRGB([input, input, input], settings: settings)[0]
                    expectClose(output[x * 4], expected)
                    if x > 0 { #expect(output[x * 4] >= output[(x - 1) * 4] - 0.000_02) }
                }
            }
        }
    }

    @Test func theFullToneAndColorOrderMatchesTheIndependentReference() throws {
        let samples: [[Float]] = [[-0.04, 0.18, 1.2], [0.003_130_8, 0.12, 0.7], [2, 1.4, 0.8]]
        let source = try fixture(width: samples.count) { x, _ in
            (samples[x][0], samples[x][1], samples[x][2], 0.25)
        }
        let settings = EditSettings(exposure: 0.7, contrast: 30, highlights: -20, shadows: 15,
            whites: 10, blacks: -5, dehaze: 8, vibrance: 20, saturation: -10,
            developColor: .init(hdrEnabled: true), toneProcessingVersion: .consistentV2)
        let output = try graphValues(source, settings: settings)
        for x in samples.indices {
            let expected = referenceRGB(samples[x].map(Double.init), settings: settings)
            for channel in 0..<3 { expectClose(output[x * 4 + channel], expected[channel] * 0.25) }
            expectClose(output[x * 4 + 3], 0.25)
        }
    }

    @Test func sdrP3NegativeWorkingCoordinatesSurviveNoiseAndPresence() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let source = try fixture(width: 16, height: 16, colorSpace: p3) { _, _ in (0, 1, 0, 0.5) }
        let baseline = try read(CIImage(cgImage: source.image))
        #expect(baseline[0] < -0.01 && baseline[2] < -0.01,
            "An in-gamut SDR-P3 green must actually have negative linear-sRGB coordinates")
        let settings = EditSettings(exposure: -0.5, texture: 35, clarity: 25,
            luminanceNoiseReduction: 40, colorNoiseReduction: 40, toneProcessingVersion: .consistentV2)
        let output = try graphValues(source, settings: settings)
        for index in stride(from: 0, to: output.count, by: 4) {
            for channel in 0..<3 { expectClose(output[index + channel], Double(baseline[index + channel]) * exp2(-0.5)) }
            expectClose(output[index + 3], 0.5)
        }
    }

    @Test func realHDRGrayRetainsItsRangeThroughNoiseAndPresence() throws {
        let source = try fixture(width: 16, height: 16) { _, _ in (2, 2, 2, 0.25) }
        let settings = EditSettings(exposure: 0.5, texture: 35, clarity: 25,
            luminanceNoiseReduction: 40, colorNoiseReduction: 40,
            developColor: .init(hdrEnabled: true), toneProcessingVersion: .consistentV2)
        let output = try graphValues(source, settings: settings)
        for index in stride(from: 0, to: output.count, by: 4) {
            for channel in 0..<3 { expectClose(output[index + channel], 2 * exp2(0.5) * 0.25) }
            expectClose(output[index + 3], 0.25)
        }
        let preview = try EditRenderer.render(source, settings: settings)
        #expect(preview.image.bitmapInfo.contains(.floatComponents))
        let visible = try read(CIImage(cgImage: preview.image))
        #expect(visible[0] / visible[3] > 2)
    }

    @Test func sharpeningPreservesP3CoordinatesAndSDRIndependentHDRHeadroom() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let p3Source = try fixture(width: 16, height: 16, colorSpace: p3) { _, _ in (0, 1, 0, 0.25) }
        let hdrSource = try fixture(width: 16, height: 16) { _, _ in (2, 2, 2, 0.25) }
        for source in [p3Source, hdrSource] {
            let baseline = try read(CIImage(cgImage: source.image))
            for masking in [0.0, 40.0] {
                // The test intentionally leaves HDR output disabled: the lazy
                // sharpening node must preserve gamut/headroom before the
                // later, explicitly chosen target-profile raster boundary.
                let settings = EditSettings(sharpeningAmount: 150, sharpeningRadius: 3,
                    sharpeningDetail: 100, sharpeningMasking: masking, toneProcessingVersion: .consistentV2)
                let output = try graphValues(source, settings: settings)
                for index in output.indices { expectClose(output[index], Double(baseline[index])) }
            }
        }
    }

    @Test func activeBalancingRetainsRealHDRAndSignedP3GamutCoordinates() throws {
        let source = try fixture(width: 128, height: 8) { x, _ in
            if x >= 124 { return (2, 2, 2, 0.5) }
            // In-gamut linear Display-P3 green expressed in the working space.
            if x >= 116 { return (-0.224_94, 1.042_06, -0.078_65, 0.5) }
            let value = Float(x) / 115 * 0.9 + 0.01
            return (value, value, value, 0.5)
        }
        let baseline = try read(CIImage(cgImage: source.image))
        for settings in [EditSettings(autoToneAmount: 100, toneProcessingVersion: .consistentV2),
                         EditSettings(naturalBalanceAmount: 80, toneProcessingVersion: .consistentV2)] {
            let output = try graphValues(source, settings: settings)
            #expect(zip(output.prefix(116 * 4), baseline.prefix(116 * 4)).contains { abs($0 - $1) > 0.000_1 },
                "The fixture must exercise an active balance curve")
            for x in 124..<128 {
                for channel in 0..<4 { expectClose(output[x * 4 + channel], Double(baseline[x * 4 + channel])) }
            }
            #expect(output[116 * 4] < 0 && output[116 * 4 + 2] < 0)
            for index in stride(from: 3, to: output.count, by: 4) { expectClose(output[index], 0.5) }
        }
    }

    @Test func fullLocalMaskInheritsTheImageVersionAndMatchesGlobalAdjustments() throws {
        let source = try fixture(width: 128, height: 8) { x, y in
            let value = Float(x) / 127 * 1.8 - 0.08
            return (value, value * 0.6, value * 0.3, y == 0 ? 0.25 : 1)
        }
        let correction = LocalAdjustmentSettings(exposure: 0.7, contrast: 35, highlights: -20,
            shadows: 25, whites: 15, blacks: -10, texture: 20, clarity: 10,
            dehaze: 8, vibrance: 15, saturation: -10)
        var global = correction.editSettings
        global.toneProcessingVersion = .consistentV2
        let coverage = try LocalMaskRaster(width: 1, height: 1, bytes: Data([255]))
        let mask = try LocalAdjustmentMask(shape: .subject(coverage), opacity: 1, feather: 0)
        let layer = try LocalAdjustment(name: "V2 full mask", mask: mask, settings: correction)
        let local = EditSettings(localAdjustments: [layer], toneProcessingVersion: .consistentV2)
        let direct = try graphValues(source, settings: global)
        let selected = try graphValues(source, settings: local)
        #expect(direct.count == selected.count)
        for index in direct.indices { expectClose(selected[index], Double(direct[index]), absolute: 0.000_1) }
    }

    @Test func cachedNoisePrefixCannotCrossProcessingVersions() throws {
        let source = try fixture(width: 16, height: 16) { _, _ in (-0.08, 0.5, 2, 0.5) }
        let cached = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        let fresh = EditRenderer.Session(lowPriority: true)
        for version in [ToneProcessingVersion.legacyV1, .consistentV2, .legacyV1, .consistentV2] {
            let settings = EditSettings(exposure: -0.5, texture: 15,
                luminanceNoiseReduction: 35, colorNoiseReduction: 25,
                developColor: .init(hdrEnabled: true), toneProcessingVersion: version)
            let actual = try read(CIImage(cgImage: EditRenderer.render(source, settings: settings, session: cached).image))
            let expected = try read(CIImage(cgImage: EditRenderer.render(source, settings: settings, session: fresh).image))
            for index in actual.indices { expectClose(actual[index], Double(expected[index]), absolute: 0.000_1) }
            if version == .consistentV2 { #expect(actual[0] < 0) }
        }
    }

    @Test func previewAndFullGraphAgreeAtTheSameHDRQuantization() throws {
        let source = try fixture(width: 128, height: 8) { x, _ in
            let value = Float(x) / 127 * 2 - 0.05
            return (value, value * 0.6, value * 0.3, 0.5)
        }
        let settings = EditSettings(exposure: 0.6, contrast: 35, highlights: -20, shadows: 10,
            texture: 15, clarity: 10, developColor: .init(temperature: 7_500, tint: 8, profile: .vivid, hdrEnabled: true),
            toneProcessingVersion: .consistentV2)
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        let preview = try EditRenderer.render(source, settings: settings, session: session)
        let graph = try EditRenderer.filterGraph(source.image, settings: settings)
        let reference = try #require(session.context(for: .consistentV2).createCGImage(graph, from: graph.extent,
            format: .RGBAf, colorSpace: Self.linearSpace, deferred: false))
        // V2 HDR output preserves the graph's 32-bit Float precision, including
        // values above the half-float ceiling. Compare the same output contract.
        #expect(preview.image.bitsPerComponent == 32 && preview.image.bitmapInfo.contains(.floatComponents))
        #expect(reference.bitsPerComponent == 32 && reference.bitmapInfo.contains(.floatComponents))
        let actualValues = try read(CIImage(cgImage: preview.image))
        let referenceValues = try read(CIImage(cgImage: reference))
        for index in actualValues.indices { expectClose(actualValues[index], Double(referenceValues[index]), absolute: 0.000_1) }
    }

    @Test func automaticAndRequestedSoftwareContextsAgreeWithinFloatTolerance() throws {
        let source = try fixture(width: 64, height: 8) { x, _ in
            let value = Float(x) / 63 * 2 - 0.02
            return (value, value * 0.7, value * 0.4, 0.5)
        }
        let settings = EditSettings(exposure: 0.3, contrast: 25, shadows: 15, dehaze: 5,
            toneProcessingVersion: .consistentV2)
        let graph = try EditRenderer.filterGraph(source.image, settings: settings)
        let automatic = EditRenderer.Session(lowPriority: true)
        let requestedSoftware = EditRenderer.Session(lowPriority: true, softwareRenderer: true)
        let actual = try read(graph, context: automatic.context(for: .consistentV2))
        let reference = try read(graph, context: requestedSoftware.context(for: .consistentV2))
        // A requested software context does not establish actual CPU execution.
        for index in actual.indices { expectClose(actual[index], Double(reference[index]), absolute: 0.000_2) }
    }

    @Test func legacyV1KeepsFrozenPreMigrationEquationAnchors() throws {
        let source = try fixture(width: 1) { _, _ in (0.015, 0.18, 0.74, 0.25) }
        for hdr in [false, true] {
            let settings = EditSettings(exposure: 0.7, contrast: 30, highlights: -20, shadows: 15,
                whites: 10, blacks: -5, dehaze: 8, vibrance: 20, saturation: -10,
                developColor: .init(hdrEnabled: hdr), toneProcessingVersion: .legacyV1)
            // Frozen from the pre-migration V1 Gamma-2.2 equations. These are
            // analytical anchors, not measurements from a historical binary.
            let expected = [0.006_571_601_750_118_459, 0.071_951_459_170_148_14,
                            hdr ? 0.292_133_022_206_921_56 : 0.25, 0.25]
            let actual = try graphValues(source, settings: settings)
            for channel in 0..<4 { expectClose(actual[channel], expected[channel], absolute: 0.000_3) }
        }
    }

    private func fixture(width: Int, height: Int = 1,
                         colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                         pixel: (Int, Int) -> (Float, Float, Float, Float)) throws -> PreviewBitmap {
        var components: [Float] = []
        components.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, alpha) = pixel(x, y)
                components.append(contentsOf: [r * alpha, g * alpha, b * alpha, alpha])
            }
        }
        let data = components.withUnsafeBytes { Data($0) }
        let input = CIImage(bitmapData: data, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace)
        let context = CIContext(options: [.workingColorSpace: colorSpace, .workingFormat: CIFormat.RGBAf])
        let image = try #require(context.createCGImage(input, from: input.extent,
            format: .RGBAf, colorSpace: colorSpace, deferred: false))
        return PreviewBitmap(image: image)
    }

    private func graphValues(_ source: PreviewBitmap, settings: EditSettings) throws -> [Float] {
        try read(EditRenderer.filterGraph(source.image, settings: settings))
    }

    private func read(_ image: CIImage, context: CIContext? = nil) throws -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        #expect(width > 0 && height > 0)
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { buffer in
            (context ?? Self.readback).render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                bounds: image.extent, format: .RGBAf, colorSpace: Self.linearSpace)
        }
        #expect(values.allSatisfy { $0.isFinite })
        return values
    }

    private func expectClose(_ actual: Float, _ expected: Double, absolute: Double = 0.000_03,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.isFinite && expected.isFinite &&
            abs(Double(actual) - expected) <= absolute + abs(expected) * 0.000_03,
            "Float graph \(actual) differs from independent reference \(expected)", sourceLocation: sourceLocation)
    }

    /// Independent Double reference: explicit signed IEC sRGB encoding,
    /// contrast/tone selection, decoding, linear 2^EV, then perceptual color.
    /// It deliberately does not call SignedSRGB or any application tone helper.
    private func referenceRGB(_ input: [Double], settings: EditSettings) -> [Double] {
        var rgb = input.map(encode)
        for channel in 0..<3 {
            let u = min(max(rgb[channel], 0), 1)
            rgb[channel] += settings.contrast / 100 * u * (1 - u) * (2 * u - 1)
        }
        let y = min(max(luma(rgb), 0), 1)
        let shift = settings.shadows / 100 * 0.22 * (1 - smoothstep(0.05, 0.65, y)) +
            settings.highlights / 100 * 0.22 * smoothstep(0.35, 0.95, y) +
            settings.blacks / 100 * 0.11 * (1 - smoothstep(0, 0.25, y)) +
            settings.whites / 100 * 0.11 * smoothstep(0.75, 1, y)
        rgb = rgb.map { encode(decode($0 + shift) * exp2(settings.exposure)) }
        let removeVeil = max(settings.dehaze / 100, 0) * 0.12
        rgb = rgb.map { ($0 - removeVeil) / (1 - removeVeil) }
        let addVeil = max(-settings.dehaze / 100, 0) * 0.18
        rgb = rgb.map { $0 * (1 - addVeil) + 0.85 * addVeil }
        let luminance = luma(rgb)
        let spread = min(max(rgb.max()! - rgb.min()!, 0), 1)
        let scale = (1 + settings.saturation / 100) * (1 + settings.vibrance / 100 * 0.85 * (1 - spread))
        return rgb.map { decode(luminance + ($0 - luminance) * scale) }
    }

    private func encode(_ value: Double) -> Double {
        let magnitude = abs(value)
        let result = magnitude <= 0.003_130_8 ? 12.92 * magnitude : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return value < 0 ? -result : result
    }
    private func decode(_ value: Double) -> Double {
        let magnitude = abs(value)
        let result = magnitude <= 0.040_45 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return value < 0 ? -result : result
    }
    private func luma(_ value: [Double]) -> Double { value[0] * 0.2126 + value[1] * 0.7152 + value[2] * 0.0722 }
    private func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        let t = min(max((value - lower) / (upper - lower), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
