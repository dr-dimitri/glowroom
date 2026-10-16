import Foundation
import PicEditCore

/// Coordinates shared renders without blocking scheduling or cancellation.
/// One render worker bounds Core Image intermediates and GPU contention while
/// independent original decodes and disk I/O continue in the preview pipeline.
actor AdjustedPreviewPipeline {
    static let shared = AdjustedPreviewPipeline()

    private struct Key: Hashable {
        let request: PreviewRequest
        let settings: EditSettings
        let width: Int
        let height: Int
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
    private let renderer: @Sendable (PreviewBitmap, EditSettings) throws -> PreviewBitmap
    private var jobs: [UUID: Job] = [:]
    private var currentJob: [Key: UUID] = [:]
    private var waiterJobs: [UUID: UUID] = [:]
    private var pending: [UUID] = []
    private var running: UUID?

    init(renderer: @escaping @Sendable (PreviewBitmap, EditSettings) throws -> PreviewBitmap = {
        try EditRenderer.render($0, settings: $1)
    }) {
        self.renderer = renderer
    }

    func image(
        _ source: PreviewBitmap, request: PreviewRequest, settings: EditSettings,
        priority: PreviewPriority = .thumbnail
    ) async throws -> PreviewBitmap {
        try Task.checkCancellation()
        let normalized = settings.normalized
        guard !normalized.isNeutral else { return source }
        let key = Key(request: request, settings: normalized, width: source.image.width, height: source.image.height)
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
        guard running == nil, !pending.isEmpty else { return }
        let index = pending.firstIndex { jobs[$0]?.priority == .selected } ?? 0
        let jobID = pending.remove(at: index)
        guard var job = jobs[jobID] else { return }
        running = jobID
        let source = job.source
        let settings = job.key.settings
        let renderer = self.renderer
        job.task = Task.detached(priority: job.priority == .selected ? .userInitiated : .utility) { [weak self] in
            let result: Result<PreviewBitmap, Error>
            do {
                try Task.checkCancellation()
                let bitmap = try renderer(source, settings)
                try Task.checkCancellation()
                result = .success(bitmap)
            } catch {
                result = .failure(error)
            }
            await self?.finish(jobID, result: result)
        }
        jobs[jobID] = job
    }

    private func finish(_ jobID: UUID, result: Result<PreviewBitmap, Error>) {
        guard let job = jobs.removeValue(forKey: jobID) else { return }
        if currentJob[job.key] == jobID { currentJob.removeValue(forKey: job.key) }
        if !job.waiters.isEmpty, case let .success(bitmap) = result { insert(bitmap, for: job.key) }
        for (waiterID, continuation) in job.waiters {
            waiterJobs.removeValue(forKey: waiterID)
            continuation.resume(with: result)
        }
        running = nil
        startNext()
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
