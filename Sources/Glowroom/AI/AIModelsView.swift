import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GlowroomCore

/// Presentation is independent of photo selection and never starts inference.
enum AIModelsDestination: String, Identifiable, CaseIterable {
    case overview, corrections, subject, sky, repair, search, metadata, index
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Alle Modelle"
        case .corrections: "KI-Korrektur"
        case .subject: "Motiv und Hintergrund"
        case .sky: "Himmel"
        case .repair: "Reparieren"
        case .search: "Bildsuche"
        case .metadata: "Bildinformationen"
        case .index: "Suchindex"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .corrections: "slider.horizontal.3"
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        case .repair: "bandage"
        case .search: "magnifyingglass"
        case .metadata: "text.bubble"
        case .index: "externaldrive"
        }
    }
    static let modelFunctions: [Self] = [.corrections, .subject, .sky, .repair, .search, .metadata]
}

/// Retain every manager while moving between cards. Model stores still own the
/// validated publication/removal gates; UI never creates a second worker pool.
struct AIModelsView: View {
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection: AIModelsDestination
    @StateObject private var corrections = LLMModelManagerModel()
    @StateObject private var subject = SubjectMattingModelSetupState()
    @StateObject private var sky = SkyMaskModelSetupState()
    @StateObject private var skySource = SkySegModelDownloadState()
    @StateObject private var repair = RepairModelManagerModel()
    @ViewState private var imageTextAvailability: ImageAnalysisAvailability?
    @ViewState private var showsHelp = false

    init(library: LibraryModel, destination: AIModelsDestination = .overview) {
        self.library = library
        _selection = ViewState(initialValue: destination)
    }

