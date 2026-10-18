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

/// Compact mask palette in the ordinary develop inspector. Only model setup
/// opens a separate settings sheet; all photo editing stays on the main canvas.
@MainActor
struct InlineMaskInspector: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    @ViewState private var showsSkySetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Maskieren").font(.headline)
                Spacer()
                Button("Abbrechen") { workspace.cancel() }.controlSize(.small)
                    .accessibilityIdentifier("local-mask.cancel")
                Button("Fertig") { workspace.apply() }.controlSize(.small).disabled(!workspace.canApply)
                    .accessibilityIdentifier("local-mask.apply")
            }
            HStack(spacing: 12) {
                Button { workspace.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(workspace.model?.canUndo != true).help("Maskenänderung rückgängig")
                    .accessibilityLabel("Maskenänderung rückgängig").accessibilityIdentifier("local-mask.undo")
                Button { workspace.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(workspace.model?.canRedo != true).help("Maskenänderung wiederholen").accessibilityLabel("Maskenänderung wiederholen")
                Spacer()
                Toggle("Overlay", isOn: $workspace.showsOverlay).toggleStyle(.checkbox)
                Toggle("Vorher", isOn: $workspace.comparesBefore).toggleStyle(.checkbox)
            }.controlSize(.small).font(.caption)
            maskList
            if let model = workspace.model {
                if let selected = workspace.selected { maskControls(selected, model: model).id(selected.id) }
                else { Text("Erstelle eine Maske und korrigiere damit einzelne Bildbereiche.").font(.caption).foregroundStyle(Theme.muted) }
                Text(workspace.instruction).font(.caption).foregroundStyle(Theme.muted)
                if model.isLoading { ProgressView("Bild wird geladen").controlSize(.small) }
                if model.isGenerating {
                    HStack { ProgressView().controlSize(.small); Text("Auswahl wird berechnet").font(.caption); Spacer(); Button("Abbrechen") { model.cancelInference() } }
                }
                if let message = workspace.errorMessage ?? model.errorMessage ?? workspace.brush.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }.padding(.vertical, 12)
            .sheet(isPresented: $showsSkySetup) { SkyMaskModelSetupView() }

    }

    private var maskList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(LocalMaskCreation.allCases) { kind in Button { workspace.model?.add(kind) } label: { Label(kind.title, systemImage: kind.symbol) } }
            } label: { Label("Neue Maske", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                .menuStyle(.borderlessButton).padding(10).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                .disabled(workspace.canvasSize == nil || workspace.model?.isGenerating == true || (workspace.model?.settings.localAdjustments.count ?? 0) >= 16)
                .accessibilityIdentifier("local-mask.add")
            ForEach(workspace.model?.settings.localAdjustments ?? [], id: \.id) { layer in
                HStack(spacing: 7) {
                    Button { workspace.select(layer.id) } label: {
                        HStack {
                            Image(systemName: symbol(for: layer.mask.shape)).frame(width: 20)
                            Text(layer.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            if layer.id == workspace.model?.selectedID { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button {
                        workspace.select(layer.id); workspace.model?.updateSelected { $0.isEnabled.toggle() }
                    } label: { Image(systemName: layer.isEnabled ? "eye" : "eye.slash").foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain).help(layer.isEnabled ? "Maske ausblenden" : "Maske einblenden")
                        .accessibilityLabel(layer.name + (layer.isEnabled ? " ausblenden" : " einblenden"))
                }.padding(9).background(layer.id == workspace.model?.selectedID ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            Button("Himmelsmodell einrichten …") { showsSkySetup = true }.font(.caption).buttonStyle(.plain).foregroundStyle(Theme.muted)
        }
    }
    private func symbol(for shape: LocalMaskShape) -> String {
        switch shape { case .brush: "paintbrush.pointed"; case .linear: "rectangle.lefthalf.filled"; case .radial: "circle.lefthalf.filled"; case .subject: "person.crop.rectangle"; case .sky: "cloud.sun" }
    }

    private func maskControls(_ layer: LocalAdjustment, model: LocalAdjustmentEditorModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            TextField("Maskenname", text: Binding(get: { workspace.selected?.name ?? "" }, set: { name in
                if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.updateSelected { $0.name = String(name.prefix(64)) } }
            })).textFieldStyle(.roundedBorder).accessibilityLabel("Maskenname")
            HStack {
                Toggle("Invertieren", isOn: Binding(get: { workspace.selected?.mask.isInverted ?? false }, set: { value in model.updateSelected { $0.mask.isInverted = value } })).toggleStyle(.checkbox)
                Spacer()
                Button { model.moveSelected(by: -1) } label: { Image(systemName: "arrow.up") }.help("Maske nach oben").accessibilityLabel("Maske nach oben")
                    .disabled(model.settings.localAdjustments.first?.id == layer.id)
                Button { model.moveSelected(by: 1) } label: { Image(systemName: "arrow.down") }.help("Maske nach unten").accessibilityLabel("Maske nach unten")
                    .disabled(model.settings.localAdjustments.last?.id == layer.id)
                Button { model.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }.help("Maske duplizieren").accessibilityLabel("Maske duplizieren")
                Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }.help("Maske löschen").accessibilityLabel("Maske löschen")
            }.font(.caption).buttonStyle(.plain)
            valueSlider("Maskenstärke", value: Binding(get: { workspace.selected?.mask.opacity ?? 1 }, set: { value in model.updateSelected { $0.mask.opacity = value } }), range: 0...1, neutral: 1, model: model)
            valueSlider("Weiche Kante", value: Binding(get: { workspace.selected?.mask.feather ?? 0 }, set: { value in model.updateSelected { $0.mask.feather = value } }), range: 0...1, neutral: 0.5, model: model)
            if case .radial = layer.mask.shape {
                valueSlider("Drehung", value: Binding(get: {
                    if case .radial(_, _, _, let angle)? = workspace.selected?.mask.shape { return angle * 180 / .pi }; return 0
                }, set: { value in
                    model.updateSelected { if case .radial(let center, let rx, let ry, _) = $0.mask.shape { $0.mask.shape = .radial(center: center, radiusX: rx, radiusY: ry, rotation: value * .pi / 180) } }
                }), range: -180...180, model: model)
            }
            if case .linear = layer.mask.shape { Toggle("Mit Pinsel verfeinern", isOn: $workspace.refines).toggleStyle(.checkbox).font(.caption) }
            else if case .radial = layer.mask.shape { Toggle("Mit Pinsel verfeinern", isOn: $workspace.refines).toggleStyle(.checkbox).font(.caption) }
            if workspace.usesBrush {
                Divider()
                HStack {
                    Text("Pinsel").font(.caption.weight(.semibold))
                    Spacer()
                    Toggle("Radierer", isOn: $workspace.erases).toggleStyle(.checkbox).font(.caption)
                    Button { workspace.brush.clear() } label: { Image(systemName: "trash.slash") }
                        .buttonStyle(.plain).help("Pinselstriche löschen").accessibilityLabel("Pinselstriche löschen")
                }
                valueSlider("Radius", value: Binding(get: { workspace.brush.radius }, set: { workspace.brush.radius = $0 }), range: 1...250, neutral: 30, model: model)
                valueSlider("Härte", value: Binding(get: { workspace.brush.hardness }, set: { workspace.brush.hardness = $0 }), range: 0...1, neutral: 0.8, model: model)
            }
            Divider()
            HStack {
                Text("Lokale Korrekturen").font(.caption.weight(.semibold))
                Spacer()
                Button { model.updateSelected { $0.settings = .neutral } } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).help("Lokale Regler zurücksetzen").accessibilityLabel("Lokale Regler zurücksetzen")
            }
            ForEach(LocalMaskControl.allCases) { control in
                valueSlider(control.title, value: Binding(get: { workspace.selected?.settings[keyPath: control.keyPath] ?? 0 },
                    set: { value in model.updateSelected { $0.settings[keyPath: control.keyPath] = value } }), range: control.range, model: model)
            }
        }
    }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double = 0, model: LocalAdjustmentEditorModel) -> some View {
        let input = LocalMaskSliderInput(value: value, model: model)
        return VStack(spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11)); Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(range.upperBound <= 5 ? 2 : 0)))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            ResettableSlider(value: input.value, in: range, neutralValue: neutral,
                onEditingChanged: input.onEditingChanged)
                .controlSize(.small).accessibilityLabel(title)
        }
    }
}

/// A native click may finish before SwiftUI dismantles controls after selection
/// changes. Bind the action itself to its selected layer as well as the view ID.
@MainActor
struct LocalMaskSliderInput {
    let value: Binding<Double>
    let onEditingChanged: (Bool) -> Void

    init(value: Binding<Double>, model: LocalAdjustmentEditorModel) {
        let selectedID = model.selectedID
        self.value = Binding(get: { value.wrappedValue }, set: { newValue in
            guard model.selectedID == selectedID else { return }
            value.wrappedValue = newValue
        })
        onEditingChanged = { editing in
            if editing {
                guard model.selectedID == selectedID else { return }
                model.beginChange()
            } else { model.endChange() }
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
