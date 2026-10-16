# Review: Bibliothek, Bearbeitung und Sicherungen

Stand: 16. Oktober 2026. Geprüft auf dem vorhandenen Apple-Silicon-Mac mit macOS 27 und den Apple Command Line Tools. Keine Behauptung einer vollständigen Fehlerfreiheit oder identischer Ergebnisse auf jeder Kamera/macOS-Version.

## Umfang

Review der Implementierung für Bibliothek und Ordnerbaum, RAW-Vorschauen, Tonwert/Präsenz/Entrauschen, Datenbank, Backup-/Recovery-Pfade, asynchrone Speicherung und Oberfläche. Datenbank, Renderer und Controller wurden parallel implementiert und anschließend zusätzlich auf ihre Schnittstellen zur Oberfläche geprüft.

## Gefundene und behobene praxisrelevante Fehler

- Zahleneingaben erzeugten zunächst einen Undo-Schritt pro gültigem Zahlenpräfix. Zusammenhängende Eingaben werden jetzt gruppiert; im App-Test führte Rückgängig direkt von 45 zum vorherigen Wert 3 zurück.
- Nicht abgeschlossene Zahlenfelder werden beim Bildwechsel, Sichern und Beenden vor der Zustandssperre übernommen.
- Ein ungültiges Backup darf eine gesunde Datenbank weder verändern noch den Editor dauerhaft sperren. Der bisherige Zustand wird geprüft und bleibt bearbeitbar.
- Eine beschädigte Datenbank ließ sich ursprünglich nicht über den normalen Restore-Pfad öffnen. Ein separater Recovery-Pfad validiert die Sicherung zuerst und erhält die beschädigte Datenbank samt Begleitdateien in einem Archiv.
- Selbst das Prüfen einer beschädigten SQLite-Datei kann Begleitdateien verändern. Die Recovery-Diagnose erfolgt deshalb an einer entbehrlichen Kopie; die archivierten Originaldateien bleiben bytegleich.
- Ältere oder widersprüchliche Schreibversionen werden als Konflikt gemeldet, statt dem Controller fälschlich erfolgreiches Speichern zu signalisieren.
- Backup-Export und Wiederherstellung werden als laufende Wartung behandelt. Beenden kann sie nicht unbemerkt unterbrechen; fehlgeschlagene Exporte erhalten das lokale Backup und das bisherige Ziel.
- Gescheiterte Schreibvorgänge zeigen ungespeicherte Änderungen mit einer Wiederholen-Aktion statt einer dauerhaft irreführenden Ladeanzeige.
- RAW-Kameravorschauen und entwickelte Bearbeitungsbasen verwenden getrennte Cache-Schlüssel. Bearbeitungsbasen werden verlustfrei gespeichert, damit erneutes Öffnen keine zusätzlichen JPEG-Artefakte in die Rauschbeurteilung einführt.
- Die tägliche Backup-Prüfung wird bei unveränderter Datei wiederverwendet; eine Regleränderung löst nicht ständig eine vollständige Integritätsprüfung aller Backup-Datensätze aus.
- Der native Speichern-Dialog ergänzt die Dateiendung selbst; der voreingestellte Name erhält keine doppelte `.sqlite`-Endung.

## Prüfung

- `./scripts/test.sh`: 84 erfolgreiche Tests (59 App-/Controller-/Renderer-/Cache-Tests, 25 Core-/Datenbanktests).
- `./scripts/test-image-pipeline.sh`: erfolgreich; Größenbegrenzung, EXIF-Orientierung, Cache, konkurrierende Anfragen, Abbrüche und defekte Eingaben.
- `./scripts/benchmark-library.sh`: erfolgreich mit 10.000 synthetischen Einträgen und Prüfsumme 473849. Misst Bibliotheksberechnungen, keine RAW-Decodierung.
- Release-App gebaut, Bundle validiert und lokal signiert.
- Separater synthetischer UI-Katalog: Tonwert, Präsenz, Entrauschen, Zahlenfelder, Undo/Redo, Bildwechsel, Neustart, Backup-Export und Wiederherstellung geprüft. Produktionsfotos wurden dabei nicht verändert.
- UI-Backup-Drill: nach der Sicherung eine zusätzliche Belichtungsänderung angelegt, Backup wiederhergestellt und aktive Datenbank, exportierte Sicherung sowie Sicherheitsbackup mit `integrity_check` geprüft. Wiederhergestellter Stand und vorherige Änderung im Sicherheitsbackup waren korrekt vorhanden.

