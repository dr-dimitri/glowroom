import Foundation

public enum CatalogLifecycleError: Error, Equatable, Sendable {
    case recoveryRequired
    case invalidAdmission
    case acceptedWriteAlreadyRunning
    case maintenanceAlreadyPending
    case wouldWaitForOwnWrite
    case durableWorkIncomplete
}

/// One small synchronous registry makes UI acceptance atomic with closing the
/// catalog for maintenance. Native work and actor hops run outside this lock.
public final class CatalogLifecycleGate: CatalogLifecycleGating, @unchecked Sendable {
    private enum Startup { case waiting, ready(CatalogStartupAdmission), blocked }
    private enum WritePhase { case registered, running, promoting }
    private struct Write { let session: UUID; let domain: CatalogWriterDomain; var phase: WritePhase }
    private struct Maintenance {
        let admission: CatalogMaintenanceAdmission
        let promotedWrite: UUID?
        var granted = false
        var durableOperation: UUID?
        var continuation: CheckedContinuation<CatalogMaintenanceAdmission, Error>?
    }
    private let owner = UUID()
    private let lock = NSLock()
    private var startup: Startup = .waiting
    private var startupWaiters: [CheckedContinuation<CatalogStartupAdmission, Error>] = []
    private var writes: [UUID: Write] = [:]
    private var maintenance: Maintenance?

    private enum Context {
        @TaskLocal static var write: CatalogAcceptedWriteAdmission?
        @TaskLocal static var exclusive: CatalogMaintenanceAdmission?
    }

    /// Production starts closed and opens only after joint durable recovery.
    /// `false` is for an explicitly isolated store without catalog participants.
    public init(requiresRecovery: Bool = true) {
        if !requiresRecovery {
            startup = .ready(CatalogStartupAdmission(sessionID: UUID(), ownerID: owner, nonce: UUID()))
        }
    }

