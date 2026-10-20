# Separate LaMa-Evaluation für textfreies Entfernen

Dieses Werkzeug untersucht in [Issue #74](https://github.com/dr-dimitri/picedit/issues/74) einen weiteren lokalen Kandidaten nach dem [No-Go aus Issue #12](../../docs/AI-IMAGE-BACKEND-DECISION.md). **V2 hat echte technische Inferenz nachgewiesen; das Produkt-No-Go bleibt bestehen.** Ein erforderlicher Qualitätsfall scheitert, weitere Produktnachweise fehlen. Das Werkzeug installiert keinen PicEdit-Bildprovider. Es verspricht weder Promptsteuerung noch Hintergrundersetzung oder Outpainting. Die [Roadmap](../../docs/AI-ROADMAP.md) erklärt die weiterhin blockierten Folgeissues.

Historische Rohberichte, Vergleichsbilder und Quellsnapshots aus V1/V2 wurden mit dem Reportsordner entfernt. Die Messwerte unten sind eine historische Zusammenfassung. Neue Läufe benötigen einen extern vorhandenen Fixture-Archivbaum und schreiben ihre Ergebnisse in ein explizites externes Verzeichnis.

## Gepinnte Daten und offene Provenienz

`package.json` bindet die öffentlich angebotene [Core-ML-Konvertierung](https://huggingface.co/mlboydaisuke/LaMa-CoreML/tree/5ed76e3799ab4cad31381750d29880c267477e18) an Revision `5ed76e3799ab4cad31381750d29880c267477e18`. Die vier ungepackten Dateien umfassen **216.650.601 Byte**: Modellspezifikation, Gewichte, Paketmanifest und Modellkarte. Größen und vollständige SHA-256-Hashes sind festgelegt; der eigene Package-Hash ist zusätzlich im Installer und nativen Harness gepinnt. Manifest und Modellkarte wurden bei der Metadatenprüfung außerdem gegen ihre Git-Blob-SHA1-Werte geprüft. Diese Identität ist keine Herkunfts- oder Lizenzfreigabe.

Die [gepinnt gelesene Modellkarte](https://huggingface.co/mlboydaisuke/LaMa-CoreML/blob/5ed76e3799ab4cad31381750d29880c267477e18/README.md) nennt [advimman/lama](https://github.com/advimman/lama) als Ursprung und john-rocky als Konvertierer; sie verweist auf [CoreML-Models](https://github.com/john-rocky/CoreML-Models) und dessen [Konversionsnotizen](https://github.com/john-rocky/CoreML-Models/blob/master/docs/coreml_conversion_notes.md). Der Lizenzwert `apache-2.0` in dieser Karte ist eine Angabe des Uploaders. Die vollständige Zuordnung der heruntergeladenen Gewichte zum ursprünglichen Checkpoint, zur tatsächlich verwendeten Konversionsrevision und zu den anwendbaren Weitergabebedingungen bleibt offen. PicEdit führt weder das fremde Konversionsskript aus noch leitet es aus dem Kartenlabel eine Verteilfreigabe ab. Fremde Geschwindigkeits- und Speicherangaben werden nicht als eigene Messwerte übernommen.

## Explizite Vorbereitung

Python 3 genügt für den Installer und seine Offline-Tests. Ohne Aktionsflag zeigt er nur den Plan, öffnet keine Netzverbindung und erzeugt keinen Installationsordner:

```sh
python3 tools/lama-evaluation/prepare.py
```

Nur `--download` erlaubt den Download der gepinnten Dateien. Das Ziel muss außerhalb des Repositorys liegen; ein vorhandenes `model/` wird nicht ersetzt. Ein neuer Evaluationsroot wird mit privaten Rechten erstellt. Ein bestehender Root muss dem aktuellen Benutzer gehören und darf nicht für Gruppe oder andere Benutzer schreibbar sein.

```sh
python3 tools/lama-evaluation/prepare.py --root /private/tmp/picedit-lama-install --download
```

Der Installer überlappt höchstens zwei Dateiübertragungen. Er verwendet einen privaten Stagingordner, prüft die vollständigen Größen und Hashes und veröffentlicht den fertigen Baum atomar unter `<root>/model/`. Dort liegen `LaMa.mlpackage`, `README.md` und `installation.json`. Es werden keine Archive entpackt, kein fremder Code ausgeführt und keine Appdateien verändert. Ein fehlgeschlagener Versuch entfernt nur seinen eigenen Stagingordner; ein fremder Installationslock und bereits vorhandene Daten bleiben erhalten.

Ein lokaler Cache spiegelt exakt die relativen Pfade aus `package.json`, einschließlich `LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin`. Er lässt sich ohne jede Netzanfrage installieren:

```sh
python3 tools/lama-evaluation/prepare.py --root /private/tmp/picedit-lama-offline --offline --source-cache /absolute/path/to/cache
```

Fehlende oder falsche Dateien scheitern ohne Downloadfallback. Symbolische Links, Hardlinks und besondere Dateitypen im Cache werden abgewiesen. Für einen neuen vollständigen Versuch einen neuen Evaluationsroot verwenden.

## Native Schnittstelle und Bildprobe

Der Swift-Harness benötigt Apple Silicon, macOS 14+, mindestens 16 GiB physischen Speicher und die installierten Command Line Tools. Er verwendet einen isolierten Entwicklerbuild. Der vorgeschaltete SwiftPM-Build kann die bereits gepinnten Paketabhängigkeiten abrufen; Modellinstallation und Modell-/Cloud-Netzzugriffe sind kein Teil der Ausführung. Normale App- und Testaufrufe starten diese Evaluation nicht.

Auch eine reine Paketinspektion benötigt das ausdrückliche `--run`: Sie prüft Hashes, kompiliert und lädt Core ML, liest die tatsächliche Schnittstelle, führt aber keine Bildvorhersage aus. Der Ausgabeordner muss neu sein.

```sh
./scripts/evaluate-image-generation.sh lama --run --inspect --root /private/tmp/picedit-lama-install --out /private/tmp/picedit-lama-interface
./scripts/evaluate-image-generation.sh lama --run --fixture-archive /private/tmp/picedit-fixture-archive --root /private/tmp/picedit-lama-install --out /private/tmp/picedit-lama-native
```

Die vollständige Probe prüft zunächst die echte `image`-/`mask`-/Ausgabeschnittstelle des 800×800-Pakets; die separate Inspektion hat BGRA-RGB-Bufferschnittstellen und eine Gray8-Maske bestätigt. Kleinere native Fixturebilder werden ohne Skalierung durch eine zentrierte ganzzahlige Verschiebung eingebettet. V2 übergibt gerades, nicht mit Alpha multipliziertes RGB ohne vorgemischten Hintergrund. Der vierkanalige Modellbuffer trägt dabei vollständig deckendes Alpha; das ursprüngliche Quellalpha bleibt separat und wird vor dem finalen Compositing wiederhergestellt.

RGB und binäre Modellmaske verwenden exakt denselben am Bildrand geklammerten Sampler. Die Modellmaske ersetzt bei Gray8-Werten ab 128; ein markierter Randpixel bleibt deshalb auch in seinem künstlichen Paddingkontext markiert. Die Ausgabe wird anhand derselben Verschiebung auf die nativen Fixturemaße zurückgeschnitten; künstliches Padding wird verworfen. Die gespeicherte native weiche Maske bleibt unverändert. Der anschließende aktuelle `MaskCompositor` erhält ursprüngliche Maske und Quellalpha; Bereiche mit nativem Maskengewicht 0 bleiben nach dessen Vertrag erhalten.

Die Probe benötigt denselben eingefrorenen synthetischen Fixturesatz wie die frühere Evaluation in einem ausdrücklich angegebenen externen Archiv (`--fixture-archive` mit `provenance/fixtures-manifest.json` und `fixtures/`). Die dortigen Dateien müssen die weiterhin gepinnten Originalhashes erfüllen; neu erzeugte Contract-Fixtures ersetzen dieses Archiv nicht. Auf die erste Vorhersage folgen drei warme Wiederholungen derselben Eingabe; die weiteren Fälle prüfen Objekt am Rand, harte/weiche Kante, Teiltransparenz, feine Motivkanten und diagnostisch ein nichtquadratisches Canvas. Ein Modellkontext verarbeitet sie nacheinander unter einer **6-GiB-Inferenzlease**. Serielle Vorhersagen vermeiden konkurrierende Modellkopien und unbrauchbare Vergleichszeiten. `criteria.json` legt vor der V2-Messung in Schema 2 die korrigierte Vorbereitung fest. Die ursprünglichen Grenzen von 45 Sekunden für das Laden, 180 Sekunden je Vorhersage und 6 GiB Peak-RSS/Footprint sowie die fachlichen Anforderungen bleiben erhalten.

Zeit- und Speichergrenzen werden **nach Rückkehr des synchronen Core-ML-Aufrufs** geprüft. Sie sind kein Watchdog, unterbrechen keinen festhängenden Aufruf und erzwingen keine Betriebssystem-Speicherquote. Die Ressourcenlease bleibt bis zur tatsächlichen Rückkehr belegt. RSS und physischer Footprint betreffen den eigenen Harnessprozess; sie erfassen nicht zuverlässig den vollständigen Speicher ausgelagerter Core-ML-Dienste. Aus diesen Werten wird kein gesamter Systemspeicherverbrauch des Modells abgeleitet.

`lama-report.json` dokumentiert Kriterien-/Paketidentität, Schnittstelle, Kompilierung, Laden, Vorhersagezeiten, Prozessspeicher und Outputhashes. Jede erfolgreiche Vorhersage erhält Quell-, Masken- und Rohbilddateien. Nach der nativen Serie folgt der aktuelle Compositor-Replay in `<out>-compositor/`; dessen Bericht wird per Hash referenziert. Die erste Vorhersage ist ein Prozess-/Modell-Erstlauf; der Harness leert keine Betriebssystem- oder Treibercaches. Keine zweite Inferenz oder andere GPU-Messung gleichzeitig starten.

## Nachvollziehbare Vorbereitungskorrektur

Die tatsächlich ausgeführte V1-Serie wurde mit den damaligen Evaluationsquellen geprüft. Sie verwendete weißen Vormatte-Hintergrund und eine unmaskierte Paddingfläche. Bei Teiltransparenz führte die spätere Wiederanwendung des Quellalpha zu einem hellen Fleck. Bei einem Randobjekt konnten dessen RGB-Pixel ins künstliche Padding geklammert werden, ohne auch die Ersetzungsmaske dorthin fortzusetzen; dieser Kontext begünstigte die erneute Objektrekonstruktion.

V2 korrigiert diese beiden Eingabeverträge wie oben beschrieben und wurde tatsächlich ausgeführt. Die damaligen V1- und V2-Artefakte sind im aktuellen Repository nicht mehr enthalten. Der Replay nutzt für die LaMa-Ausgabe eine explizite Alpha-Metadatenangabe für gerades RGB; der bisherige Standardpfad und die historische SD-1.5-Auswertung werden nicht nachträglich geändert.

## Belegtes Ergebnis und Produktgrenze

Die damalige Auswertung umfasste die native V2-Serie mit zehn Vorhersagen und den anschließenden Compositor-Replay. Die Messung erfolgte mit 16 GiB physischem Speicher unter macOS 27.0.1, Compute Units `.all` und unveränderten Schema-2-Kriterien:

| Messgröße | Tatsächlicher V2-Wert |
| --- | --- |
| Laden des kompilierten Modells | 2,160 s |
| Erste Vorhersage | 0,740 s |
| Drei warme Wiederholungen derselben Eingabe | 0,4094 / 0,4087 / 0,4088 s |
| Peak-RSS des eigenen Prozesses | 768.507.904 Byte |
| Maximaler physischer Footprint des eigenen Prozesses | 1.460.978.984 Byte |

Die erste Eingabe und ihre drei warmen Wiederholungen lieferten denselben Pixelhash. Der aktuelle Compositor-Replay meldet in allen zehn Fällen keine geänderten RGBA-Bytes bei nativem Maskengewicht 0 und keine geänderten Quellalpha-Bytes. Das belegt den Erhaltungsvertrag dieser Fixtures. Die Prozessspeichermessung umfasst weiterhin nicht zuverlässig alle ausgelagerten Core-ML-Dienste; die Vorhersagezeiten sind keine vollständige interaktive Ende-zu-Ende-Messung.

Die Randobjekt- und Alphafehler der V1-Vorbereitung sind in V2 behoben. Kleine Objektentfernung ist auf den geprüften Bildern vielversprechend. Der erforderliche Fall `05-fine-motif-edges-hard` erzeugt jedoch großflächig grünen Ersatz und besteht die fachliche Prüfung nicht. Im diagnostischen Fall `06-nonsquare-canvas-hard` bleiben sichtbare Übergänge. Diese Bilder erlauben weder eine allgemeine Maskenfreigabe noch eine Aussage zur Qualität von Hintergrundersetzung oder Outpainting.

Dieses technische Programm misst bislang weder Abbruchlatenz noch interaktives Preview-Rendering und verwendet noch keinen freigegebenen Produktadapter. Ein eingehaltenes Zeit-/Speicherlimit, unveränderte unmaskierte Pixel oder wiederholbare Rohbilder ersetzen keine fachliche Bildprüfung. Hintergrund und Outpainting bleiben eigenständige Fähigkeiten. Eine neue Entscheidung benötigt die offenen Nachweise und vollständige Provenienz; die produktive Capability bleibt bis dahin unavailable.

Ein gespeicherter nativer Ergebnisbaum lässt sich ohne erneute Inferenz durch den Compositor führen. Der Replay liest `lama-report.json.preprocessingVersion`: V2 erhält die Straight-RGB-Angabe, historische Berichte ohne Versionsfeld behalten ihre Vormatte-Angabe. Andere numerische Versionsstände werden abgewiesen.

```sh
./scripts/evaluate-image-generation.sh replay --historical /private/tmp/picedit-lama-native --out /private/tmp/picedit-lama-replay
```

Offline-Tests mit kleinen selbst erzeugten Payloads benötigen keine Gewichte, Compiler oder Netzverbindung:

```sh
python3 -B -m unittest discover -s tools/lama-evaluation -v
```