    private var modelOperationActive: Bool {
        corrections.isBusy || subject.isBusy || sky.isBusy || skySource.isBusy || repair.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("KI-Modelle").font(.title2.bold())
                Spacer()
                Button("Hilfe", systemImage: "questionmark.circle") { showsHelp = true }
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(modelOperationActive)
            }
            HStack(spacing: 10) {
                navigationButton(.overview, identifier: "ai-models.overview")
                navigationButton(.index, identifier: "ai-models.index")
                if (library.semanticState.isIndexing || library.semanticOperationLabel != nil)
                    && selection != .index && selection != .search {
                    ProgressView().controlSize(.small)
                    Button(library.semanticOperationLabel ?? "Suchindex wird aufgebaut …") { selection = .index }
                    Button("Abbrechen") { library.cancelSemanticOperation() }
                }
            }
            Divider()
            ScrollView {
                Group {
                    if selection == .overview { overview }
                    else { detail }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2)
            }
            if modelOperationActive && selection != .overview {
                Button("Laufende Arbeit und Modelle anzeigen") { selection = .overview }
            }
        }.font(.system(size: 13)).padding(24)
            .frame(width: 760, height: 580)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityIdentifier("ai-models.manager")
            .interactiveDismissDisabled(modelOperationActive)
            .onAppear { library.semanticControlsExpanded = true }
            .task {
                corrections.refresh(); repair.refresh()
                // Independent read-only inspections overlap. Store actors and
                // their existing budgets serialize only shared mutable work.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await subject.refresh() }
                    group.addTask { await sky.refresh() }
                    group.addTask { await refreshImageTextAvailability() }
                }
            }
            .onChange(of: library.aiModelsDestination) { _, destination in
                if let destination { selection = destination }
            }
            .onDisappear {
                library.semanticControlsExpanded = false
                corrections.cancel(); subject.cancel(); sky.cancel(); skySource.cancel(); repair.cancel()
            }
            .sheet(isPresented: $showsHelp) { help }
    }

    private var overview: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
            ForEach(AIModelsDestination.modelFunctions) { function in
                VStack(alignment: .leading, spacing: 10) {
                    Label(function.title, systemImage: function.symbol).font(.headline)
                    Text(status(function)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ai-models.status." + function.rawValue)
                    Button(action(function)) { selection = function }
                        .accessibilityLabel(function.title + ": " + action(function))
                        .accessibilityIdentifier("ai-models.card." + function.rawValue)
                }.padding(14).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .corrections:
            LLMModelManagerView(model: corrections, embedded: true)
        case .subject:
            SubjectMattingModelSetupView(state: subject, embedded: true)
        case .sky:
            SkyMaskModelSetupView(state: sky, sourceState: skySource, embedded: true)
        case .repair:
            RepairModelManagerView(model: repair)
        case .search:
            VStack(alignment: .leading, spacing: 14) {
                Text("Bildsuche").font(.title2.bold())
                SemanticSearchControlsView(model: library, section: .model)
                Button("Suchindex verwalten") { selection = .index }
            }
        case .index:
            VStack(alignment: .leading, spacing: 14) {
                Text("Suchindex").font(.title2.bold())
                SemanticSearchControlsView(model: library, section: .index, onShowModel: { selection = .search })
                Button("Suchmodell verwalten") { selection = .search }
            }
        case .metadata: imageTextDetails
        case .overview: EmptyView()
        }
    }

    private var imageTextDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bildinformationen").font(.title2.bold())
            Text(status(.metadata))
            LabeledContent("Anbieter", value: "Apple · lokales Systemmodell")
            LabeledContent("Version", value: ProcessInfo.processInfo.operatingSystemVersionString)
            LabeledContent("Lizenz und Speicher", value: "Von macOS verwaltet")
            LabeledContent("Funktion", value: "Bildanalyse, Titel, Beschreibung und Tags")
            if case .unavailable(let reason) = imageTextAvailability {
                Label(reason.localizedDescription, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Verfügbarkeit erneut prüfen") { Task { await refreshImageTextAvailability() } }
                .accessibilityIdentifier("ai-models.metadata.recheck")
            if case .unavailable(.disabled) = imageTextAvailability {
                Button("Systemeinstellungen öffnen") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
            }
        }
    }

    private func refreshImageTextAvailability() async {
        let value = await LocalImageAnalysisFactory.makeProvider().availability()
        guard !Task.isCancelled else { return }
        imageTextAvailability = value
    }

    private func status(_ function: AIModelsDestination) -> String {
        switch function {
        case .corrections:
            #if !arch(arm64)
            return "Nicht verfügbar · Apple Silicon erforderlich"
            #else
            if corrections.isDownloading { return corrections.progress?.text ?? "Download läuft …" }
            if corrections.isBusy { return "Modell wird geprüft …" }
            if corrections.errorMessage != nil { return "Einrichtung prüfen" }
            return corrections.installation == nil ? "Einrichten" : "Bereit"
            #endif
        case .subject:
            if subject.isBusy { return subject.progress?.text ?? "Einrichtung läuft …" }
            if subject.isChecking { return "Modell wird geprüft …" }
            if subject.requiresUpdate { return "Aktualisierung erforderlich" }
            if subject.errorMessage != nil { return "Einrichtung prüfen" }
            return subject.installed ? "Bereit" : "Einrichten"
        case .sky:
            if sky.isBusy { return sky.progress?.text ?? "Einrichtung läuft …" }
            if skySource.isBusy { return skySource.progress?.text ?? "Quelldatei wird geprüft …" }
            if sky.isChecking { return "Modell wird geprüft …" }
            if sky.errorMessage != nil { return "Einrichtung prüfen" }
            return sky.installed ? "Bereit" : "Einrichten"
        case .repair:
            if repair.isBusy { return repair.progress?.text ?? "Modell wird geprüft …" }
            if repair.errorMessage != nil { return "Einrichtung prüfen" }
            return repair.installation == nil ? "Einrichten" : "Bereit"
        case .search:
            if let label = library.semanticOperationLabel { return label }
            switch library.semanticState.availability {
            case .available: return "Bereit"
            case .unavailable(.modelNotInstalled): return "Einrichten"
            case .unavailable(let reason): return "Nicht verfügbar · " + reason.localizedDescription
            }
        case .metadata:
            switch imageTextAvailability {
            case .available: return "Bereit"
            case .unavailable(let reason): return "Nicht verfügbar · " + reason.localizedDescription
            case nil: return "Verfügbarkeit wird geprüft …"
            }
        case .overview, .index: return ""
        }
    }

    private func action(_ function: AIModelsDestination) -> String {
        status(function) == "Einrichten" ? "Einrichten …" : "Details und Aktionen …"
    }

    private func navigationButton(_ destination: AIModelsDestination, identifier: String) -> some View {
        Button { selection = destination } label: {
            Label(destination.title, systemImage: selection == destination ? "checkmark.circle.fill" : destination.symbol)
        }
        .accessibilityIdentifier(identifier)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("KI-Modelle · Hilfe").font(.title2.bold())
            Text("Wähle eine Funktion, um Modell, Version, Lizenz, Platzbedarf und Einrichtung zu sehen. Download und Import starten ausschließlich über die benannte Aktion. Laufende Arbeit bleibt beim Wechsel zwischen Karten erreichbar.")
            Text("KI-Korrektur und beschriebene Objekte verwenden das lokale Qwen-Modell. Bildinformationen verwenden die separat geprüfte Bildfähigkeit des Apple-Systemmodells für Titel, Beschreibung und Tags. Die Verfügbarkeit dieser Funktionen kann unterschiedlich sein.")
            Text("Das Suchmodell berechnet Bildinhalte. Der Suchindex speichert die daraus erstellten Einträge für den gewählten Katalogumfang. Modell und Index werden getrennt verwaltet; beide lassen sich entfernen, ohne Originalbilder oder übernommene Bearbeitungen zu ändern.")
            HStack { Spacer(); Button("Fertig") { showsHelp = false } }
        }.font(.system(size: 13)).padding(24).frame(width: 580)
    }
}

