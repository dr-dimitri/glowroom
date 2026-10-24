import AppKit
import SwiftUI

@MainActor
final class SkySegModelDownloadState: ObservableObject {
    @Published var file: URL?
    @Published var isBusy = false
    @Published var progress: SkyMaskSetupProgress?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil }
            do { file = try await SkySegModelDownloadStore.shared.downloadedFile() }
            catch is CancellationError { }
            catch { file = nil; errorMessage = error.localizedDescription }
        }
    }

    func download() {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; progress = nil
        let currentOperation = UUID()
        operation = currentOperation
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil; operation = UUID() }
            do {
                file = try await SkySegModelDownloadStore.shared.download { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.isBusy, self.operation == currentOperation else { return }
                        self.progress = value
                    }
                }
                progress = .init(text: "Skyseg wurde heruntergeladen und geprüft.", fraction: 1)
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
            do { try await SkySegModelDownloadStore.shared.remove(); file = nil; progress = nil }
            catch is CancellationError { }
            catch {
                file = try? await SkySegModelDownloadStore.shared.downloadedFile()
                progress = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func reveal() {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil }
            do {
                let current = try await SkySegModelDownloadStore.shared.downloadedFile()
                try Task.checkCancellation()
                file = current
                if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            } catch is CancellationError { }
            catch { file = nil; errorMessage = error.localizedDescription }
        }
    }

    func cancel() { task?.cancel() }
}

/// Additional source-model download. Its status never claims that the ONNX
/// export is installed as the app's active sky-recognition backend.
struct SkySegModelDownloadView: View {
    @StateObject private var state: SkySegModelDownloadState
    private let embedded: Bool

    @MainActor
    init(state: SkySegModelDownloadState? = nil, embedded: Bool = false) {
        _state = StateObject(wrappedValue: state ?? SkySegModelDownloadState())
        self.embedded = embedded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skyseg zusätzlich herunterladen").font(.headline)
            LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: SkySegApprovedDownload.file.bytes, countStyle: .file))
            LabeledContent("Freier Platz", value: "384 MB")
            LabeledContent("Verwendung", value: "Quelldatei für eigene Arbeit")
            Link("JianyuanWang/skyseg · MIT-Lizenz", destination: SkySegApprovedDownload.modelCard)
            if state.file != nil {
                Label("Skyseg-Datei heruntergeladen", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let progress = state.progress {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
                Text(progress.text).font(.system(size: 13))
            }
            if let error = state.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if state.isBusy {
                    Button("Abbrechen") { state.cancel() }
                } else if state.file != nil {
                    Button("Im Finder zeigen") { state.reveal() }
                    Button("Skyseg entfernen", role: .destructive) { state.remove() }
                } else {
                    Button("Skyseg herunterladen") { state.download() }
                }
            }
        }
        .task { state.refresh() }
        .onDisappear { if !embedded { state.cancel() } }
    }
}
