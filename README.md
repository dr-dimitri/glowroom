# PicEdit

Eine native Fotobibliothek für macOS, entwickelt mit SwiftUI und AppKit. Die Anwendung unterstützt das Sichten, Organisieren und nicht destruktive Anpassen vorhandener Bilder: Ordner hinzufügen, Vorschauen durchsehen, einzelne Bilder groß anzeigen, Tonwerte und Präsenz anpassen, Rauschen mindern und Favoriten sowie Bewertungen verwalten. Die dunkle Oberfläche orientiert sich am Bibliotheksbereich professioneller Fotoanwendungen.

## Starten

Voraussetzungen: **macOS 14 oder neuer** und Xcode oder die Apple Command Line Tools mit Swift 5.9 oder neuer. Falls die Entwicklungswerkzeuge fehlen, lassen sie sich mit `xcode-select --install` installieren. PicEdit benötigt keine zusätzlichen Pakete und keinen Online-Dienst.

```sh
swift run PicEdit
```

Ein reguläres App-Bundle erzeugen und öffnen:

```sh
./scripts/build-app.sh
open dist/PicEdit.app
```

Für einen schnelleren Entwicklungsbuild kann `./scripts/build-app.sh --debug` verwendet werden. Das Skript baut für den aktuellen Mac, setzt das App-Icon und signiert das Bundle lokal, sofern `codesign` verfügbar ist. Diese lokale Signatur ersetzt keine Apple-Notarisierung für die Verteilung auf andere Macs.

Optional setzt `PICEDIT_BUILD_PATH` ein separates Build-Verzeichnis. Mit neueren Swift-Versionen kann `PICEDIT_BUILD_SYSTEM=swiftbuild` explizit Apples Swift-Build-System auswählen; ohne diese Variable gilt der Standard der installierten Swift-Version.

### Paralleler lokaler Build

Das Build-Skript nutzt ein automatisches CPU-Jobbudget: höchstens die aktiven CPU-Kerne und vorsichtig ein Worker je 2 GiB Arbeitsspeicher, mindestens ein Worker. Bei mehr als einem Worker wird einer für die **parallel zur App-Kompilierung laufende Icon-Erzeugung** reserviert; die übrigen werden über `swift build --jobs` vergeben. Beide Schritte verwenden getrennte, wiederverwendbare Modul-Caches. Das Budget begrenzt die geplanten Jobs, nicht exakt alle internen Threads oder den tatsächlichen Speicherverbrauch der Werkzeuge. SwiftPM selbst kompiliert bereits standardmäßig parallel; das Skript koordiniert zusätzlich die unabhängigen Build-Schritte. Die Swift-Kompilierung läuft auf der CPU.

Eine explizite Vorgabe überschreibt die automatische Begrenzung, beispielsweise:

```sh
PICEDIT_BUILD_JOBS=8 ./scripts/build-app.sh
PICEDIT_BUILD_JOBS=1 ./scripts/build-app.sh --debug
```

`1` führt Kompilierung und Icon-Erzeugung nacheinander aus. Erlaubt sind ganze Zahlen von 1 bis 1024; bei nicht verfügbarer Hardware-Erkennung verwendet das Skript einen Worker. Validierung, Signierung und Veröffentlichung warten auf beide Schritte. Schlägt ein Schritt fehl, bleibt das vorhandene App-Bundle erhalten; bei Abbruch werden die Worker samt Kindprozessen beendet.

Ein Lock unter `dist/.picedit-build.lock` verhindert konkurrierende Bundle-Builds im selben Checkout. Unabhängige Pakettests können mit einem getrennten Build-Verzeichnis gleichzeitig laufen. Nach einem nicht abfangbaren Prozessabbruch kann der Lock zurückbleiben: Die darin gespeicherte PID prüfen und den Lock erst entfernen, wenn der zugehörige Build nicht mehr läuft.

## Bibliothek verwenden

