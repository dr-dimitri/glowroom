import AppKit
import Foundation
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

@Suite("Slider persistence boundaries", .serialized)
@MainActor
struct SliderPersistenceTests {
    @Test func hostedSliderInheritsPersistenceWithoutAnEditingCallback() async throws {
        let (editor, store) = try await fixture()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 240, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: ResettableSlider(value: Binding(
            get: { editor.settings(for: "A").exposure },
            set: { editor.setSettings(.init(exposure: $0), for: "A") }
        ), in: -5...5).frame(width: 220, height: 30)
            .environment(\.sliderPersistenceSession, editor.sliderPersistenceSession))
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await wait { nativeSlider(in: hosting) != nil }
        let slider = try #require(nativeSlider(in: hosting))
        defer { slider.invalidate() }
        #expect(slider.interaction.persistenceSession === editor.sliderPersistenceSession)
        slider.beginPointerTracking(at: NSPoint(x: 20, y: 10))
        slider.doubleValue = 1
        slider.continuedTracking(at: NSPoint(x: 60, y: 10))
        #expect(editor.settings(for: "A").exposure == 1)
        #expect(editor.sliderPersistenceSession.hasActiveInput)
        try await waitPastDebounce()
        #expect(await store.savedValues().isEmpty)
        slider.doubleValue = 2
        slider.continuedTracking(at: NSPoint(x: 100, y: 10))
        #expect(editor.settings(for: "A").exposure == 2, "The native binding remains live throughout the gesture")
        #expect(await store.savedValues().isEmpty)
        slider.endPointerTracking()
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        #expect(await store.savedValues() == [.init(assetID: "A", exposure: 2)])
        #expect(!editor.sliderPersistenceSession.hasActiveInput)
    }

    @Test func dragWithoutAnEditingCallbackKeepsLiveValuesAndSavesOnlyOnRelease() async throws {
        let (editor, store) = try await fixture()
        let input = interaction(editor)
        defer { input.cancel() }
        input.beginPointer(); input.beginDragging()
        input.nativeValueChanged(1)
        #expect(editor.settings(for: "A").exposure == 1)
        try await waitPastDebounce()
        #expect(await store.savedValues().isEmpty)
        input.nativeValueChanged(2)
        #expect(editor.settings(for: "A").exposure == 2)
        try await waitPastDebounce()
        #expect(await store.savedValues().isEmpty, "Pausing a held drag must not save an intermediate value")
        input.endPointer()
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        #expect(await store.savedValues() == [.init(assetID: "A", exposure: 2)])
        #expect(!editor.sliderPersistenceSession.hasActiveInput)
    }

    @Test func automaticSaveAlreadyInFlightStopsBeforeAnotherAssetOrDragValue() async throws {
        let (editor, store) = try await fixture()
        await store.blockNextSave()
        defer { Task { await store.releaseSave() } }
        editor.setSettings(.init(exposure: 1), for: "A")
        editor.setSettings(.init(exposure: -1), for: "B")
        try await wait { await store.isSaveBlocked() }
        let input = interaction(editor)
        defer { input.cancel() }
        input.beginPointer(); input.beginDragging(); input.nativeValueChanged(2)
        await store.releaseSave()
        try await wait { !editor.isSaving }
        try await waitPastDebounce()
        #expect(await store.savedValues() == [.init(assetID: "A", exposure: 1)],
                "A save accepted before the gesture may finish, but its next batch must wait")
        #expect(editor.hasPendingChanges)
        input.nativeValueChanged(3); input.endPointer()
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        #expect(await store.savedValues() == [
            .init(assetID: "A", exposure: 1), .init(assetID: "A", exposure: 3), .init(assetID: "B", exposure: -1)
        ])
    }

    @Test func explicitFlushJoiningAnAutomaticSaveDrainsTheActiveSliderValue() async throws {
        let (editor, store) = try await fixture()
        await store.blockNextSave()
        defer { Task { await store.releaseSave() } }
        editor.setSettings(.init(exposure: 1), for: "A")
        try await wait { await store.isSaveBlocked() }
        let input = interaction(editor)
        defer { input.cancel() }
        input.beginPointer(); input.beginDragging(); input.nativeValueChanged(2)
        var flushStarted = false
        let flush = Task { flushStarted = true; return await editor.flush() }
        try await wait { flushStarted }
        await store.releaseSave()
        #expect(await flush.value)
        #expect(await store.savedValues() == [.init(assetID: "A", exposure: 1), .init(assetID: "A", exposure: 2)])
        #expect(!editor.hasPendingChanges)
        #expect(editor.sliderPersistenceSession.hasActiveInput)
        input.nativeValueChanged(3)
        try await waitPastDebounce()
        #expect(await store.savedValues().count == 2, "An explicit drain must not disable deferral for later drag events")
        input.endPointer()
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        #expect(await store.savedValues().last == .init(assetID: "A", exposure: 3))
    }

    @Test(arguments: [false, true])
    func cancelAndNativeViewTeardownReleaseAcceptedValues(invalidate: Bool) async throws {
        let (editor, store) = try await fixture()
        let slider = ResettableNativeSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        slider.minValue = -5; slider.maxValue = 5
        configure(slider.interaction, editor: editor)
        defer { slider.invalidate() }
        slider.beginPointerTracking(at: NSPoint(x: 20, y: 10))
        slider.doubleValue = 1.5
        slider.continuedTracking(at: NSPoint(x: 60, y: 10))
        #expect(editor.settings(for: "A").exposure == 1.5)
        #expect(editor.sliderPersistenceSession.hasActiveInput)
        if invalidate { slider.invalidate() } else { slider.cancelInput() }
        #expect(!editor.sliderPersistenceSession.hasActiveInput)
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        #expect(await store.savedValues() == [.init(assetID: "A", exposure: 1.5)])
        slider.doubleValue = 4
        slider.endPointerTracking()
        #expect(editor.settings(for: "A").exposure == 1.5, "Late native tracking must not overwrite accepted input")
    }

    @Test func keyboardAccessibilityAndResetRemainAtomicAndDoNotLeaveTheSessionOpen() async throws {
        let (editor, store) = try await fixture()
        let input = interaction(editor)
        input.beginKeyboard(); input.nativeValueChanged(1); input.endKeyboard()
        #expect(!editor.sliderPersistenceSession.hasActiveInput)
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        // Accessibility uses an atomic native change without pointer tracking.
        input.nativeValueChanged(2)
        #expect(!editor.sliderPersistenceSession.hasActiveInput)
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        input.reset(to: 0)
        #expect(!editor.sliderPersistenceSession.hasActiveInput)
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        #expect(await store.savedValues() == [
            .init(assetID: "A", exposure: 1), .init(assetID: "A", exposure: 2), .init(assetID: "A", exposure: 0)
        ])
    }

    @Test func localMaskCallbacksCannotEndTheSharedPersistenceBoundaryEarly() async throws {
        let (editor, store) = try await fixture()
        let layer = try LocalAdjustment(name: "Bereich", mask: .init(shape: .linear(
            start: .init(x: 0, y: 0.5), end: .init(x: 1, y: 0.5))))
        editor.setSettings(.init(localAdjustments: [layer]), for: "A")
        #expect(await editor.flush())
        await store.clearSavedValues()
        let model = LocalAdjustmentEditorModel(settings: editor.settings(for: "A"))
        // Match InlineMaskWorkspace.accept: accepted states end the editor's
        // history group, independently of the local mask slider's own group.
        model.acceptSettings = { settings in
            editor.endEditing(assetID: "A")
            editor.setSettings(settings, for: "A")
            return editor.settings(for: "A") == settings
        }
        let localInput = LocalMaskSliderInput(value: Binding(
            get: { model.selected?.settings.exposure ?? 0 },
            set: { amount in model.updateSelected { $0.settings.exposure = amount } }
        ), model: model)
        let input = ResettableSliderInteraction()
        input.persistenceSession = editor.sliderPersistenceSession
        input.readValue = { localInput.value.wrappedValue }
        input.writeValue = { localInput.value.wrappedValue = $0 }
        input.onEditingChanged = localInput.onEditingChanged
        defer { input.cancel(); model.close() }
        input.beginPointer(); input.beginDragging(); input.nativeValueChanged(1)
        #expect(editor.settings(for: "A").localAdjustments.first?.settings.exposure == 1)
        #expect(!editor.hasActiveEditing(assetID: "A"))
        try await waitPastDebounce()
        #expect(await store.savedValues().isEmpty)
        input.nativeValueChanged(2); input.endPointer()
        try await wait { !editor.hasPendingChanges && !editor.isSaving }
        #expect(await store.savedValues().count == 1)
        #expect(await store.loadAll()["A"]?.localAdjustments.first?.settings.exposure == 2)
    }

    @Test func sessionsBelongToTheirWorkspaceAndRemainCapturedUntilInputEnds() async throws {
        let (first, firstStore) = try await fixture()
        let (second, secondStore) = try await fixture()
        let input = interaction(first)
        defer { input.cancel() }
        input.beginPointer(); input.beginDragging(); input.nativeValueChanged(1)
        input.persistenceSession = second.sliderPersistenceSession
        second.setSettings(.init(exposure: -1), for: "A")
        try await wait { !second.hasPendingChanges && !second.isSaving }
        #expect(await secondStore.savedValues() == [.init(assetID: "A", exposure: -1)])
        #expect(await firstStore.savedValues().isEmpty)
        #expect(first.sliderPersistenceSession.hasActiveInput)
        #expect(!second.sliderPersistenceSession.hasActiveInput)
        input.endPointer()
        try await wait { !first.hasPendingChanges && !first.isSaving }
        #expect(!first.sliderPersistenceSession.hasActiveInput)
        #expect(await firstStore.savedValues() == [.init(assetID: "A", exposure: 1)])
    }

    private func fixture() async throws -> (EditingModel, SliderPersistenceStore) {
        let store = SliderPersistenceStore()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await wait { !editor.isLoading }
        return (editor, store)
    }

    private func interaction(_ editor: EditingModel) -> ResettableSliderInteraction {
        let input = ResettableSliderInteraction()
        configure(input, editor: editor)
        return input
    }

    private func configure(_ input: ResettableSliderInteraction, editor: EditingModel) {
        input.persistenceSession = editor.sliderPersistenceSession
        input.readValue = { editor.settings(for: "A").exposure }
        input.writeValue = { editor.setSettings(.init(exposure: $0), for: "A") }
        // Deliberately keep the default onEditingChanged callback so every new
        // slider inherits persistence behavior without its own undo integration.
    }

    private func nativeSlider(in root: NSView) -> ResettableNativeSlider? {
        if let slider = root as? ResettableNativeSlider { return slider }
        for child in root.subviews {
            if let slider = nativeSlider(in: child) { return slider }
        }
        return nil
    }

    private func waitPastDebounce() async throws {
        try await Task.sleep(for: .milliseconds(450))
    }

    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw SliderPersistenceTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum SliderPersistenceTestError: Error { case timeout }

private struct SavedSliderValue: Equatable, Sendable {
    let assetID: String
    let exposure: Double
}

private actor SliderPersistenceStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    private var saves: [SavedSliderValue] = []
    private var shouldBlockSave = false
    private var saveGate: CheckedContinuation<Void, Never>?

    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) async {
        if shouldBlockSave {
            shouldBlockSave = false
            await withCheckedContinuation { saveGate = $0 }
        }
        values[assetID] = settings; versions[assetID] = revision
        saves.append(.init(assetID: assetID, exposure: settings.exposure))
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/slider-persistence-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
    func blockNextSave() { shouldBlockSave = true }
    func isSaveBlocked() -> Bool { saveGate != nil }
    func releaseSave() { shouldBlockSave = false; saveGate?.resume(); saveGate = nil }
    func savedValues() -> [SavedSliderValue] { saves }
    func clearSavedValues() { saves.removeAll() }
}
