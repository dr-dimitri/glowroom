import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Image generation fail-closed and native resource lifecycle", .timeLimit(.minutes(1)))
struct ImageGenerationServiceTests {
    @Test func productionNoGoRejectsEveryOperationAndNeverGenerates() async throws {
        let backend = UnavailableImageGenerationBackend(), service = ImageGenerationService(backend: backend, budget: AIResourceBudget(), resources: generationResources())
        for operation in ImageGenerationOperation.allCases {
            #expect(backend.descriptor.status(for: operation) == .unsupported)
            #expect(await service.availability(for: operation) == .unavailable(.qualityGateFailed))
        }
        let job = try generationJob()
        await generationError(Task { try await service.generate(job, currentToken: { job.request.token }) }, .unavailable(.qualityGateFailed))
    }

    @Test(arguments: ImageGenerationUnavailableReason.allCases)
    func readinessFailuresStopBeforeNativeWork(reason: ImageGenerationUnavailableReason) async throws {
        let backend = GenerationGateBackend(status: .unavailable(reason)), budget = AIResourceBudget()
        let service = ImageGenerationService(backend: backend, budget: budget, resources: generationResources())
        let job = try generationJob()
        await generationError(Task { try await service.generate(job, currentToken: { job.request.token }) }, .unavailable(reason))
        #expect(await backend.count == 0)
        #expect(await generationBudgetState(budget).activeInferences == 0)
    }

    @Test func unsupportedAndUnverifiedClaimsNeverReachNativeWork() async throws {
        for status in [ImageGenerationCapabilityStatus.unsupported, .unverified] {
            let backend = GenerationGateBackend(capability: status)
            let service = ImageGenerationService(backend: backend, budget: AIResourceBudget(), resources: generationResources())
            let job = try generationJob()
            let reason: ImageGenerationUnavailableReason = status == .unsupported ? .unsupportedOperation : .unverifiedCapability
            await generationError(Task { try await service.generate(job, currentToken: { job.request.token }) }, .unavailable(reason))
            #expect(await backend.count == 0)
        }
    }

    @Test func residentBudgetRejectsOversizedModelBeforeNativeLoad() async throws {
        let backend = GenerationGateBackend(residentBytes: 129)
        let budget = AIResourceBudget(limits: .init(maximumResidentModelBytes: 128))
        let service = ImageGenerationService(backend: backend, budget: budget, resources: generationResources())
        let job = try generationJob()
        await generationError(Task { try await service.generate(job, currentToken: { job.request.token }) }, .unavailable(.memoryPressure))
        #expect(await backend.count == 0)
        #expect(await generationBudgetState(budget).residentModelBytes == 0)
    }

    @Test func cancellationRetainsSharedAdmissionUntilActualReturnAndOnlyNewestWaiterRuns() async throws {
        let backend = GenerationGateBackend(residentBytes: 64), budget = AIResourceBudget()
        let service = ImageGenerationService(backend: backend, budget: budget, resources: generationResources())
        let firstJob = try generationJob()
        let first = Task { try await service.generate(firstJob, currentToken: { firstJob.request.token }) }
        await backend.waitForCalls(1)
        first.cancel(); await generationError(first, .cancelled)
        #expect(await generationBudgetState(budget).activeInferences == 1)
        #expect(await generationBudgetState(budget).residentModelBytes == 64)
        let secondJob = try generationJob(), thirdJob = try generationJob()
        let second = Task { try await service.generate(secondJob, currentToken: { secondJob.request.token }) }
        await waitGeneration(service) { $0.queuedRequestID == secondJob.request.id }
        let third = Task { try await service.generate(thirdJob, currentToken: { thirdJob.request.token }) }
        await waitGeneration(service) { $0.queuedRequestID == thirdJob.request.id }
        await generationError(second, .superseded)
        #expect(await backend.count == 1)
        await backend.complete(0)
        await backend.waitForCalls(2)
        await backend.complete(1)
        #expect(try await third.value.token == thirdJob.request.token)
        #expect(await backend.maximumActive == 1)
        #expect(await backend.wasOnMain == false)
        await waitGenerationBudget(budget) { $0.activeInferences == 0 && $0.residentModelBytes == 0 }
    }

