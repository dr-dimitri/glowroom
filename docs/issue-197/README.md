# UX-05: Gemeinsames Reparaturwerkzeug

**Reparieren** bündelt **Entfernen**, **Heilen**, **Kopierstempel** und **Rote Augen**. Die vier Modi sind beschriftet; der aktive Modus ist umrandet. Nur Entfernen bietet lokale KI, gezielte LaMa-Einrichtung und Personen-/Staubvorschläge. Quellwahl und Löschaktionen benennen ihren Umfang. Bedienung und Grenzen stehen in [Reparaturwerkzeuge](../REPAIR-TOOLS.md) und [Entwickeln](../DEVELOP-WORKSPACE.md).

## Native Aufnahme und Grenzen

Der opt-in-Test `DevelopRepairScreenshotTests` montiert die tatsächlichen Produktionsansichten `DevelopGeometryInspector` und `DevelopCanvasInteraction` in einem isolierten AppKit-Fenster. Das Foto stammt aus dem Produktionsrenderer `EditRenderer`. Dies belegt die Werkzeugoberfläche und ihre Eingabe-/Ausgabezustände; es ist kein Screenshot der vollständigen `LibraryView` oder eines persönlichen Katalogs.

Das identische synthetische Stillleben mit 900 × 600 Pixeln enthält zwei dunkle Flecken und eine rote Pupille. Der Test erzeugt es selbst. Originaldatei und SHA-256 werden nach der Bearbeitung geprüft; private lokale Testbilder sind nicht beteiligt. Die Fenster messen 1440 × 900 und 1000 × 660 pt, die Palette 340 pt. Native Scrollpositionen werden für untere Palettenbereiche geändert. Die AppKit-Fenster werden außerhalb des sichtbaren Desktops angelegt und nicht aktiviert; gemeinsame Fensterzustände bleiben geordnet, der Renderer arbeitet im Hintergrund.

Der Ausgangsstand ist `dc6209e67d4c83a317be73d0bf97f0622fb91585`. Die getrennte Archivkopie erhält allein den neuen [Screenshot-Harness](baseline-harness.patch). Die [Baseline-Inventur](baseline-source-hashes.json) bindet sämtliche App- und Paketquellen an diesen Commit. Dieser `main` enthält bereits die Zusammenführung des Entwickeln-Arbeitsbereichs aus Issue 193: Ein zusätzlicher Einstieg „Mit KI reparieren“ ist dort nicht mehr vorhanden. Die Vorher-Aufnahmen werden deshalb nicht als Reproduktion dieses älteren Zustands ausgegeben. Sie zeigen die verbleibende Symbolpalette, kleinen Texte und verfügbare/deaktivierte Aktionen.

Auf diesem Mac ist kein LaMa-Reparaturmodell installiert. Die Aufnahmen verwenden zusätzlich ein isoliertes leeres Modellverzeichnis und zeigen diesen echten Fehlzustand. Es gibt keine erfundene Aufnahme mit verfügbarem Modell und keinen behaupteten Modell-/Qualitätsnachweis. Die zwei Staubkandidaten werden gezielt aus dem synthetischen Fixture injiziert, um Auswahl, Nichtveränderung vor Bestätigung und Entfernung nur des ausgewählten Bereichs reproduzierbar zu prüfen. Das ist ein kontrollierter UI-Zustand, keine behauptete Staub- oder Personeninferenz. Die anschließende Komposition erfolgt tatsächlich über den vorhandenen Reparatur- und Renderpfad.

Die Rote-Augen-Aufnahme entsteht während eines nativen Mausziehens vor dem Loslassen. Danach wird dieselbe Geste abgeschlossen, die Korrektur gerendert und Undo geprüft. Beim Kopierstempel werden gespeicherte Quelle, Ziel und ausgewählte Reparatur mit den Produktionsmarkierungen gezeigt.

## Reproduktion

