import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Automatic tone workspace transactions")
@MainActor
struct DevelopAutomaticToneTests {
    @Test(arguments: AutomaticToneControl.allCases)
    func requestedControlIsTheOnlyChangeAndPersistsWithOneUndoStep(control: AutomaticToneControl) async throws {
        let baseline = EditSettings(exposure: 1, contrast: 8, highlights: -9, shadows: 10, whites: 11, blacks: -12,
                                    texture: 13, clarity: 14, dehaze: 15, vibrance: 16, saturation: 17,
                                    autoToneAmount: 18, naturalBalanceAmount: 19)
        let value = control == .exposure ? 0.75 : 25.0
        let probe = ToneEstimateProbe(values: [value])
        let fixture = try await ToneWorkspaceFixture.make(baseline: baseline, estimate: probe.estimate)
        defer { fixture.workspace.clear() }
        let operation = try #require(fixture.request(control))
        await operation.value

        var expected = baseline
        expected[keyPath: control.keyPath] = value
        #expect(fixture.settings == expected)
        #expect(await probe.baselines() == [baseline])
        #expect(fixture.workspace.automaticToneTask == nil)
        #expect(fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == baseline)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.settings == expected)
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id] == expected)
        #expect(await probe.calls() == 1, "Redo must restore the accepted value without another estimate")
    }

    @Test(arguments: [false, true])
    func interveningManualEditRejectsTheEstimateEvenAfterUndo(undo: Bool) async throws {
        let latch = TestAsyncLatch()
        let probe = ToneEstimateProbe(values: [30], latches: [latch])
        let fixture = try await ToneWorkspaceFixture.make(estimate: probe.estimate)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        let operation = try #require(fixture.request(.shadows))
        try await probe.waitForCalls(1)
        fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
        if undo { fixture.editor.undo(assetID: fixture.asset.id) }
        let expected = fixture.settings

        latch.releaseAll(); await operation.value
        #expect(fixture.settings == expected)
        #expect(fixture.editor.canRedo(assetID: fixture.asset.id) == undo)
        #expect(fixture.workspace.errorMessage == nil)
        #expect(await fixture.editor.flush())
    }

    @Test func evenAnUnchangedEditingGestureInvalidatesTheEstimate() async throws {
        let latch = TestAsyncLatch()
        let probe = ToneEstimateProbe(values: [30], latches: [latch])
        let fixture = try await ToneWorkspaceFixture.make(estimate: probe.estimate)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        let operation = try #require(fixture.request(.shadows))
        try await probe.waitForCalls(1)
        fixture.editor.beginEditing(assetID: fixture.asset.id)
        fixture.editor.endEditing(assetID: fixture.asset.id)
        #expect(fixture.editor.localRevision(for: fixture.asset.id) == revision)

        latch.releaseAll(); await operation.value
        #expect(fixture.settings == .neutral)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func repeatedRequestsAcceptOnlyTheNewestResult() async throws {
        let firstLatch = TestAsyncLatch()
        let probe = ToneEstimateProbe(values: [10, 20], latches: [firstLatch, TestAsyncLatch(open: true)])
        let fixture = try await ToneWorkspaceFixture.make(estimate: probe.estimate)
        defer { firstLatch.releaseAll(); fixture.workspace.clear() }
        let first = try #require(fixture.request(.shadows))
        try await probe.waitForCalls(1)
        let second = try #require(fixture.request(.whites))
        await second.value
        #expect(fixture.settings == EditSettings(whites: 20))

        firstLatch.releaseAll(); await first.value
        #expect(fixture.settings == EditSettings(whites: 20))
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == .neutral)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: ToneRequestInvalidation.allCases)
    func changesToTheSourceBitmapToolOrVisibleContextRejectLateResults(change: ToneRequestInvalidation) async throws {
        let latch = TestAsyncLatch()
        let probe = ToneEstimateProbe(values: [30], latches: [latch])
        let fixture = try await ToneWorkspaceFixture.make(estimate: probe.estimate)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        var isCurrent = true
        let originalSource = try #require(fixture.workspace.sourceIdentity)
        let operation = try #require(fixture.request(.shadows, isCurrent: { isCurrent }))
        try await probe.waitForCalls(1)
        switch change {
        case .bitmap:
            let replacement = try toneTestBitmap()
            fixture.workspace.receive(replacement, sourceBitmap: replacement)
        case .source:
            fixture.workspace.bind(source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/tone-other.png"),
                                                          modifiedAt: .distantPast, fileSize: 1)))
            fixture.workspace.bind(source: originalSource)
        case .clear: fixture.workspace.clear()
        case .context: isCurrent = false
        case .tool: fixture.workspace.tool = .crop
        }

        latch.releaseAll(); await operation.value
        #expect(fixture.settings == .neutral)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(fixture.workspace.automaticToneTask == nil)
        #expect(fixture.workspace.errorMessage == nil)
        #expect(await fixture.editor.flush())
    }

    @Test func estimatorFailurePreservesEditsAndShowsAnActionableError() async throws {
        let probe = ToneEstimateProbe(values: [], fails: true)
        let baseline = EditSettings(exposure: 1, shadows: 12)
        let fixture = try await ToneWorkspaceFixture.make(baseline: baseline, estimate: probe.estimate)
        defer { fixture.workspace.clear() }
        let operation = try #require(fixture.request(.shadows))
        await operation.value
        #expect(fixture.settings == baseline)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(fixture.workspace.errorMessage?.contains("bisherige Wert bleibt erhalten") == true)
        #expect(fixture.workspace.automaticToneTask == nil)
        #expect(await fixture.editor.flush())
    }

    @Test func estimatorFailureAfterToolChangeCannotShowAnObsoleteError() async throws {
        let latch = TestAsyncLatch()
        let probe = ToneEstimateProbe(values: [], latches: [latch], fails: true)
        let fixture = try await ToneWorkspaceFixture.make(estimate: probe.estimate)
        defer { latch.releaseAll(); fixture.workspace.clear() }
        let operation = try #require(fixture.request(.shadows))
        try await probe.waitForCalls(1)
        fixture.workspace.tool = .crop
        latch.releaseAll(); await operation.value
        #expect(fixture.settings == .neutral && fixture.workspace.errorMessage == nil)
        #expect(await fixture.editor.flush())
    }

    @Test func missingPreviewAndInactiveContextDoNotStartAnEstimate() async throws {
        let probe = ToneEstimateProbe(values: [30])
        let fixture = try await ToneWorkspaceFixture.make(estimate: probe.estimate)
        defer { fixture.workspace.clear() }
        #expect(fixture.request(.shadows, isCurrent: { false }) == nil)
        #expect(fixture.workspace.errorMessage == nil)
        fixture.workspace.clear()
        #expect(fixture.request(.shadows) == nil)
        #expect(fixture.workspace.errorMessage?.contains("Bildvorschau") == true)
        #expect(fixture.workspace.errorMessage?.contains("Shift-Doppelklick") == true)
        #expect(fixture.settings == .neutral)
        #expect(await probe.calls() == 0)
        #expect(await fixture.editor.flush())
    }
}

