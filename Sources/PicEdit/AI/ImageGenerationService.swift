import Foundation
import PicEditCore

/// One native job and one replaceable waiting request. Cancellation and deadlines
/// resolve the observer immediately, but retain admission until native return.
/// This scheduler does not create another inference pool or retain image caches.
actor ImageGenerationService {
    typealias CurrentToken = @Sendable () async -> GenerationMaskJobToken?
    nonisolated let descriptor: ImageGenerationBackendDescriptor

    struct State: Equatable, Sendable {
        let runningCount: Int
        let queuedCount: Int
        let observerCount: Int
        let runningRequestID: UUID?
        let queuedRequestID: UUID?
    }

    private struct Work {
        let id: UUID
        let job: ImageGenerationJob
        let currentToken: CurrentToken
        let expiresAt: ContinuousClock.Instant
        var continuation: CheckedContinuation<ImageGenerationOutput, Error>?
        var worker: Task<Void, Never>?
        var deadline: Task<Void, Never>?
    }

    private let backend: any ImageGenerationBackend
    private let budget: AIResourceBudget
    private let resources: any ArtifactResourceAdmitting
    private let timeout: Duration
    private var running: Work?
    private var pending: Work?
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    init(backend: any ImageGenerationBackend = UnavailableImageGenerationBackend(),
         budget: AIResourceBudget = .shared, resources: any ArtifactResourceAdmitting,
         timeout: Duration = .seconds(120)) {
        self.backend = backend; descriptor = backend.descriptor
        self.budget = budget; self.resources = resources; self.timeout = max(.milliseconds(1), timeout)
    }

    func availability(for operation: ImageGenerationOperation) async -> ImageGenerationAvailability {
        let state = await backend.availability()
        guard state == .available else { return state }
        switch descriptor.status(for: operation) {
        case .supported: return .available
        case .unsupported: return .unavailable(.unsupportedOperation)
        case .unverified: return .unavailable(.unverifiedCapability)
        }
    }

    /// The caller supplies the *current* complete UI/source/mask token, not a
    /// snapshot-equality guess. A changed mask or A→B→A epoch rejects late output.
    func generate(_ job: ImageGenerationJob, currentToken: @escaping CurrentToken) async throws -> ImageGenerationOutput {
        guard !Task.isCancelled else { throw ImageGenerationError.cancelled }
        let id = UUID(), expiresAt = ContinuousClock.now.advanced(by: timeout)
        let output: ImageGenerationOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: ImageGenerationError.cancelled); return }
                enqueue(Work(id: id, job: job, currentToken: currentToken, expiresAt: expiresAt, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id, reason: .cancelled) } }
        guard !Task.isCancelled else { throw ImageGenerationError.cancelled }
        let token = await currentToken()
        guard !Task.isCancelled else { throw ImageGenerationError.cancelled }
        guard ContinuousClock.now < expiresAt else { throw ImageGenerationError.timedOut }
        guard token == job.request.token else { throw ImageGenerationError.staleInput }
        return output
    }

    /// Selection, restore and mask lifecycle owners may explicitly revoke work.
    /// Already accepted persistence belongs to the artifact transaction service.
    func invalidate() {
        if var work = running { fail(&work, reason: .cancelled); work.worker?.cancel(); running = work }
        if var work = pending { fail(&work, reason: .cancelled); pending = nil }
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
            observerCount: (running?.continuation == nil ? 0 : 1) + (pending?.continuation == nil ? 0 : 1),
            runningRequestID: running?.job.request.id, queuedRequestID: pending?.job.request.id)
    }
    private func publish() { for observer in observers.values { observer.yield(state) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func enqueue(_ newWork: Work) {
        if var work = running { fail(&work, reason: .superseded); work.worker?.cancel(); running = work }
        if var work = pending { fail(&work, reason: .superseded) }
        var work = newWork
        let clock = ContinuousClock(), deadline = work.expiresAt, id = work.id
        work.deadline = Task { [weak self] in
            // The deadline includes time queued and time when the Mac sleeps.
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.cancel(id, reason: .timedOut)
        }
        pending = work; startNext(); publish()
    }

    private func cancel(_ id: UUID, reason: ImageGenerationError) {
        if var work = running, work.id == id {
            fail(&work, reason: reason); work.worker?.cancel(); running = work
        } else if var work = pending, work.id == id {
            fail(&work, reason: reason); pending = nil
        }
        publish()
    }

    private func fail(_ work: inout Work, reason: ImageGenerationError) {
        work.continuation?.resume(throwing: reason); work.continuation = nil
        work.deadline?.cancel(); work.deadline = nil
    }

    private func startNext() {
        guard running == nil, var work = pending else { return }
        pending = nil
        let id = work.id, job = work.job, currentToken = work.currentToken, expiresAt = work.expiresAt
        let backend = self.backend, descriptor = self.descriptor, budget = self.budget, resources = self.resources
        work.worker = Task.detached(priority: .userInitiated) { [weak self] in
            var lease: AIResourceBudget.Lease?
            let result: Result<ImageGenerationOutput, Error>
            do {
                try Task.checkCancellation()
                guard await currentToken() == job.request.token else { throw ImageGenerationError.staleInput }
                if case .unavailable(let reason) = await backend.availability() { throw ImageGenerationError.unavailable(reason) }
                switch descriptor.status(for: job.operation) {
                case .supported: break
                case .unsupported: throw ImageGenerationError.unavailable(.unsupportedOperation)
                case .unverified: throw ImageGenerationError.unavailable(.unverifiedCapability)
                }
                let size = job.placement.outputSize
                guard size.width <= descriptor.maximumOutputPixels / size.height else { throw ImageGenerationError.invalidRequest }
                lease = try await budget.acquireLocalInference(residentBytes: descriptor.residentMemoryBytes)
                try Task.checkCancellation()
                // Readiness can change while another feature holds admission.
                if case .unavailable(let reason) = await backend.availability() { throw ImageGenerationError.unavailable(reason) }
                guard await currentToken() == job.request.token else { throw ImageGenerationError.staleInput }
                try Task.checkCancellation()
                guard ContinuousClock.now < expiresAt else { throw ImageGenerationError.timedOut }
                let candidate = try await backend.generate(job)
                try Task.checkCancellation()
                try candidate.validate(for: job, descriptor: descriptor)
                guard await currentToken() == job.request.token else { throw ImageGenerationError.staleInput }
                // A model may alter every pixel. Only the authoritative frozen
                // native mask authorizes replacement before any caller can see
                // the result; small inputs use CPU, large ones the existing CI
                // lane and its bounded artifact ownership.
                let raster = try await MaskCompositor.compose(base: job.request.input, candidate: candidate.raster,
                    mask: job.request.mask.raster, resources: resources)
                try Task.checkCancellation()
                let output = try ImageGenerationOutput(immutableRaster: raster, token: job.request.token)
                try output.validate(for: job, descriptor: descriptor)
                guard await currentToken() == job.request.token else { throw ImageGenerationError.staleInput }
                guard ContinuousClock.now < expiresAt else { throw ImageGenerationError.timedOut }
                result = .success(output)
            } catch is CancellationError { result = .failure(ImageGenerationError.cancelled) }
            catch is AIResourceBudget.AdmissionError { result = .failure(ImageGenerationError.unavailable(.memoryPressure)) }
            catch ArtifactResourceError.capacityExceeded { result = .failure(ImageGenerationError.unavailable(.memoryPressure)) }
            catch let error as ImageGenerationError { result = .failure(error) }
            catch { result = .failure(ImageGenerationError.backendFailure) }
            // Uncooperative/synchronous SDK calls reach here only on actual
            // return, including when the observer's deadline expired earlier.
            if let lease { await budget.release(lease) }
            await self?.finish(id, result: result)
        }
        running = work
    }

    private func finish(_ id: UUID, result: Result<ImageGenerationOutput, Error>) async {
        guard let work = running, work.id == id else { return }
        let token = await work.currentToken()
        // Checking the app token yielded the actor; cancellation/replacement may
        // have revoked its observer in the meantime. Never resume it twice.
        guard var work = running, work.id == id else { return }
        running = nil; work.deadline?.cancel()
        if let continuation = work.continuation {
            // The timer and worker can become runnable together after sleep.
            // Publication must enforce the absolute clock deadline even if the
            // timer's cancellation message has not reached this actor yet.
            if ContinuousClock.now >= work.expiresAt { continuation.resume(throwing: ImageGenerationError.timedOut) }
            else if token != work.job.request.token { continuation.resume(throwing: ImageGenerationError.staleInput) }
            else { continuation.resume(with: result) }
            work.continuation = nil
        }
        startNext(); publish()
    }
}
