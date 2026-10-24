import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Levels picker accepted-frame transactions")
@MainActor
struct DevelopLevelsPickerTests {
    @Test func acceptedPickerUsesActualProxyAndOneUndoablePersistentReplacement() async throws {
        let probe = LevelsSampleProbe(samples: [.init(red: 0.25, green: 0.2, blue: 0.1)])
        let initial = EditSettings(exposure: 0.5, texture: 8, toneProcessingVersion: .consistentV2)
        let fixture = try await LevelsPickerFixture.make(initial: initial, sample: probe.sample)
        defer { fixture.workspace.clear() }
        fixture.activate()
        await (try #require(fixture.pick())).value
        var expected = initial; expected.levels.master.gamma = 2
        #expect(fixture.settings == expected)
        #expect(await probe.inputs() == [fixture.input.rangeSourceIdentity])
        #expect(fixture.input.image !== fixture.decoded.image)
        #expect(fixture.workspace.levelsPicker == nil)
        #expect(fixture.workspace.levelsSampleDescription == "Probe 5 × 5 in 8 × 8 Pixeln")
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == initial && !fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.settings == expected)
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id] == expected)
        #expect(await probe.calls() == 1)
    }

    @Test func repeatedIdenticalPickDoesNotCreateAnotherRevision() async throws {
        let probe = LevelsSampleProbe(samples: [.init(red: 0.25, green: 0.2, blue: 0.1), .init(red: 0.25, green: 0.2, blue: 0.1)])
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        defer { fixture.workspace.clear() }
        fixture.activate(); await (try #require(fixture.pick())).value
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        fixture.refreshDisplay()
        fixture.activate(); await (try #require(fixture.pick())).value
        #expect(fixture.editor.localRevision(for: fixture.asset.id) == revision)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == .neutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func rgbGrayReplacesAllChannelsAndOnlyTheMatchingMasterParameterWithOneUndo() async throws {
        let probe = LevelsSampleProbe(samples: [.init(red: 0.25, green: 0.2, blue: 0.1)])
        let initial = EditSettings(exposure: 0.5, levels: .init(master: .init(inputBlack: 0.1, inputWhite: 0.9, gamma: 2)))
        let fixture = try await LevelsPickerFixture.make(initial: initial, sample: probe.sample)
        defer { fixture.workspace.clear() }
        fixture.activate(mode: .neutralizeRGB); await (try #require(fixture.pick())).value
        var expected = initial
        expected.levels.master.gamma = 1
        expected.levels.red.gamma = 2
        expected.levels.green.gamma = log(0.2) / log(0.5)
        expected.levels.blue.gamma = log(0.1) / log(0.5)
        #expect(fixture.settings == expected)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == initial && !fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.settings == expected)
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [false, true])
    func manualChangeAndUndoRejectBothLateSuccessAndError(fails: Bool) async throws {
        let latch = TestAsyncLatch()
        let probe = LevelsSampleProbe(samples: [.init(red: 0.25, green: 0.25, blue: 0.25)], latches: [latch], fails: fails)
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        fixture.activate(); let operation = try #require(fixture.pick())
        try await probe.waitForCalls(1)
        fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
        fixture.editor.undo(assetID: fixture.asset.id)
        latch.releaseAll(); await operation.value
        #expect(fixture.settings == .neutral && fixture.workspace.errorMessage == nil)
        #expect(fixture.editor.canRedo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: LevelsPickerInvalidation.allCases, [false, true])
    func staleSuccessesAndErrorsCannotChangeCurrentState(change: LevelsPickerInvalidation, fails: Bool) async throws {
        let latch = TestAsyncLatch()
        let probe = LevelsSampleProbe(samples: [.init(red: 0.25, green: 0.25, blue: 0.25)], latches: [latch], fails: fails)
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        var visibleSelection = fixture.selection
        fixture.activate()
        let operation = try #require(fixture.pick(isCurrent: { visibleSelection == fixture.selection }))
        try await probe.waitForCalls(1)
        switch change {
        case .selectionABA:
            visibleSelection = .init(sessionID: fixture.selection.sessionID, generation: fixture.selection.generation + 2)
        case .profileABA:
            var modified = fixture.settings; modified.developColor.temperature = 7_000
            fixture.editor.setSettings(modified, for: fixture.asset.id); fixture.editor.undo(assetID: fixture.asset.id)
        case .geometryABA:
            var modified = fixture.settings; modified.developGeometry.quarterTurns = 1
            fixture.editor.setSettings(modified, for: fixture.asset.id); fixture.editor.undo(assetID: fixture.asset.id)
        case .freshFrame: fixture.refreshDisplay(sourceToken: UUID())
        case .pendingRetry: fixture.workspace.invalidateLevelsDisplay()
        case .artifactABA:
            fixture.workspace.bind(source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/another-levels-source.png"), modifiedAt: .distantPast, fileSize: 1)))
            fixture.workspace.bind(source: fixture.source)
        case .tool: fixture.workspace.tool = .crop
        case .readOnly: fixture.editor.beginTermination()
        case .escape: fixture.workspace.endLevelsPicker()
        case .clear: fixture.workspace.clear()
        }
        latch.releaseAll(); await operation.value
        #expect(fixture.settings == .neutral)
        #expect(fixture.workspace.errorMessage == nil)
        fixture.editor.cancelTermination()
        #expect(await fixture.editor.flush())
    }

    @Test func newestClickWinsAndOldNativeWorkCannotOverwriteIt() async throws {
        let latch = TestAsyncLatch()
        let probe = LevelsSampleProbe(samples: [.init(red: 0.2, green: 0.1, blue: 0.1), .init(red: 0.25, green: 0.1, blue: 0.1)],
                                      latches: [latch, TestAsyncLatch(open: true)])
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        fixture.activate(); let old = try #require(fixture.pick())
        try await probe.waitForCalls(1)
        let current = try #require(fixture.pick()); await current.value
        #expect(fixture.settings.levels.master.gamma == 2)
        latch.releaseAll(); await old.value
        #expect(fixture.settings.levels.master.gamma == 2)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == .neutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func invalidSamplePreservesAllSettingsAndExplainsTheFailure() async throws {
        let probe = LevelsSampleProbe(samples: [.init(red: 0, green: 0, blue: 0)])
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        defer { fixture.workspace.clear() }
        fixture.activate(); await (try #require(fixture.pick())).value
        #expect(fixture.settings == .neutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(fixture.workspace.errorMessage?.contains("Mittelton") == true)
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [false, true])
    func delayedFullGraphValidationRechecksRevisionBeforeAnyAdoption(fails: Bool) async throws {
        let latch = TestAsyncLatch()
        let validation = LevelsValidationProbe(latch: latch, fails: fails)
        let sample = LevelsSampleProbe(samples: [.init(red: 0.25, green: 0.2, blue: 0.1)])
        let fixture = try await LevelsPickerFixture.make(sample: sample.sample, validate: validation.validate)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        fixture.activate(); let operation = try #require(fixture.pick())
        try await waitForTestState("levels full graph validation", state: { await validation.calls() }, until: { $0 == 1 })
        fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
        fixture.editor.undo(assetID: fixture.asset.id)
        latch.releaseAll(); await operation.value
        #expect(fixture.settings == .neutral && fixture.workspace.errorMessage == nil)
        #expect(await fixture.editor.flush())
    }

    @Test func realWorkerRejectsAnOverflowElsewhereBeforeSavingTheSampledCorrection() async throws {
        var pixels = [Float](repeating: 0, count: 8 * 8 * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = Float(SignedSRGB.decode(0.9))
            pixels[offset + 1] = pixels[offset]; pixels[offset + 2] = pixels[offset]; pixels[offset + 3] = 1
        }
        pixels[0] = 1e30 // Outside the center's 5×5 patch, inside the full range proof.
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: 8 * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let worker = AutomaticToneEstimator()
        let initial = EditSettings(developColor: .init(hdrEnabled: true), toneProcessingVersion: .consistentV2)
        let fixture = try await LevelsPickerFixture.make(initial: initial,
            sample: { try await worker.sampleLevels(bitmap: $0, settings: $1, normalizedTopLeft: $2) },
            validate: { try await worker.validateLevels(bitmap: $0, settings: $1, neutralGraySample: $2) }, input: PreviewBitmap(image: image))
        defer { fixture.workspace.clear() }
        fixture.activate(); await (try #require(fixture.pick())).value
        #expect(fixture.settings == initial)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(fixture.workspace.errorMessage != nil)
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id] == initial)
    }

    @Test func displayedOldRevisionAndProgressiveFramesCannotActivate() async throws {
        let probe = LevelsSampleProbe(samples: [])
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        defer { fixture.workspace.clear() }
        fixture.refreshDisplay(finalSourceReady: false)
        fixture.activate()
        #expect(fixture.workspace.levelsPicker == nil)
        fixture.refreshDisplay()
        fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
        fixture.editor.undo(assetID: fixture.asset.id)
        fixture.activate()
        #expect(fixture.workspace.levelsPicker == nil)
        #expect(fixture.workspace.errorMessage?.contains("aktualisiert") == true)
        #expect(await probe.calls() == 0)
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: LevelsDisplayGate.allCases)
    func incompleteDisplayIdentityCannotActivate(gate: LevelsDisplayGate) async throws {
        let sample = LevelsSampleProbe(samples: [])
        let fixture = try await LevelsPickerFixture.make(sample: sample.sample)
        defer { fixture.workspace.clear() }
        switch gate {
        case .embedded: fixture.refreshDisplay(allowsEmbeddedPreview: true)
        case .missingToken: fixture.refreshDisplay(sourceToken: nil)
        case .missingRevision: fixture.refreshDisplay(includesRevision: false)
        case .missingSelection: fixture.refreshDisplay(hasSelection: false)
        case .pendingRetry: fixture.workspace.invalidateLevelsDisplay()
        }
        fixture.activate()
        #expect(fixture.workspace.levelsPicker == nil)
        #expect(await sample.calls() == 0)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func pickerIsExclusiveWithOtherCanvasToolsAndReadOnlyCannotStart() async throws {
        let probe = LevelsSampleProbe(samples: [])
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        defer { fixture.workspace.clear() }
        fixture.activate(); #expect(fixture.workspace.levelsPicker != nil)
        fixture.workspace.picksWhiteBalance = true
        #expect(fixture.workspace.levelsPicker == nil)
        fixture.activate(); #expect(!fixture.workspace.picksWhiteBalance)
        fixture.workspace.picksDetail = true
        #expect(fixture.workspace.levelsPicker == nil)
        fixture.activate(); #expect(!fixture.workspace.picksDetail)
        fixture.workspace.tool = .repair
        #expect(fixture.workspace.levelsPicker == nil)
        fixture.editor.beginTermination(); fixture.activate()
        #expect(fixture.workspace.levelsPicker == nil)
        #expect(await probe.calls() == 0)
        fixture.editor.cancelTermination()
        #expect(await fixture.editor.flush())
    }

    @Test func persistenceFailureIsVisibleAndAcceptedLocalEditCanBeRetried() async throws {
        let probe = LevelsSampleProbe(samples: [.init(red: 0.25, green: 0.2, blue: 0.1)])
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample, failsSave: true)
        defer { fixture.workspace.clear() }
        fixture.activate(); await (try #require(fixture.pick())).value
        #expect(fixture.settings.levels.master.gamma == 2)
        #expect(await fixture.editor.flush() == false)
        #expect(fixture.editor.errorMessage != nil)
        #expect(await fixture.store.loadAll()[fixture.asset.id] == .neutral)
        await fixture.store.allowSave()
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id]?.levels.master.gamma == 2)
    }
}

enum LevelsPickerInvalidation: CaseIterable, Sendable {
    case selectionABA, profileABA, geometryABA, freshFrame, pendingRetry, artifactABA, tool, readOnly, escape, clear
}
enum LevelsDisplayGate: CaseIterable, Sendable { case embedded, missingToken, missingRevision, missingSelection, pendingRetry }

@MainActor
struct LevelsPickerFixture {
    let asset: PhotoAsset
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let store: LevelsPickerTestStore
    let source: AISourceIdentity
    let selection: DevelopSelectionIdentity
    let decoded: PreviewBitmap
    let input: PreviewBitmap
    var settings: EditSettings { editor.settings(for: asset.id) }

    static func make(initial: EditSettings = .neutral, sample: @escaping DevelopWorkspace.SampleLevels,
                     validate: @escaping DevelopWorkspace.ValidateLevels = { _, _, _ in },
                     input: PreviewBitmap? = nil, failsSave: Bool = false,
                     estimate: DevelopWorkspace.EstimateLevels? = nil) async throws -> Self {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/levels-picker-\(UUID()).png"), pixelWidth: 16, pixelHeight: 16)
        let store = LevelsPickerTestStore(assetID: asset.id, settings: initial, failsSave: failsSave)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitForTestState("levels editor loading", state: { await editor.isLoading }, until: { !$0 })
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        }, sampleLevels: sample, validateLevels: validate, estimateLevels: estimate)
        let source = AISourceIdentity.original(.init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        let result = Self(asset: asset, editor: editor, workspace: workspace, store: store, source: source,
            selection: .init(sessionID: UUID(), generation: 4), decoded: try levelsTransactionBitmap(edge: 16), input: try input ?? levelsTransactionBitmap(edge: 8))
        workspace.bind(source: source)
        result.refreshDisplay()
        return result
    }

    func refreshDisplay(sourceToken: UUID? = UUID(), finalSourceReady: Bool = true,
                        allowsEmbeddedPreview: Bool = false, includesRevision: Bool = true, hasSelection: Bool = true) {
        let request = PreviewRequest(source: source, pixelSize: 16, allowsEmbeddedPreview: allowsEmbeddedPreview)
        let revision = DevelopPreviewRevision(assetID: asset.id, editorSessionID: editor.aiEditSessionID,
            editorGeneration: editor.aiEditGeneration, localRevision: editor.localRevision(for: asset.id),
            selection: hasSelection ? selection : nil, intent: .currentEditing)
        let identity = DevelopPreviewRenderIdentity(request: request, settings: settings.normalized,
            revision: includesRevision ? revision : nil, sourceToken: sourceToken, finalSourceReady: finalSourceReady)
        workspace.receive(input, sourceBitmap: decoded)
        workspace.markDisplayed(source: source, settings: settings)
        workspace.receiveLevelsDisplay(.init(identity: identity, frame: .init(actualInput: input, output: input), decodedSource: decoded))
    }

    func activate(point: LevelsPickerPoint = .gray, mode: LevelsPickerMode = .setTone, channel: LevelsChannel = .master) {
        workspace.beginLevelsPicker(.init(point: point, mode: mode, channel: channel), assetID: asset.id,
            editor: editor, selection: selection, isCurrent: true)
    }

    func pick(isCurrent: @escaping @MainActor () -> Bool = { true }) -> Task<Void, Never>? {
        workspace.applyLevelsPicker(at: CGPoint(x: 0.5, y: 0.5), assetID: asset.id, editor: editor,
                                    selection: selection, isCurrent: isCurrent)
    }
}

actor LevelsPickerTestStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings]
    private var versions: [String: Int64]
    private var fails: Bool
    init(assetID: String, settings: EditSettings, failsSave: Bool) {
        values = [assetID: settings]; versions = [assetID: 0]; fails = failsSave
    }
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func allowSave() { fails = false }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) throws {
        if fails { throw LevelsSamplingError.insufficientCoverage }
        values[assetID] = settings; versions[assetID] = revision
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/levels-picker-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
}

