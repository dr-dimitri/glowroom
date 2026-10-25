import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

/// Native controls have intrinsic sizes that differ from SwiftUI's proposals.
/// Keep these small window checks ordered because AppKit shares window state.
@Suite("Crop inspector native layout", .serialized)
@MainActor
struct DevelopCropInspectorTests {
    @Test(arguments: [280.0, 320.0])
    func completeCropPaletteFitsANarrowInspector(width: Double) async throws {
        let fixture = try await CropInspectorFixture.make()
        let host = CropInspectorHost(width: width, height: 410)
        defer { host.close() }
        try await host.mount(DevelopCropInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        #expect(host.fittingHeight <= 410, "All crop controls must fit below the histogram without scrolling")
        for name in ["aspect", "lock", "angle", "straighten", "auto", "distortion", "constrain", "distortion.reset", "reset", "close"] {
            let control = try #require(host.element(name), "Missing crop control: \(name)")
            let frame = control.accessibilityFrame()
            #expect(frame.width > 0 && frame.height > 0, "The \(name) control must have a visible native frame")
            #expect(host.screenFrame.insetBy(dx: -1, dy: -1).contains(frame), "The \(name) control must remain inside the narrow inspector")
        }
        let angleSlider = try #require(host.sliders.first)
        #expect(angleSlider.bounds.width >= 70, "The angle control must retain enough track for pointer input")
        #expect(host.element("constrain") != nil)
        #expect(host.element("overlay") == nil)
        let removedLabels = ["Auf Bild beschränken", "Werkzeugüberlagerung", "90° nach links drehen",
            "90° nach rechts drehen", "Horizontal spiegeln", "Vertikal spiegeln"]
        #expect(!host.elements.contains { element in
            removedLabels.contains { $0 == element.accessibilityLabel() }
        }, "The removed controls must not remain as invisible accessibility actions")
        try host.snapshotIfRequested("crop-inspector-\(Int(width))")
        #expect(await fixture.editor.flush())
    }

    @Test
    func resetPreservesOtherEditsAndCanBeUndoneBeforeClosing() async throws {
        let fixture = try await CropInspectorFixture.make()
        let host = CropInspectorHost(width: 280, height: 410)
        defer { host.close() }
        var edited = EditSettings(exposure: 1.25)
        edited.developGeometry.crop = try DevelopCropRect(x: 0.2, y: 0.1, width: 0.5, height: 0.7)
        edited.developGeometry.quarterTurns = 1
        edited.developGeometry.straightenAngle = 7.5
        edited.developGeometry.constrainToImage = false
        edited.developGeometry.flipHorizontal = true
        edited.developGeometry.flipVertical = true
        edited.developGeometry.optics = try DevelopOpticsSettings(distortion: 60)
        edited.developGeometry.retouchStrokes = [try DevelopRetouchStroke(
            source: LocalMaskPoint(x: 0.1, y: 0.1), target: LocalMaskPoint(x: 0.4, y: 0.4), radius: 0.03)]
        fixture.editor.setSettings(edited, for: fixture.asset.id)
        fixture.workspace.isStraightening = true
        try await host.mount(DevelopCropInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        let reset = try #require(host.element("reset"))
        #expect(reset.accessibilityPerformPress())
        try await host.settle()
        let result = fixture.editor.settings(for: fixture.asset.id)
        #expect(result.developGeometry.crop == nil)
        #expect(result.developGeometry.quarterTurns == 0)
        #expect(result.developGeometry.straightenAngle == 0)
        #expect(result.developGeometry.constrainToImage)
        #expect(!result.developGeometry.flipHorizontal && !result.developGeometry.flipVertical)
        #expect(result.developGeometry.optics.isNeutral)
        #expect(result.exposure == edited.exposure)
        #expect(result.developGeometry.retouchStrokes == edited.developGeometry.retouchStrokes)
        #expect(fixture.workspace.tool == .crop)
        #expect(!fixture.workspace.isStraightening)

        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        try await host.settle()
        let close = try #require(host.element("close"))
        #expect(close.accessibilityPerformPress())
        #expect(fixture.workspace.tool == .basic)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        #expect(await fixture.editor.flush())
    }

    @Test
    func levelButtonSelectsAndCancelsReferenceLineWithoutChangingEdits() async throws {
        let fixture = try await CropInspectorFixture.make()
        let host = CropInspectorHost(width: 280, height: 410)
        defer { host.close() }
        var edited = EditSettings(exposure: 0.75)
        edited.developGeometry.crop = try DevelopCropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.7)
        edited.developGeometry.straightenAngle = 4.5
        fixture.editor.setSettings(edited, for: fixture.asset.id)
        try await host.mount(DevelopCropInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        #expect(!fixture.workspace.isStraightening)
        let level = try #require(host.element("straighten"))
        #expect(level.accessibilityLabel() == "Gerade ausrichten")
        #expect(level.accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.isStraightening)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        #expect(try #require(host.element("straighten")).accessibilityPerformPress())
        try await host.settle()
        #expect(!fixture.workspace.isStraightening)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)

        #expect(try #require(host.element("straighten")).accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.isStraightening)
        #expect(try #require(host.element("close")).accessibilityPerformPress())
        #expect(!fixture.workspace.isStraightening)
        #expect(fixture.workspace.tool == .basic)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        #expect(await fixture.editor.flush())
    }

    @Test
    func ratioLockDoesNotChangeTheAcceptedCrop() async throws {
        let fixture = try await CropInspectorFixture.make()
        let host = CropInspectorHost(width: 280, height: 410)
        defer { host.close() }
        var edited = EditSettings.neutral
        edited.developGeometry.crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5)
        fixture.editor.setSettings(edited, for: fixture.asset.id)
        try await host.mount(DevelopCropInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        let initiallyLocked = fixture.workspace.cropAspectLocked
        #expect(try #require(host.element("lock")).accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.cropAspectLocked != initiallyLocked)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        #expect(try #require(host.element("lock")).accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.cropAspectLocked == initiallyLocked)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        #expect(await fixture.editor.flush())
    }

    @Test
    func restoredCropReconcilesTheLockedRatioWithoutChangingTheAcceptedRectangle() async throws {
        let fixture = try await CropInspectorFixture.make()
        let host = CropInspectorHost(width: 280, height: 410)
        defer { host.close() }
        var square = EditSettings.neutral
        square.developGeometry.crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.6)
        fixture.editor.setSettings(square, for: fixture.asset.id)
        fixture.workspace.cropAspect = "1:1"
        fixture.workspace.cropAspectLocked = true
        try await host.mount(DevelopCropInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        var restored = square
        restored.developGeometry.crop = try DevelopCropRect(x: 0.1, y: 0.3, width: 0.6, height: 0.4)
        // Undo and snapshot restore replace accepted geometry independently of
        // the palette. Simulate that publication without using a picker action.
        fixture.editor.setSettings(restored, for: fixture.asset.id)
        try await host.settle()
        #expect(fixture.workspace.cropAspectLocked)
        #expect(fixture.workspace.cropAspect == "free")
        #expect(abs(try #require(fixture.workspace.lockedCropRatio) - 2.25) < 0.000_001)
        #expect(fixture.editor.settings(for: fixture.asset.id) == restored)
        #expect(await fixture.editor.flush())
    }

    @Test
    func lateAutoResultCannotOverwriteAnEditThatWasUndoneToItsOriginalGeometry() async throws {
        let gate = CropInspectorHorizonGate()
        let workspace = DevelopWorkspace(analyze: { _ in
            DevelopPreviewAnalysis(width: 1, height: 1, pixels: [128, 128, 128, 255],
                channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0)
        }, estimateHorizon: { await gate.estimate($0) })
        let fixture = try await CropInspectorFixture.make(workspace: workspace)
        let host = CropInspectorHost(width: 280, height: 410)
        defer { gate.release(); host.close(); workspace.clear() }
        let bitmap = try makeBitmap(width: 120, height: 80)
        let source = AISourceIdentity.original(.init(fileURL: fixture.asset.fileURL,
            modifiedAt: fixture.asset.modifiedAt, fileSize: fixture.asset.fileSize))
        workspace.bind(source: source)
        workspace.receive(bitmap, sourceBitmap: bitmap)
        workspace.markDisplayed(source: source, settings: .neutral)
        try await host.mount(DevelopCropInspector(asset: fixture.asset, workspace: workspace)
            .environmentObject(fixture.editor))

        let baseline = fixture.editor.settings(for: fixture.asset.id)
        let revision = fixture.editor.localRevision(for: fixture.asset.id)
        #expect(try #require(host.element("auto")).accessibilityPerformPress())
        try await gate.started.wait("native crop Auto horizon request", until: { $0 })
        #expect(workspace.isAutoStraightening)

        var intermediate = baseline
        intermediate.developGeometry.crop = try DevelopCropRect(x: 0.1, y: 0.2, width: 0.7, height: 0.5)
        fixture.editor.setSettings(intermediate, for: fixture.asset.id)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline)
        #expect(fixture.editor.localRevision(for: fixture.asset.id) > revision)

        gate.release()
        let deadline = ContinuousClock.now + .seconds(10)
        while workspace.isAutoStraightening {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "native crop Auto completion", lastState: "horizon request is active")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await host.settle()
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.straightenAngle == 0)
        #expect(fixture.editor.settings(for: fixture.asset.id) == baseline)
        #expect(workspace.errorMessage == nil)
        #expect(await fixture.editor.flush())
    }

    private func makeBitmap(width: Int, height: Int) throws -> PreviewBitmap {
        let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: width * height * 4) as CFData))
        return PreviewBitmap(image: try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
    }
}