1. Mit **Ordner hinzufügen** oder **⌘O** einen Bilderordner auswählen.
2. Bilder in der Rasteransicht sichten und die Einzelansicht öffnen. Mit **⌘-Klick** einzelne Bilder zur Auswahl hinzufügen oder abwählen, mit **⇧-Klick** einen Bereich auswählen und mit **⌘⇧-Klick** einen Bereich hinzufügen. **⌘A** wählt alle sichtbaren Bilder; **⇧ + Pfeiltasten** erweitert die Auswahl. Die Statusleiste zeigt die Anzahl ausgewählter Bilder.
3. Bilder als Favoriten markieren oder mit einem bis fünf Sternen bewerten.

Unter **Ordner** lassen sich die eingebundenen Ordner über den Pfeil aufklappen. Die Baumansicht zeigt auch verschachtelte und leere Unterordner. Ein Klick auf einen Ordner zeigt seine Bilder einschließlich der darunterliegenden Ordner; die Zahl rechts gibt diese Gesamtanzahl an. Neue oder entfernte Unterordner werden beim Aktualisieren berücksichtigt.

Änderungen am Inhalt verknüpfter Ordner werden mit **Ordner aktualisieren** oder **⇧⌘R** erneut eingelesen. Neue Bilder erscheinen anschließend in der Bibliothek; Bewertungen und Favoriten vorhandener Bilder bleiben erhalten. Die erste Version überwacht Ordner nicht automatisch.

Die Bibliothek **verknüpft** vorhandene Dateien. Sie kopiert die Originale nicht und verändert sie nicht. Auch das Entfernen eines Ordners aus der Bibliothek löscht keine Bilder auf dem Datenträger. Verschobene, gelöschte oder vorübergehend nicht verfügbare Dateien können erst wieder geöffnet werden, wenn sie am verknüpften Speicherort verfügbar sind.

Bibliotheksdaten, Bewertungen und Favoriten werden lokal unter `~/Library/Application Support/PicEdit/catalog.json` gespeichert. Die Originalbilder bleiben in ihren bisherigen Ordnern.

Die Bildvorschau verwendet Apples ImageIO. Gängige Formate wie JPEG, PNG, TIFF und HEIC werden unterstützt, sofern das System sie lesen kann. RAW-Unterstützung hängt von der macOS-Version und dem jeweiligen Kameraformat ab; ein vorhandenes RAW-Dateiformat garantiert daher noch keine darstellbare Vorschau.

### Hintergrundarbeit und Parallelisierung

Metadaten werden mit höchstens vier, an CPU und Speicher angepassten Lesern eingelesen. Filter, Sortierung, Ordnerbäume und Importabgleich laufen im Hintergrund. Schnelle Auswahl- und Suchänderungen verwerfen überholte Ergebnisse; Bewertungen und Favoriten bleiben auch bei gleichzeitigem Import erhalten.

Decodierung, Cache-Zugriffe und Bearbeitungsrendering können sich überlappen. Ausgewählte Bilder werden bevorzugt; gleiche Anfragen teilen ihre Arbeit, größere laufende Decodierungen bedienen auch kleinere Vorschauen. Auf Rechnern mit mindestens vier aktiven CPU-Kernen und 8 GiB RAM können eine ausgewählte Bearbeitung und eine Hintergrundvorschau gleichzeitig rendern; sonst bleibt es bei einem Worker. Separate Core-Image-Kontexte geben dem ausgewählten Bild Vorrang. Datenbanktransaktionen und Backups bleiben geordnet; beim Beenden werden Katalog und Bearbeitungsdatenbank gemeinsam abgewartet.

[Zuständigkeiten, Grenzen, Testergebnisse und reproduzierbare Benchmarks](docs/PARALLELISM.md) dokumentieren die Umsetzung. Details zur GPU-Nutzung, wiederverwendeten Filterstufen und Messungen der nicht destruktiven Bearbeitung stehen im [Bearbeitungs-Performancebericht](docs/EDITING-PERFORMANCE.md). Die gemessene Beschleunigung beim Metadatenimport gilt für synthetische JPEG-Testdaten; große Kamera-RAWs wurden nicht vermessen.