    @Test func deadlineDropsLateResultAndKeepsNativeLease() async throws {
        let backend = GenerationGateBackend(), budget = AIResourceBudget()
        let service = ImageGenerationService(backend: backend, budget: budget, resources: generationResources(), timeout: .milliseconds(100))
        let job = try generationJob()
        let task = Task { try await service.generate(job, currentToken: { job.request.token }) }
        await backend.waitForCalls(1)
        await generationError(task, .timedOut)
        #expect(await generationBudgetState(budget).activeInferences == 1)
        await backend.complete(0)
        await waitGeneration(service) { $0.runningCount == 0 && $0.observerCount == 0 }
        await waitGenerationBudget(budget) { $0.activeInferences == 0 }
    }

    @Test func revokedSelectionAndMismatchedOutputTokensCannotPublish() async throws {
        let backend = GenerationGateBackend(), service = ImageGenerationService(backend: backend, budget: AIResourceBudget(), resources: generationResources())
        let job = try generationJob(), current = GenerationCurrentToken(job.request.token)
        let task = Task { try await service.generate(job, currentToken: { await current.value }) }
        await backend.waitForCalls(1)
        await current.revoke()
        await backend.complete(0)
        await generationError(task, .staleInput)
        let next = try generationJob(), unrelated = try generationJob()
        let retry = Task { try await service.generate(next, currentToken: { next.request.token }) }
        await backend.waitForCalls(2)
        await backend.complete(1, token: unrelated.request.token)
        await generationError(retry, .staleInput)
    }

    @Test func invalidDimensionsAndCorruptOutputAreRejectedAndReleaseAdmission() async throws {
        let backend = GenerationGateBackend(), budget = AIResourceBudget()
        let service = ImageGenerationService(backend: backend, budget: budget, resources: generationResources())
        for (index, invalidDimensions) in [true, false].enumerated() {
            let job = try generationJob()
            let task = Task { try await service.generate(job, currentToken: { job.request.token }) }
            await backend.waitForCalls(index + 1)
            if invalidDimensions { await backend.complete(index, image: generationImage(width: 2)) }
            else { await backend.fail(index, error: ImageGenerationError.invalidOutput) }
            await generationError(task, .invalidOutput)
            await waitGenerationBudget(budget) { $0.activeInferences == 0 }
        }
    }

    @Test func readinessIsRecheckedAfterWaitingForOtherLocalInference() async throws {
        let budget = AIResourceBudget(), backend = GenerationGateBackend()
        let occupied = try await budget.acquireLocalInference()
        let service = ImageGenerationService(backend: backend, budget: budget, resources: generationResources()), job = try generationJob()
        let task = Task { try await service.generate(job, currentToken: { job.request.token }) }
        await waitGenerationBudget(budget) { $0.waitingInferences == 1 }
        await backend.setStatus(.unavailable(.missingWeights))
        await budget.release(occupied)
        await generationError(task, .unavailable(.missingWeights))
        #expect(await backend.count == 0)
    }

    @Test func globalBackendChangesAreCompositedBeforePublicationForAllSixNativeMasks() async throws {
        let backend = GenerationGateBackend(), resources = generationResources()
        let service = ImageGenerationService(backend: backend, budget: AIResourceBudget(), resources: resources)
        for (index, fixture) in try ImageGenerationFixtures.make().enumerated() {
            let request = try fixture.request(), size = fixture.mask.raster.size
            // The sixth fixture is an already padded preprocessing canvas. This
            // checks its mask without claiming a product outpainting route.
            let job = try ImageGenerationJob(request: request, operation: .inpaint,
                placement: .init(inputSize: size, outputSize: size, inputOriginX: 0, inputOriginY: 0),
                prompt: fixture.prompt, parameters: .init(), seed: 42)
            let task = Task { try await service.generate(job, currentToken: { request.token }) }
            await backend.waitForCalls(index + 1)
            await backend.complete(index, image: generationImage(width: size.width, height: size.height, value: 255))
            let output = try await task.value
            let bytes = try #require(output.raster.image.dataProvider?.data) as Data
            let weights = fixture.mask.raster.bytes
            let preserved = (0..<weights.count).filter { weights[$0] == 0 }
            let replaced = (0..<weights.count).filter { weights[$0] == 255 }
            #expect(!preserved.isEmpty && !replaced.isEmpty)
            #expect(preserved.allSatisfy { bytes[$0 * 4..<$0 * 4 + 4] == fixture.rgba[$0 * 4..<$0 * 4 + 4] })
            #expect(replaced.allSatisfy { bytes[$0 * 4..<$0 * 4 + 4].allSatisfy { $0 == 255 } })
            #expect(output.fingerprint.canonicalPixelSHA256 != request.renderedInput.canonicalPixelSHA256)
            #expect(output.raster.memoryOwnership != nil)
        }
    }

