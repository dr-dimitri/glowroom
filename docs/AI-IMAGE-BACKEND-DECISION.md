# AI-11: Entscheidung zum Bildgenerierungsbackend

Entschieden am **17. Oktober 2026**, bezogen auf Issue #12: **No-Go für die evaluierte lokale Route; kein Cloud-Go.** PicEdit meldet keine Bildgenerierungsfähigkeit als verfügbar. `.inpaint` sowie darauf aufbauende Hintergrundbearbeitung und Canvas-Erweiterung bleiben gesperrt; die Folge-Issues #13, #14 und #15 erhalten dadurch keine Freigabe. Das Gate ist entschieden. Die Entscheidung behauptet weder die generelle Unfähigkeit lokaler Modelle noch die Unfähigkeit des geprüften Cloudanbieters.

Der Grund ist nachgewiesene unzureichende Bildqualität: tatsächliches 9-Kanal-Inpainting erzeugt Bilder, entfernt die Testobjekte aber mit sichtbaren Texturgrenzen, ergänzt unerwünschte Motivkonturen oder erweitert den Canvas als gerahmtes Bild statt als fortlaufende Szene. Die Alpha-Fixture erzeugt einen auffälligen hellen Ersatzbereich. Fehlende Gewichte sind **nicht** der Grund: Alle drei installierten Gewichte wurden am 17. Oktober erneut byteweise gehasht und stimmen mit den veröffentlichten SHA256 überein.

Maschinenlesbarer Entscheidungswert: **`fullNoGo`**. Die produktiven fünf Operationsstatus sind `unsupported`; die nicht ausgeführten Kandidatenfähigkeiten bleiben in der separaten Bewertung `unverified`.

**Zusätzlicher Produktstand vom 19. Oktober:** Der ausdrücklich beauftragte Import eines eigenen lokalen Reparaturmodells ist ein gesonderter, auf kleine Bereiche und eine vor Speicherung zu prüfende Vorschau begrenzter Pfad. Er ändert weder diese historischen Messergebnisse noch die fünf Status des allgemeinen Bildgenerierungsproviders. Es werden keine Gewichte ausgeliefert oder heruntergeladen und keine allgemeinen Qualitäts- oder Herkunftsfreigaben behauptet. Bedienung und tatsächliche Grenzen: [Reparaturwerkzeuge](REPAIR-TOOLS.md).

## Bewertete Route und Herkunft

Die ausführbar geprüfte lokale Pipeline verwendet den nativen `leejet/stable-diffusion.cpp`-Helper mit **Stable Diffusion 1.5 Inpainting**, nicht die gewöhnliche Text-to-Image-Variante. Modellquelle ist der öffentliche Spiegel `stable-diffusion-v1-5/stable-diffusion-inpainting`, Revision `8a4288a76071f7280aedbdb3253bdb9e9d5d84bb`. Das Modell besitzt einen UNet-Eingang mit neun Kanälen: vier Rauschkanäle, vier kodierte Bildkanäle und eine Ersetzungsmaske. [Gepinnte Modellkarte](https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-inpainting/blob/8a4288a76071f7280aedbdb3253bdb9e9d5d84bb/README.md)

| Bestandteil | Exakter ausgewerteter Stand |
| --- | --- |
| Native SDK | `leejet/stable-diffusion.cpp` Commit `8cd731e7b4667eb8f40a153315b9a7125d09a58d` |
| GGML | `leejet/ggml` Commit `d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93` |
| SDK-Instrumentierung | Patch-SHA256 `e7aed7286e508f87b8c566afd1dd257b10dfb5f81a7f0081b2fc22ffe3dac7f0` |
| Helperquelle | SHA256 `64ec0665e376d00b60a6a903babf62b9f078e65429f7e189a345d5ca5bc8dde0` |
| Konfiguration | Metal-Diffusion, CPU-VAE; F16 mit partieller F32-VAE-Regel; CFG ungebündelt; CPU-RNG; lineare und Attention-Skalierung 1/128 |
| Inferenzparameter | Euler, diskreter Scheduler, 25 Schritte, CFG 7,5, Stärke 1, Seed 4281, Batch 1, vier Hostthreads |
| Vorverarbeitung | Explizite RGB-Weißmatte für Modellinput; L8-Ersetzungsmaske oben-links; originale harte/weiche Maske und Quellalpha getrennt für lokales Composite |

