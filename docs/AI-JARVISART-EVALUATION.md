# Lokale JarvisArt-Prüfung vom 23. Oktober 2026

**Ergebnis: keine Freigabe zur automatischen Übernahme in der geprüften
Konfiguration.** Im gemeinsamen Vertrag fehlen alle Pflichtkorrekturen. Im
nativen Format erkennt das Modell den Korrekturbedarf besser und liefert
tatsächliche Tonwertparameter, schlägt aber auch bei guten Bildern Änderungen vor und
erzeugt bei den selektiven Pflichtfällen keine räumliche Maske. Der Befund
betrifft diesen Prompt, diese Quantisierung und zwölf synthetische Bilder;
er ist keine allgemeine Aussage über alle JarvisArt-Konfigurationen.

Diese Prüfung untersucht Szenenverständnis und automatische Korrekturplanung
auf denselben zwölf lokalen Fällen wie die
[Qwen3.5-Prüfung](AI-QWEN35-EVALUATION.md). Sie ist eine tatsächliche lokale
Inferenz mit heruntergeladenen Gewichten, keine Auswertung von Herstellerdemos.
Ein Lightroom- oder Glowroom-Korrekturadapter wird nicht ausgeführt;
Maskenraster, gerenderte Bildqualität und End-to-End-Korrektur bleiben `notRun`.

## Modell, Laufzeit und Quellen

- Offizielles Modell: `JarvisArt/JarvisArt-1208`, Revision
  `be67846a4be4780fde86473ce19fc3f3af77e4d4`, Architektur
  `Qwen2_5_VLForConditionalGeneration`.
- Tatsächlich ausgeführte Community-Konvertierung:
  `mradermacher/JarvisArt-1208-GGUF`, Revision
  `0abebb0c1c4a8e7745b9383f174df884b7662a4d`.
- Sprachgewichte: `JarvisArt-1208.Q4_K_M.gguf`, 4.683.072.640 Byte,
  SHA-256 `a12b9cbb32f1488d8c50671ae87c1a55c388c4e9b98d95ae5d68c9a0713b5704`.
- Vision-Projektor: `JarvisArt-1208.mmproj-f16.gguf`, 1.354.163.072 Byte,
  SHA-256 `03cddf9871507299ec8fc9713530b837abf223a504b918d3a56d62286e91f112`.
  Beide Dateien wurden vor den Modellanfragen gegen diese Hashes geprüft.
- Laufzeit: llama.cpp bei
  `f64a49819ccbf67a710f9a1927080e25775651ef`, separat unter `/tmp` mit
  Metal und sechs Build-Jobs gebaut. Das Binary und seine dynamischen
  Bibliotheken sind in der lokalen Laufprovenienz gehasht. Das Quellarchiv hat
  keine Git-Metadaten; die API meldet deshalb `b0-unknown`. Maßgeblich sind die
  aufgezeichnete Quellrevision und die tatsächlichen Dateihashes.
- Gerät: Apple M2 Pro, 16 GB Unified Memory. Python-Umgebung und Paketstand
  stammen aus dem vorhandenen Qwen-Versuch und sind je Lauf eingefroren.

