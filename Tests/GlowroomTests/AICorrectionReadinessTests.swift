import Foundation
import Testing
@testable import Glowroom

@Suite("AI correction model readiness")
@MainActor
struct AICorrectionReadinessTests {
    @Test func installationInspectionPublishesConcreteStatesAndCanRefreshAfterSetup() async {
        let installation = ReadinessInstallation()
        let readiness = AICorrectionReadiness(checkModel: { await installation.available })
        #expect(readiness.state == .checking)
        await readiness.refresh()
        #expect(readiness.state == .missing)
        await installation.install()
        await readiness.refresh()
        #expect(readiness.state == .ready)
    }

    @Test func inspectionErrorRemainsReadableAndRetryCanRecover() async {
        let installation = ReadinessInstallation()
        let readiness = AICorrectionReadiness(checkModel: {
            guard await installation.available else { throw ReadinessError() }
            return true
        })
        await readiness.refresh()
        #expect(readiness.state == .failed("Modellinstallation beschädigt."))
        await installation.install()
        await readiness.refresh()
        #expect(readiness.state == .ready)
    }
}

private actor ReadinessInstallation {
    private(set) var available = false
    func install() { available = true }
}

private struct ReadinessError: LocalizedError {
    var errorDescription: String? { "Modellinstallation beschädigt." }
}
