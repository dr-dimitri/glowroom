import AppKit
import Foundation
import ImageIO
import PicEditCore

/// File identity and rendering size determine whether a preview can be reused.
struct PreviewRequest: Hashable, Sendable {
    let source: AISourceIdentity
    let pixelSize: Int
    let allowsEmbeddedPreview: Bool
    let sourceRevision: String?
    var url: URL? { if case .original(let value) = source { return URL(fileURLWithPath: value.standardizedPath) }; return nil }
    var displayName: String { url?.lastPathComponent ?? "Generierte Variante" }
    var modifiedAt: Date { if case .original(let value) = source { return value.modifiedAt }; return .distantPast }
    var fileSize: Int64 { switch source { case .original(let value): return value.fileSize; case .artifact(let value): return value.raster.file.bytes } }

    init(url: URL, modifiedAt: Date, pixelSize: Int, fileSize: Int64 = 0, allowsEmbeddedPreview: Bool = true,
         sourceRevision: String? = nil) {
        self.init(source: .original(.init(fileURL: url, modifiedAt: modifiedAt, fileSize: fileSize)),
                  pixelSize: pixelSize, allowsEmbeddedPreview: allowsEmbeddedPreview, sourceRevision: sourceRevision)
    }
    init(source: AISourceIdentity, pixelSize: Int, allowsEmbeddedPreview: Bool = false, sourceRevision: String? = nil) {
        self.source = source; self.pixelSize = min(max(pixelSize, 64), 4_096)
        if case .original = source { self.allowsEmbeddedPreview = allowsEmbeddedPreview } else { self.allowsEmbeddedPreview = false }
        self.sourceRevision = sourceRevision
    }
    func resized(to size: Int) -> Self {
        Self(source: source, pixelSize: size, allowsEmbeddedPreview: allowsEmbeddedPreview, sourceRevision: sourceRevision)
    }
    func isAdequateArtifactCache(for required: PreviewRequest) -> Bool {
        if case .artifact = source { return hasSameOriginal(as: required) && pixelSize >= required.pixelSize }
        return false
    }
    func hasSameOriginal(as other: PreviewRequest) -> Bool {
        source == other.source && allowsEmbeddedPreview == other.allowsEmbeddedPreview && sourceRevision == other.sourceRevision
    }
}

enum PreviewPriority: Int, Sendable {
    case thumbnail
    case selected
}

/// CGImage is immutable. AppKit images are constructed on the main actor.
struct PreviewBitmap: @unchecked Sendable {
    let image: CGImage
    let memoryOwnership: ArtifactMemoryReservation?
    let resourceOwner: (any ArtifactResourceAdmitting)?
    init(image: CGImage, memoryOwnership: ArtifactMemoryReservation? = nil, resourceOwner: (any ArtifactResourceAdmitting)? = nil) {
        self.image = image; self.memoryOwnership = memoryOwnership; self.resourceOwner = resourceOwner
    }
    var byteCost: Int { image.bytesPerRow * image.height }
}

enum PreviewFailure: LocalizedError, Sendable {
    case unavailable
    case unsupportedOrDamaged

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Das Original ist nicht verfügbar oder kann nicht gelesen werden."
        case .unsupportedOrDamaged:
            return "Für diese Datei konnte keine Bildvorschau erstellt werden."
        }
    }
}

