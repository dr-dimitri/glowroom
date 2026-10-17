# Bildfokus und Arbeitsbereiche

Vorschlag B aus [Issue #45](https://github.com/dr-dimitri/picedit/issues/45) ergänzt die bestehende Bibliothek um einen Bildfokus mit festem Werkzeugdock. Er teilt die Bearbeitungsmodelle und den gruppierten Entwickeln-Inspector mit der normalen Ansicht. Es gibt keine zweite Bearbeitungsengine und keine automatischen KI-Anfragen durch Layoutaktionen.

## Bedienung und Zuständigkeiten

`WorkspaceLayoutModel` gehört zur App, außerhalb des nach Bild-ID erneuerten View-Unterbaums. `WorkspacePanels` speichert Sichtbarkeit, bevorzugte Breiten, Filmstreifenhöhe, offene Gruppen/Untergruppen und den optionalen Einzelgruppenmodus. Bibliothek, Entwickeln und Fokus besitzen getrennte Präferenzen. Versionierte Daten unter `workspace.layout.v1` in `UserDefaults` werden defensiv geladen; beschädigte oder unbekannte Angaben verwenden Standardwerte. Zahlen werden auf endliche, sinnvolle Bereiche begrenzt.

Beim Eintritt in den Fokus werden der bisherige Arbeitsmodus und Raster-/Einzelbildzustand als `WorkspaceFocusOrigin` erfasst. Normale Panelpräferenzen werden dabei nicht verändert. Rückkehr stellt den Ursprung wieder her; Änderungen an den Fokuspanels bleiben für den nächsten Fokus erhalten. Fokuszustand und Ursprung überstehen einen Neustart. Der Rückweg bleibt auch ohne ausgewähltes Foto sichtbar. Ein ausdrücklicher Rasterwechsel beendet den Fokus. Auswahl und fachliche Modelle werden durch diese Befehle nicht verändert.

`WorkspaceActions` fasst die Befehle für Fenster, Dock und Menü zusammen. Vor dem Verbergen von Zahleneingaben wird der aktive Feldeditor abgeschlossen, damit zusammenhängende Undo-Gesten ordentlich enden. Vorhandene Vorschläge und angenommene Speicheraufträge bleiben davon unabhängig. `WorkspaceViewCommands` bindet die Tastenkürzel ausschließlich im App-Menü; das identische Fenstermenü registriert sie nicht nochmals.

| Aktion | Bedienweg |
| --- | --- |
| Bildfokus / Rückkehr | Sichtbare Schaltfläche, Darstellung, ⇧⌘F |
| Bibliothek schalten | Dock, Ansicht/Darstellung, ⌥⌘L |
| Werkzeuge schalten | Schließen, Ansicht/Darstellung, ⌘I |
| Filmstreifen schalten | Dock, Ansicht/Darstellung, ⌥⌘S |
| Gruppe direkt öffnen | Dock, Werkzeug-… oder Darstellung |
| Darstellung zurücksetzen | Ansicht/Darstellung → Standardansicht wiederherstellen |

Navigation, Bewertungen, Favorit und Export behalten ihre vorhandenen Tastaturpfade. Layoutbefehle benötigen Modifikatoren; Textfelder und Regler werden nicht durch einfache Buchstaben umgeschaltet. Der lokale Navigationsmonitor überlässt Text-/Control-Fokus seine normale Bedienung. Gruppenheader haben Namen, Zustand und Hinweistexte; nach dem Einklappen bleibt der Fokus am Header. Nach dem Verbergen der Werkzeugseite gibt es sichtbare Fokusziele in der Fensterleiste und im Dock. Größen-Griffe unterstützen auch zugängliche Inkrement-/Dekrementaktionen.

## Entwürfe und Vorschläge

- `AIAssistantModel` und `ImageAnalysisModel` besitzen laufende Anfragen und Ergebnisse. Das Entfernen einer Section aus dem View-Baum verwirft sie nicht. Ein-/Ausblenden prüft eine bereits bekannte Verfügbarkeit nicht erneut und erzeugt keine Inferenz.
- Unveränderte Bearbeitungs-Snapshots erhalten Lookauswahl, Vergleich, Anweisung und Ergebnis. Echte Auswahl-/Quellen-/Bearbeitungswechsel sowie Wartung und explizites Verwerfen behalten ihre vorhandenen Invalidierungsregeln.
- `PhotoMetadataModel` besitzt neben normalisierten Feldern auch den rohen Tagtext beider Formulare. Dadurch bleiben beispielsweise abschließende Leerzeilen beim Einklappen erhalten. Rohtext wird bei einem echten Bild-/Quellen- oder KI-Entwurfswechsel neu zugeordnet. Angenommene Writes, Retry und Revisionen verwenden weiterhin die bisherigen geordneten Speicherpfade.
- Der Maskeneditor bleibt ein eigenes Sheet. Panels und Werkzeuggruppen beenden ihn nicht. Sein ausdrückliches Schließen bzw. ein tatsächlicher Bild-/Quellenwechsel behält die bisherigen Regeln für den lokalen Maskenentwurf.
- Statusleiste und Gruppenheader kennzeichnen Aufgaben, Vorschläge, Entwürfe und Fehler mit Text/Symbolen. Hinweise führen zur betroffenen Gruppe. **Fehler prüfen** öffnet die Fehlermeldungen und Wiederholungsaktionen mit einem Klick, unabhängig von ausgewähltem Foto und Panels. Auch dort bleiben die Sprünge zu anderen laufenden Aufgaben und offenen Entwürfen erhalten; Werkzeugsprünge benötigen ein ausgewähltes Foto. Vergleichsanzeigen wechseln keine gespeicherte Quelle; Export verwendet angenommene Werte.

## Geometrie und Ausführung

Die Canvas erhält die nach Ein-/Ausblenden tatsächlich freie Fläche. Bevorzugte Seitenbreiten werden für das aktuelle Fenster begrenzt, ohne die gespeicherten Wünsche zu überschreiben; mindestens 320 pt Bildbreite werden reserviert. Die Filmstreifenbegrenzung zieht Bildkopf, Bewertung und Größen-Griff ab und reserviert 240 pt Bildhöhe, soweit die übrige Fenstergeometrie diese zulässt. Bibliothek im Fokus schaltet die kompakte Suchzeile mit **Filter & Sortierung** wieder zu. In schmalen normalen Arbeitsbereichen bündelt derselbe Menümodus die Bibliotheksaktionen, sodass keine Werkzeugseite aus dem Fenster gedrängt wird. Die optionalen Suchmodell-/Indexkontrollen bleiben in einem begrenzten scrollbaren Bereich erreichbar. Die Status-/Fehlerinformationen und Rückkehr bleiben in der Mindestfenstergröße 1000 × 660 zugänglich.

Layoutaktionen sind kurze, geordnete MainActor-Präferenzänderungen. Dafür zusätzliche Worker zu starten würde Synchronisierungskosten ohne Rechengewinn erzeugen. Dateizugriffe, Bildanalyse, Vorschau-Rendering, Caches und Persistenz bleiben in ihren vorhandenen begrenzten Hintergrundpfaden. Filmstreifen nutzt weiterhin Lazy-Ansichten und dieselben Thumbnail-Caches. Fokuswechsel erzeugt keine neue Bild-ID oder RAW-Basis; die bestehende Detailansicht bleibt beim Wechsel erhalten. Bei Einpassen ergibt sich die Bildgröße aus der verfügbaren Canvas bei erhaltenem Seitenverhältnis. Eine bereits vergrößerte Detailansicht behält ihren lokalen Zoomzustand.

## Prüfung

`WorkspaceLayoutTests` prüft Neustart/Fokus-Rückkehr, getrennte Modi, Größenbegrenzung, beschädigte Daten, Gruppenmodus und Veröffentlichung konsistenter Präferenzen. `WorkspaceProposalLifecycleTests` montiert echte SwiftUI-Sections in isolierten Testfenstern: laufende und fertige Anfragen, Lookauswahl, Vergleich, ausdrückliches Verwerfen sowie reale Auswahl-/Bearbeitungswechsel. Workspace-Befehle werden mit Mehrfachauswahl, Filtern, Undo/Redo und unveränderter Speicherung geprüft. Metadatentests decken rohen Tagtext und neue Kontext-/Entwurfsidentitäten ab. Es werden keine persönlichen Fotos, produktiven Modelle oder Cloud-Anfragen benötigt.

Für native Renderprüfungen bei 1000 × 660 und 1440 × 900 kann `PICEDIT_WORKSPACE_SNAPSHOTS=/absoluter/ausgabeordner ./scripts/test.sh --filter WorkspaceProposalLifecycleTests` verwendet werden. Der Test rendert ausschließlich seine isolierten Ansichten mit synthetischem Bild und schreibt die Zustände mit geschlossenen Werkzeugen, offenem Inspector und allen Panels als PNG.

Build-, Test-, Review- und manuelle UI-Ergebnisse werden im zugehörigen Pull Request dokumentiert. Die historischen [Mockup-Maße](design/issue-45/README.md) sind Entwurfswerte; sie sind keine Performance- oder Pixelversprechen der nativen Umsetzung. Die native Ansicht behält eine kompakte Bildsteuerzeile auch bei geschlossenen Werkzeugen, damit Quelle/Vorschau, Maske und Vergleich am selben Ort erkennbar bleiben.
