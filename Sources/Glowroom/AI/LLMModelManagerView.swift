import SwiftUI

/// UI ownership is separate from the store's actor. Only the store publishes
/// a complete installation; cancellation cannot expose partial model weights.
@MainActor
final class LLMModelManagerModel: ObservableObject {
    @Published private(set) var installation: LLMInstalledModel?
    @Published private(set) var occupiedBytes: Int64 = 0
    @Published private(set) var isBusy = false
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: LLMModelDownloadProgress?
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private let store: LLMModelStore

    init(store: LLMModelStore = .shared) { self.store = store }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil }
            await readStatus()
        }
    }

    func download() {
        guard !isBusy else { return }
        isBusy = true; isDownloading = true; errorMessage = nil; progress = nil
        let request = UUID()
        operation = request
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; isDownloading = false; task = nil; operation = UUID() }
            do {
                installation = try await store.download { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.operation == request, self.isDownloading else { return }
                        self.progress = value
                    }
                }
            } catch is CancellationError { progress = nil }
            catch { errorMessage = error.localizedDescription; progress = nil }
            // Refresh in a fresh task after cancellation so the store may check
            // the successfully committed installation and any retained bytes.
            let store = self.store
            let bytes = await Task { try? await store.diskUsage() }.value
            if let bytes { occupiedBytes = bytes }
        }
    }

    func remove() {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; progress = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false; task = nil }
            do {
                try await store.remove()
                installation = nil; occupiedBytes = 0
            } catch {
                errorMessage = error.localizedDescription
                installation = try? await store.installation()
                if let bytes = try? await store.diskUsage() { occupiedBytes = bytes }
            }
        }
    }

    func cancel() { task?.cancel() }

    private func readStatus() async {
        errorMessage = nil
        do { installation = try await store.installation() }
        catch is CancellationError { }
        catch { installation = nil; errorMessage = error.localizedDescription }
        // Inspection may reap abandoned staging files; measure afterward so
        // the displayed disk usage describes the remaining model payload.
        do { occupiedBytes = try await store.diskUsage() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct LLMModelManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: LLMModelManagerModel
    private let embedded: Bool

    @MainActor
    init(model: LLMModelManagerModel? = nil, embedded: Bool = false) {
        _model = StateObject(wrappedValue: model ?? LLMModelManagerModel())
        self.embedded = embedded
    }
    private let descriptor = LLMModelDescriptor.qwen35

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Bildkorrekturen").font(.title2.bold())
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(descriptor.name).font(.headline)
                        Text("4-Bit · Bild und Text · Apple Silicon").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.installation != nil {
                        Label("Installiert", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                LabeledContent("Version", value: descriptor.revision)
                LabeledContent("Modellgröße / Download", value: size(descriptor.downloadBytes))
                LabeledContent("Belegt auf diesem Mac", value: size(model.occupiedBytes))
                LabeledContent("Freier Platz für Einrichtung", value: size(descriptor.requiredDownloadFreeBytes))
                Link("Modell und Lizenz ansehen", destination: URL(string: "https://huggingface.co/\(descriptor.repository)")!)
                    .font(.system(size: 13))
                if let progress = model.progress {
                    if let fraction = progress.fraction { ProgressView(value: fraction) }
                    else { ProgressView().controlSize(.small) }
                    Text(progress.text).font(.system(size: 13))
                    if progress.downloadedBytes > 0 {
                        Text("\(size(progress.downloadedBytes)) von \(size(progress.totalBytes))")
                            .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if model.isBusy {
                    ProgressView("Modell wird geprüft …").controlSize(.small)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(.orange).textSelection(.enabled)
                }
                HStack {
                    if model.isDownloading {
                        Button("Download abbrechen") { model.cancel() }
                            .accessibilityIdentifier("llm-model.cancel")
                    } else {
                        if model.installation == nil {
                            Button("Herunterladen") { model.download() }.buttonStyle(.borderedProminent)
                                .disabled(model.isBusy || !supportsLocalModel)
                                .accessibilityIdentifier("llm-model.download")
                        }
                        if model.installation != nil || model.occupiedBytes > 0 || model.errorMessage != nil {
                            Button("Modell löschen", role: .destructive) { model.remove() }
                                .disabled(model.isBusy).accessibilityIdentifier("llm-model.delete")
                        }
                    }
                }
                if !supportsLocalModel {
                    Text("Dieses Modell benötigt einen Mac mit Apple Silicon.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            if !embedded {
                HStack {
                    Spacer()
                    Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).disabled(model.isBusy)
                }
            }
        }.font(.system(size: 13)).padding(embedded ? 0 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(width: embedded ? nil : 540)
            .task { if !embedded { model.refresh() } }
            .onDisappear { if !embedded { model.cancel() } }
    }

    private var supportsLocalModel: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
