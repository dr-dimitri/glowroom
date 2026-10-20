# LC-01: Vergleichsharness

```sh
./scripts/evaluate-lightcraft.sh /private/tmp/picedit-lc01-run
```

Der Wrapper baut den vorhandenen `editing`-Harness in Release-Konfiguration und orchestriert dessen `evaluation`-Szenario. Er startet keinen persönlichen Katalog und verändert keinen Produktionsalgorithmus. Die fachliche Methode, Quellen, Grenzen und Kandidatenentscheidungen stehen in [`docs/LIGHTCRAFT-ALGORITHM-EVALUATION.md`](../../docs/LIGHTCRAFT-ALGORITHM-EVALUATION.md).

Der historische LC-01-Lauf vom 17. Oktober 2026 umfasste 126 Qualitätsdatensätze, 54 bestandene Kontrollen und die vollständige Größen-/Timingmatrix. In diesem historischen Kontrolllauf bleiben alle vier Algorithmuskandidaten mangels isolierter Referenz und Qualitätsnachweis blockiert. Der folgende LC-03-Modus ergänzt die separate Tonwertevaluation; er ändert diese historischen Kontrollwerte nicht.

Historische Rohdaten, Vergleichsbilder, Quellsnapshots und Prüfprotokolle wurden
mit dem bisherigen Ergebnisordner aus dem Repository entfernt. Zusammengefasste
Messwerte und Entscheidungen bleiben in den verlinkten Evaluationsdokumenten.
Neue Läufe benötigen ein ausdrücklich gewähltes externes Ergebnisverzeichnis,
wie `/private/tmp/picedit-lc01-run` im Beispiel oben.

## LC-03: isolierter Lichter-/Schattenvergleich

```sh
./scripts/evaluate-lightcraft.sh /private/tmp/picedit-lc03-run --candidate LC-03
```

`lc03.py` orchestriert zusätzliche Modi desselben `editing`-Harness: `tone-tune`, `tone-quality`, `tone-timing` und `tone-scale`. [`lc03-manifest.json`](lc03-manifest.json) legt vor der Abnahme die acht Reglerfälle, Matching-ROIs, Detail-/Halo-Ziele und Budgets fest. [`docs/LIGHTCRAFT-TONE-EVALUATION.md`](../../docs/LIGHTCRAFT-TONE-EVALUATION.md) erklärt Verfahren, Quellübernahme, Reihenfolge und Grenzen. Die [numerischen Referenzvektoren](lc03-reference-oracle/README.md) lassen sich ohne Rust im normalen Swift-Testlauf prüfen; nur ihre optionale Neuerzeugung benötigt `rustc` und den gepinnten lokalen Checkout.

Der Wrapper friert das Manifest sowie die Hashes aller Swift-Quellen, Build-Einstiege, Orchestrierung, Referenzvektoren und Lizenzen vor der Abstimmung ein. Danach wird `tuning/calibration.json` gehasht, bevor die getrennte Abnahme beginnt. Jede Veränderung dieser Eingaben oder des Harness-Binaries während des Laufs bricht die Reihe ab. Die qualitätsbezogenen Regeln werden nicht automatisch an Ergebnisse angepasst.

`quality/quality.json` enthält 9 Szenenklassen × 8 Richtungs-/Stärkefälle sowie getrennte Stufendiagnosen. `labeled.html` zeigt Eingabe, PicEdit, angeglichenen Kandidaten, Kandidaten mit identischen Werten, Differenz und Alphakomposite. `blind.html` benutzt neutrale Kopien und einen getrennten Zuordnungsschlüssel; das Erzeugen dieser Seite bedeutet keine erfolgte Blindfreigabe. Fehlende reale Fotos und visuelle Freigabe bleiben ausdrücklich offen. `--real-manifest` ist im LC-03-Modus nicht unterstützt, solange passende Abnahme-ROIs und Referenzen nicht definiert sind.

