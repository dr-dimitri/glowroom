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

    private func fixture() async throws -> WorkspaceProposalFixture {
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let folder = LibraryFolder(url: photos)
        let assets = try ["A.png", "B.png"].map { name in
            let url = photos.appendingPathComponent(name)
            try png.write(to: url)
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
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderBack(nil)
    }

    var contentSize: NSSize { hosting.bounds.size }

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

    func close() { window.close() }
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
private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw WorkspaceLifecycleTestError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum WorkspaceLifecycleTestError: Error { case timeout }

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
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) {
        values[assetID] = settings; versions[assetID] = revision; saveCount += 1
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/workspace-lifecycle-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values }
}
