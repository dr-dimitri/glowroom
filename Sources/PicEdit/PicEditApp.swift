import SwiftUI
import AppKit
import PicEditCore

@main
struct PicEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library: LibraryModel
    @StateObject private var editor: EditingModel
    private let dataDirectory: URL

    init() {
        let args = ProcessInfo.processInfo.arguments
        let directory: URL?
        if let index = args.firstIndex(of: "--catalog-directory"), args.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else { directory = nil }
        let repository = CatalogRepository(directory: directory)
        dataDirectory = repository.directory
        _library = StateObject(wrappedValue: LibraryModel(repository: repository))
        _editor = StateObject(wrappedValue: EditingModel(directory: repository.directory))
    }

    var body: some Scene {
        Window("PicEdit", id: "library") {
            LibraryView(model: library, dataDirectory: dataDirectory)
                .environmentObject(editor)
                .frame(minWidth: 1000, minHeight: 660)
                .preferredColorScheme(.dark)
                .onAppear { delegate.library = library; delegate.editor = editor; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ordner hinzufügen …") { library.chooseFolders() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!library.canModify || library.isImporting)
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
                Button("Bearbeitungen sichern …") { EditingBackupActions.create(using: editor, directory: dataDirectory) }.disabled(!editor.canBackUp)
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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryModel?
    weak var editor: EditingModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library else { return .terminateNow }
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
        library.beginTermination()
        editor?.beginTermination()
        Task {
            let librarySaved = await library.finishSaving()
            let editsSaved: Bool
            if let editor, !(editor.isReadOnly && !editor.hasPendingChanges) { editsSaved = await editor.flush() }
            else { editsSaved = true }
            let success = librarySaved && editsSaved
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
}
