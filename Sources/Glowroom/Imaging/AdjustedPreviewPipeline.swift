import Foundation
import GlowroomCore

fileprivate final class AdjustedPreviewInputBox: Sendable {
    let bitmap: PreviewBitmap
    init(_ bitmap: PreviewBitmap) { self.bitmap = bitmap }
}

/// The exact raster passed to the renderer and the output produced from it.
/// Only a live frame retains its input box; the output LRU keeps a weak link.
struct AdjustedPreviewFrame: Sendable {
    fileprivate let inputBox: AdjustedPreviewInputBox
    let output: PreviewBitmap
    var actualInput: PreviewBitmap { inputBox.bitmap }

    init(actualInput: PreviewBitmap, output: PreviewBitmap) {
        self.init(inputBox: AdjustedPreviewInputBox(actualInput), output: output)
    }

    fileprivate init(inputBox: AdjustedPreviewInputBox, output: PreviewBitmap) {
        self.inputBox = inputBox
        self.output = output
    }
}

/// Coordinates shared renders without blocking scheduling or cancellation.
/// At most one selected-photo and one background render can overlap. Separate
/// lanes prevent a synchronous thumbnail from blocking interactive edits while
/// bounding Core Image intermediates and GPU contention.
actor AdjustedPreviewPipeline {
    static let shared = AdjustedPreviewPipeline()

    struct State: Equatable, Sendable {
        let runningSelected: Int
        let runningBackground: Int
        let queuedCount: Int
        let waiterCount: Int
        let cachedBytes: Int
        let cachedCount: Int
        let cachedInputCount: Int
    }

    private struct Key: Hashable {
        let sourceIdentity: AISourceIdentity
        let modifiedAt: Date
        let fileSize: Int64
        let allowsEmbeddedPreview: Bool
        let allowsHDR: Bool
        let sourceRevision: String?
        let settings: EditSettings
        let width: Int
        let height: Int
        let sourceLongEdge: Int
        let rasterIdentity: UUID
        let outputWidth: Int
        let outputHeight: Int

        init(request: PreviewRequest, settings: EditSettings, width: Int, height: Int, sourceLongEdge: Int, rasterIdentity: UUID,
             outputWidth: Int, outputHeight: Int) {
            // Once the actual source raster is known, the decoder's requested
            // size is not render identity. Cards and thumbnails can share it.
            sourceIdentity = request.source
            modifiedAt = request.modifiedAt
            fileSize = request.fileSize
            allowsEmbeddedPreview = request.allowsEmbeddedPreview
            allowsHDR = request.allowsHDR
            sourceRevision = request.sourceRevision
            self.settings = settings
            self.width = width
            self.height = height
            self.sourceLongEdge = sourceLongEdge
            self.rasterIdentity = rasterIdentity
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
        }
    }
    private struct Entry {
        let bitmap: PreviewBitmap
        let inputIsOutput: Bool
        weak var inputBox: AdjustedPreviewInputBox?
        var access: UInt64
    }
    private struct Rendered: Sendable {
        let bitmap: PreviewBitmap
        let inputBox: AdjustedPreviewInputBox?
    }
    private struct Job {
        let queueSpan: PipelineTrace.Span
        let traceObserver: PipelineTrace.Observer?
        let key: Key
        let source: PreviewBitmap
        let cachedOutput: PreviewBitmap?
        var priority: PreviewPriority
        var waiters: [UUID: CheckedContinuation<Rendered, Error>]
        var task: Task<Void, Never>?
    }
    private var cache: [Key: Entry] = [:]
    private var bytes = 0
    private var sequence: UInt64 = 0
    private let limit = 32 * 1_024 * 1_024
    private let renderer: @Sendable (PreviewBitmap, EditSettings, PreviewPriority) throws -> PreviewBitmap
    private let asyncRenderer: (@Sendable (PreviewBitmap, EditSettings, PreviewPriority) async throws -> PreviewBitmap)?
    private var jobs: [UUID: Job] = [:]
    private var currentJob: [Key: UUID] = [:]
    private var waiterJobs: [UUID: UUID] = [:]
    private var pending: [UUID] = []
    private let maximumConcurrentRenders: Int
    private var running: [UUID: PreviewPriority] = [:]

    static var recommendedConcurrentRenders: Int {
        let resources = ProcessInfo.processInfo
        return resources.activeProcessorCount >= 4 && resources.physicalMemory >= 8 * 1_024 * 1_024 * 1_024 ? 2 : 1
    }

    init(maximumConcurrentRenders: Int = AdjustedPreviewPipeline.recommendedConcurrentRenders,
         renderer: (@Sendable (PreviewBitmap, EditSettings) throws -> PreviewBitmap)? = nil,
         priorityRenderer: (@Sendable (PreviewBitmap, EditSettings, PreviewPriority) throws -> PreviewBitmap)? = nil,
         asyncRenderer: (@Sendable (PreviewBitmap, EditSettings, PreviewPriority) async throws -> PreviewBitmap)? = nil) {
        self.maximumConcurrentRenders = min(2, max(1, maximumConcurrentRenders))
        // Suspending test doubles can retain a worker slot without occupying a
        // cooperative executor thread. Production renderers stay synchronous.
        self.asyncRenderer = asyncRenderer
        if let priorityRenderer { self.renderer = priorityRenderer }
        else if let renderer { self.renderer = { source, settings, _ in try renderer(source, settings) } }
        else { self.renderer = { try EditRenderer.render($0, settings: $1, priority: $2) } }
    }

    func image(
        _ source: PreviewBitmap, request: PreviewRequest, settings: EditSettings,
        priority: PreviewPriority = .thumbnail, maximumOutputPixelSize: Int? = nil
    ) async throws -> PreviewBitmap {
        try await render(source, request: request, settings: settings, priority: priority,
                         maximumOutputPixelSize: maximumOutputPixelSize, requiresInput: false).bitmap
    }

    func frame(
        _ source: PreviewBitmap, request: PreviewRequest, settings: EditSettings,
        priority: PreviewPriority = .selected, maximumOutputPixelSize: Int? = nil
    ) async throws -> AdjustedPreviewFrame {
        let result = try await render(source, request: request, settings: settings, priority: priority,
                                      maximumOutputPixelSize: maximumOutputPixelSize, requiresInput: true)
        // Every fresh job creates a box. A frame cache hit requires a live box;
        // otherwise that same bounded render lane reconstructs the proxy.
        guard let inputBox = result.inputBox else { throw ArtifactResourceError.invalidOwnership }
        return AdjustedPreviewFrame(inputBox: inputBox, output: result.bitmap)
    }

    private func render(
        _ source: PreviewBitmap, request: PreviewRequest, settings: EditSettings,
        priority: PreviewPriority, maximumOutputPixelSize: Int?, requiresInput: Bool
    ) async throws -> Rendered {
        let requestSpan = PipelineTrace.begin(.editedRequest)
        defer { requestSpan.end() }
        try Task.checkCancellation()
        let normalized = settings.normalized
        // Small geometry calculations stay serial; another worker would cost
        // more than this constant-size calculation. Scaling uses the render slot.
        let requestedSize = try EditRenderer.outputSize(source, maximumPixelSize: maximumOutputPixelSize)
        let requestedResize = requestedSize.width != source.image.width || requestedSize.height != source.image.height
        if normalized.isNeutral, !requestedResize {
            return Rendered(bitmap: source, inputBox: AdjustedPreviewInputBox(source))
        }
        let needsWorkingGraph = !normalized.isNeutral || requestedResize
        let toneWorkingBytes = needsWorkingGraph
            ? LocalAdjustmentRenderer.additionalToneWorkingBytesPerPixel(version: normalized.workingMemoryVersion) + normalized.additionalLevelsBytesPerPixel : 0
        var fixedBytes: UInt64 = 0
        var outputBytesPerPixel: UInt64 = 0
        var totalMemoryBudget = UInt64.max
        if let resources = source.resourceOwner {
            // The source remains owned while this additional render phase is
            // admitted. Fit both the unchanged admission formula and local work
            // together, rather than consuming the owner's whole budget in masks.
            let sourcePeak = UInt64(source.byteCost).multipliedReportingOverflow(by: 4)
            let sourceOwned = UInt64(source.memoryOwnership?.byteCount ?? 0)
            let fixed = sourcePeak.partialValue.addingReportingOverflow(sourceOwned)
            guard !sourcePeak.overflow, !fixed.overflow else { throw ArtifactResourceError.capacityExceeded }
            fixedBytes = fixed.partialValue
            // A resized input and output each retain twice their Float32
            // raster cost. Reserve the same again for the previous frame.
            // An unchanged input already belongs to the counted decoded source.
            outputBytesPerPixel = requestedResize ? 128 : 64
            let ownerLimit = UInt64((resources as? ArtifactResourceOwner)?.limits.maximumBytes ?? 536_870_912)
            // The old frame is counted per pixel above. This separate allowance
            // covers the output-only LRU, whose real provider costs twice its
            // raw raster bytes. Keep the plan stable across slider changes.
            let cacheHeadroom = min(UInt64(64 * 1_024 * 1_024), ownerLimit / 8)
            totalMemoryBudget = ownerLimit - cacheHeadroom
        }
        func plannedSize(outputBytes: UInt64) throws -> (width: Int, height: Int) {
            try LocalAdjustmentRenderer.previewSize(width: requestedSize.width, height: requestedSize.height,
                adjustments: normalized.localAdjustments, geometry: normalized.developGeometry, fixedBytes: fixedBytes,
                outputBytesPerPixel: outputBytes, totalMemoryBudget: totalMemoryBudget,
                replacementColorBytesPerPixel: EditRenderer.replacementColorBytesPerPixel(settings: normalized),
                globalBytesPerPixel: DevelopSharpening.additionalBytesPerPixel(settings: normalized)
                    + EditRenderer.additionalColorOutputBytesPerPixel(for: source.image, settings: normalized)
                    + toneWorkingBytes,
                toneProcessingVersion: normalized.workingMemoryVersion)
        }
        var size = try plannedSize(outputBytes: outputBytesPerPixel)
        if source.resourceOwner != nil, !requestedResize,
           size.width != source.image.width || size.height != source.image.height {
            // Spatial work can introduce an adaptive resize even when the UI
            // requested the full source. Account for that new retained proxy.
            size = try plannedSize(outputBytes: 128)
        }
        guard !normalized.isNeutral || size.width != source.image.width || size.height != source.image.height else {
            return Rendered(bitmap: source, inputBox: AdjustedPreviewInputBox(source))
        }
        let key = Key(request: request, settings: normalized, width: source.image.width, height: source.image.height,
                      sourceLongEdge: source.sourceLongEdge, rasterIdentity: source.rangeSourceIdentity,
                      outputWidth: size.width, outputHeight: size.height)
        sequence &+= 1
        var cachedOutput: PreviewBitmap?
        if var entry = cache[key] {
            entry.access = sequence
            if requiresInput, entry.inputBox == nil, entry.inputIsOutput {
                // The cache already owns the exact input in this alias case;
                // only the small frame box is recreated, with shared ownership.
                let box = AdjustedPreviewInputBox(entry.bitmap)
                entry.inputBox = box
                cache[key] = entry
                return Rendered(bitmap: entry.bitmap, inputBox: box)
            }
            cache[key] = entry
            let box = entry.inputBox
            if !requiresInput || box != nil { return Rendered(bitmap: entry.bitmap, inputBox: box) }
            cachedOutput = entry.bitmap
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(source, key: key, cachedOutput: cachedOutput, priority: priority,
                        waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    /// Content-free diagnostics for bounded-worker/cache verification.
    func state() -> State {
        State(runningSelected: running.values.filter { $0 == .selected }.count,
              runningBackground: running.values.filter { $0 == .thumbnail }.count,
              queuedCount: pending.count, waiterCount: waiterJobs.count,
              cachedBytes: bytes, cachedCount: cache.count, cachedInputCount: cache.values.filter { $0.inputBox != nil }.count)
    }

    private func enqueue(
        _ source: PreviewBitmap, key: Key, cachedOutput: PreviewBitmap?, priority: PreviewPriority, waiterID: UUID,
        continuation: CheckedContinuation<Rendered, Error>
    ) {
        if let jobID = currentJob[key], var job = jobs[jobID] {
            job.waiters[waiterID] = continuation
            if priority.rawValue > job.priority.rawValue { job.priority = priority }
            jobs[jobID] = job
            waiterJobs[waiterID] = jobID
        } else {
            let jobID = UUID()
            jobs[jobID] = Job(queueSpan: PipelineTrace.begin(.renderQueue), traceObserver: PipelineTrace.observer,
                key: key, source: source, cachedOutput: cachedOutput, priority: priority, waiters: [waiterID: continuation])
            currentJob[key] = jobID
            waiterJobs[waiterID] = jobID
            pending.append(jobID)
        }
        startNext()
    }

    private func cancel(_ waiterID: UUID) {
        guard let jobID = waiterJobs.removeValue(forKey: waiterID), var job = jobs[jobID],
              let continuation = job.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            currentJob.removeValue(forKey: job.key)
            if let task = job.task {
                jobs[jobID] = job
                // A synchronous Core Image call cannot be forcibly stopped.
                // Retain its worker slot until it has actually returned.
                task.cancel()
            } else {
                job.queueSpan.end()
                jobs.removeValue(forKey: jobID)
                pending.removeAll { $0 == jobID }
            }
        } else {
            jobs[jobID] = job
        }
    }

    private func startNext() {
        while running.count < maximumConcurrentRenders, !pending.isEmpty {
            let selected = running.values.contains(.selected) ? nil : pending.firstIndex { jobs[$0]?.priority == .selected }
            let thumbnail = running.values.contains(.thumbnail) ? nil : pending.firstIndex { jobs[$0]?.priority == .thumbnail }
            guard let index = selected ?? thumbnail else { return }
            let jobID = pending.remove(at: index)
            guard var job = jobs[jobID] else { continue }
            // Keep the originally assigned lane through cancellation and priority
            // upgrades: the synchronous renderer still occupies those resources.
            running[jobID] = job.priority
            job.queueSpan.end()
            let traceObserver = job.traceObserver
            let source = job.source
            let cachedOutput = job.cachedOutput
            let settings = job.key.settings
            let priority = job.priority
            let renderer = self.renderer
            let asyncRenderer = self.asyncRenderer
            let outputWidth = job.key.outputWidth
            let outputHeight = job.key.outputHeight
            job.task = Task.detached(priority: priority == .selected ? .userInitiated : .utility) { [weak self] in
                await PipelineTrace.$observer.withValue(traceObserver) {
                    let result: Result<Rendered, Error>
                    do {
                        try Task.checkCancellation()
                        // Downsample the shared developed source, never a camera
                        // thumbnail. It occupies this same bounded worker/CI lane.
                        var phase: ArtifactResourceLease?
                        if let resources = source.resourceOwner {
                            let resizes = outputWidth != source.image.width || outputHeight != source.image.height
                            let needsWorkingGraph = !settings.isNeutral || outputWidth != source.image.width || outputHeight != source.image.height
                            let toneWorkingBytes = needsWorkingGraph && cachedOutput == nil
                                ? LocalAdjustmentRenderer.additionalToneWorkingBytesPerPixel(version: settings.workingMemoryVersion) + settings.additionalLevelsBytesPerPixel : 0
                            let sourceBytes = Int64(source.byteCost).multipliedReportingOverflow(by: 4)
                            let outputPixels = Int64(outputWidth).multipliedReportingOverflow(by: Int64(outputHeight))
                            let outputBytes = outputPixels.partialValue.multipliedReportingOverflow(
                                by: Int64((resizes ? 64 : 32) + (cachedOutput == nil ? DevelopSharpening.additionalBytesPerPixel(settings: settings)
                                    + EditRenderer.additionalColorOutputBytesPerPixel(for: source.image, settings: settings) : 0)
                                    + toneWorkingBytes))
                            let baseBytes = sourceBytes.partialValue.addingReportingOverflow(outputBytes.partialValue)
                            guard !sourceBytes.overflow, !outputPixels.overflow, !outputBytes.overflow, !baseBytes.overflow,
                                  let local = LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: cachedOutput == nil ? settings.localAdjustments : [],
                                    width: outputWidth, height: outputHeight,
                                    additionalRenderCount: cachedOutput == nil ? DevelopGeometryRenderer.replacementCount(in: settings.developGeometry) : 0,
                                    toneProcessingVersion: settings.workingMemoryVersion),
                                  let geometryBytes = DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: cachedOutput == nil ? settings.developGeometry : .neutral,
                                    width: outputWidth, height: outputHeight,
                                    replacementColorBytesPerPixel: EditRenderer.replacementColorBytesPerPixel(settings: settings)) else {
                                throw ArtifactResourceError.capacityExceeded
                            }
                            let additionalBytes = local.addingReportingOverflow(geometryBytes)
                            guard !additionalBytes.overflow, additionalBytes.partialValue <= UInt64(Int64.max) else { throw ArtifactResourceError.capacityExceeded }
                            let plannedBytes = baseBytes.partialValue.addingReportingOverflow(Int64(additionalBytes.partialValue))
                            guard !plannedBytes.overflow else { throw ArtifactResourceError.capacityExceeded }
                            let retained = [source.memoryOwnership, cachedOutput?.memoryOwnership].compactMap { $0 }
                            phase = try await resources.acquire(kind: .codec,
                                bytes: plannedBytes.partialValue,
                                priority: priority == .selected ? .interactive : .background,
                                retaining: retained)
                        }
                        var input = try EditRenderer.resized(source, width: outputWidth, height: outputHeight, priority: priority,
                                                            toneProcessingVersion: settings.workingMemoryVersion)
                        if let resources = source.resourceOwner, let phase, input.image !== source.image {
                            let memory = try await resources.retain(bytes: Int64(input.byteCost) * 2, from: phase)
                            input = try input.retainingArtifactMemory(memory, owner: resources)
                        }
                        var bitmap: PreviewBitmap
                        if let cachedOutput { bitmap = cachedOutput }
                        else if settings.isNeutral { bitmap = input }
                        else if let asyncRenderer { bitmap = try await asyncRenderer(input, settings, priority) }
                        else { bitmap = try renderer(input, settings, priority) }
                        if bitmap.image === input.image {
                            bitmap = input
                        } else if cachedOutput == nil, let resources = source.resourceOwner, let phase {
                            let memory = try await resources.retain(bytes: Int64(bitmap.byteCost) * 2, from: phase)
                            bitmap = try bitmap.retainingArtifactMemory(memory, owner: resources)
                        }
                        try Task.checkCancellation()
                        result = .success(Rendered(bitmap: bitmap, inputBox: AdjustedPreviewInputBox(input)))
                    } catch {
                        result = .failure(error)
                    }
                    await self?.finish(jobID, result: result)
                }
            }
            jobs[jobID] = job
        }
    }

    private func finish(_ jobID: UUID, result: Result<Rendered, Error>) {
        guard let job = jobs.removeValue(forKey: jobID) else { return }
        if currentJob[job.key] == jobID { currentJob.removeValue(forKey: job.key) }
        if !job.waiters.isEmpty, case let .success(rendered) = result { insert(rendered, for: job.key) }
        for (waiterID, continuation) in job.waiters {
            waiterJobs.removeValue(forKey: waiterID)
            continuation.resume(with: result)
        }
        running.removeValue(forKey: jobID)
        startNext()
    }

    func retireArtifactCaches() {
        // Only bounded cache references retire. Views and in-flight native
        // renders continue to retain their actual provider memory reservations.
        let obsolete = cache.keys.filter { key in
            if case .artifact = key.sourceIdentity { return true }
            return false
        }
        for key in obsolete {
            if let entry = cache.removeValue(forKey: key) { bytes -= entry.bitmap.byteCost }
        }
    }

    private func insert(_ rendered: Rendered, for key: Key) {
        let bitmap = rendered.bitmap
        let cacheLimit: Int
        if let resources = bitmap.resourceOwner {
            let ownerLimit = (resources as? ArtifactResourceOwner)?.limits.maximumBytes ?? 536_870_912
            cacheLimit = min(limit, Int(ownerLimit / 16))
        } else { cacheLimit = limit }
        if bitmap.byteCost <= cacheLimit {
            if let old = cache.removeValue(forKey: key) { bytes -= old.bitmap.byteCost }
            while bytes + bitmap.byteCost > cacheLimit || cache.count >= 32 {
                guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= oldest.value.bitmap.byteCost
                cache.removeValue(forKey: oldest.key)
            }
            sequence &+= 1
            cache[key] = Entry(bitmap: bitmap, inputIsOutput: rendered.inputBox?.bitmap.image === bitmap.image,
                               inputBox: rendered.inputBox, access: sequence)
            bytes += bitmap.byteCost
        }
    }
}
