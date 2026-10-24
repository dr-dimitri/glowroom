# UX-04: Licht, Farbe und Details

**Licht** enthält die globalen Tonwertregler, natürlichen Bildausgleich,
Einzelregler-Automatik und HDR. **Farbe** enthält Profil, Weißabgleich,
Dynamik/Sättigung und Schwarzweiß. **Details** enthält Präsenz,
Detailvorschau, Schärfen und Entrauschen. Präzise Levels liegen unter
**Licht → Erweiterte Levels**; die ausdrückliche technische Migration liegt
unter **Bildstände → Erweitert**. Die Bedienungsdokumentation steht in
[Entwickeln](../DEVELOP-WORKSPACE.md), [Farbe](../DEVELOP-COLOR.md),
[Levels](../LEVELS-VALIDATION.md) und [Workspace-Layout](../WORKSPACE-LAYOUT.md).

## Aufnahmeaufbau und Quellen

Die Aufnahmen verwenden die tatsächliche `LibraryView` mit den
Produktionsansichten `DevelopInspector`, `LevelsInspector` und
`DevelopDetailPreview`. Das synthetische 768 × 512-Pixel-PNG zeigt eine
geometrische Landschaft und wird vom Test erzeugt. Private Testbilder,
persönliche Kataloge und lokale Bearbeitungen sind nicht beteiligt.

Die Hauptfenster sind 1440 × 900 und 1000 × 660 pt groß. Die bevorzugte
Werkzeugbreite ist jeweils 340 pt. Die JSON-Dateien unterscheiden bevorzugte
Breite, vom Produktionslayout begrenzte Breite und gemessene
Accessibility-Inhaltsbreite. Der Filmstreifen bleibt für den Vergleich
geschlossen. Die AppKit-Testfenster liegen außerhalb der sichtbaren
Arbeitsfläche und werden nicht aktiviert. Foto und Originalcanvas müssen
vor jeder Aufnahme vollständig geladen sein.

Die Navigation wird zuerst über die tatsächlichen Workspace-Aktionen geprüft.
Sie darf weder den angenommenen Bildstand noch dessen Revision ändern.
Anschließend lädt jeder Aufnahmefall einen frischen vollständigen
`LibraryView`-Host mit den gespeicherten Gruppenpräferenzen. Damit hat die
Scrollaufnahme keinen zuvor absichtlich auf den Gruppenheader gesetzten
SwiftUI-Fokus. Native Scrollposition und tatsächliche Sichtbarkeit des
angeforderten Controls werden geprüft. Fensterzustände bleiben geordnet;
Decodierung und Rendering nutzen die Produktionsworker im Hintergrund.

Ausgangsstand ist der unveränderte Commit
`dbde04d867d2aad7626bd4869a34b8197de10db8`. Die getrennte Archivkopie erhält
allein den zusätzlichen [Testaufbau](baseline-harness.patch). Die
[Baseline-Inventur](baseline-source-hashes.json) umfasst 302 App-/Paketdateien,
die byteweise gegen den Commit geprüft wurden. Die
[finale Inventur](source-hashes.json) bindet die Nachher-Aufnahmen an die
App-, Paket- und Testquellen des Arbeitsstands.

Dieser tatsächliche `main` enthält bereits **Licht**, **Farbe** und **Details**
aus vorangegangenen Workspace-Änderungen. Die in Issue 196 verlinkten älteren
Detail-Absätze sind dort bereits entfernt. Die Aufnahmen belegen den
verbliebenen Unterschied: HDR steht vorher bei Farbe, die technische
Migration direkt bei Licht und wichtige Aktionen haben kleine beziehungsweise
reine Symbolbeschriftungen. Sie werden nicht als Reproduktion des älteren
`c1108962`-Stands ausgegeben.

## Reproduktion

Baseline in einer getrennten Kopie des Ausgangscommits nach Anwendung des
oben verlinkten Harness-Patches:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-196-baseline-build \
GLOWROOM_196_BASELINE=1 \
GLOWROOM_196_SNAPSHOTS=/private/tmp/glowroom-196-before \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=dbde04d867d2aad7626bd4869a34b8197de10db8 \
./scripts/test.sh --jobs 3 --filter DevelopGroupingScreenshotTests
```

Nachher mit den finalen Produkt- und Testquellen:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-196-after-build \
GLOWROOM_196_SNAPSHOTS=/private/tmp/glowroom-196-after \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=working-tree \
./scripts/test.sh --jobs 3 --filter DevelopGroupingScreenshotTests
```

Die vorbereiteten Werte enthalten V1-Tonwertverarbeitung, aktive rote
Levels-Eingangsgrenzen und einen gemeinsamen Ausgangsweißwert von 0,98.
Navigation und Öffnen der Untergruppen erhalten diese Werte exakt.
Für die Levels-Aufnahmen ist die Lichtregler-Untergruppe geschlossen;
die Levels-Werte bleiben unverändert.