    public func waitForStartup() async throws -> CatalogStartupAdmission {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            switch startup {
            case .waiting: startupWaiters.append(continuation); lock.unlock()
            case .ready(let session): lock.unlock(); continuation.resume(returning: session)
            case .blocked: lock.unlock(); continuation.resume(throwing: CatalogLifecycleError.recoveryRequired)
            }
        }
    }

    public func registerAcceptedWrite(domain: CatalogWriterDomain,
                                      session: CatalogStartupAdmission) throws -> CatalogAcceptedWriteAdmission {
        try lock.withLock {
            guard case .ready(let active) = startup, session === active, session.ownerID == owner else {
                throw CatalogLifecycleError.recoveryRequired
            }
            guard maintenance == nil else { throw CatalogLifecycleError.maintenanceAlreadyPending }
            let nonce = UUID()
            writes[nonce] = Write(session: session.sessionID, domain: domain, phase: .registered)
            return CatalogAcceptedWriteAdmission(domain: domain, sessionID: session.sessionID,
                ownerID: owner, nonce: nonce, releaseOwnership: { [weak self] in self?.abandonRegistered(nonce) })
        }
    }

    public func withAcceptedWrite<Result: Sendable>(_ admission: CatalogAcceptedWriteAdmission,
                      operation: @Sendable () async throws -> Result) async throws -> Result {
        try lock.withLock {
            try validate(admission)
            guard writes[admission.nonce]?.phase == .registered else {
                throw CatalogLifecycleError.acceptedWriteAlreadyRunning
            }
            writes[admission.nonce]?.phase = .running
        }
        // Caller cancellation never removes a running slot before actual return.
        defer { finishWrite(admission.nonce); withExtendedLifetime(admission) {} }
        return try await Context.$write.withValue(admission) { try await operation() }
    }

    /// Core repositories inherit a validated running capability across actor
    /// hops. The TaskLocal transports authority; the registry verifies it anew.
    public func withRepositoryAccess<Result: Sendable>(domain: CatalogWriterDomain,
                      operation: @Sendable () async throws -> Result) async throws -> Result {
        if let exclusive = Context.exclusive {
            try lock.withLock { try validateExclusive(exclusive) }
            return try await operation()
        }
        if let inherited = Context.write {
            try lock.withLock {
                try validate(inherited)
                guard writes[inherited.nonce]?.phase == .running else {
                    throw CatalogLifecycleError.invalidAdmission
                }
                // Catalog operations intentionally call their editing/metadata
                // participants under the same accepted write, never a new pool.
                guard inherited.domain == domain || inherited.domain == .catalog ||
                      inherited.domain == .backupRestore ||
                      (inherited.domain == .editing && domain == .artifactPublication) else {
                    throw CatalogLifecycleError.invalidAdmission
                }
            }
            return try await operation()
        }
        let session = try await waitForStartup()
        let admission = try registerAcceptedWrite(domain: domain, session: session)
        return try await withAcceptedWrite(admission, operation: operation)
    }

    public func beginMaintenance(_ purpose: CatalogMaintenancePurpose) async throws -> CatalogMaintenanceAdmission {
        if Context.write != nil { throw CatalogLifecycleError.wouldWaitForOwnWrite }
        if Context.exclusive != nil { throw CatalogLifecycleError.maintenanceAlreadyPending }
        return try await requestMaintenance(purpose, promoting: nil)
    }

    public func promoteCurrentAcceptedWrite(to purpose: CatalogMaintenancePurpose) async throws -> CatalogMaintenanceAdmission {
        guard let admission = Context.write else { throw CatalogLifecycleError.invalidAdmission }
        return try await promoteAcceptedWrite(admission, to: purpose)
    }

    public func promoteAcceptedWrite(_ admission: CatalogAcceptedWriteAdmission,
                          to purpose: CatalogMaintenancePurpose) async throws -> CatalogMaintenanceAdmission {
        guard Context.write === admission else { throw CatalogLifecycleError.invalidAdmission }
        return try await requestMaintenance(purpose, promoting: admission)
    }

    private func requestMaintenance(_ purpose: CatalogMaintenancePurpose,
                   promoting admission: CatalogAcceptedWriteAdmission?) async throws -> CatalogMaintenanceAdmission {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let immediate: CatalogMaintenanceAdmission? = try lock.withLock {
                    guard maintenance == nil else { throw CatalogLifecycleError.maintenanceAlreadyPending }
                    if let admission {
                        try validate(admission)
                        guard writes[admission.nonce]?.phase == .running else {
                            throw CatalogLifecycleError.invalidAdmission
                        }
                        writes[admission.nonce]?.phase = .promoting
                    }
                    let cap = CatalogMaintenanceAdmission(purpose: purpose, ownerID: owner, nonce: UUID())
                    let drained = writes.keys.allSatisfy { $0 == admission?.nonce }
                    maintenance = Maintenance(admission: cap, promotedWrite: admission?.nonce,
                        granted: drained, continuation: drained ? nil : continuation)
                    return drained ? cap : nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            } catch { continuation.resume(throwing: error) }
        }
    }

    /// The accepted owner remains responsible for finish after any safe failure.
    /// A durable joint operation additionally requires coordinator completion.
    public func withMaintenance<Result: Sendable>(_ admission: CatalogMaintenanceAdmission,
                      operation: @Sendable () async throws -> Result) async throws -> Result {
        try lock.withLock { try validateExclusive(admission) }
        defer { withExtendedLifetime(admission) {} }
        return try await Context.$exclusive.withValue(admission) { try await operation() }
    }

    public func finishMaintenance(_ admission: CatalogMaintenanceAdmission) async throws {
        try lock.withLock {
            try validateExclusive(admission)
            guard maintenance?.durableOperation == nil else { throw CatalogLifecycleError.durableWorkIncomplete }
            if let promoted = maintenance?.promotedWrite, writes[promoted]?.phase == .promoting {
                // The outer accepted owner may still publish its UI result. It
                // retains its normal registration until actual operation return.
                writes[promoted]?.phase = .running
            }
            maintenance = nil
        }
    }

    // Only the Core joint coordinator can mark durable work or open startup.
    internal func validateRecoveryMaintenance(_ admission: CatalogMaintenanceAdmission) throws {
        try lock.withLock {
            try validateExclusive(admission)
            guard Context.exclusive === admission else { throw CatalogLifecycleError.invalidAdmission }
        }
    }
    internal func requireDurableCompletion(_ admission: CatalogMaintenanceAdmission, operationID: UUID) throws {
        try lock.withLock {
            try validateExclusive(admission)
            guard maintenance?.durableOperation == nil || maintenance?.durableOperation == operationID else {
                throw CatalogLifecycleError.invalidAdmission
            }
            maintenance?.durableOperation = operationID
        }
    }
    internal func durableWorkCompleted(_ admission: CatalogMaintenanceAdmission, operationID: UUID) throws {
        try lock.withLock {
            try validateExclusive(admission)
            guard maintenance?.durableOperation == operationID else { throw CatalogLifecycleError.invalidAdmission }
            maintenance?.durableOperation = nil
        }
    }
    internal func openAfterRecovery() throws -> CatalogStartupAdmission {
        let (session, waiting): (CatalogStartupAdmission, [CheckedContinuation<CatalogStartupAdmission, Error>]) = try lock.withLock {
            guard maintenance == nil, writes.isEmpty else { throw CatalogLifecycleError.durableWorkIncomplete }
            if case .ready(let existing) = startup { return (existing, []) }
            let session = CatalogStartupAdmission(sessionID: UUID(), ownerID: owner, nonce: UUID())
            startup = .ready(session)
            let waiting = startupWaiters; startupWaiters.removeAll()
            return (session, waiting)
        }
        waiting.forEach { $0.resume(returning: session) }
        return session
    }
    /// Bootstrap may close admission when factory IO fails before the Core
    /// coordinator exists. Only successful Core recovery can open it again.
    public func reportStartupFailure() { blockStartup() }
    internal func blockStartup() {
        let waiting = lock.withLock {
            startup = .blocked
            let waiting = startupWaiters; startupWaiters.removeAll(); return waiting
        }
        waiting.forEach { $0.resume(throwing: CatalogLifecycleError.recoveryRequired) }
    }

    private func validate(_ admission: CatalogAcceptedWriteAdmission) throws {
        guard admission.ownerID == owner, let entry = writes[admission.nonce],
              entry.session == admission.sessionID, entry.domain == admission.domain else {
            throw CatalogLifecycleError.invalidAdmission
        }
    }
    private func validateExclusive(_ admission: CatalogMaintenanceAdmission) throws {
        guard admission.ownerID == owner, maintenance?.admission === admission,
              maintenance?.granted == true else { throw CatalogLifecycleError.invalidAdmission }
    }
    private func abandonRegistered(_ nonce: UUID) {
        let wake = lock.withLock { () -> (CheckedContinuation<CatalogMaintenanceAdmission, Error>, CatalogMaintenanceAdmission)? in
            guard writes[nonce]?.phase == .registered else { return nil }
            writes.removeValue(forKey: nonce); return takeDrainedMaintenance()
        }
        if let wake { wake.0.resume(returning: wake.1) }
    }
    private func finishWrite(_ nonce: UUID) {
        let wake = lock.withLock { () -> (CheckedContinuation<CatalogMaintenanceAdmission, Error>, CatalogMaintenanceAdmission)? in
            writes.removeValue(forKey: nonce); return takeDrainedMaintenance()
        }
        if let wake { wake.0.resume(returning: wake.1) }
    }
    /// Called under the lock. Continuations always resume after unlocking.
    private func takeDrainedMaintenance() -> (CheckedContinuation<CatalogMaintenanceAdmission, Error>, CatalogMaintenanceAdmission)? {
        guard var entry = maintenance, !entry.granted,
              writes.keys.allSatisfy({ $0 == entry.promotedWrite }), let continuation = entry.continuation else { return nil }
        entry.granted = true; entry.continuation = nil; maintenance = entry
        return (continuation, entry.admission)
    }
}
