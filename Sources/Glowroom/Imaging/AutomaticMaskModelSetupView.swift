import SwiftUI

@MainActor
private final class SkyMaskModelSetupState: ObservableObject {
    @Published var installed = false
    @Published var isBusy = false
    @Published var progress: SkyMaskSetupProgress?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()

    func refresh() async {
        do { installed = try await SkyMaskModelStore.shared.installedModel() != nil }
        catch { errorMessage = error.localizedDescription }
    }

    func install() {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        operation = UUID()
        let currentOperation = operation
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil; operation = UUID() }
            do {
                _ = try await SkyMaskModelStore.shared.install { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.isBusy, self.operation == currentOperation else { return }
                        self.progress = value
                    }
                }
                installed = true
                progress = .init(text: "Himmelserkennung ist bereit.", fraction: 1)
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
            do { try await SkyMaskModelStore.shared.remove(); installed = false; progress = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
}

/// The first network action requires the explicit setup button. Photos never
/// leave the computer; only the pinned public model package is downloaded.
struct SkyMaskModelSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = SkyMaskModelSetupState()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lokale Himmelserkennung").font(.title2.bold())
            Text("Glowroom erkennt den Himmel mit Apples DETR-Segmentierungsmodell direkt auf deinem Mac. Deine Fotos bleiben auf dem Gerät.")
            Text("Die einmalige Einrichtung lädt etwa 86 MB von Hugging Face und benötigt vorübergehend mindestens 768 MB freien Speicher. Anschließend funktioniert die Erkennung offline.")
                .foregroundStyle(.secondary)
            Link("Modell von Apple · Apache-2.0-Lizenz", destination: SkyMaskApprovedPackage.modelCard)
            Text("Die Auswahl ist ein Vorschlag und kann insbesondere an feinen Kanten ungenau sein. Mit Pinsel und Radierer lässt sie sich korrigieren.")
                .font(.callout).foregroundStyle(.secondary)
            if state.installed { Label("Modell eingerichtet", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let progress = state.progress {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Text(progress.text).font(.callout)
            }
            if let error = state.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if state.isBusy {
                    Button("Abbrechen") { state.cancel() }
                } else if state.installed {
                    Button("Modell entfernen", role: .destructive) { state.remove() }
                } else {
                    Button("Modell laden und einrichten") { state.install() }.buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).disabled(state.isBusy)
            }
        }
        .padding(24).frame(width: 510)
        .task { await state.refresh() }
        .onDisappear { state.cancel() }
    }
}
