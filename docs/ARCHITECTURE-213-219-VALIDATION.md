# Abnahme der Architektur-Issues #213, #218 und #219

Stand: 25.10.2026; Ausgangspunkt ist der aktualisierte `main` bei `3f2dab5`.
Die in #224 ebenfalls genannten Bildalgorithmen #214–#217 wurden bereits durch
PR #225 abgeschlossen. Für #216 bleibt das dokumentierte Qualitäts-No-Go gültig;
dieser Auftrag ändert weder die Qualitätsgrenze noch den Produktstatus.
Die KI- und UI-Pakete #220–#223 sind eigene Arbeitspakete und nicht Teil dieses
Architekturabschlusses. Die übergeordnete Übersicht #224 bleibt deshalb offen.

## Umsetzung und Parallelisierung

- #213: sechs versionierte Entwicklungsbefehle, streng atomare numerische
  Patches, expliziter Foto-/Quell-/Epoch-/Generationskontext, gemeinsame Freigaben
  und begrenzte Deduplizierung. [Befehlsreferenz](DEVELOP-COMMANDS.md).
- #218: persönliche portable Teilvorgaben, vier auswählbare Gruppen, strikter
  JSON-Import/Export, asynchroner Dateispeicher sowie unverbindliche Vorschau und
  reguläre Annahme. [Format und Bedienung](DEVELOP-PRESETS.md).
- #219: eingefrorene Serienaufträge ohne Bilddecodes, dauerhafte Einzelfoto-
  Ergebnisse, Abbruchgrenze bei Annahme und pro Foto geprüfte Undo-Verfügbarkeit.
  [Ablauf und Grenzen](DEVELOP-TRANSFER.md).

Verträge, Speicherdienst, Dispatcher und Serienworkflow wurden parallel in
abgegrenzten Dateien bearbeitet und anschließend unabhängig sowie integriert
reviewt. Gemeinsame UI-/Editor-Eingriffe wurden koordiniert. Git-Zustand,
abhängige Zustandsannahmen und SQLite-Writes bleiben geordnet. Die kleine
synchrone Aufnahme der Ziel-Snapshotreferenzen bewahrt einen gemeinsamen
Capture-Zeitpunkt; die Vorprüfung gibt spätestens nach 32 Zielen die UI frei.
Die kurzen, atomaren MainActor-Annahmen enthalten keine Datei-I/O oder Bildarbeit.

## Automatisierte und native Prüfung

Der finale integrierte Lauf bestand mit **524 Tests in 71 Suites**:

```sh
./scripts/test.sh --skip-build --filter \
  '^(GlowroomCoreTests\.|GlowroomTests\.(DevelopCommandDispatcherTests|DevelopPresetStoreTests|EditingModelTests)/)'
```

Weitere **92 Tests in neun Suites** liefen jeweils in einem eigenen Prozess:
`DevelopPresetsModelTests` (6), `DevelopTransferTests` (10),
`AIDevelopmentModelTests` (23), `AIDevelopmentAcceptanceTests` (1 mit drei
Szenarien), `SliderPersistenceTests` (8), `DevelopSharpeningWorkspaceTests` (2),
`WorkspaceFocusRoutingTests` (9), `InlineMaskWorkspaceTests` (18) und
`WorkspaceProposalLifecycleTests` (15). Insgesamt sind das **616 Tests in
80 Suites** über diese getrennten Läufe. Vier bestehende optionale Core- bzw.
Unterprozessprüfungen wurden ausdrücklich übersprungen. Swift Testing zählt parametrisierte
Testfunktionen als einen Test, ihre einzelnen Fälle sind zusätzlich ausgeführt.

