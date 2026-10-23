# Gemeinsame KI-Grundlagen

Der frühere interaktive KI-Assistent, Textbearbeitungsprovider, Lookvorschläge und der optionale Anthropic-Cloudprovider sind entfernt. Die verbliebenen Grundlagen unterstützen unabhängig davon [lokale Bildanalyse und Metadatenvorschläge](AI-IMAGE-ANALYSIS.md), [semantische Suche](SEMANTIC-SEARCH.md), [automatische Masken](AUTOMATIC-MASKS.md) und das weiterhin gesperrte [Bildgenerierungsbackend](AI-IMAGE-BACKEND-DECISION.md). Bereits gespeicherte Einstellungen, Masken und Artefakte behalten ihre vorhandenen Speicher- und Renderverträge.

Der eigenständige Arbeitsbereich [AI Entwickeln](AI-DEVELOPMENT.md) ergänzt jetzt eine native lokale Qwen-Vorschlagsroute. Sie verwendet dieselben Quellen-/Bearbeitungstokens und das gemeinsame Ressourcenbudget; erst die ausdrückliche Übernahme schreibt reguläre Bildkorrekturen. Die historische Qualitätsentscheidung zur unbeaufsichtigten Automatik bleibt bestehen.

## Datenfluss und Quellenbezug

`GlowroomCore/AI` enthält gemeinsame `Sendable`-Werttypen, Quellenidentität, Bearbeitungssnapshots, Parameterzuordnung sowie die getrennten Analyse-, Such- und Bildgenerierungsverträge. Ein Modell erhält keine Schreibrechte auf Katalog, Bearbeitungsdatenbank, Originaldateien oder Shell. Bestätigte Metadaten und Bearbeitungen werden ausschließlich über die vorhandenen App- und Speicherpfade übernommen.

`AIEditingSnapshot` erfasst Foto, Quelle, Einstellungen, unabhängige Bearbeitungs-/Auswahltokens und gegebenenfalls die persistierte Bearbeitungsrevision. Die Originalidentität enthält standardisierten Dateipfad, Änderungszeit und Dateigröße aus dem Katalog. Das ist eine Änderungskennung, kein kryptografischer Beweis identischer Pixel. Ein Artefaktfingerprint ergänzt Store-ID, Artefakt-ID, Manifest-/Rasterhash und Geometrie.

`AIEditingToken` unterscheidet auch gleiche Einstellungen nach Undo oder Auswahlwechsel A → B → A. Sitzungskennungen verhindern Kollisionen zwischen Modellinstanzen; beim Ausschöpfen eines Generationszählers muss die zugehörige Epoche wechseln. Gesperrte oder geschlossene Bibliothek und Bearbeitung erlauben keine neue Übernahme.

Die [Bildanalysevorbereitung](AI-IMAGE-ANALYSIS.md) ergänzt eine native Quellenrevision und den SHA-256-Digest des tatsächlich übergebenen Rasters einschließlich Profil und Layout. Dateiprüfung, Rastervorbereitung und Hashberechnung laufen im Hintergrund. Originalanalysen können unabhängig von der Bearbeitungsrevision arbeiten; daraus folgt keine Berechtigung zum Ändern von Reglern. Die Analyse liefert ausschließlich begrenzte Beschreibungen und visuelle Attribute. Erst die ausdrückliche Übernahme im Bereich **Bildinformationen** bestätigt Metadaten.

Das Speichern generierter Pixel bleibt eine eigene typisierte Operation mit nativer Quellenprüfung und atomarem Snapshot-CAS. Öffnen und Wiederherstellen gespeicherter [Artefakte](ARTIFACT-STORAGE.md) benötigen weder Modell noch Netzwerk.

## Ressourcen und Abbruch

`AIResourceBudget` begrenzt die tatsächlich laufende lokale Modellarbeit gemeinsam auf einen aktiven Aufruf. Modellkompilierung, automatische Auswahlen, Analyse und semantische Inferenz verwenden diese Zulassung, soweit ihr jeweiliger Dienst sie benötigt. Die bewusste serielle Modellgrenze schützt gemeinsamen Speicher und Frameworkressourcen. Unabhängige Vorbereitung, Datei-I/O und bestehende Decoder-/Cachearbeit können weiterhin begrenzt parallel laufen. Interaktive Arbeit hat Vorrang vor Hintergrundarbeit.