### RAW-Vorschauen und Performance

Für RAW-Dateien verwendet PicEdit eine eingebettete Kameravorschau, wenn deren Auflösung ausreicht. Andernfalls erzeugt ImageIO die Vorschau aus dem Original. Die Einzelbildansicht lädt zuerst eine kleine Vorschau und verfeinert sie anschließend bis zur bisherigen Zielgröße von 2400 Pixeln. Kamera-Vorschauen können sich in Farbe und Tonwerten von einer späteren RAW-Entwicklung unterscheiden.

Raster und Filmstreifen teilen sich einen begrenzten Arbeitsspeicher-Cache. Zusätzlich werden Vorschauen unter `~/Library/Caches/PicEdit/Previews-v2` gespeichert, damit sie nach einem Neustart wieder verfügbar sind. Der Festplatten-Cache ist auf 512 MiB begrenzt und entfernt ältere Vorschauen automatisch. Pfad, Änderungszeit, Dateigröße und Vorschauauflösung bestimmen die Gültigkeit; nach Änderungen am Original den Ordner aktualisieren. Auch größere bereits vorhandene Vorschauen werden wiederverwendet.

Das ausgewählte Bild erhält Vorrang vor wartenden Rasterbildern. Höchstens drei Lade- und Speichervorgänge laufen parallel; bei der Standardeinstellung bleibt ein Platz für das ausgewählte Bild frei. Nicht mehr benötigte Anfragen werden abgebrochen. Filter, Sortierung und Ordnerbäume werden zwischen unveränderten Bibliotheksansichten wiederverwendet.

| Tastenkürzel | Funktion |
| --- | --- |
| ⌘O | Ordner hinzufügen |
| ⇧⌘R | Ordner aktualisieren |
| ⇧⌘E | Ausgewählte Fotos als JPEG exportieren |
| ⌘A | Alle sichtbaren Fotos auswählen |
| ⇧ + Pfeiltasten | Auswahlbereich erweitern |
| Pfeiltasten | Bildauswahl bewegen |
| Leertaste | Zwischen Raster und Einzelansicht wechseln |
| 1–5 | Sterne vergeben |
| 0 | Bewertung entfernen |
| F | Favorit umschalten |

## Entwickeln und prüfen

Die [KI-Verträge und sicheren Vorschläge](docs/AI-CONTRACTS.md) definieren providerunabhängige Antworten, strenge Reglerprüfung, versionsgebundene Vorschläge und begrenzte Hintergrundaufträge. Der optionale [lokale Entwicklungsassistent](docs/LOCAL-AI-ASSISTANT.md) übersetzt Text in vorhandene Reglerwerte. Er benötigt einen Build mit FoundationModels-Unterstützung sowie macOS 26 und ein bereitgestelltes Apple-Intelligence-Systemmodell. Die übrige App bleibt ab macOS 14 ohne Online-Dienst, Modellinstallation oder Zugangsdaten nutzbar.

Vor jeder neuen beauftragten Änderung zuerst den Git-Status prüfen, den Remote-Stand abrufen und den lokalen `main` mit `git pull --ff-only` aktualisieren. Anschließend einen Aufgabenbranch von diesem Stand anlegen. Fremde oder noch benötigte Änderungen beim Branchwechsel erhalten; bei blockierter Aktualisierung keine Umsetzung auf veraltetem `main` beginnen und das Hindernis melden.

Nach jeder Umsetzungsanforderung sind die betroffene Dokumentation zu aktualisieren, geeignete Tests auszuführen und ein sauberer, vollständiger lokaler App-Build erfolgreich abzuschließen. Nach jeder umgesetzten Änderung ist außerdem ein erfolgreiches Review und anschließend der Merge nach `main` verpflichtend, sofern der Nutzer nichts anderes vorgibt. Der Abschluss erfolgt in dieser Reihenfolge:

