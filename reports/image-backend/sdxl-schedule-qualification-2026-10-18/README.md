# SDXL V10: gepinnter Euler-Zeitplan

**Ergebnis vom 18. Oktober 2026: weiterhin No-Go.** Zwei unabhängige Sichtungen bestätigen breite dunkle Konturen und helle Säume neben den erhaltenen grünen Linien.

Dieser Versuch setzt die lokale Qualifikation nach dem [V9-No-Go](../sdxl-mask-qualification-2026-10-18/README.md) fort. Die Produktfähigkeiten bleiben gesperrt; der Versuch implementiert oder schließt Issue #14 nicht.

## Vorab begrenzter Versuch

Der einzige geänderte Bildfaktor ist der Euler-Rauschzeitplan einschließlich der modellgemäßen Auswahl anhand der Stärke. Die gepinnte Konfiguration nennt `leading`, Offset 1, 20 nominale Schritte und Stärke 0,99. Daraus folgen 19 tatsächliche Schritte bei Trainingszeitpunkten 901, 851, …, 1 und abschließend Sigma 0. Die vorherige SDK-Auswahl nutzte 20 Schritte von 999 bis 0. Die Werte werden über die öffentliche `custom_sigmas`-API übergeben; ein zusätzlicher SDK-Patch ist nicht erforderlich.

Die [Referenzherkunft](provenance/reference-scheduler-semantics.json) enthält Quellrevisionen, Bytehashes und genaue Fundstellen. Ausgewählte unveränderte Scheduler-Anweisungen wurden unabhängig mit CPU-PyTorch ausgeführt; ihr [numerischer Nachweis](provenance/reference-scheduler-numeric.json) belegt die Float32-Sigmas. Dies ist keine Ausführung der gesamten Diffusers-Pipeline und kein Beweis pixelgleicher Ergebnisse. Der native Test verwendet den tatsächlichen SDK-SamplePlan und seine Sigma-zu-Zeitschritt-Abbildung: Die Baseline reproduziert 20 Schritte ab 999; die neue Übergabe erhält alle 19 Referenz-Sigmas unverändert. Der größte Fehler der SDK-Zeitschrittrückrechnung beträgt 0,000213623 und bleibt unter der vorgegebenen Toleranz 0,002. Die private Stärkeauswahl wird als quellgeprüfte Formel untersucht; der Test lädt keine Modellgewichte und führt keinen VAE-Encode aus.

Originalgewichte, eigene Q8-Konvertierung, CFG 8, Seed 4281, Prompts, Nearest-Maskenraster, native Abbildung, Kachelung und finale Komposition bleiben erhalten. Die [vor Inferenz archivierten Kriterien](provenance/criteria.json) verlangen zuerst denselben Pflichtfall 05. Bei dessen Qualitätsfehler endet dieser Kandidat ohne vollständige Wiederholungs-, Vorschau- oder Abbruchserie. Alle bestehenden Grenzen gelten unverändert.

Die zunächst erwogene Abschaltung der Original-Latent-Rückmischung wurde verworfen: Die native CPU-Probe findet 9.357 Erhaltpixel im Original, 141 nach Nearest und null nach der tatsächlichen 3×3-Erweiterung der Denoise-Maske. Das SDK überspringt die Rückmischung daher bereits. Es wurde kein wirkungsloser Blend-Patch eingeführt.

## Ausführung und Ergebnis

Der neue [Rohbericht](quality/sdxl-report.json), das [Modellbild](quality/artifacts/05-fine-motif-edges-hard/raw-model-1024.png) und der [beschriftete Vergleich](quality-compositor/05-fine-motif-edges-hard/current-comparison.png) bewahren die tatsächliche Ausgabe. Die [zwei visuellen Reviews](visual-review.json) bewerten den Pflichtfall als **FAIL**: Das blaue Rechteck verschwindet, neben den feinen grünen Linien entstehen jedoch breite schwarze Konturen mit hellen Säumen oder Schatten; zusätzlich setzt das Modell Zweige bis zum Bildrand fort. Ein horizontaler graubrauner Randstreifen bleibt. Die Änderung des Zeitplans genügt damit nicht für die geforderte Motivkantenqualität.