enum ToneRequestInvalidation: CaseIterable, Sendable { case bitmap, source, clear, context, tool }

@MainActor
private struct ToneWorkspaceFixture {
    let asset: PhotoAsset
    let workspace: DevelopWorkspace
    let editor: EditingModel
    let store: ToneSnapshotStore
    var settings: EditSettings { editor.settings(for: asset.id) }

    static func make(baseline: EditSettings = .neutral, estimate: @escaping DevelopWorkspace.EstimateTone) async throws -> Self {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/glowroom-tone-\(UUID().uuidString).png"),
                               pixelWidth: 8, pixelHeight: 8)
        let store = ToneSnapshotStore(assetID: asset.id, settings: baseline)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "automatic tone fixture", lastState: "editor is loading")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        }, estimateTone: estimate)
        let source = AISourceIdentity.original(.init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        workspace.bind(source: source)
        let bitmap = try toneTestBitmap()
        workspace.receive(bitmap, sourceBitmap: bitmap)
        workspace.markDisplayed(source: source, settings: baseline)
        return Self(asset: asset, workspace: workspace, editor: editor, store: store)
    }

    func request(_ control: AutomaticToneControl, isCurrent: @escaping @MainActor () -> Bool = { true }) -> Task<Void, Never>? {
        workspace.applyAutomaticTone(control, assetID: asset.id, editor: editor, isCurrent: isCurrent)
    }
}

