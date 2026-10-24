# UX-08: klare Bedienung und übergreifende UI-Abnahme

**Issue:** [#200](https://github.com/dr-dimitri/glowroom/issues/200). **Abnahmestand: implementiert; VoiceOver-Abnahme durch Werkzeugfreigabe blockiert.** Tastatur- und visuelle Prüfung sowie der saubere App-Build sind durchgeführt. Die Regression und abschließenden Nachprüfungen sind unten mit ihren jeweiligen Grenzen dokumentiert. Issue und Pull Request bleiben bis zur vollständigen VoiceOver-Abnahme offen; ein Merge wird nicht als abgeschlossen behauptet.

## Bedienung

Die Oberfläche verwendet dieselben Aufgabennamen in Werkzeugen und Modellverwaltung: **Entwickeln**, **KI-Korrektur**, **Maskieren**, **Reparieren**, **Bildinformationen** und **KI-Modelle**. Technische Modellnamen stehen in den ausdrücklich geöffneten Modellkarten. Die Einrichtung wird über eine benannte Aktion gestartet; Auswahl oder bloßes Öffnen starten keinen Download oder Modelllauf.

Aktive Werkzeuge und die Auswahl zwischen **Aktueller Stand** und **Vorschlag** besitzen neben Farbe ein sichtbares Häkchen und einen zugänglichen Auswahlzustand. Maskieren zeigt die **Zielmaske**, bietet eine benannte **Neue Maske** und trennt **Pinsel** und **Radierer** als Werkzeugauswahl. Zuschneiden benennt Seitenverhältnissperre und Ausrichten; der Winkel behält seine Einheit. Die Reparaturmodi bleiben mit Namen und Auswahl erkennbar.

**Bildinformationen** zeigt Feldnamen, Zeichen-/Tagzahlen, manuelle Entwürfe, KI-Vorschläge, Bestätigung, Fehler und Speicherwiederholung. Technische Analyseherkunft und Rasterdigest stehen unter **Hilfe → Analysedetails**. Import- und Zuordnungsdialoge erhalten die ausdrückliche Konfliktauswahl; die Importaktion benennt sowohl fehlende Einträge als auch die gewählte Konfliktauswahl.

**Foto exportieren** zeigt Bildformat, Farbraum, weißen Transparenzhintergrund, Qualität, Größenanpassung und relevante Eingabegrenzen an den Einstellungen. Lange Formulare scrollen. Die Primäraktionen stehen im Dialogfuß; Fortschritt, Abbruch, Ersetzen-Bestätigung, Ergebnis und erneuter Versuch bleiben erhalten. Hintergrundwissen zu Export, Maskieren, Bildanalyse und Bildinformationen steht in ausdrücklich geöffneter **Hilfe** mit normaler Textgröße.

Statische Kleinsthinweise und dekorative Sätze entfallen. Feldwerte, Einheiten, reale Fehler, Fortschritt und Entwurfszustände bleiben sichtbar; betroffene Status-/Fehlertexte verwenden mindestens 13 pt. Die Änderung ergänzt keine Bearbeitungsalgorithmen, beschleunigt keine Inferenz und verändert keine Modell-, Lizenz-, Speicher-, Hardware-, Import-/Download- oder Sicherheitsgates. Originale und die bestehenden Speicher-/Abbruchpfade bleiben in ihrer fachlichen Zuständigkeit.

Weitere Bedienungsdetails: [KI-Korrektur](../AI-DEVELOPMENT.md), [KI-Modelle](../AI-MODELS.md), [Bildinformationen](../PHOTO-METADATA.md), [zentrales UI-Konzept](../ui-concept-2026-10/README.md).

## Vorangegangene UI-Abnahmen

Dieses Issue ergänzt die bereits dokumentierten nativen Nachweise der übrigen UI-Issues. Deren jeweilige Prüfgrenzen gelten weiterhin; die neuen Aufnahmen ersetzen keine funktionalen Nachweise für Persistenz, Abbruch oder Datenintegrität.

| UI-Issue | Bereits dokumentierter Umfang |
| --- | --- |
| [UX-01 / #193](../issue-193/README.md) | Gemeinsamer Entwickeln-Bereich, Navigation, Panels und Bildfokus |
| [UX-02 / #194](../issue-194/README.md) | Gerenderter Korrekturvorschlag, Vergleich und ausdrückliche Übernahme |
| [UX-03 / #195](../issue-195/README.md) | Gemeinsame Maskierung und Objektmaskenvorschlag |
| [UX-04 / #196](../issue-196/README.md) | Licht, Farbe, Details und erweiterte Tonwerte |
| [UX-05 / #197](../issue-197/README.md) | Reparaturmodi und lokale KI-Einrichtung |
| [UX-06 / #198](../issue-198/README.md) | Gemeinsame manuelle Bildinformationen und KI-Vorschläge |
| [UX-07 / #199](../issue-199/README.md) | Bibliothekssuche, Ähnlichkeitsreferenz und zentrale Modellverwaltung |

## Herkunft und Prüfgrenzen der neuen Aufnahmen

`UIClarityScreenshotTests` rendert tatsächliche SwiftUI-/AppKit-Produktionsansichten in einem isolierten nativen Host. Beide Durchgänge verwenden denselben synthetischen sRGB-Landschaftsaufbau mit 900 × 600 Pixeln, die Foto-ID `synthetic-morgenlicht` und den Namen `Morgenlicht.png`. Die Daten entstehen im Test; private Dateien aus `Fixtures/LocalTestImages/`, persönliche Bibliotheken und Metadaten werden nicht benötigt oder veröffentlicht. Der Export verwendet einen ausdrücklich publikationsfähigen temporären Zielpfad und schreibt keine Bilddatei.

Die Fensterinhaltsgrößen betragen **1000 × 660 pt** und **1440 × 900 pt**. Der Host prüft seine Inhaltsgröße und hält den tatsächlichen Skalierungsfaktor fest. Die JSON-Datei neben jeder unannotierten PNG enthält UI-Issue, Quellreferenz, macOS-Version, Fenstermaße in pt, Skalierung, Foto-ID, Schritte, Zustand sowie Fixture- und Screenshot-SHA-256. Sie hält außerdem Werkzeug, Bildfokus, sichtbare Panels und Metadaten-Vorschlagszustand fest. Markierte Darstellungen wären zusätzliche Erläuterungen; die unannotierte native Aufnahme bleibt der Beleg.

Die Metadatenantwort stammt ausdrücklich aus einem kontrollierten `PhotoMetadataSuggesting`. Fehlendes Suchmodell und Suchindexfehler stammen aus einem kontrollierten `SemanticSearchServing`. Der Fehler wird nach dem tatsächlichen Indexaufruf durch den normalen Fehlerpfad angezeigt. Das sind kontrollierte Testzustände, keine reale Modellinferenz, Modellqualifizierung oder Indexleistungsmessung. Die synthetische Landschaft belegt Layout und Bedienzustände, keine Qualität der KI-Segmentierung. Die Reparaturansicht liest ihre tatsächlich vorhandene lokale Verfügbarkeit; der Harness installiert kein Modell.

Der Vorher-Quellstand ist `cde266663c2af5eae578bd64247cad81c30fc03f`. Eine getrennte Archivkopie erhält ausschließlich den [Baseline-Harness](baseline-harness.patch); `-Xswiftc -DGLOWROOM_200_BASELINE` kennzeichnet die Dateinamen als Vorher. Die [Baseline-Inventur](baseline-source-hashes.json) und [Nachher-Inventur](after-source-hashes.json) binden die Aufnahmen an Quellen, Ressourcen, Tests, Paketauflösung und Buildskripte. Die endgültige Nachher-Commitreferenz und Inventurprüfung sind noch einzutragen.

Screenshots belegen sichtbare Anordnung und Zustände. Separate Testassertions prüfen benannte und horizontal erreichbare Werkzeugaktionen, den Rückweg aus dem Bildfokus, gezieltes Öffnen der Werkzeuge, genau einen kontrollierten Vorschlags-/Indexaufruf und unveränderte synthetische Originalbytes. Die regulären Speicher-, Konflikt-, Abbruch- und Bearbeitungstests bleiben dafür die funktionalen Nachweise.

## Szenen und Reproduktion

Pro Fenstergröße werden dreizehn Szenen vorher und nachher aufgenommen, insgesamt 52 PNGs mit je einer JSON-Datei:

1. **Entwickeln — TEXT-01 / LAYOUT-01:** `Morgenlicht.png` auswählen, Entwickeln öffnen, KI-Korrektur und Licht anzeigen; Navigation verborgen, Filmstreifen sichtbar.
2. **Entwickeln · Vorschlagsaktion:** Zur benannten Vorschlagsaktion scrollen; tatsächlichen Modellprüfzustand zeigen.
3. **Maskieren — TEXT-02:** Über den Werkzeugknopf öffnen, einen linearen Verlauf anlegen und Zielmaske sowie lokale Korrekturen anzeigen.
4. **Reparieren — TEXT-02:** Reparieren öffnen, Entfernen auswählen und Parameter sowie KI-Verfügbarkeit anzeigen.
5. **Manueller Entwurf · Kopf — TEXT-03:** Bildinformationen mit eingegebenem Titel, Beschreibung und Tag sowie sichtbarem Entwurfsstatus zeigen.
6. **Manuelle Bildinformationen · Aktionen:** Zum Ende desselben Formulars scrollen; Übernehmen und Verwerfen zeigen.
7. **KI-Vorschlag · Kopf — TEXT-03:** Manuelle Werte bestätigen, genau einen kontrollierten KI-Vorschlag anfordern; Vorschlagsauswahl und Prüfzustand zeigen.
8. **KI-Bildinformationen · Aktionen:** Übernehmen und Verwerfen desselben noch nicht bestätigten Vorschlags zeigen.
9. **Bildfokus — LAYOUT-02:** Bildfokus aktivieren, Navigation, Werkzeuge und Filmstreifen verbergen; Rückwege und Werkzeugaktionen zeigen.
10. **Werkzeuge im Bildfokus — LAYOUT-02:** Licht im Dock öffnen und das Werkzeugpanel mit Rückwegen zeigen.
11. **Modell fehlt — TEXT-04:** KI-Modelle → Suchindex öffnen; kontrolliert fehlendes Suchmodell und passende Einrichtungsaktion zeigen.
12. **Indexfehler — TEXT-04:** Kontrollierte Modellbereitschaft herstellen, einen Indexaufbau starten und den konkreten Fehler zeigen.
13. **Export — übergreifende Textabnahme:** Die native Exportansicht mit JPEG, sRGB, Qualität und Größe öffnen; nicht exportieren.

Vorher in der getrennten Archivkopie nach Anwendung des Harness-Patches:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-200-baseline-build \
GLOWROOM_200_SNAPSHOTS=/private/tmp/glowroom-200-before \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=cde266663c2af5eae578bd64247cad81c30fc03f \
./scripts/test.sh --jobs 3 --no-parallel --filter UIClarityScreenshotTests \
  -Xswiftc -DGLOWROOM_200_BASELINE
```

Nachher im Aufgabencheckout; `working-tree` wird vor Veröffentlichung durch die nachgewiesene Quellreferenz ersetzt:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-200-visual-build \
GLOWROOM_200_SNAPSHOTS=/private/tmp/glowroom-200-after \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=working-tree \
./scripts/test.sh --jobs 3 --no-parallel --filter UIClarityScreenshotTests
```

UI-/Fensterserverprüfungen bleiben geordnet, da sie gemeinsamen AppKit-/SwiftUI-Zustand verwenden. Baseline, Nachher-Testbuild und sauberer App-Build verwenden getrennte Buildpfade. Unabhängige Quellprüfungen und Reviews können parallel laufen. Diese UI-Änderung führt keinen neuen Laufzeit-Workerpool und keine zusätzliche Bilddecodierung ein.

Für einen zusätzlichen manuellen Durchgang kann der Nachher-Befehl um `GLOWROOM_200_MANUAL_PAUSE_SECONDS=60` ergänzt werden. Der Harness öffnet nach den Aufnahmen das 1000-pt-Fenster zur Bedienung. Tab, Umschalt-Tab, Leertaste und die vorhandenen Menü-/Werkzeugaktionen sind auf Erreichbarkeit, erkennbaren Fokus, Ein-/Ausklappen, Panelwechsel und Bildfokus-Rückweg zu prüfen. VoiceOver muss zusätzlich Auswahl, Namen, Zustände und nächste Aktionen verständlich ausgeben. Diese Option allein ist kein Nachweis eines durchgeführten manuellen Tests.

## Aufnahmen

Die 52 unannotierten Aufnahmen wurden bei beiden Größen visuell geprüft. Hash- und Quellinventuren werden mit dem endgültigen Commit gebunden. Die Tabelle enthält die reproduzierbaren Vorher-/Nachher-Zustände.

| Szene | Vorher 1000 × 660 pt | Nachher 1000 × 660 pt | Vorher 1440 × 900 pt | Nachher 1440 × 900 pt |
| --- | --- | --- | --- | --- |
| Entwickeln | [PNG](screenshots/before-develop-1000.png), [JSON](screenshots/before-develop-1000.json) | [PNG](screenshots/after-develop-1000.png), [JSON](screenshots/after-develop-1000.json) | [PNG](screenshots/before-develop-1440.png), [JSON](screenshots/before-develop-1440.json) | [PNG](screenshots/after-develop-1440.png), [JSON](screenshots/after-develop-1440.json) |
| Entwickeln · Vorschlagsaktion | [PNG](screenshots/before-develop-actions-1000.png), [JSON](screenshots/before-develop-actions-1000.json) | [PNG](screenshots/after-develop-actions-1000.png), [JSON](screenshots/after-develop-actions-1000.json) | [PNG](screenshots/before-develop-actions-1440.png), [JSON](screenshots/before-develop-actions-1440.json) | [PNG](screenshots/after-develop-actions-1440.png), [JSON](screenshots/after-develop-actions-1440.json) |
| Manueller Entwurf · Kopf | [PNG](screenshots/before-metadata-manual-top-1000.png), [JSON](screenshots/before-metadata-manual-top-1000.json) | [PNG](screenshots/after-metadata-manual-top-1000.png), [JSON](screenshots/after-metadata-manual-top-1000.json) | [PNG](screenshots/before-metadata-manual-top-1440.png), [JSON](screenshots/before-metadata-manual-top-1440.json) | [PNG](screenshots/after-metadata-manual-top-1440.png), [JSON](screenshots/after-metadata-manual-top-1440.json) |
| KI-Vorschlag · Kopf | [PNG](screenshots/before-metadata-proposal-top-1000.png), [JSON](screenshots/before-metadata-proposal-top-1000.json) | [PNG](screenshots/after-metadata-proposal-top-1000.png), [JSON](screenshots/after-metadata-proposal-top-1000.json) | [PNG](screenshots/before-metadata-proposal-top-1440.png), [JSON](screenshots/before-metadata-proposal-top-1440.json) | [PNG](screenshots/after-metadata-proposal-top-1440.png), [JSON](screenshots/after-metadata-proposal-top-1440.json) |
| Maskieren | [PNG](screenshots/before-mask-1000.png), [JSON](screenshots/before-mask-1000.json) | [PNG](screenshots/after-mask-1000.png), [JSON](screenshots/after-mask-1000.json) | [PNG](screenshots/before-mask-1440.png), [JSON](screenshots/before-mask-1440.json) | [PNG](screenshots/after-mask-1440.png), [JSON](screenshots/after-mask-1440.json) |
| Reparieren | [PNG](screenshots/before-repair-1000.png), [JSON](screenshots/before-repair-1000.json) | [PNG](screenshots/after-repair-1000.png), [JSON](screenshots/after-repair-1000.json) | [PNG](screenshots/before-repair-1440.png), [JSON](screenshots/before-repair-1440.json) | [PNG](screenshots/after-repair-1440.png), [JSON](screenshots/after-repair-1440.json) |
| Manuelle Bildinformationen | [PNG](screenshots/before-metadata-manual-1000.png), [JSON](screenshots/before-metadata-manual-1000.json) | [PNG](screenshots/after-metadata-manual-1000.png), [JSON](screenshots/after-metadata-manual-1000.json) | [PNG](screenshots/before-metadata-manual-1440.png), [JSON](screenshots/before-metadata-manual-1440.json) | [PNG](screenshots/after-metadata-manual-1440.png), [JSON](screenshots/after-metadata-manual-1440.json) |
| KI-Bildinformationen | [PNG](screenshots/before-metadata-proposal-1000.png), [JSON](screenshots/before-metadata-proposal-1000.json) | [PNG](screenshots/after-metadata-proposal-1000.png), [JSON](screenshots/after-metadata-proposal-1000.json) | [PNG](screenshots/before-metadata-proposal-1440.png), [JSON](screenshots/before-metadata-proposal-1440.json) | [PNG](screenshots/after-metadata-proposal-1440.png), [JSON](screenshots/after-metadata-proposal-1440.json) |
| Bildfokus | [PNG](screenshots/before-focus-1000.png), [JSON](screenshots/before-focus-1000.json) | [PNG](screenshots/after-focus-1000.png), [JSON](screenshots/after-focus-1000.json) | [PNG](screenshots/before-focus-1440.png), [JSON](screenshots/before-focus-1440.json) | [PNG](screenshots/after-focus-1440.png), [JSON](screenshots/after-focus-1440.json) |
| Werkzeuge im Bildfokus | [PNG](screenshots/before-focus-tools-1000.png), [JSON](screenshots/before-focus-tools-1000.json) | [PNG](screenshots/after-focus-tools-1000.png), [JSON](screenshots/after-focus-tools-1000.json) | [PNG](screenshots/before-focus-tools-1440.png), [JSON](screenshots/before-focus-tools-1440.json) | [PNG](screenshots/after-focus-tools-1440.png), [JSON](screenshots/after-focus-tools-1440.json) |
| Modell fehlt | [PNG](screenshots/before-model-missing-1000.png), [JSON](screenshots/before-model-missing-1000.json) | [PNG](screenshots/after-model-missing-1000.png), [JSON](screenshots/after-model-missing-1000.json) | [PNG](screenshots/before-model-missing-1440.png), [JSON](screenshots/before-model-missing-1440.json) | [PNG](screenshots/after-model-missing-1440.png), [JSON](screenshots/after-model-missing-1440.json) |
| Indexfehler | [PNG](screenshots/before-model-error-1000.png), [JSON](screenshots/before-model-error-1000.json) | [PNG](screenshots/after-model-error-1000.png), [JSON](screenshots/after-model-error-1000.json) | [PNG](screenshots/before-model-error-1440.png), [JSON](screenshots/before-model-error-1440.json) | [PNG](screenshots/after-model-error-1440.png), [JSON](screenshots/after-model-error-1440.json) |
| Export | [PNG](screenshots/before-export-1000.png), [JSON](screenshots/before-export-1000.json) | [PNG](screenshots/after-export-1000.png), [JSON](screenshots/after-export-1000.json) | [PNG](screenshots/before-export-1440.png), [JSON](screenshots/before-export-1440.json) | [PNG](screenshots/after-export-1440.png), [JSON](screenshots/after-export-1440.json) |

## Verifikation und Abschlussreview

Der gezielte Lauf besteht mit **116 Tests in elf Suites**. Die Laufzeit von 222,226 Sekunden enthält das ausdrücklich aktivierte 180-Sekunden-Wartefenster des Testhosts; sie ist keine Performance-Messung. Die endgültige Baseline besteht mit beiden Fenstergrößen in **25,704 Sekunden** und erzeugt 26 Vorher-Aufnahmen. Ein vorheriger vollständiger Lauf umfasste **2005 Tests in 276 Suites** in 349,920 Sekunden: Die übrigen Prüfungen meldeten keinen Fehler; einzig die beiden Größenvarianten des angepassten Objektmasken-Tests scheiterten noch am neuen Testzugriff auf den nativen Menünamen. AppKit lieferte dafür ein leeres Label und einen nichtleeren Titel. Nach der reinen Korrektur dieser Auslese besteht die finale Nachprüfung mit **14 Tests in drei Suites in 36,338 Sekunden**, einschließlich beider Objektmaskenvarianten, aller Maskenlayouttests und der endgültigen Screenshot-Abnahme in beiden Größen. Die getrennte Objektmaskenprüfung bestand zusätzlich in 8,255 Sekunden. Der Produktions- und Build-Quellstand blieb zwischen Gesamtlauf und Nachprüfung bytegleich; der Testname wurde nicht aus der Prüfung entfernt. **Der abschließende vollständige Standardlauf mit den korrigierten Testhelfern besteht mit 2005 Tests in 276 Suites in 324,678 Sekunden.** Die opt-in Screenshot-Abnahme ist separat erfolgreich; modellgestützte und andere ausdrücklich optionale Lastprüfungen bleiben gemäß ihren bestehenden Aktivierungsbedingungen deaktiviert.

Alle **52 PNG-/JSON-Paare** wurden auf Screenshot-Hash, Fenstermaße, Skalierung **2** und denselben Fixture-Hash geprüft. Alle lokalen Nachweislinks lösen auf. Die Quellinventuren und der Baseline-Patch wurden auf den finalen Test-Harness aktualisiert.

Die visuelle Prüfung umfasst Bibliothek/Filmstreifen, Entwickeln, Maskieren, Reparieren, Bildinformationen, KI-Modelle, Export und Bildfokus. Primäraktionen passen horizontal; lange Formulare scrollen. Die ergänzenden Metadaten-Kopfaufnahmen zeigen den manuellen Entwurf beziehungsweise **KI-Vorschlag · nicht bestätigt / Zur Prüfung bereit**, während die weiteren Aufnahmen Übernehmen und Verwerfen zeigen. Das zuvor 720 pt hohe Exportformular passte nicht vollständig in den 660-pt-Host. Die neue Begrenzung auf 620 pt erhält Kopf und Dialogfuß; die nachher ausgeführten Geometrieassertions prüfen beide Exportaktionen und den Titel vollständig in beiden Achsen. Der einzige Neue-Maske-Einstieg liegt bei sichtbarer Palette dort. Eine ausgeblendete Palette kann im Inspector einen ausdrücklich konfigurierten Ersatzweg verwenden. Singularformen für ein Foto/ein Bild sind einschließlich laufendem Index und zugänglichem Ordnernamen korrigiert.

Die Entwickeln-Aktionsaufnahmen zeigen die tatsächliche, asynchron geprüfte lokale Modellverfügbarkeit. Deren Zeitpunkt kann zwischen Vorher/Nachher variieren; die Bilder belegen keine gleichzeitige Modellbereitschaft und keine Inferenzqualität. Die kontrollierten Metadaten- und Suchzustände sind in jedem JSON ausdrücklich bezeichnet.

Mehrere unabhängige Reviews des integrierten Produktionsdiffs, der Schnittstellen, Tests und Bedienungsdokumentation ergaben keine offenen wesentlichen Codebefunde. Die neue Masken-Scrollprüfung verwendet den realen Accessibility-Rahmen und prüft den letzten Regler nach dem Scrollen. Der bestehende Objektmasken-Test prüft den einzigen sichtbaren Erstellungszugang und den gemeinsamen Creator-Zustand; er behauptet keinen nativen Menüklick im SwiftPM-Host. Der tatsächliche Menüklick ist Teil des folgenden interaktiven Durchgangs. Vorschau-, Übernahme-, Undo-, Speicher- und Originalbyte-Assertions bleiben erhalten.

Frühe Testvorläufe schlugen fehl: Eine Änderung der optionalen Wartezeit während der ersten Kompilierung führte zum korrekten Abbruch wegen einer veränderten Eingabedatei. Vier Maskentests suchten anschließend die native Slider-ID statt des Accessibility-Wrappers; der Scrollhelfer wurde korrigiert. Im ersten Gesamtlauf bestanden 2005 Tests in 276 Suites bis auf zwei Größenvarianten des alten Objektmasken-Harness, die noch den entfernten doppelten Erstellungsbutton suchten. Dieser Harness verwendet jetzt den vorhandenen Zugang; die funktionalen Anforderungen wurden erhalten. Ein späterer Screenshot-Vorlauf zeigte bei 1000 pt wegen veralteter Accessibility-Geometrie die Kopfansicht zweimal. Der Helfer liest nach jedem Scrollen neue Geometrie, wartet auf eine zweite stabile Sichtbarkeitsbeobachtung und verlangt beide Metadatenaktionen innerhalb des echten Scroll-Viewports und Hosts. Die anschließend neu erzeugte Vorschlags-Aktionsaufnahme zeigt Übernehmen und Verwerfen vollständig. Nur diese endgültigen Aufnahmen werden veröffentlicht.

## Interaktive Tastaturprüfung und offener VoiceOver-Nachweis

Der Durchgang verwendet eine separate Kopie des erfolgreich gebauten Release-Bundles mit eigener Bundle-ID und `--catalog-directory` für einen ausschließlich temporären Katalog. Zwölf Motive aus `scripts/make-demo-library.swift` sind die Testdaten; die persönliche Bibliothek wird dafür nicht geöffnet. Der Vergleich der SHA-256 aller zwölf Bilddateien nach dem Durchgang bestätigt unveränderte Originalbytes.

Tatsächlich ausgeführte native Bedienung:

- **⌘D**, Tab/Umschalt-Tab und Leertaste öffnen Entwickeln, erreichen die Licht-Gruppe und schalten Gruppen um. Der Fokus wird in der nativen Accessibility-Ausgabe bestätigt.
- **⇧⌘F** öffnet Bildfokus. Der Fokus liegt auf **Zur vorherigen Ansicht**; Leertaste stellt die vorherigen Panels wieder her. **⌥⌘L** blendet die Navigation aus und wieder ein.
- **Maskieren → Pinsel → Neue Maske** öffnet das tatsächliche native Menü. Pfeil abwärts und Return wählen **Objekt beschreiben**; das gemeinsame Auftragsformular erscheint. Ein Modellauftrag wird dabei nicht gestartet. Zielmaske und ausgewähltes Werkzeug tragen zugängliche Namen/Zustände.
- **Reparieren** zeigt die vier benannten Modi, die aktive Auswahl und den konkreten Zustand **KI-Reparatur nicht eingerichtet** mit Einrichten-Aktion.
- **⌥⌘M** öffnet KI-Modelle; Return betätigt **Fertig**. **⇧⌘E** öffnet den vollständigen Exportdialog; Escape schließt ihn ohne Dateiausgabe.
- Im gemeinsamen Metadatenformular wird per Tastatur `Tastaturprüfung` in die Beschreibung eingegeben. Aus-/Einblenden der Navigation erhält Text und sichtbaren manuellen Entwurfszustand. **Hilfe** öffnet normale Textgröße, Escape schließt sie. Die Test-App wird geordnet beendet.

**VoiceOver ist nicht vollständig abgenommen.** Der macOS-Schalter wurde aktiviert und der laufende VoiceOver-Prozess lesend bestätigt. VoiceOver-Navigationstasten wurden im Testfenster versucht; eine verlässliche Prüfung der gesprochenen Ausgabe beziehungsweise des VoiceOver-Cursors war damit nicht möglich. Der ursprüngliche Schalterzustand **Aus** ist am Ende wieder bestätigt; der VoiceOver-Prozess ist beendet. Das automatische Freigabesystem verweigerte den Zugriff auf **VoiceOver-Dienstprogramm** mit der Meldung `Computer Use was not approved to use VoiceOver Utility`. Eine Sprachausgabe- oder vollständige VoiceOver-Erfolgsbehauptung wird daraus nicht abgeleitet.

Für den Abschluss muss VoiceOver auf dem finalen App-Stand mit den obigen Ansichten erneut durchlaufen werden: Namen, ausgewählte Modi, Zielmaske, Entwurf, fehlende Fähigkeit und nächste Aktion ansagen lassen sowie Aktivierung und Rückwege prüfen. Dafür ist entweder die Freigabe des Dienstprogramms für Computer Use oder ein dokumentierter manueller Durchgang durch den Nutzer erforderlich. Dieser konkrete Abnahmenachweis blockiert den Merge; Quellen und geprüfter Aufgabenbranch bleiben erhalten.

## Sauberer App-Build

Der saubere vollständige Release-Build ist mit **391,99 Sekunden erfolgreich**. Er war erforderlich, da SwiftUI-/AppKit-Quellcode Darstellung und Bedienung verändert. Vor dem Lauf wurden die Prozesse geprüft und sämtliche verwendeten generierten App-Ergebnisse sowie das bisherige Bundle bereinigt. Tests und Baseline verwenden getrennte temporäre Buildpfade. `GLOWROOM_BUILD_JOBS=4 ./scripts/build-app.sh` verwendete den für die festgelegten Pakete freigegebenen Netzwerkzugriff. Paketierung, Plist- und Signaturprüfung bestanden.

Ein erster sauberer Vorlauf bestand bereits in 414,21 Sekunden; das anschließende visuelle Review führte zur Exporthöhen- und Singular-Korrektur und erforderte einen neuen sauberen Build. Ein Zwischenlauf wurde dafür geordnet beendet (Exit 143). Sein konservativer Cleanup behielt die Sperre; ein weiterer Start scheiterte ausdrücklich an dieser Sperre. Vor deren Bereinigung wurden der beendete Besitzer sowie alle möglichen Compiler-/Icon-Prozesse geprüft. Es war kein App-Build mehr aktiv; nur der getrennte temporäre Testprozess lief. Erst danach wurden die inaktive Sperre und generierten Zwischenstände entfernt und der oben genannte erfolgreiche finale Build ausgeführt. Eine aktive Sperre wurde nicht entfernt.

Nach dem finalen App-Build änderte sich nur noch der bestehende Test-Harness und die Abnahmedokumentation. Der abschließende SHA-256-Vergleich bestätigt unveränderte Produktions-/Build-Eingaben; für reine Test- und Dokumentationsnachpflege ist kein weiterer App-Build erforderlich.
