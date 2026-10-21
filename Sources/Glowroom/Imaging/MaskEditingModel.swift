import AppKit
import Foundation
import Darwin
import ImageIO
import os
import GlowroomCore

/// A job is bound to the immutable oriented source, not a progressive preview bitmap.
struct MaskRasterToken: Hashable, Sendable {
    let source: AISourceIdentity
    let session: UUID
    let revision: UInt64
    let canvasSize: ArtifactPixelSize
    let maskSHA256: String
}

struct MaskRasterRequest: Sendable {
    let source: AISourceIdentity
    let session: UUID
    let revision: UInt64
    let document: MaskDocument
    let cancellation: MaskRasterCancellation
}

struct MaskRasterResult: @unchecked Sendable {
    let token: MaskRasterToken
    let raster: MaskRaster
    let overlay: CGImage
    let nativeRasterReuse: MaskRasterizationReuse
}

/// Native Instruments intervals and the developer benchmark observe identical
/// production stages. A failed/cancelled stage reports its spent work as well.
enum MaskRasterPhase: String, CaseIterable, Sendable {
    case nativeRasterization, resampling, hashing, overlay, total

    fileprivate var signpostName: StaticString {
        switch self {
        case .nativeRasterization: return "Mask Native Raster"
        case .resampling: return "Mask Resample"
        case .hashing: return "Mask Canonical Hash"
        case .overlay: return "Mask Overlay"
        case .total: return "Mask Total"
        }
    }
}

struct MaskRasterTiming: Sendable {
    let phase: MaskRasterPhase
    let elapsedNanoseconds: UInt64
    let completed: Bool
}

final class MaskRasterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
        try Task.checkCancellation()
    }
}

