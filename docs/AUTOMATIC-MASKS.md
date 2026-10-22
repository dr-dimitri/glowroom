# Automatische Motiv- und Himmelsmasken

## Bedienung und Datenschutz

**Motiv** und **Hintergrund** verwenden ausschließlich das lokal ausgeführte **BiRefNet HR Matting**. Das fest freigegebene Modell berechnet eine abgestufte Vordergrunddeckung für feine Strukturen und Übergänge; eine fehlerfreie Auswahl wird nicht zugesichert. Fehlendes, veraltetes oder beschädigtes BiRefNet führt zu einem verständlichen Hinweis. Es gibt keinen Ersatzweg über Apple Vision. Pinsel und Verläufe bleiben verfügbar.

**BiRefNet einrichten …** ist in der Maskenauswahl und im Menü **…** der Maskenliste erreichbar. Bei einer frischen Installation wird einmalig das für Glowroom vorbereitete 1920-`.mlpackage` gewählt. Andere Pakete werden anhand exakter Dateigrößen und Hashes zurückgewiesen. Ein eingerichtetes, geprüftes BiRefNet zeigt nur seinen Bereitschaftsstatus; die Oberfläche bietet weder Modellaustausch noch Entfernen an. Bei einem früheren 2048-Modell ist ausschließlich die Aktualisierung auf das freigegebene BiRefNet möglich. Eine beschädigte Installation kann mit demselben freigegebenen Paket repariert werden. Die bisherige Installation bleibt bei einem fehlgeschlagenen oder abgebrochenen Import erhalten; erst ein erfolgreich geprüftes Paket ersetzt sie atomar. Der Import benötigt vorübergehend mindestens 3 GiB freien Speicher und verändert keine gespeicherten Masken. Die App enthält weder Modellgewichte noch einen Python-Interpreter und führt keinen automatischen Modelldownload aus. Das [Entwicklerwerkzeug](../tools/subject-matting/README.md) bereitet den festgelegten öffentlichen Checkpoint lokal für Core ML vor. Die Himmelsmaskierung behält ihre separate Einrichtung.

Während **Motiv**, **Hintergrund** oder **Himmel** berechnet werden, erscheint eine kleine Statusanzeige an der Bildfläche: **Maske wird berechnet …** mit Aktivitätsanzeige und **Abbrechen**. Sie verschiebt oder verdunkelt das Foto nicht und verschwindet nach Abschluss, Fehler, Abbruch oder Bildwechsel. Bei reduzierter Bewegung erscheint ein ruhiges Symbol anstelle des laufenden Spinners. Abbrechen verwirft den Auswahlauftrag sofort; eine bereits laufende native Berechnung kann technisch bis zu ihrer Rückkehr nachlaufen. Ihre veralteten Ergebnisse werden nicht übernommen.

**Himmel** verwendet nach einer einmaligen Einrichtung ein lokales Segmentierungsmodell auf der bereits geladenen, orientierten Bildvorschau. Über **Himmelsmodell einrichten …** und **Modell laden und einrichten** wird das Modell ausdrücklich heruntergeladen. Der Download umfasst 85.468.610 Bytes, angezeigt als etwa 86 MB. Die Einrichtung benötigt vorübergehend mindestens 768 MB freien Speicher. Das Modell kann im selben Dialog entfernt werden.

Fotos werden für diese Funktionen nicht hochgeladen. Nach der Einrichtung funktioniert die Himmelserkennung offline. Fehlende oder veränderte Modelldaten lösen einen Fehler aus; die Einrichtung kann erneut gestartet werden. Es gibt keinen stillen Modelldownload und keine Ersatzmaske, die nur anhand einer blauen Farbe einen vermeintlichen Himmel auswählt.

Das Ergebnis wird als unveränderliche Gray8-Auswahl mit höchstens 2048 Pixeln an der längsten Seite in den Bearbeitungseinstellungen gespeichert. Dadurch bleiben bestehende lokale Bearbeitungen nach einem Modellupdate, einem Neustart oder dem Entfernen des Modells reproduzierbar. Die Auswahl kann invertiert, in ihrer Deckkraft und Weichheit verändert sowie mit Pinsel und Radierer nachgebessert werden. Originalbilder bleiben unverändert.

