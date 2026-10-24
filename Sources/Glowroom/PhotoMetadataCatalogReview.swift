import SwiftUI
import GlowroomCore

/// Only the selected row loads two detail records. The list never starts one
/// task per catalog photo or builds every conflict's text on MainActor.
struct PhotoMetadataCatalogReviewPresenter: View {
    @ObservedObject var model: PhotoMetadataModel
    let review: PhotoMetadataModel.CatalogReview
    @ViewState<Set<UUID>> private var assignments = []
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: Binding(get: { model.catalogReview?.id == review.id },
                set: { if !$0 { model.dismissCatalogReview(id: review.id) } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ordnerzuordnungen prüfen").font(.headline)
                    Label("Nicht zugeordnete Angaben bleiben getrennt", systemImage: "arrow.triangle.branch")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(review.change.conflicts) { conflict in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Bisher: \(conflict.oldAssetID)\nNeues Ziel: \(conflict.newAssetID)").textSelection(.enabled)
                                    Button("Angaben vergleichen") { model.compareCatalogConflict(reviewID: review.id, conflictID: conflict.id) }
                                    if let comparison = model.catalogComparison, comparison.conflictID == conflict.id {
                                        recordDetails("Bisherige Angaben", record: comparison.source)
                                        recordDetails("Zielangaben", record: comparison.destination)
                                        if vacant(comparison.destination) {
                                            Toggle("Diesem leeren Ziel ausdrücklich zuordnen", isOn: Binding(
                                                get: { assignments.contains(conflict.id) }, set: {
                                                    if $0 { assignments.insert(conflict.id) } else { assignments.remove(conflict.id) }
                                                }))
                                        } else { Text("Ziel besitzt eigene Angaben oder Entwürfe. Beide Seiten bleiben erhalten.").foregroundStyle(.orange) }
                                    }
                                }.padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }.frame(minHeight: 200, maxHeight: 400)
                    Text("\(assignments.count) Zuordnungen ausgewählt")
                    HStack {
                        Button("Abbrechen", role: .cancel) { model.dismissCatalogReview(id: review.id) }
                        Spacer()
                        Button("Entscheidungen übernehmen") { model.confirmCatalogReview(id: review.id, assignments: assignments) }
                    }
                }.font(.system(size: 13)).padding(24).frame(width: 650)
            }
    }
    private func recordDetails(_ title: String, record: PhotoMetadataRecord?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.semibold)
            if record == nil { Text("Kein gespeicherter Datensatz.").foregroundStyle(Theme.muted) }
            else if record?.confirmedRevision == 0 { Text("Noch keine bestätigten Angaben.").foregroundStyle(Theme.muted) }
            ForEach(MetadataCatalogRecordDetails.sections(for: record)) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.heading).fontWeight(.medium)
                    Text(section.status).foregroundStyle(Theme.muted)
                    Text("Titel: \(section.fields.title.isEmpty ? "—" : section.fields.title)")
                    Text("Beschreibung: \(section.fields.description.isEmpty ? "—" : section.fields.description)")
                    Text("Tags: \(section.fields.tags.isEmpty ? "—" : section.fields.tags.joined(separator: ", "))")
                    Text("Sprache: \(section.fields.language)")
                }
            }
        }.textSelection(.enabled)
    }

    private func vacant(_ record: PhotoMetadataRecord?) -> Bool {
        guard let record else { return true }
        return record.confirmedRevision == 0 && record.draft == nil && record.manualDraft == nil
    }
}

/// Prepared only for the currently selected source/destination detail records.
/// It never enumerates the catalog or retains another set of metadata records.
enum MetadataCatalogRecordDetails {
    struct Section: Identifiable, Equatable {
        enum Kind: String { case confirmed, manualDraft, aiDraft }
        let id: Kind
        let heading: String
        let status: String
        let fields: PhotoTextFields
    }
    static func sections(for record: PhotoMetadataRecord?) -> [Section] {
        guard let record else { return [] }
        var sections: [Section] = []
        if record.confirmedRevision > 0 {
            sections.append(Section(id: .confirmed, heading: "Bestätigte Angaben",
                status: "Revision \(record.confirmedRevision)", fields: record.confirmed))
        }
        if let draft = record.manualDraft {
            let conflict = draft.baseConfirmedRevision != record.confirmedRevision
            sections.append(Section(id: .manualDraft, heading: "Manueller Entwurf · noch nicht bestätigt",
                status: "Entwurfsrevision \(draft.revision) · Basisbestätigung \(draft.baseConfirmedRevision)" +
                    (conflict ? " · Bestätigung inzwischen geändert" : ""), fields: draft.fields))
        }
        if let draft = record.draft {
            let state: String
            switch draft.state {
            case .pending: state = "Wartet auf Prüfung"
            case .edited: state = "Manuell korrigiert"
            case .accepted: state = "Bereits teilweise oder vollständig übernommen"
            case .rejected: state = "Verworfen"
            case .outdated: state = "Veraltet: Quelle geändert"
            }
            sections.append(Section(id: .aiDraft, heading: "KI-Entwurf",
                status: state + " · Entwurfsrevision \(draft.revision) · Basisbestätigung \(draft.baseConfirmedRevision)", fields: draft.fields))
        }
        return sections
    }
}
