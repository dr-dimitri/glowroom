# Reparaturhelligkeit und bedienbare Modustasten

Stand: 31. Oktober 2026. Ergänzt die [vorherige Ringanpassung](REPAIR-QUALITY.md).
Bedienung: [Reparaturwerkzeuge](REPAIR-TOOLS.md).

## Ursache und Änderung

Heilen und Entfernen ohne KI verglichen bisher ausschließlich die äußeren
Quell- und Zielränder. Eine helle Fläche im Inneren der Quelle konnte deshalb
in der Reparatur zu hell bleiben, obwohl die Randfarben übereinstimmten.
Dasselbe Problem trat mit dunklen Quellflächen auf.

Der Renderer schätzt nun die Zielbeleuchtung aus dem sauberen Außenring und
die Quellbeleuchtung separat auch innerhalb der kopierten Fläche. Die
Quellschätzung verwendet eine engere Gauß-Glättung (0,2 Pinselradien), die
Zielschätzung 0,6 Radien, jeweils mindestens einen Pixel. Die Differenz
gleicht großflächige Helligkeits- und Farbunterschiede aus; feine Quelltextur
bleibt erhalten. Zusätzlich wird die lokale Quellsteigung mit dem Versatz
der gewichteten Zielringmitte verrechnet. Das bewahrt passende lineare
Verläufe auch abseits der Pinselmitte. Beide Schätzungen berücksichtigen Alpha. Ohne gültigen
Kontext bleibt die Quelle unkorrigiert. Masken, Deckkraft, Außenpixel und
Originalalpha behalten ihre bisherige Bedeutung. Kopierstempel, historische
Punktkorrekturen und eingefrorene KI-Pixel verwenden ihre bisherigen Pfade.

Die Glättung skaliert mit der Bildauflösung. Sie kann weder verdeckte Motive
rekonstruieren noch jede Strukturkante passend fortsetzen; die Quellwahl
bleibt entscheidend. Große Quellstrukturen werden bei der Anpassung bewusst
verändert. Ein passender Pinselradius und kleine Teilreparaturen helfen bei
schwierigen Motiven. Die Verlaufskorrektur übernimmt die lokale Quellsteigung;
unterscheiden sich Quell- und Zielverlauf deutlich, können abseits der Mitte
weiterhin Helligkeitsreste bleiben. Sie rekonstruiert keine beliebige
Zielbeleuchtung vollständig.

Die Modustasten waren mit bildabhängigen Aktionen gemeinsam gesperrt,
solange eine Reparatur lief oder die Originalvorschau noch nicht bereitstand.
Sie benötigen jetzt nur noch einen bearbeitbaren Editor. Ein Wechsel
zwischen Entfernen, Heilen, Kopierstempel und Rote Augen verwendet die
bestehende Abbruchlogik: Noch nicht angenommene Aufträge enden, verspätete
Ergebnisse werden verworfen, angenommene Korrekturen und Undo/Redo bleiben.

## Reproduzierbare Prüfung

Die neuen synthetischen Qualitätsfälle kombinieren helle und dunkle
Quellmitten mit einer bekannten Zielbeleuchtung und feiner Quelltextur.
Sie prüfen zusätzlich unterschiedliche Quell-/Zielalphawerte, Teildeckkraft,
unverändertes Kopieren, einen übereinstimmenden linearen Quell-/Zielverlauf
an fünf Positionen innerhalb der Auswahl, doppelte Ausgabeauflösung und einen
softwarebevorzugten Core-Image-Kontext. Die vorhandenen Fälle decken
nahe Quellen, lange Verläufe, getrennte Masken, fehlenden Kontext,
unveränderte Außenpixel und Alpha ab. Eine vollständige Bildreferenz prüft
die Begrenzung des Produktionsgraphen auf den Reparaturausschnitt.

Native Inspector-Tests betätigen alle vier Modustasten bei noch fehlender
Originalvorschau und während einer angehaltenen zweiten Reparatur. Nach
deren verspäteter Rückkehr muss die erste angenommene Reparatur unverändert
bleiben und sich weiterhin rückgängig machen und wiederholen lassen.

```sh
./scripts/test.sh --configuration release --jobs 4 \
  --filter 'DevelopRepair|DevelopGeometryRendererTests|LevelsRetouchSamplingTests|DevelopWorkspaceTests|WorkspaceGeometryTests|AdjustedPreview|EditingRenderSession|JPEGExport'
```

Die optionale Fotodiagnose vergleicht jetzt ausdrücklich mit dem unmittelbar
vorherigen lokalen Ringverfahren, nicht mit dessen älterem globalen
Vorgänger. Drei lokale JPEGs liefern bekannte saubere Referenzpixel für
künstliche Defekte in Wand, Himmel und Wasser; pro Motiv werden manuelle und
automatische Quellen geprüft. Originalbytes werden per SHA-256 geprüft,
Ableitungen bleiben in einem neuen temporären Verzeichnis. Die privaten
Fixtures fehlen in CI und frischen Checkouts; ohne ausdrückliche
Umgebungsvariable wird diese Diagnose übersprungen.

