import SwiftUI
import AppKit
import PicEditCore

#if !PICEDIT_DEVELOPER_HARNESS
@main
#endif
struct PicEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library: LibraryModel
    @StateObject private var editor: EditingModel
    @StateObject private var assistant: AIAssistantModel
    @StateObject private var aiSettings: AIProviderSettings
    @StateObject private var imageAnalysis: ImageAnalysisModel
    @StateObject private var photoMetadata: PhotoMetadataModel
    @StateObject private var exporter = JPEGExportModel()
    @StateObject private var layout = WorkspaceLayoutModel()
    @FocusedValue(\.editingHistory) private var editingHistory
    private let dataDirectory: URL
    private let artifactBootstrap: ArtifactAppBootstrap

    init() {
        let args = ProcessInfo.processInfo.arguments
        let directory: URL?
        if let index = args.firstIndex(of: "--catalog-directory"), args.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else { directory = nil }
        let repository = CatalogRepository(directory: directory)
        dataDirectory = repository.directory
        let semantic = try? SemanticSearchService(directory: repository.directory)
        let bootstrap = ArtifactAppBootstrap(directory: repository.directory)
        artifactBootstrap = bootstrap
        let metadataStore = bootstrap.metadata
        let library = LibraryModel(repository: repository, semanticSearch: semantic, metadataStore: metadataStore,
            lifecycle: bootstrap.gate, coordinator: { try await bootstrap.coordinator() },
            editingDependencies: { try await bootstrap.editingDependencies() },
            catalogCleanup: { catalog, reference in
                let changed = try await bootstrap.reconcileCatalog(catalog, reference: reference)
                try await semantic?.purgeRemovedAssets(retaining: Set(catalog.assets.map(\.id)))
                return changed
            })
        let editor = EditingModel(directory: repository.directory, loader: { try await bootstrap.editingDependencies() })
        editor.library = library
        library.synchronizeEditing = { [weak editor] in try await editor?.reloadAfterCatalogChange() }
        library.invalidateEditingSources = { [weak editor] in editor?.invalidateSourcesForCoordination() }
        let provider = LocalAIEditingProviderFactory.makeProvider()
        let coordinator = AIRequestCoordinator(provider: provider)
        _library = StateObject(wrappedValue: library)
        _editor = StateObject(wrappedValue: editor)
        let assistant = AIAssistantModel(provider: provider, coordinator: coordinator,
                                                             editor: editor, library: library,
                                                             maximumPromptBytes: LocalAIEditingPrompt.maximumUserTextBytes)
        let aiSettings = AIProviderSettings(directory: repository.directory, local: provider)
        aiSettings.attach(assistant)
        _assistant = StateObject(wrappedValue: assistant)
        _aiSettings = StateObject(wrappedValue: aiSettings)
        let vision = LocalImageAnalysisFactory.makeSharedService()
        _imageAnalysis = StateObject(wrappedValue: ImageAnalysisModel(service: vision, editor: editor, library: library))
        let photoMetadata = PhotoMetadataModel(store: metadataStore,
            suggestor: LocalPhotoMetadataSuggestor(service: vision), library: library, editor: editor)
        library.prepareCatalogCleanup = { [weak editor, weak photoMetadata] in
            guard editor?.isRestoring != true, editor?.isBackingUp != true else { throw CatalogLifecycleError.maintenanceAlreadyPending }
            let saved = await editor?.flush() ?? true
            guard saved || editor?.hasPendingChanges == false,
                  await photoMetadata?.drainAcceptedWrites() ?? true else { throw ArtifactContractError.staleSnapshot }
        }
        _photoMetadata = StateObject(wrappedValue: photoMetadata)
    }

    var body: some Scene {
        Window("PicEdit", id: "library") {
            LibraryView(model: library, dataDirectory: dataDirectory)
                .environmentObject(editor)
                .environmentObject(exporter)
                .environmentObject(layout)
                .environmentObject(assistant)
                .environmentObject(imageAnalysis)
                .environmentObject(photoMetadata)
                .frame(minWidth: 1000, minHeight: 660)
                .preferredColorScheme(.dark)
                .background {
                    if let consent = aiSettings.pendingConsent {
                        AICloudConsentPresenter(settings: aiSettings, consent: consent)
                            .id(consent.id)
                    }
                }
                .background {
                    if let review = photoMetadata.importReview {
                        PhotoMetadataImportPresenter(model: photoMetadata, review: review).id(review.id)
                    }
                }
                .background {
                    if let review = photoMetadata.catalogReview {
                        PhotoMetadataCatalogReviewPresenter(model: photoMetadata, review: review).id(review.id)
                    }
                }
                .onChange(of: library.isRetryingCoordination) { _, retrying in
                    if !retrying, library.coordinationError == nil { editor.retryLoading(); photoMetadata.retryLoading() }
                }
                .onAppear { delegate.photoMetadata = photoMetadata; delegate.library = library; delegate.editor = editor; delegate.exporter = exporter; delegate.aiSettings = aiSettings; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ordner hinzufügen …") { library.chooseFolders() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!library.canModify || library.isImporting)
                Divider()
                Button(library.selectedIDs.count > 1 ? "Ausgewählte Fotos exportieren …" : "Foto exportieren …") {
                    JPEGExportActions.present(using: exporter, library: library, editor: editor)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(library.selectedIDs.isEmpty || !library.canExportJPEG || library.isProjecting || editor.isLoading || editor.isRestoring || editor.isClosing || exporter.isPresented)
            }
            CommandMenu("Bibliothek") {
                Button("Bildinformationen exportieren …") { PhotoMetadataImportExportActions.export(using: photoMetadata) }
                    .disabled(!photoMetadata.canManage)
                Button("Bildinformationen importieren …") { PhotoMetadataImportExportActions.import(using: photoMetadata) }
                    .disabled(!photoMetadata.canManage)
                Menu("Ordnerzuordnungen für Bildinformationen prüfen") {
                    ForEach(library.metadataCatalogChanges.filter { !$0.conflicts.isEmpty }, id: \.changeID) { change in
                        Button("\(change.conflicts.count) offene Zuordnungen") {
                            photoMetadata.inspectCatalogChange(change, reference: library.metadataCatalogReference)
                        }
                    }
                }.disabled(!library.canResolvePhotoMetadataCatalogChanges || library.metadataCatalogChanges.allSatisfy { $0.conflicts.isEmpty })
                Divider()
                Button("Ordner aktualisieren") { library.refreshCurrentFolder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!library.canModify || library.isImporting || library.folders.isEmpty)
                Divider()
                Button("Im Finder anzeigen") { library.reveal() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(library.selectedAsset == nil)
                Button("Favorit umschalten") { library.toggleFavorite() }.disabled(library.selectedAsset == nil)
            }
            CommandMenu("Entwickeln") {
                Button("Foto entwickeln") {
                    library.isDeveloping = true
                    library.showsDetail = true
                    layout.reveal(.edit, developing: true)
                }.keyboardShortcut("d", modifiers: .command).disabled(library.selectedAsset == nil || editor.isLoading)
                Button(library.comparesOriginal ? "Bearbeitung anzeigen" : "Importiertes Original anzeigen") { library.comparesOriginal.toggle() }
                    .disabled(!library.isDeveloping || library.selectedAsset == nil || editingHistory?.allowsComparison == false)
                Divider()
                Button("Bearbeitung rückgängig") { editingHistory?.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(editingHistory?.canUndo != true)
                Button("Bearbeitung wiederholen") { editingHistory?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(editingHistory?.canRedo != true)
                Button("Alle Regler zurücksetzen") { editingHistory?.reset() }
                    .disabled(editingHistory?.canReset != true)
                Divider()
                Button("Änderungen erneut speichern") { Task { _ = await editor.flush() } }
                    .disabled(!editor.hasPendingChanges || editor.isSaving || editor.isLoading || editor.isRestoring)
                Button("Bearbeitungen sichern …") { EditingBackupActions.create(using: editor) }.disabled(!editor.canBackUp)
                Button("Backup wiederherstellen …") { EditingBackupActions.chooseRestore(using: editor, directory: dataDirectory) }
                    .disabled(editor.isLoading || editor.isRestoring || editor.isBackingUp || editor.isClosing)
            }
            CommandGroup(after: .toolbar) {
                Button(library.showsDetail ? "Rasteransicht" : "Einzelbildansicht") {
                    if library.selectedAsset != nil {
                        if library.showsDetail { WorkspaceActions.showGrid(layout, library: library) }
                        else { library.showsDetail = true }
                    }
                }
                    .disabled(library.selectedAsset == nil)
                WorkspaceViewCommands(layout: layout, library: library, shortcuts: true)
            }
        }
        Settings { AIProviderSettingsView(settings: aiSettings) }
    }
}

/// Each sheet host has a stable identity and captures the consent it displays.
/// In particular, a late nil setter never consults a newer pending consent ID.
@MainActor
struct AICloudConsentPresentation {
    let settings: AIProviderSettings
    let consent: AICloudConsent

    var binding: Binding<AICloudConsent?> {
        Binding(get: {
            settings.pendingConsent?.id == consent.id ? consent : nil
        }, set: { value in
            if value == nil { settings.respondToConsent(false, for: consent.id) }
        })
    }

    func answer(_ allowed: Bool) {
        settings.respondToConsent(allowed, for: consent.id)
    }
}

private struct AICloudConsentPresenter: View {
    @ObservedObject var settings: AIProviderSettings
    let consent: AICloudConsent

    var body: some View {
        let presentation = AICloudConsentPresentation(settings: settings, consent: consent)
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: presentation.binding) { _ in
                AICloudConsentView(consent: consent, answer: presentation.answer)
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryModel?
    weak var editor: EditingModel?
    weak var exporter: JPEGExportModel?
    weak var aiSettings: AIProviderSettings?
    weak var photoMetadata: PhotoMetadataModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library else { return .terminateNow }
        if exporter?.isExporting == true {
            let alert = NSAlert()
            alert.messageText = "Der Export läuft noch."
            alert.informativeText = "Warte bis zum Abschluss oder brich den Export im Exportdialog ab, bevor du PicEdit beendest."
            alert.addButton(withTitle: "Zurück zum Export")
            alert.runModal()
            return .terminateCancel
        }
        if editor?.isRestoring == true || editor?.isBackingUp == true {
            let alert = NSAlert()
            alert.messageText = "Die Sicherung wird noch verarbeitet."
            alert.informativeText = "Bitte beende PicEdit nach Abschluss der Sicherung oder Wiederherstellung."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
        // Commit an active numeric field while edits are still accepted.
        NSApp.keyWindow?.makeFirstResponder(nil)
        aiSettings?.revoke()
        photoMetadata?.beginTermination()
        library.beginTermination()
        editor?.beginTermination()
        Task {
            let success = await Self.finishSaving(catalog: {
                await library.drainAcceptedCatalogOperations()
                return true
            }, edits: { [editor] in
                guard let editor else { return true }
                return await editor.finishSaving()
            }, metadata: { [photoMetadata] in
                await photoMetadata?.drainAcceptedWrites() ?? true
            }, finalize: { [photoMetadata] in
                // No editor auto-maintenance remains now. Only real dirty
                // catalog retries and final metadata validation register anew.
                async let catalogSaved = library.finishSaving()
                async let metadataSaved = photoMetadata?.finishSaving() ?? true
                let saved = await (catalogSaved, metadataSaved)
                return saved.0 && saved.1
            })
            if success { sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert()
                alert.messageText = "Änderungen konnten nicht vollständig gespeichert werden."
                alert.informativeText = "Beende PicEdit später, um die Änderungen erneut zu speichern."
                alert.addButton(withTitle: "Zurück zu PicEdit")
                alert.addButton(withTitle: "Trotzdem beenden")
                let shouldQuit = alert.runModal() == .alertSecondButtonReturn
                if !shouldQuit { library.cancelTermination(); editor?.cancelTermination(); photoMetadata?.cancelTermination() }
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            }
        }
        return .terminateLater
    }

    static func finishSaving(catalog: @escaping @MainActor @Sendable () async -> Bool,
                             edits: @escaping @MainActor @Sendable () async -> Bool,
                             metadata: @escaping @MainActor @Sendable () async -> Bool = { true },
                             finalize: @escaping @MainActor @Sendable () async -> Bool = { true }) async -> Bool {
        // Accepted catalog/metadata work must progress while the editor's
        // automatic backup drains their registrations. New finalization writes
        // depend on the real end of that shared-gate maintenance and run later.
        async let catalogSaved = catalog()
        async let editsSaved = edits()
        async let metadataSaved = metadata()
        let results = await (catalogSaved, editsSaved, metadataSaved)
        let finalized = await finalize()
        return results.0 && results.1 && results.2 && finalized
    }
}
