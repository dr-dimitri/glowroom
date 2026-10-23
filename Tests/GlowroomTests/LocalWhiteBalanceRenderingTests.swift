import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("White balance bounded by shared masks")
struct LocalWhiteBalanceRenderingTests {
    @Test func localColorChangesOnlyCoveredPixelsAndMatchesGlobalColorControls() throws {
        let source = try fixture()
        let local = LocalAdjustmentSettings(temperature: 8_500, tint: 35)
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 255, 0, 0]))
        let layer = try LocalAdjustment(name: "Top", mask: .init(shape: .subject(raster), feather: 0), settings: local)
        let settings = EditSettings(localAdjustments: [layer])
        let baseline = try pixels(EditRenderer.render(source, settings: .neutral).image)
        let global = try pixels(EditRenderer.render(source, settings: local.editSettings).image)
        let actual = try pixels(EditRenderer.render(source, settings: settings).image)
        let software = try pixels(EditRenderer.render(source, settings: settings,
            session: .init(lowPriority: true, softwareRenderer: true)).image)
        for channel in 0..<4 {
            let inside = (8 * 64 + 32) * 4 + channel, outside = (56 * 64 + 32) * 4 + channel
            #expect(abs(actual[inside] - global[inside]) <= 1)
            #expect(abs(actual[outside] - baseline[outside]) <= 1)
        }
        #expect(actual[(8 * 64 + 32) * 4] > actual[(8 * 64 + 32) * 4 + 2], "Higher local temperature warms neutral gray")
        #expect(zip(actual, software).map { abs($0 - $1) }.max() ?? 0 <= 2)
    }

    @Test func localColorGraphIsIncludedInTheMemoryAdmissionPlan() throws {
        let mask = try LocalAdjustmentMask(shape: .linear(start: .init(x: 0, y: 0.5), end: .init(x: 1, y: 0.5)))
        var layer = try LocalAdjustment(name: "Selection", mask: mask, settings: .init(exposure: 1))
        let before = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [layer], width: 64, height: 64))
        layer.settings.temperature = 8_500
        let after = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [layer], width: 64, height: 64))
        #expect(after - before == 64 * 64 * 16)
    }

    private func fixture() throws -> PreviewBitmap {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return PreviewBitmap(image: try #require(context.makeImage()))
    }

    private func pixels(_ image: CGImage) throws -> [Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try #require(CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes.map(Int.init)
    }
}
