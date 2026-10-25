import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Frozen development transfer", .serialized)
@MainActor
struct DevelopTransferTests {
    @Test func selectiveTransferPreservesExcludedGroupsAndNoOpHasNoRevision() async throws {
        var source = EditSettings.newEditingSettings
        source.exposure = 1.25; source.texture = 23; source.sharpeningAmount = 40
        source.saturation = 20
        var target = EditSettings.newEditingSettings
        target.saturation = -20
        target.developColor.temperature = 5_200
        target.levels.master.gamma = 1.2
        target.developGeometry.straightenAngle = 8
        target.localAdjustments = [try LocalAdjustment(name: "Lokal", mask: .init(shape: .radial(
            center: .init(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.4, rotation: 0)))]
        var unchanged = target
        unchanged.exposure = source.exposure; unchanged.texture = source.texture
        unchanged.sharpeningAmount = source.sharpeningAmount
        let store = TransferTestStore(initial: ["source": source, "A": target, "B": unchanged])
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await loaded(editor)
        editor.selectEditingFunction(.crop, assetID: "A")
        let transfer = editor.developTransfer
        transfer.prepare(source: asset("source"), patch: try .init(settings: source, groups: [.light, .details]),
            targets: [asset("source"), asset("A"), asset("B")])
        #expect(transfer.rows.count == 2)
        #expect(transfer.rows.first?.changesHistoryFunction == true)
        await transfer.waitUntilPrepared(); transfer.start(); await transfer.waitUntilFinished()
        #expect(transfer.changedCount == 1 && transfer.unchangedCount == 1)
        let next = editor.settings(for: "A")
        #expect(next.exposure == 1.25 && next.texture == 23 && next.sharpeningAmount == 40)
        #expect(next.developColor == target.developColor && next.saturation == target.saturation)
        #expect(next.levels == target.levels && next.developGeometry == target.developGeometry)
        #expect(next.localAdjustments == target.localAdjustments && next.toneCurves == target.toneCurves)
        #expect(editor.localRevision(for: "A") == 1 && editor.localRevision(for: "B") == 0)
        #expect(editor.settings(for: "source") == source)
        let row = try #require(transfer.rows.first)
        #expect(transfer.canUndo(row))
        transfer.undo(row)
        #expect(editor.settings(for: "A") == target)
        #expect(!transfer.canUndo(row))
        editor.redo(assetID: "A")
        #expect(editor.settings(for: "A") == next)
        #expect(await editor.finishSaving())
    }

    @Test func frozenPatchAndTargetsSurviveSourceChangesAndSkipEditedTarget() async throws {
        let store = TransferTestStore()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await loaded(editor)
        var source = EditSettings.newEditingSettings; source.exposure = 1
        let transfer = editor.developTransfer
        transfer.prepare(source: asset("source"), patch: try .init(settings: source, groups: [.light]), targets: [asset("A"), asset("B")])
        source.exposure = 2
        editor.setSettings(source, for: "source")
        var manual = EditSettings.newEditingSettings; manual.exposure = -1
        editor.setSettings(manual, for: "B")
        await transfer.waitUntilPrepared(); transfer.start(); await transfer.waitUntilFinished()
        #expect(editor.settings(for: "A").exposure == 1)
        #expect(editor.settings(for: "B").exposure == -1)
        #expect(editor.settings(for: "source").exposure == 2)
        #expect(editor.settings(for: "C") == .newEditingSettings)
        #expect(transfer.changedCount == 1 && transfer.skippedCount == 1)
        #expect(await editor.finishSaving())
    }

    @Test func threeHundredTargetsUseSerialWritesAndSharedHistoryLimit() async throws {
        let store = TransferTestStore()
        let adapter = LegacySnapshotTestAdapter(store)
        let editor = EditingModel(database: adapter)
        try await loaded(editor)
        var source = EditSettings.newEditingSettings; source.exposure = 0.75
        let transfer = editor.developTransfer
        transfer.prepare(source: asset("source"), patch: try .init(settings: source, groups: [.light]),
                         targets: (0..<300).map { asset("target-\($0)") })
        await transfer.waitUntilPrepared(); transfer.start(); await transfer.waitUntilFinished()
        #expect(transfer.changedCount == 300)
        #expect(editor.historyStateCount <= 256 && editor.historyByteCount <= EditingHistoryLimits.maximumBytes)
        #expect(!transfer.canUndo(try #require(transfer.rows.first)))
        let last = try #require(transfer.rows.last)
        #expect(transfer.canUndo(last))
        editor.selectEditingFunction(.masks, assetID: last.id)
        #expect(!transfer.canUndo(last))
        #expect(await store.maximumConcurrentSaves == 1)
        #expect(await store.saveCount == 300)
        let reopened = EditingModel(database: adapter)
        try await loaded(reopened)
        #expect(reopened.settingsByAsset.count == 300)
        #expect(reopened.settingsByAsset.values.allSatisfy { $0.exposure == 0.75 })
        #expect(await editor.finishSaving())
    }

    @Test func cancelBeforeAdmissionWritesNothingAndCanStartAgain() async throws {
        let store = TransferTestStore()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await loaded(editor)
        let transfer = editor.developTransfer
        var source = EditSettings.newEditingSettings; source.exposure = 1
        let patch = try DevelopSettingsPatch(settings: source, groups: [.light])
        transfer.prepare(source: asset("source"), patch: patch, targets: [asset("A"), asset("B")])
        await transfer.waitUntilPrepared(); transfer.start(); transfer.cancel(); await transfer.waitUntilFinished()
        #expect(transfer.cancelledCount == 2 && transfer.changedCount == 0)
        #expect(await store.saveCount == 0)
        transfer.prepare(source: asset("source"), patch: patch, targets: [asset("A"), asset("B")])
        await transfer.waitUntilPrepared(); transfer.start(); await transfer.waitUntilFinished()
        #expect(transfer.changedCount == 2)
        #expect(await store.saveCount == 2)
        // Replaying a new explicit job is harmless: no revision or undo added.
        transfer.prepare(source: asset("source"), patch: patch, targets: [asset("A"), asset("B")])
        await transfer.waitUntilPrepared(); transfer.start(); await transfer.waitUntilFinished()
        #expect(transfer.unchangedCount == 2)
        #expect(await store.saveCount == 2)
        #expect(await editor.finishSaving())
    }

    @Test func cancellingAcceptedSaveFinishesItAndStopsRemainder() async throws {
        let store = TransferTestStore(blockNextSave: true)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await loaded(editor)
        let transfer = editor.developTransfer
        var source = EditSettings.newEditingSettings; source.exposure = 1
        transfer.prepare(source: asset("source"), patch: try .init(settings: source, groups: [.light]), targets: [asset("A"), asset("B")])
        await transfer.waitUntilPrepared(); transfer.start()
        try await wait { await store.isSaveBlocked }
        #expect(transfer.changedCount == 0)
        transfer.cancel()
        await store.releaseSave()
        await transfer.waitUntilFinished()
        #expect(transfer.changedCount == 1 && transfer.cancelledCount == 1)
        #expect(await store.saveCount == 1)
        #expect(await !store.sawCancellation)
        #expect(editor.persistedState(for: "A")?.snapshot?.settings.exposure == 1)
        #expect(editor.settings(for: "B").exposure == 0)
        #expect(await editor.finishSaving())
    }

    @Test func failedSaveIsNeverCountedAsDurableSuccess() async throws {
        let store = TransferTestStore(failNextSave: true)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await loaded(editor)
        let transfer = editor.developTransfer
        var source = EditSettings.newEditingSettings; source.exposure = 1
        transfer.prepare(source: asset("source"), patch: try .init(settings: source, groups: [.light]), targets: [asset("A"), asset("B")])
        await transfer.waitUntilPrepared(); transfer.start(); await transfer.waitUntilFinished()
        #expect(transfer.failedCount == 1 && transfer.skippedCount == 1 && transfer.changedCount == 0)
        #expect(editor.isReadOnly && editor.hasPendingChanges)
        #expect(await store.loadAll().isEmpty)
        #expect(await editor.flush())
        #expect(await editor.finishSaving())
    }

    @Test func oneEditorRejectsASecondSimultaneousJobBeforeEitherTaskRuns() async throws {
        let store = TransferTestStore()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await loaded(editor)
        var source = EditSettings.newEditingSettings; source.exposure = 1
        let patch = try DevelopSettingsPatch(settings: source, groups: [.light])
        let first = editor.developTransfer
        let second = DevelopTransferModel(editor: editor)
        first.prepare(source: asset("source"), patch: patch, targets: [asset("A")])
        second.prepare(source: asset("source"), patch: patch, targets: [asset("B")])
        await first.waitUntilPrepared(); await second.waitUntilPrepared()
        first.start(); second.start()
        #expect(!second.isRunning && second.errorMessage != nil)
        await first.waitUntilFinished()
        #expect(editor.settings(for: "A").exposure == 1 && editor.settings(for: "B").exposure == 0)
        #expect(await store.saveCount == 1)
        #expect(await editor.finishSaving())
    }

    @Test func versionAndSourceLocksAreVisibleAndRestoreInvalidatesPlan() async throws {
        let store = TransferTestStore(initial: ["legacy": .neutral])
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await loaded(editor)
        let transfer = editor.developTransfer
        var source = EditSettings.newEditingSettings; source.exposure = 1
        let patch = try DevelopSettingsPatch(settings: source, groups: [.light])
        transfer.prepare(source: asset("source"), patch: patch, targets: [asset("legacy"), asset("locked"), asset("A")],
            sourceIsCurrent: { $0.id != "locked" })
        await transfer.waitUntilPrepared()
        #expect(transfer.skippedCount == 2)
        let backup = try #require(await editor.createBackup())
        #expect(await editor.restoreBackup(from: backup))
        await transfer.waitUntilPrepared(); transfer.start(); await transfer.waitUntilFinished()
        #expect(transfer.skippedCount == 3 && transfer.changedCount == 0)
        #expect(await store.saveCount == 0)
        #expect(await editor.finishSaving())
    }

    @Test func cancelledDirectObserverCannotCancelAcceptedPersistence() async throws {
        let store = TransferTestStore(blockNextSave: true)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await loaded(editor)
        let token = try #require(editor.transferTarget(assetID: "A"))
        var source = EditSettings.newEditingSettings; source.exposure = 0.5
        let patch = try DevelopSettingsPatch(settings: source, groups: [.light])
        let observer = Task { await editor.commitTransfer(patch, target: token) }
        try await wait { await store.isSaveBlocked }
        observer.cancel(); await store.releaseSave()
        guard case .changed = await observer.value else { Issue.record("Accepted write was not durable"); return }
        #expect(await !store.sawCancellation)
        #expect(editor.persistedState(for: "A")?.snapshot?.settings.exposure == 0.5)
        #expect(await editor.finishSaving())
    }

    @Test(arguments: [420.0, 560.0])
    func nativeTransferControlsFitNarrowSheetAndApplyViaAccessibility(width: Double) async throws {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(TransferTestStore()))
        try await loaded(editor)
        let model = editor.developTransfer
        editor.selectEditingFunction(.crop, assetID: "A")
        var source = EditSettings.newEditingSettings; source.exposure = 0.5
        model.prepare(source: asset("source"), patch: try .init(settings: source, groups: [.light]), targets: [asset("A")])
        await model.waitUntilPrepared()
        let host = NSHostingView(rootView: DevelopTransferView(model: model))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 650),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let bounds = window.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        for name in ["source", "targets", "history-warning", "apply", "dismiss"] {
            let element = try #require(WorkspaceAccessibilityElement.descendants(of: host)
                .first { $0.accessibilityIdentifier() == "develop-transfer.\(name)" })
            #expect(element.accessibilityFrame().width > 0)
            #expect(bounds.contains(element.accessibilityFrame()))
        }
        let apply = try #require(WorkspaceAccessibilityElement.descendants(of: host)
            .first { $0.accessibilityIdentifier() == "develop-transfer.apply" })
        #expect(apply.accessibilityPerformPress())
        await model.waitUntilFinished()
        #expect(model.changedCount == 1)
        #expect(editor.settings(for: "A").exposure == 0.5)
        #expect(await editor.finishSaving())
    }

    private func asset(_ id: String) -> PhotoAsset {
        PhotoAsset(id: id, folderID: UUID(), fileURL: URL(fileURLWithPath: "/synthetic/\(id).jpg"))
    }
    private func loaded(_ editor: EditingModel) async throws { try await wait { !editor.isLoading } }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !(await condition()) {
            if ContinuousClock.now > deadline { throw TransferTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum TransferTestError: Error { case timeout, injected }
private actor TransferTestStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings]
    private var versions: [String: Int64] = [:]
    private var backup: [String: EditSettings] = [:]
    private var blockNextSave: Bool
    private var failNextSave: Bool
    private var saveGate: CheckedContinuation<Void, Never>?
    private var activeSaves = 0
    private(set) var maximumConcurrentSaves = 0
    private(set) var saveCount = 0
    private(set) var sawCancellation = false
    var isSaveBlocked: Bool { saveGate != nil }
    init(initial: [String: EditSettings] = [:], blockNextSave: Bool = false, failNextSave: Bool = false) {
        values = initial; self.blockNextSave = blockNextSave; self.failNextSave = failNextSave
    }
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) async throws {
        saveCount += 1; activeSaves += 1
        maximumConcurrentSaves = max(maximumConcurrentSaves, activeSaves)
        defer { activeSaves -= 1 }
        if blockNextSave {
            blockNextSave = false
            await withCheckedContinuation { saveGate = $0 }
        }
        sawCancellation = sawCancellation || Task.isCancelled
        if failNextSave { failNextSave = false; throw TransferTestError.injected }
        values[assetID] = settings; versions[assetID] = revision
    }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
    func createBackup(automatic: Bool) -> URL {
        if !automatic { backup = values }
        return URL(fileURLWithPath: "/tmp/transfer-test-backup")
    }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values = backup; return values }
}