1. Änderungen und Dokumentation fertigstellen. Den finalen Diff einschließlich betroffener Schnittstellen, Tests und Dokumentation reviewen, zur Umsetzung gehörende Befunde beheben und die Korrekturen erneut prüfen. Die passenden Tests ausführen.
2. Vor dem Bereinigen sicherstellen, dass keine Builds oder Tests mehr auf die betroffenen Verzeichnisse zugreifen. Einen vorhandenen Build-Lock wie oben beschrieben prüfen; laufende Prozesse und deren Ergebnisse nicht löschen.
3. Alte generierte Build-Ergebnisse entfernen und das vollständige App-Bundle neu bauen. Für die Standardverzeichnisse im Repository-Stamm:

   ```sh
   rm -rf -- .build .build-app dist/PicEdit.app
   ./scripts/build-app.sh
   ```

   Das Build-Skript bereinigt vorherige Ergebnisse nicht automatisch. Bei `PICEDIT_BUILD_PATH`, `PICEDIT_TEST_BUILD_PATH` oder anderen benutzerdefinierten Build-Verzeichnissen die tatsächlich verwendeten Pfade vorab prüfen und deren alte generierte Ergebnisse ebenfalls gezielt entfernen. Relative `PICEDIT_BUILD_PATH`-Angaben beziehen sich auf den Repository-Stamm. Nur bestätigte Build-Artefakte löschen; Quelldateien und persönliche Daten bleiben erhalten. Bereinigung und anschließender Build laufen wegen ihrer Abhängigkeit nacheinander; das Build-Skript parallelisiert seine unabhängigen Arbeitsschritte selbst.
4. Nach erfolgreichem Review und erfolgreicher Prüfung den Diff kontrollieren, ausschließlich die zur Aufgabe gehörenden Änderungen aussagekräftig committen und auf den zugehörigen Remote-Branch pushen, anschließend den Git-Status prüfen.
5. Den zugehörigen Pull Request gegen `main` erstellen oder aktualisieren, erforderliche Reviews und Statusprüfungen erfüllen und die geprüfte Änderung mergen. Branch-Schutzregeln nicht umgehen. Wird der geprüfte Stand nachträglich verändert, die betroffenen Änderungen vor dem Merge erneut reviewen und prüfen. Einen blockierten Merge mit konkreter Ursache melden und den geprüften Branch bewahren.
6. Nach bestätigtem Merge kann der alte Aufgabenbranch lokal und auf dem Remote gelöscht werden, sofern keine ungesicherten oder noch benötigten Änderungen verloren gehen. Anschließend `main` mit `git pull --ff-only` aktualisieren und den Git-Status prüfen. `main` niemals löschen und keine unsichere Branch-Löschung erzwingen. Im Abschlussbericht Commit, Aufgabenbranch, Pull Request und Merge-Status, gegebenenfalls Branch-Löschung sowie Review- und Build-/Testergebnis nennen; verbleibende Hindernisse ausdrücklich dokumentieren.

Während der Umsetzung oder beim Review gefundene Bugs ohne Zusammenhang mit der aktuellen Umsetzung werden jeweils als eigenes Issue im Issue-Tracker des Repositorys erfasst und nicht im aktuellen Änderungsumfang behoben. Vorher nach bestehenden Issues suchen und bei einem bereits erfassten Bug das vorhandene Issue verlinken. Das Issue enthält Reproduktionsschritte, erwartetes und tatsächliches Verhalten sowie die betroffenen Stellen; im Abschlussbericht wird darauf verwiesen. Fehlt der Zugriff auf den Issue-Tracker, das Hindernis melden und den vollständigen Issue-Entwurf aufbewahren. Die verbindlichen Projektvorgaben stehen in [AGENTS.md](AGENTS.md).

Die automatisierten Tests verwenden Swift Testing und benötigen **Swift 6 oder neuer**. Das Testskript setzt lokale Compiler-Caches und berücksichtigt die Plugin-Erkennung der Apple Command Line Tools:

```sh
./scripts/test.sh
swift build
./scripts/test-image-pipeline.sh
./scripts/test-build-app.sh
```

