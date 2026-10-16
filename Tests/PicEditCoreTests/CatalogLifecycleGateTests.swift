import Foundation
import Testing
@testable import PicEditCore

private actor LifecycleLatch {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !open { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() { open = true; let values = waiting; waiting.removeAll(); values.forEach { $0.resume() } }
}

@Suite("Joint catalog lifecycle")
struct CatalogLifecycleGateTests {
    private func waitForFence(_ gate: CatalogLifecycleGate, _ session: CatalogStartupAdmission) async throws {
        for _ in 0..<20_000 {
            do { _ = try gate.registerAcceptedWrite(domain: .editing, session: session) }
            catch CatalogLifecycleError.maintenanceAlreadyPending { return }
            await Task.yield()
        }
        Issue.record("Maintenance never closed admission")
        throw CatalogLifecycleError.maintenanceAlreadyPending
    }

    @Test func startupFailureAndRecoveryDoNotPublishEarly() async throws {
        let gate = CatalogLifecycleGate()
        let observer = Task { try await gate.waitForStartup() }
        gate.blockStartup()
        await #expect(throws: CatalogLifecycleError.recoveryRequired) { try await observer.value }
        let session = try gate.openAfterRecovery()
        #expect(try await gate.waitForStartup() === session)
        let admission = try gate.registerAcceptedWrite(domain: .editing, session: session)
        let result = try await gate.withAcceptedWrite(admission) { 7 }
        #expect(result == 7)
    }

    @Test func foreignAndRepeatedAdmissionsCannotExecute() async throws {
        let a = CatalogLifecycleGate(requiresRecovery: false)
        let b = CatalogLifecycleGate(requiresRecovery: false)
        let aSession = try await a.waitForStartup()
        #expect(throws: CatalogLifecycleError.recoveryRequired) {
            try b.registerAcceptedWrite(domain: .editing, session: aSession)
        }
        let cap = try a.registerAcceptedWrite(domain: .editing, session: aSession)
        await #expect(throws: CatalogLifecycleError.invalidAdmission) {
            try await b.withAcceptedWrite(cap) { 1 }
        }
        #expect(try await a.withAcceptedWrite(cap) { 2 } == 2)
        await #expect(throws: CatalogLifecycleError.invalidAdmission) {
            try await a.withAcceptedWrite(cap) { 3 }
        }
    }

    @Test func registeredAndCanceledWorkDrainsOnlyAfterActualReturn() async throws {
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let session = try await gate.waitForStartup()
        let accepted = try gate.registerAcceptedWrite(domain: .editing, session: session)
        let native = LifecycleLatch()
        let entered = LifecycleLatch()
        let maintenance = Task { try await gate.beginMaintenance(.backup(UUID())) }
        try await waitForFence(gate, session)
        // Work accepted before maintenance still starts and drains normally.
        let writer = Task {
            try await gate.withAcceptedWrite(accepted) {
                await entered.release()
                await native.wait() // Deliberately ignores task cancellation.
                // Cross-actor nested access must not register behind its drainer.
                return try await gate.withRepositoryAccess(domain: .artifactPublication) { 42 }
            }
        }
        await entered.wait(); writer.cancel()
        #expect(throws: CatalogLifecycleError.maintenanceAlreadyPending) {
            try gate.registerAcceptedWrite(domain: .editing, session: session)
        }
        await native.release()
        #expect(try await writer.value == 42)
        let exclusive = try await maintenance.value
        try await gate.finishMaintenance(exclusive)
        _ = try gate.registerAcceptedWrite(domain: .editing, session: session)
    }

    @Test func ownMaintenanceRejectsAndExplicitPromotionDrainsOthers() async throws {
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let session = try await gate.waitForStartup()
        let first = try gate.registerAcceptedWrite(domain: .catalog, session: session)
        let second = try gate.registerAcceptedWrite(domain: .catalog, session: session)
        let secondEntered = LifecycleLatch()
        let secondMayPromote = LifecycleLatch()
        let firstTask = Task {
            try await gate.withAcceptedWrite(first) {
                await secondEntered.wait()
                await #expect(throws: CatalogLifecycleError.wouldWaitForOwnWrite) {
                    try await gate.beginMaintenance(.coordination(UUID()))
                }
                let cap = try await gate.promoteCurrentAcceptedWrite(to: .coordination(UUID()))
                let result = try await gate.withMaintenance(cap) {
                    try await gate.withRepositoryAccess(domain: .photoMetadata) { 12 }
                }
                try await gate.finishMaintenance(cap)
                return result
            }
        }
        let secondTask = Task {
            try await gate.withAcceptedWrite(second) {
                await secondEntered.release(); await secondMayPromote.wait()
                await #expect(throws: CatalogLifecycleError.maintenanceAlreadyPending) {
                    try await gate.promoteCurrentAcceptedWrite(to: .coordination(UUID()))
                }
            }
        }
        try await waitForFence(gate, session)
        await secondMayPromote.release()
        try await secondTask.value
        #expect(try await firstTask.value == 12)
    }

    @Test func durableFenceNeedsExactCoordinatorCompletion() async throws {
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let cap = try await gate.beginMaintenance(.coordination(UUID()))
        let operation = UUID()
        try gate.requireDurableCompletion(cap, operationID: operation)
        await #expect(throws: CatalogLifecycleError.durableWorkIncomplete) { try await gate.finishMaintenance(cap) }
        #expect(throws: CatalogLifecycleError.invalidAdmission) {
            try gate.durableWorkCompleted(cap, operationID: UUID())
        }
        try gate.durableWorkCompleted(cap, operationID: operation)
        try await gate.finishMaintenance(cap)
        await #expect(throws: CatalogLifecycleError.invalidAdmission) {
            try await gate.withMaintenance(cap) { 1 }
        }
    }

    @Test func inheritedAdmissionCannotChangeItsDomain() async throws {
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let session = try await gate.waitForStartup()
        let cap = try gate.registerAcceptedWrite(domain: .photoMetadata, session: session)
        _ = try await gate.withAcceptedWrite(cap) {
            await #expect(throws: CatalogLifecycleError.invalidAdmission) {
                try await gate.withRepositoryAccess(domain: .editing) { 1 }
            }
        }
    }
}
