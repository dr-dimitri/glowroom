import SwiftUI
import PicEditCore
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var exporter: JPEGExportModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @EnvironmentObject private var assistant: AIAssistantModel
    @EnvironmentObject private var imageAnalysis: ImageAnalysisModel
    @EnvironmentObject private var photoMetadata: PhotoMetadataModel
    @FocusState private var focusReturnButton: Bool
    let dataDirectory: URL
    @ViewState<LibraryFolder?> private var folderToRemove: LibraryFolder?
    @ViewState<Bool> private var dropTargeted = false
    @ViewState<Bool> private var showsWorkspaceErrors = false

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            Rectangle().fill(Theme.line).frame(height: 1)
            GeometryReader { geometry in
                let handleSpace = (panels.showsLibrary ? 6.0 : 0) + (panels.showsTools ? 6.0 : 0)
                let widths = layout.boundedWidths(availableWidth: geometry.size.width - handleSpace, developing: model.isDeveloping)
                HStack(spacing: 0) {
                    if panels.showsLibrary {
                        sidebar.frame(width: widths.library)
                        WorkspaceResizeHandle(horizontal: true, label: "Breite der Bibliothek", value: panels.libraryWidth, step: 1) { width in
                            layout.update(developing: model.isDeveloping) { $0.libraryWidth = width }
                        }
                    }
                    workspace.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    if panels.showsTools {
                        WorkspaceResizeHandle(horizontal: true, label: "Breite der Werkzeuge", value: panels.toolsWidth, step: -1) { width in
                            layout.update(developing: model.isDeveloping) { $0.toolsWidth = width }
                        }
                        Group {
                            if model.isDeveloping { DevelopInspector(library: model) }
                            else { InspectorView(model: model) }
                        }.frame(width: widths.tools)
                    }
                }
            }
            if layout.isFocused { WorkspaceDock(layout: layout, library: model) }
            if let error = model.coordinationError {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speicherzuordnung muss geprüft werden").font(.callout)
                    Text(error).font(.caption).textSelection(.enabled)
                    Button("Speicherzuordnung erneut prüfen") { model.retryCoordinatedRecovery() }
                        .disabled(model.isRetryingCoordination || model.isClosing)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            statusBar
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: acceptDrop)
        .background(KeyboardHandler { event in handleKey(event) })
        .onAppear {
            if layout.isFocused, model.selectedAsset != nil { model.showsDetail = true; model.isDeveloping = true }
        }
        .onChange(of: panels.showsTools) { old, visible in
            if old && !visible { focusReturnButton = true }
        }
        .onChange(of: model.showsDetail) { _, detail in if !detail {
            // Empty search results are a selection change, not a request to leave focus.
            // Explicit grid commands use WorkspaceActions.showGrid instead.
            if !layout.isFocused { model.isDeveloping = false }
            model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = false
        } }
        .onChange(of: model.selectedID) { old, _ in
            if let old { editor.endEditing(assetID: old) }
            model.comparesOriginal = false
            model.comparesCurrentSourceWithoutSettings = false
            if layout.isFocused, model.selectedAsset != nil { model.showsDetail = true; model.isDeveloping = true }
        }
        .onChange(of: model.selection) { _, _ in model.reconcileSelection() }
        .onChange(of: model.search) { _, _ in model.reconcileSelection() }
        .onChange(of: model.minimumRating) { _, _ in model.reconcileSelection() }
        .sheet(isPresented: Binding(get: { exporter.isPresented }, set: { if !$0 { exporter.cancel() } })) {
            JPEGExportView(model: exporter)
        }
        .alert("PicEdit", isPresented: Binding(get: { model.errorMessage != nil || editor.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; editor.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil; editor.errorMessage = nil }
        } message: { Text(model.errorMessage ?? editor.errorMessage ?? "") }
        .confirmationDialog("„\(folderToRemove?.name ?? "Ordner")“ aus der Bibliothek entfernen?", isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }), titleVisibility: .visible) {
            Button("Aus Bibliothek entfernen", role: .destructive) { if let folder = folderToRemove { model.removeFolder(folder.id) }; folderToRemove = nil }
            Button("Abbrechen", role: .cancel) { folderToRemove = nil }
        } message: { Text("Die Originalbilder bleiben auf deinem Mac. Bilder, die auch in einem anderen eingebundenen Ordner liegen, behalten ihre Bewertungen. Die übrigen Einträge werden aus dem Katalog entfernt.") }
    }

    private var panels: WorkspacePanels { layout.panels(developing: model.isDeveloping) }

    private var appHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.accent)
            Text("picedit").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.5)
            if layout.isFocused {
                Text("Bildfokus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            } else {
                Button {
                    WorkspaceActions.finishField()
                    model.isDeveloping = false
                    model.comparesOriginal = false
                    model.comparesCurrentSourceWithoutSettings = false
                    model.showsDetail = false
                } label: { Label("Bibliothek", systemImage: "square.grid.2x2.fill") }
                    .foregroundStyle(!model.isDeveloping ? Theme.accent : Theme.muted)
                Button {
                    WorkspaceActions.reveal(.edit, layout: layout, library: model)
                } label: { Label("Entwickeln", systemImage: "slider.horizontal.3") }
                    .foregroundStyle(model.isDeveloping ? Theme.accent : Theme.muted)
                    .disabled(model.selectedAsset == nil || editor.isLoading)
            }
            Spacer(minLength: 6)
            Button { WorkspaceActions.toggleFocus(layout, library: model) } label: {
                Label(layout.isFocused ? "Zur vorherigen Ansicht" : "Bildfokus", systemImage: "viewfinder")
                    .padding(.horizontal, 9).frame(height: 30)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            }.foregroundStyle(Theme.accent).focused($focusReturnButton)
                .disabled(!layout.isFocused && model.selectedAsset == nil)
                .help("Bildfokus umschalten · ⇧⌘F")
                .accessibilityIdentifier("workspace.focus")
            Menu("Ansicht") { WorkspaceViewCommands(layout: layout, library: model) }
                .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button("Bearbeitungen sichern …") { EditingBackupActions.create(using: editor) }.disabled(!editor.canBackUp)
                Button("Backup wiederherstellen …") { EditingBackupActions.chooseRestore(using: editor, directory: dataDirectory) }
                    .disabled(editor.isLoading || editor.isRestoring || editor.isBackingUp || editor.isClosing)
                Divider()
                Text("Automatisch täglich · letzte 7 Sicherungen")
                Text("Bearbeitungen und generierte Pixel · Originale separat sichern")
            } label: { Label("Sicherungen", systemImage: "externaldrive.badge.timemachine") }
                .menuStyle(.borderlessButton).fixedSize().help("Backups der Bearbeitungen")
            Button {
                JPEGExportActions.present(using: exporter, library: model, editor: editor)
            } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                .foregroundStyle(Theme.accent)
                .disabled(model.selectedIDs.isEmpty || !model.canExportJPEG || model.isProjecting || editor.isLoading || editor.isRestoring || editor.isClosing || exporter.isPresented)
                .help("Ausgewählte Fotos als JPEG exportieren · ⇧⌘E")
        }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .padding(.leading, 82).padding(.trailing, 20).frame(height: 54).background(Theme.sidebar)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Bibliothek")
                Spacer()
                IconButton(symbol: "xmark", help: "Bibliothek schließen") { WorkspaceActions.toggleLibrary(layout, library: model) }
            }.padding(.horizontal, 15).frame(height: 48)
            navRow("Alle Fotos", symbol: "square.stack.3d.up", count: model.assets.count, selection: .all)
            navRow("Favoriten", symbol: "heart", count: model.favoriteCount, selection: .favorites)
            navRow("Zuletzt hinzugefügt", symbol: "clock", count: nil, selection: .recent)
            HStack {
                SectionLabel(text: "Ordner")
                Spacer()
                Button { model.chooseFolders() } label: { Image(systemName: "plus").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Ordner hinzufügen").disabled(!model.canModify || model.isImporting)
            }.padding(.horizontal, 22).padding(.top, 32).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 3) {
                    if model.folders.isEmpty {
                        Text("Deine Fotoordner\nerscheinen hier.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 8)
                    }
                    ForEach(model.folders) { folder in
                        FolderTreeRow(model: model, folder: folder, node: model.folderTree(for: folder)) { folderToRemove = $0 }
                    }
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 7) {
                    Circle().fill(model.isReadOnly ? Color.orange : Theme.accent).frame(width: 5, height: 5)
                    Text(model.isReadOnly ? "Katalog nicht verfügbar" : "Lokaler Katalog").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Button { model.chooseFolders() } label: { Label("Ordner hinzufügen", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(AccentButton()).disabled(!model.canModify || model.isImporting)
                Text("Originale bleiben unverändert.").font(.system(size: 9)).foregroundStyle(Theme.muted.opacity(0.8)).frame(maxWidth: .infinity)
            }.padding(18)
        }.background(Theme.sidebar)
    }

    private func navRow(_ label: String, symbol: String, count: Int?, selection: LibrarySelection) -> some View {
        let active = model.selection == selection
        return Button { model.selection = selection } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 17)
                Text(label).font(.system(size: 12, weight: active ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 2)
                if let count { Text(count.formatted()).font(.system(size: 10, design: .monospaced)).foregroundStyle(active ? Theme.accent : Theme.muted) }
            }.foregroundStyle(active ? Theme.accent : Color.white.opacity(0.68)).padding(.horizontal, 12).frame(height: 37)
                .background(active ? Theme.accent.opacity(0.085) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 10)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !layout.isFocused || panels.showsLibrary {
                if layout.isFocused {
                    compactLibraryBar
                } else {
                    libraryHeading
                    ViewThatFits(in: .horizontal) {
                        controlBar
                        compactControlBar
                    }
                }
            if model.searchMode == .semantic || model.semanticOperationLabel != nil || model.semanticState.isIndexing || model.semanticImportReview != nil {
                ScrollView([.horizontal, .vertical]) {
                    SemanticSearchControlsView(model: model).frame(minWidth: 420)
                }.frame(height: 150)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            }
            if model.isLoading {
                ProgressView("Bibliothek wird geöffnet …").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleAssets.isEmpty && model.isProjecting {
                ProgressView("Fotoauswahl wird aktualisiert …").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleAssets.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.showsDetail {
                DetailView(model: model)
            } else {
                PhotoGridView(model: model)
            }
        }
    }

    private var libraryHeading: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Deine Bibliothek")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.title).font(.system(size: 27, weight: .semibold)).tracking(-0.7).lineLimit(1)
                    if model.isProjecting || model.isUpdatingCatalog {
                        ProgressView().controlSize(.small).help("Fotoauswahl wird aktualisiert …")
                    } else {
                        Text(model.visibleAssets.count.formatted()).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                }
                Text(model.subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(model.searchMode == .literal ? "Fotos wörtlich suchen …" : "Bildinhalt auf Deutsch/Englisch …", text: Binding(
                    get: { model.searchMode == .literal ? model.search : model.semanticQuery },
                    set: { if model.searchMode == .literal { model.search = $0 } else { model.semanticQuery = $0 } }))
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel(model.searchMode == .literal ? "Wörtliche Fotosuche" : "Semantische Bildsuche")
                if !(model.searchMode == .literal ? model.search : model.semanticQuery).isEmpty {
                    Button { if model.searchMode == .literal { model.search = "" } else { model.semanticQuery = "" } }
                        label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }.buttonStyle(.plain)
                }
            }.padding(10).frame(width: model.searchMode == .literal ? 175 : 240).background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        }.padding(.horizontal, 26).padding(.top, 27).padding(.bottom, 23)
    }


    private var compactLibraryBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField(model.searchMode == .literal ? "Fotos suchen …" : "Bildinhalt suchen …", text: Binding(
                get: { model.searchMode == .literal ? model.search : model.semanticQuery },
                set: { if model.searchMode == .literal { model.search = $0 } else { model.semanticQuery = $0 } }))
                .textFieldStyle(.plain).frame(minWidth: 60)
                .accessibilityLabel(model.searchMode == .literal ? "Wörtliche Fotosuche" : "Semantische Bildsuche")
            libraryOptionsMenu
        }.font(.system(size: 11)).padding(.horizontal, 14).frame(height: 48)
    }

    private var compactControlBar: some View {
        HStack(spacing: 8) {
            libraryOptionsMenu
            Spacer(minLength: 0)
            IconButton(symbol: "arrow.clockwise", help: "Ordner aktualisieren") { model.refreshCurrentFolder() }
                .disabled(model.isImporting || model.folders.isEmpty || !model.canModify)
            IconButton(symbol: "sidebar.left", help: "Bibliothek · ⌥⌘L", active: panels.showsLibrary) { WorkspaceActions.toggleLibrary(layout, library: model) }
            IconButton(symbol: "sidebar.right", help: "Werkzeuge · ⌘I", active: panels.showsTools) { WorkspaceActions.toggleTools(layout, library: model) }
        }.padding(.horizontal, 14).frame(height: 48)
    }

    private var libraryOptionsMenu: some View {
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
            Button("Rasteransicht") { WorkspaceActions.showGrid(layout, library: model) }
            Button("Einzelbildansicht") { if model.selectedAsset != nil { model.showsDetail = true } }
                .disabled(model.selectedAsset == nil)
            Button("Ordner aktualisieren") { model.refreshCurrentFolder() }
                .disabled(model.isImporting || model.folders.isEmpty || !model.canModify)
        } label: { Label("Filter & Sortierung", systemImage: "line.3.horizontal.decrease") }
            .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            .foregroundStyle(model.minimumRating > 0 || model.searchMode == .semantic ? Theme.accent : Theme.muted)
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                IconButton(symbol: "square.grid.2x2", help: "Rasteransicht", active: !model.showsDetail) { WorkspaceActions.showGrid(layout, library: model) }
                IconButton(symbol: "rectangle", help: "Einzelbildansicht · Leertaste", active: model.showsDetail) { if model.selectedAsset != nil { model.showsDetail = true } }
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 18).padding(.horizontal, 7)
            Menu {
                Button("Alle Bewertungen") { model.minimumRating = 0 }
                ForEach(1...5, id: \.self) { value in Button("Mindestens \(value) Sterne") { model.minimumRating = value } }
            } label: {
                HStack(spacing: 6) { Image(systemName: "line.3.horizontal.decrease"); Text(model.minimumRating == 0 ? "Alle Bewertungen" : "\(model.minimumRating)+ Sterne") }
                    .font(.system(size: 10)).foregroundStyle(model.minimumRating == 0 ? Theme.muted : Theme.accent)
            }.menuStyle(.borderlessButton).fixedSize()
            Picker("Suchmodus", selection: $model.searchMode) {
                ForEach(LibrarySearchMode.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).font(.system(size: 10)).fixedSize()
            Spacer(minLength: 8)
            Menu {
                Picker("Sortieren", selection: $model.sort) { ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) } }
            } label: { Label(model.sort.rawValue, systemImage: "arrow.down").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                .menuStyle(.borderlessButton).fixedSize()
            IconButton(symbol: "arrow.clockwise", help: "Ordner aktualisieren") { model.refreshCurrentFolder() }.disabled(model.isImporting || model.folders.isEmpty || !model.canModify)
            IconButton(symbol: "sidebar.left", help: "Bibliothek · ⌥⌘L", active: panels.showsLibrary) { WorkspaceActions.toggleLibrary(layout, library: model) }
            IconButton(symbol: "sidebar.right", help: "Werkzeuge · ⌘I", active: panels.showsTools) { WorkspaceActions.toggleTools(layout, library: model) }
        }.padding(.horizontal, 22).frame(height: 48)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Theme.panel).frame(width: 110, height: 90).rotationEffect(.degrees(-12)).offset(x: -16, y: 2)
                RoundedRectangle(cornerRadius: 16).fill(Theme.elevated).frame(width: 110, height: 90).rotationEffect(.degrees(9)).offset(x: 12, y: -7)
                Image(systemName: model.folders.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass").font(.system(size: 33, weight: .ultraLight)).foregroundStyle(Theme.accent).offset(y: -5)
            }.frame(height: 132).padding(.bottom, 22)
            Text(model.isReadOnly ? "Katalog nicht verfügbar" : model.folders.isEmpty ? "Platz für deinen Blick." : "Keine passenden Fotos")
                .font(.system(size: 25, weight: .medium)).tracking(-0.5)
            Text(model.isReadOnly ? "Der vorhandene Katalog wurde zum Schutz deiner Daten nicht verändert." : model.folders.isEmpty ? "Füge deinen ersten Fotoordner hinzu und entdecke\ndeine Bilder in einer neuen Übersicht." : "Wähle einen anderen Ordner oder passe\ndeine Suche und Bewertungsfilter an.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(5).padding(.top, 12)
            if model.folders.isEmpty && !model.isReadOnly {
                Button { model.chooseFolders() } label: { Label("Fotoordner hinzufügen", systemImage: "plus") }
                    .buttonStyle(AccentButton()).padding(.top, 25).disabled(model.isImporting || !model.canModify)
                Text("oder einen Ordner hierher ziehen  ·  ⌘O").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 15)
                HStack(spacing: 15) { ForEach(["JPEG", "HEIC", "PNG", "TIFF", "RAW*"], id: \.self) { Text($0).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1) } }
                    .foregroundStyle(Theme.muted.opacity(0.65)).padding(.top, 35)
                Text("* abhängig von der Kameraunterstützung in macOS").font(.system(size: 9)).foregroundStyle(Theme.muted.opacity(0.55)).padding(.top, 8)
            } else if !model.search.isEmpty || !model.semanticQuery.isEmpty || !model.semanticLiteralFilter.isEmpty || model.minimumRating > 0 {
                Button("Filter zurücksetzen") {
                    model.search = ""; model.semanticQuery = ""; model.semanticLiteralFilter = ""; model.minimumRating = 0
                }.buttonStyle(AccentButton()).padding(.top, 23)
            }
        }.padding(30)
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.isImporting {
                ProgressView().controlSize(.mini)
                Text(model.importStatus).lineLimit(1)
                Button("Abbrechen") { model.cancelImport() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "photo.stack").font(.system(size: 10))
                Text(editor.notice ?? model.notice ?? "\(model.visibleAssets.count) Fotos · \(model.folders.count) Ordner").lineLimit(1)
                if model.notice != nil || editor.notice != nil { Button { model.notice = nil; editor.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plain) }
            }
            Spacer()
            if !model.selectedIDs.isEmpty {
                Text("\(model.selectedIDs.count) ausgewählt")
            }
            if editor.isReadOnly && editor.hasPendingChanges {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Ungespeicherte Änderungen · Erneut versuchen") { Task { _ = await editor.flush() } }
                    .buttonStyle(.plain).foregroundStyle(.orange).disabled(editor.isSaving)
            } else if editor.isSaving || editor.hasPendingChanges {
                ProgressView().controlSize(.mini)
                Text("Bearbeitung wird gespeichert …")
            }
            if !model.showsDetail {
                Image(systemName: "square.grid.3x3").font(.system(size: 10))
                Slider(value: $model.gridSize, in: 150...320).controlSize(.mini).frame(width: 90).help("Vorschaugröße")
                Image(systemName: "square.grid.2x2").font(.system(size: 11))
            }
            workspaceNotices
            if !editor.isSaving && !editor.hasPendingChanges {
                Text(editor.isReadOnly ? "Speichern nicht verfügbar" : "Bearbeitung gespeichert")
                    .foregroundStyle(editor.isReadOnly ? .orange : Theme.accent)
            }
        }.font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.horizontal, 20).frame(height: 35)
            .background(Theme.sidebar).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    @ViewBuilder private var workspaceNotices: some View {
        if hasWorkspaceError {
            Button { showsWorkspaceErrors = true } label: {
                Label("Fehler prüfen", systemImage: "exclamationmark.triangle")
            }.buttonStyle(.plain).foregroundStyle(.orange)
                .popover(isPresented: $showsWorkspaceErrors) { workspaceErrors }
        } else {
            Menu {
                workspaceNoticeLinks
            } label: {
                Label(noticeLabel, systemImage: "info.circle")
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(Theme.accent)
                .accessibilityLabel("Hinweise: \(noticeLabel)")
        }
    }

    private var workspaceNoticeLinks: some View {
        Group {
            switch assistant.state {
            case .generating: Button("Assistent läuft") { revealNoticeTool(.assistant) }
            case .previewing: Button("Assistent: Vorschlag prüfen") { revealNoticeTool(.assistant) }
            case .failed: Button("Assistent: Fehler prüfen") { revealNoticeTool(.assistant) }
            default: EmptyView()
            }
            switch imageAnalysis.state {
            case .analyzing: Button("Bildanalyse läuft") { revealNoticeTool(.analysis) }
            case .ready: Button("Bildanalyse: Ergebnis anzeigen") { revealNoticeTool(.analysis) }
            case .failed: Button("Bildanalyse: Fehler prüfen") { revealNoticeTool(.analysis) }
            default: EmptyView()
            }
            if photoMetadata.hasManualDraft || photoMetadata.record?.draft != nil {
                Button("Bildinformationen: Entwurf prüfen") { revealNoticeTool(.metadata) }
            }
            if photoMetadata.isAnalyzing || photoMetadata.isSaving {
                Button("Bildinformationen: Auftrag läuft") { revealNoticeTool(.metadata) }
            }
            if photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil {
                Button("Bildinformationen: Fehler prüfen") { revealNoticeTool(.metadata) }
            }
            if editor.failedArtifactCommitID != nil || editor.isReadOnly || editor.errorMessage != nil {
                Button("Bearbeitung: Speicherfehler prüfen") { revealNoticeTool(.versions) }
            }
            Divider()
            Button("Bearbeiten öffnen") { revealNoticeTool(.edit) }
        }.disabled(model.selectedAsset == nil)
    }

    private var hasWorkspaceError: Bool {
        if editor.isReadOnly || editor.errorMessage != nil || editor.failedArtifactCommitID != nil || photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil { return true }
        if case .failed = assistant.state { return true }
        if case .failed = imageAnalysis.state { return true }
        return false
    }

    private var workspaceErrors: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hinweise prüfen").font(.headline)
            if editor.isReadOnly || editor.errorMessage != nil || editor.failedArtifactCommitID != nil {
                Text(editor.errorMessage ?? "Bearbeitungen können derzeit nicht gespeichert werden.")
                if let id = editor.failedArtifactCommitID {
                    Button("Angenommenen Bildstand erneut speichern") { _ = editor.retryAcceptedArtifactCommit(id) }
                        .disabled(editor.isCommitting || editor.isRestoring || editor.isBackingUp)
                } else if editor.hasPendingChanges {
                    Button("Änderungen erneut speichern") { Task { _ = await editor.flush() } }
                        .disabled(editor.isSaving || editor.isRestoring || editor.isBackingUp || editor.isCommitting || editor.isClosing)
                } else {
                    Button("Bearbeitungen erneut laden") { editor.retryLoading() }
                        .disabled(editor.isLoading || editor.isSaving || editor.isRestoring || editor.isBackingUp || editor.isCommitting || editor.isClosing)
                }
            }
            if let error = photoMetadata.errorMessage { Text(error) }
            if let recovery = photoMetadata.recovery {
                Text(recovery.message)
                Button("Metadatenentwurf bearbeiten") { photoMetadata.recoverUnsavedDraft() }
            }
            if photoMetadata.hasPendingRetry {
                Button("Angenommenen Metadatenauftrag erneut speichern") { photoMetadata.retryAcceptedWrite() }
                    .disabled(!photoMetadata.canRetryAcceptedWrite)
            }
            if photoMetadata.errorMessage != nil {
                Button("Bildinformationen erneut laden") { photoMetadata.retryLoading() }
                    .disabled(photoMetadata.isSaving || photoMetadata.isClosing)
            }
            if case .failed(let message) = assistant.state { Text("Assistent: \(message)") }
            if case .failed(let message) = imageAnalysis.state { Text("Bildanalyse: \(message)") }
            Divider()
            workspaceNoticeLinks
            Button("Schließen") { showsWorkspaceErrors = false }
        }.font(.system(size: 12)).textSelection(.enabled).padding(18)
        }.frame(width: 370, height: 320)
    }

    private var noticeLabel: String {
        if photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil || editor.failedArtifactCommitID != nil || editor.isReadOnly || editor.errorMessage != nil { return "Fehler prüfen" }
        if case .failed = assistant.state { return "Assistent: Fehler" }
        if case .failed = imageAnalysis.state { return "Analyse: Fehler" }
        if case .generating = assistant.state { return "Assistent läuft" }
        if imageAnalysis.state == .analyzing || photoMetadata.isAnalyzing { return "Analyse läuft" }
        if assistant.state == .previewing { return "Vorschlag unbestätigt" }
        if photoMetadata.hasManualDraft || photoMetadata.record?.draft != nil { return "Entwurf vorhanden" }
        if imageAnalysis.result != nil { return "Analyseergebnis" }
        return "Hinweise"
    }

    private func reveal(_ tool: WorkspaceTool) { WorkspaceActions.reveal(tool, layout: layout, library: model) }

    private func revealNoticeTool(_ tool: WorkspaceTool) {
        showsWorkspaceErrors = false
        reveal(tool)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.canModify, !model.isImporting else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        continuation.resume(returning: url)
                    }
                }
                if let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { urls.append(url) }
            }
            if urls.isEmpty { model.notice = "Ziehe einen Fotoordner in das Fenster, um ihn hinzuzufügen." }
            else { model.enqueueFolders(urls) }
        }
        return true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            guard event.charactersIgnoringModifiers?.lowercased() == "a",
                  event.modifierFlags.intersection([.control, .option, .shift]).isEmpty else { return false }
            model.selectAll()
            return true
        }
        let extending = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: model.navigate(-1, extending: extending)
        case 124: model.navigate(1, extending: extending)
        case 125: model.navigate(model.showsDetail ? 1 : model.gridColumnCount, extending: extending)
        case 126: model.navigate(model.showsDetail ? -1 : -model.gridColumnCount, extending: extending)
        case 53:
            if layout.isFocused { WorkspaceActions.toggleFocus(layout, library: model) }
            else { model.showsDetail = false }
        case 49:
            guard model.selectedAsset != nil else { return false }
            if layout.isFocused { WorkspaceActions.showGrid(layout, library: model) }
            else { model.showsDetail.toggle() }
        default:
            guard model.selectedAsset != nil else { return false }
            if let number = Int(event.charactersIgnoringModifiers ?? ""), (0...5).contains(number) { model.setRating(number) }
            else if event.charactersIgnoringModifiers?.lowercased() == "f" { model.toggleFavorite() }
            else { return false }
        }
        return true
    }
}

private struct KeyboardHandler: NSViewRepresentable {
    let action: (NSEvent) -> Bool
    func makeNSView(context: Context) -> NSView { let view = NSView(); context.coordinator.view = view; return view }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }
    final class Coordinator {
        weak var view: NSView?
        var action: (NSEvent) -> Bool
        var monitor: Any?
        init(action: @escaping (NSEvent) -> Bool) {
            self.action = action
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl),
                      event.modifierFlags.intersection([.control, .option]).isEmpty else { return event }
                return self.action(event) ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        deinit { stop() }
    }
}
