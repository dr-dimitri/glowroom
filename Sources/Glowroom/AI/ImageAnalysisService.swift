import Foundation
import GlowroomCore

/// One current worker and one replaceable queued context. Cache entries contain
/// bounded response data/provenance, never images or a growing conversation.
struct ImageAnalysisPayload: Sendable {
    let request: ImageAnalysisRequest
    let data: Data
    let provenance: ImageAnalysisProvenance
    let sourceStamp: ImageAnalysisSourceStamp
}

actor ImageAnalysisService: ImageAnalysisServing {
    nonisolated let descriptor: ImageAnalysisProviderDescriptor
    struct State: Sendable, Equatable {
        let runningCount: Int
        let queuedCount: Int
        let waiterCount: Int
        let cachedCount: Int
        let cachedBytes: Int
        let runningRequestID: UUID?
        let queuedRequestID: UUID?
    }

    private enum Purpose: Hashable, Sendable { case analysis, metadata }

    private struct Key: Hashable, Sendable {
        let source: AISourceIdentity
        let purpose: Purpose
        let refreshID: UUID?
        let kind: ImageAnalysisInputKind
        let settings: EditSettings?
        let editToken: AIEditingToken?
        let lifecycleID: UUID?
        let language: String
        let descriptor: ImageAnalysisProviderDescriptor
        let preprocessingVersion = ImageAnalysisProvenance.currentPreprocessingVersion
        let taskVersion = ImageAnalysisRequest.taskVersion
        let schemaVersion = ImageAnalysisRequest.schemaVersion

        init(_ request: ImageAnalysisRequest, descriptor: ImageAnalysisProviderDescriptor, purpose: Purpose) {
            self.purpose = purpose
            refreshID = request.cachePolicy == .refreshRaster ? request.id : nil
            source = request.snapshot.source; kind = request.inputKind; language = request.language
            self.descriptor = descriptor
            settings = kind == .editedPreview ? request.snapshot.settings : nil
            editToken = kind == .editedPreview ? request.snapshot.token : nil
            lifecycleID = kind == .editedPreview ? request.lifecycleID : nil
        }
    }
    private struct Waiter {
        let request: ImageAnalysisRequest
        let continuation: CheckedContinuation<ImageAnalysisPayload, Error>
    }
    private struct Job {
        let id: UUID
        let key: Key
        let request: ImageAnalysisRequest
        var waiters: [UUID: Waiter]
        var task: Task<Void, Never>?
    }
    private struct Cached: Sendable {
        let data: Data
        let provenance: ImageAnalysisProvenance
        let sourceStamp: ImageAnalysisSourceStamp
        let cost: Int
        var access: UInt64
    }
    private let provider: any ImageAnalysisProvider
    private let preparer: any ImageAnalysisPreparing
    private let budget: AIResourceBudget
    private let maximumCacheEntries: Int
    private let maximumCacheBytes: Int
    private var running: Job?
    private var pending: Job?
    private var cache: [Key: Cached] = [:]
    private var cacheBytes = 0
    private var sequence: UInt64 = 0
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    init(provider: any ImageAnalysisProvider, preparer: any ImageAnalysisPreparing = ImageAnalysisPreparer(),
         budget: AIResourceBudget = .shared, maximumCacheEntries: Int = 8, maximumCacheBytes: Int = 256 * 1_024) {
        self.provider = provider; self.preparer = preparer; self.budget = budget
        descriptor = provider.descriptor
        self.maximumCacheEntries = min(8, max(0, maximumCacheEntries))
        self.maximumCacheBytes = min(256 * 1_024, max(0, maximumCacheBytes))
    }

    func availability() async -> ImageAnalysisAvailability { await provider.availability() }

    func analyze(_ request: ImageAnalysisRequest) async throws -> ImageAnalysisResult {
        let payload = try await perform(request, purpose: .analysis)
        return ImageAnalysisResult(request: payload.request,
            suggestions: try ImageAnalysisSuggestionValidator().validate(payload.data), provenance: payload.provenance)
    }

    func metadata(_ request: ImageAnalysisRequest) async throws -> ImageAnalysisPayload {
        guard request.inputKind == .originalPreview else { throw ImageAnalysisError.invalidRequest }
        return try await perform(request, purpose: .metadata)
    }

    private func perform(_ request: ImageAnalysisRequest, purpose: Purpose) async throws -> ImageAnalysisPayload {
        try Task.checkCancellation()
        try request.validate()
        let waiterID = UUID()
        let result: ImageAnalysisPayload = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: ImageAnalysisError.cancelled); return }
                enqueue(request, purpose: purpose, waiterID: waiterID, continuation: continuation)
            }
        } onCancel: { Task { await self.cancel(waiterID) } }
        guard !Task.isCancelled else { throw ImageAnalysisError.cancelled }
        return result
    }

    /// Explicit service-wide invalidation is separate from cancelling one observer.
    /// Accepted edits/persistence belong to other services and are never cancelled.
    func invalidate() {
        if var job = running {
            fail(&job, with: .cancelled); job.task?.cancel(); running = job
        }
        if var job = pending { fail(&job, with: .cancelled); pending = nil }
        cache.removeAll(); cacheBytes = 0
        publish()
    }

    func stateUpdates() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private var state: State {
        State(runningCount: running == nil ? 0 : 1, queuedCount: pending == nil ? 0 : 1,
              waiterCount: (running?.waiters.count ?? 0) + (pending?.waiters.count ?? 0),
              cachedCount: cache.count, cachedBytes: cacheBytes,
              runningRequestID: running?.request.id, queuedRequestID: pending?.request.id)
    }
    private func publish() { for observer in observers.values { observer.yield(state) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func enqueue(_ request: ImageAnalysisRequest, purpose: Purpose, waiterID: UUID,
                         continuation: CheckedContinuation<ImageAnalysisPayload, Error>) {
        let key = Key(request, descriptor: descriptor, purpose: purpose)
        let waiter = Waiter(request: request, continuation: continuation)
        if var job = running, job.key == key, !job.waiters.isEmpty {
            job.waiters[waiterID] = waiter; running = job
        } else if var job = pending, job.key == key {
            job.waiters[waiterID] = waiter; pending = job
        } else {
            if var job = running { fail(&job, with: .superseded); job.task?.cancel(); running = job }
            if var job = pending { fail(&job, with: .superseded) }
            pending = Job(id: UUID(), key: key, request: request, waiters: [waiterID: waiter])
        }
        startNext(); publish()
    }

    private func cancel(_ waiterID: UUID) {
        if var job = running, let waiter = job.waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(throwing: ImageAnalysisError.cancelled)
            if job.waiters.isEmpty { job.task?.cancel() }
            running = job
        } else if var job = pending, let waiter = job.waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(throwing: ImageAnalysisError.cancelled)
            pending = job.waiters.isEmpty ? nil : job
        }
        publish()
    }

    private func startNext() {
        guard running == nil, var job = pending else { return }
        pending = nil
        let jobID = job.id, key = job.key, request = job.request
        let provider = self.provider, preparer = self.preparer, budget = self.budget
        let descriptor = self.descriptor
        job.task = Task.detached(priority: .userInitiated) { [weak self] in
            var lease: AIResourceBudget.Lease?
            var result: Result<Cached, Error>
            do {
                try Task.checkCancellation()
                if case .unavailable(let reason) = await provider.availability() { throw ImageAnalysisError.unavailable(reason) }
                let stamp = try await preparer.sourceStamp(for: request)
                if let cached = await self?.cached(key, matching: stamp) {
                    guard try await preparer.sourceStamp(for: request) == stamp else { throw ImageAnalysisError.staleSource }
                    result = .success(cached)
                } else {
                    let input = try await preparer.prepare(request)
                    guard input.sourceStamp == stamp else { throw ImageAnalysisError.staleSource }
                    guard input.bitmap.image.width > 0, input.bitmap.image.height > 0,
                          max(input.bitmap.image.width, input.bitmap.image.height) <= ImageAnalysisPreparer.maximumPixelSize,
                          input.bitmap.byteCost <= ImageAnalysisPreparer.maximumRasterBytes,
                          input.rasterSHA256.count == 64 else { throw ImageAnalysisError.inputLimitExceeded }
                    try Task.checkCancellation()
                    lease = try await budget.acquireLocalInference()
                    try Task.checkCancellation()
                    // Readiness is checked again after a potentially long budget wait.
                    if case .unavailable(let reason) = await provider.availability() { throw ImageAnalysisError.unavailable(reason) }
                    let data: Data
                    switch key.purpose {
                    case .analysis: data = try await provider.analyze(input)
                    case .metadata: data = try await provider.metadata(input)
                    }
                    try Task.checkCancellation()
                    switch key.purpose {
                    case .analysis: _ = try ImageAnalysisSuggestionValidator().validate(data)
                    case .metadata: _ = try PhotoMetadataModelResponseValidator.validate(data)
                    }
                    guard try await preparer.sourceStamp(for: request) == stamp else { throw ImageAnalysisError.staleSource }
                    let source = request.snapshot.source
                    let provenance = ImageAnalysisProvenance(descriptor: descriptor, analyzedAt: Date(),
                        rasterSHA256: input.rasterSHA256, pixelWidth: input.bitmap.image.width, pixelHeight: input.bitmap.image.height,
                        byteCount: input.bitmap.byteCost, colorProfile: input.colorProfile, colorProfileSHA256: input.colorProfileSHA256,
                        source: source, inputKind: request.inputKind, editToken: request.inputKind == .editedPreview ? request.snapshot.token : nil)
                    let cost = data.count + provenance.colorProfile.utf8.count + source.originalPathCost + 1_024
                    result = .success(Cached(data: data, provenance: provenance, sourceStamp: stamp, cost: cost, access: 0))
                }
                try Task.checkCancellation()
            } catch is CancellationError { result = .failure(ImageAnalysisError.cancelled) }
            catch is PhotoMetadataError { result = .failure(ImageAnalysisError.invalidResponse) }
            catch let error as ImageAnalysisError { result = .failure(Task.isCancelled ? ImageAnalysisError.cancelled : error) }
            catch { result = .failure(Task.isCancelled ? ImageAnalysisError.cancelled : ImageAnalysisError.providerFailure) }
            if let lease { await budget.release(lease) }
            await self?.finish(jobID, result: result)
        }
        running = job
    }

    private func cached(_ key: Key, matching stamp: ImageAnalysisSourceStamp) -> Cached? {
        guard var entry = cache[key] else { return nil }
        guard entry.sourceStamp == stamp else {
            // A replaced file with restored catalog metadata is new content.
            // Preparation uses this native stamp in both shared raster caches.
            cacheBytes -= entry.cost; cache.removeValue(forKey: key)
            return nil
        }
        sequence &+= 1; entry.access = sequence; cache[key] = entry
        return entry
    }

    private func finish(_ id: UUID, result: Result<Cached, Error>) {
        guard let job = running, job.id == id else { return }
        running = nil
        if !job.waiters.isEmpty, case .success(let entry) = result { insert(entry, for: job.key) }
        for waiter in job.waiters.values {
            do {
                let entry = try result.get()
                waiter.continuation.resume(returning: ImageAnalysisPayload(request: waiter.request, data: entry.data,
                    provenance: entry.provenance, sourceStamp: entry.sourceStamp))
            } catch { waiter.continuation.resume(throwing: error) }
        }
        startNext(); publish()
    }

    private func insert(_ entry: Cached, for key: Key) {
        guard maximumCacheEntries > 0, entry.cost <= maximumCacheBytes else { return }
        if let old = cache.removeValue(forKey: key) { cacheBytes -= old.cost }
        while cache.count >= maximumCacheEntries || cacheBytes > maximumCacheBytes - entry.cost {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { return }
            cacheBytes -= oldest.value.cost; cache.removeValue(forKey: oldest.key)
        }
        var entry = entry; sequence &+= 1; entry.access = sequence
        cache[key] = entry; cacheBytes += entry.cost
    }

    private func fail(_ job: inout Job, with error: ImageAnalysisError) {
        let waiters = job.waiters.values; job.waiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: error) }
    }
}
