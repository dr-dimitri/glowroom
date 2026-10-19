# PicEdit

Eine native Fotobibliothek für macOS, entwickelt mit SwiftUI und AppKit. Die Anwendung unterstützt das Sichten, Organisieren und nicht destruktive Anpassen vorhandener Bilder: Ordner hinzufügen, Vorschauen durchsehen, einzelne Bilder groß anzeigen, Tonwerte und Präsenz anpassen, Rauschen mindern und Favoriten sowie Bewertungen verwalten. Die dunkle Oberfläche orientiert sich am Bibliotheksbereich professioneller Fotoanwendungen.

Der **Bildfokus aus Vorschlag B** der [Entwürfe zu Issue #45](docs/design/issue-45/README.md) bietet mehr Bildfläche und Werkzeuge nach Bedarf. Die historischen Mockups dokumentieren den Entwurf; die implementierten Bedienwege und Zustandsregeln stehen unter [Bildfokus und Arbeitsbereiche](docs/WORKSPACE-LAYOUT.md).

## Starten

Voraussetzungen: **macOS 14 oder neuer** und Xcode oder die Apple Command Line Tools mit **Swift 6.1 oder neuer**. Falls die Entwicklungswerkzeuge fehlen, lassen sie sich mit `xcode-select --install` installieren. SwiftPM löst die in `Package.resolved` festgehaltenen Swift-Bibliotheken auf; dafür ist beim ersten Build Internetzugang oder ein bereits gefüllter lokaler Paketcache nötig. Die laufende App benötigt für Bibliothek und lokale Bearbeitung keinen Online-Dienst.

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

### Bildfokus und Werkzeuge

Wähle ein Foto und klicke oben auf **Bildfokus**, verwende **Darstellung → Bildfokus** oder **⇧⌘F**. Der Modus funktioniert im normalen Fenster und unabhängig vom macOS-Vollbild. Navigation, Filmstreifen und Werkzeugseite sind zunächst verborgen. Das beschriftete Dock öffnet **Bearbeiten** rechts sowie **Assistent & Looks**, **Analyse**, **Informationen** und **Bildstände** links. Sobald eine Spalte sichtbar ist, stehen ihre Gruppen direkt dort zur Verfügung und ihre zusätzlichen Dockknöpfe entfallen. **Zur vorherigen Ansicht** bzw. erneut **⇧⌘F** stellt die bisherige Raster-/Einzelbildansicht und deren Panelzustand wieder her. **Esc** verlässt den Fokus; **Leertaste** bzw. **Rasteransicht** wechselt geordnet ins Raster.

Über **Ansicht** im Fenster oder das Menü **Darstellung** lassen sich Bibliothek beziehungsweise Entwickeln-Navigation (**⌥⌘L**), Werkzeuge (**⌘I**) und Filmstreifen (**⌥⌘S**) unabhängig schalten. Zwischen Bibliothek und Bild bzw. Bild und Werkzeugen ziehen die Griffe die Breite auf; der Griff oberhalb des Filmstreifens verändert dessen Höhe. Die Darstellungspräferenzen werden automatisch gemerkt, getrennt für Bibliothek, Entwickeln und Bildfokus. Beim Verkleinern begrenzt die App die wirksamen Größen; die bevorzugten Größen bleiben für größere Fenster erhalten. **Standardansicht wiederherstellen** setzt die aktuelle Darstellung zurück.

Die Entwickeln-Ansicht zeigt links den **Navigator**, darunter **Assistent & Looks**, **Bildanalyse**, **Bildinformationen** und **Bildstände**. Rechts stehen Histogramm, Werkzeugleiste und Korrekturen mit den Tonwerten zuerst. Dunkle neutrale Seitenleisten, eine graue Bildfläche und helle Schrift orientieren sich an klassischen Fotoarbeitsplätzen. Gruppen und Regler-Untergruppen lassen sich einklappen. **Nur eine Gruppe geöffnet** im Kontextmenü einer Gruppenüberschrift gilt pro Spalte; eine linke Gruppe schließt die rechten Grundeinstellungen nicht. Direkte Sprünge über **Darstellung** oder das Fokusdock öffnen die zuständige Spalte. Einklappen und Fokuswechsel erhalten Anweisungen, Vorschläge, laufende Anfragen und Metadatenentwürfe. Sie übernehmen keine Werte und erzeugen keine Undo-Einträge. Ein echter Bild-/Quellenwechsel oder eine geänderte Bearbeitung kann Vorschläge weiterhin ungültig machen.

Navigation, Sterne, Favorit, Zoom und **Vergleich** bleiben beim Bild erreichbar. Das einzige Menü **Vergleich** unterscheidet importiertes Original, aktuelle Quelle ohne Regler und aktuelle Bearbeitung. **Maskieren** startet in der rechten Werkzeugleiste. Rückgängig/Wiederholen stehen unten links, vollständiges Zurücksetzen unten rechts; der Speicherstatus erscheint einmal global. Die Hinweise in der Statusleiste öffnen auch bei verborgenen Werkzeugen laufende Aufgaben, KI-Ergebnisse und Fehler; Speicherfehler bieten einen Weg zur Prüfung bzw. Wiederholung. **Sicherungen** und **Exportieren** stehen weiterhin oben. Ein Klick auf eine Lookkarte aktiviert, speichert und exportiert die gewählte Variante direkt.

1. Mit **Ordner hinzufügen** oder **⌘O** einen Bilderordner auswählen.
2. Bilder in der Rasteransicht sichten und die Einzelansicht öffnen. Mit **⌘-Klick** einzelne Bilder zur Auswahl hinzufügen oder abwählen, mit **⇧-Klick** einen Bereich auswählen und mit **⌘⇧-Klick** einen Bereich hinzufügen. **⌘A** wählt alle sichtbaren Bilder; **⇧ + Pfeiltasten** erweitert die Auswahl. Die Statusleiste zeigt die Anzahl ausgewählter Bilder.
3. Bilder als Favoriten markieren oder mit einem bis fünf Sternen bewerten.

Unter **Ordner** lassen sich die eingebundenen Ordner über den Pfeil aufklappen. Die Baumansicht zeigt auch verschachtelte und leere Unterordner. Ein Klick auf einen Ordner zeigt seine Bilder einschließlich der darunterliegenden Ordner; die Zahl rechts gibt diese Gesamtanzahl an. Neue oder entfernte Unterordner werden beim Aktualisieren berücksichtigt.

Ordnerzählung, Unterordnerfilter und Ordnerzuständigkeit vergleichen geladene Datei-URLs in derselben normalisierten Darstellung. Gleichwertige `/tmp`-/`/private/tmp`-Pfade bleiben damit auch nach einem Katalogneustart sichtbar. Auch fehlende Dateien und Unterordner sowie vorübergehend unlesbare Bilder behalten ihre Ordnerzuordnung; die Pfadauflösung läuft im Hintergrund. Gespeicherte Asset-IDs, Datei-URLs und Bearbeitungszuordnungen werden durch diesen Vergleich nicht umgeschrieben.

Änderungen am Inhalt verknüpfter Ordner werden mit **Ordner aktualisieren** oder **⇧⌘R** erneut eingelesen. Neue Bilder erscheinen anschließend in der Bibliothek; Bewertungen und Favoriten vorhandener Bilder bleiben erhalten. Die erste Version überwacht Ordner nicht automatisch.

Die Bibliothek **verknüpft** vorhandene Dateien. Sie kopiert die Originale nicht und verändert sie nicht. Auch das Entfernen eines Ordners aus der Bibliothek löscht keine Bilder auf dem Datenträger. Für Bilder, die dadurch vollständig aus dem Katalog verschwinden, entfernt PicEdit auch Bearbeitungen, Revisionen, Varianten, Bildinformationen samt Entwürfen und Suchindexeinträge aus den aktiven Datenbanken. Erneutes Hinzufügen desselben Ordners scannt die Dateien neu und beginnt ohne frühere Bewertungen, Favoriten oder Bearbeitungen. In anderen eingebundenen Ordnern verbliebene Bilder behalten ihre Daten. Verschobene, gelöschte oder vorübergehend nicht verfügbare Originale gelten allein dadurch nicht als aus dem Katalog entfernt.

Bibliotheksdaten, Bewertungen und Favoriten werden lokal unter `~/Library/Application Support/PicEdit/catalog.json` gespeichert. Die Originalbilder bleiben in ihren bisherigen Ordnern.

Die Bildvorschau verwendet Apples ImageIO. Gängige Formate wie JPEG, PNG, TIFF und HEIC werden unterstützt, sofern das System sie lesen kann. RAW-Unterstützung hängt von der macOS-Version und dem jeweiligen Kameraformat ab; ein vorhandenes RAW-Dateiformat garantiert daher noch keine darstellbare Vorschau.

### Hintergrundarbeit und Parallelisierung

Metadaten werden mit höchstens vier, an CPU und Speicher angepassten Lesern eingelesen. Filter, Sortierung, Ordnerbäume und Importabgleich laufen im Hintergrund. Schnelle Auswahl- und Suchänderungen verwerfen überholte Ergebnisse; Bewertungen und Favoriten bleiben auch bei gleichzeitigem Import erhalten.

Decodierung, Cache-Zugriffe und Bearbeitungsrendering können sich überlappen. Ausgewählte Bilder werden bevorzugt; gleiche Anfragen teilen ihre Arbeit, größere laufende Decodierungen bedienen auch kleinere Vorschauen. Auf Rechnern mit mindestens vier aktiven CPU-Kernen und 8 GiB RAM können eine ausgewählte Bearbeitung und eine Hintergrundvorschau gleichzeitig rendern; sonst bleibt es bei einem Worker. Separate Core-Image-Kontexte geben dem ausgewählten Bild Vorrang. Datenbanktransaktionen und Backups bleiben geordnet; beim Beenden werden Katalog, Bearbeitungsdatenbank und angenommene Bildinformationen-Speichervorgänge gemeinsam abgewartet.

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

### Lokale semantische Bildsuche

**Wörtlich** bleibt der Suchstandard und benötigt kein Modell. **Semantisch** sucht nach deutschen oder englischen Bildbeschreibungen in echten lokalen Bild-/Text-Embeddings, etwa „rotes Haus“. Ordner, Favoriten, Zeitraum, Mindestbewertung und das getrennte optionale wörtliche Filterfeld gelten gemeinsam vor der Relevanzsuche. Eine leere Bildsuche zeigt die normale Bibliothek. Standard sind höchstens 100 Treffer, einstellbar bis 500; bei gleichen Scores gilt die gewählte Sortierung. Scores sind keine Wahrscheinlichkeiten.

Unter **Lokales Suchmodell und Suchindex → Verwalten** ein geprüftes lokales Modellpaket auswählen und Quelle, Größe, Lizenz und temporären Platzbedarf vor dem Import prüfen. Es gibt keinen automatischen Download und keine eingebauten Modellgewichte. Das reproduzierbare Entwicklerwerkzeug und die festgelegte SigLIP2-Revision sind in [SEMANTIC-SEARCH.md](docs/SEMANTIC-SEARCH.md) beschrieben. Die App akzeptiert ausschließlich das dort gepinnte Paket und arbeitet danach ohne Netz. Aktiv installierte Modelldateien benötigen höchstens 1 GiB; Import und lokale Kompilierung benötigen zusätzlichen temporären Speicher. Die erste Produktversion nutzt den gemessenen CPU-Pfad.

Danach den **Indexumfang** ausdrücklich wählen und **Suchindex vorbereiten** starten. Es gibt keinen vollständigen Bildscan beim Appstart. Fortschritt und gültige, fehlende beziehungsweise veraltete Einträge bleiben sichtbar. **Abbrechen** erhält abgeschlossene Einträge; **Index fortsetzen** arbeitet daran weiter. **Neu aufbauen** erhält die letzte gültige Modellgeneration bis zur erfolgreichen Aktivierung. Indexeinträge und Modell lassen sich getrennt entfernen. Unbekannte oder beschädigte Indexdateien werden vor einem bewussten Neuaufbau gemeldet und konservativ aufbewahrt. Originalbilder, bestätigte Bearbeitungen und die wörtliche Suche bleiben unabhängig nutzbar.

## Entwickeln und prüfen

Die [KI-Verträge und sicheren Vorschläge](docs/AI-CONTRACTS.md) definieren providerunabhängige Antworten, strenge Reglerprüfung, versionsgebundene Vorschläge und begrenzte Hintergrundaufträge. Der optionale [lokale Entwicklungsassistent](docs/LOCAL-AI-ASSISTANT.md) übersetzt Text in vorhandene Reglerwerte. Er benötigt einen Build mit FoundationModels-Unterstützung sowie macOS 26 und ein bereitgestelltes Apple-Intelligence-Systemmodell. Die übrige App bleibt ab macOS 14 ohne Online-Dienst, Modellinstallation oder Zugangsdaten nutzbar.

Der [optionale Anthropic-Cloudprovider](docs/ai/CLOUD-PROVIDER.md) ist ab Werk aus. In **PicEdit → Einstellungen → KI-Anbieter** ausdrücklich Cloud aktivieren, eigenen API-Schlüssel im macOS-Keychain speichern und Anthropic auswählen. Für einen Schlüssel mit Zugriff auf mehrere Workspaces zusätzlich die Ziel-Workspace-ID speichern. Der lokale ad-hoc App-Build verwendet den macOS-Standardschlüsselbund mit App-Zugriffsschutz. Jeder Textauftrag verlangt eine eigene Freigabe; es gibt keinen automatischen Cloudfallback. Bilder und Cloud-Looks sind hier nicht verfügbar. Die lokalen drei Looks bleiben beim lokalen Anbieter nutzbar. Datenfluss, Kostenreservierungen und Widerruf sind im [ADR](docs/ai/0001-anthropic-cloud-provider.md) festgehalten.

Das [Inpainting-Gate aus Issue #12](docs/AI-IMAGE-BACKEND-DECISION.md) ist mit **No-Go wegen Bildqualität** entschieden. Die geprüfte lokale SD-1.5-Inpainting-Route erzeugt sichtbare Texturgrenzen und fehlerhafte Hintergrund-/Canvas-Ergänzungen. Bildgenerierung, generative Hintergrundbearbeitung und Outpainting bleiben unavailable; die Maskengrundlage erteilt dafür keine Freigabe. Echte Ergebnisbilder, Modell-/SDK-Hashes, Lizenzen und Messgrenzen sind im Bericht verlinkt. `./scripts/evaluate-image-generation.sh` zeigt standardmäßig nur den Ausführungsplan. Synthetische Fixtures und Compositor-Replay benötigen keine Modelle; Installation und tatsächliche Inferenz sind getrennte ausdrückliche Schritte.

Den aktuellen Fortgang beschreibt die [KI-Roadmap](docs/AI-ROADMAP.md). Die getrennten [LaMa-Nachweise aus #74](tools/lama-evaluation/README.md) und die [lokale SDXL-Inpainting-Evaluation aus #77](tools/sdxl-evaluation/README.md) halten weitere Kandidaten und ihre Grenzen fest. SDXL erzeugt nach geprüften SDK-/Metal-Korrekturen tatsächliche Bilder innerhalb der Zeitgrenze, verfehlt aber Motivkantenqualität und Abbruchfrist. Die geprüfte Konfiguration bleibt No-Go; #13–16 sind weiterhin offen. Die [anschließende V9-Qualifikation](reports/image-backend/sdxl-mask-qualification-2026-10-18/README.md) gleicht ausschließlich das SDXL-Maskenraster an die Referenz an; die echte Pflichtprobe verfehlt weiterhin die Motivkantenqualität. Der neue Prozesswächter bestätigt das Ende nach 4,067 s mit SIGKILL, ausdrücklich ohne kooperatives Abbruch-Go. Die Produktfähigkeiten bleiben gesperrt. Auch die [V10-Probe mit modellgemäßem Euler-Zeitplan](reports/image-backend/sdxl-schedule-qualification-2026-10-18/README.md) bleibt No-Go: 19 tatsächliche Schritte statt der bisherigen 20, weiterhin schwarze Konturen und helle Säume. Zeitplan und Originalpixel-Erhalt sind geprüft; Issue #14 bleibt blockiert.

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

Die automatisierten Tests verwenden Swift Testing und benötigen **Swift 6.1 oder neuer**. Das Testskript setzt lokale Compiler-Caches und berücksichtigt die Plugin-Erkennung der Apple Command Line Tools:

```sh
./scripts/test.sh
swift build
./scripts/test-image-pipeline.sh
./scripts/test-build-app.sh
```

Die [Scheduling-Testdokumentation](docs/TEST-SCHEDULING.md) beschreibt suspendierende Fake-Gates, den Erhalt von Workerplätzen bei Abbruch und die Kontrollprobe für blockierende gegenüber suspendierenden Testworkern. Die vollständige Suite bleibt standardmäßig parallel.

Mit einer vollständigen, normal eingerichteten Xcode-Installation ist alternativ `swift test` möglich. Optional setzt `PICEDIT_TEST_BUILD_PATH` ein separates Build-Verzeichnis für die Pakettests.

Vorschau-Smoke-Test und Editing-/Library-Benchmarks kompilieren ihre isolierten Einstiegspunkte innerhalb des echten SwiftPM-App-Targets, einschließlich aller Abhängigkeiten und Ressourcen. Ihre Release-Caches liegen unter `.build-app/developer-tools/<Werkzeug>`; `PICEDIT_DEVELOPER_BUILD_PATH` und `PICEDIT_BUILD_JOBS` erlauben eigene Build-Verzeichnisse und begrenzte Parallelität. Unabhängige Builds benötigen getrennte Verzeichnisse; Vergleichsmessungen nacheinander ausführen. App-Build und reguläres Testskript entfernen eine geerbte `PICEDIT_DEVELOPER_TOOL`-Auswahl, damit keine Benchmark-App veröffentlicht wird.

`./scripts/evaluate-lightcraft.sh /tmp/picedit-lc01-run` erweitert den Editing-Harness um reproduzierbare Bildqualitätsvergleiche: feste synthetische Szenen, eingefrorene Messgrenzen, Paar-/Differenzbilder sowie getrennte kalte/warme Messungen bis über 4096 Pixel. Der [LC-01-Bericht](docs/LIGHTCRAFT-ALGORITHM-EVALUATION.md) beschreibt Kontrollpfade, Kandidatenstatus, Nutzungsrechte optionaler realer Fixtures und Evidenzlücken. Ein bestandener Harness-Kontrolllauf ist keine Freigabe eines neuen Produktionsalgorithmus.

Mit `--candidate LC-03` wird der [isolierte Lichter-/Schattenvergleich](docs/LIGHTCRAFT-TONE-EVALUATION.md) ausgeführt; `--candidate LC-04` untersucht [Klarheit und Textur getrennt](docs/LIGHTCRAFT-DETAIL-EVALUATION.md). Diese Modi frieren die Effektangleichung vor der Abnahme ein und dokumentieren ihre Grenzen. `--candidate LC-05` ergänzt den [separaten Dynamik-/Sättigungsvergleich](docs/LIGHTCRAFT-COLOR-EVALUATION.md) mit angeglichener Chromawirkung. `--candidate LC-06` prüft [Entrauschung und native Skalierung](docs/LIGHTCRAFT-DENOISE-EVALUATION.md) bei angeglichener Rauschminderung und bekannter Ground Truth. Ihre CPU-Referenzen werden nicht vom Produktionsrenderer aufgerufen.

`./scripts/test-developer-tools.sh` prüft die sichere Ablehnung älterer, inkompatibler Quell-Checkouts ohne Swift-Kompilierung. `./scripts/test-keychain.sh` prüft ausdrücklich den echten macOS-Keychain aus einer temporären ad-hoc signierten App: Speichern, Lesen, Ersetzen und Löschen ausschließlich eines synthetischen Schlüssels in einem frischen UUID-Namensraum. Der Produktionsschlüssel wird dabei nicht angesprochen; macOS kann den Zugriff auf den lokalen Schlüsselbund bestätigen lassen.

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

**Natürlicher Bildausgleich** ersetzt die bisherige Tonwert-Automatik in der Bedienoberfläche. Er ist standardmäßig ausgeschaltet. Aktiviere ihn oberhalb der Tonwertregler: **Stärke** startet bei 70 %, **Farbe** bei 50 %. Die Stärke steuert den gesamten Effekt; Farbe regelt die zusätzliche, zurückhaltende Farbverstärkung (0 %: nur Tonwertausgleich). Das Bild wird anhand seiner Helligkeits- und Farbverteilung sowie lokaler Gesichtserkennung ausgewertet. Schatten werden geöffnet, Lichter zurückgenommen, kräftige Farben und warme Hauttöne geschont. Schwarz und Weiß bleiben erhalten; vollständig verlorene Details lassen sich nicht rekonstruieren. [Bedienung, Algorithmus und Prüfung](docs/NATURAL-BALANCE.md).

Der Bildausgleich wirkt vor den manuellen Reglern. Vorhandene Einstellungen bleiben erhalten und lassen sich weiter verfeinern; starke manuelle Korrekturen können weiterhin zu Über- oder Unterbelichtung führen. Beide Stärken werden pro Foto gespeichert, in Backups aufgenommen und von Vorher-Vergleich, Rückgängig/Wiederholen und vollständigem Zurücksetzen berücksichtigt. Ältere Bearbeitungen behalten ihre bisherige Tonwert-Automatik unverändert, bis sie ausdrücklich durch den neuen Bildausgleich ersetzt oder ausgeschaltet wird. Auch die vorhandenen KI-Assistenten können die neuen Regler auf ausdrücklichen Wunsch vorschlagen; gültige Regleränderungen werden direkt aktiviert.

Die Werte lassen sich über Schieberegler oder Zahlenfelder ändern. **Aktuelle Quelle ohne Regler** vergleicht mit der aktiven Bildbasis ohne zusätzliche Anpassungen; **Importiertes Original anzeigen** zeigt die importierte Originaldatei ohne Bearbeitung. Eine Reglerbewegung oder abgeschlossene Zahleneingabe bildet einen Rückgängig-Schritt; **⌘Z** nimmt die letzte Änderung zurück, weiteres Drücken jeweils die nächste. **⇧⌘Z** oder die Pfeile unten wiederholen Änderungen. Die Historie bleibt ohne feste Schrittgrenze bis zur Auswahl einer anderen Funktion erhalten. Speichern, derselbe Funktionsaufruf und das Aus-/Einblenden von Seitenbereichen löschen sie nicht. Die Kreis-Pfeile setzen einzelne Bereiche zurück, **Zurücksetzen** alle Regler. Ein Doppelklick auf eine Reglerbeschriftung setzt diesen Wert auf null. Rückgängig-Verläufe gelten für die laufende Sitzung; die aktuellen Werte bleiben nach einem Neustart erhalten.

Raster, Filmstreifen und Einzelansicht zeigen die gespeicherten Bearbeitungen. Die RAW-Basis im Entwickeln-Modul wird aus dem Original erzeugt, ohne eine eingebettete Kamera-Vorschau als Bearbeitungsbasis zu verwenden. Bearbeitungsbasen werden verlustfrei zwischengespeichert. Reglerbewegungen verwenden diese Basis erneut; veraltete Renderaufträge können neuere Ergebnisse nicht überschreiben. Core Image führt die Bildfilter auf seinem verfügbaren Backend aus (auf dem geprüften Apple-Silicon-Mac über Metal). Unveränderte Entrauschungs- und Bildausgleichsstufen des ausgewählten Bildes sowie die begrenzte Bildanalyse werden wiederverwendet. Originaldateien und gespeicherte Bearbeitungsparameter bleiben davon unberührt.

Dauerhafte Rastervarianten verwenden eine eigene unveränderliche Quelle unter `GeneratedArtifacts`, getrennt vom Vorschau-Cache. Ein angenommener flacher Bildstand enthält bereits die zuvor gerenderten Regler; seine neuen Regler beginnen neutral. **Zurücksetzen** setzt nur die Regler der aktiven Quelle zurück. **Zum importierten Original zurückkehren** wechselt die Quelle als eigener rückgängig machbarer Schritt. **Importiertes Original anzeigen** und **Aktuelle Quelle ohne Regler** sind reine Vergleiche. Ein gespeicherter Rasterstand bleibt bei fehlendem Original sichtbar; ein fehlendes Artefakt zeigt einen Fehler. Diese Speichergrundlage schaltet noch keine generative Endnutzerfunktion frei.

Die Filter verwenden Core Image und eigene Tonwert-/Kontrastberechnungen. Ihre Bedienung orientiert sich an Lightroom Classic, die Ergebnisse sind nicht identisch mit Adobes Entwicklungsengine. Entrauschen ist eine klassische, getrennte Luminanz-/Farbrauschminderung, keine KI-Funktion. Die Entwickeln-Ansicht verwendet Vorschauen mit bis zu 2400 Pixeln langer Kante. Weißabgleich und Zuschnitt sind gespeichert; der Weißabgleich setzt auf der Kamera-/ImageIO-Entwicklung auf. Direkte Sensordatenregler vor dem Demosaicing sind kein Bestandteil dieses Pfads. Bei aktiver Originalquelle verwendet der JPEG-Export das Original in voller Auflösung und dieselben Bearbeitungsfilter. Für aktive generierte Rasterquellen ist er bis zur geplanten Variantenexport-Integration gesperrt.

Die Entwickeln-Seitenleiste zeigt oben das RGB-Histogramm der aktuellen Vorschau, Aufnahmedaten, Schatten-/Lichterwarnung und die Werkzeugleiste. **Maskieren** öffnet **Neue Maske hinzufügen** mit Kacheln für **Motiv**, **Himmel** und **Hintergrund** sowie Zeilen für **Pinsel**, **Linearer Verlauf** und **Radialverlauf**. **Hintergrund** verwendet die umgekehrte Motivauswahl. **Landschaft** und **Objekte** bleiben sichtbar deaktiviert; **Personen** kennzeichnet die noch nicht verfügbare Personenauswahl. Bei ausgewählter Maske klappt **+** in der Kopfzeile die Auswahl oberhalb der kompakten Korrekturregler auf. Mehrere benannte Masken lassen sich mit lokalen Tonwert-/Präsenzreglern bearbeiten. Pinsel und Radierer verfeinern auch automatische Auswahlen; bei Verläufen zuerst **Mit Pinsel verfeinern** einschalten. Stärke, weiche Kante, Invertierung und Deaktivierung steuern die Auswahl. Die kleine Maskenliste liegt neben der Reglerpalette auf der Bildfläche und erscheint erst ab der ersten vorhandenen Maske. Eine Zeile wählt die Maske, ihr Papierkorb löscht sie mit lokaler Rückgängig-Möglichkeit; nach dem Löschen der letzten Maske verschwindet die Liste wieder. Rückgängig/Wiederholen bleiben dann in der Kopfzeile der rechten Palette erreichbar. Beschriftung, kleiner Regler und Wert stehen in einer Zeile. Änderungen an lokalen Korrekturen oder Maskenstärke blenden die rote Überlagerung automatisch aus; Auswählen oder Formen einer Maske zeigt sie wieder. **Überlagerung** bleibt manuell schaltbar, **Vorher** zeigt den Ausgangsstand der Palette.

Maskenänderungen wirken direkt und werden automatisch gespeichert; jeder Strich und jede Reglerbewegung lässt sich einzeln mit **⌘Z** zurücknehmen. Masken bleiben nach Neustart und Backup/Restore erhalten und fließen beim Export von Originalquellen in das JPEG ein. **Schließen** kehrt zu den Grundeinstellungen zurück. Die Rückkehr zum Raster und Bild-/Quellenwechsel bewahren bereits aktive Anpassungen. Das Aus-/Einblenden der Seitenbereiche erhält die Maskenpalette samt Historie. Vollständiges **Zurücksetzen** entfernt auch die Masken. Für die lokale Himmelserkennung einmalig über **Himmelsmodell einrichten …** etwa 86 MB laden; anschließend arbeitet sie offline. Fotos bleiben auf dem Mac. Auswahlpräzision, Modelllizenz und Grenzen stehen in [Masken](docs/MASK-EDITING.md) und [automatischen Masken](docs/AUTOMATIC-MASKS.md).

Neue Motiv-, Hintergrund- und Himmelsmasken bewahren Auswahlen mit bis zu 2048 Pixeln langer Kante und folgen bei der Erzeugung den RGB-Bildkanten. Sie starten mit **Weiche Kante = 0**, um zusätzliche breite Säume zu vermeiden. Hintergrund verwendet die umgekehrte verfeinerte Motivauswahl. Bestehende Masken werden nicht neu berechnet: Für die verbesserte Erkennung eine neue Maske erstellen; **Weiche Kante = 0** entfernt bei alten Masken nur die zusätzliche Weichzeichnung. Pinsel und Verläufe behalten ihr bisheriges Verhalten. Vollständig übersehene Zwischenräume können weiterhin eine Pinsel-/Radiererkorrektur benötigen.

Die Grundeinstellungen ergänzen **Temperatur**, **Tönung**, **Neutralpipette**, drei PicEdit-Profile und **S/W**. 6500 ist die neutrale Referenz auf bereits entwickelten Pixeln, kein ausgelesener Kamera-Kelvinwert. **HDR** erhält erweiterte Helligkeitswerte und verwendet eine HDR-fähige Anzeige; die Formatwahl im Export bietet zusätzlich **HEIF 10 Bit HDR**. JPEG bleibt SDR. **Zuschneiden** bietet acht großzügig treffbare Größen-Griffe, freie/gesperrte Seitenverhältnisse, Verschieben durch Ziehen im Rahmen einschließlich Drei-Finger-Ziehen, sofort sichtbare Winkeländerungen, eine Wasserwaage mit Bezugslinie und automatische Horizonterkennung. **Reparieren** bietet direkt wirksames Entfernen mit wechselbarer automatischer oder manueller Quelle, feine Pinsel für kleine Details, Heilen und Kopierstempel, zusammenhängende Pinselzüge, Objektauswahl, prüfbare Personen-/Staubvorschläge und Fleckenansicht. Ein ausdrücklich importiertes kompatibles LaMa-Modell ergänzt kleine Bereiche lokal; das gültige Ergebnis wird direkt aktiv und lässt sich rückgängig machen. Modelle werden weder mitgeliefert noch heruntergeladen, Spiegelungsentfernung ist weiterhin nicht verfügbar. **Rote Augen** korrigiert explizit umrahmte Pupillen. Bedienung und Grenzen: [Entwickeln](docs/DEVELOP-WORKSPACE.md), [Reparaturwerkzeuge](docs/REPAIR-TOOLS.md), [Farbkorrekturen](docs/DEVELOP-COLOR.md). Ein **Doppelklick auf einen Regler** stellt seinen fachlichen Neutralwert als eigenen Rückgängig-Schritt wieder her.


### Lokaler Entwicklungsassistent

Im Entwickeln-Inspector eine deutsche Anweisung wie „Helle die Schatten auf“ eingeben und **Vorschlag erstellen** wählen. Der Assistent übersetzt Text in Reglerwerte; er analysiert das Foto nicht. Weißabgleich, Motivbeschreibung, Retusche und neue Bildpixel gehören nicht zu seinen Fähigkeiten. Bei fehlender Unterstützung nennt die Oberfläche den Verfügbarkeitsgrund; die manuellen Regler bleiben nutzbar.

Eine gültige Assistentenantwort aktiviert ihre Regleränderungen direkt als einen Rückgängig-Schritt und zeigt Ausgangs- und Zielwerte samt Delta. Zwischen Ausgangsstand und aktiver Bearbeitung wechseln; **Importiertes Original anzeigen** vergleicht mit dem Original ohne Regler; **Aktuelle Quelle ohne Regler** zeigt die aktive Bildbasis ohne zusätzliche Anpassungen. **Schließen** entfernt nur die Ergebnisanzeige; **⌘Z** nimmt die aktive Anpassung zurück. **Abbrechen** beendet noch laufende Anfragen. Bildwechsel, manuelle Änderungen, Undo/Redo, Zurücksetzen, Backup/Restore und Schließen entwerten wartende und angezeigte Vorschläge.

**Drei Looks erstellen** liefert gemeinsam die Textrezepte „Natürlich“, „Kontrastreich“ und „Entsättigt“ aus derselben aktuellen Bearbeitung. Zusatztext ist optional. Eine Karte anklicken aktiviert die Variante direkt; jede weitere Auswahl erzeugt einen eigenen Rückgängig-Schritt. Alle Karten verwenden denselben Ausgangsstand, sodass sich Looks beim Wechsel nicht aufaddieren. Der Wechsel zwischen den Karten startet keine neue Modellanfrage. Die kleinen Karten teilen die decodierte Entwicklungsbasis mit der Hauptansicht und halten gemeinsam höchstens 8 MiB. Vertrag, Grenzen und Prüfung sind in [Drei lokale Lookvorschläge](docs/AI-LOOKS.md) beschrieben.

Raster, Filmstreifen, Speicherstatus und JPEG-Export verwenden die direkt aktivierten Werte. Ein reiner Ausgangsvergleich verändert den Export nicht. Der Provider erhält ausschließlich Anweisung und Reglerwerte, keine Bildpixel, Dateinamen, Pfade oder EXIF-Daten. PicEdit startet keinen Modelldownload und verwendet keinen Cloudfallback. Prompts und Antworten werden nicht protokolliert oder dauerhaft gespeichert. Einrichtung, Buildmatrix und ausdrücklich aktivierbare Modelltests stehen in der [Assistentendokumentation](docs/LOCAL-AI-ASSISTANT.md).

### Lokale Bildanalyse

Im separaten Bereich **Bildanalyse** mit **Bild lokal analysieren** eine Beschreibung und sichtbare Attribute vorschlagen lassen. Voraussetzung sind ein Build mit SDK 27, macOS 27 und ein verfügbares Apple-Systemmodell mit Deutsch- und Bildunterstützung. **Bildfähigkeit erneut prüfen** aktualisiert die Verfügbarkeitsanzeige. Die übrige App und der Textassistent haben ihre bisherigen Systemvoraussetzungen.

Standard ist die **Originalvorschau**, unabhängig von den Reglern. **Bearbeitete Vorschau** analysiert ausdrücklich die übernommenen Reglerwerte. Nicht angenommene Lookvorschläge sind keine Analysegrundlage. Die Eingabe ist auf 1024 Pixel lange Kante und 16 MiB Rasterdaten begrenzt; Dateipfade und EXIF-Daten werden nicht an das Modell übergeben. **Analyse abbrechen** beendet das Warten, **Analyse verwerfen** entfernt das Ergebnis. Bildwechsel und veraltete Quellen entwerten Antworten; bei bearbeiteter Eingabe gelten zusätzlich die Bearbeitungsrevisionen.

Beschreibung und Attribute bleiben als **noch nicht bestätigt** gekennzeichnet. Sie ändern keine Regler, Originale oder gespeicherten Metadaten. **Analysebezug** zeigt Anbieter, Modell, Eingabemaße und Rasterprüfsumme. Aussagen zu Identität, Gesundheit oder einem nicht belegten Aufnahmeort werden nicht bestätigt. SDK-Gates, lokale Ausführung, Datenbezug und Prüfgrenzen stehen in der [Bildanalyse-Dokumentation](docs/AI-IMAGE-ANALYSIS.md).

### Bildinformationen: Titel, Beschreibung und Tags

Der Bereich **Bildinformationen** hält redaktionelle Texte getrennt von Kameraangaben und Reglern. Titel, Beschreibung, Tags und Sprache lassen sich auch ohne KI manuell pflegen. **Vorschlagen** verwendet die lokale Bildfähigkeit und eine begrenzte Originalvorschau. Vorschläge bleiben ausdrücklich unbestätigt; erst **Übernehmen** speichert die gewählten Felder. Tags werden standardmäßig ergänzt, Ersetzen ist eine eigene bewusste Auswahl. **Neu erstellen** prüft erneut die tatsächlichen Eingabepixel. Keine Originaldatei oder EXIF-Daten werden verändert.

Bestätigte Inhalte bleiben bei erneuter Analyse, Bildwechsel und Bibliotheksaktualisierung erhalten. Geänderte Quellen und Zuordnungskonflikte werden angezeigt. Unfertige manuelle Eingaben gehören zum jeweiligen Foto und werden als eigener Entwurf erhalten. Nur bestätigte Inhalte erweitern die wörtliche Suche und deren Filter vor der semantischen Trefferauswahl.

Die dauerhaften Texte und Entwürfe liegen separat in **`photo-metadata.sqlite`** im Katalogverzeichnis, auch bei `--catalog-directory`. Vorhandene Bearbeitungsbackups enthalten sie nicht. **Bildinformationen exportieren/importieren** sichert bestätigte Inhalte als versioniertes JSON; Entwürfe, Fotos und der Katalog gehören nicht zu diesem Export. Import ergänzt standardmäßig fehlende Einträge; bestehende Inhalte werden nur nach Konfliktprüfung und ausdrücklicher Auswahl ersetzt. Grenzen, Datenbezug und Wiederanlauf stehen in [Bildinformationen und manuelle Sicherung](docs/PHOTO-METADATA.md).

## JPEG-Export

Wähle ein oder mehrere Fotos und klicke oben auf **Exportieren**, nutze **Ablage → Foto als JPEG exportieren …** beziehungsweise **Ausgewählte Fotos als JPEG exportieren …** oder **⇧⌘E**. Der Export steht auch im Kontextmenü der Bilder im Raster, Filmstreifen und in der Einzelansicht. Gehört das angeklickte Bild zur Auswahl, werden alle ausgewählten Bilder exportiert; andernfalls wird dieses Bild ausgewählt und exportiert. Der Dialog gliedert die Optionen wie in Lightroom in Speicherort, Dateieinstellungen und Bildgröße.

- **Speicherort:** Zielordner frei wählen; beim Einzelexport auch den Dateinamen. Vorgeschlagen wird `Originalname-bearbeitet.jpg`. Bei mehreren Bildern wird dieser Name pro Original automatisch vergeben; gleiche Namen erhalten einen eindeutigen Zahlenzusatz. Vorhandene Exportdateien werden nur nach Bestätigung ersetzt; importierte Originalbilder sind als Ziel gesperrt.
- **Dateieinstellungen:** JPEG mit **sRGB** oder **Display P3**. Die Pixel werden in den gewählten Farbraum umgerechnet; sRGB wird per EXIF gekennzeichnet, Display P3 mit einem eingebetteten ICC-Profil. **Qualität 0–100** steuert die Kompression: höhere Werte erhalten mehr Details und erzeugen meist größere Dateien.
- **Bildgröße:** Originalgröße, maximale lange Kante oder Einpassen in Breite und Höhe, jeweils in Pixeln. Das Seitenverhältnis bleibt erhalten; es wird weder beschnitten noch verzerrt. Vergrößern ist standardmäßig ausgeschaltet und kann ausdrücklich erlaubt werden.
- **Auflösung:** 1–1200 Pixel pro Zoll (ppi) als Druckauflösung. Dieser Wert ändert die Druckgrößenangabe, nicht die Pixelzahl.

Exportiert wird der beim Öffnen des Dialogs erfasste Bearbeitungsstand, auch wenn gerade einer der beiden Quellenvergleiche aktiv war. Der Export decodiert das Original und verwendet keine eingebettete RAW-Kameravorschau oder bereits verkleinerte Bildschirmvorschau. RAW-Unterstützung hängt weiterhin von ImageIO/macOS und dem Kameraformat ab. JPEG unterstützt keine Transparenz; transparente Bereiche werden weiß hinterlegt.

Der Export läuft im Hintergrund und kann abgebrochen werden. Mehrere Bilder verwenden dieselben Optionen und werden in der sichtbaren Reihenfolge nacheinander verarbeitet; der Dialog zeigt den Fortschritt. Bereits erfolgreich exportierte Dateien bleiben bei einem Abbruch erhalten. Erst eine fertig geschriebene Datei wird atomar am Ziel veröffentlicht. Große Exporte sind auf einen Auftrag gleichzeitig begrenzt und unterliegen einer Speicherprüfung; bei zu großen Bildern erscheint ein Fehler statt einer stillen Auflösungsreduktion. Die App wartet beim Beenden auf den Abschluss oder Abbruch eines laufenden Exports. Einstellungen und zuletzt gewählter Ordner werden für den nächsten Export gemerkt. Nach Abschluss lassen sich die Dateien im Finder anzeigen.

## Datenbank und Backups

Aktive Bildquelle und Regler stehen pro Foto gemeinsam in **`~/Library/Application Support/PicEdit/edits.sqlite`**. Schema 2 verwendet geschlossene SQLite-Dateien mit DELETE-Journal, `synchronous=FULL`, Transaktionen und fortlaufenden Versionen pro Bild. Vorhandene Schema-1-Regler einschließlich Revisionen und Tombstones werden übernommen; bei alten WAL-Datenbanken wird die unveränderte Dateifamilie vor der Migration unter `EditMigrationArchives` archiviert. Mehrere schnelle Regleränderungen werden zusammengefasst. Beim Beenden wartet die App auf tatsächlich abgeschlossene angenommene Schreibaufträge. Konflikte oder Schreibfehler werden angezeigt; ungespeicherte Werte bleiben wiederholbar.

Der vorhandene Bibliothekskatalog mit Ordnern, Metadaten, Bewertungen und Favoriten bleibt in `catalog.json`. Katalog, Bearbeitungen und die getrennten Bildinformationen liegen bei `--catalog-directory` im angegebenen Test-/Datenverzeichnis.

Beim Start werden verwaiste Einträge älterer Programmstände anhand des gespeicherten Katalogs bereinigt. Die Bereinigung läuft außerdem beim Entfernen und beim Aktualisieren eines Ordners; vor einem neuen Import werden unterbrochene Bereinigungen wiederholt. Angenommene Speichervorgänge werden zuvor abgewartet. Die Datenbanken bereinigen ihre Einträge jeweils atomar; eine neue Bearbeitungsepoche verhindert verspätete Writes mit alten Versionen. Schlägt die Bereinigung nach Veröffentlichung des Katalogs fehl, bleibt der tatsächliche Katalog sichtbar, weitere Änderungen werden gesperrt und der nächste Start wiederholt den Vorgang. Nicht verfügbare Originaldateien lösen keine Löschung aus.

Ältere gültige Bearbeitungen bleiben nach dem Hinzufügen neuer Regler lesbar: fehlende optionale Regler erhalten ihre vorgesehenen Standardwerte, die ursprüngliche gespeicherte Darstellung und Prüfsummen bleiben erhalten. Kann eine Bearbeitungsdatenbank dennoch nicht geladen werden, zeigt die Bibliothek ausdrücklich gekennzeichnete Originalvorschauen ohne Bearbeitung an, sofern der gemeinsame Katalog-Wiederanlauf erfolgreich war. Speichern bleibt bis zur Wiederherstellung gesperrt. Ungeklärte Katalogumzüge werden weiterhin geschützt.

Vorhandene manuelle/automatische Backups, Recoveryarchive und unveränderliche veröffentlichte Rasterdateien werden durch das Entfernen eines Katalogbildes nicht physisch gelöscht. Sie gehören zur Sicherungs- beziehungsweise Artefaktablage, nicht zu den aktiven Bilddatensätzen. Sie werden beim erneuten Import nicht automatisch übernommen.

- **Automatisch:** Nach dem ersten erfolgreichen Speichern an einem Tag entsteht ein geprüftes `.piceditbackup` unter `EditBackups`. Die letzten sieben eindeutig app-eigenen automatischen Pakete bleiben erhalten. Veränderte, fremde oder als Original verwendete Pakete werden vorsichtshalber behalten; dann können mehr als sieben vorhanden sein. Alte `.sqlite`-Backups werden nicht automatisch gelöscht.
- **Manuell:** Über das Backup-Symbol oben rechts oder **Entwickeln → Bearbeitungen sichern …** einen Zielort auswählen, beispielsweise ein externes Laufwerk. Manuelle Sicherungen werden nicht automatisch gelöscht.
- **Wiederherstellen:** **Backup wiederherstellen …** öffnet ein Bearbeitungspaket oder ein älteres `.sqlite`-Reglerbackup. Vor der Übernahme werden die gesamte referenzierte Datenmenge, Integrität, Schema und Werte geprüft und der bisherige Zustand separat gesichert. Ungültige Pakete verändern den aktiven Bearbeitungsstand nicht. Alte Reglerbackups stellen Originalquellen her.
- **Beschädigte Datenbank:** Eine ausdrückliche Wiederherstellung aus einem gültigen Backup erhält die beschädigte Datenbankfamilie und den bisherigen Artefaktbaum unter `EditingRecoveryArchives`. Ein nicht abgeschlossener gemeinsamer Katalogumzug muss zuvor geklärt werden. Erkennbare fremde SQLite-Datenbanken und neuere Schema-Versionen werden nicht ersetzt.

**Bearbeitungspakete enthalten aktive Quellen, Regler, Varianten und deren generierte Pixel, Masken und Provenienz. Originalbilder, `catalog.json`, `photo-metadata.sqlite` mit redaktionellen Texten/Entwürfen, Clouddaten und Vorschau-Caches sind nicht enthalten.** Bestätigte Bildinformationen separat als JSON exportieren; dieser Export enthält keine Entwürfe. Fotoordner und passenden Katalog separat sichern. Ein Paket allein stellt die Katalogzuordnung nicht her. Für eine Sicherung gegen Datenträgerausfall das manuelle Paket auf ein anderes Laufwerk speichern.

Die Sicherung verwendet die SQLite Online Backup API und Ressourcen-Leases für alle transitiv referenzierten Artefakte. Nach dem konsistenten SQL-Snapshot kann die unveränderliche Paketkopie mit weiterer Bearbeitung überlappen. Die Veröffentlichung erfolgt erst nach vollständiger Prüfung. Der separate [Speichervertrag](docs/ARTIFACT-STORAGE.md) beschreibt Format, Grenzen und Wiederanlauf.

Die Renderer-Tests prüfen mit synthetischen Bildern Richtung und Wirkung der Regler, Rauschvarianz, Tonwertverläufe, Transparenz und Farbprofile. Datenbank-/Controller-Tests decken unter anderem Neustart, Schreibkonflikte, schnelle Bildwechsel, gleichzeitige Speicherversuche, fehlgeschlagene Writes, Backup-Rotation, beschädigte Sicherungen und Wiederherstellung ab. Core Image benötigt für diese Tests eine normale macOS-Sitzung; eine restriktive Ausführungssandbox kann den Renderer blockieren.
