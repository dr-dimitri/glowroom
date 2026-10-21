# Performance-Messpfad und Maskenoptimierung (#44)

Stand: 21. Oktober 2026. Ausgangspunkt: `b195ef57b67e2560576cd38f20c09c381a2a3dfa` (aktualisierter `main`). Die historischen Ergebnisse in [EDITING-PERFORMANCE.md](EDITING-PERFORMANCE.md) bleiben eigenständige Messungen.

## Vor der Auswahl festgelegte Kriterien

Die Entscheidung fällt anhand der gesamten jeweiligen Aktion, nicht eines isolierten Kernels. Für die Swift-Wiederverwendung werden wiederholbare Verbesserungen in Append-/Strichfolgen erwartet; unveränderte und vollständige Neuberechnungen werden separat ausgewiesen. Ein zusätzlicher Rust-Produktionspfad müsste gegenüber dem besten Swift-Pfad mindestens 15 % und 2 ms Median der tatsächlich verwendeten Benutzeraktion einsparen, auch beim p95 außerhalb der zwischen Läufen beobachteten Streuung liegen und dürfte kleine Lasten nicht um mehr als 10 % beziehungsweise 0,5 ms verschlechtern. Diese Hürde berücksichtigt den zusätzlichen Build-/Architektur-/FFI-Aufwand; sie wurde vor den Abnahmemessungen festgelegt.

Die bestehenden Budgets bleiben erhalten: höchstens 16.777.216 native Maskenpixel, 268.435.456 Sampleprüfungen des vollständigen Dokuments, ein nativer Cachezustand je gemeinsamem Worker, höchstens 16 MiB geschätzte Raster-/Dokumentdaten je lokalem Cache und die bestehenden Render-Lanes. Originale, Farb-/Alphaverträge, Maskenbytes und vollständiger kanonischer SHA-256 bleiben unverändert. Eine Verbesserung des historischen kanonischen Workers allein rechtfertigt keine Rust-Abhängigkeit im heutigen sichtbaren Editor.

## Aktueller Pfad und Umfang

Der aktuelle Inline-Editor verwendet `MaskEditingModel(rendersOverlay: false)`: Pinselgeometrie wird über `LocalAdjustmentRenderer` direkt in einem Raster bis 2048 Pixel langer Kante gezeichnet. Der lokale Referenzcanvas ist auf 1024 Pixel begrenzt. Die zuvor im Issue beschriebene native Rasterisierung mit 1600-Pixel-Resampling und kanonischem Hash bleibt ein eigener Vertrags-/Entwicklerpfad. Beide werden getrennt gemessen. Das direkte lokale Raster wird nicht durch Resampling des nativen Rasters ersetzt; dadurch bleiben seine bisherigen Pixelwerte erhalten.

Die neuen Messspannen enthalten keine Dateipfade oder Bildinhalte. Quellenprüfung, ImageIO-Decode, CPU-Tonwertanalyse, Decoder-/Render-Warteschlange, Filtergraph, materialisiertes Core-Image-Rendering und UI-Übergabe sind getrennt sichtbar. Analyse und Maskenrasterisierung liegen innerhalb des Filtergraphs; diese überlappenden Spannen dürfen nicht addiert werden. Der UI-Harness misst den MainActor-Hop und die NSImage-Erzeugung; Fensterlayout und tatsächliche Bildschirmausgabe werden damit nicht gemessen.

## Messumgebung und Grenzen

Apple M2 Pro, Mac14,10, 12 CPU-Kerne, 16 GiB RAM; macOS 27.0.1 (26A434), Apple Swift 6.4 (swiftlang-6.4.0.34.1). Release-App-Target über den bestehenden Developer-Harness, vier Compilerjobs; Rust-Prototyp 1.99.1, `opt-level=3`, ein Codegen-Unit, Thin-LTO, keine Paketabhängigkeiten. Compiler und Tests laufen vor/nach Zeitmessungen. Messungen laufen seriell, weil zusätzliche CPU-/GPU-Last die Vergleichswerte und den Spitzen-RSS verfälschen würde.

