import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Image-aware editing plans and native selection", .timeLimit(.minutes(1)))
struct ImageAwareEditingProviderTests {
    @Test
    func globalShadowsUseEditedPixelsAndPreserveOtherSettings() async throws {
        var settings = EditSettings(exposure: 0.7, shadows: 10)
        settings.localAdjustments = [try imageEditingExistingLayer()]
        let preparer = try ImageEditingTestPreparer()
        let runtime = ImageEditingTestRuntime(plan: .init(status: .proposal,
            changes: [.init(parameter: .shadows, value: 30)], regions: [], explanation: "Dunkle Tonwerte etwas anheben."))
        let masks = ImageEditingMaskCounter()
        let provider = ImageAwareEditingProvider(runtime: runtime, preparer: preparer, budget: AIResourceBudget(),
            maskGenerator: { bitmap, kind in try await masks.generate(bitmap, kind) })
        let result = try await provider.resolvedProposal(for: imageEditingRequest(prompt: "Helle die dunklen Bereiche etwas auf.", settings: settings))
        guard case .changes(_, let target) = try EditProposalValidator().validate(result.data, against: settings) else {
            Issue.record("Expected global shadows"); return
        }
        #expect(target.shadows == 30 && target.exposure == 0.7)
        #expect(target.localAdjustments == settings.localAdjustments)
        #expect(result.localAdjustments.isEmpty)
        #expect(await masks.count == 0)
        #expect(await preparer.settings == [settings])
        #expect(await runtime.count == 1)
    }

    @Test
    func backgroundAndSubjectReuseOneUntransformedMatteAndPreserveExistingMasks() async throws {
        let baseline = EditSettings(localAdjustments: [try imageEditingExistingLayer()],
            developGeometry: try DevelopGeometry(crop: .init(x: 0.2, y: 0.1, width: 0.5, height: 0.6)))
        let preparer = try ImageEditingTestPreparer()
        let runtime = ImageEditingTestRuntime(plan: .init(status: .proposal, changes: [], regions: [
            .init(target: .background, changes: [.init(parameter: .highlights, value: -30), .init(parameter: .exposure, value: -0.3)]),
            .init(target: .subject, changes: [.init(parameter: .saturation, value: 8)])
        ], explanation: "Hintergrundlichter absenken und Motivfarbe vorsichtig anheben."))
        let budget = AIResourceBudget()
        let masks = ImageEditingMaskCounter()
        let service = AutomaticMaskService(budget: budget, generator: { bitmap, kind, _ in
            try await masks.generate(bitmap, kind)
        })
        let provider = ImageAwareEditingProvider(runtime: runtime, preparer: preparer, budget: budget,
            maskGenerator: { bitmap, kind in try await service.generate(bitmap, kind: kind) })
        let result = try await provider.resolvedProposal(for: imageEditingRequest(settings: baseline))
        #expect(result.localAdjustments.count == 2)
        #expect(await masks.count == 1)
        #expect(await preparer.settings == [baseline, .neutral])
        let background = try #require(result.localAdjustments.first)
        #expect(background.mask.isInverted && background.settings.highlights == -30 && background.settings.exposure == -0.3)
        #expect(background.mask.refinement == nil && background.mask.feather == 0)
        let subject = try #require(result.localAdjustments.last)
        #expect(!subject.mask.isInverted && subject.settings.saturation == 8)
        #expect(background.mask.shape == subject.mask.shape)
        #expect(Set((baseline.localAdjustments + result.localAdjustments).map(\.id)).count == 3)
        guard case .noChange = try EditProposalValidator().validate(result.data, against: baseline) else {
            Issue.record("Regional edits must not change global controls"); return
        }
    }

