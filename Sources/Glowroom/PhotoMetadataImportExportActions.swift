import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GlowroomCore

@MainActor
enum PhotoMetadataImportExportActions {
    static func export(using model: PhotoMetadataModel) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.title = "Bildinformationen exportieren"
        panel.message = "Sichert bestätigte Titel, Beschreibungen und Tags. Bearbeitungssicherungen enthalten diese Angaben nicht."
        panel.allowedContentTypes = [.json]; panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "Glowroom-Bildinformationen.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportConfirmed(destination: url)
    }
    static func `import`(using model: PhotoMetadataModel) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSOpenPanel()
        panel.title = "Bildinformationen importieren"
        panel.message = "Ergänzt fehlende bestätigte Einträge. Bestehende Angaben werden erst nach ausdrücklicher Konfliktentscheidung geändert."
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.inspectImport(source: url)
    }
}

/// A late action or dismissal always refers to the exact review being shown.
struct PhotoMetadataImportPresenter: View {
    @ObservedObject var model: PhotoMetadataModel
    let review: MetadataImportReview
    @ViewState<[UUID: Set<PhotoMetadataField>]> private var fields: [UUID: Set<PhotoMetadataField>] = [:]
    @ViewState<[UUID: MetadataTagPolicy]> private var policies: [UUID: MetadataTagPolicy] = [:]
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: Binding(get: { model.importReview?.id == review.id },
                set: { if !$0 { model.dismissImport(id: review.id) } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bildinformationen importieren").font(.headline)
                    Text(review.sourceURL.path).textSelection(.enabled)
                    Text("\(review.entryCount) Einträge · \(review.missingCount) fehlend · \(review.unassignedCount) nicht zugeordnet")
                    Text("Fehlende Einträge werden ergänzt. Nicht zugeordnete Daten bleiben getrennt; Dateinamen allein ordnen keine Bilder zu.")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(review.conflicts) { conflict in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(conflict.assetID).fontWeight(.medium).textSelection(.enabled)
                                    Text("Vorhanden: \(conflict.existing.title)\n\(conflict.existing.description)\nTags: \(conflict.existing.tags.joined(separator: ", ")) · \(conflict.existing.language)")
                                    Text("Import: \(conflict.incoming.title)\n\(conflict.incoming.description)\nTags: \(conflict.incoming.tags.joined(separator: ", ")) · \(conflict.incoming.language)")
                                    ForEach(PhotoMetadataField.allCases, id: \.self) { field in
                                        Toggle("\(label(field)) ausdrücklich übernehmen", isOn: Binding(
                                            get: { fields[conflict.id, default: []].contains(field) }, set: {
                                                var selection = fields[conflict.id, default: []]
                                                if $0 { selection.insert(field) } else { selection.remove(field) }
                                                fields[conflict.id] = selection
                                            }))
                                    }
                                    Picker("Tags", selection: Binding(get: { policies[conflict.id, default: .append] },
                                        set: { policies[conflict.id] = $0 })) {
                                        Text("Ergänzen").tag(MetadataTagPolicy.append)
                                        Text("Ausdrücklich ersetzen").tag(MetadataTagPolicy.replace)
                                    }.pickerStyle(.menu)
                                }.padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }.frame(minHeight: 160, maxHeight: 380)
                    Text("Ohne Feldauswahl bleiben vorhandene Angaben erhalten. Der ganze Import wird atomar übernommen; bei geänderter Revision muss er erneut geprüft werden.")
                    HStack {
                        Button("Abbrechen", role: .cancel) { model.dismissImport(id: review.id) }
                        Spacer()
                        Button("Auswahl importieren") {
                            let decisions = review.conflicts.map { conflict in
                                let selection = fields[conflict.id, default: []]
                                return MetadataImportDecision(conflictID: conflict.id, expectedVersion: conflict.expectedVersion,
                                    action: selection.isEmpty ? .keepExisting : .replace(fields: selection, tags: policies[conflict.id, default: .append]))
                            }
                            model.confirmImport(id: review.id, decisions: decisions)
                        }.disabled(!model.canManage)
                    }
                }.font(.system(size: 11)).padding(24).frame(width: 650)
            }
    }
    private func label(_ field: PhotoMetadataField) -> String {
        switch field { case .title: return "Titel"; case .description: return "Beschreibung"; case .tags: return "Tags"; case .language: return "Sprache" }
    }
}
