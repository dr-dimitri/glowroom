import AppKit
import Foundation
import PicEditCore
import SwiftUI
import Testing
@testable import PicEdit

@Suite("Workspace dock proposal lifecycle", .serialized, .timeLimit(.minutes(2)))
@MainActor
final class WorkspaceProposalLifecycleTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-WorkspaceLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test(arguments: [NSSize(width: 1_000, height: 660), NSSize(width: 1_440, height: 900)])
    func mountedLibraryKeepsFocusReturnPathWhenSearchTemporarilyRemovesSelection(size: NSSize) async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost(size: size)
        defer { host.close() }
        let suite = "PicEdit-WorkspaceMountedRoot-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        let metadataStore = PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata"))
        let metadataAnalysis = ImageAnalysisService(provider: UnavailableImageAnalysisProvider(reason: .sdkUnavailable),
            budget: AIResourceBudget())
        let metadata = PhotoMetadataModel(store: metadataStore,
            suggestor: LocalPhotoMetadataSuggestor(service: metadataAnalysis), library: f.library, editor: f.editor)
        let exporter = JPEGExportModel(preferences: nil)
        f.library.isDeveloping = false
        f.library.showsDetail = false
        let libraryPanels = layout.library, developPanels = layout.develop
        let assets = f.library.assets
        let originalBytes = try assets.map { try Data(contentsOf: $0.fileURL) }
        try await host.mount(
            LibraryView(model: f.library, dataDirectory: directory)
                .environmentObject(f.editor)
                .environmentObject(exporter)
                .environmentObject(layout)
                .environmentObject(f.assistant)
                .environmentObject(f.analysis)
                .environmentObject(metadata)
        )
        #expect(host.contentSize == size)
        WorkspaceActions.toggleFocus(layout, library: f.library)
        try await wait { layout.isFocused && f.library.isDeveloping && f.library.showsDetail }
        // Opt-in snapshots render this isolated native view, never the user's desktop.
        if let path = ProcessInfo.processInfo.environment["PICEDIT_WORKSPACE_SNAPSHOTS"] {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await host.settle()
            try host.snapshot(to: output.appendingPathComponent("focus-closed-\(Int(size.width)).png"))
            layout.reveal(.edit, developing: true)
            try await host.settle()
            try host.snapshot(to: output.appendingPathComponent("focus-open-\(Int(size.width)).png"))
            layout.update(developing: true) { $0.showsLibrary = true; $0.showsFilmstrip = true }
            try await host.settle()
            try host.snapshot(to: output.appendingPathComponent("focus-panels-\(Int(size.width)).png"))
            layout.update(developing: true) { $0.showsLibrary = false; $0.showsFilmstrip = false }
            layout.update(developing: true) { $0.showsTools = false }
        }
        let origin = layout.focusOrigin
        #expect(origin == WorkspaceFocusOrigin(developing: false, showsDetail: false))

        // This mutation is observed by the mounted LibraryView's onChange
        // handlers, including its real detail/selection-loss fallback.
        f.library.search = "no-photo-matches-this-query-\(UUID())"
        try await wait {
            !f.library.isProjecting && f.library.visibleAssets.isEmpty
                && f.library.selectedID == nil && !f.library.showsDetail
        }
        try await host.settle()
        #expect(layout.isFocused && f.library.isDeveloping)
        #expect(layout.focusOrigin == origin)
        // The same predicate keeps both the dock and enabled return command
        // mounted even when selectedAsset is nil; execute that actual command.
        WorkspaceActions.toggleFocus(layout, library: f.library)
        try await wait { !layout.isFocused && !f.library.isDeveloping && !f.library.showsDetail }
        #expect(layout.library == libraryPanels && layout.develop == developPanels)

        f.library.search = ""
        try await wait { !f.library.isProjecting && f.library.visibleAssets.count == 2 && f.library.selectedAsset != nil }
        WorkspaceActions.toggleFocus(layout, library: f.library)
        try await wait { layout.isFocused && f.library.showsDetail }
        f.library.search = "no-photo-matches-this-query-again-\(UUID())"
        try await wait { !f.library.isProjecting && f.library.selectedID == nil && !f.library.showsDetail }
        try await host.settle()
        #expect(layout.isFocused)
        f.library.search = ""
        try await wait {
            !f.library.isProjecting && f.library.selectedAsset != nil
                && f.library.isDeveloping && f.library.showsDetail
        }
        f.library.select(f.library.visibleAssets[1])
        #expect(f.library.selectedID == f.library.visibleAssets[1].id)
        #expect(layout.isFocused)
        WorkspaceActions.toggleFocus(layout, library: f.library)
        try await wait { !layout.isFocused && !f.library.isDeveloping && !f.library.showsDetail }
        #expect(layout.library == libraryPanels && layout.develop == developPanels)
        #expect(f.library.assets == assets)
        #expect(try assets.map { try Data(contentsOf: $0.fileURL) } == originalBytes)
        #expect(await f.provider.requests.isEmpty)
        #expect(await f.service.requests.isEmpty)
        #expect(!f.editor.hasPendingChanges)
        #expect(await f.editor.flush())
        #expect(await f.store.saveCount == 0)
        #expect(await metadata.finishSaving())
        #expect(await f.library.finishSaving())
    }

    @Test(arguments: [false, true])
    func hiddenSectionsRejectAnOriginalSourceReplacement(whilePending: Bool) async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost()
        defer { host.close() }
        try await host.mount(sections(f))
        try await wait { f.assistant.availability == .available && f.analysis.availability == .available }
        let baseline = try #require(f.editor.aiSnapshot(in: f.library))
        f.assistant.prompt = "Aufhellen"
        f.assistant.generate()
        f.analysis.analyze()
        try await wait {
            let proposals = await f.provider.requests.count
            let analyses = await f.service.requests.count
            return proposals == 1 && analyses == 1
        }
        if !whilePending {
            await f.provider.complete()
            await f.service.complete()
            try await wait { f.assistant.state == .previewing && f.analysis.state == .ready }
        }
        try await host.unmount()
        let original = try #require(f.library.selectedAsset).fileURL
        let bytes = try Data(contentsOf: original)
        try (bytes + Data([0])).write(to: original)
        f.library.refreshCurrentFolder()
        try await wait {
            !f.library.isImporting && !f.library.isProjecting
                && f.editor.aiSnapshot(in: f.library)?.source != baseline.source
                && f.assistant.result == nil && f.assistant.requestID == nil && f.analysis.result == nil
                && f.analysis.state != .analyzing
        }
        if whilePending {
            await f.provider.complete()
            await f.service.complete()
        }
        try await host.mount(sections(f))
        try await host.settle()
        #expect(f.library.selectedID == baseline.assetID)
        #expect(f.assistant.result == nil && !f.assistant.canAccept)
        #expect(f.analysis.result == nil)
        #expect(await f.provider.requests.count == 1)
        #expect(await f.service.requests.count == 1)
        #expect(f.editor.settings(for: baseline.assetID) == baseline.settings)
        #expect(await f.editor.flush())
        #expect(await f.store.saveCount == 0)
        #expect(await f.library.finishSaving())
    }

    @Test
    func paintedInlineMaskSurvivesPanelChangesAndDiscardsOnGridOrSourceChange() async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost(size: NSSize(width: 1_440, height: 900))
        defer { host.close() }
        let suite = "PicEdit-WorkspaceInlineMask-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        let metadataStore = PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata"))
        let metadataAnalysis = ImageAnalysisService(provider: UnavailableImageAnalysisProvider(reason: .sdkUnavailable),
            budget: AIResourceBudget())
        let metadata = PhotoMetadataModel(store: metadataStore,
            suggestor: LocalPhotoMetadataSuggestor(service: metadataAnalysis), library: f.library, editor: f.editor)
        let assetID = try #require(f.library.selectedID)
        let baselineSource = try #require(f.editor.aiSnapshot(in: f.library)).source
        let baselineSettings = f.editor.settings(for: assetID)
        let original = try #require(f.library.selectedAsset).fileURL
        let originalBytes = try Data(contentsOf: original)
        let mask = LocalAdjustmentEditorModel(settings: baselineSettings)
        f.library.showsDetail = true
        try await host.mount(
            LibraryView(model: f.library, dataDirectory: directory, localMaskModel: mask)
                .environmentObject(f.editor)
                .environmentObject(JPEGExportModel(preferences: nil))
                .environmentObject(layout)
                .environmentObject(f.assistant)
                .environmentObject(f.analysis)
                .environmentObject(metadata)
        )
        let maskButton = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.mask" })
        #expect(maskButton.accessibilityPerformPress())
        try await wait("inline mask canvas loads without a sheet") {
            mask.canvasSize != nil && host.sheet == nil && host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.canvas" }
        }
        mask.add(.brush)
        let canvas = try #require(mask.canvasSize)
        let painted = try MaskDocument(canvasSize: canvas, strokes: [MaskStroke(points: [
            MaskPoint(x: Double(canvas.width) * 0.25, y: Double(canvas.height) * 0.5),
            MaskPoint(x: Double(canvas.width) * 0.75, y: Double(canvas.height) * 0.5)
        ], radius: 0.2)])
        mask.updateSelected { $0.mask.shape = .brush(painted) }
        let paintedSettings = mask.settings
        do {
            try await wait("inline palette enables undo") {
                host.accessibilityElements.first { $0.accessibilityIdentifier() == "local-mask.undo" }?.isAccessibilityEnabled() == true
            }
        } catch {
            try? host.snapshot(to: URL(fileURLWithPath: "/private/tmp/picedit-inline-mask-lifecycle-failure.png"))
            Issue.record("Inline palette: developing=\(f.library.isDeveloping), detail=\(f.library.showsDetail), source=\(mask.source != nil), canUndo=\(mask.canUndo), layers=\(mask.settings.localAdjustments.count); AX=\(host.accessibilityElements.compactMap { $0.accessibilityIdentifier() })")
            throw error
        }
        WorkspaceActions.toggleFocus(layout, library: f.library)
        WorkspaceActions.toggleTools(layout, library: f.library)
        WorkspaceActions.toggleLibrary(layout, library: f.library)
        WorkspaceActions.toggleFilmstrip(layout, library: f.library)
        try await host.settle()
        #expect(host.sheet == nil)
        #expect(mask.settings == paintedSettings && mask.canUndo)
        // Showing a hidden panel preserves its draft. A dock/menu reveal is
        // navigation and is covered separately with acceptance semantics.
        layout.update(developing: true) { $0.showsTools = true }
        try await host.settle()
        #expect(mask.settings == paintedSettings && mask.canUndo)
        #expect(host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.canvas" })
        #expect(f.editor.settings(for: assetID) == baselineSettings)
        #expect(try Data(contentsOf: original) == originalBytes)

        WorkspaceActions.showGrid(layout, library: f.library)
        try await wait("leaving the canvas discards the unaccepted draft") { !f.library.showsDetail && mask.source == nil && mask.bitmap == nil }
        WorkspaceActions.reveal(.edit, layout: layout, library: f.library)
        try await host.settle()
        let reopen = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.mask" })
        #expect(reopen.accessibilityPerformPress())
        try await wait("reopening starts a clean draft") { mask.source == baselineSource && mask.canvasSize != nil && mask.settings == baselineSettings && !mask.canUndo }
        mask.add(.linear)
        try (originalBytes + Data([0])).write(to: original)
        f.library.refreshCurrentFolder()
        try await wait("replaced source discards its old draft") {
            !f.library.isImporting && !f.library.isProjecting
                && f.editor.aiSnapshot(in: f.library)?.source != baselineSource && mask.source == nil && mask.bitmap == nil
        }
        #expect(host.sheet == nil)
        let replacedSource = try #require(f.editor.aiSnapshot(in: f.library)).source
        let reopenAfterReplacement = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.mask" })
        #expect(reopenAfterReplacement.accessibilityPerformPress())
        try await wait("replacement gets a new inline canvas") { mask.source == replacedSource && mask.canvasSize != nil && mask.settings == baselineSettings }
        mask.add(.radial)
        let discard = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "local-mask.cancel" })
        #expect(discard.accessibilityPerformPress())
        try await wait("explicit discard closes the inline palette") { mask.source == nil && mask.bitmap == nil }
        #expect(f.editor.settings(for: assetID) == baselineSettings)
        #expect(await f.store.saveCount == 0)
        #expect(await metadata.finishSaving())
        #expect(await f.library.finishSaving())
    }

    @Test(arguments: [WorkspaceTool.edit, .assistant])
    func dockRevealAcceptsTheMaskDraftAndMountsItsDestination(tool: WorkspaceTool) async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost(size: NSSize(width: 1_440, height: 900))
        defer { host.close() }
        let suite = "PicEdit-RevealMask-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        let assetID = try #require(f.library.selectedID)
        let mask = LocalAdjustmentEditorModel(settings: f.editor.settings(for: assetID))
        let metadata = try await mountLibrary(f, mask: mask, layout: layout, host: host)
        let previousRequest = layout.revealRequest
        let open = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.mask" })
        #expect(open.accessibilityPerformPress())
        try await wait("mask draft before dock reveal") { mask.canvasSize != nil && mask.source != nil }
        #expect(layout.revealRequest == previousRequest, "Opening masks must not emit navigation to a hidden edit group")
        mask.add(.radial); mask.updateSelected { $0.settings.exposure = 1 }
        let expected = mask.settings
        #expect(f.editor.settings(for: assetID).localAdjustments.isEmpty)
        WorkspaceActions.reveal(tool, layout: layout, library: f.library)
        try await wait("dock target replaces the palette after draft acceptance") {
            mask.source == nil && f.editor.settings(for: assetID) == expected
                && host.accessibilityElements.contains { $0.accessibilityIdentifier() == "workspace.group.\(tool.rawValue)" }
        }
        #expect(host.sheet == nil)
        #expect(!host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.cancel" })
        #expect(layout.develop.openGroups.contains(tool))
        if tool == .assistant {
            // Direct inspector/menu reveals use the same path from geometry tools.
            let crop = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "develop.tool.crop" })
            #expect(crop.accessibilityPerformPress())
            try await wait("crop canvas is active") {
                host.accessibilityElements.contains { $0.accessibilityIdentifier() == "develop.interactive-canvas" }
            }
            layout.reveal(.versions, developing: true)
            try await wait("versions group mounts after leaving crop") {
                !host.accessibilityElements.contains { $0.accessibilityIdentifier() == "develop.interactive-canvas" }
                    && host.accessibilityElements.contains { $0.accessibilityIdentifier() == "workspace.group.versions" }
            }
        }
        #expect(f.editor.settings(for: assetID) == expected)
        f.editor.undo(assetID: assetID)
        #expect(f.editor.settings(for: assetID).localAdjustments.isEmpty)
        #expect(await f.editor.flush())
        #expect(await metadata.finishSaving())
        #expect(await f.library.finishSaving())
    }

    @Test func revealDuringAutomaticSelectionWaitsWithoutDiscardingTheDraft() async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost(size: NSSize(width: 1_440, height: 900))
        defer { host.close() }
        let suite = "PicEdit-RevealInference-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults), gate = WorkspaceMaskInferenceGate()
        let assetID = try #require(f.library.selectedID)
        let mask = LocalAdjustmentEditorModel(settings: .neutral, generator: { _, _, _ in try await gate.generate() })
        let metadata = try await mountLibrary(f, mask: mask, layout: layout, host: host)
        let open = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.mask" })
        #expect(open.accessibilityPerformPress())
        try await wait("draft source for automatic selection") { mask.canvasSize != nil }
        mask.add(.linear); mask.updateSelected { $0.settings.exposure = 1 }
        mask.add(.subject)
        try await wait("automatic selection has started") { await gate.started }
        WorkspaceActions.reveal(.assistant, layout: layout, library: f.library)
        try await host.settle()
        #expect(mask.source != nil && mask.isGenerating && mask.settings.localAdjustments.count == 1)
        #expect(f.editor.settings(for: assetID).localAdjustments.isEmpty)
        #expect(host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.cancel" })
        await gate.complete()
        try await wait("completed selection is accepted before assistant navigation") {
            mask.source == nil && f.editor.settings(for: assetID).localAdjustments.count == 2
                && host.accessibilityElements.contains { $0.accessibilityIdentifier() == "workspace.group.assistant" }
        }
        #expect(f.editor.settings(for: assetID).localAdjustments.first?.settings.exposure == 1)
        #expect(await f.editor.flush())
        #expect(await metadata.finishSaving())
        #expect(await f.library.finishSaving())
    }

    @Test(arguments: [false, true])
    func failedAutomaticSelectionKeepsItsDraftUntilANewExplicitReveal(retrySelection: Bool) async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost(size: NSSize(width: 1_440, height: 900))
        defer { host.close() }
        let suite = "PicEdit-RevealFailedInference-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults), gate = WorkspaceMaskInferenceGate()
        let assetID = try #require(f.library.selectedID)
        let mask = LocalAdjustmentEditorModel(settings: .neutral, generator: { _, _, _ in try await gate.generate() })
        let metadata = try await mountLibrary(f, mask: mask, layout: layout, host: host)
        let open = try #require(host.accessibilityElements.first { $0.accessibilityIdentifier() == "workspace.mask" })
        #expect(open.accessibilityPerformPress())
        try await wait("draft source before failed selection") { mask.canvasSize != nil }
        mask.add(.linear); mask.updateSelected { $0.settings.exposure = 1 }
        let originalDraft = mask.settings
        mask.add(.subject)
        try await wait("failing automatic selection has started") { await gate.pending }
        WorkspaceActions.reveal(.assistant, layout: layout, library: f.library)
        try await host.settle()
        #expect(mask.isGenerating && mask.source != nil)
        await gate.fail()
        try await wait("selection error is visible") { mask.errorMessage != nil && !mask.isGenerating }
        try await host.settle()
        #expect(mask.source != nil && mask.settings == originalDraft)
        #expect(f.editor.settings(for: assetID).localAdjustments.isEmpty)
        #expect(host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.cancel" })

        if retrySelection {
            // A later successful selection must not resurrect the destination
            // whose previous automatic continuation failed.
            mask.add(.subject)
            try await wait("replacement automatic selection has started") { await gate.pending }
            await gate.complete()
            try await wait("replacement selection finishes in its palette") {
                !mask.isGenerating && mask.settings.localAdjustments.count == 2
            }
            try await host.settle()
            #expect(mask.source != nil && mask.errorMessage == nil)
            #expect(f.editor.settings(for: assetID).localAdjustments.isEmpty)
            #expect(host.accessibilityElements.contains { $0.accessibilityIdentifier() == "local-mask.cancel" })
        }

        let accepted = mask.settings
        // An explicit navigation after a failure is allowed, including while
        // its already-understood error text remains visible in the palette.
        WorkspaceActions.reveal(.assistant, layout: layout, library: f.library)
        try await wait("a new explicit reveal accepts the retained draft") {
            mask.source == nil && f.editor.settings(for: assetID) == accepted
                && host.accessibilityElements.contains { $0.accessibilityIdentifier() == "workspace.group.assistant" }
        }
        #expect(f.editor.settings(for: assetID).localAdjustments.first?.settings.exposure == 1)
        #expect(await f.editor.flush())
        #expect(await metadata.finishSaving())
        #expect(await f.library.finishSaving())
    }

    @Test
    func acceptedProposalSaveFinishesWhileItsSectionsAndDetailAreHidden() async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost()
        defer { host.close() }
        let suite = "PicEdit-WorkspaceAcceptedSave-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        try await host.mount(sections(f))
        try await wait { f.assistant.availability == .available }
        let assetID = try #require(f.library.selectedID)
        let originalBytes = try Data(contentsOf: try #require(f.library.selectedAsset).fileURL)
        f.assistant.prompt = "Aufhellen"
        f.assistant.generate()
        try await wait { await f.provider.requests.count == 1 }
        await f.provider.complete()
        try await wait { f.assistant.canAccept }
        await f.store.blockWrites()
        #expect(f.assistant.acceptProposal())
        let saving = Task { await f.editor.flush() }
        try await wait { await f.store.hasBlockedWrite }
        try await host.unmount()
        WorkspaceActions.toggleFocus(layout, library: f.library)
        WorkspaceActions.toggleTools(layout, library: f.library)
        WorkspaceActions.showGrid(layout, library: f.library)
        #expect(f.editor.hasPendingChanges && f.editor.isSaving)
        #expect(f.editor.settings(for: assetID).exposure == 1)
        #expect(await f.store.saveCount == 0)
        await f.store.releaseWrite()
        #expect(await saving.value)
        try await host.mount(sections(f))
        #expect(!f.editor.hasPendingChanges)
        #expect(f.editor.settings(for: assetID).exposure == 1)
        #expect(f.editor.canUndo(assetID: assetID))
        #expect(f.assistant.result == nil)
        #expect(await f.store.saveCount == 1)
        #expect(await f.provider.requests.count == 1)
        #expect(try Data(contentsOf: try #require(f.library.selectedAsset).fileURL) == originalBytes)
        #expect(await f.library.finishSaving())
    }

    @Test(arguments: [false, true])
    func workspaceCommandsReturnToGridOrDetailWithoutChangingThePhoto(showsDetail: Bool) async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost()
        defer { host.close() }
        let suite = "PicEdit-WorkspaceActions-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayoutModel(defaults: defaults)
        layout.update(developing: false) {
            $0.showsLibrary = false; $0.libraryWidth = 270
            $0.openGroups = [.metadata, .analysis]; $0.filmstripHeight = 140
        }
        layout.update(developing: true) {
            $0.showsTools = false; $0.toolsWidth = 420
            $0.openGroups = [.edit, .versions]; $0.openAdjustmentGroups = ["presence"]
        }
        f.library.selection = .favorites
        f.library.search = ".png"
        f.library.minimumRating = 2
        f.library.sort = .name
        try await wait { !f.library.isProjecting && f.library.visibleAssets.count == 2 }
        f.library.select(f.library.visibleAssets[1], toggling: true)
        let selectedIDs = f.library.selectedIDs
        let selectedID = try #require(f.library.selectedID)
        #expect(selectedIDs.count == 2)
        f.editor.setSettings(EditSettings(exposure: 0.4), for: selectedID)
        f.editor.setSettings(EditSettings(exposure: 0.8), for: selectedID)
        f.editor.undo(assetID: selectedID)
        #expect(await f.editor.flush())
        let saves = await f.store.saveCount
        f.library.isDeveloping = false
        f.library.showsDetail = showsDetail
        let libraryPanels = layout.library, developPanels = layout.develop
        try await host.mount(sections(f))
        try await wait { f.assistant.availability == .available }
        f.assistant.prompt = "Aufhellen"
        f.assistant.generate()
        try await wait { await f.provider.requests.count == 1 }
        await f.provider.complete()
        try await wait { f.assistant.state == .previewing }
        let proposal = try #require(f.assistant.result)
        let snapshot = try #require(f.editor.aiSnapshot(in: f.library))

        WorkspaceActions.toggleFocus(layout, library: f.library)
        #expect(layout.isFocused && f.library.isDeveloping && f.library.showsDetail)
        WorkspaceActions.reveal(.assistant, layout: layout, library: f.library)
        #expect(layout.focus.showsTools && layout.focus.openGroups.contains(.assistant))
        WorkspaceActions.reveal(.analysis, layout: layout, library: f.library)
        WorkspaceActions.toggleLibrary(layout, library: f.library)
        WorkspaceActions.toggleFilmstrip(layout, library: f.library)
        WorkspaceActions.toggleFocus(layout, library: f.library)
        await Task.yield()

        #expect(!layout.isFocused)
        #expect(!f.library.isDeveloping && f.library.showsDetail == showsDetail)
        #expect(layout.library == libraryPanels && layout.develop == developPanels)
        #expect(f.library.selectedID == selectedID && f.library.selectedIDs == selectedIDs)
        #expect(f.library.selection == .favorites && f.library.search == ".png")
        #expect(f.library.minimumRating == 2 && f.library.sort == .name)
        #expect(f.editor.aiSnapshot(in: f.library) == snapshot)
        #expect(f.editor.canUndo(assetID: selectedID) && f.editor.canRedo(assetID: selectedID))
        #expect(f.assistant.result == proposal && f.assistant.canAccept)
        #expect(await f.provider.requests.count == 1)
        #expect(await f.service.requests.count == 0)
        #expect(await f.store.saveCount == saves)

        // The explicit grid command overrides either remembered focus origin.
        WorkspaceActions.toggleFocus(layout, library: f.library)
        WorkspaceActions.showGrid(layout, library: f.library)
        await Task.yield()
        #expect(!layout.isFocused && !f.library.isDeveloping && !f.library.showsDetail)
        #expect(layout.library == libraryPanels && layout.develop == developPanels)
        #expect(f.library.selectedID == selectedID && f.library.selectedIDs == selectedIDs)
        #expect(f.library.selection == .favorites && f.library.search == ".png")
        #expect(f.editor.aiSnapshot(in: f.library) == snapshot)
        #expect(f.editor.canUndo(assetID: selectedID) && f.editor.canRedo(assetID: selectedID))
        #expect(f.assistant.result == proposal && f.assistant.canAccept)

        // The same command also leaves an ordinary, non-focus tool/detail view.
        WorkspaceActions.reveal(.analysis, layout: layout, library: f.library)
        let revealedPanels = layout.develop
        WorkspaceActions.showGrid(layout, library: f.library)
        await Task.yield()
        #expect(!layout.isFocused && !f.library.isDeveloping && !f.library.showsDetail)
        #expect(layout.library == libraryPanels && layout.develop == revealedPanels)
        #expect(f.library.selectedID == selectedID && f.library.selectedIDs == selectedIDs)
        #expect(f.editor.aiSnapshot(in: f.library) == snapshot)
        #expect(f.assistant.result == proposal && f.assistant.canAccept)
        #expect(await f.provider.requests.count == 1)
        #expect(await f.service.requests.count == 0)
        #expect(await f.store.saveCount == saves)
        // Check the actual retained history, beyond the menu's enabled state.
        f.editor.redo(assetID: selectedID)
        #expect(f.editor.settings(for: selectedID).exposure == 0.8)
        f.editor.undo(assetID: selectedID)
        #expect(f.editor.settings(for: selectedID).exposure == 0.4)
        f.editor.undo(assetID: selectedID)
        #expect(f.editor.settings(for: selectedID).isNeutral)
        #expect(await f.editor.flush())
        #expect(await f.library.finishSaving())
    }

    @Test
    func pendingAndCompletedWorkSurvivesActualSectionUnmountAndModeChanges() async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost()
        defer { host.close() }
        let baseline = try #require(f.editor.aiSnapshot(in: f.library))
        let assets = f.library.assets
        let bytes = try assets.map { try Data(contentsOf: $0.fileURL) }
        try await host.mount(sections(f))
        try await wait { f.assistant.availability == .available && f.analysis.availability == .available }
        #expect(await f.provider.requests.count == 0)
        #expect(await f.service.requests.count == 0)

        f.assistant.prompt = "Tiefen aufhellen, warme Farben erhalten"
        f.assistant.generate()
        f.analysis.analyze()
        try await wait {
            let proposals = await f.provider.requests.count
            let analyses = await f.service.requests.count
            return proposals == 1 && analyses == 1
        }
        let assistantRequest = try #require(f.assistant.requestID)
        // Admission rechecks availability inside AIRequestCoordinator. Capture
        // that legitimate check before measuring subsequent layout-only work.
        let providerAvailabilityChecks = await f.provider.availabilityChecks
        let analysisAvailabilityChecks = await f.service.availabilityChecks
        try await host.unmount()
        f.library.isDeveloping = false
        await Task.yield()
        #expect(f.assistant.requestID == assistantRequest)
        #expect(f.assistant.state == .generating)
        #expect(f.analysis.state == .analyzing)

        await f.provider.complete()
        await f.service.complete()
        try await wait { f.assistant.state == .previewing && f.analysis.state == .ready }
        let proposal = try #require(f.assistant.result)
        let analysis = try #require(f.analysis.result)
        f.assistant.comparison = .current
        for _ in 0..<3 {
            f.library.isDeveloping = true
            try await host.mount(sections(f))
            #expect(f.assistant.result == proposal)
            #expect(f.assistant.canAccept)
            #expect(f.assistant.comparison == .current)
            #expect(f.assistant.prompt == "Tiefen aufhellen, warme Farben erhalten")
            #expect(f.analysis.result == analysis)
            try await host.unmount()
            f.library.isDeveloping = false
            await Task.yield()
        }
        #expect(await f.provider.requests.count == 1)
        #expect(await f.service.requests.count == 1)
        #expect(await f.provider.availabilityChecks == providerAvailabilityChecks)
        #expect(await f.service.availabilityChecks == analysisAvailabilityChecks)
        #expect(f.editor.aiSnapshot(in: f.library) == baseline)
        #expect(f.library.assets == assets)
        #expect(try assets.map { try Data(contentsOf: $0.fileURL) } == bytes)
        #expect(!f.editor.canUndo(assetID: baseline.assetID))
        #expect(!f.editor.hasPendingChanges)
        #expect(await f.editor.flush())
        #expect(await f.store.saveCount == 0)
        #expect(await f.library.finishSaving())
    }

    @Test
    func looksKeepSelectionAndComparisonUntilExplicitDiscard() async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost()
        defer { host.close() }
        try await host.mount(sections(f))
        try await wait { f.assistant.availability == .available }
        f.assistant.prompt = "Zusatz für drei Looks\n"
        f.assistant.generateLooks()
        try await wait { await f.provider.requests.count == 1 }
        await f.provider.complete()
        try await wait { f.assistant.state == .previewing }
        f.assistant.selectLook(.contrasty)
        f.assistant.comparison = .current
        let group = try #require(f.assistant.lookGroup)
        try await host.unmount()
        try await host.mount(sections(f))
        #expect(f.assistant.lookGroup == group)
        #expect(f.assistant.selectedLookID == .contrasty)
        #expect(f.assistant.cards.groupID == group.request.id)
        #expect(f.assistant.comparison == .current)
        #expect(f.assistant.prompt == "Zusatz für drei Looks\n")
        #expect(await f.provider.requests.count == 1)
        try await host.unmount()
        f.assistant.discard()
        try await host.mount(sections(f))
        #expect(f.assistant.lookGroup == nil)
        #expect(f.assistant.activeProposalResult == nil)
        #expect(f.assistant.cards.groupID == nil)
        #expect(await f.provider.requests.count == 1)
        #expect(await f.store.saveCount == 0)
        #expect(await f.library.finishSaving())
    }

    @Test
    func hiddenSectionsStillRejectRealSelectionAndEditChanges() async throws {
        let f = try await fixture()
        let host = WorkspaceSectionTestHost()
        defer { host.close() }
        try await host.mount(sections(f))
        try await wait { f.assistant.availability == .available && f.analysis.availability == .available }
        let selected = try #require(f.library.selectedID)
        for event in 0..<2 {
            f.assistant.prompt = "Aufhellen"
            f.assistant.generate()
            f.analysis.inputKind = .editedPreview
            f.analysis.analyze()
            try await wait {
                let proposals = await f.provider.requests.count
                let analyses = await f.service.requests.count
                return proposals == event + 1 && analyses == event + 1
            }
            await f.provider.complete()
            await f.service.complete()
            try await wait { f.assistant.state == .previewing && f.analysis.state == .ready }
            try await host.unmount()
            if event == 0 {
                f.library.selectedID = f.library.assets[1].id
                f.library.selectedID = selected
            } else {
                f.editor.setSettings(EditSettings(exposure: 0.5), for: selected)
                f.editor.undo(assetID: selected)
            }
            try await wait { f.assistant.result == nil && f.analysis.result == nil }
            try await host.mount(sections(f))
            #expect(!f.assistant.canAccept)
            #expect(f.analysis.result == nil)
            #expect(await f.provider.requests.count == event + 1)
            #expect(await f.service.requests.count == event + 1)
        }
        #expect(await f.editor.flush())
        #expect(await f.library.finishSaving())
    }

    private func sections(_ f: WorkspaceProposalFixture) -> some View {
        VStack {
            AIAssistantSection(model: f.assistant, comparesOriginal: false)
            ImageAnalysisSection(model: f.analysis)
        }
    }

    private func mountLibrary(_ f: WorkspaceProposalFixture, mask: LocalAdjustmentEditorModel,
                              layout: WorkspaceLayoutModel, host: WorkspaceSectionTestHost) async throws -> PhotoMetadataModel {
        let metadata = PhotoMetadataModel(store: PhotoMetadataRepository(directory: directory.appendingPathComponent("Metadata")),
            suggestor: LocalPhotoMetadataSuggestor(service: ImageAnalysisService(
                provider: UnavailableImageAnalysisProvider(reason: .sdkUnavailable), budget: AIResourceBudget())),
            library: f.library, editor: f.editor)
        f.library.showsDetail = true
        try await host.mount(LibraryView(model: f.library, dataDirectory: directory, localMaskModel: mask)
            .environmentObject(f.editor).environmentObject(JPEGExportModel(preferences: nil)).environmentObject(layout)
            .environmentObject(f.assistant).environmentObject(f.analysis).environmentObject(metadata))
        return metadata
    }

    private func fixture() async throws -> WorkspaceProposalFixture {
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let folder = LibraryFolder(url: photos)
        let assets = try ["A.png", "B.png"].map { name in
            let url = photos.appendingPathComponent(name)
            try png.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
            return PhotoAsset(folderID: folder.id, fileURL: url, fileSize: Int64(png.count),
                createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1),
                rating: 3, isFavorite: true)
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let store = WorkspaceProposalStore()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await wait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = assets[0].id
        library.isDeveloping = true
        let provider = WorkspaceProposalProvider()
        let assistant = AIAssistantModel(provider: provider,
            coordinator: AIRequestCoordinator(provider: provider, budget: AIResourceBudget()), editor: editor, library: library)
        let service = WorkspaceAnalysisService()
        let analysis = ImageAnalysisModel(service: service, editor: editor, library: library)
        return WorkspaceProposalFixture(library: library, editor: editor, store: store,
            provider: provider, service: service, assistant: assistant, analysis: analysis)
    }
}

