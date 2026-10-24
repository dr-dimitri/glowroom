# UX-07: Bibliothekssuche und KI-Modelle

Die Bibliothek verwendet einen gemeinsamen Suchbereich für **Text**, **Bildinhalt** und **Ähnliche Bilder**. Der sichtbare Modus, Zusatzfilter, Bewertung, Suchumfang, Referenz und Trefferzahl stehen am Suchort. Das frühere zusätzliche Such-Sheet im Entwicklungsbereich entfällt. **KI-Modelle** bündelt die vorhandenen, weiterhin geprüften Modellfunktionen und trennt **Bildsuche** (Modell) von **Suchindex** (Katalogeinträge). Bedienung und Fähigkeitsgrenzen stehen in [SEMANTIC-SEARCH](../SEMANTIC-SEARCH.md) und [AI-MODELS](../AI-MODELS.md).

## Native Aufnahme und Grenzen

`LibrarySearchModelScreenshotTests` montiert die tatsächliche `LibraryView` sowie die tatsächlichen Modell-/Suchansichten in einem isolierten nativen AppKit-Fenster. Die Fenster messen 1440 × 900 und 1000 × 660 pt, jeweils bei Skalierung 2× (2880 × 1800 beziehungsweise 2000 × 1320 Pixel). Die separat montierte Modellverwaltung behält ihre tatsächliche Größe von 760 × 580 pt innerhalb dieses Hosts; die schwarze Umgebung ist kein behaupteter App-Hintergrund oder Modalrahmen. Fenster außerhalb des sichtbaren Desktops ändern keine bestehende Benutzerbibliothek und werden nicht aktiviert. AppKit-Fenster und Accessibility bleiben wegen ihres gemeinsamen Prozesszustands bewusst geordnet; die Produktionsansichten verwenden weiterhin ihre vorhandenen Hintergrunddienste.

Der identische synthetische Katalog enthält `Morgenlicht.png` (4 Sterne), `Abendlicht.png` (5 Sterne) und `Wald.png` (2 Sterne). Die Landschaft wird im Test als 900 × 600 Pixel großes sRGB-Bild erzeugt. Originalbytes werden nach allen Aktionen geprüft. Private Testfotos, Bibliotheken und Pfade sind nicht Teil dieser Nachweise.

Die Suchtreffer, das fehlende Suchmodell und der laufende Index stammen aus einem ausdrücklich kontrollierten `SemanticSearchServing`. Die Aufnahmen belegen das native Layout und die Bedienzustände, keine reale semantische Inferenz, Modellqualität oder Indexleistung. Die Modellübersicht liest dagegen die tatsächlich verfügbaren lokalen Modellzustände; sie startet keine Downloads oder Inferenz. Der Index-Test startet genau eine kontrollierte Operation, pausiert bei einem abgeschlossenen Eintrag und bricht über denselben Modellpfad ab. Das bloße Öffnen der Suchansichten und der Verwaltung muss zuvor null Indexstarts ergeben.

Der Ausgangsstand ist `846aecb574739916b3807034fb6783348e5538ae`. Eine getrennte `git archive`-Kopie erhält ausschließlich den [Screenshot-Harness](baseline-harness.patch), aktiviert durch `-Xswiftc -DGLOWROOM_199_BASELINE`. Die JSON-Dateien neben den PNGs enthalten Zustand, Suchparameter, Referenz, Fenstergröße, Skalierungsfaktor, Quellstand, Fixture- und Screenshot-Hash. Die [Baseline-Inventur](baseline-source-hashes.json) und die [Nachher-Inventur](after-source-hashes.json) enthalten SHA-256 für versionierte und neue nicht ignorierte Quellen, Ressourcen, Tests, Paketauflösung und Buildskripte. Lokaler Finder-/Cachezustand ist ausgeschlossen. Sie binden die Aufnahmen an den verwendeten Stand; nachher bezeichnet `issue-199-working-tree` den durch das Nachher-Inventar festgehaltenen Produktionsdiff.

## Schritte

