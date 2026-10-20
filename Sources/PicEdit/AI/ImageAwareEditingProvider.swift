import Foundation
import PicEditCore

/// Only app-resolved selections cross this boundary. Model output can request a
/// supported region, but can never supply mask pixels, layer IDs or persistence.
protocol AIResolvedEditingProvider: AIEditingProvider {
    func resolvedProposal(for request: AIEditingRequest) async throws -> AIResolvedEditingProposal
}

struct AIResolvedEditingProposal: Sendable {
    let data: Data
    /// New layers only. Existing layers stay in the captured edit baseline.
    let localAdjustments: [LocalAdjustment]
}

struct ImageEditingPlan: Codable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case proposal, whiteBalance, unsupported, unsupportedLanguage, refused
    }
    enum Target: String, Codable, CaseIterable, Hashable, Sendable {
        case background, subject, sky
        var layerName: String {
            switch self {
            case .background: return "Assistent: Hintergrund"
            case .subject: return "Assistent: Motiv"
            case .sky: return "Assistent: Himmel"
            }
        }
    }
    struct Region: Codable, Sendable {
        let target: Target
        let changes: [EditParameterChange]
    }
    let status: Status
    let changes: [EditParameterChange]
    let regions: [Region]
    let explanation: String
}

/// SDK-independent model boundary. Each generation is isolated and ephemeral.
protocol ImageEditingModelRuntime: Sendable {
    func availability() async -> AIAvailability
    func generate(_ request: AIEditingRequest, input: PreparedImageAnalysisInput) async throws -> ImageEditingPlan
}

/// Vision chooses scalar edits and supported regions. Existing native rendering
/// and automatic selection services implement them without generating image pixels.
struct ImageAwareEditingProvider: AIResolvedEditingProvider {
    typealias MaskGenerator = @Sendable (PreviewBitmap, AutomaticMaskKind) async throws -> LocalMaskRaster
    let id = "apple.system-language-model.image-editing.v1"
    let capabilities: AIProviderCapabilities = [.textEditing, .imageUnderstanding]
    static let maximumRegions = 3
    static let localParameters: Set<EditParameter> = [
        .exposure, .contrast, .highlights, .shadows, .whites, .blacks,
        .texture, .clarity, .dehaze, .vibrance, .saturation
    ]
    private let runtime: any ImageEditingModelRuntime
    private let preparer: any ImageAnalysisPreparing
    private let budget: AIResourceBudget
    private let maskGenerator: MaskGenerator

    init(runtime: any ImageEditingModelRuntime,
         preparer: any ImageAnalysisPreparing = ImageAnalysisPreparer(),
         budget: AIResourceBudget = .shared, maskGenerator: MaskGenerator? = nil) {
        self.runtime = runtime; self.preparer = preparer; self.budget = budget
        let maskService = AutomaticMaskService(budget: budget)
        self.maskGenerator = maskGenerator ?? { bitmap, kind in
            try await maskService.generate(bitmap, kind: kind)
        }
    }

    func availability() async -> AIAvailability { await runtime.availability() }

    /// A caller using the legacy scalar-only protocol must never lose a region.
    func proposal(for request: AIEditingRequest) async throws -> Data {
        let resolved = try await resolvedProposal(for: request)
        guard resolved.localAdjustments.isEmpty else { throw AIEditingError.unsupportedCapability }
        return resolved.data
    }