Baseline in der getrennten Archivkopie des Ausgangscommits mit dem zusätzlichen Harness:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-197-baseline-build \
GLOWROOM_197_BASELINE=1 \
GLOWROOM_197_SNAPSHOTS=/private/tmp/glowroom-197-before \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=dc6209e67d4c83a317be73d0bf97f0622fb91585 \
./scripts/test.sh --jobs 3 --filter DevelopRepairScreenshotTests
```

Nachher:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-197-baseline-build \
GLOWROOM_197_SNAPSHOTS=/private/tmp/glowroom-197-after \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=working-tree \
./scripts/test.sh --jobs 3 --no-parallel \
  --filter 'DevelopRepair|DevelopDetailWorkspaceIntegrationTests|DevelopWorkspaceTests|WorkspaceLayoutTests|WorkspaceFocusRoutingTests|DevelopGeometryRendererTests|WorkspaceGeometryTests'
```

Der Nachher-Lauf verwendet denselben Scratch-Pfad erst nach abgeschlossenem Baselinelauf und mit dem finalen Checkout als Paketquelle. Dadurch können unveränderliche Paketabhängigkeiten weiterverwendet werden; Baselinequellen bleiben unverändert.

Die JSON-Dateien neben den PNGs dokumentieren Quellstand, Fenster-/Palettenmaße, Modellstatus, Kandidaten-/Auswahl-/Reparaturzahlen, den Settings-, Fixture- und Screenshot-SHA-256 sowie die macOS-Version. Alle 20 PNG-Hashes sowie der gemeinsame Fixture-Hash wurden geprüft; die neutralen Vorher-/Nachher-Settings stimmen überein. Die [finale Inventur](source-hashes.json) bindet die Implementierung und die abschließend erneut aufgenommenen visuellen Zustände an 559 App-, Core-, Paket- und Testdateien.

## Prüfung und Build

Der Baselinelauf bestand mit einem Test in zwei Fensterfällen nach 1,806 s; die vollständige isolierte Testkompilierung benötigte 333,49 s. Alle vier Vorher-Aufnahmen wurden visuell geprüft: das Foto ist vollständig gerendert, die Symbolmodi und kleinen bisherigen Einrichtungsschaltflächen sind sichtbar. Der lokale Baselinelog liegt unter `/private/tmp/glowroom-197-baseline.log`.

Ein vollständiger sauberer App-Build ist erforderlich, weil Werkzeugrouting, Eingaben und SwiftUI-Oberflächen das Laufzeitverhalten ändern. Der erste Buildversuch schlug fehl, weil sich Eingabedateien während des Builds änderten; er gilt nicht als bestandene Prüfung. Nach Ende dieses Prozesses und Prüfung auf verbliebene Worker wurden die alten generierten Ergebnisse erneut entfernt und ein zweiter sauberer Build gestartet. Der isolierte Testpfad blieb dabei erhalten. Das Protokoll dieses später kontrolliert beendeten Versuchs liegt unter `/private/tmp/glowroom-197-build-final.log`.

Der erste integrierte Nachher-Lauf kompilierte erfolgreich in 151,08 s. Er führte 208 Tests in 22 Suites aus und scheiterte nach 67,742 s an einem neuen Testaufbau: Nach Quellenwechsel suchte der Test die zu Recht entfernte Rote-Augen-Eingabefläche erneut, statt das verspätete Mouse-up an die ursprünglich gehaltene Fläche zu senden. Der korrigierte Test bewahrt diese alte native Fläche, um genau die verspätete Eingabe zu prüfen.

Das anschließende visuelle Review fand eine bestehende Überlagerungsstörung: kleine Kandidatenmasken färbten die gesamte Bildfläche ein. Die Anzeige verwendet nun eine native Core-Graphics-Maske mit ausdrücklicher Abdeckung (0 transparent, 255 deckend), ohne nachgeschaltete SwiftUI-Luminanzumwandlung. Ein nativer Pixelvergleich prüft die unveränderte Fläche außerhalb der Maske. Gespeicherte Masken und der Renderer werden dadurch nicht verändert. Die Einzahl bei einer Augenkorrektur beziehungsweise einem entfernten Bereich wurde ebenfalls korrigiert.

Ein weiterer laufender Release-Build wurde vor diesen Korrekturen kontrolliert beendet. Auch dieser Zwischenstand gilt nicht als finale Buildprüfung. Vor dem abschließenden Neuaufbau werden Prozessende und generierte Verzeichnisse erneut geprüft; die endgültige Abnahme muss die korrigierten Quellen enthalten.


