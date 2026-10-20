import SwiftUI
import PicEditCore

struct PhotoGridView: View {
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    var body: some View {
        GeometryReader { geometry in
        ScrollViewReader { reader in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.gridSize), spacing: 15)], spacing: 17) {
                    ForEach(model.visibleAssets) { asset in
                        PhotoCard(asset: asset, selected: model.selectedIDs.contains(asset.id), model: model)
                            .id(asset.id)
                    }
                }.padding(23)
            }
            .onAppear { if let id = model.selectedID { reader.scrollTo(id) } }
            .onChange(of: model.selectedID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id) } }
            }
        }
        .onAppear { updateColumns(width: geometry.size.width) }
        .onChange(of: geometry.size.width) { _, width in updateColumns(width: width) }
        .onChange(of: model.gridSize) { _, _ in updateColumns(width: geometry.size.width) }
        }
    }
    private func updateColumns(width: CGFloat) {
        model.gridColumnCount = max(1, Int((max(0, width - 46) + 15) / (model.gridSize + 15)))
    }
}

private struct PhotoCard: View {
    let asset: PhotoAsset
    let selected: Bool
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @ViewState<Bool> private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(Color.black.opacity(0.2))
                EditingThumbnail(asset: asset, size: model.gridSize)
                    .padding(10)
                if asset.isFavorite || hovered {
                    Button { model.toggleFavorite(asset.id) } label: {
                        Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 11)).foregroundStyle(asset.isFavorite ? Theme.accent : .white)
                            .padding(7).background(.black.opacity(0.55), in: Circle())
                    }.buttonStyle(.plain).help("Favorit umschalten · F").padding(9).disabled(!model.canModify)
                }
            }.aspectRatio(1.24, contentMode: .fit).clipped()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text(asset.fileName).font(.system(size: 11, weight: .medium)).foregroundStyle(selected ? Color.white : Color.white.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(editor.sourceFormat(for: asset)).font(.system(size: 7, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 4).padding(.vertical, 3).background(Theme.background, in: RoundedRectangle(cornerRadius: 3))
                }
                HStack {
                    RatingStars(rating: asset.rating, onChange: { model.setRating($0, for: asset.id) }).disabled(!model.canModify)
                    Spacer()
                    Text(editor.sourceDimensions(for: asset)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 11).padding(.vertical, 12)
        }
        .background(selected ? Theme.elevated : Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.accent.opacity(0.8) : hovered ? Color.white.opacity(0.16) : Theme.line, lineWidth: selected ? 1.5 : 1) }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { model.select(asset); model.showsDetail = true }
            .exclusively(before: photoSelectionGesture(asset: asset, model: model)))
        .onHover { hovered = $0 }
        .contextMenu { PhotoContextMenu(asset: asset, model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(asset.fileName), \(asset.rating) Sterne\(selected ? ", ausgewählt" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private func photoSelectionGesture(asset: PhotoAsset, model: LibraryModel) -> some Gesture {
    // Match the click event's modifiers. Reading NSEvent.modifierFlags in a
    // delayed single-click callback loses keys released during double-click detection.
    TapGesture().modifiers([.command, .shift])
        .onEnded { model.select(asset, extending: true, toggling: true) }
        .exclusively(before: TapGesture().modifiers(.shift)
            .onEnded { model.select(asset, extending: true) })
        .exclusively(before: TapGesture().modifiers(.command)
            .onEnded { model.select(asset, toggling: true) })
        .exclusively(before: TapGesture().onEnded { model.select(asset) })
}

private struct PhotoContextMenu: View {
    let asset: PhotoAsset
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var exporter: JPEGExportModel

    private var exportCount: Int { model.selectedIDs.contains(asset.id) ? model.selectedIDs.count : 1 }

    var body: some View {
        Button("In Einzelbildansicht öffnen") { model.select(asset); model.showsDetail = true }
        Button(exportCount > 1 ? "\(exportCount) Fotos als JPEG exportieren …" : "Foto als JPEG exportieren …") {
            JPEGExportActions.present(using: exporter, library: model, editor: editor, contextAsset: asset)
        }.disabled(!model.canExportJPEG || model.isProjecting || editor.isLoading || editor.isRestoring || editor.isClosing || exporter.isPresented)
        Button("Im Finder anzeigen") { model.reveal(asset) }
        Divider()
        Button(asset.isFavorite ? "Aus Favoriten entfernen" : "Als Favorit markieren") { model.toggleFavorite(asset.id) }.disabled(!model.canModify)
        Menu("Bewertung") {
            ForEach(0...5, id: \.self) { value in
                Button(value == 0 ? "Keine Bewertung" : "\(value) Sterne") { model.setRating(value, for: asset.id) }
            }
        }.disabled(!model.canModify)
    }
}

struct DetailView: View {
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @Environment(\.workspaceCanvasMeasurement) private var measureCanvas
    @ViewState<Bool> private var zoomed = false
    @ViewState private var canvasSize = CGSize.zero
    @ViewState private var zoomCanvasSize = CGSize.zero
    @EnvironmentObject private var maskWorkspace: InlineMaskWorkspace
    @EnvironmentObject private var developWorkspace: DevelopWorkspace
    private var usesNativeCropInput: Bool {
        model.isDeveloping && developWorkspace.tool == .crop && model.editingRenderIntent == .currentEditing
            && !maskWorkspace.isPresented && !developWorkspace.picksWhiteBalance
    }
    private var usesNativeDevelopInput: Bool {
        model.isDeveloping && [.crop, .repair].contains(developWorkspace.tool)
            && model.editingRenderIntent == .currentEditing && !maskWorkspace.isPresented && !developWorkspace.picksWhiteBalance
    }
    private var usesPhotoNavigationInput: Bool {
        !maskWorkspace.isPresented && (!model.isDeveloping || model.editingRenderIntent != .currentEditing
            || (developWorkspace.tool == .basic && !developWorkspace.picksWhiteBalance))
    }
    private struct NavigationIdentity: Hashable {
        let asset: String
        let source: AISourceIdentity?
        let comparesOriginal: Bool
        let comparesSource: Bool
    }
    var body: some View {
        GeometryReader { available in
        VStack(spacing: 0) {
            if let asset = model.selectedAsset {
                HStack(spacing: 8) {
                    Text(asset.fileName).fontWeight(.medium)
                    Text(previewLabel).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 18).frame(height: 30).background(Theme.chrome)
                GeometryReader { geometry in
                    if zoomed {
                        ScrollView([.horizontal, .vertical]) {
                            developCanvas(asset: asset)
                                // Capture magnification once; resizing panels only
                                // changes the viewport around this scroll content.
                                .frame(width: zoomCanvasSize.width, height: zoomCanvasSize.height)
                                .environment(\.photoCanvasPanning, true)
                                .onTapGesture(count: 2) { if !usesNativeDevelopInput && !usesPhotoNavigationInput { zoomed = false } }
                        }
                    } else {
                        developCanvas(asset: asset)
                            .padding(18)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .onTapGesture(count: 2) { if !usesNativeDevelopInput && !usesPhotoNavigationInput { toggleZoom(viewport: geometry.size) } }
                    }
                }.onGeometryChange(for: CGSize.self) { $0.size } action: {
                    canvasSize = $0
                    measureCanvas?($0)
                }
                    .overlay {
                        InlineMaskViewportOverlays(workspace: maskWorkspace,
                            showsMaskList: layout.panels(developing: model.isDeveloping).showsTools
                                && developWorkspace.tool == .masks)
                        if !maskWorkspace.showsCalculationStatus {
                            if developWorkspace.repairBusy {
                                EditingProgressIndicator(cancelLabel: "Reparatur abbrechen") {
                                    developWorkspace.cancelRepairWork(clearCandidates: false)
                                }
                            } else if developWorkspace.isAutoStraightening {
                                EditingProgressIndicator().allowsHitTesting(false)
                            }
                        }
                    }
                    .environment(\.editingProgressIsCovered, maskWorkspace.showsCalculationStatus
                        || developWorkspace.repairBusy || developWorkspace.isAutoStraightening)
                    .contextMenu { PhotoContextMenu(asset: asset, model: model) }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Bildfläche")
                    .accessibilityIdentifier("workspace.canvas")
                canvasControls(asset)
                if !model.isDeveloping, layout.panels(developing: false).showsFilmstrip {
                    // The bound applies to the image canvas, after its controls and resize handle.
                    let chromeHeight = 30.0 + 42 + 6
                    let height = layout.boundedFilmstripHeight(availableHeight: max(0, available.size.height - chromeHeight), developing: model.isDeveloping)
                    WorkspaceResizeHandle(horizontal: false, label: "Höhe des Filmstreifens", value: height, step: 1) { height in
                        layout.update(developing: model.isDeveloping) { $0.filmstripHeight = height }
                    }
                    PhotoFilmstrip(model: model, height: height)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(model.isDeveloping ? Theme.canvas : Theme.background)
            .onChange(of: model.selectedID) { _, _ in zoomed = false }
        }
    }

    private func developCanvas(asset: PhotoAsset) -> some View {
        GeometryReader { viewport in
            let source = developWorkspace.sourceSize ?? CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight))
            let angle = usesNativeCropInput && developWorkspace.isOriginalCanvasReady
                ? editor.settings(for: asset.id).developGeometry.straightenAngle : 0
            let fit = DevelopCropCanvasPresentation.fittingScale(sourceSize: source, viewport: viewport.size, angle: angle)
            ZStack {
                EditingPhotoPreview(asset: asset, intent: model.editingRenderIntent,
                    settingsOverride: previewSettings(for: asset.id), developing: model.isDeveloping,
                    imageScale: fit, imageRotation: angle)
                    // Composite the cached source immediately while the crop tool is
                    // open. Only the photo rotates; the shared status stays upright.
                if maskWorkspace.isPresented {
                    InlineMaskCanvas(workspace: maskWorkspace).allowsHitTesting(developWorkspace.isOriginalCanvasReady)
                } else if model.isDeveloping, model.editingRenderIntent == .currentEditing {
                    DevelopCanvasInteraction(asset: asset, workspace: developWorkspace,
                        onDoubleClick: { toggleZoom(viewport: canvasSize) })
                }
                if developWorkspace.tool == .basic, !developWorkspace.picksWhiteBalance,
                   let analysis = developWorkspace.analysis,
                   let overlay = analysis.clippingImage(shadows: developWorkspace.showsShadows, highlights: developWorkspace.showsHighlights),
                   developWorkspace.showsShadows || developWorkspace.showsHighlights {
                    Image(decorative: overlay, scale: 1).resizable().interpolation(.none)
                        .aspectRatio(contentMode: .fit).allowsHitTesting(false)
                }
                if usesPhotoNavigationInput {
                    DevelopCropInputSurface(onInput: { _ in }, onHover: { _ in }, isEnabled: true,
                        inputIdentity: AnyHashable(NavigationIdentity(asset: asset.id,
                            source: developWorkspace.sourceIdentity, comparesOriginal: model.comparesOriginal,
                            comparesSource: model.comparesCurrentSourceWithoutSettings)),
                        cursor: { _ in zoomed ? .openHand : .arrow },
                        onDoubleClick: { toggleZoom(viewport: canvasSize) },
                        canvasLabel: zoomed ? "Vergrößertes Bild verschieben · Doppelklick zum Einpassen" : "Bild · Doppelklick zum Vergrößern",
                        pansWithPointer: true, canvasIdentifier: "workspace.photo-navigation")
                }
            }
        }
    }

    private func toggleZoom(viewport: CGSize) {
        if !zoomed {
            zoomCanvasSize = CGSize(width: max(1, viewport.width * 2), height: max(1, viewport.height * 2))
        }
        zoomed.toggle()
    }

    private var previewLabel: String {
        if model.comparesOriginal { return " · Importiertes Original" }
        if model.comparesCurrentSourceWithoutSettings { return " · Aktuelle Quelle ohne Regler" }
        return ""
    }

    private func previewSettings(for assetID: String) -> EditSettings {
        var settings = maskWorkspace.previewSettings ?? editor.settings(for: assetID)
        if developWorkspace.tool.usesOriginalCanvas || developWorkspace.picksWhiteBalance {
            settings.developGeometry.crop = nil
            settings.developGeometry.quarterTurns = 0
            settings.developGeometry.straightenAngle = 0
            settings.developGeometry.constrainToImage = true
            settings.developGeometry.flipHorizontal = false
            settings.developGeometry.flipVertical = false
        }
        return settings
    }

    private func canvasControls(_ asset: PhotoAsset) -> some View {
        HStack(spacing: 5) {
            Button { toggleZoom(viewport: canvasSize) } label: {
                Image(systemName: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
                    .frame(width: 28, height: 30)
            }.buttonStyle(.plain).help(zoomed ? "Einpassen · Doppelklick auf das Bild · Drei-Finger-Ziehen zum Verschieben" : "Vergrößern · Doppelklick auf das Bild")
                .accessibilityLabel(zoomed ? "Einpassen" : "Vergrößern")
                .accessibilityIdentifier("workspace.zoom")
            Menu {
                Button { model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = false } label: {
                    Label("Aktuelle Bearbeitung", systemImage: model.editingRenderIntent == .currentEditing ? "checkmark" : "circle")
                }
                Button { model.comparesOriginal = true; model.comparesCurrentSourceWithoutSettings = false } label: {
                    Label("Importiertes Original", systemImage: model.comparesOriginal ? "checkmark" : "circle")
                }
                Button { model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = true } label: {
                    Label("Aktuelle Quelle ohne Regler", systemImage: model.comparesCurrentSourceWithoutSettings ? "checkmark" : "circle")
                }
            } label: {
                Image(systemName: "rectangle.lefthalf.inset.filled").frame(width: 24, height: 30)
            }.menuStyle(.borderlessButton).fixedSize().disabled(maskWorkspace.isPresented)
                .accessibilityLabel("Vergleich").accessibilityValue(comparisonTitle)
                .accessibilityIdentifier("workspace.compare").help("Vergleich: " + comparisonTitle)
            Spacer(minLength: 0)
            RatingStars(rating: asset.rating, size: 11, onChange: { model.setRating($0) }).disabled(!model.canModify)
            IconButton(symbol: asset.isFavorite ? "heart.fill" : "heart", help: "Favorit · F", active: asset.isFavorite) { model.toggleFavorite() }.disabled(!model.canModify)
            Spacer(minLength: 0)
            IconButton(symbol: "chevron.left", help: "Vorheriges Foto · ←") { model.navigate(-1) }
            IconButton(symbol: "chevron.right", help: "Nächstes Foto · →") { model.navigate(1) }
        }.padding(.horizontal, 10).frame(height: 42).background(Theme.panel)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var comparisonTitle: String {
        if model.comparesOriginal { return "Importiertes Original" }
        if model.comparesCurrentSourceWithoutSettings { return "Aktuelle Quelle ohne Regler" }
        return "Aktuelle Bearbeitung"
    }
}

/// Shared lazy strip spans the full developing workspace and reuses thumbnail caches.
struct PhotoFilmstrip: View {
    @ObservedObject var model: LibraryModel
    let height: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.title).fontWeight(.medium).lineLimit(1)
                Text("\(model.visibleAssets.count) Fotos").foregroundStyle(Theme.muted).fixedSize()
                Spacer(minLength: 0)
                Menu {
                    Picker("Bewertung", selection: $model.minimumRating) {
                        Text("Alle Bewertungen").tag(0)
                        ForEach(1...5, id: \.self) { Text("Mindestens \($0) Sterne").tag($0) }
                    }
                    Picker("Sortieren", selection: $model.sort) {
                        ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("Filter & Sortierung", systemImage: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton).fixedSize()
            }.font(.system(size: 10)).padding(.horizontal, 14).frame(height: 26).background(Theme.chrome)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 2) {
                        ForEach(model.visibleAssets) { asset in
                            Button { model.select(asset) } label: {
                                EditingThumbnail(asset: asset, size: max(110, height * 1.4))
                                    .padding(6).frame(width: max(32, (height - 38) * 1.3), height: max(16, height - 38))
                                    .background(model.selectedIDs.contains(asset.id) ? Theme.elevated : Theme.panel)
                                    .overlay { Rectangle().strokeBorder(model.selectedIDs.contains(asset.id) ? Theme.accent : Theme.line, lineWidth: 1) }
                            }.buttonStyle(.plain).id(asset.id).help(asset.fileName)
                                .accessibilityLabel(asset.fileName)
                                .accessibilityAddTraits(model.selectedIDs.contains(asset.id) ? .isSelected : [])
                                .highPriorityGesture(photoSelectionGesture(asset: asset, model: model))
                                .contextMenu { PhotoContextMenu(asset: asset, model: model) }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }.clipped()
                    .onAppear { if let id = model.selectedID { reader.scrollTo(id, anchor: .center) } }
                    .onChange(of: model.selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id, anchor: .center) } } }
            }
        }.frame(height: height).background(Theme.sidebar)
            .accessibilityIdentifier("workspace.filmstrip")
    }
}
