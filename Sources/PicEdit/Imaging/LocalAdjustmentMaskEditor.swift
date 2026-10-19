import AppKit
import CoreImage
import SwiftUI
import PicEditCore

/// Transparent interaction layer for the existing main image viewport. The
/// caller gives this exactly the same fitted bounds as the photo below it.
@MainActor
struct InlineMaskCanvas: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    @ViewState private var overlay: CGImage?
    @ViewState private var cursor: CGPoint?
    @ViewState private var gesture: GradientGesture?
    @ViewState private var inputIdentity: InputIdentity?
    @ViewState private var interruptsUntilMouseUp = false
    @GestureState private var pointerIsDown = false
    private struct InputIdentity { let source: AISourceIdentity; let layerID: UUID }
    private struct OverlayIdentity: Hashable {
        let source: AISourceIdentity?
        let canvas: ArtifactPixelSize?
        let mask: LocalAdjustmentMask?
    }
    private enum Handle { case start, end, center, radiusX, radiusY, new }
    private struct GradientGesture {
        let handle: Handle
        let initial: LocalMaskShape
        let start: LocalMaskPoint
    }

    var body: some View {
        GeometryReader { viewport in
            if workspace.isPresented, let canvas = workspace.canvasSize,
               let geometry = try? CanvasGeometry(canvasSize: canvas, viewportWidth: viewport.size.width,
                    viewportHeight: viewport.size.height) {
                ZStack(alignment: .topLeading) {
                    if !workspace.comparesBefore { maskImage(geometry: geometry) }
                    brushCursor(geometry: geometry)
                    Color.clear.contentShape(Rectangle())
                        .gesture(drag(geometry))
                        .onContinuousHover { phase in
                            switch phase { case .active(let point): cursor = point; case .ended: cursor = nil }
                        }
                        .accessibilityLabel("Lokale Maske auf dem Bild zeichnen")
                        .accessibilityIdentifier("local-mask.canvas")
                        .allowsHitTesting(workspace.isCurrent && !workspace.comparesBefore && workspace.model?.isGenerating != true)
                }.clipped()
                    .onChange(of: viewport.size) { _, _ in cancelGesture() }
            }
        }
        .task(id: OverlayIdentity(source: workspace.source, canvas: workspace.canvasSize, mask: workspace.displayMask)) {
            await updateOverlay()
        }
        .onChange(of: workspace.model?.selectedID) { _, _ in cancelGesture() }
        .onChange(of: workspace.refines) { _, _ in cancelGesture() }
        .onChange(of: workspace.comparesBefore) { _, _ in cancelGesture() }
        .onChange(of: workspace.model?.isGenerating) { _, generating in if generating == true { cancelGesture() } }
        .onChange(of: pointerIsDown) { _, down in
            // GestureState also resets when SwiftUI cancels hit testing during
            // inference; the next real pointer down must remain usable.
            if !down { cancelGesture(); interruptsUntilMouseUp = false }
        }
        .onDisappear { cancelGesture() }
    }

    private func maskImage(geometry: CanvasGeometry) -> some View {
        let width = Double(geometry.canvasSize.width) * geometry.scale
        let height = Double(geometry.canvasSize.height) * geometry.scale
        return ZStack {
            if workspace.showsOverlay, let overlay { Color.red.mask { Image(decorative: overlay, scale: 1).resizable() }.opacity(0.45) }
            if !workspace.usesBrush { gradientHandles }
        }.frame(width: width, height: height)
            .position(x: geometry.originX + width / 2, y: geometry.originY + height / 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func brushCursor(geometry: CanvasGeometry) -> some View {
        if workspace.usesBrush, !workspace.comparesBefore, let cursor, let document = workspace.brush.document,
           let point = try? MaskPoint(x: cursor.x, y: cursor.y), geometry.viewToCanvas(point) != nil {
            let diameter = workspace.brush.radius * 2 * geometry.scale * Double(geometry.canvasSize.width) / Double(document.canvasSize.width)
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 1)
                Circle().strokeBorder(.black.opacity(0.7), lineWidth: 1).padding(1)
                Circle().strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(diameter * (1 - workspace.brush.hardness) / 2)
            }.frame(width: diameter, height: diameter).position(cursor).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var gradientHandles: some View {
        Canvas { context, size in
            guard let shape = workspace.selected?.mask.shape else { return }
            func pixel(_ point: LocalMaskPoint) -> CGPoint { CGPoint(x: point.x * size.width, y: point.y * size.height) }
            func dot(_ point: CGPoint, radius: Double = 4) {
                let path = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                context.fill(path, with: .color(.white)); context.stroke(path, with: .color(.black.opacity(0.7)), lineWidth: 1)
            }
            switch shape {
            case .linear(let start, let end):
                let a = pixel(start), b = pixel(end)
                var path = Path(); path.move(to: a); path.addLine(to: b)
                context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                dot(a); dot(b); dot(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), radius: 3)
            case .radial(let center, let rx, let ry, let rotation):
                // Rotate in image pixels, matching the renderer for both
                // landscape and portrait aspect ratios.
                var path = Path()
                for index in 0...96 {
                    let angle = Double(index) / 96 * Double.pi * 2
                    let x = rx * size.width * cos(angle), y = ry * size.height * sin(angle)
                    let point = CGPoint(x: center.x * size.width + cos(rotation) * x - sin(rotation) * y,
                        y: center.y * size.height + sin(rotation) * x + cos(rotation) * y)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                dot(pixel(center))
                dot(CGPoint(x: center.x * size.width + cos(rotation) * rx * size.width, y: center.y * size.height + sin(rotation) * rx * size.width))
                dot(CGPoint(x: center.x * size.width - sin(rotation) * ry * size.height, y: center.y * size.height + cos(rotation) * ry * size.height))
            default: break
            }
        }.accessibilityHidden(true)
    }

    private func drag(_ geometry: CanvasGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0).updating($pointerIsDown) { _, down, _ in down = true }.onChanged { value in
            guard !interruptsUntilMouseUp, workspace.isCurrent, !workspace.comparesBefore,
                  let model = workspace.model, !model.isGenerating,
                  let source = workspace.source, let selected = workspace.selected else { return }
            if let inputIdentity {
                guard workspace.acceptsCanvasInput(source: inputIdentity.source, layerID: inputIdentity.layerID) else { cancelGesture(); return }
            } else { inputIdentity = InputIdentity(source: source, layerID: selected.id) }
            guard let point = try? MaskPoint(x: value.location.x, y: value.location.y),
                  let native = geometry.viewToCanvas(point) else {
                workspace.brush.breakStrokeSegment(); return
            }
            if workspace.usesBrush {
                if let document = workspace.brush.document,
                   let point = try? MaskPoint(x: native.x * Double(document.canvasSize.width) / Double(geometry.canvasSize.width),
                    y: native.y * Double(document.canvasSize.height) / Double(geometry.canvasSize.height)) {
                    workspace.brush.appendPoint(point)
                }
                return
            }
            guard let normalized = try? LocalMaskPoint(x: native.x / Double(geometry.canvasSize.width), y: native.y / Double(geometry.canvasSize.height)) else { return }
            if gesture == nil {
                gesture = GradientGesture(handle: nearestHandle(to: normalized, shape: selected.mask.shape, geometry: geometry),
                    initial: selected.mask.shape, start: normalized)
                model.beginChange()
            }
            guard let gesture else { return }
            switch gesture.initial {
            case .linear(let start, let end):
                switch gesture.handle {
                case .start: if normalized != end { model.updateSelected { $0.mask.shape = .linear(start: normalized, end: end) } }
                case .end: if normalized != start { model.updateSelected { $0.mask.shape = .linear(start: start, end: normalized) } }
                case .center:
                    let dx = min(1 - max(start.x, end.x), max(-min(start.x, end.x), normalized.x - gesture.start.x))
                    let dy = min(1 - max(start.y, end.y), max(-min(start.y, end.y), normalized.y - gesture.start.y))
                    let a = clampedPoint(x: start.x + dx, y: start.y + dy), b = clampedPoint(x: end.x + dx, y: end.y + dy)
                    if a != b { model.updateSelected { $0.mask.shape = .linear(start: a, end: b) } }
                default: if gesture.start != normalized { model.updateSelected { $0.mask.shape = .linear(start: gesture.start, end: normalized) } }
                }
            case .radial(let center, let rx, let ry, let rotation):
                switch gesture.handle {
                case .center:
                    let moved = clampedPoint(x: center.x + normalized.x - gesture.start.x, y: center.y + normalized.y - gesture.start.y)
                    model.updateSelected { $0.mask.shape = .radial(center: moved, radiusX: rx, radiusY: ry, rotation: rotation) }
                case .radiusX:
                    let aspect = Double(geometry.canvasSize.height) / Double(geometry.canvasSize.width)
                    let radius = max(0.002, abs((normalized.x - center.x) * cos(rotation) + (normalized.y - center.y) * aspect * sin(rotation)))
                    model.updateSelected { $0.mask.shape = .radial(center: center, radiusX: radius, radiusY: ry, rotation: rotation) }
                case .radiusY:
                    let aspect = Double(geometry.canvasSize.width) / Double(geometry.canvasSize.height)
                    let radius = max(0.002, abs(-(normalized.x - center.x) * aspect * sin(rotation) + (normalized.y - center.y) * cos(rotation)))
                    model.updateSelected { $0.mask.shape = .radial(center: center, radiusX: rx, radiusY: radius, rotation: rotation) }
                default:
                    model.updateSelected { $0.mask.shape = .radial(center: gesture.start,
                        radiusX: max(0.002, abs(normalized.x - gesture.start.x)), radiusY: max(0.002, abs(normalized.y - gesture.start.y)), rotation: 0) }
                }
            default: break
            }
        }.onEnded { _ in
            workspace.finishGesture(); gesture = nil; inputIdentity = nil; interruptsUntilMouseUp = false
        }
    }
    private func nearestHandle(to point: LocalMaskPoint, shape: LocalMaskShape, geometry: CanvasGeometry) -> Handle {
        let w = Double(geometry.canvasSize.width) * geometry.scale, h = Double(geometry.canvasSize.height) * geometry.scale
        func near(_ x: Double, _ y: Double) -> Bool { hypot((point.x - x) * w, (point.y - y) * h) <= 12 }
        switch shape {
        case .linear(let start, let end):
            if near(start.x, start.y) { return .start }
            if near(end.x, end.y) { return .end }
            if near((start.x + end.x) / 2, (start.y + end.y) / 2) { return .center }
        case .radial(let center, let rx, let ry, let angle):
            if near(center.x, center.y) { return .center }
            if near(center.x + cos(angle) * rx, center.y + sin(angle) * rx * w / h) { return .radiusX }
            if near(center.x - sin(angle) * ry * h / w, center.y + cos(angle) * ry) { return .radiusY }
        default: break
        }
        return .new
    }
    private func clampedPoint(x: Double, y: Double) -> LocalMaskPoint {
        try! LocalMaskPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
    private func cancelGesture() {
        if inputIdentity != nil { interruptsUntilMouseUp = true }
        workspace.brush.cancelStroke(); workspace.model?.endChange()
        gesture = nil; inputIdentity = nil; cursor = nil
    }
    private func updateOverlay() async {
        overlay = nil
        guard let mask = workspace.displayMask, let canvas = workspace.canvasSize else { return }
        do {
            let image = try await LocalMaskOverlayWorker.shared.image(mask, size: canvas)
            try Task.checkCancellation(); overlay = image
        } catch is CancellationError { }
        catch { workspace.errorMessage = error.localizedDescription }
    }
}

/// A bounded palette beside the photo keeps every saved mask selectable without
/// pushing the correction sliders below the inspector's visible area.
@MainActor
struct InlineMaskList: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    @ViewState private var showsSkySetup = false

    private var layers: [LocalAdjustment] { workspace.model?.settings.localAdjustments ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Masken").font(.system(size: 12, weight: .semibold))
                Text("\(layers.count)").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                Menu {
                    ForEach(LocalMaskCreation.allCases) { kind in
                        Button { workspace.finishGesture(); workspace.model?.add(kind) } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                } label: { Label("Neue Maske", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(workspace.canvasSize == nil || workspace.model?.isGenerating == true || layers.count >= 16)
                    .accessibilityIdentifier("local-mask.add")
                Menu {
                    Button("Himmelsmodell einrichten …") { showsSkySetup = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 16)
                    .accessibilityLabel("Maskeneinstellungen")
            }.controlSize(.mini).font(.system(size: 11))
            if layers.isEmpty {
                Text("Neue Maske erstellen und einen Bildbereich auswählen.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                // Only the list scrolls when many masks exist. Rendering remains
                // lazy; no extra image decoding is needed for mask-type icons.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(layers, id: \.id) { layer in maskRow(layer).id(layer.id) }
                        }
                    }.accessibilityIdentifier("local-mask.list-scroll")
                        .task(id: workspace.model?.selectedID) {
                            // New masks, undo and redo can select a row beyond
                            // the four visible slots. Keep that row reachable.
                            if let selectedID = workspace.model?.selectedID { proxy.scrollTo(selectedID, anchor: .center) }
                        }
                }.frame(height: CGFloat(min(layers.count, 4) * 31 - 3))
            }
            Divider()
            HStack(spacing: 9) {
                Button { workspace.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(workspace.model?.canUndo != true).help("Maskenänderung rückgängig")
                    .accessibilityLabel("Maskenänderung rückgängig").accessibilityIdentifier("local-mask.undo")
                Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(workspace.model?.canRedo != true).help("Maskenänderung wiederholen").accessibilityLabel("Maskenänderung wiederholen")
                Spacer(minLength: 0)
                Toggle("Überlagerung", isOn: $workspace.showsOverlay).toggleStyle(.checkbox)
                    .accessibilityIdentifier("local-mask.overlay")
                Toggle("Vorher", isOn: $workspace.comparesBefore).toggleStyle(.checkbox)
            }.controlSize(.mini).font(.system(size: 10))
        }.padding(8)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("local-mask.list")
            .sheet(isPresented: $showsSkySetup) { SkyMaskModelSetupView() }
    }

    private func maskRow(_ layer: LocalAdjustment) -> some View {
        let selected = layer.id == workspace.model?.selectedID
        return HStack(spacing: 5) {
            Button { workspace.select(layer.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: symbol(for: layer.mask.shape))
                        .font(.system(size: 12)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 2))
                    Text(layer.name).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Maske auswählen: \(layer.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("local-mask.select.\(layer.id.uuidString)")
            Button {
                workspace.select(layer.id); workspace.model?.updateSelected { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: layer.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isEnabled ? Theme.muted : .orange).frame(width: 19, height: 24)
            }.buttonStyle(.plain).help(layer.isEnabled ? "Maske ausblenden" : "Maske einblenden")
                .accessibilityLabel(layer.name + (layer.isEnabled ? " ausblenden" : " einblenden"))
                .accessibilityIdentifier("local-mask.visibility.\(layer.id.uuidString)")
            Button(role: .destructive) { workspace.delete(layer.id) } label: {
                Image(systemName: "trash").frame(width: 19, height: 24)
            }.buttonStyle(.plain).foregroundStyle(Theme.muted).help("Maske löschen")
                .accessibilityLabel("Maske löschen: \(layer.name)")
                .accessibilityIdentifier("local-mask.delete.\(layer.id.uuidString)")
        }.font(.system(size: 11)).padding(.horizontal, 4).frame(height: 28)
            .background(selected ? Theme.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Theme.accent.opacity(0.65) : Color.clear) }
    }

    private func symbol(for shape: LocalMaskShape) -> String {
        switch shape { case .brush: "paintbrush.pointed"; case .linear: "rectangle.lefthalf.filled"; case .radial: "circle.lefthalf.filled"; case .subject: "person.crop.rectangle"; case .sky: "cloud.sun" }
    }
}

/// Compact, single-line controls in the ordinary develop inspector. The mask
/// list stays beside the canvas, leaving the corrections visible together.
@MainActor
struct InlineMaskInspector: View {
    @ObservedObject var workspace: InlineMaskWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Maskieren").font(.headline)
                Spacer()
                Button("Abbrechen") { workspace.cancel() }.controlSize(.small)
                    .accessibilityIdentifier("local-mask.cancel")
                Button("Fertig") { workspace.apply() }.controlSize(.small).disabled(!workspace.canApply)
                    .accessibilityIdentifier("local-mask.apply")
            }
            if let model = workspace.model {
                if let selected = workspace.selected { maskControls(selected, model: model).id(model.inputContextID) }
                else { Text("Erstelle eine Maske und korrigiere damit einzelne Bildbereiche.").font(.caption).foregroundStyle(Theme.muted) }
                Text(workspace.instruction).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isLoading { ProgressView("Bild wird geladen").controlSize(.small) }
                if model.isGenerating {
                    HStack { ProgressView().controlSize(.small); Text("Auswahl wird berechnet").font(.caption); Spacer(); Button("Abbrechen") { model.cancelInference() } }
                }
                if let message = workspace.errorMessage ?? model.errorMessage ?? workspace.brush.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }.padding(.vertical, 4)
    }

    private func maskControls(_ layer: LocalAdjustment, model: LocalAdjustmentEditorModel) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Divider()
            if workspace.usesBrush {
                HStack {
                    Text("Pinsel").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Toggle("Radierer", isOn: $workspace.erases).toggleStyle(.checkbox).font(.system(size: 10))
                    Button { workspace.brush.clear() } label: { Image(systemName: "trash.slash") }
                        .buttonStyle(.plain).help("Pinselstriche löschen").accessibilityLabel("Pinselstriche löschen")
                }.controlSize(.mini).frame(height: 18)
                valueSlider("Radius", value: Binding(get: { workspace.brush.radius }, set: { workspace.brush.radius = $0 }), range: 1...250, neutral: 30, model: model)
                valueSlider("Härte", value: Binding(get: { workspace.brush.hardness }, set: { workspace.brush.hardness = $0 }), range: 0...1, neutral: 0.8, model: model)
                Divider()
            }
            HStack(spacing: 7) {
                TextField("Maskenname", text: Binding(get: { workspace.selected?.name ?? "" }, set: { name in
                    if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.updateSelected { $0.name = String(name.prefix(64)) } }
                })).textFieldStyle(.roundedBorder).accessibilityLabel("Maskenname")
                Toggle("Umkehren", isOn: Binding(get: { workspace.selected?.mask.isInverted ?? false }, set: { value in model.updateSelected { $0.mask.isInverted = value } })).toggleStyle(.checkbox).fixedSize()
                Menu {
                    Button("Maske duplizieren", systemImage: "plus.square.on.square") { workspace.finishGesture(); model.duplicateSelected() }
                        .disabled(model.settings.localAdjustments.count >= 16)
                    Button("Maske nach oben", systemImage: "arrow.up") { workspace.finishGesture(); model.moveSelected(by: -1) }
                        .disabled(model.settings.localAdjustments.first?.id == layer.id)
                    Button("Maske nach unten", systemImage: "arrow.down") { workspace.finishGesture(); model.moveSelected(by: 1) }
                        .disabled(model.settings.localAdjustments.last?.id == layer.id)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 16).accessibilityLabel("Aktionen für diese Maske")
            }.font(.system(size: 10)).controlSize(.mini).frame(height: 23)
            valueSlider("Maskenstärke", value: Binding(get: { workspace.selected?.mask.opacity ?? 1 }, set: { value in model.updateSelected { $0.mask.opacity = value } }), range: 0...1, neutral: 1, model: model)
            valueSlider("Weiche Kante", value: Binding(get: { workspace.selected?.mask.feather ?? 0 }, set: { value in model.updateSelected { $0.mask.feather = value } }), range: 0...1, neutral: 0.5, model: model)
            if case .radial = layer.mask.shape {
                valueSlider("Drehung", value: Binding(get: {
                    if case .radial(_, _, _, let angle)? = workspace.selected?.mask.shape { return angle * 180 / .pi }; return 0
                }, set: { value in
                    model.updateSelected { if case .radial(let center, let rx, let ry, _) = $0.mask.shape { $0.mask.shape = .radial(center: center, radiusX: rx, radiusY: ry, rotation: value * .pi / 180) } }
                }), range: -180...180, model: model)
            }
            if case .linear = layer.mask.shape { refinementToggle }
            else if case .radial = layer.mask.shape { refinementToggle }
            Divider()
            ForEach(LocalMaskControlGroup.allCases) { group in
                HStack {
                    Text(group.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    if group == .tone {
                        Button { workspace.finishGesture(); model.updateSelected { $0.settings = .neutral } } label: {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                        }.buttonStyle(.plain).help("Lokale Regler zurücksetzen").accessibilityLabel("Lokale Regler zurücksetzen")
                            .accessibilityIdentifier("local-mask.reset")
                    }
                }.frame(height: 16, alignment: .bottom)
                ForEach(group.controls) { control in
                    valueSlider(control.title, value: Binding(get: { workspace.selected?.settings[keyPath: control.keyPath] ?? 0 },
                        set: { value in model.updateSelected { $0.settings[keyPath: control.keyPath] = value } }), range: control.range, model: model,
                        accessibilityID: "local-mask.correction.\(control.rawValue)")
                }
            }
        }
    }

    private var refinementToggle: some View {
        Toggle("Mit Pinsel verfeinern", isOn: $workspace.refines).toggleStyle(.checkbox)
            .font(.system(size: 10)).controlSize(.mini).frame(height: 18)
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double = 0,
                             model: LocalAdjustmentEditorModel, accessibilityID: String? = nil) -> some View {
        let input = LocalMaskSliderInput(value: value, model: model)
        return HStack(spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .frame(width: 77, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
            ResettableSlider(value: input.value, in: range, neutralValue: neutral,
                onEditingChanged: input.onEditingChanged)
                .controlSize(.mini).accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityID ?? "local-mask.control.\(title)")
            Text(value.wrappedValue, format: .number.precision(.fractionLength(range.upperBound <= 5 ? 2 : 0)))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                .frame(width: 34, alignment: .trailing)
        }.frame(height: 19)
    }
}

