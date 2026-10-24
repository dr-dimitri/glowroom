import AppKit
import Foundation
import GlowroomCore
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

@Suite("AI development mounted acceptance", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct AIDevelopmentAcceptanceTests {
    @Test(arguments: ["global", "whiteBalance", "mask"])
    func acceptanceUpdatesNativeControlsPreviewHistoryAndDurableSettings(scenario: String) async throws {
        let screenshotProposal = scenario == "whiteBalance"
        let masked = scenario == "mask"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-AIAcceptance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("photo.png")
        let image = try Self.image()
        let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let modifiedAt = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: imageURL.path)
        let originalBytes = try Data(contentsOf: imageURL)
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: imageURL, fileSize: Int64(originalBytes.count),
            pixelWidth: image.width, pixelHeight: image.height, modifiedAt: modifiedAt)
        let catalog = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try catalog.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: catalog)

        // Seed the production store before loading the editor. The proposal must
        // preserve unrelated edits and add exactly one history transaction.
        let editingDirectory = directory.appendingPathComponent("Editing")
        let dependencies = try await ArtifactAppBootstrap(directory: editingDirectory).editingDependencies()
        let state = try await dependencies.database.loadState()
        var baseline = screenshotProposal ? EditSettings(texture: 21)
            : EditSettings(exposure: 0.2, contrast: -4, shadows: 12, texture: 21)
        let layer = try LocalAdjustment(name: "Blumenstrauß", mask: LocalAdjustmentMask(shape: .radial(
            center: LocalMaskPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.3, rotation: 0)))
        if masked { baseline.localAdjustments = [layer] }
        let expectedState = try EditingExpectedState(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil)
        _ = try await dependencies.database.saveSnapshot(EditingSnapshot(settings: baseline), for: asset.id,
            expected: expectedState, revision: 1)
        let editor = EditingModel(directory: editingDirectory, loader: { dependencies })
        try await wait("catalog and editor loaded") { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = asset.id
        library.workspaceMode = .develop
        let workspace = DevelopWorkspace()
        let frames = AIAcceptanceFrames()
        let proposal = screenshotProposal
            ? AIDevelopmentProposal(summary: "Weiß und Dynamik leicht erhöhen, Weißabgleich wärmer abstimmen.",
                adjustments: .init(whites: 10, vibrance: 20, temperature: 6_800))
            : AIDevelopmentProposal(summary: "Belichtung und Schatten aufhellen, Kontrast erhöhen.",
                adjustments: .init(exposure: 1.2, contrast: 16, shadows: 40))
        let controls: [Adjustment] = screenshotProposal ? [.whites, .vibrance] : [.exposure, .contrast, .shadows]
        var scope = AIDevelopmentIntent()
        scope.targetMaskID = masked ? layer.id : nil
        let settings = try proposal.adjustments.applying(to: baseline, intent: scope)
        if screenshotProposal {
            #expect(settings.whites == 5 && settings.vibrance == 10 && settings.developColor.temperature == 6_650)
        }
        let model = AIDevelopmentModel(propose: { snapshot, _, _ in
            let request = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: UUID())
            return AIDevelopmentResponse(proposal: proposal,
                sourceStamp: try await ImageAnalysisPreparer().sourceStamp(for: request))
        })
        model.intent.targetMaskID = scope.targetMaskID
        model.intent.brightness = screenshotProposal ? 0 : 0.6
        let requestedIntent = model.intent
        defer { model.discard(); workspace.clear() }
        let host = WorkspaceSectionTestHost(size: NSSize(width: 1_160, height: 1_100))
        defer { host.close() }
        do {
            try await host.mount(AIAcceptanceHarness(library: library, editor: editor, workspace: workspace,
                model: model, asset: asset, frames: frames, controls: controls))
            // The progressive 512px frame can precede the full source. Start only
            // after the real canvas has handed off the 768px source bitmap.
            try await wait("full baseline canvas") {
                frames.latest?.settings == baseline && frames.latest?.sourceWidth == image.width
                    && workspace.sourceSize?.width == CGFloat(image.width)
            }
            let baselineDigest = try #require(frames.latest?.digest)
            let baselineExportDigest = scenario == "global"
                ? try await exportPixelDigest(asset: asset, editor: editor, to: directory.appendingPathComponent("baseline.jpg")) : nil
            #expect(!editor.canUndo(assetID: asset.id))
            try await press("ai-development.generate", in: host)
            try await wait("proposal displayed") { model.proposal != nil && !model.isRunning }
            #expect(model.proposal?.settings == settings)
            #expect(editor.settings(for: asset.id) == baseline)
            let candidate = try #require(workspace.aiCorrectionPreview)
            #expect(candidate.settings == settings && candidate.snapshot.settings == baseline)
            #expect(workspace.showsAICorrectionProposal)
            try await host.settle()
            #expect(frames.latest?.settings == baseline && frames.latest?.digest == baselineDigest,
                "Proposal display must not hand unaccepted pixels to scopes, sampling or accepted preview consumers")
            if let baselineExportDigest {
                let reviewingExport = try await exportPixelDigest(asset: asset, editor: editor,
                    to: directory.appendingPathComponent("while-reviewing.jpg"))
                #expect(reviewingExport == baselineExportDigest,
                    "The real JPEG exporter must use accepted settings while the proposal is visible")
            }
            try #require(await editor.flush())
            #expect(try await dependencies.database.loadState().byAsset[asset.id]?.snapshot.settings == baseline)
            #expect(!editor.canUndo(assetID: asset.id))
            try await press("ai-development.current", in: host)
            #expect(!workspace.showsAICorrectionProposal)
            try await press("ai-development.proposal", in: host)
            #expect(workspace.showsAICorrectionProposal)
            #expect(frames.latest?.settings == baseline && editor.settings(for: asset.id) == baseline)
            try await press("ai-development.discard", in: host)
            #expect(workspace.aiCorrectionPreview == nil && model.proposal == nil)
            #expect(editor.settings(for: asset.id) == baseline && !editor.canUndo(assetID: asset.id))
            try await press("ai-development.generate", in: host)
            try await wait("proposal rendered again") { model.proposal != nil && !model.isRunning }
            try await press("ai-development.apply", in: host)
            try await wait("proposal accepted and rendered") {
                !model.isRunning && model.proposal == nil && editor.settings(for: asset.id) == settings
                    && frames.latest?.settings == settings && frames.latest?.sourceWidth == image.width
            }
            if masked {
                #expect(model.status == "Vorschlag auf „Blumenstrauß“ übernommen.")
                #expect(settings.exposure == baseline.exposure)
                #expect(settings.localAdjustments[0].settings.exposure == 0.6)
                #expect(settings.localAdjustments[0].mask == layer.mask)
            } else {
                #expect(model.status == "Vorschlag übernommen.")
            }
            #expect(model.intent == requestedIntent, "Intent sliders describe the request and retain its directions")
            #expect(frames.latest?.digest != baselineDigest)
            if let baselineExportDigest {
                let acceptedExport = try await exportPixelDigest(asset: asset, editor: editor,
                    to: directory.appendingPathComponent("after-acceptance.jpg"))
                #expect(acceptedExport != baselineExportDigest,
                    "Only accepting the correction may change the exported JPEG pixels")
            }
            try await expectNativeControls(settings, controls: controls, in: host)
            #expect(editor.settings(for: asset.id).texture == baseline.texture)
            // The first accepted write schedules the real daily backup. Drain
            // its admission fences before invoking history directly: a native
            // button would be disabled during maintenance, while this test
            // deliberately calls the controller API after awaiting UI renders.
            try #require(await editor.finishSaving())
            try #require(editor.canEdit && editor.canUndo(assetID: asset.id))

            editor.undo(assetID: asset.id)
            try #require(editor.settings(for: asset.id) == baseline)
            try await wait("undo rendered") { frames.latest?.settings == baseline }
            #expect(editor.settings(for: asset.id) == baseline)
            #expect(frames.latest?.digest == baselineDigest)
            #expect(!editor.canUndo(assetID: asset.id), "The accepted proposal is one shared undo step")
            try await expectNativeControls(baseline, controls: controls, in: host)
            try #require(editor.canEdit && editor.canRedo(assetID: asset.id))
            editor.redo(assetID: asset.id)
            try #require(editor.settings(for: asset.id) == settings)
            try await wait("redo rendered") { frames.latest?.settings == settings }
            try await expectNativeControls(settings, controls: controls, in: host)
            #expect(await editor.finishSaving())
            #expect(try await dependencies.database.loadState().byAsset[asset.id]?.snapshot.settings == settings)
            let reopened = EditingModel(directory: editingDirectory)
            try await wait("persisted editor reopened") { !reopened.isLoading }
            #expect(reopened.settings(for: asset.id) == settings)
            let acceptedRevision = editor.localRevision(for: asset.id)
            model.intent.strength = 0
            let zeroStrengthIntent = model.intent
            try await press("ai-development.generate", in: host)
            try await wait("zero strength proposal displayed") { model.proposal != nil && !model.isRunning }
            #expect(model.proposal?.settings == settings)
            #expect(!model.canApplyProposal)
            try await host.settle()
            let apply = try #require(host.accessibilityElements.first {
                $0.accessibilityIdentifier() == "ai-development.apply"
            })
            #expect(!apply.isAccessibilityEnabled(), "A zero-strength proposal cannot offer an empty acceptance")
            #expect(model.intent == zeroStrengthIntent)
            #expect(editor.settings(for: asset.id) == settings)
            #expect(editor.localRevision(for: asset.id) == acceptedRevision)
            model.discard()
            #expect(try Data(contentsOf: imageURL) == originalBytes)
            #expect(await library.finishSaving())
            try await host.unmount()
        } catch {
            model.discard()
            try? await host.unmount()
            workspace.clear()
            _ = await editor.finishSaving()
            _ = await library.finishSaving()
            throw error
        }
    }

    private func press(_ identifier: String, in host: WorkspaceSectionTestHost) async throws {
        try await host.settle()
        let button = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == identifier },
            "Missing \(identifier); available: \(host.accessibilityElements.compactMap { $0.accessibilityIdentifier() })")
        try #require(button.isAccessibilityEnabled(), "\(identifier) must be enabled")
        try #require(button.accessibilityPerformPress())
    }

    private func exportPixelDigest(asset: PhotoAsset, editor: EditingModel, to target: URL) async throws -> String {
        let resolved = try editor.resolvedSource(for: asset, intent: .currentEditing)
        guard case .original(let source) = resolved.identity else {
            throw ArtifactContractError.invalidCapability
        }
        let result = try await JPEGExporter().export(.init(
            sourceURL: URL(fileURLWithPath: source.standardizedPath), destinationURL: target,
            settings: resolved.settings, options: .init(quality: 100), protectedSourceURLs: [asset.fileURL]))
        let encoded = try #require(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let bitmap = PreviewBitmap(image: try #require(CGImageSourceCreateImageAtIndex(encoded, 0, nil)))
        return try ImageAnalysisPreparer.describeRaster(bitmap).digest
    }

    private func expectNativeControls(_ settings: EditSettings, controls: [Adjustment],
                                      in host: WorkspaceSectionTestHost) async throws {
        try await host.settle()
        for control in controls {
            let slider = try #require(host.sliders.first {
                $0.accessibilityLabel() == control.label
                    && $0.minValue == control.range.lowerBound && $0.maxValue == control.range.upperBound
            })
            #expect(abs(slider.doubleValue - settings[keyPath: control.keyPath]) < 0.000_001,
                "The native \(control.label) slider must display the accepted editor value")
        }
        let temperature = try #require(host.sliders.first { $0.accessibilityLabel() == "Temperatur" })
        #expect(temperature.doubleValue == settings.developColor.temperature)
    }

    private func wait(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        try await waitForTestState(description, timeout: .seconds(10),
            state: { @MainActor in condition() }, until: { $0 })
    }

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 768, height: 512, bitsPerComponent: 8, bytesPerRow: 768 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 768, height: 512))
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 192, y: 128, width: 384, height: 256))
        return try #require(context.makeImage())
    }
}

