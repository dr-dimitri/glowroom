# Parallelisierung und Prüfung

Stand: 16. Oktober 2026. Originalbilder werden weiterhin ausschließlich gelesen.

## Zuständigkeiten und Grenzen

- `FolderScanner` überlappt die Verzeichnisiteration mit höchstens vier Metadaten-/Validierungslesern. CPU-Anzahl und physischer Speicher reduzieren das Limit bei Bedarf (mindestens ein Leser, höchstens einer je GiB). Die TaskGroup erzeugt erst nach einem Ergebnis weitere Arbeit. Ergebnisse werden unabhängig von der Abschlussreihenfolge stabil sortiert. Bei Fehler oder Abbruch werden Kinder beendet und abgewartet; ein unvollständiger Scan ersetzt keinen Katalog.
- Die Verzeichnisiteration bleibt wegen des gemeinsam veränderlichen Iterators seriell. Überlappende Importordner werden in Eingabereihenfolge übernommen, weil Bildzugehörigkeit und vorhandene Bewertungen von vorherigen Ergebnissen abhängen. Es gibt keinen zusätzlichen Pool auf Ordnerebene beim Bildimport.
- Beim Öffnen laufen Bookmark-Auflösung und reine Verzeichnis-Nachpflege mit höchstens zwei parallelen Aufgaben außerhalb des MainActor. Diese Nachpflege startet keine Bilddecoder.
- `LibraryCatalogWorker` übernimmt Pfadauflösung, Importabgleich und Ordnerentfernung. Ein Importabgleich wird bei zwischenzeitlichen Katalogänderungen wiederholt; dadurch bleiben neue Bewertungen und Favoriten erhalten. Angenommene Entfernungen werden vor dem Beenden vollständig gespeichert.
- `LibraryProjectionWorker` berechnet Filter, Sortierung, Bildindex, Favoritenzahl und Ordnerbäume außerhalb des MainActor. Ein Actor begrenzt die Arbeit auf eine Berechnung gleichzeitig und verwendet Struktur-Caches erneut. Schnelle Änderungen werden zusammengefasst; ein Abbruch und eine Anfragenummer verhindern die Veröffentlichung überholter Ergebnisse. Swift-Sortierung selbst ist nicht unterbrechbar; der nachfolgende Abbruchcheck verwirft ihr Ergebnis. Die UI zeigt während der Aktualisierung einen Fortschrittsindikator und behält vorhandene Bilder bis zum neuen Ergebnis.
- Die bestehende Decodier-Pipeline hat drei Worker und reserviert nach Möglichkeit einen Platz für das ausgewählte Bild. Laufende größere Decodierungen können nun kleinere Anfragen desselben Originals mitbedienen. Jede wartende Ansicht kann ihren eigenen Bezug abbrechen.
- `AdjustedPreviewPipeline` verwaltet Anfragen in einem ansprechbaren Actor und rendert außerhalb des MainActor. Ab vier aktiven CPU-Kernen und 8 GiB physischem RAM dürfen höchstens eine ausgewählte Bearbeitung und eine Hintergrundvorschau gleichzeitig laufen, sonst insgesamt eine. Ausgewählte Bilder stehen vor wartenden Vorschaubildern; identische Bearbeitungen teilen sich Arbeit. Ein bereits laufender synchroner Core-Image-Aufruf behält seinen Platz bis zum tatsächlichen Ende. Das verhindert zusätzliche GPU-Arbeit und unkontrolliertes Wachstum der Zwischenbilder bei Abbruch.
- Die Render-Worker laufen parallel zu Decodierung und Cache-Ein-/Ausgabe. Zwei wiederverwendete Core-Image-Kontexte unterscheiden interaktive und niedrige Hintergrundpriorität. Core Image wählt seinen verfügbaren Ausführungspfad selbst; auf dem geprüften M2 Pro wird Metal verwendet. Der interaktive Kontext behält höchstens eine Bildbasis bis 64 MiB und ihren unveränderten Entrauschungs-/Auto-Tonwert-Graph. Das Rendern einer anderen oder größeren Basis gibt diese Referenzen frei. Farbprofil-, Transparenz- und Filterberechnung bleiben erhalten. Der kleine Auto-Tonwert-Histogrammschritt bleibt eine CPU-Reduktion ohne zusätzlichen Pool oder GPU-Rücklesen; bis zu acht Ergebnisse werden anhand schwacher Bildreferenzen geteilt. [Messungen und Grenzen](EDITING-PERFORMANCE.md) dokumentieren die zusätzliche Optimierung.
- SQLite-Schreibvorgänge, Revisionen und Wiederherstellung bleiben geordnet. Der gemeinsame Lifecycle-Gate registriert angenommene Katalog-, Editing- und Metadatenaufträge vor Taskstart. Nach einem konsistenten SQL-Snapshot darf die unveränderliche Artefakt-Paketkopie mit weiterer Bearbeitung überlappen; die Rotation wartet erneut auf angenommene Katalogänderungen. Beim Beenden werden angenommene Aufträge parallel abgeschlossen, danach abhängige letzte Katalog-/Metadatenprüfungen ausgeführt. Die tatsächlich beendete Editing-Wartung ist Voraussetzung für diese neuen finalen Writes. Details und Ressourcenlimits stehen im [Artefaktspeichervertrag](ARTIFACT-STORAGE.md).