    @Test
    func legacyScalarInterfaceCannotSilentlyDropRegionalLayers() async throws {
        let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: imageEditingRegionalPlan()),
            preparer: try ImageEditingTestPreparer(), budget: AIResourceBudget(),
            maskGenerator: { _, _ in try imageEditingHalfMask() })
        await imageEditingExpect(.unsupportedCapability) { _ = try await provider.proposal(for: imageEditingRequest()) }
    }

    @Test
    func everySupportedRegionAndLocalControlIsMapped() async throws {
        for target in ImageEditingPlan.Target.allCases {
            let changes = EditParameter.allCases.filter { ImageAwareEditingProvider.localParameters.contains($0) }
                .map { EditParameterChange(parameter: $0, value: $0 == .exposure ? -0.2 : 10) }
            let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: .init(status: .proposal,
                changes: [], regions: [.init(target: target, changes: changes)], explanation: "Bereich anpassen.")),
                preparer: try ImageEditingTestPreparer(), budget: AIResourceBudget(),
                maskGenerator: { _, _ in try imageEditingHalfMask() })
            let result = try await provider.resolvedProposal(for: imageEditingRequest(prompt: "Bereich anpassen."))
            let layer = try #require(result.localAdjustments.first)
            #expect(layer.mask.isInverted == (target == .background))
            if target == .sky {
                guard case .sky = layer.mask.shape else { Issue.record("Expected sky shape"); return }
            } else {
                guard case .subject = layer.mask.shape else { Issue.record("Expected subject shape"); return }
            }
            for change in changes { #expect(change.parameter.value(in: layer.settings.editSettings) == change.value) }
        }
    }

    @Test
    func validatesEntirePlanBeforeAnySegmentation() async throws {
        let invalid: [ImageEditingPlan] = [
            .init(status: .proposal, changes: [], regions: [.init(target: .subject, changes: [.init(parameter: .naturalBalanceAmount, value: 70)])], explanation: ""),
            .init(status: .proposal, changes: [], regions: [.init(target: .subject, changes: [.init(parameter: .exposure, value: 8)])], explanation: ""),
            .init(status: .proposal, changes: [], regions: [.init(target: .subject, changes: [.init(parameter: .shadows, value: 0)])], explanation: ""),
            .init(status: .proposal, changes: [], regions: [.init(target: .subject, changes: [.init(parameter: .shadows, value: 5), .init(parameter: .shadows, value: 6)])], explanation: ""),
            .init(status: .proposal, changes: [], regions: [imageEditingRegionalPlan().regions[0], imageEditingRegionalPlan().regions[0]], explanation: ""),
            .init(status: .proposal, changes: [.init(parameter: .contrast, value: .infinity)], regions: imageEditingRegionalPlan().regions, explanation: ""),
            .init(status: .proposal, changes: [], regions: imageEditingRegionalPlan().regions, explanation: String(repeating: "x", count: 2_049))
        ]
        for plan in invalid {
            let masks = ImageEditingMaskCounter()
            let preparer = try ImageEditingTestPreparer()
            let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: plan), preparer: preparer,
                budget: AIResourceBudget(), maskGenerator: { bitmap, kind in try await masks.generate(bitmap, kind) })
            do { _ = try await provider.resolvedProposal(for: imageEditingRequest()); Issue.record("Expected invalid plan") }
            catch { guard case .invalidResponse? = error as? AIEditingError else { Issue.record("Expected validation category"); continue } }
            #expect(await masks.count == 0)
            #expect(await preparer.settings.count == 1)
        }
    }

    @Test(arguments: [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 1]), Data([254, 255, 255, 255]), Data([128, 128, 128, 128])])
    func invalidCoverageFailsInsteadOfTurningBackgroundIntoGlobalEdit(_ bytes: Data) async throws {
        let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: imageEditingRegionalPlan()),
            preparer: try ImageEditingTestPreparer(), budget: AIResourceBudget(),
            maskGenerator: { _, _ in try LocalMaskRaster(width: 4, height: 1, bytes: bytes) })
        await imageEditingExpect(.regionSelectionUnavailable) { _ = try await provider.resolvedProposal(for: imageEditingRequest()) }
    }

    @Test
    func oneFailedRegionDiscardsGlobalAndCompletedRegionalWork() async throws {
        let plan = ImageEditingPlan(status: .proposal, changes: [.init(parameter: .shadows, value: 20)], regions: [
            imageEditingRegionalPlan().regions[0], .init(target: .sky, changes: [.init(parameter: .highlights, value: -10)])
        ], explanation: "Vorsichtige Korrektur.")
        let masks = ImageEditingMaskCounter(failSky: true)
        let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: plan), preparer: try ImageEditingTestPreparer(),
            budget: AIResourceBudget(), maskGenerator: { bitmap, kind in try await masks.generate(bitmap, kind) })
        await imageEditingExpect(.skyModelUnavailable) { _ = try await provider.resolvedProposal(for: imageEditingRequest()) }
        #expect(await masks.count == 2)
    }

    @Test(arguments: [AutomaticMaskError.skyModelNotInstalled, .invalidModel, .setupInProgress])
    func skySetupFailuresRemainActionableAndDoNotReturnGlobalChanges(_ failure: AutomaticMaskError) async throws {
        let plan = ImageEditingPlan(status: .proposal, changes: [.init(parameter: .shadows, value: 20)],
            regions: [.init(target: .sky, changes: [.init(parameter: .exposure, value: -0.3)])], explanation: "Himmel korrigieren.")
        let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: plan),
            preparer: try ImageEditingTestPreparer(), budget: AIResourceBudget(), maskGenerator: { _, _ in throw failure })
        await imageEditingExpect(.skyModelUnavailable) { _ = try await provider.resolvedProposal(for: imageEditingRequest(prompt: "Mache den Himmel dunkler.")) }
        #expect(AIEditingError.skyModelUnavailable.localizedDescription.contains("Himmelsmodell"))
    }

    @Test
    func explicitBackgroundRequestRejectsSilentlyGlobalModelPlan() async throws {
        let runtime = ImageEditingTestRuntime(plan: .init(status: .proposal,
            changes: [.init(parameter: .highlights, value: -30)], regions: [], explanation: "Lichter reduzieren."))
        let masks = ImageEditingMaskCounter()
        let provider = ImageAwareEditingProvider(runtime: runtime, preparer: try ImageEditingTestPreparer(), budget: AIResourceBudget(),
            maskGenerator: { bitmap, kind in try await masks.generate(bitmap, kind) })
        await imageEditingExpect(.regionSelectionUnavailable) { _ = try await provider.resolvedProposal(for: imageEditingRequest()) }
        #expect(await masks.count == 0)
    }

    @Test(arguments: [0, LocalAdjustment.maximumCount])
    func alreadySatisfiedRegionKeepsExplicitScopeAndDoesNotGenerateOrAppendMask(_ existingCount: Int) async throws {
        let settings = EditSettings(localAdjustments: try (0..<existingCount).map { _ in try imageEditingExistingLayer() })
        let plan = ImageEditingPlan(status: .proposal, changes: [],
            regions: [.init(target: .background, changes: [])], explanation: "Die Hintergrundlichter benötigen keine weitere Korrektur.")
        let masks = ImageEditingMaskCounter()
        let preparer = try ImageEditingTestPreparer()
        let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: plan), preparer: preparer, budget: AIResourceBudget(),
            maskGenerator: { bitmap, kind in try await masks.generate(bitmap, kind) })
        let result = try await provider.resolvedProposal(for: imageEditingRequest(settings: settings))
        #expect(result.localAdjustments.isEmpty)
        #expect(await masks.count == 0)
        #expect(await preparer.settings == [settings])
        guard case .noChange(let explanation) = try EditProposalValidator().validate(result.data, against: settings) else {
            Issue.record("Expected explicit regional no-op"); return
        }
        #expect(explanation == plan.explanation)
    }

    @Test
    func classifiedScopeCannotBeDroppedBroadenedOrGivenGlobalChanges() throws {
        let scope = ImageEditingScope(status: .proposal, background: true, subject: false, sky: false, global: false)
        let request = imageEditingRequest()
        try scope.validate(imageEditingRegionalPlan(), request: request)
        let invalid: [ImageEditingPlan] = [
            .init(status: .proposal, changes: [.init(parameter: .highlights, value: -30)], regions: [], explanation: ""),
            .init(status: .proposal, changes: [.init(parameter: .shadows, value: 20)], regions: imageEditingRegionalPlan().regions, explanation: ""),
            .init(status: .proposal, changes: [.init(parameter: .highlights, value: -30)], regions: [.init(target: .background, changes: [])], explanation: ""),
            .init(status: .proposal, changes: [], regions: [.init(target: .subject, changes: [.init(parameter: .highlights, value: -30)])], explanation: "")
        ]
        for plan in invalid {
            #expect(throws: AIEditingError.regionSelectionUnavailable) { try scope.validate(plan, request: request) }
        }
        #expect(throws: AIEditingError.regionSelectionUnavailable) {
            try ImageEditingScope.requireExplicitTargets(in: "Korrigiere den überstahlten Hintergrund.", actual: [])
        }
        try ImageEditingScope.requireExplicitTargets(in: "Helle die dunklen Bereiche etwas auf.", actual: [])
        try ImageEditingScope.requireExplicitTargets(in: "Helle die Schatten auf und erhalte den Hintergrund.", actual: [])
        try ImageEditingScope.requireExplicitTargets(in: "Helle das Motiv auf, nicht den Hintergrund.", actual: [.subject])
    }

    @Test
    func sourceChangeDuringModelOrFinalMaskWorkRejectsWholeResult() async throws {
        for stage in ["model", "mask"] {
            let preparer = try ImageEditingTestPreparer()
            let runtime = ImageEditingTestRuntime(plan: imageEditingRegionalPlan(), onGenerate: {
                if stage == "model" { await preparer.changeStamp() }
            })
            let provider = ImageAwareEditingProvider(runtime: runtime, preparer: preparer, budget: AIResourceBudget(),
                maskGenerator: { _, _ in
                    if stage == "mask" { await preparer.changeStamp() }
                    return try imageEditingHalfMask()
                })
            await imageEditingExpect(.staleSnapshot) { _ = try await provider.resolvedProposal(for: imageEditingRequest()) }
        }
    }

    @Test
    func cancelledNoncooperativeModelRetainsLeaseUntilActualReturn() async throws {
        let runtime = ImageEditingGateRuntime()
        let budget = AIResourceBudget()
        let masks = ImageEditingMaskCounter()
        let provider = ImageAwareEditingProvider(runtime: runtime, preparer: try ImageEditingTestPreparer(), budget: budget,
            maskGenerator: { bitmap, kind in try await masks.generate(bitmap, kind) })
        let task = Task { try await provider.resolvedProposal(for: imageEditingRequest()) }
        await runtime.waitUntilEntered()
        task.cancel()
        #expect(await imageEditingBudgetState(budget).activeInferences == 1)
        await runtime.finish()
        await imageEditingExpect(.cancelled) { _ = try await task.value }
        #expect(await imageEditingBudgetState(budget).activeInferences == 0)
        #expect(await masks.count == 0)
    }

    @Test
    func cancellationDuringMaskDoesNotReturnPartialResult() async throws {
        let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: imageEditingRegionalPlan()),
            preparer: try ImageEditingTestPreparer(), budget: AIResourceBudget(), maskGenerator: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return try imageEditingHalfMask()
            })
        let task = Task { try await provider.resolvedProposal(for: imageEditingRequest()) }
        await imageEditingExpect(.cancelled) { _ = try await task.value }
    }

    @Test
    func unavailableAndUnsupportedModesDoNotPrepareOrGenerate() async throws {
        let preparer = try ImageEditingTestPreparer()
        let runtime = ImageEditingTestRuntime(plan: imageEditingRegionalPlan(), available: .unavailable(.disabled))
        let provider = ImageAwareEditingProvider(runtime: runtime, preparer: preparer, budget: AIResourceBudget())
        await imageEditingExpect(.unavailable(.disabled)) { _ = try await provider.resolvedProposal(for: imageEditingRequest()) }
        let request = imageEditingRequest()
        await imageEditingExpect(.unsupportedCapability) {
            _ = try await provider.resolvedProposal(for: AIEditingRequest(prompt: request.prompt, snapshot: request.snapshot, mode: .lookGroup))
        }
        #expect(await runtime.count == 0)
        #expect(await preparer.settings.isEmpty)
    }

    @Test
    func modelPayloadContainsOnlyUserTextAndNumericControls() throws {
        let request = imageEditingRequest(prompt: "Korrigiere den überstrahlten Hintergrund.")
        let payload = try ImageEditingModelPrompt(request: request)
        #expect(payload.data.contains(request.prompt))
        #expect(!payload.data.contains("private-photo") && !payload.data.contains(request.snapshot.assetID))
        #expect(!payload.data.contains(request.id.uuidString) && !payload.data.contains(request.snapshot.token.editSessionID.uuidString))
        let json = try #require(JSONSerialization.jsonObject(with: Data(payload.data.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["promptVersion", "userText", "parameters", "localParameters", "localBaseline"])
        #expect(Set(try #require(json["localParameters"] as? [String])) == Set(ImageAwareEditingProvider.localParameters.map(\.rawValue)))
    }

    @Test
    func editedAndSourcePreparationShareOneDecodeAndNeverModifyOriginal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-SharedDecode-\(UUID().uuidString).nef")
        let original = Data("immutable synthetic decoder source".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try analysisFileRequest(url).snapshot
        let request = AIEditingRequest(prompt: "Korrigiere den überstrahlten Hintergrund.", snapshot: .init(
            assetID: snapshot.assetID, source: snapshot.source, settings: EditSettings(exposure: 1), token: snapshot.token))
        let counter = ImageEditingDecodeCounter()
        let bitmap = try analysisRaster(red: true)
        let pipeline = ImagePreviewPipeline(decoder: { _ in counter.record(); return bitmap })
        let preparer = ImageAnalysisPreparer(imagePipeline: pipeline, renderPipeline: AdjustedPreviewPipeline(renderer: { source, _ in source }))
        let provider = ImageAwareEditingProvider(runtime: ImageEditingTestRuntime(plan: imageEditingRegionalPlan()),
            preparer: preparer, budget: AIResourceBudget(), maskGenerator: { _, _ in try imageEditingHalfMask() })
        let result = try await provider.resolvedProposal(for: request)
        #expect(result.localAdjustments.count == 1)
        #expect(counter.count == 1)
        #expect(try Data(contentsOf: url) == original)
    }
}

