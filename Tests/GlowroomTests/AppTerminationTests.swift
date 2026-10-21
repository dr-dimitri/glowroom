import Testing
@testable import Glowroom

@Suite("Concurrent termination persistence")
@MainActor
struct AppTerminationTests {
    @Test(arguments: [true, false])
    func failureAndCallerCancellationStillWaitForBothStores(catalogFails: Bool) async throws {
        let catalog = TerminationSaveGate()
        let edits = TerminationSaveGate()
        var finished = false
        let save = Task {
            let result = await AppDelegate.finishSaving(catalog: { await catalog.save() },
                                                      edits: { await edits.save() })
            finished = true
            return result
        }
        defer { catalog.release(false); edits.release(false) }
        // Both stores must start before either is released. A sequential
        // implementation times out here even when it eventually saves both.
        try await waitUntil { catalog.started && edits.started }
        save.cancel()
        let failing = catalogFails ? catalog : edits
        let pending = catalogFails ? edits : catalog
        failing.release(false)
        try await waitUntil { failing.finished }
        #expect(!finished)
        pending.release(true)
        #expect(!(await save.value))
        #expect(catalog.finished && edits.finished)
    }

    @Test
    func successRequiresBothStoresToFinish() async throws {
        let catalog = TerminationSaveGate()
        let edits = TerminationSaveGate()
        var finished = false
        let save = Task {
            let result = await AppDelegate.finishSaving(catalog: { await catalog.save() },
                                                      edits: { await edits.save() })
            finished = true
            return result
        }
        defer { catalog.release(false); edits.release(false) }
        try await waitUntil { catalog.started && edits.started }
        catalog.release(true)
        try await waitUntil { catalog.finished }
        #expect(!finished)
        edits.release(true)
        #expect(await save.value)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TerminationTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class TerminationSaveGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var releasedResult: Bool?
    private(set) var started = false
    private(set) var finished = false

    func save() async -> Bool {
        started = true
        defer { finished = true }
        if let releasedResult { return releasedResult }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ result: Bool) {
        releasedResult = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private enum TerminationTestError: Error { case timeout }