Die Limits sind Arbeitsbudgets, keine harte Obergrenze für interne Threads von ImageIO/Core Image oder ihren Speicherbedarf. Eine laufende synchrone Betriebssystemoperation kann erst nach ihrer Rückkehr auf Abbruch reagieren.

Beim ersten Öffnen wird die Katalog-Koordinationswurzel samt vollständig geschriebenem und synchronisiertem Owner privat vorbereitet und anschließend atomar veröffentlicht. Gleichzeitige Erstöffner verwenden dieselbe Identität. Bestehende unbekannte oder beschädigte Koordinationsverzeichnisse bleiben gesperrt und unverändert. Nach einem Prozessabbruch können private `.catalog-coordination-root-….stage`-Reste erhalten bleiben; sie werden weder als aktive Koordination übernommen noch automatisch gelöscht. Diese Stage-Familie gehört ebenfalls zu den gegen Export geschützten internen Katalogpfaden.

## KI-Lookvorschläge

Die [drei lokalen Looks](AI-LOOKS.md) teilen einen gruppierten Modellaufruf und den bestehenden Inferenzplatz mit dem Einzelassistenten. Der Gruppenmodus ist Teil der Auftragsidentität. Unterschiedliche Looks lösen keine drei gleichzeitigen Modellsitzungen aus; ein laufender abgebrochener Aufruf behält seinen Platz bis zur echten Rückkehr. Abhängige Annahme und SQLite-Speicherung bleiben geordnet.

Die Hauptvorschau rendert nur die aktive Variante mit ausgewählter Priorität und höchstens 2400 Pixeln langer Kante. Kleine Karten entstehen aus derselben Entwicklungsbasis innerhalb der bisherigen Renderplätze mit nachrangiger Priorität und höchstens 512 Pixeln. Die UI hält höchstens drei Karten mit insgesamt 8 MiB, der globale Rendercache bleibt bei 32 MiB und 32 Einträgen. Es entstehen kein zusätzlicher Workerpool, keine weitere RAW-Decodierung pro Look und keine parallele CPU-Ersatzberechnung derselben GPU-Arbeit. Quellen-/Ziel-/Rasteridentität erlaubt Wiederverwendung unabhängig vom Prompt. Verwerfen, Kontextwechsel und Memory Pressure geben eigene Kartenreferenzen frei.

