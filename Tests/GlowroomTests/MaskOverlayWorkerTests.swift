import AppKit
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Transactional native mask worker")
struct MaskOverlayWorkerTests {
    @Test
    func optimizedWorkerMatchesFullReferenceThroughEditHistory() async throws {
        let canvas = try ArtifactPixelSize(width: 2_048, height: 37)
        let paint = try MaskStroke(points: [point(0, 0), point(800, 20), point(2_048, 37)], radius: 9.3, hardness: 0.2)
        let erase = try MaskStroke(points: [point(510, 18), point(1_510, 15)], radius: 4.8, hardness: 0.63, mode: .erase)
        let empty = try MaskDocument(canvasSize: canvas)
        let painted = try empty.appending(paint)
        let erased = try painted.appending(erase)
        let documents = [empty, painted, erased, erased.inverted(), painted, erased, empty, painted]
        let session = UUID()
        let optimized = MaskOverlayWorker()
        let reference = MaskOverlayWorker(usesNativeCache: false, usesOptimizedResampling: false)
        for (revision, document) in documents.enumerated() {
            let request = request(document, session: session, revision: UInt64(revision))
            let actual = try await optimized.rasterize(request)
            let expected = try await reference.rasterize(request)
            #expect(actual.token == expected.token)
            #expect(actual.raster == expected.raster)
            #expect(overlayBytes(actual.overlay) == overlayBytes(expected.overlay))
            #expect(expected.nativeRasterReuse == .full)
        }
    }

    @Test
    func cacheRequiresSourceSessionCanvasAndMonotonicRevision() async throws {
        let worker = MaskOverlayWorker()
        let empty = try MaskDocument(canvasSize: .init(width: 32, height: 16))
        let painted = try empty.appending(.init(points: [point(8, 8)], radius: 2))
        let session = UUID(), nextSession = UUID()
        let first = try await worker.rasterize(request(empty, sourceName: "first", session: session, revision: 4))
        #expect(first.nativeRasterReuse == .full)
        let same = try await worker.rasterize(request(empty, sourceName: "first", session: session, revision: 4))
        #expect(same.nativeRasterReuse == .unchanged)
        let revisionConflict = try await worker.rasterize(request(painted, sourceName: "first", session: session, revision: 4))
        #expect(revisionConflict.nativeRasterReuse == .full)
        let backwards = try await worker.rasterize(request(painted, sourceName: "first", session: session, revision: 3))
        #expect(backwards.nativeRasterReuse == .full)
        let sourceChanged = try await worker.rasterize(request(painted, sourceName: "second", session: session, revision: 5))
        #expect(sourceChanged.nativeRasterReuse == .full)
        let sessionChanged = try await worker.rasterize(request(painted, sourceName: "second", session: nextSession, revision: 6))
        #expect(sessionChanged.nativeRasterReuse == .full)
        let otherCanvas = try MaskDocument(canvasSize: .init(width: 64, height: 16))
        let canvasChanged = try await worker.rasterize(request(otherCanvas, sourceName: "second", session: nextSession, revision: 7))
        #expect(canvasChanged.nativeRasterReuse == .full)
    }

    @Test
    func cancellationAfterOverlayDoesNotPublishCandidate() async throws {
        let worker = MaskOverlayWorker()
        let document = try MaskDocument(canvasSize: .init(width: 32, height: 16),
                                        strokes: [.init(points: [point(8, 8)], radius: 2)])
        let appended = try document.appending(.init(points: [point(20, 8)], radius: 3, mode: .erase))
        let session = UUID()
        _ = try await worker.rasterize(request(document, session: session, revision: 1))
        let cancellation = MaskRasterCancellation()
        let cancelledRequest = request(appended, session: session, revision: 2, cancellation: cancellation)
        let timings = MaskTimingRecorder()
        await #expect(throws: CancellationError.self) {
            try await worker.rasterize(cancelledRequest, timingObserver: { sample in
                timings.record(sample)
                if sample.phase == .overlay { cancellation.cancel() }
            })
        }
        let next = try await worker.rasterize(request(appended, session: session, revision: 3))
        // An accidentally published cancelled candidate would yield unchanged.
        #expect(next.nativeRasterReuse == .appended)
        #expect(timings.snapshot().last?.phase == .total)
        #expect(timings.snapshot().last?.completed == false)
    }

    @Test
    func failedRasterDoesNotReplaceSuccessfulBasisAndUndoRebuilds() async throws {
        let worker = MaskOverlayWorker(maximumSampleEvaluations: 64)
        let document = try MaskDocument(canvasSize: .init(width: 32, height: 16),
                                        strokes: [.init(points: [point(8, 8)], radius: 1)])
        let expensive = try document.appending(.init(points: [point(16, 8)], radius: 30))
        let appended = try document.appending(.init(points: [point(20, 8)], radius: 1))
        let session = UUID()
        _ = try await worker.rasterize(request(document, session: session, revision: 1))
        await #expect(throws: ArtifactContractError.limitExceeded) {
            try await worker.rasterize(request(expensive, session: session, revision: 2))
        }
        let next = try await worker.rasterize(request(appended, session: session, revision: 3))
        #expect(next.nativeRasterReuse == .appended)
        let undone = try await worker.rasterize(request(document, session: session, revision: 4))
        #expect(undone.nativeRasterReuse == .full)
        #expect(undone.raster == (try MaskRasterizer.rasterize(document)))
    }

    @Test
    func timingObserverUsesProductionPhasesAndIncludesTotal() async throws {
        let timings = MaskTimingRecorder()
        let document = try MaskDocument(canvasSize: .init(width: 32, height: 16))
        _ = try await MaskOverlayWorker().rasterize(request(document), timingObserver: { timings.record($0) })
        let samples = timings.snapshot()
        #expect(samples.map(\.phase) == [.nativeRasterization, .resampling, .hashing, .overlay, .total])
        #expect(samples.allSatisfy { $0.completed })
        #expect(samples.last!.elapsedNanoseconds >= samples.dropLast().reduce(0) { $0 + $1.elapsedNanoseconds })
    }

    private func request(_ document: MaskDocument, sourceName: String = "worker", session: UUID = UUID(),
                         revision: UInt64 = 1, cancellation: MaskRasterCancellation = MaskRasterCancellation()) -> MaskRasterRequest {
        MaskRasterRequest(source: .original(.init(fileURL: URL(fileURLWithPath: "/nonexistent/\(sourceName)"),
                                                modifiedAt: .distantPast, fileSize: 1)),
                          session: session, revision: revision, document: document, cancellation: cancellation)
    }
    private func point(_ x: Double, _ y: Double) -> MaskPoint { try! .init(x: x, y: y) }
    private func overlayBytes(_ image: CGImage) -> Data? {
        guard let data = image.dataProvider?.data else { return nil }
        return data as Data
    }
}

private final class MaskTimingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [MaskRasterTiming] = []
    func record(_ sample: MaskRasterTiming) { lock.lock(); samples.append(sample); lock.unlock() }
    func snapshot() -> [MaskRasterTiming] { lock.lock(); defer { lock.unlock() }; return samples }
}
