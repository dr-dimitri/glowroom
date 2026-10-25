import AppKit
import SwiftUI
import GlowroomCore

enum SemanticSearchManagementSection { case model, index }

/// Management opens explicitly in KI-Modelle; the library only presents search controls.
struct SemanticSearchControlsView: View {
    @ObservedObject var model: LibraryModel
    var section: SemanticSearchManagementSection = .index
    var onShowModel: () -> Void = {}
    @ViewState<Deletion?> private var deletion: Deletion?
    private enum Deletion: String, Identifiable {
        case index, model
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if section == .model { modelControls }
            else { indexControls }
            if let error = model.semanticError, section != .model || error != availabilityMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let label = model.semanticOperationLabel {
                HStack { ProgressView().controlSize(.small); Text(label) }
            }
            if model.semanticState.isIndexing {
                Text("Abgeschlossen: \(model.semanticState.processedCount) · \(model.semanticActiveScopeLabel ?? "gewählter Indexumfang")")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.semanticOperationLabel != nil || model.semanticState.isIndexing {
                Button("Abbrechen") { model.cancelSemanticOperation() }
                    .accessibilityIdentifier("ai-models.search.cancel")
            }
            if let notice = model.semanticState.notice {
                Text(notice).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 13))
            .background {
                if let review = model.semanticImportReview {
                    SemanticModelReviewPresenter(model: model, review: review).id(review.id)
                }
            }
            .confirmationDialog(deletion == .model ? "Lokales Suchmodell entfernen?" : "Suchindex löschen?",
                isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                if deletion == .model {
                    Button("Modell entfernen", role: .destructive) { model.removeSemanticModel(); deletion = nil }
                } else {
                    Button("Index löschen", role: .destructive) { model.deleteSemanticIndex(); deletion = nil }
                }
                Button("Abbrechen", role: .cancel) { deletion = nil }
            }
    }

    private var availabilityMessage: String? {
        if case .unavailable(let reason) = model.semanticState.availability { return reason.localizedDescription }
        return nil
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .unavailable(let reason) = model.semanticState.availability {
                Text(reason.localizedDescription).fixedSize(horizontal: false, vertical: true)
            }
            let descriptor = model.semanticState.modelDescriptor ?? LocalModelRegistry.semantic
            Group {
                LabeledContent("Modell", value: descriptor.modelID)
                LabeledContent("Version", value: descriptor.releaseID)
                LabeledContent("Quellrevision", value: descriptor.sourceRevision)
                LabeledContent("Vektordimension", value: "\(descriptor.dimension)")
                LabeledContent("Tokenizer", value: descriptor.tokenizerVersion)
                LabeledContent("Vorverarbeitung", value: "\(descriptor.preprocessingVersion)")
                LabeledContent("Normalisierung", value: "\(descriptor.normalizationVersion)")
                if let bytes = model.semanticState.installedBytes {
                    LabeledContent("Installiert", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
            }
            LabeledContent("Maximale Installation", value: ByteCountFormatter.string(fromByteCount: SemanticModelInstaller.maximumInstalledBytes, countStyle: .file))
            LabeledContent("Zusätzlich freier Platz", value: ByteCountFormatter.string(fromByteCount: SemanticModelInstaller.stagingBytesRequired, countStyle: .file))
            Link("Modell und Apache-2.0-Lizenz", destination: URL(string: "https://huggingface.co/\(descriptor.modelID)/blob/\(descriptor.sourceRevision)/README.md")!)
            HStack {
                Button("Suchmodell importieren …") { chooseModel() }
                    .accessibilityIdentifier("ai-models.search.import")
                Button("Modell entfernen …", role: .destructive) { deletion = .model }
                    .disabled(model.semanticState.modelDescriptor == nil)
            }.disabled(!model.canManageSemanticSearch || model.semanticOperationLabel != nil || model.semanticState.isIndexing)
        }
    }

    private var indexControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Indexumfang", selection: $model.semanticScope) {
                ForEach(LibraryModel.SemanticScope.allCases) { scope in Text(scope.label).tag(scope) }
            }.pickerStyle(.menu).disabled(model.semanticOperationLabel != nil || model.semanticState.isIndexing)
            Text("\(model.semanticScope.label) · \(model.semanticScopeCount) \(model.semanticScopeCount == 1 ? "Bild" : "Bilder")")
                .fixedSize(horizontal: false, vertical: true)
            Text("\(model.semanticState.indexedCount) aktuell · \(model.semanticState.missingCount) fehlend · \(model.semanticState.staleCount) veraltet")
                .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if model.semanticState.availability != .available {
                Button("Bildsuche einrichten", action: onShowModel)
                    .accessibilityIdentifier("ai-models.index.setup-model")
            }
            HStack {
                HStack {
                    Button(model.semanticState.indexedCount == 0 ? "Suchindex vorbereiten" : "Index fortsetzen") { model.prepareSemanticIndex() }
                        .accessibilityIdentifier("ai-models.index.prepare")
                    Button("Neu aufbauen") { model.prepareSemanticIndex(rebuild: true) }
                        .accessibilityIdentifier("ai-models.index.rebuild")
                }.disabled(!model.canManageSemanticSearch || !model.semanticScopeIsReady || model.semanticScopeCount == 0 || model.semanticState.availability != .available || model.semanticOperationLabel != nil || model.semanticState.isIndexing)
                Button("Index löschen …", role: .destructive) { deletion = .index }
                    .disabled(!model.canManageSemanticSearch || model.semanticOperationLabel != nil || model.semanticState.isIndexing)
                    .accessibilityIdentifier("ai-models.index.delete")
            }
        }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Geprüftes lokales Suchmodellpaket auswählen"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.inspectSemanticModel(source: url)
    }
}

private struct SemanticModelReviewPresenter: View {
    @ObservedObject var model: LibraryModel
    let review: SemanticModelImportReview
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: Binding(get: { model.semanticImportReview?.id == review.id },
                set: { if !$0 { model.dismissSemanticImport(id: review.id) } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Lokales Suchmodell importieren").font(.headline)
                    Text("Quelle: \(review.sourceURL.path)").textSelection(.enabled)
                    Text("Modell: \(review.descriptor.modelID) · \(review.descriptor.releaseID)")
                    Text("Quelldateien: \(ByteCountFormatter.string(fromByteCount: review.sourceBytes, countStyle: .file))")
                    LabeledContent("Maximale Installation", value: ByteCountFormatter.string(fromByteCount: review.maximumInstalledBytes, countStyle: .file))
                    LabeledContent("Zusätzlich freier Platz", value: ByteCountFormatter.string(fromByteCount: review.stagingBytesRequired, countStyle: .file))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(review.licenses.enumerated()), id: \.offset) { _, license in
                                Text(license.title).font(.headline)
                                Text(license.text).textSelection(.enabled)
                            }
                        }
                    }.frame(height: 220)
                    HStack {
                        Button("Abbrechen", role: .cancel) { model.dismissSemanticImport(id: review.id) }
                        Spacer()
                        Button("Importieren") { model.installSemanticModel(reviewID: review.id) }
                    }
                }.font(.system(size: 13)).padding(24).frame(width: 580)
            }
    }
}
