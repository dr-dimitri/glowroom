import AppKit
import Foundation
import GlowroomCore
import ImageIO
import SwiftUI
import Testing
@testable import Glowroom

@Suite("Combined semantic mask and correction candidate workflow", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct AIEditPlanWorkflowTests {
    @Test func defaultProductGateRejectsPlanModeBeforeAnyInference() async throws {
        let fixture = try await PlanWorkflowFixture.make()
        defer { fixture.remove() }
        let model = AIDevelopmentModel()
        model.requestMode = .maskCorrection; model.intent.instruction = "Den Himmel dunkler"
        #expect(!model.permitsEditPlans)
        #expect(model.start(library: fixture.library, editor: fixture.editor, workspace: fixture.workspace) == nil)
        #expect(model.status?.contains("nicht freigegeben") == true)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
    }

    @Test func externalGlobalProposalClearsThePreviousCombinedOrLocalScope() async throws {
        let fixture = try await PlanWorkflowFixture.make()
        defer { fixture.remove() }
        let masks = InlineMaskWorkspace()
        fixture.editor.developCommands.bind(workspace: fixture.workspace, masks: masks)
        let model = fixture.model()
        model.intent.targetMaskID = fixture.baseline.localAdjustments[0].id
        let snapshot = try #require(fixture.editor.aiSnapshot(in: fixture.library))
        try await model.prepareExternal(snapshot: snapshot, patch: DevelopNumericPatch([.init(.exposure, 1)]),
            library: fixture.library, editor: fixture.editor, workspace: fixture.workspace)
        #expect(model.requestMode == .correction && model.intent.targetMaskID == nil)
        #expect(model.proposal?.targetName == nil && model.proposal?.createdMaskID == nil)
        #expect(model.proposal?.settings.exposure == 1)
        #expect(model.proposal?.settings.localAdjustments == fixture.baseline.localAdjustments)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        model.discard()
    }

    @Test func nativeSourceReplacementDuringRenderCannotPublishAPlan() async throws {
        let fixture = try await PlanWorkflowFixture.make()
        defer { fixture.remove() }
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        defer { release.releaseAll() }
        let model = AIDevelopmentModel(proposePlan: { snapshot, _ in try await PlanWorkflowFixture.response(snapshot: snapshot) },
            renderCorrection: { bitmap, _, _, _ in entered.releaseAll(); await release.wait(); return bitmap })
        model.requestMode = .maskCorrection; model.intent.instruction = "Den Himmel dunkler"
        let task = try #require(model.start(library: fixture.library, editor: fixture.editor, workspace: fixture.workspace))
        await entered.wait()
        // Atomic replacement retains public bytes/mtime while changing native
        // identity. A post-render native source check must still reject it.
        try fixture.original.write(to: fixture.asset.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fixture.asset.modifiedAt], ofItemAtPath: fixture.asset.fileURL.path)
        release.releaseAll(); await task.value
        #expect(model.proposal == nil && fixture.workspace.aiCorrectionPreview == nil)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
    }

    @Test func oneCompleteAcceptanceAndUndoPreserveEveryExistingValueAndSurviveReopen() async throws {
        let fixture = try await PlanWorkflowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        await (try #require(model.start(library: fixture.library, editor: fixture.editor, workspace: fixture.workspace))).value
        let review = try #require(model.proposal)
        #expect(review.includesMaskCorrection && review.createdMaskID != nil && model.canApplyProposal)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        #expect(!fixture.editor.hasPendingChanges && !fixture.editor.canUndo(assetID: fixture.asset.id))
        let correction = try #require(fixture.workspace.aiCorrectionPreview)
        let renderedSize = try DevelopGeometryRenderer.outputSize(width: 128, height: 96,
            geometry: fixture.baseline.developGeometry)
        #expect(correction.bitmap.image.width == renderedSize.width && correction.bitmap.image.height == renderedSize.height)
        model.showReview(.selection, workspace: fixture.workspace)
        #expect(model.reviewDisplay == .selection && fixture.workspace.showsAICorrectionProposal)
        let overlay = try #require(fixture.workspace.aiCorrectionPreview?.bitmap)
        #expect(overlay.image.width == renderedSize.width && overlay.image.height == renderedSize.height)
        #expect(overlay.image !== correction.bitmap.image)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        model.showReview(.current, workspace: fixture.workspace)
        #expect(!fixture.workspace.showsAICorrectionProposal)
        model.showReview(.proposal, workspace: fixture.workspace)
        #expect(fixture.workspace.aiCorrectionPreview?.bitmap.image === correction.bitmap.image)
        await (try #require(model.apply(library: fixture.library, editor: fixture.editor))).value
        let accepted = fixture.editor.settings(for: fixture.asset.id)
        #expect(accepted == review.settings && accepted.localAdjustments.count == fixture.baseline.localAdjustments.count + 1)
        var previous = accepted; previous.localAdjustments.removeLast()
        #expect(previous == fixture.baseline)
        #expect(accepted.localAdjustments.last?.settings.exposure == -0.7)
        #expect(await fixture.editor.finishSaving())
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        fixture.editor.redo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == accepted)
        #expect(await fixture.editor.finishSaving())
        let reopened = EditingModel(directory: fixture.editingDirectory)
        #expect(await reopened.finishSaving())
        #expect(reopened.settings(for: fixture.asset.id) == accepted)
        reopened.beginTermination(); _ = await reopened.finishSaving()
        #expect(try Data(contentsOf: fixture.asset.fileURL) == fixture.original)
    }

    @Test(arguments: ["cancel", "selectionABA", "editUndo", "mode", "source", "failure"])
    func rejectedOrStalePlanNeverPublishesAMaskOrPartialUndo(change: String) async throws {
        let fixture = try await PlanWorkflowFixture.make()
        defer { fixture.remove() }
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        defer { release.releaseAll() }
        let model = fixture.model(propose: { snapshot, _ in
            entered.releaseAll(); await release.wait()
            if change == "failure" { throw AIEditPlanError.invalidResponse }
            return try await PlanWorkflowFixture.response(snapshot: snapshot)
        })
        let task = try #require(model.start(library: fixture.library, editor: fixture.editor, workspace: fixture.workspace))
        await entered.wait()
        switch change {
        case "cancel": model.cancel()
        case "selectionABA": fixture.library.selectedID = nil; fixture.library.selectedID = fixture.asset.id
        case "editUndo":
            var values = fixture.baseline; values.exposure += 1
            fixture.editor.setSettings(values, for: fixture.asset.id); fixture.editor.undo(assetID: fixture.asset.id)
        case "mode": model.requestMode = .correction
        case "source": fixture.workspace.clear()
        default: break
        }
        release.releaseAll(); await task.value
        #expect(model.proposal == nil && model.maskPreview == nil && fixture.workspace.aiCorrectionPreview == nil)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.finishSaving())
    }

    @Test(arguments: [NSSize(width: 1000, height: 660), NSSize(width: 1440, height: 900)])
    func nativeReviewOffersSelectionAndEffectBeforeOneAtomicAcceptance(size: NSSize) async throws {
        let fixture = try await PlanWorkflowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        let host = WorkspaceSectionTestHost(size: size, appearance: NSAppearance(named: .darkAqua))
        let suite = "Glowroom-PlanWorkflow-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let layout = WorkspaceLayoutModel(defaults: defaults)
        let masks = InlineMaskWorkspace()
        defer { host.close(); model.discard(); defaults.removePersistentDomain(forName: suite) }
        let initialBitmap = fixture.workspace.originalBitmap.map { ObjectIdentifier($0.image) }
        try await host.mount(PlanWorkflowHarness(fixture: fixture, model: model)
            .environmentObject(layout).environmentObject(masks)
            .environmentObject(JPEGExportModel(preferences: nil)).preferredColorScheme(.dark))
        try await wait("ready canvas") {
            fixture.workspace.isFinalPreviewReady && fixture.workspace.originalBitmap.map { ObjectIdentifier($0.image) } != initialBitmap
        }
        try await host.settle()
        #expect(host.accessibilityElements.contains { $0.accessibilityIdentifier() == "ai-development.request-mode" })
        #expect(!host.accessibilityElements.contains { $0.accessibilityIdentifier() == "ai-development.scope" })
        #expect(!host.accessibilityElements.contains { $0.accessibilityIdentifier() == "ai-development.strength" })
        try await press("ai-development.generate", host: host)
        try await wait("complete plan review") { model.proposal != nil && !model.isRunning }
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        try await press("ai-development.selection", host: host)
        #expect(model.reviewDisplay == .selection)
        try await press("ai-development.current", host: host)
        #expect(!fixture.workspace.showsAICorrectionProposal)
        try await press("ai-development.proposal", host: host)
        #expect(model.reviewDisplay == .proposal)
        if let directory = ProcessInfo.processInfo.environment["GLOWROOM_221_SNAPSHOTS"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try host.snapshot(to: root.appendingPathComponent("combined-plan-\(Int(size.width)).png"))
        }
        let expected = try #require(model.proposal?.settings)
        try await press("ai-development.apply", host: host)
        try await wait("plan accepted") { model.proposal == nil && !model.isRunning }
        #expect(fixture.editor.settings(for: fixture.asset.id) == expected)
        #expect(await fixture.editor.finishSaving())
        fixture.editor.undo(assetID: fixture.asset.id)
        #expect(fixture.editor.settings(for: fixture.asset.id) == fixture.baseline)
        #expect(!fixture.editor.canUndo(assetID: fixture.asset.id))
        #expect(await fixture.editor.finishSaving())
        try await host.unmount()
    }
    private func press(_ identifier: String, host: WorkspaceSectionTestHost) async throws {
        try await host.settle()
        let element = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == identifier })
        try #require(element.isAccessibilityEnabled()); try #require(element.accessibilityPerformPress())
    }
    private func wait(_ label: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
        try await waitForTestState(label, timeout: .seconds(15), state: { @MainActor in predicate() }, until: { $0 })
    }
}

