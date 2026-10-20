import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

/// Exercise the native adapter with the real canvas and undo model. Native
/// windows share AppKit state, so these small integration checks stay ordered.
@Suite("Crop canvas native input integration", .serialized)
@MainActor
struct DevelopCropCanvasInputTests {
    @Test(arguments: [0.0, 27.0])
    func interiorDragMovesTheSelectionAsOneUndoableEdit(angle: Double) async throws {
        var baseline = EditSettings(exposure: 1.25)
        baseline.developGeometry.crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        baseline.developGeometry.straightenAngle = angle
        let fixture = try await CropCanvasInputFixture.make(settings: baseline)
        let host = CropCanvasInputHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)

        try await host.send(.leftMouseDown, at: CGPoint(x: 0.4, y: 0.4), angle: angle)
        try await host.send(.leftMouseDragged, at: CGPoint(x: 0.45, y: 0.45), angle: angle)
        try await host.send(.leftMouseDragged, at: CGPoint(x: 0.48, y: 0.5), angle: angle)
        try await host.send(.leftMouseUp, at: CGPoint(x: 0.48, y: 0.5), angle: angle)

        let result = fixture.editor.settings(for: fixture.asset.id)
        let crop = try #require(result.developGeometry.crop)
        expect(crop.x, 0.28); expect(crop.y, 0.3)
        expect(crop.width, 0.4); expect(crop.height, 0.4)
        #expect(result.exposure == baseline.exposure)
        #expect(result.developGeometry.straightenAngle == angle)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline,
            "All intermediate drag updates must be undone together")
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == result)
        #expect(await fixture.editor.flush())
    }

    @Test
    func draggingOutsideTheSelectionCreatesANewRectangle() async throws {
        var baseline = EditSettings(exposure: 0.75)
        baseline.developGeometry.crop = try DevelopCropRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3)
        let fixture = try await CropCanvasInputFixture.make(settings: baseline)
        let host = CropCanvasInputHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)

        try await host.send(.leftMouseDown, at: CGPoint(x: 0.08, y: 0.12))
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline,
            "A click alone must not replace the accepted rectangle")
        try await host.send(.leftMouseDragged, at: CGPoint(x: 0.85, y: 0.8))
        try await host.send(.leftMouseUp, at: CGPoint(x: 0.85, y: 0.8))

        let crop = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.crop)
        expect(crop.x, 0.08); expect(crop.y, 0.12)
        expect(crop.width, 0.77); expect(crop.height, 0.68)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline)
        #expect(await fixture.editor.flush())
    }

    @Test(arguments: [0.0, 23.0])
    func referenceLineSetsTheAbsoluteAngleAndCanBeUndone(angle: Double) async throws {
        var baseline = EditSettings(exposure: 0.5)
        baseline.developGeometry.crop = try DevelopCropRect(x: 0.15, y: 0.1, width: 0.7, height: 0.7)
        baseline.developGeometry.straightenAngle = angle
        let fixture = try await CropCanvasInputFixture.make(settings: baseline)
        fixture.workspace.isStraightening = true
        let host = CropCanvasInputHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)

        let start = CGPoint(x: 0.2, y: 0.2), end = CGPoint(x: 0.8, y: 0.4)
        try await host.send(.leftMouseDown, at: start, angle: angle)
        try await host.send(.leftMouseDragged, at: end, angle: angle)
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline,
            "Drawing the reference line must not move or resize the crop")
        try await host.send(.leftMouseUp, at: end, angle: angle)

        let result = fixture.editor.settings(for: fixture.asset.id)
        // The synthetic decoded source is 120 × 80. The expected angle is
        // absolute in that source, even when the displayed source was rotated.
        let expected = (-atan2(16.0, 72.0) * 180 / Double.pi * 100).rounded() / 100
        expect(result.developGeometry.straightenAngle, expected)
        #expect(result.developGeometry.crop == baseline.developGeometry.crop)
        #expect(result.exposure == baseline.exposure)
        #expect(!fixture.workspace.isStraightening)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline)
        #expect(await fixture.editor.flush())
    }

    @Test
    func continuedHeldDragCannotOverwriteAnUndo() async throws {
        var baseline = EditSettings(exposure: 1)
        baseline.developGeometry.crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let fixture = try await CropCanvasInputFixture.make(settings: baseline)
        let host = CropCanvasInputHost()
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(fixture)

        try await host.send(.leftMouseDown, at: CGPoint(x: 0.4, y: 0.4))
        try await host.send(.leftMouseDragged, at: CGPoint(x: 0.47, y: 0.43))
        let acceptedBeforeUndo = fixture.editor.settings(for: fixture.asset.id)
        #expect(acceptedBeforeUndo != baseline)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline)
        let restoredRevision = fixture.editor.localRevision(for: fixture.asset.id)
        try await host.settle()

        // Native AppKit keeps delivering the original held drag after Cmd-Z.
        // Its original rectangle must not replace the restored editor state.
        try await host.send(.leftMouseDragged, at: CGPoint(x: 0.55, y: 0.5))
        try await host.send(.leftMouseDragged, at: CGPoint(x: 0.6, y: 0.55))
        try await host.send(.leftMouseUp, at: CGPoint(x: 0.6, y: 0.55))
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline)
        #expect(fixture.editor.localRevision(for: fixture.asset.id) == restoredRevision)
        #expect(fixture.editor.canRedo(assetID: fixture.asset.id))
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == acceptedBeforeUndo)
        #expect(await fixture.editor.flush())
    }

    private func expect(_ actual: Double, _ expected: Double) {
        #expect(abs(actual - expected) < 0.000_000_001)
    }
}

