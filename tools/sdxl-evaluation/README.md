# Lokale SDXL-Inpainting-Evaluation

[Issue #77](https://github.com/dr-dimitri/picedit/issues/77) setzt die lokale Nachweisführung für [#1](https://github.com/dr-dimitri/picedit/issues/1) fort. Die produktive Bildgenerierung bleibt bis zum vollständigen Nachweis unavailable. Ein technischer Modelllauf allein schließt #13–16 nicht ab. Die bisherigen SD-1.5- und LaMa-No-Go-Ergebnisse bleiben unverändert.

**Ergebnis der abgeschlossenen V8-Serie: No-Go für diese Konfiguration.** Alle zehn Vorhersagen wurden innerhalb ihrer Zeitgrenzen erzeugt; der erforderliche Qualitätsfall 05 und das native Abbruchgate bestehen jedoch nicht. Historische Rohberichte, Bilder und damalige Quellsnapshots wurden mit dem Reportsordner entfernt. Die Ergebnisse in diesem Dokument bleiben als historische Zusammenfassung erhalten. Neue Läufe benötigen explizite externe Eingaben und Ausgabeordner.

## Fortsetzung V10: gepinnter Euler-Zeitplan

**Die tatsächliche V10-Einzelprobe bleibt No-Go:** 157,055 s bei 19 tatsächlichen Schritten, unveränderte Erhaltpixel, aber weiterhin breite dunkle Konturen und helle Säume. Zwei Sichtungen bestätigen den Pflichtfehler; keine vollständige Serie oder neue Abbruchfreigabe.

Der aktuelle Builder verwendet den [gepinnten Modellzeitplan](provenance/reference-scheduler-semantics.json): Euler mit `leading`, `steps_offset=1`, 20 angeforderten Schritten und Stärke 0,99. Die Referenz wählt daraus 19 tatsächliche Schritte bei Trainingszeitpunkten 901, 851, …, 1 und eine abschließende Sigma-Null. Das bisherige SDK-`discrete` verwendete dagegen 20 Schritte von 999 bis 0. V10 übergibt die ausgewählten Sigmas über die öffentliche `custom_sigmas`-Schnittstelle. Gewichte, CFG, Prompt, Seed, Nearest-Maske, Kachelung und finale Komposition bleiben gleich. Dies prüft eine Zeitplanabweichung; es behauptet keine vollständige numerische Gleichheit mit Diffusers.

Die zunächst erwogene Abschaltung der Original-Latent-Rückmischung wird nicht umgesetzt: Nach der tatsächlichen 3×3-Maskenerweiterung enthält Pflichtfall 05 bereits keine Erhaltzelle mehr und das SDK überspringt diesen Pfad. Eine kleine native CPU-Probe dokumentiert diese Ausschlussdiagnose ohne Modelllauf. Sie kann mit einem gepinnten Offline-Archiv in einem neuen Ausgabeordner reproduziert werden:

```sh
python3 -B tools/sdxl-evaluation/probe_denoise_mask.py --help
```

Der Runner benötigt die extern vorhandene Pflichtmaske über `--mask-fixture /private/tmp/picedit-fixture-archive/fixtures/05-fine-motif-edges-mask-hard.png` und prüft Archiv, Quellvertrag und Fixture vor der Kompilierung. Die breite Kontrollmaske prüft, dass die Bedingung nicht stets falsch ist.

Builder, Konverter und Swift-Harness verlangen für neue Ausführungen zusätzlich `sdkScheduleBaselineReproduced`, `sdkScheduleRegressionPassed`, `sdxlSchedule = euler-leading-strength099-v1` und die Hashes des Zeitplan-Headers sowie des nativen Regressionstests. Der Test prüft den tatsächlichen SDK-Zeitplan, die tatsächliche öffentliche Übergabe und die quellgeprüfte Formel der nachfolgenden Stärkeauswahl. Diese kleine Probe führt den privaten VAE-Bildpfad nicht aus; dessen tatsächliche Schrittzahl muss zusätzlich das Inferenzlog bestätigen. Bestehende V9-Receipts autorisieren keine neue V10-Ausführung.

Ein frischer privater Root und neue Ausgabeordner bewahren frühere Nachweise. Zuerst wird nur Pflichtfall 05 erzeugt; bei Qualitätsfehler endet der Kandidat als No-Go. Erst ein bestandener Pflichtfall rechtfertigt die vollständige Serie einschließlich Abbruch- und Vorschauprüfung. Alle Zeit-, Speicher- und Produktgates gelten unverändert.

```sh
python3 -B tools/sdxl-evaluation/prepare.py --root /private/tmp/picedit-sdxl-qualification-v10 --offline --source-cache /private/tmp/picedit-sdxl-qualification-v9/inputs
python3 -B tools/sdxl-evaluation/build_native.py --root /private/tmp/picedit-sdxl-qualification-v10 --build --mask-fixture /private/tmp/picedit-fixture-archive/fixtures/05-fine-motif-edges-mask-hard.png --cmake /absolute/path/to/cmake
python3 -B tools/sdxl-evaluation/convert.py --root /private/tmp/picedit-sdxl-qualification-v10 --convert
./scripts/evaluate-image-generation.sh sdxl --run --fixture-archive /private/tmp/picedit-fixture-archive --probe-case 05-fine-motif-edges-hard --root /private/tmp/picedit-sdxl-qualification-v10 --out /private/tmp/picedit-sdxl-v10-fine-edges
```

## Fortsetzung V9: isolierte Masken- und Abbruchqualifikation

V9 ergänzte eine getrennte **Maskenvariante**, die in V10 erhalten bleibt. Die [gehashte Diffusers-Referenz](provenance/reference-mask-semantics.json) verwendet gewöhnliches Nearest-Sampling für den UNet-Maskenkanal. Das bisherige SDK-`NearestMax` verliert in Pflichtfall 05 sämtliche geschützten Latentzellen; die neue, ausschließlich für `VERSION_SDXL_INPAINT` gewählte Interpolation erhält 141 von 16.384 Zellen. Der [Patch](sdk-sdxl-mask.patch) ändert weder Originalgewichte, native Masken noch Denoise-Blending. Dies ist eine geprüfte Algorithmusabweichung und zunächst eine Qualitätshypothese, kein Produkt-Go.

**Die tatsächliche V9-Probe ist abgeschlossen und bleibt No-Go:** Nach 163,944 Sekunden sind weiterhin breite schwarze Konturen und helle Säume neben den feinen Erhaltlinien sichtbar. Zwei Sichtungen bestätigen den Pflichtfehler. Die separate Abbruchprobe bestätigt das Prozessende nach 4,067 Sekunden mit SIGKILL, jedoch ohne native kooperative Rückkehr. Entsprechend wird keine vollständige Wiederholungsserie oder Produktfreigabe behauptet. Die historische Entscheidung bleibt von V1–V8 getrennt.

Der neue [native CPU-Test](sdxl_mask_regression.cpp) prüft die unveränderte Baseline, den tatsächlichen gepatchten SDK-Helfer, asymmetrische Koordinaten und unveränderte andere Modellpfade. Der Builder verlangt vor Veröffentlichung zusätzlich `sdkMaskBaselineReproduced`, `sdkMaskRegressionPassed`, `sdxlMaskInterpolation = nearest-v1` sowie Patch-, Test- und Fixturehashes. Konverter und Swift-Harness weisen alte Receipts für neue Ausführungen ab; historische Installationen und Rohberichte werden nicht umgeschrieben. Ein neuer privater Root mit erneut geprüften Eingaben ist erforderlich.

Zuerst wird ausschließlich dieselbe eingefrorene Pflichtfixture 05 erneut erzeugt. Nur bei ausreichendem Ergebnis folgt eine vollständige Serie. Die separate Abbruchprobe liefert unabhängig davon Messwerte zum Prozessende:

```sh
./scripts/evaluate-image-generation.sh sdxl --run --fixture-archive /private/tmp/picedit-fixture-archive --probe-case 05-fine-motif-edges-hard --root /private/tmp/picedit-sdxl-qualification-v9 --out /private/tmp/picedit-sdxl-v9-fine-edges
./scripts/evaluate-image-generation.sh sdxl --run --fixture-archive /private/tmp/picedit-fixture-archive --cancellation-only --root /private/tmp/picedit-sdxl-qualification-v9 --out /private/tmp/picedit-sdxl-v9-cancellation
```

`--probe-case` wählt genau einen bekannten Fall einschließlich Maskenart; dieser Lauf behauptet keine warmen Wiederholungen oder parallele Vorschau. `--cancellation-only` führt keine vollständige Vorhersage- oder Replayserie aus. Beide benötigen das ausdrückliche `--run`; numerische Diagnose und diese Probenmodi sind gegenseitig ausgeschlossen. `qualificationScope` hält den tatsächlichen Umfang fest. Die historische V9-Zusammenfassung oben ist von V1–V8 getrennt.

Alle SDXL-Abbruch-/Fehler-/Schließpfade teilen jetzt die erste absolute Fünfsekundenfrist. Ein unabhängiger Wächter versucht nach vier Sekunden SIGKILL und misst bis zur Rückkehr von `Process.waitUntilExit`, vor dem Leeren der Logreader. Auch bei Fristüberschreitung bleibt die Ressourcenlease bis zum tatsächlichen Ende belegt. Blockierendes Schreiben an den Helper darf den Wächter nicht blockieren. `cancelGatePassed` verlangt weiterhin eine kooperative `cancelled`-Rückkehr und bestätigtes Ende innerhalb der unveränderten Frist. `cancelProcessContainmentGatePassed` kann auch bei ausdrücklich ausgewiesener erzwungener Beendigung bestehen; es erteilt kein kooperatives oder Produkt-Go. Beide Probe-Gates verlangen den tatsächlich beobachteten Fortschrittsauslöser; ein Fehler vor diesem Auslöser kann nur Aufräumwerte liefern. Der SDK-Callback kann Laden oder VAE melden und beweist keinen bestimmten UNet-Schritt.

Modellfreie Prüfungen verwenden echte kleine Testprozesse für Kooperation, blockierte Writes, gebrochene Pipes, hängendes Aufräumen, Wiederholungsaufrufe und Ressourcenfreigabe:

```sh
./scripts/test.sh --jobs 3 --filter NativeProcessCancellationTests
python3 -B -m unittest discover -s tools/sdxl-evaluation -v
```

## Identität und getrennte Vorbereitung

`package.json` pinnt Originalgewichte und Metadaten von `diffusers/stable-diffusion-xl-1.0-inpainting-0.1` in Revision `115134f363124c53c7d878647567d04daf26e41e`, SDK `8cd731e7b4667eb8f40a153315b9a7125d09a58d` und GGML `d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93`. 22 Dateien umfassen **7.071.154.004 Byte**, davon vier F16-Gewichtsdateien mit **6.938.041.649 Byte**. Jede Datei besitzt exakte Länge und SHA-256. Keine Gewichte, SDK-Archive oder Binärdateien werden im Repository verteilt.

Die unveränderte [Modellkarte](provenance/MODEL-CARD.md), der von ihr verknüpfte [CreativeML-Open-RAIL++-M-Lizenztext](provenance/LICENSE-weights.txt) und die [gepinnten Herkunftsbezüge](provenance/metadata-source.json) sind erhalten. Der Lizenztext kommt aus der dort verknüpften SDXL-Base-Revision; das Inpainting-Repository enthält keinen eigenen Lizenztext. Die SDK-/Drittanbieterhinweise stehen unter [image-generation-evaluation](../image-generation-evaluation/THIRD-PARTY-NOTICES.txt). Attribution und Bedingungen müssen bei einer späteren Installation oder Weitergabe mitgeführt werden.

Der lokale [SDK-Patch](sdk-sdxl-inpaint.patch), SHA-256 `bb91dc6b5868b9c9db264c416a5695973280b4e29c7667f123819295788fe4ce`, korrigiert vor dem generischen `te.`-Mapping ausschließlich den Diffusers-Präfix `te.1.` des zweiten Textencoders. Der kanonische Name beginnt damit korrekt mit `cond_stage_model.1.transformer.`. Tensorarchitektur und Modellversion werden nicht erzwungen. Ein separater [Metadaten-Regressionstest](sdk_name_regression.cpp) prüft die tatsächlichen Konvertierungs- und Erkennungsfunktionen des gepinnten SDK für SDXL mit vier und neun Eingangskanälen sowie SD-1-Inpainting. Er lädt keine Gewichte und erzeugt keinen Modellkontext. Der Helper selbst verwendet weiterhin nur die öffentliche SDK-API.

Der zusätzliche [GGML-Metal-Patch](ggml-metal-group-norm.patch) korrigiert `GROUP_NORM` für die vierte Tensorachse: Dispatch und Kerneladressierung berücksichtigen jeden Batch. Der [native GPU-Regressionstest](ggml_group_norm_regression.cpp) führt dieselbe kleine Operation vor und nach der Korrektur aus und vergleicht sie mit der CPU-Referenz. In der unveränderten Basis stimmen die Werte des ersten Batches; alle 2.240 Werte jedes Folgebatches bleiben dagegen beim zuvor gesetzten NaN-Sentinel, insgesamt 6.720 Werte über die Fälle N=2 und N=3. Nach der Korrektur sind alle geprüften Werte für N=1, N=2 und N=3 finit; der größte absolute Fehler zur CPU-Referenz beträgt `3.5762787e-7`. Das belegt die korrigierte Operation für diese Fälle und ersetzt keinen vollständigen SDXL-Produktnachweis.

Python 3 und für den nativen Build CMake sowie Apple Command Line Tools sind nötig. Ziel ist Apple Silicon mit macOS 14+ und mindestens 16 GiB physischem Speicher. Genügend Platz für Originaldateien, Konvertierung und isolierte Builds vorsehen; die heruntergeladene Dateigröße ist kein Maß für den späteren Arbeitsspeicherverbrauch. Das Evaluationsverzeichnis muss außerhalb des Repositorys liegen und dem Benutzer gehören. Für die Konvertierung ist ein privates Verzeichnis mit Modus `0700` erforderlich. Ein neu angelegter Installer-Root erhält diesen Modus; ein bereits vorhandener Root darf nicht für Gruppe oder andere zugänglich sein.

Ohne Aktionsflag zeigen Installer und Konverter nur einen Plan, lesen keine Modellgewichte, starten kein Modell und erzeugen keinen Root:

```sh
python3 -B tools/sdxl-evaluation/prepare.py
python3 -B tools/sdxl-evaluation/convert.py
```

Jeder tatsächliche Schritt ist ein eigener ausdrücklicher Aufruf:

```sh
python3 -B tools/sdxl-evaluation/prepare.py --root /private/tmp/picedit-sdxl --download
python3 -B tools/sdxl-evaluation/build_native.py --root /private/tmp/picedit-sdxl --build --mask-fixture /private/tmp/picedit-fixture-archive/fixtures/05-fine-motif-edges-mask-hard.png --cmake /absolute/path/to/cmake
python3 -B tools/sdxl-evaluation/convert.py --root /private/tmp/picedit-sdxl --convert
```

Der Download überlappt höchstens zwei Übertragungen und publiziert die vollständig gehashten Eingaben atomar als `<root>/inputs/`. Bestehende Eingaben werden nicht überschrieben. `--offline --source-cache /absolute/path/to/cache` verwendet einen Cache mit denselben relativen Zielpfaden wie `package.json`; fehlende/falsche Dateien führen ohne Netzfallback zum Fehler. Symbolische Links, Hardlinks und spezielle Quelldateien werden abgewiesen.

Der [Builder](build_native.py) liest nur lokale gehashte Archive und extrahiert einen frischen privaten Quellbaum. `--source-cache /absolute/path/to/archives` kann einen vorhandenen SDK-Archivcache verwenden, auch während der unabhängige Modelldownload läuft. Er baut mit zwei Jobs; fremde Dateien und aktive Locks bleiben erhalten. Ein fertiger Helper oder vorhandenes Buildlog wird nicht überschrieben. Er prüft zuerst die reproduzierte GPU-Baseline, anschließend die korrigierte GPU-Operation und den tatsächlichen SDK-Namensvertrag. Nach dem Helperbuild prüft ein nativer Selbsttest die numerische Diagnose mit öffentlichen CPU-Tensoren sowie das Zurücksetzen des Callbacks durch RAII. Erst danach erscheint `native-installation.json`.

Dieser Nachweis enthält SDK-/GGML-Revisionen, Helper- und Quellhashes sowie `sdkPatchSHA256`, `sdkNameRegressionSourceSHA256`, `sdkNameRegressionPassed`, `ggmlPatchSHA256`, `metalGroupNormRegressionSourceSHA256`, `metalGroupNormBaselineReproduced`, `metalGroupNormRegressionPassed`, `numericDiagnosticSelfTestPassed` und `publicHelperSDKAPIOnly`. Die kleinen GPU-Tests verwenden keine Modellgewichte und erzeugen keinen Bildgenerierungskontext.

Die [Offline-Konvertierung](convert.py) nutzt ausschließlich den selbst gebauten Helper und die erneut geprüften Originaleingaben. Vor dem Prozessstart werden beide Patches und die Regressionsquellen gegen ihre lokalen Hashes geprüft; der bestandene SDK-Test, die reproduzierte Metal-Baseline und der bestandene korrigierte GPU-Test sind Pflicht. Alte Receipts bleiben historische Belege und autorisieren keine Konvertierung mit der korrigierten Toolversion. Der öffentliche SDK-Konverter exportiert tensorweise Q8_0 mit einer expliziten F32-Regel für VAE-Gewichte und höchstens zwei Threads. Das ist keine Zusage, dass jeder Tensor Q8 oder jeder VAE-Tensor F32 ist: Bias-, Embedding- und blockinkompatible Tensoren können ihren Typ behalten. Das gepinnte Original-VAE deklariert bereits `madebyollin/sdxl-vae-fp16-fix`, `force_upcast=false` und Skalierung 0,13025; F32 ist eine eigene konservative Einstellung.

Der Konverter hat eine separate Vorbereitungsfrist von 600 Sekunden. Nach erfolgreicher tatsächlicher Prozessrückkehr werden der Zielhash und der native Bericht als `conversion.json` festgehalten. Rohlogs bleiben erhalten. Fehler oder Timeout erzeugen keinen Erfolgsnachweis; bereits vorhandene Ausgaben werden nicht ersetzt. Ein vollständiger neuer Versuch erhält einen neuen privaten Root. `conversion.json` und `native-installation.json` sind gemeinsam aufzubewahren.

Der modellfreie Headerinspektor liest standardmäßig ungepuffert höchstens 64 MiB Header und keine Tensorinhalte. Er erfasst tatsächliche Typen, Eingangs-Convolution und deklarierte Dateibereiche. Nur das ausdrückliche Flag `--sha256` liest zusätzlich die vollständige Datei für einen Hash:

```sh
python3 -B tools/sdxl-evaluation/inspect_gguf.py /private/tmp/picedit-sdxl/model-q8_0.gguf
```

Der tatsächlich geprüfte Export enthält **2.643 Tensoren: 1.350 Q8_0, 1.167 F16, 124 F32 und zwei I32**. Im VAE sind alle 124 Nicht-Bias-Tensoren F32 und alle 124 Bias-Tensoren F16. Die beiden I32-Tensoren sind die `position_ids` der Textencoder. Die Eingangs-Convolution besitzt GGML-Dimensionen `[3,3,9,320]`, entsprechend OIHW `[320,9,3,3]`. Diese Headerprüfung belegt weder Tensorinhalte noch Bildqualität oder eine durchgehend gleiche Rechenpräzision.

Insbesondere initialisiert die tatsächliche gepinnte [SDK-Klasse `Conv2d`](https://github.com/leejet/stable-diffusion.cpp/blob/8cd731e7b4667eb8f40a153315b9a7125d09a58d/src/model/common/ggml_block.hpp#L517-L524) ihre Gewichte als F16, unabhängig vom Typ der gespeicherten GGUF-Tensoren. Ein Logeintrag mit etwa 96,47 MB Decoderparametern belegt deshalb keinen F32-Runner. Die F32-Konvertierungsregel und die Header-Typen sind von der tatsächlichen Ausführung zu unterscheiden; eine durchgehend vollständige F32-Ausführung wurde nicht nachgewiesen.

## Eigene SDXL-Konfiguration und Messung

Für echte Bildläufe ist `--fixture-archive` mit einem extern vorhandenen Archivbaum (`provenance/fixtures-manifest.json` und `fixtures/`) erforderlich. Die gepinnten Originalhashes bleiben verbindlich; neu erzeugte Contract-Fixtures ersetzen das historische Archiv nicht. Der native Builder benötigt daraus die Pflichtmaske über `--mask-fixture`.

Die Probe verwendet **1024×1024**, 20 nominale Euler-Schritte, CFG 8, Seed 4281 und Stärke 0,99. V10 führt daraus nach Referenz-Stärkeauswahl tatsächlich 19 Schritte aus; ältere Varianten führten 20 aus. Native Fixturepixel werden ohne Skalierung durch eine zentrierte ganzzahlige Translation eingebettet. Gerades RGB und die binäre Modellmaske verwenden denselben Clamp-Sampler einschließlich künstlichen Paddings. Quellalpha und native Softmaske bleiben separat für das finale Compositing.

Die ab V5 untersuchte Ausführungsvariante verwendet gebündelte CFG-Berechnung (`batchedCFG=true`) und ein angefordertes SDK-Limit von 5 GiB für verwalteten GPU-Speicher. Diffusion und VAE verwenden Metal, der Textencoder läuft auf der CPU mit Parametern vom Datenträger. Die Modellparameter, 20 Schritte und übergreifende Grenze von 6 GiB bleiben unverändert. Das SDK-Limit ersetzt keine Prozessspeicherprüfung und ist keine Betriebssystemquote.

Die abgeschlossene V8-Konfiguration verwendet VAE-Tiles von 640×640 Pixeln. Der tatsächliche Plan umfasst vier Tiles mit Startkoordinaten 0 und 384 je Achse, also 256 Pixel wirksame Überlappung. Die Gewichts- und übrigen Modellparameter bleiben erhalten; V8 prüfte die korrigierte Metal-Operation ohne numerische Callbacks.

```sh
./scripts/evaluate-image-generation.sh sdxl --run --fixture-archive /private/tmp/picedit-fixture-archive --all-fixtures --root /private/tmp/picedit-sdxl --out /private/tmp/picedit-sdxl-probe
```

Ohne `--run` wird bereits der vorgeschaltete Entwicklerbuild abgewiesen. Der neue Berichtsordner darf nicht existieren. Der explizite SwiftPM-Entwicklerbuild kann gepinnte Paketabhängigkeiten abrufen, lädt aber keine Modelle. Ohne `--all-fixtures` wird nur das erste Bild mit drei warmen Wiederholungen und technischer Abbruch-/Vorschauprobe untersucht; dies reicht für kein vollständiges Qualitäts-Go.

`criteria.json` legt die Grenzen vor der Inferenz fest: 6 GiB kombinierter Prozessspeicher, 45 s Modellladen, 180 s je Vorhersage, 240 s für den kalten Start und 5 s vom Abbruch bis zum nativen Ende. Ressourcenlease und Helperprozess werden erst nach tatsächlichem Ende freigegeben. Peak-RSS und Footprint werden bei nativen Protokollereignissen geprüft. Die künstliche 256²-Vorschauprobe verlangt echte Samples in beiden Phasen, P95 ≤ 250 ms und höchstens 2× Baseline. Sie ist kein Ersatz für den noch notwendigen Produktvorschau- und RAW-Nachweis.

Der [Swift-Evaluator](../../Sources/PicEdit/DeveloperTools/ImageGenerationEvaluation.swift) prüft die Build-, Patch- und Regressionsnachweise vor dem Modellstart. Eine ausdrückliche numerische Diagnose verwendet genau einen Fall und die öffentliche SDK-Callback-Schnittstelle:

```sh
./scripts/evaluate-image-generation.sh sdxl --run --fixture-archive /private/tmp/picedit-fixture-archive --numeric-diagnostic --root /private/tmp/picedit-sdxl --out /private/tmp/picedit-sdxl-numeric
```

Der [native Helper](helper.cpp) liest an bis zu fünf fest benannten Verarbeitungsgrenzen jeweils höchstens 256 F32-Werte zurück, also 1 KiB pro Grenze. Er untersucht erste Tiles und den ersten gebündelten UNet-Ausgang; ungesampelte Werte, weitere Tiles und spätere Schritte bleiben ungeprüft. Fehlt eine erwartete Grenze oder enthält eine Stichprobe einen nichtfiniten Wert, wird kein Ergebnis-PNG veröffentlicht. Die Callback-Registrierung wird durch RAII auch auf Fehlerpfaden zurückgesetzt; der native Selbsttest muss für diesen Diagnosemodus nachgewiesen sein. Die zusätzlichen Synchronisierungen machen diese Diagnose ungeeignet für repräsentative Laufzeitvergleiche, warme Wiederholungen oder eine Produktfreigabe.

Das Modell verarbeitet die Fälle seriell, damit keine weiteren Modellkopien oder konkurrierende Benchmarks die Messung verfälschen. Erstlauf bedeutet neuer Prozess/Modellkontext; Betriebssystem-/Datei-/Shadercaches werden nicht geleert. Der anschließende aktuelle Compositor verwendet die originalen nativen Softmasken und stellt Quellalpha wieder her. Alle finalen Erhaltpixel müssen bytegleich bleiben. Rohbilder und endgültige visuelle Qualität werden getrennt beurteilt; fehlgeschlagene frühe Lade-/Ressourcenprüfungen liefern keine behaupteten Bildqualitätsresultate.

Manuelles Replay benötigt keine Inferenz. `sdxl-report.json.preprocessingVersion=1` bestimmt die Straight-RGB-Provenienz; unbekannte Versionen und widersprüchliche Berichtstypen werden abgewiesen:

```sh
./scripts/evaluate-image-generation.sh replay --historical /private/tmp/picedit-sdxl-probe --out /private/tmp/picedit-sdxl-replay
```

Modellfreie Prüfungen:

```sh
python3 -B -m unittest discover -s tools/sdxl-evaluation -v
PICEDIT_TEST_BUILD_PATH=/private/tmp/picedit-sdxl-tests ./scripts/test.sh --filter SDXLEvaluationRasterTests
./scripts/test-developer-tools.sh
```

Die zusätzliche CLI-Prüfung verwendet einen bereits gebauten Entwickler-Executable:

```sh
python3 -B tools/sdxl-evaluation/probe_replay_cli.py --binary /absolute/path/to/PicEdit --archive /private/tmp/picedit-lama-v2
```

Sie prüft die tatsächlich gespeicherten Fall-IDs, die beobachtbare Straight-RGB-/Alpha-Behandlung und das Abweisen fehlerhafter Replay-Metadaten. Dazu benötigt sie einen extern vorhandenen LaMa-V2-Ergebnisbaum mit `native/artifacts/` und `compositor/current-compositor-report.json` (`--archive`) und verpackt dessen Ausgabebilder ausdrücklich in synthetische SDXL-Metadaten. Sie baut und lädt kein Modell und führt keine Inferenz aus. Ihre Ergebnisse sind ausschließlich ein CLI-/Compositor-Vertragstest, kein SDXL-Qualitäts- oder Laufzeitnachweis. Temporäre Prüfdateien und Protokolle bleiben im ausgegebenen Prüfverzeichnis erhalten.

## Stand der tatsächlichen Prüfung

Die folgenden historischen Versuche sind hier zusammengefasst; ihre Quellenkopien, Rohprotokolle und Ergebnisdateien sind im aktuellen Repository nicht mehr enthalten:

| Versuch | Tatsächlicher Stand |
| --- | --- |
| V1 | Laden fehlgeschlagen; kein Bild erzeugt. |
| V2 | Diagnose desselben Modells: falsche SD-1.x-Erkennung infolge des zweiten Textencoder-Präfixes; kein Bild erzeugt. |
| V3 | Mit SDK-Korrektur und bestandenem SDK-Regressionstest als `SDXL Inpaint` geladen; VAE auf der CPU. Erste Vorhersage überschritt die Frist von 180 s, kein fertiges Bild. Prozessende bestätigt. |
| V4 | VAE und Diffusion auf Metal, CFG weiterhin ungebündelt und angefordertes verwaltetes GPU-Budget 4 GiB. Erste Vorhersage überschritt dieselbe Frist; kein fertiges Bild. Prozessende bestätigt. |
| V5 | Gebündelte CFG-Berechnung und 5 GiB angefordertes verwaltetes GPU-Budget; erste Vorhersage überschritt 180 s, kein fertiges Bild. |
| V6 | Erste Vorhersage abgeschlossen: 165,228 s, kalt einschließlich Laden 165,519 s. Der native Crop ist exakt deckend weiß; der aktuelle Compositor erzeugt einen weißen Kreis statt der fortgesetzten Holztextur. Diese Konfiguration besteht den ersten erforderlichen Qualitätsfall nicht. |
| V7 | Öffentliche Float-Callbacks: beide VAE-Encoder-Stichproben mit je 256 Werten finit; am ersten gebündelten UNet-Ausgang 128 Stichproben des ersten Batches finit und 128 des zweiten Batches NaN. Kontrollierter Stopp ohne PNG. Die Diagnosezeit ist kein repräsentativer Benchmark. |
| V8 | Alle zehn Vorhersagen abgeschlossen, einschließlich drei identischer warmer Wiederholungen und aktuellem Compositor-Replay. Qualitätsfall 05 und Abbruchgate fehlgeschlagen: No-Go für diese Konfiguration. |

V1 und V2 verwenden den Export mit SHA-256 `55570c0dd79d37cd4d4e44a1e2c7613c161e4ac6385215705968593d0825226e`. Die Namenskorrektur ergibt ab V3 den neu aus den gleichen Originaleingaben konvertierten Export mit SHA-256 `2e0d24d76de6557144948429e7e86ca2d0a03aa920402529cef1df6665c72531`. Die Quellenpinning- und Qualitätsgrenzen wurden dabei nicht gelockert.

Für den historischen Versuch V6 bestätigt der kanonische RGBA8-Hash `f5fb04aa5b882706b9309e885f19477261336ef76a150c3b4d3489dfac3953ec` den exakt weißen nativen Crop. Das damalige Compositor-Replay und visuelle Review prüften 244.263 Erhaltpixel: kein RGBA-Byte außerhalb der Ersetzungsmaske und kein Quellalpha-Byte wurde verändert. Der weiße Kreis war ein klarer Qualitätsfehler dieser Ausgabe. Das RGB8-Ergebnis allein lokalisierte seine Ursache nicht. V7 belegte anschließend NaN-Stichproben in einem UNet-Batch; der separate kleine GPU-Test reproduzierte den unbehandelten Folgebatch bei Metal-`GROUP_NORM`. V8 lieferte nach der Korrektur echte Bildinhalte statt dieser Weißausgabe. Daraus folgt keine pauschale Qualitätsaussage über die Modellfamilie und kein Nachweis einer durchgehend vollständigen F32-Ausführung.

Die V6-Serie wurde nach ihrem ersten fehlgeschlagenen Pflichtbild per SIGINT gestoppt. Der Helper endete tatsächlich, die Ressourcenlease blieb bis zu diesem Ende gehalten. Die seinerzeit fehlenden warmen Wiederholungen und weiteren Pflichtbilder wurden erst mit V8 untersucht; die damaligen V6-Protokolle wurden mit den historischen Berichten entfernt.

## Abgeschlossene V8-Messung und Entscheidung

Die zehn nativen Vorhersagen dauerten **155,131–161,166 s** und lagen damit jeweils innerhalb der unveränderten 180-s-Grenze. Die drei warmen Wiederholungen desselben Falls lieferten identische Raw-PNGs. Der als „kalt“ bezeichnete Wert von **161,525 s** umfasst ausschließlich Helperstart, Modellladen und Rückkehr der ersten Vorhersage. Die vorherige Verifikation/Vorbereitung von **5,716 s**, natives Zuschneiden und Compositing sind darin nicht enthalten. Betriebssystem- und Shadercaches wurden nicht geleert.

Der berichtete kombinierte Speicherhöchstwert beträgt **3.757.559.360 Byte**. Er addiert den größeren berichteten Helper-Höchstwert aus RSS oder Footprint und den Driver-Peak-RSS und bleibt unter 6 GiB. Er ist eine Prozessmessung mit dem beschriebenen Abtastumfang, keine Betriebssystemquote oder systemweite GPU-Speichererfassung.

Die synthetische Vorschauprobe lieferte 31 Baseline- und 1.555 parallele Samples. P95 betrug 12,955 ms ohne und 10,734 ms während der Inferenz; das definierte synthetische Gate ist damit erfüllt. Das sind weder echte Produktvorschauen noch RAW-Messungen, und die Werte belegen keine allgemeine Beschleunigung durch Inferenz.

Das damalige visuelle Review dokumentierte den eindeutigen Qualitätsfehler von Fall 05: Neu erzeugte breite schwarze Zweige und helle Säume um die erhaltenen grünen Motivlinien ersetzen die feinen Kanten. Die beige Hintergrundfläche entspricht dem Prompt; die zusätzlichen Konturen verletzen das Gate. Fall 01 wurde von den Reviewern unterschiedlich bewertet, bei 02 und 03 sind Nähte erkennbar. Fall 06 erzeugt zusätzliche Rahmen, Paneele und blaue Rechtecke statt nahtloser Fortsetzung; er ist ausschließlich eine Canvas-Diagnose und begründet keine Outpainting-Freigabe. Das aktuelle Compositing erhält in allen zehn Fällen die geprüften RGBA-Bytes außerhalb der Ersetzungsmaske und die Quellalpha-Bytes unverändert. Dieser technische Erhalt ersetzt keine visuelle Qualitätsprüfung.

Auch das Abbruchgate ist nicht bestanden: Innerhalb von 5 s lag keine abgeschlossene native Abbruchrückkehr vor. Nach Timeout und begrenztem Herunterfahren wurde der Helper per SIGKILL beendet; Exit 9 und das tatsächliche Einsammeln des Prozesses sind bestätigt. Ein Abbruch-PNG wurde nicht publiziert. Die genaue Gesamtdauer vom Abbruch bis zum Prozessende wurde nicht aufgezeichnet; daraus darf kein bestandener Prozess-Endzeitnachweis abgeleitet werden. Die Ressourcenlease blieb bis zum tatsächlichen Ende gehalten.

Damit besteht für V8 trotz abgeschlossener Vorhersagen und bestandener Zeit-, Speicher- und synthetischer Vorschauprüfungen **kein Produkt-Go**. Die Produktroute bleibt unavailable; #13–16 bleiben offen. Ein nachfolgender Kandidat oder eine korrigierte Route muss Qualität und Abbruch erneut nachweisen und anschließend durch den tatsächlichen Produktadapter sowie die Produktvorschauprüfung gehen.
