import Darwin
import Foundation

/// Developer-evaluator containment for one already launched helper process.
/// A native cancellation return and a confirmed process exit are independent
/// observations. Neither a timeout nor a successful kill releases admission;
/// the caller must retain its resource lease until `finish()` returns.
final class NativeProcessCancellation: @unchecked Sendable {
    struct Policy: Equatable, Sendable {
        let maximumSeconds: Double
        let forceAfterSeconds: Double

        init(maximumSeconds: Double = 5, forceAfterSeconds: Double = 4) {
            precondition(maximumSeconds.isFinite && maximumSeconds > 0)
            precondition(forceAfterSeconds.isFinite && forceAfterSeconds > 0 && forceAfterSeconds < maximumSeconds)
            self.maximumSeconds = maximumSeconds
            self.forceAfterSeconds = forceAfterSeconds
        }
    }

    struct Evidence: Sendable {
        let policy: Policy
        let nativePID: Int32
        let requestedAt: Double?
        let nativeReturnAt: Double?
        let nativeReturnCode: String?
        let confirmedEndAt: Double
        let forceAttemptedAt: Double?
        let forceError: Int32?
        let sendStartedAt: Double?
        let sendFinishedAt: Double?
        let exitStatus: Int32
        let exitedBySignal: Bool

        var nativeReturnObserved: Bool { nativeReturnAt != nil }
        var cancelLatencyUntilNativeReturnSeconds: Double? { latency(until: nativeReturnAt) }
        var cancelLatencyUntilProcessEndSeconds: Double? { latency(until: confirmedEndAt) }
        var processContainmentGatePassed: Bool {
            guard let elapsed = cancelLatencyUntilProcessEndSeconds else { return false }
            return elapsed <= policy.maximumSeconds
        }
        var cooperativeGatePassed: Bool {
            guard let elapsed = cancelLatencyUntilNativeReturnSeconds else { return false }
            return nativeReturnCode == "cancelled" && elapsed <= policy.maximumSeconds &&
                processContainmentGatePassed && forceAttemptedAt == nil && !exitedBySignal && exitStatus == 0
        }
        var terminationPath: String {
            guard requestedAt != nil else { return "no-cancel-request" }
            guard cancelLatencyUntilProcessEndSeconds != nil else { return "process-ended-before-cancel" }
            if !processContainmentGatePassed { return "deadline-missed" }
            if forceAttemptedAt != nil { return forceError == 0 ? "forced-sigkill" : "force-sigkill-failed" }
            return cooperativeGatePassed ? "cooperative" : "process-exit-without-cooperative-cancellation"
        }

        /// Missing measurements remain null in serialized evidence. A forced
        /// exit can establish containment, but never native cooperative return.
        var report: [String: Any] {
            ["clock": "mach_continuous_time includes sleep",
             "nativePID": Int(nativePID),
             "maximumCancelSeconds": policy.maximumSeconds,
             "forceTerminationAfterSeconds": policy.forceAfterSeconds,
             "cancelRequestedAtContinuousSeconds": requestedAt.map { $0 as Any } ?? NSNull(),
             "nativeReturnObserved": nativeReturnObserved,
             "nativeReturnCode": nativeReturnCode.map { $0 as Any } ?? NSNull(),
             "cancelLatencyUntilNativeReturnSeconds": cancelLatencyUntilNativeReturnSeconds.map { $0 as Any } ?? NSNull(),
             "cancelLatencyUntilProcessEndSeconds": cancelLatencyUntilProcessEndSeconds.map { $0 as Any } ?? NSNull(),
             "confirmedProcessEndAtContinuousSeconds": confirmedEndAt,
             "confirmedProcessEnded": true,
             "processEndConfirmation": "Foundation.Process.waitUntilExit returned",
             "forcedTerminationAttempted": forceAttemptedAt != nil,
             "forceSignal": forceAttemptedAt.map { _ in SIGKILL as Any } ?? NSNull(),
             "forceSignalElapsedSeconds": latency(until: forceAttemptedAt).map { $0 as Any } ?? NSNull(),
             "forceSignalErrno": forceError.map { Int($0) as Any } ?? NSNull(),
             "cancelSendStartedElapsedSeconds": latency(until: sendStartedAt).map { $0 as Any } ?? NSNull(),
             "cancelSendFinishedElapsedSeconds": latency(until: sendFinishedAt).map { $0 as Any } ?? NSNull(),
             "nativeExitStatus": Int(exitStatus),
             "nativeTerminationReason": exitedBySignal ? "uncaught-signal" : "exit",
             "terminationPath": terminationPath,
             "cancelDeadlineMissed": requestedAt != nil && !processContainmentGatePassed,
             "cooperativeGatePassed": cooperativeGatePassed,
             "processContainmentGatePassed": processContainmentGatePassed]
        }

