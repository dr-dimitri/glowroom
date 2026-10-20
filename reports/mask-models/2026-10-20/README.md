# Lokaler Vergleich der Maskierungsmodelle

Stand: 20.10.2026. Sieben vorhandene private Testfotos wurden mit fünf
Modellvarianten tatsächlich verarbeitet. **SAM 2.1 Tiny ist der aussichtsreichste
Kandidat für schnelle, gezielte Objektauswahl. Ein vollständiger Ersatz für
BiRefNet HR Matting ist durch diese Probe nicht belegt.** BEN2 ist bei einigen
automatischen Auswahlen besser, benötigt im getesteten CPU-Pfad aber deutlich
mehr Speicher. Die App verwendet weiterhin ihre bisherigen Modelle.

## Messaufbau

- Apple M2 Pro, 12 logische CPU-Kerne, 16 GiB gemeinsamer Speicher,
  macOS 27.0.1 (26A434).
- `test_picture1.jpg` bis `test_picture7.jpg` aus `Fixtures/LocalTestImages/`:
  Eimer, Häuser, Schneemann, Spielzeugpyramide, Insel, Plüschfuchs und Blumenvase.
  Das ist eine kleine Funktionsprobe, kein repräsentativer Genauigkeitsbenchmark.
- EXIF-Ausrichtung angewendet, eingebettete ICC-Profile nach sRGB konvertiert,
  andernfalls sRGB angenommen. Metadatenfreie PNG-Vorschauen mit maximal 2048
  Pixeln längster Seite; nur Foto 7 musste dafür von 6000 × 4000 verkleinert
  werden. Anschließend erfolgte die jeweilige modellinterne Skalierung.
- Alle sieben Originaldateien blieben nach SHA-256-Prüfung unverändert.
  Fotos, abgeleitete Bilder und private Hash-Manifeste bleiben im ignorierten
  lokalen Verzeichnis und werden nicht veröffentlicht.
- Vorbereitungen, Downloads und unabhängige Reviews wurden parallel erledigt.
  Speicherintensive Modellläufe liefen nacheinander, um Konkurrenz um CPU, GPU
  und gemeinsamen RAM zu vermeiden. CPU-Kernels nutzen begrenzte Parallelität.
- Gewichte bleiben innerhalb einer Serie geladen. Systemcaches wurden nicht
  geleert. „Erster Aufruf“ bezeichnet den ersten Forward dieses Prozesses nach
  dem Laden und ist keine Zusage eines vollständig kalten Systemstarts.
- Keine Referenzmatten vorhanden: weder IoU noch Matting-Genauigkeit ableitbar.
  Flächendeckung und leere Masken sind Diagnostik, keine Qualitätsquote.

Die vollständigen, bereinigten Einzelmesswerte stehen in
[`measurements.json`](measurements.json), die Werkzeuge und Aufrufhinweise unter
[`tools/mask-evaluation/`](../../../tools/mask-evaluation/README.md).

## Laufzeit und Speicher

Sekunden, ohne Modellladen und Dateiausgabe. „Weitere Bilder“ ist der Median der
Bilder 2–7 mit residentem Modell; dabei wird keine fertige Maske wiederverwendet.
Die Messabschnitte sind ausdrücklich unterschiedlich und erlauben keinen
isolierten Vergleich der Modellarchitektur oder des Dateiformats.

| Variante und Backend | Eingabe | Laden | Erster Aufruf | Weitere Bilder | Gemessener Abschnitt | Peak Prozess-RSS |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| BiRefNet HR Matting, natives Core ML CPU/GPU | 1920² | 5,465 | 7,303 | 2,559 | `prediction` | 1,13 GiB |
| BEN2 Base, ONNX Runtime CPU, 6 Threads | 1024² | 0,803 | 4,810 | 4,721 | `session.run` | 6,40 GiB |
| SAM 2.1 Tiny, natives Core ML CPU/GPU | 1024² | 0,358 | 5,053 | 0,090 | Bildencoder + Promptencoder + Decoder | 0,29 GiB |
| BiRefNet standard F16 GGUF, vision.cpp CPU, 4 Threads | 1024² | 0,216 | 23,357 | 23,412 | Vorbereitung + Graph + Inferenz + Rückskalierung | 3,51 GiB |
| EfficientSAM3 EV-M, PyTorch CPU, 4 Threads | 1008² | 0,676 | 1,835 | 1,796 | Bildencoder + Text-/Maskenpipeline | 3,05 GiB |

