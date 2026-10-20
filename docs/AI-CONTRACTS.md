# KI-Verträge und sichere Vorschläge

Die Grundlage aus [Issue #2](https://github.com/dr-dimitri/picedit/issues/2) trennt Modellantworten, vorläufige Vorschläge und angenommene Bearbeitungen. Der darauf aufbauende [lokale Entwicklungsassistent](LOCAL-AI-ASSISTANT.md) verwendet diese Verträge und den vorhandenen Speicher-/Renderpfad. Die Grundlage selbst benötigt weder Zugangsdaten noch neue Pakete oder Apple Intelligence; das Deploymentziel bleibt macOS 14 und das Paket bei Swift tools 5.9. Die automatisierten Tests verwenden wie bisher Swift Testing mit Swift 6 oder neuer.

## Datenfluss und Verantwortlichkeiten

`PicEditCore/AI` enthält ausschließlich providerunabhängige `Sendable`-Werttypen, Reglerzuordnung, Fehler und Eingabevalidierung. Der App-Bereich `PicEdit/AI` übernimmt Auftragssteuerung und die Verbindung zu den bestehenden Bibliotheks-/Bearbeitungsmodellen. Ein Provider besitzt keine Schreibrechte auf den Katalog, die Bearbeitungsdatenbank, Originaldateien oder die Shell. Sein Ergebnis ist eine begrenzte Datenantwort.

1. Die App erfasst das ausgewählte Foto, seinen Quellenfingerabdruck, die übernommenen Regler und getrennte Bearbeitungs-/Auswahlgenerationen als unveränderlichen Snapshot.
2. Ein `AIEditingRequest` verbindet diesen Snapshot mit einer appseitigen Auftrags-ID und der Benutzeranweisung. Modelltexte erzeugen oder ersetzen diese Identität nicht.
3. Der injizierte `AIEditingProvider` meldet Verfügbarkeit und getrennte Fähigkeiten. Der lokale Bildprovider verbindet Textbearbeitung mit Bildverständnis; Textfallback und optionaler Cloudprovider bleiben global und ohne Bildpayload. Bildgenerierung gehört nicht zu diesem Bearbeitungsauftrag.
4. `EditProposalValidator` prüft die Antwort vollständig. Ein gültiger Patch ergibt einen vorläufigen Zielstand, ein leerer oder wirkungsloser reiner Textpatch das Ergebnis `noChange(explanation:)`. Dieses Ergebnis bewahrt die bereits validierte Erklärung, damit fehlende Fähigkeiten oder bereits passende Einstellungen verständlich bleiben; es enthält keinen übernehmbaren Zielstand. Ein gültiger Einzelvorschlag wird nach der erneuten App-Prüfung direkt aktiviert. Der Bildprovider liefert zusätzlich ausschließlich appseitig erzeugte lokale Ebenen über `AIResolvedEditingProvider`; sie werden gemeinsam mit dem globalen Patch validiert und angenommen. Es gibt keinen zusätzlichen Übernehmen-Button. Ein `noChange`-Ergebnis ändert weder Regler, Undo noch Datenbank.
5. Vor der Veröffentlichung und unmittelbar vor der Aktivierung wird der vollständige Snapshot erneut gegen die App geprüft. Jede erfolgreiche Aktivierung verwendet den normalen Bearbeitungspfad genau einmal und bildet einen Undo-Schritt. Die bereits angenommene Speicherung gehört dem vorhandenen `EditingModel` und ist unabhängig vom Schließen der Ergebnisanzeige oder einem Abbruch der KI-Anfrage. Nur das Speichern der selbst aktivierten Werte darf deren persistierte Version fortschreiben, ohne die Ergebnisanzeige zu entwerten. Externe Änderungen, Undo/Redo und Funktionswechsel bleiben durch Quelle, Regler, Storeepoche und vollständige Bearbeitungs-/Auswahltokens abgesichert.

## Antwortschema 1

Ein Patch enthält **absolute Zielwerte**, keine relativen Werte oder ausführbare Formeln. Nicht genannte Regler bleiben erhalten. Bei vorherigen Tiefen von 10 setzt das folgende Beispiel die Tiefen auf 30; das angezeigte Delta wäre +20.

```json
{
  "schemaVersion": 1,
  "changes": [
    { "parameter": "shadows", "value": 30 },
    { "parameter": "saturation", "value": -12 }
  ],
  "explanation": "Schatten aufhellen und Farben zurücknehmen."
}
```

`explanation` ist optional. Bekannte Parameter und Grenzen:

| Parameter | Zulässiger Bereich |
| --- | --- |
| `exposure` | −5 bis +5 EV |
| `contrast`, `highlights`, `shadows`, `whites`, `blacks` | −100 bis +100 |
| `texture`, `clarity`, `dehaze`, `vibrance`, `saturation` | −100 bis +100 |
| `luminanceNoiseReduction`, `colorNoiseReduction` | 0 bis 100 |
| `naturalBalanceAmount`, `naturalBalanceColorAmount` | 0 bis 100 |
| `autoToneAmount` (bisherige Tonwert-Automatik) | 0 bis 100 |

`naturalBalanceAmount` aktiviert den natürlichen Bildausgleich ausschließlich bei einem Wert über 0. `naturalBalanceColorAmount` steuert dessen Farbanteil; Standard ist 50, bei ausgeschaltetem Bildausgleich bleibt dieser Wert ohne Bildwirkung. Beide Felder verwenden bei älteren Bearbeitungen nur bei fehlendem Schlüssel die Vorgaben 0/50; explizites `null` und falsche Typen werden abgewiesen. Bestehendes `autoToneAmount` bleibt unverändert lesbar. Der Renderer verwendet bei aktivem natürlichem Bildausgleich diesen anstelle der bisherigen Automatik. Nicht genannte Regler bleiben auch bei einem Wechsel unverändert: Ein KI-Patch muss das Ausschalten der bisherigen Automatik ausdrücklich mit `autoToneAmount=0` enthalten. Der manuelle Einschalter führt beide Änderungen gemeinsam aus.

Unbekannte Felder, doppelte JSON-Schlüssel einschließlich gleichwertiger Unicode-Escapes, mehrfach genannte Parameter, falsche Typen, nicht endliche Zahlen, unbekannte Versionen und Grenzüberschreitungen werden abgewiesen. JSON in Markdown oder ein gültig aussehender Teil einer ansonsten ungültigen Antwort wird nicht extrahiert. Eine ungültige Antwort wird weder teilweise angewendet noch still in den Wertebereich geklemmt. Das bisherige Normalisieren manueller `EditSettings` und Lesen älterer Datenbanken/Backups bleibt davon getrennt.

Standardgrenzen sind 16 KiB UTF-8 für die Benutzeranweisung, 64 KiB für die rohe Antwort, 2 KiB UTF-8 für die Erklärung, acht Verschachtelungsebenen, 256 JSON-Werte und maximal 16 verschiedene Regleränderungen. Die Prompt-/Antwortgrenzen sind über das injizierte Budget konfigurierbar; der Validator hat zusätzlich eigene konfigurierbare Strukturgrenzen. Eine größere Validatorgrenze umgeht die Antwortgrenze des Budgets nicht. Die Übernahme prüft anschließend nur Snapshot und Patch; sie führt die Promptprüfung nicht mit abweichenden Standardgrenzen erneut aus.

## Bildbezogener Plan und eingefrorene lokale Ebenen

Der lokale `ImageAwareEditingProvider` bereitet den eingefrorenen Bearbeitungsstand als Raster bis 1024 Pixel lange Kante und 16 MiB tatsächliche Rasterbytes vor. `ImageEditingPlan` enthält Status, globale absolute Zielwerte, Erklärung und höchstens drei verschiedene Bereichsaufträge für `subject`, `background` und `sky`. Das Modell liefert weder Maskenpixel noch Ebenen-IDs, Dateipfade oder Persistenzoperationen. Die globale Antwort bleibt unverändert im strengen Schema 1; Cloud und Textfallback akzeptieren dadurch keine neuen räumlichen Befehle oder Bilddaten.

Globale Werte beziehen sich auf den eingefrorenen Ausgang. Regionale Werte beginnen dagegen auf einer neuen neutralen lokalen Ebene. Dort sind ausschließlich Belichtung, Kontrast, Lichter, Tiefen, Weiß, Schwarz, Struktur, Klarheit, Dunstentfernung, Dynamik und Sättigung erlaubt. Automatik, natürlicher Bildausgleich und Entrauschung sind keine regionalen Parameter. Ein angefordertes Ziel mit leerer Änderungsliste bedeutet ausdrücklich keine nötige Korrektur und wird vor Maskenberechnung und Ebenenzählung ausgesondert; die Zielprüfung erfolgt weiterhin am vollständigen Plan. Doppelte Ziele, nichtleere wirkungslose regionale Patches, unbekannte Parameter oder verletzte Werte-/Ebenengrenzen verwerfen die gesamte Antwort.

Nach validierter Planung erzeugt die App Motiv- und Himmelsauswahlen aus einer geometrieneutralen Vorschau der orientierten Quelle; Hintergrund verwendet dieselbe Motivauswahl invertiert. Masken bleiben als eingefrorene Raster in neuen Ebenen mit weicher Kante 0 erhalten. Neue Ebenen werden angehängt; vorhandene Ebenen werden weder ersetzt noch neu berechnet. Die Gesamtgrenzen von 16 Ebenen und 16 MiB Maskendaten gelten einschließlich des vorhandenen Ausgangs. Ein fehlendes Himmelsmodell wird gemeldet, ohne Download oder Ersatz durch eine globale Korrektur.

Auswahlfehler oder fast leere/volle Masken verwerfen auch alle globalen Änderungen desselben Plans. Erst der vollständig validierte gemeinsame Zielstand gelangt als ein Undo-Schritt in den normalen Editor. Ein reiner lokaler Auftrag bleibt deshalb wirksam, auch wenn die globale Änderungsliste leer ist. Die UI zeigt globale und regionale Werte getrennt; Vergleich und Export verwenden dieselben gespeicherten Einstellungen wie manuelle Korrekturen. Maskieren bleibt unabhängig bedienbar.

## Gültigkeit und Quellenbezug

Die Originalidentität besteht aus standardisiertem Dateipfad, Änderungszeit und Dateigröße aus dem bereits geladenen Katalog. Das ist eine Änderungskennung, kein kryptografischer Beweis identischer Pixel. Die interne [Bildanalysevorbereitung](AI-IMAGE-ANALYSIS.md), die Metadaten und Bildassistent gemeinsam verwenden, ergänzt eine native Quellenrevision und den SHA-256-Digest des tatsächlich übergebenen Rasters einschließlich Profil-/Layoutvertrag. Ihre Dateiprüfung, Rastervorbereitung und Hashberechnung laufen im Hintergrund. Textfallback und Cloudprovider lesen weiterhin keine Bilddateien; Bildraster gelangen ausschließlich in den lokalen Visionpfad.

Bearbeitungs- und Auswahlgenerationen sind unabhängig von persistierten SQLite-Revisionen. Eine manuelle Änderung mit anschließendem Undo, Reset, Restore oder ein Auswahlwechsel A→B→A macht eine alte Anfrage ungültig, auch wenn danach wieder dieselben Zahlen oder dieselbe Foto-ID sichtbar sind. Sitzungskennungen verhindern Kollisionen zwischen Modellinstanzen; beim Ausschöpfen eines Generationszählers wechselt die zugehörige Epoche. Gesperrte/geschlossene Bibliothek oder Bearbeitung erlaubt keine KI-Übernahme.

Seit [Issue #10](ARTIFACT-STORAGE.md) umfasst die Quellenidentität Original oder Artefakt. Ein Artefaktfingerprint enthält Store-ID, Artefakt-ID, Manifest-/Rasterhash und Geometrie; der vollständige Bearbeitungssnapshot enthält Quelle und Regler gemeinsam. KI-Reglerübernahmen benötigen außerdem einen gültigen persistierten Ausgangsstand. Eine reine Originalanalyse kann ohne Editing-Ausgangsrevision funktionieren und erteilt dadurch keine Übernahmeberechtigung. Das Speichern generierter Pixel bleibt eine eigene typisierte Operation mit nativer Quellenprüfung und atomarem Snapshot-CAS.

## Ressourcen, Abbruch und Datenminimierung

Lokale Modellinferenz bleibt auf einen aktiven Aufruf begrenzt. Das ist eine bewusste serielle Grenze wegen gemeinsam verwendeter Modellsitzungen und noch unbekannten Modell-Spitzenspeichers. Die Auftragssteuerung hält nur eine aktuelle wartende Anfrage; neuere Arbeit ersetzt veraltete wartende Arbeit. Unabhängige Vorbereitung und bestehende Decoder-/Cache-I/O können weiter begrenzt parallel laufen.

Das Standardbudget ist zwischen Coordinators geteilt und begrenzt die tatsächlich laufende Inferenz gemeinsam. Die einzelne wartende Anfrage gilt je Coordinator; die UI verwendet einen Coordinator je aktivem Bearbeitungsablauf, statt für jede Anfrage einen neuen anzulegen. Gleichzeitige identische Anfragen desselben Coordinators teilen einen Job, behalten aber ihre eigenen Auftrags-IDs und Abbruchbezüge.

Der Bildprovider belegt eine gemeinsame Inferenzlease für zwei geordnete native Modellphasen: eine isolierte Textklassifikation des Geltungsbereichs und eine weitere isolierte Sitzung für bildbezogene numerische Werte. Die zweite Phase ist auf die klassifizierten Ziele und erlaubte globale Änderungen beschränkt; unabhängige Prüfungen verwerfen abweichende Pläne. Die Lease wird erst nach tatsächlicher Rückkehr dieser Modellarbeit freigegeben. Vor der anschließenden Maskenerzeugung wird sie freigegeben, weil der vorhandene automatische Maskendienst dasselbe Budget verwendet. Eine äußere Lease über beide Stufen würde den Maskendienst blockieren. Motiv- und Hintergrundaufträge verwenden dieselbe erzeugte Motivauswahl; deren serielle Erzeugung respektiert den einzelnen Inferenzplatz.

Ein abgebrochener Beobachter darf die Ressourcen eines noch laufenden, nicht unterbrechbaren Provideraufrufs nicht freigeben. Dessen Antwort wird nicht mehr veröffentlicht, der Platz aber erst nach seiner tatsächlichen Rückkehr wieder vergeben. Identische geteilte Arbeit erhält getrennte Beobachterbezüge. Fehler werden als technische Kategorien ohne Prompt, Originalpfad oder rohe Modellantwort weitergereicht.

Vorschauen und Bilddecodierung bleiben Aufgabe von `ImagePreviewPipeline` und `AdjustedPreviewPipeline` mit deren bestehenden Prioritäten und Grenzen. Es entsteht kein zusätzlicher Renderpool und kein Core-Image-Kontext pro Antwort. Das KI-Budget ist eine Auftrags-/Planungsgrenze, keine harte Grenze für interne Frameworkthreads, GPU-Texturen oder den gesamten Prozessspeicher. Die Bildkorrekturen verwenden vorhandene globale und lokale Filter; es wird keine CPU-/GPU-Beschleunigung behauptet.

## Prüfen und weiterentwickeln

Das [Bildbackend-Gate aus Issue #12](AI-IMAGE-BACKEND-DECISION.md) ergänzt getrennte Statuswerte für Text-to-Image, Image-to-Image, Inpainting, Hintergrundbearbeitung und Outpainting. Der Standard ist ein getestetes `UnavailableImageGenerationBackend` mit `qualityGateFailed`; es gibt keine erzeugten Produktbilder. Ein `ImageGenerationJob` bindet den vollständigen Snapshot, unveränderliche native Pixel, Maskenrevision, Pipelineversion, Parameter und Seed. Der `ImageGenerationService` prüft die Verfügbarkeit vor der Backendarbeit sowie erneut nach dem Warten auf das Budget. Aktuelle Tokens prüft er vor und nach der tatsächlichen Backendarbeit. Er begrenzt jedes Rohresultat durch den lokalen `MaskCompositor`, bevor ein Ergebnis zurückgegeben wird. Der Dienst speichert oder übernimmt keine Artefakte; der AI-09-Transaktionspfad bleibt dafür zuständig.

Bildjobs teilen die bestehende einzelne lokale Inferenzlease. Die deklarierte Summe aus residentem Modell und Arbeitsdaten darf standardmäßig 6 GiB nicht überschreiten; reale RSS-/Footprint-Messungen im separaten Harness ergänzen diese Vorprüfung. Der aktuelle und höchstens ein wartender Bildjob bleiben begrenzt. Abbruch und kontinuierliche Deadlines verhindern Veröffentlichung, geben die Lease aber erst nach tatsächlicher Backend-/Compositor-Rückkehr frei. Bild-/Maskenvorverarbeitung verwendet denselben expliziten Ausschnitt und dieselben Pixelzentren, prüft das Seitenverhältnis und transportiert die inverse Geometrie. Sie benötigt keine zusätzlichen Worker-Pools. Normale Tests verwenden Fakes und selbst erzeugte kleine Rasters.

Die normalen Tests verwenden deterministische Fakeprovider und isolierte temporäre Kataloge/Stores. Gesteuerte Fortsetzungen statt zeitbasierter Vermutungen prüfen Queuegrenzen, Abbruchignorierung, schnelle Änderungen, ungültige Antworten und einmaliges Übernehmen. Es gibt keine realen Modellaufrufe, Netzwerkanfragen, Downloads oder API-Kosten im Testpfad.

Die Produktionsdeadline für Bildgenerierung beginnt mit dem Eintritt in `generate`. Der Test für den abschließenden Beobachter-Lookup wartet deshalb erst nach dessen Gate und nach dem nachgewiesenen Ende der nativen Arbeit samt Freigabe der Inferenzlease weitere 1,1 Sekunden; die Produktionsfrist im Test bleibt bei einer Sekunde. Beide Testfälle starten den `generate`-Aufruf ohne beziehungsweise mit 250 Millisekunden Verzögerung. Diese Verzögerung übersteigt die frühere Reserve von 100 Millisekunden und prüft, dass die Wartefrist am erreichten Gate beginnt. Swift-Testing-Suites bleiben parallel ausführbar; ihre Serialisierung ersetzt diese Synchronisierung nicht.

Für gezielte Prüfungen kann `scripts/test.sh` mit einem eigenen `PICEDIT_TEST_BUILD_PATH` und einem Swift-Testing-Filter verwendet werden. Unabhängige Test-/Buildläufe benötigen getrennte Buildverzeichnisse. Der verpflichtende abschließende saubere App-Build und das Diffreview folgen weiterhin `AGENTS.md` und dem Abschnitt „Entwickeln und prüfen“ im README.

```sh
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-ai-tests ./scripts/test.sh --jobs 4 --filter AI
```

Der Deadline-Test und anschließend die vollständige Suite mit der normalen parallelen Swift-Testing-Ausführung lassen sich so prüfen:

```sh
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-image-generation-tests ./scripts/test.sh --jobs 4 --filter ImageGenerationServiceTests/expirationDuringFinalCurrentTokenLookupCannotPublishAfterTimerWasCancelled
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-image-generation-tests ./scripts/test.sh --jobs 4
```

Der echte lokale Textprovider aus [Issue #3](https://github.com/dr-dimitri/picedit/issues/3) und die Assistentenoberfläche mit direkter Aktivierung aus [Issue #4](https://github.com/dr-dimitri/picedit/issues/4) sind in der [Assistentendokumentation](LOCAL-AI-ASSISTANT.md) beschrieben. Die [drei Lookvarianten aus Issue #5](AI-LOOKS.md) bleiben ausschließlich als interne Kompatibilitäts-API und Tests erhalten; Lookknopf und Karten sind aus der Oberfläche entfernt. Der Requestmodus trennt die erhaltenen Antwortformen weiterhin.

Der eigenständige Analysebereich ist entfernt. Die interne Bildanalyse aus [Issue #6](https://github.com/dr-dimitri/picedit/issues/6) verwendet eigene typisierte Anfragen, Ergebnisse und eine unabhängige Verfügbarkeitsprüfung für `imageUnderstanding`. Ihr lokaler Dienst teilt das Inferenzbudget mit der Textassistenz. Die Antwort enthält ausschließlich begrenzte Beschreibung und visuelle Attribute; appseitiger Quellenbezug und Auftragsidentität kommen nicht aus dem Modell. Originalanalysen bleiben bei Regleränderungen gültig, bearbeitete Eingaben sind an den vollständigen Bearbeitungssnapshot gebunden. Alle Ergebnisse sind vorläufig und schreiben keine Metadaten.
