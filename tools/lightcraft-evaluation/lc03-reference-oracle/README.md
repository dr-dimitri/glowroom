# LC-03: unabhängiges numerisches Referenzoracle

`vectors.json` enthält Float32-Ergebnisse der **ursprünglichen Rust-Funktionen**
aus `dr-dimitri/lightcraft@f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`.
Die Swift-Tests lesen diese eingefrorenen Daten; sie brauchen weder Rust noch
einen Lightcraft-Checkout. Das Oracle ist kein Produktbestandteil und wird vom
normalen App-Build nicht aufgerufen.

Optionale Reproduktion mit Python 3, `rustc` und einem vorhandenen Checkout:

```sh
python3 tools/lightcraft-evaluation/lc03-reference-oracle/generate.py /path/to/lightcraft
```

Der Generator prüft Commit **und SHA256 der gelesenen Dateien**, extrahiert
unveränderte Funktionskörper und kompiliert sie in einem temporären Verzeichnis.
Ein kleiner selbst geschriebener Speicher-/Scheduler-Ersatz stellt `Image`,
Zeileniteration und `par_join` bereit. Die kleinen Oracle-Fälle laufen seriell;
die Reihenfolge der Float32-Operationen innerhalb einer Zeile bleibt erhalten.
Der Testgenerator importiert weder Cargo-Abhängigkeiten noch GPU-/RAW-Pfade.
`--write` ersetzt die Vektoren ausdrücklich; der normale Aufruf verifiziert nur.

Verwendete Quellen und Symbole:

- `crates/pipeline/src/local.rs`: `guided`, `guided_coeffs`, `guided_apply`,
  `guided_fast`, `median_hv`, `median_row`, `transpose`, `tone_base`,
  `guided_fast_step`, `BASE_EPS`.
- `crates/raster/src/blur.rs`: unverändertes Modul ohne dessen Tests, insbesondere
  `box_radii`, `radii_for`, `box_row`, `box_v`, `gaussian`.
- `crates/raster/src/resample.rs`: unverändertes Modul ohne dessen Tests,
  insbesondere `weights`, `resize`, `Filter`, `Pixel`.
- Die Eingangsformel stammt aus `tests_tone.rs::median_matches_a_plain_per_pixel_median`.
  Die Swift-Szenentests übertragen zusätzlich `scene`, `on_line`, Median-/V1-/V2-
  und Kantenprüfungen aus derselben gepinnten Datei. Sie messen isolierte lineare
  Tonwertanpassung; die Schwellen für Lightcrafts kompletten RGBA8-Renderer werden
  nicht als identischer Test ausgegeben.

Die elf Vektorfälle prüfen Median, kleine/große Gaußradien, die vertikale
32-Zeilen-Bandgrenze, den Filterpfad ohne und mit Subsampling, V2-Medianbasis,
Box-Verkleinerung und bilineare Vergrößerung. Die CPU-Absoluttoleranz `5e-6`
entspricht der vorab bestehenden LC-01-CPU-Toleranz. Die Referenzdaten werden
nicht aus der Swift-Implementierung abgeleitet und nicht anhand deren Ergebnis
nachträglich angepasst.

Die verwendeten Lightcraft-Quellen stehen unter MIT; Copyright (c) 2026 ArtCraft
Team and the LightCraft contributors. Der vollständige Text steht in
[`LICENSE-MIT`](../licenses/lightcraft/LICENSE-MIT). Die gepinnte
[`NOTICE`](../licenses/lightcraft/NOTICE) nennt für diese Quellbereiche
keine zusätzliche Drittanbieterauflage. Kamera-/Assettabellen, Marken, Fonts,
Fotografien, Modelle und Gewichte werden nicht übernommen.