OS-, Dateisystem- und Shadercaches werden nicht geleert. „Frischer Prozess“, „frische Pipeline“, „initialisierter Renderer“ und „warmer Ausgabecache“ sind getrennte Zustände; keiner wird als vollständig kalter Systemcache bezeichnet. Prozess-Spitzen-RSS enthält Harness, Validierung, CI und alle Vergleichsvarianten, nicht nur Cachebytes; er ist bei gemeinsamem Prozess kein isolierter Variantenvergleich.

Die sieben bereitgestellten lokalen JPEGs und die ausdrücklich freigegebene `IMG_8477.CR3` bleiben ausschließlich lokal und unverändert. Eine einzige RAW-Datei liefert keine Abdeckung mehrerer Kameras/RAW-Formate. Instruments/`xctrace` sind in der installierten Command-Line-Tools-Umgebung nicht verfügbar. Native `sample`-/`heap`-Diagnosen und Prozess-CPU-Zeit ergänzen die Phasenmessungen; GPU-Auslastung und Transfers werden daraus nicht abgeleitet. Profilbegleitete Läufe werden von unbeeinflussten Messungen getrennt.

## Ergebnisse

### Masken: finale Release-Matrix

Rezept 1, SplitMix64-Seed 44, vier Fixturefamilien: vier breite/weiche Striche, 96 gemischte Striche mit Radierer, schmale Linien sowie invertierte Randmasken. Die Folgen prüfen Snapshot, acht angehängte Striche, acht Punkte eines aktiven Strichs und acht History-Zustände einschließlich Undo/Redo, Umkehren und Löschen. Alle Varianten verwenden dieselben Dokumenthashes. Pro Fall wird eine komplette Aufwärmfolge verworfen; 20 weitere Folgen liefern 20 Snapshot- beziehungsweise 160 interaktive Stichproben je Variante. Variantenreihenfolge AB/BA beziehungsweise ABC/BCA/CAB rotiert. Bereits erfolgreiche Anfangsdokumente werden außerhalb der interaktiven Zeit primiert; das Öffnen ohne Basis steht separat im Snapshot-Fall.

Der vollständige `MaskRasterizer.rasterize` bleibt die unveränderte Pixelreferenz. Die lokale Vollrasterreferenz verwendet denselben neuen konservativen Cache-Budgetvertrag wie die inkrementelle Variante; sie ist kein separates historisches App-Binary. Insbesondere darf ein History-Vergleich nicht als isolierter Vorher-/Nachher-Nachweis des früher nur nach Pixelbytes begrenzten LRU ausgelegt werden. Die wiederholten Append-/Strichfolgen messen die vermiedene Pixelarbeit bei identischer Materialisierung.

**Viele Striche, aktiver Pinsel:** lokale App-Graphfunktion einschließlich vollständiger Core-Image-Materialisierung, ohne UI-Ereignisverarbeitung, Debounce, Layout oder Bildschirmausgabe. Der lokale Kontext deaktiviert Zwischenbildcaching; Shader-/OS-Caches bleiben wie oben beschrieben initialisiert. Die großen Referenzcanvases testen die skalierende App-Funktion; neu angelegte lokale Editorvektoren verwenden heute höchstens 1024 Pixel lange Kante.

| Referenzcanvas → lokales Raster | Vollraster p50 / p95 | Inkrementelles Swift p50 / p95 |
|---|---:|---:|
| 1024×1024 → 1024×1024 | 6,61 / 7,05 ms | 1,99 / 2,43 ms |
| 4096×2048 → 2048×1024 | 8,02 / 8,63 ms | 3,45 / 3,88 ms |
| 4096×4096 → 2048×2048 | 22,10 / 23,52 ms | 5,95 / 6,38 ms |

Beim großen Fall sinken Median und p95 dieses lokalen Renderaufrufs um 73,1 % beziehungsweise 72,9 %. Durchsatz: 45,1 → 169,3 gemessene Aufrufe/s, ohne Priming/Logging/Validierung in der Latenz. Das ist kein gemessener Bildschirm-FPS-Wert. Die ursprüngliche vorsichtige Punkt→Linie-Vollberechnung wurde erst nach der ersten Matrix durch exakte Rechteck-Rekonstruktion ersetzt: dadurch sinkt auch deren zuvor bei 21,70 ms verbleibendes p95 auf 6,38 ms. Die Rohdaten `initial-*` bewahren diese Zwischenstufe.

