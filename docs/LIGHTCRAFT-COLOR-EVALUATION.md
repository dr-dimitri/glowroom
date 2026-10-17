# LC-05: Dynamik und Sättigung getrennt vergleichen

Vergleich zu [Issue #54](https://github.com/dr-dimitri/picedit/issues/54) nach
[Roadmap #49](https://github.com/dr-dimitri/picedit/issues/49). Die Referenz
untersucht nur die vorhandenen Regler `vibrance` und `saturation`. Sie ist ein
Entwicklerexperiment; Produktionsgraph, gespeicherte Bearbeitungen, UI,
AutoTone und die bestehenden 14 Regler-IDs bleiben erhalten.

**Ergebnis: getrenntes No-Go für die untersuchte Dynamik und Sättigung.**
Beide gematchten moderaten Primärziele verbessern sich deutlich. Die
Kombination mit dem ursprünglichen sRGB-Gamutmapper verletzt aber kritische
Grenzen; außerdem bleibt die kleine ursprüngliche Grauachsenabweichung über
der numerischen Toleranz. Deshalb erfolgt keine Produktionsübernahme und
keine Prozessmigration nach LC-02. Das bewertet diese eingefrorene Teilformel
mit ihrer Ausgaberegel; eine gezielt überarbeitete Formel müsste separat
geprüft werden. Eine pauschale Aussage über Lightcrafts Bildqualität folgt
daraus nicht.

Vollständige [Rohdaten und Entscheidung](../reports/lightcraft-evaluation/lc05-2026-10-17/summary.json),
[beschriftete Paarbilder](../reports/lightcraft-evaluation/lc05-2026-10-17/labeled.html),
[verblindete Paare](../reports/lightcraft-evaluation/lc05-2026-10-17/blind.html)
und [Prüfprotokolle](../reports/lightcraft-evaluation/lc05-validation/README.md)
bleiben im Repository erhalten.

## Reproduktion und Referenzgrenze

```sh
./scripts/evaluate-lightcraft.sh /tmp/picedit-lc05-run --candidate LC-05
python3 -m unittest discover -s tools/lightcraft-evaluation -p 'test_*.py'
```

Der gepinnte Lightcraft-Stand ist
`f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`. Beide Pfade erhalten dieselben
bereits entwickelten Straight-RGBA-Float32-Pixel in extended linear sRGB.
Die Referenz konvertiert RGB ausdrücklich nach Rec.2020, verwendet die
ursprünglichen OkLab-Matrizen und vorzeichenbehafteten Kubikwurzeln und
konvertiert anschließend zurück. Negative und über eins liegende Komponenten
werden nicht still vor der Farbrechnung abgeschnitten. Alpha bleibt separat;
unsichtbares RGB wird auf null kanonisiert.

Die Dynamik gewichtet geringe Chroma mit `(1-clamp(C/0.22))²`. Positive Werte
reduzieren die Verstärkung zusätzlich um den aus sRGB-Hue 25° abgeleiteten
OkLab-Farbton; negative Werte verwenden diese Heuristik nicht. Das ist eine
Farbheuristik, keine Gesichts- oder Hauterkennung. Danach skaliert Sättigung
die Chroma mit `max(0,1+saturation)`. Mixer, Grading, Profile, lokale Masken,
Kalibrierung und Lightcrafts globales Tonmodell sind deaktiviert.

Zwei explizite Ausgaberegeln trennen Farboperation und Gamutbehandlung:

- **`gamutMappedSRGB`** ist die untersuchte Kombination. Sie ergänzt nach der
  Rücktransformation die ursprüngliche Funktion `finish::gamut_map_to` für
  SDR-sRGB mit Luminanzgewichten `[0.2126,0.7152,0.0722]` und Peak 1. Sie
  entsättigt in Richtung begrenzter Luminanz, bis die Komponenten in den
  Ausgabebereich passen.
- **`unbounded`** erhält die unveränderte ColorOps-Ausgabe einschließlich
  erweiterter Werte. Diese Ablation ist diagnostisch; ihre Gamutfehler dürfen
  nicht die gemappte Kombination ablehnen.

Bei Null/Null umgehen beide Regeln Konvertierung und Gamutbehandlung vollständig
und erhalten den kanonischen Eingaberaster exakt. Die Referenz übernimmt die
ungefähre Grauachse der Originalmatrizen bewusst unverändert; eine still
korrigierte Grauachse wäre ein anderer Kandidat. Der numerische Grauvertrag
wird unabhängig von der Quelltreue und von einer sichtbaren Präferenz geprüft.

Die Berechnung ist pro Pixel zusammengefasst und verwendet den vorhandenen
begrenzten LC-03-Zeilenpool. Ein zweiter Worker-Pool, räumliche Ebenen, ein
zusätzlicher Decoder oder CPU-Readback innerhalb eines Produktionsgraphen
werden nicht eingeführt. Der unabhängige Messpfad bleibt seriell, damit
konkurrierende CPU-/GPU-Last die Laufzeiten nicht verfälscht.

## Vorab festgelegtes Verfahren

Das [Manifest](../tools/lightcraft-evaluation/lc05-manifest.json) fixiert vor der
Abnahme neun Szenen, zwei Regler, ±20/±60/±100 und beide Ausgaberegeln. Das ergibt
216 Qualitätsfälle. Moderate ±20 bilden die primäre Abnahme; stärkere Werte
liefern Belastungsfälle. 108 Aufnahmen bei −1/0/+1 und 18 unabhängige
Vollentsättigungen bei `saturation=-100` ergänzen die Verträge.

Die Szenen enthalten Hautfarbproben bei vier Helligkeiten und mehreren
Farbtönen, Rot-/Orangeproben samt Vergleichsfarben bei denselben L/C-Werten,
selbst erzeugte Textil-/Blütenmuster, geordnete Chromaverläufe, Primär-/
Sekundärfarben, P3-Randfarben, Grau-/chromaarme Rampen, transparente Kanten
und negative erweiterte Werte einschließlich Schwarz. Die Muster sind keine
Fotos und ersetzen keine fotografische Abnahme oder Hautfarbenrepräsentation.

Die 256 × 160 Pixel großen Tuning- und Abnahmebilder besitzen dieselbe
Farb-/Alpha-Verteilung mit unterschiedlicher räumlicher Anordnung. Das ist
für punktweise Algorithmen eine kontrollierte Reproduktions-/Layoutprüfung,
**kein unabhängiger Farbraum-Holdout**. Die Parametrisierung wird ausschließlich
auf dem Tuning-Split gesucht, mit 33 groben und 33 verfeinernden Punkten;
Manifest, Quellen, Binary und Kalibrierung werden vor der Abnahme gehasht.
Eine Änderung während des Laufs bricht die Messreihe ab.

Die Effektstärke ist die alpha-gewichtete mittlere vorzeichenbehaftete
OkLab-Chromaänderung über **alle sichtbaren Eingabepixel**, einschließlich
chromaarmer Farben. Der Betrag muss mindestens 0,0002 betragen. Bei gleichem
Vorzeichen darf die Abweichung höchstens das Maximum aus 0,00001 und 5 % der
PicEdit-Wirkung sein. Ein Mapping je Szene ist eine Versuchsnormalisierung,
keine universelle Reglerkennlinie. Fehlendes Matching wird nicht als Gewinn
oder kritische Farbregression gewertet; exakte/numerische Grundverträge gelten
unabhängig davon.

Hue- und Helligkeitsdrift werden mit unabhängigen Double-OkLab-Matrizen
**gegen die ursprüngliche Eingabe** gemessen. Der Hue-Maskensatz ist durch
Eingabechroma ≥0,02, L>0,02 und Alpha>0,1 festgelegt. Verschwindet Ausgabefarbe
unter Chroma 0,000001, werden fehlende Unterstützung und konservativ 180°
Drift erfasst; der Pixel verschwindet nicht aus der Statistik. Die
Helligkeitsmetrik ist der Mittelwert von `abs(Lout-Lin)`, nicht der Betrag
der mittleren Differenz, bei dem sich gegenläufige Fehler aufheben könnten.
Abweichungen zwischen PicEdit und Kandidat stehen zusätzlich als reine
Kompatibilitätsdiagnose bereit.

Die primäre Abnahme gewichtet die vier Klassen Hautfarben, Rot/Orange,
Textil/Blüten und Farbverläufe sowie beide moderaten Richtungen gleich.
Hue-Mitteldrift und mittlere absolute L-Drift müssen jeweils um mindestens
10 % sinken, sofern PicEdits Mittel über 0,05° bzw. 0,0001 liegt. Unterhalb
dieser Untergrenze muss der Kandidat höchstens diese Grenze erreichen;
mindestens ein aussagekräftiges Ziel muss sich verbessern. Zusätzlich darf
kein einzelner Primärfall um mehr als 0,25° bzw. 0,002 L schlechter werden.
Alle Fälle müssen gematcht sein und vollständige Hue-Unterstützung behalten.
Es werden weder statistische Signifikanz noch unabhängige Pixelstichproben
behauptet.

Kritische zusätzliche Grenzen gegenüber PicEdit sind 3° maximale Hue-Drift,
0,005 mittlere absolute L-Drift, 0,02 zusätzliche Gamut-/Clipping-/
Hue-Verlustanteile und 0,05 zusätzliche Kollaps-/Umkehranteile der geordneten
Chromaverläufe. Alpha darf höchstens 0,001 abweichen. Sättigung −100 wird nicht
für beabsichtigte Entsättigung oder den dann bedeutungslosen Hue bestraft;
sein eigener Vertrag fordert höchstens 0,000005 Restchroma. Derselbe
konservative numerische Grenzwert gilt für anfänglich neutrale Pixel. Diese
technischen Versuchsgrenzen sind keine empirischen Wahrnehmungsschwellen.

Dynamik und Sättigung erhalten getrennte Entscheidungen. Ein nachgewiesener
Vertragsbruch, eine gematchte kritische Regression oder ein vollständig
geprüftes verfehltes Primärziel bedeutet No-Go für den jeweiligen Kandidaten.
Fehlende reale, visuelle oder Integrationsevidenz bedeutet blockiert, niemals
Go. Ein positiver späterer Teilkandidat würde zusätzlich LC-02 und die
Produktionsabnahme benötigen.

Die zusätzliche Stufendiagnose kombiniert Belichtung, Schatten/Lichter,
Dehaze und AutoTone. Das Materialisieren der Zwischenbilder erzeugt eine
explizite Begrenzungs-/Rundungsgrenze. Bei aktiviertem AutoTone analysiert der
Pfad mit früher Farboperation außerdem die bereits farbveränderte Eingabe
neu. `order_difference` enthält deshalb auch diese Neuanalyse und isoliert
keine reine Reihenfolge bei festgehaltenem Tonmodell. Diese Diagnose ist von
der primären Farbentscheidung getrennt und ersetzt keinen Integrationstest.

Die Performance-Reihe verwendet 512 × 320, 2400 × 1600, 4096 × 2731 und
4608 × 3072 Pixel. Pro Regler, Größe und Adapter starten fünf getrennte
Prozesse mit je einem prozesskalten Wert, einer Aufwärmung und fünf warmen
Werten bei PicEdit-Reglerstellungen 18 bis 22; die Referenz verwendet dazu
proportional skalierte Werte des eingefrorenen Mappings. Die Reihenfolge der Adapter wechselt
zwischen Wiederholungen; alle Messungen laufen seriell. Konvertierung,
Rendern, Materialisierung und Rücklesen liegen innerhalb der jeweiligen
Zeitgrenze, Fixture-Erzeugung und Messwertreduktion außerhalb. Der
Prozess-Spitzenspeicher enthält hingegen auch Eingabevalidierung und
Messwertreduktion. „Prozesskalt“ leert keine Betriebssystem-/Treibercaches.

Die vorab festgelegten Obergrenzen sind das 1,25-Fache der kalten Latenz,
das 1,20-Fache der warmen Latenz und das 1,25-Fache des Prozess-RSS. Ein
Laufzeitveto ist nur der Phase zugeordnet, deren Effektstärken tatsächlich
gematcht sind; das RSS-Veto benötigt Matching aller Phasen. Die Referenz ist
ein begrenzter CPU-Pfad gegenüber PicEdits automatischem Core-Image-Backend.
Ihre Messwerte prognostizieren keine Leistung eines künftig fusionierten
CI-/Metal-Kernels. Eine zusätzliche Reihe vergleicht für alle zwölf
Richtungen direkte kleine Vorschauen mit herunterskalierten Vollbildern.

## Qualitätsbefund der eingefrorenen Reihe

Alle acht Primärfälle je Regler sind gematcht und behalten vollständige
Hue-Unterstützung. Der größte relative Matchingfehler beträgt dort 0,4222 %
bei Dynamik und 0,5024 % bei Sättigung. Gleich gewichtete Mittel über vier
Szenen und beide Vorzeichen:

| Regler / eingaberelative Metrik | PicEdit | Gemappte Referenz | Verbesserung |
| --- | ---: | ---: | ---: |
| Dynamik: mittlere Hue-Drift | 0,522193° | 0,126631° | 75,75 % |
| Dynamik: mittlere absolute L-Drift | 0,00253386 | 0,000134682 | 94,68 % |
| Sättigung: mittlere Hue-Drift | 0,721816° | 0,157635° | 78,16 % |
| Sättigung: mittlere absolute L-Drift | 0,00413831 | 0,000158288 | 96,18 % |

Damit bestehen beide **numerischen Primärziele**, einschließlich der
Einzelfallgrenzen. Die folgenden kritischen Befunde verhindern dennoch die
Übernahme. `clipping_fraction` zählt alpha-gewichtete RGB-Komponenten
außerhalb oder genau auf 0/1, nicht Pixel und nicht nachgewiesene sichtbare
Bandingfehler. Auch der Gamutmapper kann Werte exakt auf diese Grenzen legen;
mehr Grenzwerte bedeuten daher nicht automatisch schlechtere sichtbare Bilder.
Der vorab festgelegte numerische Guard bleibt trotzdem unverändert gültig.
Bei aktivem gemapptem Eingriff liegen alle RGB-Komponenten innerhalb der
Gamut-Toleranz; die genannten Clippingbefunde sind davon zu unterscheiden.

| Gematchter Fall | Metrik | PicEdit | Referenz | Zusätzlicher Anteil / Grenze |
| --- | --- | ---: | ---: | ---: |
| Dynamik −20, Farbverläufe | Clipping | 0,6364 % | 3,5433 % | +2,9069 / max. 2 Prozentpunkte |
| Dynamik +60, Hautfarbproben | Clipping | 1,7985 % | 4,3237 % | +2,5252 / max. 2 Prozentpunkte |
| Sättigung −20, Farbverläufe | Clipping | 0,2669 % | 2,3779 % | +2,1110 / max. 2 Prozentpunkte |
| Sättigung +60, Farbverläufe | Umgekehrte Chromaschritte | 0,0441 % | 5,6667 % | +5,6225 / max. 5 Prozentpunkte |
| Sättigung +60, Textil-/Blütenmuster | Clipping | 3,0290 % | 14,5345 % | +11,5055 / max. 2 Prozentpunkte |

Insgesamt überschreiten sieben gematchte Dynamikfälle acht kritische Grenzen,
14 Sättigungsfälle 15 Grenzen. Der höchste zusätzliche Hue-Maximalfehler
der Dynamik liegt im erweiterten Dunkelfall bei −100:
14,3409° → 18,0488°, also +3,7079° gegenüber höchstens 3°. Gamut-/Clipping-
Grenzen und fehlendes Matching dürfen nicht mit einem generellen Vorteil
oder Nachteil für sämtliche Bildklassen verwechselt werden.

Die Matching-Abdeckung je Klasse zeigt die Grenzen der Normalisierung. Jede
Zelle nennt **gemappt / unbounded**, jeweils von sechs Reglerwerten:

| Klasse | Dynamik | Sättigung |
| --- | ---: | ---: |
| Hautfarbproben | 5 / 5 | 6 / 6 |
| Rot/Orange | 4 / 4 | 6 / 6 |
| Textil-/Blütenmuster | 4 / 5 | 5 / 6 |
| Farbverläufe | 4 / 5 | 5 / 6 |
| Primär-/Sekundärfarben | 2 / 2 | 6 / 6 |
| P3-Randfarben | 1 / 0 | 3 / 5 |
| Graurampe | 1 / 1 | 3 / 3 |
| Transparenz | 4 / 5 | 6 / 6 |
| Erweiterte Dunkelwerte | 1 / 0 | 2 / 3 |
| Gesamt | 26 / 27 | 42 / 47 |

Damit sind 142 von 216 Fällen gematcht; 74 bleiben außerhalb der vergleichbaren
Wirkung oder unter der Mindestwirkung. Insbesondere Grau wird nicht wegen
fehlender mittlerer Chromawirkung als Erfolg bewertet. Die unveränderte
ColorOps-Ausgabe ist eine getrennte Ablation und entscheidet nicht über den
gemappten Kandidaten.

Die Rot-/Orangeheuristik zeigt die erwartete Selektivität: Bei gematchter
Dynamik +20 erhöht der Kandidat die Chroma der warmen Proben um 10,37 % und
die der Vergleichsfarbtöne um 14,96 %; PicEdit erreicht 11,96 % / 11,07 %.
Bei +60 sind es 30,69 % / 45,30 % gegenüber 35,58 % / 34,51 %. Negative
Dynamik dämpft die beiden Gruppen nahezu gleich: −14,51 % / −15,07 % bei
−20. Sättigung +60 wirkt ebenfalls nahezu gleichmäßig mit
50,04 % / 49,97 %. Das beschreibt Farbgruppen, keine erkannte Haut; die
ungematchten Dynamikwerte ±100 werden hier nicht als Vergleichssieg gewertet.

Alle 36 exakten Nullfälle behalten den Eingabehash, alle 108 −1/0/+1-Fälle
bestehen die numerischen Grundverträge. Über sämtliche Qualitätsfälle bleibt
der maximale Alpha- und verborgene RGB-Fehler null. Die Referenztests decken
zusätzlich 8/16 Bit, sRGB/P3, beide Vorzeichen, Abbruch und unveränderte
Eingaberaster ab. Das belegt die isolierte Grenze, keine neue produktive
Exportfreigabe.

Bei stärkeren Eingriffen überschreiten neutrale Pixel in der gemappten
Referenz dennoch die strenge Restchroma-Grenze: maximal 0,000122843 bei Dynamik und 0,000122271 bei
Sättigung. Bei unabhängiger Vollentsättigung liegen die neun gemappten
Szenenmaxima zwischen 0,0000875991 und 0,000124949, jeweils über 0,000005.
Das Original-Rust-Oracle bestätigt dieselbe kleine Matrixabweichung. Sie ist
ein numerischer Vertragsbruch; aus diesen Größen wird **kein sichtbarer
Farbstich behauptet**. Eine korrigierte Grauachse wäre eine neue Formel und
würde die übrigen Gamut-/Abstufungsbefunde nicht automatisch beseitigen.

Stichproben der Hautfarb-, Verlaufs- und hell/dunkel komponierten Alpha-Paare
wurden auf intakte Ausgabe und Artefaktzuordnung geprüft. Die erzeugte
Blindansicht wurde nicht als abgeschlossene verblindete Präferenzstudie
ausgegeben. Reale lizenzierte Fotos, visuelle Abnahme und ein integrierter
CI-/Metal-Vergleich fehlen weiterhin.

## Laufzeit, Speicher und Vorschaugrößen

Gemessen auf einem MacBook Pro mit Apple M2 Pro (12 CPU-/19 GPU-Kerne),
16 GiB RAM, macOS 27.0.1 und Swift 6.4 im Release-Harness. Alle 80 Prozesse
und sämtliche kalten, warmen und Aufwärm-Effektstärken sind vollständig und
gematcht. Die Tabelle nennt **PicEdit / CPU-Referenz**; Latenzen sind Mediane
aus fünf kalten beziehungsweise 25 warmen Samples, RSS ist das Maximum der
fünf Prozesse. Die warmen Werte teilen sich Prozesscaches und sind keine
unabhängigen Wiederholungen.

| Regler | Pixel | Kalt (ms) | Warm (ms) | Peak-RSS (MiB) |
| --- | --- | ---: | ---: | ---: |
| Dynamik | 512 × 320 | 51,207 / 4,073 | 2,859 / 3,439 | 44,9 / 16,1 |
| Dynamik | 2400 × 1600 | 111,174 / 83,687 | 51,163 / 77,040 | 438,4 / 129,0 |
| Dynamik | 4096 × 2731 | 243,032 / 238,849 | 153,193 / 222,894 | 1224,8 / 353,2 |
| Dynamik | 4608 × 3072 | 291,935 / 299,075 | 189,339 / 281,830 | 1541,2 / 443,8 |
| Sättigung | 512 × 320 | 49,893 / 3,130 | 2,809 / 2,365 | 45,8 / 16,9 |
| Sättigung | 2400 × 1600 | 112,593 / 64,425 | 50,019 / 53,140 | 438,5 / 129,0 |
| Sättigung | 4096 × 2731 | 249,289 / 172,126 | 154,293 / 153,803 | 1224,9 / 353,1 |
| Sättigung | 4608 × 3072 | 298,903 / 214,805 | 191,855 / 193,922 | 1541,2 / 443,8 |

Dynamik überschreitet die warme 1,20-Grenze in allen vier Größen: Faktoren
1,203 / 1,506 / 1,455 / 1,488. Der erste Fall liegt nur knapp über der Grenze;
die größeren Fälle liefern den deutlicheren Befund. Bei voller Größe reicht
die warme Streuung von 182,05–240,26 ms für PicEdit und 280,32–285,74 ms für
die Referenz. Sättigung bleibt innerhalb aller Performancebudgets; ihre
warmen Faktoren sind 0,842 / 1,062 / 0,997 / 1,011. Dort liegt die Streuung
bei voller Größe bei 185,45–196,77 ms beziehungsweise 193,01–196,86 ms.
Die Referenz benötigt in diesem Versuchsaufbau weniger Prozess-RSS und
meist weniger kalte Initialzeit. Das hebt die Qualitätsvetos nicht auf und
ist keine Prognose für eine produktive GPU-Integration oder RAW-End-to-End-Zeit.

Die 24 Skalierungsdiagnosen vergleichen 4608 × 3072 mit 400 × 267 Pixeln.
Über zwölf Richtungen liegt der mittlere RGB-Abstand zwischen direkter
Vorschau und verkleinertem Vollbild bei PicEdit zwischen 0,0000909441 und
0,000337390, bei der Referenz zwischen 0,0000497880 und 0,000416356.
Der jeweilige Maximalfehler beträgt höchstens 0,0296246 beziehungsweise
0,0480957; Alpha bleibt in beiden Pfaden gleich. Nichtlineare Farb- und
Gamutoperationen kommutieren nicht exakt mit dem Verkleinern. Diese Diagnose
verwendet das eingefrorene Qualitätsmapping auch für Extremwerte und
behauptet weder dort separat gematchte Wirkung noch produktive Exportparität.

## Prüfung und Abschlussgrenze

Die [Validierung](../reports/lightcraft-evaluation/lc05-validation/README.md)
umfasst 88 bestandene native Tests in zehn Suiten, 53 Python-Tests,
24 Original-Rust-Fälle mit je 20 Pixeln und den generischen LC-01-Smoketest
mit 126 Datensätzen ohne Kontrollfehler. Die anfänglichen Compile-/Testfehler
im neuen Harness-/Testcode sind korrigiert und samt Diagnose protokolliert.
Unabhängige Reviews prüften Quelltreue, Metriken/Fixtures, Swift-/Python-
Schnittstelle, Zahlen und Schlussfolgerungen. Der AutoTone-Diagnoseumfang
wurde dabei präzisiert. Es wurden keine unabhängigen Repository-Bugs gefunden.
Der abschließende vollständige Release-Build mit `./scripts/build-app.sh`
bestand nach sicherer Entfernung von `.build/`, `.build-app/` und
`dist/PicEdit.app`; Plist und App-Signatur wurden erfolgreich geprüft.

Das Ergebnisarchiv enthält die vollständigen JSON-/PNG-Daten, Befehle und
Herkunftshashes. Nach dem erfolgreichen Lauf wurden ausschließlich 83 leere
Prozesslogs weggelassen; die Liste steht in `artifact-packaging.json`.
Reale Fotos, visuelle Präferenz und Produktionsintegration bleiben ausdrücklich
unbelegt. Für diesen No-Go-Abschluss sind weder LC-02 noch ein erzwungener
Algorithmusaustausch erforderlich.

## Quellen

Die tatsächlich adaptierten Symbole stehen in den
[Drittanbieterhinweisen](../tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt).
Die vollständigen [MIT-Lizenz](../tools/lightcraft-evaluation/licenses/lightcraft/LICENSE-MIT)
und [NOTICE](../tools/lightcraft-evaluation/licenses/lightcraft/NOTICE) sind
beigefügt. Der [Original-Rust-Oracle](../tools/lightcraft-evaluation/lc05-reference-oracle/README.md)
prüft die Referenz unabhängig; Rust wird nur für seine optionale Neuerzeugung
benötigt, nicht für den App-Build. Es werden keine Marken, Modelle, Kamera-
oder Bildbestände übernommen.