/// A private, non-key test window exercises SwiftUI's real appear/disappear
/// callbacks without taking focus or changing any existing application window.
@MainActor
final class WorkspaceSectionTestHost {
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>
    private var appearances = 0
    private var disappearances = 0

    init(size: NSSize = NSSize(width: 340, height: 900)) {
        _ = NSApplication.shared
        WorkspaceAccessibilityElement.enableInProcess()
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    var contentSize: NSSize { hosting.bounds.size }
    var sheet: NSWindow? { window.attachedSheet }

    var accessibilityElements: [WorkspaceAccessibilityElement] { WorkspaceAccessibilityElement.descendants(of: hosting) }

    func accessibilityElements(in sheet: NSWindow) -> [WorkspaceAccessibilityElement] {
        WorkspaceAccessibilityElement.descendants(of: sheet.contentView)
    }

    func snapshot(to url: URL) throws {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    func settle() async throws {
        // Library projection publishes before SwiftUI handles onChange. Allow
        // that native update cycle before asserting the resulting root state.
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
    }

    func mount(_ content: some View) async throws {
        let expected = appearances + 1
        hosting.rootView = AnyView(content.onAppear { [weak self] in self?.appearances += 1 }
            .onDisappear { [weak self] in self?.disappearances += 1 })
        hosting.layoutSubtreeIfNeeded()
        try await wait { self.appearances >= expected }
    }

    func unmount() async throws {
        let expected = disappearances + 1
        hosting.rootView = AnyView(EmptyView())
        hosting.layoutSubtreeIfNeeded()
        try await wait { self.disappearances >= expected }
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.close() }
        window.close()
    }
}

@MainActor
private struct WorkspaceProposalFixture {
    let library: LibraryModel
    let editor: EditingModel
    let store: WorkspaceProposalStore
    let provider: WorkspaceProposalProvider
    let service: WorkspaceAnalysisService
    let assistant: AIAssistantModel
    let analysis: ImageAnalysisModel
}

@MainActor
private func wait(_ stage: String = "condition", _ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw WorkspaceLifecycleTestError.timeout(stage) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum WorkspaceLifecycleTestError: Error { case timeout(String) }

private actor WorkspaceProposalProvider: AIEditingProvider {
    nonisolated let id = "workspace-proposal-test"
    nonisolated let capabilities: AIProviderCapabilities = [.textEditing, .lookSuggestions]
    private(set) var requests: [AIEditingRequest] = []
    private(set) var availabilityChecks = 0
    private var pending: CheckedContinuation<Data, Error>?

    func availability() -> AIAvailability { availabilityChecks += 1; return .available }
    func proposal(for request: AIEditingRequest) async throws -> Data {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete() {
        let data: Data
        if requests.last?.mode == .lookGroup {
            let group = AILookProposalGroup(variants: [
                AILookProposal(id: .natural, name: "Natürlich", proposal: EditProposal(changes: [.init(parameter: .exposure, value: 0.6)])),
                AILookProposal(id: .contrasty, name: "Kontrastreich", proposal: EditProposal(changes: [.init(parameter: .contrast, value: 35)])),
                AILookProposal(id: .desaturated, name: "Entsättigt", proposal: EditProposal(changes: [.init(parameter: .saturation, value: -45)]))
            ])
            data = try! JSONEncoder().encode(group)
        } else {
            data = Data(#"{"schemaVersion":1,"changes":[{"parameter":"exposure","value":1}]}"#.utf8)
        }
        let continuation = pending; pending = nil
        continuation?.resume(returning: data)
    }
}

private actor WorkspaceAnalysisService: ImageAnalysisServing {
    nonisolated let descriptor = ImageAnalysisProviderDescriptor(providerID: "workspace-analysis-test", modelID: "synthetic")
    private(set) var requests: [ImageAnalysisRequest] = []
    private(set) var availabilityChecks = 0
    private var pending: CheckedContinuation<ImageAnalysisResult, Error>?
    func availability() -> ImageAnalysisAvailability { availabilityChecks += 1; return .available }
    func analyze(_ request: ImageAnalysisRequest) async throws -> ImageAnalysisResult {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func invalidate() {}
    func complete() {
        guard let request = requests.last else { return }
        let provenance = ImageAnalysisProvenance(descriptor: descriptor, analyzedAt: Date(timeIntervalSince1970: 100),
            rasterSHA256: String(repeating: "a", count: 64), pixelWidth: 1, pixelHeight: 1, byteCount: 4,
            colorProfile: "sRGB", colorProfileSHA256: nil, source: request.snapshot.source,
            inputKind: request.inputKind, editToken: request.inputKind == .editedPreview ? request.snapshot.token : nil)
        let continuation = pending; pending = nil
        continuation?.resume(returning: ImageAnalysisResult(request: request,
            suggestions: ImageAnalysisSuggestions(description: "Ein synthetisches Testbild.", attributes: []), provenance: provenance))
    }
}

private actor WorkspaceProposalStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    private(set) var saveCount = 0
    private var blocksWrites = false
    private var blockedWrite: CheckedContinuation<Void, Never>?
    var hasBlockedWrite: Bool { blockedWrite != nil }
    func blockWrites() { blocksWrites = true }
    func releaseWrite() { blocksWrites = false; blockedWrite?.resume(); blockedWrite = nil }
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) async {
        if blocksWrites { await withCheckedContinuation { blockedWrite = $0 } }
        values[assetID] = settings; versions[assetID] = revision; saveCount += 1
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/workspace-lifecycle-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
}

private actor WorkspaceMaskInferenceGate {
    private var continuation: CheckedContinuation<LocalMaskRaster, Error>?
    private(set) var started = false
    var pending: Bool { continuation != nil }
    func generate() async throws -> LocalMaskRaster {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete() {
        continuation?.resume(returning: try! LocalMaskRaster(width: 2, height: 2, bytes: Data(repeating: 255, count: 4)))
        continuation = nil
    }
    func fail() {
        continuation?.resume(throwing: WorkspaceMaskInferenceFailure.unavailable)
        continuation = nil
    }
}

private enum WorkspaceMaskInferenceFailure: LocalizedError {
    case unavailable
    var errorDescription: String? { "Die automatische Testauswahl ist fehlgeschlagen." }
}
