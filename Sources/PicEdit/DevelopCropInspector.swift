import SwiftUI
import PicEditCore

/// Short UI actions stay ordered with the editor's undo transaction. Horizon
/// detection uses the workspace's bounded background worker and decoded source.
struct DevelopCropInspector: View {
    let asset: PhotoAsset
    @ObservedObject var workspace: DevelopWorkspace
    @EnvironmentObject private var editor: EditingModel
    @ViewState private var autoTask: Task<Void, Never>?

    private var geometry: DevelopGeometry { editor.settings(for: asset.id).developGeometry }
    private var sourceSize: CGSize {
        workspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Werkzeug:").foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Text("Freistellen und gerade ausrichten").fontWeight(.semibold).multilineTextAlignment(.trailing)
            }.padding(.vertical, 10)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "crop").font(.system(size: 19)).frame(width: 25)
                Picker("Seitenverhältnis", selection: Binding(get: { workspace.cropAspect }, set: selectAspect)) {
                    Text("Frei").tag("free"); Text("Original").tag("original")
                    Text("1 : 1").tag("1:1"); Text("3 : 2").tag("3:2"); Text("4 : 3").tag("4:3")
                    Text("16 : 9").tag("16:9"); Text("2 : 3").tag("2:3")
                }.accessibilityIdentifier("develop.crop.aspect")
                Button(action: toggleLock) {
                    Image(systemName: workspace.cropAspectLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 17)).frame(width: 24, height: 26)
                }.buttonStyle(.plain)
                    .help("Seitenverhältnis beim Ziehen beibehalten")
                    .accessibilityLabel("Seitenverhältnis sperren")
                    .accessibilityValue(workspace.cropAspectLocked ? "Gesperrt" : "Entsperrt")
                    .accessibilityIdentifier("develop.crop.lock")
            }.padding(.vertical, 12).disabled(!editor.canEdit)
            Divider()
            VStack(spacing: 7) {
                HStack {
                    Spacer()
                    Button(workspace.isAutoStraightening ? "Ermitteln …" : "Auto", action: straightenAutomatically)
                        .buttonStyle(.bordered).controlSize(.mini)
                        .disabled(workspace.isAutoStraightening || !workspace.isOriginalCanvasReady)
                        .help("Erkannten Horizont automatisch waagerecht ausrichten")
                        .accessibilityIdentifier("develop.crop.auto")
                }
                HStack(spacing: 6) {
                    Image(systemName: "level").font(.system(size: 18)).frame(width: 25)
                    Text("Winkel")
                    ResettableSlider(value: Binding(get: { geometry.straightenAngle }, set: { angle in
                        autoTask?.cancel()
                        update(atomic: false) { $0.straightenAngle = angle }
                    }), in: -45...45, step: 0.01, onEditingChanged: { editing in
                        if editing { editor.endEditing(assetID: asset.id); editor.beginEditing(assetID: asset.id) }
                        else { editor.endEditing(assetID: asset.id) }
                    }).accessibilityLabel("Winkel").accessibilityIdentifier("develop.crop.angle")
                    Text(geometry.straightenAngle, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }.padding(.vertical, 10).disabled(!editor.canEdit)
            Divider()
            Toggle("Auf Bild beschränken", isOn: Binding(get: { geometry.constrainToImage }, set: { flag in
                update { $0.constrainToImage = flag }
            })).toggleStyle(.checkbox).padding(.vertical, 10)
                .help("Beim Ausrichten leere Ränder durch einen mittigen Zuschnitt vermeiden")
                .accessibilityIdentifier("develop.crop.constrain").disabled(!editor.canEdit)
            Divider()
            Picker("Werkzeugüberlagerung", selection: $workspace.cropOverlay) {
                ForEach(DevelopCropOverlay.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }.padding(.vertical, 10).accessibilityIdentifier("develop.crop.overlay")
                .help("Drittelraster anzeigen; Rahmen und acht Griffe bleiben bedienbar")
            Divider()
            HStack(spacing: 8) {
                orientationButton("rotate.left", title: "90° nach links drehen") { $0.quarterTurns = ($0.quarterTurns + 3) % 4 }
                orientationButton("rotate.right", title: "90° nach rechts drehen") { $0.quarterTurns = ($0.quarterTurns + 1) % 4 }
                orientationButton("arrow.left.and.right.righttriangle.left.righttriangle.right", title: "Horizontal spiegeln") { $0.flipHorizontal.toggle() }
                orientationButton("arrow.up.and.down.righttriangle.up.righttriangle.down", title: "Vertikal spiegeln") { $0.flipVertical.toggle() }
                Spacer(minLength: 0)
            }.padding(.vertical, 8).disabled(!editor.canEdit)
            Text("Eck- oder Seitengriff ziehen · ⌘-Ziehen verschiebt. Außerhalb der Griffe einen neuen Rahmen aufziehen.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text("Ausrichtung mit Schließen anzeigen.").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 4)
            if let error = workspace.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.top, 6)
            }
            Divider().padding(.top, 10)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Zurücksetzen") {
                    workspace.cropAspect = "free"; workspace.cropAspectLocked = false; workspace.lockedCropRatio = nil
                    update {
                        $0.crop = nil; $0.quarterTurns = 0; $0.straightenAngle = 0; $0.constrainToImage = true
                        $0.flipHorizontal = false; $0.flipVertical = false
                    }
                }.disabled(!editor.canEdit).accessibilityIdentifier("develop.crop.reset")
                Divider().frame(height: 14)
                Button("Schließen") {
                    autoTask?.cancel(); editor.endEditing(assetID: asset.id); workspace.tool = .basic
                }.accessibilityIdentifier("develop.crop.close")
            }.buttonStyle(.plain).padding(.vertical, 10)
        }.font(.system(size: 11)).foregroundStyle(Theme.text)
            .onAppear { reconcileAspect() }
            .onDisappear { autoTask?.cancel(); editor.endEditing(assetID: asset.id) }
            .onChange(of: workspace.sourceIdentity) { _, _ in autoTask?.cancel() }
            .onChange(of: geometry.crop) { _, _ in reconcileAspect() }
            .onChange(of: sourceSize) { _, _ in reconcileAspect() }
    }

    private func orientationButton(_ symbol: String, title: String, change: @escaping (inout DevelopGeometry) -> Void) -> some View {
        Button { update(change: change) } label: { Image(systemName: symbol).frame(width: 25, height: 20) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func selectAspect(_ aspect: String) {
        workspace.cropAspect = aspect
        workspace.cropAspectLocked = aspect != "free"
        workspace.lockedCropRatio = nil
        guard aspect != "free" else { return }
        let ratio = workspace.cropRatio(source: sourceSize) / (sourceSize.width / sourceSize.height)
        let crop = geometry.crop
        let oldWidth = crop?.width ?? 1, oldHeight = crop?.height ?? 1
        let width = min(oldWidth, oldHeight * ratio), height = width / ratio
        update { $0.crop = try? DevelopCropRect(x: (crop?.x ?? 0) + (oldWidth - width) / 2,
            y: (crop?.y ?? 0) + (oldHeight - height) / 2, width: width, height: height) }
    }

    private func toggleLock() {
        workspace.cropAspectLocked.toggle()
        if workspace.cropAspectLocked {
            let crop = geometry.crop
            workspace.lockedCropRatio = (crop?.width ?? 1) * sourceSize.width / ((crop?.height ?? 1) * sourceSize.height)
            // Re-locking after free resizing freezes the current rectangle.
            workspace.cropAspect = "free"
        } else { workspace.lockedCropRatio = nil }
    }

    private func reconcileAspect() {
        guard workspace.cropAspectLocked else { return }
        let crop = geometry.crop
        let actual = (crop?.width ?? 1) * sourceSize.width / ((crop?.height ?? 1) * sourceSize.height)
        let expected = workspace.cropAspect == "free" ? workspace.lockedCropRatio : workspace.cropRatio(source: sourceSize)
        // Undo or a restored snapshot can replace the crop independently of the
        // palette. Keep its current ratio instead of snapping on the next drag.
        if expected.map({ abs(actual / $0 - 1) > 0.000_001 }) ?? true {
            workspace.cropAspect = "free"
            workspace.lockedCropRatio = actual
        }
    }

    private func straightenAutomatically() {
        autoTask?.cancel()
        let baseline = geometry, source = workspace.sourceIdentity
        let revision = editor.localRevision(for: asset.id), session = editor.aiEditSessionID
        autoTask = Task { @MainActor in
            guard let angle = await workspace.autoStraighten(), !Task.isCancelled,
                  workspace.sourceIdentity == source, workspace.tool == .crop,
                  editor.localRevision(for: asset.id) == revision, editor.aiEditSessionID == session,
                  geometry == baseline, editor.canEdit else { return }
            update { $0.straightenAngle = angle }
        }
    }

    private func update(atomic: Bool = true, change: (inout DevelopGeometry) -> Void) {
        guard editor.canEdit else { return }
        if atomic { autoTask?.cancel(); editor.endEditing(assetID: asset.id) }
        var settings = editor.settings(for: asset.id)
        change(&settings.developGeometry)
        do {
            _ = try EditingSnapshot(settings: settings.normalized)
            editor.setSettings(settings, for: asset.id); workspace.errorMessage = nil
        } catch { workspace.errorMessage = error.localizedDescription }
    }
}
