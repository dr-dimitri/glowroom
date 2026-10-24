import SwiftUI
import UniformTypeIdentifiers
import GlowroomCore

enum DevelopRepairMode: String, CaseIterable, Identifiable, Sendable {
    case remove, heal, clone, redEye
    var id: Self { self }
    var retouchMode: DevelopRetouchMode { self == .clone ? .clone : .heal }
    var title: String {
        switch self {
        case .remove: "Entfernen"
        case .heal: "Heilen"
        case .clone: "Kopierstempel"
        case .redEye: "Rote Augen"
        }
    }
}

enum DevelopRepairOverlay: String, CaseIterable, Identifiable, Sendable {
    case always, automatic, never
    var id: Self { self }
    var title: String {
        switch self {
        case .always: "Immer"
        case .automatic: "Automatisch"
        case .never: "Nie"
        }
    }
}

/// The palette only changes UI state or starts bounded workspace operations.
/// Accepted image edits remain part of the editor's ordered undo history.
struct DevelopRepairInspector: View {
    let asset: PhotoAsset
    @ObservedObject var workspace: DevelopWorkspace
    @EnvironmentObject private var editor: EditingModel
    @ViewState private var actionTask: Task<Void, Never>?
    @ViewState private var importsModel = false
    @ViewState private var showsModelSetup = false
    @ViewState private var showsHelp = false