/// One shared, serial CPU worker bounds mask memory and avoids nested worker pools.
/// The model retains at most one running request and one replacement per editor.
actor MaskOverlayWorker {
    static let shared = MaskOverlayWorker()
    static let maximumDimension = 1_600
    private static let signpostLog = OSLog(subsystem: "com.glowroom.app", category: "MaskRaster")

    /// Exactly one successful native state is retained. Data uses copy-on-write;
    /// a candidate remains private until all dependent stages have succeeded.
    private struct NativeState {
        let source: AISourceIdentity
        let session: UUID
        let revision: UInt64
        let document: MaskDocument
        let cache: MaskRasterizationCache

        func accepts(_ request: MaskRasterRequest) -> Bool {
            source == request.source && session == request.session &&
            document.canvasSize == request.document.canvasSize &&
            (request.revision > revision || (request.revision == revision && request.document == document))
        }
    }
    private var nativeState: NativeState?
    private let usesNativeCache: Bool
    private let usesOptimizedResampling: Bool
    private let maximumSampleEvaluations: Int

    /// Reference switches retain the former full-raster/resampling path for the
    /// developer comparison. Production uses the same bounded serial worker.
    init(usesNativeCache: Bool = true, usesOptimizedResampling: Bool = true,
         maximumSampleEvaluations: Int = 268_435_456) {
        self.usesNativeCache = usesNativeCache
        self.usesOptimizedResampling = usesOptimizedResampling
        self.maximumSampleEvaluations = maximumSampleEvaluations
    }

    func rasterize(_ request: MaskRasterRequest,
                   timingObserver: (@Sendable (MaskRasterTiming) -> Void)? = nil) throws -> MaskRasterResult {
        try measure(.total, observer: timingObserver) {
            try request.cancellation.check()
            let native = request.document.canvasSize
            let scale = min(1, Double(Self.maximumDimension) / Double(max(native.width, native.height)))
            let output = try ArtifactPixelSize(width: max(1, Int((Double(native.width) * scale).rounded())),
                                               height: max(1, Int((Double(native.height) * scale).rounded())))
            // Native Gray8 stays authoritative. Identity is checked before the
            // core examines exact document/prefix compatibility; a revision
            // rollback or conflicting same-revision draft starts a fresh basis.
            var candidate: MaskRasterizationUpdate?
            let nativeRaster = try measure(.nativeRasterization, observer: timingObserver) {
                if usesNativeCache {
                    let base = nativeState.flatMap { $0.accepts(request) ? $0.cache : nil } ?? MaskRasterizationCache()
                    let update = try base.rasterize(request.document, maximumSampleEvaluations: maximumSampleEvaluations,
                                                    cancellation: { try request.cancellation.check() })
                    candidate = update
                    return update.raster
                }
                return try MaskRasterizer.rasterize(request.document, maximumSampleEvaluations: maximumSampleEvaluations,
                                                     cancellation: { try request.cancellation.check() })
            }
            let raster = try measure(.resampling, observer: timingObserver) {
                if usesOptimizedResampling {
                    return try nativeRaster.resampledOptimized(to: output, cancellation: { try request.cancellation.check() })
                }
                return try nativeRaster.resampled(to: output, cancellation: { try request.cancellation.check() })
            }
            let hash = try measure(.hashing, observer: timingObserver) {
                try nativeRaster.canonicalSHA256(cancellation: { try request.cancellation.check() }).sha256
            }
            let overlay = try measure(.overlay, observer: timingObserver) {
                try Self.makeOverlay(from: raster, cancellation: { try request.cancellation.check() })
            }
            try request.cancellation.check()
            if let candidate {
                nativeState = NativeState(source: request.source, session: request.session, revision: request.revision,
                                          document: request.document, cache: candidate.cache)
            }
            return MaskRasterResult(token: MaskRasterToken(source: request.source, session: request.session,
                revision: request.revision, canvasSize: native, maskSHA256: hash), raster: raster, overlay: overlay,
                nativeRasterReuse: candidate?.reuse ?? .full)
        }
    }

    static func makeOverlay(from raster: MaskRaster,
                            cancellation: @Sendable () throws -> Void = {}) throws -> CGImage {
        try Task.checkCancellation(); try cancellation()
        let output = raster.size
        // The UI image carries the data weight only in alpha. Standard CGImage
        // construction requires a color space, so use a bounded premultiplied RGBA
        // overlay rather than assigning an image color profile to the Gray8 mask.
        var overlayBytes = Data(count: output.width * output.height * 4)
        try overlayBytes.withUnsafeMutableBytes { destination in
            try raster.bytes.withUnsafeBytes { source in
                let dst = destination.bindMemory(to: UInt8.self)
                let src = source.bindMemory(to: UInt8.self)
                for index in 0..<src.count {
                    if index.isMultiple(of: 65_536) { try Task.checkCancellation(); try cancellation() }
                    dst[index * 4] = src[index]
                    dst[index * 4 + 3] = src[index]
                }
            }
        }
        guard let provider = CGDataProvider(data: overlayBytes as CFData),
              let overlay = CGImage(width: output.width, height: output.height, bitsPerComponent: 8,
                                    bitsPerPixel: 32, bytesPerRow: output.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ArtifactContractError.invalidValue("Maskenoverlay") }
        try Task.checkCancellation(); try cancellation()
        return overlay
    }

    private func measure<T>(_ phase: MaskRasterPhase, observer: (@Sendable (MaskRasterTiming) -> Void)?,
                            operation: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: phase.signpostName, signpostID: id)
        let start = DispatchTime.now().uptimeNanoseconds
        var completed = false
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            os_signpost(.end, log: Self.signpostLog, name: phase.signpostName, signpostID: id)
            observer?(MaskRasterTiming(phase: phase, elapsedNanoseconds: elapsed, completed: completed))
        }
        let result = try operation()
        completed = true
        return result
    }
}

