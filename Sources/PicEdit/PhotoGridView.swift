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
    @EnvironmentObject private var assistant: AIAssistantModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @Environment(\.workspaceCanvasMeasurement) private var measureCanvas
    @ViewState<Bool> private var zoomed = false
    @ViewState private var canvasSize = CGSize.zero
    @ViewState private var zoomCanvasSize = CGSize.zero
    @Binding var showsMaskEditor: Bool
    var body: some View {
        GeometryReader { available in
        VStack(spacing: 0) {
            if let asset = model.selectedAsset {
                HStack {
                    if !layout.isFocused {
                        Button { model.showsDetail = false } label: { Label("Übersicht", systemImage: "chevron.left").font(.system(size: 11)) }.buttonStyle(.plain)
                    }
                    Spacer()
                    Text(asset.fileName + previewLabel).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    Button { showsMaskEditor = true } label: {
                        Label("Maske", systemImage: "paintbrush.pointed").font(.system(size: 10))
                    }.buttonStyle(.plain).help("Maskenentwurf auf der aktuellen Bildquelle bearbeiten")
                        .accessibilityIdentifier("workspace.mask")
                        .disabled(!model.canModify || model.editingRenderIntent != .currentEditing || editor.isLoading || editor.isRestoring || editor.isClosing)
                    Button { toggleZoom(viewport: canvasSize) } label: { Label(zoomed ? "Einpassen" : "Vergrößern", systemImage: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("workspace.zoom")
                    Menu {
                        Button("Aktuelle Bearbeitung") { model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = false }
                        Button("Importiertes Original") { model.comparesOriginal = true; model.comparesCurrentSourceWithoutSettings = false }
                        Button("Aktuelle Quelle ohne Regler") { model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = true }
                    } label: { Label("Vergleich", systemImage: "rectangle.lefthalf.inset.filled").font(.system(size: 11)) }
                        .menuStyle(.borderlessButton).fixedSize()
                }.padding(.horizontal, layout.isFocused ? 14 : 23).frame(height: layout.isFocused ? 34 : 46)
                GeometryReader { geometry in
                    if zoomed {
                        ScrollView([.horizontal, .vertical]) {
                            EditingPhotoPreview(asset: asset, intent: model.editingRenderIntent, settingsOverride: previewSettings(for: asset.id), developing: model.isDeveloping)
                                // Capture magnification once; resizing panels only
                                // changes the viewport around this scroll content.
                                .frame(width: zoomCanvasSize.width, height: zoomCanvasSize.height)
                                .onTapGesture(count: 2) { zoomed = false }
                        }
                    } else {
                        EditingPhotoPreview(asset: asset, intent: model.editingRenderIntent, settingsOverride: previewSettings(for: asset.id), developing: model.isDeveloping)
                            .padding(.horizontal, 25).padding(.vertical, 10)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .onTapGesture(count: 2) { toggleZoom(viewport: geometry.size) }
                    }
                }.onGeometryChange(for: CGSize.self) { $0.size } action: {
                    canvasSize = $0
                    measureCanvas?($0)
                }
                    .contextMenu { PhotoContextMenu(asset: asset, model: model) }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Bildfläche")
                    .accessibilityIdentifier("workspace.canvas")
                HStack(spacing: 18) {
                    IconButton(symbol: "chevron.left", help: "Vorheriges Foto · ←") { model.navigate(-1) }
                    RatingStars(rating: asset.rating, size: 13, onChange: { model.setRating($0) }).disabled(!model.canModify)
                    IconButton(symbol: asset.isFavorite ? "heart.fill" : "heart", help: "Favorit · F", active: asset.isFavorite) { model.toggleFavorite() }.disabled(!model.canModify)
                    IconButton(symbol: "chevron.right", help: "Nächstes Foto · →") { model.navigate(1) }
                }.frame(height: 49)
                if layout.panels(developing: model.isDeveloping).showsFilmstrip {
                    // The bound applies to the image canvas, after its controls and resize handle.
                    let chromeHeight = (layout.isFocused ? 34.0 : 46.0) + 49 + 6
                    let height = layout.boundedFilmstripHeight(availableHeight: max(0, available.size.height - chromeHeight), developing: model.isDeveloping)
                    WorkspaceResizeHandle(horizontal: false, label: "Höhe des Filmstreifens", value: height, step: 1) { height in
                        layout.update(developing: model.isDeveloping) { $0.filmstripHeight = height }
                    }
                    filmstrip(height: height)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.14))
            .onChange(of: model.selectedID) { _, _ in zoomed = false }
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
        if model.isDeveloping, assistant.canAccept {
            return assistant.comparison == .proposal ? " · KI-Vorschau · noch nicht übernommen" : " · Aktuelle Bearbeitung"
        }
        return ""
    }

    private func previewSettings(for assetID: String) -> EditSettings {
        assistant.displaySettings(assetID: assetID, committed: editor.settings(for: assetID),
                                  developing: model.isDeveloping, comparesOriginal: model.comparesOriginal)
    }

    private func filmstrip(height: Double) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.visibleAssets) { asset in
                        Button { model.select(asset) } label: {
                            EditingThumbnail(asset: asset, size: max(110, height * 1.4))
                                .padding(4).frame(width: max(32, (height - 26) * 1.3), height: max(16, height - 26))
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(model.selectedIDs.contains(asset.id) ? Theme.accent : Theme.line, lineWidth: 1) }
                        }.buttonStyle(.plain).id(asset.id).help(asset.fileName)
                            .highPriorityGesture(photoSelectionGesture(asset: asset, model: model))
                            .contextMenu { PhotoContextMenu(asset: asset, model: model) }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 13)
            }.frame(height: height).clipped().background(Theme.sidebar)
                .onAppear { if let id = model.selectedID { reader.scrollTo(id, anchor: .center) } }
                .onChange(of: model.selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id, anchor: .center) } } }
        }
    }
}
