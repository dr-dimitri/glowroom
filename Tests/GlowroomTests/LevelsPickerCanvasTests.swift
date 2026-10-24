import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Levels picker native canvas routing", .serialized)
@MainActor
struct LevelsPickerCanvasTests {
    @Test func nativeClickSamplesTheAcceptedAdaptiveInputAndCreatesExactlyOneUndo() async throws {
        let probe = LevelsCanvasSampleProbe()
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        let host = LevelsCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        fixture.activate()
        try await host.mount(fixture)
        let input = try host.inputView()
        #expect(input.accessibilityLabel()?.contains("Tonwertpipette") == true)
        #expect(input.cursor(CGPoint(x: 250, y: 250)) === NSCursor.crosshair)
        #expect(input.cursor(CGPoint(x: 50, y: 200)) === NSCursor.arrow)

        // The accepted 8×8 input is smaller than the decoded 16×16 source.
        // In the 600×400 viewport its square output occupies x=100...500.
        try host.click(input, at: CGPoint(x: 250, y: 250))
        try await waitForTestState("native levels sample completion", state: {
            await MainActor.run { fixture.workspace.levelsTask == nil && fixture.workspace.levelsPicker == nil }
        }, until: { $0 })
        let samples = await probe.samples()
        #expect(samples.count == 1)
        let sample = try #require(samples.first)
        #expect(sample.token == fixture.input.rangeSourceIdentity)
        #expect(sample.token != fixture.decoded.rangeSourceIdentity)
        #expect(sample.point == CGPoint(x: 0.375, y: 0.625))
        #expect(sample.width == 8 && sample.height == 8)
        #expect(fixture.settings.levels.master.gamma == 2)
        #expect(fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == .neutral)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func nativeClickInvertsTheDisplayedCropAndQuarterTurnBeforeSampling() async throws {
        let probe = LevelsCanvasSampleProbe()
        var initial = EditSettings.neutral
        initial.developGeometry = .init(crop: try .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5), quarterTurns: 1)
        let fixture = try await LevelsPickerFixture.make(initial: initial, sample: probe.sample)
        try installRenderedDisplay(fixture)
        let host = LevelsCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        fixture.activate()
        try await host.mount(fixture)
        let input = try host.inputView()
        // First output pixel center (.5,.5) after the clockwise 4×4 turn
        // comes from actual input pixel center (2.5,5.5), top-left based.
        try host.click(input, at: CGPoint(x: 150, y: 50))
        try await waitForTestState("rotated native levels sample", state: {
            await MainActor.run { fixture.workspace.levelsTask == nil && fixture.workspace.levelsPicker == nil }
        }, until: { $0 })
        let sample = try #require(await probe.samples().first)
        #expect(sample.point == CGPoint(x: 2.5 / 8, y: 5.5 / 8))
        #expect(sample.token == fixture.input.rangeSourceIdentity)
        #expect(fixture.settings.developGeometry == initial.developGeometry)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.settings == initial && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func letterboxOutsideAndReleasedOutsideNeverStartASample() async throws {
        let probe = LevelsCanvasSampleProbe()
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        let host = LevelsCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        fixture.activate()
        try await host.mount(fixture)
        let input = try host.inputView()
        for point in [CGPoint(x: 50, y: 200), CGPoint(x: 550, y: 200), CGPoint(x: -5, y: 200)] {
            try host.click(input, at: point)
        }
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 300, y: 200))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 550, y: 200))
        try await host.settle()
        #expect(await probe.samples().isEmpty)
        #expect(fixture.workspace.levelsPicker != nil)
        #expect(fixture.settings == .neutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test func transparentFreeRotationCornerDoesNotSampleAnUnrelatedSourcePixel() async throws {
        let probe = LevelsCanvasSampleProbe()
        var initial = EditSettings.neutral
        initial.developGeometry = .init(straightenAngle: 30, constrainToImage: false)
        let fixture = try await LevelsPickerFixture.make(initial: initial, sample: probe.sample)
        try installRenderedDisplay(fixture)
        let output = try #require(fixture.workspace.levelsDisplay?.frame.output)
        #expect(output.image.width == 11 && output.image.height == 11)
        let host = LevelsCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        fixture.activate()
        try await host.mount(fixture)
        let input = try host.inputView()
        // Center of the actual rendered top-left pixel, inside the fitted
        // output rectangle but in its transparent free-rotation margin.
        let point = CGPoint(x: 100 + 400 * 0.5 / 11, y: 400 * 0.5 / 11)
        #expect(input.cursor(point) === NSCursor.crosshair)
        try host.click(input, at: point)
        try await host.settle()
        #expect(await probe.samples().isEmpty)
        #expect(fixture.workspace.errorMessage?.contains("Rotationsränder") == true)
        #expect(fixture.workspace.levelsPicker != nil)
        #expect(fixture.settings == initial && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [LevelsCanvasInvalidation.oldRevisionABA, .readOnly, .tool])
    func aHeldNativeClickIsCancelledWhenItsRevisionOrEditabilityChanges(invalidation: LevelsCanvasInvalidation) async throws {
        let probe = LevelsCanvasSampleProbe()
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        let host = LevelsCanvasHost()
        defer { host.close(); fixture.workspace.clear(); fixture.editor.cancelTermination() }
        fixture.activate()
        try await host.mount(fixture)
        let input = try host.inputView()
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 300, y: 200))
        switch invalidation {
        case .oldRevisionABA:
            fixture.editor.setSettings(EditSettings(exposure: 1), for: fixture.asset.id)
            fixture.editor.undo(assetID: fixture.asset.id)
        case .readOnly: fixture.editor.beginTermination()
        case .tool: fixture.workspace.tool = .repair
        }
        try await host.settle()
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 300, y: 200))
        try await host.settle()
        #expect(await probe.samples().isEmpty)
        #expect(fixture.workspace.levelsPicker == nil)
        #expect(fixture.settings == .neutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.cancelTermination()
        #expect(await fixture.editor.flush())
    }

    @Test func escapeCancelsTheNativeHeldClickBeforeMouseUp() async throws {
        let probe = LevelsCanvasSampleProbe()
        let fixture = try await LevelsPickerFixture.make(sample: probe.sample)
        let host = LevelsCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        fixture.activate()
        try await host.mount(fixture)
        let input = try host.inputView()
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 300, y: 200))
        // This is the same native cancellation entry used by its AppKit
        // Escape monitor; do not bypass the adapter via workspace.endPicker.
        #expect(input.cancelForEscape())
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 300, y: 200))
        #expect(fixture.workspace.levelsPicker == nil)
        #expect(await probe.samples().isEmpty)
        #expect(fixture.settings == .neutral && !fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    private func installRenderedDisplay(_ fixture: LevelsPickerFixture) throws {
        let output = try EditRenderer.render(fixture.input, settings: fixture.settings, session: .init(lowPriority: false))
        fixture.refreshDisplay()
        let identity = try #require(fixture.workspace.levelsDisplay?.identity)
        fixture.workspace.receive(output, sourceBitmap: fixture.decoded)
        fixture.workspace.markDisplayed(source: fixture.source, settings: fixture.settings)
        fixture.workspace.receiveLevelsDisplay(.init(identity: identity,
            frame: .init(actualInput: fixture.input, output: output), decodedSource: fixture.decoded))
    }
}

