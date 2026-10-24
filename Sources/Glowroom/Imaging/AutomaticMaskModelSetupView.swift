import SwiftUI

@MainActor
final class SkyMaskModelSetupState: ObservableObject {
    @Published var installed = false
    @Published var isChecking = true
    @Published var isBusy = false
    @Published var progress: SkyMaskSetupProgress?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private var isRefreshing = false

    func refresh() async {
        guard !isBusy, !isRefreshing else { return }
        isRefreshing = true; isChecking = true
        defer { isRefreshing = false; isChecking = false }
        do {
            let value = try await SkyMaskModelStore.shared.installedModel() != nil
            try Task.checkCancellation()
            installed = value; errorMessage = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            installed = false; errorMessage = error.localizedDescription
        }
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
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                installed = (try? await SkyMaskModelStore.shared.installedModel()) != nil
                progress = nil
                errorMessage = error.localizedDescription
            }
        }
    }
    func cancel() { task?.cancel() }
}

/// The first network action requires the explicit setup button. Photos never
/// leave the computer; only the pinned public model package is downloaded.
struct SkyMaskModelSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: SkyMaskModelSetupState
    @StateObject private var sourceState: SkySegModelDownloadState
    @ViewState private var showsHelp = false
    @ViewState private var showsSourceDownload = false
    private let embedded: Bool

    @MainActor
    init(state: SkyMaskModelSetupState? = nil, sourceState: SkySegModelDownloadState? = nil, embedded: Bool = false) {
        _state = StateObject(wrappedValue: state ?? SkyMaskModelSetupState())
        _sourceState = StateObject(wrappedValue: sourceState ?? SkySegModelDownloadState())
        self.embedded = embedded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Himmel").font(.title2.bold())
            if state.isChecking { ProgressView("Modell wird geprüft …") }
            else {
                Label(state.installed ? "Bereit" : "Einrichten",
                    systemImage: state.installed ? "checkmark.circle.fill" : "arrow.down.circle")
            }
            LabeledContent("Modell", value: "Apple DETR · Core ML")
            LabeledContent("Version", value: SkyMaskApprovedPackage.revision)
            LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: SkyMaskApprovedPackage.totalBytes, countStyle: .file))
            LabeledContent("Freier Platz für Einrichtung", value: "768 MB")
            Link("Modell und Apache-2.0-Lizenz", destination: SkyMaskApprovedPackage.modelCard)
            if let progress = state.progress {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Text(progress.text)
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
                Button("Hilfe") { showsHelp = true }
            }.disabled(state.isChecking)
            DisclosureGroup("Zusätzliche Quelldatei · Skyseg ONNX", isExpanded: Binding(
                get: { showsSourceDownload || sourceState.isBusy },
                set: { showsSourceDownload = $0 })) {
                SkySegModelDownloadView(state: sourceState, embedded: embedded).padding(.top, 8)
            }
            if !embedded {
                HStack {
                    Spacer()
                    Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
                        .disabled(state.isBusy || sourceState.isBusy)
                }
            }
        }.font(.system(size: 13)).padding(embedded ? 0 : 24)
            .frame(width: embedded ? nil : 560)
            .task { if !embedded { await state.refresh() } }
            .onDisappear { if !embedded { state.cancel(); sourceState.cancel() } }
            .sheet(isPresented: $showsHelp) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Himmel · Hilfe").font(.title2.bold())
                    Text("Glowroom erkennt den Himmel mit Apples DETR-Segmentierungsmodell lokal. Die einmalige Einrichtung lädt das geprüfte Core-ML-Paket herunter; danach arbeitet die Erkennung offline.")
                    Text("Die Auswahl ist ein Vorschlag. Feine Kanten lassen sich mit Pinsel und Radierer korrigieren.")
                    Text("Die zusätzliche Skyseg-ONNX-Datei kann für eigene Arbeit heruntergeladen und im Finder gezeigt werden. Sie ist kein aktives Himmelsmodell in Glowroom.")
                    HStack { Spacer(); Button("Fertig") { showsHelp = false } }
                }.font(.system(size: 13)).padding(24).frame(width: 540)
            }
    }
}
