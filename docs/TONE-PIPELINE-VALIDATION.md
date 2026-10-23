# Prüfung der versionierten Tonwertpipeline

Die V2-Abnahme trennt mathematische Korrektheit, Persistenz, asynchronen
UI-Zustand und lokale Laufzeitmessungen. Der geänderte Farbvertrag ist kein
Nachweis einer allgemeinen Qualitäts- oder Geschwindigkeitsverbesserung.

## Reproduzierbare synthetische Prüfungen

`./scripts/test.sh` führt die versionierten Core-, Renderer-, Automatik- und
Workspace-Tests zusammen mit den bestehenden Regressionen aus. Der Testlauf
benötigt gemäß `AGENTS.md` Netzwerkzugriff für die festgelegten Pakete und für
native UI-Tests gegebenenfalls Zugriff auf den macOS-Fensterserver.

Shader-Kompilierung, MainActor und Fensterserver sind globale Ressourcen dieses
Testprozesses. Im ungeordneten Gesamtlauf können native Arbeiten die kurzen
Latch-Zeitfenster anderer Fixtures aushungern. Für die integrierte Abnahme wird
deshalb ausdrücklich `--no-parallel` verwendet. Die internen TaskGroups,
Worker-Zulassungen und kontrollierten Nebenläufigkeitsprüfungen bleiben aktiv.
Alle Prüfungen und Toleranzen bleiben erhalten:

```sh
./scripts/test.sh --no-parallel
```

Unabhängige reine Core-Prüfungen können separat parallel ausgeführt werden.
Bei einer Aufteilung nach Testtargets muss der komplette Satz einschließlich
des maximalen Shader-Grenzfalls nachweislich abgedeckt bleiben; es werden keine
Qualitätstoleranzen oder Clipping-Budgets abgeschwächt.

- `ToneProcessingVersionTests`: eingefrorene historische Snapshot- und
  Provenienzbytes samt Hashes, neue Prozessversionen, Backup und Wiederöffnung.
- `ToneProcessingV2Tests`: unabhängige stückweise Transferreferenz,
  1.024 Float-Stufen, EV, Tonbereiche, Alpha, P3, HDR, Masken, Vorschau und Export.
  Die Legacy-Anker stammen aus der bisherigen mathematischen Definition;
  sie sind keine nachträglich als historisch gemessen bezeichneten Pixel.
- `FloatAnalysisTests`: Präzision unter einer RGBA8-Stufe, alpha-gewichtete
  Statistik, Zielprofilgrenzen, kleines echtes HDR-Licht und P3-Gamutkanäle.
- `DevelopAutomaticToneTests`: atomare Übernahme, gültige Null,
  kein Vorschlag, manuelle Zwischenänderung, Abbruch und veraltete Fehler.
- `ToneMemoryBudgetTests`: Float-Zwischenpuffer, begrenzte Vorschau und
  Exportablehnung ohne Veränderung von Quelle oder bestehender Zieldatei.

Die lokale Stufendiagnose fand beim nativen Gaußfilter beispielsweise eine
Rundung eines konstanten synthetischen Log-Luminanzwerts von `-0.5316073` auf
`-0.53125`, obwohl der Kontext RGBA-Float32 verwendete. Deshalb nutzt V2 eine
eigene separierbare Float-Gaußstufe; V1 bleibt beim bisherigen Filter. Die
Konstanten-/P3-Prüfung wird über die Korrektur erfüllt, ihre Toleranz wird dafür
nicht angehoben.

## Optionale lokale RAW-Messung

Die Messung benötigt ausdrücklich eine tatsächlich vorhandene Kamera-RAW:

```sh
GLOWROOM_TONE_RAW=/absoluter/pfad/zum/foto.CR3 ./scripts/test.sh --filter ToneProcessingPerformanceTests
# Separater Lauf für die größte unterstützte Vorschaukante:
GLOWROOM_TONE_RAW=/absoluter/pfad/zum/foto.CR3 GLOWROOM_TONE_EDGE=4096 ./scripts/test.sh --filter ToneProcessingPerformanceTests
```

Ohne diese Variable bleibt der Diagnosefall deaktiviert. Der Dateityp wird über
ImageIO geprüft; ein umbenanntes JPEG ist kein zulässiger RAW-Ersatz. Jede Quelle
wird einzeln und ohne konkurrierenden Build oder Benchmark gemessen. Originale
und private Testfotos werden weder verändert noch kopiert oder hochgeladen.
Der Test prüft den Original-Hash vor und nach dem Lauf und schreibt nur einen
temporären numerischen JSON-Bericht.