```sh
GLOWROOM_REPAIR_FIXTURES="$PWD/Fixtures/LocalTestImages" \
GLOWROOM_REPAIR_FIXTURES_OUTPUT=/private/tmp/glowroom-repair-brightness-photos \
./scripts/test.sh --configuration release --jobs 4 \
  --filter DevelopRepairLocalPhotoTests
```

## Ergebnisse

- 251 Tests in 29 Suites bestanden, einschließlich aller neuen Qualitäts-
  und nativen Moduswechseltests. Optionale externe Bild-/Modelltests ohne
  gesetzte Umgebungsvariable wurden übersprungen.
- Die sechs Fotofälle bestanden. Die erzeugten Ausschnitte wurden visuell
  geprüft; Originaldatei-Hashes blieben gleich, außerhalb der Masken gab es
  keine Änderung über den zugelassenen 8-Bit-Rundungsschritt hinaus.
- Der separate native Export mit 6.000 × 4.000 Pixeln und festem
  4-GiB-Zulassungsbudget bestand, einschließlich reparierter Pixel und
  unveränderter Originaldatei. Das Budget ist keine Messung des
  Spitzenspeicherverbrauchs.
- Ein isolierter nativer Lauf kompilierte alle drei neuen
  Core-Image-Kernel erfolgreich.
- Das unabhängige finale Review von Renderer, Speicherplanung, UI,
  Abbruchverhalten, Tests und Dokumentation ergab keine offenen Befunde.
  Ein im Review des ersten Entwurfs erkannter Versatz bei passenden linearen
  Verläufen wurde mit der Schwerpunktkorrektur und einem Regressionstest
  behoben.

Mittlerer absoluter RGB-Fehler gegenüber den bekannten sauberen Originalpixeln
im künstlichen Defekt, auf der 8-Bit-Skala 0–255 (kleiner ist besser):

| Motiv | Quelle | Vorherige Ringreferenz | Aktuell |
| --- | --- | ---: | ---: |
| Wand | Manuell | 4,35 | 4,22 |
| Wand | Automatisch | 1,81 | 1,97 |
| Himmel | Manuell | 0,50 | 0,38 |
| Himmel | Automatisch | 0,48 | 0,40 |
| Wasser | Manuell | 16,22 | 15,55 |
| Wasser | Automatisch | 14,45 | 12,74 |

Fünf Fälle haben einen geringeren Fehler; die bereits gute automatische
Wandquelle wird geringfügig schlechter. Die manuelle Wandquelle lässt eine
schmale dunkle Struktur zurück, die Wasserreparaturen passen nicht vollständig
zur ursprünglichen Wellenstruktur. Diese begrenzten Motivvergleiche und die
synthetischen Helligkeitsfälle belegen keine allgemeine Qualitätsfreigabe.
Die privaten Bilder und alle daraus erzeugten Ausschnitte bleiben lokal.

Der erste Test-Build brach ab, weil während der Kompilierung noch eine
Testdatei geändert wurde; dabei liefen keine Tests. Anschließend blieben
Quellcode und Tests unverändert, und der vollständige oben genannte Prüflauf
bestand. Es wurden keine Toleranzen abgeschwächt.

## Ressourcen und Parallelität

Analyse, Umsetzung und Review der beiden Fehler liefen parallel. Die
unabhängigen Ziel-/Quellzweige bleiben in Core Image im vorhandenen
Renderworker. Der Speicherplan berücksichtigt zwölf statt acht begrenzte
Float-RGBA-Zwischenbilder und drei Reduktionen mit Reserve. Es entstehen
keine weiteren RAW-Decodes oder CPU-Rücklesevorgänge. Ein
Geschwindigkeitsgewinn wird nicht behauptet.

Git-Zustandsänderungen, angenommene Reparaturen und die Bereinigung vor dem
Build bleiben wegen ihrer Abhängigkeiten geordnet. Test und sauberer Build
verwenden dasselbe Build-Verzeichnis nacheinander; native große Exporte
laufen separat, um konkurrierende Bildallokationen zu vermeiden. Der
vollständige saubere App-Build ist wegen der Renderer- und UI-Änderungen
erforderlich.

Nach Prüfung auf laufende Builds/Tests wurden `.build/`, gegebenenfalls
`.build-app/` und `dist/Glowroom.app` bereinigt. Der anschließende vollständige
Build mit `GLOWROOM_BUILD_JOBS=4 ./scripts/build-app.sh` und freigegebenem
Netzwerkzugriff war erfolgreich; `dist/Glowroom.app` wurde neu erstellt und
signiert. Danach wurden keine Quellcode- oder Teständerungen vorgenommen.
