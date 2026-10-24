import AppKit
import SwiftUI
import GlowroomCore

struct SemanticSearchControlsView: View {
    @ObservedObject var model: LibraryModel
    @ViewState<Deletion?> private var deletion: Deletion?
    private enum Deletion: String, Identifiable {
        case index, model
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.searchMode == .semantic {
                if let reference = model.similarityReference {
                    HStack {
                        Label("Ähnliche Bilder zu: \(reference.fileName)", systemImage: "photo.on.rectangle")
                            .font(.system(size: 11)).textSelection(.enabled)
                        Spacer()
                        Button("Ähnlichkeitssuche beenden") { model.stopFindingSimilarImages() }
                            .font(.system(size: 10))
                    }
                    Text("Suchumfang: \(model.similarityScopeLabel)")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    TextField("Optional: Dateiname/Kamera/Format filtern", text: $model.semanticLiteralFilter)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .accessibilityLabel("Zusätzlicher wörtlicher Filter vor der semantischen Suche")
                    Stepper("Top \(min(500, max(1, model.semanticTopK)))", value: $model.semanticTopK, in: 1...500)
                        .font(.system(size: 10)).fixedSize()
                }
            }
            if let error = model.semanticError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Button("Zur wörtlichen Suche") { model.searchMode = .literal }.font(.system(size: 10))
            }
            DisclosureGroup("Lokales Suchmodell und Suchindex", isExpanded: Binding(
                get: { model.semanticControlsExpanded || model.semanticOperationLabel != nil || model.semanticState.isIndexing },
                set: { model.semanticControlsExpanded = $0 })) {
                controls.padding(.top, 8)
            }.font(.system(size: 11))
        }.padding(.horizontal, 26).padding(.bottom, 12)
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
            } message: {
                Text("Originalbilder und Bearbeitungen bleiben erhalten. Der lokale Suchindex kann später aus den Originalen neu berechnet werden.")
            }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .unavailable(let reason) = model.semanticState.availability {
                Text(reason.localizedDescription).foregroundStyle(Theme.muted)
            }
            if let descriptor = model.semanticState.modelDescriptor {
                Text("Modell: \(descriptor.modelID) · \(descriptor.releaseID)").textSelection(.enabled)
                if let bytes = model.semanticState.installedBytes {
                    Text("Installiert: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                }
            } else { Text("Kein Suchmodell eingerichtet.") }
            Picker("Indexumfang", selection: $model.semanticScope) {
                ForEach(LibraryModel.SemanticScope.allCases) { scope in Text(scope.label).tag(scope) }
            }.pickerStyle(.menu).disabled(model.semanticOperationLabel != nil)
            Text("Gewählter Umfang: \(model.semanticScope.label) · \(model.semanticScopeCount) Bilder")
                .fixedSize(horizontal: false, vertical: true)
            Text("\(model.semanticState.indexedCount) gültig · \(model.semanticState.missingCount) fehlend · \(model.semanticState.staleCount) veraltet · \(model.semanticState.totalCount) im geprüften Umfang")
                .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let label = model.semanticOperationLabel {
                HStack { ProgressView().controlSize(.small); Text(label) }
            }
            if model.semanticState.isIndexing {
                Text("Abgeschlossen: \(model.semanticState.processedCount) · \(model.semanticActiveScopeLabel ?? "bewusst gestarteter Indexumfang")")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.semanticOperationLabel != nil || model.semanticState.isIndexing {
                Button("Abbrechen") { model.cancelSemanticOperation() }
            } else {
                HStack {
                    Button(model.semanticState.indexedCount == 0 ? "Suchindex vorbereiten" : "Index fortsetzen") { model.prepareSemanticIndex() }
                        .disabled(!model.canManageSemanticSearch || !model.semanticScopeIsReady || model.semanticScopeCount == 0 || model.semanticState.availability != .available)
                    Button("Neu aufbauen") { model.prepareSemanticIndex(rebuild: true) }
                        .disabled(!model.canManageSemanticSearch || !model.semanticScopeIsReady || model.semanticScopeCount == 0 || model.semanticState.availability != .available)
                    Menu("Verwalten") {
                        Button("Lokales Suchmodell importieren …") { chooseModel() }
                        Button("Suchindex löschen …", role: .destructive) { deletion = .index }
                        Button("Suchmodell entfernen …", role: .destructive) { deletion = .model }
                    }.disabled(!model.canManageSemanticSearch)
                }.font(.system(size: 11))
            }
            if let notice = model.semanticState.notice { Text(notice).foregroundStyle(Theme.muted) }
        }.font(.system(size: 13))
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
