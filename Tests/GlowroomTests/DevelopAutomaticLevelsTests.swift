import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Automatic Levels accepted-frame transactions")
@MainActor
struct DevelopAutomaticLevelsTests {
    private var proposal: LevelsSettings { .init(master: .init(inputBlack: 0.2, inputWhite: 0.8)) }

    private func fixture(probe: AutomaticLevelsProbe, initial: EditSettings = .neutral,
                         validate: @escaping DevelopWorkspace.ValidateLevels = { _, _, _ in },
                         failsSave: Bool = false) async throws -> LevelsPickerFixture {
        try await LevelsPickerFixture.make(initial: initial,
            sample: { _, _, _ in throw LevelsSamplingError.insufficientCoverage },
            validate: validate, failsSave: failsSave, estimate: probe.estimate)
    }
    private func apply(_ fixture: LevelsPickerFixture,
                       isCurrent: @escaping @MainActor () -> Bool = { true }) throws -> Task<Void, Never> {
        try #require(fixture.workspace.applyAutomaticLevels(assetID: fixture.asset.id, editor: fixture.editor,
            selection: fixture.selection, isCurrent: isCurrent))
    }

    @Test(arguments: [ToneProcessingVersion.legacyV1, .consistentV2])
    func replacesOnlyCompleteLevelsWithOneUndoAndIsIdempotent(version: ToneProcessingVersion) async throws {
        var initial = EditSettings(exposure: 0.4, texture: 12, toneProcessingVersion: version)
        initial.levels = .init(master: .init(inputBlack: 0.05, inputWhite: 0.95, gamma: 2, clampInput: true),
            red: .init(inputBlack: 0.1, gamma: 1.5, clampOutput: true), green: .init(outputBlack: 0.1),
            blue: .init(outputWhite: 0.9))
        let probe = AutomaticLevelsProbe(results: [.value(proposal), .value(proposal)])
        let fixture = try await fixture(probe: probe, initial: initial)
        defer { fixture.workspace.clear() }
        await (try apply(fixture)).value
        var expected = initial; expected.levels = proposal
        #expect(fixture.settings == expected)
        #expect(!fixture.workspace.automaticLevelsBusy)
        #expect(await probe.identities() == [[fixture.input.rangeSourceIdentity, fixture.decoded.rangeSourceIdentity]])
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == initial && !fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.settings == expected)
        fixture.refreshDisplay()
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        await (try apply(fixture)).value
        #expect(fixture.editor.localRevision(for: fixture.asset.id) == revision)
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id] == expected)
    }

    @Test(arguments: AutomaticLevelsInvalidation.allCases, [false, true])
    func staleSuccessAndFailureCannotAffectAnyNewState(change: AutomaticLevelsInvalidation, fails: Bool) async throws {
        let latch = TestAsyncLatch()
        let probe = AutomaticLevelsProbe(results: [.value(proposal)], latches: [latch], fails: fails)
        let fixture = try await fixture(probe: probe)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        var visible = fixture.selection
        let operation = try apply(fixture, isCurrent: { visible == fixture.selection })
        try await probe.wait(1)
        #expect(fixture.workspace.automaticLevelsBusy)
        switch change {
        case .selectionABA:
            visible = .init(sessionID: visible.sessionID, generation: visible.generation + 2)
        case .manualEditUndo:
            fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
            fixture.editor.undo(assetID: fixture.asset.id)
        case .geometryUndoRedo:
            var next = fixture.settings; next.developGeometry.quarterTurns = 1
            fixture.editor.setSettings(next, for: fixture.asset.id)
            fixture.editor.undo(assetID: fixture.asset.id)
            fixture.editor.redo(assetID: fixture.asset.id)
            fixture.editor.undo(assetID: fixture.asset.id)
        case .pending: fixture.workspace.invalidateLevelsDisplay()
        case .frame: fixture.refreshDisplay()
        case .source:
            fixture.workspace.bind(source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/auto-levels-other.png"),
                modifiedAt: .distantPast, fileSize: 1)))
            fixture.workspace.bind(source: fixture.source)
        case .tool: fixture.workspace.tool = .crop
        case .manualPicker: fixture.activate()
        case .whiteBalance: fixture.workspace.picksWhiteBalance = true
        case .readOnly: fixture.editor.beginTermination()
        case .escape: fixture.workspace.endLevelsPicker()
        case .clear: fixture.workspace.clear()
        }
        fixture.workspace.errorMessage = "Neuere Rückmeldung"
        latch.releaseAll(); await operation.value
        #expect(fixture.settings == .neutral)
        #expect(fixture.workspace.errorMessage == "Neuere Rückmeldung")
        #expect(!fixture.workspace.automaticLevelsBusy)
        fixture.editor.cancelTermination()
        #expect(await fixture.editor.flush())
    }

    @Test func repeatedActionCoalescesAndOnlyLatestCanCommit() async throws {
        let latch = TestAsyncLatch()
        let old = LevelsSettings(master: .init(inputBlack: 0.1, inputWhite: 0.9))
        let probe = AutomaticLevelsProbe(results: [.value(old), .value(proposal)],
            latches: [latch, TestAsyncLatch(open: true)])
        let fixture = try await fixture(probe: probe)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        let first = try apply(fixture); try await probe.wait(1)
        let latest = try apply(fixture); await latest.value
        #expect(fixture.settings.levels == proposal)
        latch.releaseAll(); await first.value
        #expect(fixture.settings.levels == proposal)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == .neutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [false, true])
    func fullValidationAlsoRechecksRevisionAndSuppressesStaleErrors(fails: Bool) async throws {
        let latch = TestAsyncLatch()
        let validation = AutomaticLevelsValidationProbe(latch: latch, fails: fails)
        let probe = AutomaticLevelsProbe(results: [.value(proposal)])
        let fixture = try await fixture(probe: probe, validate: validation.validate)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        let operation = try apply(fixture)
        try await waitForTestState("automatic Levels validation", state: { await validation.calls() }, until: { $0 == 1 })
        fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
        fixture.editor.undo(assetID: fixture.asset.id)
        latch.releaseAll(); await operation.value
        #expect(fixture.settings == .neutral && fixture.workspace.errorMessage == nil)
        #expect(!fixture.workspace.automaticLevelsBusy)
        #expect(await fixture.editor.flush())
    }

    @Test func invalidProposalCannotBeNormalizedIntoAnEdit() async throws {
        let probe = AutomaticLevelsProbe(results: [.value(.init(master: .init(inputBlack: 0.8, inputWhite: 0.2)))])
        let fixture = try await fixture(probe: probe)
        defer { fixture.workspace.clear() }
        await (try apply(fixture)).value
        #expect(fixture.settings == .neutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(fixture.workspace.errorMessage != nil)
        #expect(await fixture.editor.flush())
    }

    @Test func noProposalExplainsUnchangedLevelsWithoutUndo() async throws {
        var initial = EditSettings.neutral
        initial.levels.red.gamma = 1.4
        let probe = AutomaticLevelsProbe(results: [.noProposal(.insufficientRange)])
        let fixture = try await fixture(probe: probe, initial: initial)
        defer { fixture.workspace.clear() }
        await (try apply(fixture)).value
        #expect(fixture.settings == initial && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(fixture.workspace.errorMessage == AutomaticLevelsNoProposalReason.insufficientRange.explanation)
        #expect(!fixture.workspace.automaticLevelsBusy)
        #expect(await fixture.editor.flush())
    }

    @Test func readOnlyCannotStartAndCurrentWorkerErrorPreservesTheSnapshot() async throws {
        let probe = AutomaticLevelsProbe(results: [.value(proposal)], fails: true)
        let fixture = try await fixture(probe: probe)
        defer { fixture.workspace.clear() }
        fixture.editor.beginTermination()
        #expect(fixture.workspace.applyAutomaticLevels(assetID: fixture.asset.id, editor: fixture.editor,
            selection: fixture.selection, isCurrent: { true }) == nil)
        #expect(await probe.calls() == 0)
        fixture.editor.cancelTermination()
        // Read-only invalidates the editor generation; only a newly accepted
        // frame may authorize the next operation after editing resumes.
        fixture.refreshDisplay()
        await (try apply(fixture)).value
        #expect(fixture.workspace.errorMessage != nil && fixture.settings == .neutral)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func persistenceFailureKeepsAcceptedEditAndSupportsRetry() async throws {
        let probe = AutomaticLevelsProbe(results: [.value(proposal)])
        let fixture = try await fixture(probe: probe, failsSave: true)
        defer { fixture.workspace.clear() }
        await (try apply(fixture)).value
        #expect(fixture.settings.levels == proposal)
        #expect(await fixture.editor.flush() == false)
        #expect(fixture.editor.errorMessage != nil)
        await fixture.store.allowSave()
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id]?.levels == proposal)
    }

    @Test(arguments: LevelsDisplayGate.allCases)
    func incompleteFrameCannotStart(gate: LevelsDisplayGate) async throws {
        let probe = AutomaticLevelsProbe(results: [])
        let fixture = try await fixture(probe: probe)
        defer { fixture.workspace.clear() }
        switch gate {
        case .embedded: fixture.refreshDisplay(allowsEmbeddedPreview: true)
        case .missingToken: fixture.refreshDisplay(sourceToken: nil)
        case .missingRevision: fixture.refreshDisplay(includesRevision: false)
        case .missingSelection: fixture.refreshDisplay(hasSelection: false)
        case .pendingRetry: fixture.workspace.invalidateLevelsDisplay()
        }
        #expect(fixture.workspace.applyAutomaticLevels(assetID: fixture.asset.id, editor: fixture.editor,
            selection: fixture.selection, isCurrent: { true }) == nil)
        #expect(await probe.calls() == 0)
        #expect(await fixture.editor.flush())
    }
}

