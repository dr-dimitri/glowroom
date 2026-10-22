import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Shared global and masked tone controls")
struct ToneControlRegressionTests {
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    // CIContext is thread-safe: reuse readback resources while independent
    // regression tests run in parallel, instead of creating a context per slider.
    private static let readback = CIContext(options: [
        .workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf
    ])

    private enum Control: CaseIterable {
        case exposure, contrast, highlights, shadows, whites, blacks

        var maximum: Double { self == .exposure ? 5 : 100 }
        var sample: Float {
            switch self {
            case .exposure: 0.18
            case .contrast: 0.5
            case .highlights: 0.65
            case .shadows: 0.08
            case .whites: 0.85
            case .blacks: 0.01
            }
        }
        func settings(_ value: Double) -> LocalAdjustmentSettings {
            switch self {
            case .exposure: .init(exposure: value)
            case .contrast: .init(contrast: value)
            case .highlights: .init(highlights: value)
            case .shadows: .init(shadows: value)
            case .whites: .init(whites: value)
            case .blacks: .init(blacks: value)
            }
        }
    }

    @Test func everyToneControlHasTheSameEffectGloballyAndInsideAFullMask() throws {
        let source = try fixture { x, _ in
            let value = Float(x) / 63
            return (value, value * 0.7, value * 0.4, 1)
        }
        for control in Control.allCases {
            for direction in [-1.0, 1.0] {
                let correction = control.settings(direction * control.maximum)
                let global = try values(EditRenderer.render(source, settings: correction.editSettings).image)
                let local = try values(EditRenderer.render(source, settings: masked(correction)).image)
                #expect(maximumDifference(global, local) < 0.002,
                    "Global and local \(control), direction \(direction), must use identical tone processing")
            }
        }
    }

    @Test func exposureAndEachToneRangeRespondInBothDirections() throws {
        for control in Control.allCases where control != .contrast {
            let source = try fixture { _, _ in (control.sample, control.sample, control.sample, 1) }
            let baseline = try values(source.image)[0]
            let dark = try values(EditRenderer.render(source,
                settings: masked(control.settings(-control.maximum))).image)[0]
            let light = try values(EditRenderer.render(source,
                settings: masked(control.settings(control.maximum))).image)[0]
            #expect(dark < baseline - 0.002, "Negative \(control) must darken its tonal range")
            #expect(light > baseline + 0.002, "Positive \(control) must brighten its tonal range")
        }
    }

    @Test func sourceToneRangesRemainAdjustableAfterStrongExposureChanges() throws {
        let cases: [(Control, Double)] = [
            (.highlights, -5), (.whites, -5),
            (.shadows, 2), (.blacks, 2), (.shadows, 5), (.blacks, 5)
        ]
        for (control, exposure) in cases {
            let source = try fixture(width: 1, height: 1) { _, _ in
                (control.sample, control.sample, control.sample, 1)
            }
            // Positive exposure can exceed SDR white. Floating HDR readback
            // distinguishes an inactive tone range from output clipping.
            var exposed = LocalAdjustmentSettings(exposure: exposure).editSettings
            exposed.developColor.hdrEnabled = true
            let baseline = try values(EditRenderer.render(source, settings: exposed).image)[0]
            for direction in [-1.0, 1.0] {
                var correction = control.settings(direction * 100)
                correction.exposure = exposure
                var global = correction.editSettings
                global.developColor.hdrEnabled = true
                var local = try masked(correction)
                local.developColor.hdrEnabled = true
                let direct = try values(EditRenderer.render(source, settings: global).image)
                let selected = try values(EditRenderer.render(source, settings: local).image)
                #expect(maximumDifference(direct, selected) < max(0.002, abs(direct[0]) * 0.002))
                // A meaningful signed change is required, not just different
                // rounding: the former post-exposure thresholds failed here.
                #expect((selected[0] - baseline) * Float(direction) > baseline * 0.05,
                    "\(control) must still affect its source tones at \(exposure) EV, direction \(direction)")
            }
        }
    }

    @Test func exposureAloneRetainsItsLinearGainAndAlpha() throws {
        let source = try fixture(width: 1, height: 1) { _, _ in (0.08, 0.2, 1.1, 0.65) }
        let baseline = try values(source.image)
        for exposure in [-5.0, -2, 2, 5] {
            var settings = LocalAdjustmentSettings(exposure: exposure).editSettings
            settings.developColor.hdrEnabled = true
            let output = try values(EditRenderer.render(source, settings: settings).image)
            let gain = Float(exp2(exposure))
            for channel in 0..<3 {
                let expected = baseline[channel] * gain
                #expect(abs(output[channel] - expected) < max(0.000_1, abs(expected) * 0.003),
                    "Exposure alone must remain a linear-light EV gain in every RGB channel")
            }
            #expect(abs(output[3] - baseline[3]) < 0.002)
        }
    }

    @Test func exposureAndAllToneRangeSignCombinationsPreserveGradientOrder() throws {
        let source = try fixture(width: 256, height: 1) { x, _ in
            // Include extended source highlights to catch premature clamping
            // before a later negative exposure brings them back into SDR.
            let value = Float(x) / 255 * 2
            return (value, value, value, 1)
        }
        // Tiny independent render graphs use Core Image's parallel backend.
        // Keep this parameter sweep serial to avoid 128 competing render jobs.
        for signs in 0..<16 {
            func amount(_ bit: Int) -> Double { signs & (1 << bit) == 0 ? -100 : 100 }
            for contrast in [-100.0, 100] {
                for exposure in [-5.0, 5] {
                    let correction = LocalAdjustmentSettings(exposure: exposure, contrast: contrast,
                        highlights: amount(0), shadows: amount(1), whites: amount(2), blacks: amount(3))
                    for hdr in [false, true] {
                        var settings = correction.editSettings
                        settings.developColor.hdrEnabled = hdr
                        let output = try values(EditRenderer.render(source, settings: settings).image)
                        #expect(output.allSatisfy { $0.isFinite })
                        for x in 1..<256 {
                            let previous = output[(x - 1) * 4], next = output[x * 4]
                            #expect(next >= previous - max(0.000_03, previous * 0.002),
                                "Tone signs \(signs), contrast \(contrast), exposure \(exposure), HDR \(hdr) reversed a gradient at \(x)")
                        }
                    }
                }
            }
        }
    }

    @Test func contrastPreservesBlackWhiteAndGradientOrderAtBothExtremes() throws {
        let source = try fixture(width: 256) { x, _ in
            let value = Float(x) / 255
            return (value, value, value, 1)
        }
        let baseline = try values(source.image)
        for amount in [-100.0, -50, 50, 100] {
            let result = try values(EditRenderer.render(source,
                settings: masked(.init(contrast: amount))).image)
            #expect(result[0] < 0.000_1, "Reducing contrast must not add a gray floor to black")
            #expect(abs(result[255 * 4] - 1) < 0.002, "Contrast must retain the white endpoint")
            for x in 1..<256 {
                #expect(result[x * 4] >= result[(x - 1) * 4] - 0.000_5,
                    "Contrast \(amount) must not reverse a gradient at \(x)")
            }
            let dark = 16 * 4, light = 160 * 4
            if amount > 0 {
                #expect(result[dark] < baseline[dark] - 0.002)
                #expect(result[light] > baseline[light] + 0.002)
            } else {
                #expect(result[dark] > baseline[dark] + 0.002)
                #expect(result[light] < baseline[light] - 0.002)
            }
        }
    }

    @Test func toneControlsLeaveUnselectedPixelsUnchanged() throws {
        let source = try fixture { x, _ in
            let value = Float(x) / 64
            return (value, value * 0.6, 0.1, 1)
        }
        let baseline = try values(source.image)
        let raster = try LocalMaskRaster(width: 64, height: 8,
            bytes: Data((0..<(64 * 8)).map { $0 % 64 < 32 ? UInt8(255) : 0 }))
        for control in Control.allCases {
            for direction in [-1.0, 1.0] {
                let correction = control.settings(direction * control.maximum)
                let output = try values(EditRenderer.render(source,
                    settings: masked(correction, raster: raster)).image)
                let global = try values(EditRenderer.render(source, settings: correction.editSettings).image)
                // Avoid the interpolated boundary: assert fully selected and
                // completely unselected interiors independently.
                for y in 0..<8 {
                    for x in [8, 24, 40, 56] {
                        for channel in 0..<4 {
                            let index = (y * 64 + x) * 4 + channel
                            let expected = x < 32 ? global[index] : baseline[index]
                            #expect(abs(output[index] - expected) < 0.002,
                                "\(control) must respect coverage at x=\(x)")
                        }
                    }
                }
            }
        }
    }

    @Test func maskStrengthBlendsEveryToneControlInLinearLight() throws {
        let source = try fixture { _, _ in (0.7, 0.3, 0.06, 1) }
        let baseline = try values(source.image)
        for correction in Control.allCases.map({ $0.settings(-$0.maximum) }) + [allMinimum] + exposureCombinations {
            let full = try values(EditRenderer.render(source, settings: masked(correction)).image)
            let partial = try values(EditRenderer.render(source, settings: masked(correction, opacity: 0.77)).image)
            for channel in 0..<4 {
                let expected = baseline[channel] * 0.23 + full[channel] * 0.77
                #expect(abs(partial[channel] - expected) < 0.002,
                    "77% mask strength must retain 23% of the original linear-light pixel")
            }
        }
    }

    @Test func allMinimumControlsProduceDeepShadowsWithoutAGrayFloor() throws {
        let source = try fixture(width: 256) { x, _ in
            let value = Float(x) / 255
            return (value, value, value, 1)
        }
        let output = try values(EditRenderer.render(source, settings: masked(allMinimum)).image)
        let luminances = stride(from: 0, to: output.count, by: 4).map { output[$0] }
        #expect(luminances.max() ?? 1 < 0.03,
            "Even source white must become very dark at -5 EV with all remaining tone controls at -100")
        #expect(output[0] < 0.000_1, "Black must remain black with minimum contrast and exposure")
        for x in 1..<256 {
            #expect(output[x * 4] >= output[(x - 1) * 4] - 0.000_5)
        }
    }

    @Test func toneExtremesPreserveDisplayP3AlphaAndAgreeAcrossCoreImageBackends() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let source = try fixture(space: space) { x, _ in
            (0.85, Float(x) / 64, 0.08, x < 8 ? 0 : Float(x) / 64)
        }
        let baseline = try values(source.image)
        let automatic = EditRenderer.Session(lowPriority: true)
        let software = EditRenderer.Session(lowPriority: true, softwareRenderer: true)
        for correction in [LocalAdjustmentSettings(contrast: -100), .init(contrast: 100), allMinimum] + exposureCombinations {
            let edits = try masked(correction, opacity: 0.77)
            let output = try EditRenderer.render(source, settings: edits, session: automatic)
            let reference = try EditRenderer.render(source, settings: edits, session: software)
            let actual = try values(output.image), expected = try values(reference.image)
            #expect(output.image.colorSpace?.name == space.name)
            #expect(output.image.width == source.image.width && output.image.height == source.image.height)
            #expect(maximumDifference(actual, expected) < 0.004)
            for index in stride(from: 3, to: actual.count, by: 4) {
                #expect(abs(actual[index] - baseline[index]) < 0.002)
                if baseline[index] == 0 {
                    #expect(actual[index - 3] == 0 && actual[index - 2] == 0 && actual[index - 1] == 0)
                }
            }
        }
    }

    @Test func contrastRetainsHDRHeadroomGloballyAndThroughAMask() throws {
        let source = try fixture { _, _ in (2, 1.5, 1.1, 0.6) }
        let baseline = try values(source.image)
        for amount in [-100.0, 100] {
            let correction = LocalAdjustmentSettings(contrast: amount)
            var global = correction.editSettings
            global.developColor.hdrEnabled = true
            var local = try masked(correction)
            local.developColor.hdrEnabled = true
            let direct = try EditRenderer.render(source, settings: global)
            let masked = try EditRenderer.render(source, settings: local)
            let actual = try values(masked.image)
            #expect(masked.image.bitmapInfo.contains(.floatComponents))
            #expect(masked.image.colorSpace?.name == CGColorSpace.extendedLinearSRGB)
            #expect(maximumDifference(actual, try values(direct.image)) < 0.003)
            for channel in 0..<3 {
                #expect(actual[channel] / actual[3] > 1, "Contrast must not clip extended highlights")
                #expect(abs(actual[channel] - baseline[channel]) < 0.003)
            }
            #expect(abs(actual[3] - baseline[3]) < 0.002)
        }
    }

    @Test func previewAndExportGraphsAgreeForContrastAndCombinedToneExtremes() throws {
        let source = try fixture { x, _ in
            let value = Float(x) / 63
            return (value, value * 0.7, value * 0.4, 1)
        }
        let session = EditRenderer.Session(lowPriority: true)
        for correction in [LocalAdjustmentSettings(contrast: -100), .init(contrast: 100), allMinimum] + exposureCombinations {
            for hdr in [false, true] {
                var global = correction.editSettings
                global.developColor.hdrEnabled = hdr
                var full = try masked(correction)
                full.developColor.hdrEnabled = hdr
                let direct = try values(EditRenderer.render(source, settings: global, session: session).image)
                let selected = try values(EditRenderer.render(source, settings: full, session: session).image)
                #expect(withinRenderTolerance(direct, selected, hdr: hdr))
                for var settings in [global, try masked(correction, opacity: 0.77)] {
                    settings.developColor.hdrEnabled = hdr
                    let preview = try EditRenderer.render(source, settings: settings, session: session)
                    let graph = try EditRenderer.filterGraph(source.image, settings: settings)
                    // Match the preview's precision and transfer function so
                    // this comparison isolates graph ordering, including HDR.
                    let exported = try #require(session.context.createCGImage(graph, from: graph.extent,
                        format: hdr ? .RGBAh : .RGBA16, colorSpace: source.image.colorSpace!, deferred: false))
                    #expect(withinRenderTolerance(try values(preview.image), try values(exported), hdr: hdr))
                }
            }
        }
    }

    private var allMinimum: LocalAdjustmentSettings {
        .init(exposure: -5, contrast: -100, highlights: -100, shadows: -100, whites: -100, blacks: -100)
    }

    private var exposureCombinations: [LocalAdjustmentSettings] {
        [.init(exposure: -5, highlights: -100), .init(exposure: -5, highlights: 100),
         .init(exposure: -5, whites: -100), .init(exposure: -5, whites: 100),
         .init(exposure: 2, shadows: -100), .init(exposure: 2, shadows: 100),
         .init(exposure: 5, blacks: -100), .init(exposure: 5, blacks: 100)]
    }

    private func masked(_ correction: LocalAdjustmentSettings, opacity: Double = 1,
                        raster: LocalMaskRaster? = nil) throws -> EditSettings {
        let coverage = try raster ?? LocalMaskRaster(width: 1, height: 1, bytes: Data([255]))
        let mask = try LocalAdjustmentMask(shape: .subject(coverage), opacity: opacity, feather: 0)
        return EditSettings(localAdjustments: [try LocalAdjustment(name: "Tone regression", mask: mask, settings: correction)])
    }

    private func fixture(width: Int = 64, height: Int = 8,
                         space: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                         pixel: (Int, Int) -> (Float, Float, Float, Float)) throws -> PreviewBitmap {
        var components: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue, alpha) = pixel(x, y)
                components += [red * alpha, green * alpha, blue * alpha, alpha]
            }
        }
        let data = components.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        let result = try #require(context.createCGImage(image, from: image.extent,
            format: .RGBAh, colorSpace: space, deferred: false))
        return PreviewBitmap(image: result)
    }

    private func values(_ image: CGImage) throws -> [Float] {
        var result = [Float](repeating: 0, count: image.width * image.height * 4)
        result.withUnsafeMutableBytes { data in
            Self.readback.render(CIImage(cgImage: image), toBitmap: data.baseAddress!, rowBytes: image.width * 16,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBAf,
                colorSpace: Self.linearSpace)
        }
        return result
    }

    private func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
    }

    private func withinRenderTolerance(_ lhs: [Float], _ rhs: [Float], hdr: Bool) -> Bool {
        // Half-float HDR precision scales with magnitude; dark pixels retain
        // the same strict absolute tolerance used for the SDR graph checks.
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            abs($0 - $1) < max(0.002, hdr ? abs($0) * 0.002 : 0)
        }
    }
}
