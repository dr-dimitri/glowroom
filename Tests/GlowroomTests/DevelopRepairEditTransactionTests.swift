import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Existing repair edit transactions")
@MainActor
struct DevelopRepairEditTransactionTests {
    @Test(arguments: ["undo", "cancel", "source", "clear", "mode"])
    func invalidationBeforeAMoveCanReturnPreservesTheAcceptedSnapshot(reason: String) async throws {
        let fixture = try await RepairEditTransactionFixture.make()
        defer { fixture.workspace.clear() }
        let stroke = try #require(fixture.baseline.developGeometry.retouchStrokes.first)
        fixture.workspace.moveRepair(id: stroke.id, handle: .target,
            translation: CGSize(width: 0.1, height: 0.1), asset: fixture.asset, editor: fixture.editor,
            expectedRevision: fixture.editor.localRevision(for: fixture.asset.id),
            expectedSession: fixture.editor.aiEditSessionID)
        let operation = try #require(fixture.workspace.repairTask)
        #expect(fixture.workspace.repairBusy)
        // Deliberately do not suspend before invalidation. The move's MainActor
        // task must reject its result even if detached work returns afterward.
        switch reason {
        case "undo": fixture.editor.undo(assetID: fixture.asset.id)
        case "cancel": fixture.workspace.cancelRepairWork()
        case "mode": fixture.workspace.selectRepairMode(.redEye)
        case "source":
            let other = AISourceIdentity.original(.init(fileURL: URL(fileURLWithPath: "/tmp/repair-edit-other.png"),
                modifiedAt: .distantPast, fileSize: 1))
            fixture.workspace.bind(source: other)
            fixture.workspace.bind(source: fixture.source)
            fixture.workspace.receive(fixture.bitmap, sourceBitmap: fixture.bitmap)
            fixture.workspace.markDisplayed(source: fixture.source, settings: .newEditingSettings)
            fixture.workspace.tool = .repair
        default: fixture.workspace.clear()
        }
        await operation.value
        let expected: EditSettings = reason == "undo" ? .newEditingSettings : fixture.baseline
        #expect(fixture.editor.settings(for: fixture.asset.id) == expected)
        #expect(!fixture.workspace.repairBusy && fixture.workspace.repairTask == nil)
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id] == expected)
    }

    @Test func removingAnOlderRepairPreservesOtherEditsAndTheRemainingOrder() async throws {
        let fixture = try await RepairEditTransactionFixture.make()
        defer { fixture.workspace.clear() }
        let original = fixture.baseline.developGeometry.retouchStrokes
        let removed = try #require(original.first)
        fixture.workspace.repairSelectedStrokeID = removed.id
        fixture.workspace.removeRepair(id: removed.id, asset: fixture.asset, editor: fixture.editor)
        var expected = fixture.baseline
        expected.developGeometry.retouchStrokes.removeFirst()
        #expect(fixture.editor.settings(for: fixture.asset.id) == expected)
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.map(\.id)
            == original.dropFirst().map(\.id))
        #expect(fixture.workspace.repairSelectedStrokeID == nil)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == expected)
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id] == expected)
    }
}

@MainActor
private struct RepairEditTransactionFixture {
    let asset: PhotoAsset
    let source: AISourceIdentity
    let bitmap: PreviewBitmap
    let baseline: EditSettings
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let store: RepairEditTransactionStore

    static func make() async throws -> Self {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath:
            "/tmp/repair-edit-transaction-\(UUID().uuidString).png"), pixelWidth: 16, pixelHeight: 16)
        let store = RepairEditTransactionStore()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "repair edit transaction fixture", lastState: "editor is loading")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        var baseline = EditSettings(exposure: 0.5)
        baseline.developGeometry.straightenAngle = 6
        baseline.developGeometry.crop = try DevelopCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        baseline.developGeometry.retouchStrokes = try [0.3, 0.5, 0.7].map { x in
            try DevelopRetouchStroke(source: LocalMaskPoint(x: 0.1, y: 0.15),
                target: LocalMaskPoint(x: x, y: 0.5), radius: 0.03)
        }
        editor.setSettings(baseline, for: asset.id)
        #expect(await editor.flush())
        while !editor.canEdit {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "repair edit transaction fixture", lastState: "editor cannot edit")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let services = DevelopRepairServices(source: { _, _, _, _ in throw DevelopRepairAnalysisError.unavailable },
            object: { _, _, _ in throw DevelopRepairAnalysisError.noObject }, candidates: { _, _, _ in [] })
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        }, repairServices: services)
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: 16 * 16 * 4) as CFData))
        let bitmap = PreviewBitmap(image: try #require(CGImage(width: 16, height: 16, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 16 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
        let source = AISourceIdentity.original(.init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        workspace.bind(source: source)
        workspace.receive(bitmap, sourceBitmap: bitmap)
        // Repair input is presented against the untransformed source canvas,
        // while crop/straightening remain in the accepted edit snapshot.
        workspace.markDisplayed(source: source, settings: .newEditingSettings)
        workspace.tool = .repair
        return Self(asset: asset, source: source, bitmap: bitmap, baseline: baseline,
            editor: editor, workspace: workspace, store: store)
    }
}

private actor RepairEditTransactionStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { settings }
    func revisions() -> [String: Int64] { versions }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) { settings[assetID] = value; versions[assetID] = revision }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/repair-edit-transaction-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { settings }
}