## Bekannte Funktionsgrenzen

Die interaktive Bearbeitungsansicht verwendet Vorschauen bis 2400 Pixel langer Kante. Der implementierte [JPEG-Export](JPEG-EXPORT.md) decodiert dagegen das Original in voller Auflösung und wendet die übernommenen Bearbeitungsfilter an; optionale Größenbegrenzung und RAW-Unterstützung sind dort beschrieben. Die Filter bieten klassische Bildkorrekturen, keine identische Adobe-RAW-Engine und kein KI-Entrauschen. Die Backups enthalten Bearbeitungswerte; Originalbilder und der bestehende Bibliothekskatalog `catalog.json` müssen separat gesichert werden. Undo-Verläufe gelten für die Sitzung, aktuelle Reglerwerte werden dauerhaft gespeichert. Bearbeitungen sind an die vorhandenen pfadbasierten Bildkennungen gebunden.

## Ergänzung: Tonwert-Automatik

Die Automatik analysiert eine auf höchstens 256 Pixel lange Kante begrenzte, nach Transparenz gewichtete Vorschau. Eine monotone Tonwertkurve gleicht Schatten und Lichter aus, behält Schwarz und Weiß bei und verstärkt bei geringer Tonwertspreizung behutsam den Kontrast. Die Analyse erfolgt auf der unveränderten Bildbasis, die Korrektur vor den manuellen Tonwertreglern. Sie verwendet keine räumliche Maskierung, die Halos an Kanten erzeugen könnte.

Im Review wurde ein relevanter Sonderfall korrigiert: Eine kleine dunkle Fläche vor überwiegend hellem Hintergrund darf durch die Korrektur der mittleren Helligkeit nicht noch dunkler werden. Zusätzlich zu robusten Quantilen berücksichtigt die Analyse deshalb die dunklen und hellen Bildanteile; die Anker der Kurve schützen die jeweilige Korrekturrichtung. Umgekehrt gilt das für kleine helle Flächen in dunklen Bildern.

Ein zusätzlicher Farbtest fand neue Maximalwerte in zuvor nicht abgeschnittenen Farbkanälen stark gesättigter Motive beim Aufhellen. Die Farbkorrektur hält dafür einen kleinen Abstand zur Kanalgrenze; eine Regression prüft gesättigte rote, grüne und blaue Motive. Die bestehende Verarbeitung weiter Farbräume bleibt erhalten.

Die neue Einstellung wird nur bei fehlendem Feld als ausgeschaltet interpretiert. Alte Datenbanken und Backups bleiben lesbar, während ungültige oder unvollständige Datensätze weiter abgewiesen werden. Die Automatik ist Bestandteil von Cache-Identität, Undo/Redo, vollständigem Zurücksetzen und Sicherungen. Ein eigener Controller-Test prüft den Stärkeregler als zusammenhängenden Undo-Schritt, erhaltene manuelle Werte, Bildwechsel und Neustart. Separate Datenbanktests prüfen ältere Nutzdaten und die neue Einstellung über Neustart, Backup und Wiederherstellung.

Abschließende Prüfung: **102 Tests erfolgreich** (72 App-/Renderer-/Controller-Tests und 30 Core-/Datenbanktests), darunter 12 gezielte Tests der Automatik. Release-Build und Signaturprüfung erfolgreich. Im getrennten synthetischen UI-Katalog wurden Schalter, Stärke, Rückgängig, Bildwechsel und Vorher-Vergleich bedient; nach dem Neustart blieb die Stärke von 51 % erhalten und die korrigierte Vorschau wurde angezeigt.

Vollständig ausgebrannte Lichter oder vollständig schwarze Bildbereiche enthalten keine rekonstruierbare Zeichnung. Die Automatik kann vorhandene Tonwerte ausgleichen; starke nachfolgende manuelle Reglerwerte können weiterhin über- oder unterbelichten.

## Folgereview: Issues #32–#38

Das Anwendungsreview vom 16.10.2026 erfasste sieben weitere Fehler. Die Korrekturen wurden in getrennten Bereichen parallel umgesetzt und anschließend unabhängig sowie an ihren gemeinsamen Schnittstellen geprüft:

