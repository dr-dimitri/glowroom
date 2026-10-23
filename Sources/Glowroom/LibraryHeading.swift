import SwiftUI

/// Search and library controls share one row, including at the minimum canvas width.
struct LibraryHeading: View {
    @ObservedObject var model: LibraryModel
    let onShowGrid: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                viewButtons
                ratingMenu
                searchModePicker
                sortMenu
                Spacer(minLength: 8)
                searchField.frame(minWidth: 160, idealWidth: 195, maxWidth: 260)
                refreshButton
            }
            HStack(spacing: 8) {
                searchField.frame(minWidth: 80, maxWidth: .infinity)
                optionsMenu
                refreshButton
            }
        }
        .padding(.horizontal, 18).frame(height: 42)
    }

    private var viewButtons: some View {
        HStack(spacing: 1) {
            IconButton(symbol: "square.grid.2x2", help: "Rasteransicht", active: !model.showsDetail, action: onShowGrid)
                .accessibilityIdentifier("library.grid")
            IconButton(symbol: "rectangle", help: "Einzelbildansicht · Leertaste", active: model.showsDetail) {
                if model.selectedAsset != nil { model.showsDetail = true }
            }.disabled(model.selectedAsset == nil)
                .accessibilityIdentifier("library.detail")
        }.fixedSize()
    }

    private var ratingMenu: some View {
        Menu {
            Button("Alle Bewertungen") { model.minimumRating = 0 }
            ForEach(1...5, id: \.self) { value in
                Button("Mindestens \(value) Sterne") { model.minimumRating = value }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(model.minimumRating == 0 ? "Alle Bewertungen" : "\(model.minimumRating)+ Sterne")
            }.font(.system(size: 10))
                .foregroundStyle(model.minimumRating == 0 ? Theme.muted : Theme.accent)
        }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Bewertung")
            .accessibilityIdentifier("library.rating")
    }

    private var searchModePicker: some View {
        Picker("Suchmodus", selection: $model.searchMode) {
            ForEach(LibrarySearchMode.allCases) { Text($0.label).tag($0) }
        }.pickerStyle(.menu).font(.system(size: 10)).fixedSize()
            .accessibilityIdentifier("library.search-mode")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sortieren", selection: $model.sort) {
                ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label(model.sort.rawValue, systemImage: "arrow.down")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Sortieren")
            .accessibilityIdentifier("library.sort")
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Bewertung", selection: $model.minimumRating) {
                Text("Alle Bewertungen").tag(0)
                ForEach(1...5, id: \.self) { Text("Mindestens \($0) Sterne").tag($0) }
            }
            Picker("Suchmodus", selection: $model.searchMode) {
                ForEach(LibrarySearchMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Sortieren", selection: $model.sort) {
                ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("Rasteransicht", action: onShowGrid)
            Button("Einzelbildansicht") { if model.selectedAsset != nil { model.showsDetail = true } }
                .disabled(model.selectedAsset == nil)
        } label: {
            Label("Filter & Sortierung", systemImage: "line.3.horizontal.decrease")
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            .foregroundStyle(model.minimumRating > 0 || model.searchMode == .semantic ? Theme.accent : Theme.muted)
            .accessibilityIdentifier("library.options")
    }

    private var refreshButton: some View {
        IconButton(symbol: "arrow.clockwise", help: "Ordner aktualisieren") { model.refreshCurrentFolder() }
            .disabled(model.isImporting || model.folders.isEmpty || !model.canModify)
            .accessibilityIdentifier("library.refresh")
    }

    private var query: Binding<String> {
        Binding(get: { model.searchMode == .literal ? model.search : model.semanticQuery },
                set: { if model.searchMode == .literal { model.search = $0 } else { model.semanticQuery = $0 } })
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            if model.isProjecting || model.isUpdatingCatalog {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    .help("Fotoauswahl wird aktualisiert …")
                    .accessibilityLabel("Fotoauswahl wird aktualisiert")
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
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
