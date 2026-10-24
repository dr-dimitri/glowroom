import SwiftUI
import GlowroomCore

struct InspectorView: View {
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var photoMetadata: PhotoMetadataModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Bildinformationen")
                Spacer()
                Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(Theme.muted).accessibilityHidden(true)
            }.padding(.horizontal, 20).frame(height: 58)
            Rectangle().fill(Theme.line).frame(height: 1)
            if let asset = model.selectedAsset {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { model.showsDetail = true } label: {
                            VStack(spacing: 8) {
                                EditingThumbnail(asset: asset, size: 400, priority: .selected)
                                    .frame(height: 155).padding(8)
                                    .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                                Label("Foto öffnen", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Einzelbildansicht öffnen")
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(asset.fileName).font(.system(size: 13, weight: .medium)).textSelection(.enabled).lineLimit(2)
                                Text("\(asset.format.uppercased()) · \(ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))")
                                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 0)
                            IconButton(symbol: asset.isFavorite ? "heart.fill" : "heart", help: "Favorit · F", active: asset.isFavorite) { model.toggleFavorite() }.disabled(!model.canModify)
                        }.padding(.top, 16)
                        HStack {
                            RatingStars(rating: asset.rating, size: 13, onChange: { model.setRating($0) }).disabled(!model.canModify)
                            Spacer()
                            Text(asset.rating == 0 ? "Unbewertet" : "\(asset.rating) von 5").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }.padding(.top, 17)
                        separator
                        PhotoMetadataSection(model: photoMetadata)
                            .id(WorkspaceTool.metadata)
                        separator
                        SectionLabel(text: "Aufnahme").padding(.bottom, 17)
                        metadataRow("Kamera", asset.cameraModel ?? "—")
                        metadataRow("Objektiv", asset.lensModel ?? "—")
                        HStack(spacing: 6) {
                            exposureTile(asset.aperture ?? "—", label: "BLENDE")
                            exposureTile(asset.shutterSpeed ?? "—", label: "ZEIT")
                            exposureTile(asset.iso ?? "—", label: "ISO")
                        }.padding(.top, 7).padding(.bottom, 15)
                        metadataRow("Brennweite", asset.focalLength ?? "—")
                        metadataRow("Aufgenommen", asset.captureDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                        separator
                        SectionLabel(text: "Datei").padding(.bottom, 17)
                        metadataRow("Abmessungen", "\(asset.pixelWidth) × \(asset.pixelHeight)")
                        metadataRow("Auflösung", String(format: "%.1f MP", Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000))
                        metadataRow("Format", asset.format.uppercased())
                        metadataRow("Größe", ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
                        metadataRow("Geändert", asset.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                        separator
                        SectionLabel(text: "Speicherort").padding(.bottom, 12)
                        Text(asset.fileURL.deletingLastPathComponent().path).font(.system(size: 13)).foregroundStyle(Theme.muted).lineSpacing(4).textSelection(.enabled)
                        Button { model.reveal() } label: { Label("Im Finder anzeigen", systemImage: "arrow.up.right.square").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.top, 14)
                    }.padding(19)
                }
                .task(id: layout.revealRequest) {
                    guard layout.revealedTool == .metadata else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(WorkspaceTool.metadata, anchor: .top)
                }
                }
            } else {
                ContentUnavailableView("Kein Foto ausgewählt", systemImage: "photo")
            }
            Spacer(minLength: 0)
        }.background(Theme.sidebar)
    }

    private var separator: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 22) }
    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).foregroundStyle(Theme.muted).frame(width: 73, alignment: .leading)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(Color.white.opacity(0.75)).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 13)).padding(.bottom, 12)
    }
    private func exposureTile(_ value: String, label: String) -> some View {
        VStack(spacing: 7) {
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity).padding(.vertical, 13).background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
    }
}