Mit einer vollständigen, normal eingerichteten Xcode-Installation ist alternativ `swift test` möglich. Optional setzt `PICEDIT_TEST_BUILD_PATH` ein separates Build-Verzeichnis für die Pakettests.

Die Tests prüfen unter anderem Vorschau-Priorisierung und Abbruch, persistente Cache-Gültigkeit und Größenlimits, Transparenz und Farbprofile, Bibliotheks-Cache-Invalidierung sowie rekursiven Import, überlappende Ordner, Aktualisierung, Bewertungen, Favoriten, gespeicherte Kataloge und den Umgang mit beschädigten Dateien. Sie verwenden eigene temporäre Testordner und verändern weder persönliche Originalbilder noch den regulären PicEdit-Katalog. Der separate Vorschautest prüft EXIF-Orientierung, Größenbegrenzung, Cache-Verhalten, Abbruch sowie defekte und fehlende Dateien anhand synthetischer Testbilder.

`test-build-app.sh` prüft mit isolierten Testwerkzeugen die parallele Build-Steuerung, Jobbudgets, getrennte Caches, Abbruch samt Kindprozessen, den Build-Lock und den Erhalt der bisherigen App bei Compiler-, Icon-, Signatur- und Veröffentlichungsfehlern. Dieser Shell-Test benötigt keine Swift-Kompilierung und verändert das echte App-Bundle nicht.

Eine kleine, rein synthetische Beispielsammlung kann ohne zusätzliche Abhängigkeiten erzeugt werden. Das Zielverzeichnis muss ausdrücklich angegeben werden; bestehende Dateien werden nicht überschrieben:

```sh
swift scripts/make-demo-library.swift /tmp/PicEdit-Demo
```

Anschließend `/tmp/PicEdit-Demo` in PicEdit hinzufügen. Die Beispielbilder sind programmatisch gezeichnet und enthalten keine persönlichen Fotos.

Für einen vollständig getrennten Testkatalog lässt sich ein anderes Datenverzeichnis übergeben:

```sh
swift run PicEdit --catalog-directory /tmp/PicEdit-Testkatalog
```

Die Bibliotheksberechnungen lassen sich unabhängig vom RAW-Decoder mit 10.000 synthetischen Einträgen messen:

```sh
./scripts/benchmark-library.sh
```

Das Skript verwendet einen eigenen temporären Katalog; seine Zeiten messen Filterung, Sortierung und Ordnerbäume, nicht das Laden von Bildern.

Für einen Vergleich der ImageIO-Ladewege mit ausdrücklich angegebenen, lokal verfügbaren RAW-Dateien:

```sh
xcrun swiftc -O -parse-as-library scripts/benchmark-raw-previews.swift -o /tmp/picedit-raw-benchmark
/tmp/picedit-raw-benchmark --iterations 3 --sizes 512,2400 /Pfad/zum/Bild.CR3
```

Das Werkzeug misst erzwungene Neuerzeugung, eingebettete Vorschau und ImageIO-Fallback separat. Auflösung und erfolgreiche Decodierung müssen beim Vergleich berücksichtigt werden. Cloud-Platzhalter und unlesbare Dateien werden übersprungen; Zugriff durch die App bedeutet nicht automatisch Zugriff für ein Terminal-Werkzeug. Die tatsächliche Beschleunigung hängt vom Kameraformat, der eingebetteten Vorschau und dem Cache-Zustand ab.

## Entwickeln: Tonwert, Präsenz und Entrauschen

Wähle ein Foto und öffne **Entwickeln** (oder **⌘D**). Die Regler arbeiten nicht destruktiv; Originaldateien werden weder überschrieben noch verschoben.

| Bereich | Regler |
| --- | --- |
| Tonwert | Belichtung (−5 bis +5 EV), Kontrast, Lichter, Tiefen, Weiß, Schwarz |
| Präsenz | Struktur, Klarheit, Dunst entfernen, Dynamik, Sättigung |
| Entrauschen | Luminanz und Farbe, jeweils 0–100 |

