import Foundation
import GlowroomCore

struct AIDevelopmentResponse: Sendable {
    let proposal: AIDevelopmentProposal
    let sourceStamp: ImageAnalysisSourceStamp
}

/// The shared inference budget serializes memory-heavy local models. The existing
/// bounded preview workers reuse only caches tied to the native source revision.
struct AIDevelopmentService: Sendable {
    let store: LLMModelStore
    let budget: AIResourceBudget
    let preparer: ImageAnalysisPreparer
    init(store: LLMModelStore = .shared, budget: AIResourceBudget = .shared,
         preparer: ImageAnalysisPreparer = ImageAnalysisPreparer()) {
        self.store = store; self.budget = budget; self.preparer = preparer
    }

    func prepare(snapshot: AIEditingSnapshot) async throws -> PreparedImageAnalysisInput {
        // A workspace bitmap has no native revision. Never relabel those pixels
        // with a newly read stamp: an external replacement can retain size/mtime.
        try await preparer.prepare(ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview,
                                                       lifecycleID: UUID()))
    }

    func propose(snapshot: AIEditingSnapshot, intent: AIDevelopmentIntent) async throws -> AIDevelopmentResponse {
        try intent.validate()
        let prompt = try intent.prompt(settings: snapshot.settings)
        let analysisRequest = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview,
                                                  lifecycleID: UUID())
        let input = try await prepare(snapshot: snapshot)
        let lease = try await budget.acquireLocalInference(priority: .interactive,
            residentBytes: 5 * 1_024 * 1_024 * 1_024)
        do {
            let result = try await store.withModel { model in
                try Task.checkCancellation()
                let data = try await QwenDevelopmentBackend().propose(modelDirectory: model.directory,
                    image: input.bitmap.image, prompt: prompt, schema: AIDevelopmentProposal.schema)
                try Task.checkCancellation()
                return try AIDevelopmentProposal.decode(data)
            }
            // Native completion precedes release, including cancellation. An
            // abandoned UI observer cannot admit a second model prematurely.
            await budget.release(lease)
            try Task.checkCancellation()
            guard try await preparer.sourceStamp(for: analysisRequest) == input.sourceStamp else {
                throw AIDevelopmentError.staleContext
            }
            return AIDevelopmentResponse(proposal: result, sourceStamp: input.sourceStamp)
        } catch {
            await budget.release(lease)
            throw error
        }
    }
}
