# Umbenennung zu Glowroom

Issue [#48](https://github.com/dr-dimitri/glowroom/issues/48) benennt die vorhandene Anwendung und dasselbe GitHub-Repository in Glowroom um. Das bisherige Repository wird an Ort und Stelle umbenannt; seine Git-Historie, Issues, Pull Requests und Releases bleiben beim vorhandenen Repository.

## Aktuelle Identität

| Bereich | Name oder Pfad |
| --- | --- |
| SwiftPM-Paket, App-Produkt und App-Modul | `Glowroom` |
| Core-Modul | `GlowroomCore` |
| Tests | `GlowroomTests`, `GlowroomCoreTests` |
| App-Bundle und ausführbare Datei | `dist/Glowroom.app`, `Contents/MacOS/Glowroom` |
| Bundle-ID | `de.wolfgangbauer.glowroom` |
| App-Daten | `~/Library/Application Support/Glowroom/` |
| Vorschau-Cache | `~/Library/Caches/Glowroom/Previews-v2` |
| Sicherungspakete | `.glowroombackup` |
| Entwickleroptionen und Compile-Flags | `GLOWROOM_*` |
| Repository | `https://github.com/dr-dimitri/glowroom` |

Glowroom verwendet einen frischen Datenbereich. Es migriert keine PicEdit-Daten und bietet keine alten Umgebungsvariablen, Dateiendungen oder Pfade als Aliase an. PicEdit-Kataloge, Modelle, Einstellungen, Caches und Sicherungen bleiben bestehen und werden weder automatisch gesucht noch gelesen, kopiert oder verändert. Ein ausdrücklich über `--catalog-directory` gewählter Katalogpfad ist weiterhin eine bewusste Auswahl des Aufrufers; daraus entsteht keine automatische Migration. Originalbilder bleiben an ihren bisherigen Orten und können neu zur Glowroom-Bibliothek hinzugefügt werden.

Der aktuelle Produktstand enthält keine Anthropic-/Cloud-Einstellungen, keinen Anthropic-Keychain-Service und keinen Cloud-Consent-Pfad mehr. Die ältere Formulierung des Issues führt diese entfernten Funktionen nicht wieder ein. Frühere Cloud-Schlüssel und Einwilligungen werden weder gelesen noch migriert; diese Umbenennung löst keine Cloud-Aufrufe aus. Es gibt deshalb keinen aktiven Service `de.wolfgangbauer.picedit.anthropic`, der zusätzlich umzubenennen oder mit Live-Cloud-Anfragen zu prüfen wäre.

## Reihenfolge für Repository und lokale Checkouts

1. Die Quellumbenennung als Aufgabenbranch vom aktuellen `main` des bestehenden Repositorys erstellen. Finale Änderungen unabhängig reviewen, passende Tests und einen sauberen vollständigen App-Build ausführen. Den geprüften Pull Request zuerst im bestehenden Repository gegen `main` mergen.
2. Danach das vorhandene GitHub-Repository in `glowroom` umbenennen. Kein neues Repository und keinen neuen Mirror anlegen. GitHub-Historie, Issues, Pull Requests, Releases und die Weiterleitungen der alten Repository-, Issue-, PR- und Release-URLs prüfen.
3. Repository-Einstellungen einschließlich Standardbranch, Branch-Schutz/Rulesets, Actions, Zugriffsrechte, Webhooks, Pages und Integrationen prüfen. Keine erforderlichen Reviews oder Statusprüfungen umgehen. Verbleibende externe Einstellungen ohne ausreichende Rechte als konkrete Hindernisse dokumentieren.
4. In jedem vorhandenen Checkout den Remote aktualisieren und den gemergten Stand prüfen:

   ```sh
   git remote set-url origin https://github.com/dr-dimitri/glowroom.git
   git switch main
   git pull --ff-only
   git remote -v
   git status --short
   ```

5. Den bestätigten Merge auf dem aktualisierten `main` und die kanonischen GitHub-URLs prüfen. Den abgeschlossenen Aufgabenbranch lokal sicher und auf dem Remote löschen; `main` bleibt erhalten. Ein bestehender lokaler Checkoutordner darf seinen früheren Namen behalten: Build- und Testskripte bestimmen den Stamm aus ihrem eigenen Pfad.

## Absichtlich erhaltene historische Namen

Historische Prüfberichte und gemessene Ergebnisse bezeichnen den tatsächlich geprüften PicEdit-Stand weiterhin als PicEdit. Das betrifft insbesondere die eingefrorenen LC-01–LC-06-Berichte und Vergleichstabellen in `docs/LIGHTCRAFT-*.md`, frühere Review-/Buildnachweise sowie die drei Messdateien `tools/subject-matting/qualification.json`, `deployment-1920.json` und `resolution-experiments.json`. Diese Zahlen sind keine neuen Glowroom-Messungen. Aktuelle Reproduktionsbefehle, Quellpfade und GitHub-Links verwenden Glowroom.

Die gespeicherten numerischen Orakel unter `tools/lightcraft-evaluation/*-reference-oracle/vectors.json`, unveränderte Upstream-Lizenz-/NOTICE-Texte und `tools/sdxl-evaluation/provenance/` bleiben als Herkunftsnachweise unverändert. Die LC-06-Orakelbeschreibung enthält deshalb noch den historischen Projektnamen. Die eigene aktuelle Produktzuordnung im Lightcraft-Änderungsnachweis heißt Glowroom; darin referenzierte unveränderte Upstream-Lizenztexte behalten ihren Wortlaut. Aktive Evaluatoren, Adapterbezeichnungen, JSON-Ausgaben, C++-Namespaces, Compile-Flags und Hilfsprogramme verwenden Glowroom; eigene aktuelle Hilfsprogramm-/Patch-Hashes werden nach deren Umbenennung neu berechnet.

Der lokale Core-ML-Konverter für das freigegebene Motivmodell erhält den kanonischen UUID-Seed `picedit-subject-matting-v1:`, seine internen Python-Herkunftsnamen, Autoren-/Beschreibungsmetadaten und die vier `picedit.subjectMatting.*`-Schlüssel. Diese Werte sind Teil der bereits freigegebenen Modellbytes. Ebenso bleiben die in den freigegebenen semantischen Modellgraph eingebettete Autorenzeile des Konverters und `SemanticLicenses/CONVERSION-NOTICE.txt` bytegleich. Eine kosmetische Änderung würde die Modellprüfung und reproduzierbare Konvertierung beschädigen; diese Herkunftswerte definieren keine App-Datenpfade oder alten Produkt-Aliase.

`tools/workspace-layout/measure-baseline.py` liest zwei Quelldateien ausdrücklich aus einem festgehaltenen historischen Git-Commit unter `Sources/PicEdit/`. Dieser unveränderliche Git-Pfad muss weiter existieren; die temporäre Testkopie verwendet danach die aktuellen Glowroom-Module und Testoptionen.

## Abschlussnachweis

Commit, Pull Request, Review, Tests, sauberer App-Build, bestätigter Merge, Repository-Umbenennung, Weiterleitungen und Einstellungsprüfung werden im zugehörigen Pull Request und im Arbeitsbericht festgehalten. Historische Testergebnisse in anderen Dokumenten ersetzen diese Prüfung der Umbenennung nicht.
