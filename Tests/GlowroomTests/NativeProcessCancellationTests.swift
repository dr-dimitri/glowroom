import Darwin
import Dispatch
import Foundation
import Testing
@testable import Glowroom

@Suite("Native evaluator absolute cancellation deadline", .timeLimit(.minutes(1)))
struct NativeProcessCancellationTests {
    private let policy = NativeProcessCancellation.Policy(maximumSeconds: 1.5, forceAfterSeconds: 0.4)

    @Test func defaultPolicyKeepsTheExistingFiveSecondLimitAndReservesReapingTime() {
        let policy = NativeProcessCancellation.Policy()
        #expect(policy.maximumSeconds == 5)
        #expect(policy.forceAfterSeconds == 4)
    }

    @Test func cooperativeReturnAndConfirmedExitAreSeparateMeasuredObservations() async throws {
        let child = try await cancellationProcessWork { try CancellationChild(mode: "cooperate") }
        defer { child.close() }
        let supervisor = NativeProcessCancellation(process: child.process, policy: policy)
        supervisor.begin { child.sendCancellation() }
        let returnedCode = try await cancellationProcessWork {
            let code = try child.readEvent()
            supervisor.noteNativeReturn(code: code)
            return code
        }
        #expect(returnedCode == "cancelled")
        let evidence = try await cancellationProcessWork { supervisor.finish() }
        #expect(evidence.nativeReturnObserved)
        #expect(evidence.cooperativeGatePassed)
        #expect(evidence.processContainmentGatePassed)
        #expect(evidence.terminationPath == "cooperative")
        #expect(evidence.cancelLatencyUntilNativeReturnSeconds != nil)
        #expect(evidence.cancelLatencyUntilProcessEndSeconds != nil)
        #expect(!child.process.isRunning)
        try expectSerializable(evidence)
    }

    @Test func ignoredCancellationUsesSIGKILLWithoutInventingNativeReturn() async throws {
        let child = try await cancellationProcessWork { try CancellationChild(mode: "ignore") }
        defer { child.close() }
        let supervisor = NativeProcessCancellation(process: child.process, policy: policy)
        supervisor.begin { child.sendCancellation() }
        let evidence = try await cancellationProcessWork { supervisor.finish() }
        #expect(evidence.processContainmentGatePassed)
        #expect(!evidence.cooperativeGatePassed)
        #expect(!evidence.nativeReturnObserved)
        #expect(evidence.terminationPath == "forced-sigkill")
        #expect(evidence.exitStatus == SIGKILL)
        #expect(evidence.exitedBySignal)
        #expect(evidence.report["cancelLatencyUntilNativeReturnSeconds"] is NSNull)
        #expect(evidence.forceError == 0)
        try expectSerializable(evidence)
    }

    @Test func nativeReturnCannotHideAHelperThatHangsDuringCleanup() async throws {
        let child = try await cancellationProcessWork { try CancellationChild(mode: "return-then-hang") }
        defer { child.close() }
        let supervisor = NativeProcessCancellation(process: child.process, policy: policy)
        supervisor.begin { child.sendCancellation() }
        let returnedCode = try await cancellationProcessWork {
            let code = try child.readEvent()
            supervisor.noteNativeReturn(code: code)
            return code
        }
        #expect(returnedCode == "cancelled")
        let evidence = try await cancellationProcessWork { supervisor.finish() }
        #expect(evidence.nativeReturnObserved)
        #expect(evidence.processContainmentGatePassed)
        #expect(!evidence.cooperativeGatePassed)
        #expect(evidence.terminationPath == "forced-sigkill")
        #expect(evidence.cancelLatencyUntilNativeReturnSeconds != nil)
        #expect(evidence.exitStatus == SIGKILL)
    }

    @Test func exitWithoutNativeReturnProvesOnlyProcessContainment() async throws {
        let child = try await cancellationProcessWork { try CancellationChild(mode: "exit-without-return") }
        defer { child.close() }
        let supervisor = NativeProcessCancellation(process: child.process, policy: policy)
        supervisor.begin { child.sendCancellation() }
        let evidence = try await cancellationProcessWork { supervisor.finish() }
        #expect(evidence.processContainmentGatePassed)
        #expect(!evidence.cooperativeGatePassed)
        #expect(!evidence.nativeReturnObserved)
        #expect(evidence.forceAttemptedAt == nil)
        #expect(evidence.terminationPath == "process-exit-without-cooperative-cancellation")
        #expect(evidence.report["cancelLatencyUntilNativeReturnSeconds"] is NSNull)
    }