**Kanonischer nativer Worker, viele Striche/aktiver Pinsel:** inklusive nativer Gray8-Pixel, Resampling bis 1600 Pixel, vollständigem SHA-256 und erzeugtem RGBA-Overlay; keine UI-Darstellung.

| Natives Raster | Vollreferenz p50 / p95 | Optimiertes Swift p50 / p95 | Rust-Resampling mit gleichem Swift-Cache p50 / p95 |
|---|---:|---:|---:|
| 1024×1024 | 5,79 / 5,92 ms | 1,22 / 1,30 ms | 1,22 / 1,31 ms |
| 4096×2048 | 26,00 / 26,59 ms | 7,20 / 8,58 ms | 6,81 / 8,16 ms |
| 4096×4096 | 77,21 / 79,07 ms | 14,53 / 17,41 ms | 13,77 / 16,83 ms |

Im 16-MP-Referenzfall entfallen Median 58,38 ms (ungefähr 76 % der Aktion) auf native Rasterisierung, 10,78 ms auf Resampling und 6,41 ms auf SHA-256. Optimiertes Swift benötigt dafür 0,68 / 5,64 / 6,41 ms: Hash und Resampling bleiben relevant, der vollständige Hash wird ausdrücklich nicht durch einen Teilhash ersetzt. Die Phasenmediane sind keine exakt additive Zerlegung eines einzelnen Samples. CPU-p50 des ganzen Aufrufs: 77,18 → 14,52 ms; Durchsatz: 12,93 → 65,97 Aufrufe/s.

Snapshot ohne wiederverwendbare Basis bleibt teuer: 16 MP/viele Striche benötigen 75,87/76,52 ms p50/p95 in der Referenz und 70,45/72,60 ms mit Swift; der Gewinn stammt dort aus der horizontalen Resamplingtabelle. In der nativen History-Folge benötigen notwendige Vollrekonstruktionen bei Undo weiterhin p95 74,74 ms statt 79,95 ms. Der eine native Zustand wird bewusst nicht zu einem großen Undo-Rastercache erweitert.

Es gibt **keinen allgemeinen Gewinn für jede Maske**: bei schmalen Linien/8-MP-Canvas steigt der lokale Append-Median von 3,17 auf 3,35 ms und der aktive Median von 3,22 auf 3,38 ms. Kopie und Cacheverwaltung können bei sehr wenig Pixelarbeit überwiegen; die absoluten Mehrkosten bleiben hier unter 0,2 ms. Die komplette Matrix mit Min/Max, p50/p95, Durchsatz und Phasenmedians steht in `summary.csv`.

Prozess-Spitzen-RSS der nativen Vergleichsmatrix: bis 185,1 MiB; lokaler Matrixlauf: bis 1647,9 MiB einschließlich CI-Kontext, Quellen, Verifikation, allen Varianten und deren vorangegangenen Lasten. Diese kumulativen Werte erlauben **keinen isolierten RSS-Gewinn je Variante** und ersetzen keine GPU-Speichermessung. Der Cachevertrag begrenzt angerechnete Raster-/Dokumentdaten auf 16 MiB pro lokalem Cache, nicht den gesamten Prozess. Ein nativer Wiederverwendungszustand hält zusätzlich höchstens 16 MiB Gray8; während der privaten Copy-on-write-Kandidatur können alter und neuer Zustand gleichzeitig leben.

### Native Profilierung und Auswahl

