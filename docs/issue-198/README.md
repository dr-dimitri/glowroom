# UX-06: Gemeinsame Bildinformationen

Die gemeinsame Produktionsansicht `PhotoMetadataSection` enthält manuelle Angaben und KI-Vorschläge. Das aktive Formular liegt im Metadatenmodell und bleibt beim Einklappen sowie beim Wechsel zwischen Bibliothek und Entwickeln erhalten. Vorschläge ändern bestätigte Angaben erst nach ausdrücklicher feldweiser Übernahme. Tags werden einzeln bearbeitet; **Ergänzen** bleibt Standard, auch bei einer leeren Liste. **Ausdrücklich ersetzen** kann eine leere Ersatzliste bestätigen.

## Native Aufnahme und Grenzen

`PhotoMetadataScreenshotTests` montiert die tatsächliche `PhotoMetadataSection` neben demselben synthetischen Foto in einem isolierten nativen AppKit-Fenster. Das Bildgerüst ist Testcode; die Aufnahmen behaupten keine vollständige `LibraryView`. Der zusätzliche Integrationstest `sharedMetadataFormSurvivesLibraryDevelopAndCollapsedGroups` montiert dagegen die echte `LibraryView` und prüft Navigation, genau ein Formular, Gruppeneinklappen und den Zustand beim Arbeitsbereichswechsel.

Die Fenster messen 1440 × 900 und 1000 × 660 pt. Die Paletten sind 340 beziehungsweise 300 pt breit und haben 20 pt Innenabstand je Seite. Die native Scrollposition wird für Vorschlagsprüfung und Konflikt gezielt geändert. Fenster stehen außerhalb des sichtbaren Desktops und werden nicht aktiviert; gemeinsame AppKit-Zustände bleiben deshalb geordnet. Metadatenzugriffe verwenden weiterhin die bestehende geordnete Hintergrundpersistenz.

Der Ausgangsstand ist `d64d85803538bc7c0dee2e249ac724979ccda791`. Eine getrennte `git archive main`-Kopie erhielt ausschließlich den [Screenshot-Harness](baseline-harness.patch), aktiviert durch `-Xswiftc -DGLOWROOM_198_BASELINE`. Die [Baseline-Inventur](baseline-source-hashes.json) bindet Quellen und Testzusatz an diesen Stand. Vorher zeigt META-01 den manuellen und anschließend den separat geöffneten KI-Bereich. Nachher zeigt eine Aufnahme das gemeinsame Formular.

Das Foto wird im Test als 900 × 600 Pixel große Landschaft erzeugt. Originaldatei und SHA-256 werden nach allen Aktionen geprüft. Private Testfotos werden nicht verwendet. Der Vorschlag stammt aus einem ausdrücklich kontrollierten Suggestor mit synthetischer Herkunft, anschließend korrigiert der Test einen Tag und wählt Titel und Tags zur Übernahme aus. Dies ist ein reproduzierbarer UI-/Persistenznachweis und keine reale KI-Inferenz oder Qualitätsbewertung.

META-03 verwendet einen tatsächlichen SQLite-Zustand: Eine ältere gespeicherte manuelle Entwurfsbasis steht einer neueren bestätigten Revision gegenüber. Bestätigungen bleiben blockiert, bis die aktuelle Revision ausdrücklich geprüft ist. Die Erzeugung dieses historischen Konflikts ist ein gekennzeichneter Testaufbau, kein behaupteter spontaner Speicherfehler.

JSON-Dateien neben jedem PNG dokumentieren Foto-ID, Größe in pt, Skalierungsfaktor, Quellstand, Fixture-/Screenshot-Hash, bestätigte Angaben, Vorschlagszustand, Feldauswahl und Konfliktstatus. Die PNGs zeigen denselben Foto-Hash in beiden Ständen.

## Reproduktion

