import SwiftUI
import GlowroomCore

/// All creation starts here; object proposals share the source-bound canvas
/// and become ordinary editable masks only after explicit acceptance.
@MainActor
struct InlineMaskCreator: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    @Environment(\.openAIModels) private var openAIModels

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Neue Maske").fontWeight(.medium)
            HStack(alignment: .top, spacing: 8) {
                tile(.subject, title: "Motiv")
                tile(.sky, title: "Himmel")
                tile(.background, title: "Hintergrund")
            }.padding(.vertical, 3)
            Divider().overlay(Theme.line)
            VStack(spacing: 2) {
                Button { workspace.finishGesture(); workspace.showsObjectCreator = true } label: {
                    rowLabel("Objekt beschreiben", symbol: "viewfinder")
                }.buttonStyle(.plain).disabled(!workspace.canCreateMask)
                    .accessibilityIdentifier("local-mask.create.object")
                toolRow(.brush, title: "Pinsel")
                toolRow(.linear, title: "Linearer Verlauf")
                toolRow(.radial, title: "Radialverlauf")
            }
            Divider().overlay(Theme.line)
            Button("Himmel einrichten …") { openAIModels(.sky) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                .accessibilityIdentifier("local-mask.sky-setup")
            Button("Motiv und Hintergrund einrichten …") { openAIModels(.subject) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                .accessibilityIdentifier("local-mask.subject-setup")
            if (workspace.model?.settings.localAdjustments.count ?? 0) >= LocalAdjustment.maximumCount {
                Text("Maximal 16 Masken pro Bild.").foregroundStyle(Theme.muted)
            }
        }.font(.system(size: 13)).foregroundStyle(Theme.text)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("local-mask.creator")
    }

    private func tile(_ kind: LocalMaskCreation, title: String) -> some View {
        Button { create(kind) } label: {
            VStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.system(size: 21, weight: .light))
                    .frame(width: 48, height: 48)
                    .overlay { Rectangle().strokeBorder(Theme.muted, lineWidth: 1.5) }
                Text(title).lineLimit(1)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!workspace.canCreateMask)
            .help(kind.title).accessibilityLabel(kind.title)
            .accessibilityIdentifier("local-mask.create.\(kind.rawValue)")
    }

    private func toolRow(_ kind: LocalMaskCreation, title: String) -> some View {
        Button { create(kind) } label: { rowLabel(title, symbol: kind.symbol) }
            .buttonStyle(.plain).disabled(!workspace.canCreateMask)
            .accessibilityLabel(title)
            .accessibilityIdentifier("local-mask.create.\(kind.rawValue)")
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 17, weight: .light)).frame(width: 22)
            Text(title)
            Spacer(minLength: 0)
        }.frame(minHeight: 28).contentShape(Rectangle())
    }

    private func create(_ kind: LocalMaskCreation) {
        workspace.finishGesture()
        workspace.discardObjectMask()
        workspace.model?.add(kind)
    }
}

@MainActor
struct InlineObjectMaskCreator: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    @ObservedObject private var model: InlineObjectMaskModel
    @Environment(\.openAIModels) private var openAIModels

    init(workspace: InlineMaskWorkspace) {
        self.workspace = workspace
        _model = ObservedObject(wrappedValue: workspace.objectMask)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Objekt beschreiben").fontWeight(.semibold)
                Spacer(minLength: 0)
                Button("Zurück") {
                    workspace.discardObjectMask()
                    workspace.showsObjectCreator = false
                }.accessibilityIdentifier("local-mask.object.back")
            }
            TextField("Zum Beispiel: der Blumenstrauß", text: $model.instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...3)
                .disabled(model.isRunning)
                .accessibilityLabel("Objektbeschreibung")
                .accessibilityIdentifier("local-mask.object.instruction")
            if model.isCheckingModels {
                ProgressView("Modelle werden geprüft …").controlSize(.small)
            }
            if let setup = model.setupRequirement {
                Text(setup == .languageModel ? "KI-Modell fehlt." : "Motivmodell fehlt oder muss aktualisiert werden.")
                    .accessibilityIdentifier("local-mask.object.model-required")
                Button(setup == .languageModel ? "KI-Modell einrichten …" : "Motivmodell einrichten …") {
                    openAIModels(setup == .languageModel ? .corrections : .subject)
                }.accessibilityIdentifier("local-mask.object.setup")
            }
            if !model.modelsReady && !model.isCheckingModels && model.setupRequirement == nil {
                Button("Modelle erneut prüfen") { refreshModels() }
                    .accessibilityIdentifier("local-mask.object.retry-models")
            }
            if model.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.status ?? "Objekt wird ausgewählt …")
                    Spacer(minLength: 0)
                    Button("Abbrechen") { workspace.discardObjectMask() }
                        .accessibilityIdentifier("local-mask.object.cancel")
                }
            } else {
                if let proposal = model.proposal {
                    Text("Maskenvorschlag: \(proposal.layer.name)")
                        .fontWeight(.medium)
                        .accessibilityIdentifier("local-mask.object.proposal")
                    HStack {
                        Button("Verwerfen") { workspace.discardObjectMask() }
                            .accessibilityIdentifier("local-mask.object.discard")
                        Spacer(minLength: 0)
                        Button("Übernehmen") { workspace.applyObjectMask() }
                            .buttonStyle(.borderedProminent).disabled(!workspace.isCurrent)
                            .accessibilityIdentifier("local-mask.object.apply")
                    }
                } else {
                    Button("Objekt auswählen") {
                        WorkspaceActions.finishField()
                        workspace.requestObjectMask()
                    }.buttonStyle(.borderedProminent)
                        .disabled(!workspace.canRequestObjectMask || !model.modelsReady || model.isCheckingModels
                            || model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("local-mask.object.generate")
                }
                if let status = model.status {
                    Text(status).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("local-mask.object.status")
                    if status == AIDevelopmentError.staleContext.localizedDescription {
                        Button("Foto neu laden") { workspace.reloadObjectMaskSource() }
                            .accessibilityIdentifier("local-mask.object.reload-photo")
                    } else if status == ImageAnalysisError.staleSource.localizedDescription {
                        Button("Ordner aktualisieren") { workspace.refreshObjectMaskFolder() }
                            .accessibilityIdentifier("local-mask.object.refresh-folder")
                    }
                }
            }
        }.font(.system(size: 13)).foregroundStyle(Theme.text)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("local-mask.object.creator")
            .task { await model.refreshModels() }
    }

    private func refreshModels() { Task { await model.refreshModels() } }
}
