import AppKit
import CryptoKit
import Foundation
import GlowroomCore
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

@Suite("Unified object mask native acceptance", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct UnifiedObjectMaskAcceptanceTests {
    @Test(arguments: [NSSize(width: 1_000, height: 660), NSSize(width: 1_440, height: 900)])
    func objectProposalUsesThePhotoCanvasAndAcceptedMaskControls(size: NSSize) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-ObjectAcceptance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try fixtureImage()
        let imageURL = directory.appendingPathComponent("Roter-Kreis.png")
        let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let bytes = try Data(contentsOf: imageURL)
        let date = try imageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: imageURL, fileSize: Int64(bytes.count),
            pixelWidth: 768, pixelHeight: 512, modifiedAt: date)
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editingDirectory = directory.appendingPathComponent("Editing")
        let editor = EditingModel(directory: editingDirectory)
        try await wait("catalog and editor") { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = asset.id; library.workspaceMode = .develop
        let workspace = DevelopWorkspace(), service = ObjectMaskEvidenceService()
        workspace.tool = .masks
        let layer = try fixtureLayer()
        let object = InlineObjectMaskModel(propose: { snapshot, _ in
            try await service.request()
            let stamp = try await ImageAnalysisPreparer().sourceStamp(for: AIObjectMaskService.preparationRequest(snapshot: snapshot))
            return AIObjectMaskResponse(layer: layer, sourceStamp: stamp, summary: "Roter Kreis ausgewählt.", preview: nil)
        }, checkModels: { await service.requirement })
        let masks = InlineMaskWorkspace(objectMask: object)
        let host = WorkspaceSectionTestHost(size: size, appearance: NSAppearance(named: .darkAqua))
        let suite = "Glowroom-ObjectAcceptance-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let layout = WorkspaceLayoutModel(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite); host.close(); masks.cancel(); workspace.clear() }
        let source = try editor.resolvedSource(for: asset).identity
        try #require(masks.open(asset: asset, source: source, settings: editor.settings(for: asset.id), editor: editor, library: library, developWorkspace: workspace))
        let baseline = editor.settings(for: asset.id)
        try await host.mount(ObjectMaskEvidenceHarness(library: library, editor: editor, workspace: workspace, masks: masks)
            .frame(width: size.width, height: size.height).environmentObject(layout)
            .environmentObject(JPEGExportModel(preferences: nil)))
        try await wait("accepted full photo canvas") { masks.canvasSize != nil && workspace.isFinalPreviewReady && workspace.isOriginalCanvasReady }
        try await snapshot(host, size: size, name: "after-creator", masks: masks, editor: editor, asset: asset, bytes: bytes)
        try await press("local-mask.create.object", in: host)
        object.instruction = "Maskiere den roten Kreis"
        await object.refreshModels()
        try await snapshot(host, size: size, name: "after-order", masks: masks, editor: editor, asset: asset, bytes: bytes)
        try await press("local-mask.object.generate", in: host)
        try await wait("object request running") { object.isRunning }
        try await waitForTestState("native object inference entered", timeout: .seconds(10), state: { await service.count }, until: { $0 == 1 })
        try await snapshot(host, size: size, name: "after-running", masks: masks, editor: editor, asset: asset, bytes: bytes)
        await service.complete()
        try await wait("object proposal displayed") { object.proposal != nil && !object.isRunning }
        #expect(editor.settings(for: asset.id) == baseline && !editor.canUndo(assetID: asset.id))
        #expect(masks.displayMask == layer.mask && masks.displayMaskID == layer.id)
        #expect(!editor.hasPendingChanges)
        // The real canvas renders the same mask that will be accepted. Its
        // raster has an ellipse and fractional edge alpha, rather than a box.
        let canvasOverlay = try await LocalMaskOverlayWorker.shared.image(try #require(masks.displayMask), size: try #require(masks.canvasSize))
        let alpha = try overlayAlpha(canvasOverlay)
        #expect(alpha[256 * 768 + 384] == 255)
        #expect(alpha[132 * 768 + 196] == 0)
        #expect(alpha[100 * 768 + 384] == 0)
        #expect(alpha.contains { $0 > 0 && $0 < 255 })
        // Wait for the bounded overlay actor and native drawing before capture.
        try await Task.sleep(for: .milliseconds(100))
        try await snapshot(host, size: size, name: "after-proposal", masks: masks, editor: editor, asset: asset, bytes: bytes)
        try await press("local-mask.object.discard", in: host)
        #expect(object.proposal == nil && editor.settings(for: asset.id) == baseline && !editor.canUndo(assetID: asset.id))
        try await press("local-mask.object.generate", in: host)
        try await waitForTestState("second native object request", timeout: .seconds(10), state: { await service.count }, until: { $0 == 2 })
        await service.complete()
        try await wait("second object proposal") { object.proposal != nil && !object.isRunning }
        try await press("local-mask.object.apply", in: host)
        try await wait("object accepted") { object.proposal == nil && !object.isRunning && masks.selected?.id == layer.id }
        #expect(editor.settings(for: asset.id).localAdjustments == [layer])
        #expect(masks.usesBrush && masks.showsOverlay)
        for id in ["local-mask.invert", "local-mask.erase", "local-mask.control.Maskenstärke", "local-mask.control.Weiche Kante", "local-mask.correction.exposure"] {
            let control = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == id }, "Missing accepted-mask control \(id)")
            #expect(control.isAccessibilityEnabled())
        }
        #expect(host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.select.\(layer.id.uuidString)" })
        try await snapshot(host, size: size, name: "after-applied", masks: masks, editor: editor, asset: asset, bytes: bytes)
        masks.brush.appendPoint(try MaskPoint(x: 600, y: 100)); masks.finishGesture()
        #expect(masks.selected?.mask.refinement?.strokes.count == 1)
        masks.undo(); #expect(masks.selected == layer)
        masks.undo(); #expect(editor.settings(for: asset.id) == baseline)
        masks.redo(); #expect(masks.selected == layer)
        #expect(await editor.flush())
        let reopened = EditingModel(directory: editingDirectory)
        try await wait("reopened object mask") { !reopened.isLoading }
        #expect(reopened.settings(for: asset.id).localAdjustments == [layer])
        let create = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "local-mask.add" },
            "The accepted mask must expose the floating palette's New Mask menu")
        #expect(create.isAccessibilityEnabled())
        let menuNames = [create.accessibilityLabel(), create.accessibilityTitle()].compactMap { $0 }
        #expect(menuNames.first { !$0.isEmpty } == "Neue Maske", "Native menu names: \(menuNames)")
        #expect(!host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.show-creator" },
            "The visible floating palette owns the single New Mask entry")
        // Enter the same creation route as Neue Maske > Objekt beschreiben.
        // Native menu tracking requires an isolated child process in this
        // SwiftPM host; this test verifies the shared creator and setup route,
        // not a native menu-item click. The first request above enters through
        // the actual empty-state Objekt beschreiben button.
        masks.finishGesture()
        masks.showsObjectCreator = true
        try await host.settle()
        #expect(host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.object.generate" })
        for (requirement, name) in [(InlineObjectMaskModel.SetupRequirement.languageModel, "language"), (.subjectModel, "subject")] {
            await service.setRequirement(requirement)
            await object.refreshModels()
            try await host.settle()
            let setup = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "local-mask.object.setup" })
            #expect(setup.isAccessibilityEnabled())
            try await snapshot(host, size: size, name: "after-model-missing-" + name, masks: masks, editor: editor, asset: asset, bytes: bytes)
            try await press("local-mask.object.setup", in: host)
            try await wait("targeted model setup sheet") { host.sheet != nil }
            let sheet = try #require(host.sheet)
            let sheetView = try #require(sheet.contentView)
            let appearance = try #require(NSAppearance(named: .darkAqua))
            sheet.appearance = appearance; sheetView.appearance = appearance
            try await wait("model setup ready to close") { setupIsReady(host.accessibilityElements(in: sheet), requirement: requirement) }
            try await host.settle()
            let setupSize = sheetView.bounds.size
            let done = try #require(host.accessibilityElements(in: sheet).first { $0.accessibilityLabel() == "Fertig" })
            try #require(done.accessibilityPerformPress())
            try await wait("model setup dismissed") { host.sheet == nil }
            if let path = ProcessInfo.processInfo.environment["GLOWROOM_195_SNAPSHOTS"] {
                // A sheet's visual-effect backdrop cannot be cached by the
                // offscreen parent hosting view. After verifying the real route,
                // mount the same production view with its normal window color.
                let setupHost = WorkspaceSectionTestHost(size: setupSize, appearance: appearance)
                defer { setupHost.close() }
                try await setupHost.mount(AIModelsView(library: library,
                    destination: requirement == .languageModel ? .corrections : .subject)
                    .frame(width: setupSize.width, height: setupSize.height)
                    .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
                try await wait("standalone native setup ready") { setupIsReady(setupHost.accessibilityElements, requirement: requirement) }
                try await setupHost.settle()
                let output = URL(fileURLWithPath: path, isDirectory: true)
                let png = output.appendingPathComponent("after-model-setup-\(name)-\(Int(size.width)).png")
                try setupHost.snapshot(to: png)
                let pngBytes = try Data(contentsOf: png)
                let metadata: [String: Any] = ["state": "targeted model setup", "requiredModel": name,
                    "nativeView": "AIModelsView",
                    "sourceCommit": ProcessInfo.processInfo.environment["GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT"] ?? "working-tree",
                    "widthPoints": setupSize.width, "heightPoints": setupSize.height,
                    "screenshotSHA256": SHA256.hash(data: pngBytes).map { String(format: "%02x", $0) }.joined(),
                    "capture": "real sheet route asserted, identical production view in standalone native host with explicit system window background and dark color scheme",
                    "modelService": "real setup dialog, no download started", "macOS": ProcessInfo.processInfo.operatingSystemVersionString]
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: png.deletingPathExtension().appendingPathExtension("json"))
                try await setupHost.unmount()
            }
        }
        #expect(try Data(contentsOf: imageURL) == bytes)
        #expect(await editor.finishSaving()); #expect(await library.finishSaving())
        try await host.unmount()
    }

    private func setupIsReady(_ elements: [WorkspaceAccessibilityElement], requirement: InlineObjectMaskModel.SetupRequirement) -> Bool {
        let texts = elements.compactMap { $0.accessibilityLabel() ?? ($0.accessibilityValue() as? String) }
        let checking = texts.contains { $0.contains("wird geprüft") }
        let ready = requirement == .languageModel
            ? elements.contains { ["llm-model.download", "llm-model.delete"].contains($0.accessibilityIdentifier() ?? "") && $0.isAccessibilityEnabled() }
            : texts.contains { $0 == "Motivmodell ist bereit" || $0 == "Motivmodell aktualisieren" || $0 == "Modellpaket auswählen …" || $0 == "Modellpaket aktualisieren …" }
        return !checking && ready && elements.contains { $0.accessibilityLabel() == "Fertig" && $0.isAccessibilityEnabled() }
    }

    private func snapshot(_ host: WorkspaceSectionTestHost, size: NSSize, name: String, masks: InlineMaskWorkspace,
                          editor: EditingModel, asset: PhotoAsset, bytes: Data) async throws {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_195_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await host.settle()
        let filename = "\(name)-\(Int(size.width))"
        let png = output.appendingPathComponent(filename + ".png")
        try host.snapshot(to: png)
        let metadata: [String: Any] = [
            "sourceCommit": ProcessInfo.processInfo.environment["GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT"] ?? "working-tree",
            "windowWidthPoints": size.width, "windowHeightPoints": size.height,
            "state": name, "sourceName": asset.fileName, "zoom": "fitted, unchanged",
            "fixture": "synthetic 768x512 blue field with red ellipse",
            "sourceSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "screenshotSHA256": SHA256.hash(data: try Data(contentsOf: png)).map { String(format: "%02x", $0) }.joined(),
            "proposalVisible": masks.objectMask.proposal != nil,
            "acceptedMaskCount": editor.settings(for: asset.id).localAdjustments.count,
            "selectedMask": masks.selected?.name ?? "none",
            "localRevision": editor.localRevision(for: asset.id),
            "modelService": "controlled full-source elliptical alpha matte, no model inference",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(filename + ".json"))
    }
    private func press(_ identifier: String, in host: WorkspaceSectionTestHost) async throws {
        try await host.settle()
        let button = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == identifier },
            "Missing \(identifier); available: \(host.accessibilityElements.compactMap { $0.accessibilityIdentifier() })")
        try #require(button.isAccessibilityEnabled(), "\(identifier) must be enabled")
        try #require(button.accessibilityPerformPress())
    }
    private func wait(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        try await waitForTestState(description, timeout: .seconds(15), state: { @MainActor in condition() }, until: { $0 })
    }
    private func fixtureImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 768, height: 512, bitsPerComponent: 8, bytesPerRow: 768 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 768, height: 512))
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1)); context.fillEllipse(in: CGRect(x: 192, y: 128, width: 384, height: 256))
        return try #require(context.makeImage())
    }
    private func fixtureLayer() throws -> LocalAdjustment {
        let width = 192, height = 128
        var alpha = Data(count: width * height)
        for y in 0..<height { for x in 0..<width {
            let radius = sqrt(pow((Double(x) + 0.5 - 96) / 48, 2) + pow((Double(y) + 0.5 - 64) / 32, 2))
            alpha[y * width + x] = UInt8((max(0, min(1, (1 - radius) * 48 + 0.5)) * 255).rounded())
        } }
        return try LocalAdjustment(name: "Roter Kreis", mask: .init(shape: .subject(.init(width: width, height: height, bytes: alpha)), feather: 0))
    }
    private func overlayAlpha(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try #require(CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }
}