@MainActor
private struct CropInspectorFixture {
    let asset: PhotoAsset
    let workspace: DevelopWorkspace
    let editor: EditingModel

    static func make(workspace suppliedWorkspace: DevelopWorkspace? = nil) async throws -> Self {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/glowroom-crop-inspector-synthetic.png"),
            pixelWidth: 1_200, pixelHeight: 800)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(CropInspectorSnapshotStore()))
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "crop inspector fixture", lastState: "editor is loading")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let workspace = suppliedWorkspace ?? DevelopWorkspace()
        workspace.tool = .crop
        return Self(asset: asset, workspace: workspace, editor: editor)
    }
}

private actor CropInspectorHorizonGate {
    nonisolated let started = TestStateSignal(false)
    private nonisolated let completion = TestAsyncLatch()

    func estimate(_ bitmap: PreviewBitmap) async -> Double? {
        started.update { $0 = true }
        // The simulated native request deliberately ignores cancellation until
        // released, so the inspector must reject its obsolete successful result.
        await completion.wait()
        return 8
    }

    nonisolated func release() { completion.releaseAll() }
}

@MainActor
private final class CropInspectorHost {
    private let window: NSWindow
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let width: CGFloat

    init(width: CGFloat, height: CGFloat) {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        self.width = width
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    var fittingHeight: CGFloat { hosting.fittingSize.height }
    var screenFrame: NSRect { window.convertToScreen(hosting.convert(hosting.bounds, to: nil)) }
    var elements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }
    var sliders: [NSSlider] {
        var result: [NSSlider] = []
        var pending: [NSView] = [hosting]
        while let view = pending.popLast() {
            if let slider = view as? NSSlider { result.append(slider) }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    func element(_ name: String) -> WorkspaceAccessibilityElement? {
        elements.first { $0.accessibilityIdentifier() == "develop.crop." + name }
    }

    func mount(_ content: some View) async throws {
        hosting.rootView = AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).preferredColorScheme(.dark))
        try await settle()
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func snapshotIfRequested(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_CROP_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    func close() { window.close() }
}

private actor CropInspectorSnapshotStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { settings }
    func revisions() -> [String: Int64] { versions }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) {
        settings[assetID] = value; versions[assetID] = revision
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/crop-inspector-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { settings }
}
