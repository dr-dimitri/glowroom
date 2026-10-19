import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class SubjectMattingModelSetupState: ObservableObject {
    @Published var installed = false
    @Published var requiresUpdate = false
    @Published var isBusy = false
    @Published var progress: SubjectMattingSetupProgress?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()

    func refresh() async {
        do {
            installed = try await SubjectMattingModelStore.shared.installedModel() != nil
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

    func remove() {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        operation = UUID()
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil; operation = UUID() }
            do { try await SubjectMattingModelStore.shared.remove(); installed = false; requiresUpdate = false; progress = nil }
            catch is CancellationError { progress = nil }
            catch { errorMessage = error.localizedDescription }
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
            Text("Lokales Motivmodell").font(.title2.bold())
            Text("BiRefNet HR Matting berechnet Motiv- und Hintergrundmasken direkt auf deinem Mac. Es berücksichtigt feine Strukturen und weiche Übergänge. Deine Fotos bleiben auf dem Gerät.")
            Text("Importiere die für PicEdit vorbereitete 1920-Pixel-Variante des Core-ML-Modells (.mlpackage). Der Import benötigt vorübergehend mindestens 3 GB freien Speicher. Danach funktioniert das Modell offline.")
                .foregroundStyle(.secondary)
            Link("BiRefNet HR Matting · MIT-Lizenz", destination: URL(string: "https://huggingface.co/ZhengPeng7/BiRefNet_HR-matting")!)
            Text("Ohne importiertes Modell verwendet PicEdit weiterhin Apples lokale Motiverkennung. Vorhandene Masken bleiben erhalten; erst eine neue Motivauswahl verwendet das importierte Modell.")
                .font(.callout).foregroundStyle(.secondary)
            if state.requiresUpdate {
                Label("2048-Pixel-Modell vorhanden · Aktualisierung erforderlich", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                Text("Ersetze das bisherige Modell durch die 1920-Pixel-Variante. Bis dahin wird es für neue Auswahlen nicht verwendet. Bereits gespeicherte Masken bleiben erhalten.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if state.installed {
                Label("Motivmodell eingerichtet", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
                } else {
                    Button(state.installed ? "Modell ersetzen …" : "Modell importieren …") { importsModel = true }
                        .buttonStyle(.borderedProminent)
                    if state.installed { Button("Entfernen", role: .destructive) { state.remove() } }
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
