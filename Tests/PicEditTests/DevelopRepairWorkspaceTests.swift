import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Repair workspace transactions and frozen proposals")
@MainActor
struct DevelopRepairWorkspaceTests {
    @Test func completePaintedPathCommitsOneStrokeAndOneUndo() async throws {
        let probe = try RepairWorkspaceProbe()
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        let path = try [repairWorkspacePoint(0.4, 0.4), repairWorkspacePoint(0.5, 0.45), repairWorkspacePoint(0.6, 0.5)]
        fixture.workspace.repairObjectDetection = false
        fixture.workspace.repairRadius = 0.06
        fixture.workspace.repairFeather = 0.7
        try await fixture.paint(path)

        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.first)
        #expect(stroke.path == path)
        #expect(stroke.target == path[0])
        #expect(stroke.source == probe.sourcePoint)
        #expect(stroke.radius == 0.06 && stroke.feather == 0.7)
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.count == 1)
        #expect(await probe.state().sourceCalls == 1)
        #expect(!fixture.workspace.repairBusy)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(fixture.editor.canRedo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func cloneNeedsManualSourceAndUsesItWithoutAutomaticSearch() async throws {
        let probe = try RepairWorkspaceProbe()
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        fixture.workspace.repairMode = .clone
        let path = try [repairWorkspacePoint(0.5, 0.5), repairWorkspacePoint(0.6, 0.5)]
        fixture.beginPaint(path)
        #expect(fixture.workspace.repairTask == nil)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(fixture.workspace.errorMessage?.contains("Quellbereich") == true)
        #expect(!fixture.workspace.repairBusy)

        let manual = try repairWorkspacePoint(0.2, 0.25)
        fixture.workspace.repairSource = manual
        try await fixture.paint(path)
        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.first)
        #expect(stroke.mode == .clone && stroke.source == manual && stroke.path == path)
        #expect(await probe.state().sourceCalls == 0)
        #expect(await probe.state().objectCalls == 0)
        #expect(await fixture.editor.flush())
    }

    @Test func healCanUseAnExplicitSourceWithoutSegmentationOrSearch() async throws {
        let probe = try RepairWorkspaceProbe()
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        fixture.workspace.repairMode = .heal
        fixture.workspace.repairSource = try repairWorkspacePoint(0.1, 0.2)
        try await fixture.paint([repairWorkspacePoint(0.5, 0.5)])
        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.first)
        #expect(stroke.mode == .heal && stroke.source == fixture.workspace.repairSource)
        #expect(await probe.state().sourceCalls == 0)
        #expect(await probe.state().objectCalls == 0)
        #expect(await fixture.editor.flush())
    }

    @Test func onlyNoObjectFallsBackToThePaintedSelection() async throws {
        let absent = try RepairWorkspaceProbe(objectReply: .missing)
        let fixture = try await RepairWorkspaceFixture.make(services: absent.services)
        defer { fixture.workspace.clear() }
        let path = try [repairWorkspacePoint(0.5, 0.5), repairWorkspacePoint(0.6, 0.6)]
        try await fixture.paint(path)
        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.first)
        #expect(stroke.path == path && stroke.mask == nil)
        #expect(fixture.workspace.repairStatus?.contains("Pinselbereich") == true)
        #expect(await absent.state().sourceCalls == 1)

        let failed = try RepairWorkspaceProbe(objectReply: .failed)
        let unavailable = try await RepairWorkspaceFixture.make(services: failed.services)
        defer { unavailable.workspace.clear() }
        try await unavailable.paint(path)
        #expect(unavailable.editor.settings(for: unavailable.asset.id) == .neutral)
        #expect(unavailable.workspace.errorMessage == DevelopRepairAnalysisError.unavailable.localizedDescription)
        #expect(await failed.state().sourceCalls == 0)
        #expect(!unavailable.workspace.repairBusy)
        #expect(await fixture.editor.flush())
        #expect(await unavailable.editor.flush())
    }

    @Test func detectedObjectMaskAndItsCenterAreFrozenInTheStroke() async throws {
        let candidate = try repairWorkspaceCandidate()
        let probe = try RepairWorkspaceProbe(objectReply: .candidate(candidate))
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        try await fixture.paint([repairWorkspacePoint(0.45, 0.45), repairWorkspacePoint(0.55, 0.55)])
        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.first)
        #expect(stroke.mask == candidate.mask)
        #expect(stroke.target == candidate.center && stroke.path == [candidate.center])
        #expect(await probe.state().lastSourceMask == candidate.mask)
        #expect(await fixture.editor.flush())
    }

    @Test func sourceReturningAfterUndoCannotOverwriteHistoryAndClearsBusy() async throws {
        let latch = TestAsyncLatch()
        let probe = try RepairWorkspaceProbe(sourceLatch: latch)
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
        fixture.workspace.repairObjectDetection = false
        fixture.beginPaint([try repairWorkspacePoint(0.5, 0.5)])
        let operation = try #require(fixture.workspace.repairTask)
        try await waitForTestState("delayed repair source", state: { await probe.state() }, until: { $0.sourceCalls == 1 })
        #expect(fixture.workspace.repairBusy)
        fixture.editor.undo(assetID: fixture.asset.id)
        latch.releaseAll(); await operation.value
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(fixture.editor.canRedo(assetID: fixture.asset.id))
        #expect(!fixture.workspace.repairBusy && fixture.workspace.repairTask == nil)
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == EditSettings(exposure: 1))
        #expect(await fixture.editor.flush())
    }

    @Test func sourceReturningAfterAtoBtoAOrClearIsRejected() async throws {
        let latch = TestAsyncLatch()
        let probe = try RepairWorkspaceProbe(sourceLatch: latch)
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        fixture.workspace.repairObjectDetection = false
        let original = try #require(fixture.workspace.sourceIdentity)
        fixture.beginPaint([try repairWorkspacePoint(0.5, 0.5)])
        let operation = try #require(fixture.workspace.repairTask)
        try await waitForTestState("repair before source change", state: { await probe.state() }, until: { $0.sourceCalls == 1 })
        let other = AISourceIdentity.original(.init(fileURL: URL(fileURLWithPath: "/tmp/repair-workspace-other.png"), modifiedAt: .distantPast, fileSize: 1))
        fixture.workspace.bind(source: other)
        fixture.workspace.bind(source: original)
        fixture.workspace.tool = .repair
        latch.releaseAll(); await operation.value
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(!fixture.workspace.repairBusy)
        #expect(fixture.workspace.repairCandidates.isEmpty && fixture.workspace.repairPreviewStroke == nil)
        #expect(await fixture.editor.flush())
    }

    @Test func explicitCancellationRejectsEvenAnUncancellableNativeReturn() async throws {
        let latch = TestAsyncLatch()
        let probe = try RepairWorkspaceProbe(sourceLatch: latch)
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        fixture.workspace.repairObjectDetection = false
        fixture.beginPaint([try repairWorkspacePoint(0.5, 0.5)])
        let operation = try #require(fixture.workspace.repairTask)
        try await waitForTestState("repair cancellation", state: { await probe.state() }, until: { $0.sourceCalls == 1 })
        fixture.workspace.cancelRepairWork()
        #expect(!fixture.workspace.repairBusy && fixture.workspace.repairTask == nil)
        latch.releaseAll(); await operation.value
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(fixture.workspace.errorMessage == nil)
        #expect(await fixture.editor.flush())
    }

    @Test func clearingWorkspaceDropsCandidatesSourcesAndPendingAIWithoutChangingEdits() async throws {
        let latch = TestAsyncLatch()
        let probe = try RepairWorkspaceProbe(replacementLatch: latch)
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        let candidate = try repairWorkspaceCandidate()
        fixture.workspace.repairCandidates = [candidate]
        fixture.workspace.repairSelectedCandidateIDs = [candidate.id]
        fixture.workspace.repairSource = probe.sourcePoint
        fixture.workspace.repairAIReady = true; fixture.workspace.repairUsesAI = true; fixture.workspace.repairObjectDetection = false
        fixture.editor.setSettings(EditSettings(exposure: 0.5), for: fixture.asset.id)
        fixture.beginPaint([try repairWorkspacePoint(0.5, 0.5)])
        let operation = try #require(fixture.workspace.repairTask)
        try await waitForTestState("local repair before clear", state: { await probe.state() }, until: { $0.replacementCalls == 1 })
        fixture.workspace.clear()
        #expect(fixture.workspace.repairCandidates.isEmpty && fixture.workspace.repairSelectedCandidateIDs.isEmpty)
        #expect(fixture.workspace.repairSource == nil && fixture.workspace.repairPreviewStroke == nil)
        #expect(fixture.workspace.sourceIdentity == nil && !fixture.workspace.repairBusy)
        latch.releaseAll(); await operation.value
        #expect(fixture.workspace.repairPreviewStroke == nil)
        #expect(fixture.editor.settings(for: fixture.asset.id) == EditSettings(exposure: 0.5))
        #expect(await fixture.editor.flush())
    }

    @Test func localAIProposalDoesNotCommitUntilAcceptedAndUndoRemovesItOnce() async throws {
        let probe = try RepairWorkspaceProbe()
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        fixture.workspace.repairAIReady = true; fixture.workspace.repairUsesAI = true
        fixture.workspace.repairObjectDetection = false
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        try await fixture.paint([repairWorkspacePoint(0.5, 0.5), repairWorkspacePoint(0.55, 0.5)])
        let preview = try #require(fixture.workspace.repairPreviewStroke)
        #expect(preview.replacement == probe.replacementPixels)
        #expect(preview.mask != nil)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(fixture.editor.localRevision(for: fixture.asset.id) == revision)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(fixture.workspace.repairPreviewIsCurrent(asset: fixture.asset, editor: fixture.editor))
        #expect(await probe.state().sourceCalls == 0)
        #expect(await probe.state().replacementCalls == 1)
        fixture.workspace.acceptRepairPreview(asset: fixture.asset, editor: fixture.editor)
        #expect(fixture.workspace.repairPreviewStroke == nil)
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes == [preview])
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func localAIRejectsHDRBeforeInferenceAndPreservesTheCurrentEdit() async throws {
        let probe = try RepairWorkspaceProbe()
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        fixture.workspace.repairAIReady = true; fixture.workspace.repairUsesAI = true
        fixture.workspace.repairObjectDetection = false
        var hdr = EditSettings(exposure: 1)
        hdr.developColor.hdrEnabled = true
        fixture.editor.setSettings(hdr, for: fixture.asset.id)
        fixture.beginPaint([try repairWorkspacePoint(0.5, 0.5)])
        #expect(fixture.workspace.repairTask == nil && !fixture.workspace.repairBusy)
        #expect(fixture.workspace.repairPreviewStroke == nil)
        #expect(fixture.workspace.errorMessage?.contains("SDR") == true)
        #expect(fixture.editor.settings(for: fixture.asset.id) == hdr)
        #expect(await probe.state().replacementCalls == 0)
        #expect(await fixture.editor.flush())
    }

    @Test func discardingOrClosingAPreviewLeavesAcceptedSettingsUntouched() async throws {
        let probe = try RepairWorkspaceProbe()
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        fixture.workspace.repairAIReady = true; fixture.workspace.repairUsesAI = true; fixture.workspace.repairObjectDetection = false
        let baseline = EditSettings(exposure: 0.75)
        fixture.editor.setSettings(baseline, for: fixture.asset.id)
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        try await fixture.paint([repairWorkspacePoint(0.5, 0.5)])
        #expect(fixture.workspace.repairPreviewStroke != nil)
        fixture.workspace.discardRepairPreview()
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline)
        #expect(fixture.editor.localRevision(for: fixture.asset.id) == revision)
        try await fixture.paint([repairWorkspacePoint(0.5, 0.5)])
        fixture.workspace.closeRepair()
        #expect(fixture.workspace.repairPreviewStroke == nil)
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline)
        #expect(fixture.workspace.tool == .basic)
        #expect(await fixture.editor.flush())
    }

    @Test func undoInvalidatesAnExistingPreviewAndADelayedPreview() async throws {
        let probe = try RepairWorkspaceProbe()
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        fixture.workspace.repairAIReady = true; fixture.workspace.repairUsesAI = true; fixture.workspace.repairObjectDetection = false
        fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
        try await fixture.paint([repairWorkspacePoint(0.5, 0.5)])
        #expect(fixture.workspace.repairPreviewStroke != nil)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(!fixture.workspace.repairPreviewIsCurrent(asset: fixture.asset, editor: fixture.editor))
        fixture.workspace.acceptRepairPreview(asset: fixture.asset, editor: fixture.editor)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(fixture.workspace.repairPreviewStroke == nil)

        let latch = TestAsyncLatch()
        let delayed = try RepairWorkspaceProbe(replacementLatch: latch)
        let other = try await RepairWorkspaceFixture.make(services: delayed.services)
        defer { latch.releaseAll(); other.workspace.clear() }
        other.workspace.repairAIReady = true; other.workspace.repairUsesAI = true; other.workspace.repairObjectDetection = false
        other.editor.setSettings(EditSettings(exposure: 1), for: other.asset.id)
        other.beginPaint([try repairWorkspacePoint(0.5, 0.5)])
        let operation = try #require(other.workspace.repairTask)
        try await waitForTestState("delayed local repair preview", state: { await delayed.state() }, until: { $0.replacementCalls == 1 })
        other.editor.undo(assetID: other.asset.id)
        latch.releaseAll(); await operation.value
        #expect(other.workspace.repairPreviewStroke == nil && !other.workspace.repairBusy)
        #expect(other.editor.settings(for: other.asset.id) == .neutral)
        #expect(await fixture.editor.flush())
        #expect(await other.editor.flush())
    }

    @Test func acceptedReplacementSurvivesSerializationAndRedoWithoutInference() async throws {
        let probe = try RepairWorkspaceProbe()
        let fixture = try await RepairWorkspaceFixture.make(services: probe.services)
        defer { fixture.workspace.clear() }
        fixture.workspace.repairAIReady = true; fixture.workspace.repairUsesAI = true; fixture.workspace.repairObjectDetection = false
        try await fixture.paint([repairWorkspacePoint(0.5, 0.5)])
        fixture.workspace.acceptRepairPreview(asset: fixture.asset, editor: fixture.editor)
        let snapshot = fixture.editor.snapshot(for: fixture.asset.id)
        let bytes = try ArtifactJSONCodec.encode(snapshot)
        let decoded = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: bytes)
        #expect(decoded == snapshot)
        #expect(decoded.settings.developGeometry.retouchStrokes.first?.replacement == probe.replacementPixels)
        fixture.editor.undo(assetID: fixture.asset.id)
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.editor.snapshot(for: fixture.asset.id) == snapshot)
        #expect(await probe.state().replacementCalls == 1)
        #expect(await fixture.editor.flush())
    }
}