Die getrennten `MallocStackLogging=1`-/`sample`-/`heap`-Läufe bestätigen die eigenen Pixelschleifen als dominanten CPU-Kandidaten im Referenzpfad. Nach der Optimierung sind unter anderem `AccelerateCrypto_SHA256_compress` und Resampling sichtbar; die relevante Kopie bleibt der private Copy-on-write-Puffer. Der finale Heap-Snapshot hat 3014 lebende Allokationen mit 42.127.552 Bytes, darunter drei große Data-Puffer mit zusammen 41.009.152 Bytes. Das ist ein Zeitpunkt samt Harness/Priming/Validierung, keine vollständige Allokationshistorie oder per-Aktion-Allokationszahl. `sample` zeigt einzelne `memmove`-Stichproben; daraus wird kein exakter Transferdurchsatz abgeleitet.

`CI_PRINT_TREE=1` bestätigt im separaten synthetischen Diagnoselauf einen **Metal-Kontext** (`Glowroom interactive`). Es wurden keine GPU-Auslastungs-/Transferzähler erfasst und keine neue gleichwertige CPU-/GPU-Performancebehauptung aufgestellt. Die automatische Core-Image-Backendwahl bleibt erhalten. Ein weiterer Metal-/Accelerate-Pixelpfad wäre ohne diese Daten und mit zusätzlichem Readback des kanonischen Rasters nicht begründet.

**Rust wird nicht produktiv integriert.** Gegenüber optimiertem Swift beträgt der Vorteil im 16-MP-Gesamtaufruf der Matrix nur 0,77 ms beziehungsweise 5,3 %; der 8-MP-Fall spart 0,39 ms. Bei 1 MP ist das Resampling eine identische Größen-No-op und ruft keinen Rust-Kernel auf. Der anschließende eigenständige Wiederholungslauf bestätigt denselben Abstand. Nach zusätzlicher expliziter Absicherung der FFI-Kontextlebensdauer wurde der vollständige Vergleich nochmals geprüft (`repeat-safe-16mp-active`): Swift 14,08/14,39 ms und Rust 13,33/13,55 ms p50/p95, jeweils 160 Samples und exakte Bytes/Hashes. Der Vorteil von 0,75 ms/5,4 % unterschreitet die vorab gewählten 2 ms/15 % deutlich. Der heutige sichtbare lokale Editor benötigt diesen Resamplingkern ohnehin nicht.

Der Rust-Prototyp verwendet denselben Algorithmus mit horizontaler Samplingtabelle wie optimiertes Swift; der große Gewinn durch inkrementelle Striche und die Tabelle wird Rust nicht zugerechnet. Der gesamte Swift→Rust→Swift-Aufruf einschließlich Ausgabe-/Tabellenallokation, Eigentumsrahmen und Abbruchcallbacks ist gemessen; `dlopen` geschieht einmal vor der Last. Keine Bildkopie oder JSON-/Dateiübergabe an der FFI-Grenze. Pointer, Größen/Strides, Rückgabecodes, Lebensdauer, Threadschutz, Panic-/Abbruchverhalten, Compilerpin, Lizenz und Hostarchitektur sind im [Prototypvertrag](../tools/mask-performance/README.md) dokumentiert. Produktionsbuild, Link, Bundle und Signatur benötigen Rust nicht; Swift bleibt vollständig funktionsfähig. Universeller Rust-Build, App-Link/Bundle/Signatur und zusätzliche Architekturprüfung wären unbegründete Integrationskosten.


## Echte RAW-Vorschau und bestehende Interaktionslasten

Die freigegebene CR3-Datei hat 6000 × 4000 Pixel (24 MP, unverändertes Original; damit größer als das native Maskenlimit). Sie wurde mit dem tatsächlichen `PreviewDecoder`, `ImagePreviewPipeline`, `AdjustedPreviewPipeline` und `EditRenderer` geprüft. `allowsEmbeddedPreview=false`, HDR aus, synthetisch reproduzierbare globale Auto-Tonwert-/Farbentrauschungs-/Klarheits-/Struktur-/Belichtungseinstellungen. Je Größe 20 Folgen; der erste Prozessaufruf ist separat ausgewiesen, die übrigen 19 frischen Pipelines benutzen initialisierte System-/Rendererzustände. Nach jeder frischen Pipeline folgen unveränderte Wiederholung und neue Reglerwerte auf derselben decodierten Basis.

