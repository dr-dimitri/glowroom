import AppKit
import CryptoKit
import Foundation
import GlowroomCore
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

@Suite("AI correction shared canvas evidence", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct AICorrectionReviewWorkspaceTests {
    @Test(arguments: [NSSize(width: 1_000, height: 660), NSSize(width: 1_440, height: 900)])
    func reviewIsTransientAndAcceptanceUpdatesOrdinaryControls(size: NSSize) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-AIReview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("Morgenlicht.png")
        let image = try image()
        let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let originalBytes = try Data(contentsOf: imageURL)
        let modifiedAt = try imageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: imageURL, fileSize: Int64(originalBytes.count),
            pixelWidth: image.width, pixelHeight: image.height, modifiedAt: modifiedAt)
        let catalog = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try catalog.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: catalog)
        let editingDirectory = directory.appendingPathComponent("Editing")
        let editor = EditingModel(directory: editingDirectory)
        try await wait("catalog and editor") { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = asset.id
        library.workspaceMode = .develop
        let workspace = DevelopWorkspace()
        let frames = AICorrectionEvidenceFrames()
        let service = AICorrectionEvidenceService()
        let proposal = AIDevelopmentProposal(summary: "Licht aufhellen und Farben wärmer abstimmen.",
            adjustments: .init(exposure: 1.2, contrast: 16, shadows: 40, temperature: 7_100))
        let model = AIDevelopmentModel(propose: { snapshot, _, _ in
            try await service.request()
            let request = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: UUID())
            return AIDevelopmentResponse(proposal: proposal,
                sourceStamp: try await ImageAnalysisPreparer().sourceStamp(for: request))
        })
        let baseline = editor.settings(for: asset.id)
        let expected = try proposal.adjustments.applying(to: baseline, intent: model.intent)
        let host = WorkspaceSectionTestHost(size: size, appearance: NSAppearance(named: .darkAqua))
        defer { host.close(); model.discard(); workspace.clear() }
        let suite = "Glowroom-AIReview-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        let maskWorkspace = InlineMaskWorkspace()
        func content(checkModel: @escaping @Sendable () async throws -> Bool) -> some View {
            AICorrectionEvidenceHarness(library: library, editor: editor, workspace: workspace,
                model: model, asset: asset, frames: frames, checkModel: checkModel)
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
                .environmentObject(layout).environmentObject(maskWorkspace)
                .environmentObject(JPEGExportModel(preferences: nil))
        }
        try await host.mount(content(checkModel: { true }))
        try await wait("final accepted canvas") {
            frames.latest?.settings == baseline && frames.latest?.sourceWidth == image.width
                && workspace.sourceSize?.width == CGFloat(image.width)
        }
        let digest = try #require(frames.latest?.digest)
        let decodedImage = try #require(workspace.originalBitmap?.image)
        #expect(await service.count == 0, "Mounting the panel must not infer")
        try await snapshot(host, size: size, name: "after-empty", model: model, workspace: workspace,
            editor: editor, asset: asset, sourceBytes: originalBytes, frames: frames)
        model.intent.instruction = "Natürliches Licht, wärmere Farben"
        try await press("ai-development.generate", in: host)
        try await wait("running request") { model.isRunning }
        try await waitForTestState("first inference entered", timeout: .seconds(10),
            state: { await service.count }, until: { $0 == 1 })
        try await snapshot(host, size: size, name: "after-running", model: model, workspace: workspace,
            editor: editor, asset: asset, sourceBytes: originalBytes, frames: frames)
        await service.complete()
        try await wait("rendered correction proposal") { model.proposal != nil && !model.isRunning && workspace.aiCorrectionPreview != nil }
        #expect(editor.settings(for: asset.id) == baseline)
        #expect(!editor.canUndo(assetID: asset.id), "Review must not create history")
        #expect(!editor.hasPendingChanges, "Review must not schedule a write")
        #expect(frames.latest?.settings == baseline && frames.latest?.digest == digest,
            "The accepted preview handoff remains the current editor state")
        #expect(workspace.originalBitmap?.image === decodedImage, "Correction rendering reuses the decoded image")
        #expect(workspace.aiCorrectionPreview?.settings == expected)
        #expect(try workspace.aiCorrectionPreview.map { try ImageAnalysisPreparer.describeRaster($0.bitmap).digest } != digest)
        try await snapshot(host, size: size, name: "after-proposal", model: model, workspace: workspace,
            editor: editor, asset: asset, sourceBytes: originalBytes, frames: frames)
        try await press("ai-development.current", in: host)
        #expect(!workspace.showsAICorrectionProposal)
        try await snapshot(host, size: size, name: "after-current", model: model, workspace: workspace,
            editor: editor, asset: asset, sourceBytes: originalBytes, frames: frames)
        try await press("ai-development.proposal", in: host)
        #expect(workspace.showsAICorrectionProposal)
        #expect(await service.count == 1, "Switching the review view must reuse the rendered proposal")
        try await press("ai-development.apply", in: host)
        try await wait("accepted correction rendered") {
            !model.isRunning && model.proposal == nil && editor.settings(for: asset.id) == expected
                && frames.latest?.settings == expected && workspace.aiCorrectionPreview == nil
        }
        try await snapshot(host, size: size, name: "after-applied", model: model, workspace: workspace,
            editor: editor, asset: asset, sourceBytes: originalBytes, frames: frames)
        try await host.settle()
        for control in [Adjustment.exposure, .contrast, .shadows] {
            let slider = try #require(host.sliders.first { $0.accessibilityLabel() == control.label })
            #expect(slider.doubleValue == expected[keyPath: control.keyPath])
        }
        let temperature = try #require(host.sliders.first { $0.accessibilityLabel() == "Temperatur" })
        #expect(temperature.doubleValue == expected.developColor.temperature)
        #expect(await editor.finishSaving())
        editor.undo(assetID: asset.id)
        #expect(editor.settings(for: asset.id) == baseline)
        #expect(!editor.canUndo(assetID: asset.id), "One undo removes the whole correction")
        editor.redo(assetID: asset.id)
        #expect(editor.settings(for: asset.id) == expected)
        #expect(await editor.finishSaving())
        let reopened = EditingModel(directory: editingDirectory)
        try await wait("durable accepted correction") { !reopened.isLoading }
        #expect(reopened.settings(for: asset.id) == expected)
        try await press("ai-development.generate", in: host)
        try await wait("second running request") { model.isRunning }
        try await waitForTestState("second inference entered", timeout: .seconds(10),
            state: { await service.count }, until: { $0 == 2 })
        await service.fail()
        try await wait("visible failure") { !model.isRunning && model.status != nil }
        #expect(model.proposal == nil && workspace.aiCorrectionPreview == nil)
        try await snapshot(host, size: size, name: "after-error", model: model, workspace: workspace,
            editor: editor, asset: asset, sourceBytes: originalBytes, frames: frames)
        let acceptedRevision = editor.localRevision(for: asset.id)
        try await press("ai-development.generate", in: host)
        try await waitForTestState("discardable inference entered", timeout: .seconds(10),
            state: { await service.count }, until: { $0 == 3 })
        await service.complete()
        try await wait("discardable proposal") { !model.isRunning && model.proposal != nil }
        try await press("ai-development.discard", in: host)
        #expect(model.proposal == nil && workspace.aiCorrectionPreview == nil)
        #expect(editor.settings(for: asset.id) == expected)
        #expect(editor.localRevision(for: asset.id) == acceptedRevision, "Discard only removes the proposal")
        try await press("ai-development.generate", in: host)
        try await wait("cancelable request") { model.isRunning }
        try await waitForTestState("cancelable inference entered", timeout: .seconds(10),
            state: { await service.count }, until: { $0 == 4 })
        try await press("ai-development.cancel", in: host)
        try await wait("canceled request") { !model.isRunning }
        #expect(model.status == "Abgebrochen.")
        #expect(editor.settings(for: asset.id) == expected)
        #expect(model.proposal == nil && workspace.aiCorrectionPreview == nil)
        try await host.unmount()
        try await host.mount(content(checkModel: { false }))
        try await wait("model setup action with a final photo preview") {
            workspace.isFinalPreviewReady && workspace.navigatorImage != nil
                && frames.latest?.settings == expected
                && host.accessibilityElements.contains { $0.accessibilityIdentifier() == "ai-development.model-required" }
        }
        try await snapshot(host, size: size, name: "after-model-missing", model: model, workspace: workspace,
            editor: editor, asset: asset, sourceBytes: originalBytes, frames: frames)
        #expect(try Data(contentsOf: imageURL) == originalBytes)
        #expect(await editor.finishSaving())
        #expect(await library.finishSaving())
        try await host.unmount()
    }

    private func snapshot(_ host: WorkspaceSectionTestHost, size: NSSize, name: String,
                          model: AIDevelopmentModel, workspace: DevelopWorkspace,
                          editor: EditingModel, asset: PhotoAsset, sourceBytes: Data,
                          frames: AICorrectionEvidenceFrames) async throws {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_194_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await host.settle()
        let filename = "\(name)-\(Int(size.width))"
        try host.snapshot(to: output.appendingPathComponent(filename + ".png"))
        let metadata: [String: Any] = [
            "sourceCommit": ProcessInfo.processInfo.environment["GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT"] ?? "working-tree",
            "windowWidthPoints": size.width, "windowHeightPoints": size.height,
            "state": name, "sourceName": asset.fileName, "zoom": "fitted, unchanged",
            "fixture": ProcessInfo.processInfo.environment["GLOWROOM_194_FIXTURE"] ?? "synthetic-768x512",
            "sourceSHA256": SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined(),
            "acceptedPreviewDigest": frames.latest?.digest ?? "none",
            "proposalVisible": workspace.showsAICorrectionProposal && workspace.aiCorrectionPreview != nil,
            "proposalDigest": try workspace.aiCorrectionPreview.map { try ImageAnalysisPreparer.describeRaster($0.bitmap).digest } ?? "none",
            "acceptedExposure": editor.settings(for: asset.id).exposure,
            "localRevision": editor.localRevision(for: asset.id),
            "modelService": "controlled response, no model inference",
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
        try await waitForTestState(description, timeout: .seconds(10), state: { @MainActor in condition() }, until: { $0 })
    }

    private func image() throws -> CGImage {
        if let path = ProcessInfo.processInfo.environment["GLOWROOM_194_FIXTURE"] {
            let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            return try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 768] as CFDictionary))
        }
        let context = try #require(CGContext(data: nil, width: 768, height: 512, bitsPerComponent: 8, bytesPerRow: 768 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 768, height: 512))
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 192, y: 128, width: 384, height: 256))
        return try #require(context.makeImage())
    }
}

