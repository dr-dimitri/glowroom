import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Termination drains accepted metadata independently", .timeLimit(.minutes(1)))
@MainActor
struct PhotoMetadataTerminationTests {
    @Test func metadataFailureStillWaitsForCatalogAndEditsAfterCallerCancellation() async throws {
        let catalog = MetadataTerminationGate(), edits = MetadataTerminationGate(), metadata = MetadataTerminationGate()
        var finished = false
        let task = Task {
            let value = await AppDelegate.finishSaving(catalog: { await catalog.wait() }, edits: { await edits.wait() }, metadata: { await metadata.wait() })
            finished = true
            return value
        }
        defer { catalog.release(true); edits.release(true); metadata.release(false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(catalog.started && edits.started && metadata.started) {
            guard ContinuousClock.now < deadline else { throw ImageAnalysisError.providerFailure }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel(); metadata.release(false); await Task.yield()
        #expect(!finished)
        catalog.release(true); await Task.yield(); #expect(!finished)
        edits.release(true)
        #expect(!(await task.value))
        #expect(catalog.finished && edits.finished && metadata.finished)
    }
}
@MainActor private final class MetadataTerminationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private(set) var started = false
    private(set) var finished = false
    func wait() async -> Bool {
        started = true; defer { finished = true }
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ result: Bool) { self.result = result; continuation?.resume(returning: result); continuation = nil }
}