Die Timingmatrix umfasst 512 × 320, 2400 × 1600, 4096 × 2731 und 4608 × 3072, jeweils fünf getrennte Prozesse pro Adapter. Ein kalter Aufruf, ein ausgeschlossener Warmup und fünf warme Samples werden getrennt erfasst. Die CPU-Referenz darf ihre unveränderliche Steuerbasis bei warmen Reglerbewegungen wiederverwenden. Effektstärken werden außerhalb des Timers pro Sample erfasst; eine Budgetüberschreitung ist nur für Phasen mit angeglichener Tonwirkung ein Veto, und Peak-RSS nur bei angeglichener Wirkung aller Phasen. Andernfalls bleibt sie eine Kostenbeobachtung. Vergleichsmessungen laufen seriell, ohne konkurrierende Builds/Tests.

`summary.json` unterscheidet No-Go durch belastbare gematchte Regressionen beziehungsweise fehlenden primären Gewinn und Blockierung durch fehlende Evidenz. Der isolierte synthetische Modus kann kein Produktions-Go erteilen. Die App behält bis zu einer freigegebenen späteren Integration ihren vorhandenen Graphen.

## LC-04: isolierte Klarheit und getrennte Texturablation

```sh
./scripts/evaluate-lightcraft.sh /private/tmp/picedit-lc04-run --candidate LC-04
```

`lc04.py` verwendet die Modi `detail-tune`, `detail-quality`, `detail-timing` und
`detail-scale` desselben Editing-Harness. Das vor der Abnahme eingefrorene
[`lc04-manifest.json`](lc04-manifest.json) definiert getrennte Entscheidungen für
Guided-Klarheit und Gaussian-Textur. Der
[LC-04-Bericht](../../docs/LIGHTCRAFT-DETAIL-EVALUATION.md) erklärt Methode,
Quellen, Ablationen und Ergebnisse. Identische Reglerwerte und angeglichene
Detailverstärkung werden separat ausgewiesen. Reale Fotos oder eine
abgeschlossene visuelle Freigabe werden durch synthetische Paarbilder nicht
ersetzt; `--real-manifest` wird in diesem spezialisierten Modus ausdrücklich
abgelehnt.

## LC-05: Dynamik und Sättigung bei gleicher Chromawirkung

```sh
./scripts/evaluate-lightcraft.sh /private/tmp/picedit-lc05-run --candidate LC-05
```

`lc05.py` ergänzt `color-tune`, `color-quality`, `color-timing` und `color-scale`.
Das [Manifest](lc05-manifest.json) trennt Dynamik und Sättigung sowie die
unbegrenzte ColorOps-Ablation von der Kombination mit der ursprünglichen
sRGB-Gamutbehandlung. Die 256 × 160 großen Testbilder prüfen Hue-/L-Drift gegen
die Eingabe bei angeglichener mittlerer Chromaänderung. Positive/negative
Werte, vollständige Entsättigung, Grau, P3, Alpha und signed RGB besitzen
getrennte Diagnose- und Grundverträge. Reale Fotos/Blindabnahme und eine
Produktionsfreigabe werden nicht behauptet; `--real-manifest` wird auch hier
abgelehnt. Details stehen im [LC-05-Bericht](../../docs/LIGHTCRAFT-COLOR-EVALUATION.md).

## LC-06: Luminanz, Chroma und native Skalierung

```sh
./scripts/evaluate-lightcraft.sh /private/tmp/picedit-lc06-run --candidate LC-06
```

`lc06.py` verwendet `denoise-tune`, `denoise-quality`, `denoise-timing` und
`denoise-scale`. Das [Manifest](lc06-manifest.json) trennt die drei Entscheidungen.
Acht deterministische Ground-Truth-Szenen mit unabhängigem Tuning-/Abnahmerauschen
prüfen Detailerhalt bei gleicher positiver Rauschminderung. Die Luminanzreferenz
verwendet den vollständigen Guided-Filter in Log-Luminanz, die Chromareferenz
Gaussian-geglättetes RGB/Y. Die Skalierungsablation vergleicht bekannte
Flächenmittelung mit unveränderten Parametern; unbekannte Decoder-Skalierung
rechtfertigt keine Epsilon-Anpassung. Die tatsächliche Varianz nichtganzzahliger
Flächenmittelung kann von der ursprünglichen `scale²`-Näherung abweichen.

