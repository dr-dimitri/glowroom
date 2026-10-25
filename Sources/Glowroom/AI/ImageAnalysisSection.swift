import SwiftUI
import GlowroomCore

struct ImageAnalysisSection: View {
    @ObservedObject var model: ImageAnalysisModel
    @ViewState private var showsHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Bildanalyse", systemImage: "eye").fontWeight(.semibold)
                Spacer(minLength: 0)
                Button("Hilfe", systemImage: "questionmark.circle") { showsHelp = true }
                    .accessibilityLabel("Hilfe zur Bildanalyse")
            }
            Picker("Eingabe", selection: $model.inputKind) {
                Text("Originalvorschau").tag(ImageAnalysisInputKind.originalPreview)
                Text("Bearbeitete Vorschau").tag(ImageAnalysisInputKind.editedPreview)
            }.pickerStyle(.menu)
                .accessibilityLabel("Eingabe für die Bildanalyse")
            status
            if model.state == .analyzing {
                Button("Analyse abbrechen") { model.discard() }
            } else {
                Button("Bild lokal analysieren") { model.analyze() }
                    .disabled(!model.canAnalyze)
                    .accessibilityHint("Startet die Bildanalyse erst nach diesem bewussten Aufruf; speichert keine Metadaten")
            }
            if let result = model.result {
                Label("Bildanalyse · noch nicht bestätigt", systemImage: "doc.text.magnifyingglass")
                    .fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Text(result.request.inputKind == .originalPreview ? "Analysierte Eingabe: Originalvorschau" : "Analysierte Eingabe: bearbeitete Vorschau")
                    .foregroundStyle(Theme.muted)
                Text(result.suggestions.description).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(result.suggestions.attributes.enumerated()), id: \.offset) { _, attribute in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attribute.category.label).fontWeight(.medium)
                        Text(attribute.value).foregroundStyle(Theme.muted).textSelection(.enabled)
                    }.accessibilityElement(children: .combine)
                }
                Button("Analyse verwerfen") { model.discard() }
            }
        }.font(.system(size: 13)).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            // Hiding a dock group is presentation only. The model keeps a
            // pending analysis/result and invalidates it on source changes.
            .task {
                if model.availability == nil { await model.refreshAvailability() }
            }
            .sheet(isPresented: $showsHelp) { help }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .analyzing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Bild wird lokal analysiert …")
            }.accessibilityElement(children: .combine).accessibilityLabel("Bild wird lokal analysiert")
        case .unavailable(let reason):
            Label(reason.localizedDescription, systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
            Button("Bildfähigkeit erneut prüfen") { Task { await model.refreshAvailability() } }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            if model.availability == nil {
                ProgressView("Lokale Bildfähigkeit wird geprüft …").controlSize(.small)
            } else if !model.contextAvailable {
                Label("Foto derzeit nicht analysierbar", systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ready: EmptyView()
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bildanalyse · Hilfe").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Ausführung", value: model.executionLocation)
                    Text("Beschreibung und sichtbare Merkmale sind unbestätigte Vorschläge. Die Analyse bestätigt keine Identität, Gesundheit oder einen Aufnahmeort und speichert keine Metadaten.")
                    Text("Originalvorschau verwendet das Original ohne Regleränderungen. Bearbeitete Vorschau verwendet die übernommenen Reglerwerte. Ein offener KI-Korrekturvorschlag wird nicht analysiert. Während Katalog- oder Bearbeitungssperren ist die Analyse nicht verfügbar.")
                    if let result = model.result {
                        Text("Analysebezug").font(.headline)
                        LabeledContent("Anbieter", value: result.provenance.providerID)
                        LabeledContent("Modell", value: result.provenance.modelID)
                        LabeledContent("Eingaberaster", value: "\(result.provenance.pixelWidth) × \(result.provenance.pixelHeight) Pixel")
                        Text("Raster-SHA-256: \(result.provenance.rasterSHA256)").textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Fertig") { showsHelp = false }.keyboardShortcut(.defaultAction) }
        }.font(.system(size: 13)).padding(24).frame(width: 580, height: 420)
    }
}