**Tonwert-Automatik** gleicht sehr helle und dunkle Bildbereiche anhand der Helligkeitsverteilung des jeweiligen Fotos aus. Aktiviere den Schalter oberhalb der Tonwertregler und passe die **Stärke** bei Bedarf an. Die Korrektur erhält Schwarz und Weiß und vermeidet Tonwertumkehrungen; bereits ausgewogene Bilder werden zurückhaltender verändert. Aus vollständig weißen oder schwarzen Flächen kann sie keine verlorenen Details rekonstruieren.

Die Automatik wirkt vor den manuellen Reglern. Vorhandene Einstellungen bleiben erhalten und lassen sich weiter verfeinern; starke manuelle Korrekturen können weiterhin zu Über- oder Unterbelichtung führen. Schalter und Stärke werden pro Foto gespeichert, in Backups aufgenommen und von Vorher-Vergleich, Rückgängig/Wiederholen und vollständigem Zurücksetzen berücksichtigt. Bestehende Bearbeitungen und ältere Backups öffnen sich mit ausgeschalteter Automatik.

Die Werte lassen sich über Schieberegler oder Zahlenfelder ändern. **Vorher anzeigen** vergleicht mit derselben Bildbasis ohne Anpassungen. Eine Reglerbewegung oder abgeschlossene Zahleneingabe bildet einen Rückgängig-Schritt; die Pfeile unten wiederholen oder widerrufen Änderungen pro Foto. Die Kreis-Pfeile setzen einzelne Bereiche zurück, **Zurücksetzen** alle Regler. Ein Doppelklick auf eine Reglerbeschriftung setzt diesen Wert auf null. Rückgängig-Verläufe gelten für die laufende Sitzung; die aktuellen Werte bleiben nach einem Neustart erhalten.

Raster, Filmstreifen und Einzelansicht zeigen die gespeicherten Bearbeitungen. Die RAW-Basis im Entwickeln-Modul wird aus dem Original erzeugt, ohne eine eingebettete Kamera-Vorschau als Bearbeitungsbasis zu verwenden. Bearbeitungsbasen werden verlustfrei zwischengespeichert. Reglerbewegungen verwenden diese Basis erneut; veraltete Renderaufträge können neuere Ergebnisse nicht überschreiben. Core Image führt die Bildfilter auf seinem verfügbaren Backend aus (auf dem geprüften Apple-Silicon-Mac über Metal). Unveränderte Entrauschungs- und Auto-Tonwert-Stufen des ausgewählten Bildes sowie die kleine CPU-Tonwertanalyse werden wiederverwendet. Originaldateien und gespeicherte Bearbeitungsparameter bleiben davon unberührt.

Die Filter verwenden Core Image und eigene Tonwert-/Kontrastberechnungen. Ihre Bedienung orientiert sich an Lightroom Classic, die Ergebnisse sind nicht identisch mit Adobes Entwicklungsengine. Entrauschen ist eine klassische, getrennte Luminanz-/Farbrauschminderung, keine KI-Funktion. Bearbeitet wird derzeit die Vorschau mit bis zu 2400 Pixeln langer Kante; vollständige RAW-Entwicklung mit Belichtungsreserve aus Sensordaten, Weißabgleich, Zuschnitt und Masken sind noch nicht enthalten. Der JPEG-Export verwendet dagegen das Original in voller Auflösung und wendet dieselben Bearbeitungsfilter an.

### Lokaler Entwicklungsassistent

Im Entwickeln-Inspector eine deutsche Anweisung wie „Helle die Schatten auf“ eingeben und **Vorschlag erstellen** wählen. Der Assistent übersetzt Text in Reglerwerte; er analysiert das Foto nicht. Weißabgleich, Motivbeschreibung, Retusche und neue Bildpixel gehören nicht zu seinen Fähigkeiten. Bei fehlender Unterstützung nennt die Oberfläche den Verfügbarkeitsgrund; die manuellen Regler bleiben nutzbar.

