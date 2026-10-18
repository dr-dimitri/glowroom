# SDXL V9: Referenz-Maskenraster und absolute Abbruchfrist

**Ergebnis vom 18. Oktober 2026: No-Go der geprüften V9-Konfiguration.** Der verpflichtende Fall mit feinen Motivkanten verfehlt weiterhin die Bildqualität. Eine getrennte tatsächliche Abbruchprobe bestätigt das Ende des Helperprozesses nach 4,0673 Sekunden, jedoch nur mit SIGKILL und ohne kooperative native Rückkehr. Dies ist ein bestandener begrenzter Prozess-Containment-Nachweis, kein bestandenes natives Abbruchgate oder Produkt-Go. Issues #13–16 bleiben offen; insbesondere ist Hintergrundersatz aus #14 nicht implementiert oder freigegeben.

## Vorab begrenzter Versuch

Die Fortsetzung verwendet dieselben gepinnten Originalgewichte, dieselbe eigene Q8-Konvertierung, dieselben eingefrorenen Bilder/Masken, Prompts, Seed 4281 und 20 Euler-Schritte mit CFG 8 und Stärke 0,99 wie [V8](../sdxl-inpainting-2026-10-18/README.md). Es gibt keinen Cloudaufruf und keinen neuen Modelldownload. Der neue Export ist mit SHA256 `2e0d24d76de6557144948429e7e86ca2d0a03aa920402529cef1df6665c72531` bytegleich zum V8-GGUF. SDK, GGML, Originalmodell und Lizenzen bleiben über das [Paket](provenance/package.json), die [unveränderte Modellherkunft](../../../tools/sdxl-evaluation/README.md) und den [Konvertierungsnachweis](provenance/conversion.json) nachvollziehbar. Gewichte und ausführbare Dateien werden nicht im Repository verteilt.

Ein tatsächlicher SDK-CPU-Test zeigt: `NearestMax` macht bei Fixture 05 alle 16.384 Latentmaskenzellen zu Ersetzungszellen; keine Erhaltzelle bleibt. Die gewöhnliche Nearest-Interpolation der [gehashten Diffusers-Referenz](../../../tools/sdxl-evaluation/provenance/reference-mask-semantics.json) erhält 141 Zellen. Der [isolierte Patch](provenance/sdk-sdxl-mask.patch) ändert ausschließlich die Wahl der Maskeninterpolation für `VERSION_SDXL_INPAINT`. Andere Modelle, Maskenencoding, Denoise-Blending, Gewichte, native Einbettung und finale Kompositionsmaske bleiben gleich. Dies ist eine belegte Abweichung der Vorbereitung, kein Beweis, dass sie alle V8-Bildfehler verursacht.

Die [vor dem Modelllauf archivierten Kriterien](provenance/criteria.json) verlangen zuerst dieselbe Pflichtfixture 05. Nur bei bestandener Bildqualität würde die vollständige Qualitäts-/Kalt-/Warm-/Vorschau-Serie folgen. Der neue native Builder hat Baseline und Korrektur tatsächlich geprüft: [CPU-Maskenregressionen](provenance/native-regressions.json), [vollständiges Buildlog einschließlich CPU-/Metal- und SDK-Namensprüfungen](provenance/native-build.log), [Installationsnachweis](provenance/native-installation.json). Die [15 Quellidentitäten](provenance/source-identity.json) binden den gemessenen Arbeitsstand an die archivierten Quellen; die Basis ist `83f9973`, ergänzt um die hier dokumentierten Änderungen.

## Tatsächliche neue Einzelprobe

| Messung | Ergebnis | Geltungsbereich |
| --- | --- | --- |
| Native Kontextladung | 19,9249 s | Neue Helperinstanz; Betriebssystem-/Shadercaches nicht geleert, Lazy Loading weiterhin möglich |
| Vorhersage | 163,9438 s | Genau ein tatsächlicher Lauf von `05-fine-motif-edges-hard`, keine drei warmen Wiederholungen |
| Konservativer berichteter kombinierter Peak | 3.760.754.360 Byte | Helper-Maximum aus RSS/Footprint plus Driver-Peak-RSS; keine OS-Quote oder vollständige GPU-Speicherbilanz |
| Native Ausgabe / zurückgeführtes Bild | 1024×1024 / 512×512 | Zentrierte Einbettung und inverser nativer Crop; keine behauptete RAW-Auflösung |
| Geprüfte Erhaltpixel | 9.357 | Alle kanonischen RGBA-Bytes exakt; keine geänderten Alpha-Bytes; PNG-Roundtrip identisch |
| Pflichtfallqualität | **FAIL** | Breite schwarze Äste und helle Säume neben dünnen grünen Linien; zusätzliche Astfortsetzungen und graubrauner Streifen unten |

