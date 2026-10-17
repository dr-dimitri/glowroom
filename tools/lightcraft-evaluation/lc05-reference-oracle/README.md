# LC-05: unabhängiges numerisches Referenzoracle

`vectors.json` enthält 24 Fälle mit je 20 RGB-Pixeln aus dem gepinnten
Lightcraft-Commit `f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`.
Die Swift-Tests lesen ausschließlich die eingefrorenen Daten; die Anwendung
benötigt weder Rust noch einen Lightcraft-Checkout.

Optionale Reproduktion mit Python 3, `rustc` und vorhandenem Checkout:

```sh
python3 tools/lightcraft-evaluation/lc05-reference-oracle/generate.py /path/to/lightcraft
```

`--write` ersetzt die Vektoren ausdrücklich. Der Generator liest unveränderte
Git-Objekte des Pins und prüft alle Quellhashes. Aus den Matrix-/Farbraumtypen
werden lediglich die externen `serde`-Derives entfernt; ihre Rechenoperationen
bleiben unverändert. Der ursprüngliche schnelle Chroma-Zweig von
`ColorOps::apply` wird als unveränderter Anweisungsblock mit deaktivierten
Mixern, Point Colors, Schwarzweiß, Grading und lokalen Reglern ausgeführt.
`grade` besteht in diesem Fall nur aus der ursprünglichen inversen Transformation.

Die Originalfunktionen `oklab_matrices`, `oklab_from_2020`, `oklab_to_2020`,
`oklch_hue_of_srgb_hue`, `wrap`, `srgb_to_linear` und `gamut_map_to` liefern die
Referenzwerte. Die sRGB-Luminanzgewichte `[0.2126, 0.7152, 0.0722]` entsprechen
`OutputSpace::Srgb` in der ebenfalls gehashten `output.rs`; `peak=1` ist die
explizit gewählte SDR-Ausgabegrenze.

Die Fälle prüfen beide Vorzeichen, Extrema, Sättigung −100, Kombinationen,
Schwarz/Grau/chromaarme Pixel, Primär-/Sekundärfarben, Orange-/Hautfarbtöne,
negative und erweiterte RGB-Werte. Zwölf Fälle prüfen die originale Rec.2020-
Teilfunktion, zwölf die vollständige lineare sRGB↔Rec.2020-Grenze. Letztere
bewahren getrennte rohe und gamutbegrenzte Ergebnisse. Die Toleranz beträgt
`5e-6` absolut pro Float-Komponente.

Die signed-Kubikwurzel bleibt auch bei negativem LMS erhalten. Der rohe
ColorOps-Pfad begrenzt RGB nicht. Nur die explizite Ausgabepolitik führt den
originalen Gamutmapper nach der Rückumrechnung nach sRGB aus. Beide Politiken
umgehen bei Null/Null sämtliche Konvertierungen und Gamutoperationen, damit
neutrale P3-/Alpha-/erweiterte Eingaben exakt unverändert bleiben.

Die ursprünglichen XYZ/D65-Matrizen erzeugen eine kleine Grauachsenabweichung:
Sättigung −100 ergibt für lineares sRGB-Weiß roh ungefähr
`[1.0004195, 0.99995124, 0.99919605]`. Der Referenzadapter korrigiert diesen
Befund nicht nachträglich. Ein exakter Nullwert von nativem Lab-a/b vor der
Rücktransformation ist daher nicht mit exakt gleichen RGB-Komponenten oder
exakt null Chroma in einer unabhängig berechneten OkLab-Metrik gleichzusetzen.

Die Testfarben sind selbst erzeugt. Für übernommene Quellalgorithmen gilt MIT;
Copyright (c) 2026 ArtCraft Team and the LightCraft contributors. Vollständige
Lizenz, NOTICE und Anpassungen stehen in
[THIRD-PARTY-NOTICES.txt](../THIRD-PARTY-NOTICES.txt) und
[`licenses/lightcraft`](../licenses/lightcraft).
