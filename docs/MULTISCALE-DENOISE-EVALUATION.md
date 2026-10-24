# Kantenbewusste Multiskalen-Entrauschung — Issue #175

Die neue, eigenständig geschriebene Evaluation prüft Glowrooms aktuellen
V2-Produktionsfilter gegen drei kantenbewusste, nicht dezimierte L/C-Bänder.
Sie aktiviert keinen neuen Produktionsfilter. Die drei No-Go-Entscheidungen
aus [#55 / LC-06](LIGHTCRAFT-DENOISE-EVALUATION.md) bleiben unverändert. Der
neue Kandidat verwendet weder dessen Guided-Luma-/RGB/Y-Verfahren noch dessen
Lightcraft-Skalierungsregel. Es wird kein GPL-Code übernommen und weder
darktable noch Lightcraft zur Laufzeit oder zum Testen benötigt.

## Arbeitsraum und Einbaupunkt

Der Vertrag aus [#168](TONE-PIPELINE-VALIDATION.md) gilt: Die Eingabe ist ein bereits
entwickeltes, orientiertes Float-Raster in extended linear sRGB, D65, mit
geradem RGB und separatem Alpha. Der invertierbare Arbeitsraum ist
`L = .2126R + .7152G + .0722B`, `C1 = R-L`, `C2 = B-L`. Die Rücktransformation
ist `R=L+C1`, `B=L+C2`, `G=L-(.2126C1+.0722C2)/.7152`. Alle drei Kanäle
verwenden lineare Einheiten relativ zum nominalen SDR-Weiß 1. Es gibt keine
Lab-Normierung, keine Division durch L, keine logarithmische Schwarzwertgrenze
und kein Abschneiden negativer oder über 1 liegender Komponenten. Das ist
ein entwickelter L/C-Raum; keine Sensordomäne und kein Rauschprofil.

Luma und Chroma werden unabhängig geschwellt. Jedes Band verwendet geordnete
Abstände 1, 2, 4 Pixel, einen 3×3-Tent-Kern und separate rationale L-/C-
Kantengewichte. Auch isoluminante Farbkanten beeinflussen die Gewichte.
Die Banddetails werden mit Soft-Thresholding rekonstruiert; nur die entfernten
Residuals werden in RGB zurückgerechnet. Null umgeht diese Rechnung exakt.
Alpha bleibt erhalten, vollständig verborgenes RGB ist kanonisch null.
Teiltransparente Nachbarn werden mit ihrer Bedeckung gewichtet. Replizierte
Ränder erlauben auch 1×1-Bilder.

Die vorab eingefrorenen Schwellen sind 0,04/0,028/0,018, die beiden
Kantennormierungen 0,06. Die einzige Kennlinie ist
`Bandschwelle × Reglerwert/100`. Diese analytisch gewählten Startwerte wurden
nicht an Abnahmedaten optimiert. Die Suchwerte für eine faire Wirkung werden
ausschließlich auf dem unabhängigen Tuning-Split eingestellt. Es entstehen
keine weiteren Produktregler. EXIF-ISO, RAW-Transformationen, Anscombe,
Sensorprofile und KI sind nicht beteiligt.

Der Produktionsfilter liegt vor NaturalBalance, Weißabgleich/Farbentwicklung,
Tonwerten und Präsenz. Für die isolierte Messung bleiben diese Stufen und
Schärfung neutral. Die Baseline verwendet ausdrücklich `consistentV2` und
Float-Core-Image-Arbeitsformat RGBAf; echtes synthetisches HDR schaltet den
HDR-Ausgabepfad explizit ein. Eine Baseline erhält exakt dasselbe entwickelte
Raster wie der Kandidat. Es wird kein RAW pro Regler erneut decodiert.

## Eingefrorenes Protokoll und Ausführung

Das [Manifest](../tools/multiscale-denoise-evaluation/manifest.json) definiert
alle Gates vor der Abnahme. Der Runner kopiert es, hasht das Binary, alle
Swift-Quellen, Paketdateien und den Runner, prüft Unverändertheit vor/nach
jedem Prozess und bindet die Kalibrierung per Hash an die Abnahme.

```sh
BINARY="$(./scripts/build-developer-tool.sh editing)"
python3 tools/multiscale-denoise-evaluation/run.py \
  /private/tmp/glowroom-multiscale-175 --binary "$BINARY"
python3 -m unittest discover -s tools/multiscale-denoise-evaluation -p 'test_*.py'
```

`--extended` ergänzt 80 getrennte Timingprozesse und 54 native/preview-
Vergleiche. Währenddessen dürfen keine anderen Benchmarks oder Builds laufen.
Das Modul verwendet die bestehende Editing-Harness mit den Modi
`multiscale-denoise-tune|quality|timing|scale`; kein zweiter Produktionsrenderer.
Ausgabeordner dürfen nicht vorhanden sein. Ergebnisse liegen lokal; private
Testbilder werden im Standardlauf weder eingelesen noch kopiert oder veröffentlicht.

Die LC-06-Fixtures, Ground Truth, feste flache Noise-ROI und saubere
Detail-/RGB-Kantenmasken werden wiederverwendet. Synthetische Hautfarben und
HDR erweitern dunkle/helle Flächen, dunkle Kanten, feine Linien, isoluminante
Farblinien, Textilien, Transparenz und P3 auf zehn Szenen. Die Hautprobe ist
ein analytisches Textursignal, kein Beleg für echte Gesichtsfotografie.
Tuning und Abnahme haben identische saubere Wahrheit, unterschiedliche feste
Rausch-Seeds. 90 Fälle prüfen Luma, Chroma und beide gemeinsam bei 20/60/100.
Je aktive Komponente werden 33 grobe und 17 feine Suchpunkte ausschließlich
im Tuning-Split geprüft. Die Abnahme übernimmt unveränderte Parameter und
prüft die Wirkung erneut. Ein szenenspezifisches Matching ersetzt keine
allgemeine neue Produktkennlinie.

Matching bedeutet positive Rauschminderung `1-RMSE(output,clean)/RMSE(input,clean)`
von mindestens 0,0002 und höchstens `max(0,00001,5% Ziel)` Abweichung.
Bei 20/60 müssen Detail-RGB- und feste Kanten-RMSE im gleich gewichteten
Primärmittel jeweils um mindestens 10% sinken. Primär sind dunkle Kanten,
feine Graulinien, Farblinien, Textur und Haut. Floor ist 0,00001;
Einzelfallregression höchstens `max(0,00001,10% Baselinefehler)`.
Nichtinformative Mittel, fehlender Support und fehlendes Matching blockieren
Go. Ein kritischer gematchter Fehler oder eine vollständige primäre
Gateverletzung ergibt ein Qualitäts-No-Go pro Teilverfahren.

Kritisch sind höchstens 0,005 zusätzliche absolute Luminanzdrift,
0,005 Farbsäum-RMSE, 0,02 zusätzliche Zielgamut-/Grenzanteile und 0,001
Alphafehler. Gamut/Grenze wird alpha-gewichtet vor der finalen
Ausgabebegrenzung geprüft: lineares sRGB [0,1], für P3 ausdrücklich lineares
Display-P3 [0,1], für das als HDR erzeugte Signal linear sRGB [0,4]. Die
D65-Matrix ist die Inverse der Fixture-Matrix. Eingangsanteile, gesamte
Ausgangsanteile und neu außerhalb liegende Komponenten sind getrennt.
Die alten LC-06-Zähler am extended-sRGB-Würfel heißen ausdrücklich
`extended_srgb_cube_diagnostic_*`; sie entscheiden keine P3-/HDR-Freigabe.
Die Grenzen sind technische Guards, keine Wahrnehmungsschwellen.

Die optionale Skalierung beginnt bei 4608×3072 und integriert noisy Input,
Ground Truth und native Ausgabe mit dem bestehenden exakten,
alpha-gewichteten Flächenresampler auf 512×341, 2400×1600, 4096×2731.
Direkte Vorschau wird mit verkleinerter nativer Ausgabe für Baseline und
Kandidat verglichen. Vorab gelten jeweils 0,002 RGB-/Luma-/Chroma-RMSE,
0,001 Alpha und eine Wirkungsdifferenz von höchstens `max(0,02,10%)`.
Detail-, Kanten- und Farbsaumfehler dürfen höchstens `max(0,001,10%)` steigen.
Der Kandidat verwendet bewusst feste diskrete Bandabstände; eine günstigere
native Radiusregel wird nicht unterstellt. Es gibt keine `scale²`-Annahme.
Tatsächliches Decoder-Resampling ist hier nicht belegt und bleibt offen.

## Ressourcen und Grenzen

Bänder laufen abhängig seriell. Pixelzeilen nutzen höchstens vier Worker,
die synchron auf disjunkte Ausgabebereiche schreiben; es gibt keine
verschachtelten Pools. Zwei Approximationspuffer und ein Residualpuffer
werden pro Aufruf wiederverwendet. Das CPU-Rasterverfahren ist stateless,
prüft Abbruch vor jeder Phase und während der GCD-Arbeit über einen
synchronisierten Abbruchzustand. Wiederholte A→B→A-Aufrufe verwenden keinen
fremden Zustand. Diese Eigenschaften werden getestet, ersetzen aber keine
Produktionsprüfung verspäteter UI-Ergebnisse, Rendergenerationen oder Undo.
Der Aufrufer muss die synchrone Evaluation außerhalb des MainActor ausführen.

Der Kern hält mindestens drei RGBA-Float-Arbeitsraster (48 Bytes/Pixel),
plus Eingabe und finales Ergebnis. Swift-CoW und temporäre Bindungen können
kurz weitere Vollraster halten; reale RSS-Spitzen müssen gemessen werden.
Bei 4608×3072 sind allein drei Arbeitsraster etwa 648 MiB. Das ist ein
explizites Preview-/Exportbudgetrisiko; kein gemessener RSS-Gewinn.
Der Speicher-Preflight plant konservativ 96 Bytes/Pixel plus 64 MiB und
begrenzt diesen Plan auf höchstens 1,75 GiB sowie ein Viertel des physischen
RAM. Zu große Aufträge schlagen vor Scratch-Allokation kontrolliert fehl;
dies ist eine konservative Schätzung, kein gemessener RSS-Wert.
Eine spätere CI-Implementierung dürfte die Gerätewahl Core Image überlassen;
der jetzt geprüfte Kandidat ist CPU-only, keine GPU-Paritätsbehauptung.

Timing misst vollständige Adapter einschließlich Konvertierung,
Materialisierung/Rücklesen, ohne Fixture-Erzeugung/Metriken. Prozess-RSS
enthält dagegen Eingabe, Ground Truth und sämtliche Prozessressourcen.
Pro Regler und Größe laufen fünf getrennte Prozesse je Adapter mit einem
kalten Sample, einer Aufwärmung und fünf warmen Samples. Adapterreihenfolge
wechselt. Kalt bedeutet Prozessneustart, keine geleerten OS-/Shadercaches.
Das Qualitätsmapping wird auf jeder gemessenen Größe erneut auf positive
gleiche Wirkung geprüft; ungematchte Zeiten dürfen keinen Geschwindigkeits-
oder RSS-Vorteil begründen. Budgets sind 1,25× kalt, 1,20× warm, 1,25× RSS.

Ein angeforderter Core-Image-Softwarepfad wird gegenüber automatischer
Baselinewahl diagnostisch verglichen. Diese Anforderung allein belegt keine
tatsächliche CPU-Ausführung. Der CPU-Kandidat hat derzeit keinen CI-/GPU-
Gegenpfad. Es werden deshalb keine Beschleunigung, CPU/GPU-Gleichwertigkeit
oder vollständigen RAW-/Cache-Laufzeiten behauptet.

## Ergebnis und getrennte Entscheidungen

**Produktionsfreigabe Luma: No-Go. Produktionsfreigabe Chroma: No-Go.**
Die gemeinsame Variante erhält ebenfalls keine Freigabe. Der versionierte
Legacy-/V2-Produktionsgraph und die beiden Produktregler bleiben unverändert.
Der finale Lauf vom 24. Oktober 2026 verwendet den gemeinsamen Release-
Harness mit SHA-256 `f76bc30ece9a06f9ab93bb21fb9804f535d63e96fd919437fe6b431a6b911280`.
Manifest, 90 Kalibrierungen, 90 Abnahmefälle, Summary und 279 relative
Quellhashes sind in [results/](../tools/multiscale-denoise-evaluation/results/provenance.json)
prüfbar erhalten. Originalbilder, private Fotohashes, PNGs und absolute
lokale Pfade sind dort nicht enthalten.

| Teilverfahren | Gematchtes Tuning | Gematchte Abnahme | Gematchte Primärfälle 20/60 | Qualitätsentscheidung |
| --- | ---: | ---: | ---: | --- |
| Luminanz | 21/30 | 21/30 | 5/10 | Blockiert: Matching unvollständig |
| Chroma | 22/30 | 21/30 | 5/10 | Blockiert: Matching unvollständig |
| Gemeinsam | 21/30 | 21/30 | 5/10 | No-Go: zwei unabhängige Einzelvetos |

Für Luma und Chroma ist damit weder ein vollständiger Qualitätsvorteil noch
eine Qualitätsregression belegt. Die fehlenden Wirkungspaare verhindern
insbesondere eine zurechenbare Aussage zum geforderten gleich gewichteten
Primärmittel. Es wird kein ungematchter Fall als Verlust oder Gewinn gewertet.
Auch bei einem unvollständigen Gesamtvergleich bleiben einzeln gematchte
Fälle mit vollständigem festem Support aussagekräftig für ein technisches Veto.

| Gemeinsame Entrauschung bei 60 | Baseline Kanten-RMSE | Kandidat Kanten-RMSE | Zunahme |
| --- | ---: | ---: | ---: |
| Textur | 0,01567205 | 0,01802703 | 15,03% |
| Hautfarbene Textur | 0,01576391 | 0,01811986 | 14,95% |

Beide gematchten Fälle überschreiten die vorab festgelegte Einzelfallgrenze
von 10%. Dies ist ein eigenständiges Qualitäts-No-Go der gemeinsamen Variante,
keine Aussage über ungematchte Luma-/Chroma-Einzelverfahren. Alle 30 Null-
Identitäten sind exakt; alle 90 Ausgaben und Metriken sind endlich. Alpha-
und verborgenes-RGB-Fehler sind null. Die zugerechneten kritischen zusätzlichen
Drift-/Farbsaum-/Zielgamutguards liefern keine weiteren Vetos.

Die Auswertung fand und behob einen Protokollfehler: Ein ungematchter anderer
Primärfall darf ein gültiges gematchtes Einzelveto nicht ausblenden. Der
gezielte adversariale Test ist grün; ein vollständig frischer Tuning-/
Abnahmelauf nach dieser Korrektur bestätigt die Ergebnisse. Kalibrierung und
Qualitätsraster/-metriken sind byteidentisch zum ersten Lauf; Schwellen,
Suchgitter, Swift-Implementierung und Binary blieben unverändert.

Beide explizit benannten privaten, aus lokalen CR3s entwickelten TIFFs wurden
seriell über denselben Decoder einmal pro Datei verarbeitet. Je neun
Diagnosepaare entstanden bei 4096×2731. Das sind entwickelte SDR-Raster mit
unbekanntem ImageIO-Resampling, keine Sensordaten und keine native RAW-Abnahme.
Die 4096er Quellenkante dieser TIFFs belegt nicht die ursprünglichen
RAW-Abmessungen. Alle 18 Paare sind ausdrücklich ungematchte, nicht
qualifizierte Fotodiagnosen ohne saubere Wahrheit/Noise-ROI und ohne unabhängige
Sichtfreigabe. Ihre Quellen, Hashes und Ergebnisse bleiben ausschließlich lokal.

Wegen des gemeinsamen Einzelvetos und des fehlenden vollständigen Matchings
wurden keine vollständigen Timing-/Skalenmatrizen erhoben. Die vorhandenen
Diagnosen begründen keinen Latenz-, RSS- oder CPU-/GPU-Vorteil. Ein rein
synthetisch bestandener Test wäre ebenfalls keine Produktionsfreigabe.

Für vollständiges Go fehlen qualifizierte reale entwickelte RAW-Fotos, unabhängige
Sichtabnahme gematchter Foto-/Textur-/Haarkanten, nachgewiesene Backendparität,
faire größenrichtige Laufzeit-/RSS-Belege und die Produktionsintegration mit
Quell-/Skalen-/Prozess-/Parametercacheidentität, Undo und Abbruchgenerationen.
Zwei lokale CR3-Dateien (`IMG_8724.CR3`, `IMG_8477.CR3`) sind verfügbar,
aber noch nicht qualifiziert. Die sieben lokalen JPGs ersetzen ebenfalls
keine RAW-Abnahme. Sichtbare Haar-/Texturverluste, Farbbluten oder neue Säume
wären trotz guter Zahlen ein Veto. `gallery.html` liefert beschriftete
technische Paare; deren Erzeugung ist keine erfolgte unabhängige Abnahme.

Swift-Tests prüfen invertierbare signed/HDR-Transformation, exakte Null,
kleine Konstanten/Ränder, getrennte und gemeinsame L/C-Korrektur, feste Seeds,
Noise-Minderung, Alpha, P3-Zieldomäne, HDR-Provenienz, A→B→A und Abbruch.
Die Python-Tests prüfen vollständige Matrizen, echte residualbasierte Wirkung,
gefälschte Matchingflags, Kalibrierungs-/Seedbindungen, getrennte Mittel-/
Einzelfallgates und die Sperre fehlender Foto-/Performanceevidenz.

Lokale RAW-Diagnosen sind separat mit `--evaluation-mode multiscale-denoise-photo`
und `--input /absoluter/pfad.CR3`, Manifest und eingefrorener Kalibrierung möglich.
Sie decodieren genau einmal mit dem bestehenden ImageIO-Decoder bis 4096 Pixel,
ohne eingebettete Vorschau, und wenden das synthetisch gefrorene Mapping an.
Quell-/Rasterhash, native lange Kante, decodierte Maße und unbekanntes
Decoder-Resampling werden lokal protokolliert. Die Bildpaare sind ausdrücklich
**nicht wirkungsgematcht**: Es gibt keine saubere Foto-Ground-Truth oder
qualifizierte Noise-ROI. Sie schließen allein keine Abnahmelücke. Keine Quelle
oder private Ableitung wird committet oder hochgeladen.

Die gemeinsame finale Prüfung bestand mit 110 Swift-Tests einschließlich der
neun neuen #175-Tests und einem erfolgreichen sauberen App-Build. Die 14
Python-Tests dieses Protokolls bestanden vor dem bestätigenden Messlauf.
Das abschließende eigene und unabhängige Review umfasst Transformations-/
Alpha-/Speicherverträge, Quellen-/Fixture-/Kalibrierungshashes, Matching,
feste Masken, Einzel- und Mittelwertgates, private Fotoabgrenzung und die
bewahrten Ergebnisdateien. Es bleiben die oben ausdrücklich benannten
Abnahmelücken; die Produktions-Entrauschung wurde nicht verändert.