    @Test func closedNativeStdinStillLeadsToMeasuredForcedExit() async throws {
        let child = try await cancellationProcessWork { try CancellationChild(mode: "closed-stdin") }
        defer { child.close() }
        let supervisor = NativeProcessCancellation(process: child.process, policy: policy)
        supervisor.begin { child.sendCancellation() }
        let evidence = try await cancellationProcessWork { supervisor.finish() }
        #expect(evidence.processContainmentGatePassed)
        #expect(evidence.terminationPath == "forced-sigkill")
        #expect(!evidence.nativeReturnObserved)
        #expect(evidence.exitStatus == SIGKILL)
        #expect(!child.process.isRunning)
    }

    @Test func aBlockedProtocolSendCannotBlockTheWatchdogOrFinish() async throws {
        let child = try await cancellationProcessWork { try CancellationChild(mode: "ignore") }
        defer { child.close() }
        let sendStarted = DispatchSemaphore(value: 0), releaseSend = DispatchSemaphore(value: 0)
        defer { releaseSend.signal() }
        let supervisor = NativeProcessCancellation(process: child.process, policy: policy)
        supervisor.begin {
            sendStarted.signal()
            releaseSend.wait()
        }
        #expect(try await cancellationProcessWork { sendStarted.wait(timeout: .now() + 1) == .success })
        let evidence = try await cancellationProcessWork { supervisor.finish() }
        #expect(evidence.processContainmentGatePassed)
        #expect(evidence.sendStartedAt != nil)
        #expect(evidence.sendFinishedAt == nil)
        #expect(evidence.exitStatus == SIGKILL)
        #expect(!evidence.cooperativeGatePassed)
    }