Baseline in der getrennten Archivkopie mit dem Testzusatz:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-198-tests-build \
GLOWROOM_198_SNAPSHOTS=/private/tmp/glowroom-198-before \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=d64d85803538bc7c0dee2e249ac724979ccda791 \
./scripts/test.sh --jobs 3 --no-parallel --filter PhotoMetadataScreenshotTests \
  -Xswiftc -DGLOWROOM_198_BASELINE
```

Nachher im finalen Checkout:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-197-baseline-build \
GLOWROOM_198_SNAPSHOTS=/private/tmp/glowroom-198-after \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=working-tree \
./scripts/test.sh --jobs 3 --no-parallel \
  --filter 'PhotoMetadataModelTests|PhotoMetadataProposalIntegrationTests|MetadataTagEditorTests|WorkspaceProposalLifecycleTests|PhotoMetadataTerminationTests|PhotoMetadataScreenshotTests'
```

Der separate vorhandene Testpfad wird nur nach Prüfung auf laufende Prozesse verwendet. Der App-Build nutzt ein anderes Verzeichnis; Baseline, Release und integrierte Tests verändern keinen gemeinsamen Buildzustand.

## Aufnahmen

| Zustand | 1000 × 660 pt | 1440 × 900 pt |
| --- | --- | --- |
| META-01 vorher, manuelle Angaben | [PNG](screenshots/before-manual-1000.png), [JSON](screenshots/before-manual-1000.json) | [PNG](screenshots/before-manual-1440.png), [JSON](screenshots/before-manual-1440.json) |
| META-01 vorher, separater KI-Bereich | [PNG](screenshots/before-ai-1000.png), [JSON](screenshots/before-ai-1000.json) | [PNG](screenshots/before-ai-1440.png), [JSON](screenshots/before-ai-1440.json) |
| META-01 nachher, gemeinsames Formular | [PNG](screenshots/after-unified-1000.png), [JSON](screenshots/after-unified-1000.json) | [PNG](screenshots/after-unified-1440.png), [JSON](screenshots/after-unified-1440.json) |
| META-02 vorher, korrigierter Vorschlag | [PNG](screenshots/before-proposal-1000.png), [JSON](screenshots/before-proposal-1000.json) | [PNG](screenshots/before-proposal-1440.png), [JSON](screenshots/before-proposal-1440.json) |
| META-02 nachher, korrigierter Vorschlag | [PNG](screenshots/after-proposal-1000.png), [JSON](screenshots/after-proposal-1000.json) | [PNG](screenshots/after-proposal-1440.png), [JSON](screenshots/after-proposal-1440.json) |
| META-03 vorher, Revisionskonflikt | [PNG](screenshots/before-conflict-1000.png), [JSON](screenshots/before-conflict-1000.json) | [PNG](screenshots/before-conflict-1440.png), [JSON](screenshots/before-conflict-1440.json) |
| META-03 nachher, Revisionskonflikt | [PNG](screenshots/after-conflict-1000.png), [JSON](screenshots/after-conflict-1000.json) | [PNG](screenshots/after-conflict-1440.png), [JSON](screenshots/after-conflict-1440.json) |

## Verifikation

Der finale integrierte Lauf bestand mit **56 Tests in sechs Suites in 41,683 s** nach **39,78 s** Testkompilierung. Er umfasst alle im Issue genannten fünf Suites sowie die opt-in Screenshot-Suite. Die tatsächliche Bibliothek-/Entwickeln-Navigation bestand bei beiden Fenstergrößen einschließlich ausgeblendetem Werkzeugpanel, Einklappen und erneutem Öffnen. Layoutwechsel erzeugten keine zusätzliche Analyse. Der finale Baselinelauf bestand mit einem Test in zwei Fensterfällen nach **5,585 s**; die abschließende inkrementelle Harness-Kompilierung benötigte 22,90 s.

