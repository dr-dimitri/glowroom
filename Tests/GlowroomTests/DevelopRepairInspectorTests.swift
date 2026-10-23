import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

/// Native AppKit controls must keep usable frames at both inspector widths.
/// Windows share AppKit state, so only this UI suite is ordered.
@Suite("Repair inspector native controls", .serialized)
@MainActor
struct DevelopRepairInspectorTests {
    @Test(arguments: [280.0, 320.0])
    func repairPaletteFitsNarrowInspectorAndExposesOnlyWorkingActions(width: Double) async throws {
        let fixture = try await RepairInspectorFixture.make()
        let host = RepairInspectorHost(width: width, height: 900)
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        #expect(host.fittingHeight <= 900)
        for name in ["mode.remove", "mode.heal", "mode.clone", "size", "feather", "choose-source", "objects", "overlay",
            "visualize-spots", "threshold", "generative", "ai.import", "reset", "close", "detect-reflections", "detect-people", "detect-dust"] {
            let control = try #require(host.element(name), "Missing repair control: \(name)")
            let frame = control.accessibilityFrame()
            #expect(frame.width > 0 && frame.height > 0, "The \(name) control must have a native frame")
            #expect(host.screenFrame.insetBy(dx: -1, dy: -1).contains(frame), "The \(name) control must remain inside the inspector")
        }
        #expect(try #require(host.element("generative")).isAccessibilityEnabled() == false)
        #expect(try #require(host.element("detect-reflections")).isAccessibilityEnabled() == false)
        #expect(try #require(host.element("threshold")).isAccessibilityEnabled() == false)
        #expect(host.sliders.allSatisfy { $0.bounds.width >= 70 }, "Every slider must retain a usable native track")
        // Static SwiftUI text is exposed as AXValue, while controls commonly
        // expose AXLabel. Read both public attributes for the explanatory copy.
        #expect(host.accessibleText.contains("Kompatibles LaMa-Modell importieren, um kleine Bereiche lokal zu ergänzen."))
        #expect(host.accessibleText.contains("Das lokale Reparaturmodell trennt keine Spiegelungen. Diese Funktion ist nicht verfügbar."))
        try host.snapshotIfRequested("repair-inspector-\(Int(width))")
        #expect(await fixture.editor.flush())
    }

