import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Bounded local mask geometry cache")
struct LocalMaskImageCacheTests {
    @Test
    func incrementalBrushAndRefinementGraphsMatchFullRasterHistory() throws {
        let cache = LocalMaskImageCache()
        let reference = LocalMaskImageCache(incrementalEnabled: false)
        let context = CIContext(options: [.cacheIntermediates: false])
        let canvas = try ArtifactPixelSize(width: 128, height: 64)
        let empty = try MaskDocument(canvasSize: canvas)
        let paint = try empty.appending(.init(points: [.init(x: 0, y: 0), .init(x: 128, y: 64)], radius: 12, hardness: 0.37))
        let erase = try paint.appending(.init(points: [.init(x: 60, y: 30)], radius: 4.7, hardness: 0.2, mode: .erase))
        for extent in [CGRect(x: 0, y: 0, width: 96, height: 48), CGRect(x: 0, y: 0, width: 192, height: 96)] {
            for document in [empty, paint, erase, erase.inverted(), paint, empty, erase] {
                for isRefinement in [false, true] {
                    var mask = try LocalAdjustmentMask(shape: .brush(document), opacity: 0.7, feather: 0.14)
                    if isRefinement {
                        mask.shape = .linear(start: try .init(x: 0.1, y: 0.8), end: try .init(x: 0.9, y: 0.2))
                        mask.refinement = try MaskDocument(canvasSize: document.canvasSize, strokes: document.strokes)
                    }
                    let actual = try LocalAdjustmentRenderer.maskImage(mask, extent: extent, cache: cache)
                    let expected = try LocalAdjustmentRenderer.maskImage(mask, extent: extent, cache: reference)
                    #expect(pixels(actual, extent: extent, context: context) == pixels(expected, extent: extent, context: context))
                }
            }
        }
    }

    @Test
    func incrementalBasisSharesTheExistingCacheMemoryBudget() throws {
        let canvas = try ArtifactPixelSize(width: 64, height: 32)
        let cost = canvas.width * canvas.height
        let limit = 8 * cost
        let cache = LocalMaskImageCache(byteLimit: limit)
        let extent = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        var document = try MaskDocument(canvasSize: canvas)
        for index in 0..<8 {
            document = try document.appending(.init(points: [.init(x: Double(index * 5), y: 12)], radius: 2))
            _ = try cache.image(document, extent: extent)
            let state = cache.diagnostics()
            #expect(state.retainedBytes <= limit)
            #expect(state.basisBytes >= cost)
            #expect(state.imageCount < 8)
        }
        #expect(cache.diagnostics().lastRasterReuse == .appended)
        let tooSmall = LocalMaskImageCache(byteLimit: cost - 1)
        _ = try tooSmall.image(document, extent: extent)
        #expect(tooSmall.diagnostics().retainedBytes == 0)
        #expect(tooSmall.diagnostics().basisBytes == 0)
    }

    @Test
    func cancellationAndWorkLimitFailureDoNotPublishNewBasis() async throws {
        let canvas = try ArtifactPixelSize(width: 32, height: 16)
        let extent = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let document = try MaskDocument(canvasSize: canvas, strokes: [.init(points: [.init(x: 8, y: 8)], radius: 1)])
        let appended = try document.appending(.init(points: [.init(x: 20, y: 8)], radius: 1))
        let excessive = try document.appending(.init(points: [.init(x: 16, y: 8)], radius: 30))
        let cache = LocalMaskImageCache(maximumSampleEvaluations: 64)
        _ = try cache.image(document, extent: extent)
        #expect(throws: ArtifactContractError.limitExceeded) { try cache.image(excessive, extent: extent) }
        let cancelled = Task.detached {
            try PipelineTrace.$observer.withValue({ sample in
                if sample.phase == .maskRasterization { withUnsafeCurrentTask { $0?.cancel() } }
            }) {
                _ = try cache.image(appended, extent: extent)
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(cache.diagnostics().imageCount == 1)
        _ = try cache.image(appended, extent: extent)
        #expect(cache.diagnostics().lastRasterReuse == .appended)
    }

    @Test
    func tinyRastersStillBoundRetainedObjectsAndDocumentMetadata() throws {
        let cache = LocalMaskImageCache()
        let extent = CGRect(x: 0, y: 0, width: 1, height: 1)
        var document = try MaskDocument(canvasSize: .init(width: 1, height: 1))
        for index in 0..<96 {
            document = try document.appending(.init(points: [.init(x: Double(index) / 96, y: 0.5)], radius: 1))
            _ = try cache.image(document, extent: extent)
        }
        let state = cache.diagnostics()
        #expect(state.imageCount == LocalMaskImageCache.maximumEntries)
        #expect(state.retainedBytes > state.imageCount + 1, "Retained document arrays also consume the byte budget")
        #expect(state.retainedBytes <= 16 * 1_024 * 1_024)
    }

    private func pixels(_ image: CIImage, extent: CGRect, context: CIContext) -> Data {
        let rowBytes = Int(extent.width) * 4
        var bytes = Data(count: rowBytes * Int(extent.height))
        bytes.withUnsafeMutableBytes { storage in
            context.render(image, toBitmap: storage.baseAddress!, rowBytes: rowBytes, bounds: extent,
                           format: .RGBA8, colorSpace: nil)
        }
        return bytes
    }
}
