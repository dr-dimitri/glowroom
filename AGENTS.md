# Projektvorgaben für PicEdit

Diese Vorgaben gelten für das gesamte Repository und für alle daran arbeitenden Entwicklungsagenten.

## Parallelisierung ist der Standard

**Alle Tätigkeiten sind zu parallelisieren, sofern dies technisch möglich und sinnvoll ist.** Das gilt sowohl für die Entwicklungsarbeit als auch für die Laufzeit der Anwendung. Wähle je nach Aufgabe CPU, GPU oder eine Kombination daraus. Nutze Parallelität, wenn sie die Bearbeitungszeit, Reaktionsfähigkeit oder den Durchsatz verbessert; beachte dabei Korrektheit, Speicherbedarf und Energieverbrauch.

Abhängigkeiten und gemeinsam veränderlicher Zustand müssen geschützt bleiben. Kleine Aufgaben dürfen seriell bleiben, wenn Synchronisierung, Übertragung oder Start zusätzlicher Arbeit mehr Aufwand verursachen als sie einsparen. Begründe relevante Ausnahmen kurz im Code, in der Änderungsbeschreibung oder im Arbeitsbericht.

## Entwicklungsarbeit

- Aktualisiere vor Beginn jeder neuen beauftragten Änderung den lokalen `main` vom zugehörigen Remote: Git-Status prüfen, Remote-Stand abrufen, auf `main` wechseln und mit `git pull --ff-only` aktualisieren. Starte den Aufgabenbranch von diesem aktuellen Stand. Bewahre fremde oder noch benötigte Änderungen; überschreibe oder verwerfe sie nicht beim Branchwechsel. Scheitert die sichere Aktualisierung, melde das Hindernis und beginne keine Umsetzung auf veraltetem `main`.
- Zerlege größere Aufgaben in unabhängig bearbeitbare Teile. Nutze verfügbare Subagenten für Implementierung, Recherche, Review oder Tests, wenn dies Zeit spart oder die Qualität verbessert.
- Führe unabhängige Suchen, Dateilesen, Analysen und Werkzeugaufrufe parallel aus, soweit die Werkzeuge dies unterstützen.
- Verteile Schreibzugriffe auf klar abgegrenzte Dateien oder Verantwortungsbereiche. Gleichzeitige Änderungen an derselben Datei müssen koordiniert werden.
- Führe unabhängige Builds und Tests parallel aus, sofern sie getrennte Build-Verzeichnisse, Testdaten und andere veränderliche Ressourcen verwenden. Abhängige Schritte und Änderungen an gemeinsamem Git-Zustand bleiben geordnet.
- Prüfe parallele Teilergebnisse einzeln und anschließend ihre Integration. Parallelisierung ersetzt weder Review noch Verifikation.

## Abschluss von Änderungen

