import Foundation
import PicEditCore

/// The request identity travels with every result, including shared inference.
/// The editor must check its snapshot again on MainActor before applying it.
struct AIProposalResult: Equatable, Sendable {
    let request: AIEditingRequest
    let validation: EditProposalValidationResult
}

struct AILookGroupResult: Equatable, Sendable {
    let request: AIEditingRequest
    let validation: AIValidatedLookGroup
}

private enum AIRequestValidation: Sendable {
    case single(EditProposalValidationResult)
    case looks(AIValidatedLookGroup)
}

/// Latest-context scheduling with one actual provider call and one pending
/// context. A canceled, non-cooperative provider keeps its slot and resource
/// lease until it really returns. All inference runs outside MainActor.
actor AIRequestCoordinator {
    struct State: Equatable, Sendable {
        let runningRequestID: UUID?
        let queuedRequestID: UUID?
        let waiterCount: Int

        var runningCount: Int { runningRequestID == nil ? 0 : 1 }
        var queuedCount: Int { queuedRequestID == nil ? 0 : 1 }
    }

    private struct Context: Hashable {
        let prompt: String
        let snapshot: AIEditingSnapshot
        let mode: AIEditingMode
    }

    private struct Waiter {
        let request: AIEditingRequest
        let continuation: CheckedContinuation<AIRequestValidation, Error>
    }

    private struct Job {
        let id: UUID
        let context: Context
        let request: AIEditingRequest
        var waiters: [UUID: Waiter]
        var task: Task<Void, Never>?
    }

    private let provider: any AIEditingProvider
    private let budget: AIResourceBudget
    private let validator: EditProposalValidator
    private var running: Job?
    private var pending: Job?
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    init(provider: any AIEditingProvider, budget: AIResourceBudget = .shared,
         validator: EditProposalValidator? = nil) {
        self.provider = provider
        self.budget = budget
        self.validator = validator ?? EditProposalValidator(maximumResponseBytes: budget.limits.maximumResponseBytes)
    }

    func proposal(for request: AIEditingRequest) async throws -> AIProposalResult {
        guard request.mode == .single else { throw AIEditingError.invalidRequest }
        guard case .single(let validation) = try await perform(request) else { throw AIEditingError.invalidRequest }
        return AIProposalResult(request: request, validation: validation)
    }

    func lookGroup(for request: AIEditingRequest) async throws -> AILookGroupResult {
        guard request.mode == .lookGroup else { throw AIEditingError.invalidRequest }
        guard case .looks(let validation) = try await perform(request) else { throw AIEditingError.invalidRequest }
        return AILookGroupResult(request: request, validation: validation)
    }

    private func perform(_ request: AIEditingRequest) async throws -> AIRequestValidation {
        try Task.checkCancellation()
        try request.validate(maximumPromptBytes: budget.limits.maximumPromptBytes)
        let capability: AIProviderCapabilities = request.mode == .single ? .textEditing : .lookSuggestions
        guard provider.capabilities.contains(capability) else { throw AIEditingError.unsupportedCapability }
        let waiterID = UUID()
        let result: AIRequestValidation = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AIRequestValidation, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(request, waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
        try Task.checkCancellation()
        return result
    }

    /// Cancels waiting callers immediately, while actual provider work retains
    /// its slot until completion. Safe to call repeatedly during image changes.
    func cancelAll() {
        if var job = running {
            completeWaiters(&job, throwing: CancellationError())
            job.task?.cancel()
            running = job
        }
        if var job = pending {
            completeWaiters(&job, throwing: CancellationError())
            pending = nil
        }
        publishState()
    }

    /// At most one buffered snapshot; no model input or output is logged.
    func stateUpdates() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func enqueue(_ request: AIEditingRequest, waiterID: UUID,
                         continuation: CheckedContinuation<AIRequestValidation, Error>) {
        let context = Context(prompt: request.prompt, snapshot: request.snapshot, mode: request.mode)
        let waiter = Waiter(request: request, continuation: continuation)
        if var job = running, job.context == context, !job.waiters.isEmpty {
            job.waiters[waiterID] = waiter
            running = job
        } else if var job = pending, job.context == context {
            job.waiters[waiterID] = waiter
            pending = job
        } else {
            // Context changes invalidate old callers immediately. The running
            // provider may ignore cancellation, so its job cannot be removed.
            if var job = running {
                completeWaiters(&job, throwing: AIEditingError.superseded)
                job.task?.cancel()
                running = job
            }
            if var job = pending {
                completeWaiters(&job, throwing: AIEditingError.superseded)
            }
            pending = Job(id: UUID(), context: context, request: request, waiters: [waiterID: waiter])
        }
        startNext()
        publishState()
    }

    private func cancel(_ waiterID: UUID) {
        if var job = running, let waiter = job.waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(throwing: CancellationError())
            if job.waiters.isEmpty { job.task?.cancel() }
            running = job
        } else if var job = pending, let waiter = job.waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(throwing: CancellationError())
            pending = job.waiters.isEmpty ? nil : job
        }
        publishState()
    }

    private func startNext() {
        guard running == nil, var job = pending else { return }
        pending = nil
        let jobID = job.id
        let request = job.request
        let provider = self.provider
        let budget = self.budget
        let validator = self.validator
        job.task = Task.detached(priority: .userInitiated) { [weak self] in
            var lease: AIResourceBudget.Lease?
            let result: Result<AIRequestValidation, Error>
            do {
                try Task.checkCancellation()
                let availability = await provider.availability()
                try Task.checkCancellation()
                if case let .unavailable(reason) = availability { throw AIEditingError.unavailable(reason) }
                if !(provider is any AIRemoteEditingProvider) { lease = try await budget.acquireLocalInference() }
                try Task.checkCancellation()
                let data = try await provider.proposal(for: request)
                try Task.checkCancellation()
                guard data.count <= budget.limits.maximumResponseBytes else {
                    throw AIEditingError.invalidResponse(.responseTooLarge)
                }
                switch request.mode {
                case .single:
                    result = .success(.single(try validator.validate(data, against: request.snapshot.settings)))
                case .lookGroup:
                    result = .success(.looks(try validator.validateLookGroup(data, against: request.snapshot.settings)))
                }
            } catch is CancellationError {
                result = .failure(CancellationError())
            } catch let error as AICloudError {
                result = .failure(error)
            } catch let error as AIEditingError {
                result = .failure(error)
            } catch {
                // Provider errors can contain paths, credentials, or prompts.
                // Expose only the stable, data-free failure category.
                result = .failure(AIEditingError.providerFailure)
            }
            if let lease { await budget.release(lease) }
            await self?.finish(jobID, result: result)
        }
        running = job
    }

    private func finish(_ jobID: UUID, result: Result<AIRequestValidation, Error>) {
        guard let job = running, job.id == jobID else { return }
        running = nil
        for waiter in job.waiters.values {
            waiter.continuation.resume(with: result)
        }
        startNext()
        publishState()
    }

    private func completeWaiters(_ job: inout Job, throwing error: Error) {
        let waiters = job.waiters.values
        job.waiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: error) }
    }

    private var state: State {
        State(runningRequestID: running?.request.id, queuedRequestID: pending?.request.id,
              waiterCount: (running?.waiters.count ?? 0) + (pending?.waiters.count ?? 0))
    }

    private func publishState() {
        for observer in observers.values { observer.yield(state) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
