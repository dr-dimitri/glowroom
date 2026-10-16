import SwiftUI
import PicEditCore

struct ImageAnalysisSection: View {
    @ObservedObject var model: ImageAnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Bildanalyse", systemImage: "eye").font(.system(size: 12, weight: .semibold))
            Text("Ausführung: \(model.executionLocation). Beschreibung und sichtbare Merkmale bleiben unbestätigte Vorschläge.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Picker("Eingabe", selection: $model.inputKind) {
                Text("Originalvorschau").tag(ImageAnalysisInputKind.originalPreview)
                Text("Bearbeitete Vorschau").tag(ImageAnalysisInputKind.editedPreview)
            }.pickerStyle(.menu).font(.system(size: 11))
                .accessibilityLabel("Eingabe für die Bildanalyse")
            Text(model.inputKind == .originalPreview
                 ? "Standard: Original ohne Regleränderungen. Manuelle Regler ändern diese Analyse nicht."
                 : "Bewusst gewählt: aktuelle übernommene Reglerwerte. Eine unverbindliche KI-Lookvorschau gehört nicht dazu.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            status
            if model.state == .analyzing {
                Button("Analyse abbrechen") { model.discard() }.font(.system(size: 11))
            } else {
                Button("Bild lokal analysieren") { model.analyze() }
                    .disabled(!model.canAnalyze).font(.system(size: 11))
                    .accessibilityHint("Startet die Bildanalyse erst nach diesem bewussten Aufruf; speichert keine Metadaten")
            }
            if let result = model.result {
                Label("Bildanalyse · noch nicht bestätigt", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(result.request.inputKind == .originalPreview ? "Analysierte Eingabe: Originalvorschau" : "Analysierte Eingabe: bearbeitete Vorschau")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                Text(result.suggestions.description).font(.system(size: 11)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(result.suggestions.attributes.enumerated()), id: \.offset) { _, attribute in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attribute.category.label).font(.system(size: 10, weight: .medium))
                        Text(attribute.value).font(.system(size: 10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    }.accessibilityElement(children: .combine)
                }
                DisclosureGroup("Analysebezug") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lokal · \(result.provenance.providerID)")
                        Text("Modell: \(result.provenance.modelID)")
                        Text("Eingaberaster: \(result.provenance.pixelWidth) × \(result.provenance.pixelHeight) Pixel")
                        Text("Raster-SHA-256: \(result.provenance.rasterSHA256)").textSelection(.enabled)
                    }.font(.system(size: 9)).foregroundStyle(Theme.muted)
                }.font(.system(size: 10))
                Text("Die Analyse bestätigt keine Identität, Gesundheit oder einen Aufnahmeort. Es werden keine Metadaten gespeichert.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Analyse verwerfen") { model.discard() }.font(.system(size: 11))
            }
        }.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .task { await model.refreshAvailability() }
            .onDisappear { model.discard() }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .analyzing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Bild wird lokal analysiert …").font(.system(size: 10))
            }.accessibilityElement(children: .combine).accessibilityLabel("Bild wird lokal analysiert")
        case .unavailable(let reason):
            Text(reason.localizedDescription).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Bildfähigkeit erneut prüfen") { Task { await model.refreshAvailability() } }.font(.system(size: 10))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            if model.availability == nil {
                Text("Lokale Bildfähigkeit wird geprüft …").font(.system(size: 10)).foregroundStyle(Theme.muted)
            } else if !model.contextAvailable {
                Text("Wähle ein verfügbares Foto. Während Katalog- oder Bearbeitungssperren ist die Analyse deaktiviert.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        case .ready: EmptyView()
        }
    }
}
