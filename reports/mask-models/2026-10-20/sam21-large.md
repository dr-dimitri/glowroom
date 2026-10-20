# SAM 2.1 Hiera Large: lokaler Folgetest

20.10.2026, Apple M2 Pro mit 16 GiB RAM. **Hiera Large funktioniert im nativen
Core-ML-Pfad, verbessert die Auswahl aber nicht durchgehend gegenüber Tiny.**
Der deutlichste Vorteil ist die sauber isolierte Tulpenvase. Eimer und Pyramide
bleiben fehlerhaft. Tiny bleibt deshalb der Kandidat für schnelle Auswahl;
Large ist als zusätzliche Qualitätsoption interessant. Die App wurde nicht
auf eines dieser Modelle umgestellt.

## Modell und identische Testbedingungen

Getestet wurde [Apples Float16-Konvertierung von SAM 2.1 Hiera Large](https://huggingface.co/apple/coreml-sam2.1-large/tree/e830c0874326be7ada2bdc9dff23b7073f884a83),
Revision `e830c0874326be7ada2bdc9dff23b7073f884a83`. Die
[Modellkarte](https://huggingface.co/apple/coreml-sam2.1-large) identifiziert
das zugrunde liegende [Meta-Modell](https://huggingface.co/facebook/sam2.1-hiera-large).
Alle neun Dateien wurden gegen feste Längen und SHA-256 geprüft. Paketumfang:
**457.300.992 Bytes**, gegenüber 79.644.968 Bytes für die bereits getestete
Tiny-Konvertierung. Es handelt sich um den Bildpfad, nicht um Videotracking
oder automatische Vollbild-Objektsuche.

Die sieben privaten Originalfotos und die exakt gleichen, bereits orientierten
sRGB-Proxys aus dem [ersten Vergleich](README.md) wurden wiederverwendet;
Original- und Proxy-Hashes stimmen unverändert. Beide Varianten verwenden:

- 1024 × 1024 Pixel Eingabe, native Float16-Core-ML-Ausführung mit CPU/GPU,
  ohne `allowLowPrecisionAccumulationOnGPU` und mit zugänglichem Core-ML-Dienst.
- Identische manuelle Rahmen und positive Punkte aus
  [`prompts.json`](../../../tools/mask-evaluation/prompts.json), beim Fuchs den
  finalen rechten Rahmenrand `0,86`. Kein Sprachmodell erzeugt diese Positionen.
- Auswahl des Kandidaten mit dem höchsten modellinternen Score, Rückskalierung
  der 256²-Logits per bilinearer Interpolation, anschließend Schwelle null.
  Scores zwischen Modellen sind keine vergleichbaren Genauigkeitswerte.
- Pro Foto ein Encoderlauf und zwei Decoderaufrufe mit gecachten Bildmerkmalen.
  Frische Prozesse, zuerst Large und danach Tiny; schwere Modellarbeiten
  erfolgen seriell, um Konkurrenz um CPU/GPU/RAM zu vermeiden. Unabhängige
  Vorbereitung und Reviews erfolgten parallel.

Der Tiny-Kontrolllauf verwendet dasselbe neue Binary und dieselben finalen
Prompts wie Large. Seine **Logits und PNG-Masken sind bei allen sieben Fotos
bitgleich mit den früheren finalen Tiny-Ergebnissen**; beim Fuchs ist die
korrigierte frühere Einzelprobe die Referenz. Die ursprünglichen Zeitreihen
des ersten Vergleichs bleiben unverändert erhalten.

## Direkter Vergleich mit Tiny

„Warm“ bezeichnet den Median der sechs weiteren Bilder nach dem ersten Foto
bei residentem Modell. Dabei wird ein neues Bild codiert; es ist kein Treffer
eines fertigen Maskencaches.

| Messung | Tiny, neue Kontrolle | Hiera Large |
| --- | ---: | ---: |
| Modellladen, drei Komponenten zusammen | 0,447 s | 1,490 s |
| Erster Encoder + Promptencoder + Decoder | 0,259 s | 2,567 s |
| Warmer Encoder + Promptencoder + Decoder | **0,094 s** | **0,413 s** |
| Bereich der warmen Modellrechnung | 0,089–0,098 s | 0,410–0,425 s |
| Warme Bildanfrage bis zur validierten Logitkopie | **0,235 s** | **0,562 s** |
| Rückskalierung, Schwelle und PNG-Export zusätzlich, warm | 0,035 s | 0,036 s |
| Peak Prozess-RSS | **0,283 GiB** | **0,902 GiB** |

Large benötigt hier etwa **4,39-mal die Modellrechenzeit**, **2,39-mal die
Anfragezeit** und **3,19-mal den Prozessspeicher** der Tiny-Kontrolle.
Die Anfragezeit enthält PNG-Decodierung, sRGB-Skalierung, Encoder, Prompt und
Decoder sowie die validierte Kopie der nativen Logits. Laden und anschließende
Raster-/PNG-Ausgabe sind getrennt. Die NSNumber-basierte Logitkopie im
Entwicklerharness kostet bei beiden Varianten zusätzliche Zeit; die
Anfragezeit ist deshalb keine zugesicherte spätere App-Latenz.

System-, Core-ML- und GPU-Caches wurden nicht geleert. Insbesondere die erste
neue Tiny-Ausführung profitiert von bereits genutzten Graphen. Die beobachteten
ersten Aufrufe sind **kein fairer Kaltstartvergleich**; der frühere erste
Tiny-Wert von 5,053 s wird nicht durch den neuen Kontrollwert widerlegt.
RSS ist der separate Prozesspeak und erfasst nicht zwingend den gesamten
GPU-/Treiberbedarf. Die Messung ist eine einzelne Serie auf dieser Hardware,
keine statistische Leistungszusage.

Bei beiden Varianten waren die wiederholten Decoderlogits für alle sieben
Fotos exakt gleich. Die Wiederholungen cachen den Encoder und dürfen nicht
als Laufzeit für ein neues Foto ausgegeben werden. Alle Einzelwerte, Pins und
Messabschnitte stehen in
[`sam21-large-measurements.json`](sam21-large-measurements.json).

## Sichtprüfung der sieben Fotos

Die Prüfansicht zeigt Original, Tiny, Large, BiRefNet HR und BEN2 mit ihren
Masken und einer gemeinsamen Hintergrundabdunklung von −2 EV in linearem
sRGB. Die automatische Vordergrundwahl von BiRefNet/BEN2 und die gezielte
SAM-Auswahl sind unterschiedliche Aufgaben. Es gibt keine Referenzmatten;
aus diesen Sichtbefunden wird keine objektive Genauigkeitsquote abgeleitet.

| Foto | Large gegenüber Tiny | Vergleich mit bisherigen Ergebnissen |
| --- | --- | --- |
| Eimer | Teilweise weniger Löcher; dunkle Eimerflächen fehlen weiterhin, Fußmatte mitgewählt | BEN2 trennt die Eimer plausibler; BiRefNet HR praktisch leer |
| Häuser | Kein klarer Vorteil, zusätzliche Unterbrechungen innerhalb der Hausgruppe | Beide SAM-Varianten adressieren das Ziel besser als die automatische Vordergrundwahl |
| Schneemann | Linker Karottenarm vollständiger; kleine zusätzliche Auswahlflecken am Boden | BiRefNet HR und BEN2 bei der Gesamtform weiterhin vergleichbar |
| Pyramide | Starke falsche Innenlöcher bleiben; zusätzlich teilweise beschädigte Dachkante | Kein Fortschritt gegenüber Tiny, stellenweise schlechter; BEN2 erfasst die Gesamtform überzeugender |
| Insel | Ähnlich; stärkere Glättung verliert kleine Vegetationsdetails | Beide SAM-Varianten wählen die gewünschte Insel; automatische Modelle verfehlen dieses Ziel |
| Plüschfuchs | Unterschiede an Armen und unteren Teilflächen, kein deutlicher Gesamtsprung | Harte und teils fragmentierte Konturen bei beiden; BiRefNet HR zeigt weichere Fellübergänge |
| Tulpenvase | **Klar besser:** zusätzliche Kerzen-/Nachbarobjektauswahl entfernt | Deutlich gezielter als die breite Tisch-/Stuhlauswahl von BiRefNet HR/BEN2; Blüten und Stiele weiter vereinfacht |

Large erzeugt weiterhin binäre Segmentierung und keine qualifizierte
Transparenzmatte. Mehr Modellgröße behebt die Auswahlfehler dieser Bilder
nicht zuverlässig und ersetzt keine Matting-Prüfung an Fell, Haaren oder
Mischpixeln. Auch Large wurde nicht auf deutsche Bearbeitungsanweisungen oder
die Kopplung mit einem Textplaner getestet.

## Einordnung in den bisherigen Vergleich

Die vier anderen Modellpfade wurden nicht erneut gemessen. Ihre bisherigen
Werte dienen der Einordnung; die Abschnitte sind nicht deckungsgleich.

| Modellpfad | Median weiterer Bilder | Gemessener Abschnitt |
| --- | ---: | --- |
| SAM 2.1 Tiny, neue Core-ML-Kontrolle | 0,094 s | Encoder + erster Promptencoder + Decoder |
| SAM 2.1 Hiera Large, Core ML | 0,413 s | Encoder + erster Promptencoder + Decoder |
| BiRefNet HR Matting, Core ML | 2,559 s | Nur native Vorhersage |
| BEN2 Base, ONNX CPU | 4,721 s | Nur native Vorhersage |
| BiRefNet standard GGUF, CPU | 23,412 s | Vorbereitung, Graph, Inferenz und Rückskalierung |
| EfficientSAM3 EV-M, CPU | 1,796 s | Bildencoder und Text-/Maskenpipeline |

Large ist auf diesem Rechner für gelegentliche gezielte Auswahl mit rund
0,56 s bis zur Logitkopie praktikabel. Der Mehrbedarf lässt sich durch die
sichtbar bessere Einzelvase begründen, jedoch nicht als genereller
Qualitätsgewinn auf allen Motiven. **Tiny als schnellen Standardkandidaten
weiterverfolgen; Large bei Bedarf als zusätzliche Qualitätsoption prüfen.**
Für eine vollständige Ablösung von BiRefNet HR Matting ergibt sich weiterhin
keine belastbare Grundlage. Es wurde keine neue Modellauswahl in die App
integriert.

## Verifikation und lokale Ergebnisse

Die isolierten Swift-Helfer und beide Modellpakete wurden kompiliert, beide
nativen Serien mit allen sieben Fotos ausgeführt. Die 18 Paketdateien wurden
unabhängig erneut geprüft, Python-Syntax, Variantenargumente, Bildgeometrien,
Dokumentationslinks und bereinigte JSON-Berichte kontrolliert. Unabhängige
Reviews der Harnessänderungen und aller sieben Vergleichsansichten ergaben
keine offenen Befunde. Der Tiny-Regressionsvergleich bestätigt unveränderte
Rechensemantik; die bisherigen CLI-Aufrufe wählen weiterhin Tiny.

Private Bilder, Logits und Rohberichte liegen ausschließlich unter
`Fixtures/LocalTestImages/Evaluation-SAM21-Large-20261020/`, von Git
ausgeschlossen. Originaldateien bleiben unverändert; Modelle, Pythonumgebungen,
Originale und abgeleitete Bilder werden nicht veröffentlicht.

Geändert wurden nur eigenständige Entwicklerwerkzeuge und Dokumentation,
keine App-Quellen, Buildkonfiguration, App-Abhängigkeiten oder eingebundenen
Ressourcen. Deshalb ist gemäß Projektvorgaben kein vollständiger App-Build
erforderlich; die tatsächlich verwendeten Benchmark-Helfer wurden kompiliert.