RSS enthält Harness, Runtime und gegebenenfalls Python, jedoch nicht zwingend
alle GPU-/Treiberallokationen. Es ist kein Gesamtbedarf der späteren App. Die
CPU-Threadzahlen sind begrenzt, aber nicht auf identischen Durchsatz optimiert.
BEN2 liegt bereits als einzelner Prozess über PicEdits bisheriger
6-GiB-Zulassungsschätzung für die Motivberechnung; diese Schätzung ist kein
beobachtetes hartes Speicherlimit.

SAM 2 benötigt bei weiteren Bildern rund **232 ms bis zur validierten Kopie
der nativen Logits**, einschließlich PNG-Decodierung, Vorbereitung und
Ausgabekopie. Rückskalierung, Schwellenwert und PNG-Export benötigen zusätzlich
etwa 34–45 ms. Ein weiterer Prompt mit gecachten Bildmerkmalen benötigt nur rund
7 ms für Promptencoder und Decoder; diese Zahl gilt nicht für ein neues Foto.
Die Logits beider Decoderaufrufe waren bei allen sieben Bildern identisch.

Das BiRefNet-Harness hält ein Modell für die ganze Serie geladen. Die App prüft
ihre Installation und lädt Modellobjekte derzeit je nach Anfrage neu. Diese
Messung ersetzt daher nicht die früher dokumentierten App-Messungen von
11,62/5,89 Sekunden. RAW-Decodierung, App-Zulassung und vollständiger
Vorschau-Renderer sind hier nicht enthalten.

## Sichtprüfung der sieben Fotos

BiRefNet und BEN2 suchen automatisch Vordergrund. SAM 2 erhält einen manuell
gesetzten Rahmen und positiven Punkt; EfficientSAM3 erhält einen manuell
gewählten englischen Objektnamen. Insbesondere bei Landschaften sind das
unterschiedliche Aufgaben. Keine dieser Vorgaben stammt aus einem getesteten
Sprachmodell.

| Fall | BiRefNet HR | BEN2, ursprüngliche Normalisierung | SAM 2.1 Tiny | BiRefNet GGUF | EfficientSAM3 EV-M |
| --- | --- | --- | --- | --- | --- |
| Eimer | Praktisch leer | Eimergruppe weitgehend erfasst | Löcher; Fußmatte mitgewählt | Grobe Gruppe samt Fußmatte | Leer |
| Häuser | Praktisch leer | Große Landschaftsfläche | Hausgruppe gezielt erfasst | Leer | Häuserregion grob erfasst |
| Schneemann | Weitgehend vollständig | Weitgehend vollständig | Gut, kleine Armlücken | Weitgehend vollständig | Karottenarme fehlen |
| Pyramide | Überwiegend einzelne Figuren | Gesamtform weitgehend, unsichere Innenbereiche | Viele falsche Innenlöcher | Gesamtform vollständiger, Öffnungs-/Randfehler | Leer |
| Insel | Praktisch leer | Ufer und Bäume statt Einzelinsel | Insel plausibel, Vegetation vereinfacht | Leer | Leer |
| Plüschfuchs | Kopf/Körper, weiche Übergänge | Kopf, unklare weiche Blumen-/Körperbereiche | Armanteile erfasst, harte Kontur | Fuchs, ausgesparte Blumen, harte Kontur | Überwiegend Kopf |
| Blumenvase | Tisch, Stühle und Gegenstände | Tisch und Gegenstände | Vase grob, zusätzlich Kerzen, löchrige Stiele | Tisch und Gegenstände | Einzelvase, Blüten/Stiele stark vereinfacht |

Beim Fuchs war der erste SAM-Rahmen zu eng (`x1 = 0,70`). Eine separate
Qualitätsprobe mit `x1 = 0,86` enthält den ausgestreckten rechten Arm und wird
für die finale Sichtprüfung verwendet. Die ursprüngliche Serie bleibt als
Zeitmessung erhalten; die korrigierte Probe wurde nicht als schnellerer
Zeitwert eingesetzt. SAM-Schwellenmasken sind keine physikalischen
Transparenzmatten für Fell, Haare oder Mischpixel.

Alle Modelle wurden außerdem mit einer Hintergrundabdunklung von −2 EV in
linearem sRGB angesehen. Das ist ein gemeinsamer Diagnose-Compositor, kein
Test des vollständigen App-Renderers und keine Wiederherstellung bereits
ausgebrannter Bildinformation. Die lokalen Vergleichsbilder und Rohberichte
liegen in `Fixtures/LocalTestImages/Evaluation-20261020/`; sie sind von Git
ausgeschlossen.

## BEN2: Vorverarbeitung und Core-ML-Pfad

