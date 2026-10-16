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
            Text("Der Assistent übersetzt Text in Reglerwerte; er analysiert das Foto nicht.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text("Gewünschte Bearbeitung").font(.system(size: 11, weight: .medium))
            TextField("Zum Beispiel: Tiefen aufhellen und Sättigung leicht senken", text: $model.prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).font(.system(size: 11))
                .focused($promptFocused).accessibilityLabel("Gewünschte Bearbeitung für den KI-Assistenten")
                .disabled(model.state == .generating)
            if let problem = model.promptProblem {
                Text(problem).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            status
            if model.state != .generating {
                Button("Vorschlag erstellen") { model.generate() }
                    .buttonStyle(AccentButton()).disabled(!model.canGenerate)
                    .accessibilityHint("Erstellt eine unverbindliche Vorschau, ohne die Bearbeitung zu speichern")
            }
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
                Text("Vorschlag wird erstellt …").font(.system(size: 10))
                Spacer(minLength: 0)
                Button("Abbrechen") { model.discard(); promptFocused = true }
                    .font(.system(size: 10))
            }.accessibilityElement(children: .contain).accessibilityLabel("KI-Vorschlag wird erstellt")
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
                ForEach(model.changes) { change in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(change.parameter.assistantLabel).font(.system(size: 11, weight: .medium))
                        Text("\(change.parameter.assistantValue(change.baseline)) → \(change.parameter.assistantValue(change.target)) · Δ \(change.parameter.assistantValue(change.delta, signed: true))")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                    }.accessibilityElement(children: .combine)
                }
                if let explanation = model.explanation, !explanation.isEmpty {
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