Die [40 Original-Rust-Referenzfälle](lc06-reference-oracle/README.md) prüfen die
Quellentreue unabhängig von der Qualitätsentscheidung. Der
[LC-06-Bericht](../../docs/LIGHTCRAFT-DENOISE-EVALUATION.md) dokumentiert Matching,
Stage-/Skalengrenzen und Ergebnisse. Reale Fotos, Original-Problemaufnahmen und
visuelle Abnahme bleiben separat erforderlich; `--real-manifest` wird abgelehnt.
Ein synthetischer Erfolg allein erteilt kein Produktions-Go.

## Aufbau

- `measurement-manifest.json` beschreibt vorab Szenenklassen, Kontrolltoleranzen, kritische Grenzen und Ressourcenbudgets. Die tatsächlich verwendete Kopie wird vor der Abnahme gehasht.
- `candidate-registry.json` trennt verfügbare Kontrollen von den spezialisierten Lightcraft-Referenzvergleichen. Ein registrierter Name allein aktiviert keinen Vergleich und ist keine Freigabe.
- `run.py` führt Qualitäts-, Skalen- und Timingläufe seriell zusammen und schreibt Rohdaten sowie deren Provenienz in das gewählte Ergebnisverzeichnis.
- Der native Modus bleibt in `Sources/PicEdit/DeveloperTools/EditingBenchmark.swift`. Gemeinsame Float-Raster, deterministische Fixtures und Metriken liegen bei den Developer-Tools und sind unabhängig von der Produktionsintegration testbar.

Ein direkter nativer **LC-01-Standardaufruf** verwendet `--scenario evaluation`, `--evaluation-mode quality|timing|scale`, `--output`, `--manifest`, `--registry`, `--iterations`, `--width` und `--height`. Sein Qualitätsmodus verwendet fest 192 × 128 Pixel pro synthetischem Fall. LC-03 und LC-04 verwenden ihre spezialisierten Modi und 512 × 320 Pixel, LC-05 und LC-06 verwenden 256 × 160 Pixel. Nur `--backend default` und `--workers 1` sind für die Evaluation zulässig. Für reproduzierbare Abnahmeläufe den Wrapper verwenden, damit Manifest, Reihenfolge, Hostdaten und Hashes zusammen erfasst werden.

## Ergebnisvertrag

Die Qualitätsausgabe enthält Eingaben, PicEdit-/Kontroll-Paarbilder, Differenzen, helle/dunkle Alphakomposite und numerische Messwerte. `labeled.html` erlaubt beschriftete Kontrolle, `blind.html` die Beurteilung ohne Verfahrensnamen; `blind-key.json` enthält die Zuordnung. Der Schlüssel darf erst nach der protokollierten Blindbeurteilung geöffnet werden. Diagnose-PNGs sind sRGB-Ansichten, keine verlustfreie Float-Referenz. Die Differenzen zeigen den absoluten premultiplizierten RGB-Unterschied mit Faktor acht; die Komposite benutzen lineares Schwarz (0) und Weiß (1).

`environment.json` enthält Host-/Toolchainangaben, Quell-/Binary-/Manifest-Hashes und Abdeckungslücken. `commands.json` protokolliert jeden nativen Aufruf. `quality/quality.json`, die einzelnen `timing-*/timing.json` und `scale/scale.json` sind die Rohdaten; `summary.json` fasst bestandene Kontrollen, Zeitverteilungen und weiterhin blockierte Kandidaten zusammen. Vorhandene Ergebnisverzeichnisse werden nicht überschrieben. Ein abgebrochener oder fehlgeschlagener Lauf bleibt zur Diagnose erhalten und hat keine erfolgreiche Abschlusszusammenfassung.

Die **LC-01-Standardgrößenmatrix** ist 400 × 267, 2400 × 1600, 4096 × 2731 und 4608 × 3072; LC-03 bis LC-06 messen die kleinste Timinggröße bei 512 × 320. Timingprozesse werden getrennt gestartet, mit mindestens fünf Wiederholungen, getrenntem Initialaufruf und warmen Samples. Keine parallelen Benchmarks oder Builds während einer Messreihe ausführen. Prozesskalt ist nicht gleichbedeutend mit geleerten System-/Shadercaches. Die Rohdaten enthalten Streuung und Peak-RSS des ganzen Prozesses; fünf Werte ergeben kein belastbares p95.

