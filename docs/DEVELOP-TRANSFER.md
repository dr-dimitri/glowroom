# Ausgewählte Entwicklungseinstellungen übertragen (#219)

Unter **Entwickeln → Entwicklungsvorgaben** stehen **Einstellungen kopieren** und
**Auf ausgewählte Fotos übertragen …** bereit. Ohne vorheriges Kopieren dient
das aktive Foto als Quelle. Kopieren hält die vier portablen Einstellungsgruppen
des aktiven Fotos im Arbeitsspeicher fest; der folgende Übertragungsdialog nennt
dieses Quellfoto ausdrücklich. Ein späterer Foto- oder Reglerwechsel verändert
die kopierten Werte nicht. Erneutes Kopieren ersetzt sie. Der Kopierpuffer endet
mit dem App-Neustart und enthält keine Pixel oder Modelle.

Der Dialog friert die übrigen ausgewählten Fotos und ihre Bearbeitungsstände
beim Öffnen ein. Er zeigt Quelle, Zielanzahl sowie **Licht**, **Tonwertkorrektur**, **Farbe**
und **Details**. Gruppen können bis zur Übernahme abgewählt werden. Es gilt exakt
der Teil-Patch aus [Entwicklungsvorgaben](DEVELOP-PRESETS.md). Zuschnitt, Optik,
Masken, Reparaturen, Punktkurven, Bildquellen und HDR-/Ausgabemodi bleiben erhalten.
Die Prozessversion des Zielfotos wird niemals übernommen oder still aktualisiert;
inkompatible Ziele werden ausgewiesen und übersprungen.

Die Quellen-Eingabe wird vor der Aufnahme des Patches abgeschlossen. Der aktive
Masken-, Zuschnitt- oder Reparaturentwurf und die Vergleichsansicht sperren die
Aktionen über dieselbe Freigabe wie [Entwicklungsbefehle](DEVELOP-COMMANDS.md).
Zielauswahl und kopierter Patch bleiben danach unabhängig von der sichtbaren
Auswahl. Das Quellfoto wird nicht in seine eigene Zielmenge aufgenommen.

## Speichern, Abbrechen und Rückgängig

Übernehmen prüft unmittelbar vor jedem Einzelfoto-Commit erneut Katalogquelle,
Store-Epoch, Editor-Sitzung, lokalen Revisionszähler und vollständigen Snapshot.
Eine zwischenzeitliche Bearbeitung bleibt erhalten; dieses Ziel wird konkret als
übersprungen gemeldet. Ein wirkungsloser Patch erzeugt weder Revision noch Undo.
Backup, Wiederherstellung und Schreibschutz gelten auch für Serienaufträge.

Die Ergebnisliste trennt **übernommen**, **unverändert**, **übersprungen**,
**fehlgeschlagen** und **abgebrochen**. Übernommen bedeutet, dass der exakte
Einzelfoto-Stand dauerhaft vom vorhandenen Repository bestätigt wurde. Bei einem
Speicherfehler gelten die vorhandenen Wiederholungs-/Schreibschutzregeln; ein
ungesicherter Stand wird niemals als dauerhafter Erfolg gezählt. Bereits im
Speicher angenommene Werte bleiben für die reguläre Speicherwiederholung erhalten.
Die Serie ist keine gemeinsame Datenbanktransaktion.

**Abbrechen** beendet die noch nicht angenommenen Zielaufträge. Ein bereits
angenommener Speichervorgang wird durch einen Abbruch oder einen abgebrochenen
Beobachter nicht beendet. Dauerhaft gespeicherte Einzelfoto-Ergebnisse bleiben
bestehen; es gibt keinen stillen Serien-Rollback und keine automatische
Synchronisation späterer Reglerbewegungen. Pro Editor läuft höchstens ein Auftrag.

Die Übernahme gehört zur Funktion **Entwickeln / adjustments**. Der Dialog zeigt
den dafür nötigen Wechsel aus einer bisherigen Masken-, Zuschnitt- oder
Reparatur-History vor dem Start. Rückgängig ist pro Foto verfügbar, solange genau
dieser Schritt noch die letzte Bearbeitung in derselben Funktion ist. Weitere
Bearbeitungen, ein echter Funktionswechsel, Wiederherstellung oder Verdrängung
durch das gemeinsame History-Budget von **64 MiB / 256 Zuständen** beenden diese
Verfügbarkeit. Die Ergebnisliste prüft sie laufend und bietet dann kein falsches
Undo an. Für große Serien bietet der Dialog vor dem Start die vorhandene
Sicherungsfunktion an. Ein dauerhaft garantiertes Serien-Undo ist nicht enthalten.

## Ausführung und Grenzen

Es werden ausschließlich Settings und Metadaten verarbeitet: keine RAW-Decodes,
Dateikopien, Originalzugriffe oder Modellinitialisierungen. Die notwendige kurze
synchrone Aufnahme der Snapshot-Referenzen bildet einen gemeinsamen Capture-
Zeitpunkt. Anschließende Vorprüfung erfolgt in Portionen mit höchstens 32 Zielen
zwischen kooperativen Übergaben an die UI. Es gibt keine Aufgabe pro Foto und
keinen zusätzlichen Workerpool. Pro Dialog sind maximal **10.000 Zielfotos**
zulässig; größere Auswahlen werden ausdrücklich abgewiesen.

Abhängige Repository-Schreibvorgänge bleiben geordnet. Während eines konkreten
Einzelfoto-Commits schützt die vorhandene Commit-Sperre den angenommenen Stand
vor Überschreiben durch eine spätere lokale Eingabe. Zwischen den Commits bleibt
die UI-Ausführung frei. Abgearbeitete eingefrorene Snapshots werden sofort
freigegeben; die Ergebnisliste speichert nur kleine Revisionsbelege und umgeht
das History-Budget nicht. Ergebniszähler werden mit konstantem Aufwand gepflegt.
Die normale automatische Sicherung wird nach dem Auftrag wieder eingeplant.

## Reproduzierbare Prüfung

`DevelopTransferTests` prüft synthetisch selektive Übernahme, unveränderte Ziele,
eingefrorene Quelle, Zielkonflikt, Versions-/Quellensperren, Restore-Epoch,
Abbruch vor und nach Annahme, abgebrochene Beobachter, Speicherfehler und
Neustart aus dem gespeicherten Zustand. Ein Auftrag mit **300 Zielen** prüft
serielle Writes, korrekte Ergebniszählung und tatsächliche Undo-Verdrängung über
256 Zustände. Die verwendeten Fakes unterstützen keinen Bilddecode-Pfad.
Native Accessibility-Prüfungen prüfen sichtbare Aktionen, History-Warnung und
Annahme bei 420 und 560 Punkten Dialogbreite. Sie ersetzen keinen behaupteten
vollständigen manuellen VoiceOver-Durchlauf. Alle Daten sind synthetisch; private
Testbilder werden weder vorausgesetzt noch verändert.
