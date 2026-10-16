import Foundation

public enum ArtifactAdmissionKind: Equatable, Sendable { case retainedMemory, codec, transfer }
public enum ArtifactResourcePriority: Int, Sendable { case background, interactive }
public enum ArtifactResourceError: LocalizedError, Equatable, Sendable {
    case invalidRequest, invalidOwnership, capacityExceeded, queueFull

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Die Bildverarbeitung kann mit dieser Anfrage nicht sicher gestartet werden. Bitte starte die Anfrage erneut."
        case .invalidOwnership:
            return "Die benötigten Bilddaten sind für diese Anfrage nicht mehr verfügbar. Bitte starte die Anfrage erneut."
        case .capacityExceeded:
            return "Für die Bildverarbeitung ist momentan nicht genügend freier Bildspeicher verfügbar. Bitte versuche es nach Abschluss der laufenden Arbeit erneut."
        case .queueFull:
            return "Die Bildverarbeitung ist momentan belegt. Bitte versuche es nach Abschluss der laufenden Arbeit erneut."
        }
    }
}

/// Memory stays charged until its final real owner (bitmap/provider/cache) dies.
/// A reference copy shares this capability; a copied allocation needs a new one.
public final class ArtifactMemoryReservation: Sendable {
    public let byteCount: Int64
    fileprivate let owner: UUID
    fileprivate let id: UUID
    private let release: @Sendable () -> Void
    fileprivate init(byteCount:Int64,owner:UUID,id:UUID,release:@escaping @Sendable () -> Void) {
        self.byteCount = byteCount; self.owner = owner; self.id = id; self.release = release
    }
    deinit { release() }
}
/// Keep this strong through the actual synchronous/native return. Cancellation
/// of an observer never explicitly releases a running operation's slot/bytes.
public final class ArtifactResourceLease: Sendable {
    public let kind: ArtifactAdmissionKind
    public let reservedBytes: Int64
    fileprivate let owner: UUID
    fileprivate let id: UUID
    private let release: @Sendable () -> Void
    fileprivate init(kind:ArtifactAdmissionKind,bytes:Int64,owner:UUID,id:UUID,release:@escaping @Sendable () -> Void) {
        self.kind = kind; reservedBytes = bytes; self.owner = owner; self.id = id; self.release = release
    }
    deinit { release() }
}
public protocol ArtifactResourceAdmitting: Actor {
    /// New bytes include ALL additional buffers/scratch for this phase before
    /// allocation, including caller-owned inputs not already represented below.
    /// Bytes are charged immediately, even while the bounded slot queue waits.
    /// No operation may grow its reservation while holding a codec/transfer slot.
    func acquire(kind:ArtifactAdmissionKind,bytes:Int64,priority:ArtifactResourcePriority,
                 retaining:[ArtifactMemoryReservation]) async throws -> ArtifactResourceLease
    /// Split live output memory out of the operation's ALREADY charged peak.
    /// Scratch is released only when operation ownership actually ends. The
    /// result must be retained by the real buffer/CGDataProvider/cache owner.
    func retain(bytes:Int64,from lease:ArtifactResourceLease) async throws -> ArtifactMemoryReservation
    func validate(_ memory:ArtifactMemoryReservation,minimumBytes:Int64) async throws
}