        private func latency(until end: Double?) -> Double? {
            guard let requestedAt, let end, end >= requestedAt else { return nil }
            return end - requestedAt
        }
    }

    private let process: Process
    private let policy: Policy
    private let condition = NSCondition()
    private var requestedAt: Double?
    private var nativeReturnAt: Double?
    private var nativeReturnCode: String?
    private var confirmedEndAt: Double?
    private var forceAttemptedAt: Double?
    private var forceError: Int32?
    private var sendStartedAt: Double?
    private var sendFinishedAt: Double?

    init(process: Process, policy: Policy = Policy()) {
        precondition(process.processIdentifier > 0, "Launch the helper before creating its cancellation supervisor")
        self.process = process
        self.policy = policy
        // This sole observer uses Foundation's own reaper; a competing raw
        // waitpid could consume the child status before Process observes it.
        startControlThread("reaper") { [self] in
            process.waitUntilExit()
            let ended = Self.continuousNow() // Before pipe draining or archive I/O.
            condition.lock()
            confirmedEndAt = ended
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Starts the watchdog before scheduling protocol I/O. The callback must
    /// send cancel and shutdown; a blocked stdin must not block containment.
    /// Repeated requests preserve the first request's absolute deadline.
    @discardableResult
    func begin(sendCancel: @escaping @Sendable () -> Void) -> Double {
        condition.lock()
        if let requestedAt { condition.unlock(); return requestedAt }
        let began = Self.continuousNow()
        requestedAt = began
        condition.unlock()
        startControlThread("watchdog") { [self] in watchForExit(requestedAt: began) }
        startControlThread("sender") { [self] in
            condition.lock()
            sendStartedAt = Self.continuousNow()
            condition.unlock()
            sendCancel() // Never hold the state lock around potentially blocked I/O.
            condition.lock()
            sendFinishedAt = Self.continuousNow()
            condition.broadcast()
            condition.unlock()
        }
        return began
    }

    /// Call only for the matching operation's completed event, including error
    /// codes other than cancelled. A later event cannot replace the first one.
    func noteNativeReturn(code: String) {
        let observed = Self.continuousNow()
        condition.lock()
        if nativeReturnAt == nil {
            nativeReturnAt = observed
            nativeReturnCode = code
        }
        condition.unlock()
    }

    /// Does not return while the child is alive, even after a missed deadline.
    /// Protocol send completion and log draining are deliberately not awaited.
    func finish() -> Evidence {
        condition.lock()
        while confirmedEndAt == nil { condition.wait() }
        defer { condition.unlock() }
        return Evidence(policy: policy, nativePID: process.processIdentifier, requestedAt: requestedAt,
                        nativeReturnAt: nativeReturnAt, nativeReturnCode: nativeReturnCode,
                        confirmedEndAt: confirmedEndAt!, forceAttemptedAt: forceAttemptedAt,
                        forceError: forceError, sendStartedAt: sendStartedAt, sendFinishedAt: sendFinishedAt,
                        exitStatus: process.terminationStatus, exitedBySignal: process.terminationReason == .uncaughtSignal)
    }

    private func watchForExit(requestedAt: Double) {
        let forceAt = requestedAt + policy.forceAfterSeconds
        condition.lock()
        defer { condition.unlock() }
        while confirmedEndAt == nil {
            let remaining = forceAt - Self.continuousNow()
            if remaining <= 0, forceAttemptedAt == nil, process.isRunning {
                forceAttemptedAt = Self.continuousNow()
                forceError = Darwin.kill(process.processIdentifier, SIGKILL) == 0 ? 0 : errno
            }
            // Bounded waits recheck continuous time after sleep or wall-clock
            // adjustments. The deadline is never reset by another caller.
            let waitSeconds = remaining > 0 ? min(remaining, 0.1) : 0.1
            _ = condition.wait(until: Date(timeIntervalSinceNow: waitSeconds))
        }
    }

    private func startControlThread(_ role: String, work: @escaping @Sendable () -> Void) {
        // The evaluator admits only one helper. Its three bounded control/I/O
        // threads must not wait behind unrelated work in a shared GCD pool;
        // they do not execute inference or create another model worker pool.
        let thread = Thread(block: work)
        thread.name = "picedit.evaluation.\(process.processIdentifier).\(role)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private static func continuousNow() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