Das [veröffentlichte ONNX-Beispiel](https://huggingface.co/PramaLLC/BEN2/blob/e48a20765fb421d19dcdb0bf3cc61e802ca5ec8f/README.md)
verwendet bilineares RGB `[0,1]`, der ursprüngliche PyTorch-Pfad Lanczos und
ImageNet-Mittelwerte/Standardabweichungen. Die Normalisierung ist nicht im
ONNX-Graphen enthalten: Die erste Faltung hat dieselben, nach Float16
gerundeten Gewichte und Bias-Werte wie der Originalcheckpoint. Deshalb wurden
die vollständigen CPU-Serien für beide Varianten getrennt erhalten. Die
Qualitätstabelle und die primären BEN2-Zeiten verwenden die ursprüngliche
Normalisierung. Min-Max-Skalierung der Ausgabe wird wie im Beispiel beibehalten;
diese Werte sind nicht als kalibrierte Alpha-Deckung qualifiziert.

Zusätzlich wurde der ursprüngliche Float32-PyTorch-Checkpoint mit striktem
Safetensors-Laden für die Bilder 1 und 6 ausgeführt. Die nativen Rohwerte wurden
mit ONNX verglichen; die numerischen Unterschiede und ein kontrollierter
Vergleich bei identischen Eingaben stehen in `measurements.json`. Numerische
Nähe zum Original ist keine Genauigkeit gegenüber einer echten Referenzmatte.

| Kontrollierter Eingang | Rohalpha-MAE | P99 absolut | Maximum absolut |
| --- | ---: | ---: | ---: |
| Bild 1, gespeicherter Referenztensor direkt an ONNX | 0,001354 | 0,033742 | 0,344386 |
| Bild 6, bitgleiche Vorbereitung beider Umgebungen | 0,001862 | 0,039952 | 0,221579 |

Die normale Bild-1-Serie hatte zunächst unterschiedliche Resize-Ergebnisse:
Pillow 11.2.1 im Referenzumfeld gegenüber 13.0.0 im ONNX-Umfeld. Der Unterschied
ließ sich ohne erneute Inferenz auf Lanczos-RGB-Bytes eingrenzen (maximal
10/255, 17,75 % unterschiedliche Farbkanäle). Deshalb erfolgte für Bild 1 ein
zusätzlicher ONNX-Forward direkt auf dem gespeicherten Referenztensor.
Bild 6 war bereits bitgleich vorbereitet. Die Modelle sind numerisch nahe,
einzelne Pixel weichen jedoch deutlich ab. Der ursprüngliche private
Referenzreport vergleicht Gray8 noch mit der alten unnormalisierten Serie;
für diese Bewertung gelten die oben aufgeführten kontrollierten Rohvergleiche.

Der separate ONNX-CoreML-EP-Versuch mit der veröffentlichten Beispielvorbereitung
war unbrauchbar langsam: **85,4 s Laden**, danach **13,6–48,1 s pro Forward**
für vier Bilder. ORT meldete 88 Teilgraphen und 2691 von 2977 unterstützten
optimierten Knoten; CPU-Fallback war erlaubt. Der Lauf wurde nach vier Bildern
mit SIGINT beendet, nachdem die laufende native Berechnung zurückgekehrt war
(Exit 130). Er ist als abgebrochen dokumentiert. Es wurde kein normalisierter
Core-ML-Lauf und keine native BEN2-Core-ML-Konvertierung qualifiziert. Daraus
folgt eine Aussage über diesen ORT-Pfad, nicht über jede mögliche Apple-
Beschleunigung des Modells.

## Modellidentitäten und Grenzen

- **BiRefNet HR Matting:** das freigegebene 1920-Core-ML-Paket wurde vor dem
  Test gegen `SubjectMattingApprovedPackage.json` geprüft. Herkunft und Pins
  stehen in der [Motivmodell-Dokumentation](../../../docs/AUTOMATIC-MASKS.md).
- **BEN2:** öffentlicher Base-Checkpoint, Revision
  `e48a20765fb421d19dcdb0bf3cc61e802ca5ec8f`, ONNX Runtime 1.31.0.
  Getestet wurde nicht eine zusätzliche kommerzielle CGM-Pipeline.
- **SAM 2.1 Tiny:** [Apples Core-ML-Konvertierung](https://huggingface.co/apple/coreml-sam2.1-tiny/tree/39ae0a8a83e5e6cd196e804bf7cccc5f8171f306),
  Revision `39ae0a8a83e5e6cd196e804bf7cccc5f8171f306`, Float16. Alle neun
  Paketdateien wurden gegen gepinnte Längen und Hashes geprüft.
- **BiRefNet GGUF:** Standard-F16-Checkpoint bei 1024, nicht HR Matting 1920.
  [vision.cpp](https://github.com/Acly/vision.cpp/tree/26a752912d49f6c4ff4545b35a1bdf7400d349ed)
  wurde mit CPU/Accelerate und ausgeschaltetem Metal gebaut. Die Gewichte
  werden resident nach Float32 umgewandelt. Die besseren Grobauswahlen in zwei
  Fotos belegen keinen Qualitätsgewinn durch das GGUF-Dateiformat. Die
  wiederholte erste Ausgabe war nicht bitgleich: mittlere Gray8-Differenz
  0,01285/255, Maximum 48/255, 0,265 % geänderte Pixel.
- **„SAM 3-Lightweight“:** konkret getestet wurde
  [EfficientSAM3 EV-M Stage 3](https://github.com/SimonZeng7108/efficientsam3/tree/bd0936c788fed8d51fa799437f05abd97b401b06),
  nicht SAM3-LiteText. Der Checkpoint wurde vollständig geladen, ohne fehlende
  oder unerwartete Tensoren. Das geladene Modell enthält 97.435.030 Parameter;
  die veröffentlichte Zahl 89,2 Mio. wird daher nicht als gemessene Größe
  übernommen. CPU-Test mit Python 3.11/PyTorch 2.5 statt der neueren empfohlenen
  Umgebung; der Gerätehelfer wurde prozesslokal auf CPU festgelegt. Kein
  MPS-/Core-ML-Pfad getestet. Fester Confidence-Schwellwert 0,5; alternative
  Prompts und Schwellenwerte wurden nicht optimiert. Bei diesen Vorgaben
  blieben drei Zielauswahlen leer. Die zweimalige leere Binärmaske des ersten
  Bildes war bitgleich; das belegt keine allgemeine Logit-Deterministik.

Exakte zusätzliche Quellen, Gewichtshashes, Abhängigkeiten und
Kompatibilitätsanpassungen stehen in den
[Reproduktionshinweisen](../../../tools/mask-evaluation/extra_README.md).

## Entscheidung für PicEdit

1. **SAM 2.1 Tiny für gezielte, interaktive Auswahl weiterverfolgen.** Die
   native Core-ML-Probe zeigt einen klaren Latenz- und Speicher-Vorteil für
   diesen Anwendungsfall. Ein Textplaner müsste erst passende Objektpositionen
   liefern; diese Kopplung wurde hier noch nicht getestet.
2. **BiRefNet HR für weiche Motivkanten vorerst behalten.** Seine automatische
   Motivwahl ist auf diesen Fotos sichtbar unzuverlässig. Ein leeres Ergebnis
   darf nicht als brauchbare Hintergrundmaske interpretiert werden. Die Probe
   rechtfertigt keinen generellen Qualitätsvorsprung gegenüber BEN2.
3. **BEN2 als Qualitätskandidat, nicht als sofortigen Ersatz behandeln.** Es
   findet Eimer und Pyramide besser, ist hier aber langsamer und speicherhungrig.
   Eine native beschleunigte Konvertierung müsste separat geprüft werden.
4. **GGUF/vision.cpp und EfficientSAM3 in den getesteten Pfaden nicht wählen.**
   GGUF bringt hier keinen Performancevorteil; EV-M hat bei den festen
   Textvorgaben zu viele Ausfälle. Das schließt andere Backends oder feinere
   Promptstrategien nicht aus.

Der Wunsch „Korrigiere den überstrahlten Hintergrund und gib dem restlichen
Bild natürliche Sättigung“ braucht weiterhin Textverständnis, eine verlässliche
Bereichsauswahl und vorhandene nichtdestruktive Bildoperationen. Dieser Test
qualifiziert die Maskierungsbausteine; er testet weder deutsche Anweisungen
noch ein kombiniertes Sprachmodell-/Maskenmodell oder Highlight-Rekonstruktion.

## Verifikation und Änderungsumfang

Die Swift-/C++-Harnesses wurden kompiliert und die beschriebenen Modellläufe
ausgeführt. Python-Syntax, JSON-Berichte, Geometrie und unveränderte Originale
wurden geprüft. Die finale Sichtprüfung und ein unabhängiges Review umfassen
Werkzeuge, Vorverarbeitung und Messgrenzen. Keine App-Quellen, Buildkonfiguration,
App-Abhängigkeiten oder eingebundenen Ressourcen wurden geändert; deshalb ist
gemäß Projektvorgaben kein sauberer App-Build erforderlich. Die Werkzeuge sind
isolierte Entwicklerprogramme. Reviewbefunde zu Abbruchstatus,
Vergleichsprovenienz und Manifest-Hashpins wurden behoben und ohne weitere
Modellinferenz gezielt erneut geprüft. Das abschließende unabhängige Review
ergab keine verbleibenden blockierenden Befunde.
