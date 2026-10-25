# UX-00: Abschluss der gemeinsamen Glowroom-Oberfläche

**Issue:** [#201](https://github.com/dr-dimitri/glowroom/issues/201). **Stand: 25.10.2026, alle acht Teilaufgaben umgesetzt und zusammengeführt.** Der geprüfte Integrationsstand ist [`d24966dc8f1ca4e7214fdf13a6238c475b0a82ba`](https://github.com/dr-dimitri/glowroom/commit/d24966dc8f1ca4e7214fdf13a6238c475b0a82ba). Der Abschluss dieses übergeordneten Issues gleicht die bisher veraltete Gesamtübersicht mit der bereits gelieferten App ab.

## Gelieferter Umfang

**Bibliothek** und **Entwickeln** sind die beiden Hauptbereiche. Entwickeln verbindet den ausdrücklich angeforderten KI-Korrekturvorschlag mit Licht, Farbe, Details und den Werkzeugen Zuschneiden, Maskieren und Reparieren. Dasselbe Foto, angenommene Bearbeitungen und der gemeinsame Verlauf bleiben die Grundlage. Bildinformationen verwenden ein gemeinsames manuelles und KI-gestütztes Formular. Suche steht in der Bibliothek; **KI-Modelle** bündelt die Einrichtung auch ohne ausgewähltes Foto.

Die Bedienung verwendet verständliche Namen, sichtbare Auswahl und konkrete Aktionen. Erklärungen stehen in ausdrücklich geöffneter Hilfe in normaler Textgröße. Feldnamen, Werte, Einheiten, reale Fehler, Fortschritt und Entwurfszustände bleiben sichtbar; Status und Fehler verwenden mindestens 13 pt. Bestehende Algorithmen, Modellqualifizierung und Verfügbarkeitsgrenzen bleiben erhalten. Die Rauschminderung trägt kein KI-Etikett. Rote Augen, HDR, erweiterte Levels, Tastaturwege und Bildstände bleiben erreichbar.

| Teilaufgabe | In `main` zusammengeführt | Funktions- und Abnahmenachweis |
| --- | --- | --- |
| [#193 · UX-01](https://github.com/dr-dimitri/glowroom/issues/193) | [PR #203](https://github.com/dr-dimitri/glowroom/pull/203), `68a5422` | [Gemeinsames Entwickeln, Navigation und Bildfokus](../issue-193/README.md) |
| [#194 · UX-02](https://github.com/dr-dimitri/glowroom/issues/194) | [PR #204](https://github.com/dr-dimitri/glowroom/pull/204), `433ead6` | [Korrekturvorschlag am Foto, Vergleich, Übernahme und Undo](../issue-194/README.md) |
| [#195 · UX-03](https://github.com/dr-dimitri/glowroom/issues/195) | [PR #205](https://github.com/dr-dimitri/glowroom/pull/205), `dbde04d` | [Gemeinsame manuelle und KI-Objektmaskierung](../issue-195/README.md) |
| [#196 · UX-04](https://github.com/dr-dimitri/glowroom/issues/196) | [PR #206](https://github.com/dr-dimitri/glowroom/pull/206), `dc6209e` | [Licht, Farbe, Details und erweiterte Tonwerte](../issue-196/README.md) |
| [#197 · UX-05](https://github.com/dr-dimitri/glowroom/issues/197) | [PR #207](https://github.com/dr-dimitri/glowroom/pull/207), `fda1b7b` | [Entfernen, Heilen, Kopierstempel und Rote Augen](../issue-197/README.md) |
| [#198 · UX-06](https://github.com/dr-dimitri/glowroom/issues/198) | [PR #209](https://github.com/dr-dimitri/glowroom/pull/209), `846aecb` | [Gemeinsames Bildinformationen-Formular und Entwürfe](../issue-198/README.md) |
| [#199 · UX-07](https://github.com/dr-dimitri/glowroom/issues/199) | [PR #210](https://github.com/dr-dimitri/glowroom/pull/210), `cde2666` | [Bibliothekssuche und zentrale Modellverwaltung](../issue-199/README.md) |
| [#200 · UX-08](https://github.com/dr-dimitri/glowroom/issues/200) | [PR #211](https://github.com/dr-dimitri/glowroom/pull/211), `d24966d` | [Übergreifende Text-, Layout- und Tastaturabnahme](../issue-200/README.md) |

Alle acht Teilissues sind auf GitHub geschlossen. Frühere offene Aufgaben und Zukunftsformulierungen in ihren ursprünglichen Konzepttexten beschreiben den damaligen Ausgangsstand. Die verlinkten Abschlussberichte dokumentieren die jeweils gelieferte Umsetzung und deren Prüfgrenzen.

## Gemeinsame Abschlusskriterien

- [x] Alle acht Teilaufgaben sind in `main` integriert; ihre Abschlussberichte sind oben zugeordnet.
- [x] Ein sichtbarer Entwickeln-Bereich; gemeinsame Zuständigkeit von Vergleich, Undo/Redo und Speicherstatus. Filter und Sortierung erscheinen in der Bibliotheks-Einzelbildansicht einmal.
- [x] Keine kleinen erklärenden Hinweise in der normalen Bedienung. Die übergreifende Abnahme aus UX-08 umfasst Entwickeln, Maskieren, Reparieren, Bildinformationen, Modellzustände und Export.
- [x] Native Vorher-/Nachher-Nachweise und Reproduktionsschritte liegen bei den Teilaufgaben. UX-08 ergänzt beide Fenstergrößen 1000 × 660 und 1440 × 900 pt mit Quellreferenzen, Skalierung, Fixture und Schritten.
- [x] Vorschlag/Übernehmen/Verwerfen, globale und lokale Wirkung sowie fehlende Modelle, Fehler und Abbruch besitzen eigene Zustände. Funktionale Tests ergänzen die Bildnachweise um Speicherung, Undo und veraltete Ergebnisse bei Bildwechseln.
- [x] Tastaturdurchgang und native automatisierte Accessibility-Prüfungen sind dokumentiert. Die manuelle VoiceOver-Abnahme und zusätzliche VoiceOver-Anpassungen wurden auf ausdrücklichen Nutzerwunsch vom 25.10.2026 aus dem Umfang genommen; siehe [abschließende Umfangsänderung](../issue-200/README.md#abschlussprüfung-nach-der-nutzeränderung-vom-25102026).
- [x] Bedienungsdokumentation, Reviews, Regression und erforderliche saubere App-Builds sind bei den Implementierungs-PRs dokumentiert. Die Abschlussprüfung dieses Issues steht im folgenden Abschnitt.

## Integrationsprüfung von #201

Drei unabhängige Teilreviews prüften Masken/Reparieren, Bildinformationen/Suche/Modelle und Gruppierung/Text/Layout. Hinzu kommt die Prüfung der gemeinsamen Navigation und des KI-Korrekturpfads. Es wurden keine offenen Implementierungsfehler gefunden. Korrigiert wurden widersprüchliche Abschlussangaben in der README und im ursprünglichen UI-Konzept. Das unabhängige Review des finalen Dokumentationsdiffs einschließlich Links, Schnittstellenverweisen und Prüfbehauptungen ergab keine offenen Befunde.

Die erneute Integritätsprüfung aller acht Abnahmeordner bestätigt 197 PNG-/JSON-Paare mit passenden Screenshot-Hashes und Bildmaßen, 20 Manifestbindungen und 457 vorhandene lokale Markdown-Ziele. Die 15 Quellinventare enthalten 6781 Einträge: 6778 stimmen direkt mit dem zugeordneten Implementierungscommit überein, die drei ergänzten Baseline-Harness-Dateien stimmen mit den veröffentlichten Patches überein. Alle 16 zugeordneten Commits sind lokal vorhanden. Bei 54 Aufnahmen ist die 2×-Skalierung aus Pixel- und Punktmaßen abgeleitet, bei den übrigen 143 ist sie ausdrücklich gespeichert. Diese Prüfung bestätigt Integrität und Herkunft; sie ist keine erneute visuelle Abnahme oder Reproduktion der Laufzeit-Fixture-/Einstellungsdigests.

Die gezielte Regression auf dem oben genannten Integrationsstand prüft die fachlichen Grenzen gemeinsam: Navigation und Fokus, gemeinsame Bildstände, temporäre Korrekturvorschläge mit ausdrücklicher Übernahme, Maskenabbruch und veraltete Ergebnisse, Reparaturtransaktionen, Metadatenentwürfe und Speicherung sowie erhaltene Suchzustände und zentrale Modelle. Die native Text-/Layout-Suite wird für beide Fenstergrößen aktiviert.

**Ergebnis: 155 Tests in 13 Suites erfolgreich, 65,915 Sekunden Testlaufzeit.** Die Testkompilierung bestand in 273,87 Sekunden. Der Lauf enthält die aktivierte native Text-/Layout-Suite bei beiden Fenstergrößen. Die folgende Reproduktion entspricht dem geprüften Aufruf; App-Quellen und Tests wurden für diesen Abschluss nicht geändert.

Reproduktion auf macOS mit Fensterserver und Paketauflösung:

```sh
GLOWROOM_200_SNAPSHOTS=/private/tmp/glowroom-201-integration \
GLOWROOM_WORKSPACE_SNAPSHOT_COMMIT=d24966dc8f1ca4e7214fdf13a6238c475b0a82ba \
./scripts/test.sh --jobs 4 --no-parallel \
  --filter 'WorkspaceLayoutTests|WorkspaceFocusRoutingTests|WorkspaceMenuTrackingTests|WorkspaceSaveStatusTests|WorkspaceProposalLifecycleTests|AICorrectionReviewWorkspaceTests|InlineObjectMaskWorkspaceTests|DevelopRepairWorkspaceTests|PhotoMetadataModelTests|SemanticLibraryTests|AIModelsManagerTests|LibraryHeadingTests|UIClarityScreenshotTests'
```

AppKit-/UI-Prüfungen laufen geordnet, weil sie gemeinsamen Fenster- und Fokuszustand verwenden. Kompilierung, unabhängige Quellreviews und Evidenzprüfung nutzen Parallelität. Die Tests benötigen keine privaten Fotos aus `Fixtures/LocalTestImages/` und führen keine reale Modellinferenz durch. Die ursprünglichen veröffentlichten Bildnachweise bleiben bei den Teilissues; lokal wiederholte Aufnahmen ersetzen sie nicht.

Für diesen Abschluss ist **kein neuer sauberer App-Build erforderlich**: Geändert werden ausschließlich Dokumentation und Abschlussstatus. App-Quellen, eingebundene Ressourcen, Paketauflösung und Buildskripte bleiben unverändert. Der letzte erforderliche saubere Release-Build auf demselben Produktionsstand bestand laut [UX-08-Abschlussprüfung](../issue-200/README.md#abschlussprüfung-nach-der-nutzeränderung-vom-25102026) in 327,28 Sekunden; die dortige vollständige Regression bestand mit 2005 Tests in 276 Suites. Diese historischen Ergebnisse werden von der aktuellen gezielten Integrationsprüfung getrennt ausgewiesen.

## Grenzen der Nachweise

Die nativen Aufnahmen zeigen echte Produktionsansichten mit synthetischen, veröffentlichbaren Testmotiven. Kontrollierte Modellantworten belegen Bedienung und Zustandsübergänge; sie belegen keine reale Inferenz, Segmentierungsqualität oder Leistung. Die jeweiligen Berichte kennzeichnen abweichende Baseline-Harnesses und Aufnahmegrößen ausdrücklich. Es wird keine vollständige VoiceOver-Abnahme behauptet. Die eigenständigen Modell-/Algorithmusvorhaben #181 bis #184 bleiben außerhalb dieses UI-Abschlusses.
