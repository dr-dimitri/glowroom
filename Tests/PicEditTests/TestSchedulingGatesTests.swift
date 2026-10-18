import Foundation
import Testing

@Suite("Suspendable scheduling test gates", .timeLimit(.minutes(1)))
struct TestSchedulingGatesTests {
    @Test func anEventBeforeRegistrationIsLatched() async throws {
        let signal = TestStateSignal(0)
        signal.update { $0 = 1 }
        #expect(try await signal.wait("already published event", until: { $0 == 1 }) == 1)
        #expect(signal.waiterCount == 0)
    }

    @Test func cancellationRemovesTheWaiterWithoutConsumingALaterEvent() async throws {
        let signal = TestStateSignal(0)
        let task = Task { try await signal.wait("cancelled waiter", until: { $0 == 1 }) }
        defer { task.cancel() }
        try await waitForTestState("signal waiter registration", state: { signal.waiterCount }, until: { $0 == 1 })
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled gate returned an event") }
        catch is CancellationError {}
        #expect(signal.waiterCount == 0 && signal.value == 0)
        signal.update { $0 = 1 }
        #expect(try await signal.wait("event after cancellation", until: { $0 == 1 }) == 1)
    }

    @Test func timeoutStopsThePrerequisiteAndReapsItsContinuation() async throws {
        let signal = TestStateSignal(0)
        do {
            _ = try await signal.wait("missing start", timeout: .milliseconds(20), until: { $0 == 1 })
            Issue.record("Missing event passed its prerequisite")
        } catch let error as TestSchedulingTimeout {
            #expect(error.operation == "missing start" && error.lastState == "0")
        }
        #expect(signal.waiterCount == 0)
    }

    @Test func cancellationBeforeRegistrationDoesNotInstallAWaiter() async throws {
        let start = TestAsyncLatch()
        let signal = TestStateSignal(0)
        defer { start.releaseAll() }
        let task = Task {
            await start.wait()
            return try await signal.wait("already cancelled caller", until: { $0 == 1 })
        }
        defer { task.cancel() }
        task.cancel()
        start.releaseAll()
        do { _ = try await task.value; Issue.record("Already cancelled gate returned an event") }
        catch is CancellationError {}
        #expect(signal.waiterCount == 0)
    }

    @Test func cancelledNativeFakeStillRequiresActualRelease() async throws {
        let latch = TestAsyncLatch()
        let completed = TestStateSignal(false)
        defer { latch.releaseAll() }
        let task = Task { await latch.wait(); completed.update { $0 = true } }
        defer { task.cancel() }
        try await waitForTestState("native fake suspended", state: { latch.waitingCount }, until: { $0 == 1 })
        task.cancel()
        #expect(latch.waitingCount == 1 && !completed.value)
        latch.releaseAll()
        await task.value
        #expect(completed.value && latch.waitingCount == 0)
        // Future waits also observe the release without a lost wakeup.
        await latch.wait()
    }
}
