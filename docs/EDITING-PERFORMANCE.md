# Nicht destruktive Bearbeitung: GPU, Wiederverwendung und Parallelität

Stand: 16. Oktober 2026; Vergleichsbasis `b8d1247`.

## Umsetzung

Die Bildfilter liefen bereits über Core Image. Dessen Diagnoseausgabe (`CI_PRINT_TREE=1`) bestätigt für den bisherigen und den neuen Renderer auf dem Testrechner einen Metal-Kontext auf der Apple-M2-Pro-GPU. Es wurde daher keine zusätzliche Drittbibliothek eingebaut.

- Ein interaktiver und ein niedrig priorisierter Hintergrundkontext erlauben begrenzte Überlappung. Ab vier aktiven CPU-Kernen und 8 GiB physischem Speicher darf jeweils eine ausgewählte Bearbeitung und eine Hintergrundvorschau laufen, sonst insgesamt eine. Ein abgebrochener synchroner Systemaufruf belegt seinen Platz bis zur Rückkehr.
- Der interaktive Kontext verwendet dieselbe Bildbasis und unveränderte Entrauschungs-/Auto-Tonwert-Stufen bei Reglerbewegungen erneut. Bildidentität und normalisierte Filterparameter bestimmen die Gültigkeit. Höchstens eine Basis bis 64 MiB wird zusätzlich gehalten; Das Rendern einer anderen oder größeren Basis löst diese Referenzen und den alten Kontext-Cache. Core Image verwaltet die tatsächlichen Texturen selbst; 64 MiB sind kein Gesamtlimit des Renderers.
- Der Hintergrundkontext hält keine Filterpräfixe und deaktiviert das Zwischenergebnis-Caching. Fertige Bearbeitungen bleiben im bestehenden, auf 32 MiB begrenzten Ergebnis-Cache.
- Die kleine, auf höchstens 256 Pixel Kantenlänge reduzierte Auto-Tonwertanalyse bleibt auf der CPU. Acht Analyseergebnisse mit schwachen Bildreferenzen vermeiden wiederholte Histogramme. Gleiche laufende Anfragen teilen ihre Analyse; unabhängige Bilder können fortfahren. Es gibt keinen zusätzlichen Worker-Pool.
- Das fertige Bild wird mit `deferred: false` innerhalb des Hintergrund-Workers materialisiert. Rendering wird damit nicht auf das spätere Zeichnen in der UI verschoben. Farbprofil, Ausgabebittiefe, Transparenz, Filterreihenfolge und Filtergleichungen bleiben erhalten.
- Regleränderungen verwenden weiterhin die vorhandene decodierte Basis. Versionsprüfungen, Abbruch und Zusammenfassung schneller Änderungen bleiben bestehen. Originalbilder werden ausschließlich gelesen; akzeptierte Datenbankänderungen und Backups bleiben auf ihrem Actor geordnet.

Die automatische Backendwahl von Core Image bleibt erhalten. Falls kein unterstützter Renderpfad ein Bild liefert, wird der vorhandene verständliche Bearbeitungsfehler angezeigt. Eine Softwarepräferenz wurde auf diesem Rechner vom System ignoriert und weiterhin als Metal ausgeführt; daraus lässt sich kein CPU-/GPU-Vergleich ableiten.

## Messmethode

Optimierter Swift-Benchmark auf einem Apple M2 Pro, synthetische sRGB-Bilder. Direkte Renderings ändern die Belichtung bei jedem Aufruf und umgehen so den Cache fertiger Bearbeitungen. Ein vollständiger synchroner CGContext-Zeichenvorgang erzwingt die Materialisierung; die Zeiten schließen diesen Transfer ein. Je Konfiguration ein eigener Prozess, eine Initialisierung und acht warme Stichproben. Einzelkonfigurationen laufen seriell, damit sie nicht miteinander um die GPU konkurrieren.