| Vorschau | Frische Pipeline, initialisierter Prozess p50 / p95 | Neue Werte mit warmer Basis p50 / p95 | Prozess-Spitzen-RSS |
|---|---:|---:|---:|
| 512 × 341 | 247,93 / 254,50 ms | 1,62 / 1,79 ms | 560,1 MiB |
| 2400 × 1600 | 75,87 / 81,11 ms | 8,33 / 10,21 ms | 382,0 MiB |
| 4096 × 2731 | 199,69 / 206,58 ms | 34,51 / 38,37 ms | 1051,4 MiB |

Bei 2400 Pixeln entfallen im initialisierten Prozess mit frischen Pipelines Median 2,55 ms auf Quellenprüfung, 55,80 ms auf Decode, 5,24 ms auf Graphaufbau und 11,55 ms auf materialisiertes Rendering. Bei 4096 Pixeln sind es 2,55 / 145,26 / 13,32 / 37,29 ms. Die Phase Analyse liegt innerhalb des Graphs. Die UI-Übergabe liegt im warmen Zustand bei ungefähr 0,02–0,04 ms und misst weder Layout noch Bildschirmausgabe. Dies ist eine aktuelle Baseline, kein Nachweis beschleunigter RAW-Decodierung. Insbesondere ist der erzwungene 512-Pixel-Ladeweg auf dieser Datei langsamer als 2400 Pixel; daraus wird keine allgemeine Skalierungsregel abgeleitet.

Die ersten Prozessaufrufe benötigten 1477,26 / 340,43 / 411,65 ms bei 512 / 2400 / 4096 Pixeln. Plugin-/AppKit-/Shaderinitialisierung und nicht geleerte Systemcaches verhindern ihre Auslegung als vollständig kalte Cachemessung. Wiederholungen bei 512/2400 treffen den Ausgabecache (Median 0,032 / 0,038 ms, keine neuen Decode-/Renderphasen). Das Rohdatenlabel `warm-output` bezeichnet die unveränderte Wiederholungsanfrage: **4096 × 2731 passt nicht in den bestehenden 32-MiB-Ausgabecache**, wird erneut gerendert und benötigt Median 34,83 ms. Die Quelle bleibt dennoch im Decoder-Cache. Der hohe Prozess-Spitzenwert bei 4096 ist ausdrücklich kein Maskencachelimit oder nachgewiesener neuer Speichergewinn.

Zusätzlich wurden alle sieben bereitgestellten JPEGs mit derselben 2400-Pixel-Matrix und je 20 Folgen geprüft (`jpeg-1` bis `jpeg-7`). Die Rohdaten enthalten ausschließlich Zeiten, Ausgabegrößen, Prozess-RSS und Konsumprüfsummen. Private Quelldateien und EXIF-Inhalte werden nicht veröffentlicht. Weitere RAW-Größen, Kameras, Formate, Hardware und tatsächliche CPU-/GPU-Backendalternativen bleiben unvermessen.

20 unabhängige schnelle Reglerfolgen mit je 24 Ereignissen im 10-ms-Abstand und 45-ms-Zusammenfassung ergaben ab dem letzten Ereignis p50/p95 von 168,14/178,11 ms für leeren Ausgabecache, 49,54/51,90 ms für Cachetreffer und 63,38/65,10 ms für neue Werte bei warmem Renderer. Pro Prozess wurde die Basis genau einmal erzeugt; die Folgen erzeugten 1/0/1 Renderings und keine weitere Decodierung. Diese Last verwendet weiterhin synthetische Bilder, keine RAW-Datei. Die aktuellen RAW-Messungen zeigen separat Basiswiederverwendung ohne neue Decodephase.

20 Konkurrenzpaare mit ausgewähltem 2400×1600-Bild und nachrangiger 1536×1024-Vorschau auf den bestehenden zwei Lanes ergaben Median 5,97 ms bis zum ausgewählten Bild und 7,80 ms bis zum Paarabschluss. Direkte einfache/komplexe Bearbeitung und wechselnde Quellen wurden mit je 20 warmen Stichproben zusätzlich geprüft; alle Rohwerte stehen in `editing-*.txt` und `contention.txt`. Hier werden keine allgemeinen neuen Filter-/Schedulinggewinne behauptet.