- Führe nach jeder umgesetzten Änderung und vor deren Abschluss ein Review des finalen Diffs einschließlich betroffener Schnittstellen, Tests und Dokumentation durch. Behebe zur Umsetzung gehörende Befunde und prüfe die Korrekturen erneut; dokumentiere das Review-Ergebnis im Abschlussbericht.
- Erfasse jeden während der Umsetzung oder beim Review gefundenen Bug, der nicht mit der aktuellen Umsetzung zusammenhängt, als eigenes Issue im Issue-Tracker des Repositorys. Prüfe zuvor auf vorhandene Issues, um Duplikate zu vermeiden; verlinke gegebenenfalls das bestehende Issue. Beschreibe Reproduktionsschritte, erwartetes und tatsächliches Verhalten sowie betroffene Stellen und verlinke das Issue im Abschlussbericht. Vermische diese unabhängigen Fehlerbehebungen nicht mit der aktuellen Umsetzung. Ist die Issue-Erfassung wegen fehlenden Zugriffs nicht möglich, melde das Hindernis ausdrücklich und bewahre den vollständigen Issue-Entwurf auf.
- Führe vor dem Abschluss einer Umsetzungsanforderung nur dann einen sauberen, vollständigen lokalen Build mit `./scripts/build-app.sh` aus, wenn tatsächlich relevanter Quellcode geändert wurde. Relevant sind Änderungen, die Kompilierung, Paketierung oder Laufzeitverhalten der App beeinflussen können; dazu zählen auch entsprechende Änderungen an Build-Skripten, Abhängigkeiten, Konfiguration oder eingebundenen Ressourcen. Reine Änderungen an Dokumentation, Projektvorgaben oder anderen nicht buildwirksamen Dateien erfordern keinen neuen Build. Dokumentiere die Entscheidung und ihre Begründung im Abschlussbericht. Ist ein Build erforderlich, genügt ein inkrementeller Build allein nicht.
- Entferne vor diesem Build die alten generierten Build-Ergebnisse aus den verwendeten Build-Verzeichnissen (standardmäßig `.build/` und gegebenenfalls `.build-app/`) sowie das bisherige App-Bundle `dist/PicEdit.app`. Berücksichtige abweichende Pfade wie `PICEDIT_BUILD_PATH`. Stelle vor der Bereinigung sicher, dass kein laufender Build oder Test diese Pfade verwendet; entferne keine aktiven Build-Locks und keine Quelldateien oder Nutzerdaten. Bereinigung und anschließender Build bleiben wegen ihrer Abhängigkeit geordnet.
- Aktualisiere bei jeder Umsetzungsanforderung die zugehörige Dokumentation, damit Verhalten, Bedienung und Entwicklungsabläufe dem umgesetzten Stand entsprechen.
- Schließe beauftragte Änderungen nach erfolgreichem Review, geeigneter Prüfung und, falls nach obiger Regel erforderlich, erfolgreichem sauberem lokalen Build mit einem aussagekräftigen Git-Commit ab und pushe diesen auf den zugehörigen Remote-Branch. Erstelle oder aktualisiere den zugehörigen Pull Request gegen `main` und merge die geprüfte Änderung, sofern der Nutzer nichts anderes vorgibt. Erfülle vor dem Merge die erforderlichen Reviews und Statusprüfungen; umgehe keine Branch-Schutzregeln. Wird der geprüfte Stand nachträglich verändert, reviewe und prüfe die betroffenen Änderungen erneut vor dem Merge.
- Nimm nur die zur Aufgabe gehörenden Änderungen in den Commit auf. Überschreibe keine fremden Änderungen und verwende keinen Force-Push.
- Nach bestätigtem Merge muss der alte Aufgabenbranch lokal und auf dem Remote entfernt werden, sofern dadurch keine ungesicherten oder noch benötigten Änderungen verloren gehen. Die automatische Branch-Löschung auf GitHub ersetzt die lokale Bereinigung nicht. Wechsle vor der lokalen Löschung auf `main`, aktualisiere ihn mit `git pull --ff-only`, prüfe den bestätigten Merge und verwende eine sichere Löschung ohne Erzwingen. Prüfe anschließend, dass der Branch lokal und auf dem Remote nicht mehr existiert. Ist eine sichere Bereinigung nicht möglich, bewahre den Branch und melde das konkrete Hindernis im Abschlussbericht. Arbeite beim nächsten Auftrag vom aktualisierten `main` weiter. Lösche niemals `main` und erzwinge keine Branch-Löschung, wenn dessen sicherer Abschluss nicht nachgewiesen ist.
- Prüfe vor dem Push den Diff, nach dem Push den Git-Status und nach dem Merge den aktualisierten `main`. Berichte Commit, Aufgabenbranch, Pull Request und Merge-Status, gegebenenfalls die Branch-Löschung sowie Ergebnis des sauberen lokalen Builds oder den begründeten Build-Verzicht, Testergebnis und verbleibende Hindernisse. Melde fehlgeschlagene Builds ausdrücklich; eine Umsetzungsanforderung ist erst nach erfolgreicher geeigneter Prüfung, einem gegebenenfalls erforderlichen erfolgreichen sauberen lokalen Build und dem vorgesehenen Merge abgeschlossen. Ist der Merge blockiert, melde die konkrete Ursache und bewahre den geprüften Branch.

## CPU, GPU und Ein-/Ausgabe

