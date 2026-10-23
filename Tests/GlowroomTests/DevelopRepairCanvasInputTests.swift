import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

/// The native window tests share AppKit's event and window state.
@Suite("Repair canvas native gestures", .serialized)
@MainActor
struct DevelopRepairCanvasInputTests {
    @Test(arguments: [0.25, 1.25])
    func independentPointClicksKeepTheirOrderAndUndoSteps(interval: Double) async throws {
        let fixture = try await RepairCanvasFixture.make()
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        for point in [CGPoint(x: 0.3, y: 0.35), CGPoint(x: 0.7, y: 0.65)] {
            try host.send(.leftMouseDown, at: point)
            try host.send(.leftMouseUp, at: point)
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval * interval))
        }
        try await fixture.waitForRepairs(2)
        let settings = fixture.editor.settings(for: fixture.asset.id)
        #expect(settings.developGeometry.retouchStrokes.map(\.target) == [
            try LocalMaskPoint(x: 0.3, y: 0.35), try LocalMaskPoint(x: 0.7, y: 0.65)])
        #expect(host.doubleClicks == 0)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.count == 1)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        fixture.editor.redo(assetID: fixture.asset.id); fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == settings)
        #expect(await fixture.editor.flush())
        #expect(await fixture.store.loadAll()[fixture.asset.id] == settings)
    }

    @Test func threeRapidClicksAndADragRemainOrderedWhileAnalysisIsRunning() async throws {
        let gate = RepairCanvasSourceGate()
        let fixture = try await RepairCanvasFixture.make(source: { _, _, _, _ in try await gate.source() })
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        for point in [CGPoint(x: 0.25, y: 0.3), CGPoint(x: 0.5, y: 0.4), CGPoint(x: 0.75, y: 0.6)] {
            try host.send(.leftMouseDown, at: point); try host.send(.leftMouseUp, at: point)
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval * 0.25))
        }
        try host.send(.leftMouseDown, at: CGPoint(x: 0.4, y: 0.7))
        try host.send(.leftMouseDragged, at: CGPoint(x: 0.6, y: 0.75))
        try host.send(.leftMouseUp, at: CGPoint(x: 0.6, y: 0.75))
        #expect(fixture.workspace.repairBusy)
        await gate.release()
        try await fixture.waitForRepairs(4)
        let strokes = fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes
        #expect(strokes.map(\.target) == [try LocalMaskPoint(x: 0.25, y: 0.3),
            try LocalMaskPoint(x: 0.5, y: 0.4), try LocalMaskPoint(x: 0.75, y: 0.6), try LocalMaskPoint(x: 0.4, y: 0.7)])
        #expect(strokes.last!.path.count >= 2)
        #expect(host.doubleClicks == 0)
        for count in (0..<4).reversed() {
            fixture.editor.undo(assetID: fixture.asset.id)
            #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.count == count)
        }
        #expect(await fixture.editor.flush())
    }

    @Test func rapidCloneSourceAndTargetKeepTheChosenSource() async throws {
        let fixture = try await RepairCanvasFixture.make()
        fixture.workspace.repairMode = .clone
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        for point in [CGPoint(x: 0.2, y: 0.25), CGPoint(x: 0.7, y: 0.65)] {
            try host.send(.leftMouseDown, at: point); try host.send(.leftMouseUp, at: point)
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval * 0.25))
        }
        try await fixture.waitForRepairs(1)
        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.first)
        #expect(stroke.source == (try LocalMaskPoint(x: 0.2, y: 0.25)))
        #expect(stroke.target == (try LocalMaskPoint(x: 0.7, y: 0.65)))
        #expect(host.doubleClicks == 0)
        #expect(await fixture.editor.flush())
    }

    @Test func realZoomCanvasReplacementKeepsEarlierIndependentRepairs() async throws {
        let gate = RepairCanvasSourceGate()
        let fixture = try await RepairCanvasFixture.make(source: { _, _, _, _ in try await gate.source() })
        let host = RepairCanvasHost()
        host.replacesCanvasOnDoubleClick = true
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let first = CGPoint(x: 0.3, y: 0.35), zoom = CGPoint(x: 0.7, y: 0.65)
        try host.send(.leftMouseDown, at: first); try host.send(.leftMouseUp, at: first)
        try host.send(.leftMouseDown, at: zoom); try host.send(.leftMouseUp, at: zoom)
        let operation = try #require(fixture.workspace.repairTask)
        try host.send(.leftMouseDown, at: zoom, clickCount: 2)
        try host.send(.leftMouseUp, at: zoom, clickCount: 2)
        try await Task.sleep(for: .milliseconds(80))
        #expect(host.doubleClicks == 1 && host.didReplaceCanvas)
        #expect(fixture.workspace.repairBusy)
        await gate.release(); await operation.value
        try await fixture.waitForRepairs(1)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        let strokes = fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes
        let expectedTarget = try LocalMaskPoint(x: 0.3, y: 0.35)
        #expect(strokes.count == 1 && strokes.first?.target == expectedTarget)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: ["cancel", "reset", "undo", "source"])
    func cancellationInvalidatesQueuedAndInFlightRepairs(reason: String) async throws {
        let gate = RepairCanvasSourceGate()
        let fixture = try await RepairCanvasFixture.make(source: { _, _, _, _ in try await gate.source() })
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        // Establish an accepted undo step before suspending the repair worker.
        fixture.editor.setSettings(EditSettings(exposure: 0.5), for: fixture.asset.id)
        try await Task.sleep(for: .milliseconds(30))
        for point in [CGPoint(x: 0.25, y: 0.3), CGPoint(x: 0.75, y: 0.6)] {
            try host.send(.leftMouseDown, at: point); try host.send(.leftMouseUp, at: point)
        }
        let operation = try #require(fixture.workspace.repairTask)
        switch reason {
        case "reset": fixture.workspace.resetRepairs(asset: fixture.asset, editor: fixture.editor)
        case "undo": fixture.editor.undo(assetID: fixture.asset.id)
        case "source": fixture.workspace.bind(source: nil)
        default: try host.cancel("cancel")
        }
        await gate.release(); await operation.value
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.isEmpty)
        #expect(fixture.editor.settings(for: fixture.asset.id).exposure == (reason == "undo" ? 0 : 0.5))
        #expect(await fixture.editor.flush())
    }

    @Test func queueCapacityRejectsExtraInputWithAnExplanation() async throws {
        let gate = RepairCanvasSourceGate()
        let fixture = try await RepairCanvasFixture.make(source: { _, _, _, _ in try await gate.source() })
        let queue = DevelopRepairInputQueue()
        defer { queue.cancel(); fixture.workspace.clear() }
        for _ in 0...DevelopRepairInputQueue.maximumCommands {
            #expect(queue.begin(asset: fixture.asset, workspace: fixture.workspace, editor: fixture.editor))
            queue.submit(path: [try LocalMaskPoint(x: 0.5, y: 0.5)], selectsSource: false,
                brush: DevelopRepairBrush(fixture.workspace), pointClick: false)
        }
        #expect(fixture.workspace.errorMessage?.contains("Reparaturwarteschlange ist voll") == true)
        queue.cancel(); await gate.release()
        #expect(await fixture.editor.flush())
    }

    @Test func dragStartingOutsideTheImageCannotReuseThePreviousGesture() async throws {
        let fixture = try await RepairCanvasFixture.make()
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        try host.send(.leftMouseDown, at: CGPoint(x: 0.4, y: 0.4))
        try host.send(.leftMouseDragged, at: CGPoint(x: 0.6, y: 0.5))
        try host.send(.leftMouseUp, at: CGPoint(x: 0.6, y: 0.5))
        try await fixture.waitForRepairs(1)
        let accepted = fixture.editor.settings(for: fixture.asset.id)
        try host.send(.leftMouseDown, at: CGPoint(x: -0.1, y: 0.5))
        try host.send(.leftMouseDragged, at: CGPoint(x: 0.4, y: 0.5))
        try host.send(.leftMouseUp, at: CGPoint(x: 0.4, y: 0.5))
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(fixture.editor.settings(for: fixture.asset.id) == accepted)
        #expect(await fixture.editor.flush())
    }

    @Test func nativeDragActivatesTheWholeGestureAsOneUndoStep() async throws {
        let fixture = try await RepairCanvasFixture.make()
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        try host.send(.leftMouseDown, at: CGPoint(x: 0.4, y: 0.4))
        try host.send(.leftMouseDragged, at: CGPoint(x: 0.5, y: 0.45))
        try host.send(.leftMouseDragged, at: CGPoint(x: 0.6, y: 0.5))
        try host.send(.leftMouseUp, at: CGPoint(x: 0.6, y: 0.5))
        let operation = try #require(fixture.workspace.repairTask)
        await operation.value

        #expect(fixture.editor.canUndo(assetID: fixture.asset.id))
        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.last)
        let last = try #require(stroke.path.last)
        #expect(stroke.path.count >= 3)
        #expect(abs(stroke.target.x - 0.4) < 0.000_001)
        #expect(abs(last.x - 0.6) < 0.000_001)
        #expect(abs(last.y - 0.5) < 0.000_001)
        #expect(host.doubleClicks == 0)
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes == [stroke])
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: ["window", "cancel", "teardown"])
    func nativeCancellationDropsADelayedPointClick(reason: String) async throws {
        let fixture = try await RepairCanvasFixture.make()
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        try host.send(.leftMouseDown, at: CGPoint(x: 0.5, y: 0.5))
        try host.send(.leftMouseUp, at: CGPoint(x: 0.5, y: 0.5))
        try host.cancel(reason)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(fixture.workspace.repairSource == nil)
        #expect(!fixture.workspace.repairBusy && fixture.workspace.repairTask == nil)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(host.doubleClicks == 0)
        #expect(await fixture.editor.flush())
    }

    @Test func closingAPaintedLoopIsStillADragAndActivatesWithoutTheClickTimer() async throws {
        let fixture = try await RepairCanvasFixture.make()
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let start = CGPoint(x: 0.4, y: 0.4)
        try host.send(.leftMouseDown, at: start)
        try host.send(.leftMouseDragged, at: CGPoint(x: 0.6, y: 0.4))
        try host.send(.leftMouseDragged, at: CGPoint(x: 0.6, y: 0.6))
        try host.send(.leftMouseDragged, at: start)
        try host.send(.leftMouseUp, at: start)
        let operation = try #require(fixture.workspace.repairTask, "A real painted loop must bypass the pending point-click timer")
        await operation.value
        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.last)
        #expect(stroke.path.count >= 4 && stroke.path.first == stroke.path.last)
        #expect(fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(host.doubleClicks == 0)
        #expect(await fixture.editor.flush())
    }

    @Test func escapeKeepsAnAlreadyActiveRemovalUndoable() async throws {
        let fixture = try await RepairCanvasFixture.make()
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        try host.send(.leftMouseDown, at: CGPoint(x: 0.4, y: 0.4))
        try host.send(.leftMouseDragged, at: CGPoint(x: 0.6, y: 0.5))
        try host.send(.leftMouseUp, at: CGPoint(x: 0.6, y: 0.5))
        await (try #require(fixture.workspace.repairTask)).value
        let accepted = fixture.editor.settings(for: fixture.asset.id)
        #expect(accepted.developGeometry.retouchStrokes.count == 1)
        try host.cancel("cancel")
        #expect(fixture.editor.settings(for: fixture.asset.id) == accepted)
        #expect(fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [DevelopRepairMode.remove, .clone])
    func nativeDoubleClickZoomsOnceWithoutPaintingOrChangingSource(mode: DevelopRepairMode) async throws {
        let fixture = try await RepairCanvasFixture.make()
        fixture.workspace.repairMode = mode
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let point = CGPoint(x: 0.5, y: 0.5)
        try host.send(.leftMouseDown, at: point, clickCount: 1)
        try host.send(.leftMouseUp, at: point, clickCount: 1)
        // Give the pending first-click timer time to start, then begin the
        // second click inside the system's double-click window.
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval * 0.25))
        try host.send(.leftMouseDown, at: point, clickCount: 2)
        // Holding the second press beyond the timer must not let the first
        // click paint or select a clone source. Cancellation belongs to down.
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(host.doubleClicks == 0)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(fixture.workspace.repairSource == nil)
        #expect(!fixture.workspace.repairBusy && fixture.workspace.repairTask == nil)
        try host.send(.leftMouseUp, at: point, clickCount: 2)
        #expect(host.doubleClicks == 1)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(fixture.workspace.repairSource == nil)
        #expect(!fixture.workspace.repairBusy && fixture.workspace.repairTask == nil)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [DevelopRepairMode.remove, .clone])
    func resettingNeutralSettingsInvalidatesThePendingClickEvenWithoutARevisionChange(mode: DevelopRepairMode) async throws {
        let fixture = try await RepairCanvasFixture.make()
        fixture.workspace.repairMode = mode
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        let request = fixture.workspace.repairRequest
        try host.send(.leftMouseDown, at: CGPoint(x: 0.5, y: 0.5))
        try host.send(.leftMouseUp, at: CGPoint(x: 0.5, y: 0.5))
        fixture.workspace.resetRepairs(asset: fixture.asset, editor: fixture.editor)
        #expect(fixture.editor.localRevision(for: fixture.asset.id) == revision)
        #expect(fixture.workspace.repairRequest != request)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(fixture.workspace.repairSource == nil)
        #expect(!fixture.workspace.repairBusy && fixture.workspace.repairTask == nil)
        #expect(host.doubleClicks == 0)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func choosingANewSourceInTheInspectorInvalidatesThePendingCanvasSourceClick() async throws {
        let fixture = try await RepairCanvasFixture.make()
        fixture.workspace.repairMode = .clone
        let host = RepairCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture, withInspector: true)
        let request = fixture.workspace.repairRequest
        try host.send(.leftMouseDown, at: CGPoint(x: 0.5, y: 0.5))
        try host.send(.leftMouseUp, at: CGPoint(x: 0.5, y: 0.5))
        #expect(try host.pressInspectorControl("develop.repair.choose-source"))
        #expect(fixture.workspace.repairRequest != request)
        #expect(fixture.workspace.repairSource == nil)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        #expect(fixture.workspace.repairSource == nil)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(!fixture.workspace.repairBusy && fixture.workspace.repairTask == nil)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }
}

