# Gemeinsame lokale Modellkarten

`registry.json` registriert sechs versionierte Modellkarten. `card.schema.json`, `file.schema.json` und `native-evidence.schema.json` sind maschinenlesbare JSON-Schemas. Der Python-3-Validator verwendet ausschließlich die Standardbibliothek und prüft genau die dort verwendeten Schemaelemente. Er lädt keine Modelle herunter, verändert keine installierten Modelle und gehört nicht zur App-Laufzeit.

| Familie | Bestehender Vertrag |
| --- | --- |
| Qwen3.5-4B, MLX 4 Bit | Gepinnter kompletter Snapshot einschließlich Tokenizer, Prozessor und Chattemplate; Metal, verständlicher Fehler ohne GPU |
| SigLIP2, gepaarte Türme | Geprüftes Core-ML-Importpaket; Float32-Bildturm, Float16-Textturm; CPUOnly |
| BiRefNet HR Matting, 1920 | Geprüftes Core-ML-Importpaket; CPU/GPU mit CPU-Fallback |
| Apple DETR | Gepinnter unveränderter Core-ML-Download; `.all` mit CPU-Fallback |
| Skyseg U²-Net | Gepinnter ONNX-Download, kein aktiver Inferenzbackend |
| LaMa | Optionaler gepinnter Core-ML-Download für kleine Reparaturen sowie ausdrücklich ausgewählte kompatible 800-Pixel-Pakete; individuelle Installationsinventare bleiben erhalten |

Apple Vision und das SystemLanguageModel sind vom Betriebssystem verwaltete Dienste ohne von Glowroom verteilte Gewichte. Sie erhalten hier keine erfundene Quellrevision oder Paketfreigabe. SD-/SDXL-/JarvisArt-Kandidaten bleiben getrennte Evaluationen ohne aktiven Produktbackend. Das historische 2048-Pixel-BiRefNet-Inventar bleibt ausschließlich zur sicheren Erkennung alter Installationen erhalten; es ist keine weitere aktuelle Modellfamilie.

Jede Karte trennt Code- und Gewichtslizenz, ursprüngliche Gewichte und Konvertierung, Trainingsdatenherkunft, technischen I/O-Vertrag und Hardwaregrenzen. Ein `unknown` beziehungsweise eine ausdrücklich als unbekannt bezeichnete Herkunft ist eine belegte Lücke, keine positive Lizenz- oder Provenienzbehauptung. Der LaMa-Uploaderhinweis ersetzt keine vollständige Herkunftskette; auch die ursprüngliche Revision der Qwen-Quantisierung wird nicht erfunden. Weitere Nutzungs- und Weitergaberechte müssen vor einer neuen Veröffentlichung getrennt geklärt werden. Die LaMa-Karte führt drei paketrelative Download-Dateien unter `package.files`; `referenceFiles` bewahrt zusätzlich das frühere Evaluationsinventar einschließlich Modellkarte. Der Validator bindet die Download-Dateien an dieselben dokumentierten Bytes. Der Status `download-and-user-import` beschreibt die optionale Beschaffung für den vorhandenen Reparaturpfad und erteilt keine allgemeine Bildgenerierungs-, Hintergrund- oder Outpainting-Freigabe.

## Prüfen und deterministisch generieren

Vom Repository aus:

```sh
python3 tools/model-registry/registry.py check
python3 tools/model-registry/registry.py generate
python3 -m unittest discover -s tools/model-registry -p 'test_*.py'
```

`check` prüft Pflichtfelder, Hashformate, sichere eindeutige Paketpfade, vollständige Familienregistrierung, eindeutige Modellidentitäten, Dokumentationsverweise, Bindung an vorhandene Adapter, Runtime-/Tokenizer-/I/O-Konsistenz und die unveränderten generierten Dateien. Änderungen an den erzeugten Dateien ohne entsprechende Karte schlagen fehl. `generate` erzeugt ausschließlich die bisherigen JSON-Freigabedateien und `GeneratedLocalModelRegistry.swift`; gleiche Eingaben liefern bytegleiche Ausgaben unabhängig von Kartenreihenfolge. Die Freigabe bleibt fest in die App eingebunden. Kein Servermanifest kann ein Modell automatisch aktivieren.

Die bestehenden Installationsverträge bleiben erhalten: genaue Größen und SHA-256, ausdrückliche Einrichtung, kontrollierter Abbruch, private Staginggenerationen und atomare Veröffentlichung durch die vorhandenen Stores. Der LaMa-Download lädt ausschließlich die gepinnten Paketdateien und richtet sie durch den vorhandenen Importer ein. Manuelle kompatible LaMa-Importe bleiben unabhängig davon möglich. Zu prüfen bleiben die Swift-Regressionen `SemanticModelInstallerTests`, `LLMModelStoreTests`, `AutomaticMaskModelStoreTests`, `SkySegModelDownloadStoreTests`, `SubjectMattingModelStoreTests`, `DevelopRepairAIModelDownloadStoreTests` und `DevelopRepairAIModelStoreTests`.

## Vollständige Artefaktprüfung

