import AppKit
import Foundation
import ImageIO
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Local mask draft")
struct MaskEditingModelTests {
    @Test @MainActor
    func strokeIsOneUndoBoundaryAndEraseOnlyChangesMask() async throws {
        let model = MaskEditingModel()
        try model.begin(source: source("brush"), canvasSize: size)
        model.radius = 4; model.hardness = 1
        model.beginStroke(at: point(6, 8))
        model.appendPoint(point(8, 8)); model.appendPoint(point(10, 8))
        #expect(model.document?.strokes.isEmpty == true)
        #expect(!model.canUndo)
        model.endStroke()
        let painted = try #require(model.document)
        #expect(painted.strokes.count == 1)
        #expect(painted.strokes[0].points.count == 3)
        #expect(painted.strokes[0].radius == 4)
        #expect(painted.strokes[0].hardness == 1)
        #expect(model.canUndo)
        model.mode = .erase; model.radius = 2
        model.beginStroke(at: point(8, 8)); model.endStroke()
        #expect(model.document?.strokes.count == 2)
        await model.waitForRasterization()
        let erased = try #require(model.rasterResult)
        #expect(erased.raster.bytes[8 * size.width + 8] == 0)
        model.undo()
        #expect(model.document == painted)
        model.undo()
        #expect(model.document?.strokes.isEmpty == true)
        #expect(!model.canUndo)
        model.redo()
        #expect(model.document == painted)
        await model.waitForRasterization()
    }

    @Test @MainActor
    func clearInvertAndOverlayOpacityHaveIndependentSemantics() async throws {
        let model = MaskEditingModel()
        try model.begin(source: source("actions"), canvasSize: size)
        model.radius = 2; model.beginStroke(at: point(8, 8)); model.endStroke()
        let painted = try #require(model.document)
        let revision = model.revision
        model.overlayOpacity = 0.1
        #expect(model.document == painted)
        #expect(model.revision == revision)
        model.invert()
        #expect(model.document == painted.inverted())
        model.clear()
        #expect(model.document == painted.cleared())
        model.undo()
        #expect(model.document == painted.inverted())
        model.undo()
        #expect(model.document == painted)
        await model.waitForRasterization()
    }

    @Test @MainActor
    func leavingImageDoesNotConnectSeparateSegmentsAndUndoRemovesWholeGesture() async throws {
        let model = MaskEditingModel()
        try model.begin(source: source("edge"), canvasSize: size)
        model.radius = 1; model.hardness = 1
        model.appendPoint(point(1, 1)); model.appendPoint(point(3, 1))
        model.breakStrokeSegment()
        model.appendPoint(point(28, 14)); model.appendPoint(point(30, 14)); model.endStroke()
        #expect(model.document?.strokes.count == 2)
        await model.waitForRasterization()
        let result = try #require(model.rasterResult)
        #expect(result.raster.bytes[8 * size.width + 16] == 0)
        model.undo()
        #expect(model.document?.strokes.isEmpty == true)
        #expect(!model.canUndo)
        await model.waitForRasterization()
    }

    @Test @MainActor
    func delayedSourceAndRevisionResultsCannotOverwriteNewDraft() async throws {
        let probe = ControlledMaskRasterizer()
        let model = MaskEditingModel(rasterizer: { try await probe.render($0) })
        let firstSource = source("first"), secondSource = source("second")
        try model.begin(source: firstSource, canvasSize: size)
        await probe.waitForStart(1)
        model.appendPoint(point(3, 3)); model.endStroke()
        try model.begin(source: secondSource, canvasSize: size)
        try await probe.releaseNext()
        await probe.waitForStart(2)
        #expect(model.rasterResult == nil)
        #expect(model.document?.strokes.isEmpty == true)
        model.appendPoint(point(7, 7)); model.endStroke()
        try await probe.releaseNext()
        await probe.waitForStart(3)
        #expect(model.rasterResult == nil)
        try await probe.releaseNext()
        await model.waitForRasterization()
        let result = try #require(model.rasterResult)
        #expect(result.token.source == secondSource)
        #expect(result.token.revision == model.revision)
        #expect(result.token.canvasSize == size)
        #expect(result.token.maskSHA256.count == 64)
        let starts = await probe.startedCount
        #expect(starts == 3)
    }

    @Test @MainActor
    func fastPointsCoalesceAndDiscardRejectsUncooperativeWorker() async throws {
        let probe = ControlledMaskRasterizer()
        let model = MaskEditingModel(rasterizer: { try await probe.render($0) })
        try model.begin(source: source("coalesce"), canvasSize: size)
        await probe.waitForStart(1)
        for x in 1...30 { model.appendPoint(point(Double(x), 5)) }
        model.endStroke()
        let startsBeforeRelease = await probe.startedCount
        #expect(startsBeforeRelease == 1)
        try await probe.releaseNext()
        await probe.waitForStart(2)
        #expect(model.rasterResult == nil)
        model.discard()
        try await probe.releaseNext()
        await model.waitForRasterization()
        #expect(model.document == nil)
        #expect(model.source == nil)
        #expect(model.rasterResult == nil)
        #expect(!model.canUndo && !model.canRedo)
        let starts = await probe.startedCount
        #expect(starts == 2)
    }