@MainActor
private struct RepairCanvasFixture {
    let asset: PhotoAsset
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let store: RepairCanvasSnapshotStore

    static func make(source: (@Sendable (PreviewBitmap, [LocalMaskPoint], Double, LocalMaskRaster?) async throws -> LocalMaskPoint)? = nil) async throws -> Self {
        let sourcePoint = try LocalMaskPoint(x: 0.15, y: 0.2)
        let services = DevelopRepairServices(source: source ?? { _, _, _, _ in sourcePoint },
            object: { _, _, _ in throw DevelopRepairAnalysisError.noObject }, candidates: { _, _, _ in [] })
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/glowroom-repair-canvas-\(UUID().uuidString).png"),
            pixelWidth: 120, pixelHeight: 80)
        let store = RepairCanvasSnapshotStore()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading {
            guard ContinuousClock.now < deadline else { throw TestSchedulingTimeout(operation: "repair canvas fixture", lastState: "editor is loading") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        }, repairServices: services, repairAIStore: DevelopRepairAIModelStore(directory:
            FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-RepairCanvas-Model-" + UUID().uuidString)))
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: 120 * 80 * 4) as CFData))
        let bitmap = PreviewBitmap(image: try #require(CGImage(width: 120, height: 80, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 120 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
        let source = AISourceIdentity.original(.init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        workspace.bind(source: source); workspace.receive(bitmap, sourceBitmap: bitmap)
        workspace.markDisplayed(source: source, settings: editor.settings(for: asset.id))
        workspace.tool = .repair; workspace.repairObjectDetection = false
        return Self(asset: asset, editor: editor, workspace: workspace, store: store)
    }

    func waitForRepairs(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.settings(for: asset.id).developGeometry.retouchStrokes.count != count || workspace.repairBusy {
            guard ContinuousClock.now < deadline else { throw TestSchedulingTimeout(operation: "queued repairs", lastState: "expected \(count) repairs") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor RepairCanvasSourceGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func source() async throws -> LocalMaskPoint {
        if !isReleased { await withCheckedContinuation { waiters.append($0) } }
        return try LocalMaskPoint(x: 0.15, y: 0.2)
    }
    func release() {
        isReleased = true
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

@MainActor
private final class RepairCanvasHost {
    private let size = CGSize(width: 600, height: 400)
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    var doubleClicks = 0
    var replacesCanvasOnDoubleClick = false
    private(set) var didReplaceCanvas = false

    init() {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = hosting; window.orderBack(nil)
    }

    func mount(_ fixture: RepairCanvasFixture, withInspector: Bool = false) async throws {
        let canvas = DevelopRepairCanvas(asset: fixture.asset, workspace: fixture.workspace,
            onDoubleClick: {
                self.doubleClicks += 1
                if self.replacesCanvasOnDoubleClick { self.replaceCanvasForZoom(fixture) }
            })
            .frame(width: size.width, height: size.height)
        if withInspector {
            window.setContentSize(NSSize(width: 880, height: 760))
            hosting.rootView = AnyView(HStack(alignment: .top, spacing: 0) {
                canvas
                DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
                    .frame(width: 280).fixedSize(horizontal: false, vertical: true)
            }.environmentObject(fixture.editor).preferredColorScheme(.dark))
        } else {
            hosting.rootView = AnyView(canvas.environmentObject(fixture.editor).preferredColorScheme(.dark))
        }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        #expect(try inputView().inputEnabled)
    }

    private func replaceCanvasForZoom(_ fixture: RepairCanvasFixture) {
        // Match DetailView's structural change: the old native surface is
        // dismantled and a new, larger canvas mounts inside a ScrollView.
        hosting.rootView = AnyView(ScrollView([.horizontal, .vertical]) {
            DevelopRepairCanvas(asset: fixture.asset, workspace: fixture.workspace,
                onDoubleClick: { self.doubleClicks += 1 })
                .frame(width: size.width * 2, height: size.height * 2)
                .environment(\.photoCanvasPanning, true)
        }.environmentObject(fixture.editor).preferredColorScheme(.dark))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        didReplaceCanvas = true
    }

    func pressInspectorControl(_ identifier: String) throws -> Bool {
        let element = try #require(WorkspaceAccessibilityElement.descendants(of: hosting).first {
            $0.accessibilityIdentifier() == identifier
        }, "Missing native repair inspector action: \(identifier)")
        return element.accessibilityPerformPress()
    }

    func send(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws {
        let input = try inputView()
        let location = CGPoint(x: point.x * size.width, y: point.y * size.height)
        let event = try #require(NSEvent.mouseEvent(with: type, location: input.convert(location, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseDragged: input.mouseDragged(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unsupported repair input event: \(type)")
        }
    }

    func close() { window.close() }
    func cancel(_ reason: String) throws {
        switch reason {
        case "window": NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        case "cancel": try inputView().cancelInput()
        case "teardown": hosting.rootView = AnyView(EmptyView()); hosting.layoutSubtreeIfNeeded()
        default: Issue.record("Unsupported native repair cancellation: \(reason)")
        }
    }
    private func inputView() throws -> DevelopCropNativeInputView {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let input = view as? DevelopCropNativeInputView { return input }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as DevelopCropNativeInputView?, "Missing native repair input surface")
    }
}

private actor RepairCanvasSnapshotStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { settings }
    func revisions() -> [String: Int64] { versions }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) { settings[assetID] = value; versions[assetID] = revision }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/repair-canvas-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { settings }
}