private actor ToneEstimateProbe {
    private let values: [Double]
    private let latches: [TestAsyncLatch]
    private let fails: Bool
    private var received: [EditSettings] = []
    init(values: [Double], latches: [TestAsyncLatch] = [], fails: Bool = false) {
        self.values = values; self.latches = latches; self.fails = fails
    }
    nonisolated var estimate: DevelopWorkspace.EstimateTone { { _, _, settings in try await self.value(settings) } }
    func calls() -> Int { received.count }
    func baselines() -> [EditSettings] { received }
    nonisolated func waitForCalls(_ count: Int) async throws {
        try await waitForTestState("automatic tone estimate", state: { await self.calls() }, until: { $0 >= count })
    }
    private func value(_ settings: EditSettings) async throws -> Double {
        let index = received.count
        received.append(settings)
        if latches.indices.contains(index) { await latches[index].wait() }
        if fails { throw ToneEstimateFailure.unavailable }
        return values[index]
    }
}

private enum ToneEstimateFailure: Error { case unavailable }

private actor ToneSnapshotStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings]
    private var versions: [String: Int64]
    init(assetID: String, settings: EditSettings) { self.settings = [assetID: settings]; versions = [assetID: 0] }
    func loadAll() -> [String: EditSettings] { settings }
    func revisions() -> [String: Int64] { versions }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) { settings[assetID] = value; versions[assetID] = revision }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/tone-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { settings }
}

private func toneTestBitmap() throws -> PreviewBitmap {
    let provider = try #require(CGDataProvider(data: Data(repeating: 128, count: 8 * 8 * 4) as CFData))
    return PreviewBitmap(image: try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 8 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
}

/// Native windows share AppKit state, while the transaction fixtures above are
/// independent and remain free to run in parallel.
@Suite("Automatic tone native routing", .serialized)
@MainActor
struct DevelopAutomaticToneNativeTests {
    @Test func labelRoutesShiftDoubleClickToAutomaticAndOtherDoubleClicksToReset() async throws {
        let host = ToneSliderHost()
        defer { host.close() }
        var value = 1.0
        var requests = 0
        var editingEvents: [Bool] = []
        try await host.mount(AdjustmentSlider(control: .exposure, value: Binding(get: { value }, set: { value = $0 }),
            onAutomaticValue: { requests += 1 }, onEditingChanged: { editingEvents.append($0) }))

        try await host.doubleClickLabel("Belichtung", modifiers: .shift, until: { requests > 0 || value != 1 })
        #expect(requests == 1, "The label's routed Shift-double-click must request an automatic value")
        #expect(value == 1, "An automatic request must preserve the pre-calculation value")
        #expect(editingEvents == [false], "The preceding edit must finish before estimation")

        try await host.doubleClickLabel("Belichtung", modifiers: [], until: { value == 0 })
        #expect(requests == 1, "A plain label double-click must not request automatic calculation")
        #expect(value == 0, "A plain label double-click must still reset when automatic calculation is available")

        value = 1
        try await host.doubleClickLabel("Belichtung", modifiers: .control, until: { value == 0 })
        #expect(requests == 1, "Control without Shift must retain label reset behavior")
        #expect(value == 0)

        value = 25
        try await host.mount(AdjustmentSlider(control: .texture, value: Binding(get: { value }, set: { value = $0 }),
                                              onEditingChanged: { _ in }))
        try await host.doubleClickLabel("Struktur", modifiers: .shift, until: { value == 0 })
        #expect(value == 0, "The label retains reset behavior when no automatic callback is provided")
    }

    @Test func everyToneAdjustmentForwardsShiftDoubleClickFromItsLabelAndNativeSlider() async throws {
        for control in AutomaticToneControl.allCases {
            // Each native second-click probe starts in a fresh window. AppKit
            // otherwise retains the preceding label's double-click hit target.
            // First-click buffering/undo is covered by ResettableSliderTests.
            let host = ToneSliderHost()
            defer { host.close() }
            let adjustment = try #require(Adjustment(rawValue: control.rawValue))
            #expect(adjustment.automaticToneControl == control)
            var value = control == .exposure ? 1.0 : 25.0
            let baseline = value
            var requests = 0
            try await host.mount(AdjustmentSlider(control: adjustment, value: Binding(get: { value }, set: { value = $0 }),
                onAutomaticValue: { requests += 1 }, onEditingChanged: { _ in }))
            let slider = try host.slider()
            #expect(slider.onAutomaticValue != nil)
            try await host.shiftDoubleClick(slider)
            #expect(requests == 1 && value == baseline, "Native Shift-double-click for \(control)")
            try await host.doubleClickLabel(adjustment.label, modifiers: .shift, until: { requests > 1 || value != baseline })
            #expect(requests == 2 && value == baseline)
        }

        let host = ToneSliderHost()
        defer { host.close() }
        var value = 25.0
        try await host.mount(AdjustmentSlider(control: .texture, value: Binding(get: { value }, set: { value = $0 }),
                                              onEditingChanged: { _ in }))
        let slider = try host.slider()
        #expect(Adjustment.texture.automaticToneControl == nil && slider.onAutomaticValue == nil)
        try await host.shiftDoubleClick(slider)
        #expect(value == 0, "Controls without automatic estimation retain their double-click reset")
    }

    @Test func disabledAdjustmentRejectsShiftDoubleClickFromItsLabelAndNativeSlider() async throws {
        let host = ToneSliderHost()
        defer { host.close() }
        var value = 1.0
        var requests = 0
        var editingEvents: [Bool] = []
        try await host.mount(AdjustmentSlider(control: .exposure, value: Binding(get: { value }, set: { value = $0 }),
            onAutomaticValue: { requests += 1 }, onEditingChanged: { editingEvents.append($0) }).disabled(true))
        let slider = try host.slider()
        #expect(!slider.isEnabled)
        try await host.shiftDoubleClick(slider)
        try await host.doubleClickLabel("Belichtung", modifiers: .shift, until: { true })
        try await host.doubleClickLabel("Belichtung", modifiers: [], until: { true })
        // SwiftUI may enqueue routed gestures after sendEvent returns. Let that
        // work run before checking that neither automatic nor reset was applied.
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests == 0 && value == 1 && editingEvents.isEmpty)
    }
}

