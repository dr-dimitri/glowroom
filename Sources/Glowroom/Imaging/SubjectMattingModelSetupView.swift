import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class SubjectMattingModelSetupState: ObservableObject {
    @Published var installed = false
    @Published var requiresUpdate = false
    @Published var isChecking = true
    @Published var isBusy = false
    @Published var progress: SubjectMattingSetupProgress?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()

    func refresh() async {
        isChecking = true
        defer { isChecking = false }
        do {
            if let installation = try await SubjectMattingModelStore.shared.installedModel() {
                // A damaged installation must keep the repair action available.
                // Hashing model weights stays off MainActor.
                _ = try await Task.detached(priority: .utility) {
                    try SubjectMattingModelStore.verifyInstallation(installation)
                }.value
                installed = true
            } else { installed = false }
            requiresUpdate = false; errorMessage = nil
        } catch SubjectMattingError.updateRequired {
            installed = true; requiresUpdate = true; errorMessage = nil
        } catch { installed = false; requiresUpdate = false; errorMessage = error.localizedDescription }
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

    func cancel() { task?.cancel() }
}

/// Model preparation and import are explicit. This view performs no network
/// request; all photo analysis and subsequent predictions stay on the Mac.
struct SubjectMattingModelSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = SubjectMattingModelSetupState()
    @ViewState private var importsModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BiRefNet · Motiv und Hintergrund").font(.title2.bold())
            Text("Glowroom verwendet für Motiv- und Hintergrundmasken ausschließlich BiRefNet HR Matting. Es berücksichtigt feine Strukturen und weiche Übergänge. Deine Fotos bleiben auf dem Gerät.")
            Link("BiRefNet HR Matting · MIT-Lizenz", destination: URL(string: "https://huggingface.co/ZhengPeng7/BiRefNet_HR-matting")!)
            Text("Vorhandene Masken bleiben erhalten. Erstelle eine neue Motiv- oder Hintergrundmaske, um BiRefNet zu verwenden. Die Himmelsmaskierung wird separat eingerichtet.")
                .font(.callout).foregroundStyle(.secondary)
            if state.isChecking {
                ProgressView("BiRefNet wird geprüft …")
            } else if state.requiresUpdate {
                Label("2048-Pixel-Modell vorhanden · Aktualisierung erforderlich", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                Text("Aktualisiere BiRefNet auf die freigegebene 1920-Pixel-Variante. Bis dahin können keine neuen Motiv- oder Hintergrundmasken erstellt werden.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if state.installed {
                Label("BiRefNet ist bereit", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if !state.isChecking && (!state.installed || state.requiresUpdate) {
                Text("Wähle das für Glowroom vorbereitete BiRefNet-Paket mit 1920 Pixeln (.mlpackage). Andere Modelle werden nicht akzeptiert. Die Einrichtung benötigt vorübergehend mindestens 3 GB freien Speicher und funktioniert anschließend offline.")
                    .foregroundStyle(.secondary)
            }
            if let progress = state.progress {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Text(progress.text).font(.callout)
            }
            if let error = state.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if state.isBusy {
                    Button("Abbrechen") { state.cancel() }
                } else if !state.isChecking && (!state.installed || state.requiresUpdate) {
                    Button(state.requiresUpdate ? "BiRefNet aktualisieren …" : "BiRefNet einrichten …") { importsModel = true }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).disabled(state.isBusy)
            }
        }
        .padding(24).frame(width: 560)
        .task { await state.refresh() }
        .onDisappear { state.cancel() }
        .fileImporter(isPresented: $importsModel, allowedContentTypes: [UTType(filenameExtension: "mlpackage") ?? .folder]) { result in
            switch result {
            case .success(let url): state.install(from: url)
            case .failure(let error): state.errorMessage = error.localizedDescription
            }
        }
    }
}