1. SEARCH-01: Bibliothek, Modus Bildinhalt, `Berge im Abendlicht`, mindestens vier Sterne, gesamter Katalog. Vorher zeigt die Bibliothek den ausgeklappten Suchmodell-/Indexbereich; eine zweite Aufnahme zeigt die frühere tatsächliche `AISemanticSearchView` mit demselben Modell im separaten nativen Host. Nachher gibt es den einen Bibliothekssuchbereich. Beide Fenstergrößen werden identisch geprüft.
2. SEARCH-02: `Morgenlicht.png` auswählen und **Ähnliche Bilder finden** auslösen. Referenz, gesamter Bibliotheksumfang, Bewertungsfilter und Beenden bleiben sichtbar. Das Referenzfoto selbst ist kein Treffer. Die Ansichten geben keine Wahrscheinlichkeit oder zugesicherte Duplikaterkennung aus.
3. SEARCH-03: Suche beenden, Bewertungsfilter löschen, `Morgenlicht.png` in der Bibliotheks-Einzelbildansicht öffnen; Filmstreifen eingeblendet. Vorher sind Filter/Sortierung oben und im Filmstreifen sichtbar. Nachher liegt dort ein einziger Einstieg. Anschließend nach Entwickeln wechseln und den weiter vorhandenen Filmstreifenfilter prüfen.
4. MODEL-01: Auswahl entfernen. Vorher zeigt Entwickeln seine verteilten Modelleinstiege; nachher bleibt die zentrale Verwaltung ohne Foto erreichbar. Eine eigene Aufnahme zeigt deren tatsächliche Funktionskarten.
5. MODEL-02: Suchmodell im kontrollierten Service als fehlend markieren. Vorher liegt der Zustand im Bibliotheksverwaltungsbereich, nachher in **KI-Modelle → Bildsuche**. Danach Bereitschaft wiederherstellen, genau einen kontrollierten Indexaufbau starten und **Suchindex** mit Fortschritt/Abbruch aufnehmen. Abbruch und unveränderte Originalbytes werden geprüft.

## Reproduktion

Baseline in der getrennten Archivkopie mit dem Testzusatz:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-199-baseline-build \
GLOWROOM_199_SNAPSHOTS=/private/tmp/glowroom-199-before \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=846aecb574739916b3807034fb6783348e5538ae \
./scripts/test.sh --jobs 3 --no-parallel --filter LibrarySearchModelScreenshotTests \
  -Xswiftc -DGLOWROOM_199_BASELINE
```

Nachher im finalen Checkout:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-199-visual-build \
GLOWROOM_199_SNAPSHOTS=/private/tmp/glowroom-199-after \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=issue-199-working-tree \
./scripts/test.sh --jobs 3 --no-parallel --filter LibrarySearchModelScreenshotTests
```

Die Pfade sind getrennt vom sauberen App-Build. Native Vorher-/Nachher-Tests und Modell-/Indexzustände werden innerhalb eines Prozesses geordnet ausgeführt, damit Fensterzustand und Abbruch nicht konkurrieren.

## Aufnahmen

Alle 32 PNGs wurden visuell geprüft. Die JSON-Dateien enthalten zugehörige Parameter und SHA-256. Der frühere feste 150-pt-Verwaltungsbereich schneidet in der Bibliothek Inhalte ab; die zusätzliche Vorher-Aufnahme des Such-Sheets zeigt den damaligen vollständigen Bereich. Diese Begrenzung gehört zum dokumentierten Ausgangszustand.