enum LevelsCanvasInvalidation: Sendable { case oldRevisionABA, readOnly, tool }

private actor LevelsCanvasSampleProbe {
    struct Sample: Sendable {
        let token: UUID
        let point: CGPoint
        let width: Int
        let height: Int
    }
    private var received: [Sample] = []
    nonisolated var sample: DevelopWorkspace.SampleLevels { { bitmap, _, point in await self.record(bitmap, point) } }
    func samples() -> [Sample] { received }
    private func record(_ bitmap: PreviewBitmap, _ point: CGPoint) -> LevelsSampleReport {
        let width = bitmap.image.width, height = bitmap.image.height
        received.append(.init(token: bitmap.rangeSourceIdentity, point: point,
                              width: width, height: height))
        let centerX = min(width - 1, Int(floor(point.x * CGFloat(width))))
        let centerY = min(height - 1, Int(floor(point.y * CGFloat(height))))
        let left = max(0, centerX - 2), top = max(0, centerY - 2)
        let windowWidth = min(width, centerX + 3) - left
        let windowHeight = min(height, centerY + 3) - top
        let pixels = windowWidth * windowHeight
        return LevelsSampleReport(sample: .init(red: 0.25, green: 0.25, blue: 0.25),
            proxyWidth: width, proxyHeight: height,
            windowX: left, windowY: top, windowWidth: windowWidth, windowHeight: windowHeight,
            validPixelCount: pixels, visibleEquivalent: Double(pixels))
    }
}

@MainActor
private final class LevelsCanvasHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    func mount(_ fixture: LevelsPickerFixture) async throws {
        hosting.rootView = AnyView(DevelopCanvasInteraction(asset: fixture.asset, workspace: fixture.workspace,
            levelsSelection: fixture.selection, levelsIsCurrent: { true })
            .environmentObject(fixture.editor).frame(width: 600, height: 400))
        try await settle()
        #expect(try inputView().inputEnabled)
    }

    func click(_ input: DevelopCropNativeInputView, at point: CGPoint) throws {
        try send(.leftMouseDown, to: input, at: point)
        try send(.leftMouseUp, to: input, at: point)
    }

    func send(_ type: NSEvent.EventType, to input: DevelopCropNativeInputView, at point: CGPoint) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: input.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unsupported levels canvas event: \(type)")
        }
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
    }

    func inputView() throws -> DevelopCropNativeInputView {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let input = view as? DevelopCropNativeInputView { return input }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as DevelopCropNativeInputView?, "Missing native levels picker surface")
    }

    func close() { window.close() }
}
