# Vorschau-Scopes: Vertrag und Prüfung (#172)

Histogramm, Waveform und RGB-Parade sind reine Workspace-Anzeigen. Die
Bedienung steht in [Entwickeln](DEVELOP-WORKSPACE.md). Die Bildentwicklung,
Levels, Einzelreglerautomatik und Pipetten bleiben bei ihren bestehenden
Verträgen. Die kleine neue Reduktion wertet ausschließlich den akzeptierten,
orientierten Nachher-Proxy aus. Sie übernimmt keine GPL-Implementierung;
Kanalwahl und räumliche Dichte sind eigenständig implementierte Konzepte aus
[#172](https://github.com/dr-dimitri/glowroom/issues/172).

## Analyse und Grenzen

Der vorhandene Analyzer zeichnet höchstens 384 × 384 sRGB-RGBA8-Pixel und
entpremultipliziert sichtbare RGB genau einmal. Histogramm und räumliche Dichte
zählen die exakte Integer-Alpha-Masse (255 Einheiten je opakem Pixel). Alpha
null zählt nicht, Alpha 1/255 bleibt sichtbar. 256 Tonwertbins sind 8-Bit-
Darstellung und keine Float- oder Sensormessung. Warnmasken und Weißabgleich
verwenden weiterhin ihre getrennten historischen Schwellen/Opazitätsregeln.

Die bei Bedarf erzeugte räumliche Statistik hat maximal 128 Spalten × 256
Werte × drei UInt32-Kanäle: 393.216 Byte Nutzdaten plus Array-Verwaltung.
Der akzeptierte RGBA-Proxy hat maximal 589.824 Byte. Warnmasken, Quellproxy,
Canvas und temporäre CGContext-Puffer kommen getrennt hinzu; das Dichtelimit
ist keine Behauptung eines identischen gesamten Prozess-RSS. Waveform und
Parade teilen denselben Puffer; Histogrammmodus gibt ihn frei. Das Canvas
quantisiert lediglich die darzustellende Helligkeit auf 32 Stufen pro Kanal,
verändert dabei aber weder Bins noch alpha-gewichtete Messdaten.

Die kleine Analyse bleibt im vorhandenen Actor; ein eigener GPU-Transfer oder
zusätzlicher Workerpool wäre für diese begrenzte Reduktion nicht begründet.
Die Canvas-Zeichnung fordert asynchrone Darstellung an; die Pixelanalyse
bleibt in den Analyzer-/Reducer-Actors. Kanal- und Skalenwechsel normieren vorhandene Daten am gemeinsamen
Maximum der sichtbaren Kanäle; sie fordern weder Analyse noch Entwicklung an.
Moduswechsel benötigt höchstens einen Reduktionsauftrag aus denselben Bytes.
Neue Vorschauen, Bildwechsel und Rückkehr zum Histogramm entwerten alte
Reduktionsaufträge, einschließlich verspäteter Fehler.

## Automatisierte Abnahme

`DevelopScopeTests` prüft RGB-Rampen, alle 256 Bins, Alpha-Masse bis 1/255,
leere/ungültige und ein Pixel große Raster, begrenzte Spalten, lineare und
logarithmische Normierung, ausgeschaltete Kanäle, validierte persistierte
Präferenzen und Reuse ohne neue Analyse. Kontrollierte suspendierende Fakes
prüfen schnelle Modus-/Framewechsel sowie verspäteten Erfolg und Fehler.
Ein unabhängiger Spaltenoracle prüft die vom tatsächlichen Renderer gelieferten
Pixel nach Crop, Spiegelung und Vierteldrehungen. Die bestehenden Workspace-
und Preview-Identitätstests sichern Quellwechsel und Nachherbindung ab.
`rgb(at:)` weist nun auch leere/fehlerhafte Raster kontrolliert ab, statt einen
ungültigen Index zu erzeugen; der Weißabgleich-Samplingvertrag bleibt erhalten.

```sh
./scripts/test.sh --jobs 4 --filter 'DevelopScopeTests|DevelopWorkspaceTests|DevelopPreviewIdentityTests'
# Zeitprobe erst ohne konkurrierenden Build/Test/Benchmark ausführen:
./scripts/test.sh --skip-build --filter 'DevelopScopeTests/analysisTimingAndStorageBoundary'
```

Die Zeitprobe erzeugt 32×16- und 4096×2048-Raster, misst jeweils den ersten
Analyse-/Reduktionsaufruf und acht folgende Aufrufe sowie den Prozess-Peak-RSS.
Fixture-Erzeugung, RAW-Decode und Bildentwicklung liegen außerhalb der Uhr.
Der normale Testbuild ist Debug; die Werte sind eine begrenzte lokale
Funktions-/Kostenprobe, keine Release-End-to-End-Latenz oder Leistungszusage.
Ein neuer Testprozess leert keine OS-Caches. Private Fotos sind für diese
reproduzierbaren Prüfungen nicht erforderlich und wurden nicht eingecheckt.

## Lokale Messung am 24. Oktober 2026

Isolierter Debug-Testprozess, 12 aktive CPU-Kerne und 16 GiB RAM; keine
konkurrierenden Builds, Tests oder Algorithmusbenchmarks. Beide Raster wurden
synthetisch erzeugt und außerhalb des Timers angelegt. Jede Zeile enthält
neun Analyse-/Reduktionsaufrufe auf demselben Eingang, ohne den fertigen
Statistikpuffer zu cachen:

| Eingangsgröße | Erster Aufruf | Mittel der acht Folgeaufrufe | Gesamter Prozess-Peak-RSS |
| --- | ---: | ---: | ---: |
| 32 × 16 | 1,48 ms | 0,64 ms | 59.736.064 Byte |
| 4096 × 2048 | 98,30 ms | 88,36 ms | 128.794.624 Byte |

Das RGBA-Raster der großen Eingabe wird im Analyzer auf 384 × 192 reduziert;
Context-Zeichnen und Resampling sind in der Uhr enthalten. Der Dichtepuffer
blieb in allen Aufrufen unter 393.216 Byte. RSS enthält Testframework, große
Eingangsfixture und alle übrigen Prozessressourcen und ist keine isolierte
Scope-Allokation. Die Zahlen belegen keine Verbesserung gegenüber einem
anderen Verfahren, keine RAW-/Slider-End-to-End-Latenz und keinen Release-Wert.

Die integrierten 110 Swift-Tests in elf betroffenen Suites und 36 getrennte
Python-Protokolltests bestanden; die isolierte Kostenprobe zusätzlich als
einzelner Test. Der saubere vollständige Release-App-Build erfolgte nach
Prozessprüfung und Bereinigung in `.build-app/clean-app` mit
`GLOWROOM_BUILD_PATH` und `GLOWROOM_BUILD_JOBS=4`; das vorherige Bundle wurde
entfernt. Tests verwendeten getrennt `.build`, der Release-Harness dessen
Release-Unterpfad. Bundle-Plist, lokale Signierung und Signaturprüfung waren
erfolgreich.

Vorläufe sind ausdrücklich nicht als Erfolg gewertet: Der erste Testcompile
scheiterte an einer während des Builds geänderten Evaluationsdatei. Ein
weiterer an der Testing-Makroexpansion von `allSatisfy(\.isFinite)`, danach
vier unzutreffende EIGF-Testannahmen an exakter Float-Gleichheit bzw. einem
vollständig unsichtbaren Basiswert. Closure-Assertions sowie fachlich
passende Float-/Alpha-Prüfungen korrigieren diese Fälle; die vorab fixierten
Qualitätsgates wurden nicht geändert. Ein begonnener App-Build wurde für den
abschließenden Randfallfix geordnet gestoppt und erst nach erneuter Prüfung
aller verbliebenen Prozesse vollständig bereinigt und erfolgreich sauber
wiederholt.

Das unabhängige Scope-Gegenreview prüfte Daten-/UI-Schnittstelle, Alpha,
Geometrie, Präferenzen, Abbruch und verspätete Ergebnisse ohne offenen Befund.
Die drei Evaluationskandidaten wurden zusätzlich unabhängig gegengeprüft;
deren Ergebnisse und verbleibende Produktionsgrenzen stehen in den jeweiligen
Fachberichten.

Das abschließende UI-Review verschob die Warnschalter aus der Plotüberlagerung
in die Scope-Kopfzeile, damit insbesondere die 100-%-Markierung der räumlichen
Anzeige frei bleibt. Die 110 betroffenen Swift-Tests bestanden danach erneut;
App und Harness wurden auch für diesen finalen Quellstand erfolgreich
geprüft; der App-Build war erneut vollständig sauber, Plist und Signatur gültig.
