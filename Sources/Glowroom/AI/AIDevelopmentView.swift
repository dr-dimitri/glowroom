import SwiftUI
import GlowroomCore

/// Orders and explicit presets only affect the next requested proposal.
struct AIDevelopmentView: View {
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var workspace: DevelopWorkspace
    @StateObject private var model: AIDevelopmentModel
    @StateObject private var readiness: AICorrectionReadiness
    @ViewState private var showsIntent = false
    @ViewState private var showsChanges = false

    @MainActor
    init(library: LibraryModel, model: AIDevelopmentModel? = nil,
         checkModel: AICorrectionReadiness.CheckModel? = nil) {
        self.library = library
        _model = StateObject(wrappedValue: model ?? AIDevelopmentModel())
        // Injected services can run without installed weights in native tests.
        let check: AICorrectionReadiness.CheckModel = checkModel ?? (model == nil
            ? { try await AICorrectionReadiness.installedModel() } : { true })
        _readiness = StateObject(wrappedValue: AICorrectionReadiness(checkModel: check))
    }

    private var canEditPhoto: Bool {
        editor.canEdit && library.canModify && !library.isImporting && !library.isProjecting
            && !library.comparesOriginal && !library.comparesCurrentSourceWithoutSettings
            && workspace.isFinalPreviewReady && workspace.originalBitmap != nil
            && workspace.sourceIdentity == editor.aiSnapshot(in: library)?.source
    }

    private var canRequest: Bool { canEditPhoto && readiness.state == .ready }

    private var layers: [LocalAdjustment] {
        library.selectedID.map { editor.settings(for: $0).localAdjustments } ?? []
    }