Der [unveränderte native Bericht](quality/sdxl-report.json), [Modellrohoutput](quality/artifacts/05-fine-motif-edges-hard/raw-model-1024.png), [aktuelle Komposition](quality-compositor/05-fine-motif-edges-hard/current-final.png) und [beschrifteter Vergleich](quality-compositor/05-fine-motif-edges-hard/current-comparison.png) erhalten die tatsächlichen Ergebnisse. Das [Compositor-Replay](quality-compositor/current-compositor-report.json) ist keine zweite Inferenz. Zwei unabhängige Sichtungen bestätigen das Qualitäts-No-Go; Einzelheiten und Bildhashes stehen im [visuellen Review](visual-review.json).

Der beige Hintergrund und das Entfernen des blauen Rechtecks reichen nicht: Die neuen schwarzen Konturen verletzen gerade den geforderten Erhalt feiner Motivkanten ohne Halo. Nach diesem Pflichtfehler wurde wie vorab festgelegt keine vollständige Wiederholungsserie gerechnet. Weitere Motive, Person/Haare, echte RAW-Vorschau, 16-Bit-/P3-Produktroute und Produktadapter wurden in V9 nicht qualifiziert. Es wird kein Leistungsgewinn gegenüber V8 behauptet.

## Tatsächliche separate Abbruchprobe

Alle neuen SDXL-Abbruch-/Fehler-/Schließpfade behalten die erste absolute Fünfsekundenfrist. Drei begrenzte Steuerthreads beobachten das Prozessende, überwachen die Frist und versenden Cancel/Shutdown unabhängig von möglicherweise blockierendem Protokoll-I/O. Es gibt weiterhin nur einen zugelassenen Modellprozess. Erzwungene Beendigung und native Kooperation sind getrennte Nachweise; eine bloße Schließaktion ohne beobachteten Fortschrittstrigger kann keines der Probe-Gates bestehen.

Die [neue Rohmessung](cancellation/sdxl-report.json) hat den tatsächlichen Fortschrittstrigger beobachtet. Nach **4,0028 s** wurde SIGKILL erfolgreich gesendet; `Process.waitUntilExit` bestätigte nach **4,0673 s** das Ende mit Signal/Exitstatus 9. Die Ressourcenlease blieb bis dahin gehalten. Es wurde kein Cancel-PNG publiziert. Eine native `cancelled`-Rückkehr wurde nicht beobachtet; ihre Latenz steht ausdrücklich auf JSON-`null`. `cancelProcessContainmentGatePassed = true`, `cancelGatePassed = false`. Der SDK-Fortschrittscallback kann Laden oder VAE melden und belegt keinen bestimmten UNet-Schritt. Die Messung zählt keinen verpassten nativen Rücklauf nachträglich als Erfolg.

## Prüfung und Reproduktion

Die Befehle für getrennte Vorbereitung, `--probe-case` und `--cancellation-only` stehen in der [Werkzeugdokumentation](../../../tools/sdxl-evaluation/README.md). Frische private Roots und Ausgabeordner verhindern das Überschreiben früherer Nachweise. Die Modellproben liefen nacheinander ohne gleichzeitige Builds oder Tests; `caffeinate -i` verhinderte automatischen Leerlaufschlaf. Unabhängige Softwareprüfungen und Builds nutzten getrennte Scratchverzeichnisse und ein gemeinsames begrenztes Jobbudget. Die kleine Sampleauswertung und abhängige Publikation bleiben bewusst seriell.

Die [Softwareprüfübersicht](verification/software-checks.json) dokumentiert 707 App- und 331 Core-Tests mit 18 vorgesehenen Skips, darunter zehn neue echte Testprozess-Regressionen, 38 Python-Tests und die Shell-Opt-in-Guards. Anfängliche Cache-/Sandboxprobleme und ein unter Gesamtlast gefundener Fehler der Test-/Steuerthread-Zuständigkeit sind mit ihren Korrekturen getrennt ausgewiesen. Finale Tests, unabhängiges Diffreview und der vorgeschriebene saubere vollständige App-Build sind dort beziehungsweise im [Buildnachweis](verification/clean-application-build.json) festgehalten. Historische SD-1.5-, LaMa- und SDXL-V1–V8-Rohberichte bleiben unverändert.
