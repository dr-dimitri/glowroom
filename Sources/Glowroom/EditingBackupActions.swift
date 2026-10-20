import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum EditingBackupActions {
    static func create(using editor: EditingModel) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.title = "Bearbeitungen sichern"
        panel.message = "Sichert Regler, aktive Bildquellen, Varianten und generierte Pixel als Bearbeitungspaket. Originale, Katalog, redaktionelle Bildinformationen und Clouddaten sind nicht enthalten."
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Glowroom-Bearbeitungen-\(formatter.string(from: Date()))"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "glowroombackup", conformingTo: .data) ?? .data]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let target = panel.url else { return }
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
        panel.message = "Wähle ein Bearbeitungspaket (.glowroombackup) oder ein älteres Reglerbackup (.sqlite). Originale, Katalog und Bildinformationen werden separat gesichert."
        panel.prompt = "Backup auswählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory.appendingPathComponent("EditBackups", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Bearbeitungen aus diesem Backup wiederherstellen?"
        alert.informativeText = "„\(url.lastPathComponent)“ ersetzt die gespeicherten Bildquellen und Reglerwerte. Der aktuelle Stand wird vorher separat gesichert. Originalbilder, Bewertungen und Fotoordner bleiben unverändert."
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
