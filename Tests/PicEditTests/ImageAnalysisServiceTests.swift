import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Image analysis bounded scheduler", .timeLimit(.minutes(1)))
struct ImageAnalysisServiceTests {
    @Test
    func originalCoalescesAndCachesAcrossSlidersButRebindsObservers() async throws {
        let provider = AnalysisGateProvider()
        let preparer = AnalysisFakePreparer()
        let service = ImageAnalysisService(provider: provider, preparer: preparer, budget: AIResourceBudget())
        let a = analysisRequest()
        let b = analysisRequest(from: a, settings: EditSettings(exposure: 1), generation: 2)
        let first = Task { try await service.analyze(a) }
        await provider.waitForCalls(1)
        let second = Task { try await service.analyze(b) }
        await waitAnalysis(service) { $0.waiterCount == 2 }
        await provider.complete(0)
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult.request == a && secondResult.request == b)
        #expect(firstResult.provenance == secondResult.provenance)
        #expect(firstResult.provenance.editToken == nil)
        let cached = try await service.analyze(analysisRequest(from: b, generation: 3))
        #expect(cached.provenance == firstResult.provenance)
        #expect(await provider.count == 1)
        #expect(await preparer.prepareCount == 1)
        #expect(await provider.wasOnMain == false)
        #expect(await preparer.wasOnMain == false)
    }

    @Test
    func cancellationOfOneObserverPreservesSharedActualInference() async throws {
        let provider = AnalysisGateProvider()
        let budget = AIResourceBudget()
        let service = ImageAnalysisService(provider: provider, preparer: AnalysisFakePreparer(), budget: budget)
        let request = analysisRequest()
        let first = Task { try await service.analyze(request) }
        await provider.waitForCalls(1)
        let secondRequest = analysisRequest(from: request)
        let second = Task { try await service.analyze(secondRequest) }
        await waitAnalysis(service) { $0.waiterCount == 2 }
        first.cancel()
        await analysisError(first, .cancelled)
        #expect(await analysisBudgetState(budget).activeInferences == 1)
        await provider.complete(0)
        #expect(try await second.value.request == secondRequest)
        await waitAnalysisBudget(budget) { $0.activeInferences == 0 }
    }

    @Test
    func twentyContextsKeepNoncooperativeSlotAndOnlyLatestQueuedContext() async throws {
        let provider = AnalysisGateProvider()
        let budget = AIResourceBudget()
        let service = ImageAnalysisService(provider: provider, preparer: AnalysisFakePreparer(), budget: budget)
        let first = Task { try await service.analyze(analysisRequest(path: "first")) }
        await provider.waitForCalls(1)
        first.cancel()
        await analysisError(first, .cancelled)
        var previous: Task<ImageAnalysisResult, Error>?
        var finalRequest: ImageAnalysisRequest?
        for i in 0..<20 {
            let request = analysisRequest(path: "context\(i)")
            let next = Task { try await service.analyze(request) }
            await waitAnalysis(service) { state in
                #expect(state.runningCount == 1 && state.queuedCount <= 1)
                return state.queuedRequestID == request.id
            }
            if let previous { await analysisError(previous, .superseded) }
            previous = next; finalRequest = request
        }
        #expect(await provider.count == 1)
        #expect(await analysisBudgetState(budget).activeInferences == 1)
        await provider.complete(0)
        await provider.waitForCalls(2)
        await provider.complete(1)
        let task = try #require(previous)
        #expect(try await task.value.request == finalRequest)
        #expect(await provider.maximumActive == 1)
        await waitAnalysisBudget(budget) { $0.activeInferences == 0 }
    }

    @Test
    func editedEpochAndSourceChangesNeverReuseOriginalResults() async throws {
        let provider = AnalysisGateProvider()
        let service = ImageAnalysisService(provider: provider, preparer: AnalysisFakePreparer(), budget: AIResourceBudget())
        let original = analysisRequest()
        let edited = analysisRequest(from: original, kind: .editedPreview)
        let unchangedSlidersNewEpoch = analysisRequest(from: edited, generation: 2, kind: .editedPreview)
        let changedSource = analysisRequest(path: "other", kind: .editedPreview)
        for (index, request) in [original, edited, unchangedSlidersNewEpoch, changedSource].enumerated() {
            let task = Task { try await service.analyze(request) }
            await provider.waitForCalls(index + 1)
            await provider.complete(index)
            let result = try await task.value
            #expect(result.request == request)
            #expect(result.provenance.inputKind == request.inputKind)
            #expect(result.provenance.editToken == (request.inputKind == .editedPreview ? request.snapshot.token : nil))
        }
        #expect(await provider.count == 4)
    }

    @Test
    func unavailableReasonsStopBeforePreparationAndInference() async {
        for reason in [ImageAnalysisUnavailableReason.unsupportedSystem, .sdkUnavailable, .unsupportedHardware, .disabled, .modelUnavailable, .unsupportedLanguage, .unsupportedCapability, .temporaryFailure, .unknown] {
            let provider = AnalysisGateProvider(availability: .unavailable(reason))
            let preparer = AnalysisFakePreparer()
            let service = ImageAnalysisService(provider: provider, preparer: preparer, budget: AIResourceBudget())
            #expect(await service.availability() == .unavailable(reason))
            await analysisError(Task { try await service.analyze(analysisRequest()) }, .unavailable(reason))
            #expect(await preparer.prepareCount == 0)
            #expect(await provider.count == 0)
        }
    }

    @Test
    func sourceMutationDuringInferenceRejectsAndCacheReplacementRecomputes() async throws {
        let provider = AnalysisGateProvider()
        let preparer = AnalysisFakePreparer()
        let service = ImageAnalysisService(provider: provider, preparer: preparer, budget: AIResourceBudget())
        let request = analysisRequest()
        let first = Task { try await service.analyze(request) }
        await provider.waitForCalls(1)
        await preparer.replaceSource()
        await provider.complete(0)
        await analysisError(first, .staleSource)
        let retry = Task { try await service.analyze(request) }
        await provider.waitForCalls(2)
        await provider.complete(1)
        let result = try await retry.value
        await preparer.replaceSource()
        let replaced = Task { try await service.analyze(request) }
        await provider.waitForCalls(3)
        await provider.complete(2)
        #expect(try await replaced.value.provenance.rasterSHA256 != result.provenance.rasterSHA256)
        #expect(await preparer.prepareCount == 3)
    }

    @Test
    func globalBudgetSerializesIndependentServicesThroughActualReturn() async throws {
        let budget = AIResourceBudget()
        let providerA = AnalysisGateProvider(), providerB = AnalysisGateProvider()
        let a = ImageAnalysisService(provider: providerA, preparer: AnalysisFakePreparer(), budget: budget)
        let b = ImageAnalysisService(provider: providerB, preparer: AnalysisFakePreparer(), budget: budget)
        let taskA = Task { try await a.analyze(analysisRequest()) }
        await providerA.waitForCalls(1)
        let taskB = Task { try await b.analyze(analysisRequest()) }
        await waitAnalysisBudget(budget) { $0.waitingInferences == 1 }
        taskA.cancel()
        await analysisError(taskA, .cancelled)
        #expect(await providerB.count == 0)
        #expect(await analysisBudgetState(budget).activeInferences == 1)
        await providerA.complete(0)
        await providerB.waitForCalls(1)
        await providerB.complete(0)
        _ = try await taskB.value
        await waitAnalysisBudget(budget) { $0.activeInferences == 0 }
    }

    @Test
    func malformedResponsesDoNotCacheAndInvalidationDoesNotFreeActualSlot() async throws {
        let provider = AnalysisGateProvider()
        let budget = AIResourceBudget()
        let service = ImageAnalysisService(provider: provider, preparer: AnalysisFakePreparer(), budget: budget)
        let request = analysisRequest()
        let invalid = Task { try await service.analyze(request) }
        await provider.waitForCalls(1)
        await provider.complete(0, data: Data(#"{"description":"no schema"}"#.utf8))
        await analysisError(invalid, .invalidResponse)
        let retry = Task { try await service.analyze(request) }
        await provider.waitForCalls(2)
        await service.invalidate()
        await analysisError(retry, .cancelled)
        #expect(await analysisBudgetState(budget).activeInferences == 1)
        await provider.complete(1)
        await waitAnalysis(service) { $0.runningCount == 0 }
        await waitAnalysisBudget(budget) { $0.activeInferences == 0 }
        await waitAnalysis(service) { $0.cachedCount == 0 }
    }

    @Test
    func resultCacheRespectsEntryByteBoundsAndLRU() async throws {
        let provider = AnalysisGateProvider()
        let service = ImageAnalysisService(provider: provider, preparer: AnalysisFakePreparer(), budget: AIResourceBudget(), maximumCacheEntries: 2, maximumCacheBytes: 4_096)
        for index in 0..<3 {
            let task = Task { try await service.analyze(analysisRequest(path: "cache\(index)")) }
            await provider.waitForCalls(index + 1); await provider.complete(index)
            _ = try await task.value
        }
        await waitAnalysis(service) { $0.cachedCount == 2 && $0.cachedBytes <= 4_096 }
        _ = try await service.analyze(analysisRequest(path: "cache1"))
        #expect(await provider.count == 3)
        let evicted = Task { try await service.analyze(analysisRequest(path: "cache0")) }
        await provider.waitForCalls(4); await provider.complete(3)
        _ = try await evicted.value
        let noCache = ImageAnalysisService(provider: provider, preparer: AnalysisFakePreparer(), budget: AIResourceBudget(), maximumCacheBytes: 1)
        let uncached = Task { try await noCache.analyze(analysisRequest()) }
        await provider.waitForCalls(5); await provider.complete(4)
        _ = try await uncached.value
        await waitAnalysis(noCache) { $0.cachedCount == 0 && $0.cachedBytes == 0 }
    }
}

private let analysisValidResponse = Data(#"{"schemaVersion":1,"description":"Ein roter Kreis und ein blaues Quadrat.","attributes":[{"category":"color","value":"Rot und Blau"}]}"#.utf8)

private actor AnalysisGateProvider: ImageAnalysisProvider {
    nonisolated let descriptor = ImageAnalysisProviderDescriptor(providerID: "fake.vision", modelID: "synthetic-v1")
    private let status: ImageAnalysisAvailability
    private var jobs: [CheckedContinuation<Data, Error>?] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var wasOnMain = false
    var count: Int { jobs.count }
    init(availability: ImageAnalysisAvailability = .available) { status = availability }
    func availability() -> ImageAnalysisAvailability { status }
    func analyze(_ input: PreparedImageAnalysisInput) async throws -> Data {
        wasOnMain = wasOnMain || Thread.isMainThread
        active += 1; maximumActive = max(maximumActive, active)
        return try await withCheckedThrowingContinuation { continuation in
            jobs.append(continuation)
            let ready = observers.filter { jobs.count >= $0.0 }
            observers.removeAll { jobs.count >= $0.0 }
            for item in ready { item.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if jobs.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func complete(_ index: Int, data: Data = analysisValidResponse) {
        guard jobs.indices.contains(index), let job = jobs[index] else { Issue.record("Unknown model call"); return }
        jobs[index] = nil; active -= 1; job.resume(returning: data)
    }
}

private actor AnalysisFakePreparer: ImageAnalysisPreparing {
    private var revision: UInt64 = 1
    private(set) var prepareCount = 0
    private(set) var wasOnMain = false
    func replaceSource() { revision += 1 }
    func sourceStamp(for request: ImageAnalysisRequest) -> ImageAnalysisSourceStamp {
        ImageAnalysisSourceStamp(device: 1, inode: revision, byteCount: 1, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: Int64(revision), changedNanoseconds: 0)
    }
    func prepare(_ request: ImageAnalysisRequest) throws -> PreparedImageAnalysisInput {
        prepareCount += 1; wasOnMain = wasOnMain || Thread.isMainThread
        let bitmap = try analysisTestBitmap()
        return PreparedImageAnalysisInput(bitmap: bitmap, sourceStamp: sourceStamp(for: request),
            rasterSHA256: String(repeating: String(revision % 10), count: 64), colorProfile: "synthetic sRGB", colorProfileSHA256: nil)
    }
}

private func analysisRequest(path: String = "synthetic", kind: ImageAnalysisInputKind = .originalPreview) -> ImageAnalysisRequest {
    ImageAnalysisRequest(snapshot: AIEditingSnapshot(assetID: path, source: .original(AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/tmp/\(path).png"), modifiedAt: Date(timeIntervalSince1970: 1), fileSize: 1)), settings: .neutral,
        token: AIEditingToken(editSessionID: UUID(), editGeneration: 1, selectionSessionID: UUID(), selectionGeneration: 1)), inputKind: kind, lifecycleID: UUID())
}
private func analysisRequest(from request: ImageAnalysisRequest, settings: EditSettings? = nil, generation: UInt64? = nil, kind: ImageAnalysisInputKind? = nil) -> ImageAnalysisRequest {
    let snapshot = request.snapshot, token = snapshot.token
    return ImageAnalysisRequest(snapshot: AIEditingSnapshot(assetID: snapshot.assetID, source: snapshot.source, settings: settings ?? snapshot.settings,
        token: AIEditingToken(editSessionID: token.editSessionID, editGeneration: generation ?? token.editGeneration, selectionSessionID: token.selectionSessionID, selectionGeneration: token.selectionGeneration)), inputKind: kind ?? request.inputKind, lifecycleID: request.lifecycleID)
}
private func analysisTestBitmap() throws -> PreviewBitmap {
    let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    return PreviewBitmap(image: try #require(context.makeImage()))
}
private func waitAnalysis(_ service: ImageAnalysisService, until predicate: (ImageAnalysisService.State) -> Bool) async {
    for await state in await service.stateUpdates() { if predicate(state) { return } }
}
private func waitAnalysisBudget(_ budget: AIResourceBudget, until predicate: (AIResourceBudget.State) -> Bool) async {
    for await state in await budget.stateUpdates() { if predicate(state) { return } }
}
private func analysisError(_ task: Task<ImageAnalysisResult, Error>, _ expected: ImageAnalysisError) async {
    do { _ = try await task.value; Issue.record("Expected \(expected)") }
    catch { #expect(error as? ImageAnalysisError == expected) }
}

private func analysisBudgetState(_ budget: AIResourceBudget) async -> AIResourceBudget.State {
    for await state in await budget.stateUpdates() { return state }
    preconditionFailure("No resource state")
}