| Zustand | 1000 × 660 pt | 1440 × 900 pt |
| --- | --- | --- |
| SEARCH-01 vorher, Bibliothek | [PNG](screenshots/before-search-content-1000.png), [JSON](screenshots/before-search-content-1000.json) | [PNG](screenshots/before-search-content-1440.png), [JSON](screenshots/before-search-content-1440.json) |
| SEARCH-01 vorher, zusätzliches Such-Sheet | [PNG](screenshots/before-search-sheet-1000.png), [JSON](screenshots/before-search-sheet-1000.json) | [PNG](screenshots/before-search-sheet-1440.png), [JSON](screenshots/before-search-sheet-1440.json) |
| SEARCH-01 nachher, gemeinsamer Suchbereich | [PNG](screenshots/after-search-content-1000.png), [JSON](screenshots/after-search-content-1000.json) | [PNG](screenshots/after-search-content-1440.png), [JSON](screenshots/after-search-content-1440.json) |
| SEARCH-02 vorher, Referenzsuche | [PNG](screenshots/before-search-similar-1000.png), [JSON](screenshots/before-search-similar-1000.json) | [PNG](screenshots/before-search-similar-1440.png), [JSON](screenshots/before-search-similar-1440.json) |
| SEARCH-02 nachher, Referenzsuche | [PNG](screenshots/after-search-similar-1000.png), [JSON](screenshots/after-search-similar-1000.json) | [PNG](screenshots/after-search-similar-1440.png), [JSON](screenshots/after-search-similar-1440.json) |
| SEARCH-03 vorher, Bibliotheksfilmstreifen | [PNG](screenshots/before-library-filmstrip-1000.png), [JSON](screenshots/before-library-filmstrip-1000.json) | [PNG](screenshots/before-library-filmstrip-1440.png), [JSON](screenshots/before-library-filmstrip-1440.json) |
| SEARCH-03 nachher, Bibliotheksfilmstreifen | [PNG](screenshots/after-library-filmstrip-1000.png), [JSON](screenshots/after-library-filmstrip-1000.json) | [PNG](screenshots/after-library-filmstrip-1440.png), [JSON](screenshots/after-library-filmstrip-1440.json) |
| SEARCH-03 vorher, Entwickeln-Filmstreifen | [PNG](screenshots/before-develop-filmstrip-1000.png), [JSON](screenshots/before-develop-filmstrip-1000.json) | [PNG](screenshots/before-develop-filmstrip-1440.png), [JSON](screenshots/before-develop-filmstrip-1440.json) |
| SEARCH-03 nachher, Entwickeln-Filmstreifen | [PNG](screenshots/after-develop-filmstrip-1000.png), [JSON](screenshots/after-develop-filmstrip-1000.json) | [PNG](screenshots/after-develop-filmstrip-1440.png), [JSON](screenshots/after-develop-filmstrip-1440.json) |
| MODEL-01 vorher, verstreute Zugänge ohne Foto | [PNG](screenshots/before-models-no-photo-1000.png), [JSON](screenshots/before-models-no-photo-1000.json) | [PNG](screenshots/before-models-no-photo-1440.png), [JSON](screenshots/before-models-no-photo-1440.json) |
| MODEL-01 nachher, zentraler Zugang ohne Foto | [PNG](screenshots/after-models-no-photo-1000.png), [JSON](screenshots/after-models-no-photo-1000.json) | [PNG](screenshots/after-models-no-photo-1440.png), [JSON](screenshots/after-models-no-photo-1440.json) |
| MODEL-01 nachher, Funktionskarten ohne Foto | [PNG](screenshots/after-model-cards-1000.png), [JSON](screenshots/after-model-cards-1000.json) | [PNG](screenshots/after-model-cards-1440.png), [JSON](screenshots/after-model-cards-1440.json) |
| MODEL-02 vorher, kontrolliert fehlendes Suchmodell | [PNG](screenshots/before-model-missing-1000.png), [JSON](screenshots/before-model-missing-1000.json) | [PNG](screenshots/before-model-missing-1440.png), [JSON](screenshots/before-model-missing-1440.json) |
| MODEL-02 nachher, kontrolliert fehlendes Suchmodell | [PNG](screenshots/after-model-missing-1000.png), [JSON](screenshots/after-model-missing-1000.json) | [PNG](screenshots/after-model-missing-1440.png), [JSON](screenshots/after-model-missing-1440.json) |
| MODEL-02 vorher, kontrolliert laufender Index | [PNG](screenshots/before-index-running-1000.png), [JSON](screenshots/before-index-running-1000.json) | [PNG](screenshots/before-index-running-1440.png), [JSON](screenshots/before-index-running-1440.json) |
| MODEL-02 nachher, kontrolliert laufender Index | [PNG](screenshots/after-index-running-1000.png), [JSON](screenshots/after-index-running-1000.json) | [PNG](screenshots/after-index-running-1440.png), [JSON](screenshots/after-index-running-1440.json) |

## Verifikation und Review

Der gezielte native Abnahmelauf bestand mit **29 Tests in vier Suites in 33,456 Sekunden**: `LibraryHeadingTests`, `LibrarySearchModelScreenshotTests`, `AIModelsManagerTests` und `SemanticLibraryTests`. Der Screenshot-Test enthält beide Fenstergrößen und erzeugt 16 Nachher-Aufnahmen. Die veröffentlichten Nachher-Aufnahmen wurden anschließend im vollständigen finalen Regressionslauf mit dem endgültigen Quellstand erneut erzeugt; beide Größen bestanden dort in **32,712 Sekunden**. Sie sind bytegleich zu den zuvor visuell geprüften Aufnahmen. Die getrennte Baseline besteht mit denselben zwei Größen in 25,638 Sekunden und erzeugt 16 Vorher-Aufnahmen. Alle PNG-/JSON-Hashes, Fenstermaße, Skalierungen sowie der identische Fixture-Hash wurden zusätzlich geprüft. Der Baseline-Harness lässt sich als neue Testdatei auf die Archivkopie anwenden.

Die native Kontrolle prüft zusätzlich zur Abbildung die sichtbaren Suchmodi und die Erreichbarkeit der Referenz bei nur 320 beziehungsweise 640 pt Bibliotheksbreite, Bewertung, Scope, Trefferzahl, Beenden/Zurücksetzen sowie den einen Filter-/Sortierort in der Bibliothek und den erhaltenen Zugriff in Entwickeln. Im fehlenden Modellzustand wird **Bildsuche einrichten** im Indexbereich tatsächlich betätigt und die Importaktion derselben Verwaltung erwartet. Im kontrollierten Indexlauf wird Abbruch geprüft. Öffnen allein startet keinen Indexaufbau; sämtliche Originaldateien bleiben bytegleich.

