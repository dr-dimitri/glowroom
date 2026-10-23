import SwiftUI
import GlowroomCore

/// AI features have their own top-level workspace. They reuse the normal
/// canvas, accepted edits and history, so changing workspaces never forks a photo.
struct AIWorkspaceInspector: View {
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var metadata: PhotoMetadataModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @EnvironmentObject private var workspace: DevelopWorkspace
    @EnvironmentObject private var masks: InlineMaskWorkspace
    @ViewState private var showsModels = false
    @ViewState private var showsSearch = false
    @ViewState private var showsSky = false
    @ViewState private var showsSubject = false
    @ViewState private var showsMetadata = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("AI Entwickeln", systemImage: "sparkles").font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                        Button { showsModels = true } label: { Image(systemName: "externaldrive") }
                            .help("LLM-Modelle verwalten").accessibilityLabel("LLM-Modelle verwalten")
                    }.padding(.top, 5)

                    if library.selectedAsset != nil,
                       workspace.tool == .masks, masks.isPresented {
                        returnButton
                        InlineMaskInspector(workspace: masks)
                    } else if let asset = library.selectedAsset, workspace.tool == .repair {
                        returnButton
                        DevelopRepairInspector(asset: asset, workspace: workspace)
                    } else {
                        if library.selectedAsset != nil {
                            AIDevelopmentView(library: library).id(library.selectedID)
                            Divider()
                            DisclosureGroup("Bildtexte und Tags vorschlagen", isExpanded: $showsMetadata) {
                                PhotoMetadataSection(model: metadata, mode: .ai).id(library.selectedID).padding(.top, 8)
                            }.font(.system(size: 12, weight: .medium))
                        } else {
                            Text("Wähle ein Foto für einen Korrekturvorschlag, Bildtexte oder KI-Masken. Modelle und Suchindex kannst du schon vorher verwalten.")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("LLM-Modelle verwalten …") { showsModels = true }
                        }
                        Divider()
                        aiTools
                    }
                }.padding(14)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Button("Rückgängig") {
                    finishInput()
                    if masks.isPresented { masks.undo() }
                    else if let id = library.selectedID { workspace.cancelRepairWork(); editor.undo(assetID: id) }
                }.disabled(!editor.canEdit || (masks.isPresented ? masks.model?.canUndo != true : library.selectedID.map { editor.canUndo(assetID: $0) } != true))
                Spacer(minLength: 0)
                Button("Wiederholen") {
                    finishInput()
                    if masks.isPresented { masks.redo() }
                    else if let id = library.selectedID { workspace.cancelRepairWork(); editor.redo(assetID: id) }
                }.disabled(!editor.canEdit || (masks.isPresented ? masks.model?.canRedo != true : library.selectedID.map { editor.canRedo(assetID: $0) } != true))
            }.controlSize(.small).padding(10)
        }.background(Theme.sidebar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ai-workspace.inspector")
            .sheet(isPresented: $showsModels) { LLMModelManagerView() }
            .sheet(isPresented: $showsSearch) { AISemanticSearchView(library: library, layout: layout) }
            .sheet(isPresented: $showsSky) { SkyMaskModelSetupView() }
            .sheet(isPresented: $showsSubject) { SubjectMattingModelSetupView() }
            .onAppear { revealMetadataIfNeeded() }
            .onChange(of: layout.revealRequest) { _, _ in
                if layout.revealedTool == .aiDevelopment { revealMetadataIfNeeded() }
            }
            .onChange(of: metadata.record?.draft?.id) { _, _ in revealMetadataIfNeeded() }
    }

    private var returnButton: some View {
        Button {
            WorkspaceActions.reveal(.aiDevelopment, layout: layout, library: library)
        } label: { Label("Zur AI-Übersicht", systemImage: "chevron.left") }
            .controlSize(.small).disabled(masks.model?.isGenerating == true)
    }

    private var aiTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weitere KI-Werkzeuge").font(.system(size: 12, weight: .medium))
            Button("Bildinhalt suchen und Suchmodell verwalten …") { showsSearch = true }
            Button("Masken anzeigen und bearbeiten") {
                activate(.masks)
            }.disabled(library.selectedAsset == nil || !editor.canEdit || !library.canModify)
            Button("Mit KI reparieren") {
                workspace.repairMode = .remove
                workspace.repairUsesAI = true
                activate(.repair)
            }.disabled(library.selectedAsset == nil || !editor.canEdit || !library.canModify)
            Menu("Weitere KI-Modelle verwalten") {
                Button("Himmelserkennung …") { showsSky = true }
                Button("BiRefNet für Motiv und Hintergrund …") { showsSubject = true }
            }
            Text("Alle Entwicklungsansichten teilen dieselben Masken. Qwen erstellt Korrektur- und Objektkonturvorschläge; Motiv, Himmel, Reparatur und Suche verwenden ihre jeweiligen lokalen Modelle.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.controlSize(.small).font(.system(size: 11))
    }

    private func activate(_ tool: DevelopCanvasTool) {
        finishInput()
        guard let id = library.selectedID else { return }
        editor.selectEditingFunction(EditingFunction(tool), assetID: id)
        library.comparesOriginal = false; library.comparesCurrentSourceWithoutSettings = false
        workspace.tool = tool
    }

    private func finishInput() {
        WorkspaceActions.finishField()
        ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
        if let id = library.selectedID { editor.endEditing(assetID: id) }
    }

    private func revealMetadataIfNeeded() {
        if metadata.record?.draft != nil || metadata.isAnalyzing || metadata.recovery?.proposalID != nil
            || metadata.errorMessage != nil || metadata.hasPendingRetry {
            showsMetadata = true
        }
    }
}

private struct AISemanticSearchView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var layout: WorkspaceLayoutModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lokale Bildsuche").font(.title2.bold())
            TextField("Bildinhalt beschreiben, z. B. Berge im Abendlicht", text: $library.semanticQuery)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                SemanticSearchControlsView(model: library)
            }.frame(maxHeight: 420)
            HStack {
                Button("Schließen") { dismiss() }
                Spacer()
                Button("Treffer in der Bibliothek zeigen") {
                    library.searchMode = .semantic
                    WorkspaceActions.showGrid(layout, library: library)
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620)
            .onAppear { library.semanticControlsExpanded = true }
    }
}
