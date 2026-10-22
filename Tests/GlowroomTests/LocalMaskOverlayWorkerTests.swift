import CoreGraphics
import CoreImage
import Darwin
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Bounded inline mask overlay worker")
struct LocalMaskOverlayWorkerTests {
    @Test(arguments: [
        [4_800, 2_400, 1_600, 800], [2_400, 4_800, 800, 1_600],
        [16_384, 1, 1_600, 1], [1, 16_384, 1, 1_600], [64, 48, 64, 48]
    ])
    func boundsBitmapWithoutUpscalingOrChangingAspectRatio(_ dimensions: [Int]) async throws {
        let size = try ArtifactPixelSize(width: dimensions[0], height: dimensions[1])
        let mask = try LocalAdjustmentMask(shape: .linear(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1)))
        let image = try await LocalMaskOverlayWorker().image(mask, size: size)
        #expect(image.width == dimensions[2])
        #expect(image.height == dimensions[3])
        #expect(max(image.width, image.height) <= LocalMaskOverlayWorker.maximumDimension)
        #expect(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
    }

    @Test
    func proxyAlphaPreservesAllShapesFeatherStrengthInversionAndRefinement() async throws {
        let size = try ArtifactPixelSize(width: 4_800, height: 2_400)
        let paint = try MaskStroke(points: [.init(x: 240, y: 960), .init(x: 2_400, y: 1_920)],
                                   radius: 180, hardness: 0.4)
        let erase = try MaskStroke(points: [.init(x: 2_100, y: 1_200), .init(x: 3_000, y: 900)],
                                   radius: 120, hardness: 0.7, mode: .erase)
        let document = try MaskDocument(canvasSize: size, strokes: [paint, erase])
        let raster = try LocalMaskRaster(width: 4, height: 2, bytes: Data([0, 64, 192, 255, 255, 192, 64, 0]))
        let shapes: [LocalMaskShape] = [
            .brush(document), .linear(start: try .init(x: 0.1, y: 0.2), end: try .init(x: 0.9, y: 0.8)),
            .radial(center: try .init(x: 0.6, y: 0.4), radiusX: 0.3, radiusY: 0.4, rotation: 0.6),
            .subject(raster), .sky(raster)
        ]
        let worker = LocalMaskOverlayWorker()
        let context = CIContext(options: [.cacheIntermediates: false])
        for shape in shapes {
            for inverted in [false, true] {
                let mask = try LocalAdjustmentMask(shape: shape, isInverted: inverted, opacity: 0.63,
                                                   feather: 0.25, refinement: document)
                let overlay = try await worker.image(mask, size: size)
                let extent = CGRect(x: 0, y: 0, width: overlay.width, height: overlay.height)
                // The uncached renderer is also used for actual local edits.
                // Compare scalar coverage with overlay alpha, independently of
                // the red visualization and its premultiplied RGB channels.
                let scalar = try LocalAdjustmentRenderer.maskImage(mask, extent: extent)
                let expected = bytes(scalar, extent: extent, context: context)
                let actual = bytes(CIImage(cgImage: overlay, options: [.colorSpace: NSNull()]),
                                   extent: extent, context: context)
                var maximumDifference = 0
                for pixel in stride(from: 0, to: expected.count, by: 4) {
                    maximumDifference = max(maximumDifference, abs(Int(expected[pixel]) - Int(actual[pixel + 3])))
                }
                #expect(maximumDifference <= 1, "Proxy alpha must match rendered mask coverage to one Gray8 level")
                #expect(actual.contains { $0 > 0 && $0 < 255 })
            }
        }
    }

    @MainActor @Test
    func rasterAndImageMaterializationLeaveTheMainThread() async throws {
        let recorder = OverlayThreadRecorder()
        let document = try MaskDocument(canvasSize: .init(width: 64, height: 32),
            strokes: [.init(points: [.init(x: 20, y: 16)], radius: 6)])
        let mask = try LocalAdjustmentMask(shape: .brush(document))
        _ = try await PipelineTrace.$observer.withValue({ recorder.record($0) }) {
            try await LocalMaskOverlayWorker().image(mask, size: document.canvasSize)
        }
        let observations = recorder.snapshot()
        #expect(Set(observations.map(\.phase)) == [.maskRasterization, .maskOverlayGraph, .maskOverlayImage])
        #expect(observations.allSatisfy { !$0.onMainThread })
    }

    @Test
    func cancellationIsCheckedBeforeAndAfterNativeRendering() async throws {
        let size = try ArtifactPixelSize(width: 64, height: 32)
        let mask = try LocalAdjustmentMask(shape: .linear(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1)))
        let worker = LocalMaskOverlayWorker()
        let cancelledBefore = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.image(mask, size: size)
        }
        await #expect(throws: CancellationError.self) { try await cancelledBefore.value }
        let cancelledAfter = Task.detached {
            try await PipelineTrace.$observer.withValue({ sample in
                if sample.phase == .maskOverlayImage { withUnsafeCurrentTask { $0?.cancel() } }
            }) {
                try await worker.image(mask, size: size)
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelledAfter.value }
        let next = try await worker.image(mask, size: size)
        #expect(next.width == size.width && next.height == size.height)
    }

    private func bytes(_ image: CIImage, extent: CGRect, context: CIContext) -> Data {
        let rowBytes = Int(extent.width) * 4
        var output = Data(count: rowBytes * Int(extent.height))
        output.withUnsafeMutableBytes { storage in
            context.render(image, toBitmap: storage.baseAddress!, rowBytes: rowBytes, bounds: extent,
                           format: .RGBA8, colorSpace: nil)
        }
        return output
    }
}

