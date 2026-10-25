# Entwicklungsbefehle (Schema 1)

`GlowroomCore/DevelopCommands.swift` definiert den UI-unabhängigen,
`Sendable`-Befehlskatalog. `DevelopCommandDispatcher` im App-Target nutzt den
vorhandenen Editor, seine Freigaben, Undo-Historie, Schreibzulassungen und
Speicherworker. Ein zweiter Katalog oder Renderpool wird nicht angelegt.

| ID | Eingabe | Ergebnis | Änderung |
| --- | --- | --- | --- |
| `develop.get` | explizites Ziel | Entwicklungsstand und neues Ziel | nein |
| `develop.controls` | explizites Ziel | numerische Controls mit Grenzen | nein |
| `develop.patch` | Ziel und absolute Werte | Stand und Ergebniskennung | ja |
| `develop.undo` | Ziel | Stand und Ergebniskennung | ja |
| `develop.redo` | Ziel | Stand und Ergebniskennung | ja |
| `develop.reset` | Ziel | Stand und Ergebniskennung | ja |

Der maschinenlesbare Katalog enthält Schema-Version, stabile ID,
lokalisierbaren Bezeichnungsschlüssel, Argument-/Ergebnistyp,
Änderungskennzeichen und strukturierten Freigabegrund. Die Grenzen der
numerischen Controls stammen ausschließlich aus `EditParameter`. Temperatur,
Profile, Masken, Kurven und Geometrie werden im ersten numerischen Patchschema
nicht als unterstützt ausgewiesen. Ihre typisierten Adapter behalten ihre
bisherigen Fähigkeiten; Vorgaben nutzen dieselbe Zustandsprüfung und Freigabe.

Ein Ziel wird vom Dispatcher ausgegeben und enthält Asset, aufgelöste Quelle,
Settings, lokalen Revisionsstand, Store-Epoch sowie Editier-/Auswahlgenerationen.
Der Commit prüft es erneut. Damit sind A→B→A, gleiche Werte nach Undo,
Quellenwechsel und Wiederherstellung keine Freigabe für einen alten Auftrag.
Automatisches dauerhaftes Speichern bereits angenommener Settings darf dagegen
die SQL-Revision fortschreiben, ohne einen aktuellen Auftrag zu entwerten.

`DevelopNumericPatch` hält Werte als Liste: unbekannte oder doppelte Controls,
NaN/Inf und Bereichsverletzungen werden atomar abgewiesen. Es gibt weder
Klemmen noch Teilannahme. Eine leere oder wirkungslose Korrektur erzeugt keinen
Undo-Schritt. Native numerische Regler und reguläre globale KI-Korrekturen
verwenden den Dispatcher; ein Sliderdrag bleibt über die vorhandene
Editiergruppe ein gemeinsamer Undo-Schritt. Menüs verwenden weiterhin die
zuständige Workspace-Historie, insbesondere werkzeuglokales Masken-Undo.

`preview` validiert Quelle und unveränderten Kontext ohne Schreibwirkung.
Datei-Metadatenprüfung läuft im Hintergrund. Vorschau und eventuelles Rendering
bleiben vom synchronen `execute`/`applySettings` getrennt: unmittelbar vor der
Annahme erfolgen Kontext- und Freigabeprüfung erneut. Ein abgebrochener oder
veralteter Vorschauauftrag darf nicht automatisch zum Commit werden.
Nach synchroner Annahme gehören Save und Fehlerbehandlung dem bestehenden
Editor; ein Aufruferabbruch nimmt diese Zulassung nicht zurück. Ein erfolgreiches
Befehlsergebnis bezeichnet Annahme, nicht bereits bestätigte Speicherung auf
Datenträger; diese meldet die vorhandene Speicherstatusanzeige.

Anforderungskennungen bestehen aus App-Sitzungs-UUID und monoton wachsender,
positiver Sequenznummer. Die Sitzung wird vom Dispatcher ausgegeben. Der
Dispatcher hält höchstens 256 abgeschlossene Ergebnisse und konservativ
höchstens 64 MiB referenzierte Kontexte; große Masken-/Retuschekontexte können
früher verdrängt werden. Identische Wiederholung liefert dieselbe
Ergebniskennung, andere Nutzlast unter derselben Kennung einen Konflikt.
Verdrängte oder übersprungene Sequenznummern unter dem Höchststand und Kennungen
früherer App-Sitzungen liefern „Ausgang unbekannt – Zustand erneut prüfen“.
Sie werden niemals erneut ausgeführt. Es gibt kein dauerhaftes Journal und
keine Zusage zur Wiederholung über einen App-Neustart hinweg.

Die Vertrags- und Dispatcher-Tests verwenden synthetische Kataloge ohne Modelle
oder private Fotos. Sie prüfen Katalog/Ranges, atomare Validierung, begrenzte
Deduplizierung, UI-/Direktpfad, gruppiertes Undo, Auswahl-/Editkonflikte,
Werkzeug-/Vergleichs-/Eingabesperren sowie verspätete und abgebrochene Vorschau.
