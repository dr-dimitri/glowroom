import AppKit
import CoreImage
import SwiftUI
import PicEditCore

@MainActor
struct LocalAdjustmentMaskEditor: View {
    let asset: PhotoAsset
    let source: AISourceIdentity
    @ObservedObject var library: LibraryModel
    @Binding private var isPresented: Bool
    @EnvironmentObject private var editor: EditingModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: LocalAdjustmentEditorModel
    @StateObject private var brush = MaskEditingModel(rendersOverlay: false)
    private let baseSettings: EditSettings
    @ViewState private var overlay: CGImage?
    @ViewState private var showsOverlay = true
    @ViewState private var comparesBefore = false
    @ViewState private var showsSkySetup = false
    @ViewState private var erases = false
    @ViewState private var refines = false
    @ViewState private var pans = false
    @ViewState private var zoom: Double = 1
    @ViewState private var pan = CGSize.zero
    @ViewState private var panStart: CGSize?
    @ViewState private var gradientStart: LocalMaskPoint?
    @ViewState private var cursor: CGPoint?
    @ViewState private var anchor: LocalMaskEditingAnchor?
    private struct OverlayIdentity: Hashable {
        let source: AISourceIdentity
        let canvas: ArtifactPixelSize?
        let mask: LocalAdjustmentMask?
    }

    init(asset: PhotoAsset, source: AISourceIdentity, settings: EditSettings, library: LibraryModel,
         isPresented: Binding<Bool> = .constant(true), model: LocalAdjustmentEditorModel? = nil) {
        self.asset = asset; self.source = source; self.library = library; self.baseSettings = settings
        _isPresented = isPresented
        _model = StateObject(wrappedValue: model ?? LocalAdjustmentEditorModel(settings: settings))
    }