„Einfach“ verändert nur die Belichtung. „Komplex“ kombiniert Auto-Tonwerte, Struktur, Klarheit, Farbrauschminderung und Belichtung. „Bildwechsel“ alterniert zwei gleich große Originale mit verschiedenen Pixeln. Spitzen-RSS erfasst den ganzen Prozess einschließlich Testdaten und Ausgabepuffer, nicht nur GPU-Texturen.

Die ersten Aufrufe enthalten Initialisierung und gegebenenfalls Shaderkompilierung. System-, Shader- und Datenträger-Caches wurden nicht geleert. Ihre stark schwankenden Zeiten sind kein belastbarer Kaltstartvergleich. Die Ergebnisse messen weder ImageIO-/RAW-Decodierung noch Fensterdarstellung oder UI-Layout. Große Kamera-RAW-Dateien standen nicht zur Verfügung; hierfür wird kein Beschleunigungs- oder Speichergewinn behauptet.

## Ergebnisse

### Gleichzeitige Vorschau und Bearbeitung

Eine komplexe Hintergrundvorschau mit 1536 × 1024 Pixeln startet, 1 ms danach wird eine einfache Bearbeitung mit 2400 × 1600 Pixeln angefordert. Beide Kontexte sind zuvor initialisiert; acht Paare mit jeweils neuen Einstellungen. Verglichen werden ein und zwei Worker desselben endgültigen Programms.

| Worker | Median bis ausgewähltes Bild fertig | Median bis beide fertig | Spitzen-RSS |
|---|---:|---:|---:|
| 1 | 11,089 ms | 13,335 ms | 147,8 MiB |
| 2 | 6,786 ms | 8,942 ms | 160,1 MiB |

Damit sinkt die Wartezeit des ausgewählten Bildes in dieser Last um 38,8 %, bei rund 12,3 MiB zusätzlichem Prozess-Spitzenverbrauch. Beide Varianten liefern dieselbe Stichprobenprüfsumme `15921463955957358664`. Der Benchmark misst die tatsächlichen Anfragen, garantiert aber nicht deren genaue interne Verschachtelung; der zusätzliche Scheduling-Test beweist die begrenzte Überlappung deterministisch mit blockierten Renderern.

### Direkte Bearbeitung

| Arbeitslast | Bisheriger Renderer, Median | Neuer Renderer, Median | Spitzen-RSS bisher / neu |
|---|---:|---:|---:|
| Einfach, 2400 × 1600 | 6,186 ms | 8,271 ms | 97,8 / 97,9 MiB |
| Einfach, 400 × 267 | 0,874 ms | 0,904 ms | 25,9 / 26,1 MiB |
| Komplex, 2400 × 1600 | 14,800 ms | 17,694 ms | 102,4 / 102,1 MiB |
| Komplex, 400 × 267 | 1,792 ms | 1,549 ms | 30,6 / 30,6 MiB |
| Bildwechsel, 2400 × 1600 | 14,243 ms | 15,767 ms | 117,5 / 117,4 MiB |

Diese getrennten Prozessläufe zeigen **keinen allgemeinen Einzelbild-Geschwindigkeitsgewinn**. Insbesondere der neue komplexe große Lauf schwankte zwischen 14,575 und 31,003 ms. Alle Stichprobenprüfsummen entsprechen exakt denen der Baseline; die Grafiktests vergleichen zusätzlich vollständige kleine Bilder.

Zur Eingrenzung der Schwankung wurde dasselbe endgültige Binary anschließend mit 24 wechselnden Belichtungswerten und ansonsten gleicher komplexer Verarbeitung verglichen:

| Konfiguration | Median | Spitzen-RSS |
|---|---:|---:|
| Produktionsstandard | 13,095 ms | 117,4 MiB |
| Explizit mit Zwischenbild-/Präfix-Cache | 13,220 ms | 103,0 MiB |
| Ohne Zwischenbild-/Präfix-Cache | 15,788 ms | 103,0 MiB |

