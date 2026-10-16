# Lokaler Entwicklungsassistent

Der Assistent aus [AI-02](https://github.com/dr-dimitri/picedit/issues/3) und [AI-03](https://github.com/dr-dimitri/picedit/issues/4) übersetzt bewusst eingegebene Anweisungen in die bestehenden 14 Regler. Er erhält keine Bildpixel und kann Bildinhalt, Motive oder Bildqualität nicht beurteilen. Weißabgleich und generative Bildbearbeitung werden als nicht unterstützte Aufgaben gemeldet.

## Bedienung und Datenfluss

1. Ein Foto wählen und **Entwickeln** öffnen. Im Assistenten eine Anweisung eingeben, beispielsweise „Helle die Schatten auf“. Eingaben sind auf 2048 UTF-8-Bytes begrenzt; es gibt keine automatische Anfrage beim Tippen oder Bildwechsel.
2. **Vorschlag erstellen** schließt zunächst eine aktive Reglereingabe ab und friert den tatsächlichen Bild-/Bearbeitungsstand ein. Die Modellarbeit erfolgt außerhalb des MainActor. Fortschritt und Abbruch bleiben bedienbar.
3. Der Vorschlag nennt tatsächlich geänderte Werte als Ausgang → Ziel samt berechnetem Delta. Belichtung verwendet EV, die anderen Regler ihre vorhandene Skala. Die Modellbegründung ist eine Beschreibung des Rezepts, keine Qualitätsbewertung.
4. Die Hauptansicht kennzeichnet **KI-Vorschau · noch nicht übernommen**. Der Vorschlag-Ausgangsvergleich zeigt die aktuelle Bearbeitung; **Importiertes Original anzeigen** zeigt die importierte Originaldatei ohne Regler. **Aktuelle Quelle ohne Regler** zeigt die aktive Bildbasis ohne zusätzliche Anpassungen. Quellenbezogene Vorschauen verwenden ihre jeweils decodierte Basis erneut. Raster und Filmstreifen bleiben beim übernommenen Stand.
5. **Übernehmen** prüft den vollständigen Snapshot erneut und setzt die Zielwerte gemeinsam als einen Undo-Schritt. Der Originalvergleich wird dabei geschlossen. **Verwerfen** und **Abbrechen** verändern weder Editor noch Undo oder Datenbank. Ein wirkungsloser Vorschlag lässt sich nicht übernehmen.

Neue manuelle Eingaben, Reset, Undo/Redo, A→B→A-Bildwechsel, Import/Refresh, Wartung und Schließen entwerten laufende bzw. sichtbare Vorschläge. Fehlende, gesperrte oder unlesbare Quellen führen zu einem erklärten Fehler. Ein nach Abbruch noch laufender SDK-Aufruf behält seinen Budgetplatz bis zu seiner tatsächlichen Rückkehr; seine Antwort wird verworfen. Angenommene Bearbeitungen gehören anschließend dem normalen Speicherablauf und werden durch Verwerfen der Assistentenansicht nicht abgebrochen.

Der bestehende JPEG-Export friert ausschließlich übernommene Regler ein. Auch bei sichtbarer KI-Vorschau exportiert er den Stand vor dem Vorschlag; erst nach Übernahme enthält ein neu geöffneter Export die neuen Werte. Es gibt keinen zweiten Export-/Speicherpfad.

## Voraussetzungen und Verfügbarkeit

Die App behält **macOS 14** als Mindestversion und Swift tools **5.9**. Nur der optionale Provider benötigt eine Toolchain ab **Swift 6.2**, ein FoundationModels-SDK und zur Laufzeit **macOS 26**. Apple Intelligence muss auf einem geeigneten Gerät aktiviert und das Systemmodell bereitgestellt sein. PicEdit prüft `SystemLanguageModel.availability` und `supportsLocale(de_DE)` unmittelbar vor jedem Aufruf. Alte Betriebssysteme, fehlendes SDK, ungeeignete Hardware, deaktiviertes Apple Intelligence, nicht bereites Modell, fehlende Sprachunterstützung und unbekannte Ursachen haben getrennte deutsche Meldungen. Ein bewusster neuer Versuch aktualisiert die Verfügbarkeit.

Der ausgewählte Backendtyp ist ausdrücklich `SystemLanguageModel.default`. Die Bezeichnung FoundationModels allein gilt nicht als Lokalitätsnachweis für beliebige andere Anbieter. Jede Anfrage erhält eine neue `LanguageModelSession` mit leeren Tools; es entsteht keine über Fotos wachsende Historie. PicEdit installiert keine zusätzlichen Modelle, startet keinen Download, verwendet keine Cloud und benötigt keine Schlüssel. Für die Vorbereitung des Apple-Systemmodells gelten die Systemeinstellungen von macOS; ein noch nicht vorhandenes Modell wird als nicht verfügbar gemeldet.

Der Provider sieht nur Benutzertext, versionierte Instruktionen/Antworttyp und erlaubte Reglernamen mit Grenzen und Ausgangswerten. Asset-ID, Pfad, Dateiname, Fingerprint, EXIF, Auftrags-/Revisionstoken und Bildpixel bleiben appseitig. Benutzertext wird als JSON-Datenfeld eingefügt, nicht in Systeminstruktionen eingesetzt. Prompts und Antworten bleiben flüchtig; es gibt weder Promptarchiv noch standardmäßige Protokollierung. Apples Guided Generation mit dynamischem Schema begrenzt die Struktur; danach prüft derselbe unabhängige `EditProposalValidator` wie bei anderen Anbietern sämtliche Werte, Felder und Grenzen.

Ablehnung, Eingabe-/Kontextlimit, nicht unterstützte Aufgabe, ungültige Ausgabe und temporärer Modellfehler sind getrennte Kategorien. Es gibt keine automatische Wiederholung. Eine leere bzw. unveränderte Antwort ist „Keine Änderung vorgeschlagen“; eine fehlerhafte Antwort wird niemals teilweise angewendet.

## Build- und Testmatrix

Imports und Apple-Typen sind hinter `compiler(>=6.2) && canImport(FoundationModels)` sowie macOS-26-Verfügbarkeitsgrenzen isoliert. `PICEDIT_DISABLE_FOUNDATION_MODELS` ermöglicht einen reproduzierbaren Build des SDK-unabhängigen Nichtverfügbarkeitspfads auch auf einer neuen Toolchain:

```sh
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-ai-fallback ./scripts/test.sh --jobs 4 \
  -Xswiftc -DPICEDIT_DISABLE_FOUNDATION_MODELS --filter 'LocalAI|AIAssistant'
```

Die normalen Adapter-/Controller-Tests verwenden ausschließlich Fakes, kontrollierte Fortsetzungen und synthetische Dateien. Sie prüfen Statusgründe, Datenminimierung, strenge Validierung, Abbruch, verspätete Ergebnisse, Vergleich ohne Writes, einmalige Übernahme und den vorhandenen Export. Ein Decoder-/Renderzähler prüft Wiederverwendung beim Vorschlagvergleich. `PICEDIT_PROBE_LOCAL_AI=1` aktiviert separat nur die Verfügbarkeitsprüfung. Tests mit realem Systemmodell sind nur ausdrücklich aktiviert:

```sh
PICEDIT_RUN_LOCAL_AI_EVALUATION=1 \
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-ai-evaluation ./scripts/test.sh --jobs 4 \
  --filter LocalAI
```

Das versionierte deutsche Evaluationsset prüft mindestens zwölf Aufträge auf Struktur, Änderungsrichtung, Erhalt nicht genannter Regler, fehlenden Weißabgleich/Bildanalyse, Anweisungsüberschreibung und Überlänge. Es verlangt keine exakten Zufallszahlen. Ohne bereitgestelltes Modell wird die reale Prüfung mit konkretem Grund übersprungen. Standardtests erzeugen weder Downloads noch API-Kosten.

Die Inferenz bleibt durch das gemeinsame `AIResourceBudget` auf einen aktiven lokalen Aufruf begrenzt. Die UI hält einen aktuellen Auftrag, der Coordinator höchstens einen wartenden Kontext. Unabhängige I/O und die vorhandenen begrenzten Vorschauworker dürfen parallel arbeiten. Es entstehen kein neuer Renderpool, keine zusätzliche RAW-Decodierung pro Vergleich und keine CPU-/GPU-Beschleunigungsbehauptungen.

## Primärreferenzen

- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [Generierung mit Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Guided Generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
- [Sprachen und Locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)

## Prüfbericht vom 16. Oktober 2026

Geprüft auf MacBook Pro Mac14,10, Apple M2 Pro (12 CPU-Kerne), 16 GiB RAM, macOS 27.0.1. Installiert sind die Apple Command Line Tools mit Swift 6.4 (`swiftlang-6.4.0.34.1`), kein ausgewähltes vollständiges Xcode.

| Prüfung | Ergebnis |
| --- | --- |
| Vollständige normale Suite, SDK 27 | 229 Tests in 25 Suites erfolgreich; vier ausdrücklich optionale Prüfungen übersprungen (Modellprobe, Modellevaluation, Analysebenchmark, Kamera-RAW-Export) |
| Lokaler Provideradapter | 12 Tests erfolgreich, einschließlich sieben Verfügbarkeitsgründen und fünf Ablehnungsarten |
| Assistent/Preview/Export/Snapshot/Editor | 37 gezielte Tests erfolgreich |
| Echtmodell-Evaluation v1 | Alle zwölf deutschen Fälle erfolgreich; keine Bilddaten verwendet |
| Vollständiger Debugbuild mit stabilem SDK 26.5 | Erfolgreich, Deploymentziel macOS 14 |
| Vollständiger Debugbuild mit erzwungenem SDK-unabhängigem Fallback | Erfolgreich; keine FoundationModels-Bibliotheksabhängigkeit |
| Sauberer vollständiger Release-App-Build | Erfolgreich mit `PICEDIT_BUILD_JOBS=4 ./scripts/build-app.sh`, nach Entfernen von `.build/`, `.build-app/` und `dist/PicEdit.app`; Bundle/Plist/Signatur validiert |

Das SDK-26.5-Binärprogramm besitzt `minos 14.0` und eine schwache FoundationModels-Verknüpfung. Dadurch bleibt die Framework-Abwesenheit auf älteren Systemen mit dem Compile-/Runtime-Fallback vereinbar. Ein tatsächlich älterer Swift-5.9-Compiler und reale macOS-14-/26-Systeme wurden hier nicht ausgeführt.

Die finale Echtmodell-Evaluation dauerte 28,015 s: erster Aufruf 3,207 s, nachfolgende Inferenzaufrufe 2,211–2,725 s. Der Testprozess meldete maximal 29.081.600 Bytes RSS; der getrennte Systemmodellservice ist darin **nicht** enthalten. Das Systemmodell war durch vorangegangene Prüfungen bereits warm. Diese Zahlen sind weder eine Kaltcachemessung noch ein Vergleich zur bisherigen manuellen Bearbeitung oder eine Aussage zum gesamten Modellspeicher. Große Kamera-RAWs lagen für diesen Auftrag nicht als ausdrücklich freigegebene Testdateien vor.

In der Ausführungssandbox war der Modellservice trotz positiver Verfügbarkeitsmeldung gesperrt; die echte Evaluation wurde außerhalb dieser Sandbox ausgeführt. Erste Modellproben fanden falsche Richtungen/Capability-Antworten; nach Verbesserung der versionierten Instruktionen und Schemabeschreibungen bestanden dieselben strengen Erwartungen. Ungültige Zwischenantworten wurden vom unabhängigen Validator verworfen und nie übernommen.

Das unabhängige finale Review umfasste Code, Schnittstellen, Tests und Dokumentation. Ein zunächst unbegrenzter Reader beim Abbrechen wurde durch den gemeinsamen seriellen Quellprüfer ersetzt und erneut geprüft; keine umsetzungsbezogenen Befunde blieben offen. Der bereits bestehende veraltete Exporthinweis im historischen Reviewbericht ist separat als [Issue #19](https://github.com/dr-dimitri/picedit/issues/19) erfasst.

Die Sichtprüfung verwendet einen getrennten Katalog mit zwölf programmatisch gezeichneten JPEGs, keine persönlichen Fotos. Im finalen Release-Build wurde „Helle die Schatten auf“ lokal zu Tiefen 0 → 30 übersetzt. Die unverbindliche Vorschau, der Originalvergleich, das bewusste Übernehmen mit Schließen des Originalvergleichs und ein einzelnes Undo auf 0 funktionierten; danach war kein weiterer Undo-Schritt vorhanden. Der Inspector ist 300 Punkte breit; Beschriftungen, deaktivierte Aktionen, Eingabefokus und Aktionen sind in der Accessibility-Hierarchie erkennbar. Eine vollständige akustische VoiceOver-Prüfung, alle schmalen Fensterzustände und physisch getrenntes Netzwerk wurden nicht geprüft. Die Lokalität stützt sich hier auf die explizite SystemLanguageModel-Route und den fehlenden Netzwerk-/Cloudpfad im Provider.
