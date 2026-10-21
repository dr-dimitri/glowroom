import Foundation
import Testing
@testable import GlowroomCore

@Suite("Shared artifact resource ownership and actual work limits")
struct ArtifactResourceOwnerTests {
    @Test func peakBytesAreChargedWhileTheOneCodecWaitsAndQueueIsBounded() async throws {
        let owner = ArtifactResourceOwner(limits:try .init(maximumBytes:1_000))
        var first:ArtifactResourceLease? = try await owner.acquire(kind:.codec,bytes:400)
        #expect(first != nil)
        let pending = Task { try await owner.acquire(kind:.codec,bytes:500) }
        try await resourceWait { await owner.state().pendingCodecs == 1 }
        #expect(await owner.state().chargedBytes == 900)
        await resourceError(.queueFull) { _ = try await owner.acquire(kind:.codec,bytes:1) }
        await resourceError(.capacityExceeded) { _ = try await owner.acquire(kind:.retainedMemory,bytes:101) }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Canceled waiter should not retain a grant") }
        catch { #expect(error is CancellationError) }
        try await resourceWait { await owner.state().chargedBytes == 400 }
        #expect(await owner.state().runningCodecs == 1)
        first = nil
        try await resourceWait { await owner.state().chargedBytes == 0 }
    }
    @Test func outputMemorySurvivesOperationButScratchAndSlotDoNot() async throws {
        let owner = ArtifactResourceOwner(limits:try .init(maximumBytes:1_000))
        var operation:ArtifactResourceLease? = try await owner.acquire(kind:.codec,bytes:900)
        var output:ArtifactMemoryReservation? = try await owner.retain(bytes:200,from:try #require(operation))
        #expect(await owner.state().chargedBytes == 900)
        operation = nil
        try await resourceWait { await owner.state().chargedBytes == 200 }
        #expect(await owner.state().runningCodecs == 0)
        try await owner.validate(try #require(output),minimumBytes:200)
        await resourceError(.capacityExceeded) { _ = try await owner.acquire(kind:.codec,bytes:801) }
        output = nil
        try await resourceWait { await owner.state().chargedBytes == 0 }
    }
    @Test func duplicateBorrowedOwnershipIsCountedOnceAndHeldUntilActualWorkEnds() async throws {
        let owner = ArtifactResourceOwner(limits:try .init(maximumBytes:1_000))
        var source:ArtifactMemoryReservation? = try await resident(owner,bytes:256)
        let borrowed = try #require(source)
        var operation:ArtifactResourceLease? = try await owner.acquire(kind:.codec,bytes:128,retaining:[borrowed,borrowed])
        #expect(await owner.state().chargedBytes == 384)
        #expect(operation != nil)
        // The source's own allocation is not charged again for each reference.
        try await owner.validate(borrowed,minimumBytes:256)
        await resourceError(.invalidOwnership) { try await owner.validate(borrowed,minimumBytes:257) }
        let foreign = ArtifactResourceOwner(limits:try .init(maximumBytes:1_000))
        await resourceError(.invalidOwnership) { _ = try await foreign.acquire(kind:.codec,bytes:1,retaining:[borrowed]) }
        source = nil; operation = nil
        // `borrowed` is still a real owner here, not a permission to release early.
        try await resourceWait { await owner.state().chargedBytes == 256 }
        withExtendedLifetime(borrowed) {}
    }
    @Test func canceledNoncooperativeWorkKeepsCodecUntilActualReturn() async throws {
        let owner = ArtifactResourceOwner(limits:try .init(maximumBytes:1_000))
        let actualGate = ArtifactWorkGate(), nextGate = ArtifactWorkGate()
        let actual = Task {
            let lease = try await owner.acquire(kind:.codec,bytes:300)
            await actualGate.wait()
            withExtendedLifetime(lease) {}
        }
        try await resourceWait { await actualGate.entered }
        actual.cancel()
        let next = Task {
            let lease = try await owner.acquire(kind:.codec,bytes:400)
            await nextGate.wait()
            withExtendedLifetime(lease) {}
        }
        try await resourceWait { await owner.state().pendingCodecs == 1 }
        #expect(await owner.state().chargedBytes == 700)
        #expect(await owner.state().runningCodecs == 1)
        #expect(await nextGate.entered == false)
        await actualGate.finish(); try await actual.value
        try await resourceWait { await nextGate.entered }
        #expect(await owner.state().runningCodecs == 1)
        await nextGate.finish(); try await next.value
        try await resourceWait { await owner.state().chargedBytes == 0 }
    }
    @Test func twoTransfersCanOverlapOneCodecAndTransferWaitersRemainBounded() async throws {
        let owner = ArtifactResourceOwner(limits:try .init(maximumBytes:1_000))
        var first:ArtifactResourceLease? = try await owner.acquire(kind:.transfer,bytes:100)
        var second:ArtifactResourceLease? = try await owner.acquire(kind:.transfer,bytes:100)
        var codec:ArtifactResourceLease? = try await owner.acquire(kind:.codec,bytes:100)
        #expect(first != nil && second != nil && codec != nil)
        let a = Task { try await owner.acquire(kind:.transfer,bytes:100) }
        let b = Task { try await owner.acquire(kind:.transfer,bytes:100) }
        try await resourceWait { await owner.state().pendingTransfers == 2 }
        #expect(await owner.state().runningTransfers == 2)
        #expect(await owner.state().runningCodecs == 1)
        #expect(await owner.state().chargedBytes == 500)
        await resourceError(.queueFull) { _ = try await owner.acquire(kind:.transfer,bytes:1) }
        a.cancel(); b.cancel()
        for task in [a,b] {
            do { _ = try await task.value; Issue.record("Expected canceled transfer") }
            catch { #expect(error is CancellationError) }
        }
        first = nil; second = nil; codec = nil
        try await resourceWait { await owner.state().chargedBytes == 0 }
    }
    @Test func invalidRequestsAndOversizedRetainsNeverChangeAccounting() async throws {
        #expect(throws:ArtifactResourceError.invalidRequest) { _ = try ArtifactResourceOwner.Limits(maximumBytes:536_870_913) }
        let owner = ArtifactResourceOwner(limits:try .init(maximumBytes:1_000))
        await resourceError(.invalidRequest) { _ = try await owner.acquire(kind:.codec,bytes:-1) }
        await resourceError(.capacityExceeded) { _ = try await owner.acquire(kind:.codec,bytes:Int64.max) }
        var phase:ArtifactResourceLease? = try await owner.acquire(kind:.codec,bytes:100)
        let lease = try #require(phase)
        await resourceError(.capacityExceeded) { _ = try await owner.retain(bytes:101,from:lease) }
        #expect(await owner.state().chargedBytes == 100)
        phase = nil
        withExtendedLifetime(lease) {}
    }
    private func resident(_ owner:ArtifactResourceOwner,bytes:Int64) async throws -> ArtifactMemoryReservation {
        let phase = try await owner.acquire(kind:.retainedMemory,bytes:bytes)
        return try await owner.retain(bytes:bytes,from:phase)
    }
}
private actor ArtifactWorkGate {
    private(set) var entered = false
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}
private func resourceWait(_ condition:() async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by:.seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw ArtifactResourceError.invalidRequest }
        await Task.yield()
    }
}
private func resourceError(_ expected:ArtifactResourceError,_ body:() async throws -> Void) async {
    do { try await body(); Issue.record("Expected \(expected)") }
    catch { #expect(error as? ArtifactResourceError == expected) }
}
