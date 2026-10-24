import SwiftUI

/// One search entry point; compact canvases keep its active mode visible.
struct LibraryHeading: View {
    @ObservedObject var model: LibraryModel
    let onShowGrid: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                viewButtons
                ratingMenu
                searchModePicker()
                sortMenu
                Spacer(minLength: 8)
                searchField.frame(minWidth: 160, idealWidth: 220, maxWidth: 300)
                refreshButton
            }
            HStack(spacing: 8) {
                searchModePicker(compact: true)
                searchField.frame(minWidth: model.similarityReference == nil ? 40 : 160, maxWidth: .infinity)
                optionsMenu
                if model.similarityReference == nil { refreshButton }
            }
        }
        .padding(.horizontal, 14).frame(height: 42)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bibliothekswerkzeuge")
        .accessibilityIdentifier("library.controls")
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
            Label(model.minimumRating == 0 ? "Alle Bewertungen" : "\(model.minimumRating)+ Sterne",
                  systemImage: "line.3.horizontal.decrease")
                .font(.system(size: 13))
                .foregroundStyle(model.minimumRating == 0 ? Theme.muted : Theme.accent)
        }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Bewertung")
            .accessibilityIdentifier("library.rating")
    }

    private var searchModeLabel: String {
        model.similarityReference != nil ? "Ähnliche Bilder" : model.searchMode.label
    }

    private func searchModePicker(compact: Bool = false) -> some View {
        Menu {
            Button("Text") { model.searchMode = .literal }
            Button("Bildinhalt") { model.useSemanticTextSearch() }
            Button("Ähnliche Bilder") { model.findSimilarImages() }
                .disabled(model.selectedAsset == nil || !model.hasSemanticService)
        } label: {
            Text(compact && model.similarityReference != nil ? "Ähnlich" : searchModeLabel)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
        }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Suchmodus: \(searchModeLabel)")
            .accessibilityIdentifier("library.search-mode")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sortieren", selection: $model.sort) {
                ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label(model.sort.rawValue, systemImage: "arrow.down")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
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
            Picker("Sortieren", selection: $model.sort) {
                ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("Rasteransicht", action: onShowGrid)
            Button("Einzelbildansicht") { if model.selectedAsset != nil { model.showsDetail = true } }
                .disabled(model.selectedAsset == nil)
            Button("Ordner aktualisieren") { model.refreshCurrentFolder() }
                .disabled(model.isImporting || model.folders.isEmpty || !model.canModify)
        } label: {
            Image(systemName: "line.3.horizontal.decrease").frame(width: 22, height: 28)
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 13))
            .foregroundStyle(model.minimumRating > 0 ? Theme.accent : Theme.muted)
            .accessibilityLabel("Filter & Sortierung")
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
            if model.similarityReference == nil, model.isProjecting || model.isUpdatingCatalog {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    .accessibilityLabel("Fotoauswahl wird aktualisiert")
            } else if model.similarityReference == nil {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted).accessibilityHidden(true)
            }
            if let reference = model.similarityReference {
                AssetThumbnail(url: reference.fileURL, modifiedAt: reference.modifiedAt,
                               size: 32, fileSize: reference.fileSize)
                    .frame(width: 32, height: 22).clipped().accessibilityHidden(true)
                Text(reference.fileName).font(.system(size: 13)).lineLimit(1)
                    .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Bildreferenz: \(reference.fileName)")
                    .accessibilityIdentifier("library.search-reference")
            } else {
                TextField(model.searchMode == .literal ? "Fotos suchen …" : "Bildinhalt suchen …", text: query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .accessibilityLabel(model.searchMode == .literal ? "Wörtliche Fotosuche" : "Semantische Bildsuche")
                    .accessibilityIdentifier("library.search")
            }
            if model.similarityReference != nil || !query.wrappedValue.isEmpty {
                Button {
                    if model.similarityReference != nil { model.stopFindingSimilarImages() }
                    else { query.wrappedValue = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 28)
                }.buttonStyle(.plain).help(model.similarityReference != nil ? "Ähnlichkeitssuche beenden" : "Suche löschen")
                    .accessibilityLabel(model.similarityReference != nil ? "Ähnlichkeitssuche beenden" : "Suche löschen")
                    .accessibilityIdentifier("library.clear-search")
            }
        }.padding(.horizontal, 8).frame(height: 30)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Search controls only. Model installation and index management live in KI-Modelle.