[Offizielle Gewichte](https://huggingface.co/JarvisArt/JarvisArt-1208),
[GGUF-Snapshot](https://huggingface.co/mradermacher/JarvisArt-1208-GGUF/tree/0abebb0c1c4a8e7745b9383f174df884b7662a4d),
[geprüfter Upstream-Code](https://github.com/LYL1015/JarvisArt/tree/32a7e5845ba635a7caba480197c61df91df03796).
Die JarvisArt-Lizenz beschränkt die bereitgestellten Materialien auf
nichtkommerzielle Verwendung außerhalb des Produktivbetriebs. Dieser lokale
Versuch integriert oder verteilt keine Gewichte in Glowroom.
[Lizenz](https://github.com/LYL1015/JarvisArt/blob/32a7e5845ba635a7caba480197c61df91df03796/LICENSE).

## Vorab festgelegte Bedingungen

Die zwölf Quellen, der Erwartungsvertrag und das vollständige Antwortschema
bleiben unverändert. Quellenprüfung und Rastervorbereitung verwenden drei
Worker. Ein Modellprozess mit einem Slot verarbeitet die Fälle seriell;
gleichzeitige Modellarbeit würde Speicher und Laufzeiten verfälschen.
Das Modell erhält ausschließlich anonym neu kodierte RGB-Bildpixel und den
jeweils gemeinsamen Prompt, weder Dateinamen noch Fallkennungen, Sollwerte,
Messregionen oder Generierungsprompts.

Die LANCZOS-Eingaben mit 1024 Pixeln langer Kante sind bytegleich zum
vorbereiteten RGB-Raster des Qwen-Versuchs. Die unterschiedlichen Modellprozessoren
und Laufzeiten machen daraus keinen identischen Bildtoken- oder Leistungstest.
Jarvis verwendet 8192 Kontexttokens, sechs CPU-Threads, Metal-Offloading,
512er Batch-/Microbatch-Größen und deaktivierten Prompt-/RAM-Cache.
`--reasoning-format none` erhält native Think-/Answer-Ausgaben im Rohtext.
`--offline`, lokale Gewichtsdateien und Loopback verhindern Modellanbieteraufrufe;
öffentliche Gewichts-/Quellcode-Downloads fanden vor der Inferenz statt.

Ein erster reiner Serverstart meldete die Empfehlung, für Qwen-VL-Grounding
mindestens 1024 Bildtokens zu verwenden. **Vor jeder Fixture-Inferenz** wurde
der Testplan deshalb um `--image-min-tokens 1024 --image-max-tokens 1280`
ergänzt und der Server neu gestartet. Der erste Start und diese Vorabänderung
bleiben lokal dokumentiert. Es gab davor keine Bildantworten und keine
fallabhängige Anpassung. Der endgültige Vorabplan hat SHA-256
`d5485776640ddb3ba63d9ca1511259754764a674db7127882696894a4e837918`.

**Run 01 – gemeinsamer Vertrag:** derselbe deutsche Prompt und dieselbe
Decoderansicht wie Qwen Run 02; Greedy-Decoding, Seed 0 und höchstens
768 Ausgabetokens. Nicht unterstützte Decoderregeln (`uniqueItems`, bedingte
`allOf`-Regeln) werden weiter gegen das unveränderte vollständige Schema geprüft.
Prompt SHA-256:
`ed09169664eecc31103275181e2f249fcc4cb1b2de9b2acafc24e6d4a2b41f3d`.

**Run 02 – natives Format:** unveränderter
`SHORT_SYSTEM_PROMPT_WITH_THINKING` aus der gepinnten Upstream-Datei
`utils/system_prompt.py`, auch einschließlich ihrer redaktionellen Resttexte.
SHA-256:
`e14039c53c841009d6b9f61a5c0e16763932de5a92fd70105aac49bd0c88ac91`.
Die gemeinsame deutsche Bildaufgabe erhält nur eine passende Ausgabeanweisung
für `<think>…</think><answer>…</answer>` und Lightroom-Parameter, ohne
fallspezifische Hinweise. Dieser getrennte Prompt verlangt bei fehlendem Bedarf
ein leeres Parameterobjekt. Es gelten Greedy-Decoding, Seed 0 und höchstens
2048 Ausgabetokens, ohne erzwungenes Antwortschema. Ein nativer Erfolg wäre
kein nachträgliches Bestehen von Run 01.

Beide Bedingungen umfassen die vollständigen zwölf Fälle in fester Reihenfolge,
ohne selektive Wiederholungen oder Antwortreparatur. Ein reguläres Prozessende
beweist technische Inferenz, keine bestandene Fotokorrektur.

## Ergebnis des gemeinsamen Vertrags

Alle zwölf HTTP-Anfragen wurden technisch ausgeführt. Elf endeten regulär,
Fall 11 erreichte das 768-Token-Limit während einer wiederholten Beschreibung.
Alle elf vollständig beendeten Antworten schlagen `no_op` vor. Es gibt keine
brauchbare erforderliche Korrektur für dunklen Schnee, Innenschatten oder das
Gegenlichtgesicht.

| Automatischer Zustand | Anzahl |
| --- | ---: |
| Vollständiges Schema bestanden, fachliche Kriterien verletzt | 9 |
| Schemafehler | 3 (03 und 09: doppelte Tags; 11: abgeschnitten) |
| Alle maschinellen Kriterien erfüllt | 0 |
| Timeout / technische Inferenzfehler | 0 |

Fehlende Tags sind dabei nicht automatisch fehlendes Motivverständnis: Die
erste Landschaft wird etwa als See in den Alpen beschrieben, aber nicht als
`landscape` getaggt. Für die Pflichtkorrekturen kommen dagegen echte
Planfehler hinzu. Nacht und Sonnenuntergang erhalten passende unveränderte
Pläne; das strukturelle Ergebnis scheitert dennoch an anderen Anforderungen.
Die ausführliche unabhängige Sichtung wird getrennt lokal aufbewahrt.

## Ergebnis des nativen Formats

Alle zwölf Antworten enden regulär und enthalten genau einen vollständigen
`<answer>`-Block. Die Parameterobjekte sind Python-Literale mit beispielsweise
`True` statt gültigem JSON; sie sind mit dem auch von Upstream verwendeten
`ast.literal_eval` lesbar. Das ist ein nativer Parse-Nachweis und kein Bestehen
des gemeinsamen Antwortschemas. Der lokale Parser weist doppelte Schlüssel,
nicht endliche Zahlen und unvollständige Antworten zurück und verändert keine
Rohantwort. Der vollständige Parser bleibt mit seinem Hash bei den privaten
Laufdaten erhalten.

**Kein einziges Objekt ist leer; kein einziges enthält eine nichtleere
`MaskGroupBasedCorrections`-Liste.** Alle zwölf Pläne verfehlen mindestens einen
Teil des vorab festgelegten strengen Vertrags. Das ist kein Nachweis, dass
jedes gerenderte Ergebnis schlecht aussähe. Insbesondere die gewünschte
Aufhellungsrichtung beim dunklen Schnee wird im nativen Format getroffen.

| Fall | Beobachteter nativer Vorschlag | Bewertung des Plans |
| --- | --- | --- |
| 01 ausgewogene Landschaft | Belichtung −0,04 EV, Schatten +26, Lichter −27, Dynamik +10 | Motiv erkannt, aber kein zurückhaltender No-op. |
| 02 heller Schnee | Unter anderem feste Temperatur/Tönung und aktiviertes Objektivprofil mit Digest | Schnee erkannt; unveränderte Darstellung ist aus diesem nichtleeren, teilweise unbelegten Einstellungsobjekt nicht nachgewiesen. |
| 03 dunkler Schnee | Belichtung +0,48 EV, Schatten +30, Weiß +33; zusätzlich Kontrast und Farbe | Kernentscheidung und Aufhellungsrichtung passen. Zusätzliche Farb-/Kontraständerungen verfehlen den strengen Planvertrag; Teilziel erfüllt. |
| 04 Innenraum | Dunkle Möbel und heller Garten erkannt; Belichtung +0,2 EV, Schatten +55, Lichter −68, Vignette −18; Maskenliste leer | Plausible globale Tonwertidee, aber keine geforderte räumliche Auswahl oder geprüfter Fensterschutz. |
| 05 Nacht | Nacht erkannt; Belichtung +0,42 EV, Schatten +43, zusätzliche Farb-/Profilwerte | Kein erforderlicher No-op; ein konkretes Canon-Objektivprofil ist für dieses EXIF-freie PNG unbelegt. |
| 06 Gegenlichtporträt | Gesichtsschatten erkannt; globale Schatten +53 und Lichter −67, keine Personen-/Gesichtsmaske | Erforderliche räumlich selektive Aufhellung fehlt. |
| 07 Mischlicht | Globale Schatten +40, Lichter −58 und feste Temperatur/Tönung | Lichtquellen nicht ausreichend getrennt; aktive globale Korrektur statt des vertraglichen No-op beziehungsweise Begrenzungshinweises. |
| 08 Sonnenuntergang | Abendstimmung erkannt; unter anderem Kontrast −12, Schatten +18, Dynamik +11 | Kein erforderlicher No-op. Eine tatsächliche Neutralisierung der warmen Stimmung wird ohne Render nicht behauptet. |
| 09 Nebel | Weichen Nebel erkannt; Weiß +46, Schwarz −26, Kontrast +7 | Kein erforderlicher No-op; tatsächliche Kontrastwirkung bleibt ungeprüft. Kein zusätzliches Dehazing behaupten. |
| 10 naheweißes Fenster | Globale Aufhellungs-/Farbparameter, kein Hinweis auf fehlende sichtbare Außenzeichnung | Informationsgrenze nicht benannt; keine sichere Wiederherstellung von Außendetails behauptet. |
| 11 schwarzer Hund | Fell als vollständig im Schatten verloren beschrieben; globale Schatten +49, Lichter −58, Maskenliste leer | Erkennbare Fell-/Gesichtsstruktur unterschätzt; keine zulässige kleine lokale Auswahl. |
| 12 weißes Produkt | Korrekt helle Szene als zu flach/kühl behandelt; Lichter −62, Schwarz −37, Textur/Klarheit jeweils +12, fester Weißabgleich | Kein erforderlicher No-op für die High-Key-Aufnahme. |

Globale Schatten-/Lichterregler beeinflussen Tonwertbereiche und können einen
nützlichen Vorschlag darstellen. Sie beweisen aber keine räumliche
Möbel-/Gesichtsmaske oder den geforderten Schutz anderer Bildregionen. Ohne
Render darf aus diesen Zahlen weder gelungene Fensterzeichnung noch verlorene
Schnee-, Haut- oder Fellstruktur abgeleitet werden.

Die Antworten enthalten zudem nicht verifizierbare Verwaltungs-/Profilwerte
wie `AutoToneDigest` und `LensProfileDigest`. Fall 05 benennt sogar
`Adobe (Canon RF 24-50mm F4.5-6.3 IS STM)`, obwohl das übergebene synthetische
PNG keine Kamera- oder Objektivmetadaten enthält. Solche Angaben dürften nicht
ungeprüft übernommen werden. Absolute Temperatur-/Tönungswerte und vermeintliche
Lightroom-Defaults beweisen ohne bekannten Ausgangszustand ebenfalls keinen
No-op. `{}` wäre ein deklarierter unveränderter Plan gewesen.

Die unabhängige Sichtung aller zwölf Originalraster und Antworten bestätigt
diese Unterscheidung zwischen brauchbarem Teilvorschlag, unvollständigem Plan
und unbewerteter Pixelwirkung. Die lokalen `native-parameters.json` und
`manual-review.json` bewahren Parse-Ergebnis und fachliche Sichtung getrennt.
Eine abweichende globale Promptkalibrierung wäre ein neuer vollständiger Versuch;
dieser Lauf wurde nach Kenntnis der Antworten nicht umformuliert.

## Gemessene Antwortzeiten und Speicher

| Messgröße | Gemeinsamer Vertrag | Natives Format |
| --- | ---: | ---: |
| Vollständig ausgeführte Anfragen | 12 | 12 |
| Regulär beendet / Tokenlimit | 11 / 1 | 12 / 0 |
| Median der HTTP-Antwortzeit | 11,56 s | 32,49 s |
| Minimum / Maximum | 10,73 / 31,51 s | 25,97 / 38,89 s |
| Summe der zwölf Antwortzeiten | 164,16 s | 384,07 s |
| Größter beobachteter Server-RSS | 6.641.680.384 Byte | 6.659.915.776 Byte |
| Eingabetokens je Bild laut Server | 2075 | 3127 |
| Gecachte Prompttokens je Anfrage | 0 | 0 |

Die Zeiten umfassen die lokale HTTP-Anfrage einschließlich serverseitiger
Bildverarbeitung und Antwortgenerierung. Dateiprüfung, Rastervorbereitung,
Modelldownload und Serverstart sind darin nicht enthalten. Im nativen Format
kommen ein anderer Systemprompt und längere Parameterantworten hinzu; die
beiden Zeitspalten sind unterschiedliche Aufgaben. Alle OS-Messzähler waren
erreichbar. Der separat gestartete Server wurde nach den Läufen kontrolliert
beendet; es bleibt kein laufender Modellprozess.

## Messgrenzen und Ablage

Die API bestätigt `modalities.vision=true` und den tatsächlichen lokalen
Modellpfad. Runtime, Modell, Projektor, Host, Port und ein Slot werden zusätzlich
an den Serverprozess gebunden. Der Server meldet im gemeinsamen Lauf für jedes
Bild 2075 Eingabetokens und null gecachte Prompttokens. Rohe API-Antworten,
Template-Diagnose und Serverlogs bleiben erhalten. Die API liefert keinen
separaten Bildtokenzähler; der Runner behauptet daher keinen direkt gemessenen
Bildtokenwert. Ein Template-Marker ist kein Bildtoken.

Die Speicherwerte sind im 50-ms-Raster beobachteter Server-Prozessbaum-RSS.
Sie sind kein MLX-/Metal-Allokatorpeak und keine vollständige Systembilanz.
Globale Verfügbarkeit und Swap-Veränderungen sind nicht eindeutig diesem
Prozess zuzuordnen. Andere Anwendungen blieben offen. Es wurde kein
OS-Dateicache geleert, keine vollständige Kalt-/Warmcache-Serie durchgeführt
und kein 8-GB-Rechner geprüft. Die verschiedenen Tokenbudgets, Quantisierungen
und Laufzeiten erlauben keinen isolierten Geschwindigkeitsvergleich mit Qwen.

Private Ergebnisse liegen unter `Fixtures/LocalTestImages/Evaluations/`, in
`jarvisart-1208-q4km-2026-10-23-run01-shared` und
`jarvisart-1208-q4km-2026-10-23-run02-native`. Rohantworten, Bilder, Gewichte,
Prompts und vollständige private Provenienz bleiben ignoriert und werden weder
committet noch nach GitHub übertragen. Der wiederverwendbare Runner und seine
isolierten Tests stehen unter [Werkzeugablauf](../tools/auto-correction-evaluation/README.md).

Ein sauberer App-Build ist nicht erforderlich: Geändert werden ausschließlich
optionale externe Evaluationswerkzeuge und Dokumentation, keine App-Quellen,
Abhängigkeiten, Ressourcen oder Build-/Paketierungskonfiguration.

## Review und Werkzeugprüfung

Der neue Runner wurde unabhängig einschließlich Bildübertragung, Blindheit,
Provenienz, Messung und Fehlerbehandlung reviewt. Dabei gefundene Fehler bei
Bildtokenzählern, fehlenden OS-Messrechten, JSON-Duplikaten/Zahlenüberlauf und
der Bindung von Dateiprovenienz an Prozess und Endpunkt wurden direkt behoben
und erneut geprüft. Keine offenen relevanten Codebefunde.
Nach der finalen Codekorrektur bestanden alle **42 isolierten Werkzeugtests**
einschließlich der 13 Jarvis-Tests. Beide Bedingungen wurden auf bytegleichen
vorbereiteten Rastern gegen die gespeicherten Qwen-Identitäten abgeglichen;
gemeinsamer Prompt, Oracle und Antwortschema stimmen ebenfalls überein.
Das abschließende unabhängige Review hat zusätzlich alle Ergebniszahlen,
Tabellenparameter, Quellen-/Runneridentitäten und Dokumentationslinks gegen
die tatsächlichen lokalen Laufdaten geprüft; keine offenen Befunde.