Verträge/Provider, UI sowie Rendering/Kartenspeicher wurden in getrennten Verantwortungsbereichen parallel entwickelt und anschließend gemeinsam geprüft. Modell-/GPU-Messungen laufen seriell, damit sie sich nicht gegenseitig verfälschen. Kleine Gruppenvalidierung und Kartenverwaltung bleiben geordnet, weil drei Elemente keinen zusätzlichen Workeraufwand rechtfertigen. Reproduzierbare Messung und ihre Grenzen stehen im [Look-Prüfbericht](AI-LOOKS.md#prüfung).

## Prüfung

Die ergänzende Prüfung der GPU-Bearbeitung und des Analyse-Caches ist im [Bearbeitungs-Performancebericht](EDITING-PERFORMANCE.md#prüfung) dokumentiert. Die folgenden Ergebnisse beziehen sich auf den vorangegangenen Parallelisierungsstand `b8d1247`.

118 Tests bestanden, verteilt auf 97 Bibliotheks-/Persistenz-/Scheduling-/Cache-Tests und 21 tatsächliche Render-/Auto-Tonwert-Tests. Neue Fälle prüfen begrenzte Überlappung, deterministische Metadaten, Abbruch und Fehler beim Scannen, überholte Filteranfragen, schnelle Metadatenänderungen, angenommene Ordnerentfernung beim Beenden, Priorisierung und unabhängigen Abbruch geteilter Render-/Decodier-Anfragen sowie parallelen Abschluss beider Speicherbereiche.

```sh
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-tests scripts/test.sh --jobs 4
scripts/test-image-pipeline.sh
scripts/benchmark-library.sh
scripts/benchmark-scanner.sh 120 5
PICEDIT_BENCHMARK_SESSION_API=1 scripts/benchmark-editing.sh
```

Der separate Vorschau-Smoke-Test (unter anderem Orientierung, Cache-Grenzen und 40 Abbrüche) und der Release-Build von `dist/PicEdit.app` waren ebenfalls erfolgreich. Apples `dsymutil` benötigte für den Release-Build die Ausführung außerhalb der Sandbox.

Die Tests und Benchmarks verwenden eigene Testdaten. Core Image benötigt eine normale macOS-Grafiksitzung; die 21 Grafiktests wurden außerhalb der restriktiven Ausführungssandbox erfolgreich ausgeführt. Unabhängige Tests wurden mit getrennten Build-Verzeichnissen ausgeführt; einzelne Benchmark-Konfigurationen laufen seriell, damit sie nicht miteinander um CPU und Datenträger konkurrieren.

## Gemessene Arbeitslasten

Einzelmessungen auf dem Entwicklungsrechner, optimierte Benchmark-Binaries; andere Entwicklungsprozesse können die Werte beeinflussen. Sie sind keine allgemeine Leistungszusage.

### Scanner

120 selbst erzeugte JPEGs mit jeweils 6000 × 4000 Pixeln, insgesamt etwa 532 MB. Separate Prozesse für einen und vier angeforderte Leser, jeweils fünf Scans. Der erste Lauf enthält frische ImageIO-/Typinitialisierung; der Betriebssystem-Dateicache wurde **nicht** geleert und ist daher kein nachgewiesener kalter Datenträger-Cache.

| Leser | Erster Lauf | Median der vier Folgeläufe | Spitzen-RSS |
|---|---:|---:|---:|
| 1 | 3,600 s | 3,471 s | 25,8 MiB |
| 4 | 1,399 s | 0,951 s | 47,0 MiB |

Für genau diese synthetische Last entspricht das etwa 3,65-fachem warmem Durchsatz bei höherem Speicherbedarf. Die Ein-Leser-Variante nutzt denselben neuen Scanner und isoliert damit den Einfluss der Parallelität.

### Bibliotheksberechnungen

10.000 synthetische Katalogeinträge ohne Bilddecodierung; identische Ergebnisprüfsumme 473849 vor und nach der Änderung.

| Arbeit | Vorher, synchron auf MainActor | Nachher, einschließlich Warten auf Hintergrundarbeit |
|---|---:|---:|
| Erste Ordnerauswahl | 24,34 ms | 18,44 ms |
| 12 Auswahl-/Layoutwechsel mit Projektionszugriffen | 21,64 ms | 0,15 ms |
| Erste Unterordnerauswahl | 19,37 ms | 14,53 ms |
| 12 wiederholte Unterordner-/Baumzugriffe | 0,06 ms | 0,04 ms |

Beim neuen Modell werden Ordnerbäume bereits beim Öffnen vorbereitet; ein Teil der Arbeit wurde also zeitlich verlagert. Die Werte belegen keinen gleich großen Gewinn für die gesamte Startzeit. Während des neuen Messabschnitts betrug der größte beobachtete Abstand eines auf 1 ms eingestellten MainActor-Timers 6,13 ms (14 Stichproben); Spitzen-RSS des Prozesses 54,7 MiB. Das ist eine begrenzte Reaktionsfähigkeits-Stichprobe, keine garantierte Framezeit.

### Schnelle Regleränderungen (Stand `b8d1247`)

Eine synthetische Basis mit 2400 × 1600 Pixeln, 24 Änderungen im Abstand von 10 ms, vorhandene Zusammenfassung über 45 ms. Tatsächliche Core-Image-Filter: Auto-Tonwerte, Struktur, Klarheit, Farbrauschminderung und Belichtung.

| Zustand | Zeit ab letzter Änderung | Gesamte Folge | Neue Renderings |
|---|---:|---:|---:|
| Frischer Anwendungs-/Render-Cache | 2526 ms | 2814 ms | 1 |
| Wiederholung mit warmem Cache | 45,98 ms | 330,54 ms | 0 |

Der injizierte synthetische Decoder wurde insgesamt einmal aufgerufen; während der beiden Reglerfolgen gab es keine weiteren Aufrufe. Er liefert ein bereits erzeugtes Bitmap, misst also keine tatsächliche ImageIO-Decodierung. Kumulativer Spitzen-RSS des Prozesses: 87,3 MiB. Der erste Lauf enthält Renderer-Initialisierung. Es gibt hierfür keine Vorhermessung und damit keine Aussage über eine Beschleunigung gegenüber dem alten Renderer.

Für repräsentative große Kamera-RAWs waren in dieser Aufgabe keine Testdateien verfügbar. RAW-Durchsatz, RAW-Spitzenspeicher und ein expliziter CPU-/GPU-Leistungsvergleich sind daher nicht gemessen. Der bestehende RAW-Benchmark kann mit ausdrücklich angegebenen lokalen Dateien ergänzend ausgeführt werden; die Grafikpfade selbst wurden in dieser Änderung nicht ausgetauscht.
