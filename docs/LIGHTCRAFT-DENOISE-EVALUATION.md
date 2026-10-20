# LC-06: Entrauschung und native Vorschau-Skalierung

Die historischen Rohdaten, Vergleichsbilder, Quellsnapshots und Prüfprotokolle
wurden mit dem bisherigen Ergebnisordner aus dem Repository entfernt. Die
folgenden Messwerte und Entscheidungen bleiben als historische Zusammenfassung
erhalten; die ursprünglichen Einzelartefakte stehen hier nicht mehr zur Verfügung.
Neue Läufe schreiben in ein ausdrücklich gewähltes externes Ergebnisverzeichnis,
beispielsweise unter `/private/tmp/`.

Vergleich zu [Issue #55](https://github.com/dr-dimitri/picedit/issues/55) nach
[Roadmap #49](https://github.com/dr-dimitri/picedit/issues/49), begonnen auf
aktualisiertem `main` bei `f75a5e131e7de1c674b768c905dfeb9be6e03f43`.
Luminanzverfahren, Chromaverfahren und native Skalierung erhalten getrennte
Entscheidungen. Der Versuch führt weder einen KI-Denoiser noch ein RAW-Backend
oder weitere Regler ein. Die bestehenden Produktionspfade werden erst bei
belegtem Go und abgeschlossenem LC-02 verändert.

**Ergebnis: drei getrennte No-Go-Entscheidungen.** Luminanz verfehlt den
Detail-/Kantennachweis, Chroma verletzt auch an normalen Farblinien die
Detail-/Farbsäumgrenzen. Die native Skalierung verbessert die Übereinstimmung
zur Vollauflösung deutlich, erhält aber die Rauschminderung nicht innerhalb
der vorher festgelegten Grenzen. Deshalb erfolgt keine Produktionsübernahme;
LC-02 wird durch dieses Ergebnis nicht ausgelöst. Positive Teilbefunde und
fehlende Evidenz bleiben neben den Vetos unten zusammengefasst.

## Reproduktion und eingefrorene Referenz

```sh
./scripts/evaluate-lightcraft.sh /private/tmp/picedit-lc06-run --candidate LC-06
python3 -m unittest discover -s tools/lightcraft-evaluation -p 'test_*.py'
```

Die Referenz isoliert `local::{detail_scale,nr_radius,nr_params,apply_nr}`
aus Lightcraft `f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`. Beide Seiten
erhalten dieselben bereits entwickelten Straight-RGBA-Float32-Pixel in
extended linear sRGB. Die Referenz konvertiert explizit nach Rec.2020 und
zurück. Profile, Weißabgleich, Tonmodell, Schärfen und andere lokale Werkzeuge
gehören nicht zum isolierten Filter. `nr_detail`, `nr_color_detail` und
`nr_color_smoothness` bleiben fest bei 50. Diese Kalibrierung wird nicht anhand
der Abnahme verändert. Das upstream wirkungslose `nr_contrast` wird nicht
als funktionierender Regler übernommen.

Luminanzentrauschung verwendet den vollständigen selbstgeführten Guided-Filter
auf `log2(max(Y2020,1e-7)/0.18)`, **nicht `guided_fast`**, und multipliziert
RGB mit `exp2((filtered-original)*k)`. Die Farbentrauschung glättet
`RGB/max(Y2020,1e-6)` mit dem ursprünglichen Gaussian aus drei Box-Pässen,
mischt die Chromatizität und multipliziert mit dem ursprünglichen Y. Erst
danach begrenzt sie jeden Rec.2020-Kanal nach unten auf null. Die Ausgabe in
sRGB kann weiterhin negative Komponenten enthalten; kein zusätzlicher
Gamutmapper oder stiller Eingabe-Clamp wird eingeführt.

Bei vollständig negativer Luminanz ist diese originale Chromarechnung nicht
robust: Das unabhängige Original-Rust-Oracle liefert für den einzelnen
Rec.2020-Pixel `[-0.2,-0.1,-0.05]` bei Farbe 60 ungefähr
`[24661.002,12330.501,6165.2505]`. Die Referenz bewahrt und testet diesen
Quellbefund. Er ist kein hinzugefügter Swift-Fehler. Der Luma-Pfad erhält
signiertes RGB ebenfalls bewusst; die Log-Luminanz folgt dem originalen Floor.

Null bleibt exakt identisch einschließlich des Eingabehashes. Alpha wird
unverändert weitergegeben, unsichtbares RGB auf null kanonisiert. Die
räumlichen Filter erhalten bei Transparenz eine Alpha-Gewichtung, damit
unsichtbare Pixel keine Farbe in sichtbare Nachbarn tragen. Diese PicEdit-
Anpassung wird separat vom originalen opaken Rust-Oracle geprüft.

Die CPU-Referenz verwendet den bestehenden begrenzten LC-03-Zeilenpool.
Gaussian-Pässe und Farbkanäle bleiben geordnet: zusätzliche äußere Worker
würden denselben Pool überbelegen und mehr große Ebenen gleichzeitig halten.
Es entsteht kein neuer Produktionscache oder Decoder. Parameterwechsel
erzeugen die dazu passenden Ebenen neu; Null und der originale Subpixel-Fade
überspringen unnötige Farbraum- und Filterarbeit.

## Vorab festgelegter Qualitätsvergleich

Das [Manifest](../tools/lightcraft-evaluation/lc06-manifest.json) fixiert
256 × 160 Pixel, acht Klassen, zwei Regler und die Werte 20/60/100:
48 Qualitätsfälle. Die Klassen sind dunkle/helle flache Felder, dunkle
Kanten, feine Graulinien, isoluminante Farblinien, Textilmuster,
Transparenz und dunkle P3-Randfarben. Untere dunkle Flächen können durch
die ausdrücklich ungeklemmte Störung negative Luminanz enthalten.

Rauschfreie Ground Truth wird für jede Szene gespeichert. Deterministische,
voneinander unabhängige Counter-PRNG-Seeds erzeugen unterschiedliche
Rauschrealisierungen für Tuning und Abnahme bei derselben sauberen Szene.
Unabhängige uniforme Störungen besitzen Standardabweichung 0,012 in Y und
0,010 in den beiden linearen Opponenten R−Y/B−Y; das helle Feld verwendet
0,035 beziehungsweise 0,025. Dies ist ein kontrollierter synthetischer
Vergleich, kein universelles Sensormodell oder unabhängiger Motiv-Holdout.

Die obere Fläche ist konstant. Das Matching misst nur innerhalb
`x ∈ [width/8,7*width/8)`, `y ∈ [height/16,3*height/16)` mit Abstand zur
unteren Struktur. Der unabhängige Detailbereich liegt in der unteren
Bildhälfte. Vor dem ersten Messlauf ergänzte Webblock-Grenzen im Textilmuster
stellen bei allen nativen Vorschaugrößen eine aussagekräftige feste
Kantenmaske sicher; die feinen Sinusmuster bleiben zusätzlich enthalten.

Luminanz ist `Y=.2126R+.7152G+.0722B`. Chromarauschen und Farbsäume werden
als RMS der Differenzen in R−Y/B−Y gemessen, in linearen RGB-Einheiten.
Diese Messung verwendet keine Division durch Y und bleibt nahe Schwarz und
bei signierten Komponenten definiert. Die Stärke ist
`1 − RMSE(Ausgabe,GroundTruth)/RMSE(Eingabe,GroundTruth)` im flachen Bereich.
So wird eine nahezu unveränderte Ausgabe nicht durch einen Restnoise-Quotienten
nahe eins scheinbar angeglichen. Das Ziel muss positiv und mindestens 0,0002
sein; die Abweichung darf höchstens `max(0,00001,5% der Rauschminderung)` sein.

33 grobe und 17 verfeinernde Stützstellen suchen je Szene/Regler/Stärke
einen Referenzwert zwischen 0 und 100 ausschließlich im Tuning-Split.
Kalibrierung, Eingaben, Ground Truth, Manifest, Quellen und Binary werden
vor der Abnahme gehasht. Die Abnahme verwendet ihre eigene Noise-Realisierung
und prüft das Matching erneut. Es gibt keine Abnahme-Nachjustierung oder
Verallgemeinerung des szenenspezifischen Mappings zur Reglerkennlinie.

Die primären Klassen sind dunkle Kanten, feine Graulinien, Farblinien und
Textilmuster bei 20 und 60. Pro Regler müssen sowohl Detail-RGB-RMSE gegen
Ground Truth als auch RGB-Gradienten-RMSE an festen Ground-Truth-Kanten im
gleich gewichteten Mittel um mindestens 10 % sinken. Der Kantenmaskensatz
hängt ausschließlich von sauberen RGB-Differenzen ab; stärkeres Restrauchen
kann nicht als zusätzlicher Kantenerhalt zählen. Die numerischen Floors sind
jeweils 0,00001; unterhalb des Floors muss die Referenz darin bleiben.
Einzelfälle dürfen sich höchstens um `max(0,00001,10% des Baselinefehlers)`
verschlechtern. Fehlender Support, fehlendes Matching oder ausschließlich
uninformative Baselines blockieren eine Freigabe.

Kritische zusätzliche Grenzen gegenüber PicEdit sind 0,005 absolute
Luminanzdrift gegen Ground Truth, 0,005 Farbsäum-RMSE an den festen Kanten,
0,02 zusätzlicher Gamut-/Clippinganteil und 0,001 Alphaabweichung. Der
Clippinganteil zählt alpha-gewichtete RGB-Komponenten an oder außerhalb 0/1;
dies ist ein technischer Guard, kein automatischer sichtbarer Bandingnachweis.
32 unabhängige Null-/1-Diagnosen prüfen exakte Neutralität, endliche Werte,
Alpha und verborgenes RGB unabhängig vom Stärke-Matching.

Die bekannten [Schattenprobleme #1129](https://github.com/storytold/lightcraft/issues/1129)
und [Farbsaumprobleme #815](https://github.com/storytold/lightcraft/issues/815)
wurden als Quell-/Fehlerbeschreibungen gelesen. Die synthetischen dunklen
Flächen und feinen Farbgrenzen prüfen entsprechende Fehlerklassen; die
ursprünglichen RAW-Fotos und ihre konkrete Pipeline wurden nicht reproduziert.
Es gibt keine aus den fremden Abbildungen abgeleitete Fotofreigabe.

## Separate Skalierungsentscheidung

`nativeLong` und `pixelsPerLongEdge` bezeichnen die ursprüngliche ganze lange
Bildkante, nicht die Breite eines Crops oder Tiles. Die Referenz unterscheidet
native, nachweislich flächengemittelte und unbekannt resampelte Eingaben.
Native Daten verlangen keinen verkleinerten Maßstab. Bei unbekanntem
Decoder-Resampling skaliert die geometrische Radius-/Blend-Regel, während
Epsilon konservativ auf nativem Niveau bleibt. Nur bei nachgewiesener
Flächenmittelung wird die ursprüngliche `scale²`-Annahme angewandt.

Für Radien unter einem Pixel blendet `nr_radius` die kleinste tatsächlich
erzeugte Box-Approximation nach dem Verhältnis ihrer Varianzen ein. Unter
1 % Blend überspringt die originale Regel den Filter. Die Skalierungsablation
`unscaled` setzt Radius, Blend und Epsilon auf den nativen Maßstab; die
Filterformel und der eingefrorene Reglerwert bleiben identisch.

Die Skalierungsreihe erzeugt eine feste native Textilszene mit 4608 × 3072
Pixeln und mittelt noisy Input sowie Ground Truth explizit auf
512 × 341, 2400 × 1600 und 4096 × 2731. Der separable Resampler integriert
die tatsächlichen rechteckigen Pixelüberlappungen, arbeitet dazwischen
premultipliziert und dividiert erst am Ende durch Alpha. Nichtganzzahlige
Skalierungen besitzen andere diskrete Varianzen als ideale gleich große
Blöcke; die Ergebnisse prüfen die `scale²`-Näherung tatsächlich, statt deren
Genauigkeit vorauszusetzen.

Die vorab berechnete Varianz der Flächengewichte
illustriert diese Grenze. Für unabhängiges natives Rauschen ist der
Varianzfaktor das Produkt der mittleren Summen quadrierter Überlappungsgewichte
beider Achsen. Das ist eine analytische Eigenschaft des Resamplers, keine
nachträgliche Anpassung von Epsilon oder Abnahmetoleranzen.

| Vorschau | Tatsächlicher mittlerer Varianzfaktor | Ursprüngliches `scale²` |
| --- | ---: | ---: |
| 512 × 341 | 0,0118773 | 0,0123457 |
| 2400 × 1600 | 0,1853781 | 0,2712674 |
| 4096 × 2731 | 0,3938703 | 0,7901235 |

54 Datensätze vergleichen für beide Regler und alle drei Stärken die
skalierte Formel, dieselbe unskalierte Formel und PicEdit. Die Referenzvarianten
teilen sich exakt die native Ausgabe. Direkte Vorschau wird mit der
flächengemittelten nativen Ausgabe verglichen. Je Regler muss die mittlere
kontrollbezogene Luma-/Chroma-RMS-Distanz um 10 % sinken; pro Fall gilt
höchstens 0,002. Ein Fehler unter 0,000001 bietet keinen informativen
Verbesserungsnachweis.

Eine neutrale Vorschau darf nicht allein durch scheinbare Invarianz gewinnen:
Die Rauschminderung muss positiv sein und mit der gemittelten nativen Ausgabe
innerhalb `max(0,02,10% ihrer Minderung)` übereinstimmen. Detail-, Kanten- und
Farbsäumfehler gegen die größenrichtig gemittelte Ground Truth dürfen sich
gegenüber der gemittelten nativen Ausgabe höchstens um
`max(0,001,10% des Vergleichswerts)` verschlechtern. Alle Support- und
Hashbeziehungen werden unabhängig geprüft. PicEdits Skalierungsdaten sind
eine eigene Diagnose und verleihen der Referenz keine Freigabe.

Eine gemessene hilfreiche Radiusregel wäre noch kein Nachweis für die
vorhandene Decode-Pipeline: Das Experiment hat ihre Quellen nicht decodiert
und übergibt Samplingherkunft ausdrücklich. Produktionsintegration würde
die tatsächlichen Native-/Source-/Resampling-Metadaten sowie Prozess-,
Cache-, Undo-/Abbruch- und Exportverträge zusätzlich benötigen.

## Laufzeitverfahren und Grenzen

Pro Regler werden 512 × 320, 2400 × 1600, 4096 × 2731 und 4608 × 3072 Pixel
mit jeweils fünf getrennten Prozessen pro Adapter gemessen. Jeder Prozess
liefert einen kalten Wert, eine Aufwärmung und fünf warme Werte. PicEdit
verwendet dabei 18–22; die Referenz proportional skalierte eingefrorene
Mappingwerte. Alle Zeitwerte werden nur bei tatsächlich passender gemessener
Rauschminderung zugeordnet. Kalt bedeutet frischer Prozess, keine gelöschten
Betriebssystem-/Shadercaches. Die Adapterreihenfolge wechselt je Wiederholung.

Die Zeitgrenze umfasst Konvertierung, sämtliche benötigten räumlichen Ebenen,
Rendern, Materialisierung und Rücklesen. Die Fixture-Erzeugung und Metriken
liegen außerhalb; Prozess-RSS umfasst dagegen auch Ground Truth, Eingabe und
Validierung. Die Referenz verwendet keinen vorbereiteten Cache, da schon
der NR-Regler Radius und Epsilon verändert. Sie wird nicht als warmes
Apply-only gegen einen vollständigen PicEdit-Render verglichen.

Die Budgets sind 1,25-fache kalte Latenz, 1,20-fache warme Latenz und
1,25-facher Prozess-RSS. Alle Messprozesse bleiben seriell, um CPU/GPU und
Speicher nicht durch konkurrierende Builds zu belasten. Unabhängige Entwicklung,
Reviews und Tests verwenden dagegen getrennte Zuständigkeiten und Buildpfade.
Ein isolierter CPU-Befund prognostiziert keine optimierte CI-/Metal-Integration
oder vollständige RAW-Decodierzeit.

32 zusätzliche Stufendiagnosen kombinieren NR bei 20 mit Exposure,
Schatten/Lichtern, Dehaze und AutoTone. Sie enthalten Zwischenmaterialisierung,
Clamp-/Rundungsgrenzen und veränderte AutoTone-Neuanalyse; sie isolieren keine
reine Reihenfolge bei festem Tonmodell und ersetzen keine Produktionsprüfung.

## Gemessene Qualität am 18. Oktober 2026

Die historische Qualitätsreihe
umfasste 48 Fälle. Luminanz ist in 18 von 24, Chroma in allen 24 Fällen
angeglichen. Alle acht primären Fälle je Regler sind gematcht und besitzen
unabhängigen Noise-, Detail- und Kantensupport. Die sechs übrigen Luma-Fälle
bleiben als Matchinglücke sichtbar; sie begründen keine Qualitätsaussage.

| Primärvergleich, acht gleich gewichtete Fälle | PicEdit | Referenz | Veränderung |
| --- | ---: | ---: | ---: |
| Luminanz: Detail-RGB-RMSE | 0,0135623 | 0,0137984 | 1,74 % schlechter |
| Luminanz: Kanten-RMSE | 0,0216732 | 0,0198389 | 8,46 % besser, Ziel 10 % verfehlt |

Auch die Einzelfallgrenzen scheitern: Luminanz 60 verschlechtert den
Detailfehler an dunklen Kanten um 13,01 % und im Textilmuster um 11,63 %;
dessen Kantenfehler steigt um 15,23 %. Damit ergibt sich ein eigenständiges
**No-Go für die Luminanzformel**. Vier gematchte Fälle verletzen zusätzlich
fünf kritische Grenzen: vier Gamutguards und einen Farbsäumguard.
Die Gamutbefunde sind als Ausgabekompatibilität zu lesen: Insbesondere die
P3-Ground-Truth besitzt selbst negative sRGB-Komponenten, welche die Referenz
erhält und PicEdits materialisierte Ausgabe begrenzt. Ein höherer Gamutanteil
beweist dort keinen neu erzeugten Farbfehler.

Die **Chromaformel erhält ebenfalls No-Go**. Im ungeklemmten Dark-edge-Fall
erzeugt das quellgetreue RGB/Y-Verfahren sehr große Fehler; bei Wert 20 steigt
der Detail-RMSE von 0,01356 auf 1,84652, bei 60 von 0,01257 auf 1,29175.
Diese Ausreißer dominieren die aggregierten Mittel, weshalb eine einzelne
Prozentzahl das Ergebnis schlecht beschriebe. Die Entscheidung hängt aber
nicht von diesen negativen-Y-Pixeln allein ab: An den Farblinien steigt der
Detailfehler bei 20/60 um 21,58 %/64,48 %, der Kantenfehler um 26,74 %/22,44 %.
Der Farbsäum-RMSE steigt bei Farblinien 20 von 0,01552 auf 0,02144 und bei
Transparenz 20 von 0,01851 auf 0,02757. Insgesamt verletzen zwölf gematchte
Chroma-Fälle 23 kritische Grenzen. Die ursprünglichen Einzelwerte wurden mit dem Ergebnisordner entfernt.

Alle 16 Null-Hashes sind exakt, sämtliche 32 Null-/1-Diagnosen bestehen.
Die Qualitätsausgaben sind endlich; Alpha- und verborgenes-RGB-Fehlermaß
sind null. Die beschrifteten Farblinien-/Dark-edge-Bilder wurden als technische
Darstellung geprüft. Das war keine verblindete Bevorzugungsstudie.

## Skalierungsergebnis

Die 54 historischen Skalierungsdatensätze
umfassten alle drei Varianten, drei Vorschauen und sechs Reglerfälle. Alle
18 Referenzvergleiche besitzen vollständigen Noise-/Detail-/Kantensupport
und denselben verifizierten nativen Ausgangsraster. Die gemeinsam getestete
Radius-/Blend-/Epsilon-Regel
liefert einen deutlichen positiven Teilbefund:

| Kontrollbezogene RMS-Distanz zur gemittelten nativen Ausgabe | Unskaliert | Native-Pixel-Regel | Verbesserung |
| --- | ---: | ---: | ---: |
| Luminanz, neun gleich gewichtete Fälle | 0,00140192 | 0,00033306 | 76,24 % |
| Chroma, neun gleich gewichtete Fälle | 0,00248233 | 0,00011128 | 95,52 % |

Alle kontrollbezogenen Distanzen der skalierten Referenz bleiben unter 0,002;
auch Detail-, Kanten- und
Farbsäumguards bestehen. Trotzdem folgt ein **eigenständiges Skalierungs-No-Go**:
Sieben Fälle verletzen die Rauschminderungsgrenze, sechs für Luminanz und
einer für Chroma. Beispielsweise beträgt die Luma-Minderung bei 60 in der
512er Vorschau nur 0,01282 gegenüber 0,09355 nach Verkleinerung der nativen
Ausgabe. Bei 4096 und Luma 20 ist sie umgekehrt stärker: 0,07667 statt 0,04478.
Chroma 20 erreicht bei 512 nur 0,03035 statt 0,06954. Die Verbesserung
der räumlichen Konsistenz rechtfertigt somit keine behauptete konstante
Entrauschungswirkung. Dieser Befund lehnt die unveränderte getestete Regel
ab; er widerlegt nicht jede denkbare native Radiusmodellierung.

Die bekannte Varianzabweichung nichtganzzahliger Flächenmittelung ist eine
Grenze der `scale²`-Annahme, erklärt aber ohne separate Ablation nicht alle
gemessenen Unterschiede. Es wurde weder Epsilon nachjustiert noch eine
skalierte PicEdit-Produktionsvariante als vermeintlicher Gewinner integriert.

## Laufzeitmessung und fehlende Attribution

Gemessen auf Apple M2 Pro, 12 CPU-/19 GPU-Kernen, 16 GB, macOS 27.0.1,
Swift 6.4, Release. 80 getrennte Prozesse liefern 80 kalte, 80 ausgeschlossene
Warmup- und 400 warme Werte. Jede Tabellenzelle nennt **PicEdit / CPU-Referenz**;
die Latenzen sind Mediane, der RSS-Wert das größte Prozessmaximum je Gruppe.

| Regler | Pixel | Kalt, ms | Warm, ms | Peak-RSS, MiB |
| --- | --- | ---: | ---: | ---: |
| Luminanz | 512 × 320 | 57,05 / 4,58 | 3,08 / 3,85 | 52,2 / 29,5 |
| Luminanz | 2400 × 1600 | 130,64 / 87,72 | 54,71 / 74,06 | 501,3 / 350,5 |
| Luminanz | 4096 × 2731 | 293,69 / 252,10 | 200,65 / 207,36 | 1668,1 / 994,5 |
| Luminanz | 4608 × 3072 | 344,96 / 316,07 | 256,16 / 258,68 | 2054,8 / 1255,9 |
| Chroma | 512 × 320 | 55,68 / 4,47 | 2,98 / 3,82 | 51,0 / 28,3 |
| Chroma | 2400 × 1600 | 121,11 / 89,63 | 51,50 / 75,57 | 500,8 / 365,2 |
| Chroma | 4096 × 2731 | 277,13 / 260,10 | 202,18 / 219,30 | 1667,8 / 1037,5 |
| Chroma | 4608 × 3072 | 371,56 / 327,89 | 255,46 / 275,06 | 2055,1 / 1309,8 |

**Keines der 280 gepaarten Wirkungssamples ist angeglichen.** Das eingefrorene
Mapping aus dem 256er Qualitätsvergleich generalisiert nicht auf die größeren
nativen Rauschfelder. Beispielsweise erreicht PicEdit bei Luma 20 und 4608
eine Minderung von 0,15048, die Referenz 0,04824; bei Chroma sind es 0,17451
und 0,12762. Daher sind alle acht Timinggruppen ausschließlich
Kostenbeobachtungen. Weder die geringere kalte Latenz/der geringere RSS noch
die höheren warmen Werte begründen einen Gewinn oder ein Performance-Veto
bei gleicher Wirkung. Die Qualitäts-No-Gos sind davon unabhängig. Für einen
späteren fairen Leistungsnachweis wären vorab getrennt abgestimmte
Größenmappings nötig, keine nachträgliche Umdeutung dieser Reihe.

Die damaligen Rohdaten erfassten Streuung und sämtliche Einzelsamples. Fünf kalte
Prozesse liefern kein belastbares p95; native synthetische Raster ersetzen
keine RAW-Decodier-/Cache-End-to-End-Messung. Reale dunkle/helle Foto-Raster,
Original-Problemaufnahmen, Blindabnahme und optimierte CI-/Metal-Parität
bleiben ausdrücklich offen. Kein positiver Produktionsnachweis wird daraus
abgeleitet.

## Prüfung und Abschluss

Die damalige Prüfung ergab 90 bestandene native Tests in zehn Suites, 78 bestandene Python-Tests,
40 unabhängig regenerierte Original-Rust-Fälle und den generischen LC-01-
Smoke-Test mit 126 Datensätzen ohne Kontrollfehler. Der saubere vollständige
`./scripts/build-app.sh` nach sicherer Entfernung von `.build/`, `.build-app/`
und `dist/PicEdit.app` ist erfolgreich (100,72 Sekunden); Plist und Signatur
wurden geprüft.

Das abschließende Review umfasst den finalen Diff, Quellen-/Raster-/Renderer-
Schnittstellen, Metriken, Abbruch-/Profil-/Alpha-/Resamplingtests, Gateauswertung
und Dokumentation. Zwei vor der Messung gefundene Runner-Lücken sowie die
abschließenden Formulierungspräzisierungen sind behoben und nachgeprüft.
Alle 186 eingefrorenen Quellhashes stimmen; es gibt keine offenen Reviewbefunde
oder neu gefundenen unabhängigen Bugs. Originalbilder, gespeicherte Looks,
die zwei vorhandenen Rauschregler und der Produktionsgraph bleiben erhalten.

## Herkunft

Die adaptierten Symbole und Anpassungen stehen in
[THIRD-PARTY-NOTICES](../tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt).
Die vollständige [MIT-Lizenz](../tools/lightcraft-evaluation/licenses/lightcraft/LICENSE-MIT)
und [NOTICE](../tools/lightcraft-evaluation/licenses/lightcraft/NOTICE)
sind enthalten. Das [Original-Rust-Oracle](../tools/lightcraft-evaluation/lc06-reference-oracle/README.md)
ist optional regenerierbar; die Anwendung und ihre Tests benötigen keinen
Rust-/Lightcraft-Checkout. Kameratabellen, Modelle und fremde Fotos werden
nicht übernommen.
