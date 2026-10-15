# Review: Bibliothek, Bearbeitung und Sicherungen

Stand: 16. Oktober 2026. Geprüft auf dem vorhandenen Apple-Silicon-Mac mit macOS 27 und den Apple Command Line Tools. Keine Behauptung einer vollständigen Fehlerfreiheit oder identischer Ergebnisse auf jeder Kamera/macOS-Version.

## Umfang

Review der Implementierung für Bibliothek und Ordnerbaum, RAW-Vorschauen, Tonwert/Präsenz/Entrauschen, Datenbank, Backup-/Recovery-Pfade, asynchrone Speicherung und Oberfläche. Datenbank, Renderer und Controller wurden parallel implementiert und anschließend zusätzlich auf ihre Schnittstellen zur Oberfläche geprüft.

## Gefundene und behobene praxisrelevante Fehler

- Zahleneingaben erzeugten zunächst einen Undo-Schritt pro gültigem Zahlenpräfix. Zusammenhängende Eingaben werden jetzt gruppiert; im App-Test führte Rückgängig direkt von 45 zum vorherigen Wert 3 zurück.
- Nicht abgeschlossene Zahlenfelder werden beim Bildwechsel, Sichern und Beenden vor der Zustandssperre übernommen.
- Ein ungültiges Backup darf eine gesunde Datenbank weder verändern noch den Editor dauerhaft sperren. Der bisherige Zustand wird geprüft und bleibt bearbeitbar.
- Eine beschädigte Datenbank ließ sich ursprünglich nicht über den normalen Restore-Pfad öffnen. Ein separater Recovery-Pfad validiert die Sicherung zuerst und erhält die beschädigte Datenbank samt Begleitdateien in einem Archiv.
- Selbst das Prüfen einer beschädigten SQLite-Datei kann Begleitdateien verändern. Die Recovery-Diagnose erfolgt deshalb an einer entbehrlichen Kopie; die archivierten Originaldateien bleiben bytegleich.
- Ältere oder widersprüchliche Schreibversionen werden als Konflikt gemeldet, statt dem Controller fälschlich erfolgreiches Speichern zu signalisieren.
- Backup-Export und Wiederherstellung werden als laufende Wartung behandelt. Beenden kann sie nicht unbemerkt unterbrechen; fehlgeschlagene Exporte erhalten das lokale Backup und das bisherige Ziel.
- Gescheiterte Schreibvorgänge zeigen ungespeicherte Änderungen mit einer Wiederholen-Aktion statt einer dauerhaft irreführenden Ladeanzeige.
- RAW-Kameravorschauen und entwickelte Bearbeitungsbasen verwenden getrennte Cache-Schlüssel. Bearbeitungsbasen werden verlustfrei gespeichert, damit erneutes Öffnen keine zusätzlichen JPEG-Artefakte in die Rauschbeurteilung einführt.
- Die tägliche Backup-Prüfung wird bei unveränderter Datei wiederverwendet; eine Regleränderung löst nicht ständig eine vollständige Integritätsprüfung aller Backup-Datensätze aus.
- Der native Speichern-Dialog ergänzt die Dateiendung selbst; der voreingestellte Name erhält keine doppelte `.sqlite`-Endung.

## Prüfung

- `./scripts/test.sh`: 84 erfolgreiche Tests (59 App-/Controller-/Renderer-/Cache-Tests, 25 Core-/Datenbanktests).
- `./scripts/test-image-pipeline.sh`: erfolgreich; Größenbegrenzung, EXIF-Orientierung, Cache, konkurrierende Anfragen, Abbrüche und defekte Eingaben.
- `./scripts/benchmark-library.sh`: erfolgreich mit 10.000 synthetischen Einträgen und Prüfsumme 473849. Misst Bibliotheksberechnungen, keine RAW-Decodierung.
- Release-App gebaut, Bundle validiert und lokal signiert.
- Separater synthetischer UI-Katalog: Tonwert, Präsenz, Entrauschen, Zahlenfelder, Undo/Redo, Bildwechsel, Neustart, Backup-Export und Wiederherstellung geprüft. Produktionsfotos wurden dabei nicht verändert.
- UI-Backup-Drill: nach der Sicherung eine zusätzliche Belichtungsänderung angelegt, Backup wiederhergestellt und aktive Datenbank, exportierte Sicherung sowie Sicherheitsbackup mit `integrity_check` geprüft. Wiederhergestellter Stand und vorherige Änderung im Sicherheitsbackup waren korrekt vorhanden.

