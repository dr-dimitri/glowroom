# Abnahme der Algorithmus-Issues #214–217

Stand: 25.10.2026. Reihenfolge gemäß [#224](https://github.com/dr-dimitri/glowroom/issues/224):
zuerst die unabhängig vorbereiteten P1-Themen Punktkurven (#214) und
Maskenkomponenten (#215), danach das Farbmischer-Gate (#216) und die auf dem
gemeinsamen Quellkoordinatenvertrag aufbauende radiale Optik (#217).
Gemeinsame Settings-, Renderer-, History- und UI-Dateien wurden koordiniert
integriert. Git-Änderungen, abhängige Prüfungen und die Build-Bereinigung blieben
geordnet; unabhängige Analyse, Implementierung und Reviews liefen parallel.

## Ergebnis und Verträge

- **#214:** globale monotone Master-/RGB-Punktkurven, signiertes sRGB, nach
  Levels und vor Präsenz, Einheitssteigung außerhalb 0–1, unverändertes Alpha.
  [Bedienung, Formeln, Floatprüfung und begründete Sicherheits-Readbacks](DEVELOP-COLOR.md).
- **#215:** geordnete editierbare Komponenten mit `max(a,b)`, `a*(1-b)` und
  `a*b`, Komponenten-/Gesamtinvertierung, eingefrorenen Rastern und gemeinsamen
  Budgets. Historische Einzelmasken zählen als eine logische Komponente und
  behalten ihre Bytes. [Semantik und Grenzen](MASK-EDITING.md).
- **#216:** reproduzierbares **No-Go**, wie im Issue ausdrücklich vorgesehen.
  V1 und die versionierte Alternative V2 verfehlen das unveränderte HDR-Gate
  0,0001. Kein unqualifizierter Produktregler und kein neues Snapshotfeld.
  [Spezifikation, Fixtures und Messbericht](COLOR-MIXER-EVALUATION.md).
- **#217:** ein gemeinsamer radialer/affiner Plan und ein einziges Sampling,
  explizit transparente Grenzen, versionierte neutrale Omission sowie
  ursprüngliche Masken-/Retuschekoordinaten. Die bestehenden Quellwerkzeuge
  behalten ihre vollständige untransformierte Bearbeitungsfläche.
  [Koordinatenvertrag und konservative Constrain-Grenze](DEVELOP-GEOMETRY.md).

## Automatisierte und native Prüfung

Der integrierte Lauf mit allen Core- sowie relevanten Farb-/Masken-/Geometrie-
Suites bestand mit **575 Tests in 76 Suites**. Nach den letzten Reviewkorrekturen
bestanden erneut **485 Core-/Kurvenrenderer-Tests in 67 Suites** sowie
**21 Render-Tests in vier Suites**, einschließlich der zusätzlichen
Speicherreservierungsprüfung und der neutralen Kurven-Speicherregression.
Die unabhängige Kurvenmatrix prüft 4.097 Werte je Kanal gegen den tatsächlichen
Float-Kernel; zusätzliche Tests decken negative Gamutwerte, HDR, Alpha,
konstante Segmente, minimale Punktabstände, Snapshotbytes und Backup/Restore ab.
Die Geometrieprüfung verwendet eine unabhängige Newton-/Affine-Referenz,
Gitter-Landmarken und denselben tatsächlichen Vorschau-/Exportgraphen.

Die relevanten nativen Suites wurden in getrennten Prozessen geprüft, damit
AppKit-Ereignistracking und Fensterzustand keine konkurrierenden Prüfungen
verfälschen: Kurveneditor 5, Zuschneideinspektor 6, kompakte Maskenpalette 13,
Canvasbereitschaft 3, Maskenmodell 14, Masken-Canvas 2, Maskenworkspace 18,
Overlayworker 4, Overlaymodell 3, Historybudget 3, Levels-Picker 13,
Weißabgleich-Canvas 3, Reparatur-Canvas 24, Render-Sitzungen 6 und
Detailworkspace 12 Tests. Layoutprüfungen erfassen schmale 280/320-Punkte-
Inspektoren bzw. den 1000 × 660-Punkte-Arbeitsbereich, native Eingabe sowie
die Accessibility-Baumstruktur. Sie sind kein behaupteter manueller
VoiceOver-Durchlauf aller möglichen Foto-/Werkzeugkombinationen.

Für die Farbmischer-Entwicklerevaluation bestanden acht Python-Tests und der
native RGBAf-Evaluationslauf auf 4.295 festen synthetischen Fixtures. Sein
Ergebnis ist ein nachgewiesenes No-Go, kein numerisches oder visuelles Go.
Alle synthetischen Prüfungen funktionieren ohne private Fotos oder Modelle.

## Echte RAW-Dateien: Cache, schnelle Änderungen und Speicher

Die vom Nutzer ausdrücklich benannten lokalen **IMG_8477.CR3** und
**IMG_8724.CR3** wurden einzeln in frischen Testprozessen gemessen, ohne
gleichzeitigen Build oder Benchmark. Originale und abgeleitete Bilddateien
wurden weder geschrieben noch kopiert oder hochgeladen. SHA-256 vor und nach
jedem Lauf sowie eine zusätzliche Abschlussprüfung bestätigten unveränderte
Originalbytes. Die Dateien bleiben ignoriert und gehören nicht zum Repository
oder App-Bundle.

Beide Quellen haben eine native lange Kante von 6.000 Pixeln. Der echte
ImageIO-RAW-Pfad wurde mit deaktivierter Wiederverwendung eingebetteter
Kameravorschauen angefordert. Die decodierte SDR-Basis war 2400 × 1600 mit
8 Bit pro Komponente; der vorhandene konservative Speicherplan ließ bei aktiven
Levels, Kurven, Optik und zwei Maskenkomponenten **1627 × 1085** zu. Diese
adaptive Vorschau ist keine Prüfung einer vollauflösenden 6000-Pixel-Ausgabe.

| Messung | IMG_8477.CR3 | IMG_8724.CR3 |
|---|---:|---:|
| RAW-Decodes einschließlich warmer Zugriffe und Drag-Burst | 1 | 1 |
| Kalter App-Quellcache: Decode | 267,8 ms | 222,2 ms |
| Warmer Quellcache | 0,020 ms | 0,012 ms |
| Erste Entwicklung der kombinierten Korrektur | 987,1 ms | 95,8 ms |
| Warmer Ausgabecache, identisches Bildobjekt | 0,384 ms | 0,431 ms |
| Warme Sitzung mit zwei neuen Kurveneinstellungen | 532,2 / 531,5 ms | 18,8 / 19,7 ms |
| Letztes Drag-Ereignis bis fertiges Bitmap | 585,3 ms | 73,1 ms |
| Kumulativer Peak-RSS des Testprozesses | 307,9 MiB | 322,7 MiB |

Je acht Ereignisse im Abstand von 10 ms wurden mit dem vorhandenen 45-ms-
Intervall zusammengefasst. Sieben veraltete Anforderungen wurden abgebrochen;
am Ende war ausschließlich Revision 8 veröffentlicht. Insgesamt gab es je
vier tatsächliche Renderings, höchstens einen aktiven Renderworker, einen
Kurven-Eingangsbereichsnachweis und drei Wiederverwendungen. Originaldecode,
Quellcache und letzter angenommener Bildstand blieben korrekt.

Dies sind **Debug-Test-Diagnosen** der Anforderung bis zum materialisierten
Bitmap, keine Messungen nativer Eingabe bis zur Displayausgabe. »Kalt« bedeutet
leere App-Speichercaches und deaktivierten Diskcache; OS-, ImageIO-, Treiber-
und Shadercaches wurden nicht geleert. Neue Kurvenidentitäten können neue
Kernelkompilierung enthalten; die zweite Datei kann von systemweiten Caches
profitieren. Aus den deutlich verschiedenen Zeiten wird weder ein Vergleich
der Motive noch ein Leistungsgewinn abgeleitet. RSS ist der kumulative
Hochwasserstand des gesamten Testprozesses einschließlich Frameworks,
Decodierung, CI-Staging und gehaltener Frames, keine isolierte GPU-Messung.

Reproduktion nach einem normalen Testcompile, jeweils ohne konkurrierende
Last und mit ausdrücklich vorhandener Datei:

```sh
GLOWROOM_ALGORITHM_RAW_INPUT=/absoluter/Pfad/IMG_8477.CR3 \
  ./scripts/test.sh --skip-build --filter AlgorithmRAWValidationTests
```

Ohne Umgebungsvariable wird der private RAW-Test mit ausdrücklichem Grund
übersprungen. JSON-Diagnosen liegen lokal unter `/tmp/glowroom-algorithm-raw-*.json`.
Die sieben optionalen JPEGs in `Fixtures/LocalTestImages/` werden dafür nicht
vorausgesetzt und bleiben ebenfalls unverändert.

## Reviewkorrekturen

Das unabhängige Review und die tatsächlichen Tests fanden und behoben:

- veraltete Kurven-Zahlendrafts, Drag-Indizes nach Undo und falsch fortgesetzte
  Eingaben nach Quellenwechsel;
- zusätzliche wirkungslose Kurvenpunkte, deren zunächst unterschiedliche
  In-Memory-/JSON-Darstellung SQL-Snapshot und Speicherbeleg auseinanderlaufen
  ließ: lokale Editorentwürfe und kanonische Zweipunkt-Identität verhindern
  den falschen Versionskonflikt bei der nächsten Speicherung;
- wiederholte Eingangsbereichs-Readbacks bei Kurvendrags, auch für eingefrorene
  Retuscheflächen, einschließlich Cacheinvalidierung und begrenzter Ownership;
- einen möglichen Dictionary-Trap bei doppelten Retusche-IDs;
- verspätete Overlays nach Komponenten-/Moduswechsel und irrtümlich wieder
  eingeschaltete Overlays bei unveränderter Undo-Komponentenauswahl;
- unvollständige Komponenten-/History-/Analyse-/Zwischenmaskenbudgets und die
  fehlende frühe Gesamtprüfung beim direkten Settings-Encoding;
- nicht erreichbare bzw. von Eltern-IDs überschriebene Komponenten-AX-Ziele;
- Zuschnitteingaben auf einer veralteten optischen Vorschau und exakte
  Bildrandecken im gemeinsamen Mapping;
- tatsächlich geklemmte Randpixel des ursprünglichen Warp-Ansatzes: der finale
  reguläre CI-Kernel prüft Crop- und Quellgrenzen explizit und sampelt einmal.

Die Rohdaten-Zeilenrichtung zweier neuer Tests und die native AX-/Textfeld-
Zuordnung wurden anhand unabhängiger Experimente korrigiert; die numerischen
Qualitätsgrenzen wurden nicht gelockert. Das finale Review fand keine weiteren
konkreten offenen Fehler.

## Sauberer vollständiger Release-Build

Der endgültige Stand wurde mit `GLOWROOM_BUILD_PATH=.build-app
GLOWROOM_BUILD_JOBS=4 ./scripts/build-app.sh` erfolgreich vollständig neu gebaut
(Swift-Produktbuild 398,11 s). Vorher wurden nach Prüfung laufender Prozesse
sämtliche generierten Ergebnisse dieses Release-Verzeichnisses und
`dist/Glowroom.app` entfernt. `.build` blieb als unabhängiger Testpfad erhalten;
kein Release-Ergebnis wurde daraus übernommen. Der Build erhielt Netzwerkzugriff
für die exakt festgelegten Pakete. `Info.plist`-Validierung und die im Skript
enthaltene strikte Signaturprüfung bestanden, Ergebnis: `dist/Glowroom.app`.
Ein Build-Verzicht war wegen der relevanten Produktquelländerungen unzulässig.

Ein vorheriger Build wurde für Reviewkorrekturen abgebrochen; ein Neustart wurde
zunächst wegen seiner verbliebenen Sperre abgewiesen. Nach nachgewiesener
Prozessruhe wurden ausschließlich diese inaktive Sperre und eigene generierte
Zwischenstände bereinigt. Der anschließende finale Build war erfolgreich.
