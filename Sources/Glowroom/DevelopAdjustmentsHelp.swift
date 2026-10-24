import SwiftUI

/// Explanations are opened deliberately and use normal reading size.
struct DevelopAdjustmentsHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hilfe zu Korrekturen").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    help("Globale und lokale Korrekturen",
                         "Licht, Farbe und Details wirken auf das ganze Foto. Beim Maskieren wirken die lokalen Korrekturen nur innerhalb der ausgewählten Maske. Doppelklick auf einen Regler setzt seinen Wert zurück. Die Zurücksetzen-Aktion einer Untergruppe betrifft nur deren Regler; Alle Bildkorrekturen zurücksetzen setzt die Korrekturen einschließlich Zuschnitt und Masken zurück. Die aktive Bildquelle und die Tonwertverarbeitung bleiben erhalten.")
                    help("Vier unterschiedliche Aufgaben",
                         "Natürlicher Bildausgleich analysiert Helligkeit und Farbe gemeinsam; seine Stärke und Farbwirkung bleiben einstellbar. Einzelregler automatisch setzen berechnet nur den gewählten Lichtregler, auch per Umschalt-Doppelklick. Levels automatisch setzen ersetzt die Levels aller Kanäle gemeinsam. Ein KI-Auftrag erzeugt zuerst einen prüfbaren Vorschlag mit eigener Übernahmeaktion.")
                    help("Farbe und Weißabgleich",
                         "Profile sind kreative Glowroom-Profile. Temperatur und Tönung arbeiten relativ auf bereits entwickelten Pixeln: 6500/0 erhält den Kamera-Weißabgleich. Neutralgrau wählen misst eine graue Bildfläche vor den Korrekturen. Schwarzweiß bewahrt deine bisherigen Farbeinstellungen.")
                    help("HDR und Export",
                         "HDR erhält im Rendergraph Helligkeiten oberhalb von SDR-Weiß. Die sichtbare Helligkeit hängt von Display und verfügbarer HDR-Reserve ab. HDR stellt keine verlorenen Lichter wieder her. JPEG-Export bleibt SDR; HDR-Dateiausgabe muss im Export ausdrücklich gewählt werden. Die Scopes analysieren weiterhin die SDR-Vorschau.")
                    help("Details beurteilen",
                         "Präsenz enthält Struktur, Klarheit und Dunst entfernen. Schärfen und Entrauschen beurteilst du in der Detailvorschau bei 100 oder 200 Prozent. Detailbereich auswählen lässt den Ausschnitt dem Mauszeiger folgen; ein Klick fixiert ihn, Escape beendet die Auswahl. In der Lupe verschiebt Ziehen den Ausschnitt; Klicken wechselt zwischen Einpassen und Vergrößerung.")
                    help("Bestehende Bildstände",
                         "Gespeicherte Tonwertverarbeitung bleibt unverändert. Unter Bildstände → Erweitert kannst du eine ältere Verarbeitung ausdrücklich auf sRGB Float (V2) umstellen. Prüfe danach das Bild; Rückgängig stellt den vorherigen Stand wieder her. Erweiterte Levels behalten ihre eigenen Kanal-, Eingangs- und Ausgangswerte.")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
        }.font(.system(size: 14)).padding(24).frame(width: 560, height: 600)
    }

    private func help(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ToneProcessingMigrationView: View {
    @Environment(\.dismiss) private var dismiss
    var canMigrate = true
    let migrate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tonwertverarbeitung umstellen").font(.title2)
            Text("Bisherige Verarbeitung (V1) → sRGB Float (V2)").font(.headline)
            Text("Die Tonwertkennlinien dieses Bildstands ändern sich. Regler, Levels-Kanäle und Begrenzungswerte bleiben erhalten. Prüfe die sichtbare Wirkung nach dem Umstellen. Einmal Rückgängig stellt die bisherige Verarbeitung wieder her.")
                .fixedSize(horizontal: false, vertical: true)
            if !canMigrate {
                Label("Der Bildstand hat sich geändert. Schließe diese Prüfung und öffne sie für den aktuellen Stand erneut.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Auf sRGB Float (V2) umstellen", action: migrate)
                    .accessibilityIdentifier("develop.tone-processing.confirm")
                    .disabled(!canMigrate)
            }
        }.font(.system(size: 14)).padding(24).frame(width: 540)
    }
}
