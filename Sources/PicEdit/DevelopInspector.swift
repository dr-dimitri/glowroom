import SwiftUI
import PicEditCore

struct DevelopInspector: View {
    @ObservedObject var library: LibraryModel
    var focusedControl: FocusState<WorkspaceControlFocus?>.Binding
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var assistant: AIAssistantModel
    @EnvironmentObject private var imageAnalysis: ImageAnalysisModel
    @EnvironmentObject private var photoMetadata: PhotoMetadataModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @ViewState private var showsMasks = false

    private var panels: WorkspacePanels { layout.panels(developing: library.isDeveloping) }
    private var saveStatus: WorkspaceSaveStatus { WorkspaceSaveStatus(editor: editor) }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider().overlay(Theme.line)
            if let asset = library.selectedAsset {
                selectedPhotoHeader(asset)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Toggle("Nur eine Gruppe geöffnet", isOn: Binding(
                                get: { panels.singleGroup },
                                set: { enabled in
                                    finishInput(assetID: asset.id)
                                    layout.update(developing: library.isDeveloping) { state in
                                        state.singleGroup = enabled
                                        if enabled, state.openGroups.count > 1 {
                                            let first = WorkspaceTool.allCases.first(where: state.openGroups.contains) ?? .edit
                                            state.openGroups = [first]
                                        }
                                    }
                                }
                            )).font(.system(size: 11)).toggleStyle(.checkbox).padding(.bottom, 14)
                            ForEach(WorkspaceTool.allCases, id: \.self) { tool in
                                toolGroup(tool, asset: asset)
                            }
                        }.padding(16)
                    }
                    .onChange(of: layout.revealRequest) { _, _ in
                        guard let tool = layout.revealedTool else { return }
                        // All headers are eager children; a dock jump can reach a
                        // closed group below a long, already open tool section.
                        withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(tool, anchor: .top) }
                        focusedControl.wrappedValue = .group(tool)
                    }
                    .onAppear {
                        if let tool = layout.revealedTool, panels.openGroups.contains(tool) {
                            proxy.scrollTo(tool, anchor: .top)
                            focusedControl.wrappedValue = .group(tool)
                        }
                    }
                }
                Divider().overlay(Theme.line)
                editingHistory(assetID: asset.id)
            } else {
                Text("Wähle ein Foto zum Bearbeiten.").font(.callout).foregroundStyle(Theme.muted).padding(24)
                Spacer()
            }
            Text("Nicht destruktiv · Original unverändert").font(.system(size: 10)).foregroundStyle(Theme.muted)
                .padding(.bottom, 14)
        }.background(Theme.sidebar)
            .sheet(isPresented: $showsMasks) {
                if let asset = library.selectedAsset, let source = try? editor.resolvedSource(for: asset) {
                    LocalAdjustmentMaskEditor(asset: asset, source: source.identity, settings: source.settings, library: library,
                        isPresented: $showsMasks)
                        .id(source.identity)
                }
            }
            .onChange(of: library.selectedID) { _, _ in showsMasks = false }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 12) {
            Label("Werkzeuge", systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Menu {
                ForEach(WorkspaceTool.allCases, id: \.self) { tool in
                    Button { reveal(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Werkzeuggruppe öffnen")
                .help("Direkt zu einer Werkzeuggruppe springen")
            Button {
                if let assetID = library.selectedID { finishInput(assetID: assetID) }
                layout.update(developing: library.isDeveloping) { $0.showsTools = false }
            } label: { Image(systemName: "xmark").frame(width: 24, height: 28) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                .accessibilityLabel("Werkzeugbereich schließen").help("Werkzeugbereich schließen")
        }.padding(.horizontal, 16).frame(height: 50)
    }

    private func selectedPhotoHeader(_ asset: PhotoAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(asset.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text("Quelle: \(editor.snapshot(for: asset.id).source == .original ? "Importiertes Original" : "Generierter Bildstand")")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            Button { finishInput(assetID: asset.id); showsMasks = true } label: {
                Label("Masken (\(editor.settings(for: asset.id).localAdjustments.count))", systemImage: "circle.dashed.inset.filled")
                    .font(.system(size: 11))
            }.disabled(!editor.canEdit || !library.canModify)
                .accessibilityIdentifier("workspace.local-masks")
            if saveStatus.hasError {
                Button { reveal(.versions) } label: {
                    Label("Speicherfehler · Prüfen", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                }.buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(editor.isReadOnly ? Color.orange : Theme.accent).frame(width: 5, height: 5)
                    Text(saveStatus.text).font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func toolGroup(_ tool: WorkspaceTool, asset: PhotoAsset) -> some View {
        let expanded = panels.openGroups.contains(tool)
        let groupStatus = status(for: tool, assetID: asset.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleGroup(tool, assetID: asset.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 10)
                    Label(tool.title, systemImage: tool.symbol)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 3)
                    if let status = groupStatus {
                        Label(status.text, systemImage: status.symbol)
                            .font(.system(size: 10)).foregroundStyle(status.isError ? Color.orange : Theme.accent)
                    }
                }.frame(maxWidth: .infinity, minHeight: 43, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .workspaceFocusTarget(focusedControl, equals: .group(tool)) {
                    toggleGroup(tool, assetID: asset.id)
                }
                .accessibilityLabel(tool.title)
                .accessibilityValue([expanded ? "Geöffnet" : "Geschlossen", groupStatus?.text].compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint(expanded ? "Werkzeuggruppe zuklappen" : "Werkzeuggruppe aufklappen")
            if expanded {
                toolContent(tool, asset: asset)
                    // Photo-bound controls reset on selection. Group preferences
                    // stay in the workspace model outside this identity boundary.
                    .id(asset.id)
                    .padding(.bottom, 16)
            }
            Divider().overlay(Theme.line)
        }.id(tool)
    }

    @ViewBuilder private func toolContent(_ tool: WorkspaceTool, asset: PhotoAsset) -> some View {
        switch tool {
        case .edit:
            VStack(alignment: .leading, spacing: 14) {
                naturalBalanceSection(assetID: asset.id)
                adjustmentSection("Tonwert", key: "tone", controls: Array(Adjustment.allCases.prefix(6)), assetID: asset.id)
                adjustmentSection("Präsenz", key: "presence", controls: Array(Adjustment.allCases.dropFirst(6).prefix(5)), assetID: asset.id)
                adjustmentSection("Entrauschen", key: "noise", controls: Array(Adjustment.allCases.suffix(2)), assetID: asset.id)
            }
        case .assistant:
            AIAssistantSection(model: assistant, comparesOriginal: library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
        case .analysis:
            ImageAnalysisSection(model: imageAnalysis)
        case .metadata:
            VStack(alignment: .leading, spacing: 20) {
                PhotoMetadataSection(model: photoMetadata)
                photoDetails(asset)
            }
        case .versions:
            VStack(alignment: .leading, spacing: 13) {
                Text("Aktive Quelle: \(editor.snapshot(for: asset.id).source == .original ? "Importiertes Original" : "Generierter Bildstand")")
                    .font(.system(size: 11, weight: .medium))
                Toggle("Importiertes Original anzeigen", isOn: $library.comparesOriginal)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                    .help("Zeigt ausschließlich das importierte Original ohne Regler. Der aktive Bildstand bleibt gespeichert.")
                Toggle("Aktuelle Quelle ohne Regler", isOn: $library.comparesCurrentSourceWithoutSettings)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                Button("Zum importierten Original zurückkehren") {
                    finishInput(assetID: asset.id)
                    editor.returnToOriginal(assetID: asset.id)
                    library.comparesOriginal = false
                    library.comparesCurrentSourceWithoutSettings = false
                }.disabled(!editor.canEdit || editor.snapshot(for: asset.id).source == .original)
                if let error = editor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let retry = saveStatus.retryAction {
                    Button(retry.title) {
                        switch retry {
                        case .acceptedArtifact(let id): _ = editor.retryAcceptedArtifactCommit(id)
                        case .pendingChanges: Task { _ = await editor.flush() }
                        case .reload: editor.retryLoading()
                        }
                    }.disabled(!saveStatus.canRetry)
                }
                ArtifactVariantsSection(assetID: asset.id)
            }
        }
    }

    private func editingHistory(assetID: String) -> some View {
        HStack(spacing: 10) {
            IconButton(symbol: "arrow.uturn.backward", help: "Bearbeitung rückgängig") {
                finishInput(assetID: assetID)
                editor.undo(assetID: assetID)
            }.disabled(!editor.canUndo(assetID: assetID) || !editor.canEdit)
            IconButton(symbol: "arrow.uturn.forward", help: "Bearbeitung wiederholen") {
                finishInput(assetID: assetID)
                editor.redo(assetID: assetID)
            }.disabled(!editor.canRedo(assetID: assetID) || !editor.canEdit)
            Spacer()
            Button("Zurücksetzen") {
                finishInput(assetID: assetID)
                editor.reset(assetID: assetID)
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                .disabled(!editor.canEdit || editor.settings(for: assetID).isNeutral)
        }.padding(.horizontal, 16).frame(height: 49)
    }

    private func reveal(_ tool: WorkspaceTool) {
        if let assetID = library.selectedID { finishInput(assetID: assetID) }
        layout.reveal(tool, developing: library.isDeveloping)
        focusedControl.wrappedValue = .group(tool)
    }

    private func toggleGroup(_ tool: WorkspaceTool, assetID: String) {
        finishInput(assetID: assetID)
        layout.toggleGroup(tool, developing: library.isDeveloping)
        focusedControl.wrappedValue = .group(tool)
    }

    private func toggleAdjustmentGroup(_ key: String, assetID: String) {
        finishInput(assetID: assetID)
        layout.update(developing: library.isDeveloping) { state in
            if state.openAdjustmentGroups.contains(key) { state.openAdjustmentGroups.remove(key) }
            else { state.openAdjustmentGroups.insert(key) }
        }
        focusedControl.wrappedValue = .adjustmentGroup(key)
    }

    private func finishInput(assetID: String) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        editor.endEditing(assetID: assetID)
    }

    private func status(for tool: WorkspaceTool, assetID: String) -> (text: String, symbol: String, isError: Bool)? {
        switch tool {
        case .edit:
            if editor.isReadOnly { return ("Fehler", "exclamationmark.triangle", true) }
            if editor.isSaving || editor.isLoading || editor.hasPendingChanges { return ("Läuft", "arrow.triangle.2.circlepath", false) }
            if !editor.settings(for: assetID).isNeutral { return ("Geändert", "slider.horizontal.3", false) }
        case .assistant:
            switch assistant.state {
            case .generating: return ("Läuft", "arrow.triangle.2.circlepath", false)
            case .previewing: return ("Vorschlag", "sparkles", false)
            case .failed: return ("Fehler", "exclamationmark.triangle", true)
            default: break
            }
        case .analysis:
            switch imageAnalysis.state {
            case .analyzing: return ("Läuft", "arrow.triangle.2.circlepath", false)
            case .ready: return ("Vorschlag", "doc.text.magnifyingglass", false)
            case .failed: return ("Fehler", "exclamationmark.triangle", true)
            default: break
            }
        case .metadata:
            if photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil {
                return ("Fehler", "exclamationmark.triangle", true)
            }
            if photoMetadata.isAnalyzing || photoMetadata.isSaving || photoMetadata.isLoading { return ("Läuft", "arrow.triangle.2.circlepath", false) }
            if photoMetadata.hasManualDraft || photoMetadata.record?.draft?.state == .pending || photoMetadata.record?.draft?.state == .edited {
                return ("Entwurf", "square.and.pencil", false)
            }
        case .versions:
            if editor.errorMessage != nil || editor.failedArtifactCommitID != nil { return ("Fehler", "exclamationmark.triangle", true) }
            if editor.isCommitting || editor.isLoadingVariants { return ("Läuft", "arrow.triangle.2.circlepath", false) }
        }
        return nil
    }

    private func photoDetails(_ asset: PhotoAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            SectionLabel(text: "Aufnahme")
            metadataRow("Kamera", asset.cameraModel ?? "—")
            metadataRow("Objektiv", asset.lensModel ?? "—")
            metadataRow("Blende", asset.aperture ?? "—")
            metadataRow("Zeit", asset.shutterSpeed ?? "—")
            metadataRow("ISO", asset.iso ?? "—")
            metadataRow("Brennweite", asset.focalLength ?? "—")
            metadataRow("Aufgenommen", asset.captureDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
            Divider()
            SectionLabel(text: "Datei")
            metadataRow("Abmessungen", "\(asset.pixelWidth) × \(asset.pixelHeight)")
            metadataRow("Auflösung", String(format: "%.1f MP", Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000))
            metadataRow("Format", asset.format.uppercased())
            metadataRow("Größe", ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
            metadataRow("Geändert", asset.modifiedAt.formatted(date: .abbreviated, time: .omitted))
            Divider()
            SectionLabel(text: "Speicherort")
            Text(asset.fileURL.deletingLastPathComponent().path)
                .font(.system(size: 11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button { library.reveal() } label: { Label("Im Finder anzeigen", systemImage: "arrow.up.right.square") }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }

    private func naturalBalanceSection(assetID: String) -> some View {
        let settings = editor.settings(for: assetID)
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { editor.settings(for: assetID).naturalBalanceAmount > 0 },
                set: { enabled in
                    finishInput(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    settings.naturalBalanceAmount = enabled ? 70 : 0
                    if enabled { settings.autoToneAmount = 0 }
                    editor.setSettings(settings, for: assetID)
                }
            )) {
                Label("Natürlicher Bildausgleich", systemImage: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
            }.toggleStyle(.switch).controlSize(.small)
                .help("Analysiert dieses Foto lokal und gleicht Helligkeit, Lichter, Schatten und Farben zurückhaltend aus. Manuelle Regler bleiben zusätzlich wirksam.")

            if settings.naturalBalanceAmount > 0 {
                naturalBalanceSlider("Stärke", keyPath: \.naturalBalanceAmount, range: 1...100, assetID: assetID)
                naturalBalanceSlider("Farbe", keyPath: \.naturalBalanceColorAmount, range: 0...100, assetID: assetID)
                Text("Farbe 0: nur Tonwerte. Höhere Werte beleben zurückhaltend die Farben.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if settings.autoToneAmount > 0 {
                Text("Bisherige Tonwert-Automatik aktiv (\(Int(settings.autoToneAmount)) %). Dein gespeicherter Bildstand bleibt erhalten. Einschalten ersetzt sie durch den natürlichen Bildausgleich.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Bisherige Automatik ausschalten") {
                    finishInput(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    settings.autoToneAmount = 0
                    editor.setSettings(settings, for: assetID)
                }.font(.system(size: 10))
            }
            Text("Nur auf Wunsch aktiv. Helle Bereiche zügeln, Schatten öffnen und natürliche Farben bewahren.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }.disabled(!editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings)
            .padding(12)
            .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func naturalBalanceSlider(_ title: String, keyPath: WritableKeyPath<EditSettings, Double>,
                                      range: ClosedRange<Double>, assetID: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(editor.settings(for: assetID)[keyPath: keyPath])) %")
                    .monospacedDigit().foregroundStyle(Theme.accent)
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
            Slider(value: Binding(
                get: { editor.settings(for: assetID)[keyPath: keyPath] },
                set: { newValue in
                    var settings = editor.settings(for: assetID)
                    settings[keyPath: keyPath] = newValue
                    editor.setSettings(settings, for: assetID)
                }
            ), in: range, step: 1, onEditingChanged: { editing in
                if editing { editor.beginEditing(assetID: assetID) }
                else { editor.endEditing(assetID: assetID) }
            }).controlSize(.mini).accessibilityLabel("Bildausgleich · \(title)")
        }
    }

    private func adjustmentSection(_ title: String, key: String, controls: [Adjustment], assetID: String) -> some View {
        let expanded = panels.openAdjustmentGroups.contains(key)
        let readOnly = !editor.canEdit || !library.canModify || library.comparesOriginal || library.comparesCurrentSourceWithoutSettings
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Button {
                    toggleAdjustmentGroup(key, assetID: assetID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).frame(width: 10)
                        SectionLabel(text: title)
                        Spacer(minLength: 0)
                    }.frame(minHeight: 30).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .workspaceFocusTarget(focusedControl, equals: .adjustmentGroup(key)) {
                        toggleAdjustmentGroup(key, assetID: assetID)
                    }
                    .accessibilityLabel(title).accessibilityValue(expanded ? "Geöffnet" : "Geschlossen")
                    .accessibilityHint(expanded ? "Reglergruppe zuklappen" : "Reglergruppe aufklappen")
                Button {
                    finishInput(assetID: assetID)
                    var settings = editor.settings(for: assetID)
                    for item in controls { settings[keyPath: item.keyPath] = 0 }
                    editor.setSettings(settings, for: assetID)
                } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 11)).frame(width: 28, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("\(title) zurücksetzen")
                    .accessibilityLabel("\(title) zurücksetzen").disabled(readOnly)
            }
            if expanded {
                VStack(spacing: 13) {
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
                    if key == "noise" {
                        Text("Luminanz reduziert Helligkeitsrauschen, Farbe reduziert Farbflecken. Vergrößere das Bild, um die Wirkung zu beurteilen.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
                    }
                }.disabled(readOnly)
            }
        }.padding(.top, 10)
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