    @Test func repeatedCancellationDoesNotResetTheOneAbsoluteDeadline() async throws {
        let child = try await cancellationProcessWork { try CancellationChild(mode: "ignore") }
        defer { child.close() }
        let supervisor = NativeProcessCancellation(process: child.process,
            policy: .init(maximumSeconds: 1.5, forceAfterSeconds: 0.6))
        let sendCompleted = DispatchSemaphore(value: 0)
        let callbackCount = CancellationCallbackCount()
        let began = supervisor.begin {
            callbackCount.record()
            child.sendCancellation()
            sendCompleted.signal()
        }
        let repeated = supervisor.begin {
            callbackCount.record()
            sendCompleted.signal()
        }
        #expect(repeated == began)
        #expect(try await cancellationProcessWork { sendCompleted.wait(timeout: .now() + 1) == .success })
        let evidence = try await cancellationProcessWork { supervisor.finish() }
        let signalAfter = (try #require(evidence.forceAttemptedAt)) - began
        #expect(signalAfter >= 0.6)
        #expect(callbackCount.value == 1)
        #expect(sendCompleted.wait(timeout: .now()) == .timedOut)
        #expect(evidence.processContainmentGatePassed)
    }

    @Test func admissionRemainsHeldUntilTheRealChildHasEnded() async throws {
        let budget = AIResourceBudget(limits: .init(maximumResidentModelBytes: 64))
        let lease = try await budget.acquireLocalInference(residentBytes: 64)
        let child = try await cancellationProcessWork { try CancellationChild(mode: "ignore") }
        defer { child.close() }
        let supervisor = NativeProcessCancellation(process: child.process, policy: policy)
        let next = Task { try await budget.acquireLocalInference(residentBytes: 64) }
        for await state in await budget.stateUpdates() {
            if state.waitingInferences == 1 { break }
        }
        supervisor.begin { child.sendCancellation() }
        for await state in await budget.stateUpdates() {
            #expect(state.activeInferences == 1)
            #expect(state.waitingInferences == 1)
            #expect(state.residentModelBytes == 64)
            break
        }
        let evidence = try await cancellationProcessWork { supervisor.finish() }
        #expect(evidence.processContainmentGatePassed)
        #expect(!child.process.isRunning)
        await budget.release(lease)
        let nextLease = try await next.value
        await budget.release(nextLease)
    }

    @Test func missedDeadlineAndMissingRequestCannotPassTheGates() async throws {
        // Classification remains conservative even if the OS cannot reap the
        // child by the deadline; no synthetic process or timing Go is inferred.
        let evidence = NativeProcessCancellation.Evidence(policy: .init(), nativePID: 123,
            requestedAt: 10, nativeReturnAt: 10.2, nativeReturnCode: "cancelled", confirmedEndAt: 15.1,
            forceAttemptedAt: 14, forceError: 0, sendStartedAt: 10, sendFinishedAt: 10.01,
            exitStatus: SIGKILL, exitedBySignal: true)
        #expect(evidence.terminationPath == "deadline-missed")
        #expect(!evidence.processContainmentGatePassed)
        #expect(!evidence.cooperativeGatePassed)
        #expect(evidence.report["cancelDeadlineMissed"] as? Bool == true)
        try expectSerializable(evidence)

        let child = try await cancellationProcessWork { try CancellationChild(mode: "exit-without-return") }
        defer { child.close() }
        let supervisor = NativeProcessCancellation(process: child.process, policy: policy)
        child.sendCancellation()
        let missing = try await cancellationProcessWork { supervisor.finish() }
        #expect(missing.terminationPath == "no-cancel-request")
        #expect(!missing.processContainmentGatePassed)
        #expect(!missing.cooperativeGatePassed)
        #expect(missing.report["cancelLatencyUntilProcessEndSeconds"] is NSNull)
        try expectSerializable(missing)
    }

    private func expectSerializable(_ evidence: NativeProcessCancellation.Evidence) throws {
        #expect(JSONSerialization.isValidJSONObject(evidence.report))
        let data = try JSONSerialization.data(withJSONObject: evidence.report)
        let restored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(restored["processContainmentGatePassed"] as? Bool == evidence.processContainmentGatePassed)
        #expect(restored["cooperativeGatePassed"] as? Bool == evidence.cooperativeGatePassed)
    }
}

/// Child launch/read/reaping are blocking OS operations. Await them on private
/// queues so these tests leave Swift's cooperative executor free for the rest
/// of the parallel suite. Assertions stay in the calling test's task context.
private func cancellationProcessWork<Value: Sendable>(
    _ work: @escaping @Sendable () throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue(label: "glowroom.cancellation-test.\(UUID().uuidString)", qos: .userInitiated).async {
            do { continuation.resume(returning: try work()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

private final class CancellationCallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Real, model-free processes exercise pipe closure, signal delivery and the
/// Foundation reaper. Python sleeps in its own process; no orphan grandchildren
/// can retain pipes or survive a forced helper termination.
private final class CancellationChild: @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe()

    init(mode: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
        import json, os, signal, sys, time
        mode = sys.argv[1]
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if mode == 'closed-stdin': os.close(0)
        print(json.dumps({'event': 'ready'}), flush=True)
        if mode not in ('ignore', 'closed-stdin'):
            sys.stdin.readline()
            if mode != 'exit-without-return':
                print(json.dumps({'event': 'completed', 'code': 'cancelled'}), flush=True)
            if mode != 'return-then-hang':
                time.sleep(0.05)
                sys.exit(0)
        while True: time.sleep(60)
        """, mode]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Per-descriptor SIGPIPE suppression avoids changing global signal
        // disposition while other Swift Testing suites run in parallel.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CancellationChildError.pipeConfiguration
        }
        try process.run()
        do {
            guard try readEvent() == "ready" else { throw CancellationChildError.notReady }
        } catch { close(); throw error }
    }

    func sendCancellation() {
        try? input.fileHandleForWriting.write(contentsOf: Data("{\"operation\":\"cancel\"}\n{\"operation\":\"shutdown\"}\n".utf8))
    }

    func readEvent() throws -> String {
        var bytes = Data(), byte: UInt8 = 0
        while bytes.count < 4_096 {
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw CancellationChildError.missingEvent }
            if byte == 10 {
                let event = try JSONSerialization.jsonObject(with: bytes) as? [String: String]
                return event?["code"] ?? event?["event"] ?? "invalid"
            }
            bytes.append(byte)
        }
        throw CancellationChildError.missingEvent
    }

    func close() {
        // Normal paths have already been reaped by supervisor.finish(). A
        // second waitUntilExit() stalled the native test host after that
        // confirmation. Only a still-running child needs the cleanup wait;
        // this also retains containment when launch/protocol setup fails.
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
}

private enum CancellationChildError: Error {
    case pipeConfiguration, notReady, missingEvent
}