Der kontrollierte Cache-Vergleich ergibt hier 16,3 % kürzere Renderzeit; alle drei Prüfwerte sind `3890091192201248823`. Der Standard nutzt dieselbe Cache-Konfiguration; die Ursache seines höheren gemessenen Prozess-Spitzenwerts wurde nicht isoliert. Dieser Vergleich isoliert die Cache-Einstellung innerhalb des neuen Renderers und ersetzt keinen Vorher-/Nachher-Nachweis für alle Arbeitslasten.

### Schnelle Regleränderungen und Analyse

24 Änderungen im Abstand von 10 ms mit 45 ms Zusammenfassung. Ein synthetischer Decoderaufruf erzeugt die Basis vor den Folgen; danach wird sie ohne weitere Decodierung wiederverwendet.

| Zustand | Ab letzter Änderung, bisher / neu | Neue Renderings |
|---|---:|---:|
| Leerer Ausgabecache | 148,793 / 179,479 ms | 1 |
| Treffer im Ausgabecache | 46,551 / 52,032 ms | 0 |
| Warmer Renderer, neue Werte | 65,375 / 74,472 ms | 1 |

Auch hier wird kein Latenzgewinn behauptet. Zusammenfassung und Wiederverwendung bleiben wirksam; die neuen Gesamtdauern der Folgen betragen 451,619 / 323,546 / 343,091 ms. Der kumulative Spitzen-RSS liegt bei 116,5 MiB. Der leere Ausgabecache ist kein kalter System- oder Shadercache.

Der isolierte CPU-Analysebenchmark mit 3072 × 2048 Pixeln und 60 Wiederholungen benötigte 10,577 ms für wiederholte frische Analysen gegenüber 0,018 ms für Cache-Treffer. Der erste Cache-Aufbau brauchte 6,261 ms. Das belegt vermiedene Histogrammarbeit, ist aber keine entsprechende Beschleunigung des vollständigen Renderings.

## Bewertung der Alternativen

Eine explizite Metal-Context-Erzeugung bietet gegenüber dem bereits aktiven Metal-Backend allein keinen Beschleunigungsnachweis. Die probeweise Übersetzung der Filter in zur Laufzeit kompilierte Metal-Kernels ergab keinen warmen Vorteil und zusätzliche Kaltstartkosten; sie wurde verworfen. Erzwungene Materialisierung von Zwischenstufen war langsamer und veränderte einzelne RGB-Werte um eine 8-Bit-Stufe.

Ein explizites Core-Image-`memoryTarget` von 128/64 MB verschlechterte im kontrollierten Vergleich das große komplexe Rendering und veränderte Stichprobenprüfsummen; die genaue interne Ursache wurde nicht isoliert. Ohne dieses Limit stimmten die Prüfsummen wieder mit der Baseline überein. Deshalb verwaltet Core Image seine Texturen selbst; begrenzt werden Anfragen, decodierte Basen und Anwendungs-Caches.