    @Test func compositorMemoryPressureRejectsPublicationAndReleasesInferenceAdmission() async throws {
        let backend = GenerationGateBackend(), budget = AIResourceBudget()
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1))
        let service = ImageGenerationService(backend: backend, budget: budget, resources: resources)
        let job = try generationJob()
        let task = Task { try await service.generate(job, currentToken: { job.request.token }) }
        await backend.waitForCalls(1); await backend.complete(0)
        await generationError(task, .unavailable(.memoryPressure))
        await waitGenerationBudget(budget) { $0.activeInferences == 0 && $0.residentModelBytes == 0 }
        #expect(await resources.state().chargedBytes == 0)
    }

    @Test func opaqueRGBInputExpandsToOpaqueRGBAWhileKeepingPreservedComponents() async throws {
        let backend = GenerationGateBackend()
        let service = ImageGenerationService(backend: backend, budget: AIResourceBudget(), resources: generationResources())
        let job = try generationJob(inputAlpha: false)
        let task = Task { try await service.generate(job, currentToken: { job.request.token }) }
        await backend.waitForCalls(1); await backend.complete(0)
        let output = try await task.value
        #expect(output.fingerprint.format.channels == .rgba)
        let original = try #require(job.request.input.image.dataProvider?.data) as Data
        let bytes = try #require(output.raster.image.dataProvider?.data) as Data
        #expect((0..<6).allSatisfy { bytes[$0 * 4..<$0 * 4 + 3] == original[$0 * 3..<$0 * 3 + 3] && bytes[$0 * 4 + 3] == 255 })
    }

    @Test func expirationDuringFinalCurrentTokenLookupCannotPublishAfterTimerWasCancelled() async throws {
        let backend = GenerationGateBackend(), budget = AIResourceBudget(), job = try generationJob()
        let service = ImageGenerationService(backend: backend, budget: budget, resources: generationResources(), timeout: .seconds(1))
        let gate = GenerationObserverTokenGate(job.request.token)
        let clock = ContinuousClock(), began = clock.now
        let task = Task {
            try await GenerationObserverContext.$isObserver.withValue(true) {
                try await service.generate(job, currentToken: {
                    await gate.token(isObserver: GenerationObserverContext.isObserver)
                })
            }
        }
        await backend.waitForCalls(1); await backend.complete(0)
        // Only the observer's final lookup waits. Detached native work and the
        // actor's completion check have already finished and canceled the timer.
        await gate.waitForObserverLookup()
        await waitGeneration(service) { $0.runningCount == 0 }
        #expect(await generationBudgetState(budget).activeInferences == 0)
        try await clock.sleep(until: began.advanced(by: .milliseconds(1_100)))
        await gate.releaseObserver()
        await generationError(task, .timedOut)
    }
}

private enum GenerationObserverContext { @TaskLocal static var isObserver = false }

private actor GenerationObserverTokenGate {
    private let value: GenerationMaskJobToken
    private var observerLookup: CheckedContinuation<Void, Never>?
    private var observerStarted = false
    private var ready: CheckedContinuation<Void, Never>?
    init(_ value: GenerationMaskJobToken) { self.value = value }
    func token(isObserver: Bool) async -> GenerationMaskJobToken {
        if isObserver {
            await withCheckedContinuation { continuation in
                observerLookup = continuation; observerStarted = true; ready?.resume(); ready = nil
            }
        }
        return value
    }
    func waitForObserverLookup() async {
        if !observerStarted { await withCheckedContinuation { ready = $0 } }
    }
    func releaseObserver() { observerLookup?.resume(); observerLookup = nil }
}

private actor GenerationCurrentToken {
    var value: GenerationMaskJobToken?
    init(_ value: GenerationMaskJobToken) { self.value = value }
    func revoke() { value = nil }
}

