import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

/// Independent, known-background fixtures measure removal quality rather than
/// reproducing the healing implementation. Values are linear RGB; no display
/// gamma, photographic judgement or private fixture is hidden in the limits.
@Suite("Repair quality against clean synthetic backgrounds")
struct DevelopRepairQualityTests {
    @Test(arguments: [false, true])
    func nearbyCleanDonorDoesNotPickUpTheRemovedObjectInItsSurroundings(redObject: Bool) throws {
        let width = 256, height = 160
        let input = fixture(width: width, height: height) { x, y in
            if hypot(Double(x) + 0.5 - 128, Double(y) + 0.5 - 80) < 14.5 {
                return redObject ? SIMD4(0.85, 0.03, 0.02, 1) : SIMD4(0.02, 0.02, 0.02, 1)
            }
            return SIMD4(0.45, 0.45, 0.45, 1)
        }
        let target = try LocalMaskPoint(x: 0.5, y: 0.5)
        // The donor disk is completely clean. Its outer comparison ring,
        // however, intersects the original object on its left-hand side.
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.625, y: 0.5), target: target,
            radius: 0.1, feather: 0.1, path: [target])
        let output = try render(input, stroke: stroke)
        let center = pixel(output, width: width, height: height, x: 128, y: 80)
        for channel in 0..<3 {
            #expect(abs(center[channel] - 0.45) < 0.015,
                "A clean nearby donor must not acquire the removed object's color through its surrounding ring")
        }
    }

    @Test func longStrokeFollowsLocalIlluminationAndKeepsDonorTexture() throws {
        let width = 256, height = 256
        let input = fixture(width: width, height: height) { x, y in
            if x < 128 {
                let detail: Float = x % 4 < 2 ? -0.04 : 0.04
                return gray(0.30 + detail)
            }
            if abs(Double(x) + 0.5 - 192) < 7, (35..<221).contains(y) { return gray(0.02) }
            return gray(0.20 + 0.60 * (Float(y) + 0.5) / Float(height))
        }
        let target = try LocalMaskPoint(x: 0.75, y: 0.15)
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.15), target: target,
            radius: 0.04, feather: 0.2, path: [target, .init(x: 0.75, y: 0.85)])
        let output = try render(input, stroke: stroke)
        for y in [64, 128, 192] {
            let expected = 0.20 + 0.60 * (Float(y) + 0.5) / Float(height)
            let darker = pixel(output, width: width, height: height, x: 192, y: y).x
            let lighter = pixel(output, width: width, height: height, x: 194, y: y).x
            #expect(abs((darker + lighter) / 2 - expected) < 0.025,
                "The top and bottom of a long repair must match their own surrounding illumination")
            #expect((0.06...0.10).contains(lighter - darker),
                "Healing must retain the donor's fine texture rather than smoothing the replacement")
        }
    }

    @Test func disconnectedMaskComponentsDoNotShareOneGlobalColorCorrection() throws {
        let width = 256, height = 256
        var cells = Data(count: width * height)
        for centerY in [64, 192] {
            for y in (centerY - 10)..<(centerY + 10) {
                for x in 182..<202 { cells[y * width + x] = 255 }
            }
        }
        let input = fixture(width: width, height: height) { x, y in
            if x < 128 { return gray(0.4) }
            if cells[y * width + x] != 0 { return SIMD4(0.9, 0.02, 0.02, 1) }
            return gray(y < 128 ? 0.24 : 0.70)
        }
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.25),
            target: .init(x: 0.75, y: 0.25), radius: 0.04,
            mask: .init(width: width, height: height, bytes: cells))
        let output = try render(input, stroke: stroke)
        for (y, expected): (Int, Float) in [(64, 0.24), (192, 0.70)] {
            let actual = pixel(output, width: width, height: height, x: 192, y: y)
            for channel in 0..<3 { #expect(abs(actual[channel] - expected) < 0.025) }
        }
    }

    @Test func localHealingPreservesEveryUnselectedPixelAndOriginalAlpha() throws {
        let width = 192, height = 128
        let input = fixture(width: width, height: height) { x, y in
            let alpha: Float = x < 8 ? 0 : 0.25 + 0.7 * Float(y) / Float(height)
            let value: Float = hypot(Double(x - 136), Double(y - 64)) < 8 ? 0.02 : 0.25 + Float(y) / 300
            return SIMD4(value, value * 0.8, value * 0.6, alpha)
        }
        let target = try LocalMaskPoint(x: 136.0 / 192, y: 0.5)
        let stroke = try DevelopRetouchStroke(source: .init(x: 90.0 / 192, y: 0.5), target: target,
            radius: 0.10, feather: 0.25, opacity: 0.8, path: [target])
        let before = read(input), after = try render(input, stroke: stroke)
        let coverage = read(try DevelopRetouchMaskRenderer.coverage(for: stroke, extent: input.extent))
        var outsideMaximum: Float = 0, alphaMaximum: Float = 0, changedPixels = 0
        for index in 0..<(width * height) {
            alphaMaximum = max(alphaMaximum, abs(before[index * 4 + 3] - after[index * 4 + 3]))
            let difference = (0..<3).map { abs(before[index * 4 + $0] - after[index * 4 + $0]) }.max() ?? 0
            if coverage[index * 4] <= 0 { outsideMaximum = max(outsideMaximum, difference) }
            else if difference > 0.01 { changedPixels += 1 }
        }
        #expect(alphaMaximum < 0.000_2)
        #expect(outsideMaximum < 0.000_2)
        #expect(changedPixels > 100, "Alpha preservation must not be achieved by skipping the repair")
    }

    @Test func normalizedHealingAgreesAtPreviewAndDoubleResolution() throws {
        let target = try LocalMaskPoint(x: 0.75, y: 0.2)
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.2), target: target,
            radius: 0.045, feather: 0.2, path: [target, .init(x: 0.75, y: 0.8)])
        func rendered(_ size: Int) throws -> [Float] {
            let input = fixture(width: size, height: size) { x, y in
                let nx = (Double(x) + 0.5) / Double(size), ny = (Double(y) + 0.5) / Double(size)
                if nx < 0.5 { return gray(0.3) }
                if abs(nx - 0.75) < 0.025, (0.18...0.82).contains(ny) { return gray(0.02) }
                return gray(0.2 + 0.6 * Float(ny))
            }
            return try render(input, stroke: stroke)
        }
        let preview = try rendered(256), export = try rendered(512)
        for y in [80, 128, 176] {
            let small = pixel(preview, width: 256, height: 256, x: 192, y: y)
            let large = pixel(export, width: 512, height: 512, x: 384, y: y * 2)
            for channel in 0..<3 { #expect(abs(small[channel] - large[channel]) < 0.015) }
            #expect(abs(small.x - (0.2 + 0.6 * (Float(y) + 0.5) / 256)) < 0.025)
        }
    }

    @Test func broadSelectionUsesTheCleanSurroundingMeanWhenLocalSupportRunsOut() throws {
        let width = 256, height = 256
        var cells = Data(count: width * height)
        for y in 40..<216 { for x in 170..<214 { cells[y * width + x] = 255 } }
        let input = fixture(width: width, height: height) { x, y in
            if x < 128 { return gray(0.25) }
            return gray(cells[y * width + x] == 0 ? 0.65 : 0.02)
        }
        // A stored object mask can be much wider than its brush radius. At the
        // center there is no nearby exterior sample; the fallback must still
        // transfer the known surrounding color without division artifacts.
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.5),
            target: .init(x: 0.75, y: 0.5), radius: 0.002,
            mask: .init(width: width, height: height, bytes: cells))
        let output = try render(input, stroke: stroke)
        #expect(output.allSatisfy { $0.isFinite })
        for y in [72, 128, 184] {
            let actual = pixel(output, width: width, height: height, x: 192, y: y)
            for channel in 0..<3 { #expect(abs(actual[channel] - 0.65) < 0.015) }
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func selectionWithoutAnyCleanSurroundingsFallsBackToFiniteUncorrectedDonor(variant: Int) throws {
        let width = 128, height = 96
        let input = fixture(width: width, height: height) { x, y in
            // Exact binary values isolate an invented correction from the
            // RGBAh rounding of independently fused/intermediate render paths.
            SIMD4(0.25 + Float(x) / 256, 0.25 + Float(y) / 256, 0.5, 1)
        }
        let mask = try LocalMaskRaster(width: width, height: height,
            bytes: Data(repeating: 255, count: width * height))
        // Four bounded cases exercise different Gaussian and source domains in
        // parallel on the shared context; the expected pixels stay exact.
        let shift = 64 - variant * 16
        func stroke(_ mode: DevelopRetouchMode) throws -> DevelopRetouchStroke {
            try .init(mode: mode, source: .init(x: 0.25 + Double(variant) / 8, y: 0.5), target: .init(x: 0.75, y: 0.5),
                radius: [0.08, 0.12, 0.06, 0.03][variant], mask: mask)
        }
        let healed = try render(input, stroke: stroke(.heal))
        let cloned = try render(input, stroke: stroke(.clone))
        #expect(healed.allSatisfy { $0.isFinite })
        let differences = zip(healed, cloned).map { abs($0 - $1) }
        let maximum = differences.max() ?? 0, index = differences.firstIndex(of: maximum) ?? 0
        #expect(maximum < 0.000_2,
            "No-context heal/clone maximum \(maximum) at (\((index / 4) % width), \(height - 1 - (index / 4) / width)), channel \(index % 4), healed \(healed[index]), cloned \(cloned[index])")
        var expectedMaximum: Float = 0
        for y in 0..<height { for x in 0..<width {
            // The source uses an exact integer offset; samples left
            // of the image clamp to its first column. No renderer is the oracle.
            let expected = SIMD4<Float>(0.25 + Float(max(0, x - shift)) / 256, 0.25 + Float(y) / 256, 0.5, 1)
            let actual = pixel(healed, width: width, height: height, x: x, y: y)
            for channel in 0..<4 { expectedMaximum = max(expectedMaximum, abs(actual[channel] - expected[channel])) }
        } }
        #expect(expectedMaximum < 0.000_2,
            "Without a valid ring, every healed pixel must equal its known clamped donor; maximum \(expectedMaximum)")
    }

    @Test func paintedFullCanvasWithoutCleanExteriorUsesTheKnownUncorrectedDonor() throws {
        let width = 128, height = 96
        let input = fixture(width: width, height: height) { x, y in
            SIMD4(0.25 + Float(x) / 256, 0.125 + Float(y) / 256, 0.625, 1)
        }
        let target = try LocalMaskPoint(x: 0, y: 0)
        // A hard 48-pixel-radius perimeter covers every pixel: the top and
        // bottom strokes meet at the center. This uses the actual path raster,
        // with no supplied mask and no dependency on its internal support flag.
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0), target: target,
            radius: 0.5, feather: 0, path: [.init(x: 1, y: 0), .init(x: 1, y: 1),
                .init(x: 0, y: 1), target])
        let healed = try render(input, stroke: stroke)
        #expect(healed.allSatisfy { $0.isFinite })
        var maximum: Float = 0
        for y in 0..<height { for x in 0..<width {
            // Moving the donor 32 pixels right samples x+32; the last source
            // column supplies every location beyond that edge.
            let expected = SIMD4<Float>(0.25 + Float(min(width - 1, x + 32)) / 256,
                0.125 + Float(y) / 256, 0.625, 1)
            let actual = pixel(healed, width: width, height: height, x: x, y: y)
            for channel in 0..<4 { maximum = max(maximum, abs(actual[channel] - expected[channel])) }
        } }
        #expect(maximum < 0.000_2,
            "A painted full-canvas selection has no clean exterior to infer a correction; maximum \(maximum)")
    }

    @Test func softwareRenderingPreferencePreservesTheSignedLocalCorrection() throws {
        let width = 192, height = 192
        let input = fixture(width: width, height: height) { x, y in
            if x < 96 { return gray(0.50 + (x % 4 < 2 ? -0.03 : 0.03)) }
            if abs(Double(x) + 0.5 - 144) < 5, (26..<166).contains(y) { return gray(0.02) }
            return gray(0.20 + 0.60 * (Float(y) + 0.5) / Float(height))
        }
        let target = try LocalMaskPoint(x: 0.75, y: 0.15)
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.15), target: target,
            radius: 0.045, feather: 0.2, path: [target, .init(x: 0.75, y: 0.85)])
        let automatic = try render(input, stroke: stroke)
        let softwarePreferred = try render(input, stroke: stroke, softwareRenderer: true)
        #expect(softwarePreferred.allSatisfy { $0.isFinite })
        let maximum = zip(automatic, softwarePreferred).map { abs($0 - $1) }.max() ?? 0
        #expect(maximum < 0.005, "The rendering preference must preserve signed corrections within float-filter tolerance")
        for y in [48, 144] {
            let sample = pixel(softwarePreferred, width: width, height: height, x: 144, y: y).x
            let expected = 0.20 + 0.60 * (Float(y) + 0.5) / Float(height) - 0.03
            #expect(abs(sample - expected) < 0.025, "Exercise both negative and positive illumination correction")
        }
        // Core Image owns the actual device decision. This validates the
        // software-preferred context, not a claim that every OS uses a CPU.
    }

    private func gray(_ value: Float) -> SIMD4<Float> { SIMD4(value, value, value, 1) }

    /// CI bitmap rows start at the lower edge; callers use the stored stroke's
    /// top-left coordinates. Keep this conversion explicit on both sides.
    private func fixture(width: Int, height: Int, pixel: (Int, Int) -> SIMD4<Float>) -> CIImage {
        var values = [Float](); values.reserveCapacity(width * height * 4)
        for y in (0..<height).reversed() {
            for x in 0..<width {
                let color = pixel(x, y)
                values.append(contentsOf: [color.x * color.w, color.y * color.w, color.z * color.w, color.w])
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
    }

    private func render(_ input: CIImage, stroke: DevelopRetouchStroke, softwareRenderer: Bool = false) throws -> [Float] {
        read(try DevelopGeometryRenderer.apply(to: input, geometry: .init(retouchStrokes: [stroke]), extent: input.extent),
             softwareRenderer: softwareRenderer)
    }

    private func read(_ image: CIImage, softwareRenderer: Bool = false) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { storage in
            EditRenderer.maskCompositingContext(softwareRenderer: softwareRenderer).render(image, toBitmap: storage.baseAddress!, rowBytes: width * 16,
                bounds: image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return values
    }

    private func pixel(_ data: [Float], width: Int, height: Int, x: Int, y: Int) -> SIMD4<Float> {
        let offset = ((height - y - 1) * width + x) * 4
        return SIMD4(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }
}