Apples Dokumentation beschreibt [Core-Image-Kontexte und Ausführungswege](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_tasks/ci_tasks.html), [Zwischenergebnis-Caching](https://developer.apple.com/documentation/coreimage/cicontextoption/cacheintermediates) und die [Software-Renderer-Präferenz](https://developer.apple.com/documentation/coreimage/cicontextoption/usesoftwarerenderer). Die Auswahl hier beruht zusätzlich auf den lokalen Renderdiagnosen und Messungen.

## Prüfung

130 Tests bestanden; der optionale Analysebenchmark wurde im vollständigen Testlauf übersprungen und zuvor separat in Release-Konfiguration ausgeführt. Die vier neuen Grafiktests prüfen Cache-Invalidierung über Bild-/Parameterwechsel, gleichzeitige unabhängige Quellen, Display P3 mit Transparenz und echter 16-Bit-Ausgabe sowie Wiederaufnahme nach Abbruch. Analyse- und Scheduling-Tests prüfen gemeinsame Anfragen, Fehler, Abbruch, Quellenfreigabe, Cache-Grenzen und maximal zwei tatsächlich aktive Renderer.

Die 13 funktionalen Analyse-/Scheduling-Prüfungen bestanden zusätzlich mit Thread Sanitizer ohne gemeldete Datenrennen; der optionale Benchmark blieb dabei ausgeschaltet. Der vollständige Testlauf, Shell-Syntaxprüfung und `git diff --check` waren erfolgreich. Der Release-Build von `dist/PicEdit.app` einschließlich Signierung wurde erfolgreich erstellt. Grafiktests und Apples `dsymutil` liefen mit normalem macOS-Zugriff außerhalb der restriktiven Automationssandbox.

Unabhängige Code-Reviews prüften außerdem Synchronisierung, Fehlerzustände und Graph-Invalidierung. Die gemessenen Performancegewinne gelten für die beschriebenen synthetischen Arbeitslasten auf diesem Rechner.

## Reproduktion

```sh
# Gesamte Matrix einschließlich Konkurrenzlast mit einem/zwei Workern
GLOWROOM_BENCHMARK_SESSION_API=1 scripts/benchmark-editing.sh

# Gezielter Vergleich mit ausgeschaltetem Zwischenbild-/Präfix-Cache
GLOWROOM_BENCHMARK_SESSION_API=1 scripts/benchmark-editing.sh --scenario complex --backend cached --iterations 24
GLOWROOM_BENCHMARK_SESSION_API=1 scripts/benchmark-editing.sh --scenario complex --backend uncached --iterations 24

# Alle Tests; Grafiktests benötigen eine normale macOS-Grafiksitzung
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-editing-tests scripts/test.sh --jobs 4

# Scheduling und Analyse unter Thread Sanitizer, getrenntes Build-Verzeichnis
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-editing-tsan scripts/test.sh --sanitize thread --jobs 3 --filter 'AutoToneAnalysisCacheTests|AdjustedPreviewPipelineTests'

# Optionaler isolierter CPU-Analysebenchmark in Release-Konfiguration
GLOWROOM_AUTOTONE_BENCHMARK=1 GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-analysis-benchmark scripts/test.sh -c release --filter AutoToneAnalysisCacheTests.benchmarkRepeatedLargePreviewAnalysis
```

Die Benchmark-Einstiegspunkte liegen unter `Sources/Glowroom/DeveloperTools` und werden mit dem vollständigen SwiftPM-App-Target in Release-Konfiguration gebaut. So bleiben Modulabhängigkeiten und Ressourcen mit der Anwendung synchron. Standardmäßig bleibt der Cache unter `.build-app/developer-tools/editing` erhalten. `GLOWROOM_BENCHMARK_BUILD_PATH` (alternativ `GLOWROOM_DEVELOPER_BUILD_PATH`) wählt einen anderen Build-Pfad; parallele Builds benötigen unterschiedliche Verzeichnisse. `GLOWROOM_BUILD_JOBS` begrenzt die Compilerparallelität, die Messszenarien selbst laufen nacheinander.

Für Vorhervergleiche kann `GLOWROOM_BENCHMARK_SOURCE_ROOT` auf einen separaten Checkout mit derselben Developer-Harness-Unterstützung zeigen. Ältere Checkouts ohne diesen Vertrag werden vor dem Build abgewiesen, damit kein regulärer App-Einstiegspunkt mit persönlichen Katalogdaten gestartet wird. Für solche historischen Stände deren damalige Benchmark-Skripte verwenden. `GLOWROOM_BENCHMARK_SESSION_API=1` aktiviert weiterhin die Session-Szenarien. Die Reparatur der Build-Skripte liefert keine neue Leistungsaussage zu den oben dokumentierten Messungen.

## Neue Messungen vom 21. Oktober 2026

Dieser Bericht bewahrt die historischen Ergebnisse von 16. Oktober. Der [neue Performancebericht zu #44](PERFORMANCE.md) ergänzt aktuelle Release-Phasenmessungen, native und sichtbare Maskenpfade, einen optionalen Rust-Vergleich und eine ausdrücklich freigegebene echte RAW-Datei. Seine Zahlen sind kein Vorher-/Nachher-Nachweis für die hier historischen Filteränderungen.