Der bestehende Bibliotheksbenchmark mit 10.000 synthetischen Datensätzen bestand mit unveränderter Ergebnisprüfsumme 473849. Ein aktueller Kontrolllauf benötigte 20,21 ms für die erste sichtbare Projektion und 14,57 ms für die erste Unterordnerprojektion; Spitzen-RSS 80.592.896 Bytes. Das ist ein einzelner Regressionstest ohne neuen Vorhervergleich, keine allgemeine neue Geschwindigkeitsbehauptung (`library.txt`).

## Reproduktion und Rohdaten

Alle Befehle im Repository ausführen. Builds und Tests zuerst abschließen, danach die Messprozesse ohne konkurrierende Compiler oder Bildarbeit nacheinander starten. `GLOWROOM_MASK_RUST=1` ist ausschließlich ein Opt-in für den Entwicklerprototyp; die gepinnte Rust-Toolchain muss lokal vorhanden sein. Ohne diese Variable läuft der Vergleich vollständig mit Swift.

```sh
# Tatsächliches Release-App-Target; getrenntes Developer-Buildverzeichnis.
GLOWROOM_MASK_RUST=1 ./scripts/benchmark-masks.sh > /tmp/masks-all.jsonl
GLOWROOM_MASK_RUST=1 ./scripts/benchmark-masks.sh --width 4096 --height 4096 \
    --mask-fixture many-mixed --mask-workload active --iterations 20 \
    > /tmp/repeat-16mp-active.jsonl

# Harness einmal bauen, danach denselben Build für die lokalen Lasten verwenden.
benchmark_binary="$(GLOWROOM_BENCHMARK_SESSION_API=1 GLOWROOM_BUILD_JOBS=4 ./scripts/build-developer-tool.sh editing)"
for dimensions in '1024 1024' '4096 2048' '4096 4096'; do
    read -r width height <<EOF
$dimensions
EOF
    "$benchmark_binary" --scenario local-masks --width "$width" --height "$height" \
        --iterations 20 > "/tmp/local-${width}x${height}.jsonl"
done

# Nur ausdrücklich freigegebene lokale Dateien; kein Scan einer Bildbibliothek.
for width in 512 2400 4096; do
    "$benchmark_binary" --scenario preview --input "$PWD/IMG_8477.CR3" \
        --width "$width" --iterations 20 > "/tmp/raw-${width}.jsonl"
done
for index in 1 2 3 4 5 6 7; do
    "$benchmark_binary" --scenario preview \
        --input "$PWD/Fixtures/LocalTestImages/test_picture${index}.jpg" \
        --width 2400 --iterations 20 > "/tmp/jpeg-${index}.jsonl"
done
for scenario in simple complex alternating; do
    "$benchmark_binary" --scenario "$scenario" --width 2400 --height 1600 \
        --iterations 20 > "/tmp/editing-${scenario}.txt"
done
"$benchmark_binary" --scenario contention --workers 2 --width 2400 --height 1600 \
    --iterations 20 > /tmp/contention.txt
for iteration in $(seq 1 20); do
    "$benchmark_binary" --scenario burst
done > /tmp/slider-bursts.txt

library_binary="$(GLOWROOM_BUILD_JOBS=4 ./scripts/build-developer-tool.sh library)"
"$library_binary" > /tmp/library.txt
```

Die Bash-Schleife mit `read` erhält beide Dimensionen ohne `eval`. Bei getrennten Aufrufen des gemessenen Binaries lassen sich die Herkunftsfelder über `GLOWROOM_BENCHMARK_COMMIT`, `GLOWROOM_BENCHMARK_SWIFT_VERSION` und `GLOWROOM_BENCHMARK_RUST_VERSION` setzen; das Maskenskript setzt sie automatisch. Quelldateien, Compiler-/Binärfingerprints und Hostumgebung sind zusätzlich in diesem Bericht und den Manifesten festgehalten.

