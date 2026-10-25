import SwiftUI
import UniformTypeIdentifiers
import GlowroomCore

struct DevelopPresetsPanel: View {
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var editor: EditingModel
    @EnvironmentObject private var workspace: DevelopWorkspace
    @StateObject private var model: DevelopPresetsModel
    @ViewState private var expanded = false
    @ViewState private var name = ""
    @ViewState private var naming: Naming?
    private enum Naming: String, Identifiable { case save, rename; var id: String { rawValue } }

    init(library: LibraryModel, model: DevelopPresetsModel? = nil) {
        self.library = library
        _model = StateObject(wrappedValue: model ?? DevelopPresetsModel())
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Persönliche Vorgabe", selection: Binding(get: { model.selectedID }, set: { model.choose($0) })) {
                    Text("Vorgabe auswählen").tag(Optional<UUID>.none)
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().accessibilityLabel("Persönliche Entwicklungsvorgabe")
                    .accessibilityIdentifier("develop.presets.selection")
                DevelopPresetGroupPicker(groups: $model.groups,
                    available: model.selected?.patch.groups ?? Set(DevelopPresetGroup.allCases))
                HStack {
                    Button("Vorschau") { model.showPreview(library: library, editor: editor, workspace: workspace) }
                        .disabled(model.selected == nil || model.groups.isEmpty || model.isWorking || !editor.canEdit)
                        .accessibilityIdentifier("develop.presets.preview")
                    if model.isWorking { ProgressView().controlSize(.small) }
                }
                if model.hasPreview {
                    HStack {
                        Button("Übernehmen") { model.apply(library: library, editor: editor) }
                            .disabled(!editor.canEdit || model.isWorking || library.comparesOriginal
                                      || library.comparesCurrentSourceWithoutSettings)
                            .accessibilityIdentifier("develop.presets.apply")
                        Button("Verwerfen") { model.discard() }
                            .accessibilityIdentifier("develop.presets.discard")
                    }
                }
                HStack {
                    Button("Speichern …") { name = ""; naming = .save }
                        .disabled(model.groups.isEmpty || !editor.canEdit)
                        .accessibilityIdentifier("develop.presets.save")
                    Menu("Verwalten") {
                        Button("Umbenennen …") { name = model.selected?.name ?? ""; naming = .rename }
                            .disabled(model.selected == nil)
                        Button("Löschen", role: .destructive) { Task { await model.delete() } }
                            .disabled(model.selected == nil)
                        Divider()
                        Button("Importieren …", action: importPreset)
                        Button("Exportieren …", action: exportPreset).disabled(model.selected == nil)
                    }.accessibilityLabel("Entwicklungsvorgaben verwalten")
                }
                if let status = model.status {
                    Text(status).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("develop.presets.status")
                }
                DevelopTransferControls(library: library, editor: editor, model: editor.developTransfer)
            }.padding(.vertical, 6)
        } label: {
            Text("Entwicklungsvorgaben").accessibilityIdentifier("develop.presets")
        }.font(.system(size: 13)).padding(.vertical, 8)
            .task { await model.load() }
            .onChange(of: library.aiSelectionGeneration) { _, _ in model.discard() }
            .onReceive(editor.objectWillChange) { _ in
                Task { @MainActor in model.invalidate(library: library, editor: editor) }
            }
            .onChange(of: workspace.tool) { _, _ in model.discard() }
            .onReceive(workspace.objectWillChange) { _ in
                Task { @MainActor in model.invalidate(library: library, editor: editor) }
            }
            .onDisappear { model.discard() }
            .sheet(item: $naming) { purpose in
                VStack(alignment: .leading, spacing: 16) {
                    Text(purpose == .save ? "Entwicklungsvorgabe speichern" : "Vorgabe umbenennen")
                        .font(.headline)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("develop.presets.name")
                    HStack {
                        Button("Abbrechen") { naming = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Speichern") {
                            let value = name; naming = nil
                            Task {
                                if purpose == .save { await model.save(name: value, library: library, editor: editor) }
                                else { await model.rename(value) }
                            }
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 400)
            }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "glowroompreset") ?? .json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { Task { await model.importFile(url) } }
        }
    }

    private func exportPreset() {
        guard let preset = model.selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "glowroompreset") ?? .json]
        panel.nameFieldStringValue = preset.name + ".glowroompreset"
        panel.begin { response in
            if response == .OK, let url = panel.url { Task { await model.export(preset, to: url) } }
        }
    }
}

struct DevelopPresetGroupPicker: View {
    @Binding var groups: Set<DevelopPresetGroup>
    var available = Set(DevelopPresetGroup.allCases)
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(DevelopPresetGroup.allCases, id: \.self) { group in
                Toggle(group.title, isOn: Binding(get: { groups.contains(group) }, set: { selected in
                    if selected { groups.insert(group) } else { groups.remove(group) }
                })).disabled(!available.contains(group))
                    .accessibilityIdentifier("develop.groups.\(group.rawValue)")
            }
        }
    }
}

private struct DevelopTransferControls: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var editor: EditingModel
    @ObservedObject var model: DevelopTransferModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button("Einstellungen kopieren") { model.copy(library: library) }
                .accessibilityIdentifier("develop.transfer.copy")
            Button("Auf ausgewählte Fotos übertragen …") { model.present(library: library) }
                .disabled(model.isRunning)
                .accessibilityIdentifier("develop.transfer.open")
        }.disabled(model.isRunning || !editor.developCommands.availability(in: library,
            permitsActiveInput: true).isAvailable)
            .sheet(isPresented: $model.isPresented) { DevelopTransferView(model: model) }
    }
}
