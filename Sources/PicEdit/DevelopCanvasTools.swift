import SwiftUI
import PicEditCore

struct DevelopGeometryInspector: View {
    let asset: PhotoAsset
    @ObservedObject var workspace: DevelopWorkspace
    @EnvironmentObject private var editor: EditingModel
    private var geometry: DevelopGeometry { editor.settings(for: asset.id).developGeometry }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(workspace.tool.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Fertig") { workspace.tool = .basic }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            Text("Unbeschnittene Quelle · Änderungen werden nicht destruktiv gespeichert.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            switch workspace.tool {
            case .crop: cropControls
            case .repair: repairControls
            case .redEye: redEyeControls
            default: EmptyView()
            }
            if let error = workspace.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 8)
    }
    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ziehe einen Rahmen auf dem Bild. Ziehe einen Eckpunkt für die Größe; ⌘-Ziehen verschiebt den Rahmen.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            Picker("Seitenverhältnis", selection: Binding(get: { workspace.cropAspect }, set: { aspect in
                workspace.cropAspect = aspect
                guard aspect != "free" else { return }
                let source = workspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight))
                let ratio = workspace.cropRatio(source: source)
                let normalized = ratio / (source.width / source.height)
                let width = min(1, normalized), height = min(1, 1 / normalized)
                update { $0.crop = try? DevelopCropRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height) }
            })) {
                Text("Frei").tag("free"); Text("Original").tag("original")
                Text("1 : 1").tag("1:1"); Text("3 : 2").tag("3:2"); Text("4 : 3").tag("4:3")
                Text("16 : 9").tag("16:9"); Text("2 : 3").tag("2:3")
            }.font(.system(size: 11))
            HStack {
                Button { update { $0.quarterTurns = ($0.quarterTurns + 3) % 4 } } label: { Label("Links", systemImage: "rotate.left") }
                Button { update { $0.quarterTurns = ($0.quarterTurns + 1) % 4 } } label: { Label("Rechts", systemImage: "rotate.right") }
            }.controlSize(.small)
            Toggle("Horizontal spiegeln", isOn: Binding(get: { geometry.flipHorizontal }, set: { flag in update { $0.flipHorizontal = flag } }))
            Toggle("Vertikal spiegeln", isOn: Binding(get: { geometry.flipVertical }, set: { flag in update { $0.flipVertical = flag } }))
            Text("Drehung: \(geometry.quarterTurns * 90)° · Ergebnis mit Fertig anzeigen")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            Button("Zuschnitt und Ausrichtung zurücksetzen") {
                workspace.cropAspect = "free"
                update { $0.crop = nil; $0.quarterTurns = 0; $0.flipHorizontal = false; $0.flipVertical = false }
            }.controlSize(.small)
        }.font(.system(size: 11))
    }
    private var repairControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Modus", selection: $workspace.repairMode) {
                Text("Reparieren").tag(DevelopRetouchMode.heal)
                Text("Kopierstempel").tag(DevelopRetouchMode.clone)
            }.pickerStyle(.segmented)
            Text(workspace.repairSource == nil ? "Klicke zuerst auf einen sauberen Quellbereich." : "Klicke oder male über den zu korrigierenden Bereich. ⌥-Klick wählt eine neue Quelle.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            toolSlider("Radius", value: $workspace.repairRadius, range: 0.005...0.15, neutral: 0.035)
            toolSlider("Weiche Kante", value: $workspace.repairFeather, range: 0...1, neutral: 0.5)
            Button("Neue Quelle wählen") { workspace.repairSource = nil }.controlSize(.small)
            Text("\(geometry.retouchStrokes.count) Korrekturstellen · Reparieren passt die Quellfarbe an die Umgebung an.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            HStack {
                Button("Letzte entfernen") { update { if !$0.retouchStrokes.isEmpty { $0.retouchStrokes.removeLast() } } }
                Button("Alle löschen") { update { $0.retouchStrokes = [] } }
            }.controlSize(.small).disabled(geometry.retouchStrokes.isEmpty)
        }
    }
    private var redEyeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ziehe eine Ellipse um die rote Pupille. Nur rotdominante Pixel innerhalb der Auswahl werden abgedunkelt.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            toolSlider("Stärke", value: $workspace.redEyeStrength, range: 0...1, neutral: 1)
            Text("\(geometry.redEyeCorrections.count) Augenkorrekturen")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            HStack {
                Button("Letzte entfernen") { update { if !$0.redEyeCorrections.isEmpty { $0.redEyeCorrections.removeLast() } } }
                Button("Alle löschen") { update { $0.redEyeCorrections = [] } }
            }.controlSize(.small).disabled(geometry.redEyeCorrections.isEmpty)
        }
    }
    private func toolSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue * 100)) %").monospacedDigit() }.font(.system(size: 10))
            ResettableSlider(value: value, in: range, neutralValue: neutral).accessibilityLabel(title)
        }
    }
    private func update(_ change: (inout DevelopGeometry) -> Void) {
        editor.endEditing(assetID: asset.id)
        var settings = editor.settings(for: asset.id); change(&settings.developGeometry)
        settings = settings.normalized
        do { _ = try EditingSnapshot(settings: settings); editor.setSettings(settings, for: asset.id); workspace.errorMessage = nil }
        catch { workspace.errorMessage = error.localizedDescription }
    }
}

