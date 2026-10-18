# Lokale SDXL-Inpainting-Route: No-Go der geprüften Konfiguration

[Issue #77](https://github.com/dr-dimitri/picedit/issues/77) prüft den vom Nutzer gewählten weiteren lokalen Weg für [#1](https://github.com/dr-dimitri/picedit/issues/1). Die SD-1.5- und LaMa-Entscheidungen bleiben erhalten. Es wurden ausschließlich selbst erstellte, eingefrorene Fixtures lokal verarbeitet. Keine Fotos wurden übertragen und kein Cloudbackend aufgerufen.

**V8 ist vollständig gemessen und bleibt No-Go:** Zehn Vorhersagen einschließlich dreier warmer Wiederholungen bestehen die Laufzeitgrenze. Die geprüften Speicherwerte und die kleine synthetische Vorschauprobe liegen innerhalb ihrer Grenzen. Feine Motivkanten erhalten jedoch breite schwarze Ergänzungen und helle Säume; mehrere Retuschen zeigen sichtbare Texturübergänge. Der separate Abbruchtest liefert keine native Rückkehr innerhalb von fünf Sekunden. Es gibt damit kein Inpainting-Go und keine Freigabe für #13–16. Die Aussage gilt für diesen Quellstand, diese Parameter und Fixtures, nicht für die gesamte SDXL-Modellfamilie.

## Feste Bedingungen und Herkunft

Modell: `diffusers/stable-diffusion-xl-1.0-inpainting-0.1`, Revision `115134f363124c53c7d878647567d04daf26e41e`. SDK: `8cd731e7b4667eb8f40a153315b9a7125d09a58d`; GGML: `d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93`. Das [Paketmanifest](../../../tools/sdxl-evaluation/package.json) pinnt alle 22 Eingaben mit Länge und SHA-256. Die [Werkzeuganleitung](../../../tools/sdxl-evaluation/README.md) dokumentiert getrennte Installation, Konvertierung und Ausführung sowie Lizenz-/Attributionsnachweise. Gewichte und Binärdateien liegen außerhalb des Repositorys.

Eigene Offline-Konvertierung: Q8_0 mit konservativer F32-Regel für VAE-Gewichte. Der tatsächliche korrigierte GGUF-Header enthält 1.350 Q8_0-, 1.167 F16-, 124 F32- und zwei I32-Tensoren. Die 124 VAE-Nicht-Bias-Tensoren sind F32, die 124 Bias-Tensoren F16. Weder alle Gewichte noch alle Rechenschritte werden als F32 ausgegeben. Der neun-kanalige UNet-Eingang wurde am Header und durch die tatsächliche SDK-Erkennung geprüft.

Native Fixtures werden ohne Skalierung auf 1024×1024 eingebettet, mit identischem Clamp-Sampling für gerades RGB und binäre Maske. Das spätere native Compositing behält Quellalpha und die originale weiche Maske. 20 Euler-Schritte, CFG 8, Stärke 0,99 und Seed 4281 bleiben fest. Die vor dem jeweiligen Versuch archivierten Kriterien verlangen 6 GiB kombinierten Prozessspeicher, Laden ≤45 s, Vorhersage ≤180 s, kalt ≤240 s, tatsächliches Abbruchende ≤5 s sowie ausreichend Bildqualität und gleichzeitige Vorschau. Ein SDK-internes VRAM-Limit ist keine OS-Speicherquote.

Referenz: Apple M2 Pro, 16 GiB, macOS 27.0.1, arm64. Modellläufe bleiben seriell und ohne konkurrierende Builds/Tests; dadurch werden Modellkopien, Speicher und Messwerte nicht durch zusätzliche Arbeit verfälscht. „Kalt“ bedeutet neuer Prozess/Modellkontext; Datei- und Shadercaches des Systems wurden nicht geleert. Lazy Loading kann Gewichtslesen in die erste Vorhersage verschieben; die kurze Load-Zeit ist daher kein vollständiger Startzeitnachweis.

## Erhaltene Versuche

| Versuch | Änderung und tatsächliches Ergebnis |
| --- | --- |
| [V1](v1-load-failure/) | Initiale selbst konvertierte Route. Modellladen scheitert; kein Bild. Die damalige Logweiterleitung unterdrückte SDK-Details. |
| [V2](v2-loader-diagnosis/) | Gleiche Gewichte, begrenzte SDK-Logs erhalten. Zweiter Diffusers-Encoder erhält im SDK einen falschen Alias; GGUF wird dadurch als SD 1.x Inpaint erkannt. Laden scheitert; kein Bild. |
| [V3](v3-cpu-vae-timeout/) | Gezielter Aliaspatch, tatsächliche SDK-Metadatenregression bestanden. SDXL Inpaint wird korrekt erkannt. Die Route mit CPU-VAE verfehlt die erste Vorhersagefrist; der native Auftrag kehrt nach insgesamt 180,513 s als `cancelled` zurück. Kein Bild. Dies ist keine gemessene Abbruchlatenz. |
| [V4](v4-metal-vae-timeout/) | Nur VAE-Ausführung und VAE-Parameter auf Metal. Encoding rund 28,70 s, Sampling 136,57 s, anschließend Decode. Erste Vorhersage verfehlt 180 s; nach fünf Sekunden Stopfrist wird der Helper beendet und tatsächlich eingesammelt. Kein fertiges Bild. |
| [V5](v5-batched-cfg-timeout/) | Gebündelte CFG-Berechnung und 5 GiB SDK-verwaltetes GPU-Budget. UNet-Graphpuffer 1.666,29 MiB, Sampling 124,28 s. Erste Vorhersage verfehlt weiterhin 180 s; kein fertiges Bild. Helper nach Stopfrist beendet und eingesammelt. |
| [V6](v6-white-output/) | Nur VAE-Kacheln auf 640×640 vergrößert: tatsächlich vier Kacheln mit 256 Pixel Überlappung. Erste Vorhersage 165,228 s, kalt 165,519 s. Nativer Crop ist exakt vollständig weiß; aktueller Compositor ersetzt das Objekt durch einen weißen Kreis. Nach diesem klar fehlgeschlagenen Pflichtfall kontrolliert gestoppt. |
| [V7](v7-unet-nonfinite-diagnostic/) | Getrennte öffentliche Graphdiagnose, kein Zeitvergleich: je 256 Stichproben am ersten Original- und Masken-Encode-Tile endlich. Im ersten UNet-Batchoutput `[128,128,4,2]` sind die 128 Stichproben der ersten Hälfte endlich, alle 128 der zweiten Hälfte NaN. Kontrollierter Abbruch vor Bildveröffentlichung, tatsächliches Prozessende bestätigt. |
| [V8](v8-quality-and-cancel-no-go/) | Korrigiertes Metal-`GROUP_NORM`, sonst V6-Einstellungen, keine Diagnosecallbacks. Alle zehn Vorhersagen abgeschlossen. Erstmals strukturierte Bilder statt weißer Ausgaben; erforderliche Qualität und Abbruchgrenze dennoch verfehlt. |

Jeder Ordner hält ursprüngliche Reports, Rohlogs, native Build-/Konvertierungsbelege und die exakten damaligen Quellen samt Hashes fest. Frühe Ladefehler werden nicht als Qualitätsversagen des Modells ausgegeben. Fehlende Qualitäts-, warme Laufzeit-, Vorschau- und Abbruchproben sind keine bestandenen Gates.

V6 erhält für diese Konfiguration **kein Qualitäts-Go**. Zwei unabhängige Sichtungen und der [visuelle Bericht](v6-white-output/visual-review.json) halten den weißen Ersatz ohne fortgesetzte Holzstruktur fest. Der aktuelle Compositor bewahrt alle 244.263 Erhaltpixel bytegleich; das bestätigt die lokale Maskenbegrenzung, macht den Inhalt aber nicht brauchbar. Drei warme Wiederholungen, weitere Fälle und die vollständigen Vorschau-/Abbruchgates wurden nicht abgeschlossen. Die unterbrochene Vorschauprobe und ein bestätigtes Prozessende ersetzen diese Gates nicht.

Die ursprünglichen GGUF-Präzisionsangaben betreffen Speichergewichte. Die tatsächliche SDK-Implementierung `model/common/ggml_block.hpp` initialisiert `Conv2d`-Gewichte mit F16, unabhängig vom F32-Typ in der GGUF-Datei. Der F32-Export ist daher keine durchgehende F32-VAE-Ausführung. V7 lokalisiert tatsächlich NaN-Stichproben am ersten UNet-Batchoutput; RGB8 allein hatte dies nicht belegt. Die begrenzten Stichproben bestätigen weder alle VAE-Werte noch spätere Schritte als endlich.

## Gezielte Metal-Gruppennormalisierung

Die anschließende Prüfung des gepinnten GGML-Codes zeigt: Der Metal-Host dispatcht nur `ngrp` Gruppen; der Kernel betrachtet nur die ersten drei Dimensionen und schreibt ausschließlich den ersten Batchbereich. Die CPU-Implementierung iteriert dagegen über `ne03`. Der SDXL-Packcode ordnet positive und negative Konditionierung den beiden Batchhälften zu. Der fehlende zweite Normalisierungsbereich passt zum V7-Befund; sein Einfluss wird gesondert geprüft.

Der [minimale GGML-Patch](../../../tools/sdxl-evaluation/ggml-metal-group-norm.patch) dispatcht alle `ngrp × ne03` Gruppen und setzt im vorhandenen dichten Layout den unabhängigen Batchoffset. Gruppenformel, Parameterstruktur und N=1-Verhalten bleiben gleich. Der [modellfreie CPU-/Metal-Vergleich](../../../tools/sdxl-evaluation/ggml_group_norm_regression.cpp) prüft N=1, 2 und 3 mit unterschiedlichen Eingaben und maximal 6.720 F32-Werten pro Backend/Fall. Ein NaN-Sentinel weist unbeschriebene Ausgaben nach; alle Werte werden nach der Korrektur gegen CPU mit absoluter Toleranz `1e-4` geprüft. Ein fehlender Backendpfad zählt als Umgebungsfehler, nicht als reproduzierter Defekt.

Der neue Builder prüft zuerst den ungepatchten Batchdefekt, korrigiert ausschließlich seine private GGML-Quelle, baut den abhängigen eingebetteten Norm-Kernel neu und prüft anschließend CPU und Metal erneut. Erst danach darf ein Helper samt gehashtem Korrektur-/Regressionsnachweis erscheinen. Die neue Modellmessung benötigt eigene Nachweise; der kleine Kerneltest ist kein Produkt-Go.

Dieser Vorher-/Nachher-Test wurde auf dem Apple M2 Pro tatsächlich bestanden: Vor der Korrektur stimmt jeweils Batch 0 mit der CPU überein, während alle 2.240 Werte jedes späteren Batchbildes unverändert das NaN-Sentinel enthalten. Nach der Korrektur sind sämtliche Werte von N=1, 2 und 3 endlich; maximaler absoluter CPU-/Metal-Fehler `3,5762787e-7`. Das ist deutlich unter der vorab festgelegten Toleranz `1e-4`. Das native Buildlog und beide unveränderten JSON-Ergebnisse sind mit V8 archiviert.

## V8: vollständige Serie und Entscheidung

Die [Messzusammenfassung](v8-quality-and-cancel-no-go/measurement-summary.json), der unveränderte [native Bericht](v8-quality-and-cancel-no-go/native/sdxl-report.json) und das getrennte [visuelle Review](v8-quality-and-cancel-no-go/visual-review.json) halten das Ergebnis fest. Kriterien und exakte Quellen wurden vor dem Lauf eingefroren und sind über SHA-256 an Helper, Konvertierung und Harness gebunden.

| Messung | Tatsächliches Ergebnis | Grenze / Bedeutung |
| --- | --- | --- |
| Kontextladen | 0,347 s | ≤45 s; wegen Lazy Loading keine vollständige Gewichtsinitialisierung |
| Erste Vorhersage | 161,166 s | ≤180 s |
| Drei warme Wiederholungen | 155,467 / 155,397 / 155,483 s | Je ≤180 s; Roh-PNGs identisch mit dem ersten Ergebnis |
| Weitere sechs Vorhersagen | 155,131–157,777 s | Je ≤180 s; Canvasfall nur Diagnose |
| Kalter nativer Kontext | 161,525 s | ≤240 s; Prozessstart, Laden und erste Rückkehr. Zusätzlich 5,716 s Verifikation/Vorbereitung; Crop und Compositing nicht eingeschlossen. |
| Kombinierter berichteter Speicher | 3.757.559.360 Byte | ≤6 GiB; maximaler Helper-RSS/Footprint 3.706.097.216 Byte plus Driver-Peak-RSS 51.462.144 Byte. Ereignisbasierte Messung, keine OS-Quote. |
| Synthetische Vorschau P95 | Baseline 12,955 ms / gleichzeitig 10,734 ms | 31 / 1.555 Samples; ≤250 ms und ≤2× Baseline. 256²-Test, keine ausgewählte RAW-Vorschau. |
| Abbruch | Keine native `cancelled`-Rückkehr innerhalb von 5 s | **Fail**; danach begrenzter Shutdown und SIGKILL, Exit 9 bestätigt und Prozess eingesammelt. Kein Abbruch-PNG. |

Das SDK-Cancelflag unterbricht laufendes Laden und VAE-Graphen nicht unmittelbar. Der öffentliche Fortschrittscallback meldet auch Lade- und Tilefortschritte; `cancelAtStep:2` ist deshalb kein Nachweis eines zweiten UNet-Schritts. Im V8-Rohlog folgt die erste Cancel-Anforderung auf den gemeldeten Wert `108/108`. Der Owner wartet nach dem fehlgeschlagenen Fünfsekundengate noch einmal begrenzt auf Shutdown. Die exakte Gesamtlatenz bis zum erzwungenen Prozessende wurde nicht aufgezeichnet und wird nicht als bestanden ausgegeben. Beide Prozesse sind nachweislich beendet; die Ressourcenlease bleibt bis dahin gehalten. Ein künftiger Produktpfad benötigt eine einzige absolute Abbruchfrist und darf erst nach bestätigtem Prozessende Ressourcen freigeben.

Da der Lauf vor dem automatischen Replay am Abbruchgate scheitert, wurde ein **separat gekennzeichneter Replay-Eingabestand** erstellt: Kopie der unveränderten Rohdaten plus das gehashte ursprüngliche Canvasfixture, das der damalige Harness erst nach den technischen Gates kopierte. [Ergänzungsnachweis](v8-quality-and-cancel-no-go/provenance/replay-input-addition.json) und [Fixture](v8-quality-and-cancel-no-go/replay-fixtures/06-canvas-original.png) sind separat erhalten. Das [aktuelle Compositor-Replay](v8-quality-and-cancel-no-go/compositor/current-compositor-report.json) ist keine neue Inferenz. Der finale Harness legt dieses verifizierte Fixture bereits vor dem Modelllauf ab, damit fehlgeschlagene Serien direkt replaybar bleiben; der gemessene V8-Quellstand wird dadurch nicht nachträglich verändert.

Alle zehn Kompositionen bewahren insgesamt 2.041.570 geprüfte Nullmaskenpixel bytegleich und verändern kein Quellalpha-Byte. PNG-Roundtrips sind identisch, Ausgabe ist sRGB RGBA8. Das belegt die Begrenzung für diese normalisierten Fixtures, keine große native RAW-/16-Bit-Produktroute. Fall 04 entfernt die teiltransparente Kugel plausibel. Fall 05 erzeugt jedoch breite schwarze Zweige und helle Säume neben den geschützten grünen Linien. Fall 02 und beide Varianten von 03 behalten sichtbare Ersatzflächen. Bei Fall 01 unterscheiden sich die Sichtungen über den subtilen Texturübergang; die Entscheidung hängt davon nicht ab. Der diagnostische Canvasfall erzeugt Rahmen und neue blaue Rechtecke statt nahtloser Fortsetzung und erteilt kein Outpainting-Go.

## SDK-Korrektur

Die Konvertierung des Diffusers-Verzeichnisses bezeichnet den zweiten Textencoder mit `te.1.`. Der ursprüngliche generische `te.`-Alias machte daraus `cond_stage_model.transformer.1.` statt `cond_stage_model.1.transformer.`. Der [gehashte minimale Patch](../../../tools/sdxl-evaluation/sdk-sdxl-inpaint.patch) normalisiert ausschließlich diesen Präfix vor der generischen Zuordnung. Er verändert keine Architektur und erzwingt keine Modellversion. Die [tatsächlich gegen den gepinnten SDK-Code gebaute Regression](../../../tools/sdxl-evaluation/sdk_name_regression.cpp) prüft beide Encoder, Projektion, kanonische Namen und SDXL-4-/9-Kanal- sowie SD-1.x-Inpaint-Metadaten vor Veröffentlichung des Helpers.

V1/V2-GGUF: `55570c0dd79d37cd4d4e44a1e2c7613c161e4ac6385215705968593d0825226e`. Korrigiertes V3/V4-GGUF: `2e0d24d76de6557144948429e7e86ca2d0a03aa920402529cef1df6665c72531`, jeweils 4.347.581.632 Byte. Die Originaleingaben bleiben identisch; frühere Artefakte wurden nicht überschrieben.

## Zusätzliche Produktprüfung

Die technische Serie ersetzt keinen `ImageGenerationService`-Produktadapter. Der aktuelle Dienst hat 120 Sekunden Gesamttimeout, während die neue lokale Route rund 161 Sekunden für die erste Vorhersage benötigt. Ein Adapter braucht ein ausdrücklich geprüftes Zeitbudget, einen vertrauenswürdigen gebündelten Helper, eine verifizierte Modellinstallation und tatsächliches Prozessende vor Ressourcenfreigabe. Ein Helper aus einer benutzerseitigen Quittung ist keine vertrauenswürdige Produktquelle.

Die native Modelleingabe, ROI und zentrierte Einbettung müssen im Produktionsvertrag nachvollziehbar sein; der bisherige Maskentransform beschreibt nur Crop und Skalierung. Für große RAW-Bilder muss außerdem die gesamte native Komposition samt PNG-Staging innerhalb des Artefaktbudgets bleiben. Die bisherige Vollbildkomposition überschreitet bei 24 MP RGBA8 die 512-MiB-Grenze. Kleine Modell-ROIs allein ändern diesen Vollbildbedarf nicht. Vorschau, Alpha, Profil und Bit-Tiefe benötigen einen eigenen Nachweis über diesen tatsächlichen Pfad. Der lokale private RAW-Prüfeingang bleibt außerhalb der veröffentlichten Ergebnisse.

Erst danach folgt #13 mit eigener Kandidaten-/Commitsteuerung, anschließend #16 über den vorhandenen JPEG-Exporter mit strenger Artefaktquellwahl. #14 und #15 benötigen weiterhin eigene Fähigkeitsnachweise. Die ergänzende Lightcraft-Sichtung liefert Muster für Modellzuständigkeit, begrenzten Kontext und Speicherzulassung; dessen klassischer PatchMatch-Entferner ist kein generatives Diffusionsbackend. Es wurde kein Lightcraft-Code übernommen.

## Softwareprüfung und Review

Die [Prüfübersicht](verification/software-checks.json) trennt modellfreie Softwareprüfungen von der tatsächlichen Modellserie: 687 App-Tests in 86 Suites und 331 Core-Tests in 44 Suites bestanden, einschließlich der sechs neuen Rastertests. Dazu bestehen 36 Python-Tests, Shell-Opt-in-Prüfungen und sieben modellfreie Replay-CLI-Proben des finalen Entwicklerbuilds. Die CLI-Proben verwenden ausdrücklich synthetische SDXL-Metadaten um archivierte LaMa-PNGs und sind keine SDXL-Inferenzbelege. SDK-Namensregression, nativer CPU-Diagnoseselbsttest und tatsächlicher CPU-/Metal-Vorher-/Nachhervergleich sind im nativen Buildnachweis erhalten.

Das finale Review umfasst Schnittstellen, Prozess-/Lease-Ende, Vorbereitung, Tests, Dokumentation und archivierte Identitäten. Alle 100 deklarierten Sourceidentity-Einträge der acht Varianten stimmen mit ihren Dateilängen und SHA-256 überein; V8-Rohdaten und Compositor sind bytegleich mit den ursprünglichen Ausgaben. Zugehörige Befunde wurden korrigiert und erneut geprüft. Der separate Bestandsfehler [#78](https://github.com/dr-dimitri/picedit/issues/78) betrifft ein mögliches falsches Preview-Go ohne Samples im alten SD-1.5-Harness. Der neue SDXL-Pfad verlangt positive Samplezahlen; die unabhängige alte Fehlerbehebung gehört nicht zu diesem Diff.

Der vorgeschriebene [saubere vollständige App-Build](verification/clean-application-build.json) besteht mit `PICEDIT_BUILD_PATH=.build-app PICEDIT_BUILD_JOBS=4 ./scripts/build-app.sh` nach Prüfung auf aktive Arbeiten und Bereinigung der vorhandenen generierten Ergebnisse sowie des bisherigen Bundles. Swift-Buildzeit 110,66 s, Exit 0; die Bundle-Signatur wurde zusätzlich verifiziert. Das [Buildlog](verification/clean-application-build.log) ist erhalten. Quellcode, Tests und Dokumentation bestehen die Whitespaceprüfung; unveränderte Rohlogs, ursprünglicher Lizenztext und Unified-Patch-Kontext behalten ihre originalen Bytes.