    @Test
    func modeSourceAndSpotControlsChangeWorkspaceWithoutChangingAcceptedImage() async throws {
        let fixture = try await RepairInspectorFixture.make()
        fixture.workspace.repairObjectDetection = true
        let host = RepairInspectorHost(width: 280, height: 900)
        defer { host.close(); fixture.workspace.clear() }
        let edited = EditSettings(exposure: 0.75)
        fixture.editor.setSettings(edited, for: fixture.asset.id)
        try await host.mount(DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        #expect(fixture.workspace.repairObjectDetection)
        #expect(try #require(host.element("objects")).accessibilityPerformPress())
        try await host.settle()
        #expect(!fixture.workspace.repairObjectDetection)
        #expect(try #require(host.element("feather")).isAccessibilityEnabled())
        #expect(try #require(host.element("choose-source")).isAccessibilityEnabled())
        fixture.workspace.repairSource = try LocalMaskPoint(x: 0.2, y: 0.3)
        #expect(try #require(host.element("choose-source")).accessibilityPerformPress())
        #expect(fixture.workspace.repairSource == nil)
        fixture.workspace.repairSource = try LocalMaskPoint(x: 0.2, y: 0.3)
        #expect(try #require(host.element("mode.clone")).accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.repairMode == .clone)
        #expect(fixture.workspace.repairSource == nil)
        #expect(try #require(host.element("objects")).isAccessibilityEnabled() == false)
        fixture.workspace.repairSource = try LocalMaskPoint(x: 0.4, y: 0.5)
        #expect(try #require(host.element("choose-source")).accessibilityPerformPress())
        #expect(fixture.workspace.repairSource == nil)
        #expect(try #require(host.element("mode.heal")).accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.repairMode == .heal)
        #expect(try #require(host.element("feather")).isAccessibilityEnabled())

        #expect(!fixture.workspace.repairVisualizesSpots)
        #expect(try #require(host.element("visualize-spots")).accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.repairVisualizesSpots)
        #expect(try #require(host.element("threshold")).isAccessibilityEnabled())
        let size = try #require(host.sliders.first { abs($0.doubleValue - 0.035) < 0.000_001 })
        size.doubleValue = 0.08
        size.sendAction(size.action, to: size.target)
        #expect(abs(fixture.workspace.repairRadius - 0.08) < 0.000_001)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        #expect(await fixture.editor.flush())
    }

    @Test func fineBrushKeepsItsSubpixelSizeAndShowsThePreviewPixelDiameter() async throws {
        let fixture = try await RepairInspectorFixture.make()
        fixture.workspace.repairObjectDetection = false
        let host = RepairInspectorHost(width: 280, height: 900)
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))
        let size = try #require(host.sliders.first { abs($0.doubleValue - 0.035) < 0.000_001 })
        #expect(size.minValue == 0.0005)
        size.doubleValue = 0.0005
        size.sendAction(size.action, to: size.target)
        try await host.settle()
        #expect(fixture.workspace.repairRadius == 0.0005)
        #expect(host.accessibleText.contains("0.1 px"))
        #expect(try #require(host.element("feather")).isAccessibilityEnabled())
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(await fixture.editor.flush())
    }

    @Test
    func lastRepairAndResetAreUndoableAndPreserveOtherEdits() async throws {
        let fixture = try await RepairInspectorFixture.make()
        let host = RepairInspectorHost(width: 280, height: 740)
        defer { host.close(); fixture.workspace.clear() }
        var edited = EditSettings(exposure: 1.25)
        edited.developGeometry.straightenAngle = 7.5
        edited.developGeometry.crop = try DevelopCropRect(x: 0.2, y: 0.1, width: 0.5, height: 0.7)
        edited.developGeometry.retouchStrokes = [
            try DevelopRetouchStroke(source: LocalMaskPoint(x: 0.1, y: 0.1), target: LocalMaskPoint(x: 0.4, y: 0.4), radius: 0.03),
            try DevelopRetouchStroke(mode: .clone, source: LocalMaskPoint(x: 0.2, y: 0.3), target: LocalMaskPoint(x: 0.6, y: 0.7), radius: 0.04)
        ]
        fixture.editor.setSettings(edited, for: fixture.asset.id)
        try await host.mount(DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        #expect(try #require(host.element("remove-last")).accessibilityPerformPress())
        var oneRepair = edited
        oneRepair.developGeometry.retouchStrokes.removeLast()
        #expect(fixture.editor.settings(for: fixture.asset.id) == oneRepair)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        try await host.settle()
        #expect(try #require(host.element("reset")).accessibilityPerformPress())
        var noRepairs = edited
        noRepairs.developGeometry.retouchStrokes = []
        #expect(fixture.editor.settings(for: fixture.asset.id) == noRepairs)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        try await host.settle()
        #expect(try #require(host.element("close")).accessibilityPerformPress())
        #expect(fixture.workspace.tool == .basic)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        #expect(await fixture.editor.flush())
    }

    @Test
    func editingActionsStayDisabledUntilOriginalCanvasIsReady() async throws {
        let fixture = try await RepairInspectorFixture.make(prepareCanvas: false)
        let host = RepairInspectorHost(width: 280, height: 900)
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        for name in ["mode.remove", "mode.heal", "mode.clone", "size", "feather", "choose-source", "objects", "overlay",
            "visualize-spots", "threshold", "reset", "detect-people", "detect-dust"] {
            #expect(try #require(host.element(name)).isAccessibilityEnabled() == false, "The \(name) action needs the original image mapping")
        }
        #expect(try #require(host.element("close")).isAccessibilityEnabled())
        #expect(try #require(host.element("close")).accessibilityPerformPress())
        #expect(fixture.workspace.tool == .basic)
        #expect(await fixture.editor.flush())
    }

    @Test
    func detectedCandidatesCanBeReviewedAndOnlySelectedAreasAreRemoved() async throws {
        let candidate = DevelopRepairCandidate(id: UUID(), label: "Person 1",
            mask: try LocalMaskRaster(width: 2, height: 2, bytes: Data([0, 0, 0, 255])),
            center: try LocalMaskPoint(x: 0.7, y: 0.7), radius: 0.08)
        let fixture = try await RepairInspectorFixture.make(repairServices: .init(
            source: { _, _, _, _ in try LocalMaskPoint(x: 0.15, y: 0.15) },
            object: { _, _, _ in candidate }, candidates: { _, _, _ in [candidate] }))
        let host = RepairInspectorHost(width: 280, height: 780)
        defer { host.close(); fixture.workspace.clear() }
        try await host.mount(DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        #expect(try #require(host.element("detect-people")).accessibilityPerformPress())
        try await waitUntil("repair candidate publication") { !fixture.workspace.repairCandidates.isEmpty }
        try await host.settle()
        #expect(fixture.workspace.repairSelectedCandidateIDs == [candidate.id])
        let candidateName = "candidate." + candidate.id.uuidString
        #expect(try #require(host.element(candidateName)).accessibilityPerformPress())
        try await host.settle()
        #expect(fixture.workspace.repairSelectedCandidateIDs.isEmpty)
        #expect(try #require(host.element("remove-selected")).isAccessibilityEnabled() == false)
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.isEmpty)
        #expect(try #require(host.element(candidateName)).accessibilityPerformPress())
        try await host.settle()
        #expect(try #require(host.element("remove-selected")).accessibilityPerformPress())
        try await waitUntil("selected repair commit") {
            !fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.isEmpty
        }
        let stroke = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.first)
        #expect(stroke.target == candidate.center)
        #expect(stroke.mask == candidate.mask)
        #expect(fixture.workspace.repairCandidates.isEmpty)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.isEmpty)
        #expect(await fixture.editor.flush())
    }

    @Test
    func activeLocalAIRepairNeedsNoAcceptanceAndKeepsEditingControlsAvailable() async throws {
        let fixture = try await RepairInspectorFixture.make()
        let host = RepairInspectorHost(width: 280, height: 900)
        defer { host.close(); fixture.workspace.clear() }
        let edited = EditSettings(exposure: 0.75)
        fixture.editor.setSettings(edited, for: fixture.asset.id)
        let replacement = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0.2, y: 0.3, width: 0.1, height: 0.1),
            width: 2, height: 2, rgba: Data(repeating: 120, count: 16))
        let stroke = try DevelopRetouchStroke(source: LocalMaskPoint(x: 0.1, y: 0.1),
            target: LocalMaskPoint(x: 0.25, y: 0.35), radius: 0.03, replacement: replacement)
        var repaired = edited
        repaired.developGeometry.retouchStrokes = [stroke]
        fixture.editor.setSettings(repaired, for: fixture.asset.id)
        try await host.mount(DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))

        #expect(host.element("ai.accept") == nil)
        #expect(host.element("ai.discard") == nil)
        #expect(host.element("next-source") == nil)
        for name in ["mode.remove", "size", "ai.import", "reset", "detect-people"] {
            #expect(try #require(host.element(name)).isAccessibilityEnabled())
        }
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == edited)
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == repaired)
        #expect(await fixture.editor.flush())
    }

    @Test func ordinaryRemovalAndAlternativeSourcesAreActiveWithoutAnAcceptanceButton() async throws {
        let fixture = try await RepairInspectorFixture.make(repairServices: .init(
            source: { _, _, _, _ in try LocalMaskPoint(x: 0.15, y: 0.15) },
            object: { _, _, _ in throw DevelopRepairAnalysisError.noObject }, candidates: { _, _, _ in [] },
            nextSource: { _, _, _, _, _ in try LocalMaskPoint(x: 0.3, y: 0.2) }))
        fixture.workspace.repairObjectDetection = false
        let host = RepairInspectorHost(width: 280, height: 1_100)
        defer { host.close(); fixture.workspace.clear() }
        let point = try LocalMaskPoint(x: 0.5, y: 0.5)
        fixture.workspace.applyRepair(path: [point], asset: fixture.asset, editor: fixture.editor,
            expectedRevision: fixture.editor.localRevision(for: fixture.asset.id), expectedSession: fixture.editor.aiEditSessionID)
        await (try #require(fixture.workspace.repairTask)).value
        let original = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.last)
        try await host.mount(DevelopRepairInspector(asset: fixture.asset, workspace: fixture.workspace)
            .environmentObject(fixture.editor))
        #expect(host.element("ai.accept") == nil)
        #expect(host.element("ai.discard") == nil)
        #expect(try #require(host.element("next-source")).isAccessibilityEnabled())
        #expect(fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(try #require(host.element("next-source")).accessibilityPerformPress())
        await (try #require(fixture.workspace.repairTask)).value
        let alternative = try #require(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes.last)
        #expect(alternative.id == original.id)
        #expect(alternative.source == (try LocalMaskPoint(x: 0.3, y: 0.2)))
        #expect(alternative.path == original.path)
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id).developGeometry.retouchStrokes == [original])
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == .newEditingSettings)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.flush())
    }

    private func waitUntil(_ operation: String, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: operation, lastState: "native action has not published")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private struct RepairInspectorFixture {
    let asset: PhotoAsset
    let workspace: DevelopWorkspace
    let editor: EditingModel

    static func make(prepareCanvas: Bool = true, repairServices: DevelopRepairServices = .live) async throws -> Self {
        let asset = PhotoAsset(folderID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/glowroom-repair-inspector-synthetic.png"),
            pixelWidth: 1_200, pixelHeight: 800)
        let editor = EditingModel(database: LegacySnapshotTestAdapter(RepairInspectorSnapshotStore()))
        let deadline = ContinuousClock.now + .seconds(10)
        while editor.isLoading {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "repair inspector fixture", lastState: "editor is loading")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let workspace = DevelopWorkspace(repairServices: repairServices, repairAIStore: DevelopRepairAIModelStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-repair-inspector-model-" + UUID().uuidString)))
        workspace.tool = .repair
        if prepareCanvas {
            let provider = try #require(CGDataProvider(data: Data(repeating: 255, count: 120 * 80 * 4) as CFData))
            let image = try #require(CGImage(width: 120, height: 80, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 120 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let source = AISourceIdentity.original(.init(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
            workspace.bind(source: source)
            let bitmap = PreviewBitmap(image: image)
            workspace.receive(bitmap, sourceBitmap: bitmap)
            workspace.markDisplayed(source: source, settings: editor.settings(for: asset.id))
        }
        return Self(asset: asset, workspace: workspace, editor: editor)
    }
}

@MainActor
private final class RepairInspectorHost {
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
    var accessibleText: String {
        var pending: [Any] = [hosting]
        var seen: Set<ObjectIdentifier> = []
        var values: [String] = []
        while let next = pending.popLast() {
            guard let object = next as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            for key in ["accessibilityLabel", "accessibilityValue"] where object.responds(to: NSSelectorFromString(key)) {
                if let text = object.value(forKey: key) as? String { values.append(text) }
                else if let text = object.value(forKey: key) as? NSAttributedString { values.append(text.string) }
            }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")) {
                pending.append(contentsOf: object.value(forKey: "accessibilityChildren") as? [Any] ?? [])
            }
        }
        return values.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
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
        elements.first { $0.accessibilityIdentifier() == "develop.repair." + name }
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
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_REPAIR_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    func close() { window.close() }
}

private actor RepairInspectorSnapshotStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    func loadAll() -> [String: EditSettings] { settings }
    func revisions() -> [String: Int64] { versions }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) {
        settings[assetID] = value; versions[assetID] = revision
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/repair-inspector-test-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { settings }
}
