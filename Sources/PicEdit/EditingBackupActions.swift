import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum EditingBackupActions {
    static func create(using editor: EditingModel, directory: URL) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.title = "Bearbeitungen sichern"
        panel.message = "Speichert die Reglerwerte aller Fotos. Wähle bei Bedarf ein externes Laufwerk. Originalbilder und Bibliothekskatalog sind nicht enthalten."
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "PicEdit-Bearbeitungen-\(formatter.string(from: Date()))"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite", conformingTo: .data) ?? .data]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let protected = ["edits.sqlite", "edits.sqlite-wal", "edits.sqlite-shm", "edits.sqlite-journal", "catalog.json"]
            .map { directory.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL }
        guard target.pathExtension.lowercased() == "sqlite",
              !protected.contains(target.resolvingSymlinksInPath().standardizedFileURL) else {
            editor.errorMessage = "Wähle eine separate Datei mit der Endung .sqlite als Backup-Ziel. Die aktive Datenbank darf nicht überschrieben werden."
            return
        }
        let accessed = target.startAccessingSecurityScopedResource()
        Task {
            defer { if accessed { target.stopAccessingSecurityScopedResource() } }
            if let exported = await editor.createBackup(exportTo: target) {
                NSWorkspace.shared.activateFileViewerSelecting([exported])
            }
        }
    }

    static func chooseRestore(using editor: EditingModel, directory: URL) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSOpenPanel()
        panel.title = "Bearbeitungen wiederherstellen"
        panel.message = "Wähle ein PicEdit-Backup (.sqlite). Es enthält die Reglerwerte aller gesicherten Fotos."
        panel.prompt = "Backup auswählen"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory.appendingPathComponent("EditBackups", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Bearbeitungen aus diesem Backup wiederherstellen?"
        alert.informativeText = "„\(url.lastPathComponent)“ ersetzt die gespeicherten Reglerwerte. Der aktuelle Stand wird vorher separat gesichert. Originalbilder, Bewertungen und Fotoordner bleiben unverändert."
        alert.addButton(withTitle: "Wiederherstellen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            _ = await editor.restoreBackup(from: url)
        }
    }
}
