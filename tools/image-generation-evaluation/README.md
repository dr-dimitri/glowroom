# Explizite lokale Vorbereitung für das entschiedene No-Go-Gate

Diese Dateien bauen einen **Evaluationshelper**. Sie schalten keine Produktfähigkeit frei und starten keine Inferenz. SDK/GGML, Modell, Patch, Helper und Parameter sind gepinnt. `evaluation-package.json` enthält Größen und SHA256 für alle 14 Modelldateien, beide Sourcearchive und die Buildinputs; sein eigener SHA256 ist im Vorbereitungsscript festgelegt. Das unveränderte historische `model-manifest.json` bleibt in diesem Werkzeugordner zur Prüfung des alten Vertrags bytegleich. Historische Rohberichte, Bilder und Evaluationsquellsnapshots wurden mit dem Reportsordner entfernt.

Erforderlich sind Apple Silicon, macOS 14+, mindestens 16 GiB physischer Speicher, mindestens 8 GiB freier Speicherplatz, installierte Command Line Tools, Python 3 und CMake. Dies sind Startbedingungen für eine Evaluation; sie behaupten keine Qualitäts- oder Geschwindigkeitsfreigabe auf allen solchen Geräten. Die bisher tatsächlich gemessene Konfiguration ist M2 Pro/16 GiB/macOS 27.0.1. Der Build verwendet höchstens zwei Jobs und ein eigenes temporäres Quell-/Buildverzeichnis; keine Glowroom- oder fremden Buildpfade werden bereinigt.

Download und Build sind getrennte, ausdrücklich aufzurufende Schritte. Der Download beträgt einschließlich Modellmetadaten ungefähr 2,13 GB plus 130 MB Quellarchive. Die CreativeML-OpenRAIL-M-Gewichtelizenz mit ihren Nutzungs-/Weitergabebedingungen liegt vollständig in `LICENSE-weights.txt`; die SDK-/Drittanbieterhinweise liegen in `THIRD-PARTY-NOTICES.txt`. Es werden keine Gewichte oder Binärdateien ins Repository geschrieben.

```sh
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/glowroom-image-evaluation --download --fixture-archive /private/tmp/glowroom-fixture-archive
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/glowroom-image-evaluation --build --fixture-archive /private/tmp/glowroom-fixture-archive
```

Ein expliziter CMake-Pfad kann mit `--cmake /absolute/path/to/cmake` angegeben werden. `--build` verwendet stets nur lokal vorhandene geprüfte Archive und greift niemals auf das Netzwerk zu. Ein vorhandener abgeschlossener Helper wird nicht überschrieben; für einen erneuten Build ist ein neuer Evaluationsordner zu verwenden.

Ein vollständiger vorhandener Evaluationscache kann ohne Netzverbindung wiederverwendet werden:

```sh
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/glowroom-image-evaluation --download --fixture-archive /private/tmp/glowroom-fixture-archive --offline --source-cache /absolute/path/to/verified-cache
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/glowroom-image-evaluation --build --fixture-archive /private/tmp/glowroom-fixture-archive --source-cache /absolute/path/to/verified-cache
```

`--offline` verbietet auch beim expliziten Download jede Netzanfrage. Fehlende oder beschädigte Cachedateien führen zu einem Fehler; sie werden nicht still durch einen Download ersetzt. Hashes werden vor Nutzung und nach Kopieren/Download geprüft. Das Modell wird unter einem privaten Stagingnamen vollständig vorbereitet und anschließend atomar als `model/` veröffentlicht. Der native Build erfolgt aus isoliert extrahierten, größenbegrenzten Archiven; Pfadtraversal, Links und besondere Dateitypen werden abgelehnt. Der bekannte GGML-Metadatenlink `.pi/SYSTEM.md` wird lediglich übersprungen und nie verfolgt.