@MainActor
private final class AIAcceptanceFrames {
    struct Frame {
        let settings: EditSettings
        let digest: String
        let sourceWidth: Int
    }
    var latest: Frame?

    func receive(settings: EditSettings, bitmap: PreviewBitmap, source: PreviewBitmap) {
        do {
            latest = Frame(settings: settings, digest: try ImageAnalysisPreparer.describeRaster(bitmap).digest,
                sourceWidth: source.image.width)
        } catch { Issue.record("Cannot inspect the accepted preview: \(error)") }
    }
}

@MainActor
private struct AIAcceptanceHarness: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var editor: EditingModel
    @ObservedObject var workspace: DevelopWorkspace
    let model: AIDevelopmentModel
    let asset: PhotoAsset
    let frames: AIAcceptanceFrames
    let controls: [Adjustment]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            AIDevelopmentView(library: library, model: model).frame(width: 360)
            EditingPhotoPreview(asset: asset, intent: .currentEditing, developing: true).frame(width: 400, height: 400)
            VStack {
                ForEach(controls) { control in
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
            }.frame(width: 300)
        }
        .padding(20)
        .environmentObject(editor)
        .environmentObject(workspace)
        .environment(\.developSelectionIdentity, DevelopSelectionIdentity(
            sessionID: library.aiSelectionSessionID, generation: library.aiSelectionGeneration))
        .environment(\.aiCorrectionDisplay, workspace.correctionDisplay(library: library, editor: editor))
        .environment(\.developPreviewSink, { handoff in
            let request = handoff.identity.request
            let settings = handoff.identity.settings
            let bitmap = handoff.frame.output
            let source = handoff.decodedSource
            workspace.bind(source: request.source)
            workspace.markDisplayed(source: request.source, settings: settings)
            workspace.receive(bitmap, sourceBitmap: source, sourceStamp: handoff.sourceStamp,
                finalSourceReady: handoff.identity.finalSourceReady)
            frames.receive(settings: settings, bitmap: bitmap, source: source)
        })
    }
}
