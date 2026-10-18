import Foundation

/// Run each mode in a separate process. This models only the old synchronous
/// fake wait versus a suspended fake, not image processing or app performance.
@main
struct CooperativePoolProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              ["--blocking", "--suspending"].contains(CommandLine.arguments[1]) else {
            throw TestSchedulingTimeout(operation: "argument --blocking or --suspending", lastState: "invalid arguments")
        }
        let blocking = CommandLine.arguments[1] == "--blocking"
        let result = try await Task.detached(priority: .userInitiated) {
            let count = min(64, max(8, ProcessInfo.processInfo.activeProcessorCount * 2))
            let started = TestStateSignal(0)
            let timedOut = TestStateSignal(0)
            let latch = TestAsyncLatch()
            let semaphore = DispatchSemaphore(value: 0)
            let clock = ContinuousClock(), began = clock.now
            let workers = (0..<count).map { _ in
                Task.detached(priority: .userInitiated) {
                    started.update { $0 += 1 }
                    if blocking {
                        if synchronousFake(semaphore) == .timedOut { timedOut.update { $0 += 1 } }
                    } else {
                        await latch.wait()
                    }
                }
            }
            // The controller must itself obtain a cooperative executor thread
            // before it can free any fake. Blocking workers can delay this wake.
            try await Task.sleep(for: .milliseconds(20))
            let elapsed = began.duration(to: clock.now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            let startedAtWake = started.value
            latch.releaseAll()
            for _ in workers { semaphore.signal() }
            for worker in workers { await worker.value }
            return ["mode": blocking ? "blocking" : "suspending", "workers": count,
                    "startedAtControllerWake": startedAtWake, "controllerMilliseconds": milliseconds,
                    "fakeTimeouts": timedOut.value] as [String: any Sendable]
        }.value
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    // The old fake's synchronous API hid this blocking wait from its async
    // caller. Keep that exact shape only in the explicit diagnostic control.
    private static func synchronousFake(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 5)
    }
}