Ein abgebrochener Beobachter darf Ressourcen eines noch laufenden, nicht unterbrechbaren nativen Aufrufs nicht vorzeitig freigeben. Dessen Antwort wird nicht mehr veröffentlicht; der Platz bleibt bis zur tatsächlichen Rückkehr belegt. Die getrennten Dienste begrenzen ihre wartenden Anfragen und prüfen vor Veröffentlichung die jeweilige Quellen- und Kontextidentität. Identische geteilte Arbeit erhält getrennte Beobachterbezüge. Fehler werden ohne Prompt, Originalpfad oder rohe Modellantwort kategorisiert.

Vorschauen und Bilddecodierung bleiben Aufgabe von `ImagePreviewPipeline` und `AdjustedPreviewPipeline` mit ihren bestehenden Prioritäten und Grenzen. Es entsteht kein zusätzlicher Renderpool oder Core-Image-Kontext pro Antwort. Das KI-Budget ist eine Zulassungsgrenze; es begrenzt interne Frameworkthreads, GPU-Texturen oder den gesamten Prozessspeicher nicht hart.

## Gesperrte Bildgenerierung

Das [Bildbackend-Gate aus Issue #12](AI-IMAGE-BACKEND-DECISION.md) führt getrennte Statuswerte für Text-to-Image, Image-to-Image, Inpainting, Hintergrundbearbeitung und Outpainting. Der Standard ist ein getestetes `UnavailableImageGenerationBackend` mit `qualityGateFailed`; es gibt keine allgemeine produktive Bildgenerierung. Der getrennte ausdrücklich importierte [LaMa-Reparaturpfad](REPAIR-TOOLS.md) ist davon unabhängig.

Ein `ImageGenerationJob` bindet den vollständigen Snapshot, unveränderliche native Pixel, Maskenrevision, Pipelineversion, Parameter und Seed. `ImageGenerationService` prüft die Verfügbarkeit vor der Backendarbeit sowie erneut nach dem Warten auf das Budget. Aktuelle Tokens prüft er vor und nach der tatsächlichen Backendarbeit. Er begrenzt jedes Rohresultat durch den lokalen `MaskCompositor`, bevor ein Ergebnis zurückgegeben wird. Der Dienst speichert oder übernimmt keine Artefakte.

Bildjobs teilen die einzelne lokale Inferenzlease. Die deklarierte Summe aus residentem Modell und Arbeitsdaten darf standardmäßig 6 GiB nicht überschreiten; tatsächliche RSS-/Footprint-Messungen im separaten Harness ergänzen diese Vorprüfung. Der aktuelle und höchstens ein wartender Bildjob bleiben begrenzt. Abbruch und kontinuierliche Deadlines verhindern Veröffentlichung, geben die Lease aber erst nach tatsächlicher Backend-/Compositor-Rückkehr frei. Bild-/Maskenvorverarbeitung verwendet denselben expliziten Ausschnitt und dieselben Pixelzentren, prüft das Seitenverhältnis und transportiert die inverse Geometrie.

## Prüfung

Normale Tests verwenden deterministische Fakes und isolierte temporäre Kataloge, Stores und synthetische Raster. Gesteuerte Fortsetzungen prüfen Queuegrenzen, Abbruchignorierung, Quellenwechsel, schnelle Änderungen und ungültige Antworten. Es gibt keine realen Modellaufrufe, Downloads, Netzwerkanfragen oder API-Kosten im Standardtestpfad. Echte Modellprüfungen sind ausdrücklich aktivierbar und unter dem jeweiligen Funktionsvertrag dokumentiert.

Die Produktionsdeadline für Bildgenerierung beginnt mit dem Eintritt in `generate`. Der Test für den abschließenden Beobachter-Lookup wartet deshalb erst nach dessen Gate und nach dem nachgewiesenen Ende der nativen Arbeit samt Freigabe der Inferenzlease weitere 1,1 Sekunden; die Produktionsfrist im Test bleibt bei einer Sekunde. Beide Testfälle starten `generate` ohne beziehungsweise mit 250 Millisekunden Verzögerung. Swift-Testing-Suites bleiben parallel ausführbar; ihre Serialisierung ersetzt diese Synchronisierung nicht.

Gezielte Prüfungen und ein anschließender vollständiger Lauf verwenden denselben Test-Buildpfad nacheinander. Unabhängige Test-/Buildläufe benötigen getrennte Verzeichnisse und ein gemeinsames CPU-/Speicherbudget:

```sh
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-image-generation-tests ./scripts/test.sh --jobs 4 --filter ImageGenerationServiceTests/expirationDuringFinalCurrentTokenLookupCannotPublishAfterTimerWasCancelled
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-image-generation-tests ./scripts/test.sh --jobs 4
```

Der erforderliche abschließende saubere App-Build und das Diffreview folgen `AGENTS.md` und dem Abschnitt „Entwickeln und prüfen“ im README.
