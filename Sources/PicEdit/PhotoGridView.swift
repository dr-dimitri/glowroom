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
                AssetThumbnail(url: asset.fileURL, modifiedAt: asset.modifiedAt, size: model.gridSize, fileSize: asset.fileSize, settings: editor.settings(for: asset.id))
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
                    Text(asset.format.uppercased()).font(.system(size: 7, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 4).padding(.vertical, 3).background(Theme.background, in: RoundedRectangle(cornerRadius: 3))
                }
                HStack {
                    RatingStars(rating: asset.rating, onChange: { model.setRating($0, for: asset.id) }).disabled(!model.canModify)
                    Spacer()
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight)").font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.muted)
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
        }.disabled(model.isProjecting || editor.isLoading || editor.isRestoring || editor.isClosing || exporter.isPresented)
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
    @ViewState<Bool> private var zoomed = false
    var body: some View {
        VStack(spacing: 0) {
            if let asset = model.selectedAsset {
                HStack {
                    Button { model.showsDetail = false } label: { Label("Übersicht", systemImage: "chevron.left").font(.system(size: 11)) }.buttonStyle(.plain)
                    Spacer()
                    Text(asset.fileName + (model.comparesOriginal ? " · Vorher" : "")).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    Button { zoomed.toggle() } label: { Label(zoomed ? "Einpassen" : "Vergrößern", systemImage: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                }.padding(.horizontal, 23).frame(height: 46)
                GeometryReader { geometry in
                    if zoomed {
                        ScrollView([.horizontal, .vertical]) {
                            PhotoPreview(url: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize, settings: model.comparesOriginal ? .neutral : editor.settings(for: asset.id), developing: model.isDeveloping)
                                .frame(width: max(1, geometry.size.width * 2), height: max(1, geometry.size.height * 2))
                                .onTapGesture(count: 2) { zoomed = false }
                        }
                    } else {
                        PhotoPreview(url: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize, settings: model.comparesOriginal ? .neutral : editor.settings(for: asset.id), developing: model.isDeveloping)
                            .padding(.horizontal, 25).padding(.vertical, 10)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .onTapGesture(count: 2) { zoomed = true }
                    }
                }.contextMenu { PhotoContextMenu(asset: asset, model: model) }
                HStack(spacing: 18) {
                    IconButton(symbol: "chevron.left", help: "Vorheriges Foto · ←") { model.navigate(-1) }
                    RatingStars(rating: asset.rating, size: 13, onChange: { model.setRating($0) }).disabled(!model.canModify)
                    IconButton(symbol: asset.isFavorite ? "heart.fill" : "heart", help: "Favorit · F", active: asset.isFavorite) { model.toggleFavorite() }.disabled(!model.canModify)
                    IconButton(symbol: "chevron.right", help: "Nächstes Foto · →") { model.navigate(1) }
                }.frame(height: 49)
                filmstrip
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.14))
            .onChange(of: model.selectedID) { _, _ in zoomed = false }
    }

    private var filmstrip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.visibleAssets) { asset in
                        Button { model.select(asset) } label: {
                            AssetThumbnail(url: asset.fileURL, modifiedAt: asset.modifiedAt, size: 110, fileSize: asset.fileSize, settings: editor.settings(for: asset.id))
                                .padding(4).frame(width: 90, height: 68)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(model.selectedIDs.contains(asset.id) ? Theme.accent : Theme.line, lineWidth: 1) }
                        }.buttonStyle(.plain).id(asset.id).help(asset.fileName)
                            .highPriorityGesture(photoSelectionGesture(asset: asset, model: model))
                            .contextMenu { PhotoContextMenu(asset: asset, model: model) }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 13)
            }.frame(height: 98).background(Theme.sidebar)
                .onAppear { if let id = model.selectedID { reader.scrollTo(id, anchor: .center) } }
                .onChange(of: model.selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id, anchor: .center) } } }
        }
    }
}