private actor LevelsSampleProbe {
    let samples: [LevelsPickerSample]
    let latches: [TestAsyncLatch]
    let fails: Bool
    private var received: [UUID] = []
    init(samples: [LevelsPickerSample], latches: [TestAsyncLatch] = [], fails: Bool = false) {
        self.samples = samples; self.latches = latches; self.fails = fails
    }
    nonisolated var sample: DevelopWorkspace.SampleLevels { { bitmap, _, _ in try await self.value(bitmap) } }
    func calls() -> Int { received.count }
    func inputs() -> [UUID] { received }
    nonisolated func waitForCalls(_ count: Int) async throws {
        try await waitForTestState("levels sampler call", state: { await self.calls() }, until: { $0 >= count })
    }
    private func value(_ bitmap: PreviewBitmap) async throws -> LevelsSampleReport {
        let index = received.count; received.append(bitmap.rangeSourceIdentity)
        if latches.indices.contains(index) { await latches[index].wait() }
        if fails { throw LevelsSamplingError.insufficientCoverage }
        return LevelsSampleReport(sample: samples[index], proxyWidth: bitmap.image.width, proxyHeight: bitmap.image.height,
            windowX: 2, windowY: 2, windowWidth: 5, windowHeight: 5, validPixelCount: 25, visibleEquivalent: 25)
    }
}

private actor LevelsValidationProbe {
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

func levelsTransactionBitmap(edge: Int) throws -> PreviewBitmap {
    var data = Data(repeating: 128, count: edge * edge * 4)
    for offset in stride(from: 3, to: data.count, by: 4) { data[offset] = 255 }
    let provider = try #require(CGDataProvider(data: data as CFData))
    return PreviewBitmap(image: try #require(CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: edge * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
}
