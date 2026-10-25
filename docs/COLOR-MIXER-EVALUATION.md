# Achtband-Farbmischer – Qualitätsgate zu #216

**Ergebnis am 25.10.2026: No-Go für den Produktanschluss.** Der angeforderte
Kandidat v1 und eine ausdrücklich versionierte Alternative v2 überschreiten
die unveränderte absolute Grenze von **0,0001 je linearem RGB-Kanal** bei
moderaten Einstellungen auf HDR-Fixtures. Die Entwickler-Evaluation ist
vollständig reproduzierbar. In der Anwendung wird kein Farbmischer aktiviert.
Globale Dynamik, Sättigung und das dokumentierte LC-05-Ergebnis bleiben erhalten.

## Festgelegter Farbvertrag vor dem Produktanschluss

Ein-/Ausgabe ist **extended linear sRGB**, als Float32-Raster mit Alpha.
Berechnung erfolgt auf ungepremultipliziertem RGB; Alpha wird unverändert
wieder angewendet. Vollständig transparente aktive Pixel werden schwarz-
transparent. Eine neutrale Einstellung überspringt den gesamten Knoten.
Exakt gleiche RGB-Kanäle überspringen die Konvertierung ebenfalls, damit die
gerundeten Matrixkoeffizienten keine chromatische Abweichung auf der Grauachse
erzeugen. Es gibt keinen SDR-, RGB- oder Gamut-Clamp und keine 8-Bit-Umwandlung.
Negative LMS-Werte verwenden die reelle vorzeichenbewahrende Kubikwurzel.