Die Migrationsprüfung öffnet den echten Dialog. Eine zwischenzeitliche
Änderung sperrt die Bestätigung, während **Abbrechen** aktiv bleibt.
Nach Abbruch, Undo und erneutem Öffnen wird ausdrücklich migriert;
anschließendes Undo stellt die bisherigen Werte einschließlich V1 wieder her.
Die Dialogbilder montieren nach Prüfung der echten Sheet-Route dieselbe
`ToneProcessingMigrationView` mit den gemessenen Sheet-Maßen in einem nativen
Ersatzhost mit Systemfensterhintergrund. Dies umgeht ausschließlich die
transparente Offscreen-Zwischenspeicherung der Sheet-Kulisse.

Die Fehleraufnahme verwendet eine kontrollierte Meldung im tatsächlichen
`DevelopWorkspace`. Sie behauptet keinen Systemfehler und keine fehlgeschlagene
Modellinferenz. HDR wird über den Produktionsschalter aktiviert, der
Verarbeitungsstatus wird abgewartet und anschließend werden mit Undo exakt
die bisherigen Einstellungen wiederhergestellt. Die Anzeige bestätigt keine
bestimmte Hardware-Helligkeit.

## Aufnahmen

Die JSONs neben den PNGs enthalten Zustand, Quellstand, Fenster-/Palettenmaße,
Fixture-/Screenshot-SHA-256, kanonisch sortierten Settings-SHA-256 und
macOS-Version. Alle 22 finalen Nachher-Aufnahmen wurden visuell geprüft. Die sechs
Hauptgruppenbilder wurden zusätzlich unabhängig geprüft; untere Details,
Levels-Kanäle/-Werte, Migration, Fehler und HDR erhielten keinen verbleibenden
Befund. Die Hauptaufnahmen haben bei zweifacher Skalierung
2880 × 1800 beziehungsweise 2000 × 1320 Pixel.

| Zustand | Vorher 1000 | Nachher 1000 | Vorher 1440 | Nachher 1440 |
| --- | --- | --- | --- | --- |
| Licht | [PNG](screenshots/before-light-1000.png), [JSON](screenshots/before-light-1000.json) | [PNG](screenshots/after-light-1000.png), [JSON](screenshots/after-light-1000.json) | [PNG](screenshots/before-light-1440.png), [JSON](screenshots/before-light-1440.json) | [PNG](screenshots/after-light-1440.png), [JSON](screenshots/after-light-1440.json) |
| Farbe | [PNG](screenshots/before-color-1000.png), [JSON](screenshots/before-color-1000.json) | [PNG](screenshots/after-color-1000.png), [JSON](screenshots/after-color-1000.json) | [PNG](screenshots/before-color-1440.png), [JSON](screenshots/before-color-1440.json) | [PNG](screenshots/after-color-1440.png), [JSON](screenshots/after-color-1440.json) |
| Details mit Präsenz und Vorschau | [PNG](screenshots/before-details-1000.png), [JSON](screenshots/before-details-1000.json) | [PNG](screenshots/after-details-1000.png), [JSON](screenshots/after-details-1000.json) | [PNG](screenshots/before-details-1440.png), [JSON](screenshots/before-details-1440.json) | [PNG](screenshots/after-details-1440.png), [JSON](screenshots/after-details-1440.json) |
| Untere Details: Schärfen/Entrauschen | [PNG](screenshots/before-details-lower-1000.png), [JSON](screenshots/before-details-lower-1000.json) | [PNG](screenshots/after-details-lower-1000.png), [JSON](screenshots/after-details-lower-1000.json) | [PNG](screenshots/before-details-lower-1440.png), [JSON](screenshots/before-details-lower-1440.json) | [PNG](screenshots/after-details-lower-1440.png), [JSON](screenshots/after-details-lower-1440.json) |
| Levels: Kanäle und Pipetten | [PNG](screenshots/before-levels-top-1000.png), [JSON](screenshots/before-levels-top-1000.json) | [PNG](screenshots/after-levels-top-1000.png), [JSON](screenshots/after-levels-top-1000.json) | [PNG](screenshots/before-levels-top-1440.png), [JSON](screenshots/before-levels-top-1440.json) | [PNG](screenshots/after-levels-top-1440.png), [JSON](screenshots/after-levels-top-1440.json) |
| Levels: fünf Parameter, Clamps und Resetumfang | [PNG](screenshots/before-levels-1000.png), [JSON](screenshots/before-levels-1000.json) | [PNG](screenshots/after-levels-1000.png), [JSON](screenshots/after-levels-1000.json) | [PNG](screenshots/before-levels-1440.png), [JSON](screenshots/before-levels-1440.json) | [PNG](screenshots/after-levels-1440.png), [JSON](screenshots/after-levels-1440.json) |