Ein Vorschlag zeigt Ausgangs- und Zielwerte samt Delta sowie eine **KI-Vorschau · noch nicht übernommen**. Zwischen aktueller Bearbeitung und Vorschlag wechseln; **Vorher anzeigen** vergleicht weiterhin mit dem Original ohne Regler. **Verwerfen** oder **Abbrechen** ändern keine Bearbeitung. Erst **Übernehmen** setzt alle vorgeschlagenen Werte gemeinsam und erzeugt einen Rückgängig-Schritt. Bildwechsel, manuelle Änderungen, Undo/Redo, Zurücksetzen, Backup/Restore und Schließen entwerten wartende und angezeigte Vorschläge.

Raster, Filmstreifen, Speicherstatus und JPEG-Export verwenden die übernommenen Werte. Ein Export während der KI-Vorschau enthält deshalb die aktuelle Bearbeitung vor dem Vorschlag. Der Provider erhält ausschließlich Anweisung und Reglerwerte, keine Bildpixel, Namen, Pfade oder EXIF-Daten. PicEdit startet keinen Modelldownload und verwendet keinen Cloudfallback. Prompts und Antworten werden nicht protokolliert oder dauerhaft gespeichert. Einrichtung, Buildmatrix und ausdrücklich aktivierbare Modelltests stehen in der [Assistentendokumentation](docs/LOCAL-AI-ASSISTANT.md).

## JPEG-Export

Wähle ein oder mehrere Fotos und klicke oben auf **Exportieren**, nutze **Ablage → Foto als JPEG exportieren …** beziehungsweise **Ausgewählte Fotos als JPEG exportieren …** oder **⇧⌘E**. Der Export steht auch im Kontextmenü der Bilder im Raster, Filmstreifen und in der Einzelansicht. Gehört das angeklickte Bild zur Auswahl, werden alle ausgewählten Bilder exportiert; andernfalls wird dieses Bild ausgewählt und exportiert. Der Dialog gliedert die Optionen wie in Lightroom in Speicherort, Dateieinstellungen und Bildgröße.

- **Speicherort:** Zielordner frei wählen; beim Einzelexport auch den Dateinamen. Vorgeschlagen wird `Originalname-bearbeitet.jpg`. Bei mehreren Bildern wird dieser Name pro Original automatisch vergeben; gleiche Namen erhalten einen eindeutigen Zahlenzusatz. Vorhandene Exportdateien werden nur nach Bestätigung ersetzt; importierte Originalbilder sind als Ziel gesperrt.
- **Dateieinstellungen:** JPEG mit **sRGB** oder **Display P3**. Die Pixel werden in den gewählten Farbraum umgerechnet; sRGB wird per EXIF gekennzeichnet, Display P3 mit einem eingebetteten ICC-Profil. **Qualität 0–100** steuert die Kompression: höhere Werte erhalten mehr Details und erzeugen meist größere Dateien.
- **Bildgröße:** Originalgröße, maximale lange Kante oder Einpassen in Breite und Höhe, jeweils in Pixeln. Das Seitenverhältnis bleibt erhalten; es wird weder beschnitten noch verzerrt. Vergrößern ist standardmäßig ausgeschaltet und kann ausdrücklich erlaubt werden.
- **Auflösung:** 1–1200 Pixel pro Zoll (ppi) als Druckauflösung. Dieser Wert ändert die Druckgrößenangabe, nicht die Pixelzahl.

Exportiert wird der beim Öffnen des Dialogs erfasste Bearbeitungsstand, auch wenn gerade „Vorher anzeigen“ aktiv war. Der Export decodiert das Original und verwendet keine eingebettete RAW-Kameravorschau oder bereits verkleinerte Bildschirmvorschau. RAW-Unterstützung hängt weiterhin von ImageIO/macOS und dem Kameraformat ab. JPEG unterstützt keine Transparenz; transparente Bereiche werden weiß hinterlegt.