Der korrigierte integrierte Lauf bestand mit **209 Tests in 23 Suites in 68,826 s** nach 35,15 s inkrementeller Testkompilierung. Die neue native Pixelregression bestand für Kandidaten- und gespeicherte Masken; die Screenshot-Abnahme bestand in beiden Fenstergrößen nach 9,974 s. Alle 16 finalen Nachher-Aufnahmen wurden visuell geprüft. Masken markieren nur die ausgewählten Bildbereiche, Quell-/Zielpunkte bleiben erkennbar, Status und Aktionen verwenden lesbare Schrift. Die schmale Palette scrollt bei erweiterten Einrichtungen und Kandidatenlisten; die Modusansichten beginnen wieder oben. Das lokale Log liegt unter `/private/tmp/glowroom-197-final-tests-retry.log`; die maschinenlesbaren Ergebnisse stehen in [test-results.json](test-results.json).

Das abschließende Schnittstellenreview fand zusätzlich eine Historiengrenze beim Wechsel zu Rote Augen. Alle vier Modi verwenden nun dieselbe Reparaturhistorie. Bereits angenommene Pinselzüge und Augenkorrekturen bleiben beim Moduswechsel gemeinsam rückgängig und wiederholbar; erst der Wechsel zu einem anderen Werkzeug beginnt eine neue Historie. Die Korrektur betrifft die Historienzuordnung, nicht das sichtbare Layout oder die aufgenommenen Bildzustände. Die gezielte abschließende Prüfung mit dem tatsächlichen vollständigen Inspektor und den nativen Eingabeflächen bestand mit **40 Tests in vier Suites in 50,918 s** nach 47,80 s Testkompilierung. Das Log liegt unter `/private/tmp/glowroom-197-history-final.log`.

## Aufnahmen

| Ausgangszustand | 1000 × 660 pt | 1440 × 900 pt |
| --- | --- | --- |
| Symbolpalette und fehlendes Modell | [PNG](screenshots/before-remove-missing-model-1000.png), [JSON](screenshots/before-remove-missing-model-1000.json) | [PNG](screenshots/before-remove-missing-model-1440.png), [JSON](screenshots/before-remove-missing-model-1440.json) |
| Bisherige Erkennungsaktionen | [PNG](screenshots/before-detection-actions-1000.png), [JSON](screenshots/before-detection-actions-1000.json) | [PNG](screenshots/before-detection-actions-1440.png), [JSON](screenshots/before-detection-actions-1440.json) |

| Gemeinsames Reparaturwerkzeug | 1000 × 660 pt | 1440 × 900 pt |
| --- | --- | --- |
| Beschriftete Modi und fehlendes LaMa-Modell | [PNG](screenshots/after-remove-missing-model-1000.png), [JSON](screenshots/after-remove-missing-model-1000.json) | [PNG](screenshots/after-remove-missing-model-1440.png), [JSON](screenshots/after-remove-missing-model-1440.json) |
| Gezielte Modelleinrichtung geöffnet | [PNG](screenshots/after-model-setup-1000.png), [JSON](screenshots/after-model-setup-1000.json) | [PNG](screenshots/after-model-setup-1440.png), [JSON](screenshots/after-model-setup-1440.json) |
| Personen-/Staubaktionen | [PNG](screenshots/after-detection-actions-1000.png), [JSON](screenshots/after-detection-actions-1000.json) | [PNG](screenshots/after-detection-actions-1440.png), [JSON](screenshots/after-detection-actions-1440.json) |
| Kopierstempel mit ausgewählter Quelle und Ziel | [PNG](screenshots/after-clone-source-target-1000.png), [JSON](screenshots/after-clone-source-target-1000.json) | [PNG](screenshots/after-clone-source-target-1440.png), [JSON](screenshots/after-clone-source-target-1440.json) |
| Zwei kontrollierte Staubkandidaten, einer ausgewählt | [PNG](screenshots/after-dust-candidates-1000.png), [JSON](screenshots/after-dust-candidates-1000.json) | [PNG](screenshots/after-dust-candidates-1440.png), [JSON](screenshots/after-dust-candidates-1440.json) |
| Angenommene Entfernung nur des ausgewählten Bereichs | [PNG](screenshots/after-accepted-removal-1000.png), [JSON](screenshots/after-accepted-removal-1000.json) | [PNG](screenshots/after-accepted-removal-1440.png), [JSON](screenshots/after-accepted-removal-1440.json) |
| Rote Augen während der Ellipsenauswahl | [PNG](screenshots/after-red-eye-ellipse-1000.png), [JSON](screenshots/after-red-eye-ellipse-1000.json) | [PNG](screenshots/after-red-eye-ellipse-1440.png), [JSON](screenshots/after-red-eye-ellipse-1440.json) |
| Angenommene Augenkorrektur mit Löschaktionen | [PNG](screenshots/after-red-eye-accepted-1000.png), [JSON](screenshots/after-red-eye-accepted-1000.json) | [PNG](screenshots/after-red-eye-accepted-1440.png), [JSON](screenshots/after-red-eye-accepted-1440.json) |


