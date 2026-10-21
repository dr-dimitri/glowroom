import Foundation
import Testing
@testable import Glowroom

@Suite("Local AI resident admission accounting", .timeLimit(.minutes(1)))
struct AIResourceBudgetTests {
    @Test func invalidAndOversizedResidentRequestsNeverConsumeAdmission() async throws {
        let budget = AIResourceBudget(limits: .init(maximumResidentModelBytes: 64))
        await #expect(throws: AIResourceBudget.AdmissionError.invalidMemoryRequest) {
            _ = try await budget.acquireLocalInference(residentBytes: -1)
        }
        await #expect(throws: AIResourceBudget.AdmissionError.exceedsResidentMemoryLimit) {
            _ = try await budget.acquireLocalInference(residentBytes: 65)
        }
        #expect(await residentState(budget) == .init(activeInferences: 0, waitingInferences: 0, residentModelBytes: 0))
        let legacy = try await budget.acquireLocalInference()
        #expect(await residentState(budget).residentModelBytes == 0)
        await budget.release(legacy)
    }

    @Test func queuedMemoryIsChargedOnlyAtActualGrantAndDuplicateReleaseDoesNotFreeTheNextJob() async throws {
        let budget = AIResourceBudget(limits: .init(maximumResidentModelBytes: 64))
        let first = try await budget.acquireLocalInference(residentBytes: 48)
        let second = Task { try await budget.acquireLocalInference(residentBytes: 64) }
        await waitResident(budget) { $0.waitingInferences == 1 }
        #expect(await residentState(budget).residentModelBytes == 48)
        await budget.release(first)
        let next = try await second.value
        #expect(await residentState(budget) == .init(activeInferences: 1, waitingInferences: 0, residentModelBytes: 64))
        await budget.release(first)
        #expect(await residentState(budget).residentModelBytes == 64)
        await budget.release(next)
        #expect(await residentState(budget).residentModelBytes == 0)
    }

    @Test func cancelledWaiterCannotStrandResidentBytesOrDelayInteractiveWork() async throws {
        let budget = AIResourceBudget(limits: .init(maximumResidentModelBytes: 64))
        let first = try await budget.acquireLocalInference(residentBytes: 48)
        let cancelled = Task { try await budget.acquireLocalInference(priority: .background, residentBytes: 64) }
        await waitResident(budget) { $0.waitingInferences == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        await waitResident(budget) { $0.waitingInferences == 0 }
        #expect(await residentState(budget).residentModelBytes == 48)
        let next = Task { try await budget.acquireLocalInference(residentBytes: 32) }
        await waitResident(budget) { $0.waitingInferences == 1 }
        await budget.release(first)
        let lease = try await next.value
        #expect(await residentState(budget).residentModelBytes == 32)
        await budget.release(lease)
        #expect(await residentState(budget).activeInferences == 0)
    }
}

private func residentState(_ budget: AIResourceBudget) async -> AIResourceBudget.State {
    for await state in await budget.stateUpdates() { return state }
    preconditionFailure("No resource state")
}
private func waitResident(_ budget: AIResourceBudget, until predicate: (AIResourceBudget.State) -> Bool) async {
    for await state in await budget.stateUpdates() { if predicate(state) { return } }
}
