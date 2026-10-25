import CoreGraphics
import Foundation
import GlowroomCore

struct AIEditPlanResponse: Sendable {
    let plan: AIEditPlan
    let sourceStamp: ImageAnalysisSourceStamp
}

/// Research candidate for #221. Production UI remains gated; only explicit test
/// providers expose the complete review workflow before qualification.
/// Dependent mask/LLM phases are serial; each native service releases its shared
/// inference admission before the next service acquires it. I/O and rendering
/// retain the existing bounded source and adjusted-preview caches.
struct AIEditPlanService: Sendable {
    enum Stage: String, Sendable { case prepare, target, mask, correction }
    typealias Infer = @Sendable (CGImage, String, String) async throws -> Data
    typealias Resolve = @Sendable (AIEditPlanTarget, AIEditingSnapshot, PreparedImageAnalysisInput) async throws -> LocalAdjustment
    typealias Trace = @Sendable (Stage, Double, Bool) async -> Void
    let preparer: any ImageAnalysisPreparing
    private let budget: AIResourceBudget
    private let infer: Infer
    private let resolve: Resolve
    private let trace: Trace

    init(store: LLMModelStore = .shared, budget: AIResourceBudget = .shared,
         preparer: any ImageAnalysisPreparing = ImageAnalysisPreparer(),
         infer: Infer? = nil, resolve: Resolve? = nil,
         trace: @escaping Trace = { _, _, _ in }) {
        self.preparer = preparer; self.budget = budget; self.trace = trace
        self.infer = infer ?? { image, prompt, schema in
            try await store.withModel { model in
                try await QwenDevelopmentBackend().propose(modelDirectory: model.directory,
                    image: image, prompt: prompt, schema: schema, suppressesWhitespaceRuns: true)
            }
        }
        self.resolve = resolve ?? { target, snapshot, input in
            if target.kind == .object {
                let response = try await AIObjectMaskService(store: store, budget: budget, preparer: preparer)
                    .propose(snapshot: snapshot, instruction: target.description)
                guard response.sourceStamp == input.sourceStamp else { throw AIEditPlanError.staleContext }
                return response.layer
            }
            let raster = try await AutomaticMaskService(budget: budget).generate(input.bitmap,
                kind: target.kind == .sky ? .sky : .subject)
            let mask = try LocalAdjustmentMask(shape: target.kind == .sky ? .sky(raster) : .subject(raster),
                isInverted: target.kind == .background, feather: 0)
            return try LocalAdjustment(name: target.description, mask: mask, settings: .neutral)
        }
    }

    func propose(snapshot: AIEditingSnapshot, instruction: String) async throws -> AIEditPlanResponse {
        try snapshot.validate()
        let prompt = try AIEditPlanTarget.prompt(instruction: instruction)
        guard snapshot.settings.localAdjustments.count < LocalAdjustment.maximumCount else { throw AIObjectMaskError.maskLimit }
        let request = AIObjectMaskService.preparationRequest(snapshot: snapshot)
        let input = try await measured(.prepare) { try await preparer.prepare(request) }
        let target = try await measured(.target) {
            try AIEditPlanTarget.decode(await inference(image: input.bitmap.image, prompt: prompt, schema: AIEditPlanTarget.schema))
        }
        return try await prepareResolved(snapshot: snapshot, instruction: instruction, target: target, request: request, input: input)
    }

    /// Independent explicit-flow reference for the frozen native evaluation.
    /// It skips only language-based target selection; mask/correction services
    /// and source checks are identical to the user's existing two-step workflow.
    func explicitReference(snapshot: AIEditingSnapshot, instruction: String, target: AIEditPlanTarget) async throws -> AIEditPlanResponse {
        try snapshot.validate(); try AIObjectMaskProposal.validateInstruction(instruction); try target.validate()
        guard target.kind != .unsupported else { throw AIEditPlanError.unsupportedRequest }
        let request = AIObjectMaskService.preparationRequest(snapshot: snapshot)
        let input = try await measured(.prepare) { try await preparer.prepare(request) }
        return try await prepareResolved(snapshot: snapshot, instruction: instruction, target: target, request: request, input: input)
    }

    private func prepareResolved(snapshot: AIEditingSnapshot, instruction: String, target: AIEditPlanTarget,
                                 request: ImageAnalysisRequest, input: PreparedImageAnalysisInput) async throws -> AIEditPlanResponse {
        try await checkSource(request, expected: input.sourceStamp)
        let layer = try await measured(.mask) { try await resolve(target, snapshot, input) }
        guard layer.isEnabled, layer.settings == .neutral, layer.mask.opacity > 0,
              !snapshot.settings.localAdjustments.contains(where: { $0.id == layer.id }) else { throw AIEditPlanError.invalidResponse }
        switch layer.mask.shape {
        case .sky(let raster), .subject(let raster):
            guard raster.bytes.contains(where: { layer.mask.isInverted ? $0 < 255 : $0 > 0 }) else { throw AIEditPlanError.emptySelection }
        default: throw AIEditPlanError.invalidResponse // Never substitute a rectangle.
        }
        try await checkSource(request, expected: input.sourceStamp)
        var draft = snapshot.settings; draft.localAdjustments.append(layer)
        _ = try EditingSnapshot(settings: draft)
        var intent = AIDevelopmentIntent(); intent.targetMaskID = layer.id; intent.instruction = instruction; intent.strength = 1
        let proposal = try await measured(.correction) {
            let selected = try AIDevelopmentMaskInput.render(input.bitmap, mask: layer.mask)
            return try AIDevelopmentProposal.decode(await inference(image: selected.image,
                prompt: intent.prompt(settings: draft), schema: AIDevelopmentProposal.schema))
        }
        try await checkSource(request, expected: input.sourceStamp)
        let provenance = AIEditPlanProvenance(languageModelRevision: LLMModelDescriptor.qwen35.revision,
            maskModelRevision: target.kind == .sky ? SkyMaskApprovedPackage.revision : SubjectMattingModelInterface.sourceRevision,
            preprocessingVersion: "full-oriented-canvas-1024-dim-outside-v1")
        let plan = try AIEditPlan(baseline: snapshot, target: target, maskDraft: layer, proposal: proposal, provenance: provenance)
        return AIEditPlanResponse(plan: plan, sourceStamp: input.sourceStamp)
    }

    private func checkSource(_ request: ImageAnalysisRequest, expected: ImageAnalysisSourceStamp) async throws {
        try Task.checkCancellation()
        guard try await preparer.sourceStamp(for: request) == expected else { throw AIEditPlanError.staleContext }
    }

    private func inference(image: CGImage, prompt: String, schema: String) async throws -> Data {
        let lease = try await budget.acquireLocalInference(priority: .interactive, residentBytes: 5 * 1_024 * 1_024 * 1_024)
        do {
            let bytes = try await infer(image, prompt, schema)
            await budget.release(lease)
            try Task.checkCancellation()
            return bytes
        } catch {
            await budget.release(lease)
            throw error
        }
    }

    private func measured<T: Sendable>(_ stage: Stage, operation: () async throws -> T) async throws -> T {
        let start = ContinuousClock.now
        do {
            let value = try await operation()
            await trace(stage, Self.milliseconds(start.duration(to: .now)), true)
            return value
        } catch {
            await trace(stage, Self.milliseconds(start.duration(to: .now)), false)
            throw error
        }
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