- [#32](https://github.com/dr-dimitri/picedit/issues/32): Bereits angenommene Metadaten-Writes aktualisieren ihre dauerhafte Revision auch nach Bewertung/Favoritenänderung oder beim Beenden. Quellenwechsel und neuere Formulare bleiben geschützt. Regressionen prüfen manuelle und KI-Entwürfe, Folgeänderungen, A→B→A, neuere Revisionen sowie den tatsächlichen LibraryModel-/SQLite-Quit-Pfad.
- [#33](https://github.com/dr-dimitri/picedit/issues/33): Der Inspector verwendet dieselbe aufgelöste Original-/Artefaktquelle wie Raster und Hauptvorschau, mit Priorität für das ausgewählte Bild.
- [#34](https://github.com/dr-dimitri/picedit/issues/34): Eine optionale validierte Anthropic-Workspace-ID wird in Einstellungen, Freigabe und HTTP-Header konsistent verwendet. Konfigurationsänderungen entwerten bestehende Freigaben; ungültige IDs starten keinen Upload.
- [#35](https://github.com/dr-dimitri/picedit/issues/35): Gültige Antworten ohne Regleränderung behalten ihre geprüfte Erklärung. Sie bleiben ohne Übernahme-, Undo- und Speicherwirkung.
- [#36](https://github.com/dr-dimitri/picedit/issues/36): Die Koordinationswurzel wird samt Owner atomar veröffentlicht. Tests prüfen jeweils 2 und 16 gleichzeitige Erstöffner über 16 frische Kataloge, beschädigte Owner, Neustart nach unterbrochener Vorbereitung, Abbruch und Schutz interner Stage-Dateien vor Export.
- [#37](https://github.com/dr-dimitri/picedit/issues/37): Vorschau-Smoke und Editing-/Library-Benchmarks bauen den echten SwiftPM-Abhängigkeitsbaum. Veraltete Quell-Checkouts werden vor Ausführung abgewiesen; regulärer App-Build und Tests entfernen die interne Harness-Auswahl aus der Umgebung.
- [#38](https://github.com/dr-dimitri/picedit/issues/38): Der lokale ad-hoc App-Build speichert Schlüssel im lokalen macOS-Keychain mit explizitem App-Zugriffsschutz. Berechtigte signierte Builds behalten Data Protection. Bei Zugriffsfehlern wird nicht zwischen Speichern gewechselt. Der native Smoke verwendet ausschließlich einen synthetischen Schlüssel in einem eigenen UUID-Namensraum.

Das Gegenreview fand zwei zusätzliche Risiken im neuen Harness-Aufruf (historischer Checkout startet die normale App; geerbte Harness-Auswahl gelangt in den Bundle-Build); beide wurden vor Abschluss abgesichert und durch Shell-Prüfungen abgedeckt. Ein Initialisierungsfehler im neuen Einstellungsfeld wurde nach dem ersten Compilerlauf korrigiert. Bestehende unabhängige Issues [#27](https://github.com/dr-dimitri/picedit/issues/27) und [#30](https://github.com/dr-dimitri/picedit/issues/30) bleiben außerhalb dieses Änderungsumfangs.

Verifiziert mit dem integrierten Stand auf dem vorhandenen Mac:

- Vollständige Suite erfolgreich: 437 App-Tests in 58 Suites und 276 Core-Tests in 35 Suites. Elf Opt-in- beziehungsweise ausschließlich über einen Elternprozess verwendete Testeinstiegspunkte meldeten im Standardlauf „skipped“. Der Lauf startete absichtlich mit geerbter Harness-Auswahl; das Testskript verwendete korrekt die normale App-Konfiguration.
- Vorschau-Smoke erfolgreich, einschließlich Orientierung, Cache, Zusammenfassung identischer Anfragen und 40 Abbrüchen.
- Library-Benchmark erfolgreich: 10.000 synthetische Einträge, erwartete Prüfsumme 473849.
- Editing-Benchmark mit Session-API erfolgreich: einfache und komplexe Bearbeitung in beiden Größen, wechselnde Quellen, schnelle Reglerfolgen und Rendering mit einem sowie zwei Arbeitern. Zusätzlich bestand der Standardaufruf ohne Session-Flag mit komplexer Bearbeitung bei 400 × 267 Pixeln. Kalte und warme Reglerfolgen benötigten keine erneute Decodierung; die Vergleichsmessungen früherer Abschnitte bleiben unverändert.
- Echte ad-hoc signierte Keychain-Testapp erfolgreich: synthetischen UUID-Schlüssel gespeichert, gelesen, ersetzt und gelöscht. Kein produktiver Schlüssel wurde gelesen oder verändert.
- Shell-Prüfungen für Build-Steuerung, Fehler-/Abbruchpfade, Harness-Umgebung und inkompatible Quell-Checkouts erfolgreich; Syntax- und Diffprüfung ohne Fehler.

Grenzen dieser Prüfung: keine kostenpflichtigen Cloud-Livecalls, keine neu bereitgestellten Kamera-RAWs oder lokalen Modelle und kein provisionierter Data-Protection-Build. Die Benchmark-Läufe prüfen Funktion und reproduzierbare Ergebnisse; aus ihnen wird keine neue Beschleunigung abgeleitet.

## Ergänzung vom 17. Oktober 2026: Exportschutz und native Katalogdateien

[Issue #27](https://github.com/dr-dimitri/picedit/issues/27) betrifft Originale, die erst nach dem Öffnen eines JPEG-Exportdialogs importiert werden. Bearbeitungen und Ausgabeoptionen bleiben eingefroren; der Originalschutz wird dagegen bei jedem Versuch und vor der Veröffentlichung aus dem aktuellen Katalog ergänzt. Angenommene und wartende Imports sowie andere Änderungen von Quellenverweisen bleiben bis zu ihrem tatsächlichen Abschluss registriert. Die abschließende Referenzprüfung verwendet den nativen Katalog-Publikationslock; unmittelbar vor dem atomaren Rename werden zusätzlich die lokale Zulässigkeit und Generation geprüft. Ein inzwischen geänderter oder noch beschäftigter Katalog führt zu einem wiederholbaren Fehler, ohne die Zieldatei zu ersetzen. Diese Sperren umfassen weder Bilddecodierung noch Rendering.

[Issue #30](https://github.com/dr-dimitri/picedit/issues/30) betrifft das Schließen abgewiesener Katalogdateien, die auf einen aktiven SQLite-Inode zeigen. Ein FD-loser Vorabcheck weist bereits vorhandene Hardlinks vor dem Öffnen ab. Nach einem Open übernimmt die vorhandene begrenzte Native-FD-Verwaltung den Deskriptor vor jeder weiteren Prüfung; ein `FileHandle` darf ihn nur ausleihen. Dadurch bleibt auch bei einem zwischen Vorabprüfung und Open ausgetauschten Pfad der physische Close bis zum Ende eines registrierten SQLite-Scopes zurückgestellt. Eigene Staging-Payloads und duplizierte Koordinator-Payloads verwenden denselben Lebenszyklus. Es wird keine zusätzliche Kernelsperre um SQLite-Transaktionen gelegt.

Die beiden Bereiche wurden unabhängig implementiert und an ihrer gemeinsamen Katalog-Publikationsschnittstelle geprüft. Dateizugriffe und Rendering bleiben im Hintergrund. Abhängige Schutzprüfung und Rename werden bewusst seriell ausgeführt, damit kein neu angenommener Import zwischen Prüfung und Veröffentlichung gelangen kann. Änderungen an Originalbildern erfolgen ausschließlich an synthetischen Testkopien; persönliche Fotos werden nicht für destruktive Reproduktionen verwendet.

Der integrierte Lauf mit `./scripts/test.sh --jobs 6` war erfolgreich: Swift Testing meldet 442 App-Tests in 58 Suites und 278 Core-Tests in 36 Suites; 16 optionale beziehungsweise ausschließlich für Unterprozesse bestimmte Tests wurden übersprungen. Alle neuen Regressionen sind enthalten, einschließlich zwölf Export-Szenarien und sechs Katalog-/SQLite-Sperrfällen. Das finale unabhängige Code-Review fand keine weiteren Fehler in diesen Änderungen. Die Recovery-Exporttests simulieren aktualisierte Schutzpfade und Fehlerzustände; sie ersetzen keinen vollständigen neuen Bookmark-Recovery-End-to-End-Test. Nicht veröffentlichte Imports anderer Prozesse sowie externe Umbenennungen bleiben außerhalb der lokalen Importsperre.
