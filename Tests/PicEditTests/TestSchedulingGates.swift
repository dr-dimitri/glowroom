import Foundation

struct TestSchedulingTimeout: Error, CustomStringConvertible {
    let operation: String
    let lastState: String
    var description: String { "Timed out waiting for \(operation); last state: \(lastState)" }
}

/// Latched fake events suspend the test instead of occupying a cooperative
/// executor thread. Registration, publication and cancellation share one lock;
/// continuations always resume after leaving that short critical section.
final class TestStateSignal<Value: Sendable>: @unchecked Sendable {
    private struct Waiter {
        let predicate: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Value, Error>
    }
    private let lock = NSLock()
    private var stored: Value
    private var waiters: [UUID: Waiter] = [:]

    init(_ initialValue: Value) { stored = initialValue }
    var value: Value { lock.withLock { stored } }
    var waiterCount: Int { lock.withLock { waiters.count } }

    func update(_ mutation: (inout Value) -> Void) {
        let ready: (Value, [Waiter]) = lock.withLock {
            mutation(&stored)
            let matched = waiters.filter { $0.value.predicate(stored) }
            for id in matched.keys { waiters.removeValue(forKey: id) }
            return (stored, Array(matched.values))
        }
        for waiter in ready.1 { waiter.continuation.resume(returning: ready.0) }
    }

    @discardableResult
    func wait(_ description: String, timeout: Duration = .seconds(4),
              until predicate: @escaping @Sendable (Value) -> Bool) async throws -> Value {
        try Task.checkCancellation()
        let current = value
        if predicate(current) { return current }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await self.waitUntil(predicate) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestSchedulingTimeout(operation: description, lastState: String(describing: self.value))
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func waitUntil(_ predicate: @escaping @Sendable (Value) -> Bool) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Value, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if predicate(stored) { return .success(stored) }
                    waiters[id] = Waiter(predicate: predicate, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
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
