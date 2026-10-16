import SwiftUI
import PicEditCore

private typealias AssistantFocus<Value: Hashable> = SwiftUI.FocusState<Value>

struct AIAssistantSection: View {
    @ObservedObject var model: AIAssistantModel
    let comparesOriginal: Bool
    @AssistantFocus private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("KI-Assistent", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
            HStack {
                Text(model.providerLabel).font(.system(size: 10, weight: .medium))
                Spacer()
                SettingsLink { Text("KI-Einstellungen …").font(.system(size: 10)) }
            }
            Text("Der Assistent übersetzt Text in Reglerwerte; er analysiert das Foto nicht.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text("Bearbeitung oder optionaler Look-Zusatz").font(.system(size: 11, weight: .medium))
            TextField("Zum Beispiel: Tiefen aufhellen und Sättigung leicht senken", text: $model.prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).font(.system(size: 11))
                .focused($promptFocused).accessibilityLabel("Gewünschte Bearbeitung für den KI-Assistenten")
                .disabled(model.state == .generating)
            if let problem = model.lookPromptProblem {
                Text(problem).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Für einen Einzelvorschlag Text eingeben. Drei Looks funktionieren auch ohne Zusatztext.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            status
            if model.state != .generating {
                Button("Vorschlag erstellen") { model.generate() }
                    .buttonStyle(AccentButton()).disabled(!model.canGenerate)
                    .accessibilityHint("Erstellt eine unverbindliche Vorschau, ohne die Bearbeitung zu speichern")
                Button("Drei Looks erstellen") { model.generateLooks() }
                    .disabled(!model.canGenerateLooks)
                    .accessibilityHint("Erstellt drei unverbindliche Textrezepte aus demselben Ausgangsstand")
                Text(model.supportsLooks ? "Natürlich · Kontrastreich · Entsättigt. Stilistische Textrezepte, keine Bildanalyse." : "Drei Looks sind bei diesem Cloud-Provider nicht verfügbar. Wähle dafür Lokal in den KI-Einstellungen.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.mode == .lookGroup, model.state == .generating { lookPlaceholders }
            if model.state == .previewing { preview }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .task { await model.refreshAvailability() }
        .onDisappear { model.discard() }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.mode == .lookGroup ? "Drei Looks werden erstellt …" : "Vorschlag wird erstellt …").font(.system(size: 10))
                Spacer(minLength: 0)
                Button("Abbrechen") { model.discard(); promptFocused = true }
                    .font(.system(size: 10))
            }.accessibilityElement(children: .contain)
                .accessibilityLabel(model.mode == .lookGroup ? "Drei KI-Looks werden erstellt" : "KI-Vorschlag wird erstellt")
        case .unavailable(let reason):
            Text(reason.localizedDescription).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Verfügbarkeit erneut prüfen") { Task { await model.refreshAvailability() } }
                .font(.system(size: 10))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        case .idle:
            if model.availability == nil {
                Text("Lokaler Anbieter wird geprüft …").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        case .previewing: EmptyView()
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.changes.isEmpty {
                Text("Keine Änderung vorgeschlagen").font(.system(size: 11, weight: .medium))
            } else {
                Label("KI-Vorschau · noch nicht übernommen", systemImage: "eye")
                    .font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Picker("Vorschauvergleich", selection: $model.comparison) {
                    ForEach(AIAssistantModel.Comparison.allCases) { comparison in
                        Text(comparison.rawValue).tag(comparison)
                    }
                }.labelsHidden().pickerStyle(.menu).controlSize(.small)
                    .accessibilityLabel("Vorschauvergleich: aktuelle Bearbeitung oder Vorschlag")
                if comparesOriginal {
                    Text("„Vorher anzeigen“ zeigt das Original. Übernehmen schließt diesen Originalvergleich.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                if let group = model.lookGroup {
                    Text("Alle drei Looks verwenden dieselbe aktuelle Bearbeitung als Ausgang. Die Auswahl speichert nichts.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(group.validation.variants, id: \.proposal.id) { look in
                        AILookRecipeCard(model: model, look: look)
                    }
                } else {
                    AIAdjustmentChanges(changes: model.changes)
                }
                if model.lookGroup == nil, let explanation = model.explanation, !explanation.isEmpty {
                    Text("Begründung des Vorschlags: \(explanation)").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Text("Der JPEG-Export verwendet bis zur Übernahme die gespeicherte Bearbeitung.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Übernehmen") { _ = model.acceptProposal(); promptFocused = true }
                    .disabled(!model.canAccept)
                    .accessibilityHint("Übernimmt alle vorgeschlagenen Reglerwerte als einen rückgängig machbaren Schritt")
                Button("Verwerfen") { model.discard(); promptFocused = true }
            }.font(.system(size: 11))
        }
    }

    private var lookPlaceholders: some View {
        ForEach(AILookID.allCases, id: \.self) { id in
            VStack(alignment: .leading, spacing: 6) {
                Text(id.assistantLabel).font(.system(size: 11, weight: .medium))
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.2))
                    Text("Textrezept wird erstellt …").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.frame(height: 110)
            }.padding(8).background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct AILookRecipeCard: View {
    @ObservedObject var model: AIAssistantModel
    let look: AIValidatedLook

    private var selected: Bool { model.selectedLookID == look.proposal.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.selectLook(look.proposal.id) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        Text(look.proposal.name).font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                        Text(selected ? "Ausgewählt" : "Auswählen").font(.system(size: 9))
                    }
                    AILookCardImage(store: model.cards, id: look.proposal.id)
                        .frame(maxWidth: .infinity).frame(height: 110)
                        .background(Color.black.opacity(0.2))
                        .clipped()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(look.proposal.name), \(selected ? "ausgewählt" : "Look auswählen")")
                .accessibilityHint("Zeigt dieses Textrezept in der Hauptvorschau, ohne es zu übernehmen")
            Text("Gemeinsamer Ausgang: aktuelle Bearbeitung").font(.system(size: 9)).foregroundStyle(Theme.muted)
            if let explanation = look.proposal.proposal.explanation, !explanation.isEmpty {
                Text("Textrezept: \(explanation)").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Regleränderungen (\(model.changes(for: look.proposal.id).count))") {
                AIAdjustmentChanges(changes: model.changes(for: look.proposal.id)).padding(.top, 5)
            }.font(.system(size: 10))
        }.padding(8)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : Theme.line, lineWidth: 1) }
    }
}

private struct AIAdjustmentChanges: View {
    let changes: [AIAssistantModel.Change]
    var body: some View {
        ForEach(changes) { change in
            VStack(alignment: .leading, spacing: 3) {
                Text(change.parameter.assistantLabel).font(.system(size: 11, weight: .medium))
                Text("\(change.parameter.assistantValue(change.baseline)) → \(change.parameter.assistantValue(change.target)) · Δ \(change.parameter.assistantValue(change.delta, signed: true))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }.accessibilityElement(children: .combine)
        }
    }
}

extension AILookID {
    var assistantLabel: String {
        switch self {
        case .natural: return "Natürlich"
        case .contrasty: return "Kontrastreich"
        case .desaturated: return "Entsättigt"
        }
    }
}

extension EditParameter {
    var assistantLabel: String {
        switch self {
        case .exposure: return "Belichtung"
        case .contrast: return "Kontrast"
        case .highlights: return "Lichter"
        case .shadows: return "Tiefen"
        case .whites: return "Weiß"
        case .blacks: return "Schwarz"
        case .texture: return "Struktur"
        case .clarity: return "Klarheit"
        case .dehaze: return "Dunst entfernen"
        case .vibrance: return "Dynamik"
        case .saturation: return "Sättigung"
        case .luminanceNoiseReduction: return "Luminanz-Entrauschung"
        case .colorNoiseReduction: return "Farb-Entrauschung"
        case .autoToneAmount: return "Tonwert-Automatik"
        }
    }

    func assistantValue(_ value: Double, signed: Bool = false) -> String {
        // Match the inspector's EV precision and numeric scales. Only the
        // existing automatic tone strength is labelled as a percentage.
        let format = self == .exposure ? (signed ? "%+.2f" : "%.2f") : (signed ? "%+.0f" : "%.0f")
        let unit = self == .exposure ? " EV" : self == .autoToneAmount ? " %" : ""
        return String(format: format, value) + unit
    }
}
