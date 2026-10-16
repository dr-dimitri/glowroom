import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Local three-look real-model smoke v1", .timeLimit(.minutes(5)))
struct LocalAILookEvaluationTests {
    @Test(.enabled("Requires PICEDIT_RUN_LOCAL_AI_LOOK_EVALUATION=1 and a ready German system model") {
        guard ProcessInfo.processInfo.environment["PICEDIT_RUN_LOCAL_AI_LOOK_EVALUATION"] == "1" else { return false }
        if case .unavailable(let reason) = await LocalAIEditingProviderFactory.makeProvider().availability() {
            print("Local look evaluation skipped: \(reason.localizedDescription)")
            return false
        }
        return true
    })
    func groupedRecipesAndUnsupportedTasks() async throws {
        let coordinator = AIRequestCoordinator(provider: LocalAIEditingProviderFactory.makeProvider(), budget: .shared)
        for index in 0..<2 {
            let baseline = index == 0 ? EditSettings.neutral : EditSettings(exposure: 0.7, shadows: 12)
            let request = providerRequest(prompt: index == 0 ? "" : "Lasse die Belichtung unverändert.", settings: baseline, mode: .lookGroup)
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await coordinator.lookGroup(for: request)
            #expect(result.request == request)
            #expect(result.validation.variants.map(\.proposal.id) == AILookID.allCases)
            #expect(Set(result.validation.variants.map(\.target)).count == 3)
            #expect(result.validation.variants.allSatisfy { $0.target != baseline })
            let natural = try #require(result.validation.variants.first { $0.proposal.id == .natural })
            let contrasty = try #require(result.validation.variants.first { $0.proposal.id == .contrasty })
            let desaturated = try #require(result.validation.variants.first { $0.proposal.id == .desaturated })
            #expect(contrasty.target.contrast > natural.target.contrast)
            #expect(desaturated.target.saturation < baseline.saturation)
            if index == 1 { #expect(result.validation.variants.allSatisfy { $0.target.exposure == baseline.exposure }) }
            print("Local look smoke v1 case \(index + 1): \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start)) s; 3 validated text recipes")
        }
        for (text, expected) in [("Mache das Bild wärmer.", AIUnsupportedTaskReason.whiteBalance),
                                 ("Was ist auf dem Foto?", AIUnsupportedTaskReason.imageAnalysis)] {
            do {
                _ = try await coordinator.lookGroup(for: providerRequest(prompt: text, mode: .lookGroup))
                Issue.record("Expected an honest capability rejection")
            } catch let error as AIEditingError { #expect(error == .unsupportedTask(expected)) }
        }
    }
}
