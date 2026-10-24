import AppKit
import SwiftUI
import GlowroomCore

/// An explicit, disposable mask draft. It never changes the photo or catalog edits.
@MainActor
struct MaskCanvasView: View {
    let asset: PhotoAsset
    let source: AISourceIdentity
    let settings: EditSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @StateObject private var mask: MaskEditingModel
    @ViewState private var tool: Tool = .brush
    @ViewState private var zoom: Double = 1
    @ViewState private var pan = CGSize.zero
    @ViewState private var panStart: CGSize?
    @ViewState private var cursor: CGPoint?
    @ViewState private var loadingError: String?
    @ViewState private var isActualSize = false
    @ViewState private var sourceRevision: String?
    @ViewState private var showsHelp = false

    private enum Tool: String, CaseIterable {
        case brush, erase, pan
        var name: String { switch self { case .brush: return "Pinsel"; case .erase: return "Radierer"; case .pan: return "Hand" } }
        var symbol: String { switch self { case .brush: return "paintbrush.pointed"; case .erase: return "eraser"; case .pan: return "hand.draw" } }
    }

    init(asset: PhotoAsset, source: AISourceIdentity, settings: EditSettings, model: MaskEditingModel? = nil) {
        self.asset = asset
        self.source = source
        self.settings = settings
        _mask = StateObject(wrappedValue: model ?? MaskEditingModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Maske bearbeiten", systemImage: "paintbrush.pointed").font(.headline)
                Spacer()
                Text(asset.fileName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Entwurf verwerfen und schließen") { mask.discard(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            controls.padding(.horizontal, 16).padding(.vertical, 12)
            GeometryReader { viewport in
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.35)
                    if let canvas = mask.document?.canvasSize,
                       let geometry = try? CanvasGeometry(canvasSize: canvas,
                            viewportWidth: viewport.size.width, viewportHeight: viewport.size.height,
                            zoom: zoom, panX: pan.width, panY: pan.height) {
                        imageCanvas(canvas, geometry: geometry)
                        cursorPreview(geometry: geometry)
                        Color.clear.contentShape(Rectangle())
                            .gesture(drag(geometry: geometry))
                            .onContinuousHover { phase in
                                switch phase { case .active(let location): cursor = location; case .ended: cursor = nil }
                            }
                            .accessibilityLabel("Maskencanvas für \(asset.fileName)")
                            .accessibilityIdentifier("mask.canvas")
                            .accessibilityHint("Mit Pinsel oder Radierer ziehen. Mit der Hand das Bild verschieben. Ein Strich ist ein Rückgängig-Schritt.")
                    } else if let loadingError {
                        ContentUnavailableView("Maskencanvas nicht verfügbar", systemImage: "exclamationmark.triangle", description: Text(loadingError))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView("Bildmaße werden gelesen").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.clipped()
                    .overlay(alignment: .bottomTrailing) { zoomControls(viewport: viewport.size).padding(12) }
                    .onChange(of: viewport.size) { _, _ in
                        mask.cancelStroke()
                        if isActualSize { actualSize(viewport: viewport.size) }
                    }
                    .onChange(of: displayScale) { _, _ in if isActualSize { actualSize(viewport: viewport.size) } }
            }
            Divider()
            HStack {
                Label("Maskenentwurf", systemImage: "square.and.pencil")
                Spacer()
                if mask.isRasterizing { ProgressView("Maskenvorschau wird aktualisiert …").controlSize(.small) }
                Button("Hilfe", systemImage: "questionmark.circle") { showsHelp = true }
            }.padding(12)
            if let message = mask.errorMessage { Text(message).foregroundStyle(.orange).padding(.bottom, 10) }
        }
        .font(.system(size: 13))
        .frame(minWidth: 980, idealWidth: 1_080, minHeight: 560, idealHeight: 760)
        .sheet(isPresented: $showsHelp) { maskHelp }
        .task(id: source) {
            mask.discard(); loadingError = nil; fit()
            do {
                let canvasSource = try await MaskCanvasSourceReader.shared.read(source)
                try Task.checkCancellation()
                sourceRevision = canvasSource.revision
                try mask.begin(source: source, canvasSize: canvasSource.size)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { loadingError = error.localizedDescription } }
        }
        .onChange(of: tool) { _, value in
            mask.cancelStroke(); panStart = nil
            if value != .pan { mask.mode = value == .brush ? .brush : .erase }
        }
        .onDisappear { mask.discard() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
            Picker("Werkzeug", selection: $tool) {
                ForEach(Tool.allCases, id: \.self) { tool in Label(tool.name, systemImage: tool.symbol).tag(tool) }
            }.pickerStyle(.segmented).frame(width: 245).accessibilityLabel("Maskenwerkzeug")
                Spacer(minLength: 0)
                Button("Rückgängig", systemImage: "arrow.uturn.backward") { mask.undo() }
                    .disabled(!mask.canUndo).accessibilityLabel("Maskenstrich rückgängig")
                    .accessibilityIdentifier("mask.undo")
                Button("Wiederholen", systemImage: "arrow.uturn.forward") { mask.redo() }
                    .disabled(!mask.canRedo).accessibilityLabel("Maskenstrich wiederholen")
                Menu("Maskenaktionen") {
                    Button("Maske löschen") { mask.clear() }
                    Button("Maske invertieren") { mask.invert() }
                }
            }
            HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Radius: \(Int(mask.radius)) Bildpixel")
                ResettableSlider(value: $mask.radius, in: 1...500, step: 1, neutralValue: 30).accessibilityLabel("Pinselradius in Bildpixeln")
                    .accessibilityValue("\(Int(mask.radius)) Pixel")
            }.frame(maxWidth: .infinity).disabled(tool == .pan)
            VStack(alignment: .leading, spacing: 3) {
                Text("Härte: \(Int(mask.hardness * 100)) %")
                ResettableSlider(value: $mask.hardness, in: 0...1, neutralValue: 0.8).accessibilityLabel("Pinselhärte")
                    .accessibilityValue("\(Int(mask.hardness * 100)) Prozent")
            }.frame(maxWidth: .infinity).disabled(tool == .pan)
            VStack(alignment: .leading, spacing: 3) {
                Text("Überlagerung: \(Int(mask.overlayOpacity * 100)) %")
                ResettableSlider(value: $mask.overlayOpacity, in: 0...1, neutralValue: 0.55).accessibilityLabel("Deckkraft des Maskenoverlays")
                    .help("Ändert nur die Anzeige, nicht die Maskengewichte.")
            }.frame(maxWidth: .infinity)
            }
        }.disabled(mask.document == nil)
    }

    private var maskHelp: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Maskenentwurf · Hilfe").font(.title2.bold())
            Text("Pinsel markiert den Bereich, der ersetzt werden darf. Radierer nimmt Bereiche aus der Auswahl; Hand verschiebt das Bild. Die rote Überlagerung zeigt die Auswahl. Ohne Maske bleibt das Foto erhalten.")
            Text("Dieser lokale Entwurf startet keine Bildgenerierung und ändert das Foto nicht. Entwurf verwerfen und schließen entfernt ihn. Jeder Pinselstrich lässt sich rückgängig machen.")
            HStack { Spacer(); Button("Hilfe schließen") { showsHelp = false }.keyboardShortcut(.cancelAction) }
        }.font(.system(size: 13)).padding(24).frame(width: 500)
    }

    private func imageCanvas(_ canvas: ArtifactPixelSize, geometry: CanvasGeometry) -> some View {
        let size = CGSize(width: Double(canvas.width) * geometry.scale, height: Double(canvas.height) * geometry.scale)
        return ZStack {
            PhotoPreview(url: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize,
                         settings: settings, source: source, developing: true, sourceRevision: sourceRevision)
            if let result = mask.rasterResult {
                Color.red.mask { Image(decorative: result.overlay, scale: 1).resizable().interpolation(.high) }
                    .opacity(mask.overlayOpacity).allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }.frame(width: size.width, height: size.height)
            .position(x: geometry.originX + size.width / 2, y: geometry.originY + size.height / 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cursorPreview(geometry: CanvasGeometry) -> some View {
        if tool != .pan, let cursor, let point = try? MaskPoint(x: cursor.x, y: cursor.y), geometry.viewToCanvas(point) != nil {
            let diameter = mask.radius * geometry.scale * 2
            ZStack {
                Circle().fill((tool == .erase ? Color.white : .red).opacity(0.12))
                Circle().strokeBorder(Color.white, lineWidth: 1)
                Circle().strokeBorder(Color.black.opacity(0.8), lineWidth: 1).padding(1)
                Circle().strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(diameter * (1 - mask.hardness) / 2)
            }.frame(width: diameter, height: diameter).position(cursor).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func drag(geometry: CanvasGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                cursor = value.location
                if tool == .pan {
                    if panStart == nil { panStart = pan }
                    if let start = panStart { pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height) }
                } else if let viewPoint = try? MaskPoint(x: value.location.x, y: value.location.y),
                          let point = geometry.viewToCanvas(viewPoint) {
                    mask.appendPoint(point)
                } else { mask.breakStrokeSegment() }
            }
            .onEnded { _ in if tool == .pan { panStart = nil } else { mask.endStroke() } }
    }

    private func zoomControls(viewport: CGSize) -> some View {
        HStack(spacing: 8) {
            Button("Einpassen") { fit() }.accessibilityLabel("Bild einpassen")
            Button("100 %") { actualSize(viewport: viewport) }.help("Ein Bildpixel pro Bildschirm-Pixel")
            Button { zoomBy(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Verkleinern")
            Button { zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Vergrößern")
        }.buttonStyle(.bordered).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .disabled(mask.document == nil)
    }
    private func fit() { mask.cancelStroke(); zoom = 1; pan = .zero; isActualSize = false }
    private func zoomBy(_ factor: Double) { mask.cancelStroke(); zoom = min(64, max(0.0000001, zoom * factor)); isActualSize = false }
    private func actualSize(viewport: CGSize) {
        guard let canvas = mask.document?.canvasSize,
              let geometry = try? CanvasGeometry(canvasSize: canvas, viewportWidth: viewport.width, viewportHeight: viewport.height) else { return }
        mask.cancelStroke(); zoom = min(64, max(0.0000001, 1 / max(1, displayScale) / geometry.scale)); pan = .zero; isActualSize = true
    }
}
