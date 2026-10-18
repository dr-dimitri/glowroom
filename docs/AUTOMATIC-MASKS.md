# Automatische Motiv- und Himmelsmasken

## Bedienung und Datenschutz

**Motiv** verwendet Apples lokale Vision-Freistellung unter macOS 14 oder neuer. PicEdit wählt alle vom System erkannten Vordergrundobjekte gemeinsam aus. Wenn kein freistellbares Motiv erkannt wird, erscheint ein verständlicher Hinweis; Pinsel und Verläufe bleiben verfügbar.

**Himmel** verwendet nach einer einmaligen Einrichtung ein lokales Segmentierungsmodell auf der bereits geladenen, orientierten Bildvorschau. Über **Himmelsmodell einrichten …** und **Modell laden und einrichten** wird das Modell ausdrücklich heruntergeladen. Der Download umfasst 85.468.610 Bytes, angezeigt als etwa 86 MB. Die Einrichtung benötigt vorübergehend mindestens 768 MB freien Speicher. Das Modell kann im selben Dialog entfernt werden.

Fotos werden für diese Funktionen nicht hochgeladen. Nach der Einrichtung funktioniert die Himmelserkennung offline. Fehlende oder veränderte Modelldaten lösen einen Fehler aus; die Einrichtung kann erneut gestartet werden. Es gibt keinen stillen Modelldownload und keine Ersatzmaske, die nur anhand einer blauen Farbe einen vermeintlichen Himmel auswählt.

Das Ergebnis wird als unveränderliche Gray8-Auswahl mit höchstens 512 Pixeln an der längsten Seite in den Bearbeitungseinstellungen gespeichert. Dadurch bleiben bestehende lokale Bearbeitungen nach einem Modellupdate, einem Neustart oder dem Entfernen des Modells reproduzierbar. Die Auswahl kann invertiert, in ihrer Deckkraft und Weichheit verändert sowie mit Pinsel und Radierer nachgebessert werden. Originalbilder bleiben unverändert.

## Modellquelle und Lizenz