| Nachher-Zustand | 1000 × 660 pt | 1440 × 900 pt |
| --- | --- | --- |
| Bildstand-Migrationsaktion | [PNG](screenshots/after-migration-1000.png), [JSON](screenshots/after-migration-1000.json) | [PNG](screenshots/after-migration-1440.png), [JSON](screenshots/after-migration-1440.json) |
| Ausdrückliche Migrationsprüfung | [PNG](screenshots/after-migration-review-1000.png), [JSON](screenshots/after-migration-review-1000.json) | [PNG](screenshots/after-migration-review-1440.png), [JSON](screenshots/after-migration-review-1440.json) |
| Veralteter Bildstand: Bestätigung gesperrt | [PNG](screenshots/after-migration-stale-1000.png), [JSON](screenshots/after-migration-stale-1000.json) | [PNG](screenshots/after-migration-stale-1440.png), [JSON](screenshots/after-migration-stale-1440.json) |
| Lesbarer Fehler bei Einzelregler-Automatik | [PNG](screenshots/after-error-1000.png), [JSON](screenshots/after-error-1000.json) | [PNG](screenshots/after-error-1440.png), [JSON](screenshots/after-error-1440.json) |
| HDR-Verarbeitung und Hilfezugang | [PNG](screenshots/after-hdr-1000.png), [JSON](screenshots/after-hdr-1000.json) | [PNG](screenshots/after-hdr-1440.png), [JSON](screenshots/after-hdr-1440.json) |

## Prüfungen, Review und Grenzen

Die integrierte gezielte Prüfung bestand mit **123 Tests in zwölf Suites in
23,588 s**. Sie umfasst Levels-Oberfläche/-Navigation, automatische einzelne
Tonwertregler, natürlichen Bildausgleich, Detailvorschau im vollständigen
Workspace, Layout/Fokus und gemeinsame Historie.
Das lokale Log liegt unter `/private/tmp/glowroom-196-tests.log`.

Nach den finalen Schrift-, Beschriftungs- und Werkzeugleistenkorrekturen
bestand die zusätzliche Prüfung mit **13 Tests in zwei Suites in 20,363 s**:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-196-baseline-build \
./scripts/test.sh --jobs 3 --skip-build --no-parallel \
  --filter 'DevelopDetailWorkspaceIntegrationTests|LevelsInspectorNavigationTests'
```

Ein sauberer vollständiger App-Build ist erforderlich, weil die Oberfläche
das Laufzeitverhalten ändert. Nach Prozessprüfung wurden alte `.build/`-
Ergebnisse und `dist/Glowroom.app` entfernt; aktive isolierte Testpfade,
Quellen und Nutzerdaten blieben erhalten. Der erste Zwischenstand bestand
nach **394,29 s**. Das visuelle Review fand danach abgeschnittene Werkzeugnamen
bei fünf Spalten in der Schmalansicht sowie eine am ganzen DisclosureGroup
vererbte ID, welche die Migrationsaktion überschrieb. Die finale Leiste
verwendet drei Spalten und die ID steht nur am Erweitert-Label.

Der erneut sauber ausgeführte finale Release-Build bestand nach **380,81 s**
einschließlich Paketierung, Info.plist-Prüfung, ad-hoc Signierung und strenger
Signaturprüfung. Das Ergebnis liegt in `dist/Glowroom.app`, das lokale Log
unter `/private/tmp/glowroom-196-build-final.log`. Die spätere Verbesserung
des Screenshot-Aufbaus ändert keine Appquelle und erfordert keinen weiteren
App-Build.

Der erste Screenshot-Harness ließ die Fotodetailansicht geschlossen und
scheiterte am Timeout. Weitere Aufnahmen wurden bei der visuellen Prüfung
zurückgewiesen, weil der absichtlich gesetzte Gruppenfokus nach einem
Scrollversuch den Header wieder sichtbar machte. Diese Versuche gelten
nicht als Abnahme. Der finale Aufbau prüft normale Navigation getrennt von
den frischen vollständigen Aufnahmehosts und fordert tatsächliche
Controlsichtbarkeit. Es werden keine Screenshot-Pixel nachbearbeitet.

Die Abnahme beansprucht keine echte Modellinferenz, physische
VoiceOver-Nutzung, HDR-Displayhelligkeit oder Prüfung persönlicher
Vollkataloge. Sie bedient native Accessibility-Aktionen und ergänzt die
bestehenden Tastatur-/Fokusregressionen. Die Einzelregler-, Levels-,
natürlichen Bildausgleichs- und KI-Berechnungen bleiben getrennt; neue
Verarbeitungsalgorithmen oder Leistungsgewinne werden nicht behauptet.

Die finale native Nachher-Abnahme bestand mit **einem Test in zwei Fensterfällen
in 29,026 s** nach **20,79 s** Testkompilierung. Das lokale Log liegt unter
`/private/tmp/glowroom-196-after-complete.log`. Der Baselinelauf und die
maschinell zusammengefassten Ergebnisse stehen in [test-results.json](test-results.json).

Die finale Baseline bestand mit **einem Test in zwei Fensterfällen in
14,915 s** nach **96,91 s** erneuter Testkompilierung der exakt restaurierten
Originalquellen. Alle zwölf Baseline-Aufnahmen wurden visuell geprüft;
sechs Hauptgruppenbilder zusätzlich unabhängig. Beide Inventuren, sämtliche
34 Screenshot-Hashes und identische Fixture-/nicht-HDR-Settings-Hashes
wurden abschließend verifiziert. Es bleiben keine offenen Reviewbefunde.