Ein bestandener Kontrollvergleich ist ein Harness-Erfolg. Die Algorithmusentscheidung bleibt bei fehlendem Adapter, echter Bildabdeckung oder visueller Abnahme blockiert. Ergebnisse dürfen nicht durch Weglassen fehlgeschlagener Fälle zu einem Go zusammengefasst werden.

## Einen Kandidaten ergänzen

1. Einen abgegrenzten Referenzadapter implementieren und seine Quellen auf `f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15` pinnen. Kopierte/adaptierte Symbole samt MIT-Text und Copyright erfassen. Den Produktionsrenderer dafür nicht austauschen.
2. Als Eingang das identische, einmal orientierte Float32-Straight-RGBA-Raster in extended linear sRGB übernehmen. Rec.2020-Konvertierung und OkLab-Konstanten explizit testen. Alpha separat erhalten, korrekt premultiplizieren/entpremultiplizieren und unsichtbare RGB-Werte ausschließen.
3. Auf dem Tuning-Split Parameter abstimmen. Identische Reglerwerte und angeglichene Effektstärke getrennt dokumentieren; das Stärke-Maß muss zum Verfahren passen.
4. Vor dem ersten getrennten Abnahmelauf Klassen, Referenzziel, primäre Verbesserung, kritische numerische Grenzen, CPU-/CI-Toleranzen und Performance-/Speicherbudgets einfrieren. Änderungen daran erfordern eine neue Reihe.
5. Alle Pflichtklassen, Skalen, Transparenzfälle und benötigten realen Raster prüfen. Konvertierung und Readback auf beiden Seiten in die Laufzeit einbeziehen. CPU-/GPU-Ausführungen nicht zu einer Stichprobe vermischen.
6. Verblindete visuelle Beurteilung protokollieren. Go nur bei verbesserter benannter Primärmetrik, bestandenen kritischen Fällen und Budgets sowie vollständiger Evidenz. Einen Trade-off ausdrücklich benennen.

## Reale Eingaben

Reale Fotos oder bereits entwickelte RAW-Raster sind optional und vom synthetischen Standardsatz getrennt. Nur ausdrücklich angegebene Dateien lesen; keine automatische Fotosuche. PNG, TIFF und JPEG sind erlaubt, RAW-Eingaben nicht. Der native Decoder begrenzt Eingaben vor dem vollständigen Decodieren auf 8192 Pixel je Achse und 32 Megapixel. Ein lokales Manifest verwendet diese Struktur; relative Pfade beziehen sich auf seinen Ordner:

```json
{
  "files": [
    {
      "path": "portrait-developed.tiff",
      "sha256": "vollständiger SHA256 der Datei",
      "scene_class": "colors",
      "source": "eigene Aufnahme, dokumentierte Entwicklung",
      "license": "eigene Aufnahme; ausschließlich lokale Auswertung",
      "permission_to_use": true
    }
  ]
}
```

```sh
./scripts/evaluate-lightcraft.sh /private/tmp/picedit-lc01-with-real --real-manifest /path/to/local-fixtures.json
```

Die Eingaben werden einmal nach `private-inputs/` kopiert und dort gegen ihren Datei-Hash geprüft. Die Messung decodiert diese lokale Momentaufnahme, damit eine spätere Änderung des Originals die Provenienz nicht verfälscht. Die optionalen Resultate stehen separat unter `private-real-N/` mit Provenienz und werden nicht automatisch veröffentlicht. Sie liefern PicEdit-Diagnosebilder, noch keine registrierten Abnahmeszenen mit passenden ROIs, Vergleichsreferenzen oder dokumentierter visueller Bewertung. Fehlende Bildklassen bleiben deshalb in der Auswertung sichtbar; ein lokal hinzugefügtes Bild ersetzt nicht automatisch die noch fehlende reale Abnahme. Originaldateien werden nicht verändert.

Die Fixtures und Messläufe benötigen weder Netzwerkzugriff noch Lightcraft-Checkout, Rust/wgpu oder Modelle. Der vorherige SwiftPM-Build verwendet die normalen gepinnten Projektabhängigkeiten und kann sie bei leerem Build-Cache abrufen. Die initialen Kontrollen prüfen die Messinfrastruktur; die eigentlichen Algorithmusadapter gehören zu LC-03 bis LC-06.