Die linearen sRGB/OkLab-Vorwärts- und Rückwärtsmatrizen sind die von
[Björn Ottosson am 25.01.2021 aktualisierten sRGB-Matrizen](https://bottosson.github.io/posts/oklab/).
Alle Koeffizienten stehen explizit in der unabhängigen
[skalaren Referenz](../tools/color-mixer-evaluation/reference.py) und den
getrennten [Float-Kerneln](../tools/color-mixer-evaluation/candidate-v1.cikernel).
Es werden keine Rec.2020-Koeffizienten als sRGB-Koeffizienten verwendet.

Die acht Bandzentren entstehen aus **sRGB-codiertem HSV(H, 1, 1)** für
`H = 0°, 30°, 60°, 120°, 180°, 225°, 270°, 315°`. Zunächst wird sRGB mit
seiner stückweisen Transferfunktion decodiert, dann nach OkLab/OkLCh
transformiert. Die resultierenden Winkel in Radiant sind:

| Band | Zentrum |
|---|---:|
| Rot | 0,5102275497563948 |
| Orange | 0,9211103989444132 |
| Gelb | 1,9158345171210678 |
| Grün | 2,4870128323373986 |
| Aqua | 3,3993594220581693 |
| Blau | 4,604695960947877 |
| Violett | 5,127324348702114 |
| Magenta | 5,999419057316489 |

Für einen ursprünglichen Pixelwinkel `h` zwischen zwei benachbarten Zentren
`a ≤ h ≤ b` gilt zirkulär `t=(h-a)/(b-a)`,
`w_a=(1+cos(πt))/2`, `w_b=(1-cos(πt))/2`; alle übrigen Gewichte sind 0.
Der letzte Abschnitt verbindet Magenta mit Rot plus `2π`. Die Gewichte werden
einmal aus dem ursprünglichen Farbton gebildet und summieren sich zu 1.

Jedes Band hat `Farbton`, `Sättigung`, `Helligkeit` in `−100…100`.
Mit `u=Farbton/100`, `s=Sättigung/100`, `v=Helligkeit/100` und
`d=min(C/0,12,1)` lautet Kandidat **v1**:

```text
Δh = 0,5 · Σ(w·u) · d
C' = max(0, C · (1 + Σ(w·s)))
L' = L + 0,2 · Σ(w·v) · d · sqrt(max(L, 0,05))
RGB' = OkLabInverse(L', C'·cos(h+Δh), C'·sin(h+Δh))
```

Bei `C=0` bleiben RGB und L unverändert. Sind alle drei gewichteten Änderungen
exakt 0, wird der ursprüngliche Pixel ohne Matrix-Roundtrip zurückgegeben.
Der potentielle Produktplatz ist versioniert festgelegt: **global nach Levels
und Punktkurven, vor Präsenz und Schwarzweiß**. Die Einstellung ändert keine
vorhandene Tonwertversion. Da das Gate nicht besteht, wird dieser Platz in
der produktiven Pipeline noch nicht belegt und kein `EditSettings`-Feld ergänzt.
Das Evaluationsformat hat eine explizite Kandidatenversion, benannte Bänder
und alle drei Parameter je vorhandenem Band; neutrale Bänder fehlen.
Unbekannte Versionen/Felder und nicht endliche oder übergroße Parameter werden
abgewiesen. Dieses Format ist kein gespeicherter Produkt-Snapshotvertrag.

## Versionierte Alternative v2

V2 verwendet dieselben Fixtures, Bandzentren, Gewichte, Parameter und
Akzeptanzgrenzen. L', C' und h' bleiben gleich; die exakte neue Ausgangsformel
ist ausdrücklich:

```text
RGB' = RGB + OkLabInverse(L', a', b') − OkLabInverse(L, a, b)
```

Der native Kernel berechnet die Differenz der Kuben über
`(t+δ)³−t³ = δ·(3t²+3tδ+δ²)`, um große HDR-Basiswerte nicht zuerst voneinander
abziehen zu müssen. Diese differenzbasierte Alternative reduziert einen Teil
des Rundungsfehlers, erreicht das Gate jedoch ebenfalls nicht. Es gibt
keine nachträgliche Begrenzung auf einen engeren HDR-Bereich und keine
Lockerung der Grenze, um einen Kandidaten freizugeben.

## Eingecheckte Fixtures und Nachweis

[fixtures.json](../tools/color-mixer-evaluation/fixtures.json) enthält 4.295
deterministische Pixel: negative/positive Grauwerte bis linear 1.024 mit
Alpha 0/0,25/1, einen dichten Farbkreis mit 4.097 Punkten, gesättigte Display-P3-
Farben im linearen sRGB-Arbeitsraum, HDR-Farbflächen bei 2/4/16/64/256/1.024,
beidseitige Grenzwerte jedes Bandzentrums und synthetische Haut-/Himmel-/
Vegetations-/Orange-/negative-Gamut-Patches. Linear 1.024 liegt zehn Blenden
über nominalem SDR-Weiß; solche endlichen Float-Werte werden vom bestehenden
erweiterten Arbeitsvertrag nicht auf 1 begrenzt. Die zu prüfende Formel hat
keine niedrigere spezifizierte HDR-Grenze.

Die feste Settingsmatrix umfasst Neutral, Blau moderat, acht Bänder moderat
und alle Bandregler an beiden Extremgrenzen. Die Double-Referenz rechnet
getrennt vom nativen Kernel mit generischen Matrizen und bisektierten
zirkulären Intervallen. Verglichen wird ungepremultipliziertes RGB nach dem
tatsächlichen RGBAf-Eingang; dessen Float-Quantisierung wird für das Orakel
explizit reproduziert. Die Prüfung liest ausschließlich die kleine
Evaluationsfläche zurück. Sie ist kein Readback je Produkt-Reglerbewegung.

Der [native Bericht](../tools/color-mixer-evaluation/results-2026-10-25.json)
enthält Fixture-SHA256, Backend-/OS-Angabe, jede Gateverletzung und gruppierte
Maximalfehler. Gemessen wurde mit Core Image RGBAf auf macOS
`Version 27.0.1 (Build 26A434)`. Das tatsächliche Ausführungsgerät wird nicht
behauptet. Die angeforderte Float-Grenze bleibt auf anderen Backends gleich.

| Kandidat / moderate Einstellung | max. HDR-RGB-Fehler | max. P3-RGB-Fehler |
|---|---:|---:|
| v1 / Blau | 0,001220703125 | 0,000001359688 |
| v1 / acht Bänder | 0,002474739830 | 0,000002700571 |
| v2 / Blau | 0,000732421875 | 0,000002222519 |
| v2 / acht Bänder | 0,001402821915 | 0,000003563403 |

Das Gate scheitert auf HDR trotz bestandener moderater SDR-/P3-Abweichung.
Die beiden moderaten Einstellungen verletzen zusammen 42 native Pixeltests
bei v1 und 32 bei v2. Alle gemessenen Extremwerte bleiben endlich. Alpha,
Grauachse, Neutraldurchlauf und der Orangepatch außerhalb des blauen
Bandgewichts sind in dieser Matrix exakt unverändert. Die skalaren Tests
prüfen zusätzlich die Summe/Lokalität der Gewichte und beidseitige Farb-
stetigkeit an jedem Bandzentrum und am Magenta-/Rot-Umlauf. Dies ersetzt
keine Sichtprüfung auf Banding oder unbeabsichtigte Farbsäume.

## Wiederholung und Grenzen

```sh
python3 -m unittest discover -s tools/color-mixer-evaluation -p 'test_*.py'
python3 tools/color-mixer-evaluation/evaluate.py --output /tmp/color-mixer-results.json
```

Die erste Prüfung benötigt nur Python ab 3.11; die zweite zusätzlich macOS,
Apple Command Line Tools und Zugriff auf Core Image/Fensterserver. In der
Codex-Sandbox ist die native Ausführung gegebenenfalls freizugeben.
Eine nicht ausgeführte/fehlerhafte native Prüfung ergibt keinen Go-Nachweis.
Für CI und frische Checkouts sind alle numerischen Fixtures vorhanden;
`Fixtures/LocalTestImages/` wird weder gelesen noch vorausgesetzt.

Wegen des numerischen No-Go wurden Naturfotos, Banding-/Farbsaum-Sichtprüfung,
Produkt-UI, Tastatur/VoiceOver, Undo/Redo, Neustart, Backup/Restore und native
Vorschau-/Exportannahme nicht als bestanden deklariert. Die synthetisch
benannten Motivpatches sind keine Abnahme realer Haut-, Himmel- oder
Vegetationsfotos. Eine bloß numerisch erfolgreiche Folgemessung könnte den
Produktanschluss ebenfalls erst nach den übrigen Nachweisen freigeben.

Die Evaluation verändert keinen Produktgraphen, Cache, Workerpool oder
RAW-Decode. Der kleine Controller bleibt seriell; pro Band zusätzliche
Prozesse zu starten würde Kosten und Synchronisation ohne Nutzen erzeugen.
Core Image plant die datenparallele Pixelarbeit. Es werden keine
Geschwindigkeits- oder Qualitätsvorteile gegenüber Lightcraft behauptet.
