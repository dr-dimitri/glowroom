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
            Text(model.usesImageContext
                 ? "Der Assistent berücksichtigt die Helligkeit des Fotos und setzt deinen Auftrag als rückgängig machbare Bearbeitung um."
                 : "Der Assistent übersetzt deinen Text in globale Reglerwerte.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text("Was möchtest du verbessern?").font(.system(size: 11, weight: .medium))
            TextField("Zum Beispiel: Helle die dunklen Bereiche etwas auf", text: $model.prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).font(.system(size: 11))
                .focused($promptFocused).accessibilityLabel("Gewünschte Bearbeitung für den KI-Assistenten")
                .disabled(model.state == .generating)
            if let problem = model.promptProblem, !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(problem).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(model.usesImageContext
                     ? "Zum Beispiel: „Korrigiere den überstrahlten Hintergrund“ oder „Helle die dunklen Bereiche etwas auf“."
                     : "Zum Beispiel: „Lichter reduzieren“ oder „Tiefen etwas aufhellen“.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Maskieren bleibt als eigenes Werkzeug verfügbar.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            status
            if model.state != .generating {
                Button("Bearbeitung ausführen") { model.generate() }
                    .buttonStyle(AccentButton()).disabled(!model.canGenerate)
                    .accessibilityIdentifier("assistant.execute")
                    .accessibilityHint("Aktiviert die Bearbeitung direkt als einen rückgängig machbaren Schritt")
            }
            if model.state == .previewing { preview }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        // The workspace may unmount this section when its dock group changes.
        // Proposal/request ownership stays with the model; only an explicit
        // retry rechecks a provider whose availability is already known.
        .task {
            if model.availability == nil { await model.refreshAvailability() }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Bearbeitung wird vorbereitet …").font(.system(size: 10))
                Spacer(minLength: 0)
                Button("Abbrechen") { model.discard(); promptFocused = true }
                    .font(.system(size: 10))
            }.accessibilityElement(children: .contain)
                .accessibilityLabel("KI-Bearbeitung wird vorbereitet")
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
            if model.changes.isEmpty && model.regionalChanges.isEmpty {
                Text("Keine Änderung vorgeschlagen").font(.system(size: 11, weight: .medium))
            } else {
                Label("KI-Anpassungen aktiv", systemImage: "checkmark.circle")
                    .font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !model.changes.isEmpty {
                    if !model.regionalChanges.isEmpty {
                        Text("Gesamtes Bild").font(.system(size: 11, weight: .medium))
                    }
                    AIAdjustmentChanges(changes: model.changes)
                }
                ForEach(model.regionalChanges) { region in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(region.name, systemImage: "circle.dashed.inset.filled")
                            .font(.system(size: 11, weight: .medium))
                        AIAdjustmentChanges(changes: region.changes)
                    }
                }
            }
            if model.hasAppliedChanges {
                Picker("Bearbeitungsvergleich", selection: $model.comparison) {
                    ForEach(AIAssistantModel.Comparison.allCases) { comparison in
                        Text(comparison.rawValue).tag(comparison)
                    }
                }.labelsHidden().pickerStyle(.menu).controlSize(.small)
                    .accessibilityLabel("Bearbeitungsvergleich: Ausgangsstand oder aktive Bearbeitung")
                if comparesOriginal {
                    Text("„Vorher anzeigen“ zeigt das Original.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Text("Command-Z macht die letzte Anpassung rückgängig. Der JPEG-Export verwendet die aktive Bearbeitung.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let explanation = model.explanation, !explanation.isEmpty {
                Text(explanation).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Button("Ergebnis schließen") { model.discard(); promptFocused = true }
                .font(.system(size: 11))
                .accessibilityHint("Schließt die Ergebnisanzeige; aktive Anpassungen bleiben erhalten")
        }
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
        case .autoToneAmount: return "Bisherige Tonwert-Automatik"
        case .naturalBalanceAmount: return "Natürlicher Bildausgleich"
        case .naturalBalanceColorAmount: return "Bildausgleich · Farbe"
        }
    }

    func assistantValue(_ value: Double, signed: Bool = false) -> String {
        // Match the inspector's EV precision and numeric scales; balance
        // strength/color and legacy automatic tone use percentages.
        let format = self == .exposure ? (signed ? "%+.2f" : "%.2f") : (signed ? "%+.0f" : "%.0f")
        let percentage = self == .autoToneAmount || self == .naturalBalanceAmount || self == .naturalBalanceColorAmount
        let unit = self == .exposure ? " EV" : percentage ? " %" : ""
        return String(format: format, value) + unit
    }
}
