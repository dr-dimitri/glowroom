import AppKit
import Foundation

/// This entry is scheduled as a CFRunLoop perform block, not a main-dispatch
/// callback. Nested default-mode runs can therefore service MainActor jobs as
/// the async scenario yields. Menu dismissal may stop one nested iteration;
/// the enclosing bounded loop keeps driving until the WHOLE scenario returns.
func runProtectedNativeAcceptanceScenario(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                let completion = NativeAcceptanceScenarioState()
                let worker = Task { @MainActor in
                    do { try await operation(); completion.result = .success(()) }
                    catch { completion.result = .failure(error) }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(90))
                while completion.result == nil {
                    if ContinuousClock.now >= deadline {
                        worker.cancel()
                        continuation.resume(throwing: NativeAcceptanceLoopError.timeout)
                        return
                    }
                    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                continuation.resume(with: completion.result!)
            }
        }
    }
}

@MainActor
private final class NativeAcceptanceScenarioState { var result: Result<Void, Error>? }

private enum NativeAcceptanceLoopError: Error { case timeout }