struct LibrarySearchStatusView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.searchMode == .semantic {
                HStack(spacing: 12) {
                    TextField("Dateiname, Kamera oder Format filtern", text: $model.semanticLiteralFilter)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Zusätzlicher Textfilter")
                        .accessibilityIdentifier("library.additional-filter")
                    Stepper("Top \(min(500, max(1, model.semanticTopK)))", value: $model.semanticTopK, in: 1...500)
                        .fixedSize().accessibilityIdentifier("library.top-k")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    scopeLabel.frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                    ratingLabel
                    endSimilarityButton
                    resultsLabel
                    resetButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        scopeLabel.frame(maxWidth: .infinity, alignment: .leading)
                        ratingLabel
                    }
                    HStack(spacing: 12) {
                        resultsLabel
                        Spacer(minLength: 0)
                        endSimilarityButton
                        resetButton
                    }
                }
            }
            if let label = model.semanticOperationLabel {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(label).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Fortschritt") { model.aiModelsDestination = .index }
                    Button("Abbrechen") { model.cancelSemanticOperation() }
                }
            } else if model.semanticState.isIndexing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Suchindex: \(model.semanticState.processedCount) abgeschlossen")
                    Spacer(minLength: 0)
                    Button("Fortschritt") { model.aiModelsDestination = .index }
                    Button("Abbrechen") { model.cancelSemanticOperation() }
                }
            } else if model.searchMode == .semantic {
                semanticStatus
            }
        }.font(.system(size: 13)).padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var scopeLabel: some View {
        Label(model.searchScopeLabel, systemImage: "square.stack.3d.up").lineLimit(1)
            .accessibilityIdentifier("library.search-scope")
    }

    @ViewBuilder private var ratingLabel: some View {
        if model.minimumRating > 0 {
            Label("\(model.minimumRating)+ Sterne", systemImage: "star.fill").foregroundStyle(Theme.accent)
                .fixedSize().accessibilityIdentifier("library.active-rating")
        }
    }

    @ViewBuilder private var endSimilarityButton: some View {
        if model.similarityReference != nil {
            Button("Beenden") { model.stopFindingSimilarImages() }.fixedSize()
                .accessibilityLabel("Ähnlichkeitssuche beenden")
                .accessibilityIdentifier("library.end-similarity")
        }
    }

    private var resultsLabel: some View {
        Text(model.isProjecting ? "Suche läuft …" : "\(model.visibleAssets.count) Treffer").fixedSize()
            .accessibilityIdentifier("library.search-results")
    }

    private var resetButton: some View {
        Button("Zurücksetzen") { model.resetVisibleSearch() }.fixedSize()
            .accessibilityIdentifier("library.reset-search")
    }

    @ViewBuilder private var semanticStatus: some View {
        if case .unavailable(let reason) = model.semanticState.availability {
            status(reason.localizedDescription, action: "Einrichten", destination: .search)
        } else if let error = model.semanticError {
            status(error, action: "Suchindex öffnen", destination: .index)
        } else if model.semanticScopeIsReady, model.semanticState.indexGenerationID == nil {
            status("Suchindex fehlt", action: "Suchindex vorbereiten", destination: .index)
        } else if model.semanticState.staleCount > 0 {
            status("Suchindex veraltet · \(model.semanticState.staleCount) Bilder", action: "Suchindex aktualisieren", destination: .index)
        } else if model.semanticState.missingCount > 0 {
            status("Suchindex unvollständig · \(model.semanticState.missingCount) Bilder fehlen", action: "Suchindex fortsetzen", destination: .index)
        }
    }

    private func status(_ message: String, action: String, destination: AIModelsDestination) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library.search-status")
            Spacer(minLength: 0)
            Button(action) { model.aiModelsDestination = destination }.fixedSize()
                .accessibilityIdentifier("library.search-setup")
        }
    }
}