Verwendet wird das von Apple veröffentlichte [DETRResnet50SemanticSegmentationF16](https://huggingface.co/apple/coreml-detr-semantic-segmentation), Revision `bfcb6e4210d7289310082d7c93bf9a1417b3699f`. Das Modell basiert auf [facebook/detr-resnet-50-panoptic](https://huggingface.co/facebook/detr-resnet-50-panoptic). Modellkarte und eingebettete Modellmetadaten weisen die Apache-2.0-Lizenz aus. Der vollständige Lizenztext liegt unter `Sources/PicEdit/AI/Resources/SkyMaskLicenses/SkyMask-APACHE-2.0.txt`; Hinweise und Attribution stehen daneben in `SkyMask-NOTICE.txt`.

Die App besitzt eine feste Dateiliste mit exakter Länge und SHA-256. Sie akzeptiert weder eine vom Server gelieferte neue Revision noch eine frei angegebene Modelldatei:

| Datei im veröffentlichten `.mlpackage` | Bytes | SHA-256 |
| --- | ---: | --- |
| `Manifest.json` | 617 | `0749549c6b11139e11a40aaab82add4843a9977010337e596cce3dbb35c98512` |
| `Data/com.apple.CoreML/model.mlmodel` | 309817 | `61e05678150bcae26deac589b998dffe13c2977a9ba6f802938a9f3a60bfdcce` |
| `Data/com.apple.CoreML/weights/weight.bin` | 85158176 | `2f4de3dfed1aeced35ad7096d7c8721fcfb59571110a9e9138d73a7e56480408` |

Die Eingabe ist ein farbverwaltetes RGB-Bild mit 448 × 448 Pixeln, die Ausgabe `semanticPredictions` ein `Int32[448,448]`-Klassenraster. Die Himmelsklasse wird aus der im geprüften Modell eingebetteten Beschriftung **`sky (other)`** ermittelt. Es wird kein Klassenindex geraten. Das gesamte Bild wird auf die Modelleingabe skaliert und anschließend in sein ursprüngliches Seitenverhältnis zurückgeführt; ein mittiger Ausschnitt würde Himmel und Motivteile am Bildrand verlieren.

## Ausführung, Abbruch und Installation

Die native Erkennung läuft auf einem Hintergrund-Actor. Die vorhandene gemeinsame `AIResourceBudget`-Zulassung begrenzt lokale Modellerkennung und Modellkompilierung zusammen auf eine gleichzeitig laufende Arbeit. Vision/Core ML übernehmen die interne CPU-/GPU-/Neural-Engine-Parallelität. Es wird kein zweiter Foto-Workerpool gestartet. Die angekündigten 384 MiB sind eine Zulassungsschätzung, keine harte Obergrenze für Framework- oder GPU-Speicher.

Motiverkennung verwendet einen bereits orientierten Vorschau-Proxy mit höchstens 1024 Pixeln. Sie löst keine eigene RAW-Entwicklung aus. Vision-Abbruch wird an die native Anfrage weitergegeben. Native Kompilierung und Core-ML-Inferenz können einen Abbruch erst bei ihrer Rückkehr beachten; die gemeinsame Zulassung bleibt bis dahin belegt. Der Editor prüft vor der Übernahme weiterhin die Bildquelle und Bearbeitungssitzung. Reglerbewegungen ändern nur die gespeicherte Auswahl und führen keine neue Motiverkennung aus.

Core ML darf geeignete Beschleuniger auswählen. Scheitert das Laden oder die Vorhersage auf dem beschleunigten Pfad, wird derselbe geprüfte Graph auf der CPU ausgeführt. Zwischen beiden Versuchen werden temporäre Modellobjekte freigegeben. Beide automatischen Werkzeuge verwenden ausschließlich den übergebenen unveränderlichen Bild-Proxy. Separate neue Dateizugriffe für eingebettete Himmelsmatten unterbleiben, damit eine zwischenzeitlich ersetzte Originaldatei nicht mit einem älteren Cachebild vermischt wird.

Die Installation liegt getrennt vom Katalog unter `~/Library/Application Support/PicEdit/Models/Sky/`. Der Download schreibt begrenzt in temporäre Dateien. Erst nach Größen-/Hashprüfung aller drei Paketdateien und erfolgreicher lokaler Kompilierung werden private Kopien der kompilierten Dateien in einer neuen Generation abgelegt. Ein atomar ersetzter `current.json`-Zeiger ist der Commitpunkt. Fehler oder Abbruch davor erhalten eine bestehende Installation; unbekannte oder nicht verifizierbare Generationen werden nicht rekursiv entfernt. Symlinks und fremde Hardlinks in verwendeten Installationsbäumen werden zurückgewiesen.

Vor jedem Modellladen werden die kompilierten Dateien anhand des lokalen Installationsbelegs geprüft. Nach der Inferenz werden Dateistempel erneut geprüft. Das Modell wird nach einer abgeschlossenen Auswahl wieder freigegeben. Das Entfernen des Modells wartet auf die tatsächliche Rückkehr laufender lokaler Inferenz.

## Grenzen und Verifikation

Die Himmelsauswahl ist ein Vorschlag eines allgemeinen COCO-Segmentierungsmodells. Feine Äste, Haare, transparente Flächen, Spiegelungen und ungewöhnliche Lichtverhältnisse können ungenaue Ränder oder falsche Auswahlteile erzeugen. Die Modelleingabe und das gespeicherte Raster sind bewusst begrenzt; es wird keine pixelgenaue Freistellung in voller RAW-Auflösung zugesichert. Pinselkorrektur und Maskenweichheit dienen der Nachbearbeitung. Es werden keine Leistungs- oder Genauigkeitsgewinne gegenüber Lightroom behauptet.

Die normalen Tests benötigen keine Modelldaten und keinen Netzwerkzugriff. `AutomaticMaskTests` prüft Gray8-Konvertierung, Zeilenorientierung, Zeilenpadding, ungültige Gleitkommawerte, Seitenverhältnisse, semantische Klassenauswahl und die gemeinsame Zulassung bei abgebrochener nativer Arbeit. `AutomaticMaskModelStoreTests` prüft Hashfehler, Manipulation, Symlink-Umleitungen, sichere Löschung und den Rollback einer während nativer Kompilierung abgebrochenen Einrichtung.

Für eine ausdrücklich gestartete native Prüfung kann das unveränderte, oben gepinnte Paket in einen temporären Ordner geladen und übergeben werden:

```sh
PICEDIT_SKY_MODEL_SMOKE_PACKAGE=/absoluter/pfad/DETRResnet50SemanticSegmentationF16.mlpackage \
  ./scripts/test.sh --jobs 3 --filter AutomaticMaskTests/approvedNativeSkyModelSmokeWhenExplicitlyConfigured
```

Dieser Test lädt nichts herunter. Er installiert und kompiliert das echte Modell ausschließlich in einem eigenen temporären Testordner und prüft die obere/untere Auswahl auf einer deterministisch erzeugten synthetischen Landschaft. Anschließend vergleicht er die Auswahl bei automatischer Gerätewahl mit einer unabhängigen CPU-Ausführung; verlangt werden mindestens 98 % Schnittmenge-zu-Vereinigungsmenge (IoU) für diese Fixture. Diese Funktionsprüfung ersetzt keinen Genauigkeitsvergleich an einem repräsentativen Fotodatensatz.

API-Grundlagen: [Vision-Vordergrundfreistellung](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest), [Apples Modellkarte](https://huggingface.co/apple/coreml-detr-semantic-segmentation) und [Core-ML-Beispielanwendung des Herausgebers](https://github.com/huggingface/coreml-examples/tree/main/SemanticSegmentationSample).