Die eingecheckten [Rohdaten](../reports/performance/) sind gzip-komprimierte JSONL beziehungsweise Textausgaben. `summary.csv` lässt sich mit folgendem Befehl reproduzieren; die Anfangsmatrix und profilbegleitete Läufe werden absichtlich nicht mit den finalen Akzeptanzmessungen gemischt:

```sh
python3 scripts/summarize-performance.py \
    reports/performance/masks-*.jsonl.gz reports/performance/local-*.jsonl.gz \
    reports/performance/raw-*.jsonl.gz reports/performance/jpeg-*.jsonl.gz \
    reports/performance/repeat-16mp-active.jsonl.gz \
    reports/performance/repeat-safe-16mp-active.jsonl.gz \
    --output /tmp/summary.csv
diff -u reports/performance/summary.csv /tmp/summary.csv
```

Das Skript gruppiert Dateiname, Größe, Fixture, Aktion, Variante und Cache-/Initialisierungszustand getrennt. Es verwirft Aufwärmfolgen, interpoliert den Median und verwendet den nächsten Rang für p95. `requests_per_second` ist die Zahl gemessener Aufrufe geteilt durch ihre kumulierte Latenz, kein paralleler Durchsatz oder Bildschirm-FPS.

`matrix-source-sha256.txt` und `matrix-binaries-sha256.txt` kennzeichnen die volle finale Matrix. Danach wurde ausschließlich im Entwickler-FFI-Wrapper die Kontextlebensdauer zusätzlich explizit mit `withExtendedLifetime` gesichert; `source-sha256.txt`, `measured-binaries-sha256.txt` und `repeat-safe-16mp-active` kennzeichnen diesen nochmals gemessenen Stand. Im anschließenden Review wurde nur noch der CLI-Parser präzisiert: ungültige Seeds werden ausdrücklich abgewiesen und die Hilfe nennt alle Szenarien. Produktionsalgorithmen, Fixtures und gültiger Seed 44 sind zwischen diesen Ständen identisch. Die kleinen SHA-Manifeste erlauben eine Zuordnung trotz noch uncommittierter Implementierung während der Messung; als historischer Commit ist in den Rohdaten der oben genannte Ausgangsstand erfasst.

Getrennte native Profilierung verwendet beispielsweise `MallocStackLogging=1` beim Start eines längeren einzelnen Maskenfalls (`--mask-fixture many-mixed --mask-workload active --mask-backend reference` beziehungsweise `swift`), danach `sample PID 5 -file /tmp/mask-sample.txt` und `heap PID`. Der finale Diagnoselauf verwendete denselben optimierten Kern wie die Akzeptanzmatrix. Die eingecheckten Textauszüge enthalten symbolische Stack-/Allokationsdaten, keine privaten Bilddateien; abschließende Leerzeichen und Leerzeilen wurden normalisiert. `CI_PRINT_TREE=1` wurde ausschließlich für den separaten synthetischen Renderdiagnoselauf gesetzt.

## Korrektheit, Nebenläufigkeit und Review

Die neuen Core-Tests vergleichen vollständige Bytes und kanonische Hashes gegen den unveränderten Vollrasterpfad: native und skalierte Raster, Crops, Brush/Erase, Invertieren, Append, Punkt→Kapsel, Undo, Canvaswechsel, Arbeitsbudgets sowie Abbruch nach Teilwrites. Grenzwerte an weichen Kanten werden mit `nextDown`, exakt und `nextUp` geprüft. App-Tests prüfen Quelle/Sitzung/Revision, vollständige Overlaybytes, fehlgeschlagene/abgebrochene Kandidaten, begrenzten lokalen Cache, materialisierte Brush-/Refinementgraphen und TaskLocal-Tracing. Bestehende Pipeline-Tests decken schnelle Änderungen, Bildwechsel, Priorität und ausstehende native Arbeit nach Abbruch ab.

```sh
./scripts/test.sh --jobs 4
GLOWROOM_TEST_BUILD_PATH="$(mktemp -d /private/tmp/glowroom-mask-tsan.XXXXXX)" \
    ./scripts/test.sh --sanitize thread --jobs 2 \
    --filter 'MaskRasterizationCacheTests|MaskOverlayWorkerTests|LocalMaskImageCacheTests|PipelineTraceTests|MaskEditingModelTests|AdjustedPreviewPipelineTests|JPEGExportModelTests|SemanticLibraryTests'
CARGO_TARGET_DIR=/private/tmp/glowroom-mask-rust \
    cargo test --manifest-path tools/mask-performance/Cargo.toml --release --locked --offline
```

