import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Source-pixel luminance sharpening", .serialized)
struct DevelopSharpeningTests {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    @Test func amountRadiusAndDetailEachChangeThePixels() throws {
        let input = fixture { x, y in 0.2 + 0.012 * sin(Double(x) * 1.7) + (x > 64 ? 0.12 : 0) + 0.005 * cos(Double(y)) }
        let baseline = try pixels(input)
        let standard = EditSettings(sharpeningAmount: 100)
        let output = try render(input, settings: standard)
        #expect(difference(baseline, output) > 0.0001)
        var wider = standard; wider.sharpeningRadius = 3
        #expect(difference(output, try render(input, settings: wider)) > 0.0001)
        var fine = standard; fine.sharpeningDetail = 100
        var edges = standard; edges.sharpeningDetail = 0
        let fineOutput = try render(input, settings: fine)
        let edgesOutput = try render(input, settings: edges)
        #expect(difference(baseline, fineOutput, x: 8..<50) > difference(baseline, edgesOutput, x: 8..<50) * 1.2)
    }

    @Test func maskingSuppressesFlatTextureAndRetainsStrongEdges() throws {
        let input = fixture { x, y in (x < 64 ? 0.1 : 0.7) + 0.003 * sin(Double(x * 7 + y * 3)) }
        let baseline = try pixels(input)
        var settings = EditSettings(sharpeningAmount: 100, sharpeningDetail: 100)
        let unmasked = try render(input, settings: settings)
        settings.sharpeningMasking = 100
        let masked = try render(input, settings: settings)
        #expect(difference(baseline, masked, x: 8..<50) < difference(baseline, unmasked, x: 8..<50) * 0.1)
        #expect(difference(baseline, masked, x: 62..<66) > 0.001)
    }

    @Test func constantsAlphaAndChannelRatiosSurviveIncludingTransparentBorders() throws {
        let constant = fixture(alpha: { x in x < 30 ? 0 : x < 70 ? 0.4 : 1 }) { _, _ in 0.3 }
        let before = try pixels(constant)
        let after = try render(constant, settings: .init(sharpeningAmount: 150, sharpeningRadius: 3, sharpeningDetail: 100))
        // Core Image's Gaussian stage can use half-float intermediates, even
        // with float readback. At maximum Detail, bound that rounding drift.
        #expect(difference(before, after) < 0.0003)
        #expect(zip(before, after).allSatisfy { abs($0.0 - $0.1) < 0.0015 })
        let color = fixture(alpha: { _ in 0.6 }) { x, _ in x < 64 ? 0.2 : 0.4 }
        let output = try render(color, settings: .init(sharpeningAmount: 150, sharpeningDetail: 100))
        for index in stride(from: 0, to: output.count, by: 4) {
            #expect(abs(output[index + 3] - 0.6) < 0.0001)
            #expect(abs(output[index] / output[index + 1] - 2) < 0.0001)
            #expect(abs(output[index + 1] / output[index + 2] - 2) < 0.0001)
        }
    }

    @Test func hdrHeadroomAndSDRChannelBoundsArePreserved() throws {
        let image = fixture { x, _ in x < 64 ? 1.4 : 2.0 }
        let hdr = try render(image, settings: .init(sharpeningAmount: 150, developColor: .init(hdrEnabled: true)))
        #expect(hdr[64 * 4] > 2)
        #expect(hdr.allSatisfy { $0.isFinite })
        let sdr = try render(fixture { x, _ in x < 64 ? 0.8 : 0.98 }, settings: .init(sharpeningAmount: 150))
        #expect(sdr.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
    }

    @Test func originalPixelRadiusScalesWithThePreview() throws {
        let image = fixture { x, _ in 0.3 + 0.02 * sin(Double(x) * 1.1) }
        let settings = EditSettings(sharpeningAmount: 100, sharpeningRadius: 2, sharpeningDetail: 100)
        let scaled = try render(image, settings: settings, scale: 0.5)
        var native = settings; native.sharpeningRadius = 1
        #expect(difference(scaled, try render(image, settings: native)) < 0.000001)
        #expect(difference(scaled, try render(image, settings: settings)) > 0.0001)
    }