Der Export läuft im Hintergrund und kann abgebrochen werden. Mehrere Bilder verwenden dieselben Optionen und werden in der sichtbaren Reihenfolge nacheinander verarbeitet; der Dialog zeigt den Fortschritt. Bereits erfolgreich exportierte Dateien bleiben bei einem Abbruch erhalten. Erst eine fertig geschriebene Datei wird atomar am Ziel veröffentlicht. Große Exporte sind auf einen Auftrag gleichzeitig begrenzt und unterliegen einer Speicherprüfung; bei zu großen Bildern erscheint ein Fehler statt einer stillen Auflösungsreduktion. Die App wartet beim Beenden auf den Abschluss oder Abbruch eines laufenden Exports. Einstellungen und zuletzt gewählter Ordner werden für den nächsten Export gemerkt. Nach Abschluss lassen sich die Dateien im Finder anzeigen.

## Datenbank und Backups

Die Reglerwerte stehen pro Foto in **`~/Library/Application Support/PicEdit/edits.sqlite`**. SQLite verwendet WAL, `synchronous=FULL`, Transaktionen und fortlaufende Versionen pro Bild. Mehrere schnelle Änderungen werden nach einer kurzen Eingabepause zusammengefasst. Beim Beenden wird auf ausstehende Speichervorgänge gewartet. Konflikte oder Schreibfehler werden angezeigt; ungespeicherte Werte bleiben im Speicher und können über **Entwickeln → Änderungen erneut speichern** erneut geschrieben werden.

Der vorhandene Bibliothekskatalog mit Ordnern, Metadaten, Bewertungen und Favoriten bleibt in `catalog.json`. Beide Dateien liegen bei `--catalog-directory` im angegebenen Test-/Datenverzeichnis.

- **Automatisch:** Nach dem ersten erfolgreichen Speichern an einem Tag entsteht ein geprüftes Backup unter `EditBackups` im Datenverzeichnis. Die letzten sieben automatischen Sicherungen bleiben erhalten.
- **Manuell:** Über das Backup-Symbol oben rechts oder **Entwickeln → Bearbeitungen sichern …** einen Zielort auswählen, beispielsweise ein externes Laufwerk. Manuelle Sicherungen werden nicht automatisch gelöscht.
- **Wiederherstellen:** **Backup wiederherstellen …** öffnet eine Sicherungsdatei. Vor der Übernahme werden Integrität, Schema und Werte geprüft und der bisherige Zustand separat gesichert. Ungültige Dateien verändern die vorhandenen Bearbeitungen nicht.
- **Beschädigte Datenbank:** Ein gültiges Backup kann auch bei nicht mehr startfähiger Bearbeitungsdatenbank wiederhergestellt werden. Die beschädigte Datenbank und ihre Begleitdateien bleiben im Unterordner `Recovery` erhalten.

**Diese Backups enthalten ausschließlich die Bearbeitungswerte. Originalbilder, `catalog.json` und der entbehrliche Vorschau-Cache sind nicht enthalten.** Fotoordner und Katalog separat sichern, etwa mit der vorhandenen Mac-Sicherung. Eine lokale Sicherung auf demselben Datenträger schützt nicht vor dessen Ausfall; hierfür die manuelle Sicherung auf ein anderes Laufwerk speichern.

Die Sicherung verwendet die [SQLite Online Backup API](https://sqlite.org/backup.html), damit auch noch im WAL stehende Änderungen in einer eigenständig lesbaren Datei enthalten sind. Eine laufende Datenbank wird nicht einfach mit ihren WAL-Dateien kopiert.

Die Renderer-Tests prüfen mit synthetischen Bildern Richtung und Wirkung der Regler, Rauschvarianz, Tonwertverläufe, Transparenz und Farbprofile. Datenbank-/Controller-Tests decken unter anderem Neustart, Schreibkonflikte, schnelle Bildwechsel, gleichzeitige Speicherversuche, fehlgeschlagene Writes, Backup-Rotation, beschädigte Sicherungen und Wiederherstellung ab. Core Image benötigt für diese Tests eine normale macOS-Sitzung; eine restriktive Ausführungssandbox kann den Renderer blockieren.