Der separate frische Thread-Sanitizer-Build hat 65 App-Tests in sieben Suites und neun Core-Tests ohne Race-Meldung bestanden; die Testbibliothek linkt nachweislich `libclang_rt.tsan_osx_dynamic.dylib`. Die vier Rust-ABI-/Strides-/Fehler-/Abbruchtests bestehen ebenfalls. Das ist eine Prüfung der ausgeführten Lasten, kein Beweis für jede mögliche Ausführungsreihenfolge.

Der finale normale parallele Gesamtlauf besteht mit **1050 App-Tests in 136 Suites und 372 Core-Tests in 49 Suites**. Nach dem frischen Testbuild mit `./scripts/test.sh --jobs 2 --filter DevelopSharpeningWorkspaceTests` wurde `./scripts/test.sh --skip-build` für beide vollständig gebauten Testtargets ausgeführt. Zuvor aufgefallene bestehende Test-Rennen wurden direkt behoben: JPEG-Fake/Modellzustände werden ereignisbasiert beobachtet, der semantische Test wartet auf die angenommene Serviceantwort, und der native Schärfentest beachtet Backup-Bereitschaft und Fokus vor Layout. Seine zwei gezielten Tests bestehen zusätzlich. Produktionsbackups, Export-, Status- und Fokusverhalten wurden dafür nicht verändert; Diagnose und Prüfprinzipien stehen in [TEST-SCHEDULING.md](TEST-SCHEDULING.md).

Frühe Entwicklerbuilds scheiterten an inzwischen korrigierten Bezeichner-/`throws`-Stellen im neuen Messcode. Ein weiterer Harness-Build scheiterte beim Erzeugen der dSYM an einer Sandbox-Beschränkung; der identische autorisierte Build in der normalen macOS-Umgebung bestand. Native Fenstertests wurden ebenfalls dort abgeschlossen. Der abschließende Release-Harness besteht einschließlich expliziter Ablehnung ungültiger Seeds und exakter Raster-/Hash-/Overlayprüfung für 0, 44 und `UInt64.max`.

Das finale Diff einschließlich Core-/App-Schnittstellen, Tests, Dokumentation, Rust-Lebensdauer und Messdaten wurde unabhängig gegengeprüft. Gefundene Punkte (unter anderem FFI-Kontextlebensdauer, Seedvalidierung und die genaue Cache-Eintragszählung) sind korrigiert und erneut geprüft; es bestehen keine offenen Reviewbefunde. Die vollständige CSV lässt sich aus den 18 finalen Eingabedateien mit 286 Ergebnisgruppen reproduzieren.

Da Laufzeitquellcode geändert wurde, war der vollständige saubere App-Build erforderlich. Vor der Bereinigung wurden laufende Compiler-/Testprozesse ausgeschlossen; `GLOWROOM_BUILD_PATH` und `PICEDIT_BUILD_PATH` waren ungesetzt. Alte generierte Ergebnisse einschließlich Modulcaches aus `.build/` und `.build-app/developer-tools/editing/` sowie `dist/Glowroom.app` wurden entfernt. Dependency-Checkouts, Repositories, heruntergeladene Artefakte und Lockdateien blieben erhalten. Danach bestand `GLOWROOM_BUILD_JOBS=4 ./scripts/build-app.sh` in Release-Konfiguration (117,45 s SwiftPM-Build, drei Compilerjobs plus parallele Iconerzeugung). Bundle-Metadaten und Ad-hoc-Signatur wurden erfolgreich geprüft. Das Produktionsbinary enthält weder den Rust-FFI-Einstiegspunkt noch eine Rust-Prototypbibliothek. Bereinigung und Build blieben wegen aktiver Pfadnutzung beziehungsweise ihrer Abhängigkeit geordnet.