private actor GenerationGateBackend: ImageGenerationBackend {
    nonisolated let descriptor: ImageGenerationBackendDescriptor
    private var status: ImageGenerationAvailability
    private var calls: [(ImageGenerationJob, CheckedContinuation<ImageGenerationOutput, Error>?)] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var wasOnMain = false
    var count: Int { calls.count }
    init(status: ImageGenerationAvailability = .available, capability: ImageGenerationCapabilityStatus = .supported, residentBytes: Int64 = 32) {
        descriptor = try! .init(identity: .init(providerID: "test-only.synthetic-generator"),
            operations: [.inpaint: capability], residentMemoryBytes: residentBytes, maximumOutputPixels: 1_048_576)
        self.status = status
    }
    func availability() -> ImageGenerationAvailability { status }
    func setStatus(_ value: ImageGenerationAvailability) { status = value }
    func generate(_ job: ImageGenerationJob) async throws -> ImageGenerationOutput {
        wasOnMain = wasOnMain || Thread.isMainThread; active += 1; maximumActive = max(maximumActive, active)
        return try await withCheckedThrowingContinuation { continuation in
            calls.append((job, continuation))
            let ready = observers.filter { calls.count >= $0.0 }
            observers.removeAll { calls.count >= $0.0 }
            for observer in ready { observer.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func complete(_ index: Int, image: CGImage? = nil, token: GenerationMaskJobToken? = nil) {
        guard calls.indices.contains(index), let continuation = calls[index].1 else { Issue.record("Unknown generation call"); return }
        let job = calls[index].0; calls[index].1 = nil; active -= 1
        do { continuation.resume(returning: try .init(immutableRaster: image.map { .init(immutableImage: $0) } ?? job.request.input,
            token: token ?? job.request.token)) }
        catch { continuation.resume(throwing: error) }
    }
    func fail(_ index: Int, error: any Error) {
        guard calls.indices.contains(index), let continuation = calls[index].1 else { Issue.record("Unknown generation call"); return }
        calls[index].1 = nil; active -= 1; continuation.resume(throwing: error)
    }
}

private func generationJob(inputAlpha: Bool = true) throws -> ImageGenerationJob {
    let size = try ArtifactPixelSize(width: 3, height: 2)
    let mask = try FrozenGenerationMask.capture(document: .init(canvasSize: size), modelSize: size)
    let snapshot = AIEditingSnapshot(assetID: "synthetic", source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/picedit-synthetic-generation.png"),
        modifiedAt: .distantPast, fileSize: 3)), settings: .neutral,
        token: .init(editSessionID: UUID(), editGeneration: 1, selectionSessionID: UUID(), selectionGeneration: 1))
    return try ImageGenerationJob(request: .init(snapshot: snapshot, immutableInput: .init(immutableImage: generationImage(alpha: inputAlpha)), mask: mask),
        operation: .inpaint, placement: .init(inputSize: size, outputSize: size, inputOriginX: 0, inputOriginY: 0),
        prompt: "Remove synthetic object", parameters: .init(), seed: 7)
}

private func generationImage(width: Int = 3, height: Int = 2, value: UInt8 = 127, alpha: Bool = true) -> CGImage {
    let components = alpha ? 4 : 3
    let bytes = Data(repeating: value, count: width * height * components)
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: components * 8, bytesPerRow: width * components,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : .none).rawValue),
        provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
private func generationResources() -> ArtifactResourceOwner { ArtifactResourceOwner(limits: try! .init()) }
private func generationError(_ task: Task<ImageGenerationOutput, Error>, _ expected: ImageGenerationError) async {
    do { _ = try await task.value; Issue.record("Expected \(expected)") }
    catch { #expect(error as? ImageGenerationError == expected) }
}
private func waitGeneration(_ service: ImageGenerationService, until predicate: (ImageGenerationService.State) -> Bool) async {
    for await state in await service.stateUpdates() { if predicate(state) { return } }
}
private func generationBudgetState(_ budget: AIResourceBudget) async -> AIResourceBudget.State {
    for await state in await budget.stateUpdates() { return state }
    preconditionFailure("No resource state")
}
private func waitGenerationBudget(_ budget: AIResourceBudget, until predicate: (AIResourceBudget.State) -> Bool) async {
    for await state in await budget.stateUpdates() { if predicate(state) { return } }
}