/// One injected owner for artifact raster/codec bytes, not a worker pool and not
/// another model budget. Existing AIResourceBudget remains model-only. Charged
/// owned buffers/scratch are bounded; this does not claim a process RSS/GPU cap.
public actor ArtifactResourceOwner: ArtifactResourceAdmitting {
    public struct Limits: Sendable {
        public let maximumBytes:Int64
        public let maximumCodecs = 1
        public let maximumTransfers = 2
        public let maximumPendingCodecs = 1
        public let maximumPendingTransfers = 2
        public let maximumOwnerships = 4_096
        public init(maximumBytes:Int64 = 536_870_912) throws {
            guard maximumBytes > 0, maximumBytes <= 536_870_912 else { throw ArtifactResourceError.invalidRequest }
            self.maximumBytes = maximumBytes
        }
    }
    public struct State: Equatable, Sendable {
        public let chargedBytes:Int64
        public let runningCodecs:Int, runningTransfers:Int
        public let pendingCodecs:Int, pendingTransfers:Int
        public let retainedAllocations:Int
    }
    private struct Operation {
        let kind:ArtifactAdmissionKind
        let bytes:Int64
        let retaining:[ArtifactMemoryReservation]
        var active:Bool
        var outputs:Set<UUID> = []
    }
    private struct Memory { let bytes:Int64; var parent:UUID? }
    private struct Waiter {
        let id:UUID
        let priority:ArtifactResourcePriority
        let continuation:CheckedContinuation<ArtifactResourceLease,Error>
    }
    public nonisolated let limits:Limits
    private let owner = UUID()
    private var charged:Int64 = 0
    private var codecs = 0, transfers = 0
    private var operations:[UUID:Operation] = [:]
    private var memory:[UUID:Memory] = [:]
    private var codecWaiters:[Waiter] = [], transferWaiters:[Waiter] = []
    public init(limits:Limits) { self.limits = limits }

    public func acquire(kind:ArtifactAdmissionKind,bytes:Int64,priority:ArtifactResourcePriority = .interactive,
                        retaining:[ArtifactMemoryReservation] = []) async throws -> ArtifactResourceLease {
        try Task.checkCancellation()
        guard bytes >= 0, kind != .retainedMemory || bytes > 0,
              retaining.count <= limits.maximumOwnerships else { throw ArtifactResourceError.invalidRequest }
        guard operations.count + memory.count < limits.maximumOwnerships else { throw ArtifactResourceError.queueFull }
        // Validate every owner and keep each same-owner nonce exactly once.
        var ids = Set<UUID>(), unique:[ArtifactMemoryReservation] = []
        for value in retaining {
            try validate(value,minimumBytes:0)
            if ids.insert(value.id).inserted { unique.append(value) }
        }
        guard bytes <= limits.maximumBytes-charged else { throw ArtifactResourceError.capacityExceeded }
        let available = kind == .retainedMemory || (kind == .codec ? codecs < limits.maximumCodecs : transfers < limits.maximumTransfers)
        if !available {
            guard kind == .codec ? codecWaiters.count < limits.maximumPendingCodecs : transferWaiters.count < limits.maximumPendingTransfers else { throw ArtifactResourceError.queueFull }
        }
        let id = UUID()
        operations[id] = Operation(kind:kind,bytes:bytes,retaining:unique,active:available)
        charged += bytes
        if available {
            increment(kind)
            return lease(id)
        }
        let granted:ArtifactResourceLease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    closeOperation(id); continuation.resume(throwing:CancellationError()); return
                }
                let waiter = Waiter(id:id,priority:priority,continuation:continuation)
                if kind == .codec { codecWaiters.append(waiter) } else { transferWaiters.append(waiter) }
            }
        } onCancel: { Task { await self.cancelWaiting(id) } }
        // Cancellation can race the actual grant. Return its counted resources
        // exactly once before throwing, rather than stranding a slot.
        if Task.isCancelled { closeOperation(id); throw CancellationError() }
        return granted
    }
    public func retain(bytes:Int64,from lease:ArtifactResourceLease) throws -> ArtifactMemoryReservation {
        guard lease.owner == owner, var operation = operations[lease.id], operation.active,
              bytes > 0, operations.count + memory.count < limits.maximumOwnerships else { throw ArtifactResourceError.invalidOwnership }
        let retained = operation.outputs.reduce(Int64(0)) { $0 + (memory[$1]?.bytes ?? 0) }
        guard bytes <= operation.bytes-retained else { throw ArtifactResourceError.capacityExceeded }
        let id = UUID(); memory[id] = Memory(bytes:bytes,parent:lease.id)
        operation.outputs.insert(id); operations[lease.id] = operation
        return ArtifactMemoryReservation(byteCount:bytes,owner:owner,id:id) { [weak self] in
            Task { await self?.releaseMemory(id) }
        }
    }
    public func validate(_ value:ArtifactMemoryReservation,minimumBytes:Int64) throws {
        guard minimumBytes >= 0, value.owner == owner, let record = memory[value.id],
              record.bytes == value.byteCount, record.bytes >= minimumBytes else { throw ArtifactResourceError.invalidOwnership }
    }
    public func state() -> State {
        State(chargedBytes:charged,runningCodecs:codecs,runningTransfers:transfers,
              pendingCodecs:codecWaiters.count,pendingTransfers:transferWaiters.count,retainedAllocations:memory.count)
    }
    private func lease(_ id:UUID) -> ArtifactResourceLease {
        let value = operations[id]!
        return ArtifactResourceLease(kind:value.kind,bytes:value.bytes,owner:owner,id:id) { [weak self] in
            Task { await self?.closeOperation(id) }
        }
    }
    private func increment(_ kind:ArtifactAdmissionKind) {
        if kind == .codec { codecs += 1 }; if kind == .transfer { transfers += 1 }
    }
    private func closeOperation(_ id:UUID) {
        guard let operation = operations.removeValue(forKey:id) else { return }
        var retained:Int64 = 0
        for output in operation.outputs {
            guard var value = memory[output] else { continue }
            retained += value.bytes; value.parent = nil; memory[output] = value
        }
        charged -= operation.bytes-retained
        if operation.active {
            if operation.kind == .codec { codecs -= 1 }; if operation.kind == .transfer { transfers -= 1 }
        }
        // Destroying the retained input list merely enqueues their own release;
        // charging may stay conservatively high until that bookkeeping runs.
        grantWaiting(kind:operation.kind)
    }
    private func releaseMemory(_ id:UUID) {
        guard let value = memory.removeValue(forKey:id) else { return }
        if let parent = value.parent, operations[parent] != nil {
            operations[parent]?.outputs.remove(id) // still covered by phase peak
        } else { charged -= value.bytes }
    }
    private func cancelWaiting(_ id:UUID) {
        if let index = codecWaiters.firstIndex(where:{$0.id == id}) {
            let waiter = codecWaiters.remove(at:index); closeOperation(id)
            waiter.continuation.resume(throwing:CancellationError())
        } else if let index = transferWaiters.firstIndex(where:{$0.id == id}) {
            let waiter = transferWaiters.remove(at:index); closeOperation(id)
            waiter.continuation.resume(throwing:CancellationError())
        }
        // A granted/running operation stays owned by its actual native caller.
    }
    private func grantWaiting(kind:ArtifactAdmissionKind) {
        if kind == .codec, codecs < limits.maximumCodecs, !codecWaiters.isEmpty {
            let index = codecWaiters.firstIndex(where:{$0.priority == .interactive}) ?? 0
            let waiter = codecWaiters.remove(at:index)
            guard operations[waiter.id] != nil else { return }
            operations[waiter.id]?.active = true; codecs += 1
            waiter.continuation.resume(returning:lease(waiter.id))
        } else if kind == .transfer, transfers < limits.maximumTransfers, !transferWaiters.isEmpty {
            let index = transferWaiters.firstIndex(where:{$0.priority == .interactive}) ?? 0
            let waiter = transferWaiters.remove(at:index)
            guard operations[waiter.id] != nil else { return }
            operations[waiter.id]?.active = true; transfers += 1
            waiter.continuation.resume(returning:lease(waiter.id))
        }
    }
}
