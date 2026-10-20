# Schärfen

Stand: 20. Oktober 2026.

Unter **Entwickeln → Details** folgt auf den Detailzoom die Gruppe **Schärfen**. Details, Schärfen und Entrauschen bleiben bei sichtbarer Werkzeugseite immer geöffnet und lassen sich nicht einklappen; ältere geschlossene Layoutpräferenzen werden für ihre Darstellung ignoriert. **Betrag** (0–150) schaltet den Effekt ein und steuert seine Stärke. **Radius** (0,5–3,0) bestimmt die Breite der geschärften Strukturen in Originalpixeln. **Details** (0–100) lässt mit steigenden Werten auch schwächere feine Texturen durch. **Maskieren** (0–100) beschränkt die Schärfung zunehmend auf starke Kanten und schützt ruhige Flächen vor zusätzlichem Rauschen. Ausgangswerte sind 0 / 1,0 / 25 / 0; vorhandene Bilder erhalten keine zusätzliche Schärfung.

Radius, Details und Maskieren werden bei Betrag 0 inaktiv, ihre Werte bleiben gespeichert. Doppelklick setzt den jeweiligen Regler auf seinen Ausgangswert zurück. Die Vorschau folgt dem Reglerzug unmittelbar; automatisch gespeichert wird der letzte Wert erst beim Loslassen der Maustaste. Reglerzug und zusammenhängende Zahleneingabe bilden jeweils einen Rückgängig-Schritt. Werte gehören wie andere Bildkorrekturen zu Speicherung, Varianten, Backup/Restore, Vorhervergleich und vollständigem Zurücksetzen.

Die Lupe zeigt die bereits entwickelte Vorschau bis 2400 Pixel langer Kante, keine neu decodierte 1:1-Originalregion. Sehr feine Schärfung großer Originale lässt sich deshalb am zuverlässigsten zusätzlich im Export beurteilen. Verkleinerte Vorschauen verwenden den Radius multipliziert mit dem Verhältnis Vorschau-/Originalkante. Das verhindert eine überbreite Schärfung in kleinen Vorschauen; Resampling und Schärfung sind mathematisch nicht vertauschbar, daher wird keine pixelidentische Übereinstimmung verschiedener Auflösungen zugesagt.

## Algorithmus und Quellen

