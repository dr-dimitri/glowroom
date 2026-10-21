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

    @Test func timelyPublicationWinsBeforeDelayedDeliveryPastTheDeadline() async throws {
        let scheduling = ControlledSignalScheduling()
        defer { scheduling.releaseAll() }
        let signal = scheduling.makeSignal()
        let task = Task { try await signal.wait("timely publication", timeout: .seconds(5), until: { $0 == 1 }) }
        defer { task.cancel() }
        try await scheduling.waitForWatchdog()

        scheduling.advance(to: .seconds(4))
        signal.update { $0 = 1 }
        #expect(signal.waiterCount == 0 && scheduling.pendingDeliveries == 1)
        // Keep the success continuation suspended while the watchdog's deadline
        // passes. Cancellation must reap the watchdog before caller delivery.
        scheduling.advance(to: .seconds(6))
        scheduling.releaseDeadline()
        try await scheduling.waitForWatchdogCleanup()
        #expect(scheduling.pendingDeliveries == 1)
        scheduling.deliverAll()
        #expect(try await task.value == 1)
    }

    @Test func timeoutWinsBeforeALaterPublicationAndKeepsItsAtomicSnapshot() async throws {
        let scheduling = ControlledSignalScheduling()
        defer { scheduling.releaseAll() }
        let signal = scheduling.makeSignal()
        let task = Task { try await signal.wait("deadline before event", timeout: .seconds(5), until: { $0 == 1 }) }
        defer { task.cancel() }
        try await scheduling.waitForWatchdog()

        scheduling.advance(to: .seconds(5))
        scheduling.releaseDeadline()
        try await scheduling.waitForDelivery()
        #expect(signal.waiterCount == 0)
        scheduling.advance(to: .seconds(6))
        signal.update { $0 = 1 }
        #expect(scheduling.pendingDeliveries == 1)
        scheduling.deliverAll()
        do { _ = try await task.value; Issue.record("Late publication replaced an already decided timeout") }
        catch let error as TestSchedulingTimeout {
            #expect(error.lastState == "0")
            #expect(error.lastPublicationRelativeToDeadline == .seconds(-5))
            #expect(error.decisionRelativeToDeadline == .zero)
        }
        try await scheduling.waitForWatchdogCleanup()
    }

    @Test func publicationWinsBeforeADelayedWatchdogDecision() async throws {
        let scheduling = ControlledSignalScheduling()
        defer { scheduling.releaseAll() }
        let signal = scheduling.makeSignal()
        let task = Task { try await signal.wait("publication before delayed watchdog", timeout: .seconds(5), until: { $0 == 1 }) }
        defer { task.cancel() }
        try await scheduling.waitForWatchdog()

        // The short watchdog diagnoses a hang; it is not a production deadline.
        // Event publication wins while the watchdog still has no executor turn.
        scheduling.advance(to: .seconds(6))
        signal.update { $0 = 1 }
        #expect(signal.waiterCount == 0 && scheduling.pendingDeliveries == 1)
        scheduling.deliverAll()
        #expect(try await task.value == 1)
        try await scheduling.waitForWatchdogCleanup()
    }

    @Test func anUnmetLatePublicationWaitsForTheWatchdogAndReportsItsTime() async throws {
        let scheduling = ControlledSignalScheduling()
        defer { scheduling.releaseAll() }
        let signal = scheduling.makeSignal()
        let task = Task { try await signal.wait("unmet state after nominal sleep", timeout: .seconds(5), until: { $0 == 1 }) }
        defer { task.cancel() }
        try await scheduling.waitForWatchdog()

        scheduling.advance(to: .seconds(6))
        signal.update { $0 = 0 }
        #expect(signal.waiterCount == 1 && scheduling.pendingDeliveries == 0)
        scheduling.releaseDeadline()
        try await scheduling.waitForDelivery()
        scheduling.deliverAll()
        do { _ = try await task.value; Issue.record("Unmet prerequisite passed its watchdog") }
        catch let error as TestSchedulingTimeout {
            #expect(error.operation == "unmet state after nominal sleep" && error.lastState == "0")
            #expect(error.lastPublicationRelativeToDeadline == .seconds(1))
            #expect(error.decisionRelativeToDeadline == .seconds(1))
            #expect(error.description.contains("state publication relative to deadline:"))
        }
        #expect(signal.waiterCount == 0)
        try await scheduling.waitForWatchdogCleanup()
    }

    @Test func cancellationWinsBeforePublicationAndTimeoutWithoutDoubleDelivery() async throws {
        let scheduling = ControlledSignalScheduling()
        defer { scheduling.releaseAll() }
        let signal = scheduling.makeSignal()
        let task = Task { try await signal.wait("cancelled competing waiter", timeout: .seconds(5), until: { $0 == 1 }) }
        defer { task.cancel() }
        try await scheduling.waitForWatchdog()

        task.cancel()
        try await scheduling.waitForDelivery()
        scheduling.advance(to: .seconds(6))
        scheduling.releaseDeadline()
        signal.update { $0 = 1 }
        try await scheduling.waitForWatchdogCleanup()
        #expect(signal.waiterCount == 0 && scheduling.pendingDeliveries == 1)
        scheduling.deliverAll()
        do { _ = try await task.value; Issue.record("Cancelled gate returned an event") }
        catch is CancellationError {}
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

/// A virtual clock and explicit barriers order the competing gate decisions;
/// neither a short sleep nor executor speed establishes a test prerequisite.
private final class ControlledSignalScheduling: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var elapsed = Duration.zero
    private var deliveries: [@Sendable () -> Void] = []
    private var released = false
    private let deadline = TestStateSignal(false)
    private let watchdogStarted = TestStateSignal(false)
    private let watchdogFinished = TestStateSignal(false)
    private let deliveryQueued = TestStateSignal(false)

    var pendingDeliveries: Int { lock.withLock { deliveries.count } }

    func makeSignal() -> TestStateSignal<Int> {
        TestStateSignal(0, now: { self.lock.withLock { self.origin.advanced(by: self.elapsed) } },
                        sleepUntil: { _ in
                            self.watchdogStarted.update { $0 = true }
                            defer { self.watchdogFinished.update { $0 = true } }
                            try await self.deadline.wait("controlled deadline release", until: { $0 })
                        }, deliver: { continuation in
                            let immediate = self.lock.withLock {
                                if self.released { return true }
                                self.deliveries.append(continuation)
                                return false
                            }
                            if immediate { continuation() }
                            else { self.deliveryQueued.update { $0 = true } }
                        })
    }

    func advance(to elapsed: Duration) { lock.withLock { self.elapsed = elapsed } }
    func releaseDeadline() { deadline.update { $0 = true } }
    func waitForWatchdog() async throws {
        try await watchdogStarted.wait("controlled watchdog registered", until: { $0 })
    }
    func waitForWatchdogCleanup() async throws {
        try await watchdogFinished.wait("controlled watchdog reaped", until: { $0 })
        #expect(deadline.waiterCount == 0)
    }
    func waitForDelivery() async throws {
        try await deliveryQueued.wait("controlled continuation queued", until: { $0 })
    }
    func deliverAll() {
        let ready = lock.withLock {
            let ready = deliveries
            deliveries.removeAll()
            return ready
        }
        for continuation in ready { continuation() }
    }
    func releaseAll() {
        lock.withLock { released = true }
        releaseDeadline()
        deliverAll()
    }
}