Neue Masken für **Motiv**, **Hintergrund** und **Himmel** beginnen mit **Weiche Kante = 0**. Ihre bereits abgestuften Auswahlkanten erhalten dadurch keine zusätzliche breite Weichzeichnung. Himmelsränder werden einmalig anhand der RGB-Bildkanten verfeinert. BiRefNet berechnet die Deckung selbst; dessen gelernte Übergänge erhalten weder einen zusätzlichen Guided Filter noch eine Erosion oder harte Schwelle. **Hintergrund** ist immer die umgekehrte Motivauswahl. Wer einen weicheren Übergang möchte, kann **Weiche Kante** weiterhin erhöhen. Pinsel, lineare und radiale Verläufe behalten ihre bisherigen Vorgaben und ihre Weichheit.

Bereits gespeicherte Masken werden weder neu erkannt noch umgeschrieben. Für die höhere Auswahlauflösung und Kantennachführung eine neue automatische Maske erstellen. Bei einer bestehenden Maske entfernt **Weiche Kante = 0** nur die zusätzliche Weichzeichnung; fehlende Details des alten gespeicherten Rasters entstehen dadurch nicht nachträglich.

## Modellquelle und Lizenz

Das fest vorgegebene Motivmodell ist [ZhengPeng7/BiRefNet_HR-matting](https://huggingface.co/ZhengPeng7/BiRefNet_HR-matting), Revision `5d6b6f8adcb5b417c871b1d84ceaae9871355b7f`, MIT-Lizenz. Die Originalgewichte haben SHA-256 `a5a4de698739ea5e0e8bbab28e1b293dde95092b87a442d566cbc585c53cef55`. Konvertierung, gepinnte Quellen, Prüfungen und Lizenztexte liegen unter [`tools/subject-matting/`](../tools/subject-matting/README.md). Gelernte deformierbare Abtastung bleibt bei der Konvertierung erhalten; sie wird nicht durch gewöhnliche Faltung angenähert.

Der Motivmodellvertrag `birefnet-hr-matting-v1` verwendet jetzt ein sRGB-RGB-Bild mit **1920 × 1920 Pixeln**. Das gesamte orientierte Bild wird auf dieses Quadrat skaliert. Byte-Skalierung sowie ImageNet-Mittelwerte und Standardabweichungen sind im Modell enthalten. Ausgabe ist `alpha`, Float32 `[1,1,1920,1920]` mit sigmoid-basierter Vordergrunddeckung. Glowroom stellt das ursprüngliche Seitenverhältnis wieder her und speichert das Ergebnis ohne Gammakurve als Gray8. Nicht endliche Vorhersagen werden verworfen. Die exakten freigegebenen Paketdateien und die Ein-/Ausgabeprüfung binden die 1920-Variante; Normalisierung und Deckungssemantik bleiben unverändert. Das gespeicherte Raster behält die vorhandene 2048-Pixel-Grenze und die bestehenden Bearbeitungsbudgets.

Verwendet wird das von Apple veröffentlichte [DETRResnet50SemanticSegmentationF16](https://huggingface.co/apple/coreml-detr-semantic-segmentation), Revision `bfcb6e4210d7289310082d7c93bf9a1417b3699f`. Das Modell basiert auf [facebook/detr-resnet-50-panoptic](https://huggingface.co/facebook/detr-resnet-50-panoptic). Modellkarte und eingebettete Modellmetadaten weisen die Apache-2.0-Lizenz aus. Der vollständige Lizenztext liegt unter `Sources/Glowroom/AI/Resources/SkyMaskLicenses/SkyMask-APACHE-2.0.txt`; Hinweise und Attribution stehen daneben in `SkyMask-NOTICE.txt`.

Die App besitzt eine feste Dateiliste mit exakter Länge und SHA-256. Sie akzeptiert weder eine vom Server gelieferte neue Revision noch eine frei angegebene Modelldatei:

| Datei im veröffentlichten `.mlpackage` | Bytes | SHA-256 |
| --- | ---: | --- |
| `Manifest.json` | 617 | `0749549c6b11139e11a40aaab82add4843a9977010337e596cce3dbb35c98512` |
| `Data/com.apple.CoreML/model.mlmodel` | 309817 | `61e05678150bcae26deac589b998dffe13c2977a9ba6f802938a9f3a60bfdcce` |
| `Data/com.apple.CoreML/weights/weight.bin` | 85158176 | `2f4de3dfed1aeced35ad7096d7c8721fcfb59571110a9e9138d73a7e56480408` |

Die Eingabe ist ein farbverwaltetes RGB-Bild mit 448 × 448 Pixeln, die Ausgabe `semanticPredictions` ein `Int32[448,448]`-Klassenraster. Die Himmelsklasse wird aus der im geprüften Modell eingebetteten Beschriftung **`sky (other)`** ermittelt. Es wird kein Klassenindex geraten. Das gesamte Bild wird auf die Modelleingabe skaliert und anschließend in sein ursprüngliches Seitenverhältnis zurückgeführt; ein mittiger Ausschnitt würde Himmel und Motivteile am Bildrand verlieren.

Das importierbare Motivpaket ist mit exakten Dateigrößen und SHA-256 in `Sources/Glowroom/AI/Resources/SubjectMattingApprovedPackage.json` festgelegt. Abweichende Graphen, Gewichte oder Paketmanifeste werden vor der Kompilierung abgewiesen. Modellmetadaten allein gelten nicht als Herkunftsnachweis. Der Produktionspfad prüft auch beim Wiederöffnen, dass die gespeicherte Quellinventur diesem Paket entspricht. Eine neue qualifizierte Konvertierung erfordert eine bewusste Aktualisierung dieses Manifests.

## Ausführung, Abbruch und Installation

Die native Erkennung läuft auf einem Hintergrund-Actor. Die vorhandene gemeinsame `AIResourceBudget`-Zulassung begrenzt lokale Modellerkennung und Modellkompilierung zusammen auf eine gleichzeitig laufende Arbeit. Core ML übernimmt die interne Datenparallelität. Es wird kein zweiter Foto-Workerpool gestartet. Motivaufträge reservieren vor dem Einreihen den BiRefNet-Modellpfad mit einer Zulassungsschätzung von 6 GiB. Die Himmelsauswahl verwendet weiterhin 384 MiB. Diese Schätzungen sind keine harten Obergrenzen für Framework- oder GPU-Speicher.

BiRefNet läuft auf CPU und GPU; die Neural Engine bleibt für diesen Graphen ausgeschlossen. Wenn beschleunigtes Laden oder Vorhersagen scheitern oder ungültige Zahlen liefern, versucht Glowroom denselben Graphen auf der CPU. Die vorherigen nativen Modellobjekte werden vor dem zweiten Versuch freigegeben. Ein defektes installiertes Paket führt zu einem verständlichen Fehler; Glowroom ersetzt es nicht still durch eine andere Auswahl. Der importierte Quellbaum wird vor der Kompilierung privat und geprüft kopiert. Eine neue Generation unter `~/Library/Application Support/Glowroom/Models/SubjectMatting/` wird erst nach erfolgreicher Kompilierung, Schnittstellenprüfung und Hashinventur durch einen atomaren `current.json`-Zeiger veröffentlicht. Abbruch oder Fehler davor erhalten die vorige Installation. Entfernen und Ersetzen warten auf die tatsächliche Rückkehr laufender Inferenz.

Motiverkennung verwendet die bereits orientierte Bildbasis des Editors und skaliert sie auf 1920 × 1920 Pixel für BiRefNet. Sie löst keine eigene RAW-Entwicklung aus. Native Kompilierung und Core-ML-Inferenz können einen Abbruch erst bei ihrer Rückkehr beachten; die gemeinsame Zulassung bleibt bis dahin belegt. Der Editor prüft vor der Übernahme weiterhin die Bildquelle und Bearbeitungssitzung. Reglerbewegungen verändern nur die Anwendung der gespeicherten Auswahl und führen keine neue Motiverkennung aus.

Himmel erhält eine RGB-geführte Kantennachführung auf Grundlage des Guided Filters von He, Sun und Tang. Sie verwendet das unveränderliche Eingabebild als Leitbild und speichert das verfeinerte Ergebnis. Die verfeinerte Deckung wird auf die ursprüngliche Deckung begrenzt. Die Core-Image-Pixeloperationen dürfen parallel auf dem geeigneten Backend laufen; die abhängigen Filterstufen bleiben geordnet. BiRefNet erhält keine solche Nachfilterung. Für den Hintergrund wird dieselbe Motivmaske invertiert, statt Vorder- und Hintergrund unabhängig zu erkennen. Die Himmelsinferenz bleibt bei 448 × 448 Pixeln; eine größere gespeicherte Maske erhöht nicht die semantische Auflösung des Modells.

Für das Himmelsmodell darf Core ML geeignete Beschleuniger auswählen. Scheitert das Laden oder die Vorhersage auf dem beschleunigten Pfad, wird derselbe geprüfte Graph auf der CPU ausgeführt. Zwischen beiden Versuchen werden temporäre Modellobjekte freigegeben. Alle automatischen Werkzeuge verwenden ausschließlich den übergebenen unveränderlichen Bild-Proxy. Separate neue Dateizugriffe für eingebettete Himmelsmatten unterbleiben, damit eine zwischenzeitlich ersetzte Originaldatei nicht mit einem älteren Cachebild vermischt wird.

Die Himmelsinstallation liegt getrennt vom Katalog unter `~/Library/Application Support/Glowroom/Models/Sky/`. Der Download schreibt begrenzt in temporäre Dateien. Erst nach Größen-/Hashprüfung aller drei Paketdateien und erfolgreicher lokaler Kompilierung werden private Kopien der kompilierten Dateien in einer neuen Generation abgelegt. Ein atomar ersetzter `current.json`-Zeiger ist der Commitpunkt. Fehler oder Abbruch davor erhalten eine bestehende Installation; unbekannte oder nicht verifizierbare Generationen werden nicht rekursiv entfernt. Symlinks und fremde Hardlinks in verwendeten Installationsbäumen werden zurückgewiesen.

Vor jedem Modellladen werden die kompilierten Dateien anhand des lokalen Installationsbelegs geprüft. Nach der Inferenz werden Dateistempel erneut geprüft. Das Modell wird nach einer abgeschlossenen Auswahl wieder freigegeben. Das Entfernen des Modells wartet auf die tatsächliche Rückkehr laufender lokaler Inferenz.

## Laufzeit und Wiederverwendung

Die historischen Messungen der früheren 2048-Variante auf dem vorhandenen M2 Pro (12 CPU-Kerne, 16 GiB) gelten für ein Foto, nicht für alle Geräte oder Motive. Der native 2048-Pixel-Pfad benötigte mit CPU/GPU 33,51–40,96 Sekunden reine Inferenz plus etwa 6,66 Sekunden Laden. Im tatsächlichen Glowroom-Pfad einschließlich Installationsprüfungen wurden 41,21 und 38,80 Sekunden pro neuer Berechnung gemessen. Beide gespeicherten Gray8-Masken waren bytegleich. Der CPU-Fallback benötigte in der separaten Probe 8,66 Sekunden plus 6,32 Sekunden Laden, wich aber stärker von der Float32-Referenz ab. Diese Werte beschreiben die frühere Version und bleiben als Vergleich dokumentiert.

Die frühere 1024-Pixel-Qualifikation brauchte mit CPU/GPU 3,21 Sekunden erste Inferenz plus 6,35 Sekunden Laden; sie erzeugte an den feinen Nadeln jedoch wieder breitere helle Übergänge und verlor Spitzen. Sie ist daher eine Entwicklerprobe und kein vom Import akzeptiertes Produktmodell. Ergebnisse und Messgrenzen dieser Qualifikation stehen in [`tools/subject-matting/qualification.json`](../tools/subject-matting/qualification.json).

Eine anschließende Auflösungsprobe mit demselben Foto und Checkpoint verwendet jeweils drei neue native Prozesse mit CPU/GPU. Betriebssystem-, Core-ML- und GPU-Caches werden dabei nicht geleert. Die Messung beginnt vor dem Modellladen und endet nach der ersten validierten Alpha-Kopie; PNG-Decodierung und Eingabeskalierung zählen mit, RAW-Entwicklung, Installationshashes und das abschließende Gray8-Raster nicht. Es handelt sich daher um eine native Entwicklungsprobe, nicht um vollständige Glowroom-Latenz.

| Modelleingabe | Median aus drei Prozessen | Erster Prozess der Messreihe |
| --- | ---: | ---: |
| 1024 × 1024 | 2,44 s | 3,45 s |
| 1536 × 1536 | 3,64 s | 9,41 s |
| 1792 × 1792 | 5,17 s | 10,53 s |
| 1920 × 1920 | 5,43 s | 11,84 s |

Ein aktueller 2048-Kontrolllauf mit derselben Messung benötigte 33,24 Sekunden einschließlich 0,72 Sekunden Laden und 31,89 Sekunden Inferenz; dies ist ein Einzelwert, kein Median. Die abschließende 1024-Kontrolle dauerte 3,27 Sekunden bei 2,09 Sekunden Inferenz und 0,93 Sekunden Laden. Damit bleibt der Einfluss des Ladens auch innerhalb der Sitzung sichtbar. Laufzeiten zwischen diesen Größen lassen sich nicht zuverlässig aus der Pixelzahl interpolieren.

Die App verwendet nun die daraufhin ausgewählte **1920-Variante** mit CPU/GPU und demselben CPU-Fallback. Die native Probe liegt bei erneutem Aufruf mit gefüllten Systemcaches ungefähr im Sechs-Sekunden-Bereich. Der erste Prozess mit diesem neuen Graphen liegt deutlich darüber; ein Sechs-Sekunden-Kaltstart wird nicht zugesichert. Das Modell wurde in jedem Messprozess neu geladen, es wurde keine vorhandene Maske wiederverwendet. Die 1024-Variante war bereits vor dieser Messreihe verwendet worden. Alle Einzelwerte, Kontrollmessungen und Grenzen der damaligen Größenwahl stehen unverändert in [`resolution-experiments.json`](../tools/subject-matting/resolution-experiments.json). Das dortige „experimentell“ beschreibt den Stand vor der anschließenden Freigabe. Der App-Import akzeptiert jetzt ausschließlich das exakt gepinnte 1920-Paket.

In den zwei geprüften 100-%-Ausschnitten sind Nadelspitzen und Innenlücken bei 1920 sehr ähnlich wie bei 2048 erhalten; ein klarer systematischer Detailverlust ist dort nicht erkennbar. 1024 zeigt weichere, breitere Ränder. Punktuelle Unterschiede und schmale helle Mischpixelränder unter −5 EV bleiben auch bei 1920 sichtbar. Diese Sichtprüfung an einem Foto ergibt keine objektive Genauigkeitsquote und ersetzt keine Prüfung mit dem vollständigen App-Renderer oder einem größeren Bildsatz.

Der separate Vergleich mit der jeweiligen ursprünglichen Float32-Rechnung zeigt bei 1792 geringere numerische Abweichungen als bei der ausgewählten 1920-Variante: mittlere absolute Alpha-Differenz 0,000934 gegenüber 0,001990, 99-%-Quantil 0,02450 gegenüber 0,05389 und Maximum 0,20853 gegenüber 0,50255. Beide bestehen die vorhandenen Prüfgrenzen, sind aber nicht numerisch gleichwertig. Die bewusste Auswahl von 1920 beseitigt diese punktuell größeren Abweichungen nicht. Daraus wird keine gemessene Genauigkeit gegenüber einer echten Referenzmaske abgeleitet.

Auch der 1920-CPU-Fallback wurde mit derselben gespeicherten Referenzeingabe geprüft: ein neuer Prozess benötigte 4,87 Sekunden Laden und 5,82 Sekunden Inferenz, insgesamt 11,22 Sekunden bis zur validierten Alpha-Kopie. Die mittlere absolute Abweichung zur Float32-Rechnung betrug 0,002239, das 99-%-Quantil 0,05804 und das Maximum 0,44827. Der vorhandene Zahlen-/Form-/Deckungsbereichstest besteht; CPU und GPU sind damit nicht pixelgleich. Diese Referenzprobe misst keine vollständige App-Latenz und leert keine Systemcaches.

Die abschließende Produktionsprobe mit dem Original-RAW und der tatsächlich eingerichteten 1920-Installation benötigte **11,62 Sekunden für die erste und 5,89 Sekunden für die zweite neue Maskenberechnung** einschließlich Installationsprüfung und abschließendem Raster. Der Ergebniscache war dafür deaktiviert; beide Gray8-Raster waren bytegleich bei 2048 × 1365 Pixeln. Ein bereits abgebrochener Auftrag wurde zurückgewiesen, und das Original blieb unverändert. Der Import lädt das Modell bereits zur Validierung; RAW-Entwicklung und PNG-Ausgaben sind in diesen beiden Zeiten nicht enthalten. Systemcaches wurden nicht geleert. Paketpins, CPU-/GPU-Prüfungen, UI-Lifecycle- und Layouttests sowie Messgrenzen stehen in [`deployment-1920.json`](../tools/subject-matting/deployment-1920.json).

Der Motiv-Worker behält genau ein Ergebnis für dasselbe unveränderliche Vorschaubild und dieselbe Modellidentität. Motiv und Hintergrund können so dieselbe Auswahl verwenden. Ein Treffer prüft die Installation erneut, benötigt aber keine weitere Modellerkennung. Ein anderes Bild, eine geänderte Installation oder ein fehlendes Modell verdrängt den Eintrag. Ohne gültige Installation wird auch kein gecachtes Ergebnis ausgegeben. Die Bildbasis samt gegebenenfalls vorhandener Artefakt-Speicherreservierung und höchstens 4 MiB Maskendaten bleiben erhalten; Modellgewichte werden nicht dauerhaft gehalten. Die gemeinsame Zulassung fasst gleichzeitige Zugriffe geordnet zusammen. Regler und Export verwenden weiterhin die bereits gespeicherte Maske.

## Grenzen und Verifikation

Die folgenden Modellvergleiche beschreiben historische Messungen. Ihre Berichte
wurden mit dem Ordner `reports` entfernt; Werkzeuge für neue lokale Messungen
stehen unter [Maskenmodellvergleich](../tools/mask-evaluation/README.md).

Ein separater lokaler Vergleich mit sieben Testfotos
untersucht BiRefNet HR, BEN2, BiRefNet GGUF, SAM 2.1 Tiny und EfficientSAM3 EV-M.
Er erfasste reale Laufzeiten, Speicherwerte, Sichtbefunde und die Unterschiede
zwischen automatischer Vordergrundwahl und gezielter Objektauswahl. Er ändert
die in der App verfügbaren Modelle nicht. Private Fotos und Vergleichsbilder
bleiben ausschließlich lokal unter dem von Git ausgeschlossenen
`Fixtures/LocalTestImages/Evaluation-20261020/`.

Der Folgetest von SAM 2.1 Hiera Large
enthält einen direkten nativen Core-ML-Vergleich mit Tiny bei identischen
Vorschau-Dateien und finalen manuellen Auswahlvorgaben. Auch dieser Test ändert
die Modellauswahl der App nicht.

Der EfficientViT-SAM-L1-Vergleich
prüft zusätzlich den offiziellen Predictor mit 512²-Encoder und separatem
1024er Promptframe auf MPS sowie eine CPU-Kontrolle. Hugging Face Hub übernimmt
den Download; ein direkter Ultralytics-/Transformers-Adapter wird nicht
vorausgesetzt. Auch diese isolierten Entwicklertests ändern die App nicht.

Der Florence-2-large-Test
untersucht auf denselben sieben Proxys zusätzlich die Auswahl durch englische
Zielbegriffe: direkte Polygonmasken und separat erkannte Rechtecke. Diese
Rechtecke sind noch keine Segmentierung. Frühere finale Masken werden als
Referenz wiederverwendet; die Modellreihen laufen nicht gemeinsam. Florence
ist damit weder als neues App-Modell freigegeben noch als Auswertung freier
deutscher Bearbeitungsanweisungen qualifiziert.

Die Himmelsauswahl ist ein Vorschlag eines allgemeinen COCO-Segmentierungsmodells. Feine Äste, Haare, transparente Flächen, Spiegelungen und ungewöhnliche Lichtverhältnisse können ungenaue Ränder oder falsche Auswahlteile erzeugen. Die Modelleingabe und das gespeicherte Raster sind bewusst begrenzt; es wird keine pixelgenaue Freistellung in voller RAW-Auflösung zugesichert. Bildgeführte Kantennachführung kann vollständig fehlende Zwischenräume nicht rekonstruieren, wenn die Ausgangsmaske dort und in ihrer Umgebung nur Vordergrund enthält. Pinsel und Radierer bleiben für solche Korrekturen verfügbar. Es werden keine Leistungs- oder Genauigkeitsgewinne gegenüber Lightroom behauptet.

Pro Bearbeitung sind insgesamt höchstens 16 MiB automatische Raster zulässig; ein einzelnes Raster bleibt auf 2048 × 2048 Pixel begrenzt. Das JSON-Budget der vollständigen Bearbeitungseinstellungen beträgt 32 MiB einschließlich der codierten Raster. Die bestehenden Grenzen von 16 Masken sowie 16.384 Pinsel-/Korrekturpunkten in 1024 Strichen bleiben erhalten. Wird eine Grenze überschritten, bleibt der vorherige gültige Bearbeitungsstand erhalten.

Die normalen Tests benötigen keine Modelldaten und keinen Netzwerkzugriff. `SubjectMattingModelStoreTests` prüft außerdem, dass fehlendes oder entferntes BiRefNet keine Ersatzmaske und kein veraltetes Cacheergebnis liefert. `AutomaticMaskTests` prüft Gray8-Konvertierung, Zeilenorientierung, Zeilenpadding, ungültige Gleitkommawerte, Seitenverhältnisse, semantische Klassenauswahl und die gemeinsame Zulassung bei abgebrochener nativer Arbeit. `AutomaticMaskModelStoreTests` prüft Hashfehler, Manipulation, Symlink-Umleitungen, sichere Löschung und den Rollback einer während nativer Kompilierung abgebrochenen Einrichtung.

`AutomaticMaskRefinerTests` prüft konstante Deckung ohne Gammaverschiebung, chromatische Kanten mit nahezu gleicher Helligkeit, schmale Innenlücken, begrenzte Maskenausdehnung, Software-/automatische Gerätewahl und Abbruch. Eine ausdrücklich gestartete Fotoprobe erzeugt PNG-Vergleiche und einen Messbericht ausschließlich in einem neuen temporären Ordner:

```sh
GLOWROOM_MASK_QUALITY_IMAGE="$PWD/IMG_8724.CR3" \
GLOWROOM_MASK_QUALITY_OUTPUT=/tmp/glowroom-mask-quality \
GLOWROOM_SUBJECT_MATTING_PACKAGE=/absoluter/pfad/GlowroomBiRefNetHR.mlpackage \
  ./scripts/test.sh --jobs 3 --filter AutomaticMaskQualityTests
```

Die Probe entwickelt die RAW-Datei bei 2048 Pixeln ohne eingebettete Vorschau. Sie vergleicht die frühere Pipeline (Vision 1024, Raster 512, Weiche Kante 0,5), rohe Vision-2048-Auswahl, Vision mit Guided Filter und die aktuelle Produktionsroute. Das freigegebene BiRefNet-Paket muss ausdrücklich mitgegeben werden und wird standardmäßig isoliert installiert; ein vorhandenes persönliches Modell beeinflusst den Vergleich nicht. Die Vision-Ergebnisse sind ausschließlich historische Vergleichsrouten im Test, keine verfügbaren App-Alternativen. Vollbilder und unvergrößerte Ausschnitte zeigen Nadeln und innere Hintergrundlücken getrennt. Der SHA-256 des Originals muss unverändert bleiben. Laufzeiten gelten nur für dieses Foto und diese Ausführungsreihenfolge; Betriebssystem-/Modellcaches werden nicht geleert. Ohne Referenzmatte ergibt sich daraus keine objektive Genauigkeitsquote und keine Gleichwertigkeit mit Lightroom. Private Fotos und daraus erzeugte PNGs werden nicht ins Repository aufgenommen.

Für eine zusätzliche Wiederholbarkeitsprüfung:

```sh
GLOWROOM_MASK_QUALITY_IMAGE="$PWD/IMG_8724.CR3" \
GLOWROOM_MASK_QUALITY_OUTPUT=/private/tmp/glowroom-matting-quality-neu \
GLOWROOM_SUBJECT_MATTING_PACKAGE=/absoluter/pfad/GlowroomBiRefNetHR.mlpackage \
GLOWROOM_MASK_QUALITY_REPEAT_CURRENT=1 \
  ./scripts/test.sh --jobs 3 --filter AutomaticMaskQualityTests
```

Der Import erfolgt im Standardfall in einer anschließend entfernten temporären Installation. `GLOWROOM_SUBJECT_MATTING_INSTALL_ROOT` kann ausdrücklich ein anderes Installationsziel festlegen, das dann erhalten bleibt. Der Bericht identifiziert Modellroute, Herkunft, Quell-/Installationshashes und Ausführungsreihenfolge. Ein zweiter Durchlauf prüft die Wiederholbarkeit; beide Aufrufe laden ihre Modellobjekte neu. Bereits der Import lädt das Modell zur Validierung, daher sind die Messungen keine zugesicherten Kaltstartzeiten. Die gemeinsame Zulassung wird außerdem mit einem bereits abgebrochenen Auftrag geprüft. Echte Inferenz ist synchron; ein Abbruch verwirft das Ergebnis, gibt die Zulassung aber erst nach der nativen Rückkehr frei.

Matting schätzt die Deckung, rekonstruiert jedoch nicht getrennt Motiv- und Hintergrundfarben eines bereits gemischten Randpixels. Die lokale Korrektur mischt weiterhin Originalpixel und korrigierte Pixel anhand dieser Deckung. Sehr starke Hintergrundabdunklung kann deshalb auch mit einer besseren Maske Restsäume sichtbar machen. Entscheidend ist die Prüfung des gerenderten Fotos und nicht nur der Graustufenmaske.

Für eine ausdrücklich gestartete native Prüfung kann das unveränderte, oben gepinnte Paket in einen temporären Ordner geladen und übergeben werden:

```sh
GLOWROOM_SKY_MODEL_SMOKE_PACKAGE=/absoluter/pfad/DETRResnet50SemanticSegmentationF16.mlpackage \
  ./scripts/test.sh --jobs 3 --filter AutomaticMaskTests/approvedNativeSkyModelSmokeWhenExplicitlyConfigured
```

Dieser Test lädt nichts herunter. Er installiert und kompiliert das echte Modell ausschließlich in einem eigenen temporären Testordner und prüft die obere/untere Auswahl auf einer deterministisch erzeugten synthetischen Landschaft. Anschließend vergleicht er die Auswahl bei automatischer Gerätewahl mit einer unabhängigen CPU-Ausführung; verlangt werden mindestens 98 % Schnittmenge-zu-Vereinigungsmenge (IoU) für diese Fixture. Diese Funktionsprüfung ersetzt keinen Genauigkeitsvergleich an einem repräsentativen Fotodatensatz.

API-Grundlagen: [Vision-Vordergrundfreistellung](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest), [Apples Modellkarte](https://huggingface.co/apple/coreml-detr-semantic-segmentation) und [Core-ML-Beispielanwendung des Herausgebers](https://github.com/huggingface/coreml-examples/tree/main/SemanticSegmentationSample).

Algorithmische Grundlage: [Guided Image Filtering, He, Sun und Tang](https://people.csail.mit.edu/kaiming/eccv10/index.html), insbesondere die RGB-geführte lokale Regression für Maskenverfeinerung. Bei der Untersuchung diente Lightcrafts gemeinsame bildgeführte Maskenverfeinerung als Architekturvergleich. Die Umsetzung in Glowroom verwendet Core Image und enthält keine kopierte Lightcraft-Implementierung.