Zusätzliche Regressionen prüfen modellgebundenen Editor, Roh-Tags, Auswahl und Ersetzungspolitik über Remount, temporär leere Auswahl, Foto-/Quellenwechsel; native Tagzeilen mit Ergänzen und Entfernen; wiederholte Wiederherstellung eines fehlenden/ersetzten Vorschlags; Quellenwechsel während einer blockierten Wiederherstellung sowie einen fehlgeschlagenen angenommenen Write nach A→B→A. Das Review fand und behob dabei bestehende Recoverygrenzen: ursprüngliche Vorschlags-ID und Quelle bleiben auch bei wiederholter Wiederherstellung erhalten; verspätete Ladevorgänge dürfen keine andere Quelle übernehmen; ausgehende ungesicherte Felder werden keinem noch ungeladenen Zielfoto zugeordnet. Abgetrennte gerettete Vorschläge bleiben erkennbar und können weder einen neuen Vorschlag verändern noch ungeprüft bestätigen.

Die ersten Baselineversuche scheiterten an Harnessfehlern: internem Core-Import, einem Katalog am falschen Verzeichnis und einer fehlenden manuellen Entwurfsrevision im Konfliktauftrag. Der erste integrierte Lauf scheiterte mit zehn Befunden: an dieser frühen Screenshot-Fixture und an nativen Accessibility-/Bereitschaftsprüfungen. Benannte native Gruppen verhindern nun die Weitergabe derselben Formular-ID an alle Kinder; die Tests warten auf das native Layout und einen abgeschlossenen Verfügbarkeitscheck. Die vollständige korrigierte Prüfung bestand; keine dieser fehlgeschlagenen Ausführungen wird als bestandener Nachweis gezählt.

Alle 14 PNG-Hashes, der gemeinsame Fixture-Hash, identische bestätigte Angaben und Feldauswahl bei META-02 sowie blockierte Übernahme bei META-03 wurden maschinell geprüft. Die [finale Quelleninventur](source-hashes.json) bindet Implementierung und Tests an die Aufnahmen. Ergebnisse und Prüfgrenzen stehen zusätzlich in [test-results.json](test-results.json). Alle 14 finalen PNGs wurden zusätzlich in Originalauflösung visuell geprüft: Feldnamen und Primäraktionen sind bei 1000 × 660 pt vollständig sichtbar; Vorschlagsprüfung und Konfliktzustände scrollen vertikal, ohne horizontalen Beschnitt. Es gibt keinen offenen visuellen Befund und keine kleinen erklärenden Caption-Zeilen im gemeinsamen Formular. Der erforderliche saubere lokale App-Build ist ebenfalls bestanden; ein inkrementeller Testbuild wurde dafür nicht als Ersatz gezählt.

Der erste Releaseversuch wurde vor den letzten Recoverykorrekturen kontrolliert beendet (Exit 143). Ein weiterer Start blieb durch einen anschließend als verwaist nachgewiesenen Build-Lock blockiert (Exit 1). Nach bestätigtem Ende aller zugehörigen Prozesse wurden der verwaiste Lock, das zugehörige generierte Staging und sämtliche alten `.build/`-Ergebnisse sicher entfernt. `.build-app/` und das alte `dist/Glowroom.app` waren zu diesem Zeitpunkt nicht vorhanden; der separate Testpfad blieb erhalten. Der finale vollständige saubere App-Build mit `./scripts/build-app.sh` bestand (Exit 0), einschließlich Paketauflösung, Release-Kompilierung in **324,09 s**, Paketierung, Info.plist-Prüfung, ad-hoc Signierung und strenger Signaturprüfung. Das Bundle liegt unter `dist/Glowroom.app`, das Log unter `/private/tmp/glowroom-198-build-verified.log`. Der Build war wegen der Änderungen an SwiftUI, Navigation und Metadatenzustand erforderlich. Das finale Review umfasst Implementierung, betroffene Schnittstellen, Tests und Dokumentation; es gibt keine offenen Befunde.
