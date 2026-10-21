# LC-03: detailerhaltende Lichter und Schatten

Die historischen Rohdaten, Vergleichsbilder, Quellsnapshots und Prüfprotokolle
wurden mit dem bisherigen Ergebnisordner aus dem Repository entfernt. Die
folgenden Messwerte und Entscheidungen bleiben als historische Zusammenfassung
erhalten; die ursprünglichen Einzelartefakte stehen hier nicht mehr zur Verfügung.
Neue Läufe schreiben in ein ausdrücklich gewähltes externes Ergebnisverzeichnis,
beispielsweise unter `/private/tmp/`.

Stand: 17. Oktober 2026. Vergleich zu [Issue #52](https://github.com/dr-dimitri/glowroom/issues/52) nach der [Roadmap #49](https://github.com/dr-dimitri/glowroom/issues/49) auf der [LC-01-Vergleichsgrundlage](LIGHTCRAFT-ALGORITHM-EVALUATION.md). Die Versuchsregeln wurden vor dem ersten Abnahmelauf festgelegt.

## Ergebnis der Qualitätsabnahme: No-Go für den isolierten Kandidaten

Die v2-Reihe wurde mit Umgebung, Quell-/Binary-Hashes und exakten Aufrufen protokolliert. Ein neuer Lauf mit dem aktuellen Quellstand:

```sh
./scripts/evaluate-lightcraft.sh /private/tmp/glowroom-lc03-run --candidate LC-03
```

Die übertragene V2-Basis erhält den lokalen Float-Kontrast der feinen Linien deutlich besser, verletzt mit ihren ursprünglichen Lichter-/Schattengewichten aber das vorab festgelegte Gamut-/Clipping-Gate. Daher wird **dieser isolierte CPU-Kandidat nicht in PicEdits Produktionsgraph übernommen**. Das ist keine Ablehnung aller Lightcraft-Verfahren oder jeder möglichen Verwendung der besseren Steuerbasis. Eine abweichende Gewichtung oder ein neues Ausgabemodell wäre ein neuer Kandidat mit eigenem vorab festgelegtem Vergleich.

Der entscheidende Fall ist `fine-lines / shadows-positive-20`: Beide Seiten erhalten dieselbe vollständig opake Eingabe aus 0,035 und 0,92 linearem RGB, also keine schon ausgebrannten oder außerhalb des sRGB-Würfels liegenden Pixel. PicEdit erzeugt in der festen Schatten-ROI eine mittlere Anhebung von **0,0138252117**, der auf der Abstimmvariante eingefrorene Referenzparameter **84,5703125** erzeugt **0,0138359053**. Die Tonwirkung ist damit innerhalb der erlaubten Toleranz angeglichen. Trotzdem steigen Gamut- und Clippinganteil jeweils um **0,05625 = 5,625 Prozentpunkte**, gegenüber höchstens **2 Prozentpunkten** im vorab festgelegten Gate. Die Metrik zählt sichtbare, alpha-gewichtete RGB-Komponenten; in diesem grauen, opaken Fall entspricht der Anteil auch dem Pixelanteil. Die spätere PNG-/Ausgabebegrenzung kann diese Float-Überschreitung verdecken, aber nicht rückgängig machen. Dieser gematchte kritische Befund genügt für das No-Go.

Die historische Qualitätsreihe umfasste 72 getrennte Abnahmefälle und 96 Stufendiagnosen. **28 von 72** Fällen erreichen das Matching; **44** sind nicht angeglichen oder besitzen keine geeignete Ziel-ROI. Sie zählen weder als bestandene Qualitätsvergleiche noch allein als No-Go. Sieben der gematchten Fälle verletzen mindestens eine kritische Grenze. Das vor der ersten Abstimmung eingefrorene v1-Manifest hat SHA256 `19153efe6b749c6554390f0cfcb7025e8ed28e600358c87cf95290bcb142e371`.

Die erste Reihe hieß `LC03-tone-v1`. Eine getrennte Ergänzungsreihe `LC03-tone-v2` wechselt ausschließlich die Performance-/Skalenfixture von `texture` auf `fine-lines`, deren moderate Tonwirkung bereits angeglichen ist. Matching, Richtungen, Qualitätsgrenzen und Stufendiagnose bleiben identisch; es findet keine Abstimmung anhand der Abnahme und keine Lockerung eines Gates statt. Das aktuelle v2-Manifest hat SHA256 `d1a77063c9e61b92f713f34ad59fd48e9052baeee89a8b4f86900b744845b272`. Die für die Wiederholung geänderten v1-Quellen wurden damals samt ursprünglichen Hashes als Quellsnapshot gesichert.

Der damalige direkte Reproduzierbarkeitsabgleich bestätigte: Alle 72 Kalibrierungsdatensätze, 72 Qualitätsdatensätze und 96 Stufendatensätze sind zwischen v1 und v2 exakt identisch; auch sämtliche 552 Qualitäts-PNGs haben identische SHA256-Werte. Der entscheidende erste Clipping-Befund bleibt unverändert. Nur die Meta-Hashes der JSON-Gesamtdateien ändern sich wegen des neuen Manifests; die eigentlichen Qualitätsdaten ändern sich nicht.

Alle vier moderaten Feinlinienfälle erreichen die Tonangleichung. Ihr gleich gewichteter mittlerer Log-Kontrastfehler sinkt von **0,0697150171** auf **0,0031355793**, numerisch um **95,5023 %**. Diese Werte stammen aus dem unbegrenzten Float-Raster; sie sind wegen des Clipping-Vetos kein freigegebener Bildqualitätsgewinn.

| PicEdit-Regler | Eingefrorener Referenzwert | PicEdit ΔY | Referenz ΔY | PicEdit Kontrastfehler | Referenz Kontrastfehler |
|---|---:|---:|---:|---:|---:|
| Schatten +20 | 84,5703125 | 0,0138252 | 0,0138359 | 0,1018343 | 0,0049470 |
| Schatten −20 | −100 | −0,0113601 | −0,0109399 | 0,1200391 | 0,0058496 |
| Lichter +20 | 8,3984375 | 0,0800000 | 0,0802085 | 0,0255066 | 0,0007739 |
| Lichter −20 | −10,546875 | −0,0899678 | −0,0905988 | 0,0314801 | 0,0009718 |

Die Abnahme verwendet je Richtung 9.126 helle und 9.061 dunkle Linienpaare. Bei Schatten ±40 erreicht die begrenzte Referenz das Ziel dagegen nicht. Für die sechs gematchten harten Kantenfälle bleibt das größte Plateau-Über-/Unterschwingen mit **0,0108953** unter der Grenze 0,02. Die gemessene Alphaabweichung ist in allen 72 Paaren null. Dies widerlegt das Gamut-/Clipping-Veto nicht und ersetzt keine Profil-/Produktionsabnahme.

Weitere kritische Beobachtungen sind zusätzliche Clippinganteile von 0,0870504 bei `colors / highlights-positive-20` sowie maximale Hue-Abweichungen gegenüber PicEdit von 4,4785° beziehungsweise 8,8333° bei `saturation / highlights-positive-20/40`. Diese Hue-Zahlen messen Unterschiede zum bestehenden PicEdit-Look; sie beweisen nicht, dass der Kandidat die ursprüngliche Objektfarbe schlechter erhält. Das No-Go stützt sich bereits unabhängig davon auf den neutralgrauen, gematchten Feinlinienfall.

Die 96 Stufendiagnosen zeigen bei ausgeschaltetem AutoTone keinen Unterschied zwischen den beiden untersuchten Reihenfolgen. Mit AutoTone liegt der mittlere absolute RGB-Unterschied je Fall zwischen 0 und 0,0359140. Das zeigt die Nichtvertauschbarkeit der Stufen, keine beste Reihenfolge: Die Diagnose wurde nicht separat auf gleiche Effektstärke abgestimmt und enthält unterschiedliche Materialisierungspunkte. Für eine Produktionseinbindung ist deshalb keine Stufenposition freigegeben.

Stichproben der beschrifteten Feinlinien- und Farbpaare wurden auf plausiblen Bildinhalt geprüft. Die beschriftete und die verblindete Ansicht dienten der Sichtprüfung; es fand keine abgeschlossene verblindete Präferenzabnahme statt. Reale Porträts, Gegenlichtfotos, Landschaften und hoch-ISO-Aufnahmen fehlen weiterhin. Diese Lücken verhindern eine positive Übernahme, sind aber nicht die Begründung des nachgewiesenen technischen No-Go.

## Gemessene Kosten und Skalen

Die v2-Reihe enthält 40 getrennte Timingprozesse, fünf pro Adapter und Größe, mit jeweils einem prozesskalten Aufruf, einem ausgeschlossenen Warmup und fünf warmen Samples. Alle kalten und warmen Effektstärken sind im vorab definierten Sinn angeglichen. Gemessen wurde auf einem Apple M2 Pro mit 12 CPU-Kernen, 19 GPU-Kernen und 16 GB RAM, macOS 27.0.1 (26A434), Swift 6.4.0.34.1. Die Tabelle zeigt Mediane in Millisekunden und das höchste Prozess-RSS in MiB (1.048.576 Byte); die ursprünglichen Spannweiten und Rohsamples wurden mit dem Ergebnisordner entfernt.

| Bildmaß | PicEdit kalt | CPU-Kandidat kalt | PicEdit warm | CPU-Kandidat warm | PicEdit RSS, MiB | CPU-Kandidat RSS, MiB |
|---|---:|---:|---:|---:|---:|---:|
| 512 × 320 | 54,143 | 5,175 | 2,780 | 0,607 | 44,4 | 19,7 |
| 2400 × 1600 | 118,018 | 67,805 | 54,596 | 13,428 | 442,5 | 208,7 |
| 4096 × 2731 | 252,774 | 211,256 | 160,157 | 38,513 | 1228,7 | 576,9 |
| 4608 × 3072 | 299,913 | 255,386 | 189,847 | 48,598 | 1545,3 | 722,7 |

Die gemessenen Kosten des isolierten CPU-Adapters liegen in dieser Reihe unter den gemeinsamen Budgets; **das No-Go beruht auf Bildqualität, nicht auf einer Kostenverletzung**. Der Referenzadapter übernimmt nur den begrenzten Tonwertbaustein, hat keinen CI-Materialisierungs-/Readback-Schritt und verwendet warm seine vorbereitete Basis wieder. PicEdit rendert den bestehenden Graphen einschließlich seiner gemeinsamen Float-Brücke. Diese Ergebnisse belegen keine allgemeine Überlegenheit von CPU über GPU, keine Beschleunigung der unveränderten App und keine Kosten einer späteren Produktionsintegration. Weder RAW-Decode noch UI-Präsentation wurden in diesem Modus ausgeführt.

Die erste v1-Kostenserie diente als negative Matchingkontrolle. Ihr `texture`-Abstimmfall konnte die Tonwirkung nicht erreichen; der eingefrorene Kandidatenwert war null. Dadurch führten warme Samples nur Exposure aus oder nahmen den neutralen Schnellpfad. Keine v1-Timingphase wurde als gematcht gewertet. Ihre kleineren Zeiten und ihre nullwertigen Kandidaten-Skalenfehler sind weder Geschwindigkeitsgewinn noch Skalentreue-Nachweis. Dieser Befund war der ausdrücklich dokumentierte Grund für die getrennte v2-Lastwahl.

Der v2-Skalentest vergleicht die direkte Verarbeitung bei 400 × 267 mit dem in Float32 von 4608 × 3072 verkleinerten Ergebnis, jeweils mit der eingefrorenen Reglerzuordnung. Das Eingangsmuster enthält pixelbreite Linien; seine Kleinansicht mischt diese mit dem Hintergrund. Die mittleren absoluten RGB-Abweichungen lauten:

| Richtung | PicEdit | CPU-Kandidat |
|---|---:|---:|
| Schatten +20 | 0,0014454 | 0,0315058 |
| Schatten −20 | 0,0014165 | 0,0242540 |
| Lichter +20 | 0,0123754 | 0,0020666 |
| Lichter −20 | 0,0060258 | 0,0024939 |

Die Schattenfälle zeigen hier deutlich größere Skalenabweichungen des Kandidaten. Eine Gleichwertigkeit von Vorschau und Vollauflösung ist somit nicht nachgewiesen. Der Skalentest besitzt keine nachträglich eingeführte Gewinnschwelle und ersetzt das vorab definierte Qualitätsgate nicht. Er liefert eine weitere konkrete Grenze dieser isolierten Übernahme.

## Umfang und Quellen

Untersucht wird ausschließlich die V2-Steuerbasis für Lichter/Schatten aus `dr-dimitri/lightcraft@f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`: Log-Luminanz, separabler Median, kantenbewusster Guided-Filter und die davon gesteuerte lokale EV-Änderung. Der Median verändert die Steuerbasis; er ersetzt keine Bilddetails durch geglättete Pixel. Dies ist weder ein vollständiger Local-Laplacian-Filter noch eine RAW-Lichterrekonstruktion. Bereits ausgebrannte Eingaben enthalten keine rekonstruierbaren Details.

Die Quellanker sind [`local.rs`](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/pipeline/src/local.rs), [`finish.rs`](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/pipeline/src/finish.rs), [`blur.rs`](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/raster/src/blur.rs), [`resample.rs`](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/raster/src/resample.rs) und [`tests_tone.rs`](https://github.com/dr-dimitri/lightcraft/blob/f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15/crates/pipeline/src/tests_tone.rs). Übernommene Symbole, Anpassungen und die gewählte MIT-Lizenz stehen in den [Drittanbieterhinweisen](../tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt); vollständige Lizenz und upstream NOTICE bleiben dabei erhalten.

Der Referenzbaustein benutzt `log2(max(Y, 1e-7) / 0.18)`. V2 wählt einen Medianradius von `min(24, round(0.0015 × pxPerLong))`; anschließend folgt der Guided-Filter mit `sigma = max(1, 0.015 × pxPerLong)` und `epsilon = 0.35`. Guided-Fast begrenzt die Unterabtastung auf `floor(sigma / 3)` zwischen 1 und 16, verwendet Box-Downsampling und bilineares Upsampling der Koeffizienten. Der Gaussian-Helfer benutzt drei Boxfilter mit geklemmten Rändern. `CIGaussianBlur` wäre dafür kein numerisch gleicher Ersatz.

Für die RGB-Änderung gelten `ws = 1 − smoothstep(−4.8, 0.3, base)`, `wh = smoothstep(−1, 2.8, base)` und `deltaEV = shadows × 1.7 × ws × sqrt(ws) + highlights × 1.7 × wh`, jeweils mit auf ±1 normierten Lightcraft-Reglern. RGB wird mit `exp2(deltaEV)` multipliziert. Lightcrafts sonstige Regler, globales Tonmodell, RAW-Entwicklung und Ausgabe-Gamutmapping gehören nicht zum Kandidaten.

Die gemeinsamen Eingaben sind bereits entwickelte Straight-RGB-Pixel in extended linear sRGB mit separatem Alpha. Der Referenzadapter transformiert RGB ausdrücklich nach Rec.2020 und benutzt dort die ursprünglichen Float-Luminanzgewichte 0,2627 / 0,6780 / 0,0593. Der skalare Belichtungsfaktor wird danach direkt auf das ursprüngliche sRGB angewandt: Ein skalarer Faktor kommutiert mit der linearen Farbmatrix und vermeidet eine unnötige Rücktransformation. Die unabhängigen Qualitätsmetriken benutzen weiterhin sRGB-Y mit 0,2126 / 0,7152 / 0,0722. Ein neutraler D65-Patch hat in beiden Räumen dieselbe relative Luminanz; farbige und außerhalb des sRGB-Würfels liegende Pixel benötigen eigene Prüfungen.

Lightcrafts dreikanalige Referenz definiert kein Alpha-Verhalten. Der PicEdit-Adapter gewichtet deshalb Median, Mittelwerte/Korrelationen und Resampling mit der Pixeldeckung und normalisiert räumliche Mittelwerte mit der verfügbaren Deckung. Unsichtbares RGB bleibt kanonisch null; fehlende Unterstützung trägt keinen Bildinhalt bei. Diese Alpha-Anpassung ist ausdrücklich kein upstream Verhalten und benötigt separate Tests für transparente und semitransparente Nachbarschaften.

## Vorab festgelegter Vergleich

Der ausführbare Vertrag ist [`lc03-manifest.json`](../tools/lightcraft-evaluation/lc03-manifest.json). Er wird mit den Ergebnissen eingefroren und gehasht. Änderungen an Metrik, Toleranz, Mapping, ROI oder Kandidat nach Kenntnis der Abnahme erfordern eine neue benannte Versuchsreihe; sie dürfen den ursprünglichen Befund nicht ersetzen.

Alle neun vorhandenen LC-01-Szenen werden in ihren getrennten deterministischen Abstimm- und Abnahmevarianten bei 512 × 320 verarbeitet. Vier moderate Richtungen bilden den primären Vergleich: Schatten +20/−20 und Lichter +20/−20 in PicEdit. Dieselben vier Richtungen bei ±40 sind zusätzlich festgelegte Belastungsfälle. Die moderate Reihe soll eine innerhalb des begrenzten Referenzreglers erreichbare Tonwirkung untersuchen; die stärkere Reihe prüft dessen Grenzen. Ein Lauf mit identischen Reglerwerten dokumentiert die unterschiedlichen Bedienkennlinien. Der entscheidende zweite Vergleich verwendet eine angeglichene mittlere lineare Luminanzänderung, damit ein schwächerer Effekt nicht als Qualitätsgewinn erscheint.

Das Mapping wird ausschließlich aus der Abstimmvariante der jeweiligen Szenenklasse bestimmt. Es ist eine experimentelle Angleichung pro Bildklasse und keine universelle Reglerkennlinie für die Anwendung. Die Schatten-ROI enthält Eingabepixel mit `Y < 0.25`, die Lichter-ROI solche mit `Y > 0.5`; die ROIs hängen weder vom Kandidatenausgang noch von dessen Reglerstärke ab. Ziel ist die vorzeichenbehaftete mittlere Änderung `mean(Youtput − Yinput)` des PicEdit-Reglers. Ein grobes Raster und eine Verfeinerung mit jeweils 33 Kandidatenpunkten suchen innerhalb der zulässigen ±100, mit gleicher Richtung. Je Szenenklasse und Richtung wird genau ein Parameter eingefroren. Die Zuordnung wird auf der getrennten Abnahmevariante derselben Klasse nicht neu optimiert. Konstante Flächen und Graurampen bleiben zusätzliche Kontrollen der Tonwirkung.

Ziel und gemessene Änderung müssen dasselbe von null verschiedene Vorzeichen haben. Ein Ziel unter 0,002 absolutem linearem Y ist nicht aussagekräftig. Der zulässige Matchingfehler beträgt höchstens das Maximum aus 0,003 linearem Y und 5 % des Zielbetrags. Diese Grenze beschränkt verbleibende Tonwirkungsunterschiede; sie beweist keine fotografisch identische Wirkung. Erreicht der begrenzte Kandidat das Ziel nicht, ist die Richtung kein bestandener gematchter Vergleich. Erreichte Änderungen und Abweichungen werden auch auf jeder Abnahmeszene offengelegt.

## Detailerhalt und kritische Grenzen

Das primäre Ziel ist die Erhaltung des lokalen **Log-Luminanzkontrasts** heller Linien auf dunklem und dunkler Linien auf hellem Hintergrund. Für jedes fest aus der Eingabe abgeleitete Linien-/Nachbarschaftspaar gilt `C = log2(Yline / Ybackground)`. Der Fehler je Paar ist `abs(Coutput − Cinput) / max(abs(Cinput), 0.05 EV)`; innerhalb jeder Bildhälfte wird dessen Mittel berechnet. Die ROI verwendet die bekannten hellen Linien (`Y > 0.8`) im dunklen oberen und dunklen Linien (`Y < 0.1`) im hellen unteren Hintergrund. Als Umgebung dient der erste passende Hintergrundpixel in den horizontalen Abständen −2, −1, +1, +2. Der äußere Rand von zwei Pixeln und die beiden Zeilen beiderseits der Halbengrenze werden ausgeschlossen. Eine leere Hälfte ist fehlende Evidenz. Eine gleiche lokale Belichtungsmultiplikation erhält diesen Kontrast. Die Metrik misst sowohl verlorenen als auch künstlich verstärkten Kontrast; ein bloßes Abschneiden negativer Verlustwerte würde Überverstärkung fälschlich belohnen.

Beide Regionen und die vier moderaten Richtungen werden gleich gewichtet und getrennt ausgewiesen. Die ±40-Belastungsfälle werden nicht in den primären Mittelwert gemischt; ein belastbarer kritischer Fehler bei gematchter Tonwirkung bleibt auch dort ein Veto. Das vorab definierte Ziel verlangt mindestens 10 % weniger Fehler gegenüber PicEdit bei angeglichener Tonwirkung. Kein einzelner gematchter Fall darf sich um mehr als 0,05 absolute Fehleranteile verschlechtern. Rauschenergie, geclippte Linien und unbrauchbare Referenzkontraste zählen nicht als Detailgewinn. Die globale LC-01-Gradienten- und Laplace-Energie bleibt ergänzende Diagnostik: Verstärkung, Tonwirkung und Rauschen können diese Werte ohne erhaltene Struktur erhöhen.

Das Halo-Gate benutzt die harte Flächenkante. Bewertet werden feste Streifen beiderseits der Kante gegen das entfernte Plateau derselben Ausgangsseite; ein bereits in der Eingabe bestehender Unterschied zum jeweiligen Plateau wird abgezogen. Über- und Unterschwingen dürfen jeweils 0,02 lineares Y nicht überschreiten. Dies übernimmt die LC-01-Kantentoleranz, normalisiert aber die beabsichtigte Tonänderung heraus. Eine globale Anhebung gegen die unveränderte Eingabehülle wäre allein kein Halo-Nachweis. Die globalen LC-01-Hüllmetriken werden zusätzlich berichtet, jedoch nicht als eigenständiger Beweis einer Tonwertregression verwendet.

Kritische Paarvergleiche gegen den PicEdit-Ausgang verwenden höchstens 3° Hue-Abweichung bei definierter Chroma, 0,02 zusätzliche Gamut-/Clippinganteile und 0,001 Alphaabweichung. Die sRGB-Ansichtsbegrenzung darf außerhalb des sichtbaren Würfels liegende Float-Werte nicht verbergen. Fehlende, nicht endliche oder leere Messwerte bestehen kein Gate. Farbflächen, synthetische Hautfarben, transparente Ränder und Rauschbilder ergänzen den Detail-/Kantenvergleich; sie ersetzen keine realen Fotos.

Die LC-01-Rauschfixture besitzt zwar eine bekannte saubere Referenz, die konkrete LC-03-Qualitäts- und Stufendiagnose übergibt sie jedoch nicht an die Metrikfunktion (`groundTruth: nil`). Dort wird der PicEdit-Ausgang als Vergleich verwendet. Die Felder `luma_noise_rmse` und `chroma_noise_rmse` beschreiben deshalb Abstände zu PicEdit in den dafür ausgewählten Bereichen, keine Restrauchmessung gegen die saubere Fixture. Diese Paardiagnosen und die Kombination mit Denoise belegen keine unabhängige Rauschqualität des Kandidaten.

## Position im vorhandenen Graph

PicEdit verwendet bislang `Denoise → AutoTone → Tone/Color → Presence`. Im kombinierten Tone/Color-Kernel folgen auf Exposure die Gamma-2,2-Arbeitskurve, Kontrast, Lichter/Schatten, Weiß/Schwarz und Farbe. Ein isolierter LC-03-Vergleich darf diesen gesamten Kernel nicht durch Lightcrafts `finish` ersetzen.

Der primäre Qualitätsvergleich arbeitet auf denselben eingefrorenen Float-Eingabepixeln ohne aktive Vorstufen. Der vorgeschlagene spätere Einbaupunkt liegt nach dem bestehenden Denoise und AutoTone, vor dem verbleibenden Tone/Color- und Presence-Schritt. Die zusätzliche Stufendiagnose materialisiert diese Vorstufen für den CPU-Kandidaten, während die PicEdit-Seite ihren vollständigen bestehenden Graphen rendert. Diese zusätzliche Materialisierung ist somit ein Unterschied des Versuchspfads und kann numerische Abweichungen beitragen; beide Seiten erhalten dort nicht schon denselben materialisierten Vorstufenausgang.

Exposure wird genau einmal auf die Kandidatenpixel angewandt; die vor Exposure vorbereitete Log-Basis erhält denselben EV-Offset. Bei einer späteren Integration müsste der nachfolgende bestehende Kernel Exposure und Lichter/Schatten auf null erhalten und die übrigen Einstellungen beibehalten. Ein entsprechender neutraler Vergleich müsste zuerst belegen, dass der zusätzliche Materialisierungspunkt vorhandene Regler nicht unbemerkt ändert. Diese Gleichwertigkeit wird durch die Stufendiagnose nicht nachgewiesen.

Die konkrete Stufendiagnose hält Kontrast, Weiß/Schwarz, Dehaze, Dynamik und Sättigung neutral; nach dem isolierten Tonwertschritt wird der vorhandene Presence-Schritt angewandt. Sie umfasst 96 Kombinationen aus vier Bildklassen, zwei AutoTone-Stufen, vier moderaten Lichter-/Schattenrichtungen und drei Belichtungen, stets mit Luma-Denoise 40 sowie Textur 25/Klarheit 15. Damit ist keine vollständige Kompatibilität aller übrigen Regler und alter Looks nachgewiesen. Die Beschreibung des verbleibenden Tone/Color-Schritts ist der Integrationsvertrag für einen späteren positiven Kandidaten.

Ein separater Diagnosepfad untersucht LC-03 vor AutoTone. Er ist kein weiterer Kandidat, der nachträglich anhand der Abnahme zum Gewinner gewählt werden darf. AutoTone an/aus, Exposure −0,7/0/+0,7 EV sowie Luma-Denoise 40 und Textur 25/Klarheit 15 prüfen die Stufenabhängigkeit. PicEdits AutoTone analysiert ausdrücklich das unveränderte Originalbild; der Diagnosepfad muss diese Quellenidentität erhalten. Die nichtlineare Kurve wird bei veränderter Reihenfolge auf andere Pixel angewandt, weshalb die Stufen trotz identischer Analyse nicht algebraisch austauschbar sind. Eine Aussage über die beste Position muss aus den gemessenen Kombinationen folgen und bleibt auf diese Kombinationen begrenzt.

## Skalierung, Kosten und Entscheidungsregel

Die Radien folgen der expliziten Ausgabe-Pixelskala relativ zum vollständigen Bildraum; ein Crop-/Zoomfenster darf nicht seine eigene Fensterbreite als native Bildlänge ausgeben. Für die unbeschnittenen Fixtures ist `pxPerLong` die native lange Kante multipliziert mit der Ausgabe-/Nativerskalierung. Kleine Bilder, geklemmte Ränder, extreme erlaubte Regler, nicht endliche Parameter und transparente Nachbarschaften gehören zur Referenzprüfung. Nullwerte benötigen weder Basisbildung noch eine neue Bildbearbeitung.

Die Größenmatrix ist 512 × 320, 2400 × 1600, 4096 × 2731 und 4608 × 3072. Konvertierung, erforderliche Materialisierung und CPU-Readback gehören zur Messstrecke; Peak-RSS gehört zum ganzen Prozess. Fünf neue Prozesse mit getrennt ausgewiesenen kalten Aufrufen und mindestens fünf warmen Wiederholungen je Prozess bilden die geplante Vergleichsserie. Prozesskalt bedeutet keinen nachgewiesen kalten Betriebssystem-/Shadercache. Die LC-01-Budgets gelten weiter: höchstens Faktor 1,25 kalt, 1,20 warm und 1,25 Peak-RSS gegenüber der gleichen PicEdit-Strecke. Eine bewusst einfache CPU-Referenz beweist weder die Kosten eines späteren GPU-Pfads noch dessen Gleichwertigkeit. Die Aussage „GPU schneller“ erfordert eine eigene Messung.

Der warme CPU-Pfad verwendet dieselbe unveränderliche `Prepared`-Instanz mit Log-Luminanz und Steuerbasis weiter; nur die Lichter-/Schattenstärke und Exposure ändern sich. Die PicEdit-Seite verwendet denselben `CIContext`, baut ihren vorhandenen `filterGraph` je Sample neu auf und materialisiert das Ergebnis. Das ist ein Vergleich dieser beiden konkreten Wiederverwendungsmöglichkeiten, kein Nachweis eines produktiven Cacheeinbaus. Die erste CPU-Messung enthält die Basisbildung. Fixture-Erzeugung, Hashes, Effektmessung und PNGs liegen auf beiden Seiten außerhalb des Timers. Kostenverhältnisse werden nur für nachweislich gematchte Phasen als Budgetbefund gewertet.

Der separate Skalentest verwendet den bestehenden LC-01-Downsamplingvertrag: 4608 × 3072 wird in Float32 auf 400 × 267 verkleinert und mit der direkten Verarbeitung dieser kleinen Eingabe verglichen. Das ist ein eigener Diagnosemaßstab und kein zusätzlicher 512-Pixel-Timingfall. Die native Größe bleibt dem Kandidaten bekannt; seine räumlichen Radien folgen der tatsächlichen Ausgabeskala.

Vergleichsmessungen laufen seriell, weil konkurrierende CPU-/GPU-Last die Vergleichskosten verfälschen würde. Unabhängige Quellprüfung, Implementierung, Referenztests und Dokumentation können parallel erfolgen. Große Raster werden begrenzt nacheinander verarbeitet; es entsteht kein unbeschränkter Foto-Worker-Pool.

Innerhalb jeder Größe sind die fünf Prozesswiederholungen gepaart: Bei ungeraden Paaren startet PicEdit zuerst, bei geraden der Lightcraft-Kandidat. Diese abwechselnde Reihenfolge begrenzt zeitlichen Last-/Temperaturbias, ohne parallele Messlast oder zusätzliche Samples zu erzeugen. Sie beweist keine vollständige Unabhängigkeit von Systemlast und thermischem Zustand.

Eine reproduzierbare kritische Regression oder ein vollständig gematchter Vergleich ohne das vorab geforderte primäre Qualitätsziel ergibt **No-Go für den untersuchten Kandidaten**. Ein solcher negativer technischer Befund kann trotz noch fehlender realer Fotos ausreichend sein, um diesen Kandidaten abzulehnen. Ohne nachgewiesenen negativen Befund ergeben fehlende notwendige Szenen, Matching, Messungen oder Beurteilungen **blockiert**. **Go** benötigt das primäre Ziel, sämtliche kritischen Fälle, vergleichbare Effektstärke, Budgets, vollständige erforderliche Evidenz und visuelle Abnahme; eine Produktionsintegration benötigt zusätzlich [LC-02 / #51](https://github.com/dr-dimitri/glowroom/issues/51).

Reale Porträts, natürliche Gegenlichtkanten, Landschaftsstruktur und hoch-ISO-Kamerabilder sowie eine verblindete visuelle Freigabe sind im synthetischen Standardsatz weiterhin nicht enthalten. Ein Entwickleradapter belegt keine Produktions-Cache-, Regler-/Bildwechsel-, Abbruch- oder Exportintegration. Bei No-Go bleibt der Produktionsrenderer unverändert; zusätzliche Beschleunigung und Kompatibilitätsmigration sind dann keine Voraussetzung für eine Ablehnung.

## Referenzprüfung und Review

Elf eingefrorene Vektoren aus den ursprünglichen, gepinnten Rust-Funktionen prüfen Median, drei Boxfilter, die vertikale 32-Zeilen-Bandgrenze, Guided-Fast ohne/mit Unterabtastung, V2-Basis sowie Box-/Bilinear-Resampling. Der Vergleich gegen den Swift-Port zeigte auf diesem Rechner einen maximalen absoluten Fehler von **0** bei vorab erlaubten `5e-6`; die Vektoren wurden nicht aus dem Swift-Port erzeugt. Alpha-Anpassungen werden separat geprüft, weil die upstream Referenz kein Alpha definiert.

Die gezielte LC-03-Prüfung bestand mit **25 Tests**, einschließlich Neutralpfad, erlaubten Extremwerten, ungültigen Geometrien/Pixelspeichern, `NaN`/Inf, transparenten Nachbarschaften, Cacheunabhängigkeit, parallel unabhängigen Vorbereitungen, Abbruch und Metrik-/Matching-Grenzen. Die **302 Core-Tests** bestanden. Der vollständige App-Lauf mit **546 Tests** scheiterte ausschließlich an der bereits bekannten unabhängigen [Timeout-Regression #47](https://github.com/dr-dimitri/glowroom/issues/47); die isolierte Wiederholung zusammen mit LC-03 bestand. Der vollständige Lauf wird deshalb ausdrücklich nicht als vollständig grün ausgegeben. Die zehn Python-Tests für bestehende Orchestrierung und neue Entscheidungsgates bestanden; Shellsyntax und lokale Dokumentationslinks wurden geprüft.

Das Review betrachtete Referenz und Originalvektoren, Farbraum-/Alpha-Vertrag, begrenzte Worker, Abbruch, feste Matching-ROIs, vollständige Abnahmematrix, Kalibrierungsprovenienz, Vorzeichen und leere Metrikstützung, zeitlich gepaarte Messreihen, Quellen-/Binary-Unveränderlichkeit sowie diese Dokumentation. Die zusätzliche Stufendiagnose bleibt ausdrücklich außerhalb der Freigabeentscheidung. Für den abgelehnten Kandidaten wurden weder neue UI-Regler noch gespeicherte Prozessversionen, RAW-Decoder, Produktionscaches oder Rust-/GPU-Abhängigkeiten eingeführt.
