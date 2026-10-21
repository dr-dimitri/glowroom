import Foundation

struct TestSchedulingTimeout: Error, CustomStringConvertible {
    let operation: String
    let lastState: String
    let lastPublicationRelativeToDeadline: Duration?
    let decisionRelativeToDeadline: Duration?

    init(operation: String, lastState: String,
         lastPublicationRelativeToDeadline: Duration? = nil,
         decisionRelativeToDeadline: Duration? = nil) {
        self.operation = operation
        self.lastState = lastState
        self.lastPublicationRelativeToDeadline = lastPublicationRelativeToDeadline
        self.decisionRelativeToDeadline = decisionRelativeToDeadline
    }

    var description: String {
        var diagnostic = "Timed out waiting for \(operation); last state: \(lastState)"
        if let lastPublicationRelativeToDeadline, let decisionRelativeToDeadline {
            diagnostic += "; state publication relative to deadline: \(lastPublicationRelativeToDeadline)"
            diagnostic += "; decision relative to deadline: \(decisionRelativeToDeadline)"
        }
        return diagnostic
    }
}

/// Latched fake events suspend the test instead of occupying a cooperative
/// executor thread. Registration, publication, timeout and cancellation decide
/// each waiter exactly once under one lock. Delivery happens outside the lock;
/// a delayed continuation cannot turn an already published success into timeout.
final class TestStateSignal<Value: Sendable>: @unchecked Sendable {
    typealias Delivery = @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct Waiter {
        let operation: String
        let deadline: ContinuousClock.Instant
        let predicate: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Value, Error>
        var timeoutTask: Task<Void, Never>?
    }
    private struct Completion {
        let waiter: Waiter
        let result: Result<Value, Error>
    }
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    private let deliver: Delivery
    private var stored: Value
    private var lastPublication: ContinuousClock.Instant
    private var waiters: [UUID: Waiter] = [:]

    // Scheduling dependencies are only for deterministic gate regressions.
    // Every application fake uses the continuous clock and immediate delivery.
    init(_ initialValue: Value,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         },
         deliver: @escaping Delivery = { $0() }) {
        stored = initialValue
        self.now = now
        self.sleepUntil = sleepUntil
        self.deliver = deliver
        lastPublication = now()
    }
    var value: Value { lock.withLock { stored } }
    var waiterCount: Int { lock.withLock { waiters.count } }

    func update(_ mutation: (inout Value) -> Void) {
        let ready: [Completion] = lock.withLock {
            mutation(&stored)
            lastPublication = now()
            var ready: [Completion] = []
            var completedIDs: [UUID] = []
            for (id, waiter) in waiters {
                if waiter.predicate(stored) {
                    ready.append(Completion(waiter: waiter, result: .success(stored)))
                } else {
                    continue
                }
                completedIDs.append(id)
            }
            for id in completedIDs { waiters.removeValue(forKey: id) }
            return ready
        }
        for completion in ready { complete(completion) }
    }

    @discardableResult
    func wait(_ description: String, timeout: Duration = .seconds(4),
              until predicate: @escaping @Sendable (Value) -> Bool) async throws -> Value {
        try Task.checkCancellation()
        let id = UUID()
        let deadline = now().advanced(by: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let immediate: Completion? = lock.withLock {
                    let waiter = Waiter(operation: description, deadline: deadline,
                                        predicate: predicate, continuation: continuation)
                    if Task.isCancelled { return Completion(waiter: waiter, result: .failure(CancellationError())) }
                    if predicate(stored) {
                        return Completion(waiter: waiter, result: .success(stored))
                    }
                    waiters[id] = waiter
                    return nil
                }
                if let immediate {
                    complete(immediate)
                    return
                }
                let timeoutTask = Task {
                    do {
                        try await self.sleepUntil(deadline)
                        try Task.checkCancellation()
                        self.expire(id)
                    } catch {
                        // The winning event or caller cancellation reaps this
                        // watchdog; it never competes through a second result.
                    }
                }
                let installed = lock.withLock {
                    guard waiters[id] != nil else { return false }
                    waiters[id]?.timeoutTask = timeoutTask
                    return true
                }
                if !installed { timeoutTask.cancel() }
            }
        } onCancel: {
            let completion = self.lock.withLock { () -> Completion? in
                guard let waiter = self.waiters.removeValue(forKey: id) else { return nil }
                return Completion(waiter: waiter, result: .failure(CancellationError()))
            }
            if let completion { self.complete(completion) }
        }
    }

    private func expire(_ id: UUID) {
        let completion = lock.withLock { () -> Completion? in
            guard let waiter = waiters.removeValue(forKey: id) else { return nil }
            // This is a diagnostic hang guard, not an application deadline.
            // An event published before this atomic decision wins even if the
            // executor resumed both contenders after the nominal sleep ended.
            let result: Result<Value, Error> = waiter.predicate(stored)
                ? .success(stored) : .failure(timeout(for: waiter, at: now()))
            return Completion(waiter: waiter, result: result)
        }
        if let completion { complete(completion) }
    }

    // Caller holds lock so the state and publication timestamp describe the
    // same timeout decision. Offsets reveal a delayed watchdog independently
    // of whether the required event has actually been published.
    private func timeout(for waiter: Waiter, at instant: ContinuousClock.Instant) -> TestSchedulingTimeout {
        TestSchedulingTimeout(operation: waiter.operation, lastState: String(describing: stored),
                              lastPublicationRelativeToDeadline: waiter.deadline.duration(to: lastPublication),
                              decisionRelativeToDeadline: waiter.deadline.duration(to: instant))
    }

    private func complete(_ completion: Completion) {
        completion.waiter.timeoutTask?.cancel()
        deliver { completion.waiter.continuation.resume(with: completion.result) }
    }
}

/// Models native work that ignores cancellation until its actual return. Only
/// the fake worker uses this uncancellable wait; its test owns releaseAll in
/// defer so a failed prerequisite cannot strand work or its pipeline slot.
final class TestAsyncLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) { self.open = open }
    var waitingCount: Int { lock.withLock { waiting.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let released = lock.withLock {
                if open { return true }
                waiting.append(continuation)
                return false
            }
            if released { continuation.resume() }
        }
    }

    func releaseAll() {
        let ready = lock.withLock {
            open = true
            let ready = waiting
            waiting.removeAll()
            return ready
        }
        for continuation in ready { continuation.resume() }
    }
}

/// A bounded diagnostic fallback for actor state without an event stream.
/// The timeout is a hang guard, never evidence that an operation has enqueued.
@discardableResult
func waitForTestState<Value: Sendable>(
    _ description: String, timeout: Duration = .seconds(4),
    state: @Sendable () async -> Value, until predicate: @Sendable (Value) -> Bool
) async throws -> Value {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        try Task.checkCancellation()
        let current = await state()
        if predicate(current) { return current }
        guard ContinuousClock.now < deadline else {
            throw TestSchedulingTimeout(operation: description, lastState: String(describing: current))
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
