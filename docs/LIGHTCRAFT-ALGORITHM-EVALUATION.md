# Lightcraft-Verfahren: reproduzierbare Vergleichsgrundlage

Stand: 17. Oktober 2026. Umsetzung von [LC-01 / #50](https://github.com/dr-dimitri/picedit/issues/50) aus der [selektiven Roadmap #49](https://github.com/dr-dimitri/picedit/issues/49).

LC-01 stellt gemeinsame Eingaben, Kontrollvergleiche, Messgrößen, Rohdaten und ein konservatives Entscheidungsgate bereit. Es übernimmt keinen Lightcraft-Algorithmus in den Produktionsrenderer. Ein bestandener unveränderter oder neutraler Kontrollvergleich belegt die Integrität des Vergleichswegs; er belegt keinen Qualitätsgewinn. Am Ende von LC-01 waren die vier geplanten Algorithmusfamilien **blockiert wegen fehlender Evidenz**. Die nachfolgende LC-03-Evaluation ist unten separat fortgeschrieben; historische LC-01-Messwerte bleiben unverändert.

## Reproduktion und Ausgangsstand

```sh
./scripts/evaluate-lightcraft.sh /tmp/picedit-lc01-run
```

Der Befehl baut den bestehenden `editing`-Developer-Harness optimiert und führt dessen Evaluationsmodus aus. Es gibt keinen zweiten allgemeinen Rendering-/Benchmark-Einstiegspunkt. `EditingBenchmark`, `EditRenderer` und der übrige App-Target werden mit denselben SwiftPM-Abhängigkeiten gebaut. Die Anwendung, der persönliche Katalog und RAW-Decoder werden dabei nicht gestartet. Die bisherigen Szenarien unter `scripts/benchmark-editing.sh` und die Arbeit aus #44 bleiben zuständig für allgemeine Vorschau-/Scheduling-Messungen.

Die vor Beginn der Umsetzung erfasste Release-Baseline liegt unter [`reports/lightcraft-evaluation/prechange`](../reports/lightcraft-evaluation/prechange/). Ausgangspunkt ist `bf1900970089b26de9b76c37d83a5a168bf91de3`, der aktualisierte `main` vor LC-01. Die Dateien enthalten Commit, Swift-Version, macOS-/Hardwaredaten und die unbearbeiteten Benchmarkausgaben. Gemessen wurde auf einem Apple M2 Pro mit 12 CPU-Kernen, 19 GPU-Kernen und 16 GB Arbeitsspeicher, macOS 27.0.1 (26A434), Swift 6.4.0.34.1. Diese Angaben beschreiben nur diesen Rechner.

Die historische Baseline benutzt `--scenario complex --width 2400 --height 1600 --iterations 5`: deterministisch erzeugte, opake sRGB-Eingabe mit 8 Bit je Kanal. Das Muster ist eine geschlossene Ganzzahlformel ohne Zufallszahlengenerator. Die Bearbeitung kombiniert Belichtung, Auto-Tonwerte, Struktur, Klarheit und Farbrauschminderung; die genauen Parameter und jedes Sample stehen im Log und im gepinnten `EditingBenchmark.swift`. Dieser ältere Mischlastvergleich ist kein isolierter Lightcraft-Qualitätsvergleich.

Fünf getrennte Prozesse lieferten fünf erste Aufrufe und je fünf warme Renderings. Die ersten Aufrufe hatten einen Median von 90,042 ms und eine Spannweite von 87,224–1810,105 ms. Die 25 warmen Werte hatten einen Median von 8,998 ms und eine Spannweite von 8,004–12,300 ms. Der höchste Prozess-Spitzen-RSS betrug 110.329.856 Byte. Die starke Streuung der ersten Aufrufe zeigt insbesondere, weshalb daraus kein stabiler kalter System-/Shadercache abgeleitet werden darf. Die neuen Float-Evaluationszeiten messen eine andere Konvertierungsstrecke und sind kein direkter Vorher-/Nachher-Geschwindigkeitsvergleich zu dieser 8-Bit-Baseline.

Neue Ausgaben gehören unter `reports/lightcraft-evaluation/` oder in ein ausdrücklich gewähltes externes Ergebnisverzeichnis. Die maschinenlesbaren Reports verknüpfen die verwendeten Manifeste, Fixtures und Ergebnisdateien mit Hashes. PNGs dienen der Ansicht; die Qualitätswerte werden aus dem gemeinsamen Float-Raster berechnet. Die ausführbaren Optionen und die Erweiterungsschnittstelle stehen in [`tools/lightcraft-evaluation/README.md`](../tools/lightcraft-evaluation/README.md).

## Gemeinsamer Pixelvertrag

Beide Vergleichsseiten erhalten dieselben **bereits entwickelten, aufrecht orientierten Pixel**. Das Eingangsbild wird einmal anhand seiner EXIF-Orientierung normalisiert und anschließend als Float32-Raster in extended linear sRGB eingefroren. Abmessungen und die Little-Endian-Float32-Pixel gehen in den Fixture-Hash ein. Ein Vergleich vollständiger Lightcraft-RAW-Renderings mit PicEdit-JPEG-Renderings erfüllt diesen Vertrag nicht.

Das Arbeitsraster enthält Straight-RGB und separates Alpha. Farbwerte außerhalb `[0, 1]` bleiben im Arbeitsraster erhalten; erst die sRGB-Ansicht kann sie begrenzen. Die CGImage-Brücke premultipliziert RGB, die Rückführung entpremultipliziert nur bei positivem Alpha. Bei Alpha null wird unsichtbares RGB auf null kanonisiert. Unsichtbare Werte zählen nicht als Qualitätsgewinn. Der transparente Rand wird zusätzlich über festem linearem Weiß und Schwarz beurteilt; ein anderer Alpha-Kanal darf keinen scheinbar besseren RGB-Wert erzeugen.

PicEdit arbeitet bereits in extended linear sRGB. Lightcraft verwendet am gepinnten Quellstand lineares Rec.2020/D65. Ein künftiger Lightcraft-Referenzadapter muss deshalb die Transformation linear sRGB → Rec.2020 → linear sRGB explizit ausführen oder seine Gleichungen nachweislich an den PicEdit-Arbeitsraum anpassen. Ein identischer D65-Weißpunkt erspart keine Transformation der Primärfarben. Auch negative Werte und Werte größer eins gehören in die Konvertierungstests.

Die OkLab-Messung verwendet die im Metrikmodul offengelegten [linear-sRGB-Matrizen von Björn Ottosson](https://bottosson.github.io/posts/oklab/) in der Fassung vom 25. Januar 2021 und vorzeichenbehaftete Kubikwurzeln. Ottosson stellt die Referenz als Public Domain oder alternativ unter MIT bereit. Die Metrik kopiert keinen Lightcraft-Code. Lightcrafts `oklab_from_2020` verwendet dagegen eine aus Rec.2020 abgeleitete RGB→LMS-Matrix; diese darf nicht unverändert auf sRGB-Pixel angewendet werden. Lightcrafts dreikanaliger `Rgb32f` ist keine Referenz für Alphaverhalten. Räumliche Kandidaten müssen transparente Nachbarschaften zusätzlich prüfen.

## Fixtures und unabhängige Abnahme

Die synthetischen Eingaben umfassen neun Klassen: Graurampen, konstante Flächen, feine helle/dunkle Linien, harte Kanten, Texturen, Haut-/Primärfarben, gesättigte Farbverläufe, transparente/semitransparente Kanten und Rauschen. Tuning und Abnahme verwenden getrennte deterministische Varianten. Rauschbilder entstehen aus einer bekannten sauberen Referenz mit festem Seed; Signal-, Luma- und Chromarauschen sind dadurch nachvollziehbar und nicht mit Bildstruktur gleichgesetzt.

Die Integration prüft zusätzlich 8/16 Bit × sRGB/Display P3 × alle acht EXIF-Orientierungen, also 32 Kombinationen, anhand von TIFF-/ImageIO-Eingaben. Float-Roundtrips prüfen Semitransparenz, Alpha-null-Kanonisierung und das Erhalten von Werten außerhalb des sichtbaren sRGB-Würfels. Diese kleinen Integrationsfälle belegen keine Abdeckung aller Kamera-, ICC- oder RAW-Formate.

Es werden keine persönlichen Fotos automatisch gesucht oder veröffentlicht. Reale Fotos und bereits entwickelte RAW-Raster sind über `--real-manifest` optionale, separat deklarierte Eingaben mit Nutzungsnachweis und Datei-Hash. Akzeptiert werden entwickelte PNG/TIFF/JPEG-Raster, keine RAW-Dateien. Die optionalen PicEdit-Diagnosen unter `private-real-N/` sind noch keine registrierte Abnahmeserie mit passenden Referenzen und ROIs. Der synthetische Standardsatz enthält keine realen Porträts, natürlichen Gegenlichtkanten, Landschaftstexturen oder hoch-ISO-Kamerabilder. Diese Bildklassen bleiben eine ausdrücklich ausgewiesene Evidenzlücke. Ein zusätzlicher realer Datensatz darf nicht als bereits geprüfte Standardabdeckung erscheinen.

Vor dem ersten Abnahmelauf wird das verwendete maschinenlesbare Manifest unverändert in das Ergebnisverzeichnis kopiert und gehasht. Bei Änderungen an Parametern, Vergleichsmaßstab, Messgrößen oder Grenzwerten entsteht eine neue Versuchsreihe. Abnahmebilder dürfen nicht nachträglich zur Parameterauswahl oder zur Lockerung der Toleranzen dienen.

## Messgrößen und Entscheidung

Das Manifest trennt numerische Kontrolltoleranzen von den Grenzen einer beabsichtigten Bildänderung. Ein neuer Tonwertalgorithmus muss nicht pixelgleich mit einer neutralen Eingabe sein. Für sein benanntes primäres Qualitätsziel werden PicEdit und Kandidat gegen dieselbe ausdrücklich deklarierte Referenz gemessen; kritische Regressionen werden zusätzlich im Paarvergleich gegen PicEdit erfasst.

| Messgröße | Bedeutung und Grenze der Aussage |
|---|---|
| Sichtbarer RGB-Fehler | Mittlere/maximale absolute Abweichung in linearem Straight-RGB; Alpha-null-Pixel sind ausgeschlossen. |
| Halo-Über-/Unterschwingen | Abweichung über/unter der lokalen Referenzhülle; ein numerischer Indikator für lokale Extremwerte, kein vollständiges Modell wahrgenommener Halos. |
| Feinlinien-/Kantenerhalt | Relativer Verlust der Gradientenstärke, berechnet aus der Wurzel des Energieverhältnisses. Rauschen kann Energie erhöhen; deshalb niemals allein als Detailgewinn werten. |
| Texturerhalt | Relativer Verlust der Laplace-Stärke, ebenfalls aus der Wurzel des Energieverhältnisses; gemeinsam mit Restnoise und visueller Beurteilung auswerten. |
| Luminanzdrift | Mittlere Abweichung von linearem sRGB-Y mit Gewichten 0,2126 / 0,7152 / 0,0722. |
| Hue-/Chroma-Abweichung | OkLab-Werte; Hue wird bei zu geringer Chroma nicht als definierte Farbe behandelt. |
| Gamut-/Clippinganteil | Zunahme von Werten außerhalb bzw. an den Grenzen `[0, 1]`; Diagnostik vor der Ansichtsbegrenzung. |
| Luma-/Chroma-Restnoise | RMS-Abweichung gegenüber sauberer Ground Truth in deren flachen Bereichen. Kein Rauschmaß ohne geeignete Referenz. |
| Transparenter Rand | Alpha-Fehler und RGB-Abweichung der Komposite über Weiß/Schwarz. |

Alle Qualitätswerte sind nichtnegative Fehler-/Verlustgrößen: kleiner ist besser, und kritische Grenzen sind Obergrenzen. RGB-/Luminanz-Fehler und Restnoise benutzen normalisierte lineare Kanalwerte, Hue wird in Grad und Chroma in OkLab-Einheiten gemessen. Detailverluste, Gamut-/Clippingzunahme und Alpha-Fehler sind Anteile; ROI-Zähler und Referenzenergien belegen ausschließlich, dass ein geeigneter Bildbereich ausgewertet wurde.

Die konkreten Grenzwerte und Szenenklassen stehen im [Messmanifest](../tools/lightcraft-evaluation/measurement-manifest.json), die Primärziele im [Kandidatenregister](../tools/lightcraft-evaluation/candidate-registry.json), damit der ausführbare Vertrag und die Dokumentation nicht getrennt gepflegte Toleranzen enthalten. Fehlende oder nicht endliche Werte sind kein bestandener Test. Zusätzlich werden beschriftete und verblindet vergleichbare Paaransichten mit Differenzen erzeugt; der Zuordnungsschlüssel bleibt getrennt. Eine numerische Verbesserung ersetzt die visuelle Abnahme nicht.

Ein künftiger Kandidat muss zwei Vergleiche dokumentieren: identische Reglerwerte und eine auf den Tuning-Fixtures angeglichene Effektstärke. Beispielsweise kann die mittlere Schattenanhebung, der Detailkontrast, die Chromazunahme oder das Restrauchen angeglichen werden. Das gewählte Maß und seine Toleranz werden vor der Abnahme festgelegt. Ein schwächerer Effekt darf nicht wegen geringerer Halos zum Gewinner erklärt werden.

**Go** setzt mindestens ein vorab benanntes verbessertes primäres Qualitätsziel, alle kritischen Abnahmefälle, dokumentierte Performance-/Speicherbudgets, vergleichbare Effektstärke, vollständige notwendige Evidenz und bestandene visuelle Beurteilung voraus. Ein geprüfter Kandidat mit kritischer Regression, Budgetverletzung oder ohne primären Gewinn erhält **No-Go**. Fehlender Adapter, fehlende Szenen, fehlende Messung oder fehlende Beurteilung ergeben **blockiert**. Ein Trade-off wird nicht still als Sieg behandelt.

## Laufzeiten, Speicher und Skalen

Die Größenmatrix umfasst 400 × 267, 2400 × 1600, 4096 × 2731 und 4608 × 3072 Pixel. Der größte Fall liegt oberhalb der Vorschaugrenze. Die Evaluation benutzt für alle Größen denselben vorhandenen vollständigen `filterGraph` mit RGBAh-Arbeitsformat und Float32-Ausgabe; `EditRenderer.render` bleibt auf seine unveränderte Vorschaugrenze beschränkt. Diese Zahlen messen den gemeinsamen Graph mit der Evaluationsbrücke, nicht die gesamte interaktive Vorschau mit deren Cache-/Scheduling-Pfad oder einen 8-/16-Bit-Dateiexport. Der Skalenvergleich stellt die direkte Vorschau dem verkleinerten vollständigen Ergebnis gegenüber; beide Verkleinerungen werden über Core Image in Float32 materialisiert und nicht zwischendurch auf 16-Bit-Integer begrenzt.

Messkonfigurationen laufen nacheinander. Gleichzeitige CPU-/GPU-Schwerlast würde die Vergleichslatenz und den Speicherverbrauch verzerren; diese serielle Ausnahme ist Absicht. Entwicklung, unabhängige Analysen und getrennte Tests können parallel laufen. Arbeitsrastern und Ergebnisdateien werden nicht für beliebig viele große Bilder gleichzeitig gehalten.

Pro Konfiguration werden mindestens fünf neue Prozesse und getrennte warme Wiederholungen erfasst. Der erste Aufruf ist ein **prozesskalter Renderer**, kein nachgewiesen kalter Betriebssystem-, Treiber- oder Shadercache. Warmup wird getrennt ausgewiesen. Median, Minimum/Maximum und Rohsamples erlauben das Prüfen der Streuung. p95 ist nur ab mindestens 30 geeigneten Messwerten mit dokumentierter Schätzmethode aussagekräftig und wird aus fünf Samples nicht behauptet.

Die gemessene Renderstrecke schließt die erforderliche Eingangs-/Ausgangskonvertierung und das Materialisieren/Zurücklesen der Pixel ein. Das Erzeugen der Fixture, PNG-/HTML-Berichte und die CPU-Qualitätsanalyse sind gesonderte Arbeit; sie dürfen nicht unbemerkt die Kernelzeit ersetzen oder in verschiedene Seiten unterschiedlich eingehen. Peak-RSS gehört zum ganzen jeweiligen Prozess einschließlich seiner Puffer, nicht zu einem einzelnen Filter oder allen GPU-Allokationen. Ein kumulativer Prozesshöchstwert ist keine Summe unabhängiger Bildkosten.

Core Image wählt seinen verfügbaren Backendpfad. Eine Softwarepräferenz ist ohne bestätigte Ausführung kein CPU-Nachweis. Das vorhandene Gerät liefert keine allgemeine CPU-/GPU-Parität und keine Abdeckung anderer Macs. Zahlen aus Lightcraft-Dokumenten werden nicht als PicEdit-Messwerte übernommen.

## Gemessene LC-01-Evidenz

Der vollständige Lauf vom 17. Oktober 2026 ist unter [`reports/lightcraft-evaluation/run-2026-10-17`](../reports/lightcraft-evaluation/run-2026-10-17/) gespeichert. Die [Zusammenfassung](../reports/lightcraft-evaluation/run-2026-10-17/summary.json), [Umgebung und Quell-/Binary-Hashes](../reports/lightcraft-evaluation/run-2026-10-17/environment.json) sowie [exakten Aufrufe](../reports/lightcraft-evaluation/run-2026-10-17/commands.json) gehören zusammen. Das vor der Abnahme eingefrorene Messmanifest hat SHA256 `f07176a58dfcf56f1d7570027dc8ae146ff28b9dbdb34255f785389001e25504`.

Alle **54 Kontrollvergleiche** bestanden: unveränderte Kontrolle, neutrale Core-Image-Brücke und neutrale Rec.2020-Rundreise auf jeweils neun Klassen in beiden Splits. Die übrigen 72 der insgesamt 126 [Qualitätsdatensätze](../reports/lightcraft-evaluation/run-2026-10-17/quality/quality.json) zeigen die vier bestehenden PicEdit-Bearbeitungen als Ausgangswerte. Kein Lightcraft-Referenzalgorithmus wurde damit bewertet. Die unveränderte Kontrolle war bitgenau; der größte sichtbare RGB-Fehler betrug für die neutrale Core-Image-Brücke etwa `5,96 × 10⁻⁸`, für die Rec.2020-Rundreise etwa `1,67 × 10⁻¹⁵`. Alle Kontroll-Alphafehler waren null.

Der Lauf enthielt 20 getrennte Timingprozesse: fünf je Größe, jeweils mit einem prozesskalten Aufruf, einem gesonderten Warmup und fünf warmen Aufrufen. Die Tabelle nennt Median und Spannweite der fünf kalten bzw. 25 warmen Werte; MiB bedeutet 1.048.576 Byte.

| Bildmaß | Prozesskalt: Median [Min–Max], ms | Warm: Median [Min–Max], ms | Höchster Prozess-RSS, MiB |
|---|---:|---:|---:|
| 400 × 267 | 75,879 [71,087–113,015] | 3,954 [3,720–6,685] | 48,3 |
| 2400 × 1600 | 177,616 [166,805–225,204] | 86,830 [84,097–95,152] | 443,7 |
| 4096 × 2731 | 404,611 [397,857–562,502] | 303,306 [298,393–314,214] | 1539,5 |
| 4608 × 3072 | 510,912 [502,951–518,485] | 392,949 [388,942–411,998] | 1960,5 |

Dies sind Ausgangskosten des vollständigen Graphs mit Float-Konvertierung und CPU-Readback. Es gibt keinen Kandidaten- oder Beschleunigungsnachweis. Die warmen Werte sind innerhalb von fünf Prozessen gruppiert; ihre statistische Unabhängigkeit wird nicht behauptet. Für keine Verteilung wird p95 ausgegeben. Der größere Speicherverbrauch gegenüber der historischen sRGB8-Baseline folgt einer anderen Messstrecke mit mehreren Float-Rastern und ist keine nachgewiesene Produktionsregression.

Der [Skalenvergleich](../reports/lightcraft-evaluation/run-2026-10-17/scale/scale.json) stellt den auf 400 × 267 verkleinerten 4608 × 3072-Graphen der direkten Verarbeitung des ebenso verkleinerten Eingangs gegenüber. Der mittlere absolute RGB-Unterschied lag für Tonwerte bei 0,000279, Klarheit bei 0,001120, Farbe bei 0,000203 und Entrauschung bei 0,000207. Diese Werte dokumentieren die vorhandene Skalenabweichung; sie sind kein Kandidatengewinn und kein vollständiger Nachweis über weitere Bildklassen.

Die [beschriftete Ansicht](../reports/lightcraft-evaluation/run-2026-10-17/labeled.html) und [verblindete Paaransicht](../reports/lightcraft-evaluation/run-2026-10-17/blind.html) sind reproduzierbare Sichtprüfungsartefakte. Stichproben der Linien-, Transparenz-, Rausch- und Farbansichten wurden auf plausiblen Bildinhalt und lesbare Differenzen geprüft. Das ist keine abgeschlossene verblindete Bewertung eines Algorithmuskandidaten. Reale Fotos wurden in dieser Reihe nicht verwendet.

## Prüfung und Review

Die abschließende gezielte Prüfung bestand mit **58 Tests in sieben Suites**, einschließlich der isoliert wiederholten bekannten Timeout-Prüfung. Der vollständige App-Testlauf umfasste 521 Tests in 68 Suites und scheiterte an genau der bereits erfassten, unabhängigen [Timeout-Regression unter paralleler Last #47](https://github.com/dr-dimitri/picedit/issues/47). Die 302 Core-Tests in 41 Suites bestanden. Damit wird der vollständige Lauf ausdrücklich nicht als vollständig grün ausgegeben. Die drei Python-Tests für Statistik, Timingphasen und reale Eingangsmanifeste sowie Shell-/Harness-Schutzprüfungen bestanden.

Das finale Review erfasste Fixtures, Metriken, Kandidatengate, Referenz-/Farbbrücken, den vorhandenen Benchmark-Einstiegspunkt, Orchestrierung, Tests und diese Dokumentation. Zugehörige Befunde wurden vor dem Messlauf behoben: Hautfarbabdeckung auch im Abnahmesplit, getrennte CPU-/CI-Kontrolltoleranzen, übereinstimmende Alphahintergründe, Float32-Verkleinerung, überprüfte Momentaufnahmen realer Eingaben und ausdrückliche Ablehnung nicht unterstützter Backendoptionen. Es wurde kein weiterer unabhängiger Bug gefunden; #47 wird wiederverwendet. Lokale Dokumentationslinks und `git diff --check` wurden geprüft.

Der vorgeschriebene saubere vollständige `./scripts/build-app.sh` war erfolgreich. Vorher wurden nach Prüfung auf laufende Builds/Tests die generierten Verzeichnisse `.build/`, `.build-app/` und das bisherige `dist/PicEdit.app` entfernt; es waren keine abweichenden Buildpfade aktiv. Das neue Release-Bundle bestand die Plist- und Signaturprüfung. Die [Prüfprotokolle](../reports/lightcraft-evaluation/validation/) enthalten den Build und beide Swift-Testläufe; ausschließlich nachgestellte Leerzeichen in Compilerdiagnosen wurden normalisiert.

## Kandidatenstand und Quellen

Der [separate LC-03-Bericht](LIGHTCRAFT-TONE-EVALUATION.md) dokumentiert den ersten isolierten Vergleich. Die vorab definierte lokale Kontrastmetrik verbessert sich in den vier moderaten, gematchten Feinlinienfällen numerisch um 95,5023 %. Dennoch scheitert der übertragene V2-Kandidat am Gamut-/Clipping-Gate: Bei Schatten +20 und fast gleicher mittlerer Schattenanhebung steigen beide Anteile um 5,625 Prozentpunkte gegenüber höchstens 2 erlaubten Prozentpunkten. Deshalb **No-Go für diese isolierte Übernahme**, ohne Änderung des Produktionsgraphen. 28 von 72 Fällen sind gematcht; 44 nicht passende oder nicht belegte Fälle und weiterhin fehlende reale/visuelle Abnahme werden nicht als Erfolg ausgegeben. Andere Lightcraft-Verfahren und spätere abweichende Gewichtungen sind damit nicht pauschal bewertet.

Die abschließende [LC-03-v2-Zusammenfassung](../reports/lightcraft-evaluation/lc03-matched-2026-10-17/summary.json) enthält zudem 40 gematchte Timingprozesse über 512/2400/4096/4608 Pixel lange Kante; sämtliche Kostenbudgets des isolierten CPU-Pfads sind eingehalten. Das ist kein Beschleunigungsnachweis für die unveränderte App. Der separate Skalentest zeigt bei Schatten +20 einen mittleren RGB-Unterschied von 0,0315058 beim Kandidaten gegenüber 0,0014454 bei PicEdit und belegt keine Vorschau-/Exportgleichwertigkeit. Die ursprüngliche v1-Last mit unpassender `texture`-Tonwirkung bleibt erhalten; nur Performance-/Skalenszene wurden in v2 geändert. [72 identische Mappings, 72 identische Qualitätsfälle, 96 identische Stufendiagnosen und 552 identische PNG-Hashes](../reports/lightcraft-evaluation/lc03-matched-2026-10-17/reproducibility-comparison.json) sichern, dass der Qualitätsbefund dabei unverändert blieb.

| Kandidat | Zuständiges Folgeissue | Aktueller Vergleichsstand |
|---|---|---|
| Lichter/Schatten, kantenbewusste Tonwertbasis | [LC-03 / #52](https://github.com/dr-dimitri/picedit/issues/52) | No-Go für den isolierten V2-Kandidaten: besserer Float-Linienkontrast, kritische Gamut-/Clippingregression bei gematchter Tonwirkung. |
| Klarheit, gegebenenfalls Textur | [LC-04 / #53](https://github.com/dr-dimitri/picedit/issues/53) | Blockiert: kein isolierter Algorithmusadapter und kein Qualitätsnachweis. |
| Dynamik/Sättigung in OkLab | [LC-05 / #54](https://github.com/dr-dimitri/picedit/issues/54) | Blockiert: kein isolierter Algorithmusadapter und kein Qualitätsnachweis. |
| Klassische Luma-/Chroma-Entrauschung | [LC-06 / #55](https://github.com/dr-dimitri/picedit/issues/55) | Blockiert: kein isolierter Algorithmusadapter und kein Qualitätsnachweis. |

Alle Lightcraft-Quellverweise beziehen sich auf `dr-dimitri/lightcraft@f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`: [`render_impl`/`StageCache`](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/pipeline/src/lib.rs), [`tone_base`, Guided-Filter und NR](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/pipeline/src/local.rs), [`ColorOps`](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/pipeline/src/colorops.rs) und [`oklab_from_2020`/`oklab_to_2020`](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/color/src/perceptual.rs). WGSL ist gegebenenfalls eine separat zu prüfende zweite Implementierung, kein automatisch fehlerfreier Maßstab.

LC-01 kopiert keinen dieser Produktionsalgorithmen. Bei einer späteren Übernahme werden Quellcommit, Datei, tatsächlich kopierte/adaptierte Symbole und Änderungen in der Kandidatenprovenienz aufgeführt. Dazu gehören der vollständige [MIT-Lizenztext](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/LICENSE-MIT) und der Copyright-Hinweis „2026 ArtCraft Team and the LightCraft contributors“; die [NOTICE](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/NOTICE) ist auf weitere betroffene Bestandteile zu prüfen. Marken, Kamera-/Assettabellen, Modelle und Gewichte sind nicht Teil dieses Vergleichsauftrags. Rust/wgpu und Modelldownloads sind keine Voraussetzung.

Für die inzwischen hinzugekommene, ausschließlich experimentelle LC-03-CPU-Referenz sind diese Pflichten in den [Drittanbieterhinweisen](../tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt) und den vollständigen lokalen [MIT](../tools/lightcraft-evaluation/licenses/lightcraft/LICENSE-MIT)-/[NOTICE](../tools/lightcraft-evaluation/licenses/lightcraft/NOTICE)-Kopien erfüllt. Elf eingefrorene Original-Rust-Vektoren prüfen den Swift-Port; ihre [Provenienz und optionale Neuerzeugung](../tools/lightcraft-evaluation/lc03-reference-oracle/README.md) gehören zum Referenzvertrag. Der normale App-Build benötigt weiterhin keinen Rust-Compiler.

Erst ein positiver Kandidat rechtfertigt den minimalen Produktionsvertrag aus [LC-02 / #51](https://github.com/dr-dimitri/picedit/issues/51). Bis dahin bleiben PicEdits Produktionsgraph, gespeicherte Looks, UI und Reglerumfang unverändert.