private actor ObjectMaskEvidenceService {
    private var outcomes: Set<Int> = []
    private(set) var count = 0
    private(set) var requirement: InlineObjectMaskModel.SetupRequirement?
    func request() async throws {
        count += 1; let index = count
        while !outcomes.contains(index) { try await Task.sleep(for: .milliseconds(10)) }
    }
    func complete() { outcomes.insert(count) }
    func setRequirement(_ value: InlineObjectMaskModel.SetupRequirement?) { requirement = value }
}

@MainActor
private struct ObjectMaskEvidenceHarness: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var editor: EditingModel
    @ObservedObject var workspace: DevelopWorkspace
    @ObservedObject var masks: InlineMaskWorkspace
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DetailView(model: library, photoViewport: workspace.photoViewport)
            ScrollView { InlineMaskInspector(workspace: masks).padding(12) }
                .frame(width: 340).background(Theme.panel)
        }.background(Theme.background).foregroundStyle(Theme.text).tint(Theme.accent).preferredColorScheme(.dark)
            .environmentObject(editor).environmentObject(workspace).environmentObject(masks)
            .environment(\.developSelectionIdentity, DevelopSelectionIdentity(sessionID: library.aiSelectionSessionID,
                generation: library.aiSelectionGeneration))
            .environment(\.developPreviewPending, { workspace.markPreviewPending($0) })
            .environment(\.developPreviewSink, { handoff in
                workspace.bind(source: handoff.identity.request.source)
                workspace.markDisplayed(source: handoff.identity.request.source, settings: handoff.identity.settings)
                workspace.receive(handoff.frame.output, sourceBitmap: handoff.decodedSource, sourceStamp: handoff.sourceStamp,
                    finalSourceReady: handoff.identity.finalSourceReady)
            })
            .environment(\.openAIModels, { library.aiModelsDestination = $0 })
            .sheet(item: $library.aiModelsDestination) { destination in
                AIModelsView(library: library, destination: destination)
            }
    }
}