@MainActor
final class MaskEditingModel: ObservableObject {
    typealias Rasterizer = @Sendable (MaskRasterRequest) async throws -> MaskRasterResult
    @Published private(set) var document: MaskDocument?
    @Published private(set) var previewDocument: MaskDocument?
    @Published private(set) var source: AISourceIdentity?
    @Published private(set) var rasterResult: MaskRasterResult?
    @Published private(set) var isRasterizing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var radius: Double = 30
    @Published var hardness: Double = 0.8
    @Published var overlayOpacity: Double = 0.55
    @Published var mode: MaskStrokeMode = .brush

    private var undoDocuments: [MaskDocument] = []
    private var redoDocuments: [MaskDocument] = []
    private var completedSegments: [MaskStroke] = []
    private var points: [MaskPoint] = []
    private var activePointCount = 0
    private var draftLimitReached = false
    private var committedPointCount = 0
    private var activeStyle: (radius: Double, hardness: Double, mode: MaskStrokeMode)?
    private(set) var revision: UInt64 = 0
    private var session = UUID()
    private let rasterizer: Rasterizer
    private let rendersOverlay: Bool
    private var pending: MaskRasterRequest?
    private var runningCancellation: MaskRasterCancellation?
    private var worker: Task<Void, Never>?

    init(rasterizer: @escaping Rasterizer = { try await MaskOverlayWorker.shared.rasterize($0) }, rendersOverlay: Bool = true) {
        self.rasterizer = rasterizer
        self.rendersOverlay = rendersOverlay
    }

    /// Explicit new draft: leaving the editor or replacing the source loses no accepted edit.
    func begin(source: AISourceIdentity, canvasSize: ArtifactPixelSize) throws {
        try load(source: source, document: MaskDocument(canvasSize: canvasSize))
    }

    /// Local adjustments may reopen a saved vector mask without changing its
    /// coordinate canvas. The original disposable generation editor uses begin.
    func load(source: AISourceIdentity, document: MaskDocument) throws {
        try document.validate()
        discard()
        self.source = source
        self.document = document
        committedPointCount = document.strokes.reduce(0) { $0 + $1.points.count }
        scheduleRaster()
    }

    func discard() {
        session = UUID(); revision = 0
        runningCancellation?.cancel(); pending?.cancellation.cancel(); pending = nil
        source = nil; document = nil; previewDocument = nil; rasterResult = nil
        points = []; completedSegments = []; activeStyle = nil
        activePointCount = 0; draftLimitReached = false; committedPointCount = 0
        undoDocuments = []; redoDocuments = []; updateHistory()
        isRasterizing = false; errorMessage = nil
    }

    func beginStroke(at point: MaskPoint) {
        guard document != nil else { return }
        if activeStyle == nil { activeStyle = (radius, hardness, mode) }
        appendPoint(point)
    }

    func appendPoint(_ point: MaskPoint) {
        guard let document else { return }
        guard point.x >= 0, point.y >= 0, point.x <= Double(document.canvasSize.width), point.y <= Double(document.canvasSize.height) else {
            breakStrokeSegment(); return
        }
        if activeStyle == nil { activeStyle = (radius, hardness, mode) }
        guard !draftLimitReached else { return }
        if points.last == point { return }
        // Metadata is bounded even for a long-held mouse gesture. Preserve the
        // original segment and start another, sharing a single undo boundary.
        if points.count >= 4_096 {
            let last = points.last
            finishSegment()
            guard document.strokes.count + completedSegments.count < MaskDocument.maximumStrokes,
                  committedPointCount + activePointCount + 2 <= MaskDocument.maximumTotalPoints else {
                reachedDraftLimit(); return
            }
            if let last { points = [last]; activePointCount += 1 }
        }
        guard committedPointCount + activePointCount < MaskDocument.maximumTotalPoints,
              !points.isEmpty || document.strokes.count + completedSegments.count < MaskDocument.maximumStrokes else {
            reachedDraftLimit(); return
        }
        points.append(point); activePointCount += 1
        scheduleRaster()
    }