## Bekannte Funktionsgrenzen

Die Verarbeitung betrifft derzeit Vorschauen bis 2400 Pixel langer Kante. Die Filter bieten klassische Bildkorrekturen, keine identische Adobe-RAW-Engine und kein KI-Entrauschen. Ein Vollauflösungsexport ist noch nicht implementiert. Die Backups enthalten Bearbeitungswerte; Originalbilder und der bestehende Bibliothekskatalog `catalog.json` müssen separat gesichert werden. Undo-Verläufe gelten für die Sitzung, aktuelle Reglerwerte werden dauerhaft gespeichert. Bearbeitungen sind an die vorhandenen pfadbasierten Bildkennungen gebunden.

## Ergänzung: Tonwert-Automatik

Die Automatik analysiert eine auf höchstens 256 Pixel lange Kante begrenzte, nach Transparenz gewichtete Vorschau. Eine monotone Tonwertkurve gleicht Schatten und Lichter aus, behält Schwarz und Weiß bei und verstärkt bei geringer Tonwertspreizung behutsam den Kontrast. Die Analyse erfolgt auf der unveränderten Bildbasis, die Korrektur vor den manuellen Tonwertreglern. Sie verwendet keine räumliche Maskierung, die Halos an Kanten erzeugen könnte.

Im Review wurde ein relevanter Sonderfall korrigiert: Eine kleine dunkle Fläche vor überwiegend hellem Hintergrund darf durch die Korrektur der mittleren Helligkeit nicht noch dunkler werden. Zusätzlich zu robusten Quantilen berücksichtigt die Analyse deshalb die dunklen und hellen Bildanteile; die Anker der Kurve schützen die jeweilige Korrekturrichtung. Umgekehrt gilt das für kleine helle Flächen in dunklen Bildern.

Ein zusätzlicher Farbtest fand neue Maximalwerte in zuvor nicht abgeschnittenen Farbkanälen stark gesättigter Motive beim Aufhellen. Die Farbkorrektur hält dafür einen kleinen Abstand zur Kanalgrenze; eine Regression prüft gesättigte rote, grüne und blaue Motive. Die bestehende Verarbeitung weiter Farbräume bleibt erhalten.

Die neue Einstellung wird nur bei fehlendem Feld als ausgeschaltet interpretiert. Alte Datenbanken und Backups bleiben lesbar, während ungültige oder unvollständige Datensätze weiter abgewiesen werden. Die Automatik ist Bestandteil von Cache-Identität, Undo/Redo, vollständigem Zurücksetzen und Sicherungen. Ein eigener Controller-Test prüft den Stärkeregler als zusammenhängenden Undo-Schritt, erhaltene manuelle Werte, Bildwechsel und Neustart. Separate Datenbanktests prüfen ältere Nutzdaten und die neue Einstellung über Neustart, Backup und Wiederherstellung.

Abschließende Prüfung: **102 Tests erfolgreich** (72 App-/Renderer-/Controller-Tests und 30 Core-/Datenbanktests), darunter 12 gezielte Tests der Automatik. Release-Build und Signaturprüfung erfolgreich. Im getrennten synthetischen UI-Katalog wurden Schalter, Stärke, Rückgängig, Bildwechsel und Vorher-Vergleich bedient; nach dem Neustart blieb die Stärke von 51 % erhalten und die korrigierte Vorschau wurde angezeigt.

Vollständig ausgebrannte Lichter oder vollständig schwarze Bildbereiche enthalten keine rekonstruierbare Zeichnung. Die Automatik kann vorhandene Tonwerte ausgleichen; starke nachfolgende manuelle Reglerwerte können weiterhin über- oder unterbelichten.