enum AutomaticLevelsInvalidation: CaseIterable, Sendable {
    case selectionABA, manualEditUndo, geometryUndoRedo, pending, frame, source, tool, manualPicker, whiteBalance, readOnly, escape, clear
}

private actor AutomaticLevelsProbe {
    let results: [AutomaticLevelsEstimate]
    let latches: [TestAsyncLatch]
    let fails: Bool
    private var inputs: [[UUID]] = []
    init(results: [AutomaticLevelsEstimate], latches: [TestAsyncLatch] = [], fails: Bool = false) {
        self.results = results; self.latches = latches; self.fails = fails
    }
    nonisolated var estimate: DevelopWorkspace.EstimateLevels { { try await self.run($0, $1, $2) } }
    func calls() -> Int { inputs.count }
    func identities() -> [[UUID]] { inputs }
    nonisolated func wait(_ count: Int) async throws {
        try await waitForTestState("automatic Levels estimate", state: { await self.calls() }, until: { $0 >= count })
    }
    private func run(_ bitmap: PreviewBitmap, _ source: PreviewBitmap, _ settings: EditSettings) async throws -> AutomaticLevelsEstimate {
        let index = inputs.count; inputs.append([bitmap.rangeSourceIdentity, source.rangeSourceIdentity])
        if latches.indices.contains(index) { await latches[index].wait() }
        if fails { throw EditRenderError.unavailable }
        return results[index]
    }
}

private actor AutomaticLevelsValidationProbe {
    let latch: TestAsyncLatch
    let fails: Bool
    private var count = 0
    init(latch: TestAsyncLatch, fails: Bool) { self.latch = latch; self.fails = fails }
    func calls() -> Int { count }
    nonisolated var validate: DevelopWorkspace.ValidateLevels { { _, _, _ in try await self.run() } }
    private func run() async throws {
        count += 1; await latch.wait()
        if fails { throw EditRenderError.unrepresentableLevels }
    }
}
