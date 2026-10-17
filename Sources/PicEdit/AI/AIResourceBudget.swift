import Foundation

/// Shared admission for local model work. Preview decoding and rendering remain
/// with ImagePreviewPipeline and AdjustedPreviewPipeline and their existing
/// bounded caches, selected-photo priority, and worker limits. This budget does
/// not start another preview worker pool or promise a total GPU memory limit.
actor AIResourceBudget {
    static let shared = AIResourceBudget()

    struct Limits: Equatable, Sendable {
        /// Text, image analysis, semantic inference and model compilation share
        /// one admission slot; native work owns it until its actual return.
        let maximumConcurrentLocalInferences = 1
        let maximumPromptBytes: Int
        let maximumResponseBytes: Int
        /// Admission for declared resident weights plus native working buffers.
        /// The evaluation helper separately measures actual RSS/footprint; this
        /// estimate is not a hard limit on framework or system GPU allocations.
        let maximumResidentModelBytes: Int64

        init(maximumPromptBytes: Int = 16_384, maximumResponseBytes: Int = 65_536,
             maximumResidentModelBytes: Int64 = 6 * 1_024 * 1_024 * 1_024) {
            self.maximumPromptBytes = max(1, maximumPromptBytes)
            self.maximumResponseBytes = max(1, maximumResponseBytes)
            self.maximumResidentModelBytes = max(0, maximumResidentModelBytes)
        }
    }

    enum AdmissionError: Error, Equatable, Sendable {
        case invalidMemoryRequest, exceedsResidentMemoryLimit
    }

    enum Priority: Int, Sendable {
        case background, interactive
    }

    struct Lease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct State: Equatable, Sendable {
        let activeInferences: Int
        let waitingInferences: Int
        let residentModelBytes: Int64
    }

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let residentBytes: Int64
        let continuation: CheckedContinuation<Lease, Error>
    }

    nonisolated let limits: Limits
    private var leases: [UUID: Int64] = [:]
    private var waiting: [Waiter] = []
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    func acquireLocalInference(priority: Priority = .interactive, residentBytes: Int64 = 0) async throws -> Lease {
        try Task.checkCancellation()
        guard residentBytes >= 0 else { throw AdmissionError.invalidMemoryRequest }
        guard residentBytes <= limits.maximumResidentModelBytes else { throw AdmissionError.exceedsResidentMemoryLimit }
        let id = UUID()
        let lease: Lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if leases.count < limits.maximumConcurrentLocalInferences {
                    leases[id] = residentBytes
                    continuation.resume(returning: Lease(id: id))
                } else {
                    waiting.append(Waiter(id: id, priority: priority, residentBytes: residentBytes, continuation: continuation))
                }
                publishState()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // The cancellation handler may race a just-granted continuation. Never
        // strand that lease when the caller was canceled at the same instant.
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    func release(_ lease: Lease) {
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        if !waiting.isEmpty {
            // A running native inference cannot be preempted safely. At its
            // actual return, selected/query work precedes queued index work;
            // preserve FIFO within either class rather than starting more pools.
            let index = waiting.firstIndex { $0.priority == .interactive } ?? 0
            let next = waiting.remove(at: index)
            leases[next.id] = next.residentBytes
            next.continuation.resume(returning: Lease(id: next.id))
        }
        publishState()
    }

    /// Bounded diagnostic snapshots contain counts only, never prompts or paths.
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

    private var state: State {
        State(activeInferences: leases.count, waitingInferences: waiting.count,
              residentModelBytes: leases.values.reduce(0, +))
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        publishState()
    }

    private func publishState() {
        for observer in observers.values { observer.yield(state) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
