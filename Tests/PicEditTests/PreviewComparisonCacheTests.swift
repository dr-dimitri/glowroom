import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Preview comparison cache reuse")
struct PreviewComparisonCacheTests {
    @Test
    func comparingEditedVersionsAndOriginalReusesDecodedBaseAndRenderedResults() async throws {
        let probe = PreviewComparisonProbe()
        let decoder = ImagePreviewPipeline(concurrencyLimit: 1, decoder: { try probe.decode($0) })
        let renderer = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
            renderer: { bitmap, settings in probe.render(bitmap, settings: settings) })
        // All three comparisons use the developed original, including neutral
        // settings. Switching to a camera thumbnail would change the source.
        let request = PreviewRequest(url: URL(fileURLWithPath: "/tmp/comparison-preview-fixture.raw"),
            modifiedAt: Date(timeIntervalSince1970: 100), pixelSize: 2400,
            fileSize: 50, allowsEmbeddedPreview: false)
        var committed = EditSettings.neutral
        committed.exposure = 0.6
        var comparison = committed
        comparison.shadows = 30
        let base = try await decoder.image(for: request, priority: .selected)
        let firstCommitted = try await renderer.image(base, request: request, settings: committed, priority: .selected)
        let firstProposed = try await renderer.image(base, request: request, settings: comparison, priority: .selected)
        for settings in [committed, comparison, .neutral, comparison, committed, comparison] {
            let reusedBase = try await decoder.image(for: request, priority: .selected)
            #expect(reusedBase.image === base.image)
            let rendered = try await renderer.image(reusedBase, request: request, settings: settings, priority: .selected)
            if settings == committed { #expect(rendered.image === firstCommitted.image) }
            if settings == comparison { #expect(rendered.image === firstProposed.image) }
        }
        #expect(probe.decodeCount == 1)
        #expect(probe.renderedSettings == [committed, comparison])
    }
}

private final class PreviewComparisonProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var decodes = 0
    private var renders: [EditSettings] = []

    var decodeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return decodes
    }

    var renderedSettings: [EditSettings] {
        lock.lock(); defer { lock.unlock() }
        return renders
    }

    func decode(_ request: PreviewRequest) throws -> PreviewBitmap {
        lock.lock(); decodes += 1; lock.unlock()
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage()
        else { throw PreviewFailure.unavailable }
        return PreviewBitmap(image: image)
    }

    func render(_ bitmap: PreviewBitmap, settings: EditSettings) -> PreviewBitmap {
        lock.lock(); renders.append(settings); lock.unlock()
        return bitmap
    }
}
