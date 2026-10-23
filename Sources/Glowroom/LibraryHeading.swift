import SwiftUI

/// Keep the collection context and search on one row, even at the minimum canvas width.
struct LibraryHeading: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(model.title)
                        .accessibilityIdentifier("library.title")
                    if model.isProjecting || model.isUpdatingCatalog {
                        ProgressView().controlSize(.small).help("Fotoauswahl wird aktualisiert …")
                    } else {
                        Text("\(model.visibleAssets.count.formatted()) Fotos")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.muted).fixedSize()
                            .accessibilityIdentifier("library.photo-count")
                    }
                    Spacer(minLength: 0)
                }
                searchField
                    // Reserve room for both the collection context and a usable search field.
                    .frame(width: min(model.searchMode == .literal ? 195 : 260,
                                      max(0, geometry.size.width - 36) * 0.45))
            }.padding(.horizontal, 18).frame(height: 42)
        }.frame(height: 42)
    }

    private var query: Binding<String> {
        Binding(get: { model.searchMode == .literal ? model.search : model.semanticQuery },
                set: { if model.searchMode == .literal { model.search = $0 } else { model.semanticQuery = $0 } })
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            TextField(model.searchMode == .literal ? "Fotos wörtlich suchen …" : "Bildinhalt auf Deutsch/Englisch …", text: query)
                .textFieldStyle(.plain).font(.system(size: 12))
                .accessibilityLabel(model.searchMode == .literal ? "Wörtliche Fotosuche" : "Semantische Bildsuche")
                .accessibilityIdentifier("library.search")
            if !query.wrappedValue.isEmpty {
                Button { query.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 28)
                }.buttonStyle(.plain).help("Suche löschen")
                    .accessibilityLabel("Suche löschen")
                    .accessibilityIdentifier("library.clear-search")
            }
        }.padding(.horizontal, 8).frame(height: 30)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }
}
