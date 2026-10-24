import SwiftUI
import GlowroomCore

struct PhotoMetadataSection: View {
    @ObservedObject var model: PhotoMetadataModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bildinformationen").font(.system(size: 15, weight: .semibold))
            suggestionActions
            if model.isLoading { ProgressView("Bildinformationen werden geladen …") }
            recoveryAndErrors
            if let notice = model.notice { Text(notice).foregroundStyle(Theme.muted) }
            if let record = model.record, record.confirmedRevision > 0 {
                DisclosureGroup("Bestätigte Angaben · Revision \(record.confirmedRevision)") {
                    confirmed(record.confirmed)
                }
                if record.sourceChanged {
                    Label("Bildquelle geändert. Bestätigte Angaben prüfen.", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Noch keine bestätigten Angaben").foregroundStyle(Theme.muted)
            }
            Divider()
            if model.record?.draft != nil || model.hasDetachedRecoveredProposal {
                Picker("Bearbeiten", selection: $model.editor) {
                    Text("Manuelle Angaben").tag(PhotoMetadataEditor.manual)
                    Text("KI-Vorschlag").tag(PhotoMetadataEditor.proposal)
                }.pickerStyle(.menu).accessibilityIdentifier("metadata.editor")
            }
            if model.editor == .proposal, model.hasDetachedRecoveredProposal {
                detachedProposalEditor
            } else if model.editor == .proposal, let draft = model.record?.draft {
                proposalEditor(draft)
            } else {
                manualEditor
            }
            if model.isSaving { ProgressView("Bildinformationen werden gesichert …") }
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("metadata.form")
            .task {
                model.synchronizeContext()
                await model.refreshAvailability()
            }
    }

    @ViewBuilder private var suggestionActions: some View {
        if model.isAnalyzing {
            HStack { ProgressView().controlSize(.small); Text("Bildtexte werden vorgeschlagen …") }
            Button("Vorschlag abbrechen") { model.invalidateAnalysis() }
        } else {
            Button(model.record?.draft == nil ? "Mit KI vorschlagen" : "Neu vorschlagen") {
                model.suggest(refresh: model.record?.draft != nil)
            }.disabled(!model.canSuggest).accessibilityIdentifier("metadata.suggest")
        }
        if model.isCheckingAvailability {
            ProgressView("KI-Verfügbarkeit wird geprüft …")
        } else if case .unavailable(let reason) = model.availability {
            Label(unavailability(reason), systemImage: "sparkles")
                .foregroundStyle(Theme.muted).accessibilityIdentifier("metadata.unavailable")
            if canRecheck(reason) {
                Button("Verfügbarkeit erneut prüfen") { Task { await model.refreshAvailability() } }
                    .disabled(model.isAnalyzing)
            }
        }
    }

    @ViewBuilder private var recoveryAndErrors: some View {
        if let recovery = model.recovery {
            Label("Ungesicherter Entwurf: \(URL(fileURLWithPath: recovery.context.source.standardizedPath).lastPathComponent)", systemImage: "exclamationmark.triangle")
            Text(recovery.message).textSelection(.enabled)
            HStack {
                Button("Entwurf bearbeiten") { model.recoverUnsavedDraft() }
                Button("Verwerfen", role: .destructive) { model.discardRecovery() }
            }
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .accessibilityIdentifier("metadata.error")
            if !model.hasPendingRetry {
                Button("Erneut laden") { model.retryLoading() }
            }
        }
        if model.hasPendingRetry {
            Button("Angenommenen Auftrag erneut speichern") { model.retryAcceptedWrite() }
                .disabled(!model.canRetryAcceptedWrite)
            Button("Fehlgeschlagenen Auftrag verwerfen", role: .destructive) { model.discardAcceptedWrite() }
                .disabled(model.isSaving)
        }
    }

    private var manualEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.hasManualDraft ? "Manueller Entwurf · nicht bestätigt" : "Manuelle Angaben")
                .fontWeight(.medium)
            MetadataTextFieldsEditor(fields: Binding(get: { model.manualFields }, set: { model.editManualFields($0) }),
                selection: $model.manualSelection,
                tagText: Binding(get: { model.manualTagEditor.text }, set: { model.editManualTags($0) }))
                .id(MetadataFieldsIdentity(assetID: model.context?.assetID, source: model.context?.source, draftID: nil))
                .disabled(!model.canEditManual)
            tagPolicy($model.manualTagPolicy).disabled(!model.canEditManual)
            if model.manualHasConflict {
                Label("Entwurf basiert auf älteren bestätigten Angaben.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Toggle("Aktuelle bestätigte Angaben geprüft", isOn: $model.manualConflictReviewed)
                    .accessibilityIdentifier("metadata.conflict-reviewed")
            }
            HStack {
                Button("Übernehmen") { model.acceptManualFields() }.disabled(!model.canConfirmManual)
                    .accessibilityIdentifier("metadata.accept")
                Button("Verwerfen", role: .destructive) { model.discardManualDraft() }
                    .disabled(!model.canDiscardManualDraft)
            }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("metadata.manual")
    }