    func resolvedProposal(for request: AIEditingRequest) async throws -> AIResolvedEditingProposal {
        do {
            try Task.checkCancellation()
            guard request.mode == .single else { throw AIEditingError.unsupportedCapability }
            guard request.prompt.utf8.count <= LocalAIEditingPrompt.maximumUserTextBytes else {
                throw AIEditingError.inputLimitExceeded
            }
            try request.validate(maximumPromptBytes: LocalAIEditingPrompt.maximumUserTextBytes)
            try request.snapshot.settings.validateLocalAdjustments()
            try await requireAvailable()
            let analysis = analysisRequest(for: request, settings: request.snapshot.settings)
            let before = try await preparer.sourceStamp(for: analysis)
            let input = try await preparer.prepare(analysis)
            guard input.sourceStamp == before else { throw AIEditingError.staleSnapshot }
            try Task.checkCancellation()

            // The coordinator deliberately does not acquire an outer lease for
            // resolved providers: the mask service needs the same admission slot.
            // Retain this lease until native generation actually returns, even
            // when cancellation cannot immediately interrupt the system service.
            let lease = try await budget.acquireLocalInference(priority: .interactive)
            let plan: ImageEditingPlan
            do {
                try await requireAvailable()
                try Task.checkCancellation()
                plan = try await runtime.generate(request, input: input)
                await budget.release(lease)
            } catch {
                await budget.release(lease)
                throw error
            }
            try Task.checkCancellation()
            let validated = try validate(plan, against: request.snapshot.settings)
            try ImageEditingScope.requireExplicitTargets(in: request.prompt, actual: Set(plan.regions.map(\.target)))
            var layers: [LocalAdjustment] = []
            if !validated.regions.isEmpty {
                // Masks use the untransformed oriented source. Local layers are
                // rendered before crop/rotation, while vision sees the current
                // edited preview. Both requests share the bounded decoded cache
                // and native source revision, including expensive RAW decoding.
                let source = try await preparer.prepare(analysisRequest(for: request, settings: .neutral))
                guard source.sourceStamp == before else { throw AIEditingError.staleSnapshot }
                var subject: LocalMaskRaster?
                var sky: LocalMaskRaster?
                // One shared native inference slot makes parallel segmentation
                // counterproductive. Reuse the same subject matte for its inverse.
                for region in validated.regions {
                    try Task.checkCancellation()
                    let raster: LocalMaskRaster
                    switch region.target {
                    case .subject, .background:
                        if let subject { raster = subject }
                        else {
                            let generated = try await maskGenerator(source.bitmap, .subject)
                            try Self.validateCoverage(generated)
                            subject = generated; raster = generated
                        }
                    case .sky:
                        if let sky { raster = sky }
                        else {
                            let generated = try await maskGenerator(source.bitmap, .sky)
                            try Self.validateCoverage(generated)
                            sky = generated; raster = generated
                        }
                    }
                    try Task.checkCancellation()
                    let shape: LocalMaskShape = region.target == .sky ? .sky(raster) : .subject(raster)
                    let mask = try LocalAdjustmentMask(shape: shape, isInverted: region.target == .background,
                                                       opacity: 1, feather: 0)
                    layers.append(try LocalAdjustment(name: region.target.layerName, mask: mask,
                                                       settings: region.settings))
                }
            }
            try Task.checkCancellation()
            let after = try await preparer.sourceStamp(for: analysis)
            guard after == before else { throw AIEditingError.staleSnapshot }
            var combined = request.snapshot.settings
            combined.localAdjustments.append(contentsOf: layers)
            try combined.validateLocalAdjustments()
            return AIResolvedEditingProposal(data: validated.data, localAdjustments: layers)
        } catch {
            if error is CancellationError || Task.isCancelled { throw AIEditingError.cancelled }
            if let error = error as? AIEditingError { throw error }
            if let error = error as? ImageAnalysisError {
                switch error {
                case .cancelled, .superseded: throw AIEditingError.cancelled
                case .staleSource: throw AIEditingError.staleSnapshot
                case .inputLimitExceeded: throw AIEditingError.inputLimitExceeded
                case .invalidRequest: throw AIEditingError.invalidRequest
                default: throw AIEditingError.providerFailure
                }
            }
            if let error = error as? AutomaticMaskError {
                switch error {
                case .skyModelNotInstalled, .invalidModel, .setupInProgress:
                    throw AIEditingError.skyModelUnavailable
                default: throw AIEditingError.regionSelectionUnavailable
                }
            }
            if error is SubjectMattingError {
                throw AIEditingError.regionSelectionUnavailable
            }
            // No raw SDK output, source path or user prompt escapes the adapter.
            throw AIEditingError.providerFailure
        }
    }