private final class OverlayThreadRecorder: @unchecked Sendable {
    struct Observation {
        let phase: PipelineTrace.Phase
        let onMainThread: Bool
    }
    private let lock = NSLock()
    private var observations: [Observation] = []
    func record(_ sample: PipelineTrace.Sample) {
        lock.lock(); defer { lock.unlock() }
        observations.append(Observation(phase: sample.phase, onMainThread: Thread.isMainThread))
    }
    func snapshot() -> [Observation] { lock.lock(); defer { lock.unlock() }; return observations }
}

/// Run each variant in its own process, after builds/tests have finished. This
/// measures overlay rendering/consumption, not pointer-to-screen latency or RAW
/// decoding. The inline workspace currently caps its coordinate canvas at 1024
/// pixels, including RAW sources; larger output is only an optional stress case.
@Suite("Inline mask overlay performance probe", .serialized)
struct LocalMaskOverlayPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_MASK_OVERLAY_BENCHMARK"] != nil))
    func measureFreshWarmStrokeAndSliderFrames() async throws {
        let variant = try #require(ProcessInfo.processInfo.environment["GLOWROOM_MASK_OVERLAY_BENCHMARK"])
        #expect(["reference", "bounded"].contains(variant))
        guard ["reference", "bounded"].contains(variant) else { return }
        var dimensionsToMeasure = [[1_024, 683], [1_024, 1_024]]
        if ProcessInfo.processInfo.environment["GLOWROOM_MASK_OVERLAY_BENCHMARK_STRESS"] == "1" {
            dimensionsToMeasure.append([4_096, 4_096])
        }
        for dimensions in dimensionsToMeasure {
            let size = try ArtifactPixelSize(width: dimensions[0], height: dimensions[1])
            let renderer = OverlayBenchmarkRenderer(reference: variant == "reference")
            let document = try benchmarkDocument(size)
            let mask = try LocalAdjustmentMask(shape: .brush(document), opacity: 0.8, feather: 0.3)
            var frames: [(String, LocalAdjustmentMask)] = [("fresh-renderer", mask)]
            frames += (0..<6).map { _ in ("warm-identical", mask) }
            for count in 1...12 {
                let points = try (0..<count).map { index in
                    try MaskPoint(x: Double(size.width) * (0.1 + Double(index) * 0.06),
                                  y: Double(size.height) * (0.6 + sin(Double(index) * 0.6) * 0.1))
                }
                var active = mask
                active.shape = .brush(try document.appending(.init(points: points,
                    radius: Double(min(size.width, size.height)) * 0.025, hardness: 0.5)))
                frames.append(("active-stroke", active))
            }
            for index in 0..<12 {
                var slider = mask
                slider.opacity = 0.2 + Double(index) * 0.06
                slider.feather = Double(index) / 12
                frames.append(("strength-feather", slider))
            }
            for (index, frame) in frames.enumerated() {
                let sample = try await renderer.render(frame.1, size: size)
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                let result: [String: Any] = [
                    "kind": "inline-mask-overlay", "variant": variant, "phase": frame.0, "frame": index,
                    "canvas_scope": size.width <= 1_024 ? "current-inline-canvas" : "optional-large-canvas-stress",
                    "canvas_width": size.width, "canvas_height": size.height,
                    "output_width": sample.width, "output_height": sample.height,
                    "render_ms": sample.renderMS, "consume_ms": sample.consumeMS,
                    "total_ms": sample.renderMS + sample.consumeMS, "checksum": sample.checksum,
                    "process_peak_rss_bytes": usage.ru_maxrss,
                    "scope": "Synthetic mask at current inline canvas size unless marked stress; fresh renderer is not cold OS/GPU cache; sequential frames measure rendering and consumption, not coalescing, cursor latency, RAW decode or UI scheduling"
                ]
                let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                FileHandle.standardOutput.write(json + Data([10]))
            }
        }
    }

    private func benchmarkDocument(_ size: ArtifactPixelSize) throws -> MaskDocument {
        let short = Double(min(size.width, size.height))
        let strokes = try (0..<12).map { index in
            let points = try (0..<8).map { step in
                try MaskPoint(x: Double(size.width) * (0.08 + Double(step) * 0.11),
                              y: Double(size.height) * (0.08 + Double(index) * 0.065 + sin(Double(step)) * 0.025))
            }
            return try MaskStroke(points: points, radius: short * 0.018, hardness: 0.4,
                                  mode: index.isMultiple(of: 5) ? .erase : .brush)
        }
        return try MaskDocument(canvasSize: size, strokes: strokes)
    }
}

