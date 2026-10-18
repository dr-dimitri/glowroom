# LaMa/Core ML: technische Folgeprüfung, kein Produkt-Go

**Entscheidung vom 18. Oktober 2026: Die lokale technische Route funktioniert; die geprüfte Konfiguration erhält wegen Bildqualität kein Produkt-Go.** [Issue #74](https://github.com/dr-dimitri/picedit/issues/74) setzt die Nachweisführung aus [#1](https://github.com/dr-dimitri/picedit/issues/1) nach dem [bestehenden SD-1.5-No-Go](../../../docs/AI-IMAGE-BACKEND-DECISION.md) fort. Der Pflichtfall mit großflächiger Maske und feinem geschütztem Motiv liefert einen flächig grünen Ersatz. Erfolgreiche kleine Objektentfernungen reichen nicht für das vorab festgelegte Gate. #13–16 bleiben offen; produktive Bildgenerierungsfähigkeiten bleiben unavailable.

## Prüfling und Verfahren

- Öffentliches Paket [mlboydaisuke/LaMa-CoreML](https://huggingface.co/mlboydaisuke/LaMa-CoreML/tree/5ed76e3799ab4cad31381750d29880c267477e18), Revision `5ed76e3799ab4cad31381750d29880c267477e18`. Vier gepinnte Dateien, zusammen **216.650.601 Byte**, separat ausdrücklich heruntergeladen. [Dateihashes und Installationsbeleg](v2-straight-rgb/provenance/installation.json); keine Gewichte im Repository.
- Modellbeschreibung tatsächlich gelesen: `image` als 800×800 RGB/BGRA, `mask` als 800×800 Gray8, `output` als RGB/BGRA. Core ML wählt mit `.all` die Ausführung; GPU-Low-Precision-Akkumulation ist ausgeschaltet. Es gibt keinen Textinput.
- Referenzrechner: Apple M2 Pro, 12 CPU-Kerne, 16 GiB, macOS 27.0.1 (26A434). Ein Modellkontext verarbeitet die Fälle seriell unter einer 6-GiB-Inferenzlease. Compiler und andere Modellmessungen liefen während der Serie nicht. Unabhängige Downloads und Entwicklungsprüfungen wurden begrenzt parallelisiert.
- Derselbe eingefrorene synthetische Fixturesatz wie bei der historischen Evaluation: sechs Bilder mit sieben Maskenfällen, davon sechs verpflichtende Entfernerfälle und ein diagnostischer Canvasfall. Keine Benutzerfotos, keine Cloudinferenz. Die erste Eingabe wurde dreimal warm wiederholt: insgesamt zehn echte Vorhersagen.
- Native Pixel werden ohne Skalierung zentriert ins 800er Raster verschoben und anhand derselben ganzzahligen Zuordnung zurückgeschnitten. V2 verwendet gerades RGB und identisches Clamp-Sampling für RGB und binäre Modellmaske, auch im künstlichen Padding. Das Quellalpha wird getrennt gehalten; die native weiche Maske bleibt unverändert für den aktuellen `MaskCompositor`.
- [V2-Kriterien](v2-straight-rgb/native/criteria.json) wurden vor dieser Messung festgelegt. Grenzen: Laden ≤45 s, einzelne Vorhersage ≤180 s, eigener Peak-RSS und Footprint ≤6 GiB, drei warme Wiederholungen, kein sichtbarer Objekt-/Naht-/Textur-/Halo-Fehler und bytegleiche Erhaltpixel. Das Werkzeug prüft Zeit und Prozessspeicher nach Rückkehr synchroner Core-ML-Aufrufe; es besitzt keinen unterbrechenden Watchdog und keine OS-Speicherquote.

## Tatsächliche V2-Messung

[Unveränderter nativer Bericht](v2-straight-rgb/native/lama-report.json), [Vorhersagelog](v2-straight-rgb/native.log), [aktueller Compositorbericht](v2-straight-rgb/compositor/current-compositor-report.json).

| Messwert | Ergebnis |
| --- | ---: |
| Core-ML-Kompilierung | 0,336 s |
| Modell laden | 2,160 s |
| Erste Vorhersage im neuen Prozess | 0,740 s |
| Warme Wiederholung 1 / 2 / 3 | 0,4094 / 0,4087 / 0,4088 s |
| Weitere sechs Vorhersagen | 0,4080–0,4088 s |
| Peak-RSS des eigenen Prozesses | 768.507.904 Byte |
| Peak-physischer Footprint des eigenen Prozesses | 1.460.978.984 Byte |

Die vier identischen Eingaben erzeugten denselben RGBA8-Hash `9bce8cae4238c194a87b56f684f4a77820b9642e12b51fe0e66ed10133ef0474`. Das ist ein Wiederholbarkeitsnachweis für diesen Rechner und Lauf, keine allgemeine Hardwaregarantie. Der Erstlauf leert keine Betriebssystem-/Treiber-Caches. Prozessspeicherwerte erfassen ausgelagerte Core-ML-Dienste nicht vollständig; aus ihnen folgt kein gesamter Systemspeicherverbrauch. Es wurden weder ein CPU/GPU-Vergleich noch große RAWs oder eine interaktive Vorschau gemessen; es gibt keine daraus abgeleitete Beschleunigungsbehauptung.

Alle zehn Rohbilder wurden durch den aktuellen **Produkt-Compositor mit CPU-Backend** verarbeitet. In jedem Fall sind alle kanonischen RGBA-Bytes mit nativem Maskengewicht 0 identisch, alle Quellalpha-Bytes identisch und der PNG-Roundtrip identisch. Im Canvasfall bleiben zusätzlich alle 98.304 Pixel der Original-ROI bytegleich. Diese Erhaltverträge sagen nichts über die Qualität neu erzeugter Pixel aus.

## Visuelle Prüfung des aktuellen Composites

Root und ein unabhängiger Reviewer haben alle sieben unterschiedlichen Vergleiche angesehen. Die [separate Sichtprüfung](visual-review.json) hält fallbezogene Belege und die Sicherheit der Urteile fest; die maschinellen Originalberichte bleiben unverändert bei `pending-manual-review`. Ein gelungener Objektentfernerfall wird hier nicht zu einem umfassenden Gate-Pass aufgewertet.

| Fall und tatsächlicher Vergleich | Beobachtung | Gate-Einordnung |
| --- | --- | --- |
| [01 – strukturiertes Holz](v2-straight-rgb/compositor/01-structured-removal-hard/current-comparison.png) | Rote Kugel entfernt, Holzlinien plausibel fortgesetzt; lokal schwächer geänderte Diagonaltextur. | Vielversprechend; kein uneingeschränkter Qualitäts-Pass. |
| [02 – Objekt am Rand](v2-straight-rgb/compositor/02-edge-object-hard/current-comparison.png) | Blaue Tasse einschließlich Rand entfernt. Keine erneute Tasse aus künstlichem Kontext; lokale Texturabweichung bleibt sichtbar. | V1-Eingabefehler korrigiert; kein uneingeschränkter Qualitäts-Pass. |
| [03 – harte Kante](v2-straight-rgb/compositor/03-mask-edge-hard/current-comparison.png) | Gelber Block entfernt; feine Textur lokal weicher bzw. phasenverschoben. | Unter dem strengen Texturkriterium nicht sauber bestanden. |
| [03 – weiche Kante](v2-straight-rgb/compositor/03-mask-edge-soft/current-comparison.png) | Block entfernt, native weiche Maske angewendet; lokale Fülltextur unterscheidet sich. | Unter dem strengen Texturkriterium nicht sauber bestanden. |
| [04 – Teiltransparenz](v2-straight-rgb/compositor/04-partial-alpha-hard/current-comparison.png) | Violette Kugel entfernt; Quelltransparenz erhalten, kein weißer Vormatte-Fleck. Kleiner Texturunterschied am früheren Objekt. | V1-Eingabefehler korrigiert; kein uneingeschränkter Qualitäts-Pass. |
| [05 – feines Motiv, große Maske](v2-straight-rgb/compositor/05-fine-motif-edges-hard/current-comparison.png) | Originalmotiv bleibt in der Erhaltmaske; fast der ganze erzeugte Bereich wird flächig grün, mit schwachen Geisterstrukturen. | **Eindeutiger Pflichtfehler; verhindert das Qualitäts-Go.** |
| [06 – nichtquadratisches Canvas](v2-straight-rgb/compositor/06-nonsquare-canvas-hard/current-comparison.png) | Geschützte Original-ROI bleibt exakt; erzeugte Umgebung zeigt rechteckige Übergänge, verwaschene bzw. raue Textur. | Diagnostischer Fehler; keine Outpainting-Freigabe. |

LaMa ist textfrei. Der großflächige Stressfall wird nicht als Nachweis einer Prompt- oder Hintergrundfähigkeit ausgegeben. Er war bereits vor der V2-Serie Teil des verpflichtenden Prüfumfangs; die Anforderung wird nach Sichtung des schlechten Ergebnisses nicht entfernt. Die Beurteilung gilt für dieses Paket, diese Vorverarbeitung und diese Fixtures, nicht für jede denkbare LaMa-Konfiguration.

## V1 bleibt als fehlgeschlagene Vorbereitung erhalten

Die erste echte [V1-Serie](v1-white-matte/) samt damaligem Quellstand wurde vor der Korrektur archiviert. Weißes Vormatten und spätere Quellalpha-Wiederherstellung verursachten bei 04 einen hellen Fleck. In 02 wurden markierte Randpixel im künstlichen Kontext als unmaskierte RGB-Kopien angeboten. Diese Fehler gehören zur neuen Evaluationsvorbereitung; sie sind korrigiert und durch modellfreie Pixeltransporttests abgesichert. Sie werden nicht dem Modell als unveränderliche Eigenschaft zugeschrieben.

V2 besitzt eigene Rohbilder, Berichte, Kriterienhash und [exakte Messquellen einschließlich Binärhash](v2-straight-rgb/provenance/source-identity.json). V1 wurde nicht überschrieben. Der archivierte V2-Messquellstand liegt vor der anschließenden CLI-Protokollkorrektur: Ein manueller `replay` erkennt nun `lama-report.json.preprocessingVersion == 2` und behält die Straight-RGB-Angabe bei; historische Replays behalten ihre Vormatte-Angabe. Der automatisch gemessene LaMa-Replay verwendete bereits die korrekte Policy. Die Korrektur ändert keine Inferenz oder Pixel.

## Offene Freigaben und Nachprüfung

Die [gepinnt gelesene Modellkarte](https://huggingface.co/mlboydaisuke/LaMa-CoreML/blob/5ed76e3799ab4cad31381750d29880c267477e18/README.md) und die native Modellmetadaten nennen das [LaMa-Ursprungsprojekt](https://github.com/advimman/lama), einen Konvertierer und Apache 2.0. Die vollständige Zuordnung zum ursprünglichen Checkpoint und zur tatsächlich verwendeten Konversionsrevision sowie die Verteilprüfung sind damit nicht belegt. Die Identitätsprüfung ist keine rechtliche Freigabe; es wird keine ungeklärte Herkunft als geklärt behauptet.

Zusätzlich fehlen ein nachgewiesener Produktadapter, Abbruchlatenz und gleichzeitig bedienbare Vorschau. Das technische Werkzeug aktiviert keinen Provider. Der bereits ausreichende Qualitätsfehler begründet das No-Go; weitere ungeprüfte Releasebedingungen werden nicht als bestanden dargestellt. Die ursprüngliche SD-1.5-Entscheidung bleibt erhalten.

Wiederholung und Offline-Prüfungen sind in der [Werkzeuganleitung](../../../tools/lama-evaluation/README.md) beschrieben. Mapping-/Pixeltests verwenden echte gepolsterte Core-Video-Buffer, feste Kanal-/Koordinatenanker und ein Identitätsmodell mit echtem Compositor. Sie benötigen keine Modellgewichte. Der Installer wird mit kleinen lokalen Payloads auf Identität, Fehler, fremde Daten, Links und atomare Veröffentlichung geprüft. Die abschließenden Build-/Testergebnisse und Reviewkorrekturen stehen im zugehörigen Pull Request.
