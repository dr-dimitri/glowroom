import AppKit
import Foundation
import GlowroomCore
import SwiftUI
import Testing
@testable import Glowroom

/// Exercise the production inspector rather than inferring its toolbar from an enum.
/// Native windows share AppKit state and therefore run in order.
@Suite("Unified repair toolbar integration", .serialized)
@MainActor
struct DevelopRepairToolbarTests {
    @Test(arguments: [280.0, 340.0])
    func oneRepairEntryStaysActiveForRedEyesAndKeepsCrossModeUndoHistory(width: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-RepairToolbar-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferenceSuite = "Glowroom-RepairToolbar-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: preferenceSuite))
        defer { defaults.removePersistentDomain(forName: preferenceSuite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        layout.update(developing: true) { $0.openGroups = [] }
        let imageURL = directory.appendingPathComponent("Photo.png")
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try png.write(to: imageURL)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: imageURL, fileSize: Int64(png.count), pixelWidth: 1, pixelHeight: 1)
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: directory.appendingPathComponent("Editing"))
        let workspace = DevelopWorkspace(repairAIStore: DevelopRepairAIModelStore(directory: directory.appendingPathComponent("Model")))
        let masks = InlineMaskWorkspace()
        let metadata = PhotoMetadataModel(store: PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata")),
            suggestor: LocalPhotoMetadataSuggestor(service: ImageAnalysisService(
                provider: UnavailableImageAnalysisProvider(reason: .sdkUnavailable), budget: AIResourceBudget())),
            library: library, editor: editor)
        let deadline = ContinuousClock.now + .seconds(10)
        while library.isLoading || library.isProjecting || editor.isLoading {
            guard ContinuousClock.now < deadline else {
                throw TestSchedulingTimeout(operation: "repair toolbar fixture", lastState: "library or editor is loading")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        library.select(asset); library.isDeveloping = true
        let source = AISourceIdentity.original(.init(fileURL: imageURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize))
        workspace.bind(source: source)
        workspace.markDisplayed(source: source, settings: .newEditingSettings)
        let host = WorkspaceSectionTestHost(size: NSSize(width: width, height: 900),
            appearance: NSAppearance(named: .darkAqua))
        defer { host.close(); workspace.clear() }
        try await host.mount(RepairToolbarInspector(library: library)
            .environmentObject(editor).environmentObject(metadata).environmentObject(layout)
            .environmentObject(masks).environmentObject(workspace).preferredColorScheme(.dark))
        func control(_ identifier: String) throws -> WorkspaceAccessibilityElement {
            try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == identifier }, "Missing inspector control: \(identifier)")
        }
        func assertSingleRetouchEntry() throws {
            let elements = host.accessibilityElements
            let tools = elements.compactMap { $0.accessibilityIdentifier() }.filter { $0.hasPrefix("develop.tool.") }
            #expect(Set(tools) == ["develop.tool.basic", "develop.tool.crop", "develop.tool.repair", "develop.tool.masks"])
            #expect(tools.count == 4)
            #expect(elements.filter { $0.accessibilityIdentifier() == "develop.tool.repair" }.count == 1)
            #expect(!elements.contains { $0.accessibilityIdentifier() == "develop.tool.redEye" })
            #expect(!elements.contains { $0.accessibilityLabel() == "Mit KI reparieren" })
            #expect(!elements.contains { $0.accessibilityIdentifier() == "workspace.ai-develop" })
            #expect(try control("develop.tool.repair").accessibilityLabel() == "Reparieren")
            let frames = try DevelopCanvasTool.toolbarCases.map { tool in
                let button = try control("develop.tool.\(tool.rawValue)")
                #expect(button.accessibilityLabel() == tool.title)
                return button.accessibilityFrame()
            }
            let firstFrame = try #require(frames.first)
            for frame in frames {
                #expect(abs(frame.midY - firstFrame.midY) < 1, "All four icons share a compact row")
                #expect(frame.height >= 32 && frame.height <= 42)
                #expect(frame.width >= 44, "Icon-only tools retain a generous click target")
            }
        }
        try assertSingleRetouchEntry()
        #expect(try control("develop.tool.repair").accessibilityValue() as? String == "Inaktiv")
        #expect(try control("develop.tool.repair").accessibilityPerformPress())
        try await host.settle()
        #expect(workspace.tool == .repair)
        if let path = ProcessInfo.processInfo.environment["GLOWROOM_REPAIR_SNAPSHOTS"] {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try host.snapshot(to: output.appendingPathComponent("repair-toolbar-panel-\(Int(width)).png"))
        }
        #expect(try control("develop.repair.mode.redEye").accessibilityPerformPress())
        try await host.settle()
        #expect(workspace.tool == .redEye)
        try assertSingleRetouchEntry()
        #expect(try control("develop.tool.repair").accessibilityValue() as? String == "Aktiv")
        #expect(try control("develop.repair.mode.redEye").accessibilityValue() as? String == "Ausgewählt")
        #expect(try control("develop.tool.basic").accessibilityPerformPress())
        try await host.settle()
        #expect(workspace.tool == .basic)
        #expect(try control("develop.tool.repair").accessibilityValue() as? String == "Inaktiv")
        #expect(try control("develop.tool.repair").accessibilityPerformPress())
        try await host.settle()
        #expect(workspace.tool == .redEye)
        #expect(try control("develop.tool.repair").accessibilityValue() as? String == "Aktiv")
        #expect(try control("develop.repair.red-eye.strength").isAccessibilityEnabled())
        #expect(editor.settings(for: asset.id) == .newEditingSettings)
        #expect(!editor.canUndo(assetID: asset.id))

        // All four modes are one tool. Switching its mode must retain each
        // immediately accepted repair and eye correction as a separate undo step.
        #expect(try control("develop.repair.mode.heal").accessibilityPerformPress())
        try await host.settle()
        var repaired = EditSettings.newEditingSettings
        repaired.developGeometry.retouchStrokes = [try DevelopRetouchStroke(
            source: LocalMaskPoint(x: 0.15, y: 0.2), target: LocalMaskPoint(x: 0.6, y: 0.5), radius: 0.03)]
        editor.setSettings(repaired, for: asset.id)
        #expect(editor.canUndo(assetID: asset.id))
        #expect(try control("develop.repair.mode.redEye").accessibilityPerformPress())
        try await host.settle()
        #expect(workspace.tool == .redEye)
        #expect(editor.canUndo(assetID: asset.id), "Changing to Rote Augen preserves accepted painted repairs")
        var repairedAndEyes = repaired
        repairedAndEyes.developGeometry.redEyeCorrections = [try DevelopRedEyeCorrection(
            center: LocalMaskPoint(x: 0.4, y: 0.4), radiusX: 0.03, radiusY: 0.04, strength: 0.8)]
        editor.setSettings(repairedAndEyes, for: asset.id)
        #expect(try control("develop.repair.mode.heal").accessibilityPerformPress())
        try await host.settle()
        #expect(workspace.tool == .repair && workspace.repairMode == .heal)
        editor.undo(assetID: asset.id)
        #expect(editor.settings(for: asset.id) == repaired)
        editor.undo(assetID: asset.id)
        #expect(editor.settings(for: asset.id) == .newEditingSettings)
        #expect(!editor.canUndo(assetID: asset.id))
        editor.redo(assetID: asset.id)
        #expect(editor.settings(for: asset.id) == repaired)
        editor.redo(assetID: asset.id)
        #expect(editor.settings(for: asset.id) == repairedAndEyes)
        // Re-entering the same toolbar owner also retains the stack in red-eye mode.
        #expect(try control("develop.repair.mode.redEye").accessibilityPerformPress())
        try await host.settle()
        #expect(try control("develop.tool.repair").accessibilityPerformPress())
        try await host.settle()
        editor.undo(assetID: asset.id)
        #expect(editor.settings(for: asset.id) == repaired)
        editor.redo(assetID: asset.id)
        #expect(editor.settings(for: asset.id) == repairedAndEyes)
        #expect(await editor.finishSaving())
        #expect(await metadata.finishSaving())
        #expect(await library.finishSaving())
    }
}

private struct RepairToolbarInspector: View {
    @ObservedObject var library: LibraryModel
    @FocusState private var focus: WorkspaceControlFocus?
    var body: some View { DevelopInspector(library: library, focusedControl: $focus) }
}
