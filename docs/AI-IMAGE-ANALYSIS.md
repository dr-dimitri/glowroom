# Lokale Bildanalyse: interne Grundlage und historische Entscheidung

Der eigenständige Bereich **Bildanalyse** wurde aus der aktuellen Oberfläche entfernt. Die lokale Vision-Anbindung, Quellenprüfung und begrenzte Rastervorbereitung bleiben für **Bildinformationen** erhalten. Die folgenden datierten Nachweise betreffen Bildbeschreibung und Vorbereitung; sie belegen allein keine textgesteuerte Bildkorrektur.

Stand: 16. Oktober 2026. Diese Entscheidung wurde vor der Adapterimplementierung für [AI-05 / Issue #6](https://github.com/dr-dimitri/glowroom/issues/6) getroffen. Der damalige Textprovider ohne Bildzugriff ist mit dem interaktiven Assistenten entfernt. Eine getrennte Bildanalysefähigkeit darf nur nach SDK-, Laufzeit-, Sprach- und Modellprüfung angeboten werden.

## Gebaute und geprüfte Grundlage

| Pfad | Gebautes SDK / Compiler | Niedrigste optionale Laufzeit | Nachweis |
| --- | --- | --- | --- |
| Vorhandene Bibliothek und Bearbeitung | Swift tools 5.9, Deploymentziel macOS 14 | macOS 14 | Mindestziel bleibt unverändert |
| Native Bildattachments | FoundationModels 2.0.68.1.402 / SDK 27, Swift 6.4 | macOS 27 | Gebaute synthetische Attachment-Probe erfolgreich |
| SDK 26.5 / älterer Build | Keine Attachment- oder Vision-Symbole | Bildanalyse nicht verfügbar | Getrenntes Compile-Time-Gate erforderlich |

Testgerät: MacBook Pro Mac14,10 mit Apple M2 Pro (12 CPU-Kerne), 16 GiB RAM, macOS 27.0.1; Apple Command Line Tools mit Swift 6.4 (`swiftlang-6.4.0.34.1`). Kein vollständiges Xcode ausgewählt. Die Package-Mindestplattform wird für die optionale Fähigkeit nicht angehoben.

Das tatsächlich installierte SDK 27 deklariert `Attachment(CGImage)` und `SystemLanguageModel.capabilities.contains(.vision)` erst ab macOS 27. Das SDK 26.5 kennt diese Symbole nicht. Der lokale Nachweis der Modulversionen erlaubt ein präzises SDK-Gate mit `compiler(>=6.4) && canImport(FoundationModels, _version: 2.0)`; bloßes `canImport(FoundationModels)` würde beim neuen Compiler mit altem SDK nicht genügen. Zusätzlich bleiben ein expliziter Fallbackschalter und `@available`/`if #available(macOS 27, *)` erforderlich. Tatsächlich ältere Compiler und Betriebssysteme wurden auf diesem Gerät nicht ausgeführt.

## Echte synthetische Bildprobe

Ein selbst erzeugtes sRGB-Raster mit 512 × 320 Pixeln enthält einen roten Kreis und ein blaues Quadrat auf Weiß. Es enthält weder Textaufschrift noch Dateinamen-/EXIF-Hinweise. An `SystemLanguageModel.default` wurden ausschließlich dieses `CGImage` als Attachment und eine neutrale deutsche Frage nach sichtbaren Formen/Farben übergeben, ohne Tools oder Cloudclient.

Unmittelbar vor der Probe meldete das Modell `available`, Deutschunterstützung und die ausdrückliche Vision-Capability. Die Antwort erkannte Rot/Kreis und Blau/Rechteck. Ein Quadrat ist ebenfalls ein Rechteck; die Auswertung akzeptiert diese zutreffende allgemeinere Bezeichnung, ohne eine perfekte Formbeschreibung zu behaupten. Damit ist tatsächliche visuelle Information belegt. Die erste Wortprüfung verlangte ausschließlich „Quadrat“ und war zu eng; aus diesem Auswertungsfehler wurde kein Modell-No-Go abgeleitet.

Das angehängte Raster hatte SHA-256 `98a798f6bf3684b15785d800f568bfceb016e386c04bc68aa21005a4e593cf17`. Die erfolgreiche lokale Probe dauerte 3,451 s. Das ist eine einzelne funktionale Stichprobe bei zuvor verwendetem Systemmodell, keine Qualitätsbewertung privater Fotos und keine Kaltcache-/Durchsatzmessung. Die Ausführung erfolgte außerhalb der restriktiven Ausführungssandbox, die den lokalen Modellservice sperrt. Es wurden keine persönlichen Bilder und keine Cloud verwendet.

**Entscheidung:** Der native On-Device-Pfad ist auf dieser nachgewiesenen SDK-/Systemkombination für einen eigenen optionalen Adapter geeignet. Fehlende Modellbereitschaft, ungeeignete Hardware, deaktiviertes Apple Intelligence, fehlende Sprache oder Vision-Capability müssen trotzdem bei jedem Einsatz kontrolliert gemeldet werden. Glowroom startet keinen Modelldownload und schaltet niemals automatisch einen Cloudanbieter hinzu.

## Vertrag für die anschließende Umsetzung

Der injizierbare Dienst verwendet die vorhandenen begrenzten Vorschau-/Renderpipelines und das gemeinsame lokale Inferenzbudget. Standard ist eine orientierte Originalvorschau; eine ausdrücklich gewählte bearbeitete Vorschau besitzt zusätzlich die vollständige Bearbeitungsidentität. Das Modell erhält keine Pfade, Asset-/Auftragskennungen oder EXIF-Daten. Appseitig gehören Quellenfingerprint, exakter Eingaberasterdigest, native Eingabemaße, Profil-/Orientierungsvertrag, Vorverarbeitungsversion, Aufgabe, Sprache und Providerkennung zum Ergebnisbezug.

Gleiche Analyseanfragen sollen ihre Arbeit teilen; Abbruch eines Beobachters darf andere nicht abbrechen. Cacheeinträge bleiben nach Anzahl/Bytes begrenzt und enthalten keine dauerhafte Foto-/Promptablage. Nach Bild-/Quellenwechsel dürfen verspätete Antworten nicht veröffentlicht werden. Regleränderungen ändern die Originalanalyse nicht; eine bearbeitete Eingabe muss dagegen auch nach Undo auf identische Zahlen durch ihren Revisionstoken vor alten Ergebnissen geschützt sein.

Analyseergebnisse bleiben begrenzte Vorschläge. Sie sind keine bestätigten Metadaten und geben weder Auskunft über Identität oder Gesundheit von Personen noch über nicht belegte Aufnahmeorte. Metadatenpersistenz folgt separat in [AI-06 / Issue #7](https://github.com/dr-dimitri/glowroom/issues/7).

## Erhaltene interne Implementierung

Der frühere eigenständige Analyse-Inspector samt Start-, Abbruch- und Verwerfen-Aktionen ist entfernt. Interne Originalanalysen dienen weiterhin den Metadatenvorschlägen. Der reine Beschreibungsdienst ändert selbst weiterhin keine Regler oder Metadaten.

`ImageAnalysisRequest` bindet Sprache `de_DE`, Originalquelle, Eingabeart und getrennte Auswahl-/Bearbeitungs-/Lebenszyklusepochen. `ImageAnalysisResult` trennt den modellgelieferten Vorschlag von appseitiger Provenienz. `ImageAnalysisProviderDescriptor.capabilities` nennt ausdrücklich `imageUnderstanding`; die Modellbereitschaft allein genügt ohne diese Bildfähigkeit nicht. Die Systemmodellversion ist über die verwendete API nicht öffentlich verfügbar und bleibt deshalb `nil`, statt eine Version zu erfinden.

`ImageAnalysisPreparer` verwendet die vorhandenen ausgewählten Decoder-/Renderpfade ohne eingebettete Kamera-Vorschau. Die Ausgabe ist hart auf **1024 Pixel lange Kante und 16 MiB tatsächliche Rasterbytes** beschränkt, auch wenn bereits eine größere Entwicklungsbasis im Cache liegt. Dies ist ein konservatives appseitiges Aufnahmebudget für die native Attachment-Schnittstelle, kein behauptetes internes Tensorformat des Systemmodells. Das Framework führt seine eigene Modellvorverarbeitung aus; Glowroom fügt keine zweite Farbkonvertierung hinzu. Die Bildorientierung ist zuvor durch ImageIO angewendet.

Vor und nach Vorbereitung sowie nach Inferenz prüft der Dienst Dateityp, Größe, mtime, ctime, Device und Inode im Hintergrund. Die stärkere optionale `PreviewRequest.sourceRevision` gehört zu Decoder-, Disk- und Renderidentität. Damit kann ein Austausch bei unveränderter Kataloggröße und mtime keine alten Analysepixel aus dem Vorschaucache übernehmen. Die erste Analyse mit dieser stärkeren Revision kann eine vorhandene, nur kataloggebundene Basis nicht wiederverwenden; sie verwendet trotzdem dieselben begrenzten Worker und anschließend ihren eigenen gültigen Cacheeintrag. Die bisherigen Cache-Schlüssel ohne Revision bleiben kompatibel.

Der SHA-256-Digest umfasst die tatsächlich als `CGImage` übergebenen Pixelzeilen sowie Maße, Bittiefe, Layout, Decode-Interpretation, Rendering-Intent, Orientierung und ICC-/Profilbezug. Unbenutzte X-Kanäle, gepackte Zeilenendbits und Zeilenpadding werden beim Hashen ausgeschlossen beziehungsweise kanonisiert, ohne das angehängte Raster zu verändern. Beschrieben wird das native Attachment vor der privaten Frameworkkonvertierung. Rohes EXIF, Dateipfade und Katalogidentitäten gehen nicht in den Prompt. Die Provenienz enthält Quellenbezug, Rasterdigest, native Maße/Bytes, Profil, Zeitpunkt und Versionen von Vorverarbeitung, Aufgabe und Schema.

`ImageAnalysisService` hält höchstens einen aktiven und einen ersetzbaren wartenden Kontext. Gleiche Anfragen teilen Arbeit und binden das Ergebnis an die jeweilige Beobachter-ID zurück. Ein einzelner Abbruch lässt andere Beobachter bestehen. Nicht kooperierende Modellarbeit behält ihren Platz und die gemeinsame `AIResourceBudget`-Lease bis zur tatsächlichen Rückkehr. Der In-Memory-Ergebniscache enthält höchstens acht Einträge und 256 KiB berechnete Eintragskosten; er hält keine Bildraster. Er ist weder eine dauerhafte Modellkonversation noch ein Metadatenspeicher.

Der native Adapter erstellt pro Auftrag eine frische Sitzung am wiederverwendeten Systemmodell, ohne Tools oder Cloud. Guided Generation liefert Schema 1 mit höchstens zwölf Attributen aus Motiv, Farbe, Komposition, Licht und Stil. Die gemeinsame unabhängige JSON-Prüfung lehnt unbekannte/doppelte Felder, ungültige Versionen, Kategorien und Typen vollständig ab. Grenzen: 16 KiB rohe Antwort, sechs Verschachtelungsebenen, 96 JSON-Werte, 2048 UTF-8-Bytes Beschreibung und 256 UTF-8-Bytes pro Attribut. Ungültige Antworten werden nicht gekürzt oder teilweise angezeigt. Modellfehler werden ohne rohe Antwort oder Dateipfad kategorisiert.

## Historische Prüfung der Bildanalyse-Integration vom 16. Oktober 2026

Die Standardtests verwenden ausschließlich Fakes und isolierte synthetische Dateien. Gesteuerte Fortsetzungen prüfen geteilte Aufträge, einzelne Abbrüche, zwanzig schnelle Kontexte, nicht kooperierende Arbeit, gemeinsame Lease, Original-/Bearbeitungsidentität, Quellenwechsel, begrenzten LRU-Cache, Schemafehler und Verfügbarkeitsgründe. Controllerprüfungen erfassen A → B → A, Undo auf gleiche Werte, kurze Restore-/Backup-/Schließen-Phasen und verspätete Antworten. Sie prüfen außerdem, dass Analyse keine Regler, Undo-Schritte oder Metadaten speichert.

Beim vollständigen Integrationslauf wurde eine zu strenge Testannahme korrigiert: Der verlustfreie PNG-Cache kann ein ARGB-Thumbnail als RGBA-Raster mit anderem Rendering-Intent wieder öffnen. Dessen native Interpretation und damit der exakte Digest dürfen sich unterscheiden. Der Regressionstest prüft stattdessen identische sichtbare Pixel und Profil sowie weiterhin neue Pixel nach Dateiaustausch. Direkte Tests sichern ignorierte X-Bytes für 8-/16-Bit-Komponenten mit unterschiedlichen Byteordnungen und gepackte 1-Bit-Zeilenenden ab. Der Befund betraf den neuen Analyse-/Hashvertrag und wurde in dieser Umsetzung geklärt.

```sh
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-image-analysis-tests ./scripts/test.sh --jobs 2 --filter ImageAnalysis
```

Die funktionale Bildprobe und die späteren Integrationsergebnisse sind voneinander getrennt: ein unterstütztes SDK allein belegt weder aktuelle Modellbereitschaft noch die Qualität beliebiger Fotobeschreibungen. Nicht verfügbar auf diesem Gerät sind echte Tests auf macOS 14/26 und Intel-Hardware. Ältere SDK-/Fallback-Builds prüfen die kompilierte Trennung; sie ersetzen keinen Betriebssystemtest. Reale Personen, private Fotobibliotheken und große Kamera-RAWs sind keine Testfixtures.

Die integrierte native Smokeprüfung verwendet zwei getrennt erzeugte 512×320-sRGB-Bilder und neutrale Prompts: Rot/Kreis plus Blau/Quadrat sowie Grün/Dreieck plus Gelb/Kreis. Beide Antworten enthielten die erwarteten visuellen Informationen. Das Vorbereitungsraster und die Provenienz werden unabhängig gegengeprüft; zwei anschließende Cacheaufrufe verursachten keine weitere Inferenz. Die beiden echten Aufrufe dauerten 5,936 s und 4,783 s, die Cacheaufrufe 0,0005 s und 0,0004 s. High-Water-RSS des isolierten Testprozesses: 45 694 976 beziehungsweise 46 202 880 Bytes. Speicher des Systemmodellservice und GPU-Speicher sind darin nicht enthalten. Dies ist keine Messung einer kalten Fotobibliothek oder ein zugesagter Leistungswert.

```sh
GLOWROOM_RUN_IMAGE_ANALYSIS_EVALUATION=1 GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-image-analysis-tests \
  ./scripts/test.sh --jobs 2 --filter LocalImageAnalysisEvaluationTests
GLOWROOM_RUN_IMAGE_ANALYSIS_RASTER_TESTS=1 GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-image-analysis-tests \
  ./scripts/test.sh --jobs 2 --filter actualLargerDecodedBaseIsClampedInsideExistingRenderWorker
```

Diese opt-in-Prüfungen benötigen einen erreichbaren nativen Modell-/Core-Image-Dienst. Eine restriktive Entwicklungssandbox kann dessen Verbindung blockieren; das ist von einem Produktfehler getrennt zu prüfen. Beim Modelltest muss im Log eine tatsächliche Ausführung stehen: ein wegen fehlender Bereitschaft übersprungener Test ist kein Bildfähigkeitsnachweis.

Der abschließende vollständige Standardlauf bestand mit 228 App- und 61 Core-Tests in 34 Suiten; acht ausdrücklich optionale Modell-/Raster-/Benchmark-/RAW-Prüfungen waren darin übersprungen. Die neue native Bildprobe und der echte Core-Image-Test wurden separat erfolgreich ausgeführt. Letzterer begrenzte eine gelieferte 2400×1600-Basis tatsächlich auf 1024 Pixel lange Kante, prüfte die Bytegrenze und unterschied Original von ausdrücklich bearbeiteter Eingabe. SDK 26.5 und der vollständige Fallbackbuild mit `GLOWROOM_DISABLE_FOUNDATION_MODELS` kompilierten auch nach der Rasterhash-Korrektur erfolgreich. Eigenes Backendreview, unabhängiges UI-/Backendreview und abschließendes Integrationsreview fanden nach Korrektur der beschriebenen Cache-/Hashbefunde keine offenen umsetzungsbezogenen Fehler.

## Primärquellen

- [Apple: Analyzing images with multimodal prompting](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting)
- [Apple: Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels)
- [Apple: Generating content and performing tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

Die installierten Swiftinterfaces von SDK 27 und SDK 26.5 sowie die gebaute und ausgeführte synthetische Probe sind die konkrete Grundlage dieser Entscheidung; eine Dokumentationsseite allein ersetzt keinen Laufzeitnachweis.
