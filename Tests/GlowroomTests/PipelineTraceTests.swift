import Foundation
import CoreGraphics
import Testing
@testable import Glowroom
import GlowroomCore

@Suite("Pipeline phase tracing")
struct PipelineTraceTests {
    final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [PipelineTrace.Phase] = []
        func record(_ sample: PipelineTrace.Sample) { lock.lock(); phases.append(sample.phase); lock.unlock() }
        func snapshot() -> [PipelineTrace.Phase] { lock.lock(); defer { lock.unlock() }; return phases }
    }

    @Test func detachedDecodeAndRenderKeepRequestObserver() async throws {
        let samples = Samples()
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = PreviewBitmap(image: try #require(context.makeImage()))
        let originals = ImagePreviewPipeline(diskCache: nil, decoder: { _ in
            PipelineTrace.measure(.decode) { bitmap }
        })
        let edits = AdjustedPreviewPipeline(renderer: { input, _ in
            PipelineTrace.measure(.render) { input }
        })
        let request = PreviewRequest(url: URL(fileURLWithPath: "/trace-fixture"), modifiedAt: .distantPast, pixelSize: 64)
        var settings = EditSettings.neutral
        settings.exposure = 1
        try await PipelineTrace.$observer.withValue({ samples.record($0) }) {
            let input = try await originals.image(for: request, priority: .selected)
            _ = try await edits.image(input, request: request, settings: settings, priority: .selected)
        }
        let phases = samples.snapshot()
        for phase in [PipelineTrace.Phase.decodeQueue, .decode, .previewRequest, .renderQueue, .render, .editedRequest] {
            #expect(phases.filter { $0 == phase }.count == 1)
        }
        // Task-local instrumentation never leaks into the next caller.
        #expect(PipelineTrace.observer == nil)
        _ = try await originals.image(for: request, priority: .selected)
        #expect(samples.snapshot().count == phases.count)
    }
}
