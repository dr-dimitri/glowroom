import Foundation
import PicEditCore

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
    }

    private struct Key: Hashable {
        let sourceIdentity: AISourceIdentity
        let modifiedAt: Date
        let fileSize: Int64
        let allowsEmbeddedPreview: Bool
        let sourceRevision: String?
        let settings: EditSettings
        let width: Int
        let height: Int
        let outputWidth: Int
        let outputHeight: Int

        init(request: PreviewRequest, settings: EditSettings, width: Int, height: Int,
             outputWidth: Int, outputHeight: Int) {
            // Once the actual source raster is known, the decoder's requested
            // size is not render identity. Cards and thumbnails can share it.
            sourceIdentity = request.source
            modifiedAt = request.modifiedAt
            fileSize = request.fileSize
            allowsEmbeddedPreview = request.allowsEmbeddedPreview
            sourceRevision = request.sourceRevision
            self.settings = settings
            self.width = width
            self.height = height
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
        }
    }
    private struct Entry {
        let bitmap: PreviewBitmap
        var access: UInt64
    }
    private struct Job {
        let key: Key
        let source: PreviewBitmap
        var priority: PreviewPriority
        var waiters: [UUID: CheckedContinuation<PreviewBitmap, Error>]
        var task: Task<Void, Never>?
    }
    private var cache: [Key: Entry] = [:]
    private var bytes = 0
    private var sequence: UInt64 = 0
    private let limit = 32 * 1_024 * 1_024
    private let renderer: @Sendable (PreviewBitmap, EditSettings, PreviewPriority) throws -> PreviewBitmap
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
         priorityRenderer: (@Sendable (PreviewBitmap, EditSettings, PreviewPriority) throws -> PreviewBitmap)? = nil) {
        self.maximumConcurrentRenders = min(2, max(1, maximumConcurrentRenders))
        if let priorityRenderer { self.renderer = priorityRenderer }
        else if let renderer { self.renderer = { source, settings, _ in try renderer(source, settings) } }
        else { self.renderer = { try EditRenderer.render($0, settings: $1, priority: $2) } }
    }

    func image(
        _ source: PreviewBitmap, request: PreviewRequest, settings: EditSettings,
        priority: PreviewPriority = .thumbnail, maximumOutputPixelSize: Int? = nil
    ) async throws -> PreviewBitmap {
        try Task.checkCancellation()
        let normalized = settings.normalized
        // Small geometry calculations stay serial; another worker would cost
        // more than this constant-size calculation. Scaling uses the render slot.
        let size = try EditRenderer.outputSize(source, maximumPixelSize: maximumOutputPixelSize)
        guard !normalized.isNeutral || size.width != source.image.width || size.height != source.image.height else { return source }
        let key = Key(request: request, settings: normalized, width: source.image.width, height: source.image.height,
                      outputWidth: size.width, outputHeight: size.height)
        sequence &+= 1
        if var entry = cache[key] {
            entry.access = sequence
            cache[key] = entry
            return entry.bitmap
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(source, key: key, priority: priority, waiterID: waiterID, continuation: continuation)
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
              cachedBytes: bytes, cachedCount: cache.count)
    }

    private func enqueue(
        _ source: PreviewBitmap, key: Key, priority: PreviewPriority, waiterID: UUID,
        continuation: CheckedContinuation<PreviewBitmap, Error>
    ) {
        if let jobID = currentJob[key], var job = jobs[jobID] {
            job.waiters[waiterID] = continuation
            if priority.rawValue > job.priority.rawValue { job.priority = priority }
            jobs[jobID] = job
            waiterJobs[waiterID] = jobID
        } else {
            let jobID = UUID()
            jobs[jobID] = Job(key: key, source: source, priority: priority, waiters: [waiterID: continuation])
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
            let source = job.source
            let settings = job.key.settings
            let priority = job.priority
            let renderer = self.renderer
            let outputWidth = job.key.outputWidth
            let outputHeight = job.key.outputHeight
            job.task = Task.detached(priority: priority == .selected ? .userInitiated : .utility) { [weak self] in
                let result: Result<PreviewBitmap, Error>
                do {
                    try Task.checkCancellation()
                    // Downsample the shared developed source, never a camera
                    // thumbnail. It occupies this same bounded worker/CI lane.
                    var phase: ArtifactResourceLease?
                    if let resources = source.resourceOwner {
                        phase = try await resources.acquire(kind: .codec,
                            bytes: Int64(source.byteCost) * 4 + Int64(outputWidth) * Int64(outputHeight) * 32,
                            priority: priority == .selected ? .interactive : .background,
                            retaining: source.memoryOwnership.map { [$0] } ?? [])
                    }
                    let input = try EditRenderer.resized(source, width: outputWidth, height: outputHeight, priority: priority)
                    var bitmap = settings.isNeutral ? input : try renderer(input, settings, priority)
                    if let resources = source.resourceOwner, let phase {
                        let memory = try await resources.retain(bytes: Int64(bitmap.byteCost) * 2, from: phase)
                        bitmap = try bitmap.retainingArtifactMemory(memory, owner: resources)
                    }
                    try Task.checkCancellation()
                    result = .success(bitmap)
                } catch {
                    result = .failure(error)
                }
                await self?.finish(jobID, result: result)
            }
            jobs[jobID] = job
        }
    }

    private func finish(_ jobID: UUID, result: Result<PreviewBitmap, Error>) {
        guard let job = jobs.removeValue(forKey: jobID) else { return }
        if currentJob[job.key] == jobID { currentJob.removeValue(forKey: job.key) }
        if !job.waiters.isEmpty, case let .success(bitmap) = result { insert(bitmap, for: job.key) }
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

    private func insert(_ bitmap: PreviewBitmap, for key: Key) {
        if bitmap.byteCost <= limit {
            if let old = cache.removeValue(forKey: key) { bytes -= old.bitmap.byteCost }
            while bytes + bitmap.byteCost > limit || cache.count >= 32 {
                guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= oldest.value.bitmap.byteCost
                cache.removeValue(forKey: oldest.key)
            }
            sequence &+= 1
            cache[key] = Entry(bitmap: bitmap, access: sequence)
            bytes += bitmap.byteCost
        }
    }
}