    /// Never bridge a pointer excursion through letterboxing into a new diagonal.
    func breakStrokeSegment() { finishSegment() }

    func endStroke() {
        guard let previous = document, activeStyle != nil else { return }
        finishSegment()
        let segments = completedSegments
        points = []; completedSegments = []; activeStyle = nil
        activePointCount = 0; draftLimitReached = false
        guard !segments.isEmpty else { return }
        do {
            let next = try MaskDocument(canvasSize: previous.canvasSize, strokes: previous.strokes + segments,
                                        isInverted: previous.isInverted)
            commit(next, previous: previous)
        } catch { errorMessage = error.localizedDescription; scheduleRaster() }
    }

    func cancelStroke() {
        guard activeStyle != nil else { return }
        points = []; completedSegments = []; activeStyle = nil
        activePointCount = 0; draftLimitReached = false
        scheduleRaster()
    }

    func clear() { if let document { cancelStroke(); commit(document.cleared(), previous: document) } }
    func invert() { if let document { cancelStroke(); commit(document.inverted(), previous: document) } }

    func undo() {
        cancelStroke()
        guard let current = document, let previous = undoDocuments.popLast() else { return }
        redoDocuments.append(current); document = previous; updateHistory(); scheduleRaster()
    }
    func redo() {
        cancelStroke()
        guard let current = document, let next = redoDocuments.popLast() else { return }
        undoDocuments.append(current); document = next; updateHistory(); scheduleRaster()
    }

    private func reachedDraftLimit() {
        draftLimitReached = true
        errorMessage = "Der Maskenentwurf hat sein Punkt- oder Strichlimit erreicht. Der bisherige Strich bleibt erhalten."
    }

    private func finishSegment() {
        guard !points.isEmpty, let style = activeStyle else { return }
        do { completedSegments.append(try MaskStroke(points: points, radius: style.radius, hardness: style.hardness, mode: style.mode)) }
        catch { errorMessage = error.localizedDescription }
        points = []
    }

    private func commit(_ next: MaskDocument, previous: MaskDocument) {
        guard next != previous else { return }
        undoDocuments.append(previous)
        // Local draft history is deliberately bounded, independently of catalog undo.
        if undoDocuments.count > 64 { undoDocuments.removeFirst() }
        redoDocuments = []; document = next; updateHistory(); scheduleRaster()
    }
    private func updateHistory() {
        canUndo = !undoDocuments.isEmpty; canRedo = !redoDocuments.isEmpty
        committedPointCount = document?.strokes.reduce(0, { $0 + $1.points.count }) ?? 0
    }

    private func scheduleRaster() {
        guard let source, var draft = document else { return }
        // Invalidate first, including when an invalid draft cannot be rendered.
        if revision == .max { session = UUID(); revision = 0 }
        revision += 1
        runningCancellation?.cancel(); pending?.cancellation.cancel(); pending = nil
        do {
            var strokes = draft.strokes + completedSegments
            if let style = activeStyle, !points.isEmpty {
                strokes.append(try MaskStroke(points: points, radius: style.radius, hardness: style.hardness, mode: style.mode))
            }
            draft = try MaskDocument(canvasSize: draft.canvasSize, strokes: strokes, isInverted: draft.isInverted)
        } catch { errorMessage = error.localizedDescription; return }
        previewDocument = draft
        // Local adjustment overlays render this same draft through their shared
        // filter graph. Avoid a second raster/hash worker for each pointer event.
        guard rendersOverlay else { isRasterizing = false; return }
        pending = MaskRasterRequest(source: source, session: session, revision: revision,
                                    document: draft, cancellation: MaskRasterCancellation())
        isRasterizing = true
        guard worker == nil else { return }
        // At most one async operation is outstanding. Replacing `pending` coalesces
        // fast pointer events without enqueueing a task for every brush sample.
        worker = Task { [weak self] in
            guard let self else { return }
            while let request = self.pending {
                self.pending = nil; self.runningCancellation = request.cancellation
                do {
                    let result = try await self.rasterizer(request)
                    if self.matches(result.token) {
                        self.rasterResult = result
                        if !self.draftLimitReached { self.errorMessage = nil }
                    }
                } catch is CancellationError {
                    // The replacement remains pending until the occupied worker returns.
                } catch {
                    if self.matches(request) { self.errorMessage = error.localizedDescription }
                }
            }
            self.runningCancellation = nil; self.worker = nil; self.isRasterizing = false
        }
    }
    private func matches(_ token: MaskRasterToken) -> Bool {
        token.source == source && token.session == session && token.revision == revision && token.canvasSize == document?.canvasSize
    }
    private func matches(_ request: MaskRasterRequest) -> Bool {
        request.source == source && request.session == session && request.revision == revision && request.document.canvasSize == document?.canvasSize
    }

