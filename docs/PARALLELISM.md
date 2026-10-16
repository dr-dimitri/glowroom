# Parallelisierung und Prüfung

Stand: 16. Oktober 2026. Originalbilder werden weiterhin ausschließlich gelesen.

## Zuständigkeiten und Grenzen

- `FolderScanner` überlappt die Verzeichnisiteration mit höchstens vier Metadaten-/Validierungslesern. CPU-Anzahl und physischer Speicher reduzieren das Limit bei Bedarf (mindestens ein Leser, höchstens einer je GiB). Die TaskGroup erzeugt erst nach einem Ergebnis weitere Arbeit. Ergebnisse werden unabhängig von der Abschlussreihenfolge stabil sortiert. Bei Fehler oder Abbruch werden Kinder beendet und abgewartet; ein unvollständiger Scan ersetzt keinen Katalog.
- Die Verzeichnisiteration bleibt wegen des gemeinsam veränderlichen Iterators seriell. Überlappende Importordner werden in Eingabereihenfolge übernommen, weil Bildzugehörigkeit und vorhandene Bewertungen von vorherigen Ergebnissen abhängen. Es gibt keinen zusätzlichen Pool auf Ordnerebene beim Bildimport.
- Beim Öffnen laufen Bookmark-Auflösung und reine Verzeichnis-Nachpflege mit höchstens zwei parallelen Aufgaben außerhalb des MainActor. Diese Nachpflege startet keine Bilddecoder.
- `LibraryCatalogWorker` übernimmt Pfadauflösung, Importabgleich und Ordnerentfernung. Ein Importabgleich wird bei zwischenzeitlichen Katalogänderungen wiederholt; dadurch bleiben neue Bewertungen und Favoriten erhalten. Angenommene Entfernungen werden vor dem Beenden vollständig gespeichert.
- `LibraryProjectionWorker` berechnet Filter, Sortierung, Bildindex, Favoritenzahl und Ordnerbäume außerhalb des MainActor. Ein Actor begrenzt die Arbeit auf eine Berechnung gleichzeitig und verwendet Struktur-Caches erneut. Schnelle Änderungen werden zusammengefasst; ein Abbruch und eine Anfragenummer verhindern die Veröffentlichung überholter Ergebnisse. Swift-Sortierung selbst ist nicht unterbrechbar; der nachfolgende Abbruchcheck verwirft ihr Ergebnis. Die UI zeigt während der Aktualisierung einen Fortschrittsindikator und behält vorhandene Bilder bis zum neuen Ergebnis.
- Die bestehende Decodier-Pipeline hat drei Worker und reserviert nach Möglichkeit einen Platz für das ausgewählte Bild. Laufende größere Decodierungen können nun kleinere Anfragen desselben Originals mitbedienen. Jede wartende Ansicht kann ihren eigenen Bezug abbrechen.
- `AdjustedPreviewPipeline` verwaltet Anfragen in einem ansprechbaren Actor und rendert auf einem separaten Worker. Ausgewählte Bilder stehen vor wartenden Vorschaubildern; identische Bearbeitungen teilen sich Arbeit. Ein bereits laufender synchroner Core-Image-Aufruf behält seinen Platz bis zum tatsächlichen Ende. Das verhindert zusätzliche GPU-Arbeit und unkontrolliertes Wachstum der Zwischenbilder bei Abbruch.
- Der einzelne Render-Worker läuft parallel zu Decodierung und Cache-Ein-/Ausgabe. Core Image verwendet weiterhin einen gemeinsamen Kontext und wählt seinen verfügbaren Ausführungspfad selbst. Farbprofil-, Transparenz- und Filterberechnung wurden nicht verändert. Der kleine Auto-Tonwert-Histogrammschritt bleibt bewusst eine CPU-Reduktion ohne zusätzlichen Pool oder GPU-Rücklesen.
- SQLite-Schreibvorgänge, Revisionen, Sicherungen und Wiederherstellung bleiben auf ihrem Datenbank-Actor geordnet. Beim Beenden werden der unabhängige JSON-Katalog und die Bearbeitungsdatenbank gleichzeitig abgeschlossen; beide Ergebnisse müssen vorliegen. Backup-Zielauflösung läuft innerhalb des geschützten Backup-Ablaufs im Hintergrund.

Die Limits sind Arbeitsbudgets, keine harte Obergrenze für interne Threads von ImageIO/Core Image oder ihren Speicherbedarf. Eine laufende synchrone Betriebssystemoperation kann erst nach ihrer Rückkehr auf Abbruch reagieren.

## Prüfung

118 Tests bestanden, verteilt auf 97 Bibliotheks-/Persistenz-/Scheduling-/Cache-Tests und 21 tatsächliche Render-/Auto-Tonwert-Tests. Neue Fälle prüfen begrenzte Überlappung, deterministische Metadaten, Abbruch und Fehler beim Scannen, überholte Filteranfragen, schnelle Metadatenänderungen, angenommene Ordnerentfernung beim Beenden, Priorisierung und unabhängigen Abbruch geteilter Render-/Decodier-Anfragen sowie parallelen Abschluss beider Speicherbereiche.

```sh
PICEDIT_TEST_BUILD_PATH=/tmp/picedit-tests scripts/test.sh --jobs 4
scripts/test-image-pipeline.sh
scripts/benchmark-library.sh
scripts/benchmark-scanner.sh 120 5
scripts/benchmark-editing.sh
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

### Schnelle Regleränderungen

Eine synthetische Basis mit 2400 × 1600 Pixeln, 24 Änderungen im Abstand von 10 ms, vorhandene Zusammenfassung über 45 ms. Tatsächliche Core-Image-Filter: Auto-Tonwerte, Struktur, Klarheit, Farbrauschminderung und Belichtung.

| Zustand | Zeit ab letzter Änderung | Gesamte Folge | Neue Renderings |
|---|---:|---:|---:|
| Frischer Anwendungs-/Render-Cache | 2526 ms | 2814 ms | 1 |
| Wiederholung mit warmem Cache | 45,98 ms | 330,54 ms | 0 |

Der injizierte synthetische Decoder wurde insgesamt einmal aufgerufen; während der beiden Reglerfolgen gab es keine weiteren Aufrufe. Er liefert ein bereits erzeugtes Bitmap, misst also keine tatsächliche ImageIO-Decodierung. Kumulativer Spitzen-RSS des Prozesses: 87,3 MiB. Der erste Lauf enthält Renderer-Initialisierung. Es gibt hierfür keine Vorhermessung und damit keine Aussage über eine Beschleunigung gegenüber dem alten Renderer.

Für repräsentative große Kamera-RAWs waren in dieser Aufgabe keine Testdateien verfügbar. RAW-Durchsatz, RAW-Spitzenspeicher und ein expliziter CPU-/GPU-Leistungsvergleich sind daher nicht gemessen. Der bestehende RAW-Benchmark kann mit ausdrücklich angegebenen lokalen Dateien ergänzend ausgeführt werden; die Grafikpfade selbst wurden in dieser Änderung nicht ausgetauscht.
