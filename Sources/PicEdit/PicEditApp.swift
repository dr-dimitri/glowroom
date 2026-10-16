import SwiftUI
import AppKit
import PicEditCore

@main
struct PicEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library: LibraryModel
    @StateObject private var editor: EditingModel
    @StateObject private var assistant: AIAssistantModel
    @StateObject private var aiSettings: AIProviderSettings
    @StateObject private var imageAnalysis: ImageAnalysisModel
    @StateObject private var exporter = JPEGExportModel()
    private let dataDirectory: URL

    init() {
        let args = ProcessInfo.processInfo.arguments
        let directory: URL?
        if let index = args.firstIndex(of: "--catalog-directory"), args.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else { directory = nil }
        let repository = CatalogRepository(directory: directory)
        dataDirectory = repository.directory
        let library = LibraryModel(repository: repository)
        let editor = EditingModel(directory: repository.directory)
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
        _imageAnalysis = StateObject(wrappedValue: ImageAnalysisModel(service: LocalImageAnalysisFactory.makeService(),
                                                                    editor: editor, library: library))
    }

    var body: some Scene {
        Window("PicEdit", id: "library") {
            LibraryView(model: library, dataDirectory: dataDirectory)
                .environmentObject(editor)
                .environmentObject(exporter)
                .environmentObject(assistant)
                .environmentObject(imageAnalysis)
                .frame(minWidth: 1000, minHeight: 660)
                .preferredColorScheme(.dark)
                .background {
                    if let consent = aiSettings.pendingConsent {
                        AICloudConsentPresenter(settings: aiSettings, consent: consent)
                            .id(consent.id)
                    }
                }
                .onAppear { delegate.library = library; delegate.editor = editor; delegate.exporter = exporter; delegate.aiSettings = aiSettings; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ordner hinzufügen …") { library.chooseFolders() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!library.canModify || library.isImporting)
                Divider()
                Button(library.selectedIDs.count > 1 ? "Ausgewählte Fotos als JPEG exportieren …" : "Foto als JPEG exportieren …") {
                    JPEGExportActions.present(using: exporter, library: library, editor: editor)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(library.selectedIDs.isEmpty || library.isProjecting || editor.isLoading || editor.isRestoring || editor.isClosing || exporter.isPresented)
            }
            CommandMenu("Bibliothek") {
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
                    library.showsInspector = true
                }.keyboardShortcut("d", modifiers: .command).disabled(library.selectedAsset == nil || editor.isLoading)
                Button(library.comparesOriginal ? "Bearbeitung anzeigen" : "Vorher anzeigen") { library.comparesOriginal.toggle() }
                    .disabled(!library.isDeveloping || library.selectedAsset == nil)
                Divider()
                Button("Bearbeitung rückgängig") { if let id = library.selectedID { editor.undo(assetID: id) } }
                    .disabled(library.selectedID.map { !editor.canUndo(assetID: $0) } ?? true)
                Button("Bearbeitung wiederholen") { if let id = library.selectedID { editor.redo(assetID: id) } }
                    .disabled(library.selectedID.map { !editor.canRedo(assetID: $0) } ?? true)
                Button("Alle Regler zurücksetzen") { if let id = library.selectedID { editor.reset(assetID: id) } }
                    .disabled(!editor.canEdit || library.selectedID == nil)
                Divider()
                Button("Änderungen erneut speichern") { Task { _ = await editor.flush() } }
                    .disabled(!editor.hasPendingChanges || editor.isSaving || editor.isLoading || editor.isRestoring)
                Button("Bearbeitungen sichern …") { EditingBackupActions.create(using: editor) }.disabled(!editor.canBackUp)
                Button("Backup wiederherstellen …") { EditingBackupActions.chooseRestore(using: editor, directory: dataDirectory) }
                    .disabled(editor.isLoading || editor.isRestoring || editor.isBackingUp || editor.isClosing)
            }
            CommandGroup(after: .toolbar) {
                Button(library.showsDetail ? "Rasteransicht" : "Einzelbildansicht") { if library.selectedAsset != nil { library.showsDetail.toggle() } }
                    .disabled(library.selectedAsset == nil)
                Button(library.showsInspector ? "Informationen ausblenden" : "Informationen einblenden") { library.showsInspector.toggle() }
                    .keyboardShortcut("i", modifiers: .command)
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library else { return .terminateNow }
        if exporter?.isExporting == true {
            let alert = NSAlert()
            alert.messageText = "Der JPEG-Export läuft noch."
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
        library.beginTermination()
        editor?.beginTermination()
        Task {
            let success = await Self.finishSaving(catalog: {
                await library.finishSaving()
            }, edits: { [editor] in
                guard let editor, !(editor.isReadOnly && !editor.hasPendingChanges) else { return true }
                return await editor.flush()
            })
            if success { sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert()
                alert.messageText = "Änderungen konnten nicht vollständig gespeichert werden."
                alert.informativeText = "Beende PicEdit später, um die Änderungen erneut zu speichern."
                alert.addButton(withTitle: "Zurück zu PicEdit")
                alert.addButton(withTitle: "Trotzdem beenden")
                let shouldQuit = alert.runModal() == .alertSecondButtonReturn
                if !shouldQuit { library.cancelTermination(); editor?.cancelTermination() }
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            }
        }
        return .terminateLater
    }

    static func finishSaving(catalog: @escaping @MainActor @Sendable () async -> Bool,
                             edits: @escaping @MainActor @Sendable () async -> Bool) async -> Bool {
        // The catalog and edit database own different files and serialize their
        // own mutations. Drain both concurrently, but always await both results
        // before allowing termination, even when one store reports a failure.
        async let catalogSaved = catalog()
        async let editsSaved = edits()
        let results = await (catalogSaved, editsSaved)
        return results.0 && results.1
    }
}
