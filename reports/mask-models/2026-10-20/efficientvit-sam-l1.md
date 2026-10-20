# Offizieller EfficientViT-SAM-L1: lokaler Vergleich

20.10.2026, Apple M2 Pro, 12 logische Kerne, 16 GiB gemeinsamer Speicher.
Der Nutzer hat nach Klärung der Modellbezeichnung die offizielle
EfficientViT-SAM-Familie gewählt. Geprüft wurde **L1 mit 512²-Bildencoder**.
Die Ergebnisse gelten für diese Variante; L0/L2/XL0/XL1 wurden nicht getestet.

**Ergebnis:** Der Python/MPS-Pfad verarbeitet neue Bilder mit residentem Modell
sehr schnell: rund 53 ms synchronisierte Modulrechnung und 113 ms bis zur
validierten Maske im ursprünglichen Bildformat. Die Auswahl ist beim Schneemann
und im Inneren der Pyramide gut, verschlechtert aber andere Fälle. Ein
durchgehender Qualitätsvorsprung oder Ersatz für weiche Matting-Kanten ist
nicht belegt. Die Modellauswahl der App bleibt unverändert.

## Modell, Laufzeit und Schnittstellen

Die Gewichte stammen aus dem [offiziellen Hugging-Face-Repository](https://huggingface.co/mit-han-lab/efficientvit-sam/tree/a2f0c5929196a13ef1ffc9338d3f9e482e1e0e68),
Revision `a2f0c5929196a13ef1ffc9338d3f9e482e1e0e68`:
`efficientvit_sam_l1.pt`, **190.916.834 Bytes**, SHA-256
`fa151df2b9b96896accd505470755cdd293a4c50cdabac95478f3fbd86d9152b`.
Der Loader prüft Länge und Hash und lädt ausschließlich Tensoren mit
`weights_only=True` und `load_state_dict(strict=True)`.

Die isolierte Umgebung verwendet **PyTorch 2.14.1, torchvision 0.29.1 und
huggingface_hub 2.2.0** auf Python 3.11/macOS ARM64. Die Hugging-Face-Bibliothek
übernimmt Download und Cache; lokale Inferenz erfolgt mit MITs unverändertem
`EfficientViTSamPredictor`. Das ist kein Transformers- oder Ultralytics-
Inferenzlauf. Die Unterscheidung ist für diesen Auftrag wesentlich:

| Schnittstelle | Geprüfter Vertrag |
| --- | --- |
| Hugging Face Hub 2.2.0 | `hf_hub_download` liefert den lokalen Checkpointpfad, keine Masken |
| Transformers 5.20.2 | Kein EfficientViT-SAM-Eintrag in AutoConfig/AutoModelForMaskGeneration; diese Architektur wird nicht automatisch aus dem offiziellen Checkpoint aufgebaut |
| Ultralytics 8.4.183 | Kein EfficientViT-SAM-Builder in der SAM-Registry; `.gguf` ist zudem kein akzeptierter Dateityp des SAM-Loaders |
| Offizieller MIT-Predictor | `set_image(RGB_uint8)` und `predict(point_coords, point_labels, box, ...)` mit Originalvorschau-Pixelkoordinaten |

Belege aus den veröffentlichten Versionen:
[Ultralytics-Dateitypen](https://github.com/ultralytics/ultralytics/blob/v8.4.183/ultralytics/models/sam/model.py#L60),
[Ultralytics-Modellregistry](https://github.com/ultralytics/ultralytics/blob/v8.4.183/ultralytics/models/sam/build.py#L319),
[Transformers-Maskenmodellregistry](https://github.com/huggingface/transformers/blob/v5.20.2/src/transformers/models/auto/modeling_auto.py#L1989).
Diese beiden Inferenzbibliotheken wurden anhand ihrer Releasequellen geprüft;
es wird kein erfolgreicher Modelllauf mit ihnen behauptet. Die allgemeine
GGUF-Unterstützung anderer Architekturen ist kein Nachweis für EfficientViT-SAM.

Die [HF-Modellkarte](https://huggingface.co/mit-han-lab/efficientvit-sam)
zeigt den älteren Factory-Namen `create_sam_model`. Zum verwendeten
SAM-Quellstand passt `create_sam_model('l1', pretrained=False)`; der neuere
Repositorykopf verwendet dagegen `create_efficientvit_sam_model` mit Namen
wie `efficientvit-sam-l1`. Der Test hält Quellstand und Aufruf zusammen und
übernimmt keine Defaultgewichte aus dem Beispiel. Der bereits getestete EfficientSAM3 EV-M ist ein anderes
Modell mit Textencoder; EfficientViT-SAM-L1 nimmt Punkte und Boxen entgegen.

## Kompatibilität des offiziellen Quellstands

Der aktuelle EfficientViT-Repositorykopf
`de7d7733cc0329f391b33f1f459271562ec27bd5` scheitert auf diesem Mac bereits beim
Import: Ein später hinzugefügter DC-AE/RMSNorm-Pfad importiert unbedingt Triton.
Das ist ein Importhindernis vor der Modellinferenz und kein gemessener
MPS-Vorhersagefehler.

Verwendet wird deshalb der unveränderte offizielle
[SAM-Quellstand vor DC-AE](https://github.com/mit-han-lab/efficientvit/tree/e81ebbe761b2c75fc99b7827cb7dbd30a76c0ace),
Revision `e81ebbe761b2c75fc99b7827cb7dbd30a76c0ace` vom 15.10.2024, zusammen mit
dem gepinnten offiziellen SAM-Paket. Der Harness prüft die Quellarchive und
sämtliche Python-Dateien der importierten Upstream-Pakete gegen diese Archive.
Die aktuellen PyTorch-/Hub-Bibliotheken bleiben erhalten. Quellen, Hashes,
Installationsbefehle und Aufrufe stehen in den
[Reproduktionshinweisen](../../../tools/mask-evaluation/efficientvit_sam_README.md).

## Bild- und Promptvertrag

Die sieben lokalen JPEGs aus dem [ersten Vergleich](README.md) werden mit den
exakt gleichen orientierten sRGB-Proxys verwendet. Originale und Proxybytes
sind per privaten Hashes geprüft. Die finalen manuellen Rahmen und positiven
Punkte bleiben gleich, einschließlich des Fuchsrahmens mit rechtem Rand 0,86.
Alle Fotos und abgeleiteten Ergebnisse bleiben lokal und außerhalb von Git.

Die offizielle Geometrie unterscheidet sich vom bisherigen Core-ML-SAM2-Pfad:

1. **Encoder:** längste Seite auf 512 verkleinern, Seitenverhältnis erhalten,
   ImageNet-Normalisierung und Padding rechts/unten auf 512².
2. **Prompts:** normierte Testangaben zuerst in Pixel der Originalvorschau
   umrechnen. Der Predictor transformiert sie selbst in seinen separat
   gerundeten 1024er Koordinatenrahmen. Eine zusätzliche manuelle Skalierung
   auf Encoderpixel wäre falsch.
3. **Ausgabe:** native 256²-Logits auf 1024² interpolieren, Padding entsprechend
   dem Promptframe abschneiden, danach auf das ursprüngliche Seitenverhältnis
   skalieren. Direktes Strecken der Rohlogits wäre geometrisch falsch.
4. **Auswahl:** drei Kandidaten, höchster modellinterner Score, Schwelle null.
   Zwei identische Promptdurchläufe verwenden dieselben Bildmerkmale, ohne
   `mask_input`-Verfeinerung. Die Ausgabe ist binäre Segmentierung, keine
   qualifizierte Alpha-Deckung für Matting.

Der vorherige SAM2-Core-ML-Vergleich skaliert das ganze Foto dagegen auf ein
1024²-Quadrat. Es werden gleiche Ziele und Annotationen verglichen, jedoch
unterschiedliche offizielle Bildpipelines. Modellinterne Scores sind keine
zwischen Modellen vergleichbaren Genauigkeitswerte. Referenzmatten fehlen;
die Sichtprüfung liefert keine objektive Genauigkeitsquote.

## Ausgeführte Messungen

Die Hauptserie auf MPS verwendet Float32 ohne Autocast und
`PYTORCH_ENABLE_MPS_FALLBACK=0`. Alle sieben Bilder wurden erfolgreich
verarbeitet. Die Modellparameter wurden strikt geladen; die tatsächlich
geladene Variante enthält 47.650.128 Parameter. CPU-Parallelität ist auf vier
Intraop- und einen Interop-Thread begrenzt. Die schweren Messprozesse liefen
nacheinander, während Vorbereitung und unabhängige Reviews parallel erfolgten.

„Warm“ bezeichnet den Median der Bilder 2–7, jeweils mit neuem Encoderlauf bei
residenten Gewichten. Hauptserie und erste Anfrage enthalten keinen zusätzlichen
Encoder-Wiederholungslauf. Die separat markierte Encoderprobe verändert die
Zeitreihe nicht.

| Abschnitt | Erster Aufruf | Warm, Median | Warmer Bereich |
| --- | ---: | ---: | ---: |
| Bildencoder, synchronisierte Modulzeit | 1,715 s | **0,042 s** | 0,042–0,053 s |
| Encoder + Promptencoder + Maskendecoder | 3,716 s | **0,053 s** | 0,052–0,064 s |
| `set_image`, einschließlich Vorbereitung und Transfer | 1,728 s | 0,053 s | 0,051–0,064 s |
| Offizielles `predict`, einschließlich Postprocess und CPU-Ausgabekopie | 2,112 s | 0,014 s | 0,013–0,016 s |
| Bildanfrage bis zur validierten Maske | **3,889 s** | **0,113 s** | 0,105–0,131 s |
| Export von Maske und nativen Logitdateien zusätzlich | 0,006 s | 0,006 s | 0,003–0,013 s |

Modulzeiten stammen aus Forward-Hooks mit MPS-Synchronisierung vor und nach
jedem Modul. Sie sind Modul-Wandzeiten und keine reinen Metal-Ereigniszeiten.
Arbeit zwischen den Modulen bleibt außerhalb ihrer Summe.
`predict` enthält bereits die offizielle Paddingentfernung, Rückskalierung
und NumPy-Kopie aller Kandidaten; die vollständige Anfrage zusätzlich
PNG-Decodierung, Vorbereitung, Auswahl und Validierung. Die einzelnen
Medianwerte dürfen nicht zu einem vermeintlichen Gesamtmedian addiert werden.

Zusätzlich benötigte der Prozess 1,607 s für Import und Quellverifikation,
0,197 s für Modellaufbau und striktes CPU-Gewichtsladen sowie 0,155 s für
Gerätetransfer. Diese Abschnitte sind nicht Teil der Bildanfrage. System- und
Gerätecaches wurden nicht geleert; Erstgebrauch ist kein kontrollierter Kaltstart.

Peak Prozess-RSS: **930.414.592 Bytes (0,867 GiB)**. Der höchste abgetastete
MPS-Treiberwert betrug **1.363.132.416 Bytes (1,270 GiB)**. Das sind verschiedene,
teilweise überlappende Sichten, keine addierbaren unabhängigen Speicherbudgets.
Treiberwerte sind Stichproben, keine garantierten Peaks. Der Prozess enthält
auch Python und PyTorch; er misst nicht den späteren Speicher einer Swift-App.

Alle zwei Promptwiederholungen pro Foto lieferten exakt gleiche native Logits
und binäre Masken. Eine separate MPS-Probe am Fuchs wiederholte auch den
Encoder: maximale Feature-Differenz null. Eine anschließende CPU-Probe an
demselben Bild ergab Logit-MAE **0,0002222**, P99 absolut **0,0009206**, Maximum
**0,0016074**. Die binären Masken unterscheiden sich in **2 von 2.666.000 Pixeln**
(IoU 0,9999947). Das ist eine Geräteübereinstimmungsprobe an einem Foto, keine
Genauigkeit gegenüber Ground Truth und keine Qualifizierung aller CPU-Fälle.

Die vollständige Serie, die getrennten Kontrollen und der fehlgeschlagene
Importversuch stehen bereinigt in
[`efficientvit-sam-l1-measurements.json`](efficientvit-sam-l1-measurements.json).

## Sichtprüfung mit den bisherigen Masken

Gemeinsame Ansichten zeigen Original, EfficientViT-L1, SAM2 Tiny, SAM2 Large,
BiRefNet HR und BEN2, jeweils mit Vordergrundmaske und einer −2-EV-
Hintergrundabdunklung in linearem sRGB. Die vier älteren Modellpfade wurden
nicht erneut gerechnet; ihre finalen Masken stammen aus den vorherigen Tests.

| Foto | EfficientViT-SAM-L1 | Gegenüber bisherigen Ergebnissen |
| --- | --- | --- |
| Eimer | Vor allem weißer Eimer und Fußmatte; dunkle Eimer fehlen weitgehend | Schlechtere Gruppenauswahl als SAM2; BEN2 plausibler |
| Häuser | Plausible zusammenhängende Häuserregion | Etwa Tiny-Niveau, weniger Innenunterbrechungen als Large |
| Schneemann | Gute Gesamtform und weitgehend vollständige Karottenarme | Weniger Armlücken als Tiny, keine zusätzlichen Bodenflecken wie Large |
| Pyramide | Deutlich weniger falsche Innenlöcher; Dachkanten löchrig, Verpackungsabgrenzung unsauber | Innenbereich besser als beide SAM2-Varianten; BEN2 bleibt insgesamt überzeugender |
| Insel | Ziel erkannt, zusätzlich schmaler Wasser-/Reflexionsstreifen ausgewählt | SAM2 trennt hier sauberer |
| Plüschfuchs | Kopf brauchbar, Arme und untere Teilflächen zwischen Blumen fragmentiert | Ähnlich zu SAM2; harte Konturen statt weicher Fellübergänge |
| Tulpenvase | Vase zusammenhängend, zusätzliche Kerzen deutlich mitgewählt | Large isoliert das gewünschte Objekt klarer |

Das sind Sichtbefunde an sieben Fotos, keine allgemeine Rangliste der
Modellfamilien. Automatische Vordergrundwahl von BiRefNet/BEN2 und manuell
adressierte Objektauswahl bleiben unterschiedliche Aufgaben.

## Vergleich der gemessenen Pfade und Entscheidung

| Modellpfad | Warme Modell-/Pipelinezeit | Abschnitt |
| --- | ---: | --- |
| EfficientViT-SAM-L1, Python/MPS Float32, 512² | **0,053 s** | Synchronisierte Encoder-/Prompt-/Decodermodule |
| SAM 2.1 Tiny, natives Core ML Float16, 1024² | 0,094 s | Encoder + Promptencoder + Decoder |
| SAM 2.1 Large, natives Core ML Float16, 1024² | 0,413 s | Encoder + Promptencoder + Decoder |
| BiRefNet HR Matting, Core ML, 1920² | 2,559 s | Nur native Vorhersage |
| BEN2 Base, ONNX CPU, 1024² | 4,721 s | Nur native Vorhersage |
| BiRefNet standard GGUF, CPU, 1024² | 23,412 s | Vorbereitung, Graph, Inferenz und Rückskalierung |
| EfficientSAM3 EV-M, CPU, 1008² | 1,796 s | Bildencoder und Text-/Maskenpipeline |

L1 ist in diesem getesteten Pfad ein sehr schneller Kandidat. Daraus folgt
kein isolierter Architekturgewinn: Auflösung, Präzision, Laufzeit, Geometrie
und Messabschnitte unterscheiden sich. Auch die 113-ms-Anfrage ist nicht
deckungsgleich mit SAM2s 235/562 ms: Dessen Harness kopiert und validiert
native 256²-Logits über NSNumber-Zugriffe und stellt das Seitenverhältnis erst
beim separaten Export wieder her; L1 nutzt die offizielle vollständige
Ausgabepipeline. Die Zahlen qualifizieren keine fertige PicEdit-Integration.

**L1 als schnellen Prototyp weiter berücksichtigen, aber keinen pauschalen
Modellwechsel vornehmen.** Es löst das Pyramidenproblem teilweise besser,
wählt dafür dunkle Eimer, Reflexionen und Kerzen weniger passend aus. Tiny
bleibt der bereits native Core-ML-Kandidat; Large bietet in einzelnen Fällen
die gezieltere Auswahl. Eine native L1-Konvertierung oder Quantisierung wurde
nicht gemessen. Für weiche Haare/Fell/Mischpixel bleibt gesondertes Matting
erforderlich; Textverständnis und automatische Positionsbestimmung sind nicht
Teil dieses Tests.

## Verifikation und lokale Ergebnisse

Die Hauptserie, getrennte Encoderprobe und CPU-Kontrolle wurden tatsächlich
ausgeführt. Checkpoint und alle 74 Python-Dateien der importierten offiziellen
Pakete wurden gegen gepinnte Quellen geprüft. Python-Syntax, Geometrien,
bereinigte JSON-Daten, Dokumentationslinks und unveränderte Original-/Proxybytes
wurden geprüft. Unabhängige Reviews von Code, Messwerten und allen sieben
Vergleichsansichten ergaben keine offenen Befunde.

Private Bilder, Logits und Rohberichte liegen lokal unter
`Fixtures/LocalTestImages/Evaluation-EfficientViT-SAM-L1-20261020/`, vollständig
von Git ausgeschlossen. Quellenarchive, Gewichte und Umgebungen bleiben
außerhalb der App und werden nicht veröffentlicht.

Geändert wurden nur isolierte Entwicklerwerkzeuge und Dokumentation. App-Quellen,
Buildkonfiguration, App-Abhängigkeiten und eingebundene Ressourcen bleiben
unverändert; deshalb ist kein vollständiger App-Build erforderlich.
