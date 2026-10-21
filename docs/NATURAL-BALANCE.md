# Natürlicher Bildausgleich

Der Bildausgleich ist eine ausdrücklich aktivierte, nicht destruktive Bearbeitung. Ziel ist ein ausgewogenes Foto mit zurückhaltenden, lebendigen Farben. Import, Auswahl und KI-Indexierung aktivieren ihn nicht.

## Bedienung

In **Entwickeln → Bearbeiten** ersetzt **Natürlicher Bildausgleich** die bisherige Tonwert-Automatik. Einschalten startet mit **Stärke 70 %**. **Farbe** steht anfangs auf **50 %** und regelt nur die zusätzliche Farbverstärkung. Bei Farbe 0 bleibt der Tonwertausgleich aktiv. Ausschalten deaktiviert den gesamten neuen Effekt. Die Farbvorliebe bleibt dabei gespeichert. Manuelle Tonwert-, Präsenz- und Entrauschungsregler lassen sich weiter verwenden.

Die beiden Werte gehören zu Foto, Undo/Redo, Bildstand, Backup und Export. Bestehende `autoToneAmount`-Bearbeitungen behalten ihren bisherigen Renderer; die Oberfläche kennzeichnet diesen Altbestand. Erst das ausdrückliche Einschalten des neuen Effekts ersetzt ihn. Bei Daten, die beide Effekte enthalten, hat der neue Vorrang; sie werden nie gestapelt.

Natürlicher Bildausgleich wird über seine beiden manuellen Regler gesteuert und ist kein regionaler Maskenparameter. Der interaktive KI-Assistent und der frühere eigenständige Analysebereich sind entfernt.

## Verfahren und Grenzen

1. Die unveränderte, bereits entwickelte Bildbasis wird farbverwaltet auf höchstens 256 Pixel lange Kante verkleinert. Eine alpha-gewichtete Helligkeitsverteilung, Perzentile, dunkle/helle Bildanteile und die vorhandene Sättigung liefern die Korrektur. Fast einfarbige Flächen und geringes Sensorrauschen erhalten keinen erfundenen Kontrast.
2. Apples lokale Vision-Gesichtserkennung (festgelegte Request-Revision 1) ergänzt einen konservativen Porträtschutz. Bei erkannten Gesichtern fällt der Farbzuwachs geringer aus. Die mittlere Helligkeit ihrer zentralen Bereiche hilft, kleine dunkle Gesichter vor hellem Hintergrund zu erkennen und die begrenzte globale Schattenaufhellung passend zu verstärken. Dunkle Szenen erlauben etwas mehr Schattenaufhellung; der zusätzliche Gegenlichtausgleich setzt zugleich einen hellen Hintergrund voraus. Ohne verfügbare Erkennung bleibt die statistische Korrektur nutzbar. Es werden keine Identitäten bestimmt, Modelle heruntergeladen oder Bilder übertragen.
3. Eine monotone kubische Helligkeitskurve öffnet Schatten und dämpft Lichter mit festen Schwarz-/Weißankern. Dunkle und helle Bildstimmungen werden zurückhaltender behandelt. Es gibt keine lokale Weichzeichnung und damit keine durch solche Filter erzeugten Säume an Motivkanten.
4. Farbe wird entlang der vorhandenen RGB-Chromarichtung verstärkt. Bereits kräftige Farben, sehr dunkle/helle Bereiche und warme Hautfarbtöne reagieren schwächer. Zusätzlich begrenzt der verfügbare Kanalspielraum die Wirkung. Keine pauschale Grauwelt-Weißkorrektur neutralisiert Sonnenuntergänge oder absichtlich farbiges Licht.
5. Die gemeinsame Core-Image-Stufe arbeitet vor den manuellen Reglern, nach Entrauschung, mit unverändertem Alpha und dem Ausgabefarbprofil. Core Image wählt sein verfügbares Backend. Vorschau und JPEG-Export verwenden denselben Graphen, analysieren aber ihre jeweilige Bildauflösung; geringe Unterschiede durch Resampling sind möglich.

Dies ist eine begrenzte bildabhängige Korrektur, keine Rekonstruktion abgeschnittener Sensordaten und kein kalibrierter Weißabgleich. Motiverkennung kann fehlen oder falsch liegen; sie darf nur die begrenzte Wirkung beeinflussen. Ein einzelnes Prüffoto belegt keine allgemeine Qualitätssteigerung. Die manuell folgenden Regler können auch weiterhin übersteuern.

Die Lightcraft-Quellen `crates/pipeline/src/auto.rs` und `colorops.rs` dienten als Vergleich für begrenzte Stichproben und die Schonung vorhandener Chromastärke/warmer Farben. Dessen an Sony-RAWs angepasste feste Auto-Tone-Werte wurden nicht übernommen: Glowroom arbeitet hier auf entwickelten, farbverwalteten Pixeln. Die früheren LC-03/LC-04-Bewertungen bleiben historische, separate Versuche.

## Ausführung und Wiederverwendung