## Abschließende Historienprüfung

Nach der gemeinsamen Historienzuordnung wurden ausschließlich die betroffenen Schnittstellen erneut geprüft:

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-197-baseline-build \
./scripts/test.sh --jobs 3 --no-parallel \
  --filter 'DevelopRepairToolbarTests|DevelopRepairCanvasInputTests|DevelopDetailWorkspaceIntegrationTests|EditingHistoryBudgetTests'
```

Der native vollständige Inspektor prüft bei 280 und 340 pt eine angenommene Pinselreparatur und eine Augenkorrektur, Modus-/Werkzeugleistenwechsel und gemeinsames Undo/Redo. Nach dieser Korrektur wurde die Screenshot-Abnahme einmal ohne Neubuild gegen denselben final geprüften Teststand wiederholt: ein Test mit beiden Fensterfällen bestand nach **9,897 s**. Alle 16 Nachher-PNGs sind byteweise identisch mit den zuvor visuell geprüften Aufnahmen. Sämtliche 20 PNG-Hashes einschließlich Baseline sowie die 559 Hashes der [finalen Quelleninventur](source-hashes.json) wurden erneut geprüft. Das Log liegt unter `/private/tmp/glowroom-197-screenshots-final.log`.

```sh
GLOWROOM_TEST_BUILD_PATH=/private/tmp/glowroom-197-baseline-build \
GLOWROOM_197_SNAPSHOTS=/private/tmp/glowroom-197-after \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=working-tree \
./scripts/test.sh --jobs 3 --skip-build --no-parallel --filter DevelopRepairScreenshotTests
```


Das Abschlussreview umfasst Werkzeugrouting, gemeinsame Historie, native Eingaben, Abbruch-/Quellenwechsel, Modellauskunft, Maskenüberlagerungen, Tests und Dokumentation. Die gefundenen Überlagerungs-, Einzahl-, Historien- und Testaufbaufehler sind behoben und passend erneut geprüft; es bleibt kein offener Reviewbefund. Die reale LaMa-Inferenz bleibt mangels installiertem Modell ausdrücklich unbelegt. Die native UI-Abnahme und kontrollierten Dienste ersetzen diesen Qualitätsnachweis nicht; es werden keine zusätzlichen Modellfähigkeiten oder Leistungsgewinne behauptet.

Nach erfolgreicher Prüfung wurden erneut sämtliche alten generierten `.build/`-Ergebnisse sowie verwaiste Build-Staging-/Lock-Dateien und `dist/Glowroom.app` erst nach bestätigtem Prozessende entfernt. `.build-app/` war nicht vorhanden; der isolierte Testpfad blieb erhalten. Der dritte saubere vollständige App-Build mit `./scripts/build-app.sh` bestand mit den final geprüften Quellen (Exit 0). Die Release-Kompilierung benötigte **321,32 s**; anschließend bestanden Paketierung, Info.plist-Prüfung, ad-hoc Signierung und strenge Signaturprüfung. Eine zusätzliche unabhängige Prüfung mit `codesign --verify --strict dist/Glowroom.app` bestand ebenfalls. Das Bundle liegt unter `dist/Glowroom.app`, das Protokoll unter `/private/tmp/glowroom-197-build-verified.log`.
