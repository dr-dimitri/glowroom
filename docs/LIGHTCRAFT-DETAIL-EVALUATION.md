# LC-04: Klarheit und Textur getrennt vergleichen

Vergleich zu [Issue #53](https://github.com/dr-dimitri/picedit/issues/53) nach der
[Roadmap #49](https://github.com/dr-dimitri/picedit/issues/49). Die isolierte
Referenz ergänzt die [LC-01-Vergleichsgrundlage](LIGHTCRAFT-ALGORITHM-EVALUATION.md)
und verwendet die reinen räumlichen Filter aus
[LC-03](LIGHTCRAFT-TONE-EVALUATION.md). Ein gemeinsamer Filter bedeutet keine
gemeinsame Freigabe der unterschiedlichen Bildwirkungen.

**Ergebnis: separates No-Go für die untersuchte Klarheit und Textur.** Bei
angeglichener Wirkung verfehlt Klarheit das primäre Haloziel und überschreitet
im starken positiven Fall die Grenze für zusätzliches Überschwingen. Textur
verbessert die moderaten Halo-Messwerte, überschreitet aber bei +60 ebenfalls
die Überschwinggrenze. Der bestehende Produktionsrenderer bleibt erhalten;
LC-02 wird durch diesen Vergleich nicht ausgelöst.

## Reproduktion und Umfang

```sh
./scripts/evaluate-lightcraft.sh /tmp/picedit-lc04-run --candidate LC-04
python3 -m unittest discover -s tools/lightcraft-evaluation -p 'test_*.py'
```

Die Referenz verwendet den gepinnten Lightcraft-Stand
`f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`. Sie verarbeitet identische, bereits
entwickelte Straight-RGBA-Float32-Pixel in extended linear sRGB. Der skalare
EV-Gain aus der ausdrücklich nach Rec.2020 konvertierten Luminanz wird auf die
ursprünglichen RGB-Werte angewandt. Alpha bleibt separat erhalten; räumliche
Mittelwerte berücksichtigen die Deckung, damit unsichtbares RGB nicht in
sichtbare Nachbarpixel gelangt.

Untersucht werden Guided-Klarheit in Log-Luminanz und separat die
Gaussian-basierte Textur. Die Texturablation trennt den Helligkeitsraum von der
Detailbegrenzung: gleicher Gaussian und Radius mit PicEdits bestehender
Gamma-/Additionswirkung, mit unbegrenztem Log-Detail sowie mit Lightcrafts
begrenztem und kantenabhängig gedämpftem Log-Detail. PicEdits bestehender
Produktionsrenderer ist ein eigener Vergleichspfad. Ein gemeinsamer Radius in
den Ablationen ersetzt nicht die Messung gegen diesen tatsächlichen Pfad.

Die CPU-Referenz erzeugt nur die zum gewählten Effekt benötigten Ebenen. Eine
unveränderliche Vorbereitung kann bei Regleränderungen wiederverwendet werden;
sie ist an Eingabepixel, Variante und Geometrie gebunden. Das ist ein begrenzter
Versuch im Entwickler-Harness, keine neue Cache- oder Prozessarchitektur der
App. Der bestehende begrenzte Worker-Pool der LC-03-Filter wird wiederverwendet.
Abhängige Filterpässe und Vergleichsmessungen laufen seriell; konkurrierende
Benchmarks oder Builds würden die Kostenmessung verfälschen.

## Verfahren und Vergleichsvertrag

Für Klarheit gilt `sigma = max(1, 0.012 × pxPerLong)` und Guided-Filter-Epsilon
0,8. Das Log-Detail wird auf ±2,5 EV begrenzt. Die Verstärkung beträgt
`clarity × 0.85 × detail × (0.35 + 0.65 × exp(-(base / 3.2)²))`, bei einem
auf ±1 normierten Regler. Ohne andere Lightcraft-Tonregler ist `base` die
ursprüngliche Log-Luminanz, nicht die Guided-Klarheitsbasis. Diese Unterscheidung
ist im isolierten Referenzadapter ausdrücklich erhalten.

Die Textur verwendet `sigma = max(0.6, 0.0018 × pxPerLong)`. Die vollständige
Kandidatenwirkung ist `texture × 1.1 × clamp(detail, -1, 1) × tame`, mit
`tame = 1 - 0.6 × smoothstep(0.4, 1.6, abs(detail))`. Die unbegrenzte
Log-Variante lässt Begrenzung und `tame` weg. Die Variante im bisherigen
PicEdit-Helligkeitsraum nimmt nach dem Gaussian auf linearem RGB dessen
Gamma-Luminanz und addiert die mit 0,9 gewichtete Differenz in Gamma-RGB.
Alle drei Texturablationen verwenden dieselbe Gaussian-Implementierung und
denselben Radius. Die zusätzliche Gaussian-Klarheit behält die Log-Domäne,
Gewichtung und Begrenzung der Guided-Klarheit bei und ersetzt nur den Filter.

Das [ausführbare Manifest](../tools/lightcraft-evaluation/lc04-manifest.json)
fixiert die Regeln vor der ersten Abnahme. Positive und negative moderate
Reglerwerte sowie stärkere Belastungsfälle werden getrennt geprüft. Die
Abstimmung verwendet eine begrenzte Parametersuche auf dem Tuning-Split;
dieses Mapping wird danach gehasht und auf der Abnahme nicht nachjustiert.
Ein Mapping je Szene ist eine experimentelle Angleichung, keine universelle
Kennlinie für den Regler in der App.

Die Reglerfälle sind ±20 und ±60, davon ±20 für die primäre Abnahme. Eine
Effektänderung unter 0,0002 linearem RMS-Y ist nicht aussagekräftig. Für
gleichgerichtete Änderungen beträgt die zulässige Abweichung höchstens das
Maximum aus 0,00001 RMS-Y und 5 % der PicEdit-Wirkung. Die Suche umfasst 33
grobe Punkte und 33 Punkte zur Verfeinerung innerhalb der zulässigen ±100.
Diese Toleranz und alle Grenzwerte wurden vor der ersten Messung festgelegt.

Die Effektstärke ist die vorzeichenbehaftete Änderung des lokalen
RMS-Luminanzkontrasts. Die Eingabe bestimmt die Messmaske; starke Kanten und
die separate Rauschregion gehören nicht zur Detailmessung. Zusätzliche
schwache Strukturproben erlauben auch bei einer harten Kante eine vom Halo
unabhängige Angleichung. Das primäre Halo-Maß verwendet die mittlere absolute
Abweichung vom entfernten Plateau derselben Kantenseite. Größe der Messregion,
Saumbreite und maximales Überschwingen werden zusätzlich ausgewiesen.

Klarheit und Textur erhalten jeweils eine eigene Entscheidung. Nur gematchte
Fälle dürfen einen Qualitätsgewinn oder ein kritisches Veto belegen; der
exakte Nullstellungsvertrag wird davon unabhängig geprüft. Nicht
erreichte Effektstärken bleiben fehlende Evidenz. Die Texturablationen werden
zusätzlich paarweise verglichen, damit ein Effekt des Radius oder des
Helligkeitsraums nicht pauschal der Detailbegrenzung zugeschrieben wird.

Das primäre Ziel verlangt mindestens 10 % weniger mittlere Halo-Abweichung über
beide Kantenszenen und beide moderaten Richtungen, mit höchstens 0,02 absoluter
Regression je Fall. Die gemeinsamen kritischen Grenzen sind 3° Hue-Abweichung,
0,02 zusätzliche Gamut-/Clippinganteile und 0,001 Alphaabweichung gegenüber
PicEdit. Zusätzlich dürfen maximales Kantenüberschwingen um höchstens 0,03
lineares Y und Rauschverstärkung um höchstens 2 % relativ zunehmen. Das sind
konservative technische Versuchsgrenzen, keine empirisch ermittelten
Wahrnehmungsschwellen. Die Rauschmessung benutzt die Differenz aus verrauschtem
und sauberem Bild nach derselben Bearbeitung; die Effektangleichung dieser
Szene verwendet das bekannte saubere Bild.

Die Detailmaske hält zusätzlich einen Abstand von mindestens vier Pixeln bzw.
5 % der Bildbreite von starken Eingabekanten. Die Maske wird bei der Abstimmung
und beim Timing einmal vorbereitet und wiederverwendet. Die Halo-Messung
fordert Unterstützung auf der hellen und der dunklen Seite. Die Nullstellung
wird über identische Float-Raster-Hashes geprüft; Aufnahmen bei −1 und +1
dokumentieren den Übergang, ohne eine nicht definierte Kontinuitätsschwelle
vorzutäuschen.

Die erste vollständige Reihe `LC04-detail-v1` bleibt unter
[`lc04-2026-10-17`](../reports/lightcraft-evaluation/lc04-2026-10-17/summary.json)
erhalten. Ihre Texturwirkung in den beiden primären Kantenszenen lag selbst
bei ±60 unter der Mindestwirkung von 0,0002. Bei Klarheit verschob die
unterschiedliche Flächenaufteilung der harten Kante die Wirkung der eingefrorenen
Abstimmung um etwa 9 %. Das bedeutet fehlendes Matching, keinen Sieg durch
geringere Stärke. Die v1-Primärvergleiche bleiben deshalb blockiert; ein
separater gematchter Farbunterschied überschreitet dort das Klarheitsgate.

Vor der Ergänzungsreihe `LC04-detail-v2` wurde ausschließlich die Unterstützung
der beiden primären Testbilder korrigiert: Ihre obere Hälfte enthält nun ein
unabhängiges neutralgraues Detailfeld, mit linearer Basis 0,18 und zwei
Sinuskomponenten der Amplitude 0,02 und Perioden acht bzw. 32 Pixel bei 512
Pixeln Breite. Die feste Messregion umfasst dort `x=64..<448, y=48..<112`;
ganzzahlige Phasenverschiebungen trennen Abstimmung und Abnahme bei identischem
Eingangskontrast und gleicher Anzahl von Paaren. Die untere Hälfte mit allen
Halo-Messpunkten bleibt pixelgleich zu v1. Algorithmen, Reglerfälle, Grenzwerte,
andere Szenen und Performanceprotokoll bleiben unverändert. Die
[v1-Quellsnapshots](../reports/lightcraft-evaluation/lc04-2026-10-17/source-snapshot/README.md)
sind gegen die ursprünglichen Hashes geprüft; keine Messreihe wird überschrieben
oder mit der anderen zu einem günstigeren Ergebnis gemischt.

Das neutrale Probe-Feld normiert die Effektstärke auf festgelegten Frequenzen
und einer Helligkeit. Es beweist keine identische Wirkung über alle Farben,
Helligkeiten oder echten Fotomotive. Die ursprünglichen v1-Befunde bleiben
deshalb separat verfügbar.

## Qualitätsentscheidung

Die vollständige
[v2-Zusammenfassung](../reports/lightcraft-evaluation/lc04-matched-2026-10-17/summary.json)
enthält 140 Qualitätsfälle einschließlich der Ablationen. **94 sind gematcht**:
40 von 56 Klarheitsfällen und 54 von 84 Texturfällen. Alle primären
Kantenszenen bei ±20 besitzen passende Effektstärke und Unterstützung auf
beiden Kantenseiten. Nicht gematchte Farb-/Transparenz- und schwache
Rauschfälle liefern weder Qualitätsgewinn noch Veto.

| Primärer Vergleich bei ±20 | PicEdit bzw. Ablation | Kandidat | Relative Verringerung des Halo-Maßes |
|---|---:|---:|---:|
| Guided-Klarheit gegen PicEdit | 0,0078090 | 0,0080764 | **−3,43 %**, Ziel verfehlt |
| Begrenzte Log-Textur gegen PicEdit | 0,0028864 | 0,0023175 | **19,71 %** |
| Begrenzte Log-Textur gegen denselben Gaussian in bisheriger Domäne | 0,0032579 | 0,0023175 | **28,86 %** |
| Begrenzte gegen unbegrenzte Log-Textur | 0,0070485 | 0,0023175 | **67,12 %** |

Die Werte sind Mittel über harte Kante und Himmel/Zweige sowie positive und
negative moderate Wirkung. Die Texturablation belegt auf diesen synthetischen
Szenen einen numerischen Zusatznutzen der Kombination aus Log-Domäne und
Begrenzung. Die unbegrenzte Log-Domäne allein verbessert den bisherigen
Gaussian hier nicht. Dieser Befund ersetzt die Prüfung der starken Werte nicht.

Zwei unabhängig vom Farbvergleich gemessene Belastungsfälle verhindern die
Übernahme:

| Gematchter Fall | PicEdit / Kandidatenregler | RMS-Y-Änderung PicEdit / Kandidat | Maximales Überschwingen PicEdit / Kandidat | Zusätzliche Abweichung |
|---|---:|---:|---:|---:|
| Harte Kante, Klarheit +60 | 60 / 51,5625 | 0,00958709 / 0,00959718 | 0,0502374 / 0,1166224 | **0,0663851 > 0,03** |
| Himmel/Zweige, Textur +60 | 60 / 50,1953 | 0,00147638 / 0,00147621 | 0,1471679 / 0,1995279 | **0,0523601 > 0,03** |

Auf Himmel/Zweige bei +60 überschreiten außerdem die maximalen
Farbtonabweichungen gegenüber PicEdit die 3°-Grenze: 16,2535° für Klarheit und
37,2194° für Textur, jeweils mit 81.920 auswertbaren farbigen Pixeln.
Das ist eine **Kompatibilitätsgrenze gegenüber PicEdit**, kein Nachweis
schlechterer Farbtreue zum Original: Ein positiver skalarer linearer RGB-Gain
erhält den Eingabefarbton mathematisch; PicEdits Gamma-/Additionswirkung und
Begrenzung können ihn anders verändern. Schon die eigenständigen
Überschwingbefunde reichen hier für beide No-Go-Entscheidungen.

In v1 überschreitet der gematchte Klarheitsfall Himmel/Zweige +60 diese
Kompatibilitätsgrenze ebenfalls: 9,3692° bei nur 0,01166 % Abweichung der
Detailwirkung. Sein Halo-Maß sinkt zugleich um 31,81 % und sein Überschwingen
um 18,41 %. Dies ist kein pauschaler Befund schlechterer Kanten oder Farben.
Die v1-Texturentscheidung bleibt wegen fehlender Primärunterstützung
**blockiert**; erst die getrennte v2-Reihe belegt das Textur-No-Go.

Alle 105 Diagnoseaufnahmen bei −1/0/+1 sind vorhanden; Null erhält für jede
Szene und Variante exakt den Eingaberaster-Hash. Die 96 Stufendiagnosen
vergleichen die Detailwirkung vor/nach manuellen Tonwertänderungen nach
gemeinsamer Entrauschung/AutoTone. Sie dokumentieren die Abhängigkeit von der
Reihenfolge und sind keine freigegebene Produktionsintegration. Paarbilder,
Differenzen und eine Blindansicht liegen im Bericht; es wurde keine
abgeschlossene Blindabnahme behauptet.

Die gematchten Rauschfälle halten die 2-%-Grenze ein. Bei Klarheit beträgt
die größte zusätzliche Rauschverstärkung 0,257 %, bei Textur +60 sind es
1,072 %. Für Textur ±20 ist die saubere Zielwirkung dieser Szene zu schwach;
daraus folgt keine bestandene moderate Rauschabnahme. Die Farb- und
Transparenzszenen liefern wegen fehlendem Matching ebenfalls keine positive
Qualitätsfreigabe, auch wenn ihre separaten Neutralitäts-/Alpha-Verträge
geprüft werden.

Der [Reproduktionsvergleich](../reports/lightcraft-evaluation/lc04-matched-2026-10-17/reproducibility-comparison.json)
bestätigt zwischen v1 und v2 **100 identische Mappings, 100 identische
Qualitätsfälle, 96 identische Stufendiagnosen, 75 identische Nullübergangsdiagnosen,
724 identische Qualitäts-PNGs und alle 16 identischen Skalenfälle** außerhalb
der beabsichtigten Änderung. Genau drei gehashte Swift-Quellen unterscheiden
sich; ihre v1-Snapshots sind verifiziert. Das v2-Manifest hat SHA256
`94c6aedd328c1034852952cc9bbf7833beb09acb24c44335a7528d237459bb5d`, die vor der
Abnahme eingefrorene Kalibrierung
`a7c52ea8afb2c35fc9754397ae300ba2804a3a7282f22ec8ee570d14d88141ea`.

## Kosten und Vorschau-/Exportskala

Gemessen auf Apple M2 Pro mit zwölf CPU-/19 GPU-Kernen und 16 GB Speicher,
macOS 27.0.1, Apple Swift 6.4, Release-Konfiguration. Je Regler, Größe und
Adapter laufen fünf getrennte Prozesse mit je einem kalten Durchlauf, einem
ausgeschlossenen Aufwärmlauf und fünf warmen Reglerwerten (18 bis 22).
Damit entstehen 80 Prozesse und 400 warme Samples. Die Reihenfolge der
Adapter wechselt je Wiederholung; alle Messungen laufen ohne konkurrierende
Builds/Tests. Betriebssystem-/Treiber-Caches werden nicht geleert, warme
Samples innerhalb eines Prozesses sind keine unabhängigen Wiederholungen.

Die Zeit umfasst bereits entwickelte Float32-Eingaben bis zum materialisierten
Float32-Ergebnis, einschließlich Core-Image-Graph, Konvertierung und Readback
oder CPU-Vorbereitung und Anwendung. Warm wird der CIContext bzw. die
unveränderliche aktive Referenzebene wiederverwendet. RAW-Decodierung, UI,
PNG-Ausgabe und Metriken liegen außerhalb der Zeitgrenze. Peak-RSS ist das
Maximum des gesamten Prozesses, einschließlich gemeinsamer Eingabe und
vorbereiteter Diagnosemaske. Es ist kein isolierter Kernel-Speicherwert.

Alle Zahlenpaare nennen **PicEdit / CPU-Referenz**; Zeitwerte sind Mediane in
Millisekunden, Speicher ist Peak-RSS in MiB. Bereiche und Rohsamples stehen
in der [Zusammenfassung](../reports/lightcraft-evaluation/lc04-matched-2026-10-17/summary.json).

| Effekt, Größe | Kalt ms | Warm ms | Peak-RSS MiB | Wirkung in allen Phasen gematcht |
|---|---:|---:|---:|---|
| Klarheit 512 × 320 | 56,395 / 4,490 | 2,947 / 0,651 | 47,3 / 19,9 | ja |
| Klarheit 2400 × 1600 | 120,189 / 53,356 | 52,576 / 14,479 | 452,5 / 203,4 | ja |
| Klarheit 4096 × 2731 | 292,784 / 145,790 | 199,480 / 42,248 | 1554,1 / 555,8 | ja |
| Klarheit 4608 × 3072 | 347,090 / 183,353 | 249,591 / 52,941 | 1885,9 / 695,8 | ja |
| Textur 512 × 320 | 54,492 / 2,236 | 2,829 / 0,613 | 47,3 / 17,8 | ja |
| Textur 2400 × 1600 | 115,581 / 53,838 | 52,271 / 13,620 | 452,5 / 184,5 | **nein**, Kostendiagnose |
| Textur 4096 × 2731 | 288,434 / 159,246 | 200,127 / 39,445 | 1522,0 / 507,0 | **nein**, Kostendiagnose |
| Textur 4608 × 3072 | 343,882 / 200,026 | 254,607 / 49,625 | 1869,5 / 637,3 | **nein**, Kostendiagnose |

Kein gematchter Kostenvergleich überschreitet die vorab festgelegten Faktoren
1,25 kalt, 1,20 warm und 1,25 Peak-RSS. Die größeren Texturfälle erhalten wegen
fehlender Effektangleichung keine Performancefreigabe. Die Werte sind keine
Beschleunigungsmessung der App: Beide Algorithmen sind verschieden, die
Referenz wird nicht integriert, und ein neuer beschleunigter Pfad wurde nicht
implementiert. Es gibt keinen zusätzlichen Decoderaufruf im Regler-Harness;
reale RAW-Wechsel, UI-Latenz und Produktionscaches wären separat abzunehmen.

Der [Skalenvergleich](../reports/lightcraft-evaluation/lc04-matched-2026-10-17/scale/scale.json)
prüft dieselbe Mauer-/Textilszene direkt bei 400 × 267 gegen das verkleinerte
Ergebnis von 4608 × 3072. Die Werte sind mittlere absolute RGB-Differenzen
innerhalb des jeweiligen Adapters, bei eingefrorenen Parametern:

| Reglerfall | PicEdit | CPU-Referenz |
|---|---:|---:|
| Klarheit +20 | 0,0001941 | 0,0003237 |
| Klarheit −20 | 0,0001711 | 0,0003013 |
| Klarheit +60 | 0,0005449 | 0,0009794 |
| Klarheit −60 | 0,0003567 | 0,0007806 |
| Textur +20 | 0,0002496 | 0,0005131 |
| Textur −20 | 0,0002374 | 0,0004944 |
| Textur +60 | 0,0007327 | 0,0015625 |
| Textur −60 | 0,0006439 | 0,0014127 |

Die Referenz zeigt in allen acht Fällen größere Skalenabweichungen. Das ist
eine Diagnose auf dieser Szene und keine Vorschau-/Exportfreigabe. Gerade bei
Textur verbietet das unvollständige Größenmatching einen gleichwertigen
Qualitäts-/Kostenvergleich über alle Auflösungen.

## Referenzprüfung

Die zwölf eingefrorenen
[Original-Rust-Fälle](../tools/lightcraft-evaluation/lc04-reference-oracle/README.md)
prüfen Guided-Filter mit und ohne Unterabtastung, Gaussian-Textur, Mittengewicht,
Begrenzung und `tame` bei negativen, neutralen und positiven Werten. Ihre
Neuerzeugung aus den verifizierten Quellhashes und die anschließende unabhängige
Reproduktion bestanden. Der normale App-/Testbuild benötigt keinen Rust-Compiler.

Der gezielte Swift-Lauf besteht mit **112 Tests in zwölf Suites**. Er umfasst
die neuen Referenz-/Messverträge, LC-03, die LC-01-Farbbrücken und Metriken sowie
`EditRendererTests`, `EditRenderSessionTests`, `AdjustedPreviewPipelineTests`,
`JPEGExporterTests` und `AutoToneRendererTests`. Die Tests prüfen unter anderem
8-/16-Bit-sRGB-/P3-Eingaben, Alpha, vorzeichenbehaftete Farben, Nullstellung,
Abbruch, Quellen-/Geometriewechsel und die Wiederverwendung vorbereiteter Ebenen.
**31 Python-Tests** prüfen die getrennten Entscheidungen, fehlende Evidenz,
Matching, Nullstellung und die Zuordnung von Kostenverletzungen zu tatsächlich
angeglichenen Phasen.

Nach der Ergänzung des v2-Probes bestehen erneut **41 native Tests in fünf
Suites**, einschließlich zweier neuer Prüfungen für die gleiche
Effektunterstützung der Splits, die unveränderte untere Bildhälfte und die
Unabhängigkeit der Detailmessung von Haloänderungen. Die 31 Python-Tests
bestehen auch mit dem v2-Manifest.

Die [Validierungsprotokolle](../reports/lightcraft-evaluation/lc04-validation/)
bewahren auch die anfänglichen Hindernisse: Der erste Harness-Build konnte
innerhalb der Sandbox die gepinnten Abhängigkeiten nicht auflösen. Der erste
Swift-Testbuild scheiterte an zwei inzwischen korrigierten Swift-Testing-
Makroausdrücken. Ein anschließender Sandbox-Testlauf wurde nach Diagnose einer
blockierten Metal-Geräteinitialisierung kontrolliert beendet. Der erfolgreiche
Swift-Testlauf erfolgte mit normalem Core-Image-/Metal-Zugriff.

Der abschließende vollständige Release-Build mit
`PICEDIT_BUILD_JOBS=6 ./scripts/build-app.sh` bestand nach bestätigtem Ende
aller Messungen/Tests und vollständiger Entfernung von `.build/`, `.build-app/`
und `dist/PicEdit.app`. Es waren keine abweichenden Buildpfade gesetzt und
kein aktiver Build-Lock vorhanden. Bundle-Plist und Signaturprüfung bestanden.
Das [Buildprotokoll](../reports/lightcraft-evaluation/lc04-validation/clean-build.log)
enthält den vollständigen Neuaufbau. Die anfänglichen Build-/Testprobleme
sind oben dokumentiert; der finale Build ist erfolgreich.

Der finale Diff-, Schnittstellen-, Test- und Dokumentationsreview erfolgte
mit getrennten Verantwortlichkeiten für Referenz/Oracle, native Messung und
Python-Orchestrierung. Die Präzisierungen zur Nullstellung, zur gemeinsamen
Wirkung von Log-Domäne und Begrenzung und zu den LC-01-Standardgrößen wurden
übernommen und erneut geprüft. Es bleiben keine offenen Reviewbefunde; es
wurde kein unabhängiger neuer Bug gefunden. Beschriftete Paarbilder der
entscheidenden Fälle wurden zusätzlich auf plausible Artefakte geprüft;
das ist keine verblindete Präferenzabnahme.

## Quellen und Grenzen

Die tatsächlich übernommenen Symbole und Anpassungen stehen in den
[Drittanbieterhinweisen](../tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt).
Die vollständigen [MIT-Lizenz](../tools/lightcraft-evaluation/licenses/lightcraft/LICENSE-MIT)
und [NOTICE](../tools/lightcraft-evaluation/licenses/lightcraft/NOTICE) bleiben
beigefügt. Kein RAW-Decoder, globales Lightcraft-Tonmodell, wgpu-Backend,
Kameraprofil, Modell oder zusätzlicher Regler wird übernommen.

Die synthetischen Szenen besitzen getrennte deterministische Abstimm- und
Abnahmevarianten. Sie bilden kontrollierte Kanten, Zweigstrukturen, Haut-/Poren-,
Mauer-/Textilmuster und Rauschen ab, ersetzen aber keine lizenzierten realen
Fotos. Paarbilder und eine erzeugte Blindansicht bedeuten keine abgeschlossene
visuelle Präferenzabnahme. Ein positiver synthetischer Befund allein kann
deshalb keine Produktionsfreigabe erteilen. Fehlende Evidenz wird von einem
nachgewiesenen technischen No-Go getrennt.

Der native App-Graph, gespeicherte Bearbeitungen, Source-/Cache-/Undo-Verträge
und Originaldateien werden durch die Referenz nicht geändert. Eine spätere
positive Integration würde zusätzlich LC-02 sowie die vollständige
Produktionsabnahme einschließlich Profile, Bit-Tiefen, Abbruch und
Vorschau-/Exportkonsistenz erfordern.