    private var isCurrent: Bool {
        guard let anchor else { return false }
        return library.selectedID == asset.id && editor.canEdit && editor.settings(for: asset.id) == baseSettings
            && (try? editor.resolvedSource(for: asset).identity) == source
            && anchor.isCurrent(editor: editor, library: library)
    }
    private var selected: LocalAdjustment? { model.selected }
    private var usesBrush: Bool {
        guard let selected else { return false }
        switch selected.mask.shape {
        case .brush, .subject, .sky: return true
        case .linear, .radial: return refines
        }
    }
    private var displayMask: LocalAdjustmentMask? {
        guard var mask = selected?.mask else { return nil }
        if let document = brush.previewDocument, brush.source == source {
            if case .brush = mask.shape { mask.shape = .brush(document) }
            else if !document.strokes.isEmpty { mask.refinement = document }
        }
        return mask
    }
    private var canvas: ArtifactPixelSize? {
        if let selected, case .brush(let document) = selected.mask.shape { return document.canvasSize }
        return model.canvasSize
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("Masken", systemImage: "circle.dashed.inset.filled").font(.headline)
                Text(asset.fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(!isCurrent || model.isLoading || model.isGenerating)
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    canvasToolbar.padding(12)
                    GeometryReader { viewport in
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.4)
                            if let canvas, let geometry = try? CanvasGeometry(canvasSize: canvas,
                                viewportWidth: viewport.size.width, viewportHeight: viewport.size.height,
                                zoom: zoom, panX: pan.width, panY: pan.height) {
                                picture(geometry: geometry)
                                brushCursor(geometry: geometry)
                                Color.clear.contentShape(Rectangle()).gesture(drag(geometry))
                                    .onContinuousHover { phase in
                                        switch phase { case .active(let point): cursor = point; case .ended: cursor = nil }
                                    }
                                    .accessibilityLabel("Lokale Maske auf dem Bild zeichnen")
                                    .accessibilityIdentifier("local-mask.canvas")
                            } else if model.isLoading {
                                ProgressView("Bild wird geladen").frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ContentUnavailableView("Bild nicht verfügbar", systemImage: "photo",
                                    description: Text(model.errorMessage ?? "Die Bildquelle konnte nicht geladen werden."))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }.clipped().onChange(of: viewport.size) { _, _ in brush.cancelStroke(); gradientStart = nil; model.endChange() }
                    }
                    HStack {
                        Text(instruction).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Original unverändert").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }.frame(minWidth: 530, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        maskList
                        if let selected { maskControls(selected) }
                        else {
                            Text("Füge eine Maske hinzu. Die lokalen Regler verändern nur den ausgewählten Bereich.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if model.isGenerating {
                            HStack { ProgressView().controlSize(.small); Text("Auswahl wird berechnet").font(.caption); Spacer(); Button("Abbrechen") { model.cancelInference() } }
                        }
                        if let message = model.errorMessage ?? brush.errorMessage {
                            Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if !isCurrent { Text("Die Bearbeitung oder Bildquelle wurde inzwischen geändert. Öffne die Masken erneut, um den aktuellen Stand zu bearbeiten.").font(.caption).foregroundStyle(.orange) }
                    }.padding(16)
                }.frame(width: 310)
            }
        }.frame(minWidth: 900, idealWidth: 1180, minHeight: 620, idealHeight: 800)
            .task(id: source) {
                guard isPresented, !Task.isCancelled else { return }
                anchor = LocalMaskEditingAnchor(editor: editor, library: library)
                await model.load(source: source)
                guard isPresented, !Task.isCancelled else { model.close(); return }
                syncBrush()
            }
            .onChange(of: isPresented) { _, presented in if !presented { brush.discard(); model.close() } }
            .task(id: OverlayIdentity(source: source, canvas: model.canvasSize, mask: displayMask)) { await updateOverlay() }
            .onChange(of: model.selectedID) { _, _ in model.endChange(); brush.cancelStroke(); syncBrush() }
            .onChange(of: selected?.mask) { _, _ in syncBrush() }
            .onChange(of: brush.document) { _, document in
                guard let document, let selected else { return }
                if case .brush = selected.mask.shape { model.updateSelected { $0.mask.shape = .brush(document) } }
                else if !document.strokes.isEmpty || selected.mask.refinement != nil { model.updateSelected { $0.mask.refinement = document } }
                syncBrush()
            }
            .sheet(isPresented: $showsSkySetup) { SkyMaskModelSetupView() }
            .onDisappear { brush.discard(); model.close() }
    }

    private var canvasToolbar: some View {
        HStack(spacing: 12) {
            Button { brush.cancelStroke(); model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Maskenänderung rückgängig").accessibilityLabel("Maskenänderung rückgängig")
                .accessibilityIdentifier("local-mask.undo")
            Button { brush.cancelStroke(); model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Maskenänderung wiederholen").accessibilityLabel("Maskenänderung wiederholen")
            Divider().frame(height: 18)
            Toggle("Overlay", isOn: $showsOverlay).toggleStyle(.checkbox)
            Toggle("Vorher", isOn: $comparesBefore).toggleStyle(.checkbox).help("Stand vor dem Öffnen der Masken anzeigen")
            Spacer(minLength: 0)
            Toggle(isOn: $pans) { Image(systemName: "hand.draw") }.toggleStyle(.button).help("Bild verschieben")
            Button("Einpassen") { brush.cancelStroke(); zoom = 1; pan = .zero }
            Button { brush.cancelStroke(); zoom = max(1, zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Verkleinern")
            Button { brush.cancelStroke(); zoom = min(16, zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Vergrößern")
        }.controlSize(.small)
    }

    private var maskList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(LocalMaskCreation.allCases) { kind in
                    Button { model.add(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                }
            } label: { Label("Neue Maske", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                .menuStyle(.borderlessButton).padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .disabled(model.canvasSize == nil || model.isGenerating || model.settings.localAdjustments.count >= 16)
                .accessibilityIdentifier("local-mask.add")
            ForEach(model.settings.localAdjustments, id: \.id) { layer in
                Button { model.selectedID = layer.id } label: {
                    HStack {
                        Image(systemName: layer.isEnabled ? "circle.dashed.inset.filled" : "eye.slash")
                        Text(layer.name).lineLimit(1)
                        Spacer()
                        if layer.id == model.selectedID { Image(systemName: "checkmark").foregroundStyle(.orange) }
                    }.padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain).background(layer.id == model.selectedID ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(layer.name + (layer.isEnabled ? "" : ", ausgeblendet"))
            }
            Button("Himmelsmodell einrichten …") { showsSkySetup = true }.font(.caption)
        }
    }

    private func maskControls(_ layer: LocalAdjustment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            TextField("Maskenname", text: Binding(get: { selected?.name ?? "" }, set: { name in
                if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.updateSelected { $0.name = String(name.prefix(64)) }
                }
            })).textFieldStyle(.roundedBorder).accessibilityLabel("Maskenname")
            HStack {
                Toggle("Aktiv", isOn: Binding(get: { selected?.isEnabled ?? false }, set: { value in model.updateSelected { $0.isEnabled = value } })).toggleStyle(.checkbox)
                Spacer()
                Button { model.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }.help("Maske duplizieren").accessibilityLabel("Maske duplizieren")
                Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }.help("Maske löschen").accessibilityLabel("Maske löschen")
            }
            Toggle("Maske invertieren", isOn: Binding(get: { selected?.mask.isInverted ?? false }, set: { value in model.updateSelected { $0.mask.isInverted = value } })).toggleStyle(.checkbox)
            valueSlider("Maskenstärke", value: Binding(get: { selected?.mask.opacity ?? 1 }, set: { value in model.updateSelected { $0.mask.opacity = value } }), range: 0...1)
            valueSlider("Weiche Kante", value: Binding(get: { selected?.mask.feather ?? 0 }, set: { value in model.updateSelected { $0.mask.feather = value } }), range: 0...1)
            if case .linear = layer.mask.shape {
                Toggle("Mit Pinsel verfeinern", isOn: $refines).toggleStyle(.checkbox)
            } else if case .radial = layer.mask.shape {
                Toggle("Mit Pinsel verfeinern", isOn: $refines).toggleStyle(.checkbox)
            }
            if usesBrush {
                Divider()
                Toggle("Radierer", isOn: $erases).toggleStyle(.checkbox).onChange(of: erases) { _, value in brush.cancelStroke(); brush.mode = value ? .erase : .brush }
                valueSlider("Pinselradius", value: $brush.radius, range: 1...250)
                valueSlider("Pinselhärte", value: $brush.hardness, range: 0...1)
            }
            Divider()
            HStack {
                Text("Lokale Korrekturen").font(.headline)
                Spacer()
                Button { model.updateSelected { $0.settings = .neutral } } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Lokale Regler zurücksetzen").accessibilityLabel("Lokale Regler zurücksetzen")
            }
            ForEach(LocalMaskControl.allCases) { control in
                valueSlider(control.title, value: Binding(get: { selected?.settings[keyPath: control.keyPath] ?? 0 },
                    set: { value in model.updateSelected { $0.settings[keyPath: control.keyPath] = value } }), range: control.range)
            }
        }
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(range.upperBound <= 5 ? 2 : 0)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in if editing { model.beginChange() } else { model.endChange() } })
                .controlSize(.small).accessibilityLabel(title)
        }
    }

    private func picture(geometry: CanvasGeometry) -> some View {
        let width = Double(geometry.canvasSize.width) * geometry.scale
        let height = Double(geometry.canvasSize.height) * geometry.scale
        return ZStack {
            PhotoPreview(url: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize,
                settings: comparesBefore ? baseSettings : model.settings, source: source, developing: true)
            if showsOverlay, !comparesBefore {
                if let overlay {
                    Color.red.mask { Image(decorative: overlay, scale: 1).resizable() }.opacity(0.45)
                }
                gradientHandles
            }
        }.frame(width: width, height: height)
            .position(x: geometry.originX + width / 2, y: geometry.originY + height / 2).allowsHitTesting(false)
    }

    @ViewBuilder private func brushCursor(geometry: CanvasGeometry) -> some View {
        if usesBrush, !pans, !comparesBefore, let cursor, let document = brush.document,
           let point = try? MaskPoint(x: cursor.x, y: cursor.y), geometry.viewToCanvas(point) != nil {
            let diameter = brush.radius * 2 * geometry.scale * Double(geometry.canvasSize.width) / Double(document.canvasSize.width)
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 1)
                Circle().strokeBorder(.black.opacity(0.7), lineWidth: 1).padding(1)
                Circle().strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(diameter * (1 - brush.hardness) / 2)
            }.frame(width: diameter, height: diameter).position(cursor).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var gradientHandles: some View {
        Canvas { context, size in
            guard let selected else { return }
            switch selected.mask.shape {
            case .linear(let start, let end):
                let a = CGPoint(x: start.x * size.width, y: start.y * size.height)
                let b = CGPoint(x: end.x * size.width, y: end.y * size.height)
                var path = Path(); path.move(to: a); path.addLine(to: b)
                context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                for point in [a, b] { context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.white)) }
            case .radial(let center, let rx, let ry, _):
                let rect = CGRect(x: (center.x - rx) * size.width, y: (center.y - ry) * size.height, width: 2 * rx * size.width, height: 2 * ry * size.height)
                context.stroke(Path(ellipseIn: rect), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            default: break
            }
        }.accessibilityHidden(true)
    }

    private func drag(_ geometry: CanvasGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            guard !comparesBefore else { return }
            if pans {
                if panStart == nil { brush.cancelStroke(); panStart = pan }
                if let start = panStart { pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height) }
                return
            }
            guard let point = try? MaskPoint(x: value.location.x, y: value.location.y),
                  let native = geometry.viewToCanvas(point), let selected else { brush.breakStrokeSegment(); return }
            if usesBrush {
                if let document = brush.document {
                    let x = native.x * Double(document.canvasSize.width) / Double(geometry.canvasSize.width)
                    let y = native.y * Double(document.canvasSize.height) / Double(geometry.canvasSize.height)
                    if let point = try? MaskPoint(x: x, y: y) { brush.appendPoint(point) }
                }
                return
            }
            switch selected.mask.shape {
            case .brush: brush.appendPoint(native)
            case .linear, .radial:
                guard let normalized = try? LocalMaskPoint(x: native.x / Double(geometry.canvasSize.width), y: native.y / Double(geometry.canvasSize.height)) else { return }
                if gradientStart == nil { gradientStart = normalized; model.beginChange() }
                guard let start = gradientStart else { return }
                if case .linear = selected.mask.shape {
                    if start != normalized { model.updateSelected { $0.mask.shape = .linear(start: start, end: normalized) } }
                } else {
                    model.updateSelected { $0.mask.shape = .radial(center: start,
                        radiusX: max(0.002, abs(normalized.x - start.x)), radiusY: max(0.002, abs(normalized.y - start.y)), rotation: 0) }
                }
            default: break
            }
        }.onEnded { _ in
            brush.endStroke(); model.endChange(); gradientStart = nil; panStart = nil
        }
    }

    private var instruction: String {
        if pans { return "Ziehen verschiebt das Bild." }
        guard let selected else { return "Neue Maske hinzufügen, anschließend den Bereich wählen." }
        switch selected.mask.shape {
        case .brush: return erases ? "Ziehen entfernt Bereiche aus der Pinselmaske." : "Ziehen malt die Pinselmaske."
        case .linear: return refines ? "Mit Pinsel ergänzen oder mit Radierer abziehen." : "Verlauf vom vollständig gewählten zum ungewählten Bereich ziehen."
        case .radial: return refines ? "Mit Pinsel ergänzen oder mit Radierer abziehen." : "Von der Mitte nach außen ziehen, um die Ellipse aufzuspannen."
        case .subject, .sky: return "Automatische Auswahl prüfen; mit Pinsel ergänzen oder mit Radierer abziehen."
        }
    }
    private func syncBrush() {
        guard let selected, let canvas = model.canvasSize else { brush.discard(); return }
        let document: MaskDocument
        if case .brush(let saved) = selected.mask.shape { document = saved }
        else if let saved = selected.mask.refinement { document = saved }
        else { guard let empty = try? MaskDocument(canvasSize: canvas) else { return }; document = empty }
        if brush.document != document || brush.source != source { try? brush.load(source: source, document: document) }
        brush.mode = erases ? .erase : .brush
    }
    private func updateOverlay() async {
        overlay = nil
        guard let mask = displayMask, let canvas = model.canvasSize else { return }
        do {
            let image = try await LocalMaskOverlayWorker.shared.image(mask, size: canvas)
            try Task.checkCancellation(); overlay = image
        } catch is CancellationError { }
        catch { model.errorMessage = error.localizedDescription }
    }
    private func apply() {
        brush.endStroke()
        if let document = brush.document, let selected {
            if case .brush = selected.mask.shape { model.updateSelected { $0.mask.shape = .brush(document) } }
            else if !document.strokes.isEmpty || selected.mask.refinement != nil { model.updateSelected { $0.mask.refinement = document } }
            let accepted = model.selected.flatMap { layer -> MaskDocument? in
                if case .brush(let saved) = layer.mask.shape { return saved }
                return layer.mask.refinement
            }
            if !document.strokes.isEmpty, accepted != document { syncBrush(); return }
        }
        model.endChange()
        guard isCurrent else { return }
        editor.endEditing(assetID: asset.id)
        editor.setSettings(model.settings, for: asset.id)
        if editor.settings(for: asset.id) == model.settings { dismiss() }
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
        guard let image = alphaKernel?.apply(extent: extent, arguments: [scalar]) else { throw EditRenderError.unavailable }
        guard let bitmap = context.createCGImage(image, from: extent) else { throw EditRenderError.unavailable }
        return bitmap
    }
}

private enum LocalMaskControl: String, CaseIterable, Identifiable {
    case exposure, contrast, highlights, shadows, whites, blacks, texture, clarity, dehaze, vibrance, saturation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exposure: "Belichtung"
        case .contrast: "Kontrast"
        case .highlights: "Lichter"
        case .shadows: "Tiefen"
        case .whites: "Weiß"
        case .blacks: "Schwarz"
        case .texture: "Struktur"
        case .clarity: "Klarheit"
        case .dehaze: "Dunst entfernen"
        case .vibrance: "Dynamik"
        case .saturation: "Sättigung"
        }
    }
    var range: ClosedRange<Double> { self == .exposure ? -5...5 : -100...100 }
    var keyPath: WritableKeyPath<LocalAdjustmentSettings, Double> {
        switch self {
        case .exposure: \.exposure
        case .contrast: \.contrast
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .whites: \.whites
        case .blacks: \.blacks
        case .texture: \.texture
        case .clarity: \.clarity
        case .dehaze: \.dehaze
        case .vibrance: \.vibrance
        case .saturation: \.saturation
        }
    }
}