    private func requireAvailable() async throws {
        if case .unavailable(let reason) = await runtime.availability() { throw AIEditingError.unavailable(reason) }
    }

    private func analysisRequest(for request: AIEditingRequest, settings: EditSettings) -> ImageAnalysisRequest {
        let snapshot = request.snapshot
        return ImageAnalysisRequest(id: request.id, snapshot: AIEditingSnapshot(assetID: snapshot.assetID,
            source: snapshot.source, settings: settings, token: snapshot.token, persistedVersion: snapshot.persistedVersion),
            inputKind: .editedPreview, lifecycleID: request.id)
    }

    private struct ValidatedRegion {
        let target: ImageEditingPlan.Target
        let settings: LocalAdjustmentSettings
    }
    private struct ValidatedPlan {
        let data: Data
        let regions: [ValidatedRegion]
    }

    /// Validate the complete plan before any segmentation. No partial proposal
    /// is returned when one region is invalid or cannot be selected reliably.
    private func validate(_ plan: ImageEditingPlan, against baseline: EditSettings) throws -> ValidatedPlan {
        switch plan.status {
        case .proposal: break
        case .whiteBalance: throw AIEditingError.unsupportedTask(.whiteBalance)
        case .unsupported: throw AIEditingError.unsupportedTask(.other)
        case .unsupportedLanguage: throw AIEditingError.unsupportedTask(.unsupportedLanguage)
        case .refused: throw AIEditingError.safetyRefusal
        }
        guard plan.regions.count <= Self.maximumRegions,
              Set(plan.regions.map(\.target)).count == plan.regions.count,
              baseline.localAdjustments.count + plan.regions.filter({ !$0.changes.isEmpty }).count <= LocalAdjustment.maximumCount else {
            throw AIEditingError.invalidResponse(.tooManyChanges)
        }
        let validator = EditProposalValidator(maximumResponseBytes: budget.limits.maximumResponseBytes)
        let global = EditProposal(changes: plan.changes, explanation: plan.explanation)
        _ = try validator.validate(global, against: baseline)
        let data = try JSONEncoder().encode(global)
        _ = try validator.validate(data, against: baseline)
        let regions = try plan.regions.compactMap { region -> ValidatedRegion? in
            // Retain the requested scope in the model plan, while an explicit
            // empty patch means that this region already needs no correction.
            // It must not spend an inference or add a neutral mask layer.
            if region.changes.isEmpty { return nil }
            guard region.changes.allSatisfy({ Self.localParameters.contains($0.parameter) }) else {
                throw AIEditingError.invalidResponse(.unknownParameter)
            }
            let patch = EditProposal(changes: region.changes)
            guard case .changes(_, let value) = try validator.validate(patch, against: .neutral) else {
                throw AIEditingError.invalidResponse(.invalidType)
            }
            return ValidatedRegion(target: region.target, settings: .init(exposure: value.exposure,
                contrast: value.contrast, highlights: value.highlights, shadows: value.shadows,
                whites: value.whites, blacks: value.blacks, texture: value.texture, clarity: value.clarity,
                dehaze: value.dehaze, vibrance: value.vibrance, saturation: value.saturation))
        }
        return ValidatedPlan(data: data, regions: regions)
    }

    static func validateCoverage(_ raster: LocalMaskRaster) throws {
        // A nearly empty/full matte can turn an intended region into a global
        // edit, especially after inversion. Require 1–99% mean coverage and
        // definite selected/unselected pixels; retain soft edge values unchanged.
        let sum = raster.bytes.reduce(UInt64(0)) { $0 + UInt64($1) }
        let mass = Double(sum) / (255 * Double(raster.bytes.count))
        guard (0.01...0.99).contains(mass), raster.bytes.contains(where: { $0 <= 31 }),
              raster.bytes.contains(where: { $0 >= 224 }) else { throw AIEditingError.regionSelectionUnavailable }
    }
}