Die Verzeichniswurzel enthält genau die Dateien des modellbezogenen Karteninventars, beispielsweise beim Suchmodell `models/`, `tokenizer/` und `licenses/`. Optional ist dort das bytegleiche generierte `manifest.json` erlaubt. Ein fehlender Baum, fehlende oder zusätzliche Dateien, Symlinks, Hardlinks, falsche Größen und Hashes sowie während des Lesens veränderte Dateien scheitern. Kein Netzfallback:

```sh
python3 tools/model-registry/registry.py check \
  --model siglip2-base-p32-256-fp32-image-fp16-text-v1 \
  --artifacts-dir /absoluter/pfad/zum/portablen-paket --jobs 2
```

Unabhängige Kartenvorbereitung und Dateihashes arbeiten standardmäßig mit zwei, höchstens vier Workern. Dateihashes verwenden 1-MiB-Puffer. Keine Modellinferenz startet in diesem Pool.

## Native Qualifizierung

Die bestehenden Quellenberichte sind in den Karten ausdrücklich `existing-evidence-only`: BiRefNet enthält native Referenz- und Fallbackprüfungen, SigLIP und Qwen haben die in ihren Dokumentationen beschriebenen begrenzten Nachweise. Diese Migration führt keine neue native Messreihe aus und macht aus Python-/ONNX-Proben keine Core-ML-Freigabe. Fehlende ältere-macOS-/Intel-Nachweise, Rohdaten und vollständige Kalt-/Warmreihen bleiben benannt. Die Werkzeugeinheitstests verwenden ausschließlich synthetische Payloads und belegen keine Modellqualität.

Neue Freigabebelege müssen das Schema `native-evidence.schema.json` erfüllen. Es bindet Modellkennung, kanonischen Kartenhash, vollständigen Inventarhash und Vertragshash; dokumentiert macOS und Hardware, angeforderte und tatsächlich beobachtete Ausführungswege samt Beobachtungsmethode, Laden, I/O, Referenzmethode/Fixture/Schwellen/Ergebnis und CPU-Fallback oder verständlichen Fehler. Erstlauf (`process-first`) und warme Modellläufe (`model-warm`) werden einzeln mit Zeit, Peak-RSS, Cachevorbereitung und Ausführungsweg dokumentiert. Ein Prozess-Erstlauf behauptet keine geleerten OS-/Treiber-Caches; Core ML `.all` beweist allein keinen GPU-/ANE-Pfad. Solche Beobachtungsgrenzen gehören in den Bericht.

```sh
python3 tools/model-registry/registry.py release-check \
  --model birefnet-hr-matting-v1-1920 \
  --artifacts-dir /absoluter/pfad/BiRefNet.mlpackage \
  --evidence /absoluter/pfad/native-evidence.json
```

Alle Pflichtprüfungen müssen bestanden sein, exakte Artefakte vorhanden sein und Erst-/Warmläufe getrennt vorliegen. Unbekannte oder ungültige Originalgewichtshashes, nicht unveränderlich belegte Originalrevisionen und unbekannte Konverterversionen sperren jede neue Requalifizierung; die vorhandenen Installationsverträge bleiben davon unberührt. Download-only und individuelle Nutzerimporte können hier keine neue Paketfreigabe erhalten. Erfolgreiche Validierung liefert `automaticAppApproval: false`: Änderungen an Karten und Appfreigabe benötigen weiterhin Review und die vorgesehenen nativen Produktprüfungen.

`native-run` kann einen ausdrücklich benannten nativen Harness unter einer hostweiten exklusiven Qualifizierungsdateisperre ausführen. Ein paralleler Aufruf scheitert, anstatt die Messung zu verfälschen; aktive Sperren werden nicht gelöscht. Vorherige und nachherige Artefaktprüfung binden den Lauf an unveränderte Dateien. Der Harness muss selbst den vollständigen Bericht schreiben; es gibt keine automatische Umdeutung alter Berichte:

```sh
python3 tools/model-registry/registry.py native-run \
  --model birefnet-hr-matting-v1-1920 \
  --artifacts-dir /absoluter/pfad/BiRefNet.mlpackage \
  --evidence /absoluter/pfad/neuer-native-evidence.json \
  -- /absoluter/pfad/zum/nativen-harness
```

Der Harness erhält `GLOWROOM_QUALIFICATION_MODEL_ID`, `GLOWROOM_QUALIFICATION_CARD_SHA256`, `GLOWROOM_QUALIFICATION_PACKAGE_SHA256`, `GLOWROOM_QUALIFICATION_CONTRACT_SHA256`, `GLOWROOM_QUALIFICATION_ARTIFACTS` und `GLOWROOM_QUALIFICATION_OUTPUT`. Das Ziel muss neu sein. Vorhandene modellbezogene Swift-/Core-ML-Harnesses dienen als Ausgangspunkt, erzeugen bisher aber nicht dieses gemeinsame Berichtschema; ein Lauf ohne passenden Bericht scheitert ausdrücklich. Andere App-/Benchmark-/GPU-Prozesse müssen für die Messreihe ebenfalls beendet sein; die Sperre koordiniert nur Aufrufe dieses Entwicklerkommandos. Native Messungen bleiben absichtlich seriell, da konkurrierende Unified-Memory-/GPU-Last die Ergebnisse entwertet.
