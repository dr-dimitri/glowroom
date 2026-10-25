import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Semantic edit plan staged source and resource safety", .timeLimit(.minutes(1)))
struct AIEditPlanServiceTests {
    @Test func stagedPreparationUsesFullCanvasAndReleasesAdmissionBeforeMaskService() async throws {
        let preparer = try PlanTestPreparer()
        let budget = AIResourceBudget()
        var settings = EditSettings(exposure: 0.5)
        settings.developGeometry = DevelopGeometry(crop: try .init(x: 0.1, y: 0.2, width: 0.6, height: 0.5),
            quarterTurns: 1, flipHorizontal: true, flipVertical: true)
        let baseline = snapshot(settings)
        let service = AIEditPlanService(budget: budget, preparer: preparer, infer: Self.infer,
            resolve: { target, frozen, input in
                #expect(target.kind == .sky && frozen == baseline)
                for await state in await budget.stateUpdates() {
                    #expect(state.activeInferences == 0, "Masking must be able to acquire the shared lease")
                    break
                }
                return try Self.layer()
            })
        let response = try await service.propose(snapshot: baseline, instruction: "Den Himmel dunkler")
        let request = try #require(await preparer.request)
        #expect(request.snapshot.settings.developGeometry.crop == nil)
        #expect(request.snapshot.settings.developGeometry.quarterTurns == 0)
        #expect(!request.snapshot.settings.developGeometry.flipHorizontal && !request.snapshot.settings.developGeometry.flipVertical)
        let result = try response.plan.applying(to: baseline)
        #expect(result.localAdjustments.count == 1 && result.localAdjustments[0].settings.exposure == -0.5)
        #expect(result.developGeometry == settings.developGeometry && result.exposure == 0.5)
        #expect(response.sourceStamp == preparer.stamp)
    }

    @Test func errorsBetweenStagesNeverPublishPartialPlans() async throws {
        for failure in ["target", "mask", "correction", "source", "noop"] {
            let preparer = try PlanTestPreparer()
            let service = AIEditPlanService(preparer: preparer, infer: { image, prompt, schema in
                if failure == "target" || (failure == "correction" && schema == AIDevelopmentProposal.schema) {
                    return Data(#"{"unexpected":true}"#.utf8)
                }
                if failure == "noop" && schema == AIDevelopmentProposal.schema {
                    return try JSONEncoder().encode(AIDevelopmentProposal(summary: "Keine Korrektur", adjustments: .init()))
                }
                return try await Self.infer(image, prompt, schema)
            }, resolve: { _, _, _ in
                if failure == "mask" { throw AIObjectMaskError.emptyMask }
                if failure == "source" { await preparer.changeSource() }
                return try Self.layer()
            })
            let baseline = snapshot()
            await #expect(throws: (any Error).self) {
                _ = try await service.propose(snapshot: baseline, instruction: "Himmel dunkler")
            }
            #expect(baseline.settings.localAdjustments.isEmpty)
        }
    }

    @Test func cancelledNativeWorkKeepsLeaseAndNeverStartsDependentMask() async throws {
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        defer { release.releaseAll() }
        let budget = AIResourceBudget()
        let service = AIEditPlanService(budget: budget, preparer: try PlanTestPreparer(), infer: { image, prompt, schema in
            entered.releaseAll(); await release.wait()
            return try await Self.infer(image, prompt, schema)
        }, resolve: { _, _, _ in
            Issue.record("Cancelled target inference cannot start masking")
            return try Self.layer()
        })
        let task = Task { try await service.propose(snapshot: snapshot(), instruction: "Himmel dunkler") }
        await entered.wait(); task.cancel()
        for await state in await budget.stateUpdates() { #expect(state.activeInferences == 1); break }
        release.releaseAll()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        for await state in await budget.stateUpdates() { #expect(state.activeInferences == 0); break }
    }

    static let infer: AIEditPlanService.Infer = { _, _, schema in
        if schema == AIEditPlanTarget.schema {
            return Data(#"{"kind":"sky","description":"Himmel","summary":"Himmel abdunkeln"}"#.utf8)
        }
        return try JSONEncoder().encode(AIDevelopmentProposal(summary: "Dunkler", adjustments: .init(exposure: -0.5)))
    }
    static func layer() throws -> LocalAdjustment {
        try .init(name: "Himmel", mask: .init(shape: .sky(.init(width: 2, height: 2, bytes: Data([255, 128, 0, 0]))), feather: 0))
    }
    private func snapshot(_ settings: EditSettings = .neutral) -> AIEditingSnapshot {
        .init(assetID: "plan", source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/plan.png"), modifiedAt: .distantPast, fileSize: 1)),
            settings: settings, token: .init(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 0))
    }
}

private actor PlanTestPreparer: ImageAnalysisPreparing {
    nonisolated let stamp = ImageAnalysisSourceStamp(device: 1, inode: 2, byteCount: 1,
        modifiedSeconds: 0, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0)
    let bitmap: PreviewBitmap
    private var changed = false
    private(set) var request: ImageAnalysisRequest?
    init() throws { bitmap = try analysisRaster(red: true) }
    func changeSource() { changed = true }
    func sourceStamp(for request: ImageAnalysisRequest) async throws -> ImageAnalysisSourceStamp {
        changed ? ImageAnalysisSourceStamp(device: 1, inode: 3, byteCount: 1,
            modifiedSeconds: 0, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0) : stamp
    }
    func prepare(_ request: ImageAnalysisRequest) async throws -> PreparedImageAnalysisInput {
        self.request = request
        return .init(bitmap: bitmap, sourceStamp: stamp, rasterSHA256: "test", colorProfile: "sRGB", colorProfileSHA256: nil)
    }
}