@MainActor
private final class ToneSliderHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var lastGestureEventTimestamp: TimeInterval?
    init() {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 60),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }
    func mount(_ content: some View) async throws {
        hosting.rootView = AnyView(content.frame(width: 300, height: 60))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }
    func slider() throws -> ResettableNativeSlider {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let slider = view as? ResettableNativeSlider { return slider }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as ResettableNativeSlider?, "AdjustmentSlider did not mount its native slider")
    }
    func shiftDoubleClick(_ slider: ResettableNativeSlider) async throws {
        let location = slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: nil)
        let events = try await doubleClickEvents(at: location, modifiers: .shift)
        // Probe the routed double-click completion without entering AppKit's
        // synchronous single-click tracking loop inside the Swift Testing host.
        // Balance the down with an up so no pointer input remains active.
        window.sendEvent(events[2])
        window.sendEvent(events[3])
    }
    func doubleClickLabel(_ text: String, modifiers: NSEvent.ModifierFlags,
                          until completed: @MainActor () -> Bool) async throws {
        let label = try #require(WorkspaceAccessibilityElement.descendants(of: hosting).first {
            $0.accessibilityRole() == .staticText &&
                ($0.accessibilityLabel() == text || $0.accessibilityValue() as? String == text)
        }, "Missing native accessibility frame for adjustment label \(text)")
        let frame = label.accessibilityFrame()
        #expect(frame.width > 0 && frame.height > 0)
        let windowFrame = window.convertFromScreen(frame)
        let location = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        let events = try await doubleClickEvents(at: location, modifiers: modifiers)
        // Route one complete gesture without yielding the MainActor: unrelated
        // suite work must not stretch its clicks beyond AppKit's interval.
        for event in events { window.sendEvent(event) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !completed() {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "routed adjustment label double-click", lastState: "gesture callback has not completed")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func doubleClickEvents(at location: NSPoint, modifiers: NSEvent.ModifierFlags) async throws -> [NSEvent] {
        if let lastGestureEventTimestamp {
            let remaining = lastGestureEventTimestamp + 0.1 - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        }
        let start = ProcessInfo.processInfo.systemUptime - 0.1
        lastGestureEventTimestamp = start + 0.075
        return try [NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp].enumerated().map { index, type in
            try #require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: modifiers, timestamp: start + Double(index) * 0.025,
                windowNumber: window.windowNumber, context: nil, eventNumber: index,
                clickCount: index < 2 ? 1 : 2, pressure: type == .leftMouseDown ? 1 : 0))
        }
    }
    func close() { window.close() }
}