/// Shares work and bounded caches between the grid, filmstrip and loupe.
/// A canceled synchronous ImageIO decoder retains its slot until it returns.
actor ImagePreviewPipeline {
    static let shared = ImagePreviewPipeline(
        diskCache: PreviewDiskCache(directory: PreviewDiskCache.defaultDirectory)
    )

    private struct CacheEntry {
        let bitmap: PreviewBitmap
        var lastAccess: UInt64
    }

    private struct Job {
        let request: PreviewRequest
        var priority: PreviewPriority
        var waiters: [UUID: CheckedContinuation<PreviewBitmap, Error>]
        var task: Task<Void, Never>?
        var startedAsThumbnail = false
    }

    private let concurrencyLimit: Int
    private let memoryLimit: Int
    private let diskCache: PreviewDiskCache?
    private let decoder: @Sendable (PreviewRequest) throws -> PreviewBitmap
    private let entryLimit = 256
    private var cache: [PreviewRequest: CacheEntry] = [:]
    private var cacheBytes = 0
    private var accessCounter: UInt64 = 0
    private var jobs: [UUID: Job] = [:]
    private var currentJob: [PreviewRequest: UUID] = [:]
    private var waiterJobs: [UUID: UUID] = [:]
    private var pending: [UUID] = []
    private var running = 0
    private var runningThumbnails = 0

    init(
        concurrencyLimit: Int = 3,
        memoryLimit: Int = 96 * 1_024 * 1_024,
        diskCache: PreviewDiskCache? = nil,
        decoder: @escaping @Sendable (PreviewRequest) throws -> PreviewBitmap = { try PreviewDecoder.decode($0) }
    ) {
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.memoryLimit = max(0, memoryLimit)
        self.diskCache = diskCache
        self.decoder = decoder
    }

    func image(for request: PreviewRequest, priority: PreviewPriority = .thumbnail) async throws -> PreviewBitmap {
        try Task.checkCancellation()
        if case .original = request.source, let bitmap = cachedImage(for: request) { return bitmap }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(request, priority: priority, waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    private func cachedImage(for request: PreviewRequest) -> PreviewBitmap? {
        // Reuse the smallest adequate bitmap, including larger grid/loupe images.
        let key = cache[request] != nil ? request : cache.keys.filter {
            $0.hasSameOriginal(as: request) && $0.pixelSize >= request.pixelSize
        }.min { $0.pixelSize < $1.pixelSize }
        guard let key, var entry = cache[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[key] = entry
        return entry.bitmap
    }

    private func enqueue(
        _ request: PreviewRequest,
        priority: PreviewPriority,
        waiterID: UUID,
        continuation: CheckedContinuation<PreviewBitmap, Error>
    ) {
        // A grid/filmstrip request can share an already pending or running
        // larger decode, not just its eventual cache entry. Editing bases stay
        // separate from embedded browsing previews through hasSameOriginal.
        let reusableRequest = currentJob[request] != nil ? request : currentJob.keys.filter {
            $0.hasSameOriginal(as: request) && $0.pixelSize >= request.pixelSize
        }.min { $0.pixelSize < $1.pixelSize }
        if let reusableRequest, let jobID = currentJob[reusableRequest], var job = jobs[jobID] {
            job.waiters[waiterID] = continuation
            if priority.rawValue > job.priority.rawValue { job.priority = priority }
            jobs[jobID] = job
            waiterJobs[waiterID] = jobID
        } else {
            let jobID = UUID()
            jobs[jobID] = Job(request: request, priority: priority, waiters: [waiterID: continuation])
            currentJob[request] = jobID
            waiterJobs[waiterID] = jobID
            pending.append(jobID)
        }
        startPendingJobs()
    }

    private func cancel(waiterID: UUID) {
        guard let jobID = waiterJobs.removeValue(forKey: waiterID), var job = jobs[jobID],
              let continuation = job.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            currentJob.removeValue(forKey: job.request)
            if let task = job.task {
                jobs[jobID] = job
                task.cancel()
            } else {
                jobs.removeValue(forKey: jobID)
                pending.removeAll { $0 == jobID }
            }
        } else {
            jobs[jobID] = job
        }
        startPendingJobs()
    }

    private func startPendingJobs() {
        while running < concurrencyLimit, !pending.isEmpty {
            // Keep one decoder available for the selected photo. Within each
            // priority, preserve arrival order to avoid starving visible cells.
            let selectedIndex = pending.firstIndex { jobs[$0]?.priority == .selected }
            guard let index = selectedIndex ?? (runningThumbnails < max(1, concurrencyLimit - 1) ? 0 : nil) else { break }
            let jobID = pending.remove(at: index)
            guard var job = jobs[jobID] else { continue }
            let request = job.request
            let diskCache = self.diskCache
            let decoder = self.decoder
            running += 1
            job.startedAsThumbnail = job.priority == .thumbnail
            if job.startedAsThumbnail { runningThumbnails += 1 }
            job.task = Task.detached(priority: job.priority == .selected ? .userInitiated : .utility) { [weak self] in
                var shouldStore = false
                var cachedAs = request
                let result: Result<PreviewBitmap, Error>
                do {
                    try Task.checkCancellation()
                    var persisted: PreviewBitmap?
                    if let diskCache, case .original = request.source {
                        // A previous session may have cached only a larger grid
                        // or loupe rendition. Reuse it before opening the RAW.
                        let sizes = [request.pixelSize] + [256, 512, 1_024, 1_536, 2_400, 4_096].filter { $0 > request.pixelSize }
                        for size in sizes {
                            try Task.checkCancellation()
                            let candidate = request.resized(to: size)
                            if let bitmap = await diskCache.image(for: candidate) {
                                persisted = bitmap
                                cachedAs = candidate
                                break
                            }
                        }
                    }
                    if let bitmap = persisted {
                        try Task.checkCancellation()
                        result = .success(bitmap)
                    } else {
                        try Task.checkCancellation()
                        let bitmap: PreviewBitmap
                        if case .artifact(let fingerprint) = request.source {
                            let budget = try ArtifactPreviewBudget(format: fingerprint.raster.format, pixelSize: request.pixelSize)
                            let retire: @Sendable () async -> Void = { [weak self] in
                                await self?.retireArtifactCaches(for: request)
                                await AdjustedPreviewPipeline.shared.retireArtifactCaches()
                            }
                            if budget.retiresOtherCaches { await retire() }
                            let opened = try await ArtifactPreviewAdmission.perform(retireCaches: retire) {
                                try await ArtifactPreviewAccess.shared.open(fingerprint)
                            }
                            if let cached = await self?.cachedImage(for: request) { bitmap = cached }
                            else {
                                let lease = try await ArtifactPreviewAdmission.perform(retireCaches: retire) {
                                    try await opened.resources.acquire(kind: .codec, bytes: budget.peakBytes,
                                        priority: .interactive, retaining: [])
                                }
                                let decoded = try PreviewDecoder.decodeArtifact(opened.handle, expected: fingerprint, pixelSize: request.pixelSize)
                                try budget.validate(decoded)
                                let ownership = try await opened.resources.retain(bytes: Int64(decoded.byteCost) * 2, from: lease)
                                bitmap = try decoded.retainingArtifactMemory(ownership, owner: opened.resources)
                                withExtendedLifetime(lease) {}
                            }
                        } else { bitmap = try decoder(request) }
                        try Task.checkCancellation()
                        if case .original = request.source { shouldStore = true }
                        result = .success(bitmap)
                    }
                } catch {
                    result = .failure(error)
                }
                let wasNeeded = await self?.complete(jobID, result: result, cachedAs: cachedAs) ?? false
                // Display immediately; compression and disk I/O follow off-main.
                if shouldStore, wasNeeded, case let .success(bitmap) = result {
                    await diskCache?.store(bitmap, for: request)
                }
                await self?.finish(jobID)
            }
            jobs[jobID] = job
        }
    }

    @discardableResult
    private func complete(_ jobID: UUID, result: Result<PreviewBitmap, Error>, cachedAs: PreviewRequest) -> Bool {
        guard var job = jobs[jobID] else { return false }
        if currentJob[job.request] == jobID { currentJob.removeValue(forKey: job.request) }
        let wasNeeded = !job.waiters.isEmpty
        if case let .success(bitmap) = result, wasNeeded { insert(bitmap, for: cachedAs) }
        for (waiterID, continuation) in job.waiters {
            waiterJobs.removeValue(forKey: waiterID)
            continuation.resume(with: result)
        }
        job.waiters.removeAll()
        jobs[jobID] = job
        return wasNeeded
    }

    private func finish(_ jobID: UUID) {
        guard let job = jobs.removeValue(forKey: jobID) else { return }
        running -= 1
        if job.startedAsThumbnail { runningThumbnails -= 1 }
        // Keep the slot until persistence finishes, too: a slow disk must not
        // accumulate an unbounded queue of bitmaps waiting to be compressed.
        startPendingJobs()
    }

    func retireArtifactCaches(for required: PreviewRequest) {
        // At most 256 entries; no reader/worker ownership is revoked here.
        let obsolete = cache.keys.filter { key in
            if case .artifact = key.source {
                // A same-source 1536 bitmap is not a 2400 cache hit. Keeping
                // every size would permanently strand large 16-bit upgrades.
                return !key.isAdequateArtifactCache(for: required)
            }
            return false
        }
        for key in obsolete {
            if let entry = cache.removeValue(forKey: key) { cacheBytes -= entry.bitmap.byteCost }
        }
    }

    private func insert(_ bitmap: PreviewBitmap, for request: PreviewRequest) {
        guard bitmap.byteCost <= memoryLimit else { return }
        if let old = cache.removeValue(forKey: request) { cacheBytes -= old.bitmap.byteCost }
        while cacheBytes + bitmap.byteCost > memoryLimit || cache.count >= entryLimit {
            guard let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
            cacheBytes -= oldest.value.bitmap.byteCost
            cache.removeValue(forKey: oldest.key)
        }
        accessCounter &+= 1
        cache[request] = CacheEntry(bitmap: bitmap, lastAccess: accessCounter)
        cacheBytes += bitmap.byteCost
    }
}
