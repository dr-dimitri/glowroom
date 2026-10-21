import Foundation

/// Isolate the few deliberately synchronous native-cache probes from Swift's
/// cooperative pool. Call sites bound concurrent workers to at most three;
/// actor jobs preserve Task cancellation through the synchronous operation.
private final class TestSynchronousExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "glowroom.test.synchronous-worker", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job), executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

actor TestSynchronousWorker {
    nonisolated private let executor = TestSynchronousExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    func run<Value: Sendable>(_ operation: @Sendable () throws -> Value) throws -> Value {
        try operation()
    }
}
