import SwiftUI

struct AIProviderSettingsView: View {
    @ObservedObject var settings: AIProviderSettings
    var body: some View {
        Form {
            Picker("KI-Anbieter", selection: Binding(get: { settings.selection }, set: settings.select)) {
                ForEach(AIProviderSettings.Selection.allCases) { Text($0.label).tag($0) }
            }
            Text("Lokal funktioniert ohne Konto. Es gibt keinen automatischen Cloud-Fallback. Anthropic unterstützt hier ausschließlich Text-Regleraufträge; Bilder und drei Cloud-Looks sind nicht verfügbar.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Anthropic Cloud bewusst aktivieren", isOn: Binding(get: { settings.enabled }, set: settings.setEnabled))
            LabeledContent("Modell", value: CloudAIProvider.model)
            SecureField("Eigener Anthropic-API-Schlüssel", text: $settings.keyInput)
                .textContentType(.password)
            HStack {
                Button("Schlüssel speichern / ersetzen") { settings.saveKey() }.disabled(settings.keyInput.isEmpty || settings.keyBusy)
                Button("Schlüssel löschen") { settings.deleteKey() }.disabled(settings.keyBusy)
            }
            Text("Nur im gerätegebundenen macOS-Keychain; kein Lesen beim Start. Das Eingabefeld wird nach dem Speichern geleert.")
            Stepper("Auftragslimit: \(settings.requestLimit) pro UTC-Monat", value: $settings.requestLimit, in: 1...10_000)
            Stepper("Modellpreisbudget: \(settings.budgetDollars) USD pro UTC-Monat", value: $settings.budgetDollars, in: 1...1_000)
            Button("Limits speichern") { settings.saveLimits() }
            Text("Outputlimit: 1200 Tokens pro Auftrag. Vor Versand werden konservativ 0,60 USD vorgemerkt; vollständige gemeldete Nutzung gleicht den Modellpreis ab. Keine Euro- oder Rechnungsgarantie; Preise vom 16.10.2026, andere Apps und Anbieteränderungen sind nicht erfasst. Zusätzlich ein Anbieterbudget setzen.")
                .fixedSize(horizontal: false, vertical: true)
            Text(settings.usageText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Nutzung aktualisieren") { Task { await settings.refreshUsage() } }
                Button("Freigaben widerrufen und Anfragen abbrechen") { settings.revoke() }
            }
            Text("Verarbeitung weltweit; Standard-API-Daten in der Regel innerhalb 30 Tagen gelöscht, mit Anbieter-Ausnahmen (u.a. Safety/Recht). Keine EU-Residenz- oder Zero-Retention-Garantie. Jeder Upload braucht eine neue Einzelfreigabe.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Datenaufbewahrung", destination: URL(string: "https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data")!)
                Link("Preise", destination: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!)
            }
            if let message = settings.message { Text(message).accessibilityLabel(message).fixedSize(horizontal: false, vertical: true) }
        }
        .formStyle(.grouped).padding().frame(width: 620, height: 720)
        .task { await settings.refreshUsage() }
    }
}

struct AICloudConsentView: View {
    let consent: AICloudConsent
    let answer: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diesen Textauftrag an Anthropic senden?").font(.headline)
            Text("Anbieter: Anthropic · Modell: \(consent.model)")
            Text("Ein eingefrorener Textauftrag mit Regler-Ausgangswerten, \(consent.bodyByteCount) Requestbytes. Keine Bilder (Anzahl 0), keine Auflösung, keine Dateipfade oder Fotometadaten aus dem Katalog. Dein eingegebener Text wird übertragen.")
            Text("Outputlimit \(consent.maximumOutputTokens) Tokens. Konservative Vormerkung 0,60 USD; nach vollständiger gemeldeter Nutzung Abgleich zum geschätzten Modellpreis. Bei Abbruch oder unsicherer Antwort bleibt die Vormerkung bestehen. Kosten entstehen in deinem API-Konto.")
            Text("Verarbeitung kann weltweit stattfinden. Für Standard-API-Konten gelten in der Regel bis 30 Tage Aufbewahrung; Ausnahmen sind möglich. Keine EU-Residenz- oder Zero-Retention-Garantie.")
            HStack {
                Button("Nicht senden", role: .cancel) { answer(false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Einmal senden · bis 0,60 USD vormerken") { answer(true) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530).fixedSize(horizontal: false, vertical: true)
    }
}
