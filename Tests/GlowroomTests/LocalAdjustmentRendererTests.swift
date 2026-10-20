import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Local adjustment rendering")
struct LocalAdjustmentRendererTests {
    @Test func linearAndAutomaticMasksShareTopLeftOrientation() throws {
        let source = try fixture()
        let linear = LocalMaskShape.linear(start: try .init(x: 0.5, y: 0.2), end: try .init(x: 0.5, y: 0.8))
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 255, 0, 0]))
        for shape in [linear, .subject(raster), .sky(raster)] {
            let settings = try settings(shape)
            let values = try pixels(EditRenderer.render(source, settings: settings).image)
            #expect(sample(values, x: 64, y: 8) > 105)
            #expect(abs(sample(values, x: 64, y: 88) - 80) <= 1)
        }
    }

    @Test func radialAndBrushGeometryRemainRelativeToTheOrientedImage() throws {
        let source = try fixture()
        let radial = LocalMaskShape.radial(center: try .init(x: 0.25, y: 0.25),
                                           radiusX: 0.13, radiusY: 0.13, rotation: 0)
        let canvas = try ArtifactPixelSize(width: 1_024, height: 768)
        let point = try MaskPoint(x: 256, y: 192)
        let brush = try MaskDocument(canvasSize: canvas, strokes: [
            .init(points: [point], radius: 104), .init(points: [point], radius: 24, mode: .erase)
        ])
        let radialValues = try pixels(EditRenderer.render(source, settings: settings(radial)).image)
        #expect(sample(radialValues, x: 32, y: 24) > 105)
        #expect(abs(sample(radialValues, x: 32, y: 72) - 80) <= 1)
        let brushValues = try pixels(EditRenderer.render(source, settings: settings(.brush(brush))).image)
        #expect(abs(sample(brushValues, x: 32, y: 24) - 80) <= 1, "Erasing a brush restores the unadjusted image")
        #expect(sample(brushValues, x: 40, y: 24) > 105)
        #expect(abs(sample(brushValues, x: 32, y: 72) - 80) <= 1)
    }

    @Test func inversionOpacityAndDisabledLayersHaveDistinctEffects() throws {
        let source = try fixture()
        let shape = LocalMaskShape.linear(start: try .init(x: 0.2, y: 0.5), end: try .init(x: 0.8, y: 0.5))
        let full = try pixels(EditRenderer.render(source, settings: settings(shape)).image)
        var inverted = try settings(shape)
        inverted.localAdjustments[0].mask.isInverted = true
        let flipped = try pixels(EditRenderer.render(source, settings: inverted).image)
        #expect(sample(full, x: 8, y: 48) > 105 && abs(sample(full, x: 120, y: 48) - 80) <= 1)
        #expect(sample(flipped, x: 120, y: 48) > 105 && abs(sample(flipped, x: 8, y: 48) - 80) <= 1)
        var partial = try settings(shape)
        partial.localAdjustments[0].mask.opacity = 0.4
        let mixed = try pixels(EditRenderer.render(source, settings: partial).image)
        #expect(sample(mixed, x: 8, y: 48) > 85)
        #expect(sample(mixed, x: 8, y: 48) < sample(full, x: 8, y: 48) - 5)
        partial.localAdjustments[0].isEnabled = false
        #expect(try pixels(EditRenderer.render(source, settings: partial).image) == pixels(source.image))
    }

    @Test func automaticAndGradientRefinementsRespectOrderedPaintAndErase() throws {
        let source = try fixture()
        let document = try MaskDocument(canvasSize: .init(width: 128, height: 96), strokes: [
            .init(points: [.init(x: 24, y: 48)], radius: 12),
            .init(points: [.init(x: 24, y: 48)], radius: 4, mode: .erase),
            .init(points: [.init(x: 100, y: 48)], radius: 12, mode: .erase),
            .init(points: [.init(x: 100, y: 48)], radius: 4)
        ])
        let raster = try LocalMaskRaster(width: 2, height: 1, bytes: Data([0, 255]))
        let gradient = LocalMaskShape.linear(start: try .init(x: 0.7, y: 0.5), end: try .init(x: 0.3, y: 0.5))
        for shape in [gradient, .subject(raster), .sky(raster)] {
            var edits = try settings(shape)
            edits.localAdjustments[0].mask.refinement = document
            let values = try pixels(EditRenderer.render(source, settings: edits).image)
            #expect(abs(sample(values, x: 24, y: 48) - 80) <= 1, "Erase after paint removes the selected center")
            #expect(sample(values, x: 30, y: 48) > 105, "Painting can add outside the original selection")
            #expect(sample(values, x: 100, y: 48) > 105, "Paint after erase restores the selected center")
            #expect(abs(sample(values, x: 106, y: 48) - 80) <= 1, "Erasing can remove the original selection")
            var emptyRefinement = try settings(shape)
            let unchanged = try pixels(EditRenderer.render(source, settings: emptyRefinement).image)
            emptyRefinement.localAdjustments[0].mask.refinement = document.cleared()
            #expect(try pixels(EditRenderer.render(source, settings: emptyRefinement).image) == unchanged)
        }
    }

    @Test func finalInversionKeepsHistoricStrokesAndMappedNewPaintEraseRemainOrdered() throws {
        let source = try fixture()
        let canvas = try ArtifactPixelSize(width: 128, height: 96)
        let brush = try MaskDocument(canvasSize: canvas, strokes: [
            .init(points: [.init(x: 24, y: 12), .init(x: 24, y: 84)], radius: 28)
        ])
        // Different lower-quadrant values make the automatic raster asymmetric.
        let raster = try LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 0, 200, 48]))
        let shapes: [LocalMaskShape] = [
            .brush(brush), .brush(brush.inverted()),
            .linear(start: try .init(x: 0.2, y: 0.5), end: try .init(x: 0.8, y: 0.5)),
            .radial(center: try .init(x: 0.2, y: 0.5), radiusX: 0.22, radiusY: 0.7, rotation: 0),
            .subject(raster), .sky(raster)
        ]
        let historic: [MaskStroke] = try [
            .init(points: [.init(x: 24, y: 24)], radius: 12, mode: .erase),
            .init(points: [.init(x: 100, y: 24)], radius: 12)
        ]
        // Workspace maps new visible paint/erase through the outer inversion.
        // Preserve these canonical operations in the renderer and in snapshots.
        let afterInversion: [MaskStroke] = try [
            .init(points: [.init(x: 24, y: 72)], radius: 12, mode: .erase),
            .init(points: [.init(x: 24, y: 72)], radius: 4),
            .init(points: [.init(x: 100, y: 72)], radius: 12),
            .init(points: [.init(x: 100, y: 72)], radius: 4, mode: .erase)
        ]
        for shape in shapes {
            func mask(strokes: [MaskStroke], inverted: Bool) throws -> LocalAdjustmentMask {
                if case .brush(let document) = shape {
                    let combined = try MaskDocument(canvasSize: canvas, strokes: document.strokes + strokes,
                        isInverted: document.isInverted)
                    return try .init(shape: .brush(combined), isInverted: inverted, feather: 0)
                }
                return try .init(shape: shape, isInverted: inverted, feather: 0,
                    refinement: MaskDocument(canvasSize: canvas, strokes: strokes))
            }
            var edits = try settings(shape)
            edits.localAdjustments[0].mask = try mask(strokes: historic, inverted: false)
            let before = try pixels(EditRenderer.render(source, settings: edits).image)
            #expect(abs(sample(before, x: 24, y: 24) - 80) <= 1)
            #expect(sample(before, x: 100, y: 24) > 105)
            edits.localAdjustments[0].mask.isInverted = true
            let inverted = try pixels(EditRenderer.render(source, settings: edits).image)
            #expect(sample(inverted, x: 24, y: 24) > 105, "Toggle must invert an existing erased area")
            #expect(abs(sample(inverted, x: 100, y: 24) - 80) <= 1, "Toggle must invert an existing painted area")

            edits.localAdjustments[0].mask = try mask(strokes: historic + afterInversion, inverted: true)
            let refined = try pixels(EditRenderer.render(source, settings: edits).image)
            #expect(sample(refined, x: 24, y: 24) > 105)
            #expect(abs(sample(refined, x: 100, y: 24) - 80) <= 1)
            #expect(abs(sample(refined, x: 24, y: 72) - 80) <= 1, "Visible erase after paint removes the center")
            #expect(sample(refined, x: 30, y: 72) > 105, "Visible paint adds a ring to the inverted selection")
            #expect(sample(refined, x: 100, y: 72) > 105, "Visible paint after erase restores the center")
            #expect(abs(sample(refined, x: 106, y: 72) - 80) <= 1, "Visible erase removes the surrounding area")
        }
    }

    @Test func overlappingLayersApplyInSavedOrderAfterGlobalAdjustments() throws {
        let source = try fixture { _, _ in (95, 70, 45, 255) }
        let raster = try LocalMaskRaster(width: 1, height: 1, bytes: Data([255]))
        let mask = try LocalAdjustmentMask(shape: .subject(raster), feather: 0)
        let exposure = try LocalAdjustment(name: "Exposure", mask: mask, settings: .init(exposure: 0.8))
        let contrast = try LocalAdjustment(name: "Contrast", mask: mask, settings: .init(contrast: 80))
        let global = EditSettings(exposure: -0.3, saturation: -35)
        var combined = global
        combined.localAdjustments = [exposure, contrast]
        let globalResult = try EditRenderer.render(source, settings: global)
        let first = try EditRenderer.render(globalResult, settings: exposure.settings.editSettings)
        let expected = try pixels(EditRenderer.render(first, settings: contrast.settings.editSettings).image)
        let actual = try pixels(EditRenderer.render(source, settings: combined).image)
        #expect(zip(expected, actual).map { abs($0 - $1) }.max() ?? 0 <= 2)
        combined.localAdjustments.reverse()
        let reversed = try pixels(EditRenderer.render(source, settings: combined).image)
        #expect(abs(sample(actual, x: 50, y: 50) - sample(reversed, x: 50, y: 50)) > 2)
    }

    @Test func localPresenceAndTonePreserveWideGamutAlpha() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let source = try fixture(space: space) { x, y in
            (UInt8(50 + x), UInt8(60 + y), 90, x < 8 ? 0 : UInt8(80 + x))
        }
        let shape = LocalMaskShape.radial(center: try .init(x: 0.25, y: 0.25), radiusX: 0.7, radiusY: 0.8, rotation: 0.5)
        var edits = try settings(shape)
        edits.localAdjustments[0].settings = .init(exposure: 0.5, texture: 55, clarity: -40, saturation: 35)
        edits.localAdjustments[0].mask.refinement = try MaskDocument(canvasSize: .init(width: 128, height: 96),
            strokes: [.init(points: [.init(x: 10, y: 30)], radius: 15, mode: .erase)])
        let output = try EditRenderer.render(source, settings: edits)
        #expect(output.image.colorSpace?.name == source.image.colorSpace?.name)
        let before = try pixels(source.image), after = try pixels(output.image)
        for offset in stride(from: 3, to: before.count, by: 4) {
            #expect(abs(before[offset] - after[offset]) <= 1)
            if before[offset] == 0 { #expect(after[offset - 3] + after[offset - 2] + after[offset - 1] == 0) }
        }
    }

    @Test func brushCacheInvalidatesForGeometryAndConcurrentSources() async throws {
        let cached = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let reference = EditRenderer.Session(lowPriority: true)
        let canvas = try ArtifactPixelSize(width: 128, height: 96)
        let sources = try [fixture(), fixture { _, _ in (90, 90, 90, 255) }]
        for x in [24.0, 100.0] {
            let document = try MaskDocument(canvasSize: canvas, strokes: [
                .init(points: [.init(x: x, y: 24)], radius: 16)
            ])
            let edits = try settings(.brush(document))
            let expected = try sources.map { try pixels(EditRenderer.render($0, settings: edits, session: reference).image) }
            try await withThrowingTaskGroup(of: (Int, PreviewBitmap).self) { group in
                for index in sources.indices {
                    group.addTask { (index, try EditRenderer.render(sources[index], settings: edits, session: cached)) }
                }
                for try await (index, output) in group {
                    let actual = try pixels(output.image)
                    #expect(zip(expected[index], actual).map { abs($0 - $1) }.max() ?? 0 <= 1)
                }
            }
        }
    }

    @Test func automaticAndSoftwareCoreImageBackendsAgreeForFeatheredMasks() throws {
        let source = try fixture { x, y in (UInt8(50 + x), UInt8(60 + y), 90, 255) }
        let shape = LocalMaskShape.radial(center: try .init(x: 0.3, y: 0.25), radiusX: 0.6, radiusY: 0.3, rotation: 0.5)
        var edits = try settings(shape)
        edits.localAdjustments[0].mask.feather = 0.65
        edits.localAdjustments[0].mask.opacity = 0.7
        let automatic = try pixels(EditRenderer.render(source, settings: edits,
            session: .init(lowPriority: true)).image)
        let software = try pixels(EditRenderer.render(source, settings: edits,
            session: .init(lowPriority: true, softwareRenderer: true)).image)
        #expect(zip(automatic, software).map { abs($0 - $1) }.max() ?? 0 <= 2)
    }

    @Test func additionalMemoryPlanningRejectsOverflowAndIgnoresDormantLayers() throws {
        var edits = try settings(.radial(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.3, rotation: 0))
        #expect(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: edits.localAdjustments,
            width: Int.max, height: Int.max) == nil)
        edits.localAdjustments[0].isEnabled = false
        #expect(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: edits.localAdjustments,
            width: 128, height: 96) == 0)
    }

    @Test func directPreviewRenderRejectsExcessiveMaskWorkBeforeBuildingTheGraph() throws {
        let context = try #require(CGContext(data: nil, width: 2_400, height: 1_200, bitsPerComponent: 8,
            bytesPerRow: 2_400 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = PreviewBitmap(image: try #require(context.makeImage()))
        let mask = try LocalAdjustmentMask(shape: .radial(center: .init(x: 0.5, y: 0.5),
            radiusX: 0.2, radiusY: 0.3, rotation: 0))
        var edits = EditSettings.neutral
        edits.localAdjustments = try (0..<16).map { index in
            try LocalAdjustment(name: "Mask \(index)", mask: mask, settings: .init(exposure: 0.2))
        }
        #expect(throws: EditRenderError.insufficientMaskMemory) {
            try EditRenderer.render(source, settings: edits)
        }
    }

    private func settings(_ shape: LocalMaskShape) throws -> EditSettings {
        var value = EditSettings.neutral
        value.localAdjustments = [try LocalAdjustment(name: "Selection", mask: .init(shape: shape, feather: 0),
                                                       settings: .init(exposure: 1))]
        return value
    }

    private func fixture(space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                         pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { _, _ in (80, 80, 80, 255) }) throws -> PreviewBitmap {
        var bytes = [UInt8]()
        for y in 0..<96 {
            for x in 0..<128 {
                let (r, g, b, a) = pixel(x, y)
                bytes += [UInt8(Int(r) * Int(a) / 255), UInt8(Int(g) * Int(a) / 255), UInt8(Int(b) * Int(a) / 255), a]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: 128, height: 96, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
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

    private func sample(_ values: [Double], x: Int, y: Int) -> Double { values[(y * 128 + x) * 4] }
}
