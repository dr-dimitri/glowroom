# Drei lokale Lookvorschläge

[AI-04 / Issue #5](https://github.com/dr-dimitri/picedit/issues/5) ergänzt den [Entwicklungsassistenten](LOCAL-AI-ASSISTANT.md) um drei vergleichbare Textrezepte. Die Voraussetzungen AI-01, AI-02 und AI-03 sind gemergt. Die Varianten beruhen auf einem gemeinsamen übernommenen Ausgangsstand; der reine Textprovider sieht weiterhin keine Bildpixel und bewertet kein Motiv.

## Bedienung

**Drei Looks erstellen** fordert gemeinsam die Stile „Natürlich“, „Kontrastreich“ und „Entsättigt“ an. Ein zusätzlicher Wunsch ist optional und auf 2048 UTF-8-Bytes begrenzt. Die drei gleichartigen Karten bleiben in dieser Reihenfolge. Ihre Auswahl ändert ausschließlich die unverbindliche Hauptvorschau. Alle Reglerangaben und Deltas werden aus Ausgang und validiertem Ziel berechnet; Varianten bauen nicht aufeinander auf.

Der Vergleich mit der aktuellen Bearbeitung sowie **Importiertes Original anzeigen** und **Aktuelle Quelle ohne Regler** bleiben erreichbar. Die beiden Quellenvergleiche zeigen das importierte Original beziehungsweise die aktive Bildbasis ohne zusätzliche Regler. Ein Auswahlwechsel ruft das Modell nicht erneut auf und speichert nichts. **Übernehmen** konsumiert die ganze Vorschlagsgruppe und übernimmt die ausgewählte Variante als einen Undo-Schritt. **Verwerfen**, Bild-/Reglerwechsel, Undo/Redo, Wartung/Restore und Schließen entwerten alle drei Varianten und geben die gruppeneigenen Bildreferenzen frei. Raster, Filmstreifen und JPEG-Export verwenden bis zur Übernahme weiterhin die übernommenen Werte.

## Gemeinsamer Vertrag und Grenzen

Ein Lookauftrag verwendet denselben `AIRequestCoordinator` und dasselbe Inferenzbudget wie ein Einzelvorschlag. Der Modus ist Teil der Auftragsidentität: Einzel- und Gruppenantworten werden auch bei identischem Text nicht verwechselt. Ein einziger gruppierter Provideraufruf liefert genau drei stabile IDs: `natural`, `contrasty`, `desaturated`. Die App ergänzt den gemeinsamen Snapshot; das Modell bestimmt keine Asset- oder Revisionskennung.

Die gesamte Antwort muss vor Veröffentlichung bestehen: richtige Gruppenversion, genaue Anzahl und ID-Menge, begrenzte Namen/Erklärungen und je ein strenger Reglerpatch. Jedes Ziel wird unabhängig aus demselben Ausgang gebildet. Ein wirkungsloser Patch, gleiche Zielstände, doppelte oder fehlende IDs oder ein ungültiger Wert verwerfen die ganze Gruppe. PicEdit ergänzt keine erfundenen Ersatzrezepte. Eine erklärbare Fehlermeldung erlaubt einen neuen bewussten Versuch.

Es gibt keinen zusätzlichen Inferenzcache mit Prompthistorie. Die aktuelle Gruppe bleibt flüchtig; Lookwechsel brauchen ohnehin keinen neuen Modellaufruf. Der vorhandene Rendercache verwendet renderrelevante Quelle, Zielwerte und tatsächliche Rastergrößen, unabhängig von Prompt, Anzeigename und Gruppen-ID. Gleiche Renderanfragen können daher trotz anderer Aufträge ein Bitmap wiederverwenden.

## Vorschauen, Parallelität und Speicher

Die aktive Hauptvorschau verwendet höchstens 2400 Pixel lange Kante. Drei kleine Karten werden aus derselben entwickelten Basis mit höchstens 512 Pixeln langer Kante erzeugt. Ein kleiner Decoderrequest allein reicht dafür nicht: die vorhandene Pipeline darf eine größere bereits decodierte Basis zurückgeben. Das tatsächliche Kartenraster wird deshalb innerhalb der bestehenden Renderplätze begrenzt, auch für neutrale Einstellungen.

Die Karten teilen `ImagePreviewPipeline` und `AdjustedPreviewPipeline` mit dem Hauptbild. Es gibt keine RAW-Decodierung pro Variante, keinen zusätzlichen Renderpool und keinen Core-Image-Kontext pro Karte. Die aktive Variante erhält `.selected`, Karten nachrangige Priorität. Die bisherige Hardwaregrenze von höchstens einer ausgewählten und einer Hintergrundarbeit bleibt erhalten; auf kleineren Macs ein Renderplatz insgesamt. Ein nicht abbrechbarer synchroner Render behält seinen Platz bis zur Rückkehr.

Der gruppeneigene Kartenstore hält höchstens drei Bitmaps und insgesamt höchstens **8 MiB**, anhand der tatsächlichen `PreviewBitmap.byteCost`. Kartenansichten verwenden dessen Bildreferenzen ohne zusätzlichen eigenen Bitmapcache. Memory Pressure, Verwerfen und Kontextwechsel entfernen entbehrliche Kartenreferenzen. Die Gruppe hält keine drei großen Variantenbilder; die vorhandene Hauptansicht bleibt Besitzerin der einzigen aktiven großen Vorschau. Der globale Rendercache bleibt bei **32 MiB / 32 Einträgen**. Diese Grenzen beschreiben die ausdrücklich gehaltenen Bitmaps; interne Framework-/GPU-Speicher und der gesamte Prozess-RSS sind davon verschieden.

## Prüfung

Normale Tests verwenden Fakes und synthetische Raster. Sie prüfen vollständige Gruppenvalidierung, einen Aufruf für drei Looks, Abbruchignorierung, gemeinsame Arbeit, Modustrennung, Quellen-/Revisionswechsel, Auswahl ohne Writes, einmalige Übernahme und Byte-/Anzahlgrenzen. Der vorhandene Export- und Farb-/Transparenzvertrag gilt auch für Lookvorschläge.

Ein ausdrücklich aktivierter Echtmodelltest prüft gültige Gruppen aus neutralem und verändertem Ausgang sowie die ehrliche Ablehnung nicht unterstützter Aufgaben. Er läuft getrennt von der Render-Messung:

```sh
PICEDIT_RUN_LOCAL_AI_LOOK_EVALUATION=1 \
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-look-model ./scripts/test.sh --jobs 4 \
  --filter LocalAILookEvaluation
```

Eine separate Messung wird ausdrücklich aktiviert und seriell ausgeführt, ohne konkurrierende Modell-/GPU-Messung:

```sh
PICEDIT_RUN_LOOK_PREVIEW_BENCHMARK=1 \
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-look-benchmark ./scripts/test.sh --jobs 4 \
  --filter synthetic2400PixelFirstAndWarmCacheBenchmark
```

Die Arbeitslast umfasst eine synthetische 2400-Pixel-Basis, drei kleine Karten und mindestens zehn aktive Wechsel. Erste und warme Rendercaches, Decoder-/Renderaufrufe, Zeit bis zur aktiven Vorschau und Prozess-Spitzen-RSS werden getrennt ausgewiesen. Synthetische Daten belegen Cache-/Schedulingverhalten; große Kamera-RAWs werden nur mit ausdrücklich verfügbaren Testdateien gemessen.

## Prüfbericht vom 16. Oktober 2026

Umgebung: MacBook Pro Mac14,10 mit M2 Pro (12 CPU-Kerne), 16 GiB RAM, macOS 27.0.1, Apple Command Line Tools / Swift 6.4 und SDK 27. Die allgemeinen Mindestanforderungen bleiben macOS 14 und Swift tools 5.9; die lokalen Modellfunktionen sind optional ab Swift 6.2 / geeignetem FoundationModels-SDK und macOS 26.

- Vollständige normale Suite: 259 Tests in 29 Suites erfasst, Lauf erfolgreich (203 App-/56 Core-Tests); sechs ausdrücklich optionale Modell-, Benchmark- und RAW-Prüfungen standardmäßig übersprungen.
- Gezielte UI-/Controllerintegration: 55 Tests erfolgreich, einschließlich zwölf Lookauswahlen ohne weitere Inferenz/Speicherung, einer Übernahme mit Undo/Export sowie 20 schnellen Gruppenaufträgen und verspäteten Antworten nach Kontextwechsel.
- Strenger Gruppenvertrag: sechs neue Tests erfolgreich; Provider-/Coordinatorprüfung einschließlich bestehender Validierung und gemischter Modi erfolgreich.
- Reale Raster-/Schedulerprüfung außerhalb der Ausführungssandbox erfolgreich. P3/sRGB, Alpha, weiche transparente Kante, asymmetrische Geometrie, 16-Bit-SDR und Graustufen geprüft. Der Resizer folgt dem bisherigen Vorschauvertrag; dies ist kein Nachweis unveränderter HDR-Sensordaten.
- Echtmodell-Gruppenprüfung: zwei gültige Aufträge (neutraler und veränderter Ausgang) mit jeweils genau drei verschiedenen wirksamen Zielen sowie korrekte Ablehnung von Weißabgleich/Bildanalyse erfolgreich. Die bestehende Zwölf-Aufgaben-Einzelprüfung bestand erneut.
- Vollständige Debugbuilds mit stabilem SDK 26.5 und erzwungenem SDK-unabhängigem Fallback erfolgreich; macOS 14 bleibt Deploymentziel, Fallback ohne FoundationModels-Verknüpfung.
- Sauberer vollständiger Release-App-Build mit `PICEDIT_BUILD_JOBS=4 ./scripts/build-app.sh` erfolgreich nach Entfernen der inaktiven `.build/`, `.build-app/` und `dist/PicEdit.app`. Plist, Bundle und lokale Signatur wurden validiert.
- Finale Release-Oberfläche mit getrenntem synthetischem Katalog geprüft: drei lokale Karten ohne Zusatztext, Auswahl „Entsättigt“, sichtbares Delta Sättigung 0 → −35, währenddessen unveränderte Editorwerte und Filmstreifen. Erst „Übernehmen“ setzte −35 und entfernte die Gruppe; ein Undo stellte 0 wieder her und ließ keinen weiteren Undo-Schritt zurück. Karten, Textkennzeichnung, auswählbare Details und 300-Punkt-Inspector waren sichtbar bedienbar.

Die vier gruppierten Modellprüfungen dauerten zusammen 79,043 s, davon die beiden gültigen Gruppen 24,357 s bzw. 6,650 s. Die nachfolgende Einzelprüfung dauerte 28,342 s. Dies sind funktionale Stichproben mit frischen Sitzungen bei bereits zuvor verwendetem Systemmodell, keine kontrollierte Kalt-/Warm- oder Beschleunigungsmessung. Es wurde kein Prompt-/Antwortarchiv angelegt. Erste Gruppenproben klassifizierten nicht unterstützte Aufgaben ungenau, lieferten aber wegen der strengen Validierung keine übernehmbare Gruppe; explizite Capability-Fragen im Guided-Generation-Schema behoben die geprüften Fälle.

Der separate Renderbenchmark lief anschließend allein in einem frischen Testprozess, ohne andere Agenten-Builds oder Modellaufrufe. Basis: 2400 × 1600 Pixel, drei Karten mit 512 × 341 Pixeln, zehn aktive Variantenwechsel; echte Core-Image-Filter und nachrangiger Kontext für Karten. Der injizierte Decoder liefert ein vorher erzeugtes Raster und zählt Wiederverwendung, keine tatsächliche ImageIO-/RAW-Decodierzeit.

| Messung | Erste Anwendungs-/Rendercaches | Warme Wiederholung |
| --- | ---: | ---: |
| Aktive Vorschau | 77,94 ms | 0,023 ms |
| Drei Karten bereit ab Start | 110,04 ms | 12,73 ms |
| Gesamte Folge einschließlich zehn Wechseln | 160,51 ms | 64,49 ms |
| Zusätzliche Decoderaufrufe | 1 | 0 |
| Filterrenderings, davon Hintergrund | 13, davon 3 | 12, davon 3 |
| UI-Kartenbytes / Anzahl | 2.095.104 / 3 | 2.095.104 / 3 |
| Kumulativer Prozess-Spitzen-RSS | 133.120.000 Bytes | 133.152.768 Bytes |

Drei große RGBA-Vorschauen mit den hier verwendeten Maßen von 2400 × 1600 Pixeln passen gemeinsam nicht in den beibehaltenen 32-MiB-Rendercache. Die LRU-Verdrängung erklärt erneutes Rendern beim Wechsel und erneut angeforderte Karten im warmen Lauf; sie vergrößert das Speicherbudget nicht. Ein zusätzlicher Test weist Wiederverwendung derselben tatsächlichen Renderanfrage über verschiedene angeforderte Decodergrößen nach. Betriebssystem-/GPU-Caches wurden nicht geleert; „erste Caches“ meint die neuen Anwendungs-/Pipelineinstanzen. RSS ist der Prozess-Höchststand einschließlich Initialisierung, keine isolierte Kartenallokation oder vollständige GPU-Speichermessung. Es gibt keine Vorhermessung und keine daraus abgeleitete Beschleunigungsbehauptung.

Das finale Review fand eine vermeidbare doppelte Cacheidentität: identische tatsächliche Raster konnten durch unterschiedliche angeforderte Decodergrößen getrennt gerendert werden. Der Schlüssel verwendet jetzt Quellenfingerprint/Entwicklungsart, tatsächliche Basis-/Ausgabemaße und Zielwerte. Eine Regression beweist dieselbe Bildreferenz bei 512-/2400-Pixel-Anfrage mit identischer Basis und Ausgabe. Die Benchmarkinstrumentierung reicht außerdem die tatsächliche Renderpriorität bis zum Core-Image-Kontext durch. Beide Korrekturen wurden erneut geprüft.

Die Ausführungssandbox blockiert reale Core-Image-/Modellservices; nach diesem bekannten Umgebungsfehler wurden dieselben Bildprüfungen außerhalb der Sandbox erfolgreich ausgeführt. Alte tatsächliche Compiler-/Betriebssysteme, eine vollständige akustische VoiceOver-Prüfung, physisch getrenntes Netzwerk und repräsentative Kamera-RAWs sind hier nicht geprüft. Die ausdrücklichen UI-/Cachebudgets sind von internen Framework-/GPU-Allokationen und Prozess-RSS zu unterscheiden.

Provider/Core/Coordinator, Oberfläche sowie Imaging/Kartenspeicher wurden anschließend gegenseitig und durch den integrierenden Agenten reviewt; keine umsetzungsbezogenen Befunde blieben offen. Ein vermuteter CMYK-Vorschaufehler wurde am tatsächlichen ImageIO-Thumbnailpfad mit einer synthetischen CMYK-JPEG-Datei geprüft: der Decoder liefert dort RGB, der Verdacht bestätigte sich nicht. Der unabhängige ältere Dokumentationsfehler [#19](https://github.com/dr-dimitri/picedit/issues/19) bleibt separat erfasst.
