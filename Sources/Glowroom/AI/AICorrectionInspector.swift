import SwiftUI
import GlowroomCore

/// Correction and setup reuse the common develop context.
/// The enclosing inspector owns scrolling, histogram and editing history.
struct AICorrectionInspector: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AIDevelopmentView(library: library)
            AIDevelopmentManagementControls(library: library)
        }.font(.system(size: 13))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ai-correction.inspector")
    }
}

/// Keep existing setup/search destinations reachable without a selected photo
/// until the library navigation consolidates their management dialogs.
struct AIDevelopmentManagementControls: View {
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var layout: WorkspaceLayoutModel
    @ViewState private var showsSearch = false
    @ViewState private var showsSky = false
    @ViewState private var showsSubject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Bildinhalt suchen …") { showsSearch = true }
                .accessibilityIdentifier("ai-development.search")
            Menu("Weitere KI-Modelle") {
                Button("Himmelserkennung …") { showsSky = true }
                Button("Motiv und Hintergrund …") { showsSubject = true }
            }.accessibilityIdentifier("ai-development.model-tools")
        }.font(.system(size: 13))
            .sheet(isPresented: $showsSearch) { AISemanticSearchView(library: library, layout: layout) }
            .sheet(isPresented: $showsSky) { SkyMaskModelSetupView() }
            .sheet(isPresented: $showsSubject) { SubjectMattingModelSetupView() }
    }
}

struct AISemanticSearchView: View {
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
                    library.useSemanticTextSearch()
                    WorkspaceActions.showGrid(layout, library: library)
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620)
            .onAppear { library.semanticControlsExpanded = true }
    }
}
