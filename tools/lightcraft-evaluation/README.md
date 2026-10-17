# LC-01: Vergleichsharness

```sh
./scripts/evaluate-lightcraft.sh /tmp/picedit-lc01-run
```

Der Wrapper baut den vorhandenen `editing`-Harness in Release-Konfiguration und orchestriert dessen `evaluation`-Szenario. Er startet keinen persönlichen Katalog und verändert keinen Produktionsalgorithmus. Die fachliche Methode, Quellen, Grenzen und Kandidatenentscheidungen stehen in [`docs/LIGHTCRAFT-ALGORITHM-EVALUATION.md`](../../docs/LIGHTCRAFT-ALGORITHM-EVALUATION.md).

Der eingecheckte [Lauf vom 17. Oktober 2026](../../reports/lightcraft-evaluation/run-2026-10-17/summary.json) enthält 126 Qualitätsdatensätze, 54 bestandene Kontrollen und die vollständige Größen-/Timingmatrix. Alle vier Algorithmuskandidaten bleiben mangels isolierter Referenz und Qualitätsnachweis blockiert.

## Aufbau

- `measurement-manifest.json` beschreibt vorab Szenenklassen, Kontrolltoleranzen, kritische Grenzen und Ressourcenbudgets. Die tatsächlich verwendete Kopie wird vor der Abnahme gehasht.
- `candidate-registry.json` trennt verfügbare Kontrollen von noch nicht implementierten Lightcraft-Verfahren. Ein registrierter Name allein aktiviert keinen Vergleich und ist keine Freigabe.
- `run.py` führt Qualitäts-, Skalen- und Timingläufe seriell zusammen und schreibt Rohdaten sowie deren Provenienz in das gewählte Ergebnisverzeichnis.
- Der native Modus bleibt in `Sources/PicEdit/DeveloperTools/EditingBenchmark.swift`. Gemeinsame Float-Raster, deterministische Fixtures und Metriken liegen bei den Developer-Tools und sind unabhängig von der Produktionsintegration testbar.

Ein direkter nativer Aufruf verwendet `--scenario evaluation`, `--evaluation-mode quality|timing|scale`, `--output`, `--manifest`, `--registry`, `--iterations`, `--width` und `--height`. Der Qualitätsmodus verwendet fest 192 × 128 Pixel pro synthetischem Fall. Nur `--backend default` und `--workers 1` sind für die Evaluation zulässig. Für reproduzierbare Abnahmeläufe den Wrapper verwenden, damit Manifest, Reihenfolge, Hostdaten und Hashes zusammen erfasst werden.

## Ergebnisvertrag

Die Qualitätsausgabe enthält Eingaben, PicEdit-/Kontroll-Paarbilder, Differenzen, helle/dunkle Alphakomposite und numerische Messwerte. `labeled.html` erlaubt beschriftete Kontrolle, `blind.html` die Beurteilung ohne Verfahrensnamen; `blind-key.json` enthält die Zuordnung. Der Schlüssel darf erst nach der protokollierten Blindbeurteilung geöffnet werden. Diagnose-PNGs sind sRGB-Ansichten, keine verlustfreie Float-Referenz. Die Differenzen zeigen den absoluten premultiplizierten RGB-Unterschied mit Faktor acht; die Komposite benutzen lineares Schwarz (0) und Weiß (1).

`environment.json` enthält Host-/Toolchainangaben, Quell-/Binary-/Manifest-Hashes und Abdeckungslücken. `commands.json` protokolliert jeden nativen Aufruf. `quality/quality.json`, die einzelnen `timing-*/timing.json` und `scale/scale.json` sind die Rohdaten; `summary.json` fasst bestandene Kontrollen, Zeitverteilungen und weiterhin blockierte Kandidaten zusammen. Vorhandene Ergebnisverzeichnisse werden nicht überschrieben. Ein abgebrochener oder fehlgeschlagener Lauf bleibt zur Diagnose erhalten und hat keine erfolgreiche Abschlusszusammenfassung.

Die Größenmatrix ist 400 × 267, 2400 × 1600, 4096 × 2731 und 4608 × 3072. Timingprozesse werden getrennt gestartet, mit mindestens fünf Wiederholungen, getrenntem Initialaufruf und warmen Samples. Keine parallelen Benchmarks oder Builds während einer Messreihe ausführen. Prozesskalt ist nicht gleichbedeutend mit geleerten System-/Shadercaches. Die Rohdaten enthalten Streuung und Peak-RSS des ganzen Prozesses; fünf Werte ergeben kein belastbares p95.

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
./scripts/evaluate-lightcraft.sh /tmp/picedit-lc01-with-real --real-manifest /path/to/local-fixtures.json
```

Die Eingaben werden einmal nach `private-inputs/` kopiert und dort gegen ihren Datei-Hash geprüft. Die Messung decodiert diese lokale Momentaufnahme, damit eine spätere Änderung des Originals die Provenienz nicht verfälscht. Die optionalen Resultate stehen separat unter `private-real-N/` mit Provenienz und werden nicht automatisch veröffentlicht. Sie liefern PicEdit-Diagnosebilder, noch keine registrierten Abnahmeszenen mit passenden ROIs, Vergleichsreferenzen oder dokumentierter visueller Bewertung. Fehlende Bildklassen bleiben deshalb in der Auswertung sichtbar; ein lokal hinzugefügtes Bild ersetzt nicht automatisch die noch fehlende reale Abnahme. Originaldateien werden nicht verändert.

Die Fixtures und Messläufe benötigen weder Netzwerkzugriff noch Lightcraft-Checkout, Rust/wgpu oder Modelle. Der vorherige SwiftPM-Build verwendet die normalen gepinnten Projektabhängigkeiten und kann sie bei leerem Build-Cache abrufen. Die initialen Kontrollen prüfen die Messinfrastruktur; die eigentlichen Algorithmusadapter gehören zu LC-03 bis LC-06.