private func imageEditingRequest(prompt: String = "Korrigiere den überstrahlten Hintergrund.", settings: EditSettings = .neutral) -> AIEditingRequest {
    AIEditingRequest(prompt: prompt, snapshot: AIEditingSnapshot(assetID: "private-image-aware-asset",
        source: .original(AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/private/private-photo.nef"), modifiedAt: .distantPast, fileSize: 100)),
        settings: settings, token: AIEditingToken(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 0)))
}
private func imageEditingRegionalPlan() -> ImageEditingPlan {
    .init(status: .proposal, changes: [], regions: [.init(target: .background, changes: [.init(parameter: .highlights, value: -30)])],
          explanation: "Hintergrundlichter vorsichtig reduzieren.")
}
private func imageEditingExistingLayer() throws -> LocalAdjustment {
    try LocalAdjustment(name: "Meine Maske", mask: .init(shape: .subject(imageEditingHalfMask()), feather: 0), settings: .init(shadows: 5))
}
private func imageEditingHalfMask() throws -> LocalMaskRaster {
    try LocalMaskRaster(width: 4, height: 2, bytes: Data([0, 0, 255, 255, 0, 0, 255, 255]))
}
private actor ImageEditingTestPreparer: ImageAnalysisPreparing {
    private var stamp = ImageAnalysisSourceStamp(device: 1, inode: 2, byteCount: 100, modifiedSeconds: 3,
        modifiedNanoseconds: 0, changedSeconds: 3, changedNanoseconds: 0)
    private let bitmap: PreviewBitmap
    private(set) var settings: [EditSettings] = []
    init() throws { bitmap = try analysisRaster(red: true) }
    func sourceStamp(for request: ImageAnalysisRequest) -> ImageAnalysisSourceStamp { stamp }
    func prepare(_ request: ImageAnalysisRequest) -> PreparedImageAnalysisInput {
        settings.append(request.snapshot.settings)
        return .init(bitmap: bitmap, sourceStamp: stamp, rasterSHA256: String(repeating: "a", count: 64), colorProfile: "sRGB", colorProfileSHA256: nil)
    }
    func changeStamp() {
        stamp = .init(device: 1, inode: 7, byteCount: 100, modifiedSeconds: 3, modifiedNanoseconds: 0, changedSeconds: 4, changedNanoseconds: 0)
    }
}
private actor ImageEditingTestRuntime: ImageEditingModelRuntime {
    let plan: ImageEditingPlan
    let available: AIAvailability
    let onGenerate: @Sendable () async -> Void
    private(set) var count = 0
    init(plan: ImageEditingPlan, available: AIAvailability = .available, onGenerate: @escaping @Sendable () async -> Void = {}) {
        self.plan = plan; self.available = available; self.onGenerate = onGenerate
    }
    func availability() -> AIAvailability { available }
    func generate(_ request: AIEditingRequest, input: PreparedImageAnalysisInput) async -> ImageEditingPlan {
        count += 1; await onGenerate(); return plan
    }
}
private actor ImageEditingMaskCounter {
    private(set) var count = 0
    let failSky: Bool
    init(failSky: Bool = false) { self.failSky = failSky }
    func generate(_ bitmap: PreviewBitmap, _ kind: AutomaticMaskKind) throws -> LocalMaskRaster {
        count += 1
        if failSky && kind == .sky { throw AutomaticMaskError.skyModelNotInstalled }
        return try imageEditingHalfMask()
    }
}
private actor ImageEditingGateRuntime: ImageEditingModelRuntime {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    func availability() -> AIAvailability { .available }
    func generate(_ request: AIEditingRequest, input: PreparedImageAnalysisInput) async -> ImageEditingPlan {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; entered = true
            for waiter in enteredWaiters { waiter.resume() }
            enteredWaiters.removeAll()
        }
        return imageEditingRegionalPlan()
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
private func imageEditingBudgetState(_ budget: AIResourceBudget) async -> AIResourceBudget.State {
    var iterator = await budget.stateUpdates().makeAsyncIterator()
    return await iterator.next()!
}
private func imageEditingExpect(_ expected: AIEditingError, operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected \(expected)") }
    catch { #expect(error as? AIEditingError == expected) }
}
private final class ImageEditingDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}
