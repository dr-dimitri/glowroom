import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SubjectMattingModelSetupState: ObservableObject {
    @Published var installed = false
    @Published var requiresUpdate = false
    @Published var isChecking = true
    @Published var isBusy = false
    @Published var progress: SubjectMattingSetupProgress?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private var isRefreshing = false

    func refresh() async {
        guard !isBusy, !isRefreshing else { return }
        isRefreshing = true; isChecking = true
        defer { isRefreshing = false; isChecking = false }
        do {
            if let installation = try await SubjectMattingModelStore.shared.installedModel() {
                // A damaged installation must keep the repair action available.
                // Hashing model weights stays off MainActor.
                _ = try await Task.detached(priority: .utility) {
                    try SubjectMattingModelStore.verifyInstallation(installation)
                }.value
                try Task.checkCancellation()
                installed = true
            } else { installed = false }
            requiresUpdate = false; errorMessage = nil
        } catch SubjectMattingError.updateRequired {
            installed = true; requiresUpdate = true; errorMessage = nil
        } catch is CancellationError { }
        catch { installed = false; requiresUpdate = false; errorMessage = error.localizedDescription }
    }

    func install(from url: URL) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; progress = nil
        operation = UUID()
        let currentOperation = operation
        task = Task { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isBusy = false; task = nil; operation = UUID()
            }
            do {
                _ = try await SubjectMattingModelStore.shared.install(from: url) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.isBusy, self.operation == currentOperation else { return }
                        self.progress = value
                    }
                }
                installed = true; requiresUpdate = false
                progress = .init(text: "Lokales Motivmodell ist bereit.", fraction: 1)
            } catch is CancellationError { progress = nil }
            catch { errorMessage = error.localizedDescription; progress = nil }
        }
    }

    func remove() {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil }
            do {
                try await SubjectMattingModelStore.shared.remove()
                installed = false; requiresUpdate = false; progress = nil
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func cancel() { task?.cancel() }
}

/// Model preparation and import are explicit. This view performs no network
/// request; all photo analysis and subsequent predictions stay on the Mac.
struct SubjectMattingModelSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: SubjectMattingModelSetupState
    private let embedded: Bool

    @MainActor
    init(state: SubjectMattingModelSetupState? = nil, embedded: Bool = false) {
        _state = StateObject(wrappedValue: state ?? SubjectMattingModelSetupState())
        self.embedded = embedded
    }
    @ViewState private var importsModel = false
    @ViewState private var showsHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Motiv und Hintergrund").font(.title2.bold())
            if state.isChecking {
                ProgressView("Motivmodell wird geprüft …")
            } else if state.requiresUpdate {
                Label("Motivmodell aktualisieren", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            } else if state.installed {
                Label("Motivmodell ist bereit", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            LabeledContent("Modell", value: "BiRefNet HR Matting · 1920 Pixel")
            LabeledContent("Version", value: LocalModelRegistry.subjectRevision)
            LabeledContent("Freier Platz für Einrichtung", value: "3 GB")
            Link("Modell und MIT-Lizenz", destination: URL(string: "https://huggingface.co/ZhengPeng7/BiRefNet_HR-matting")!)
            if let progress = state.progress {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Text(progress.text)
            }
            if let error = state.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if state.isBusy {
                    Button("Abbrechen") { state.cancel() }
                } else if !state.isChecking && (!state.installed || state.requiresUpdate) {
                    Button(state.requiresUpdate ? "Modellpaket aktualisieren …" : "Modellpaket auswählen …") { importsModel = true }
                        .buttonStyle(.borderedProminent)
                }
                if !state.isBusy && !state.isChecking && state.installed {
                    Button("Modell entfernen", role: .destructive) { state.remove() }
                        .accessibilityIdentifier("subject-model.remove")
                }
                Button("Hilfe") { showsHelp = true }
                    .accessibilityIdentifier("subject-model.help")
                if !embedded {
                    Spacer()
                    Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).disabled(state.isBusy)
                }
            }
        }
        .font(.system(size: 13))
        .padding(embedded ? 0 : 24).frame(width: embedded ? nil : 560)
        .accessibilityIdentifier("subject-model.setup")
        .sheet(isPresented: $showsHelp) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Motivmodell · Hilfe").font(.title2.bold())
                Text("Motiv, Hintergrund und beschriebene Objekte werden lokal mit BiRefNet HR Matting ausgewählt. Fotos bleiben auf deinem Mac.")
                Text("Wähle das für Glowroom vorbereitete BiRefNet-Paket mit 1920 Pixeln (.mlpackage). Die Einrichtung benötigt vorübergehend mindestens 3 GB freien Speicher und funktioniert anschließend offline.")
                Text("Ein älteres Modell mit 2048 Pixeln muss aktualisiert werden. Vorhandene Masken bleiben erhalten. Die Himmelsauswahl hat eine eigene Einrichtung.")
                Link("BiRefNet HR Matting · Modell und MIT-Lizenz", destination: URL(string: "https://huggingface.co/ZhengPeng7/BiRefNet_HR-matting")!)
                HStack { Spacer(); Button("Fertig") { showsHelp = false } }
            }.font(.system(size: 13)).padding(24).frame(width: 540)
        }
        .task { if !embedded { await state.refresh() } }
        .onDisappear { if !embedded { state.cancel() } }
        .fileImporter(isPresented: $importsModel, allowedContentTypes: [UTType(filenameExtension: "mlpackage") ?? .folder]) { result in
            switch result {
            case .success(let url): state.install(from: url)
            case .failure(let error): state.errorMessage = error.localizedDescription
            }
        }
    }
}