    @Test @MainActor
    func gestureDraftIsBoundedBeforeValidationAndPreservesAcceptedSegments() async throws {
        let probe = ControlledMaskRasterizer()
        let model = MaskEditingModel(rasterizer: { try await probe.render($0) })
        try model.begin(source: source("bounded-gesture"), canvasSize: size)
        await probe.waitForStart(1)
        for index in 0..<(MaskDocument.maximumStrokes + 100) {
            model.appendPoint(point(Double(index % 30), 5)); model.breakStrokeSegment()
        }
        #expect(model.errorMessage != nil)
        model.endStroke()
        #expect(model.document?.strokes.count == MaskDocument.maximumStrokes)
        #expect(model.document?.strokes.reduce(0, { $0 + $1.points.count }) == MaskDocument.maximumStrokes)
        model.undo()
        #expect(model.document?.strokes.isEmpty == true)
        try await probe.releaseNext()
        await probe.waitForStart(2)
        try await probe.releaseNext()
        await model.waitForRasterization()
    }

    @Test @MainActor
    func overlayIsBoundedAndNeverDecodesSourceOrChangesNativeCanvas() async throws {
        let canvas = try ArtifactPixelSize(width: 4_096, height: 4_096)
        let model = MaskEditingModel()
        // The source deliberately does not exist. Raster work has no source IO.
        try model.begin(source: source("nonexistent.raw"), canvasSize: canvas)
        model.radius = 5; model.appendPoint(point(2_000, 2_000)); model.endStroke()
        await model.waitForRasterization()
        let result = try #require(model.rasterResult)
        #expect(model.document?.canvasSize == canvas)
        #expect(result.token.canvasSize == canvas)
        #expect(max(result.raster.size.width, result.raster.size.height) <= MaskOverlayWorker.maximumDimension)
        #expect(result.overlay.width == result.raster.size.width)
        #expect(result.overlay.alphaInfo == .premultipliedLast)
    }

    @Test
    func overlayUsesCanonicalNativeResamplingAndCancellation() async throws {
        let canvas = try ArtifactPixelSize(width: 2_048, height: 16)
        let stroke = try MaskStroke(points: [point(1_024.5, 8.5)], radius: 0.7, hardness: 0.3)
        let document = try MaskDocument(canvasSize: canvas, strokes: [stroke])
        let request = MaskRasterRequest(source: source("narrow"), session: UUID(), revision: 7,
                                        document: document, cancellation: MaskRasterCancellation())
        let result = try await MaskOverlayWorker.shared.rasterize(request)
        let native = try MaskRasterizer.rasterize(document)
        #expect(result.raster == (try native.resampled(to: result.raster.size)))
        #expect(result.token.maskSHA256 == (try native.canonicalSHA256().sha256))
        let cancelled = MaskRasterCancellation(); cancelled.cancel()
        let obsolete = MaskRasterRequest(source: request.source, session: request.session, revision: 8,
                                         document: document, cancellation: cancelled)
        await #expect(throws: CancellationError.self) { try await MaskOverlayWorker.shared.rasterize(obsolete) }
    }

    @Test
    func nativeCanvasReadsAllEXIFOrientationsWithoutPreviewDimensions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(repeating: 160, count: 8 * 4 * 4)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: 8, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for orientation in 1...8 {
            let url = directory.appendingPathComponent("orientation-\(orientation).tiff")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let modified = try #require(attributes[.modificationDate] as? Date)
            let byteCount = try #require(attributes[.size] as? NSNumber).int64Value
            let source = AISourceIdentity.original(.init(fileURL: url, modifiedAt: modified, fileSize: byteCount))
            let canvas = try await MaskCanvasSourceReader.shared.size(for: source)
            #expect(canvas.width == (orientation >= 5 ? 4 : 8))
            #expect(canvas.height == (orientation >= 5 ? 8 : 4))
            let stale = AISourceIdentity.original(.init(fileURL: url, modifiedAt: modified.addingTimeInterval(-1), fileSize: byteCount))
            await #expect(throws: MaskCanvasError.sourceChanged) { try await MaskCanvasSourceReader.shared.size(for: stale) }
        }
    }

    private var size: ArtifactPixelSize { try! .init(width: 32, height: 16) }
    private func point(_ x: Double, _ y: Double) -> MaskPoint { try! .init(x: x, y: y) }
    private func source(_ name: String) -> AISourceIdentity {
        .original(.init(fileURL: URL(fileURLWithPath: "/nonexistent/\(name)"), modifiedAt: .distantPast, fileSize: 1))
    }
}

/// Ignores cancellation on purpose: a late native result must still be rejected.
private actor ControlledMaskRasterizer {
    private var pending: [(MaskRasterRequest, CheckedContinuation<MaskRasterResult, Error>)] = []
    private var starts: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var startedCount = 0
    func render(_ request: MaskRasterRequest) async throws -> MaskRasterResult {
        startedCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((request, continuation))
            let ready = starts.filter { $0.0 <= startedCount }
            starts.removeAll { $0.0 <= startedCount }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForStart(_ count: Int) async {
        if startedCount >= count { return }
        await withCheckedContinuation { starts.append((count, $0)) }
    }
    func releaseNext() async throws {
        let (request, continuation) = pending.removeFirst()
        let uncancelled = MaskRasterRequest(source: request.source, session: request.session,
            revision: request.revision, document: request.document, cancellation: MaskRasterCancellation())
        do { continuation.resume(returning: try await MaskOverlayWorker.shared.rasterize(uncancelled)) }
        catch { continuation.resume(throwing: error); throw error }
    }
}