    @Test func previewExportAndSoftwareContextUseTheSameGraph() throws {
        let input = fixture(alpha: { _ in 0.75 }) { x, y in 0.3 + 0.03 * sin(Double(x + y)) }
        let context = makeContext()
        let cg = try #require(context.createCGImage(input, from: input.extent, format: .RGBA16, colorSpace: space, deferred: false))
        let settings = EditSettings(sharpeningAmount: 70, sharpeningRadius: 1.4, sharpeningDetail: 55, sharpeningMasking: 15)
        let session = EditRenderer.Session(lowPriority: true)
        let preview = try EditRenderer.render(PreviewBitmap(image: cg), settings: settings, session: session)
        let export = try EditRenderer.filterGraph(cg, settings: settings)
        #expect(difference(try pixels(CIImage(cgImage: preview.image)), try pixels(export)) < 0.00003)
        let software = EditRenderer.Session(lowPriority: true, softwareRenderer: true)
        let cpu = try EditRenderer.render(PreviewBitmap(image: cg), settings: settings, session: software)
        #expect(difference(try pixels(CIImage(cgImage: preview.image)), try pixels(CIImage(cgImage: cpu.image))) < 0.0005)
        // The preference can be ignored by macOS; this checks output agreement,
        // not proof that a physical CPU/GPU backend was selected.
    }

    @Test func cachedPrefixDoesNotReuseAnEarlierSharpeningValueOrSourceScale() throws {
        let image = fixture { x, y in 0.3 + 0.04 * sin(Double(x * 2 + y)) }
        let cg = try #require(makeContext().createCGImage(image, from: image.extent, format: .RGBA16, colorSpace: space, deferred: false))
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        var settings = EditSettings(sharpeningAmount: 40)
        _ = try EditRenderer.render(.init(image: cg), settings: settings, session: session)
        settings.sharpeningAmount = 130; settings.sharpeningRadius = 2.7
        let input = PreviewBitmap(image: cg, sourceLongEdge: 256)
        let result = try EditRenderer.render(input, settings: settings, session: session)
        let fresh = try EditRenderer.render(input, settings: settings, session: .init(lowPriority: true))
        #expect(result.sourceLongEdge == 256)
        #expect(difference(try pixels(CIImage(cgImage: result.image)), try pixels(CIImage(cgImage: fresh.image))) < 0.000001)
    }

    @Test func cancelledSharpeningDoesNotPublishOutput() async throws {
        let input = fixture { _, _ in 0.3 }
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try DevelopSharpening.apply(to: input, settings: .init(sharpeningAmount: 100), extent: input.extent, sourcePixelScale: 1)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled sharpening returned an image") }
        catch { #expect(error is CancellationError) }
    }

    @Test func largeSharpeningPreviewsFitTheExistingSharedMemoryBudget() throws {
        let settings = EditSettings(sharpeningAmount: 100, sharpeningMasking: 50)
        let bytes = DevelopSharpening.additionalBytesPerPixel(settings: settings)
        let size = try LocalAdjustmentRenderer.previewSize(width: 4_096, height: 4_096, adjustments: [],
            globalBytesPerPixel: bytes)
        #expect(size.width < 4_096)
        #expect(UInt64(size.width * size.height) * bytes <= LocalAdjustmentRenderer.previewWorkingMemoryBudget)
        // Turning off the amount adds no planes or automatic resolution change.
        #expect(try LocalAdjustmentRenderer.previewSize(width: 4_096, height: 4_096, adjustments: []) == (4_096, 4_096))
    }

    private func fixture(alpha: (Int) -> Double = { _ in 1 }, luminance: (Int, Int) -> Double) -> CIImage {
        var rgba = [Float](); rgba.reserveCapacity(128 * 32 * 4)
        for y in 0..<32 { for x in 0..<128 {
            let a = alpha(x), v = luminance(x, y)
            rgba += [Float(v * a), Float(v * 0.5 * a), Float(v * 0.25 * a), Float(a)]
        } }
        return rgba.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: 128 * 16,
            size: CGSize(width: 128, height: 32), format: .RGBAf, colorSpace: space) }
    }

    private func makeContext() -> CIContext { CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf]) }
    private func render(_ image: CIImage, settings: EditSettings, scale: Double = 1) throws -> [Float] {
        try pixels(DevelopSharpening.apply(to: image, settings: settings, extent: image.extent, sourcePixelScale: scale))
    }
    private func pixels(_ image: CIImage) throws -> [Float] {
        var values = [Float](repeating: 0, count: 128 * 32 * 4)
        values.withUnsafeMutableBytes { makeContext().render(image, toBitmap: $0.baseAddress!, rowBytes: 128 * 16,
            bounds: image.extent, format: .RGBAf, colorSpace: space) }
        #expect(values.allSatisfy { $0.isFinite })
        return values
    }
    private func difference(_ first: [Float], _ second: [Float], x: Range<Int> = 0..<128) -> Double {
        var total = 0.0
        for y in 0..<32 { for column in x {
            for c in 0..<3 { let i = (y * 128 + column) * 4 + c; total += Double(abs(first[i] - second[i])) }
        } }
        return total / Double(32 * x.count * 3)
    }
}
