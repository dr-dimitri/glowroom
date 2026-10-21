import SwiftUI
import GlowroomCore

struct PhotoMetadataSection: View {
    @ObservedObject var model: PhotoMetadataModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Bildinformationen")
            Text("Titel, Beschreibung und Tags werden lokal getrennt vom Original gespeichert.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            if model.isLoading { ProgressView("Bildinformationen werden geladen …").font(.caption) }
            if let recovery = model.recovery {
                Label("Ungesicherter Entwurf für \(URL(fileURLWithPath: recovery.context.source.standardizedPath).lastPathComponent)", systemImage: "exclamationmark.triangle")
                Text(recovery.message).textSelection(.enabled)
                HStack {
                    Button("Entwurf bearbeiten") { model.recoverUnsavedDraft() }
                    Button("Verwerfen", role: .destructive) { model.discardRecovery() }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Erneut laden") { model.retryLoading() }
            }
            if model.hasPendingRetry {
                Button("Angenommenen Auftrag erneut speichern") { model.retryAcceptedWrite() }
                    .disabled(!model.canRetryAcceptedWrite)
                Button("Fehlgeschlagenen Auftrag verwerfen", role: .destructive) { model.discardAcceptedWrite() }
                    .disabled(model.isSaving)
            }
            if let notice = model.notice { Text(notice).foregroundStyle(Theme.muted) }
            if let record = model.record, record.confirmedRevision > 0 {
                Text("Bestätigt · Revision \(record.confirmedRevision)").fontWeight(.medium)
                confirmed(record.confirmed)
                if record.sourceChanged {
                    Label("Die Quelle hat sich seit der Bestätigung geändert. Die Texte bleiben erhalten.", systemImage: "arrow.triangle.2.circlepath")
                }
            } else { Text("Noch keine bestätigten Bildinformationen.").foregroundStyle(Theme.muted) }
            Divider()
            Text("Manuelle Angaben").fontWeight(.medium)
            MetadataTextFieldsEditor(fields: Binding(get: { model.manualFields }, set: { model.editManualFields($0) }),
                selection: $model.manualSelection,
                tagText: Binding(get: { model.manualTagEditor.text }, set: { model.editManualTags($0) }))
                .id(MetadataFieldsIdentity(assetID: model.context?.assetID, source: model.context?.source, draftID: nil))
                .disabled(!model.canEditManual)
            tagPolicy($model.manualTagPolicy)
            if model.manualHasConflict {
                Toggle("Aktuelle bestätigte Revision geprüft", isOn: $model.manualConflictReviewed)
                Text("Dieser manuelle Entwurf basiert auf einer älteren Bestätigung. Vergleiche die Angaben vor der Übernahme.")
                    .foregroundStyle(.orange)
            }
            Button("Manuelle Angaben übernehmen") { model.acceptManualFields() }.disabled(!model.canConfirmManual)
            if model.hasManualDraft {
                Button("Manuellen Entwurf verwerfen") { model.discardManualDraft() }.disabled(!model.canDiscardManualDraft)
            }
            Divider()
            Text("KI-Entwurf · noch nicht bestätigt").fontWeight(.medium)
            Text("Lokale Bildanalyse des Originals. Reglerwerte und Cloud-Textanbieter ändern diese Eingabe nicht.")
                .foregroundStyle(Theme.muted)
            if case .unavailable(let reason) = model.availability {
                Text(reason.localizedDescription).foregroundStyle(Theme.muted)
            }
            Button("Bildfähigkeit erneut prüfen") { Task { await model.refreshAvailability() } }
                .disabled(model.isCheckingAvailability || model.isAnalyzing)
            if model.isAnalyzing {
                HStack { ProgressView().controlSize(.small); Text("Bildtexte werden vorgeschlagen …") }
                Button("Vorschlag abbrechen") { model.invalidateAnalysis() }
            }
            HStack {
                Button("Vorschlagen") { model.suggest() }.disabled(!model.canSuggest)
                Button("Neu erstellen") { model.suggest(refresh: true) }.disabled(!model.canSuggest)
            }
            if let draft = model.record?.draft {
                Text(state(draft.state)).foregroundStyle(draft.state == .outdated ? .orange : Theme.muted)
                MetadataTextFieldsEditor(fields: Binding(get: { model.proposalFields }, set: { model.editProposalFields($0) }),
                    selection: $model.proposalSelection,
                    tagText: Binding(get: { model.proposalTagEditor.text }, set: { model.editProposalTags($0) }))
                    .id(MetadataFieldsIdentity(assetID: model.context?.assetID, source: model.context?.source, draftID: draft.id))
                    .disabled(!model.canEditProposal)
                tagPolicy($model.proposalTagPolicy)
                HStack {
                    Button("Übernehmen") { model.acceptProposal() }.disabled(!model.canConfirmProposal)
                    Button("Verwerfen") { model.discardProposal() }.disabled(!model.canRejectProposal)
                }
                if draft.state == .accepted || draft.state == .rejected || draft.state == .outdated {
                    Button("Als manuelle Angaben bearbeiten") { model.useProposalAsManual() }.disabled(!model.canUseProposalAsManual)
                }
                if let analysis = draft.source.analyzedRaster {
                    Text("\(analysis.providerID) · \(analysis.modelID) · \(analysis.analyzedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(Theme.muted).textSelection(.enabled)
                    Text("Eingaberaster: \(analysis.raster.pixelWidth) × \(analysis.raster.pixelHeight) · SHA256 \(analysis.raster.sha256)")
                        .font(.system(size: 9)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
            if model.isSaving { ProgressView("Bildinformationen werden gesichert …") }
            Text("Nur bestätigte Felder sind suchbar. Bearbeitungssicherungen enthalten diese Angaben nicht.")
                .foregroundStyle(Theme.muted)
        }.font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            .task { model.synchronizeContext(); await model.refreshAvailability() }
    }

    private func tagPolicy(_ policy: Binding<MetadataTagPolicy>) -> some View {
        Picker("Tags beim Übernehmen", selection: policy) {
            Text("Ergänzen").tag(MetadataTagPolicy.append)
            Text("Ausdrücklich ersetzen").tag(MetadataTagPolicy.replace)
        }.pickerStyle(.menu)
    }
    private func confirmed(_ fields: PhotoTextFields) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fields.title.isEmpty ? "Ohne Titel" : fields.title).fontWeight(.medium)
            if !fields.description.isEmpty { Text(fields.description) }
            Text(fields.tags.isEmpty ? "Keine Tags" : fields.tags.joined(separator: " · "))
            Text("Sprache: \(fields.language)").foregroundStyle(Theme.muted)
        }.textSelection(.enabled)
    }
    private func state(_ value: MetadataDraftState) -> String {
        switch value {
        case .pending: return "Vorschlag wartet auf Prüfung"
        case .edited: return "Vorschlag manuell korrigiert"
        case .accepted: return "Vorschlag bereits teilweise oder vollständig übernommen"
        case .rejected: return "Vorschlag verworfen"
        case .outdated: return "Vorschlag veraltet: Quelle geändert"
        }
    }
}

private struct MetadataFieldsIdentity: Hashable {
    let assetID: String?
    let source: AIOriginalSourceFingerprint?
    let draftID: UUID?
}

private struct MetadataTextFieldsEditor: View {
    @Binding var fields: PhotoTextFields
    @Binding var selection: Set<PhotoMetadataField>
    @Binding var tagText: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            selected(.title, label: "Titel · \(fields.title.count)/120")
            TextField("Titel", text: field(\.title)).textFieldStyle(.roundedBorder)
            selected(.description, label: "Beschreibung · \(fields.description.count)/2000")
            TextEditor(text: field(\.description)).font(.system(size: 10)).frame(minHeight: 70, maxHeight: 110)
                .scrollContentBackground(.hidden).background(Theme.panel)
                .accessibilityLabel("Beschreibung")
            selected(.tags, label: "Tags · \(fields.tags.count)/20 · ein Tag pro Zeile")
            TextEditor(text: $tagText).font(.system(size: 10)).frame(height: 54).scrollContentBackground(.hidden)
                .background(Theme.panel).accessibilityLabel("Tags, ein Tag pro Zeile")
            Text("Je Tag höchstens 60 Zeichen. Leere Ersatzliste löscht Tags nur bei ausdrücklich gewähltem Ersetzen.")
                .foregroundStyle(Theme.muted)
            selected(.language, label: "Sprache ausdrücklich übernehmen")
            TextField("Sprache, z. B. de_DE", text: field(\.language)).textFieldStyle(.roundedBorder)
        }
    }
    private func field(_ path: WritableKeyPath<PhotoTextFields, String>) -> Binding<String> {
        Binding(get: { fields[keyPath: path] }, set: { fields[keyPath: path] = $0 })
    }
    private func selected(_ field: PhotoMetadataField, label: String) -> some View {
        Toggle(label, isOn: Binding(get: { selection.contains(field) }, set: {
            if $0 { selection.insert(field) } else { selection.remove(field) }
        })).toggleStyle(.checkbox)
    }
}