| Messung | Ergebnis und Grenze |
| --- | --- |
| Kontextladung | 0,2830 s; Lazy Loading bleibt möglich |
| Tatsächliche Vorhersage | 157,0546 s; ein einzelner Lauf, Grenze 180 s |
| Neuer Kontext plus Vorhersage | 157,3497 s; ohne vorangehende Eingabeprüfung und nachfolgendes Compositing |
| Tatsächliche Schrittzahl | 19; durch SDK-Regression und tatsächliche native Fortschritts-/Samplinglogs bestätigt |
| Konservativer kombinierter Peak | 3.761.933.960 Byte; Helper-Maximum aus RSS/Footprint plus Driver-Peak-RSS, Grenze 6 GiB |
| Native Ausgabe | 1024×1024, inverser ganzzahliger Crop auf 512×512 |
| Erhaltpixel | 9.357; kein geändertes kanonisches RGBA-Byte, kein geändertes Alpha-Byte, PNG-Roundtrip identisch |
| Qualitätsgate | **FAIL**; keine volle Wiederholungsserie |

Die [Messübersicht](measurement-summary.json) enthält die ungerundeten Werte. Ein frischer Helperkontext bedeutet keine geleerten Betriebssystem-/Shadercaches. Aus einem Lauf mit anderer Schrittzahl wird kein allgemeiner Geschwindigkeitsgewinn gegenüber V9 abgeleitet. Der Speicherwert ist keine vollständige GPU-Bilanz oder OS-Quote.

Der Gewichtexport ist bytegleich zu V9 (`2e0d24d76de6557144948429e7e86ca2d0a03aa920402529cef1df6665c72531`); [Konvertierungsnachweis](provenance/conversion.json). Der Helper endete nach der abgeschlossenen Vorhersage regulär mit Exit 0, und die Ressourcenlease blieb bis zum Ende gehalten. Dieses normale Schließen ist **keine Inferenz-Abbruchprobe**. V10 führt nach dem Qualitätsfehler weder die vollständige Serie noch eine neue Abbruchprobe aus. Das V9-No-Go für kooperativen Abbruch bleibt bestehen. Produktadapter, echte RAW-Vorschau und Fähigkeitsnachweise fehlen weiterhin; insbesondere #14 bleibt blockiert.

## Prüfung und Reproduktion

Die [Werkzeugdokumentation](../../../tools/sdxl-evaluation/README.md) beschreibt Vorbereitung und Einzelprobe. Die tatsächliche erfolgreiche Vorbereitung lief in `/private/tmp/picedit-sdxl-qualification-v10b`; alle Eingaben kamen aus dem vorhandenen geprüften Offline-Cache. Es gab keinen neuen Modelldownload oder Cloudaufruf. Modellläufe liefen seriell mit `caffeinate -i` und ohne konkurrierende Builds/Tests. Unabhängige Softwareprüfungen und Builds nutzten getrennte Verzeichnisse und begrenzte Jobbudgets.

Die erste native Testkompilierung scheiterte an der fehlenden SDK-Compilerdefinition `GGML_MAX_NAME=160`. Das [Fehlerlog](verification/initial-native-build/native-build.log) und die damaligen geänderten Quellen sind erhalten. Nach Angleichung aller externen Helper-/Testübersetzungseinheiten an das gepinnte SDK bestand der Build im frischen V10b-Root. Es wurde vor diesem Fehler kein Helper veröffentlicht und keine Inferenz ausgeführt. Die Änderung der Compilerdefinition betrifft die ABI-Konsistenz; die vom Helper verwendeten Tensorfelder liegen vor dem Namensfeld.

Final bestanden 707 App-Tests, 331 Core-Tests mit insgesamt 18 vorgesehenen Skips, 43 Python-Tests sowie die Shell-Opt-in-Prüfungen. Die echten nativen Zeitplan-, Masken-, SDK-Namens-, Metal- und Diagnoseregressionen bestanden ebenfalls. Der vorgeschriebene [saubere vollständige App-Build](verification/clean-application-build.json) war erfolgreich; Plist und Signatur wurden geprüft. Details stehen in der [Softwareprüfübersicht](verification/software-checks.json). Das unabhängige finale Diffreview einschließlich Schnittstellen, Tests, Dokumentation und Belegen ist ohne offene Befunde abgeschlossen. Es wurden keine unabhängigen Fehler gefunden, die ein eigenes Issue erfordern.

Die [Quellidentitäten](provenance/source-identity.json) binden die Inferenz an die archivierten Dateien. Rohberichte V1–V9 bleiben unverändert; Gewichte und ausführbare Binärdateien werden nicht im Repository verteilt.
