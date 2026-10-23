import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("AI development mask input coordinates")
struct AIDevelopmentMaskInputTests {
    @Test func fullCanvasRetainsSourceBindingsMasksAndRepairsWithoutDisplayGeometry() throws {
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 0, 0, 0]))
        let replacement = try DevelopRetouchReplacement(bounds: .init(x: 0.2, y: 0.3, width: 0.1, height: 0.1),
            width: 1, height: 1, rgba: Data([100, 110, 120, 255]))
        let repair = try DevelopRetouchStroke(mode: .heal, source: .init(x: 0.1, y: 0.1),
            target: .init(x: 0.25, y: 0.35), radius: 0.1, mask: raster, replacement: replacement)
        let eye = try DevelopRedEyeCorrection(center: .init(x: 0.7, y: 0.25), radiusX: 0.04, radiusY: 0.03)
        let layer = try LocalAdjustment(name: "Blumenstrauß", mask: .init(shape: .subject(raster), isInverted: true),
            settings: .init(exposure: 0.4, temperature: 7_500, tint: 20))
        let geometry = try DevelopGeometry(crop: .init(x: 0.2, y: 0.1, width: 0.5, height: 0.6),
            quarterTurns: 3, straightenAngle: 17, constrainToImage: false,
            flipHorizontal: true, flipVertical: true, retouchStrokes: [repair], redEyeCorrections: [eye])
        let settings = EditSettings(exposure: 0.2, clarity: 12, localAdjustments: [layer],
            developColor: .init(temperature: 6_800, tint: -10), developGeometry: geometry)
        let persisted = try EditingExpectedState(storeEpoch: UUID(), revision: 7, snapshot: .init(settings: settings))
        let snapshot = AIEditingSnapshot(assetID: "selected-photo",
            source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/ai-mask-input-synthetic.png"),
                modifiedAt: Date(timeIntervalSince1970: 1), fileSize: 128)), settings: settings,
            token: .init(editSessionID: UUID(), editGeneration: 4, selectionSessionID: UUID(), selectionGeneration: 9),
            persistedVersion: persisted)

        let full = AIDevelopmentMaskInput.fullCanvasSnapshot(snapshot)
        #expect(full.assetID == snapshot.assetID && full.source == snapshot.source)
        #expect(full.token == snapshot.token && full.persistedVersion == snapshot.persistedVersion)
        #expect(full.settings.localAdjustments == [layer])
        #expect(full.settings.developGeometry.retouchStrokes == [repair])
        #expect(full.settings.developGeometry.redEyeCorrections == [eye])
        #expect(full.settings.developGeometry.crop == nil)
        #expect(full.settings.developGeometry.quarterTurns == 0 && full.settings.developGeometry.straightenAngle == 0)
        #expect(!full.settings.developGeometry.flipHorizontal && !full.settings.developGeometry.flipVertical)
        var expected = settings
        expected.developGeometry = .init(retouchStrokes: [repair], redEyeCorrections: [eye])
        #expect(full.settings == expected)
        #expect(snapshot.settings == settings, "Preparing model input must not rewrite accepted photo settings")
        #expect(AIDevelopmentMaskInput.fullCanvasSnapshot(full) == full)
    }

    @Test(arguments: [false, true], [0.2, 1.0])
    func asymmetricalMaskDimsOnlyItsUnselectedAreaInTopLeftCoordinates(inverted: Bool, opacity: Double) throws {
        let source = try fixture()
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 0, 0, 0]))
        let mask = try LocalAdjustmentMask(shape: .subject(raster), isInverted: inverted, opacity: opacity, feather: 0)
        let output = try AIDevelopmentMaskInput.render(source, mask: mask)
        #expect(output.image.width == source.image.width && output.image.height == source.image.height)
        #expect(output.image.colorSpace?.name == source.image.colorSpace?.name)
        let before = try pixels(source.image), after = try pixels(output.image)
        for (x, y, topLeft) in [(12, 8, true), (80, 8, false), (12, 56, false), (80, 56, false)] {
            let selected = topLeft != inverted
            for channel in 0..<3 {
                let index = (y * 96 + x) * 4 + channel
                if selected { #expect(abs(after[index] - before[index]) <= 1) }
                else { #expect(after[index] < before[index] - 30) }
            }
            #expect(after[(y * 96 + x) * 4 + 3] == before[(y * 96 + x) * 4 + 3])
        }
    }

    @Test func refinedMaskShowsPaintedAreasAndDimsErasedAreas() throws {
        let source = try fixture()
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 0, 0, 0]))
        let refinement = try MaskDocument(canvasSize: .init(width: 96, height: 64), strokes: [
            .init(points: [.init(x: 16, y: 12)], radius: 6, mode: .erase),
            .init(points: [.init(x: 80, y: 48)], radius: 6)
        ])
        let mask = try LocalAdjustmentMask(shape: .subject(raster), feather: 0, refinement: refinement)
        let before = try pixels(source.image)
        let after = try pixels(AIDevelopmentMaskInput.render(source, mask: mask).image)
        for (x, y, selected) in [(16, 12, false), (8, 4, true), (80, 48, true), (80, 12, false)] {
            for channel in 0..<3 {
                let index = (y * 96 + x) * 4 + channel
                if selected { #expect(abs(after[index] - before[index]) <= 1) }
                else { #expect(after[index] < before[index] - 30) }
            }
        }
        // The 2×2 mask interpolates between texel centers. (32, 20) lies in
        // that transition, outside both brush strokes; it must retain its
        // partial coverage rather than the full brightness of a selected texel.
        let unrefined = try pixels(AIDevelopmentMaskInput.render(source,
            mask: .init(shape: .subject(raster), feather: 0)).image)
        for channel in 0..<3 {
            let index = (20 * 96 + 32) * 4 + channel
            #expect(abs(after[index] - unrefined[index]) <= 1)
            #expect(after[index] < before[index] - 5)
        }
    }

    private func fixture() throws -> PreviewBitmap {
        var bytes = [UInt8]()
        for y in 0..<64 {
            for x in 0..<96 { bytes += [UInt8(80 + x), UInt8(100 + y), 140, 255] }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return PreviewBitmap(image: try #require(CGImage(width: 96, height: 64, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
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
