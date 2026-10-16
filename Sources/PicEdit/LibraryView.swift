import SwiftUI
import PicEditCore
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var exporter: JPEGExportModel
    let dataDirectory: URL
    @ViewState<LibraryFolder?> private var folderToRemove: LibraryFolder?
    @ViewState<Bool> private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                sidebar.frame(width: 218)
                Rectangle().fill(Theme.line).frame(width: 1)
                workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showsInspector || model.isDeveloping {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    if model.isDeveloping { DevelopInspector(library: model).frame(width: 300) }
                    else { InspectorView(model: model).frame(width: 260) }
                }
            }
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
        .onChange(of: model.showsDetail) { _, detail in if !detail { model.isDeveloping = false; model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = false } }
        .onChange(of: model.selectedID) { old, _ in
            if let old { editor.endEditing(assetID: old) }
            model.comparesOriginal = false
            model.comparesCurrentSourceWithoutSettings = false
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

    private var appHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture").font(.system(size: 23, weight: .light)).foregroundStyle(Theme.accent)
            Text("picedit").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.5)
            Text("/  Dein Blick. Deine Bibliothek.").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.leading, 13)
            Spacer()
            HStack(spacing: 20) {
                Button {
                    model.isDeveloping = false
                    model.comparesOriginal = false
            model.comparesCurrentSourceWithoutSettings = false
                    model.showsDetail = false
                } label: { Label("Bibliothek", systemImage: "square.grid.2x2.fill") }
                    .foregroundStyle(!model.isDeveloping ? Theme.accent : Theme.muted)
                Button {
                    model.isDeveloping = true
                    model.showsDetail = true
                    model.showsInspector = true
                } label: { Label("Entwickeln", systemImage: "slider.horizontal.3") }
                    .foregroundStyle(model.isDeveloping ? Theme.accent : Theme.muted)
                    .disabled(model.selectedAsset == nil || editor.isLoading)
                Button {
                    JPEGExportActions.present(using: exporter, library: model, editor: editor)
                } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                    .foregroundStyle(Theme.muted)
                    .disabled(model.selectedIDs.isEmpty || !model.canExportJPEG || model.isProjecting || editor.isLoading || editor.isRestoring || editor.isClosing || exporter.isPresented)
                    .help("Ausgewählte Fotos als JPEG exportieren · ⇧⌘E")
                Menu {
                    Button("Bearbeitungen sichern …") { EditingBackupActions.create(using: editor) }.disabled(!editor.canBackUp)
                    Button("Backup wiederherstellen …") { EditingBackupActions.chooseRestore(using: editor, directory: dataDirectory) }
                        .disabled(editor.isLoading || editor.isRestoring || editor.isBackingUp || editor.isClosing)
                    Divider()
                    Text("Automatisch täglich · letzte 7 Sicherungen")
                    Text("Bearbeitungen und generierte Pixel · Originale separat sichern")
                } label: { Image(systemName: "externaldrive.badge.timemachine") }
                    .menuStyle(.borderlessButton).fixedSize().help("Backups der Bearbeitungen")
                    .accessibilityLabel("Backups der Bearbeitungen")
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
        }.padding(.leading, 82).padding(.trailing, 25).frame(height: 66).background(Theme.sidebar)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Bibliothek").padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 13)
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
            controlBar
            if model.searchMode == .semantic || model.semanticOperationLabel != nil || model.semanticState.isIndexing || model.semanticImportReview != nil {
                SemanticSearchControlsView(model: model)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
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

    private var controlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                IconButton(symbol: "square.grid.2x2", help: "Rasteransicht", active: !model.showsDetail) { model.showsDetail = false }
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
            IconButton(symbol: "sidebar.right", help: "Bildinformationen · ⌘I", active: model.showsInspector) { model.showsInspector.toggle() }
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
            Text("LOKAL AUF DEINEM MAC").font(.system(size: 8, weight: .medium)).tracking(1).padding(.leading, 18)
        }.font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.horizontal, 20).frame(height: 35)
            .background(Theme.sidebar).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
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
        case 53: model.showsDetail = false
        case 49:
            guard model.selectedAsset != nil else { return false }
            model.showsDetail.toggle()
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
