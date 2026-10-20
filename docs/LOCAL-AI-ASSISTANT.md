# Lokaler Entwicklungsassistent

Der Assistent aus [AI-02](https://github.com/dr-dimitri/picedit/issues/3) und [AI-03](https://github.com/dr-dimitri/picedit/issues/4) verbindet deutsche Bearbeitungswünsche mit PicEdits vorhandenen Reglern. Auf **macOS 27 mit FoundationModels 2** berücksichtigt er zusätzlich das aktuelle Foto und kann **Motiv, Hintergrund oder Himmel** gezielt korrigieren. Auf macOS 26 beziehungsweise mit älterem SDK bleibt der lokale Textprovider für globale Regler verfügbar. Die optionale Cloud bleibt ebenfalls textbasiert und global. Weißabgleich, beliebige benannte Objekte und generative Bildbearbeitung gehören nicht zu diesem Ablauf.

## Bedienung

1. Ein Foto wählen und unter **Entwickeln → Assistent** eine Anweisung eingeben, beispielsweise „Helle die dunklen Bereiche etwas auf“, „Korrigiere den überstrahlten Hintergrund“ oder „Mache den Hintergrund schwarz weiss“. Eingaben sind auf 2048 UTF-8-Bytes begrenzt; Tippen und Bildwechsel starten keine Anfrage.
2. **Bearbeitung ausführen** schließt eine aktive Reglereingabe ab und friert den aktuellen Bild-/Bearbeitungsstand ein. Vorbereitung, Inferenz und automatische Auswahl laufen außerhalb des MainActor. Fortschritt und Abbruch bleiben bedienbar.
3. Das Ergebnis zeigt Erklärung sowie geänderte Werte als Ausgang → Ziel mit Delta, getrennt nach gesamtem Bild und betroffenen Bereichen. Belichtung verwendet EV, die übrigen Regler ihre vorhandene Skala. Eine gültige Antwort aktiviert alle Änderungen gemeinsam als **einen Rückgängig-Schritt**. Ein zusätzlicher Übernehmen-Knopf entfällt; ein wirkungsloser Vorschlag bleibt eine Erklärung ohne Änderung.
4. **⌘Z** nimmt die Bearbeitung zurück. **Ausgangsstand / Aktive Bearbeitung** vergleicht den eingefrorenen Ausgang mit dem Ergebnis. **Importiertes Original anzeigen** und **Aktuelle Quelle ohne Regler** bleiben die normalen Quellenvergleiche. **Ergebnis schließen** schließt nur die Anzeige; aktive Anpassungen bleiben erhalten. **Abbrechen** beendet einen noch laufenden Auftrag ohne neue Bearbeitung.

**Maskieren** bleibt unabhängig in der rechten Werkzeugleiste verfügbar. Der Assistent ergänzt bei räumlichen Aufträgen neue, eingefrorene lokale Ebenen; vorhandene Masken und ihre Einstellungen bleiben erhalten. Diese Ebenen lassen sich anschließend wie andere lokale Korrekturen prüfen und bearbeiten. Der frühere Knopf **Drei Looks erstellen**, die Lookkarten und der eigenständige Bereich **Bildanalyse** wurden entfernt. Die erhaltenen Look-APIs und Tests sind [Kompatibilitätsbestand](AI-LOOKS.md).

## Bildbezug und Grenzen

Der lokale Bildprovider erhält eine **bearbeitete Vorschau mit höchstens 1024 Pixeln langer Kante und 16 MiB tatsächlichen Rasterbytes**, die Anweisung und erlaubte Regler mit Grenzen/Ausgangswerten. Das Raster entspricht dem eingefrorenen Bearbeitungsstand. Pfade, Dateinamen, Asset-/Auftragskennungen, Revisionstoken und EXIF werden nicht an das Modell gegeben. Die vorhandene [Rastervorbereitung](AI-IMAGE-ANALYSIS.md) übernimmt Quellenprüfung, Bildorientierung und Rasterdigest; sie nutzt die begrenzten Decoder-/Renderpipelines.

Der lokale Bildpfad verwendet zwei nacheinander ausgeführte, isolierte Modellsitzungen: Zuerst bestimmt eine kurze Textklassifikation den gewünschten Geltungsbereich allein aus der Anweisung. Danach wählt eine zweite Sitzung mit den Bildpixeln passende numerische Werte. Beide Phasen teilen dieselbe Inferenzlease; es gibt keine gespeicherte Gesprächshistorie. Diese zusätzliche Klassifikation kostet Zeit; daraus wird kein Leistungsgewinn abgeleitet.

Das Schema der zweiten Phase erlaubt nur die zuvor bestimmten Bereiche und verbietet globale Werte, wenn keine globale Korrektur angefordert wurde. Eine unabhängige Prüfung verwirft ausgelassene oder zusätzliche Ziele und unzulässige globale Änderungen; eine ergänzende konservative Textprüfung erkennt verlorene eindeutige Bereichswünsche. Die strikt geprüfte Modellantwort enthält globale Zielwerte und höchstens **drei Bereichsaufträge** für `subject`, `background` oder `sky`. Benötigt ein angeforderter Bereich keine Korrektur, bleibt sein Ziel im Plan mit leerer Änderungsliste erhalten; dafür wird weder eine Maske berechnet noch eine Ebene oder ein Undo-Schritt angelegt. Die App erzeugt deren Auswahl aus einer geometrieneutralen Vorschau der orientierten Quelle und friert das Maskenraster ein. Hintergrund bedeutet die umgekehrte Motivauswahl; beliebige Objekte wie einzelne Häuser oder Stühle werden nicht lokalisiert. Eine Himmelsauswahl benötigt das bereits eingerichtete lokale Himmelsmodell. Der Assistent startet keinen Modelldownload. Bei einem beschnittenen Foto sieht die Planung den aktuellen Ausschnitt, während die automatische Motivauswahl auf der vollständigen orientierten Quelle entsteht. Das dort erkannte Hauptmotiv kann vom gewünschten Motiv im Ausschnitt abweichen; die Auswahl und Bildwirkung anschließend visuell prüfen und bei Bedarf über Maskieren korrigieren.

Fehlende oder unbrauchbare Auswahl verwirft die **gesamte** Bearbeitung einschließlich globaler Werte. Die Auswahl muss bestimmte ausgewählte und nicht ausgewählte Pixel enthalten und zwischen 1 und 99 Prozent mittlerer Abdeckung liegen. Es gibt keinen Ersatz durch eine unbemerkte globale Korrektur. Bestehende Ebenen zählen weiterhin zu den normalen Grenzen von 16 lokalen Ebenen und 16 MiB Maskendaten. Vollständig ausgebrannte Bildinformationen lassen sich durch Abdunkeln nicht wiederherstellen; die Erklärung ist keine Qualitätsgarantie.

Alle Zielwerte werden unabhängig validiert. Nicht genannte globale Regler bleiben erhalten; lokale Änderungen beginnen in neuen Ebenen. Originaldateien bleiben unverändert. Raster, Filmstreifen und neu geöffnete JPEG-Exporte verwenden die aktive Bearbeitung über den üblichen Speicher-/Renderpfad, auch bei sichtbarem Ausgangsvergleich.

„Schwarzweiß“, „schwarz weiß“ und „schwarz weiss“ bedeuten vollständige Entsättigung mit `saturation=-100`; `0` ist der neutrale Farbwert. Bei einem reinen Hintergrundauftrag wird dieser Wert ausschließlich in einer neuen Hintergrundebene angewandt. Motivfarben und globale Helligkeitsregler bleiben erhalten. Der Planungsprompt (Version 3) und die Reglerbeschreibung erklären diese Bedeutung ausdrücklich. Das Generierungsschema begrenzt numerische Werte zusätzlich auf die gemeinsame äußere Spanne −100 bis 100; die unabhängige Prüfung erzwingt weiterhin die engeren Grenzen jedes Parameters, insbesondere −5 bis 5 EV für Belichtung. Ungültige Vorschläge werden weder geklemmt noch nachträglich in andere Korrekturen umgedeutet.

Neue manuelle Eingaben, Reset, Undo/Redo, A→B→A-Bildwechsel, Quellenwechsel, Wartung und Schließen entwerten laufende oder sichtbare Ergebnisse. Quellenprüfung, Abbruchkontrollen und die vollständige Snapshotprüfung unmittelbar vor Annahme verhindern das Aktivieren überholter Ergebnisse. Fehlende, gesperrte oder unlesbare Quellen führen zu einem erklärten Fehler. Ein nach Abbruch noch laufender SDK-Aufruf behält seinen Budgetplatz bis zu seiner tatsächlichen Rückkehr; seine Antwort wird verworfen. Bereits angenommene Bearbeitungen werden zuverlässig im normalen Editorablauf gespeichert und durch Schließen der Ergebnisanzeige nicht abgebrochen.

Der natürliche Bildausgleich bleibt ausdrücklich anforderbar, etwa „Aktiviere den natürlichen Bildausgleich“. Sein Farbanteil lässt sich getrennt setzen, ohne einen ausgeschalteten Ausgleich zu aktivieren. Die bisherige Tonwert-Automatik bleibt für alte Bearbeitungen lesbar und soll nicht neu aktiviert werden. Details: [Natürlicher Bildausgleich](NATURAL-BALANCE.md).

## Voraussetzungen und Datenminimierung

Die übrige App behält **macOS 14** als Mindestversion. Der lokale Textprovider benötigt Swift 6.2, ein FoundationModels-SDK, macOS 26, geeignetes Gerät und ein bereitgestelltes Apple-Intelligence-Systemmodell. Bildbezogene Bearbeitung benötigt zusätzlich **Swift 6.4, FoundationModels 2 / SDK 27 und macOS 27**. Text- und Vision-Bereitschaft sowie Deutschunterstützung werden ausdrücklich geprüft; das Vorhandensein des Frameworks allein genügt nicht. Bei fehlender Unterstützung nennt die Oberfläche den Grund. Ein bewusster neuer Versuch prüft die Verfügbarkeit erneut.

Der Backendtyp ist ausdrücklich `SystemLanguageModel.default`. Jede Anfrage erhält eine frische Sitzung ohne Tools; es entsteht keine über Fotos wachsende Historie. PicEdit installiert kein Apple-Modell und benötigt dafür weder Konto noch Schlüssel. Textfallback und [optionaler Cloudprovider](ai/CLOUD-PROVIDER.md) erhalten keine Bildpixel und führen ausschließlich globale Regleränderungen aus. Lokale Fehler wechseln niemals automatisch zur Cloud; der Cloudpfad bleibt separat auszuwählen und je Textauftrag freizugeben.

Benutzertext wird als Datenfeld übergeben. Prompts und Antworten bleiben flüchtig, ohne Promptarchiv oder standardmäßige Protokollierung. Guided Generation begrenzt die Form; unabhängige Validatoren prüfen danach alle Werte, Felder, Grenzen und Bereichsaufträge. Ablehnung, Eingabe-/Kontextlimit, nicht unterstützte Aufgabe, ungültige Ausgabe und temporärer Modellfehler bleiben getrennte Kategorien. Es gibt keine automatische Wiederholung und keine Teilübernahme ungültiger Antworten.

## Build- und Testmatrix

Apple-Typen bleiben hinter Compile-/Laufzeitgrenzen isoliert: Text ab `compiler(>=6.2) && canImport(FoundationModels)`, Bildattachments ab `compiler(>=6.4) && canImport(FoundationModels, _version: 2.0)` sowie macOS 27. `PICEDIT_DISABLE_FOUNDATION_MODELS` prüft den SDK-unabhängigen Nichtverfügbarkeitspfad:

```sh
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-ai-fallback ./scripts/test.sh --jobs 4 \
  -Xswiftc -DPICEDIT_DISABLE_FOUNDATION_MODELS --filter 'LocalAI|AIAssistant'
```

Normale Tests verwenden Fakes, gesteuerte Fortsetzungen und synthetische Dateien. Sie prüfen strenge Antwortvalidierung, Quellen-/Bearbeitungswechsel, Abbruch und verspätete Ergebnisse, automatische Auswahlfehler, Erhalt vorhandener Masken, gemeinsame Annahme als einen Schritt sowie Vergleich und Export. Sie starten weder Downloads noch kostenpflichtige Anfragen. `PICEDIT_PROBE_LOCAL_AI=1` prüft separat die Textmodell-Verfügbarkeit.

Die vorhandene Text-Evaluation und die neue Bildbearbeitungsprobe werden ausdrücklich und getrennt aktiviert:

```sh
PICEDIT_RUN_LOCAL_AI_EVALUATION=1 \
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-ai-evaluation ./scripts/test.sh --jobs 4 --filter LocalAIProviderEvaluationTests
PICEDIT_RUN_IMAGE_EDITING_EVALUATION=1 \
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-image-editing-evaluation ./scripts/test.sh --jobs 2 --filter LocalImageEditingEvaluationTests
```

Die historische Zwölf-Aufgaben-Textprüfung belegt ausschließlich den damaligen Textprovider. Sie ist kein Nachweis für den neuen vollständigen Ablauf aus Bildverständnis, Maskenauswahl und lokaler Korrektur. Eine übersprungene Echtmodellprüfung ist ebenfalls kein Funktionsnachweis. Die neue Qualität und Laufzeit dürfen erst aus tatsächlich ausgeführten, dokumentierten Prüfungen abgeleitet werden.

Das gemeinsame `AIResourceBudget` erlaubt einen aktiven lokalen Modellaufruf. Diese serielle Grenze schützt Modellressourcen; unabhängige I/O und vorhandene Vorschauworker bleiben begrenzt parallel. Es entsteht kein zusätzlicher Renderpool. Vergleiche und Reglerbewegungen nutzen decodierte Bildbasen erneut; eine CPU-/GPU-Beschleunigung wird daraus nicht behauptet.

`AIBackgroundMonochromeTests` prüft ohne Modellzugriff den vollständigen Provider-/Coordinator-/Renderpfad mit synthetischen Farben und einer deterministischen Auswahl: Hintergrund grau, Motiv unverändert farbig, vorhandene manuelle Maske und nichtneutrale globale Regler erhalten. Die ausdrücklich aktivierte `LocalImageEditingEvaluationTests` prüft zusätzlich die drei Schreibweisen „schwarz weiss“, „schwarzweiß“ und „schwarz weiß“ mit dem echten lokalen Modell und der optionalen privaten Datei `test_picture3.jpg`. Fehlen die Modellbereitschaft oder die Datei, wird diese Echtmodellprüfung ausdrücklich übersprungen. Mit `PICEDIT_IMAGE_EDITING_EVALUATION_OUTPUT=/absoluter/lokaler/Ordner` lassen sich Vorher/Nachher/Auswahl lokal speichern; die Schwarzweißprobe schreibt in den Unterordner `monochrome/`. Fotos und abgeleitete Raster werden nicht eingecheckt.

## Primärreferenzen

- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [Multimodale Bildanalyse](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting)
- [Guided Generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
- [Sprachen und Locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)

## Fehlerkorrektur Schwarzweiß vom 20. Oktober 2026

Die genaue Eingabe `mache den hintergrund schwarz weiss` wurde mit dem echten lokalen Apple-Visionmodell und dem privaten Testfoto `test_picture3.jpg` reproduziert. Zwei Läufe des bisherigen Planungsprompts scheiterten mit `invalidResponse(outOfRange)`. Eine ausschließlich für diese lokale Diagnose vorübergehend erfasste Antwort enthielt einen Hintergrundauftrag mit `exposure=-10` und einer Erklärung zum Abdunkeln statt einer Entsättigung. Die unabhängige Prüfung lehnte diese Belichtung korrekt ab (zulässig sind −5 bis 5 EV). Die temporäre Diagnoseausgabe wurde entfernt; Produktionsanfragen werden weiterhin nicht protokolliert.

Promptversion 3 erklärt Schwarzweiß als Sättigung −100, ergänzt das konkrete regionale Beispiel und unterscheidet Entsättigung ausdrücklich von Belichtung und Weißabgleich. Eine zusätzliche numerische Schemahilfe begrenzt die gemeinsame äußere Wertespanne. Validator, Motivauswahl, Maskenwerkzeug, Persistenz und Undo-Verhalten werden nicht gelockert oder ersetzt. Ein unabhängiges Review einschließlich Schnittstellen und Tests ergab keine Befunde; die kleinen abhängigen Prüfungen bleiben seriell, Bildoperationen nutzen die vorhandene Core-Image-Verarbeitung.

Die Prüfung betrifft das vorhandene JPEG-Testfoto und synthetische Renderpixel. Die im Screenshot abgebildete Datei `IMG_8724.CR3` lag nicht als Quelldatei vor; ihr konkreter Maskenverlauf und ihre RAW-Entwicklung wurden damit nicht geprüft. Die Ergebnisse sind keine allgemeine Erfolgsquote für freie Modellanweisungen oder beliebige Motive.

Der finale Echtmodelllauf war erfolgreich: drei Tests mit insgesamt fünf Aufträgen in 50,153 s, darunter alle drei Schwarzweißschreibweisen sowie die bestehenden Schatten- und Hintergrundlichter-Aufträge. Alle Schwarzweißfälle erzeugten ausschließlich eine invertierte Motivebene mit Sättigung −100, ohne globale Regleränderung. Das lokal exportierte Ergebnis wurde visuell geprüft: grauer Hintergrund, orangefarbene Karotten am Motiv. Der synthetische Integrationstest prüft entsprechende Farbkanäle zusätzlich automatisch und benötigt keine privaten Fotos. Originalbytes des verwendeten Testfotos blieben unverändert. Die Laufzeit ist eine Funktionsmessung mit bereits benutztem Modell und keine Kaltcache- oder Leistungsqualifikation.

Die vollständige normale Suite (`./scripts/test.sh --skip-build --jobs 4` nach dem vollständigen Testbuild) bestand mit **1082 App-Tests in 133 Suites** und **372 Core-Tests in 48 Suites**, ohne Fehler. Optionale Echtmodelltests bleiben dort ausdrücklich deaktiviert und wurden wie oben beschrieben separat ausgeführt. Es wurden keine unabhängigen Fehler gefunden, die ein zusätzliches Issue erfordern.

Wegen der laufzeitwirksamen Änderung wurde nach Ende aller Builds/Tests `.build/`, `.build-app/` und `dist/PicEdit.app` vollständig entfernt und mit `PICEDIT_BUILD_PATH=.build-app PICEDIT_BUILD_JOBS=4 ./scripts/build-app.sh` sauber neu gebaut. Der vollständige Release-Build war erfolgreich (127,60 s); Bundle/Plist/Signatur wurden validiert. Die anschließende Ergänzung dieses Prüfberichts betrifft ausschließlich Dokumentation und erfordert keinen weiteren App-Build.

## Prüfbericht vom 16. Oktober 2026

Dieser historische Bericht beschreibt die damalige Vorschau mit gesonderter Übernahme. Die aktuelle direkte Aktivierung und Undo-Bedienung sind oben dokumentiert.

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


## Prüfung des bildbezogenen Assistenten vom 20. Oktober 2026

Geprüft auf Apple M2 Pro, 16 GiB, macOS 27.0.1 und Swift 6.4 / SDK 27. Die finale vollständige parallele Suite bestand mit **1.080 App-Tests in 132 Suites** und **372 Core-Tests in 48 Suites**. Normale optionale Modell-/Hardwareprüfungen bleiben standardmäßig übersprungen. Die beiden neuen Echtmodellprüfungen wurden ausdrücklich separat ausgeführt:

- „Helle die dunklen Bereiche etwas auf.“ erhöht global die Tiefen, ohne lokale Ebene.
- „Korrigiere den überstrahlten Hintergrund.“ erzeugt über den tatsächlichen Produktionsprovider eine eingefrorene umgekehrte Motivauswahl. Eine vorhandene manuelle Maske bleibt erhalten. Die getrennte Sichtprüfung der lokal gespeicherten Vorschauen und Hintergrundmaske zeigt das ausgesparte Hauptmotiv einschließlich beider Karottenarme.

Der finale Lauf benötigte 7,861 s beziehungsweise 14,519 s für die Auftragsprüfung. Kumulativer Testprozess-Spitzen-RSS: 74.268.672 beziehungsweise 1.069.383.680 Byte; der getrennte Systemmodellservice und eine vollständige GPU-Bilanz fehlen darin. Das sind zwei funktionale Stichproben mit vorhandenen Systemcaches, keine Kaltcache-, RAW-, Genauigkeits- oder Beschleunigungsmessung. Das zweite Szenario benötigt ausdrücklich das ignorierte lokale `test_picture3.jpg`; in CI wird es ohne diese Datei nachvollziehbar übersprungen. Alle sieben Original-Testbilder blieben bytegleich. Private Fotos, Masken und Ausgaben wurden nicht veröffentlicht.

Der erste einphasige Echtmodellversuch ordnete den Hintergrundauftrag fälschlich global zu. Die Trennung von Geltungsbereich und Reglerplan behebt diesen beobachteten Fehler; beide unveränderten Beispielsätze bestehen im finalen Ablauf. Regressionen sichern außerdem Leeränderungen ohne Maskenberechnung, fehlende Himmelsmodelle, strikte Rohantworten, Budgetfreigabe nach tatsächlicher Rückkehr, veraltete Ergebnisse, bestehenden Maskenbestand und atomare Annahme mit Undo/Export. Die native Oberflächenprüfung bestätigt den entfernten Analysebereich und die entfernte Look-Erstellung. Das unabhängige finale Review von Quellcode, Schnittstellen, Tests und Dokumentation ist ohne offene umsetzungsbezogene Befunde abgeschlossen.

Der separate Kompatibilitätsbuild mit **SDK 26.5** besteht. Der wegen relevanter App-Quelländerungen erforderliche **saubere vollständige Release-Build** besteht nach Beendigung aller Tests und Bereinigung von `.build/`, `.build-app/` sowie `dist/PicEdit.app`: `PICEDIT_BUILD_PATH=.build-app PICEDIT_BUILD_JOBS=4 ./scripts/build-app.sh`, Buildzeit 123,43 s, Exit 0; Plist und Bundle-Signatur geprüft. Ein früher Integrationsbuild scheiterte, weil der neue Fehlerfall noch nicht im bereits kompilierten Core-Modul lag. Ein zu früh gestarteter Bundle-Build wurde kontrolliert mit Exit 143 angehalten; nach abgeschlossener erneuter Bereinigung wurde der oben genannte finale saubere Build erfolgreich ausgeführt.

Im ersten vollständigen Testlauf traten die bereits bekannten unabhängigen Wartefehler aus [#75](https://github.com/dr-dimitri/picedit/issues/75#issuecomment-6288033333), [#108](https://github.com/dr-dimitri/picedit/issues/108#issuecomment-6288033403) und [#109](https://github.com/dr-dimitri/picedit/issues/109#issuecomment-6288033408) erneut auf; die vorhandenen Issues wurden um diese Beobachtung ergänzt. Der gezielte Nachlauf bestand mit 35 Tests, der unveränderte vollständige Nachlauf ohne konkurrierenden Build mit den oben genannten 1.452 Tests. Das beweist keine Behebung dieser sporadischen Fehler. Es wurden keine unabhängigen Fehlerkorrekturen in diese Änderung aufgenommen. Unabhängige Vorbereitung und Reviews liefen parallel; echte Modellprüfungen und die finale Testkontrolle liefen ohne konkurrierende Kompilierung, damit Ressourcen und Zeitwächter nicht zusätzlich belastet werden.