    private var validRequest: Bool {
        guard let id = model.intent.targetMaskID else { return true }
        return layers.contains { $0.id == id && $0.isEnabled && $0.mask.opacity > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            order.disabled(model.isRunning)
            prerequisites

            if model.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.status ?? "Vorschlag wird erstellt …")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Abbrechen") { model.cancel() }
                        .accessibilityIdentifier("ai-development.cancel")
                }
            } else {
                Button {
                    WorkspaceActions.finishField()
                    model.start(library: library, editor: editor, workspace: workspace)
                } label: {
                    Label("Vorschlag erstellen", systemImage: "sparkles").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                    .disabled(!canRequest || !validRequest)
                    .accessibilityIdentifier("ai-development.generate")
                if let status = model.status {
                    Text(status).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("ai-development.status")
                    if status == AIDevelopmentError.staleContext.localizedDescription {
                        Button("Foto neu laden") {
                            model.discard()
                            workspace.previewReloadID = UUID()
                        }.accessibilityIdentifier("ai-development.reload-photo")
                    } else if status == ImageAnalysisError.staleSource.localizedDescription {
                        Button("Ordner aktualisieren") { library.refreshCurrentFolder() }
                            .accessibilityIdentifier("ai-development.refresh-folder")
                    }
                }
            }

            if let proposal = model.proposal {
                review(proposal)
            }
        }
        .font(.system(size: 13))
        .onChange(of: library.aiModelsDestination) { _, destination in
            if destination == nil { Task { await readiness.refresh() } }
        }
        .task { await readiness.refresh() }
        .onChange(of: editor.aiSnapshot(in: library)) { _, _ in
            model.invalidateIfNeeded(library: library, editor: editor)
        }
        .onDisappear { model.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-development.panel")
    }

    private var order: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Zielbereich", selection: $model.intent.targetMaskID) {
                Text("Gesamtes Bild").tag(Optional<UUID>.none)
                ForEach(layers) { layer in
                    Text(layer.name + (layer.isEnabled && layer.mask.opacity > 0 ? "" : " (ausgeblendet)"))
                        .tag(Optional(layer.id))
                }
                if let id = model.intent.targetMaskID, !layers.contains(where: { $0.id == id }) {
                    Text("Maske nicht mehr verfügbar").tag(Optional(id))
                }
            }.accessibilityIdentifier("ai-development.scope")
            Text("Auftrag").fontWeight(.medium)
            TextField("Zum Beispiel: natürliches Licht, wärmere Farben", text: $model.intent.instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...3)
                .accessibilityIdentifier("ai-development.instruction")
            Menu("Auftragsvorgabe wählen") {
                ForEach(["Natürliches Licht und ausgewogene Farben", "Schatten behutsam aufhellen", "Wärmere Farben", "Zurückhaltende Farben"], id: \.self) { instruction in
                    Button(instruction) { model.intent.instruction = instruction }
                }
            }.accessibilityIdentifier("ai-development.presets")
            DisclosureGroup("Erweiterte Auftragsvorgaben", isExpanded: $showsIntent) {
                Picker("Stärke des nächsten Vorschlags", selection: $model.intent.strength) {
                    Text("Dezent").tag(0.25)
                    Text("Mittel").tag(0.5)
                    Text("Kräftig").tag(1.0)
                    if ![0.25, 0.5, 1].contains(model.intent.strength) {
                        Text("\(Int((model.intent.strength * 100).rounded())) %").tag(model.intent.strength)
                    }
                }.accessibilityIdentifier("ai-development.strength")
            }
        }
    }

    @ViewBuilder private var prerequisites: some View {
        if library.selectedAsset == nil {
            Text("Kein Foto ausgewählt.")
            Button("Foto auswählen") { library.workspaceMode = .library }
                .accessibilityIdentifier("ai-development.select-photo")
        } else if !validRequest {
            Text(AIDevelopmentError.unavailableMask.localizedDescription)
            Button("Gesamtes Bild verwenden") { model.intent.targetMaskID = nil }
                .accessibilityIdentifier("ai-development.reset-scope")
        } else if library.comparesOriginal || library.comparesCurrentSourceWithoutSettings {
            Text("Importiertes Original oder Quelle ohne Regler wird angezeigt.")
            Button("Aktuellen Stand anzeigen") { library.showPreviewComparison(.single) }
        } else if !workspace.isFinalPreviewReady {
            Text("Fotovorschau nicht verfügbar.")
            Button("Foto in Bibliothek auswählen") { library.workspaceMode = .library }
            Button("Ordner aktualisieren") { library.refreshCurrentFolder() }
                .accessibilityIdentifier("ai-development.refresh-folder")
        }
        switch readiness.state {
        case .checking:
            ProgressView("Modell wird geprüft …").controlSize(.small)
        case .missing:
            Text("KI-Modell fehlt.").accessibilityIdentifier("ai-development.model-required")
            Button("KI-Modell einrichten …") { library.aiModelsDestination = .corrections }
                .accessibilityIdentifier("ai-development.setup-model")
        case .failed(let message):
            Text(message).textSelection(.enabled)
                .accessibilityIdentifier("ai-development.model-error")
            Button("Modell prüfen und einrichten …") { library.aiModelsDestination = .corrections }
                .accessibilityIdentifier("ai-development.setup-model")
        case .ready: EmptyView()
        }
    }

    private func review(_ proposal: AIDevelopmentReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Korrekturvorschlag").fontWeight(.medium)
            Text(proposal.targetName.map { "Zielbereich: \($0)" } ?? "Zielbereich: Gesamtes Bild")
            if workspace.aiCorrectionPreview != nil {
                HStack(spacing: 6) {
                    comparisonButton("Aktueller Stand", proposal: false, identifier: "current")
                    comparisonButton("Vorschlag", proposal: true, identifier: "proposal")
                }
            }
            HStack {
                Button("Verwerfen") { model.discard() }
                    .accessibilityIdentifier("ai-development.discard")
                Spacer(minLength: 0)
                Button("Übernehmen") { model.apply(library: library, editor: editor) }
                    .buttonStyle(.borderedProminent).disabled(!canEditPhoto || model.isRunning || !model.canApplyProposal)
                    .accessibilityIdentifier("ai-development.apply")
            }.disabled(model.isRunning)
            Text(proposal.summary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !proposal.changes.isEmpty {
                DisclosureGroup("Geänderte Werte", isExpanded: $showsChanges) {
                    ForEach(Array(proposal.changes.enumerated()), id: \.offset) { _, change in
                        Text(change).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }

    private func comparisonButton(_ title: String, proposal: Bool, identifier: String) -> some View {
        Button {
            library.showPreviewComparison(.single)
            workspace.picksWhiteBalance = false
            workspace.picksDetail = false
            workspace.endLevelsPicker()
            workspace.showsAICorrectionProposal = proposal
        } label: {
            Label(title, systemImage: workspace.correctionDisplay(library: library, editor: editor)?.showsProposal == proposal
                  ? "checkmark.circle.fill" : "circle")
                .frame(maxWidth: .infinity)
        }
            .tint(workspace.correctionDisplay(library: library, editor: editor)?.showsProposal == proposal ? Theme.accent : nil)
            .accessibilityValue(workspace.correctionDisplay(library: library, editor: editor)?.showsProposal == proposal ? "Aktiv" : "Inaktiv")
            .accessibilityAddTraits(workspace.correctionDisplay(library: library, editor: editor)?.showsProposal == proposal ? .isSelected : [])
            .accessibilityIdentifier("ai-development.\(identifier)")
    }
}
