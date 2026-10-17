# Explizite lokale Vorbereitung für das entschiedene No-Go-Gate

Diese Dateien bauen einen **Evaluationshelper**. Sie schalten keine Produktfähigkeit frei und starten keine Inferenz. SDK/GGML, Modell, Patch, Helper und Parameter sind gepinnt. `evaluation-package.json` enthält Größen und SHA256 für alle 14 Modelldateien, beide Sourcearchive und die Buildinputs; sein eigener SHA256 ist im Vorbereitungsscript festgelegt. Der unveränderte historische `model-manifest.json` bleibt zur Prüfung des alten Vertrags bytegleich.

Erforderlich sind Apple Silicon, macOS 14+, mindestens 16 GiB physischer Speicher, mindestens 8 GiB freier Speicherplatz, installierte Command Line Tools, Python 3 und CMake. Dies sind Startbedingungen für eine Evaluation; sie behaupten keine Qualitäts- oder Geschwindigkeitsfreigabe auf allen solchen Geräten. Die bisher tatsächlich gemessene Konfiguration ist M2 Pro/16 GiB/macOS 27.0.1. Der Build verwendet höchstens zwei Jobs und ein eigenes temporäres Quell-/Buildverzeichnis; keine PicEdit- oder fremden Buildpfade werden bereinigt.

Download und Build sind getrennte, ausdrücklich aufzurufende Schritte. Der Download beträgt einschließlich Modellmetadaten ungefähr 2,13 GB plus 130 MB Quellarchive. Die CreativeML-OpenRAIL-M-Gewichtelizenz mit ihren Nutzungs-/Weitergabebedingungen liegt vollständig in `LICENSE-weights.txt`; die SDK-/Drittanbieterhinweise liegen in `THIRD-PARTY-NOTICES.txt`. Es werden keine Gewichte oder Binärdateien ins Repository geschrieben.

```sh
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/picedit-image-evaluation --download
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/picedit-image-evaluation --build
```

Ein expliziter CMake-Pfad kann mit `--cmake /absolute/path/to/cmake` angegeben werden. `--build` verwendet stets nur lokal vorhandene geprüfte Archive und greift niemals auf das Netzwerk zu. Ein vorhandener abgeschlossener Helper wird nicht überschrieben; für einen erneuten Build ist ein neuer Evaluationsordner zu verwenden.

Ein vollständiger vorhandener Evaluationscache kann ohne Netzverbindung wiederverwendet werden:

```sh
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/picedit-image-evaluation --download --offline --source-cache /absolute/path/to/verified-cache
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/picedit-image-evaluation --build --source-cache /absolute/path/to/verified-cache
```

`--offline` verbietet auch beim expliziten Download jede Netzanfrage. Fehlende oder beschädigte Cachedateien führen zu einem Fehler; sie werden nicht still durch einen Download ersetzt. Hashes werden vor Nutzung und nach Kopieren/Download geprüft. Das Modell wird unter einem privaten Stagingnamen vollständig vorbereitet und anschließend atomar als `model/` veröffentlicht. Der native Build erfolgt aus isoliert extrahierten, größenbegrenzten Archiven; Pfadtraversal, Links und besondere Dateitypen werden abgelehnt. Der bekannte GGML-Metadatenlink `.pi/SYSTEM.md` wird lediglich übersprungen und nie verfolgt.

Der fertige Helper heißt `<root>/evaluation-helper-current` und erhält **genau einen absoluten Rootpfad** als Argument. Der JSONL-Vertrag bleibt der archivierten C++-Route entsprechend: `load`, `generate`, `cancel`, `unload`, `stats`, `shutdown`; keine Prompts als Prozessargumente. Modell, Quellen und Ausgaben werden weiterhin unter diesem expliziten Root gesucht. Die Rechenparameter bleiben Metal-Diffusion/CPU-VAE, partielle F32-VAE-Regel, ungebündelte CFG, Skalen 1/128, Euler/25 Schritte/CFG 7,5/Stärke 1.

Erst nach erfolgreichem Build wird `evaluation-installation.json` als abschließender Readiness-Marker veröffentlicht. Er enthält Helper-, Modellmanifest- und Konfigurationshash sowie SDK-, GGML- und Modellrevision. `configurationSHA256` bezeichnet das kanonische sortierte JSON ohne abschließenden Zeilenumbruch (`a356133c…`); `configurationFileSHA256` bezeichnet die unveränderten vollständigen Dateibytes einschließlich Zeilenumbruch (`bfcd90c9…`). Beide Werte sind getrennt zu prüfen. `modelFilesInstalled` beschreibt den Buildzeitpunkt; ein separat später ausgeführter Download verändert diesen historischen Buildwert nicht. Ein Ausführungsharness muss vor jedem Start die aktuellen Modell-/Helperhashes, Maße, Ressourcenlage und den Konfigurationsvertrag prüfen. Der Builder installiert außerdem die unveränderten sechs synthetischen Fixtures, deren Manifest, `unbatched-configuration.json` und Drittanbieterhinweise.

Offline-Tests benötigen weder Gewichte noch Compiler, Schlüssel oder Netzwerk:

```sh
python3 -B -m unittest discover -s tools/image-generation-evaluation -v
```
