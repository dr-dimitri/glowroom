# Abnahmeprotokoll zu Issue 45

18. Oktober 2026 · [Issue #45](https://github.com/dr-dimitri/picedit/issues/45) · Ausgangsoberfläche `fba0c9b`, native Einführung `162f6ae` / [PR #56](https://github.com/dr-dimitri/picedit/pull/56).

Die klassische Ansicht und der Bildfokus verwenden dieselben Werkzeuggruppen, Bildauswahl und Bearbeitungsmodelle. Die klassische Ansicht stellt Bibliothek und Werkzeuge neben dem Bild dar; Seitenleisten und Filmstreifen lassen sich unabhängig schließen und verändern. Der Bildfokus blendet die Bibliotheksköpfe aus, hält Navigation und Bildsteuerung beim Foto und öffnet Gruppen über das beschriftete Dock. Die Werkzeugseite beansprucht eigene Breite neben dem Motiv. Rückkehr, Export, Sicherungen und Status bleiben sichtbar. Die konkrete Bedienung steht unter [Bildfokus und Arbeitsbereiche](../../WORKSPACE-LAYOUT.md).

## Herkunft der Belege

| Beleg | Aussage und Grenze |
| --- | --- |
| [Historische Entwürfe](README.md), acht PNGs und `layout-measurements.json` | Beide Vorschläge offen/geschlossen, Funktionszuordnung und CSS-Geometrien bei 1000 × 660 und 1440 × 900. Keine Messung der nativen App. |
| Bedienvergleich unten | Kontrollierter Durchgang der tatsächlich vorhandenen Befehle anhand der nativen Implementierung und des Ausgangscodes. Keine Nutzerstudie, keine gemessene Bedienzeit und keine gezählten Scrollgesten. |
| `WorkspaceLayoutTests` | Getrennte Präferenzen, Neustart/Fokus-Rückkehr, Reset, Einzelgruppenmodus, beschädigte Daten und endliche Größenbegrenzungen. |
| `WorkspaceFocusRoutingTests` | Reine Routenauswahl für erreichbare Wiederöffnen-Schalter, Moduswechsel und fehlende Bildauswahl. Die tatsächliche native Tastatureingabe wurde gesondert manuell geprüft. |
| `WorkspaceProposalLifecycleTests` | Echte SwiftUI-Sections werden montiert und entfernt. Laufende/fertige Anfragen, Lookauswahl, Vergleich und Anweisung überstehen den Layoutwechsel; ausdrückliches Verwerfen und echte Auswahl-/Bearbeitungs-/Quellenwechsel entwerten Ergebnisse. Ein blockierter angenommener Speicherauftrag endet nach dem Verbergen der Sections und Einzelansicht. Ein tatsächlich montiertes Masken-Sheet erhält einen Zweipunktstrich über die normale API seines injizierten Modells; nativer Undo-Schalter, Dokument und Modellrevision bleiben beim Panel-, Fokus- und Rasterwechsel erhalten. Echte neue Quellen entwerten den alten Entwurf. Workspace-Befehle erhalten Mehrfachauswahl, Filter und Undo/Redo. |
| `PhotoMetadataModelTests` | Roher Tagtext einschließlich leerer Schlusszeilen übersteht Section-Wechsel. Neue Bild-/Quellen-/Entwurfsidentitäten werden neu zugeordnet; angenommene Speicheraufträge und spätere Antworten behalten ihre Kontextregeln. |
| `WorkspaceGeometryTests` und [native Messdaten](native/layout-measurements.json) | Erfolgreicher nativer Messlauf mit 24 Kombinationen aus drei Fenstergrößen, vier Panelzuständen und zwei Bildformaten. Die Bildgeometrie bleibt beim Vergrößern auch nach Paneländerungen gleich. Keine Zeit- oder Performanceaussage. |
| [Rekonstruierte Ausgangsgeometrie](native/baseline-layout-measurements.json) | Sechs Messungen der historischen äußeren Views mit heutiger gemeinsamer Bildpipeline. Bei angefragten 1000 Punkten verbreiterte deren intrinsische Mindestbreite das native Testfenster auf 1238 Punkte; nur 1440 und 1920 sind Vergleiche bei gleicher tatsächlicher Fenstergröße. |
| [Prüfbericht von PR #56](https://github.com/dr-dimitri/picedit/pull/56) | Sauberer Release-Build, geeignete Tests, unabhängige Reviews, native Renderings sowie manuelle Fokus-/Panel-/Belichtungs-/Metadaten-/Such-/Neustartprüfung mit synthetischen Fotos sind dokumentiert. Ein vollständiger manueller VoiceOver-Durchlauf wurde ausdrücklich nicht ausgeführt. |
| Manueller nativer Durchgang am 18. Oktober 2026, unten | Isolierte Release-App im normalen Fenster bei 1440 × 900, synthetische Bilder mit 1200 × 800 und 800 × 1200 Pixeln. Tatsächliche Bedienung mehrerer Kernabläufe; keine komplette Abnahme aller sieben Abläufe. |

Die ursprünglichen Snapshot-Fixtures von PR #56 verwendeten quadratische 1-Pixel-PNGs. Sie belegen die Montage der nativen Oberfläche, jedoch keinen Hoch-/Querformatvergleich oder eine gemessene sichtbare Bildgröße. Reale Modell-, Kamera-RAW- oder Cloudtests sind für die Layoutbefehle nicht erforderlich; dieses Protokoll behauptet dafür keine neuen Messergebnisse.

## Repräsentative Bedienwege

Start für den Vergleich: ausgewähltes Foto in der Einzelbildansicht, klassische Ansicht im Entwickeln-Modus mit sichtbaren Panels und geöffneter Gruppe **Bearbeiten**, Fokus mit geschlossenen Panels. Alle Bibliotheksfilter sind zunächst aus. Eine Zielaktivierung zählt als ein Klick; Menüwahl und Untermenüwahl werden einzeln gezählt. Tastatureingaben, Reglerbewegungen, Wartezeit einer Inferenz und Systemdateidialoge sind gesonderte Schritte. Bei den beiden neuen Ansichten ist der einmalige Eintritt in den jeweiligen Modus nicht mitgezählt. Die Ausgangsoberfläche startet wie im historischen Entwurf vor dem Eintritt in **Entwickeln**.

| Aufgabe | Ausgangsoberfläche `fba0c9b` | Klassische Ansicht | Bildfokus |
| --- | --- | --- | --- |
| Ordner wählen und auf mindestens vier Sterne filtern | Ordner, Bewertungsmenü, „Mindestens 4 Sterne“: 3 Ziele; Ordnerbaum ggf. scrollen. | Breite Steuerleiste: ebenfalls 3 Ziele. Kompakte Steuerleiste: Ordner, „Filter & Sortierung“, „Bewertung“, „Mindestens 4 Sterne“: 4 Ziele. | „Bibliothek“, Ordner, „Filter & Sortierung“, „Bewertung“, „Mindestens 4 Sterne“: 5 Ziele; bei offener Bibliothek 4. |
| Foto bewerten | Stern am Bild: 1 Ziel. | 1 Ziel; die Bewertungszeile bleibt ohne Filmstreifen. | 1 Ziel; die Bewertungszeile bleibt ohne Panels. |
| Belichtung ändern | „Entwickeln“ und danach zu den Reglern unter Assistent, Analyse, Metadaten und Bildständen scrollen; Wert ändern. | Tonwert steht in der ersten Gruppe bereit: 0 vorbereitende Ziele, Wert ändern. Falls geschlossen, Gruppe/Untergruppe öffnen. | „Bearbeiten“ im Dock: 1 vorbereitendes Ziel, Wert ändern. Der Sprung scrollt direkt zur Gruppe. |
| Look prüfen und übernehmen | „Entwickeln“, „Drei Looks erstellen“, Karte, Vergleichsmenü, „Vorschlag“, „Übernehmen“: bis zu 6 Ziele; Assistent ggf. scrollen. | Gruppensprung über Werkzeug-… und „Assistent & Looks“ oder Gruppenheader; dann Erstellen, Karte, ggf. Vergleich und Übernehmen. Bei bereits sichtbarem Header höchstens 6 Ziele einschließlich expliziter Vergleichswahl. | Dock „Assistent & Looks“, Erstellen, Karte, ggf. Vergleichsmenü und „Vorschlag“, Übernehmen: höchstens 6 Ziele. Inhalte/Lookkarten ggf. innerhalb der Gruppe scrollen. |
| Titel/Tags bearbeiten | Info-Inspector bzw. Entwickeln öffnen, Formular unter anderen Inhalten suchen, Texte ändern und ausdrücklich übernehmen. | Sichtbaren Header „Bildinformationen“ öffnen, Texte ändern, „Manuelle Angaben übernehmen“: 2 Ziele plus Eingabe. Ein direkter Sprung über Werkzeug-… kostet ein zusätzliches Ziel. | Dock „Informationen“, Texte ändern, „Manuelle Angaben übernehmen“: 2 Ziele plus Eingabe. Innerhalb des Formulars ggf. scrollen. |
| Gespeicherten Bildstand aktivieren und vergleichen | „Entwickeln“, zu den Bildständen scrollen, „Gespeicherte Bildstände“, Variante und Quellenvergleich wählen. | Gruppenheader oder direkter Gruppensprung, „Gespeicherte Bildstände“, Variante, Bildmenü „Vergleich“, Vergleich wählen: 5 Ziele bei sichtbarem Header, 6 über Werkzeug-…. | Dock „Bildstände“, „Gespeicherte Bildstände“, Variante, Bildmenü „Vergleich“, Vergleich wählen: 5 Ziele. |
| JPEG exportieren | Global „Exportieren“, danach Systemdialog „Exportieren“: 2 Ziele bei gemerktem Ziel. | Gleicher Einstieg und Dialog: 2 Ziele. | Gleicher Einstieg und Dialog: 2 Ziele; auch bei geschlossenen Panels. |

Der Vorschlagvergleich steht nach Erzeugung/Auswahl normalerweise bereits auf **Vorschlag**. Die Tabelle zählt die ausdrückliche erneute Vergleichswahl, damit der Prüfweg eindeutig bleibt. Die beiden Vergleichsmenüs gehören zu unterschiedlichen Zuständen: Der Assistent vergleicht eine unbestätigte Rezeptvorschau mit ihrer Ausgangsbearbeitung; das Menü beim Foto zeigt aktuelle Bearbeitung, importiertes Original oder aktive Quelle ohne Regler. Ein reiner Quellenvergleich benötigt in beiden neuen Ansichten zwei Ziele und keinen Wechsel des gespeicherten Bildstands. Ein Quellenwechsel ist eine rückgängig machbare Bearbeitung. Der Export verwendet angenommene Werte.

Die fachliche Gruppierung verkürzt insbesondere den Weg zur Belichtung und ermöglicht direkte Sprünge zu langen Gruppen. Kompakte Bibliotheksmenüs benötigen zusätzliche Menüwahlen. Innerhalb von Lookkarten, Metadatenformularen oder langen Variantenlisten bleibt Scrollen abhängig vom Inhalt und der Fensterhöhe erforderlich. Daraus wird kein gemessener Zeitgewinn abgeleitet.

## Manueller nativer Durchgang am 18. Oktober 2026

Geprüft wurde eine isolierte Release-App mit eigenem synthetischem Katalog im normalen Fenster bei 1440 × 900. Die beiden PNGs haben 1200 × 800 beziehungsweise 800 × 1200 Pixel. Die Prüfung verwendete die sichtbaren nativen Bedienelemente und deren Accessibility-Informationen.

| Ablauf | Tatsächliche Beobachtung |
| --- | --- |
| Ordner und Filter | In der klassischen Ansicht den Ordner angeklickt und den Bewertungsfilter auf mindestens vier Sterne gestellt. |
| Bewerten | Ein Foto auf fünf Sterne gesetzt. |
| Belichtung | Das Zahlenfeld mit `1` bedient; es zeigte anschließend `1.00`. Der Wert blieb beim anschließenden Eintritt in den Bildfokus erhalten. |
| Metadatenentwurf | Titel „Layoutprüfung“ und die beiden Tags „Landschaft“/„Test“ eingegeben. Der rohe Tagtext mit zwei abschließenden Zeilenumbrüchen überstand zweimaliges Schalten der Werkzeuge mit ⌘I. Danach „Manuelle Angaben übernehmen“ ausdrücklich betätigt. |
| Bildfokus | Bildfokus geöffnet; Dock und Gruppen waren erreichbar. Die gespeicherte Belichtung blieb sichtbar erhalten. |
| Bemalte Maske | Im tatsächlichen nativen Maskeneditor des Hochformats einen Strich per Maus gezogen; „Rückgängig“ wurde aktiv. Bei weiterhin offenem Sheet mit ⇧⌘F von klassisch in den Fokus gewechselt und mit ⌘I die Werkzeuge verborgen. Das Sheet blieb mit aktivem Undo erhalten. Ausdrücklich „Entwurf verwerfen und schließen“ gewählt; darunter war der ausgeführte Bildfokus mit geschlossenen Werkzeugen sichtbar. |
| Vergleich und JPEG | Im Bildfokus den Originalvergleich bedient und tatsächlich ein JPEG exportiert. `sips` bestätigte für „Hochformat-bearbeitet.jpg“ 800 × 1200 Pixel. |
| Rückfokus nach Korrektur | Der erste Durchgang ließ den Fokus nach ⌘I im Suchfeld. Die erneute Prüfung der korrigierten Release-App bestand: Im Bildfokus führte ⌘I zum Dock-Schalter „Bearbeiten“, Leertaste öffnete den Inspector erneut; Tab wechselte normal durch Felder. In der klassischen Ansicht führte ⌘I zum Schalter „Werkzeuge“, Leertaste öffnete ihn erneut, ⌥⌘L führte zum Schalter „Bibliothek“. |
| Neustart | Bildfokus, Panelzustände und Belichtung `1.00` wurden wiederhergestellt. Der Metadatenbereich zeigte zunächst einen Ladefehler. Die bestätigten Angaben „Layoutprüfung“, „Landschaft“ und „Test“ lagen mit Revision 1 in SQLite vor und wurden über die Wiederholungsaktion erfolgreich geladen. Dieser unabhängige Start-/Ladefehler ist als [Issue #66](https://github.com/dr-dimitri/picedit/issues/66) erfasst; es wurde kein Verlust der gespeicherten Angaben beobachtet. |

Eine tatsächliche lokale Look-Inferenz mit anschließender Annahme, ein vollständiger manueller Wechsel gespeicherter Varianten sowie ein vollständiger VoiceOver-Durchlauf sind damit nicht nachgewiesen. Der Versuch, VoiceOver über eine an die Test-App gesendete Tastenkombination zu starten, startete keinen VoiceOver-Prozess und gilt nicht als VoiceOver-Prüfung. Die synthetischen Provider in den Integrationstests prüfen die betreffenden Zustandsverträge unabhängig von einem installierten Modell.

## Native Geometrie

Der opt-in-Test `WorkspaceGeometryTests` rendert die echte SwiftUI-Hauptansicht in isolierten nativen Fenstern bei 1000 × 660, 1440 × 900 und 1920 × 1080. Alle Zustände verwenden dieselben synthetischen PNGs mit 1200 × 800 beziehungsweise 800 × 1200 Pixeln. Die Größen sind Punkte des Fensterinhalts, ohne macOS-Menüleiste, Fenstertitel und Schatten. Das JSON hält angefragte Größen in `requestedWindowWidth`/`requestedWindowHeight` und tatsächliche Größen in `windowWidth`/`windowHeight` getrennt fest; der aktuelle Test prüft zusätzlich deren Gleichheit. „Viewport“ ist die gesamte Canvas vor den inneren Abständen; „Bild“ ist der tatsächlich eingepasste Bildrahmen einschließlich nativer Rundung. Eine passive optionale Beobachterfunktion am vorhandenen `GeometryReader` liefert die Canvas-Größe; der Bildrahmen wird aus dem nativen Accessibility-Element gelesen. Im normalen Betrieb ist kein Beobachter gesetzt.

Der erste Offscreen-Versuch ohne aktivierte Prozess-Accessibility und die anfängliche Verwendung des AX-Gruppenrahmens lieferten keine gültige Canvas-Messung: AX-Gruppen beschreiben nur die Vereinigung ihrer Kinder und lassen leere Bildränder aus. Die vorliegenden JSON-Protokolle stammen aus den korrigierten erfolgreichen Läufen: [24 aktuelle Messungen](native/layout-measurements.json) und [sechs historische Rekonstruktionsmessungen](native/baseline-layout-measurements.json). Der Test prüft positive Größen, erhaltenes Seitenverhältnis und Einpassung innerhalb der Canvas. Die Läufe bestanden in 11,127 beziehungsweise 4,543 Sekunden; das sind Testlaufzeiten und kein Performancevergleich.

| Fensterinhalt | Zustand | Viewport | Bild 3:2 | Bild 2:3 |
| --- | --- | --- | --- | --- |
| 1000 × 660 angefragt, **1238 × 660 tatsächlich** | Ausgangsgeometrie rekonstruiert | 718 × 195 | 262,5 × 175 | 117 × 175 |
| 1000 × 660 | Klassisch offen | 448 × 240 | 330 × 220 | 147 × 220 |
| 1000 × 660 | Klassisch geschlossen | 1000 × 305 | 427,5 × 285 | 190 × 285 |
| 1000 × 660 | Fokus, Werkzeuge offen | 673 × 437 | 623 × 415 | 278 × 417 |
| 1000 × 660 | Fokus geschlossen | 1000 × 437 | 625,5 × 417 | 278 × 417 |
| 1440 × 900 | Ausgangsgeometrie rekonstruiert | 920 × 435 | 622,5 × 415 | 277 × 415 |
| 1440 × 900 | Klassisch offen | 888 × 440 | 630 × 420 | 280 × 420 |
| 1440 × 900 | Klassisch geschlossen | 1440 × 545 | 787,5 × 525 | 350 × 525 |
| 1440 × 900 | Fokus, Werkzeuge offen | 1113 × 677 | 985,5 × 657 | 438 × 657 |
| 1440 × 900 | Fokus geschlossen | 1440 × 677 | 985,5 × 657 | 438 × 657 |
| 1920 × 1080 | Ausgangsgeometrie rekonstruiert | 1400 × 615 | 892,5 × 595 | 397 × 595 |
| 1920 × 1080 | Klassisch offen | 1368 × 620 | 900 × 600 | 400 × 600 |
| 1920 × 1080 | Klassisch geschlossen | 1920 × 725 | 1057,5 × 705 | 470 × 705 |
| 1920 × 1080 | Fokus, Werkzeuge offen | 1593 × 857 | 1255,5 × 837 | 558 × 837 |
| 1920 × 1080 | Fokus geschlossen | 1920 × 857 | 1255,5 × 837 | 558 × 837 |

„Klassisch offen“ zeigt beide Seitenleisten und Filmstreifen; „Klassisch geschlossen“ blendet diese aus. Im Fokus sind Bibliothek und Filmstreifen in beiden Zuständen geschlossen; „Werkzeuge offen“ öffnet ausschließlich die Werkzeugseite. Die zusätzliche Breite wird tatsächlich zur Canvas. Ein höhenbegrenztes Bild wächst dadurch allein nicht weiter: Bei 1440 × 900 ist es im Fokus mit offener und geschlossener Werkzeugseite gleich groß.

Die rekonstruierte alte Ansicht verbreiterte das angefragte 1000-Punkte-Fenster durch ihre intrinsische Mindestbreite tatsächlich auf 1238 Punkte. Das zugehörige PNG hat bei Skalierung 2 exakt 2476 × 1320 Pixel. Dieser Ausgangswert gehört deshalb ausdrücklich **nicht** in einen Vergleich bei identischer tatsächlicher Fenstergröße. Die neue klassische Ansicht bleibt bei tatsächlichen 1000 × 660. Bei 1440 × 900 und 1920 × 1080 stimmen angefragte und tatsächliche Größen in beiden Läufen überein. Dort erhält die geöffnete neue klassische Ansicht fünf zusätzliche Punkte Canvas-Höhe bei etwas breiterer Werkzeugseite; geschlossene Panels und Bildfokus nutzen weitere freie Fläche. Bei identischen 1440 × 900 wächst das eingepasste Querformat von 622,5 × 415 in der Ausgangsrekonstruktion auf 985,5 × 657 im geschlossenen Fokus, Hochformat von 277 × 415 auf 438 × 657. Dies sind gemessene Geometrien dieser synthetischen Bilder, keine allgemeine Prozent- oder Leistungszusage.

Native Beispiele: [Ausgangsrekonstruktion bei angefragter Mindestgröße](native/baseline-1000.png), [klassisch bei tatsächlicher Mindestgröße](native/classic-open-1000.png), [Fokus bei Mindestgröße](native/focus-closed-1000.png), [Hochformat Ausgangsrekonstruktion](native/baseline-1440-portrait.png), [Hochformat klassisch](native/classic-open-1440-portrait.png), [Hochformat im Fokus](native/focus-closed-1440-portrait.png). Diese Bilder stammen aus nativen Testfenstern und sind unabhängig von den historischen CSS-Mockups.

Reproduktion aus dem aktuellen Checkout, Ausgabe in ein neues Verzeichnis:

```sh
PICEDIT_WORKSPACE_MEASUREMENTS=/absoluter/ausgabeordner ./scripts/test.sh --jobs 4 --filter WorkspaceGeometryTests
python3 tools/workspace-layout/measure-baseline.py /absoluter/baselineordner --jobs 4
```

Der erste Befehl verwendet den normalen Test-Buildpfad; einen dort aktiven Build oder Test zuerst beenden oder einen getrennten `PICEDIT_TEST_BUILD_PATH` wählen. Der zweite Befehl erstellt ein temporäres Projekt mit eigenem Buildpfad und rekonstruiert die historische äußere `LibraryView`-/`PhotoGridView`-Anordnung von `fba0c9b` mit denselben Bildern und demselben heutigen Bild-/Modellpfad. Es werden Typnamen, passive Messbeobachtung und Accessibility-Markierungen angepasst; der aktuelle gemeinsame Inspector und die Bildpipeline bleiben erhalten. Dieser Aufbau misst die damalige äußere Geometrie unter denselben Testbedingungen, keine unveränderte historische App oder deren Laufzeit. Die Zustände bleiben wegen des gemeinsamen MainActor-Fensterzustands geordnet; unabhängige Buildverzeichnisse erlauben parallele historische und aktuelle Läufe.

## Prüfung und verbleibende Grenzen

Die funktionalen Tests prüfen Zustandsübergänge und reale View-Lebenszyklen, ohne die gesamte View-Anordnung in Tests nachzubilden. Layoutpräferenzen bleiben kurze, geordnete MainActor-Änderungen; zusätzliche Worker wären für diese kleinen Zustandsänderungen teurer als die Arbeit selbst. Rendering, Cache-Ein-/Ausgabe und angenommene Speicherung verwenden die vorhandenen Hintergrundpfade.

Die Maskenintegration öffnet das echte native Sheet über dessen Accessibility-Schalter und prüft seinen aktivierten Undo-Schalter sowie den erhaltenen Dokument-/Revisionszustand nach dem Zweipunktstrich. Der Test setzt dazu das Modell derselben montierten `MaskCanvasView`; im normalen App-Aufruf besitzt der Editor weiterhin sein eigenes Modell. Das vermeidet simulierte globale Mausereignisse und eine Aktivierung der Test-App. Die inaktiven Testfenster können den nativen Tastaturfokus nicht zuverlässig besitzen; dafür werden reine Routenauswahltests und die oben dokumentierten tatsächlichen manuellen Tastatureingaben verwendet.

Die Einführung in PR #56 dokumentiert einen manuellen Durchgang für Fokus/Rückkehr, Panelwechsel, Belichtung, Metadaten mit Tag-Leerzeilen, erfolglose Suche und Neustart/Wiederherstellung. Der aktuelle manuelle Durchgang ergänzt die oben einzeln genannten Beobachtungen an beiden Bildformaten. Die vollständigen sieben Abläufe in der Vergleichstabelle sind als überprüfbarer Befehlsdurchgang dokumentiert; sie sind keine nachträgliche Behauptung einer manuellen Komplettabnahme beider Oberflächen.

Zugängliche Namen, Gruppenstatus, Größenaktionen und Fokusziele sind implementiert. Ein vollständiger manueller VoiceOver-Durchlauf einschließlich Tab-Reihenfolge, Rückfokus nach dem Schließen jeder Panelart und aller sieben Abläufe bleibt offen. Ein solcher Durchlauf muss in einer sichtbaren App durchgeführt und mit macOS-/VoiceOver-Version protokolliert werden. Native Geometrien und funktionale Tests ersetzen diesen Nachweis nicht.

Build- und Testergebnisse des aktuellen Änderungsstands gehören in dessen Pull Request. Historische erfolgreiche Prüfungen gelten ausschließlich für die jeweils genannten Commits. Dieses Protokoll hält offene manuelle Nachweise sichtbar und macht keine Leistungsversprechen.
