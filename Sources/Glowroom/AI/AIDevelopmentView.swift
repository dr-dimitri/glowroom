import SwiftUI
import GlowroomCore

/// Intent controls are sent together on an explicit request. Moving them never
/// schedules inference or mutates the photo's persisted adjustment settings.
struct AIDevelopmentView: View {
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var workspace: DevelopWorkspace
    @StateObject private var model: AIDevelopmentModel
    @ViewState private var showsModels = false
    @ViewState private var showsSubjectModel = false

    @MainActor
    init(library: LibraryModel, model: AIDevelopmentModel? = nil) {
        self.library = library
        _model = StateObject(wrappedValue: model ?? AIDevelopmentModel())
    }

    private var canRequest: Bool {
        editor.canEdit && library.canModify && !library.isImporting && !library.isProjecting
            && !library.comparesOriginal && !library.comparesCurrentSourceWithoutSettings
            && workspace.navigatorImage != nil
    }

    private var layers: [LocalAdjustment] {
        library.selectedID.map { editor.settings(for: $0).localAdjustments } ?? []
    }

    private var validRequest: Bool {
        if model.createsMask {
            return layers.count < LocalAdjustment.maximumCount
                && !model.intent.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let id = model.intent.targetMaskID else { return true }
        return layers.contains { $0.id == id && $0.isEnabled && $0.mask.opacity > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Qwen3.5-4B").font(.system(size: 12, weight: .medium))
                    Text("Lokal auf diesem Mac").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                Button { showsModels = true } label: {
                    Label("Modelle", systemImage: "externaldrive")
                }.controlSize(.small)
                    .accessibilityIdentifier("ai-development.models")
            }

            Text("Aufträge werden erst nach einem Vorschlag und deiner Übernahme gespeichert. Bildkorrekturen und Masken sind in allen Entwicklungsansichten gemeinsam verfügbar.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Picker("Aufgabe", selection: $model.createsMask) {
                    Text("Entwickeln").tag(false)
                    Text("Neue Maske").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("ai-development.task")
                if !model.createsMask {
                    Picker("Anwenden auf", selection: $model.intent.targetMaskID) {
                        Text("Gesamtes Bild").tag(Optional<UUID>.none)
                        ForEach(layers) { layer in
                            Text(layer.name + (layer.isEnabled && layer.mask.opacity > 0 ? "" : " (ausgeblendet)"))
                                .tag(Optional(layer.id))
                        }
                        if let id = model.intent.targetMaskID, !layers.contains(where: { $0.id == id }) {
                            Text("Maske nicht mehr verfügbar").tag(Optional(id))
                        }
                    }.accessibilityIdentifier("ai-development.scope")
                    if model.intent.targetMaskID != nil {
                        Text("Nur die gewählte Maske wird korrigiert. Globale Werte und andere Masken bleiben erhalten.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    if !validRequest {
                        Text(AIDevelopmentError.unavailableMask.localizedDescription)
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
                Text("Auftrag für den nächsten Vorschlag").font(.system(size: 11, weight: .medium))
                TextField(model.createsMask ? "Zum Beispiel: Maskiere den Blumenstrauß" : "Zum Beispiel: natürliches Licht, wärmere Farben", text: $model.intent.instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...5)
                    .accessibilityIdentifier("ai-development.instruction")
                if model.createsMask {
                    Text("Qwen findet das gewünschte Objekt; das lokale Freistellungsmodell erstellt die Maske. Prüfe die rote Fläche auf dem vollständigen Bild. Nach der Übernahme kannst du sie unter „Masken“ mit Pinsel und Radierer verfeinern.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Freistellungsmodell einrichten …") { showsSubjectModel = true }
                        .controlSize(.small).accessibilityIdentifier("ai-development.subject-model")
                    if layers.count >= LocalAdjustment.maximumCount {
                        Text("Pro Foto sind höchstens 16 Masken möglich.").font(.system(size: 10))
                    }
                } else {
                    intentSlider("Helligkeit", value: $model.intent.brightness,
                             low: "Dunkler", high: "Heller", identifier: "brightness")
                    intentSlider("Kontrast", value: $model.intent.contrast,
                             low: "Weicher", high: "Kräftiger", identifier: "contrast")
                    intentSlider("Wärme", value: $model.intent.warmth,
                             low: "Kühler", high: "Wärmer", identifier: "warmth")
                    intentSlider("Farbkraft", value: $model.intent.color,
                             low: "Gedämpft", high: "Lebendig", identifier: "color")
                    intentSlider("Stärke", value: $model.intent.strength,
                             low: "Dezent", high: "Deutlich", identifier: "strength", range: 0...1, neutral: 0.5)
                }
            }.disabled(model.isRunning)

            if model.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Vorschlag wird erstellt …").font(.system(size: 11))
                    Spacer(minLength: 0)
                    Button("Abbrechen") { model.cancel() }.controlSize(.small)
                }
            } else {
                Button {
                    WorkspaceActions.finishField()
                    model.start(library: library, editor: editor, workspace: workspace)
                } label: {
                    Label("Vorschlag erstellen", systemImage: "sparkles").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!canRequest || !validRequest)
                    .accessibilityIdentifier("ai-development.generate")
            }

            if let status = model.status {
                Text(status).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("ai-development.status")
            }

            if let proposal = model.proposal {
                VStack(alignment: .leading, spacing: 8) {
                    Text(proposal.createdMaskID == nil ? "Korrekturvorschlag" : "Maskenvorschlag")
                        .font(.system(size: 12, weight: .medium))
                    if let name = proposal.targetName, proposal.createdMaskID == nil {
                        Text("Nur Maske: \(name)").font(.system(size: 11, weight: .medium))
                    }
                    if let preview = model.maskPreview {
                        Image(decorative: preview.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 240).accessibilityLabel("Vorgeschlagene Maske als rote Fläche auf dem vollständigen Foto")
                            .accessibilityIdentifier("ai-development.mask-preview")
                    }
                    Text(proposal.summary).font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    ForEach(Array(proposal.changes.enumerated()), id: \.offset) { _, change in
                        Text(change).font(.system(size: 10)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Verwerfen") { model.discard() }
                        Spacer(minLength: 0)
                        Button("Übernehmen") { model.apply(library: library, editor: editor) }
                            .buttonStyle(.borderedProminent).disabled(!canRequest || model.isRunning || !model.canApplyProposal)
                            .accessibilityIdentifier("ai-development.apply")
                    }.controlSize(.small)
                }.padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            }

            Text("Prüfe den Vorschlag vor dem Übernehmen. Das Modell kann Bildinhalte und Korrekturen falsch einschätzen. Übernommene Korrekturen lassen sich rückgängig machen.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showsModels) { LLMModelManagerView() }
        .sheet(isPresented: $showsSubjectModel) { SubjectMattingModelSetupView() }
        .onChange(of: editor.aiSnapshot(in: library)) { _, _ in
            model.invalidateIfNeeded(library: library, editor: editor)
        }
        .onDisappear { model.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-development.panel")
    }

    private func intentSlider(_ title: String, value: Binding<Double>, low: String, high: String,
                              identifier: String, range: ClosedRange<Double> = -1...1,
                              neutral: Double = 0) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer(minLength: 0)
                Text("\(Int((value.wrappedValue * 100).rounded())) %")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            ResettableSlider(value: value, in: range, step: 0.05, neutralValue: neutral)
                .controlSize(.small).accessibilityLabel(title)
                .accessibilityIdentifier("ai-development.\(identifier)")
            HStack {
                Text(low)
                Spacer(minLength: 0)
                Text(high)
            }.font(.system(size: 9)).foregroundStyle(Theme.muted)
        }
    }
}