„Kalt“ bedeutet frische App-Caches. Betriebssystem-, ImageIO- und GPU-Caches
werden nicht geleert; die Integritätsprüfung liest die Datei vor der Zeitmessung.
Die Vorschau ist standardmäßig auf 2.048 Pixel begrenzt; `GLOWROOM_TONE_EDGE`
erlaubt eine ausdrücklich gewählte Kante zwischen 64 und 4.096 Pixeln.
Gemessen werden genau ein RAW-Decode,
erster Render, Speicher-Cachetreffer, vier echte Renderdurchläufe mit geändertem
EV bei wiederverwendetem Prefix sowie kalte und warme Float-Analyse. Eine Folge
von 24 Änderungen im Abstand von 10 ms nutzt die bestehende 45-ms-Zusammenfassung
und einen Renderworker. Nur die letzte Revision darf angenommen werden.
Große gerenderte Bilder können den bestehenden 32-MiB-Cache überschreiten.
Solche Cache-Misses werden ausdrücklich berichtet; der Benchmark vergrößert
dafür kein Produktionslimit und bezeichnet einen erneuten Render nicht als Hit.

`ru_maxrss` ist auf macOS das kumulative Maximum des gesamten Testprozesses in
Bytes. Es ist weder eine Messung separater GPU-Residency noch der alleinigen
Zusatzkosten eines einzelnen Filters. Die Messung erfasst keine tatsächliche
Bildschirmlatenz. Keine geräteübergreifenden Beschleunigungsversprechen ableiten.

## Lokaler Abnahmelauf vom 24.10.2026

1.615 Tests in 220 Suiten bestanden im vollständigen geordneten Lauf
(`--no-parallel`, 241,991 s). Die unabhängige Float-Gauß-/P3-Abnahme bestand
zusätzlich mit 18 Tests in zwei Suiten. Frühere ungeordnete Gesamtläufe zeigten
Ressourcen-Zeitüberschreitungen; diese werden nicht als erfolgreiche Läufe
gezählt. Die geordnete Ausführung verändert keine Testtoleranzen.

Zwei tatsächlich vorhandene lokale CR3-Dateien wurden anschließend einzeln
auf einem Mac mit 16 GiB und 12 aktiven CPU-Kernen gemessen. Die anonymisierten
Werte beschreiben unterschiedliche Motive und Vorschaugrößen; daraus folgt
kein kontrollierter Größenvergleich und kein Vergleich gegen V1 oder GIMP.
Private Bilddaten, Dateinamen, Quellhashes und Aufnahmemetadaten bleiben lokal.

| Messgröße | RAW A, Kante 4.096 | RAW B, Kante 2.048 |
| --- | ---: | ---: |
| RAW-Decode, kalter App-Cache | 389 ms | 247 ms |
| Erster zugelassener Render | 5.690 ms | 1.396 ms |
| Vier echte warme Render mit geändertem EV | 1.469–1.478 ms | 35–37 ms |
| Float-Analyse kalt / warm | 11.895 / 11.536 ms | 1.006 / 905 ms |
| Letzte Reglerrevision nach letztem Ereignis | 1.610 ms | 126 ms |
| Kumulierter Prozess-Spitzenspeicher | 468 MiB | 220 MiB |
| Warme Ausgabecache-Abfrage | Miss, erneuter Render | Hit, 0,045 ms |
| RAW-Decodes im gesamten Lauf | 1 | 1 |
| Gleichzeitig aktive Renderworker | 1 | 1 |

Beide Läufe bestanden die Integritäts-, Abbruch- und Revisionsprüfungen:
23 von 24 schnellen Aufträgen wurden verworfen, ausschließlich Revision 24
wurde angenommen. Die große Ausgabe überschreitet den vorhandenen 32-MiB-Cache;
dieser Miss ist erwartetes begrenztes Cacheverhalten. Die erheblichen Kosten
der präzisen 4.096-Pixel-Verarbeitung und der Kandidatenanalyse sind ausdrücklich
sichtbar und kein Beschleunigungsnachweis. Die Messung umfasst keine weitere
RAW-Decodierung pro Regler- oder Analyseauftrag und keine isolierte GPU-Speichermessung.