@MainActor
private struct RepairWorkspaceFixture {
    let asset: PhotoAsset
    let workspace: DevelopWorkspace
    let editor: EditingModel

    static func make(services: DevelopRepairServices) async throws -> Self {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/picedit-repair-workspace-\(UUID().uuidString).png"),
            pixelWidth: 120, pixelHeight: 80)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(RepairWorkspaceSnapshotStore()))
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading {
            guard ContinuousClock.now < deadline else { throw TestSchedulingTimeout(operation: "repair workspace fixture", lastState: "editor is loading") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        }, repairServices: services)
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: 120 * 80 * 4) as CFData))
        let image = try #require(CGImage(width: 120, height: 80, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 120 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = AISourceIdentity.original(.init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        workspace.bind(source: source)
        let bitmap = PreviewBitmap(image: image)
        workspace.receive(bitmap, sourceBitmap: bitmap)
        workspace.markDisplayed(source: source, settings: .neutral)
        workspace.tool = .repair
        return Self(asset: asset, workspace: workspace, editor: editor)
    }

    func beginPaint(_ path: [LocalMaskPoint]) {
        workspace.applyRepair(path: path, asset: asset, editor: editor,
            expectedRevision: editor.localRevision(for: asset.id), expectedSession: editor.aiEditSessionID)
    }

    func paint(_ path: [LocalMaskPoint]) async throws {
        beginPaint(path)
        let operation = try #require(workspace.repairTask)
        await operation.value
    }
}