Frühe Vorläufe schlugen vor der finalen Abnahme fehl. Der neue Harness verwendete zunächst eine unpassende Persistenzinitialisierung, übernahm beim Wiederverwenden eines Hosts eine modale Fenstergröße und behielt eine frühere Kartenwahl. Das ist behoben: Jede Szene besitzt eine neue Präsentationsidentität, eine feste geprüfte Fenstergröße und einen expliziten nativen Hintergrund. Compilerbefunde am neuen Zustandswrapper und Actor-Zugriffen wurden korrigiert. Die native Prüfung fand außerdem einen tatsächlich auf null Breite verdrängten Referenznamen bei 320 pt; die kompakte Anordnung und eine zweite Statuszeile beheben ihn. Für native Menütitel musste der Testhelper den von AppKit gelieferten `NSAttributedString` auslesen. Diese früheren fehlgeschlagenen Aufnahmen sind nicht veröffentlicht.

Der abschließende visuelle Durchgang bestätigt in beiden Größen bedienbare Suche und Primäraktionen, eine erkennbare Referenz, alle sechs Funktionskarten und normal lesbare Status-/Fehlertexte. Technische Modelldetails stehen erst in der ausdrücklich geöffneten Karte. Die Änderungen führen keine erklärenden Caption-/10-/11-pt-Zeilen in Suche oder Modellverwaltung ein. Doppelte gleichlautende Fehlmodellmeldungen und doppelte Fortschritts-/Abbruchanzeigen innerhalb derselben Indexansicht wurden beim Review entfernt und die finalen Aufnahmen danach neu erzeugt.

Die Nachweise ersetzen keine reale Modellqualifizierung, Inferenzqualitätsbewertung oder Performance-Messung. Modell-, Lizenz-, Speicher-, Hardware- und Download-/Importgates werden durch diese UI-Prüfungen nicht aufgehoben. Die vollständige finale Regression besteht mit **2004 Tests in 275 Suites in 356,072 Sekunden**. Sie umfasst auch die migrierten nativen Reparatur- und Objektmasken-Einrichtungswege sowie die bestehenden Such-, Installer-, Speicher-, Abbruch- und Qualifizierungstests.


## Sauberer App-Build und endgültige Prüfung

Ein sauberer vollständiger App-Build war erforderlich, weil SwiftUI-Quellcode und Modellverwaltung das Laufzeitverhalten der App ändern. Vor dem Build wurden laufende Prozesse geprüft, die verwendeten generierten App-Build-Ergebnisse und das bisherige App-Bundle bereinigt; die Tests verwendeten einen getrennten Buildpfad. `./scripts/build-app.sh` wurde mit dem für die festgelegten Pakete erforderlichen Netzwerkzugriff ausgeführt. Der finale saubere Release-Build ist mit **335,50 Sekunden erfolgreich**; Paketierung und Bundleprüfung waren erfolgreich und die Build-Sperre wurde freigegeben. Der Vergleich der Eingabe-Hashes vor und nach dem Lauf zeigte keine Veränderung des geprüften Quellstands.

Der erste saubere App-Build war fehlgeschlagen: Der neue direkte `@State`-Einsatz verlangte ein in der verwendeten Toolchain nicht verfügbares SwiftUI-Makro. Die Ansichten verwenden nun den bestehenden Projektwrapper `@ViewState`; der anschließend erforderliche vollständig saubere Build bestand. Der erste vollständige Testlauf umfasste 2003 Tests in 275 Suites und meldete drei veraltete Reparatur-Erwartungen auf den entfernten Inline-Download beziehungsweise den alten Statustext. Diese Tests prüfen jetzt die gezielte Route zur zentralen Reparaturkarte und zusätzlich deren echte native Download-/Fortschritts-/Abbruchbedienung mit kontrolliertem Download. Angenommene Fotoeinstellungen bleiben dabei erhalten. Der Objektmasken-Harness verwendet ebenfalls den zentralen Dispatcher. Alle diese Tests bestehen im finalen Gesamtlauf; Tests oder Paketgates wurden nicht abgeschwächt.

Das abschließende Review des integrierten Diffs, der betroffenen Schnittstellen, Tests und Dokumentation ergab **keine offenen Befunde**. Die endgültigen 16 Nachher-Aufnahmen, Quellen und Tests sind durch die aktualisierte Nachher-Inventur gebunden. Rohprotokolle mit privaten Dateisystempfaden und lokale Testbilder werden nicht veröffentlicht.