Die exakte Instrumentierung, Konfiguration, C++-Helperquelle, Float-Diagnostik und Buildbelege liegen unter [`reports/image-backend/historical-2026-10-16/provenance/`](../reports/image-backend/historical-2026-10-16/provenance/). Der Patch prüft tatsächliche Float-Zwischenwerte und die CFG-Ausgabe; ein erfolgreicher PNG-Encode allein gilt nicht als numerischer Nachweis. Diese konkrete modifizierte Pipeline wurde bewertet. [Native Revision](https://github.com/leejet/stable-diffusion.cpp/tree/8cd731e7b4667eb8f40a153315b9a7125d09a58d), [GGML-Revision](https://github.com/leejet/ggml/tree/d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93)

## Ressourcen, Installation und Rechte

Die drei FP16-Dateien benötigen zusammen **2.132.634.310 Bytes**, das vollständige Installationsmanifest einschließlich Tokenizer, Konfigurationen und Lizenz **2.134.252.439 Bytes**. Die unveränderten `.fp16.safetensors`-Downloads werden lediglich auf die vom nativen Loader erwarteten Namen abgebildet; es gibt keine Gewichts-Konvertierung. Das vollständige gepinnte HTTPS-Manifest liegt in `provenance/model-manifest.json` des historischen Berichts.

| Ressource in der Modellrevision | Bytes | SHA256 |
| --- | ---: | --- |
| `unet/diffusion_pytorch_model.fp16.safetensors` | 1.719.154.104 | `24b788b4a777748377cc20364eea4ae113c8c42f4468c16bc8c02fdae5492af9` |
| `text_encoder/model.fp16.safetensors` | 246.144.864 | `77795e2023adcf39bc29a884661950380bd093cf0750a966d473d1718dc9ef4e` |
| `vae/diffusion_pytorch_model.fp16.safetensors` | 167.335.342 | `4fbcf0ebe55a0984f5a5e00d8c4521d52359af7229bb4d81890039d2aa16dd7c` |

Die Gewichte stehen unter **CreativeML OpenRAIL-M**. Der vollständige Lizenztext samt Nutzungsbeschränkungen und Attributionshinweisen ist archiviert; diese Bedingungen müssen bei einer künftigen Installation oder Weitergabe mitgeführt werden. SDK und GGML stehen unter MIT; tatsächlich mitkompilierte Drittanbieterhinweise stehen in `provenance/THIRD-PARTY-NOTICES-EVALUATION.txt`. PicEdit verteilt für dieses No-Go keine Gewichte, kein Modell-SDK und keinen generierenden Helper. Downloads bleiben ein eigener expliziter Evaluationsschritt. [Gewichtelizenz in fester Revision](https://huggingface.co/spaces/CompVis/stable-diffusion-license/blob/14d42d09bffd871b1666a084fc954a50cff72ac0/license.txt)

Die Referenz war ein **M2 Pro, 12 CPU-Kerne, 16 GiB gemeinsamer Speicher, macOS 27.0.1**, mit CLT/Swift 6.4 und SDK 27. Der Helper wurde für arm64 mit Deploymentziel macOS 14 gebaut. Das belegt keine Ausführung auf macOS 14, Intel oder Geräten unter 16 GiB; diese Kombinationen sind für die evaluierte Route nicht freigegeben. PicEdits Basisfunktionen behalten macOS 14 als Mindeststand.

## Vor der Inferenz festgelegte Kriterien

Die Kriterien wurden am 16. Oktober vor der ersten Modellladung festgehalten und nach Sichtung der Resultate nicht abgeschwächt:

- Apple Silicon mit mindestens 16 GiB, normale Speicherdrucklage; höchstens **6 GiB Peak-RSS** für den nativen Prozess einschließlich Modell und Arbeitsdaten. Physischer Footprint wird zusätzlich gemessen, weil RSS keine vollständige GPU-Speicherbilanz darstellt.
- Native Bilder 512×512; separater Geometriefall 640×384 mit maximal 262.144 Modellpixeln, Kantenlänge maximal 640 und durch 64 teilbaren Seiten. Keine Aussage zur vollen RAW-Ausgabeauflösung.
- Kalte Modellladung höchstens 45 s, kalte erste Gesamtgenerierung höchstens 240 s; warme 25-Schritt-Generierung höchstens 180 s. Kalt bezeichnet einen neuen Prozess/Modellkontext, keinen zwangsgeleerten Betriebssystem-Dateicache.
- Abbruch bis zur tatsächlichen Beendigung höchstens 5 s; Ressourcen bleiben bis zum nativen Rücklauf beziehungsweise bestätigten Prozessende gebunden. Ein neuer schwerer Auftrag darf vorher nicht beginnen.
- Promptziel erkennbar erfüllt, Maskenposition und Orientierung korrekt, keine neue sichtbare Naht oder Verzerrung; Quellenpixel außerhalb der finalen Maske und Originalalpha erhalten. Alle sechs Fixtures sowie beide Maskenkanten müssen bestehen.
- Ein einzelner Core-Image-Vorschaurenderer läuft während der Inferenz weiter. Der historische Test ist ausdrücklich eine synthetische 256×256-Probe; er ist weder ein tatsächlicher PicEdit-UI-Test noch ein RAW-Benchmark.

## Echte Ergebnisse und Messgrenzen

Die vollständige historische Serie vom **16. Oktober** enthält zehn tatsächliche Inferenzresultate: sieben unterschiedliche Fixture-/Maskenfälle und drei Wiederholungen im selben geladenen Prozess. Messwerte, Ereignisse, Parameter, beschriftete Bilder, Rohoutput und endgültiges Review werden unter [`reports/image-backend/historical-2026-10-16/`](../reports/image-backend/historical-2026-10-16/) bewahrt. Die Dateien wurden am 17. Oktober erneut auf Hashgleichheit geprüft; die ursprünglichen Messungen werden dadurch nicht als neue Messung ausgegeben.

| Messgröße | Historischer Wert / Begrenzung |
| --- | --- |
| Modellladung | 23,2004 s |
| Kalte erste Gesamtgenerierung | 159,6594 s |
| Ununterbrochene Generierung | 119,5758–136,4462 s, unterschiedliche Fixtures |
| Peak-RSS / Peak-Footprint des nativen Prozesses | 3.780.132.864 / 3.993.046.784 Bytes |
| Tatsächlicher Cancel-Rücklauf | 4,1048 s; kein Output; Lease erst nach Prozessende frei |
| Synthetische Preview p95 ohne / mit Modellrechnung | 7,7604 / 6,1932 ms; kein daraus abgeleiteter Leistungsgewinn |
| Gesamtes Qualitätsgate | **FAIL** |

`warm-repeat-2` wurde durch Systemschlaf unterbrochen. Seine native Dauer von 1870,96 s und Swift-Uptime von 151,13 s bleiben unverändert im Bericht, sind jedoch **für die Laufzeitfreigabe nicht auswertbar**. Der historische Harness verwendete `systemUptime`; seine Deadlineprüfung schloss Schlaf nicht ein. Drei Wiederholungen existieren, aber nur zwei zusätzliche identische warme Wiederholungen sind ununterbrochen. Sechs weitere warme Fixtureläufe liefen ununterbrochen. Es wird kein vollständiges dreifaches ununterbrochenes Wiederholungsbenchmark behauptet. Die Qualitätsablehnung ist von diesem Zeitproblem unabhängig.

| Eigene Fixture | Visuelles Ergebnis |
| --- | --- |
| Objekt auf strukturierten Holztafeln entfernen | Objekt entfernt; auffälliger runder Textur- und Helligkeitsfleck bleibt. |
| Objekt am rechten Rand | Tasse entfernt; rechteckige Texturgrenze rechts unten bleibt. |
| Harte und weiche Maskenkante | Block entfernt; bei beiden Kanten sichtbarer großer Fleck, weich nur abgeschwächt. |
| Halbtransparente RGBA-Quelle | Alpha numerisch erhalten; heller kreisförmiger RGB-Ersatzbereich sichtbar. |
| Hintergrund an feinen Motivkanten | Erhaltpixel geschützt; Modell ergänzt dicke grüne Strukturen statt des verlangten leeren Hintergrunds. |
| Nichtquadratische Canvas-Erweiterung | Originalgeometrie erhalten; Modell ergänzt Holzrahmen und graue Umgebung statt fortlaufender Holztextur. |

Ein zusätzlicher begrenzter Kontextfarbabgleich (`v2`) reduziert teils den Helligkeitsunterschied, behebt aber die Texturgrenzen nicht; Alpha-, Feinkanten- und Canvasfälle werden von dessen Kontextprüfung abgelehnt. Er erhält kein Go. Alle sechs Quellen sind selbst erzeugte synthetische Motive; ihr Generator und die vorab eingefrorenen Bild-/Maskenhashes sind archiviert. Es wurden keine fremden Privatfotos verwendet.

## Neue echte Messreihe und aktueller Produkt-Compositor

Eine **neue echte Messreihe am 17. Oktober** führt den aus den gepinnten Archiven neu gebauten portablen Helper aus. Seine einzige funktionale Schnittstellenänderung ist der explizite Evaluationsroot als Argument; SDK-Patch, Gewichte und Modellparameter bleiben gleich. Alle vier tatsächlichen Rohoutputs der ersten Fixture sind untereinander und mit dem historischen ersten Output bytegleich (`14389520…`). Das neu betrachtete aktuelle Composite zeigt dieselbe kreisförmige Texturgrenze. Es entsteht kein Qualitäts-Go.

| Neue Messgröße, M2 Pro / 16 GiB / macOS 27.0.1 | Tatsächliches Ergebnis |
| --- | --- |
| Neue Prozess-/Modellladung | 28,4103 s |
| Kalter erster Gesamtlauf | 170,8515 s |
| Kalte Generierung / drei warme Generierungen | 141,8297 / 141,6614 / 139,6604 / 140,7744 s |
| 100 native Denoising-Schrittcallbacks: Minimum / Median / Maximum | 4,0908 / 4,1716 / 4,2743 s |
| Peak-RSS / Peak-Footprint des nativen Prozesses | 3.838.787.584 / 3.988.590.336 Bytes |
| Zusätzlicher Peak-RSS des Swift-Harness während der Modellserie, vor Compositing | 30.801.920 Bytes |
| Tatsächlicher Cancel-Rücklauf | 4,1650 s; kein Output; Prozessende bestätigt |
| Synthetische Preview p95 ohne / mit Modellrechnung | 12,7337 / 11,4207 ms; kein abgeleiteter Leistungsgewinn |
| Technische Schwellen dieser Probe / Qualitätsgate | PASS / **FAIL** |

Die kontinuierliche Uhr zählt Schlaf mit. Drei zusätzliche identische warme Läufe sind damit neu und vollständig gemessen; `caffeinate` verhinderte bei diesem konkreten Run automatischen Leerlaufschlaf. Modellzeiten enthalten kein nachträgliches Compositing. Das einzelne synthetische 256×256-Preview bleibt eine begrenzte GPU-/Render-Konkurrenzprobe und keine Freigabe tatsächlicher UI-/RAW-Latenzen. Native Ereignisse, Parameter, JSON-Messungen, echte Bilder und abschließendes Review: [`picedit-issue12-benchmark-20261017/`](../reports/image-backend/picedit-issue12-benchmark-20261017/); zugehörige [`aktuelle Composites`](../reports/image-backend/picedit-issue12-benchmark-20261017-compositor/).

Am 17. Oktober wurden alle sieben unterschiedlichen echten Rohoutputs erneut durch den **aktuellen `MaskCompositor.cpu` aus Issue #11** verarbeitet. Das ist ein neues Compositor-Replay und keine wiederholte Inferenz. Sämtliche **1.308.781 Pixel außerhalb der Masken** bleiben in kanonischem RGBA8 bytegleich. Im 640×384-Canvas bleiben zusätzlich alle **98.304 Pixel des ursprünglichen 384×256-Ausschnitts bei x=128/y=64** exakt erhalten. Profil, Straight-Alpha, PNG-Roundtrip und die explizite Alpha-Erhaltpolicy der halbtransparenten Fixture bestehen. Die beschrifteten aktuellen Vergleiche zeigen weiterhin alle sieben Qualitätsfehler; drei Fälle wurden zusätzlich unabhängig visuell geprüft. Bericht und Bildhashes: [`current-compositor-2026-10-17/`](../reports/image-backend/current-compositor-2026-10-17/), abschließendes [`visual-review.json`](../reports/image-backend/current-compositor-2026-10-17/visual-review.json).

## Capabilities und Produktintegration

| Operation | Kandidatenbewertung | Produktstatus |
| --- | --- | --- |
| Text-to-Image | `unverified`, kein eigener erfolgreicher Test | unavailable |
| Image-to-Image | `unverified`, kein eigener erfolgreicher Test | unavailable |
| Echte maskierte Bearbeitung | `unsupported` für diese Freigabe: echte Inferenz, Qualität FAIL | unavailable |
| Hintergrundbearbeitung mit Erhaltmaske | `unsupported` für diese Freigabe: Feinkantenqualität FAIL | unavailable |
| Outpainting | `unsupported` für diese Freigabe: Canvasqualität FAIL | unavailable |
| CPU-Fallback | `unverified`, kein freigegebener gleichwertiger CPU-Lauf | unavailable mit verständlichem Fehler |

Der Produktpfad liefert ein getestetes unavailable-Backend unter dem bestehenden AI-01-Vertrag. Eine fehlgeschlagene Freigabe wird nicht durch ein Fake-Bild, Text-to-Image-Demo oder Image-to-Image ersetzt. Der Evaluationsharness verarbeitet Eingabe, kanonische Maske, Prompt, Parameter, Output und JSON-Bericht getrennt von einer Installation. Normale Tests verwenden deterministische Fakes; echte Modelle benötigen einen ausdrücklichen Opt-in. Globale Änderungen eines experimentellen Rohoutputs dürfen nur durch den lokalen Compositor begrenzt angezeigt werden. Eine aktuelle Produkt-Compositor-Probe und ihre genaue Reproduktionsanweisung werden im zugehörigen aktuellen Berichtsordner getrennt von der historischen Serie festgehalten.

## Apple-Core-ML-Kandidat: tatsächliche API geprüft

Apples offizielles `ml-stable-diffusion` wurde am 17. Oktober live auf Commit **`ea2805dc1945be20561c77e5f6d1d9a5a637cda2`** verifiziert. Die Standard-Swift-Pipeline besitzt `startingImage` und `strength`, aber keinen Maskeneingang; ihre Konfiguration unterscheidet Text-to-Image und Image-to-Image. Der Encoderkommentar kündigt Inpainting erst an. Daher ist die unveränderte Standard-API kein belegter Ersatz für den geprüften Maskenpfad. Es wurden hierfür keine zusätzlichen Gewichte geladen. Quellkopien mit SHA256 und aktuelle MIT-Lizenz sind im historischen Berichtsordner unter `research/` archiviert. Die MIT-Lizenz des SDK ersetzt keine jeweilige Modelllizenz. [Gepinnte Konfiguration](https://github.com/apple-aiml-research/ml-stable-diffusion/blob/ea2805dc1945be20561c77e5f6d1d9a5a637cda2/swift/StableDiffusion/pipeline/StableDiffusionPipeline.Configuration.swift), [gepinntes Pipeline-API](https://github.com/apple-aiml-research/ml-stable-diffusion/blob/ea2805dc1945be20561c77e5f6d1d9a5a637cda2/swift/StableDiffusion/pipeline/StableDiffusionPipeline.swift)

## Konkreter optionaler Cloudkandidat

Für den lokalen No-Go wurde **Stability AI Stable Image Edit / Inpaint**, `POST https://api.stability.ai/v2beta/stable-image/edit/inpaint`, anhand offizieller Dokumentation erneut am 17. Oktober geprüft. Der Vertrag beschreibt echtes Maskeninpainting mit Bearer-Authentifizierung und Multipart-Bild/Prompt/optionaler expliziter Maske; die Ausgabe wird als 4 Megapixel beschrieben. Das ist ein konkreter Kandidat, **keine nachgewiesene PicEdit-Route**. Die gewichtsgenaue Modellrevision ist über diesen Dienstvertrag nicht auswählbar. Die API-Serviceversion und tatsächliche Antwortprovenienz müssten separat geführt werden. [Offizielle API-Referenz](https://platform.stability.ai/docs/api-reference#tag/Edit/paths/~1v2beta~1stable-image~1edit~1inpaint/post)

Der aktuelle veröffentlichte Preis beträgt fünf Credits je erfolgreicher Inpaint-Generierung; ein Credit entspricht 0,01 USD. Preise können sich ändern. Es wurden keine authentifizierten Anfragen, Bildübertragungen oder Zahlungen durchgeführt und keine Credentials gesucht oder gelesen. Ein Timeout wäre kein Nachweis einer unberechneten Anfrage. [Offizielle Preise](https://platform.stability.ai/pricing)

Der damalige AI-08-Anthropic-Textprovider ist mit dem interaktiven KI-Assistenten entfernt. Er stellt keinen verwendbaren Cloud-Bildpfad bereit. Ein künftiger Stability-Go benötigt eigenen Provider-/Endpointvertrag, separate Keychain-Zuordnung, gültige auftragsbezogene Bild-/Maskenfreigabe, Kostenreservierung, begrenzten Bildtransport und den tatsächlichen AI-09-Artefaktimport. Serverausgabegröße, Geometrieabbildung, Maskenorientierung, Alpha und Erhaltpixel müssen über dieselbe Produktroute belegt werden. Bis dahin bleibt der Kandidat `unverified` und die Cloud-Bildfunktion unavailable; es gibt keinen automatischen Cloudwechsel. Die Entscheidung für Issue #12 enthält keine offene Anbieterauswahl: **dieser lokale Stand wird nicht freigegeben, diese konkrete Cloudroute erhält ohne tatsächlichen Nachweis ebenfalls kein Go**.

## Aktuelle Reproduktion und normale Tests

`./scripts/evaluate-image-generation.sh` zeigt ohne Argumente nur den Plan und baut oder lädt kein Modell. Das Swift-Werkzeug wird als isolierter Einstiegspunkt im tatsächlichen PicEdit-App-Target kompiliert; die normale App enthält keinen generierenden SDK-Adapter. Modelldownload und Inferenz bleiben getrennt. Der vorgelagerte SwiftPM-Build kann die bereits gepinnten Paketabhängigkeiten in seinen isolierten Cache laden; der Benchmark selbst greift nicht auf Modell- oder Clouddienste zu:

```sh
# Ohne Modelle: eigene Contract-Fixtures bzw. echte archivierte Outputs prüfen.
./scripts/evaluate-image-generation.sh fixtures --out /private/tmp/picedit-contract-fixtures
./scripts/evaluate-image-generation.sh replay --historical reports/image-backend/historical-2026-10-16 --out /private/tmp/picedit-compositor-replay

# Expliziter Download mit gepinnten Hashes, danach separater Offline-Build.
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/picedit-image-evaluation --download
python3 scripts/prepare-image-generation-evaluation.py --root /private/tmp/picedit-image-evaluation --build

# Explizite echte Inferenz: neuer Reportordner, kalt + drei identische warme
# Läufe, synthetische gleichzeitige Preview, eigener Abbruchkontext.
./scripts/evaluate-image-generation.sh benchmark --run --root /private/tmp/picedit-image-evaluation --out /private/tmp/picedit-image-measurement
```

`--all-fixtures` ergänzt die sechs weiteren Maskenfälle. Standardmäßig wird die erste Fixture zur kalten/warmspezifischen Messung wiederholt; die vollständige Qualitätsabdeckung bleibt separat referenziert. Jeder Benchmarklauf prüft vor dem Laden alle Modell-/Input-/Helperhashes, Apple Silicon, mindestens 16 GiB und normalen Speicherdruck. Größen, Prompt, Seed und die übrigen festen Parameter werden im protokollierten Request bzw. gepinnten Parametersatz geführt. Derselbe native Modellkontext bleibt durch die Serie resident. Die einzelne AI-01-Lease bleibt bis zum bestätigten Helperende belegt. Die Uhr `mach_continuous_time` schließt Systemschlaf ein; Abbruch, Fristen und Speicher werden beim Empfang sowie unmittelbar vor dem Verarbeiten eines Ereignisses geprüft. Alle Teilresultate bleiben bei Fehlern im gesonderten Bericht erhalten. Compositing und beschriftete Vergleiche laufen erst nach dem Modellprozess und zählen nicht zur Modellzeit. Ihre Ausgabe liegt im Geschwisterordner `<Messordner>-compositor`.

Die [Werkzeugdokumentation](../tools/image-generation-evaluation/README.md) beschreibt Manifest, Lizenz, temporäre Installation, Offline-Cache und native Buildvoraussetzungen. Normale `./scripts/test.sh --jobs 4`-Läufe verwenden ausschließlich kleine Fakes/Fixtures. `python3 tools/image-generation-evaluation/test_prepare.py` prüft Installation, Hashfehler, Offlinepflicht, sichere Archive und fehlgeschlagene Veröffentlichung ohne Downloads. `./scripts/test-developer-tools.sh` prüft zusätzlich, dass Standardaufruf und fehlendes Inferenz-Opt-in keinen Compiler oder Modellpfad erreichen. Es gibt keinen automatischen Cloudaufruf und keine zusätzlichen KI-Pakete in `Package.swift`.