@MainActor
final class RepairModelManagerModel: ObservableObject {
    @Published private(set) var installation: DevelopRepairAIInstallation?
    @Published private(set) var isBusy = false
    @Published private(set) var progress: SkyMaskSetupProgress?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private let store: DevelopRepairAIModelStore
    private let downloadModel: @Sendable (@escaping @Sendable (SkyMaskSetupProgress) -> Void) async throws -> DevelopRepairAIInstallation

    init(store: DevelopRepairAIModelStore = .shared,
         download: @escaping @Sendable (@escaping @Sendable (SkyMaskSetupProgress) -> Void) async throws -> DevelopRepairAIInstallation = {
             try await DevelopRepairAIModelDownloadStore.shared.downloadAndInstall(progress: $0)
         }) {
        self.store = store; downloadModel = download
    }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil }
            do { installation = try await store.installedModel(); errorMessage = nil }
            catch is CancellationError { }
            catch { installation = nil; errorMessage = error.localizedDescription }
        }
    }

    func download() { run { [downloadModel] update in try await downloadModel(update) } }

    func importModel(from url: URL) {
        run { [store] _ in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try await store.importModel(from: url)
        }
    }

    private func run(_ work: @escaping @Sendable (@escaping @Sendable (SkyMaskSetupProgress) -> Void) async throws -> DevelopRepairAIInstallation) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; progress = nil
        let request = UUID(); operation = request
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil; operation = UUID() }
            do {
                installation = try await work { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.isBusy, self.operation == request else { return }
                        self.progress = value
                    }
                }
                progress = .init(text: "Reparaturmodell ist bereit.", fraction: 1)
            } catch is CancellationError { progress = nil }
            catch { errorMessage = error.localizedDescription; progress = nil }
        }
    }

    func remove() {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; progress = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil }
            do { try await store.remove(); installation = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func cancel() { task?.cancel() }
}

struct RepairModelManagerView: View {
    @ObservedObject var model: RepairModelManagerModel
    @ViewState private var importsModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reparieren").font(.title2.bold())
            Label(model.installation == nil ? "Einrichten" : "Bereit", systemImage: model.installation == nil ? "arrow.down.circle" : "checkmark.circle")
            LabeledContent("Modell", value: model.installation?.displayName ?? "LaMa · Core ML")
            LabeledContent("Version", value: DevelopRepairAIApprovedDownload.revision)
            LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: DevelopRepairAIApprovedDownload.totalBytes, countStyle: .file))
            LabeledContent("Freier Platz für Einrichtung", value: "1 GB")
            Link("Modellquelle und Lizenzangaben", destination: DevelopRepairAIApprovedDownload.modelCard)
            if let progress = model.progress {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Text(progress.text)
            }
            if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            if model.isBusy {
                if model.progress == nil { ProgressView("Modell wird geprüft oder eingerichtet …") }
                Button("Abbrechen") { model.cancel() }.accessibilityIdentifier("repair-model.cancel")
            } else {
                HStack {
                    if model.installation == nil {
                        Button("Reparaturmodell herunterladen") { model.download() }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("repair-model.download")
                    }
                    Button("Modell importieren …") { importsModel = true }
                        .accessibilityIdentifier("repair-model.import")
                    if model.installation != nil {
                        Button("Modell entfernen", role: .destructive) { model.remove() }
                            .accessibilityIdentifier("repair-model.remove")
                    }
                }
            }
        }.font(.system(size: 13))
            .fileImporter(isPresented: $importsModel, allowedContentTypes: [.folder, UTType(filenameExtension: "mlpackage") ?? .folder]) { result in
                switch result {
                case .success(let url): model.importModel(from: url)
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
    }
}
