import SwiftUI
import GlowroomCore
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var exporter: JPEGExportModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @EnvironmentObject private var photoMetadata: PhotoMetadataModel
    @FocusState private var focusedWorkspaceControl: WorkspaceControlFocus?
    let dataDirectory: URL
    private let localMaskModel: LocalAdjustmentEditorModel?
    @ViewState<LibraryFolder?> private var folderToRemove: LibraryFolder?
    @ViewState<Bool> private var dropTargeted = false
    @ViewState<Bool> private var showsWorkspaceErrors = false
    @StateObject private var maskWorkspace = InlineMaskWorkspace()
    @StateObject private var developWorkspace: DevelopWorkspace
    @ViewState private var focusReturnRequest: FocusReturnRequest?
    @ViewState private var pendingToolReveal: UUID?

    private struct FocusReturnRequest: Equatable {
        let target: WorkspaceControlFocus
        let identity = UUID()
    }

    init(model: LibraryModel, dataDirectory: URL, localMaskModel: LocalAdjustmentEditorModel? = nil,
         developWorkspace: DevelopWorkspace? = nil) {
        self.model = model
        self.dataDirectory = dataDirectory
        self.localMaskModel = localMaskModel
        _developWorkspace = StateObject(wrappedValue: developWorkspace ?? DevelopWorkspace())
    }

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            Rectangle().fill(Theme.line).frame(height: 1)
            GeometryReader { geometry in
                let handleSpace = (panels.showsLibrary ? 6.0 : 0) + (panels.showsTools ? 6.0 : 0)
                let widths = layout.boundedWidths(availableWidth: geometry.size.width - handleSpace, developing: model.isDeveloping)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if panels.showsLibrary {
                            Group {
                                if model.isDeveloping {
                                    DevelopInspector(library: model, focusedControl: $focusedWorkspaceControl, column: .navigation)
                                } else { sidebar }
                            }.frame(width: widths.library)
                            WorkspaceResizeHandle(horizontal: true, label: model.isDeveloping ? "Breite der Navigation" : "Breite der Bibliothek", value: panels.libraryWidth, step: 1) { width in
                                layout.update(developing: model.isDeveloping) { $0.libraryWidth = width }
                            }
                        }
                        workspace.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        if panels.showsTools {
                            WorkspaceResizeHandle(horizontal: true, label: "Breite der Werkzeuge", value: panels.toolsWidth, step: -1) { width in
                                layout.update(developing: model.isDeveloping) { $0.toolsWidth = width }
                            }
                            Group {
                                if model.isAIDeveloping { AIWorkspaceInspector(library: model) }
                                else if model.isDeveloping { DevelopInspector(library: model, focusedControl: $focusedWorkspaceControl) }
                                else { InspectorView(model: model) }
                            }.frame(width: widths.tools)
                        }
                    }
                    if model.isDeveloping, model.showsDetail, model.selectedAsset != nil, panels.showsFilmstrip {
                        let height = layout.boundedFilmstripHeight(availableHeight: max(0, geometry.size.height - 78), developing: true)
                        WorkspaceResizeHandle(horizontal: false, label: "Höhe des Filmstreifens", value: height, step: 1) { height in
                            layout.update(developing: true) { $0.filmstripHeight = height }
                        }
                        PhotoFilmstrip(model: model, height: height)
                    }
                }
            }
            if layout.isFocused {
                WorkspaceDock(layout: layout, library: model, focusedControl: $focusedWorkspaceControl)
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
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .environmentObject(maskWorkspace)
        .environmentObject(developWorkspace)
        .environment(\.developSelectionIdentity, DevelopSelectionIdentity(
            sessionID: model.aiSelectionSessionID, generation: model.aiSelectionGeneration))
        .focusedSceneValue(\.editingHistory, editingHistory)
        .environment(\.developPreviewSink, { display in
            let request = display.identity.request
            let settings = display.identity.settings
            guard isCurrentDevelopPreview(display.identity) else { return }
            developWorkspace.bind(source: request.source)
            developWorkspace.markDisplayed(source: request.source, settings: settings)
            developWorkspace.receive(display.frame.output, sourceBitmap: display.decodedSource)
            developWorkspace.receiveLevelsDisplay(display)
        })
        .environment(\.developPreviewPending, { identity in
            guard isCurrentDevelopPreview(identity) else { return }
            developWorkspace.invalidateLevelsDisplay()
        })
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: acceptDrop)
        .background(KeyboardHandler(handlesTextUndo: {
            guard let id = model.selectedID else { return false }
            return editor.hasActiveEditing(assetID: id) || maskWorkspace.model?.hasActiveChange == true
        }, handlesLevelsEscape: {
            developWorkspace.levelsPicker != nil || developWorkspace.automaticLevelsBusy
        }, action: { event in handleKey(event) }))
        .onAppear {
            if layout.isFocused, model.selectedAsset != nil {
                model.showsDetail = true
                model.workspaceMode = layout.focusOrigin.aiDeveloping == true ? .aiDevelop : .develop
            }
        }
        .onChange(of: panelVisibility) { previous, current in
            // One owner routes focus after removal; the dock and normal controls
            // must not compete to focus different buttons in the same update.
            let target = WorkspaceFocusRouting.target(previous: previous, current: current,
                                                      revealedTool: layout.revealedTool,
                                                      hasSelection: model.selectedAsset != nil,
                                                      isAIDeveloping: model.isAIDeveloping)
            focusReturnRequest = target.map { FocusReturnRequest(target: $0) }
            if target != nil { focusedWorkspaceControl = nil }
        }
        .task(id: focusReturnRequest) {
            guard let request = focusReturnRequest else { return }
            // AppKit first repairs focus after removing the old control. Restore
            // it after that update; a newer layout cancels this pending request.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedWorkspaceControl = request.target
        }
        .onChange(of: model.showsDetail) { _, detail in if !detail {
            // Empty search results are a selection change, not a request to leave focus.
            // Explicit grid commands use WorkspaceActions.showGrid instead.
            if !layout.isFocused && !model.isAIDeveloping { model.isDeveloping = false }
            model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = false
            model.previewComparisonLayout = .single
        } }
        .onChange(of: model.selectedID) { old, current in
            pendingToolReveal = nil
            if let old { editor.endEditing(assetID: old) }
            maskWorkspace.cancel()
            developWorkspace.clear()
            if let current { editor.selectEditingFunction(.adjustments, assetID: current) }
            model.comparesOriginal = false
            model.comparesCurrentSourceWithoutSettings = false
            if layout.isFocused, model.selectedAsset != nil { model.showsDetail = true; model.isDeveloping = true }
        }
        .onChange(of: previewSourceIdentity) { _, source in
            maskWorkspace.reconcile()
            developWorkspace.bind(source: source)
        }
        .onChange(of: model.editingRenderIntent) { _, _ in
            developWorkspace.endLevelsPicker()
            developWorkspace.picksWhiteBalance = false
            developWorkspace.picksDetail = false
            if model.editingRenderIntent != .currentEditing { maskWorkspace.cancel(); developWorkspace.tool = .basic }
        }
        .onChange(of: model.previewComparisonLayout) { _, current in
            if current != .single {
                developWorkspace.endLevelsPicker()
                developWorkspace.picksWhiteBalance = false
                developWorkspace.picksDetail = false
            }
        }
        .onChange(of: developWorkspace.picksWhiteBalance) { _, picking in
            if picking { model.previewComparisonLayout = .single }
        }
        .onChange(of: developWorkspace.picksDetail) { _, picking in
            if picking { model.previewComparisonLayout = .single }
        }
        .onChange(of: developWorkspace.levelsPicker) { _, picker in
            if picker != nil { model.previewComparisonLayout = .single }
        }
        .onChange(of: model.selection) { _, _ in model.reconcileSelection() }
        .onChange(of: model.search) { _, _ in model.reconcileSelection() }
        .onChange(of: model.minimumRating) { _, _ in model.reconcileSelection() }
        .sheet(isPresented: Binding(get: { exporter.isPresented }, set: { if !$0 { exporter.cancel() } })) {
            JPEGExportView(model: exporter)
        }
        .onChange(of: layout.revealRequest) { _, request in
            pendingToolReveal = request
            finishToolReveal()
        }
        .onChange(of: maskWorkspace.model?.isGenerating) { _, generating in
            if generating != true { finishToolReveal(resuming: true) }
        }
        .onChange(of: maskWorkspace.model?.isLoading) { _, loading in
            if loading != true { finishToolReveal(resuming: true) }
        }
        .onChange(of: developWorkspace.tool) { previous, current in
            if previous != current { model.previewComparisonLayout = .single }
            if let id = model.selectedID { editor.endEditing(assetID: id) }
            developWorkspace.picksWhiteBalance = false
            developWorkspace.repairSource = nil
            if previous == .masks, current != .masks, maskWorkspace.isPresented {
                if maskWorkspace.canApply {
                    if !maskWorkspace.apply() { developWorkspace.tool = .masks; return }
                } else { maskWorkspace.cancel() }
            }
            if current == .masks { openMasks() }
            if let id = model.selectedID, model.editingRenderIntent == .currentEditing,
               editor.editingFunction(assetID: id) == EditingFunction(previous) {
                editor.selectEditingFunction(EditingFunction(current), assetID: id)
            }
        }
        .onChange(of: maskWorkspace.isPresented) { _, visible in
            if !visible, developWorkspace.tool == .masks { developWorkspace.tool = .basic }
        }
        .onChange(of: model.showsDetail) { _, visible in
            if !visible { maskWorkspace.cancel(); developWorkspace.tool = .basic }
        }
        .alert("Glowroom", isPresented: Binding(get: { model.errorMessage != nil || editor.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; editor.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil; editor.errorMessage = nil }
        } message: { Text(model.errorMessage ?? editor.errorMessage ?? "") }
        .confirmationDialog("„\(folderToRemove?.name ?? "Ordner")“ aus der Bibliothek entfernen?", isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }), titleVisibility: .visible) {
            Button("Aus Bibliothek entfernen", role: .destructive) { if let folder = folderToRemove { model.removeFolder(folder.id) }; folderToRemove = nil }
            Button("Abbrechen", role: .cancel) { folderToRemove = nil }
        } message: { Text("Die Originalbilder bleiben auf deinem Mac. Für vollständig entfernte Bilder werden Bearbeitungen, Bildinformationen und Suchindexeinträge gelöscht. Erneutes Hinzufügen erfasst sie neu. Bilder in anderen eingebundenen Ordnern bleiben erhalten.") }
        .environment(\.sliderPersistenceSession, editor.sliderPersistenceSession)
    }

    private func openMasks() {
        guard let asset = model.selectedAsset, editor.canEdit, model.canModify,
              let source = try? editor.resolvedSource(for: asset) else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        editor.endEditing(assetID: asset.id)
        editor.selectEditingFunction(.masks, assetID: asset.id)
        model.comparesOriginal = false; model.comparesCurrentSourceWithoutSettings = false
        model.previewComparisonLayout = .single
        model.showsDetail = true; model.isDeveloping = true
        // Opening a canvas palette is not navigation to the ordinary edit
        // group. Keep reveal requests reserved for dock/menu destinations.
        pendingToolReveal = nil
        layout.update(developing: true) { panels in
            panels.showsTools = true
            panels.openGroups.insert(.edit)
        }
        developWorkspace.tool = .masks
        if !maskWorkspace.isPresented {
            _ = maskWorkspace.open(asset: asset, source: source.identity, settings: source.settings,
                                   editor: editor, library: model, model: localMaskModel)
        }
    }

    private func finishToolReveal(resuming: Bool = false) {
        guard let request = pendingToolReveal, request == layout.revealRequest,
              let tool = layout.revealedTool else { return }
        if maskWorkspace.isPresented {
            // Inference owns its native resources until it returns. Keep both
            // the draft and requested destination until selection is complete.
            guard maskWorkspace.model?.isGenerating != true, maskWorkspace.model?.isLoading != true else { return }
            // A failed asynchronous selection must remain visible. A later
            // explicit destination is a new decision to accept the valid draft.
            if resuming, maskWorkspace.model?.errorMessage != nil {
                pendingToolReveal = nil
                return
            }
            // Admission may fail during maintenance even with enabled UI. Keep
            // the palette and draft so the destination can be requested again.
            guard maskWorkspace.canApply, maskWorkspace.apply() else {
                pendingToolReveal = nil
                return
            }
        }
        developWorkspace.picksWhiteBalance = false
        developWorkspace.picksDetail = false
        developWorkspace.repairSource = nil
        developWorkspace.tool = .basic
        if let id = model.selectedID { editor.selectEditingFunction(EditingFunction(tool), assetID: id) }
        pendingToolReveal = nil
    }

    private var editingHistory: WorkspaceEditingHistory {
        let id = model.selectedID
        let masks = maskWorkspace.isPresented
        return WorkspaceEditingHistory(
            canUndo: editor.canEdit && (masks ? maskWorkspace.model?.canUndo == true : id.map { editor.canUndo(assetID: $0) } == true),
            canRedo: editor.canEdit && (masks ? maskWorkspace.model?.canRedo == true : id.map { editor.canRedo(assetID: $0) } == true),
            undo: { performHistory(redo: false) }, redo: { performHistory(redo: true) },
            canReset: editor.canEdit && !masks && id != nil,
            reset: {
                guard let id = model.selectedID, !maskWorkspace.isPresented else { return }
                NSApp.keyWindow?.makeFirstResponder(nil)
                ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
                developWorkspace.cancelRepairWork()
                editor.reset(assetID: id)
            }, allowsComparison: !masks)
    }

    private func performHistory(redo: Bool) {
        guard let id = model.selectedID else { return }
        // Commit a numeric field and cancel native tracking before restoring a
        // snapshot. A later native callback must not overwrite the restored edit.
        NSApp.keyWindow?.makeFirstResponder(nil)
        ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
        if maskWorkspace.isPresented {
            if redo { maskWorkspace.redo() } else { maskWorkspace.undo() }
        } else {
            developWorkspace.cancelRepairWork()
            if redo { editor.redo(assetID: id) } else { editor.undo(assetID: id) }
        }
    }

    private func isCurrentDevelopPreview(_ identity: DevelopPreviewRenderIdentity) -> Bool {
        guard let asset = model.selectedAsset, let revision = identity.revision,
              revision.assetID == asset.id, revision.editorSessionID == editor.aiEditSessionID,
              revision.editorGeneration == editor.aiEditGeneration,
              revision.localRevision == editor.localRevision(for: asset.id),
              revision.selection == DevelopSelectionIdentity(sessionID: model.aiSelectionSessionID,
                                                             generation: model.aiSelectionGeneration),
              revision.intent == model.editingRenderIntent,
              (try? editor.resolvedSource(for: asset, intent: revision.intent).identity) == identity.request.source else { return false }
        return true
    }

    private var previewSourceIdentity: AISourceIdentity? {
        guard let asset = model.selectedAsset else { return nil }
        return try? editor.resolvedSource(for: asset, intent: model.editingRenderIntent).identity
    }

    private var panels: WorkspacePanels { layout.panels(developing: model.isDeveloping) }
    private var saveStatus: WorkspaceSaveStatus { WorkspaceSaveStatus(editor: editor) }

    private var panelVisibility: WorkspacePanelVisibility {
        WorkspacePanelVisibility(isFocused: layout.isFocused, showsLibrary: panels.showsLibrary,
                                 showsTools: panels.showsTools, showsFilmstrip: panels.showsFilmstrip)
    }

    private static let brandImage: NSImage? = {
        // Classic SwiftPM's accessor can point at the development build. A
        // packaged app must load its branding from its own Resources bundle.
        let main = Bundle.main
        let containingApp = main.executableURL?.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let appURL = [main.bundleURL, containingApp].compactMap { $0 }
            .first { $0.pathExtension.lowercased() == "app" }
        let resources: Bundle?
        if let appURL {
            resources = Bundle(url: appURL.appendingPathComponent("Contents/Resources/Glowroom_Glowroom.bundle"))
        } else {
            resources = .module
        }
        guard let url = resources?.url(forResource: "BrandMark", withExtension: "png") else { return nil }
        // Cache the explicit PNG resource instead of relying on named-image lookup.
        return NSImage(contentsOf: url)
    }()

    private var appHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let image = Self.brandImage {
                    Image(nsImage: image).renderingMode(.original).resizable()
                        .interpolation(.high).aspectRatio(contentMode: .fit)
                }
            }.frame(width: 28, height: 28).accessibilityHidden(true)
            Text("Glowroom").font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 18) {
                Button {
                    WorkspaceActions.showGrid(layout, library: model)
                    model.comparesOriginal = false
                    model.comparesCurrentSourceWithoutSettings = false
                } label: { Text("Bibliothek") }
                    .foregroundStyle(!model.isDeveloping ? Theme.text : Theme.muted)
                Button { WorkspaceActions.reveal(.edit, layout: layout, library: model) } label: { Text("Entwickeln") }
                    .foregroundStyle(model.workspaceMode == .develop ? Theme.text : Theme.muted)
                    .disabled(model.selectedAsset == nil || editor.isLoading)
                Button { WorkspaceActions.reveal(.aiDevelopment, layout: layout, library: model) } label: { Text("AI Entwickeln") }
                    .foregroundStyle(model.isAIDeveloping ? Theme.text : Theme.muted)
                    .accessibilityIdentifier("workspace.ai-develop")
            }.font(.system(size: 14, weight: .medium))
            if !layout.isFocused {
                Divider().frame(height: 20)
                panelControls
            }
            Button { WorkspaceActions.toggleFocus(layout, library: model) } label: {
                if layout.isFocused { Label("Zur vorherigen Ansicht", systemImage: "viewfinder") }
                else { Image(systemName: "viewfinder").frame(width: 28, height: 30) }
            }.workspaceFocusTarget($focusedWorkspaceControl, equals: .focus) {
                WorkspaceActions.toggleFocus(layout, library: model)
            }
                .disabled(!layout.isFocused && model.selectedAsset == nil)
                .help("Bildfokus umschalten · ⇧⌘F")
                .accessibilityLabel(layout.isFocused ? "Zur vorherigen Ansicht" : "Bildfokus")
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
            } label: { Image(systemName: "externaldrive.badge.timemachine") }
                .menuStyle(.borderlessButton).fixedSize().help("Backups der Bearbeitungen")
                .accessibilityLabel("Sicherungen")
            Button {
                JPEGExportActions.present(using: exporter, library: model, editor: editor)
            } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                .disabled(model.selectedIDs.isEmpty || !model.canExportJPEG || model.isProjecting || editor.isLoading || editor.isRestoring || editor.isClosing || exporter.isPresented)
                .help("Ausgewählte Fotos als JPEG oder HDR-HEIF exportieren · ⇧⌘E")
        }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .padding(.leading, 8).padding(.trailing, 16).frame(height: 48).background(Theme.chrome)
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
            if !model.isDeveloping && (!layout.isFocused || panels.showsLibrary) {
                if layout.isFocused {
                    compactLibraryBar
                } else {
                    LibraryHeading(model: model) {
                        WorkspaceActions.showGrid(layout, library: model)
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
                DetailView(model: model, photoViewport: developWorkspace.photoViewport)
            } else {
                PhotoGridView(model: model)
            }
        }
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

    private var panelControls: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "sidebar.left", help: model.isDeveloping ? "Navigation · ⌥⌘L" : "Bibliothek · ⌥⌘L", active: panels.showsLibrary) {
                WorkspaceActions.toggleLibrary(layout, library: model)
            }.workspaceFocusTarget($focusedWorkspaceControl, equals: .library) {
                WorkspaceActions.toggleLibrary(layout, library: model)
            }
                .accessibilityValue(panels.showsLibrary ? "Geöffnet" : "Geschlossen")
            IconButton(symbol: "sidebar.right", help: "Werkzeuge · ⌘I", active: panels.showsTools) {
                WorkspaceActions.toggleTools(layout, library: model)
            }.workspaceFocusTarget($focusedWorkspaceControl, equals: .tools) {
                WorkspaceActions.toggleTools(layout, library: model)
            }
                .accessibilityValue(panels.showsTools ? "Geöffnet" : "Geschlossen")
            IconButton(symbol: "film", help: "Filmstreifen · ⌥⌘S", active: panels.showsFilmstrip) {
                WorkspaceActions.toggleFilmstrip(layout, library: model)
            }.workspaceFocusTarget($focusedWorkspaceControl, equals: .filmstrip) {
                WorkspaceActions.toggleFilmstrip(layout, library: model)
            }
                .accessibilityValue(panels.showsFilmstrip ? "Geöffnet" : "Geschlossen")
        }.fixedSize()
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
            if !model.showsDetail {
                Image(systemName: "square.grid.3x3").font(.system(size: 10))
                ResettableSlider(value: $model.gridSize, in: 150...320, neutralValue: 210).controlSize(.mini).frame(width: 90).help("Vorschaugröße")
                Image(systemName: "square.grid.2x2").font(.system(size: 11))
            }
            workspaceNotices
            if saveStatus.isBusy { ProgressView().controlSize(.mini) }
            Text(saveStatus.text)
                .foregroundStyle(saveStatus.hasError ? .orange : (saveStatus.isBusy ? Theme.muted : Theme.accent))
                .accessibilityIdentifier("workspace.saveStatus")
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
            if photoMetadata.hasManualDraft {
                Button("Bildinformationen: manuellen Entwurf prüfen") { revealNoticeTool(.metadata) }
            }
            if photoMetadata.record?.draft != nil {
                Button("AI Entwickeln: Bildtextvorschlag prüfen") { revealNoticeTool(.aiDevelopment) }
            }
            if photoMetadata.isAnalyzing {
                Button("AI Entwickeln: Bildanalyse läuft") { revealNoticeTool(.aiDevelopment) }
            }
            if photoMetadata.isSaving {
                Button("Bildinformationen: Speichern läuft") { revealNoticeTool(metadataNoticeTarget) }
            }
            if photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil {
                Button("Bildinformationen: Fehler prüfen") { revealNoticeTool(metadataNoticeTarget) }
            }
            if editor.failedArtifactCommitID != nil || editor.isReadOnly || editor.errorMessage != nil {
                Button("Bearbeitung: Speicherfehler prüfen") { revealNoticeTool(.versions) }
            }
            Divider()
            Button("Bearbeiten öffnen") { revealNoticeTool(.edit) }
        }.disabled(model.selectedAsset == nil)
    }

    private var hasWorkspaceError: Bool {
        if saveStatus.hasError || photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil { return true }
        return false
    }

    private var workspaceErrors: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hinweise prüfen").font(.headline)
            if saveStatus.hasError {
                Text(editor.errorMessage ?? "Bearbeitungen können derzeit nicht gespeichert werden.")
                if let retry = saveStatus.retryAction {
                    Button(retry.title) {
                        switch retry {
                        case .acceptedArtifact(let id): _ = editor.retryAcceptedArtifactCommit(id)
                        case .pendingChanges: Task { _ = await editor.flush() }
                        case .reload: editor.retryLoading()
                        }
                    }.disabled(!saveStatus.canRetry)
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
            Divider()
            workspaceNoticeLinks
            Button("Schließen") { showsWorkspaceErrors = false }
        }.font(.system(size: 12)).textSelection(.enabled).padding(18)
        }.frame(width: 370, height: 320)
    }

    private var noticeLabel: String {
        if photoMetadata.errorMessage != nil || photoMetadata.hasPendingRetry || photoMetadata.recovery != nil || editor.failedArtifactCommitID != nil || editor.isReadOnly || editor.errorMessage != nil { return "Fehler prüfen" }
        if photoMetadata.isAnalyzing { return "Bildinformationen: Analyse" }
        if photoMetadata.hasManualDraft || photoMetadata.record?.draft != nil { return "Entwurf vorhanden" }
        return "Hinweise"
    }

    private var metadataNoticeTarget: WorkspaceTool {
        if let recovery = photoMetadata.recovery { return recovery.proposalID == nil ? .metadata : .aiDevelopment }
        return photoMetadata.hasManualDraft ? .metadata : .aiDevelopment
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
        // Let workspace buttons activate normally while retaining photo arrows,
        // ratings and favorites immediately after a panel or focus transition.
        if focusedWorkspaceControl != nil && [49, 36, 76].contains(event.keyCode) { return false }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "z" {
                performHistory(redo: event.modifierFlags.contains(.shift))
                return true
            }
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
            if developWorkspace.levelsPicker != nil || developWorkspace.automaticLevelsBusy { developWorkspace.endLevelsPicker() }
            else if developWorkspace.picksDetail { developWorkspace.picksDetail = false }
            else if layout.isFocused { WorkspaceActions.toggleFocus(layout, library: model) }
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

/// The mounted native input surface owns the same event path used by the
/// local AppKit monitor. Keeping dispatch here also permits non-key test
/// windows to exercise routing without running an application event loop.
@MainActor
final class WorkspaceKeyboardInputView: NSView {
    fileprivate var processEvent: ((NSEvent) -> NSEvent?)?

    func process(_ event: NSEvent) -> NSEvent? {
        guard let processEvent else { return event }
        return processEvent(event)
    }
}

private struct KeyboardHandler: NSViewRepresentable {
    let handlesTextUndo: () -> Bool
    let handlesLevelsEscape: () -> Bool
    let action: (NSEvent) -> Bool
    func makeNSView(context: Context) -> WorkspaceKeyboardInputView {
        let view = WorkspaceKeyboardInputView()
        context.coordinator.view = view
        view.processEvent = { [weak coordinator = context.coordinator] event in
            guard let coordinator else { return event }
            return coordinator.process(event)
        }
        return view
    }
    func updateNSView(_ nsView: WorkspaceKeyboardInputView, context: Context) {
        context.coordinator.action = action
        context.coordinator.handlesTextUndo = handlesTextUndo
        context.coordinator.handlesLevelsEscape = handlesLevelsEscape
    }
    func makeCoordinator() -> Coordinator { Coordinator(handlesTextUndo: handlesTextUndo, handlesLevelsEscape: handlesLevelsEscape, action: action) }
    static func dismantleNSView(_ nsView: WorkspaceKeyboardInputView, coordinator: Coordinator) {
        nsView.processEvent = nil
        coordinator.stop()
    }
    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var action: (NSEvent) -> Bool
        var handlesTextUndo: () -> Bool
        var handlesLevelsEscape: () -> Bool
        var monitor: Any?
        private let menus = WorkspaceMenuTracking()
        init(handlesTextUndo: @escaping () -> Bool, handlesLevelsEscape: @escaping () -> Bool, action: @escaping (NSEvent) -> Bool) {
            self.action = action
            self.handlesTextUndo = handlesTextUndo
            self.handlesLevelsEscape = handlesLevelsEscape
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.process(event)
            }
        }
        func process(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !menus.isTracking,
                  event.modifierFlags.intersection([.control, .option]).isEmpty else { return event }
            let historyKey = event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "z"
            let levelsEscape = event.keyCode == 53 && handlesLevelsEscape()
            if window.firstResponder is NSTextView {
                guard levelsEscape || (historyKey && handlesTextUndo()) else { return event }
            } else if window.firstResponder is NSControl, !historyKey, !levelsEscape { return event }
            return action(event) ? nil : event
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            menus.stop()
        }
        deinit {
            // The notification center removes the menu tracker's selector
            // observers when it deallocates. Event monitors need explicit
            // removal even if SwiftUI did not call dismantleNSView first.
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
