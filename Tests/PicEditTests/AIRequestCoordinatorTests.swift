import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("AI request scheduling", .timeLimit(.minutes(1)))
struct AIRequestCoordinatorTests {
    @Test
    func lookGroupSharesOneCallAndBindsEachOriginalRequest() async throws {
        let provider = GatedAIProvider(capabilities: [.lookSuggestions])
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let a = request(prompt: "", mode: .lookGroup)
        let b = request(prompt: "", mode: .lookGroup)
        let first = Task { try await coordinator.lookGroup(for: a) }
        await provider.waitUntilStarted(a.id)
        let second = Task { try await coordinator.lookGroup(for: b) }
        await wait(coordinator) { $0.waiterCount == 2 }
        await provider.complete(a.id, with: validLookResponse)
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult.request == a)
        #expect(secondResult.request == b)
        #expect(firstResult.validation == secondResult.validation)
        #expect(firstResult.validation.variants.map(\.proposal.id) == AILookID.allCases)
        #expect(await provider.statistics().started == [a.id])
    }

    @Test
    func singleAndLookModesNeverCoalesceAndKeepTheSameWorkerSlot() async throws {
        let provider = GatedAIProvider(capabilities: [.textEditing, .lookSuggestions])
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let single = request(prompt: "same text")
        let looks = request(prompt: "same text", mode: .lookGroup)
        let first = Task { try await coordinator.proposal(for: single) }
        await provider.waitUntilStarted(single.id)
        let second = Task { try await coordinator.lookGroup(for: looks) }
        await wait(coordinator) { $0.queuedRequestID == looks.id }
        await expectError(first, .superseded)
        #expect(await provider.statistics().started == [single.id])
        await provider.complete(single.id, with: validResponse)
        await provider.waitUntilStarted(looks.id)
        await provider.complete(looks.id, with: validLookResponse)
        #expect(try await second.value.request == looks)
        #expect(await provider.statistics().maximumActive == 1)
    }

    @Test
    func twentyLookRequestsRemainBoundedAfterCancellation() async throws {
        let provider = GatedAIProvider(capabilities: [.lookSuggestions])
        let budget = AIResourceBudget()
        let coordinator = AIRequestCoordinator(provider: provider, budget: budget)
        let original = request(prompt: "", mode: .lookGroup)
        let first = Task { try await coordinator.lookGroup(for: original) }
        await provider.waitUntilStarted(original.id)
        first.cancel()
        await expectCancelled(first)
        var latest: Task<AILookGroupResult, Error>?
        var lastRequest: AIEditingRequest?
        for index in 0..<20 {
            let nextRequest = request(prompt: "look \(index)", mode: .lookGroup)
            let next = Task { try await coordinator.lookGroup(for: nextRequest) }
            await wait(coordinator) { state in
                #expect(state.runningCount <= 1 && state.queuedCount <= 1)
                return state.queuedRequestID == nextRequest.id
            }
            if let latest { await expectError(latest, .superseded) }
            latest = next
            lastRequest = nextRequest
        }
        #expect(await provider.statistics().started == [original.id])
        await wait(budget) { $0.activeInferences == 1 }
        let finalRequest = try #require(lastRequest)
        let final = try #require(latest)
        await provider.complete(original.id, with: validLookResponse)
        await provider.waitUntilStarted(finalRequest.id)
        await provider.complete(finalRequest.id, with: validLookResponse)
        #expect(try await final.value.request == finalRequest)
        #expect(await provider.statistics().maximumActive == 1)
        await wait(budget) { $0.activeInferences == 0 }
    }

    @Test
    func invalidGroupPublishesNoPartialResultAndReleasesTheSharedBudget() async throws {
        let provider = GatedAIProvider(capabilities: [.textEditing, .lookSuggestions])
        let budget = AIResourceBudget()
        let coordinator = AIRequestCoordinator(provider: provider, budget: budget)
        let looks = request(prompt: "", mode: .lookGroup)
        let groupTask = Task { try await coordinator.lookGroup(for: looks) }
        await provider.waitUntilStarted(looks.id)
        await provider.complete(looks.id, with: Data(String(decoding: validLookResponse, as: UTF8.self).replacingOccurrences(of: "desaturated", with: "natural").utf8))
        await expectError(groupTask, .invalidResponse(.invalidLookID))
        await wait(budget) { $0.activeInferences == 0 }
        let single = request()
        let retry = Task { try await coordinator.proposal(for: single) }
        await provider.waitUntilStarted(single.id)
        await provider.complete(single.id, with: validResponse)
        #expect(try await retry.value.request == single)
    }

    @Test
    func modeAndCapabilityChecksPrecedeAnyProviderWork() async {
        let provider = GatedAIProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        await expectError(Task { try await coordinator.lookGroup(for: request()) }, .invalidRequest)
        await expectError(Task { try await coordinator.proposal(for: request(mode: .lookGroup)) }, .invalidRequest)
        await expectError(Task { try await coordinator.lookGroup(for: request(mode: .lookGroup)) }, .unsupportedCapability)
        #expect(await provider.statistics().availabilityCalls == 0)
        #expect(await provider.statistics().started.isEmpty)
    }
    @Test
    func validatesAndBindsResultsToEachSharedRequest() async throws {
        let provider = GatedAIProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let firstRequest = request()
        let secondRequest = request()
        let first = Task { try await coordinator.proposal(for: firstRequest) }
        await provider.waitUntilStarted(firstRequest.id)
        let second = Task { try await coordinator.proposal(for: secondRequest) }
        await wait(coordinator) { $0.waiterCount == 2 }
        await provider.complete(firstRequest.id, with: validResponse)
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult.request == firstRequest)
        #expect(secondResult.request == secondRequest)
        #expect(firstResult.validation == secondResult.validation)
        guard case .changes(_, let target) = firstResult.validation else {
            Issue.record("Expected a validated settings patch")
            return
        }
        #expect(target.shadows == 30)
        #expect(target.exposure == firstRequest.snapshot.settings.exposure)
        #expect(await provider.statistics().started == [firstRequest.id])
    }

    @Test
    func sharedInferenceSurvivesOneCancelledWaiter() async throws {
        let provider = GatedAIProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let firstRequest = request()
        let secondRequest = request()
        let first = Task { try await coordinator.proposal(for: firstRequest) }
        await provider.waitUntilStarted(firstRequest.id)
        let second = Task { try await coordinator.proposal(for: secondRequest) }
        await wait(coordinator) { $0.waiterCount == 2 }
        first.cancel()
        await expectCancelled(first)
        await provider.complete(firstRequest.id, with: validResponse)
        #expect(try await second.value.request == secondRequest)
        #expect(await provider.statistics().started == [firstRequest.id])
    }

    @Test
    func twentyRapidRequestsKeepOnlyLatestQueuedAndRetainCancelledSlot() async throws {
        let provider = GatedAIProvider()
        let budget = AIResourceBudget()
        let coordinator = AIRequestCoordinator(provider: provider, budget: budget)
        let firstRequest = request(prompt: "first")
        let first = Task { try await coordinator.proposal(for: firstRequest) }
        await provider.waitUntilStarted(firstRequest.id)
        first.cancel()
        await expectCancelled(first)

        var latest: Task<AIProposalResult, Error>?
        var latestRequest: AIEditingRequest?
        for index in 0..<20 {
            let nextRequest = request(prompt: "change \(index)")
            let next = Task { try await coordinator.proposal(for: nextRequest) }
            await wait(coordinator) { state in
                #expect(state.runningCount <= 1)
                #expect(state.queuedCount <= 1)
                return state.queuedRequestID == nextRequest.id
            }
            if let latest { await expectError(latest, .superseded) }
            latest = next
            latestRequest = nextRequest
        }
        #expect(await provider.statistics().started == [firstRequest.id])
        await wait(budget) { $0.activeInferences == 1 && $0.waitingInferences == 0 }
        let finalRequest = try #require(latestRequest)
        let final = try #require(latest)
        await provider.complete(firstRequest.id, with: validResponse)
        await provider.waitUntilStarted(finalRequest.id)
        await provider.complete(finalRequest.id, with: validResponse)
        #expect(try await final.value.request == finalRequest)
        #expect(await provider.statistics().started == [firstRequest.id, finalRequest.id])
        #expect(await provider.statistics().maximumActive == 1)
        await wait(budget) { $0.activeInferences == 0 && $0.waitingInferences == 0 }
    }

    @Test
    func newerContextSupersedesRunningCallerAndQueuedCancellationIsImmediate() async throws {
        let provider = GatedAIProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let firstRequest = request(prompt: "old")
        let nextRequest = request(prompt: "new")
        let first = Task { try await coordinator.proposal(for: firstRequest) }
        await provider.waitUntilStarted(firstRequest.id)
        let next = Task { try await coordinator.proposal(for: nextRequest) }
        await wait(coordinator) { $0.queuedRequestID == nextRequest.id }
        await expectError(first, .superseded)
        next.cancel()
        await expectCancelled(next)
        await wait(coordinator) { $0.queuedCount == 0 && $0.waiterCount == 0 }
        await provider.complete(firstRequest.id, with: validResponse)
        await wait(coordinator) { $0.runningCount == 0 }
        #expect(await provider.statistics().started == [firstRequest.id])
    }

    @Test
    func cancelledGenerationCannotRemoveReplacementWithIdenticalContext() async throws {
        let provider = GatedAIProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let firstRequest = request()
        let nextRequest = request()
        let first = Task { try await coordinator.proposal(for: firstRequest) }
        await provider.waitUntilStarted(firstRequest.id)
        first.cancel()
        await expectCancelled(first)
        let next = Task { try await coordinator.proposal(for: nextRequest) }
        await wait(coordinator) { $0.queuedRequestID == nextRequest.id }
        await provider.complete(firstRequest.id, with: validResponse)
        await provider.waitUntilStarted(nextRequest.id)
        await provider.complete(nextRequest.id, with: validResponse)
        #expect(try await next.value.request == nextRequest)
        #expect(await provider.statistics().maximumActive == 1)
    }

    @Test
    func sharedBudgetRetainsLeaseAcrossCoordinatorsUntilProviderActuallyReturns() async throws {
        let budget = AIResourceBudget()
        let firstProvider = GatedAIProvider()
        let secondProvider = GatedAIProvider()
        let firstCoordinator = AIRequestCoordinator(provider: firstProvider, budget: budget)
        let secondCoordinator = AIRequestCoordinator(provider: secondProvider, budget: budget)
        let firstRequest = request()
        let secondRequest = request()
        let first = Task { try await firstCoordinator.proposal(for: firstRequest) }
        await firstProvider.waitUntilStarted(firstRequest.id)
        let second = Task { try await secondCoordinator.proposal(for: secondRequest) }
        await wait(budget) { $0.activeInferences == 1 && $0.waitingInferences == 1 }
        first.cancel()
        await expectCancelled(first)
        #expect(await secondProvider.statistics().started.isEmpty)
        await firstProvider.complete(firstRequest.id, with: validResponse)
        await secondProvider.waitUntilStarted(secondRequest.id)
        await secondProvider.complete(secondRequest.id, with: validResponse)
        _ = try await second.value
        await wait(budget) { $0.activeInferences == 0 && $0.waitingInferences == 0 }
    }

    @Test
    func cancellingBudgetWaiterDoesNotLeakAdmissionOrStartProvider() async throws {
        let budget = AIResourceBudget()
        let firstProvider = GatedAIProvider()
        let waitingProvider = GatedAIProvider()
        let firstCoordinator = AIRequestCoordinator(provider: firstProvider, budget: budget)
        let waitingCoordinator = AIRequestCoordinator(provider: waitingProvider, budget: budget)
        let firstRequest = request()
        let waitingRequest = request()
        let first = Task { try await firstCoordinator.proposal(for: firstRequest) }
        await firstProvider.waitUntilStarted(firstRequest.id)
        let waiting = Task { try await waitingCoordinator.proposal(for: waitingRequest) }
        await wait(budget) { $0.waitingInferences == 1 }
        waiting.cancel()
        await expectCancelled(waiting)
        await wait(budget) { $0.activeInferences == 1 && $0.waitingInferences == 0 }
        #expect(await waitingProvider.statistics().started.isEmpty)
        await firstProvider.complete(firstRequest.id, with: validResponse)
        _ = try await first.value
        await wait(budget) { $0.activeInferences == 0 }

        let retryRequest = request()
        let retry = Task { try await waitingCoordinator.proposal(for: retryRequest) }
        await waitingProvider.waitUntilStarted(retryRequest.id)
        await waitingProvider.complete(retryRequest.id, with: validResponse)
        _ = try await retry.value
    }

    @Test
    func failureInvalidResponseAndNoChangeAllReleaseLease() async throws {
        let provider = GatedAIProvider()
        let budget = AIResourceBudget()
        let coordinator = AIRequestCoordinator(provider: provider, budget: budget)
        let failedRequest = request()
        let failed = Task { try await coordinator.proposal(for: failedRequest) }
        await provider.waitUntilStarted(failedRequest.id)
        await provider.fail(failedRequest.id)
        await expectError(failed, .providerFailure)
        await wait(budget) { $0.activeInferences == 0 }

        let invalidRequest = request()
        let invalid = Task { try await coordinator.proposal(for: invalidRequest) }
        await provider.waitUntilStarted(invalidRequest.id)
        await provider.complete(invalidRequest.id, with: Data("private invalid response".utf8))
        await expectError(invalid, .invalidResponse(.malformedJSON))
        await wait(budget) { $0.activeInferences == 0 }

        let noChangeRequest = request()
        let noChange = Task { try await coordinator.proposal(for: noChangeRequest) }
        await provider.waitUntilStarted(noChangeRequest.id)
        await provider.complete(noChangeRequest.id, with: Data(#"{"schemaVersion":1,"changes":[]}"#.utf8))
        #expect(try await noChange.value.validation == .noChange())
        #expect(await provider.statistics().maximumActive == 1)
        await wait(budget) { $0.activeInferences == 0 }
    }

    @Test
    func rejectsInvalidInputsUnsupportedCapabilityAndUnavailableProvider() async {
        let provider = GatedAIProvider()
        let coordinator = AIRequestCoordinator(provider: provider,
            budget: AIResourceBudget(limits: .init(maximumPromptBytes: 4)))
        await expectError(Task { try await coordinator.proposal(for: request(prompt: "too long")) }, .invalidRequest)
        await expectError(Task { try await coordinator.proposal(for: request(prompt: "  ")) }, .invalidRequest)
        #expect(await provider.statistics().availabilityCalls == 0)
        #expect(await provider.statistics().started.isEmpty)

        let unsupported = GatedAIProvider(capabilities: [.imageGeneration])
        let unsupportedCoordinator = AIRequestCoordinator(provider: unsupported, budget: AIResourceBudget())
        await expectError(Task { try await unsupportedCoordinator.proposal(for: request()) }, .unsupportedCapability)
        #expect(await unsupported.statistics().availabilityCalls == 0)

        let unavailable = GatedAIProvider(availability: .unavailable(.modelUnavailable))
        let unavailableCoordinator = AIRequestCoordinator(provider: unavailable, budget: AIResourceBudget())
        await expectError(Task { try await unavailableCoordinator.proposal(for: request()) }, .unavailable(.modelUnavailable))
        #expect(await unavailable.statistics().started.isEmpty)
    }

    @Test
    func responseByteLimitAppliesEvenWithLargerInjectedValidator() async throws {
        let provider = GatedAIProvider()
        let budget = AIResourceBudget(limits: .init(maximumResponseBytes: 4))
        let coordinator = AIRequestCoordinator(provider: provider, budget: budget,
            validator: EditProposalValidator(maximumResponseBytes: 1_024))
        let input = request()
        let result = Task { try await coordinator.proposal(for: input) }
        await provider.waitUntilStarted(input.id)
        await provider.complete(input.id, with: validResponse)
        await expectError(result, .invalidResponse(.responseTooLarge))
        await wait(budget) { $0.activeInferences == 0 }
    }

    @Test
    func cancelAllCanRepeatAndStillRetainsNonCooperativeProviderSlot() async throws {
        let provider = GatedAIProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let input = request()
        let result = Task { try await coordinator.proposal(for: input) }
        await provider.waitUntilStarted(input.id)
        await coordinator.cancelAll()
        await coordinator.cancelAll()
        await expectCancelled(result)
        await wait(coordinator) { $0.runningCount == 1 && $0.waiterCount == 0 }
        await provider.complete(input.id, with: validResponse)
        await wait(coordinator) { $0.runningCount == 0 }
    }

    @Test @MainActor
    func nonCooperativeProviderLeavesMainActorResponsive() async throws {
        let provider = GatedAIProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let input = request()
        let result = Task { try await coordinator.proposal(for: input) }
        await provider.waitUntilStarted(input.id)
        // A main-actor hop completes while the provider's gate remains closed.
        let marker = await MainActor.run { 42 }
        #expect(marker == 42)
        #expect(await provider.statistics().active == 1)
        await provider.complete(input.id, with: validResponse)
        _ = try await result.value
    }

    private var validResponse: Data {
        Data(#"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":30}]}"#.utf8)
    }

    private var validLookResponse: Data {
        Data(#"{"schemaVersion":1,"variants":[{"id":"natural","name":"Natürlich","proposal":{"schemaVersion":1,"changes":[{"parameter":"contrast","value":8}]}},{"id":"contrasty","name":"Kontrastreich","proposal":{"schemaVersion":1,"changes":[{"parameter":"contrast","value":35}]}},{"id":"desaturated","name":"Entsättigt","proposal":{"schemaVersion":1,"changes":[{"parameter":"saturation","value":-35}]}}]}"#.utf8)
    }

    private func request(prompt: String = "Lift shadows", mode: AIEditingMode = .single) -> AIEditingRequest {
        AIEditingRequest(prompt: prompt, snapshot: AIEditingSnapshot(assetID: "asset-1",
            source: .original(AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/tmp/ai-test.raw"),
                modifiedAt: Date(timeIntervalSince1970: 100), fileSize: 10)),
            settings: .neutral,
            token: AIEditingToken(editSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                editGeneration: 0, selectionSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                selectionGeneration: 0)), mode: mode)
    }

    private func wait(_ coordinator: AIRequestCoordinator, until predicate: (AIRequestCoordinator.State) -> Bool) async {
        for await state in await coordinator.stateUpdates() {
            if predicate(state) { return }
        }
        Issue.record("Coordinator state stream ended before the expected state")
    }

    private func wait(_ budget: AIResourceBudget, until predicate: (AIResourceBudget.State) -> Bool) async {
        for await state in await budget.stateUpdates() {
            #expect(state.activeInferences <= budget.limits.maximumConcurrentLocalInferences)
            if predicate(state) { return }
        }
        Issue.record("Resource state stream ended before the expected state")
    }

    private func expectCancelled<T: Sendable>(_ task: Task<T, Error>) async {
        do { _ = try await task.value; Issue.record("Canceled caller received a proposal") }
        catch is CancellationError {} catch { Issue.record("Expected cancellation, received \(error)") }
    }

    private func expectError<T: Sendable>(_ task: Task<T, Error>, _ expected: AIEditingError) async {
        do { _ = try await task.value; Issue.record("Expected \(expected), received a proposal") }
        catch let error as AIEditingError { #expect(error == expected) }
        catch { Issue.record("Expected \(expected), received \(error)") }
    }
}

/// Deliberately ignores cancellation. Tests advance explicit continuations and
/// receive start events, so scheduling assertions require no sleeps or polling.
private actor GatedAIProvider: AIEditingProvider {
    nonisolated let id = "deterministic-test-provider"
    nonisolated let capabilities: AIProviderCapabilities
    private let status: AIAvailability
    private var gates: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var startWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var started: [UUID] = []
    private var active = 0
    private var maximumActive = 0
    private var availabilityCalls = 0

    struct Statistics: Sendable {
        let started: [UUID]
        let active: Int
        let maximumActive: Int
        let availabilityCalls: Int
    }

    init(capabilities: AIProviderCapabilities = [.textEditing], availability: AIAvailability = .available) {
        self.capabilities = capabilities
        status = availability
    }

    func availability() async -> AIAvailability {
        availabilityCalls += 1
        return status
    }

    func proposal(for request: AIEditingRequest) async throws -> Data {
        active += 1
        maximumActive = max(maximumActive, active)
        started.append(request.id)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            gates[request.id] = continuation
            for waiter in startWaiters.removeValue(forKey: request.id) ?? [] { waiter.resume() }
        }
    }

    func waitUntilStarted(_ id: UUID) async {
        if started.contains(id) { return }
        await withCheckedContinuation { startWaiters[id, default: []].append($0) }
    }

    func complete(_ id: UUID, with data: Data) {
        guard let gate = gates.removeValue(forKey: id) else {
            Issue.record("Attempted to release a provider call that has not started")
            return
        }
        gate.resume(returning: data)
    }

    func fail(_ id: UUID) {
        gates.removeValue(forKey: id)?.resume(throwing: PrivateProviderFailure())
    }

    func statistics() -> Statistics {
        Statistics(started: started, active: active, maximumActive: maximumActive, availabilityCalls: availabilityCalls)
    }
}

private struct PrivateProviderFailure: Error, CustomStringConvertible {
    var description: String { "Sensitive provider payload must never cross the boundary" }
}
