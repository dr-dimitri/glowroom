import Foundation
import PicEditCore

/// The request identity travels with every result, including shared inference.
/// The editor must check its snapshot again on MainActor before applying it.
struct AIProposalResult: Equatable, Sendable {
    let request: AIEditingRequest
    let validation: EditProposalValidationResult
    /// Frozen selections created by app services, never decoded from provider JSON.
    let localAdjustments: [LocalAdjustment]

    init(request: AIEditingRequest, validation: EditProposalValidationResult,
         localAdjustments: [LocalAdjustment] = []) {
        self.request = request
        self.validation = validation
        self.localAdjustments = localAdjustments
    }

    /// Reused at acceptance so a target cannot replace existing masks or smuggle
    /// unsupported settings past the model's deliberately small scalar schema.
    static func validate(proposal: EditProposal, localAdjustments: [LocalAdjustment],
                         against baseline: EditSettings,
                         validator: EditProposalValidator = .init()) throws -> EditProposalValidationResult {
        let global = try validator.validate(proposal, against: baseline)
        do {
            try baseline.validateLocalAdjustments()
            guard localAdjustments.count <= 3,
                  localAdjustments.allSatisfy(\.isEffective) else {
                throw AIEditingError.invalidResponse(.invalidType)
            }
            // These bounded scalar/shape checks remain serial. Raster coverage
            // generation and inspection belong to the background mask service.
            for layer in localAdjustments {
                try layer.validate()
                guard layer.mask.refinement == nil else { throw AIEditingError.invalidResponse(.invalidType) }
                switch layer.mask.shape {
                case .subject, .sky: break
                case .brush, .linear, .radial: throw AIEditingError.invalidResponse(.invalidType)
                }
            }
            var target: EditSettings
            switch global {
            case .changes(_, let settings): target = settings
            case .noChange: target = baseline
            }
            target.localAdjustments.append(contentsOf: localAdjustments)
            try target.validateLocalAdjustments()
            return target == baseline ? .noChange(explanation: proposal.explanation)
                : .changes(proposal: proposal, settings: target)
        } catch {
            throw AIEditingError.invalidResponse(.invalidType)
        }
    }
}

struct AILookGroupResult: Equatable, Sendable {
    let request: AIEditingRequest
    let validation: AIValidatedLookGroup
}

private enum AIRequestValidation: Sendable {
    case single(EditProposalValidationResult, localAdjustments: [LocalAdjustment])
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
        guard case .single(let validation, let localAdjustments) = try await perform(request) else { throw AIEditingError.invalidRequest }
        return AIProposalResult(request: request, validation: validation, localAdjustments: localAdjustments)
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
                // Resolved providers lease their actual inference separately
                // from mask work; an outer lease would deadlock a shared budget.
                if !(provider is any AIRemoteEditingProvider), !(provider is any AIResolvedEditingProvider) {
                    lease = try await budget.acquireLocalInference()
                }
                try Task.checkCancellation()
                let data: Data
                let localAdjustments: [LocalAdjustment]
                if let resolved = provider as? any AIResolvedEditingProvider {
                    let proposal = try await resolved.resolvedProposal(for: request)
                    data = proposal.data
                    localAdjustments = proposal.localAdjustments
                } else {
                    data = try await provider.proposal(for: request)
                    localAdjustments = []
                }
                try Task.checkCancellation()
                guard data.count <= budget.limits.maximumResponseBytes else {
                    throw AIEditingError.invalidResponse(.responseTooLarge)
                }
                switch request.mode {
                case .single:
                    let global = try validator.validate(data, against: request.snapshot.settings)
                    let proposal: EditProposal
                    switch global {
                    case .changes(let patch, _): proposal = patch
                    case .noChange(let explanation): proposal = EditProposal(changes: [], explanation: explanation)
                    }
                    let validation = try AIProposalResult.validate(proposal: proposal, localAdjustments: localAdjustments,
                        against: request.snapshot.settings, validator: validator)
                    result = .success(.single(validation, localAdjustments: localAdjustments))
                case .lookGroup:
                    guard localAdjustments.isEmpty else { throw AIEditingError.invalidResponse(.invalidType) }
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
