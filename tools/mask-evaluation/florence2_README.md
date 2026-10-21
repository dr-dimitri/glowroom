# Florence-2-large: lokaler Text-/Maskentest

Dieses getrennte Messwerkzeug verändert Glowroom nicht. Es prüft genau
[`microsoft/Florence-2-large`](https://huggingface.co/microsoft/Florence-2-large/tree/21a599d414c4d928c9032694c424fb94458e3594),
Revision `21a599d414c4d928c9032694c424fb94458e3594`. Die aktuelle Microsoft-Modellkarte
beschreibt die weiter vortrainierte 4k-Version mit nur 0,1 Milliarden zusätzlichen
Trainingsbeispielen und warnt vor möglicher Untertrainiertheit. Das Werkzeug
ersetzt diesen Checkpoint weder durch `large-ft` noch durch eine Community-Konvertierung.

## Herkunft und Ausführung

`florence2.py download ROOT` lädt zwölf ausdrücklich erlaubte Dateien mit
`huggingface_hub.hf_hub_download`, festem Commit und ohne Authentifizierung.
Alle Dateigrößen und SHA-256 sind im Werkzeug fest hinterlegt. Zusammen sind es
1.556.231.245 Byte, davon 1.553.563.458 Byte für `model.safetensors`
(`4f38ce741c6b71188fe2b3419a55e11917a8a7b321ae2e63c61da0191b0ebad7`).
Das Pickle-Checkpoint `pytorch_model.bin` wird nicht geladen.

Vor jedem Lauf prüft das Werkzeug alle zwölf Dateien erneut, anschließend die
tatsächlich importierten drei Microsoft-Python-Dateien. Gewichte werden nur mit
`use_safetensors=True` geladen. Fehlende, unerwartete oder abweichende Gewichte
brechen den Lauf ab; zusätzlich werden alle 918 gespeicherten Tensorformen und
776.721.497 Elemente gegen das unveränderte Modell geprüft. Die MIT-Modelllizenz
und die Apache-2.0-Hinweise in den Microsoft-Quellköpfen bleiben erhalten.

Der unveränderte Microsoft-Code ist mit Transformers 5.20.2 nicht direkt kompatibel:
bereits die Konfiguration scheitert an `Florence2LanguageConfig.forced_bos_token_id`.
Der private Vorversuch dokumentiert diesen Fehler vor jeder Gewichts-/Inferenzarbeit.
Die native Florence2-Implementierung dieser Bibliothek erwartet andere Konfigurations-
und Gewichtsnamen; eine ungeprüfte native Ladung wäre kein gleichwertiger Test.
Deshalb wird eine getrennte kompatible Runtime mit Transformers 4.49.0 und
Hugging Face Hub 0.28.1 verwendet. Der Download erfolgte getrennt mit Hub 2.2.0.
Microsoft-Modellcode, Prozessor, Gewichte und Tokenizer werden nicht gepatcht.
Die drei Python-Dateien wurden vor Ausführung auf Datei-, Netzwerk- und Prozesszugriffe
geprüft; der Lauf arbeitet mit lokalen PIL-Bildern und offline geschaltetem Hub.

Beispiel für zwei getrennte virtuelle Umgebungen (Python 3.11):

```sh
python3 -m venv "$EVAL_ROOT/download-venv"
"$EVAL_ROOT/download-venv/bin/pip" install huggingface-hub==2.2.0
"$EVAL_ROOT/download-venv/bin/python" tools/mask-evaluation/florence2.py download "$EVAL_ROOT"

python3 -m venv "$EVAL_ROOT/compat-venv"
"$EVAL_ROOT/compat-venv/bin/pip" install torch==2.14.1 torchvision==0.29.1 transformers==4.49.0 huggingface-hub==0.28.1 accelerate==1.15.0 timm==1.0.30 einops==0.8.2 pillow==13.0.0 numpy==2.4.6 safetensors==0.8.0
env PYTORCH_ENABLE_MPS_FALLBACK=0 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 HF_HOME="$EVAL_ROOT/compat-hf-home" \
  "$EVAL_ROOT/compat-venv/bin/python" tools/mask-evaluation/florence2.py run "$EVAL_ROOT" \
  --manifest "$EVAL_ROOT/prompts.json" --output "$EVAL_ROOT/results-mps" \
  --device mps --beams 3 --max-new-tokens 1024
```

`EVAL_ROOT` muss auf einen privaten Messordner zeigen. Das JSON-Manifest enthält
`images` mit `id`, lokalem `path` und englischem `target`. Zusätzliche manuelle
Boxen/Punkte des SAM-Vergleichs werden nicht gelesen. Die Bilddateien werden
nicht hochgeladen. Laufoptionen: `--device cpu|mps`, `--threads` (Standard 4),
`--image-id`, `--limit`, `--task referring-segmentation|phrase-grounding`,
`--beams` (Standard 3), `--max-new-tokens` (Standard 1024).

## Schnittstelle und Messumfang

Pro Bild werden die offiziellen Aufgaben `<REFERRING_EXPRESSION_SEGMENTATION>`
und `<CAPTION_TO_PHRASE_GROUNDING>` mit demselben englischen Ziel ausgeführt.
Der offizielle Prozessor expandiert die Aufgabe in seine Microsoft-Promptvorlage.
Sein CLIPImageProcessor verarbeitet das Bild mit der gespeicherten festen Größe
768 × 768 und ImageNet-Normalisierung. `input_ids` bleiben Integer; nur
`pixel_values` werden bei MPS in Float16 umgewandelt. CPU verwendet Float32.
Die Aufmerksamkeit verwendet den unveränderten `eager`-Pfad ohne FlashAttention.

Die Hauptserie verwendet die offizielle Empfehlung mit drei Beams, Decoding ohne
Sampling und höchstens 1024 neuen Tokens. Dies garantiert keine bitgleichen Ergebnisse
zwischen MPS-Prozessen; eine getrennte Wiederholung prüft diese Grenze. Jeder `generate`-Aufruf enthält die
Bildkodierung und die autoregressive Textgenerierung. Zwischen den beiden Aufgaben
wird das decodierte Foto wiederverwendet; Bildmerkmale werden nicht separat gecacht.
Die beiden Aufgaben laufen seriell, damit sie sich auf dem gemeinsamen MPS-Gerät
nicht bezüglich Latenz und Speicher beeinflussen. Drei unabhängige Downloads
können sich überlappen. Die MPS-Ausführung synchronisiert an den gemessenen
Übertragungs- und Generierungsgrenzen; CPU-Fallback ist ausdrücklich abgeschaltet.

Der unveränderte offizielle `post_process_generation` erhält `image_size=(width,height)`
des Originalproxies. Die zurückgegebenen Koordinaten sind bereits Pixelkoordinaten
und werden nicht erneut skaliert. Microsoft dequantisiert die 1000 Ortsbins über
ihre Zentren, `(bin + 0,5) × Dimension / 1000`. Polygoninstanzen enthalten jeweils
Teilpolygone mit flachen xy-Paaren, ohne definierte Lochrollen; der Rasterizer bildet
ihre Vereinigung auf der Quellgeometrie. Das Ergebnis ist eine binäre Polygonmaske,
keine Haar-/Transparenzmatte. Grounding liefert Boxen; `box-union.png` ist nur die
Vereinigung ihrer Rechtecke und ausdrücklich keine Objektsegmentierung.

## Private Ergebnisse und Grenzen

`OUTPUT/benchmark.json` enthält Herkunft, Bibliotheksversionen, vollständige
Gewichts-Ladeinformationen, Quellenprüfung, Ladezeit und `images[].tasks[]`.
Bei neuen Läufen werden außerdem beide GenerationConfig-Objekte gespeichert:
Microsoft delegiert an das innere `language_model`, dessen aus der Textkonfiguration
abgeleitete Defaults vom äußeren `generation_config.json` abweichen können.
Die expliziten Flags überschreiben Beamzahl, Sampling, Cache und Tokenbudget.
Bei diesem unveränderten Checkpoint und Transformers 4.49.0 verwendet das innere
Modell insbesondere `early_stopping=True`, `no_repeat_ngram_size=3`,
`forced_bos_token_id=0` und `forced_eos_token_id=2`. Das äußere JSON mit
`early_stopping=False` beschreibt diese tatsächlich verwendeten inneren Defaults
nicht vollständig. Für die bereits abgeschlossenen Messungen hält eine getrennte
Meta-Modellinspektion diese Konfiguration fest, ohne weitere Inferenz auszuführen.
Pro Aufgabe gibt es einen Unterordner mit `benchmark.json`, `raw-text.txt`,
`token-ids.json`, `parsed.json` sowie `mask.png` oder `box-union.png`.
Rohtexte, Token, Polygone, Boxen und Masken sind private rekonstruierbare Bilddaten;
sie gehören nicht in den öffentlichen Bericht oder Git. Das Werkzeug schreibt
diese Daten ausschließlich in den ausdrücklich gewählten privaten Ausgabeordner.

Die Metriken trennen Vorverarbeitung, Eingabeübertragung, `generate` inklusive
Bildencoder, Textdecodierung/offizielles Parsing und Rasterisierung/Maskenspeicherung.
`requestToParsedOutputSeconds` endet vor der Maskenspeicherung;
`requestToSavedMaskSeconds` enthält sie. Modellprüfung/-laden und Bilddecodierung
sind getrennt erfasst. Die erste Generierung kann erstmalige MPS-Initialisierung
enthalten; spätere verschiedene Bilder sind keine Wiederholungen desselben Requests.
Es werden keine Decoder-only- oder warmen Wiederholungszeiten behauptet.
Darwin-`ru_maxrss` ist der Prozess-RSS-Höchstwert in Byte; MPS meldet zusätzlich
aktuell zugewiesenen und vom Treiber belegten Speicher. Unified Memory kann diese
Werte überlappen lassen; sie dürfen nicht addiert werden.

Das Werkzeug speichert die rohe Ausgabe, weil der offizielle Parser etwa ungerade
Koordinaten still kürzen kann. Prüfungen erfassen EOS nach dem Decoder-Starttoken,
Tokenbudget, Ortsbins, Polygon-Tagabschluss, Koordinatenpaarzahl, mindestens drei
Polygonpunkte, endliche Werte, Nullfläche und Quellgrenzen. Ein am Budgetende
erzwungenes EOS zählt weiterhin als Abbruchrisiko. `outputCompleteByChecks` belegt
nur diese Syntax-/Geometrieprüfungen; `hasNonemptyParsedOutput` wird separat erfasst.
Keiner dieser Werte belegt semantisch korrekte Objektauswahl oder Maskengüte.
Ohne annotierte Ground Truth sind Bildbefunde und Differenzen zu anderen Modellen
qualitative Vergleiche, keine gemessene Segmentierungsgenauigkeit.

Das Hilfswerkzeug ist nicht in die App eingebunden; dafür ist kein Glowroom-Build nötig.