Geprüft sind unter anderem A→B→A, gleiche Settings nach Undo, Restore-Epoch,
Quellenwechsel, Read-only/Backup, ungültige/duplizierte Controls, NaN/Inf,
verdrängte Request-IDs, inkompatible Prozesse, Datei-/Speicherfehler, Abbruch vor
und nach Save-Annahme sowie die gegenseitige Zuständigkeit von KI- und
Vorgabenvorschauen. 300 synthetische Ziele prüfen geordnete Writes, Ergebnis-
zählungen und tatsächliche History-Verdrängung jenseits von 256 Zuständen.
Vorgaben erhalten die vorhandene Quelle, Masken, Retuschen, Geometrie, Kurven
und HDR-Ausgabe. Vorschau/Verwerfen verändern weder SQL-Stand noch History;
Annahme, Undo/Redo und Wiederöffnen werden über die vorhandene Persistenz geprüft.

Native Prüfungen erfassen eine 280-Punkte-Vorgabenpalette, Serien-Dialoge mit
420/560 Punkten, Accessibility-Aktionen, Reglerbedienung und die vorhandenen
Tastatur-/Masken-History-Regressionen aus #88. Das ist kein behaupteter manueller
VoiceOver-Durchlauf aller Kombinationen. Alle neuen Fixtures sind synthetisch;
private Testbilder und Modelle werden nicht vorausgesetzt oder verändert.
Es werden keine neuen Leistungsgewinne oder RAW-/GPU-Benchmarkergebnisse behauptet.

## Reviewkorrekturen und Vorläufe

Das unabhängige Review und die nativen Tests fanden und behoben:

- konkurrierende KI-/Vorgabenvorschauen, verspätete Veröffentlichungen und die
  erneute Prüfung des sichtbaren Vorschau-Besitzers nach Quellenvalidierung;
- fehlende automatische Sicherungsplanung nach der Serien-Commit-Sperre;
- eine zweite Serienannahme über zwei unterschiedliche Modelinstanzen;
- NaN-Nutzlastgleichheit für die Wiederholung bereits abgewiesener Befehle;
- fälschliche Erfolgsmeldungen bei gescheiterter Undo-/Reset-Annahme;
- überschreibende Accessibility-IDs am übergeordneten DisclosureGroup;
- begrenztes Lesen auch bei kurzen Datei-Reads und unzulässige Exportendungen;
- die vorhandene falsche README-Aussage einer unbegrenzten History.

Zwei anfängliche Testcompiles scheiterten an Actor-Isolation beziehungsweise an
während der Kompilierung weiterbearbeiteten Eingabedateien. Eine neue Testfixture
erwartete nach absichtlicher Revisionserschöpfung irrtümlich ein weiter verfügbares
Ziel; sie wurde korrigiert, ohne Produktgrenzen zu lockern. Der erste native
Palettenlauf deckte den oben behobenen Accessibility-Fehler auf. Die jeweiligen
finalen Wiederholungen bestanden. Das abschließende unabhängige Diffreview fand
keine weiteren konkreten offenen Befunde.

## Sauberer vollständiger Release-Build

Der Produktquellcode ist buildwirksam; ein Build-Verzicht ist nicht zulässig.
Der finale Build verwendet `GLOWROOM_BUILD_PATH=.build-app GLOWROOM_BUILD_JOBS=4
./scripts/build-app.sh`. Vorher wurden nach Prozessprüfung sämtliche generierten
Ergebnisse dieses Release-Verzeichnisses und `dist/Glowroom.app` entfernt.
`.build` ist der unabhängige Testpfad; daraus werden keine Release-Ergebnisse
übernommen. Netzwerkzugriff dient der Auflösung der festgelegten Pakete.

Ein früherer Release-Versuch wurde für die Accessibility-Korrektur abgebrochen.
Ein Neustart wurde zunächst durch dessen zurückgebliebene Sperre abgewiesen.
Nach erneutem Nachweis der Prozessruhe wurden ausschließlich diese inaktive
Sperre und der eigene generierte Stage entfernt.

Der endgültige vollständige Produktbuild bestand in **397,64 Sekunden**.
`Info.plist`-Validierung und die im Skript enthaltene strikte Signaturprüfung
bestanden; das Ergebnis liegt unter `dist/Glowroom.app`. Die verbleibenden
Compiler-/SwiftPM-Warnungen verhindern den erfolgreichen Build nicht. Der
geprüfte Produktquellcode wurde danach nicht mehr verändert.