@MainActor
private struct PlanWorkflowFixture {
    let directory: URL
    let editingDirectory: URL
    let asset: PhotoAsset
    let library: LibraryModel
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let baseline: EditSettings
    let original: Data

    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-PlanWorkflow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8,
            bytesPerRow: 128 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        let image = try #require(context.makeImage())
        let url = directory.appendingPathComponent("sky.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); try #require(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: url, fileSize: Int64(original.count), pixelWidth: 128, pixelHeight: 96, modifiedAt: date)
        let catalog = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try catalog.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let editingDirectory = directory.appendingPathComponent("Editing")
        let dependencies = try await ArtifactAppBootstrap(directory: editingDirectory).editingDependencies()
        let state = try await dependencies.database.loadState()
        var baseline = EditSettings(exposure: 0.2, shadows: 7)
        baseline.developGeometry = DevelopGeometry(crop: try .init(x: 0.1, y: 0.1, width: 0.7, height: 0.6), quarterTurns: 1, flipHorizontal: true)
        baseline.localAdjustments = [try .init(name: "Vorhanden", mask: .init(shape: .radial(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.3, rotation: 0)), settings: .init(exposure: 0.1))]
        _ = try await dependencies.database.saveSnapshot(EditingSnapshot(settings: baseline), for: asset.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let library = LibraryModel(repository: catalog), editor = EditingModel(directory: editingDirectory, loader: { dependencies })
        async let a = library.finishSaving(); async let b = editor.finishSaving()
        let loaded = await (a, b); try #require(loaded.0 && loaded.1)
        await library.waitForProjection(); library.selectedID = asset.id; library.workspaceMode = .develop; library.showsDetail = true
        let workspace = DevelopWorkspace()
        let snapshot = try #require(editor.aiSnapshot(in: library))
        let stamp = try await ImageAnalysisPreparer().sourceStamp(for: AIObjectMaskService.preparationRequest(snapshot: snapshot))
        let bitmap = PreviewBitmap(image: image)
        workspace.bind(source: snapshot.source)
        workspace.markDisplayed(source: snapshot.source, settings: baseline)
        workspace.receive(bitmap, sourceBitmap: bitmap, sourceStamp: stamp)
        return Self(directory: directory, editingDirectory: editingDirectory, asset: asset,
            library: library, editor: editor, workspace: workspace, baseline: baseline, original: original)
    }
    func model(propose: AIDevelopmentModel.ProposePlan? = nil) -> AIDevelopmentModel {
        let model = AIDevelopmentModel(proposePlan: propose ?? { snapshot, _ in try await Self.response(snapshot: snapshot) })
        model.requestMode = .maskCorrection; model.intent.instruction = "Den Himmel dunkler"
        return model
    }
    nonisolated static func response(snapshot: AIEditingSnapshot) async throws -> AIEditPlanResponse {
        let layer = try LocalAdjustment(name: "Himmel", mask: .init(shape: .sky(.init(width: 4, height: 3,
            bytes: Data([255,255,255,255,128,128,128,128,0,0,0,0]))), feather: 0))
        let plan = try AIEditPlan(baseline: snapshot, target: .init(kind: .sky, description: "Himmel", summary: "Himmel abdunkeln"),
            maskDraft: layer, proposal: .init(summary: "Den Himmel etwas dunkler gestalten", adjustments: .init(exposure: -0.7)),
            provenance: .init(languageModelRevision: "controlled-test", maskModelRevision: "controlled-test", preprocessingVersion: "full-source-test"))
        let stamp = try await ImageAnalysisPreparer().sourceStamp(for: AIObjectMaskService.preparationRequest(snapshot: snapshot))
        return AIEditPlanResponse(plan: plan, sourceStamp: stamp)
    }
    func remove() {
        workspace.clear(); editor.beginTermination(); library.beginTermination()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct PlanWorkflowHarness: View {
    let fixture: PlanWorkflowFixture
    @ObservedObject var model: AIDevelopmentModel
    @ObservedObject private var library: LibraryModel
    @ObservedObject private var editor: EditingModel
    @ObservedObject private var workspace: DevelopWorkspace
    init(fixture: PlanWorkflowFixture, model: AIDevelopmentModel) {
        self.fixture = fixture; self.model = model
        self.library = fixture.library; self.editor = fixture.editor; self.workspace = fixture.workspace
    }
    var body: some View {
        HStack(spacing: 12) {
            DetailView(model: library, photoViewport: workspace.photoViewport)
            ScrollView { AIDevelopmentView(library: library, model: model).padding(12) }.frame(width: 330)
        }.background(Theme.background).foregroundStyle(Theme.text).tint(Theme.accent)
            .environmentObject(editor).environmentObject(workspace)
            .environment(\.aiCorrectionDisplay, workspace.correctionDisplay(library: library, editor: editor))
            .environment(\.developSelectionIdentity, DevelopSelectionIdentity(sessionID: library.aiSelectionSessionID,
                generation: library.aiSelectionGeneration))
            .environment(\.developPreviewPending, { workspace.markPreviewPending($0) })
            .environment(\.developPreviewSink, { handoff in
                workspace.bind(source: handoff.identity.request.source)
                workspace.markDisplayed(source: handoff.identity.request.source, settings: handoff.identity.settings)
                workspace.receive(handoff.frame.output, sourceBitmap: handoff.decodedSource, sourceStamp: handoff.sourceStamp,
                    finalSourceReady: handoff.identity.finalSourceReady)
            })
    }
}