private actor RepairWorkspaceProbe {
    enum ObjectReply: Sendable { case missing, failed, candidate(DevelopRepairCandidate) }
    struct State: Sendable {
        var sourceCalls = 0, objectCalls = 0, replacementCalls = 0
        var lastSourceMask: LocalMaskRaster?
    }
    nonisolated let sourcePoint: LocalMaskPoint
    nonisolated let replacementPixels: DevelopRetouchReplacement
    private let objectReply: ObjectReply
    private let sourceLatch: TestAsyncLatch?
    private let replacementLatch: TestAsyncLatch?
    private var current = State()

    init(objectReply: ObjectReply = .missing, sourceLatch: TestAsyncLatch? = nil, replacementLatch: TestAsyncLatch? = nil) throws {
        sourcePoint = try repairWorkspacePoint(0.15, 0.2)
        replacementPixels = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            width: 2, height: 2, rgba: Data([30, 80, 110, 255, 40, 80, 100, 255, 40, 90, 100, 255, 30, 90, 110, 255]))
        self.objectReply = objectReply; self.sourceLatch = sourceLatch; self.replacementLatch = replacementLatch
    }

    nonisolated var services: DevelopRepairServices {
        DevelopRepairServices(source: { _, _, _, mask in try await self.source(mask: mask) },
            object: { _, _, _ in try await self.object() }, candidates: { _, _, _ in [] },
            replacement: { _, _, _ in await self.replacement() })
    }
    func state() -> State { current }
    private func source(mask: LocalMaskRaster?) async throws -> LocalMaskPoint {
        current.sourceCalls += 1; current.lastSourceMask = mask
        await sourceLatch?.wait()
        return sourcePoint
    }
    private func object() throws -> DevelopRepairCandidate {
        current.objectCalls += 1
        switch objectReply {
        case .missing: throw DevelopRepairAnalysisError.noObject
        case .failed: throw DevelopRepairAnalysisError.unavailable
        case .candidate(let value): return value
        }
    }
    private func replacement() async -> DevelopRetouchReplacement {
        current.replacementCalls += 1
        await replacementLatch?.wait()
        return replacementPixels
    }
}

private func repairWorkspacePoint(_ x: Double, _ y: Double) throws -> LocalMaskPoint { try LocalMaskPoint(x: x, y: y) }
private func repairWorkspaceCandidate() throws -> DevelopRepairCandidate {
    DevelopRepairCandidate(id: UUID(), label: "Person 1", mask: try LocalMaskRaster(width: 4, height: 4,
        bytes: Data([0, 0, 0, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 0, 0, 0])),
        center: try repairWorkspacePoint(0.5, 0.5), radius: 0.08)
}

private actor RepairWorkspaceSnapshotStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { settings }
    func revisions() -> [String: Int64] { versions }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) { settings[assetID] = value; versions[assetID] = revision }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/repair-workspace-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { settings }
}