private actor OverlayBenchmarkRenderer {
    struct Sample: Sendable {
        let width: Int
        let height: Int
        let renderMS: Double
        let consumeMS: Double
        let checksum: UInt64
    }
    private let bounded: LocalMaskOverlayWorker?
    private let context: CIContext?
    private let cache: LocalMaskImageCache?
    private let alpha: CIColorKernel?

    init(reference: Bool) {
        bounded = reference ? nil : LocalMaskOverlayWorker()
        context = reference ? CIContext(options: [.cacheIntermediates: false]) : nil
        cache = reference ? LocalMaskImageCache() : nil
        alpha = reference ? CIColorKernel(source: """
            kernel vec4 oldOverlay(__sample mask) {
                float weight = clamp(mask.r, 0.0, 1.0);
                return vec4(weight, 0.0, 0.0, weight);
            }
            """) : nil
    }

    func render(_ mask: LocalAdjustmentMask, size: ArtifactPixelSize) async throws -> Sample {
        let start = DispatchTime.now().uptimeNanoseconds
        let image: CGImage
        if let bounded { image = try await bounded.image(mask, size: size) }
        else {
            // Exact previous worker route: native extent and default deferred
            // CGImage. CGContext consumption includes its delayed native work.
            let extent = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            let scalar = try LocalAdjustmentRenderer.maskImage(mask, extent: extent, cache: cache)
            let graph = try #require(alpha?.apply(extent: extent, arguments: [scalar]))
            image = try #require(context?.createCGImage(graph, from: extent))
        }
        let rendered = DispatchTime.now().uptimeNanoseconds
        let checksum = try autoreleasepool {
            let sink = try #require(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            sink.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = try #require(sink.data).assumingMemoryBound(to: UInt8.self)
            return stride(from: 3, to: image.width * image.height * 4, by: 4_096)
                .reduce(UInt64(0)) { $0 &+ UInt64(pixels[$1]) }
        }
        let consumed = DispatchTime.now().uptimeNanoseconds
        return Sample(width: image.width, height: image.height,
            renderMS: Double(rendered - start) / 1e6, consumeMS: Double(consumed - rendered) / 1e6, checksum: checksum)
    }
}