Der lokale Lightcraft-Checkout wurde auf `5fe74557` aktualisiert, identisch mit `origin/main` und `upstream/main`. Die Prüfung von `crates/pipeline/src/finish.rs`, `crates/pipeline/src/local.rs` und `crates/gpu/src/wgsl/finish.wgsl` fand eine logarithmische Luminanzschärfung mit Betrag und Maskierung. Die gespeicherten Regler Radius und Details werden dort nicht ausgewertet; die Unschärfebreite wird mit Struktur geteilt. Das ist bereits als [Lightcraft #757](https://github.com/storytold/lightcraft/issues/757) erfasst. Glowroom übernimmt diesen unvollständigen Filter nicht.

Die eigene Implementierung verwendet das dokumentierte Prinzip der [Unscharfmaskierung](https://scikit-image.org/docs/0.25.x/auto_examples/filters/plot_unsharp_mask.html): Differenz zwischen Signal und Gauß-geglättetem Signal, multipliziert mit der Stärke. [Apple dokumentiert Luminanzschärfung](https://developer.apple.com/documentation/coreimage/cisharpenluminance); die [Beschreibung der vier Lightroom-Regler](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/retouch-photos.html) dient ausschließlich als Verhaltensreferenz. Glowroom verwendet eigene Schwellen und behauptet keine identische Lightroom-Entwicklung.

`DevelopSharpening` arbeitet nach globalen Farb-/Tonwertkorrekturen und vor lokalen Maskenkorrekturen und Geometrie:

- Das Signal ist `log2(max(lineare Luminanz, 0,0001))`, mit linearen sRGB-Gewichten 0,2126 / 0,7152 / 0,0722. Alpha wird beim Glätten gewichtet; transparente Ränder dunkeln gleichförmige sichtbare Flächen nicht ab.
- Radius ist die Gauß-Sigma in Originalpixeln. Das Residuum ist Signal minus geglättetes Signal. Details steuert eine weiche Residuum-Schwelle von `0,12 × (1 − Details/100)²` Blendenstufen; bei 100 bleibt auch schwache Textur wirksam.
- Maskieren verwendet unabhängig davon den zentralen Gradienten einer mit Sigma 0,5 Originalpixeln geglätteten Luminanz. Eine weiche Schwelle von `0,8 × Maskieren/100` bis zu diesem Wert plus 0,15 Blendenstufen bevorzugt starke Kanten. Bei 0 ist die Maske vollständig offen.
- Der Gewinn ist `2^delta`, mit `delta = Betrag/100 × Residuum × Detailgewicht × Maske`, auf ±0,5 Blendenstufen begrenzt. Derselbe Faktor wirkt auf alle RGB-Kanäle. Bei SDR wird der Gewinn gemeinsam an der Kanalobergrenze begrenzt; HDR behält Helligkeiten über 1. Alpha bleibt erhalten. Sehr dunkle Signale unterhalb der logarithmischen Untergrenze werden nicht zusätzlich verstärkt.

Der Core-Image-Graph bleibt auf dem verfügbaren Systembackend. Wiederverwendete Kontexte und die vorhandenen begrenzten Hintergrundworker führen Vorschau und Export aus; es gibt keinen zusätzlichen Workerpool, CPU-Pixeltransfer oder RAW-Decode pro Reglerbewegung. Unabhängige Decode-/Cache-Arbeit kann weiter parallel laufen. Abhängige Filterstufen bleiben im Graphen geordnet, Core Image parallelisiert die Bildoperationen. Abbruch vor/nach Graphaufbau und vor Veröffentlichung verwendet die bestehenden Anfragenidentitäten.

Zusätzliche Arbeitsflächen werden konservativ mit 48 Byte/Pixel, bei Maskierung mit 64 Byte/Pixel geplant, einschließlich eingefrorener Retuschequellen. Die gemeinsame Vorschauplanung verkleinert bei Bedarf den Renderproxy; Export prüft das vollständige Originalbudget vor dem Decode. Die Werte sind Zulassungsbudgets, keine gemessenen Grenzen interner GPU-Allokationen.

Native Originalabmessungen begleiten Vorschauen im Speicher und als eigene XMP-Angabe im atomar geschriebenen PNG-/JPEG-Cache. Ein neuer Cache-Schlüssel verwirft alte Einträge ohne diese Angabe. Kamera-, Orts- und sonstige Originalmetadaten werden dabei nicht kopiert. Originaldateien bleiben unverändert.

## Prüfung

Die gezielten Tests prüfen Wirkung aller Regler, Textur-/Kantenmaskierung, konstanten Bildinhalt, transparente Ränder, RGB-Verhältnisse, SDR/HDR, Radius-Skalierung, Vorschau-/Exportgraph, Software-Kontextpräferenz, Session-Wiederverwendung, Abbruch und Speicherplanung. Die Software-Präferenz kann vom Betriebssystem ignoriert werden und beweist keine physische Backendwahl. Decoder-/Cachetests prüfen Originalabmessungen, Orientierung, PNG/JPEG-Rundlauf nach Neustart und Artefaktbesitz. Core-Tests prüfen historische Einstellungen und unveränderte Snapshot-Prüfsummen sowie Speicherung und Backup/Restore. Alle Testbilder sind synthetisch; lokale persönliche Testbilder werden weder benötigt noch veröffentlicht. Es wird kein Leistungsvorteil gegenüber dem bisherigen Stand behauptet.

Der integrierte Gesamtlauf bestand mit **1011 App-Tests in 129 Suites** und **356 Core-Tests in 47 Suites**. Die vorhandene Swift-6.4-Toolchain begrenzte Swift Testing auf vier parallele Testtasks:

```sh
./scripts/test.sh --skip-build --jobs 3 --experimental-maximum-parallelization-width 4
```

Ein vorheriger Gesamtlauf ohne diese Begrenzung traf bekannte Test-Watchdogs in [JPEG-Export #75](https://github.com/dr-dimitri/glowroom/issues/75), [Artefakt-Controller #108](https://github.com/dr-dimitri/glowroom/issues/108), [Katalogbereinigung #109](https://github.com/dr-dimitri/glowroom/issues/109) und [semantischer Suche #91](https://github.com/dr-dimitri/glowroom/issues/91). Auch diese Tests bestanden im anschließenden gezielten Nachlauf und im vollständigen begrenzt parallelen Lauf. Die `limitExceeded`-Meldung des Artefakttests kam aus dessen Wartehelper, nicht aus nachgewiesener Speichererschöpfung. Es wurden keine Duplikat-Issues angelegt und keine unabhängigen Produktionspfade verändert.

Das unabhängige Diffreview fand eine zunächst fehlende Berücksichtigung der Schärfung in der adaptiven Vorschauplanung. Diese wurde korrigiert, mit Schärfung allein und zusammen mit Masken/Retusche in kleinen Artefaktbudgets geprüft und erneut reviewt. Im Änderungsumfang blieben keine offenen Reviewbefunde.

Der damals erforderliche vollständige Release-Build war erfolgreich. `.build-app/` war vor Beginn nicht vorhanden, das alte `dist/PicEdit.app` wurde entfernt. Der gleichzeitig aktive Testpfad `.build/` blieb geschützt und wurde vom App-Build nicht verwendet. Bundle-Prüfung und lokale Signaturprüfung waren erfolgreich. Dieser historische Nachweis bezieht sich auf PicEdit. Der entsprechende aktuelle Befehl `GLOWROOM_BUILD_PATH=.build-app GLOWROOM_BUILD_JOBS=3 ./scripts/build-app.sh` erstellt `dist/Glowroom.app`.
