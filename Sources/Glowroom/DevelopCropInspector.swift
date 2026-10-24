import SwiftUI
import GlowroomCore

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
            Text("Zuschneiden").font(.system(size: 15, weight: .semibold)).padding(.vertical, 10)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "crop").font(.system(size: 19)).frame(width: 25)
                Picker("Seitenverhältnis", selection: Binding(get: { workspace.cropAspect }, set: selectAspect)) {
                    Text("Frei").tag("free"); Text("Original").tag("original")
                    Text("1 : 1").tag("1:1"); Text("3 : 2").tag("3:2"); Text("4 : 3").tag("4:3")
                    Text("16 : 9").tag("16:9"); Text("2 : 3").tag("2:3")
                }.accessibilityIdentifier("develop.crop.aspect")
            }.padding(.vertical, 12).disabled(!editor.canEdit)
            Button(action: toggleLock) {
                Label(workspace.cropAspectLocked ? "Seitenverhältnis gesperrt" : "Seitenverhältnis sperren",
                    systemImage: workspace.cropAspectLocked ? "lock.fill" : "lock.open")
            }.buttonStyle(.plain).padding(.bottom, 12).disabled(!editor.canEdit)
                .accessibilityLabel("Seitenverhältnis sperren")
                .accessibilityValue(workspace.cropAspectLocked ? "Gesperrt" : "Entsperrt")
                .accessibilityIdentifier("develop.crop.lock")
            Divider()
            VStack(spacing: 7) {
                HStack {
                    Spacer()
                    Button(workspace.isAutoStraightening ? "Horizont wird ermittelt …" : "Automatisch ausrichten", action: straightenAutomatically)
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(workspace.isAutoStraightening || !workspace.isOriginalCanvasReady)
                        .help("Erkannten Horizont automatisch waagerecht ausrichten")
                        .accessibilityIdentifier("develop.crop.auto")
                }
                Button {
                        autoTask?.cancel()
                        editor.endEditing(assetID: asset.id)
                        workspace.isStraightening.toggle()
                    } label: {
                        Label(workspace.isStraightening ? "Gerade ausrichten · aktiv" : "Gerade ausrichten",
                            systemImage: workspace.isStraightening ? "checkmark.circle.fill" : "level")
                    }.buttonStyle(.plain)
                        .help("Eine waagerechte oder senkrechte Bezugslinie im Bild ziehen")
                        .accessibilityLabel("Gerade ausrichten")
                        .accessibilityValue(workspace.isStraightening ? "Aktiv" : "Inaktiv")
                        .accessibilityIdentifier("develop.crop.straighten")
                HStack(spacing: 6) {
                    Text("Winkel")
                    ResettableSlider(value: Binding(get: { geometry.straightenAngle }, set: { angle in
                        autoTask?.cancel()
                        update(atomic: false) { $0.straightenAngle = angle }
                    }), in: -45...45, step: 0.01, onEditingChanged: { editing in
                        if editing { editor.endEditing(assetID: asset.id); editor.beginEditing(assetID: asset.id) }
                        else { editor.endEditing(assetID: asset.id) }
                    }).accessibilityLabel("Winkel").accessibilityIdentifier("develop.crop.angle")
                    Text("\(geometry.straightenAngle, format: .number.precision(.fractionLength(2)))°")
                        .monospacedDigit().frame(width: 60, alignment: .trailing)
                }
            }.padding(.vertical, 10).disabled(!editor.canEdit)
            Divider()
            if let error = workspace.errorMessage {
                Text(error).font(.system(size: 13)).foregroundStyle(.orange).padding(.top, 6)
            }
            Divider().padding(.top, 10)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Zurücksetzen") {
                    workspace.cropAspect = "free"; workspace.cropAspectLocked = false; workspace.lockedCropRatio = nil
                    workspace.isStraightening = false
                    update {
                        $0.crop = nil; $0.quarterTurns = 0; $0.straightenAngle = 0; $0.constrainToImage = true
                        $0.flipHorizontal = false; $0.flipVertical = false
                    }
                }.disabled(!editor.canEdit).accessibilityIdentifier("develop.crop.reset")
                Divider().frame(height: 14)
                Button("Schließen") {
                    autoTask?.cancel(); editor.endEditing(assetID: asset.id)
                    workspace.isStraightening = false; workspace.tool = .basic
                }.accessibilityIdentifier("develop.crop.close")
            }.buttonStyle(.plain).padding(.vertical, 10)
        }.font(.system(size: 13)).foregroundStyle(Theme.text)
            .onAppear { reconcileAspect() }
            .onDisappear { autoTask?.cancel(); workspace.isStraightening = false; editor.endEditing(assetID: asset.id) }
            .onChange(of: workspace.sourceIdentity) { _, _ in autoTask?.cancel() }
            .onChange(of: geometry.crop) { _, _ in reconcileAspect() }
            .onChange(of: sourceSize) { _, _ in reconcileAspect() }
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
