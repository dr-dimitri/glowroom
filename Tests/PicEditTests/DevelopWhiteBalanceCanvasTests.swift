import AppKit
import Foundation
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

@Suite("White balance canvas cursor and input", .serialized)
@MainActor
struct DevelopWhiteBalanceCanvasTests {
    @Test func nativePickerUsesTheEyedropperOnlyInsideTheDisplayedImage() async throws {
        let fixture = try await WhiteBalanceCanvasFixture.make()
        let host = WhiteBalanceCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()

        #expect(input.accessibilityLabel() == "Neutrale Fläche für Weißabgleich wählen")
        #expect(input.cursor(CGPoint(x: 300, y: 300)) === DevelopWhiteBalanceCursor.eyedropper)
        #expect(input.cursor(CGPoint(x: 300, y: 50)) === NSCursor.arrow)
        #expect(input.cursor(CGPoint(x: 300, y: 550)) === NSCursor.arrow)
        #expect(DevelopWhiteBalanceCursor.eyedropper !== NSCursor.crosshair)

        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 300, y: 50))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 300, y: 50))
        #expect(fixture.workspace.picksWhiteBalance)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)

        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 300, y: 300))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 300, y: 300))
        #expect(!fixture.workspace.picksWhiteBalance)
        #expect(fixture.editor.settings(for: fixture.asset.id).developColor.temperature != 6_500)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(await fixture.editor.flush())
    }

    @Test func pickerTakesPriorityOverCropWithoutChangingGeometry() async throws {
        let fixture = try await WhiteBalanceCanvasFixture.make()
        var baseline = EditSettings.neutral
        baseline.developGeometry.crop = try DevelopCropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        baseline.developGeometry.straightenAngle = 23
        fixture.editor.setSettings(baseline, for: fixture.asset.id)
        fixture.workspace.tool = .crop
        let host = WhiteBalanceCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()
        #expect(input.cursor(CGPoint(x: 300, y: 300)) === DevelopWhiteBalanceCursor.eyedropper)
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 300, y: 300))
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 300, y: 300))
        let result = fixture.editor.settings(for: fixture.asset.id)
        #expect(result.developGeometry == baseline.developGeometry)
        #expect(result.developColor.temperature != baseline.developColor.temperature)
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [false, true])
    func pickerShutdownOrUnreadyPhotoCancelsAHeldSample(losesReadiness: Bool) async throws {
        let fixture = try await WhiteBalanceCanvasFixture.make()
        let host = WhiteBalanceCanvasHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)
        let input = try host.inputView()
        try host.send(.leftMouseDown, to: input, at: CGPoint(x: 300, y: 300))
        if losesReadiness {
            var cropped = EditSettings.neutral
            cropped.developGeometry.crop = try DevelopCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            fixture.workspace.markDisplayed(source: fixture.source, settings: cropped)
        } else {
            fixture.workspace.picksWhiteBalance = false
        }
        try await host.settle()
        #expect(input.cursor(CGPoint(x: 300, y: 300)) === NSCursor.arrow)
        try host.send(.leftMouseUp, to: input, at: CGPoint(x: 300, y: 300))
        #expect(fixture.editor.settings(for: fixture.asset.id) == .neutral)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }
}

@MainActor
private struct WhiteBalanceCanvasFixture {
    let asset: PhotoAsset
    let source: AISourceIdentity
    let editor: EditingModel
    let workspace: DevelopWorkspace

    static func make() async throws -> Self {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/picedit-white-balance-canvas.png"),
            pixelWidth: 120, pixelHeight: 80)
        let source = AISourceIdentity.original(.init(fileURL: asset.fileURL,
            modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        let editor = EditingModel(database: LegacySnapshotTestAdapter(WhiteBalanceCanvasSnapshotStore()))
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [150, 128, 100, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        })
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: 120 * 80 * 4) as CFData))
        let bitmap = PreviewBitmap(image: try #require(CGImage(width: 120, height: 80,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 120 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
        workspace.bind(source: source)
        workspace.receive(bitmap, sourceBitmap: bitmap)
        workspace.markDisplayed(source: source, settings: .neutral)
        workspace.picksWhiteBalance = true
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading || workspace.sourceAnalysis == nil {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "white balance canvas fixture", lastState: "editor or source analysis is loading")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return Self(asset: asset, source: source, editor: editor, workspace: workspace)
    }
}

@MainActor
private final class WhiteBalanceCanvasHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    func mount(_ fixture: WhiteBalanceCanvasFixture) async throws {
        hosting.rootView = AnyView(DevelopCanvasInteraction(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor).frame(width: 600, height: 600))
        try await settle()
        #expect(try inputView().inputEnabled)
    }

    func send(_ type: NSEvent.EventType, to input: DevelopCropNativeInputView, at point: CGPoint) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: input.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unsupported white balance input event: \(type)")
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
        return try #require(nil as DevelopCropNativeInputView?, "Missing native white balance input surface")
    }

    func close() { window.close() }
}

private actor WhiteBalanceCanvasSnapshotStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { settings }
    func revisions() -> [String: Int64] { versions }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) {
        settings[assetID] = value; versions[assetID] = revision
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/white-balance-canvas-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { settings }
}