private actor AICorrectionEvidenceService {
    private var outcomes: [Int: Bool] = [:]
    private(set) var count = 0
    func request() async throws {
        count += 1
        let index = count
        while outcomes[index] == nil { try await Task.sleep(for: .milliseconds(10)) }
        if outcomes[index] == false { throw AIDevelopmentError.inferenceFailed }
    }
    func complete() { outcomes[count] = true }
    func fail() { outcomes[count] = false }
}

@MainActor
private final class AICorrectionEvidenceFrames {
    struct Frame { let settings: EditSettings; let digest: String; let sourceWidth: Int }
    var latest: Frame?
    func receive(_ handoff: DevelopPreviewHandoff) {
        do {
            latest = Frame(settings: handoff.identity.settings,
                digest: try ImageAnalysisPreparer.describeRaster(handoff.frame.output).digest,
                sourceWidth: handoff.decodedSource.image.width)
        } catch { Issue.record("Cannot inspect accepted canvas: \(error)") }
    }
}

@MainActor
private struct AICorrectionEvidenceHarness: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var editor: EditingModel
    @ObservedObject var workspace: DevelopWorkspace
    let model: AIDevelopmentModel
    let asset: PhotoAsset
    let frames: AICorrectionEvidenceFrames
    let checkModel: @Sendable () async throws -> Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Licht und Farbe").font(.system(size: 15, weight: .semibold))
                ForEach([Adjustment.exposure, .contrast, .shadows]) { control in
                    AdjustmentSlider(control: control, value: Binding(
                        get: { editor.settings(for: asset.id)[keyPath: control.keyPath] },
                        set: { value in
                            var settings = editor.settings(for: asset.id)
                            settings[keyPath: control.keyPath] = value
                            editor.setSettings(settings, for: asset.id)
                        }), onEditingChanged: { editing in
                            if editing { editor.beginEditing(assetID: asset.id) }
                            else { editor.endEditing(assetID: asset.id) }
                        })
                }
                Text("Temperatur").font(.system(size: 13))
                ResettableSlider(value: Binding(
                    get: { editor.settings(for: asset.id).developColor.temperature },
                    set: { value in
                        var settings = editor.settings(for: asset.id)
                        settings.developColor.temperature = value
                        editor.setSettings(settings, for: asset.id)
                    }), in: DevelopColorSettings.temperatureRange, step: 50, neutralValue: 6_500,
                    onEditingChanged: { editing in
                        if editing { editor.beginEditing(assetID: asset.id) }
                        else { editor.endEditing(assetID: asset.id) }
                    }).accessibilityLabel("Temperatur")
                Text(editor.settings(for: asset.id).developColor.temperature.formatted() + " K").font(.system(size: 13))
                Spacer(minLength: 0)
            }.padding(12).frame(width: 210).background(Theme.panel)
            DetailView(model: library, photoViewport: workspace.photoViewport)
            ScrollView {
                AIDevelopmentView(library: library, model: model, checkModel: checkModel).padding(12)
            }.frame(width: 310).background(Theme.panel)
        }
        .background(Theme.background).foregroundStyle(Theme.text).tint(Theme.accent)
        .environmentObject(editor).environmentObject(workspace)
        .environment(\.aiCorrectionDisplay, workspace.correctionDisplay(library: library, editor: editor))
        .environment(\.developSelectionIdentity, DevelopSelectionIdentity(sessionID: library.aiSelectionSessionID,
            generation: library.aiSelectionGeneration))
        .environment(\.photoPreviewReloadID, workspace.previewReloadID)
        .environment(\.developPreviewPending, { workspace.markPreviewPending($0) })
        .environment(\.developPreviewSink, { handoff in
            workspace.bind(source: handoff.identity.request.source)
            workspace.markDisplayed(source: handoff.identity.request.source, settings: handoff.identity.settings)
            workspace.receive(handoff.frame.output, sourceBitmap: handoff.decodedSource,
                sourceStamp: handoff.sourceStamp, finalSourceReady: handoff.identity.finalSourceReady)
            frames.receive(handoff)
        })
    }
}