Der fertige Helper heißt `<root>/evaluation-helper-current` und erhält **genau einen absoluten Rootpfad** als Argument. Der JSONL-Vertrag bleibt der historischen C++-Route entsprechend: `load`, `generate`, `cancel`, `unload`, `stats`, `shutdown`; keine Prompts als Prozessargumente. Modell, Quellen und Ausgaben werden weiterhin unter diesem expliziten Root gesucht. Die Rechenparameter bleiben Metal-Diffusion/CPU-VAE, partielle F32-VAE-Regel, ungebündelte CFG, Skalen 1/128, Euler/25 Schritte/CFG 7,5/Stärke 1.

Das Preview-Gate des ausdrücklich gestarteten SD-1.5-Benchmarks verlangt für Baseline und konkurrierende Phase jeweils eine positive ganzzahlige `sampleCount` sowie eine endliche, nichtnegative P95-Latenz. Fehlende, leere oder ungültige Messungen ergeben ein nicht bestandenes Gate mit Diagnose; eine leere Messreihe wird nicht als Null-Latenz ausgegeben. Die Grenzen bleiben unverändert: konkurrierendes P95 höchstens 0,25 Sekunden und höchstens das Zweifache des Baseline-P95. Der einzelne Hintergrundrenderer misst weiterhin nur das synthetische 256×256-Schachbrett, keine tatsächlichen UI-/RAW-Latenzen. Die damalige Prüfung der SD-1.5-Samplezahlen ergab für beide historischen Läufe nichtleere Phasen. Die Rohberichte wurden entfernt; die zusammengefasste Qualitätsentscheidung bleibt No-Go. Diese Korrektur erfordert keinen neuen Modelllauf.

Die gemeinsame Preview-Auswertung für SD-1.5 und SDXL schreibt fehlende oder ungültige Latenzmetriken als JSON-`null`. `measurementStatus` unterscheidet `measured`, `missing-samples` und `invalid-latencies`; `previewGateFailureReasons` benennt die betroffene Phase beziehungsweise die überschrittene Grenze. Boolesche Werte und Zahlenstrings gelten nicht als numerische Messwerte. Modellfreie Regressionen prüfen beide leeren Phasen einzeln und gemeinsam, einen kontrolliert erst nach der Stop-Anforderung gestarteten Renderer, ungültige Werte, Quantile und die unveränderten Grenzwerte:

```sh
./scripts/test.sh --jobs 4 --filter ImageGenerationPreviewProbeTests
```

Erst nach erfolgreichem Build wird `evaluation-installation.json` als abschließender Readiness-Marker veröffentlicht. Er enthält Helper-, Modellmanifest- und Konfigurationshash sowie SDK-, GGML- und Modellrevision. `configurationSHA256` bezeichnet das kanonische sortierte JSON ohne abschließenden Zeilenumbruch (`a356133c…`); `configurationFileSHA256` bezeichnet die unveränderten vollständigen Dateibytes einschließlich Zeilenumbruch (`bfcd90c9…`). Beide Werte sind getrennt zu prüfen. `modelFilesInstalled` beschreibt den Buildzeitpunkt; ein separat später ausgeführter Download verändert diesen historischen Buildwert nicht. Ein Ausführungsharness muss vor jedem Start die aktuellen Modell-/Helperhashes, Maße, Ressourcenlage und den Konfigurationsvertrag prüfen. Die Vorbereitung benötigt sowohl für `--download` als auch `--build` für die sechs unveränderten synthetischen Fixtures ein ausdrücklich angegebenes externes Archiv (`--fixture-archive` mit `provenance/fixtures-manifest.json` und `fixtures/`). Die gepinnten Originalhashes bleiben verbindlich; neu erzeugte Contract-Fixtures ersetzen dieses Archiv nicht. Er installiert die geprüften Fixtures mit Manifest, `unbatched-configuration.json` und Drittanbieterhinweisen im externen Root. Neue Benchmarkausgaben werden ebenfalls nur im ausdrücklich gewählten externen Ausgabeordner angelegt.

Offline-Tests benötigen weder Gewichte noch Compiler, Schlüssel oder Netzwerk:

```sh
python3 -B -m unittest discover -s tools/image-generation-evaluation -v
```
