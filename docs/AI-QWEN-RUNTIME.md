# Native Qwen-Laufzeit

Der Arbeitsbereich **AI Entwickeln** verwendet Qwen3.5-4B lokal als Vision-Language-Modell.
Die bisherigen [Python-Messungen](AI-QWEN35-EVALUATION.md) bleiben getrennte
Evaluationen; deren negative Qualitätsentscheidung wird nicht in eine Freigabe
unbeaufsichtigter Autokorrektur umgedeutet. Die neue Route erstellt überprüfbare
Vorschläge aus Bildvorschau, Entwicklungswunsch und semantischen Reglern.

## Gepinnte Komponenten

- [mlx-swift-lm 3.32.3](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3),
  Commit `3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`: MLXVLM/Qwen3.5,
  MLXLMCommon und MLXGuidedGeneration mit vendortem XGrammar.
- [mlx-swift 0.32.3](https://github.com/ml-explore/mlx-swift/releases/tag/0.32.3),
  Commit `19601207e9a0de51e03ee6ec0c3c5f3784275075`.
- Sein `Source/Cmlx/mlx`-Submodul ist exakt MLX **v0.32.2**, Commit
  `1f8e74e3f12f31365464a6867c6579f0e9b29d85`. Maßgeblich ist dieses
  Submodul, nicht die ältere Versionskonstante im Swift-Paketmanifest.
- Der vorhandene gepinnte Swift-Transformers-Tokenizer wird über einen schmalen
  Adapter wiederverwendet; Laden ausschließlich aus dem installierten Ordner.

Apple Silicon und Metal sind erforderlich; bei fehlender GPU zeigt die App einen
verständlichen Fehler. Ein gleichwertiger, qualifizierter CPU-Qwen-Pfad ist nicht
vorhanden. Die generelle Mindestversion der App bleibt macOS 14. Für das Bauen
der neuen Abhängigkeiten ist Swift 6.3 oder neuer erforderlich.

## Metal-Paketierung ohne Python-Laufzeit

`prepare-mlx-runtime.sh` lädt das offizielle
[`mlx-metal`-Wheel 0.32.2 für macOS 14 / arm64](https://pypi.org/project/mlx-metal/0.32.2/)
und extrahiert ausschließlich `mlx/lib/mlx.metallib` sowie den MIT-Lizenztext.
Es installiert und startet keinen Python-Code. Das Wheel enthält die Shader des
exakt gleichen Core-Releases wie das Swift-Paket. Das Skript prüft vor Verwendung
beide SHA-256-Digests:

- Wheel: `3825fff379dbc107dd3413e564a06caeaa24819910ec49c0439e454c06a1b9b8`
- Metal-Bibliothek: `a19618258e2a215d0d0ac3056174a6e066818bb6cdecb50062cc9316076ebe43`

Der Builddownload umfasst 42.516.623 Byte; die ausgepackte Bibliothek umfasst
135.865.440 Byte und gehört zu den App-Ressourcen, zusätzlich zu den separat
verwalteten Modellgewichten. Die Quellen/Lizenzen verbleiben unverändert.
`build-app.sh` kopiert Shader und Lizenz vor Signatur ins Bundle. Die App prüft
die Metal-Ladbarkeit vor dem ersten MLX-Aufruf. Sie benötigt weder `/tmp`-Dateien,
Python, Homebrew, einen Modellserver noch Netzwerk bei der Inferenz.

Die Buildskripte verwenden standardmäßig SwiftPMs `native`-Buildsystem, damit
auch reine Command-Line-Tools-Installationen ohne Metal-Compiler dasselbe
Artefakt bauen. `GLOWROOM_BUILD_SYSTEM` kann dies auf Entwicklungsmaschinen mit
passender Metal-Toolchain überschreiben. Allein `swift build` erstellt noch kein
vollständiges Glowroom-Bundle. Tests erhalten den geprüften Shaderpfad über
`GLOWROOM_MLX_METALLIB`; Entwicklerwerkzeuge bekommen eine Kopie neben dem
Executable. Ein sauberer Build entfernt den Shadercache gemeinsam mit seinem
Buildverzeichnis und prüft den erneuten Download.

## Ausführung und Abbruch

`QwenDevelopmentBackend` erwartet einen bereits installierten, während des
Aufrufs geleasten Modellordner, eine höchstens 2048 Pixel große Vorschau, Prompt
und JSON-Schema. Die Bildvorverarbeitung begrenzt die Modellansicht auf 1024 Pixel.
Der Aufruf arbeitet auf einem Hintergrundactor; die gemeinsame
`AIResourceBudget`-Lease bleibt bis zur tatsächlichen Rückkehr belegt.
Der Adapter lehnt zusätzliche gleichzeitige Aufrufe ab.

Die Laufzeit lädt lokal, deaktiviert Thinking und erzeugt mit dem nativen
XGrammar-Decoder greedy höchstens 768 Tokens bei Prefill-Blöcken von 512.
Unvollständige Ausgaben, Abbruch und zu große Antworten werden verworfen.
Anschließend prüft der gemeinsame Swift-Vertrag zusätzlich Feldnamen, Zahlen und
Bereiche. Modelloutput führt keine Werkzeuge aus und schreibt keine Dateien.

CPU-Grammatikarbeit überlappt die GPU-Forward-Passes. Die bewusst einzelne
Modellinferenz schützt Unified Memory; sie ist kein harter Gesamt-RAM-Grenzwert.
Nach jeder Anfrage werden Modell und KV-Zustand freigegeben, GPU-Arbeit
synchronisiert und der MLX-Allokatorcache geleert. Das verhindert residente
Gewichte nach dem Löschen und Konkurrenz mit späterer Bildbearbeitung. Es
behauptet keinen Geschwindigkeitsgewinn gegenüber dem Python-Versuch.

## Tatsächliche Prüfung am 23. Oktober 2026

Der opt-in Test `QwenNativeModelTests` führte den beschriebenen nativen Adapter
mit dem vorhandenen, gepinnten Qwen-Snapshot und einem synthetischen RGB-Bild
aus. Gewünschte behutsame Aufhellung ergab ein vollständig validiertes JSON mit
`exposure: 0.3`, `whites: 10` und einer deutschen Erklärung. Die Testdauer betrug
53,730 Sekunden im Debug-Build, einschließlich Laden, kalter Grammatik und
Inferenz. Dies ist ein technischer Funktionsnachweis für diese Eingabe, keine
Qualitätsfreigabe, Laufzeitzusage oder Kalt-/Warmcache-Benchmarkreihe.

```sh
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-qwen-tests \
GLOWROOM_QWEN_MODEL_PATH=/absoluter/pfad/zum/geprüften/modell \
./scripts/test.sh --jobs 4 --filter QwenNativeModelTests
```

Ohne `GLOWROOM_QWEN_MODEL_PATH` bleibt dieser Test deaktiviert. Er lädt keine
Gewichte nach. Die gewöhnlichen AI-Entwicklungstests verwenden kontrollierte
Fakes; die Buildskripttests prüfen zusätzlich das Einbinden von Shader und Lizenz
in das signierte Bundle.
