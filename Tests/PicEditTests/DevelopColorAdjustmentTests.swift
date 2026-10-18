import CoreImage
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Develop white balance, profiles, monochrome and HDR", .serialized)
struct DevelopColorAdjustmentTests {
    @Test func neutralPreservesTheOriginalBitmapExactly() throws {
        let source = try fixture(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        let output = try EditRenderer.render(source, settings: .neutral)
        #expect(output.image === source.image)
    }

    @Test func temperatureAndTintHaveVisibleIndependentEffectsAndPreserveAlpha() throws {
        let source = try fixture(red: 0.18, green: 0.18, blue: 0.18, alpha: 0.5)
        let warm = try pixel(EditRenderer.render(source, settings: .init(developColor: .init(temperature: 9_000))).image)
        let cool = try pixel(EditRenderer.render(source, settings: .init(developColor: .init(temperature: 3_500))).image)
        let magenta = try pixel(EditRenderer.render(source, settings: .init(developColor: .init(tint: 70))).image)
        #expect(warm[0] / warm[2] > cool[0] / cool[2])
        #expect((magenta[0] + magenta[2]) / 2 > magenta[1])
        for result in [warm, cool, magenta] { #expect(abs(result[3] - 0.5) < 0.001) }
    }

    @Test(arguments: DevelopColorProfile.allCases)
    func monochromeIsARealRenderModeWithoutMutatingTheUnderlyingColorControls(profile: DevelopColorProfile) throws {
        let source = try fixture(red: 0.4, green: 0.13, blue: 0.07, alpha: 0.75)
        let settings = EditSettings(saturation: 30, developColor: .init(temperature: 7_500, tint: 14,
            profile: profile, isMonochrome: true))
        let result = try pixel(EditRenderer.render(source, settings: settings).image)
        #expect(abs(result[0] - result[1]) < 0.000_1 && abs(result[1] - result[2]) < 0.000_1)
        #expect(abs(result[3] - 0.75) < 0.001)
        #expect(settings.saturation == 30 && settings.developColor.temperature == 7_500)
    }

    @Test func profilesChangeTheGraphAndExportUsesTheSameColorPipeline() throws {
        let source = try fixture(red: 0.36, green: 0.16, blue: 0.08)
        let session = EditRenderer.Session(lowPriority: true)
        var results: [[Float]] = []
        for profile in DevelopColorProfile.allCases {
            let settings = EditSettings(exposure: 0.2, developColor: .init(temperature: 5_500, tint: -12, profile: profile))
            let preview = try EditRenderer.render(source, settings: settings, session: session)
            let graph = try EditRenderer.filterGraph(source.image, settings: settings)
            let exported = try #require(session.context.createCGImage(graph, from: graph.extent, format: .RGBA16,
                colorSpace: source.image.colorSpace!, deferred: false))
            let actual = try pixel(preview.image), reference = try pixel(exported)
            for channel in 0..<4 { #expect(abs(actual[channel] - reference[channel]) < 0.000_1) }
            results.append(actual)
        }
        #expect(results[0] != results[1] && results[1] != results[2])
    }

    @Test func hdrKeepsHighlightHeadroomThroughManualNoisePresenceAndLocalEdits() throws {
        let source = try fixture(red: 2.0, green: 1.5, blue: 1.1, alpha: 0.6)
        let layer = try LocalAdjustment(name: "HDR light", mask: .init(shape: .radial(center: .init(x: 0.5, y: 0.5),
            radiusX: 1, radiusY: 1, rotation: 0)), settings: .init(exposure: 0.3, texture: 10))
        let settings = EditSettings(exposure: 0.4, texture: 15, clarity: 10,
            luminanceNoiseReduction: 20, colorNoiseReduction: 20, naturalBalanceAmount: 70,
            localAdjustments: [layer], developColor: .init(temperature: 7_000, profile: .vivid, hdrEnabled: true))
        let result = try EditRenderer.render(source, settings: settings)
        #expect(result.image.bitmapInfo.contains(.floatComponents))
        #expect(result.image.colorSpace?.name == CGColorSpace.extendedLinearSRGB)
        let values = try pixel(result.image)
        #expect(values[0] / values[3] > 1)
        #expect(abs(values[3] - 0.6) < 0.002)
        let smaller = try EditRenderer.resized(result, width: 4, height: 4, priority: .selected)
        #expect(smaller.image.bitmapInfo.contains(.floatComponents))
        let reduced = try pixel(smaller.image)
        #expect(reduced[0] / reduced[3] > 1)
    }

    @Test func togglingHDRDoesNotReuseAnSDRClampedNoisePrefix() throws {
        let source = try fixture(red: 2, green: 1.4, blue: 1.1)
        #expect(try pixel(source.image)[0] > 1, "The fixture must contain real extended-range pixels before rendering")
        let cached = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let reference = EditRenderer.Session(lowPriority: true)
        var settings = EditSettings(luminanceNoiseReduction: 30)
        _ = try EditRenderer.render(source, settings: settings, session: cached)
        settings.developColor.hdrEnabled = true
        let actual = try pixel(EditRenderer.render(source, settings: settings, session: cached).image)
        let expected = try pixel(EditRenderer.render(source, settings: settings, session: reference).image)
        #expect(actual[0] > 1)
        for channel in 0..<4 { #expect(abs(actual[channel] - expected[channel]) < 0.002) }
    }

    private func fixture(red: Double, green: Double, blue: Double, alpha: Double = 1) throws -> PreviewBitmap {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let color = try #require(CIColor(red: red, green: green, blue: blue, alpha: alpha, colorSpace: space))
        let image = CIImage(color: color)
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
        let output = try #require(context.createCGImage(image, from: image.extent, format: .RGBAh,
            colorSpace: space, deferred: false))
        return PreviewBitmap(image: output)
    }

    private func pixel(_ image: CGImage) throws -> [Float] {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: space])
        var values = [Float](repeating: 0, count: image.width * image.height * 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(CIImage(cgImage: image), toBitmap: buffer.baseAddress!, rowBytes: image.width * 16,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBAf, colorSpace: space)
        }
        return Array(values.prefix(4))
    }
}