/// A native click may finish before SwiftUI dismantles controls after selection
/// changes. Bind the action and the native view to the same editing context,
/// including when selection or undo later returns to the same layer UUID.
@MainActor
struct LocalMaskSliderInput {
    let value: Binding<Double>
    let onEditingChanged: (Bool) -> Void

    init(value: Binding<Double>, model: LocalAdjustmentEditorModel) {
        let inputContextID = model.inputContextID
        self.value = Binding(get: { value.wrappedValue }, set: { newValue in
            guard model.inputContextID == inputContextID else { return }
            value.wrappedValue = newValue
        })
        onEditingChanged = { editing in
            guard model.inputContextID == inputContextID else { return }
            if editing {
                model.beginChange()
            } else { model.endChange() }
        }
    }
}

private enum LocalMaskControlGroup: String, CaseIterable, Identifiable {
    case tone, color, effects
    var id: String { rawValue }
    var title: String {
        switch self { case .tone: "Tonwert"; case .color: "Farbe"; case .effects: "Effekte" }
    }
    var controls: [LocalMaskControl] {
        switch self {
        case .tone: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
        case .color: [.vibrance, .saturation]
        case .effects: [.texture, .clarity, .dehaze]
        }
    }
}

private actor LocalMaskOverlayWorker {
    static let shared = LocalMaskOverlayWorker()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let alphaKernel = CIColorKernel(source: """
        kernel vec4 maskOverlay(__sample mask) {
            float weight = clamp(mask.r, 0.0, 1.0);
            return vec4(weight, 0.0, 0.0, weight);
        }
        """)
    func image(_ mask: LocalAdjustmentMask, size: ArtifactPixelSize) throws -> CGImage {
        try Task.checkCancellation()
        let extent = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let scalar = try LocalAdjustmentRenderer.maskImage(mask, extent: extent)
        guard let image = alphaKernel?.apply(extent: extent, arguments: [scalar]),
              let bitmap = context.createCGImage(image, from: extent) else { throw EditRenderError.unavailable }
        return bitmap
    }
}

private enum LocalMaskControl: String, CaseIterable, Identifiable {
    case exposure, contrast, highlights, shadows, whites, blacks, texture, clarity, dehaze, vibrance, saturation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exposure: "Belichtung"; case .contrast: "Kontrast"; case .highlights: "Lichter"; case .shadows: "Tiefen"; case .whites: "Weiß"; case .blacks: "Schwarz"; case .texture: "Struktur"; case .clarity: "Klarheit"; case .dehaze: "Dunst entfernen"; case .vibrance: "Dynamik"; case .saturation: "Sättigung"
        }
    }
    var range: ClosedRange<Double> { self == .exposure ? -5...5 : -100...100 }
    var keyPath: WritableKeyPath<LocalAdjustmentSettings, Double> {
        switch self {
        case .exposure: \.exposure; case .contrast: \.contrast; case .highlights: \.highlights; case .shadows: \.shadows; case .whites: \.whites; case .blacks: \.blacks; case .texture: \.texture; case .clarity: \.clarity; case .dehaze: \.dehaze; case .vibrance: \.vibrance; case .saturation: \.saturation
        }
    }
}
