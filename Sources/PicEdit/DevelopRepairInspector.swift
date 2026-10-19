import SwiftUI
import UniformTypeIdentifiers
import PicEditCore

enum DevelopRepairMode: String, CaseIterable, Identifiable, Sendable {
    case remove, heal, clone
    var id: Self { self }
    var retouchMode: DevelopRetouchMode { self == .clone ? .clone : .heal }
    var title: String {
        switch self {
        case .remove: "Entfernen"
        case .heal: "Heilen"
        case .clone: "Kopierstempel"
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

    private var ready: Bool { editor.canEdit && workspace.isOriginalCanvasReady && !workspace.repairBusy && workspace.repairPreviewStroke == nil }
    private var strokes: [DevelopRetouchStroke] { editor.settings(for: asset.id).developGeometry.retouchStrokes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Entfernen").fontWeight(.semibold)
                Spacer(minLength: 0)
                if workspace.repairBusy {
                    ProgressView().controlSize(.mini).accessibilityLabel("Reparatur wird verarbeitet")
                    Button("Abbrechen") { actionTask?.cancel(); workspace.cancelRepairWork(clearCandidates: false) }
                        .controlSize(.mini).accessibilityIdentifier("develop.repair.cancel")
                }
            }.padding(.vertical, 10)
            Divider()
            mainControls
            if workspace.repairPreviewStroke != nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Lokale KI-Vorschau").fontWeight(.semibold)
                    Text("Ergebnis im Bild prüfen. Erst Übernehmen speichert die Reparatur.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Verwerfen") { workspace.discardRepairPreview() }.accessibilityIdentifier("develop.repair.ai.discard")
                        Spacer(minLength: 0)
                        Button("Übernehmen") { workspace.acceptRepairPreview(asset: asset, editor: editor) }
                            .disabled(!editor.canEdit).accessibilityIdentifier("develop.repair.ai.accept")
                    }.controlSize(.small)
                }.padding(.vertical, 10)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Zurücksetzen") {
                    actionTask?.cancel()
                    workspace.resetRepairs(asset: asset, editor: editor)
                }.disabled(!ready).accessibilityIdentifier("develop.repair.reset")
                Divider().frame(height: 14)
                Button("Schließen") {
                    actionTask?.cancel()
                    editor.endEditing(assetID: asset.id)
                    workspace.closeRepair()
                }.accessibilityIdentifier("develop.repair.close")
            }.buttonStyle(.plain).padding(.vertical, 10)
            Divider()
            detectionControls
            if let error = workspace.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6).accessibilityIdentifier("develop.repair.error")
            }
        }.font(.system(size: 11)).foregroundStyle(Theme.text)
            .onDisappear { actionTask?.cancel(); editor.endEditing(assetID: asset.id) }
            .task { await workspace.refreshRepairAIAvailability() }
            .fileImporter(isPresented: $importsModel, allowedContentTypes: [.folder, UTType(filenameExtension: "mlpackage") ?? .folder]) { result in
                guard case .success(let url) = result else { return }
                actionTask = Task {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    await workspace.importRepairAIModel(from: url)
                }
            }
    }

    private var mainControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Modus:").foregroundStyle(Theme.muted)
                ForEach(DevelopRepairMode.allCases) { mode in
                    Button {
                        editor.endEditing(assetID: asset.id)
                        workspace.cancelRepairWork()
                        workspace.repairMode = mode
                        workspace.repairSource = nil
                    } label: {
                        modeSymbol(mode).frame(width: 29, height: 27)
                            .foregroundStyle(workspace.repairMode == mode ? Theme.accent : Theme.muted)
                            .background(workspace.repairMode == mode ? Theme.elevated : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).help(mode.title).accessibilityLabel(mode.title)
                        .accessibilityValue(workspace.repairMode == mode ? "Ausgewählt" : "Nicht ausgewählt")
                        .accessibilityIdentifier("develop.repair.mode." + mode.rawValue)
                }
                Spacer(minLength: 0)
            }.disabled(!ready)
            Text(modeHelp).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("develop.repair.instructions")
            sliderRow("Größe", value: $workspace.repairRadius, range: 0.005...0.15,
                valueText: "\(Int((workspace.repairRadius * 1000).rounded()))", identifier: "size", neutral: 0.035)
            if workspace.repairMode != .remove {
                sliderRow("Weiche Kante", value: $workspace.repairFeather, range: 0...1,
                    valueText: "\(Int((workspace.repairFeather * 100).rounded()))", identifier: "feather", neutral: 0.5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Lokale KI", isOn: $workspace.repairUsesAI)
                    .disabled(!ready || !workspace.repairAIReady || workspace.repairMode != .remove)
                    .accessibilityIdentifier("develop.repair.generative")
                Text(workspace.repairAIModelName.map { "\($0) · lokal · Ergebnis vor dem Speichern prüfen" }
                     ?? "Kompatibles LaMa-Modell importieren, um kleine Bereiche lokal zu ergänzen.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Lokales Modell importieren …") { importsModel = true }
                    .controlSize(.mini).disabled(!ready).accessibilityIdentifier("develop.repair.ai.import")
            }
            Toggle("Objekte erkennen", isOn: $workspace.repairObjectDetection)
                .disabled(!ready || workspace.repairMode != .remove)
                .help("Das markierte Vordergrundobjekt erkennen und dessen Auswahl verwenden")
                .accessibilityIdentifier("develop.repair.objects")
            if workspace.repairMode != .remove {
                Button("Neue Quelle wählen") {
                    editor.endEditing(assetID: asset.id)
                    workspace.cancelRepairWork(clearCandidates: false)
                    workspace.repairSource = nil
                }.controlSize(.small).disabled(!ready)
                    .accessibilityIdentifier("develop.repair.choose-source")
            }
            if !strokes.isEmpty {
                Button("Letzte Reparatur entfernen", action: removeLastStroke)
                    .controlSize(.small).disabled(!ready)
                    .accessibilityIdentifier("develop.repair.remove-last")
            }
            Divider()
            Picker("Werkzeugüberlagerung", selection: $workspace.repairOverlay) {
                ForEach(DevelopRepairOverlay.allCases) { overlay in Text(overlay.title).tag(overlay) }
            }.disabled(!ready).accessibilityIdentifier("develop.repair.overlay")
            Toggle("Bereiche anzeigen", isOn: $workspace.repairVisualizesSpots)
                .disabled(!ready).help("Kontrastreiche Flecken für die Staubsichtung hervorheben")
                .accessibilityIdentifier("develop.repair.visualize-spots")
            sliderRow("Empfindlichkeit", value: $workspace.repairSpotThreshold, range: 0...1,
                valueText: "\(Int((workspace.repairSpotThreshold * 100).rounded()))", identifier: "threshold",
                neutral: 0.5, enabled: workspace.repairVisualizesSpots)
        }.padding(.vertical, 10)
    }

    private var detectionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Störende Elemente entfernen").fontWeight(.semibold).padding(.top, 10)
            HStack {
                Text("Spiegelungen").foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Button("Erkennen") {}.controlSize(.mini).disabled(true)
                    .accessibilityIdentifier("develop.repair.detect-reflections")
            }
            Text("Das lokale Reparaturmodell trennt keine Spiegelungen. Diese Funktion ist nicht verfügbar.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("Personen")
                Spacer(minLength: 0)
                Button("Erkennen") { detect(.people) }.controlSize(.mini).disabled(!ready)
                    .accessibilityLabel("Personen erkennen").accessibilityIdentifier("develop.repair.detect-people")
            }
            HStack {
                Text("Staub")
                Spacer(minLength: 0)
                Button("Erkennen") { detect(.dust) }.controlSize(.mini).disabled(!ready)
                    .accessibilityLabel("Staub erkennen").accessibilityIdentifier("develop.repair.detect-dust")
            }
            if let status = workspace.repairStatus {
                Text(status).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("develop.repair.status")
            }
            if !workspace.repairCandidates.isEmpty {
                Divider()
                Text("Vorschläge prüfen und auswählen").foregroundStyle(Theme.muted)
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
                }.controlSize(.small).disabled(!ready || workspace.repairSelectedCandidateIDs.isEmpty)
                    .accessibilityIdentifier("develop.repair.remove-selected")
            }
        }.padding(.bottom, 10)
    }

    private var modeHelp: String {
        switch workspace.repairMode {
        case .remove: workspace.repairUsesAI
            ? "Über einen kleinen störenden Bereich malen. Die lokale KI erstellt eine Vorschau zum Prüfen."
            : "Über den störenden Bereich malen. Eine passende Quelle wird automatisch gewählt."
        case .heal: workspace.repairSource == nil
            ? "Zu heilende Stelle übermalen. Die Quelle wird automatisch gewählt; ⌥-Klick setzt eine eigene Quelle."
            : "Zu heilende Stelle übermalen. ⌥-Klick wählt eine neue Quelle; Farbe und Helligkeit werden angepasst."
        case .clone: workspace.repairSource == nil
            ? "Zuerst den zu kopierenden Quellbereich anklicken, dann über die Zielstelle malen."
            : "Über die Zielstelle malen. ⌥-Klick wählt eine neue Quelle."
        }
    }

    @ViewBuilder private func modeSymbol(_ mode: DevelopRepairMode) -> some View {
        switch mode {
        case .remove: Image(systemName: "eraser.fill").font(.system(size: 19))
        case .heal: Image(systemName: "bandage.fill").font(.system(size: 19))
        case .clone: RepairStampSymbol().stroke(lineWidth: 1.6).frame(width: 19, height: 21)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           valueText: String, identifier: String, neutral: Double, enabled: Bool = true) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 82, alignment: .leading)
            ResettableSlider(value: value, in: range, neutralValue: neutral).accessibilityLabel(title)
                .accessibilityIdentifier("develop.repair." + identifier)
            Text(valueText).monospacedDigit().frame(width: 24, alignment: .trailing)
        }.disabled(!ready || !enabled)
    }

    private func detect(_ kind: DevelopRepairDetectionKind) {
        actionTask?.cancel()
        actionTask = Task { @MainActor in await workspace.detectRepairCandidates(kind) }
    }

    private func removeLastStroke() {
        guard ready, !strokes.isEmpty else { return }
        editor.endEditing(assetID: asset.id)
        var settings = editor.settings(for: asset.id)
        settings.developGeometry.retouchStrokes.removeLast()
        editor.setSettings(settings, for: asset.id)
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