- **CPU:** Nutze begrenzte Hintergrundparallelität für unabhängige Datei- und Metadatenverarbeitung, Katalogberechnungen, Analysen und andere geeignete Aufgaben. Bevorzuge strukturierte Swift-Concurrency mit `TaskGroup`, Actors oder passend begrenzten Queues.
- **GPU:** Nutze für ausreichend große, datenparallele Bildoperationen bevorzugt Core Image und bei begründetem Bedarf Metal. Wiederverwendbare Kontexte und zusammenhängende Verarbeitungsschritte sollen Initialisierung und CPU-/GPU-Transfers reduzieren. Lasse Core Image seine geeignete Ausführung wählen, statt jede Operation ungeprüft auf die GPU zu zwingen.
- **CPU oder GPU:** Entscheide anhand von Bildgröße, Arbeitsmenge, Transfer- und Synchronisierungskosten, Hardwareunterstützung und Messungen. Kleine Histogramme oder Verwaltungsaufgaben können auf der CPU günstiger sein. Vermeide unnötiges Zurücklesen von GPU-Ergebnissen und doppelte Arbeit auf beiden Prozessoren.
- **Ein-/Ausgabe:** Überlappe unabhängige Datei- und Cache-Zugriffe mit Berechnungen, ohne Datenträger oder Speicher durch unbegrenzte Anfragen zu überlasten. Bevorzuge das aktuell ausgewählte Bild gegenüber Hintergrundvorschaubildern.
- **Fallback:** Erhalte nach Möglichkeit einen funktionsgleichen CPU-Pfad, wenn GPU-Beschleunigung nicht verfügbar ist. Falls kein gleichwertiger Verarbeitungspfad existiert, zeige einen verständlichen Fehler. Fehler dürfen weder Originalbilder noch gespeicherte Bearbeitungen beschädigen.

## Grenzen und Korrektheit

- Halte den `MainActor` für UI-Zustand und kurze UI-Aktionen frei. Dateizugriffe, RAW-Decodierung, Bildanalyse, Rendering, Datenbankarbeit und Backups gehören in geeignete Hintergrundausführung.
- Begrenze gleichzeitig laufende Arbeiten anhand von Speicherbedarf und verfügbaren Ressourcen. Starte nicht für jedes Foto gleichzeitig einen eigenen Task. Vermeide verschachtelte Worker-Pools und Überbelegung von CPU oder GPU.
- Nutze bestehende Vorschau-Caches, fasse identische Anfragen zusammen und verwende bereits decodierte Bildbasen erneut. Reglerbewegungen dürfen keine wiederholte RAW-Decodierung auslösen.
- Unterstütze Abbruch und fasse schnelle Änderungen zusammen. Veraltete Ergebnisse dürfen weder eine neuere Vorschau noch neuere gespeicherte Einstellungen ersetzen. Bereits angenommene Bearbeitungen, Transaktionen und Backups müssen trotz Abbruch einer Vorschau zuverlässig abgeschlossen oder kontrolliert zurückgerollt werden.
- Schütze gemeinsam veränderliche Daten durch klare Zuständigkeiten und Synchronisierung. SQLite-Schreibvorgänge, Revisionen, Wiederherstellungen und andere abhängige Zustandsänderungen müssen atomar und korrekt geordnet bleiben; erzwinge hier keine parallelen Writes.
- Originalbilder bleiben unverändert. Ergebnisse müssen bei identischen Eingaben reproduzierbar bleiben; Parallelität darf Bildqualität, Farbprofile, Transparenz oder Datensicherheit nicht beeinträchtigen.

## Prüfung relevanter Änderungen

- Prüfe neue Nebenläufigkeit auf Datenrennen, Abbruch, schnelle Bildwechsel, veraltete Ergebnisse, Speichergrenzen und Fehlerbehandlung.
- Vergleiche bei relevanten Performance-Änderungen repräsentative Arbeitslasten, einschließlich großer RAW-Vorschauen und schneller Regleränderungen. Berücksichtige Reaktionszeit, Durchsatz und maximalen Speicherverbrauch; messe kalte und warme Caches getrennt, wenn dies die Aussage beeinflusst.
- Prüfe CPU-/GPU-Alternativen auf gleichwertige Funktion und akzeptable Bildqualität. Behaupte Leistungsgewinne nur auf Grundlage passender Messungen und benenne deren Grenzen.
- Führe die für die Änderung geeigneten Tests aus. Vermeide zusätzliche Parallelisierung oder wiederholte Testläufe ohne nachvollziehbaren Nutzen.