@MainActor
private struct CropCanvasInputFixture {
    let asset: PhotoAsset
    let editor: EditingModel
    let workspace: DevelopWorkspace

    static func make(settings: EditSettings) async throws -> Self {
        let asset = PhotoAsset(folderID: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/glowroom-crop-canvas-synthetic.png"),
            pixelWidth: 120, pixelHeight: 80)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(CropCanvasInputSnapshotStore()))
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "native crop canvas fixture", lastState: "editor is loading")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        editor.setSettings(settings, for: asset.id)
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        })
        let source = AISourceIdentity.original(.init(fileURL: asset.fileURL,
            modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: 120 * 80 * 4) as CFData))
        let bitmap = PreviewBitmap(image: try #require(CGImage(width: 120, height: 80,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 120 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
        workspace.bind(source: source)
        workspace.receive(bitmap, sourceBitmap: bitmap)
        workspace.markDisplayed(source: source, settings: .neutral)
        workspace.tool = .crop
        #expect(workspace.isOriginalCanvasReady)
        return Self(asset: asset, editor: editor, workspace: workspace)
    }
}

@MainActor
private final class CropCanvasInputHost {
    private let size = CGSize(width: 600, height: 400)
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

    func mount(_ fixture: CropCanvasInputFixture) async throws {
        hosting.rootView = AnyView(DevelopCanvasInteraction(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor).frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark))
        try await settle()
        let input = try inputView()
        #expect(input.bounds.size == size)
        #expect(input.inputEnabled)
    }

    func send(_ type: NSEvent.EventType, at normalized: CGPoint, angle: Double = 0) async throws {
        let input = try inputView()
        // Forward-project a source position. Production must invert this
        // transform before applying the drag in normalized source coordinates.
        let scale = DevelopCropCanvasPresentation.fittingScale(sourceSize: size, viewport: size, angle: angle)
        let radians = CGFloat(angle * .pi / 180)
        let x = (normalized.x - 0.5) * size.width, y = (normalized.y - 0.5) * size.height
        let point = CGPoint(x: size.width / 2 + (x * cos(radians) - y * sin(radians)) * scale,
                            y: size.height / 2 + (x * sin(radians) + y * cos(radians)) * scale)
        let event = try #require(NSEvent.mouseEvent(with: type,
            location: input.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseDragged: input.mouseDragged(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unsupported crop input event: \(type)")
        }
        try await settle()
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func close() { window.close() }

    private func inputView() throws -> DevelopCropNativeInputView {
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let input = view as? DevelopCropNativeInputView { return input }
            pending.append(contentsOf: view.subviews)
        }
        return try #require(nil as DevelopCropNativeInputView?, "Missing native crop input surface")
    }
}

private actor CropCanvasInputSnapshotStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { settings }
    func revisions() -> [String: Int64] { versions }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) {
        settings[assetID] = value; versions[assetID] = revision
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/crop-canvas-input-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { settings }
}