struct DevelopCanvasInteraction: View {
    let asset: PhotoAsset
    @ObservedObject var workspace: DevelopWorkspace
    @EnvironmentObject private var editor: EditingModel
    @ViewState private var start: CGPoint?
    @ViewState private var current: CGPoint?
    @ViewState private var originalCrop: DevelopCropRect?
    @ViewState private var movingCrop = false
    @ViewState private var lastRepairPoint: CGPoint?
    @ViewState private var repairTargetStart: CGPoint?
    private var sourceSize: CGSize { workspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight)) }
    private var geometry: DevelopGeometry { editor.settings(for: asset.id).developGeometry }
    var body: some View {
        GeometryReader { viewport in
            let rect = imageRect(viewport.size)
            ZStack(alignment: .topLeading) {
                if workspace.tool == .crop {
                    cropOutline(rect)
                } else if workspace.tool == .repair, let source = workspace.repairSource {
                    let point = CGPoint(x: rect.minX + source.x * rect.width, y: rect.minY + source.y * rect.height)
                    Circle().stroke(Theme.accent, lineWidth: 1.5)
                        .frame(width: radius(rect) * 2, height: radius(rect) * 2)
                        .position(point).allowsHitTesting(false)
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Theme.accent).position(point).allowsHitTesting(false)
                } else if workspace.tool == .redEye, let start, let current {
                    Ellipse().stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .frame(width: abs(current.x - start.x) * rect.width, height: abs(current.y - start.y) * rect.height)
                        .position(x: rect.minX + (current.x + start.x) / 2 * rect.width, y: rect.minY + (current.y + start.y) / 2 * rect.height)
                        .allowsHitTesting(false)
                }
                if workspace.tool != .basic || workspace.picksWhiteBalance {
                    Color.clear.contentShape(Rectangle()).gesture(drag(rect))
                        .accessibilityLabel(workspace.picksWhiteBalance ? "Neutrale Fläche für Weißabgleich wählen" : workspace.tool.title + " auf dem Bild")
                        .accessibilityIdentifier("develop.interactive-canvas")
                }
            }
            .onChange(of: viewport.size) { _, _ in finishGesture() }
        }.allowsHitTesting(workspace.isOriginalCanvasReady && (workspace.tool != .basic || workspace.picksWhiteBalance))
            .onChange(of: workspace.tool) { _, _ in finishGesture() }
            .onChange(of: asset.id) { _, _ in finishGesture() }
            .onDisappear { finishGesture() }
    }
    private func imageRect(_ viewport: CGSize) -> CGRect {
        let scale = min(viewport.width / sourceSize.width, viewport.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2, width: size.width, height: size.height)
    }
    private func radius(_ rect: CGRect) -> Double { workspace.repairRadius * min(rect.width, rect.height) }
    private func normalized(_ point: CGPoint, rect: CGRect, clamp: Bool = false) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func cropOutline(_ rect: CGRect) -> some View {
        let crop = geometry.crop
        let box = CGRect(x: rect.minX + (crop?.x ?? 0) * rect.width, y: rect.minY + (crop?.y ?? 0) * rect.height,
                         width: (crop?.width ?? 1) * rect.width, height: (crop?.height ?? 1) * rect.height)
        return Canvas { context, _ in
            var shade = Path(rect); shade.addRect(box)
            context.fill(shade, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            context.stroke(Path(box), with: .color(.white), lineWidth: 1)
            var grid = Path()
            for fraction in [1.0 / 3, 2.0 / 3] {
                grid.move(to: CGPoint(x: box.minX + box.width * fraction, y: box.minY)); grid.addLine(to: CGPoint(x: box.minX + box.width * fraction, y: box.maxY))
                grid.move(to: CGPoint(x: box.minX, y: box.minY + box.height * fraction)); grid.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * fraction))
            }
            context.stroke(grid, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
            for x in [box.minX, box.maxX] { for y in [box.minY, box.maxY] {
                context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.white))
            } }
        }.allowsHitTesting(false)
    }
    private func drag(_ rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            guard editor.canEdit, workspace.isOriginalCanvasReady, let point = normalized(value.location, rect: rect, clamp: start != nil) else { return }
            if start == nil {
                guard let initial = normalized(value.startLocation, rect: rect) else { return }
                start = initial; originalCrop = geometry.crop; current = initial
                movingCrop = NSEvent.modifierFlags.contains(.command)
                editor.endEditing(assetID: asset.id); editor.beginEditing(assetID: asset.id)
                if workspace.tool == .repair {
                    if workspace.repairSource == nil || NSEvent.modifierFlags.contains(.option) {
                        workspace.repairSource = try? LocalMaskPoint(x: initial.x, y: initial.y)
                        repairTargetStart = nil
                    } else { repairTargetStart = initial; addRepair(initial) }
                }
            }
            current = point
            if workspace.picksWhiteBalance { return }
            if workspace.tool == .crop { updateCrop(point) }
            if workspace.tool == .repair, repairTargetStart != nil {
                let distance = lastRepairPoint.map { hypot(($0.x - point.x) * rect.width, ($0.y - point.y) * rect.height) } ?? .infinity
                if distance > radius(rect) * 0.6 { addRepair(point) }
            }
        }.onEnded { value in
            defer { finishGesture() }
            guard let start, let end = normalized(value.location, rect: rect, clamp: true) else { return }
            if workspace.picksWhiteBalance { pickWhiteBalance(end); return }
            if workspace.tool == .redEye {
                let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                do {
                    let correction = try DevelopRedEyeCorrection(center: LocalMaskPoint(x: center.x, y: center.y),
                        radiusX: max(0.005, abs(end.x - start.x) / 2), radiusY: max(0.005, abs(end.y - start.y) / 2), strength: workspace.redEyeStrength)
                    update { $0.redEyeCorrections.append(correction) }
                } catch { workspace.errorMessage = error.localizedDescription }
            }
        }
    }
    private func updateCrop(_ end: CGPoint) {
        guard let start else { return }
        if movingCrop, let crop = originalCrop {
            let x = min(1 - crop.width, max(0, crop.x + end.x - start.x))
            let y = min(1 - crop.height, max(0, crop.y + end.y - start.y))
            update { $0.crop = try? DevelopCropRect(x: x, y: y, width: crop.width, height: crop.height) }
            return
        }
        var anchor = start
        if let crop = originalCrop {
            let nearX = abs(start.x - crop.x) < 0.025 || abs(start.x - crop.x - crop.width) < 0.025
            let nearY = abs(start.y - crop.y) < 0.025 || abs(start.y - crop.y - crop.height) < 0.025
            if nearX && nearY {
                anchor = CGPoint(x: start.x < crop.x + crop.width / 2 ? crop.x + crop.width : crop.x,
                                 y: start.y < crop.y + crop.height / 2 ? crop.y + crop.height : crop.y)
            }
        }
        var width = abs(end.x - anchor.x), height = abs(end.y - anchor.y)
        if workspace.cropAspect != "free" {
            let ratio = workspace.cropRatio(source: sourceSize) / (sourceSize.width / sourceSize.height)
            if width / max(height, 0.00001) > ratio { height = width / ratio } else { width = height * ratio }
            width = min(width, end.x < anchor.x ? anchor.x : 1 - anchor.x)
            height = min(height, end.y < anchor.y ? anchor.y : 1 - anchor.y)
            let edge = min(width, height * ratio); width = edge; height = edge / ratio
        }
        guard width >= 0.005, height >= 0.005 else { return }
        let x = end.x < anchor.x ? anchor.x - width : anchor.x
        let y = end.y < anchor.y ? anchor.y - height : anchor.y
        update { $0.crop = try? DevelopCropRect(x: x, y: y, width: width, height: height) }
    }
    private func addRepair(_ point: CGPoint) {
        guard let source = workspace.repairSource, let targetStart = repairTargetStart else { return }
        let previous = lastRepairPoint ?? point
        let distance = hypot((point.x - previous.x) * sourceSize.width, (point.y - previous.y) * sourceSize.height)
        let spacing = max(1, workspace.repairRadius * min(sourceSize.width, sourceSize.height) * 0.6)
        let available = DevelopGeometry.maximumRetouchStrokes - geometry.retouchStrokes.count
        guard available > 0 else { workspace.errorMessage = "Die Grenze von 256 Korrekturstellen ist erreicht."; return }
        let steps = min(available, max(1, Int(ceil(distance / spacing))))
        do {
            var patches: [DevelopRetouchStroke] = []
            for index in 1...steps {
                let amount = Double(index) / Double(steps)
                let target = CGPoint(x: previous.x + (point.x - previous.x) * amount, y: previous.y + (point.y - previous.y) * amount)
                let sourceX = min(1, max(0, source.x + target.x - targetStart.x))
                let sourceY = min(1, max(0, source.y + target.y - targetStart.y))
                patches.append(try DevelopRetouchStroke(mode: workspace.repairMode,
                    source: LocalMaskPoint(x: sourceX, y: sourceY), target: LocalMaskPoint(x: target.x, y: target.y),
                    radius: workspace.repairRadius, feather: workspace.repairFeather))
            }
            update { $0.retouchStrokes.append(contentsOf: patches) }; lastRepairPoint = point
        } catch { workspace.errorMessage = error.localizedDescription }
    }

    private func pickWhiteBalance(_ point: CGPoint) {
        guard let rgb = workspace.sourceAnalysis?.rgb(at: point),
              let correction = DevelopWhiteBalance.neutralizing(sRGBRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: rgb.3) else {
            workspace.errorMessage = "Wähle eine mittlere, deckende graue Fläche ohne ausgefressene Lichter oder tiefes Schwarz."
            return
        }
        var settings = editor.settings(for: asset.id)
        settings.developColor.temperature = correction.temperature; settings.developColor.tint = correction.tint
        editor.setSettings(settings, for: asset.id)
        workspace.picksWhiteBalance = false
        workspace.errorMessage = correction.isClamped ? "Die Farbkorrektur wurde auf den verfügbaren Reglerbereich begrenzt." : nil
    }
    private func update(_ change: (inout DevelopGeometry) -> Void) {
        var settings = editor.settings(for: asset.id); change(&settings.developGeometry)
        settings = settings.normalized
        do { _ = try EditingSnapshot(settings: settings); editor.setSettings(settings, for: asset.id); workspace.errorMessage = nil }
        catch { workspace.errorMessage = error.localizedDescription }
    }
    private func finishGesture() {
        editor.endEditing(assetID: asset.id)
        start = nil; current = nil; originalCrop = nil; lastRepairPoint = nil; repairTargetStart = nil
    }
}