    private var detachedProposalEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ungesicherter Vorschlag · nicht mehr aktuell", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).fontWeight(.medium)
            MetadataTextFieldsEditor(fields: .constant(model.proposalFields),
                selection: .constant(model.proposalSelection),
                tagText: .constant(model.proposalTagEditor.text))
                .disabled(true)
            Button("Als manuelle Angaben bearbeiten") { model.useProposalAsManual() }
                .disabled(!model.canUseProposalAsManual)
            Button("Verwerfen", role: .destructive) { model.discardRecoveredProposal() }
                .disabled(!model.canDiscardRecoveredProposal)
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("metadata.recovered-proposal")
    }

    private func proposalEditor(_ draft: PhotoMetadataDraft) -> some View {
        let draftState = model.proposalState ?? draft.state
        return VStack(alignment: .leading, spacing: 12) {
            Text(draftState == .accepted || draftState == .rejected ? "KI-Vorschlag" : "KI-Vorschlag · nicht bestätigt")
                .fontWeight(.medium)
            Text(state(draftState)).foregroundStyle(draftState == .outdated ? .orange : Theme.muted)
            MetadataTextFieldsEditor(fields: Binding(get: { model.proposalFields }, set: { model.editProposalFields($0) }),
                selection: $model.proposalSelection,
                tagText: Binding(get: { model.proposalTagEditor.text }, set: { model.editProposalTags($0) }))
                .id(MetadataFieldsIdentity(assetID: model.context?.assetID, source: model.context?.source, draftID: draft.id))
                .disabled(!model.canEditProposal)
            tagPolicy($model.proposalTagPolicy).disabled(!model.canEditProposal)
            HStack {
                Button("Übernehmen") { model.acceptProposal() }.disabled(!model.canConfirmProposal)
                    .accessibilityIdentifier("metadata.accept")
                Button("Verwerfen", role: .destructive) { model.discardProposal() }.disabled(!model.canRejectProposal)
            }
            if draftState == .accepted || draftState == .rejected || draftState == .outdated {
                Button("Als manuelle Angaben bearbeiten") { model.useProposalAsManual() }
                    .disabled(!model.canUseProposalAsManual)
            }
            if let analysis = draft.source.analyzedRaster {
                DisclosureGroup("Analysedetails") {
                    Text("\(analysis.providerID) · \(analysis.modelID) · \(analysis.analyzedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(Theme.muted).textSelection(.enabled)
                    Text("Eingaberaster: \(analysis.raster.pixelWidth) × \(analysis.raster.pixelHeight) · SHA256 \(analysis.raster.sha256)")
                        .foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("metadata.proposal")
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
        case .pending: return "Zur Prüfung bereit"
        case .edited: return "Manuell korrigiert"
        case .accepted: return "Bereits übernommen"
        case .rejected: return "Verworfen"
        case .outdated: return "Veraltet: Quelle oder bestätigte Angaben geändert"
        }
    }

    private func unavailability(_ reason: ImageAnalysisUnavailableReason) -> String {
        switch reason {
        case .unsupportedSystem: return "KI-Vorschläge benötigen macOS 27."
        case .sdkUnavailable: return "Dieser Build unterstützt keine KI-Bildvorschläge."
        case .unsupportedHardware: return "Dieser Mac unterstützt keine lokalen KI-Bildvorschläge."
        case .disabled: return "Apple Intelligence ist deaktiviert."
        case .modelUnavailable: return "Das lokale Bildmodell ist noch nicht bereit."
        case .unsupportedLanguage: return "Das lokale Bildmodell unterstützt Deutsch nicht."
        case .unsupportedCapability: return "Das lokale Systemmodell unterstützt keine Bildanalyse."
        case .temporaryFailure: return "Der lokale Bildanalysedienst ist vorübergehend nicht erreichbar."
        case .unknown: return "KI-Vorschläge sind derzeit nicht verfügbar."
        }
    }

    private func canRecheck(_ reason: ImageAnalysisUnavailableReason) -> Bool {
        switch reason {
        case .disabled, .modelUnavailable, .temporaryFailure, .unknown: return true
        case .unsupportedSystem, .sdkUnavailable, .unsupportedHardware, .unsupportedLanguage, .unsupportedCapability: return false
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
            TextEditor(text: field(\.description)).font(.system(size: 13)).frame(minHeight: 70, maxHeight: 110)
                .scrollContentBackground(.hidden).background(Theme.panel)
                .accessibilityLabel("Beschreibung")
            selected(.tags, label: "Tags · \(fields.tags.count)/20")
            MetadataTagEntriesEditor(text: $tagText)
            selected(.language, label: "Sprache")
            TextField("Sprache", text: field(\.language)).textFieldStyle(.roundedBorder)
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

/// Keep raw rows in the model's existing form state: unmounting a dock group
/// must retain a just-added empty entry and partially typed tag text.
private struct MetadataTagEntriesEditor: View {
    @Binding var text: String
    @ViewState private var rowGeneration = UUID()
    private var entries: [String] { text.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("Tag hinzufügen", text: entry(index))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Tag \(index + 1)")
                    Button {
                        var values = entries
                        guard values.indices.contains(index) else { return }
                        values.remove(at: index)
                        replaceEntries(values)
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Tag \(index + 1) entfernen")
                        .disabled(entries.count == 1 && text.isEmpty)
                }
            }.id(rowGeneration)
            Button("Tag hinzufügen", systemImage: "plus") { replaceEntries(entries + [""]) }
                .disabled(entries.count >= 20 || entries.last?.isEmpty != false)
        }
    }

    private func replaceEntries(_ values: [String]) {
        // AppKit can finish editing after a remove action. Recreate row views
        // and reject their old bindings before an index can name another tag.
        rowGeneration = UUID()
        text = values.joined(separator: "\n")
    }

    private func entry(_ index: Int) -> Binding<String> {
        let generation = rowGeneration
        return Binding(get: { entries.indices.contains(index) ? entries[index] : "" }, set: { value in
            var values = entries
            guard rowGeneration == generation, values.indices.contains(index) else { return }
            values[index] = value
            if value.contains("\n") { replaceEntries(values) }
            else { text = values.joined(separator: "\n") }
        })
    }
}