    /// Deterministic synchronization seam for model tests; no UI timing sleeps.
    func waitForRasterization() async { while let worker { await worker.value } }
}

/// Reads metadata only. Preview resolution and Retina scale never define the mask canvas.
struct MaskCanvasSource: Sendable {
    let size: ArtifactPixelSize
    let revision: String?
}

actor MaskCanvasSourceReader {
    static let shared = MaskCanvasSourceReader()
    func size(for source: AISourceIdentity) throws -> ArtifactPixelSize { try read(source).size }

    func read(_ source: AISourceIdentity) throws -> MaskCanvasSource {
        try Task.checkCancellation()
        switch source {
        case .artifact(let fingerprint): return MaskCanvasSource(size: fingerprint.raster.format.size, revision: nil)
        case .original(let fingerprint):
            let url = URL(fileURLWithPath: fingerprint.standardizedPath)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let before = try Self.stamp(url, fingerprint: fingerprint)
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let image = CGImageSourceCreateWithURL(url as CFURL, options),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else { throw PreviewFailure.unsupportedOrDamaged }
            let after = try Self.stamp(url, fingerprint: fingerprint)
            guard before == after else { throw MaskCanvasError.sourceChanged }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let w = width.intValue, h = height.intValue
            guard w > 0, h > 0, w <= 16_384, h <= 16_384, w <= 16_777_216 / h else {
                throw MaskCanvasError.canvasTooLarge
            }
            return MaskCanvasSource(size: try ArtifactPixelSize(width: (5...8).contains(orientation) ? h : w,
                                                               height: (5...8).contains(orientation) ? w : h),
                                    revision: before.cacheRevision)
        }
    }

    private static func stamp(_ url: URL, fingerprint: AIOriginalSourceFingerprint) throws -> ImageAnalysisNativeSourceStamp {
        // Metadata-only: opening/closing a second descriptor can release a
        // process-owned SQLite lock if a malicious source aliases a catalog.
        var value = stat()
        guard fstatat(AT_FDCWD, url.path, &value, 0) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size == fingerprint.fileSize else { throw MaskCanvasError.sourceChanged }
        let modified = Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
        guard abs(modified - fingerprint.modifiedAt.timeIntervalSince1970) <= 0.000_005 else {
            throw MaskCanvasError.sourceChanged
        }
        return ImageAnalysisNativeSourceStamp(device: value.st_dev, inode: UInt64(value.st_ino), byteCount: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
}

enum MaskCanvasError: LocalizedError, Hashable, Sendable {
    case canvasTooLarge, sourceChanged
    var errorDescription: String? {
        switch self {
        case .canvasTooLarge:
            return "Der Maskeneditor unterstützt derzeit bis zu 16.777.216 Bildpixel (16 MP) und 16.384 Pixel je Kante. Diese Bildquelle ist größer."
        case .sourceChanged:
            return "Die Bildquelle hat sich seit dem Einlesen geändert. Bitte den Ordner aktualisieren und den Maskeneditor erneut öffnen."
        }
    }
}