    private var ready: Bool { editor.canEdit && workspace.isOriginalCanvasReady && !workspace.repairBusy }
    private var geometry: DevelopGeometry { editor.settings(for: asset.id).developGeometry }
    private var strokes: [DevelopRetouchStroke] { geometry.retouchStrokes }
    private var selectedMode: DevelopRepairMode { workspace.tool == .redEye ? .redEye : workspace.repairMode }
    private var usesFrozenSelection: Bool {
        selectedMode == .remove && (workspace.repairUsesAI || workspace.repairObjectDetection)
    }
    private var brushDiameterText: String {
        let size = workspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight))
        let diameter = 2 * workspace.repairRadius * min(size.width, size.height)
        return diameter < 10 ? String(format: "%.1f px", diameter) : "\(Int(diameter.rounded())) px"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reparieren").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button("Hilfe", systemImage: "questionmark.circle") { showsHelp = true }
                    .labelStyle(.iconOnly).accessibilityIdentifier("develop.repair.help")
            }
            modeControls
            if workspace.repairBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityLabel("Reparatur wird verarbeitet")
                    Text(workspace.repairAISetupProgress == nil ? "Reparatur läuft …" : "Modell wird eingerichtet …")
                    Spacer(minLength: 0)
                    Button("Abbrechen") { cancelWork() }
                        .accessibilityIdentifier("develop.repair.cancel")
                }
            }
            Divider()
            if selectedMode == .redEye {
                redEyeControls
            } else {
                brushControls
                if selectedMode == .remove {
                    Divider()
                    aiControls
                    Divider()
                    detectionControls
                }
                if let status = workspace.repairStatus {
                    Text(status).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("develop.repair.status")
                }
            }
            if let error = workspace.errorMessage {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("develop.repair.error")
            }
            Divider()
            if selectedMode != .redEye {
                Button("Alle Reparaturen löschen") {
                    actionTask?.cancel()
                    workspace.resetRepairs(asset: asset, editor: editor)
                }.disabled(!ready || strokes.isEmpty).accessibilityIdentifier("develop.repair.reset")
            }
            HStack {
                Spacer(minLength: 0)
                Button("Schließen") {
                    actionTask?.cancel()
                    editor.endEditing(assetID: asset.id)
                    workspace.closeRepair()
                }.accessibilityIdentifier("develop.repair.close")
            }
        }.font(.system(size: 13)).foregroundStyle(Theme.text).padding(.vertical, 10)
            .onDisappear { cancelWork(); editor.endEditing(assetID: asset.id) }
            .task(id: selectedMode) {
                if selectedMode == .remove { await workspace.refreshRepairAIAvailability() }
            }
            .sheet(isPresented: $showsHelp) { repairHelp }
            .fileImporter(isPresented: $importsModel, allowedContentTypes: [.folder, UTType(filenameExtension: "mlpackage") ?? .folder]) { result in
                guard case .success(let url) = result else { return }
                actionTask = Task {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    await workspace.importRepairAIModel(from: url)
                }
            }
    }

    private var modeControls: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(DevelopRepairMode.allCases) { mode in
                Button {
                    actionTask?.cancel()
                    editor.endEditing(assetID: asset.id)
                    editor.selectEditingFunction(.repair, assetID: asset.id)
                    workspace.selectRepairMode(mode)
                    showsModelSetup = false
                } label: {
                    VStack(spacing: 4) {
                        modeSymbol(mode).frame(width: 18, height: 20)
                        Text(mode.title).fixedSize(horizontal: false, vertical: true)
                    }.padding(.horizontal, 4).padding(.vertical, 5).frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(selectedMode == mode ? Theme.text : Theme.muted)
                        .background(selectedMode == mode ? Theme.elevated : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(selectedMode == mode ? Theme.accent : Theme.line, lineWidth: selectedMode == mode ? 2 : 1))
                }.buttonStyle(.plain).accessibilityLabel(mode.title)
                    .accessibilityValue(selectedMode == mode ? "Ausgewählt" : "Nicht ausgewählt")
                    .accessibilityIdentifier("develop.repair.mode." + mode.rawValue)
            }
        }.disabled(!ready)
    }

    private var brushControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow("Pinselgröße", value: $workspace.repairRadius, range: 0.0005...0.15,
                valueText: brushDiameterText, identifier: "size", neutral: 0.035)
            if !usesFrozenSelection {
                sliderRow("Weiche Kante", value: $workspace.repairFeather, range: 0...1,
                    valueText: "\(Int((workspace.repairFeather * 100).rounded())) %", identifier: "feather", neutral: 0.5)
            }
            if selectedMode == .remove {
                Toggle("Gemaltes Objekt auswählen", isOn: $workspace.repairObjectDetection)
                    .disabled(!ready).accessibilityIdentifier("develop.repair.objects")
            }
            if selectedMode != .remove || !workspace.repairUsesAI {
                if workspace.repairChoosesSource || (selectedMode == .clone && workspace.repairSource == nil) {
                    Label("Quelle im Bild wählen", systemImage: "scope")
                        .accessibilityIdentifier("develop.repair.source-status")
                } else if workspace.repairSource != nil {
                    Label("Quelle gesetzt", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("develop.repair.source-status")
                }
                Button("Neue Quelle im Bild wählen") {
                    editor.endEditing(assetID: asset.id)
                    workspace.chooseRepairSource()
                }.disabled(!ready).accessibilityIdentifier("develop.repair.choose-source")
                if selectedMode != .clone && (workspace.repairSource != nil || workspace.repairChoosesSource) {
                    Button("Automatische Quellwahl verwenden") {
                        editor.endEditing(assetID: asset.id)
                        workspace.cancelRepairWork(clearCandidates: false)
                        workspace.repairSource = nil
                        workspace.repairChoosesSource = false
                    }.disabled(!ready).accessibilityIdentifier("develop.repair.automatic-source")
                }
            }
            if workspace.canTryAnotherRepairSource(asset: asset, editor: editor) {
                Button("Andere Quelle für letzte Reparatur") {
                    workspace.tryAnotherRepairSource(asset: asset, editor: editor)
                }.disabled(!ready).accessibilityIdentifier("develop.repair.next-source")
            }
            if let selected = workspace.repairSelectedStrokeID, strokes.contains(where: { $0.id == selected }) {
                Button("Ausgewählte Reparatur löschen") {
                    workspace.removeRepair(id: selected, asset: asset, editor: editor)
                }.disabled(!ready).accessibilityIdentifier("develop.repair.delete-selected")
            }
            if !strokes.isEmpty {
                Button("Letzte Reparatur löschen", action: removeLastStroke)
                    .disabled(!ready).accessibilityIdentifier("develop.repair.remove-last")
            }
            Picker("Markierungen", selection: $workspace.repairOverlay) {
                ForEach(DevelopRepairOverlay.allCases) { overlay in Text(overlay.title).tag(overlay) }
            }.disabled(!ready).accessibilityIdentifier("develop.repair.overlay")
            Toggle("Staub hervorheben", isOn: $workspace.repairVisualizesSpots)
                .disabled(!ready).accessibilityIdentifier("develop.repair.visualize-spots")
            if workspace.repairVisualizesSpots {
                sliderRow("Empfindlichkeit", value: $workspace.repairSpotThreshold, range: 0...1,
                    valueText: "\(Int((workspace.repairSpotThreshold * 100).rounded())) %", identifier: "threshold", neutral: 0.5)
            }
        }
    }

    private var aiControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Mit lokaler KI entfernen", isOn: $workspace.repairUsesAI)
                .disabled(!ready || !workspace.repairAIReady)
                .accessibilityIdentifier("develop.repair.generative")
            Label(workspace.repairAIReady ? "LaMa verfügbar" : "LaMa nicht eingerichtet",
                systemImage: workspace.repairAIReady ? "checkmark.circle" : "arrow.down.circle")
                .foregroundStyle(Theme.muted).accessibilityIdentifier("develop.repair.ai.availability")
            Button(showsModelSetup ? "Einrichtung schließen" : "LaMa einrichten …") { showsModelSetup.toggle() }
                .disabled(workspace.repairBusy).accessibilityIdentifier("develop.repair.ai.setup")
            if showsModelSetup {
                if let modelName = workspace.repairAIModelName {
                    Text(modelName).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                if workspace.repairAISetupProgress == nil && !workspace.repairAIReady {
                    Button("LaMa herunterladen (ca. 217 MB)") { workspace.downloadRepairAIModel() }
                        .disabled(!ready).accessibilityIdentifier("develop.repair.ai.download")
                }
                Button("Lokales Modell importieren …") { importsModel = true }
                    .disabled(!ready).accessibilityIdentifier("develop.repair.ai.import")
                Link("Modellquelle und Lizenzangaben", destination: DevelopRepairAIApprovedDownload.modelCard)
            }
            if let progress = workspace.repairAISetupProgress {
                Group {
                    if let fraction = progress.fraction { ProgressView(value: fraction) }
                    else { ProgressView().controlSize(.small) }
                }.accessibilityIdentifier("develop.repair.ai.progress")
                Text(progress.text).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var redEyeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pupille im Bild mit Ellipse markieren", systemImage: "oval")
                .accessibilityIdentifier("develop.repair.red-eye.selection")
            sliderRow("Stärke", value: $workspace.redEyeStrength, range: 0...1,
                valueText: "\(Int((workspace.redEyeStrength * 100).rounded())) %", identifier: "red-eye.strength", neutral: 1)
            Text(geometry.redEyeCorrections.count == 1 ? "1 Augenkorrektur" : "\(geometry.redEyeCorrections.count) Augenkorrekturen")
                .foregroundStyle(Theme.muted).accessibilityIdentifier("develop.repair.red-eye.count")
            Button("Letzte Augenkorrektur löschen") {
                updateRedEyes { if !$0.redEyeCorrections.isEmpty { $0.redEyeCorrections.removeLast() } }
            }.disabled(!ready || geometry.redEyeCorrections.isEmpty)
                .accessibilityIdentifier("develop.repair.red-eye.remove-last")
            Button("Alle Augenkorrekturen löschen") { updateRedEyes { $0.redEyeCorrections = [] } }
                .disabled(!ready || geometry.redEyeCorrections.isEmpty)
                .accessibilityIdentifier("develop.repair.red-eye.remove-all")
        }
    }

    private var detectionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Störungen erkennen").fontWeight(.semibold)
            HStack(spacing: 8) {
                Button("Personen erkennen") { detect(.people) }
                    .disabled(!ready).accessibilityIdentifier("develop.repair.detect-people")
                Button("Staub erkennen") { detect(.dust) }
                    .disabled(!ready).accessibilityIdentifier("develop.repair.detect-dust")
            }
            if !workspace.repairCandidates.isEmpty {
                Text("Vorschläge auswählen").fontWeight(.semibold)
                ForEach(workspace.repairCandidates) { candidate in
                    Toggle(candidate.label, isOn: Binding(
                        get: { workspace.repairSelectedCandidateIDs.contains(candidate.id) },
                        set: { selected in
                            if selected { workspace.repairSelectedCandidateIDs.insert(candidate.id) }
                            else { workspace.repairSelectedCandidateIDs.remove(candidate.id) }
                        }))
                        .disabled(!ready)
                        .accessibilityIdentifier("develop.repair.candidate." + candidate.id.uuidString)
                }
                Button("Ausgewählte entfernen") {
                    actionTask?.cancel()
                    actionTask = Task { @MainActor in
                        await workspace.removeSelectedRepairCandidates(asset: asset, editor: editor)
                    }
                }.disabled(!ready || workspace.repairSelectedCandidateIDs.isEmpty)
                    .accessibilityIdentifier("develop.repair.remove-selected")
            }
        }
    }

    private var repairHelp: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reparieren").font(.system(size: 17, weight: .semibold))
            Text("Entfernen und Heilen suchen eine passende Quelle. Mit ⌥-Klick wählen Sie selbst eine saubere Bildstelle. Beim Kopierstempel wählt auch der erste Klick die Quelle; anschließend malen Sie über das Ziel.")
            Text("Markierungen zeigen die offene Quelle und das ausgefüllte Ziel. Klicken Sie eine Reparatur an, um sie auszuwählen. Ziehen Sie Quelle oder Ziel zum Verschieben; die Löschtaste entfernt die Auswahl.")
            Text("Bei Rote Augen ziehen Sie eine Ellipse um die Pupille. Stärke gilt für die nächste Augenkorrektur.")
            Text("Personen und Staub erkennen erzeugt nur Vorschläge. Erst Ausgewählte entfernen verändert das Foto. Jeder verarbeitete Pinselzug wird dagegen sofort aktiv. ⌘Z nimmt jede Reparatur zurück.")
            Text("LaMa ergänzt kleine ausgewählte Stellen lokal. Prüfen Sie das Ergebnis im Bild. Die Ausgabe ist auf die sRGB-Vorschau mit 8 Bit begrenzt; große Auswahlen und HDR werden abgewiesen. LaMa ist nicht für Hintergrundersatz, Bildgenerierung oder Erweiterung freigegeben. Spiegelungsentfernung ist nicht verfügbar.")
            HStack { Spacer(); Button("Hilfe schließen") { showsHelp = false }.keyboardShortcut(.cancelAction) }
        }.font(.system(size: 13)).foregroundStyle(Theme.text).padding(24).frame(width: 500)
    }

    @ViewBuilder private func modeSymbol(_ mode: DevelopRepairMode) -> some View {
        switch mode {
        case .remove: Image(systemName: "eraser.fill")
        case .heal: Image(systemName: "bandage.fill")
        case .clone: RepairStampSymbol().stroke(lineWidth: 1.4).frame(width: 16, height: 18)
        case .redEye: Image(systemName: "eye")
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           valueText: String, identifier: String, neutral: Double) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 82, alignment: .leading)
            ResettableSlider(value: value, in: range, neutralValue: neutral).accessibilityLabel(title)
                .accessibilityIdentifier("develop.repair." + identifier)
            Text(valueText).monospacedDigit().frame(width: 46, alignment: .trailing)
        }.disabled(!ready)
    }

    private func updateRedEyes(_ change: (inout DevelopGeometry) -> Void) {
        guard ready else { return }
        editor.endEditing(assetID: asset.id)
        var settings = editor.settings(for: asset.id)
        change(&settings.developGeometry)
        settings = settings.normalized
        do {
            _ = try EditingSnapshot(settings: settings)
            editor.setSettings(settings, for: asset.id)
            workspace.errorMessage = nil
        } catch { workspace.errorMessage = error.localizedDescription }
    }

    private func detect(_ kind: DevelopRepairDetectionKind) {
        actionTask?.cancel()
        actionTask = Task { @MainActor in await workspace.detectRepairCandidates(kind) }
    }

    private func cancelWork() {
        actionTask?.cancel()
        workspace.cancelRepairWork(clearCandidates: false)
    }

    private func removeLastStroke() {
        guard ready, let last = strokes.last else { return }
        workspace.removeRepair(id: last.id, asset: asset, editor: editor)
    }
}

/// The established SF Symbols set has no rubber stamp glyph. A small vector
/// keeps this tool recognizable without shipping a bitmap or using a brush.
private struct RepairStampSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.08, y: rect.height * 0.96))
        path.addLine(to: CGPoint(x: rect.width * 0.92, y: rect.height * 0.96))
        path.addLine(to: CGPoint(x: rect.width * 0.92, y: rect.height * 0.72))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.63, y: rect.height * 0.57),
            control: CGPoint(x: rect.width * 0.90, y: rect.height * 0.59))
        path.addLine(to: CGPoint(x: rect.width * 0.61, y: rect.height * 0.40))
        path.addCurve(to: CGPoint(x: rect.width * 0.39, y: rect.height * 0.40),
            control1: CGPoint(x: rect.width * 0.95, y: 0), control2: CGPoint(x: rect.width * 0.05, y: 0))
        path.addLine(to: CGPoint(x: rect.width * 0.37, y: rect.height * 0.57))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.08, y: rect.height * 0.72),
            control: CGPoint(x: rect.width * 0.10, y: rect.height * 0.59))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.width * 0.09, y: rect.height * 0.81))
        path.addLine(to: CGPoint(x: rect.width * 0.91, y: rect.height * 0.81))
        return path
    }
}