Die vorhandenen begrenzten Hintergrund-Renderworker führen Analyse und Filterung aus. Eine serielle CPU-Reduktion über höchstens 65.536 Pixel vermeidet den Aufwand eines zusätzlichen Worker-Pools. Vision nutzt denselben bereits begrenzten Aufrufpfad; der eigentliche Bildfilter bleibt datenparallel in Core Image. Originaldecodierung, andere Bilder und I/O können sich weiterhin überlappen.

Ein synchronisierter Cache fasst gleiche Analysen zusammen, hält höchstens acht Einträge und nur schwache Referenzen auf die Bildbasen. Regleränderungen lösen weder erneute RAW-Decodierung noch erneute Gesichtserkennung aus. Fehlgeschlagene oder abgebrochene Produzenten werden entfernt; wartende Aufrufer prüfen Abbruch. Native Zeichen-/Vision-Aufrufe sind nur an ihren Grenzen abbrechbar. Die vorhandene Pipeline schützt vor verspäteten Ergebnissen bei schnellen Regler- und Bildwechseln.

## Reproduzierbare Prüfung

Die synthetischen Tests prüfen Aus/Altbestand, Tonwertreihenfolge, ungleiche helle/dunkle Bildanteile, Grenzen/Farbe/Hautfarbschutz, Transparenz/Farbraum, Cache und Abbruch, manuelle Nachbearbeitung, Persistenz, KI-Verträge und Export. Referenzadapter der historischen Lightcraft-Evaluation lehnen den neuen Effekt ausdrücklich ab.

```sh
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-natural-tests ./scripts/test.sh --jobs 4 \
  --filter 'NaturalBalance|AutoTone|EditRenderSession|EditingModel|JPEGExporter|Lightcraft.*Reference'

GLOWROOM_NATURAL_BALANCE_RAW="$PWD/IMG_8362.CR3" \
GLOWROOM_NATURAL_BALANCE_OUTPUT=/tmp/glowroom-natural-balance-review \
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-natural-tests \
  ./scripts/test.sh --filter NaturalBalanceRAWTests
```

Der optionale RAW-Test schreibt ausschließlich in ein neues temporäres Verzeichnis. Er entwickelt die RAW-Basis mit 2400 Pixeln langer Kante ohne eingebettete Kameravorschau, speichert Vorher/70–50/100–100 als PNG, prüft den unveränderten RAW-Hash und misst erste/wiederholte Aufrufe sowie 24 schnelle Reglerereignisse. Grafische Tests brauchen Zugriff auf die nativen macOS-Grafikdienste. `IMG_8362.CR3` ist ausdrücklich in `.gitignore` eingetragen. RAW, private Bildableitungen und Dateihash werden nicht mit dem Repository veröffentlicht.

### Lokale Prüfung am 18. Oktober 2026

Der finale unabhängige Diff-Review fand keine offenen Befunde. Die vollständige Suite mit `--jobs 4 --no-parallel` bestand: 634 App-Tests und 307 Core-Tests. Die Kompilierung bleibt parallel. Die Testfälle wurden hier bewusst nacheinander ausgeführt, weil der vorherige gleichzeitige Gesamtlauf 17 vorhandene Scheduler-Tests mit 19 Timeout-/Folgebefunden überlastete. Diese separate Testproblematik ist in [Issue #62](https://github.com/dr-dimitri/glowroom/issues/62) mit Reproduktion und erfolgreichem Vergleichslauf dokumentiert; die neuen Funktionstests bestanden auch im parallelen Lauf. Die Ursache der Timeouts ist damit noch nicht abschließend bewiesen.

Die separate finale RAW-Probe bestand ebenfalls. Zwei Gesichter wurden erkannt; die Vorher-/Nachher-Sichtprüfung zeigte eine zurückhaltende Öffnung des dunklen Motivs vor hellem Hintergrund. Das Original blieb bytegenau unverändert. Bei 24 Ereignissen im Abstand von 10 ms und 45 ms Zusammenfassung entstanden genau eine RAW-Decodierung, ein abschließender Renderauftrag und 23 abgebrochene veraltete Anfragen; das letzte Ergebnis entsprach den finalen Einstellungen.

Auf diesem Apple-Silicon-Mac dauerte die erste 2400×1600-Decodierung im Testprozess rund 212 ms, die erste Korrektur einschließlich Analyse rund 88 ms. Fünf Wiederholungen mit gleicher Bildbasis und gleichen Einstellungen benötigten 1,20–1,57 ms, geänderte Stärke/Farbe rund 5,08 ms. Die letzte schnelle Regleränderung war einschließlich Zusammenfassung nach rund 71 ms fertig. Prozess-Maximal-RSS: rund 218 MiB. Dies sind Debug-Testmessungen eines einzelnen Fotos, keine allgemeine Beschleunigungszusage; OS-/GPU-Caches wurden nicht geleert, UI-Präsentation und PNG-Schreiben sind in den Renderzeiten nicht enthalten, separater GPU-Speicher nicht im RSS.

Die Software-Renderer-Anforderung und der automatische Core-Image-Pfad lieferten in den synthetischen Prüfungen innerhalb der festgelegten Toleranz gleiche Pixel. Das beweist nicht, dass das System tatsächlich eine CPU-Ausführung gewählt hat. Reale Intel-/macOS-14-Hardware wurde nicht geprüft.
