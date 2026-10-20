# Florence-2-large: lokaler Vergleich

20.10.2026, Apple M2 Pro mit 16 GiB gemeinsamem Speicher. Untersucht wird
**Microsoft Florence-2-large** mit denselben sieben lokalen Testfotos wie in
den [bisherigen Modellvergleichen](README.md).

## Exakte Modellidentität und Schnittstelle

Verwendet wird der offizielle Checkpoint
[`microsoft/Florence-2-large`](https://huggingface.co/microsoft/Florence-2-large/tree/21a599d414c4d928c9032694c424fb94458e3594),
Revision `21a599d414c4d928c9032694c424fb94458e3594`. Die Safetensors-Datei umfasst
**1.553.563.458 Bytes**, SHA-256
`4f38ce741c6b71188fe2b3419a55e11917a8a7b321ae2e63c61da0191b0ebad7`.
Konfiguration, Tokenizer, Processor und Microsoft-Pythonquellen werden ebenfalls
gepinned und vor Verwendung geprüft.

Die [Microsoft-Modellkarte](https://huggingface.co/microsoft/Florence-2-large)
beschreibt diesen Stand als fortgesetzt vortrainierte Version mit
4096 Textpositionen und weist auf das begrenzte zusätzliche Training hin.
Die [4k-Änderung](https://huggingface.co/microsoft/Florence-2-large/commit/00d2f1570b00c6dea5df998f5635db96840436bc)
stammt vom 08.12.2024. `Florence-2-large-ft` ist ein separat feinabgestimmter
Checkpoint; Community-Konvertierungen besitzen ebenfalls eigene Konfigurationen
und Gewichtshashes. Sie werden in diesem Test nicht als Microsoft Large
ausgegeben. Ergebnisse gelten für die konkret geprüfte Revision.

Microsofts Veröffentlichung enthält eine eigene Python-Implementierung und
einen eigenen Processor. Die eingebauten Klassen neuer Transformers-Versionen
sind kein automatisch identischer Ladepfad: Konfigurationsnamen, Gewichtsschlüssel,
Projektionsmatrix-Ausrichtung und Tokenizer-/Parserdetails unterscheiden sich.
Der unveränderte Microsoft-Code scheitert im dokumentierten Preflight unter
Transformers 5.20.2 bereits beim Konfigurationsaufbau an
`Florence2LanguageConfig.forced_bos_token_id`, vor Gewichtsladen und Inferenz.
Die tatsächliche Inferenz läuft mit unveränderten Microsoft-Quellen unter
Transformers **4.49.0**, Torch **2.14.1**, torchvision 0.29.1, Hub **0.28.1**,
tokenizers 0.21.4, Python 3.11.16. Nur der vorherige Download verwendet Hub 2.2.0.
Die Gewichte laden ohne fehlende, unerwartete oder formabweichende Schlüssel;
918 gespeicherte Tensoren mit 776.721.497 Elementen wurden zusätzlich geprüft.
Die drei tatsächlich ausgeführten Microsoft-Quelldateien stimmen mit ihren
gepinnten SHA-256 überein. Es werden nur Safetensors geladen.
Quellen: [Microsoft-Konfiguration](https://huggingface.co/microsoft/Florence-2-large/blob/21a599d414c4d928c9032694c424fb94458e3594/config.json),
[native Transformers-Konfiguration](https://github.com/huggingface/transformers/blob/v5.20.2/src/transformers/models/florence2/configuration_florence2.py).

## Aufgaben und Vergleichsbedingungen

Florence liefert autoregressiv Text und quantisierte Koordinatentokens. Es
besitzt eine andere Schnittstelle als die bisherigen SAM-Decoder:

| Aufgabe | Eingabe | Nutzbare Ausgabe |
| --- | --- | --- |
| `<REFERRING_EXPRESSION_SEGMENTATION>` | Aufgabenpräfix + englischer Zielbegriff | Instanzen mit Teilpolygonen; daraus binäres Raster |
| `<CAPTION_TO_PHRASE_GROUNDING>` | Aufgabenpräfix + englischer Zielbegriff | Boxen mit Labels; allein keine Maske |

Die Zielbegriffe sind unverändert: `buckets`, `houses`, `snowman`, `toy pyramid`,
`island`, `stuffed fox`, `vase of tulips`. Florence bekommt keine manuellen
räumlichen Hinweise. Die bisherigen SAM2-/EfficientViT-SAM-Proben erhielten
zusätzlich Rahmen und Punkte. Dieser Vergleich bewertet daher unterschiedliche
vollständige Ziel-zu-Region-Pfade, keine isolierte Segmentiergenauigkeit.

Originale und die bereits orientierten sRGB-Proxys bleiben unverändert.
Verwendet werden exakt dieselben Vorschau-Dateien mit maximal 2048 Pixeln
längster Seite. Die modellinterne Aufbereitung folgt dem zum Checkpoint
gehörenden Processor, nicht der alten SAM-Skalierung. Die anderen Modelle
werden nicht parallel erneut ausgeführt; deren gespeicherte finale Masken und
getrennte Messreihen dienen als Referenz. Schwere Modelljobs laufen seriell,
unabhängige Vorbereitung und Reviews parallel.

Der offizielle Processor wird mit `image_size=(width, height)` der
Originalvorschau aufgerufen. Seine Ergebnisse enthalten bereits Pixelkoordinaten.
Microsoft dequantisiert die 1000 Positionsbins über deren Binzentren. Eine
zweite Skalierung der bereits zurückgerechneten Polygone wäre falsch.
Polygonlisten enthalten Instanzen, darin Teilpolygone und flache x/y-Paare;
explizite Rollen für Löcher oder Innenringe fehlen. Gültige Teilpolygone werden
vereinigt und als binäres Raster gespeichert, nicht als Alpha-Deckung.
Quelle: [geprüfter Microsoft-Processor](https://huggingface.co/microsoft/Florence-2-large/blob/21a599d414c4d928c9032694c424fb94458e3594/processing_florence2.py).

Rohantworten und Tokenfolgen bleiben lokal erhalten. Tokenbudget, EOS-Abschluss,
Syntax, degenerierte Polygone und leere Ergebnisse werden getrennt erfasst.
Ein EOS allein belegt keine vollständige Antwort: BART kann damit beginnen,
und am Tokenlimit kann ein EOS erzwungen werden. Eine leere oder beschädigte
Antwort ist keine brauchbare Hintergrundauswahl. Es gibt keine Referenzmatten
und damit keine objektive Genauigkeitsquote.

## Tatsächlich ausgeführte Hauptserie

MPS mit Float16, `eager`-Aufmerksamkeit, vier CPU-Threads und ausdrücklich
abgeschaltetem MPS-CPU-Fallback. Alle Modelleingaben sind **1 × 3 × 768 × 768**.
Der Microsoft-CLIPImageProcessor übernimmt die checkpointgerechte Skalierung
und ImageNet-Normalisierung. Die beiden Aufgaben verwenden drei Beams,
`do_sample=False`, KV-Cache und höchstens **1024 neue Tokens**, entsprechend
dem Aufgabenbeispiel der Modellkarte. Deren allgemeines Einstiegsbeispiel zeigt
auch 4096; gezielte Kontrollen mit höherem Limit sind getrennt ausgewiesen.
Der Microsoft-Wrapper delegiert an das innere Sprachmodell. Dessen offizielle
Defaults gelten zusätzlich, darunter `early_stopping=True`,
`no_repeat_ngram_size=3`, erzwungener BOS 0 und EOS 2. Das wurde nachträglich
an einem gewichtslosen Meta-Modell derselben Konfiguration geprüft; die äußere
`generation_config.json` allein beschreibt diesen Pfad nicht vollständig.

Jeder `generate`-Aufruf enthält erneut den Bildencoder und die autoregressive
Ausgabe. Das Foto wird einmal je Bild decodiert; Encodermerkmale werden zwischen
den Aufgaben nicht gecacht. MPS wird an den Messgrenzen synchronisiert. Die
erste Generierung kann zusätzliche MPS-Initialisierung enthalten; die folgenden
verschiedenen Motive sind keine warmen Wiederholungen desselben Auftrags.

| Foto / Ziel | Polygon: Generate | Neue Tokens | Abschlussprüfung | Grounding: Generate | Boxen |
| --- | ---: | ---: | --- | ---: | ---: |
| 1 Eimer | 5,687 s | 180 | bestanden | 0,805 s | 5 |
| 2 Häuser | 15,672 s | 986 | bestanden | 0,772 s | 5 |
| 3 Schneemann | 9,727 s | 642 | bestanden | 0,578 s | 1 |
| 4 Spielzeugpyramide | 16,507 s | 986 | bestanden | 0,634 s | 1 |
| 5 Insel | 19,113 s | 1024 | **Tokenlimit erreicht** | 0,781 s | 3 |
| 6 Plüschfuchs | 11,927 s | 649 | bestanden | 0,674 s | 1 |
| 7 Tulpenvase | 18,966 s | 1024 | **Tokenlimit erreicht** | 0,744 s | 2 |

„Bestanden“ bezieht sich ausschließlich auf Abschluss, Syntax und nicht
degenerierte Geometrie. Alle sieben Polygonantworten und Groundingantworten
enthalten geparste Formen; nur fünf Polygonantworten bestehen die vollständige
Abschlussprüfung. Alle sieben Groundingantworten bestehen sie. Keiner dieser
Zähler misst richtige Objektauswahl.

Über alle sieben Bilder einschließlich Erstaufruf und Limitfällen liegt der
Median für Polygon-`generate` bei **15,672 s**, bis zum geparsten Ergebnis bei
**15,698 s** und bis zum gespeicherten Raster bei **15,701 s**. Grounding benötigt
**0,744 s**, **0,777 s** beziehungsweise **0,780 s**. Die vollständige Serie mit
Prüfungen, Importen, Laden und privaten Ausgaben dauert 113,44 s.

Modell-/Processorladen und Übertragung zu MPS dauern 1,286 s, nach 0,773 s
vollständigem Hashlesen und 7,963 s Importzeit. Diese Ladezeit ist **kein
Kaltstart vom ungecachten Datenträger**. Bilddecodierung benötigt separat
0,036–0,047 s. Prozess-RSS erreicht **0,644 GiB**; maximal an den Taskgrenzen
beobachteter MPS-Treiberspeicher **2,632 GiB**, aktuell zugewiesener MPS-Speicher
rund 1,453 GiB. Die Unified-Memory-Werte können sich überlappen und dürfen nicht
addiert werden; der Treiberwert ist kein kontinuierlich gemessener Spitzenwert.

## Gezielte Kontrollen

Die unveränderte Wiederholung beider Schneemann-Tasks in einem neuen Prozess
liefert beim Grounding identische Tokens, Koordinaten und Raster. Die
Polygonsegmentierung ist dagegen **nicht token- oder pixelidentisch**:
482 statt 642 neue Tokens, aber sehr ähnliche Form mit binärer Masken-IoU
**0,99448** und Pixelübereinstimmung **0,99870**. Das sind Übereinstimmungsmaße
zwischen zwei Modellantworten, keine Genauigkeit gegen Ground Truth.
`do_sample=False` garantiert in diesem MPS-Pfad somit keine Bitreproduzierbarkeit.

Die beiden Limitfälle wurden zusätzlich mit **2048** neuen Tokens als Obergrenze
in einem eigenen Prozess geprüft. Die Insel beendet nach 934 Tokens in
17,886 s, die Vase nach 1062 Tokens in 17,986 s; beide bestehen Abschluss und
Geometrieprüfung. Die Inselkontrolle maskiert die kleine Zielinsel statt des
Dreiecksartefakts, allerdings mit einer sichtbar eckigen unteren Kontur. Die
Vasenkontrolle liefert eine brauchbare vereinfachte Auswahl ohne die Kerzen.
Das verbessert den Befund dieser beiden Motive. Die Hauptserie bleibt
unverändert und ihre Mediane werden nicht durch Kontrollwerte ersetzt.

Die Tokenfolgen dieser Kontrollen weichen schon früh vom Hauptlauf ab. Wegen
der beobachteten MPS-Schwankung und der getrennten Prozesshistorie lässt sich
der Unterschied **nicht allein dem erhöhten Tokenbudget zuschreiben**. Ein
höheres Budget vermeidet die beobachteten Abbrüche in dieser Kontrolle, macht
aber weder alle sieben Zielwahlen zuverlässig noch den Pfad schnell. Die
auffälligen kleinen Masken von Häusern/Pyramide zeigen keine triviale Wiederholung
identischer Punktfolgen; daraus wird keine weitergehende Fehlerursache abgeleitet.

## Sichtprüfung der Hauptserie auf den sieben Fotos

Zwei unabhängige Sichtprüfungen betrachten die Quellbilder, Polygonmasken,
Groundingrahmen und eine Hintergrundabsenkung um zwei Belichtungsstufen in
linearem sRGB. Das ist eine Maskendiagnose, keine Wiederherstellung ausgebrannter
Information. Die beiden Limitfälle bleiben in allen Übersichten als
unvollständige Diagnose markiert.

| Ziel | Florence-Polygonmaske | Grounding / Vergleich zu vorhandenen Masken |
| --- | --- | --- |
| Eimer | Nur ein einzelner Eimer, die Gruppe fehlt. | Mehrere überlappende Rahmen erkennen den Bereich. BEN2 und SAM2 erfassen mehr vom Gruppenziel. |
| Häuser | Kleine Teilfläche eines Hauses statt Häusergruppe. | Häuser plausibel lokalisiert; SAM2/EfficientViT maskieren die Gruppe vollständiger. |
| Schneemann | Gute geschlossene Gesamtform einschließlich beider Karottenarme, ohne auffällige Bodenflecken. | Passender enger Rahmen. Positiver Einzelfall, qualitativ nahe den guten bisherigen Masken. |
| Spielzeugpyramide | Winzige Figuren-/Konturfragmente, die Pyramide fehlt. | Rahmen enthält oben viel Verpackung. BEN2 und EfficientViT sind als Masken deutlich brauchbarer. |
| Insel | Dreiecksartefakt, Ausgabe am Limit unvollständig. | Inselrahmen vorhanden, zusätzlich große falsche Ufer-/Wasserrahmen. Die Vereinigung aller Boxen wäre unbrauchbar. |
| Plüschfuchs | Kopf weitgehend erfasst; sichtbare Arme und untere Teile fehlen, harte Kontur. | Fuchsbereich plausibel lokalisiert. SAM2/EfficientViT erfassen mehr; keine Methode löst die Blumenverdeckung perfekt. |
| Tulpenvase | Plausible schmale Auswahl ohne Kerzen, vereinfachte Stiele; trotzdem unvollständige Ausgabe. | Zwei überlappende Rahmen um Vase/Tulpen. SAM2 Large liefert bereits eine qualifizierte Auswahl ohne die Kerzen. |

## Einordnung gegenüber den früheren Pfaden

| Getesteter Pfad | Gemessener Abschnitt | Zeit |
| --- | --- | ---: |
| Florence Large, Polygon | Median Generate / bis Parsed, alle sieben Bilder | 15,672 / 15,698 s |
| Florence Large, Grounding | Median Generate / bis Parsed, alle sieben Bilder; **noch keine Maske** | 0,744 / 0,777 s |
| EfficientViT-SAM-L1, MPS | Früherer Median ab Bild 2, Encoder+Decoder / vollständiger validierter Quellmaske | 0,053 / 0,113 s |
| SAM2.1 Tiny, Core ML | Frühere Kontrolle ab Bild 2, Encoder+Decoder / bis kopierte native Logits | 0,094 / 0,235 s |
| SAM2.1 Large, Core ML | Früherer Median ab Bild 2, Encoder+Decoder / bis kopierte native Logits | 0,413 / 0,562 s |
| BiRefNet HR, Core ML | Früherer Median ab Bild 2, residenter Inferenzkern | 2,559 s |
| BEN2, ONNX CPU | Früherer Median ab Bild 2, Inferenzkern | 4,721 s |

Diese Abschnitte und Eingaben unterscheiden sich. Florence erledigt zusätzlich
die textbezogene Lokalisierung und generiert unterschiedlich lange Antworten;
die SAM-Reihen erhalten manuelle Raumhinweise. Die Tabelle begründet keine
Architektur-Rangfolge und keinen gleichartigen Ende-zu-Ende-Geschwindigkeitsfaktor.
Die Originalserien und ihre Grenzen stehen im [Hauptbericht](README.md), im
[Large-Bericht](sam21-large.md) und im [L1-Bericht](efficientvit-sam-l1.md).

Für PicEdit belegt diese Revision **keinen allgemeinen Vorteil als direkter
Maskenersatz**. Die Polygonantwort ist langsam und bei mehreren Motiven
unvollständig oder semantisch falsch. Grounding ist deutlich günstiger und
liefert mehrfach brauchbare Startregionen. Eine Kombination Florence → SAM
wurde hier jedoch nicht ausgeführt; Mehrdeutigkeit, falsche Zusatzboxen und
doppelte Rahmen müssten zuverlässig behandelt werden.

Der ursprüngliche Wunsch „Korrigiere den überstrahlten Hintergrund und statte
das restliche Bild mit einer natürlichen Sättigung aus“ ist dadurch nicht als
freie deutsche Bildbearbeitungsanweisung geprüft. Die getesteten Florence-Tasks
lokalisieren englisch benannte Inhalte; sie liefern weder einen verifizierten
Reglerplan noch eine Wiederherstellung verlorener Lichter. Die App-Modellauswahl
bleibt unverändert. `large-ft` wäre eine eigene Modellprobe mit eigenen Gewichten.

## Artefakte, Prüfung und Abschluss

Der [bereinigte Messbericht](florence2-large-measurements.json) enthält
Checkpoint-/Quellpins, Versionen, Einzelzeiten, Form-/Tokenzahlen und getrennte
Kontrollen. Fotos, Masken, Rohtexte, Token-IDs, vollständige Polygone/Boxen und
private Bildhashes verbleiben ausschließlich lokal im ignorierten Ordner
`Fixtures/LocalTestImages/Evaluation-Florence2-Large-20261020/`. Dort liegen
auch Vergleichsgalerien und Diagnosen. Originale und Proxy-Dateien wurden vor
und nach der Auswertung auf unveränderte Bytes geprüft. Gewichte und virtuelle
Umgebungen werden nicht committet. Der [Harness](../../../tools/mask-evaluation/florence2_README.md)
dokumentiert Reproduktion und private Ausgaben.

Geprüft wurden alle 14 Hauptausgaben einschließlich unabhängig kontrollierter
Token-/EOS-/Limitzählung, offizieller Rückskalierung und Rasterisierung. Die
gespeicherten Gray8-Raster stimmen mit der unabhängigen Neurasterisierung
überein. Ein separates Review fand zwei Harness-Schwächen: fehlender
Abbruchstatus bei Strg-C und eine nicht in die Gesamtfreigabe eingerechnete
Quellgrenzenprüfung. Beide sind behoben; alle gemessenen Antworten haben null
Grenzverletzungen, deshalb bleiben ihre Resultate gültig. Syntax-, JSON-,
Artefakt- und Datenschutzprüfungen sowie abschließendes Diff-Review ergänzen
die tatsächlich ausgeführten Modellproben.

Es wurden ausschließlich eigenständige Entwicklerwerkzeuge und Dokumentation
geändert. Keine App-Quelle, Paketabhängigkeit oder eingebundene Ressource ist
betroffen; deshalb entfällt nach Projektvorgabe der vollständige App-Build.
Weitere, vom Auftrag unabhängige Repositoryfehler wurden nicht festgestellt.
