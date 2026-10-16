import SwiftUI
import PicEditCore

struct DevelopInspector: View {
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var assistant: AIAssistantModel
    @EnvironmentObject private var imageAnalysis: ImageAnalysisModel
    @EnvironmentObject private var photoMetadata: PhotoMetadataModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Entwickeln")
                Spacer()
                Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.accent)
            }.padding(.horizontal, 20).frame(height: 58)
            Divider().overlay(Theme.line)
            if let asset = library.selectedAsset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(asset.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 6) {
                                Circle().fill(editor.isReadOnly ? Color.orange : Theme.accent).frame(width: 5, height: 5)
                                Text(saveStatus).font(.system(size: 10)).foregroundStyle(Theme.muted)
                            }
                        }
                        Toggle("Importiertes Original anzeigen", isOn: $library.comparesOriginal)
                            .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                            .help("Zeigt ausschließlich das importierte Original ohne Regler. Der aktive Bildstand bleibt gespeichert.")
                        Toggle("Aktuelle Quelle ohne Regler", isOn: $library.comparesCurrentSourceWithoutSettings)
                            .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                        Button("Zum importierten Original zurückkehren") {
                            editor.returnToOriginal(assetID: asset.id)
                            library.comparesOriginal = false; library.comparesCurrentSourceWithoutSettings = false
                        }
                            .disabled(!editor.canEdit || editor.snapshot(for: asset.id).source == .original)
                        if let id = editor.failedArtifactCommitID {
                            Button("Angenommenen Bildstand erneut speichern") { _ = editor.retryAcceptedArtifactCommit(id) }
                                .disabled(editor.isCommitting || editor.isRestoring || editor.isBackingUp)
                        }
                        AIAssistantSection(model: assistant, comparesOriginal: library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
                        ImageAnalysisSection(model: imageAnalysis)
                        PhotoMetadataSection(model: photoMetadata)
                        ArtifactVariantsSection(assetID: asset.id)
                        autoToneSection(assetID: asset.id)
                        adjustmentSection("Tonwert", controls: Array(Adjustment.allCases.prefix(6)), assetID: asset.id)
                        adjustmentSection("Präsenz", controls: Array(Adjustment.allCases.dropFirst(6).prefix(5)), assetID: asset.id)
                        adjustmentSection("Entrauschen", controls: Array(Adjustment.allCases.suffix(2)), assetID: asset.id)
                        Text("Luminanz reduziert Helligkeitsrauschen, Farbe reduziert Farbflecken. Vergrößere das Bild, um die Wirkung zu beurteilen.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
                    }.padding(18)
                }.id(asset.id)
                Divider().overlay(Theme.line)
                HStack(spacing: 6) {
                    IconButton(symbol: "arrow.uturn.backward", help: "Bearbeitung rückgängig") { editor.undo(assetID: asset.id) }
                        .disabled(!editor.canUndo(assetID: asset.id) || !editor.canEdit)
                    IconButton(symbol: "arrow.uturn.forward", help: "Bearbeitung wiederholen") { editor.redo(assetID: asset.id) }
                        .disabled(!editor.canRedo(assetID: asset.id) || !editor.canEdit)
                    Spacer()
                    Button("Zurücksetzen") { editor.reset(assetID: asset.id) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .disabled(!editor.canEdit || editor.settings(for: asset.id).isNeutral)
                }.padding(.horizontal, 15).frame(height: 49)
            } else {
                Text("Wähle ein Foto zum Bearbeiten.").font(.callout).foregroundStyle(Theme.muted).padding(24)
                Spacer()
            }
            Text("Nicht destruktiv · Original unverändert").font(.system(size: 9)).foregroundStyle(Theme.muted)
                .padding(.bottom, 14)
        }.background(Theme.sidebar)
    }

    private var saveStatus: String {
        if editor.isLoading { return "Bearbeitungen werden geladen …" }
        if editor.isReadOnly { return "Speichern nicht verfügbar" }
        if editor.isRestoring { return "Sicherung wird wiederhergestellt …" }
        if editor.isCommitting { return "Bildstand wird gespeichert …" }
        if editor.isSaving { return "Wird gespeichert …" }
        if editor.hasPendingChanges { return "Änderungen werden gesichert …" }
        return "Alle Änderungen gespeichert"
    }

    private func autoToneSection(assetID: String) -> some View {
        let amount = editor.settings(for: assetID).autoToneAmount
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { editor.settings(for: assetID).autoToneAmount > 0 },
                set: { enabled in
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    editor.endEditing(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    settings.autoToneAmount = enabled ? 100 : 0
                    editor.setSettings(settings, for: assetID)
                }
            )) {
                Label("Tonwert-Automatik", systemImage: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
            }.toggleStyle(.switch).controlSize(.small)
                .help("Gleicht Lichter und Schatten passend zu diesem Foto aus. Manuelle Regler bleiben zusätzlich wirksam.")

            if amount > 0 {
                HStack {
                    Text("Stärke")
                    Spacer()
                    Text("\(Int(amount)) %").monospacedDigit().foregroundStyle(Theme.accent)
                }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                Slider(value: Binding(
                    get: { editor.settings(for: assetID).autoToneAmount },
                    set: { newValue in
                        var settings = editor.settings(for: assetID)
                        settings.autoToneAmount = newValue
                        editor.setSettings(settings, for: assetID)
                    }
                ), in: 1...100, step: 1, onEditingChanged: { editing in
                    if editing { editor.beginEditing(assetID: assetID) }
                    else { editor.endEditing(assetID: assetID) }
                }).controlSize(.mini).accessibilityLabel("Automatik-Stärke")
            }
            Text("Helle Bereiche zügeln, Schatten öffnen. Schwarz, Weiß und Kontrast bleiben erhalten.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
        }.disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
            .padding(12)
            .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func adjustmentSection(_ title: String, controls: [Adjustment], assetID: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                Button {
                    var settings = editor.settings(for: assetID)
                    for item in controls { settings[keyPath: item.keyPath] = 0 }
                    editor.setSettings(settings, for: assetID)
                } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("\(title) zurücksetzen")
                    .accessibilityLabel("\(title) zurücksetzen")
            }
            ForEach(controls) { control in
                AdjustmentSlider(control: control, value: Binding(
                    get: { editor.settings(for: assetID)[keyPath: control.keyPath] },
                    set: { newValue in
                        var settings = editor.settings(for: assetID)
                        settings[keyPath: control.keyPath] = newValue
                        editor.setSettings(settings, for: assetID)
                    }
                ), onEditingChanged: { editing in
                    if editing { editor.beginEditing(assetID: assetID) }
                    else { editor.endEditing(assetID: assetID) }
                })
            }
        }.disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private struct AdjustmentSlider: View {
    let control: Adjustment
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @FocusState private var valueFocused: Bool

    private var numericValue: Binding<Double> {
        Binding(get: { value }, set: { newValue in
            // TextField parses valid prefixes while typing (3, then 35). Keep
            // the complete entry in one undo group until submit or focus loss.
            onEditingChanged(true)
            value = newValue
        })
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(control.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.78))
                    .onTapGesture(count: 2) { value = 0 }.help("Doppelklick setzt den Wert zurück")
                Spacer()
                TextField(control.label, value: numericValue,
                          format: .number.precision(.fractionLength(control == .exposure ? 2 : 0)))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(value == 0 ? Theme.muted : Theme.accent)
                    .frame(width: 47).accessibilityLabel("\(control.label) Wert")
                    .focused($valueFocused)
                    .onSubmit { onEditingChanged(false) }
                    .onChange(of: valueFocused) { _, focused in if !focused { onEditingChanged(false) } }
                    .onDisappear { onEditingChanged(false) }
                if control == .exposure { Text("EV").font(.system(size: 8)).foregroundStyle(Theme.muted) }
            }
            Slider(value: $value, in: control.range, step: control == .exposure ? 0.05 : 1,
                   onEditingChanged: onEditingChanged)
                .controlSize(.mini).accessibilityLabel(control.label)
        }
    }
}

private enum Adjustment: String, CaseIterable, Identifiable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case texture, clarity, dehaze, vibrance, saturation
    case luminanceNoiseReduction, colorNoiseReduction
    var id: String { rawValue }
    var label: String {
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
        case .luminanceNoiseReduction: return "Luminanz"
        case .colorNoiseReduction: return "Farbe"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .luminanceNoiseReduction, .colorNoiseReduction: return 0...100
        default: return -100...100
        }
    }
    var keyPath: WritableKeyPath<EditSettings, Double> {
        switch self {
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .whites: return \.whites
        case .blacks: return \.blacks
        case .texture: return \.texture
        case .clarity: return \.clarity
        case .dehaze: return \.dehaze
        case .vibrance: return \.vibrance
        case .saturation: return \.saturation
        case .luminanceNoiseReduction: return \.luminanceNoiseReduction
        case .colorNoiseReduction: return \.colorNoiseReduction
        }
    }
}
