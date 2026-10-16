# Modellentscheidung für lokale semantische Suche – Vorbereitung zu Issue #8

Stand: 16. Oktober 2026. Diese Notiz entscheidet noch keine Produktfreigabe. Es wurden ausschließlich öffentliche Modellmetadaten, kleine Konfigurationsdateien, Lizenzen und Quelltexte gelesen. Keine Gewichte, Vokabulardateien oder Tokenizer-Modelle wurden heruntergeladen; keine Pakete installiert, keine Modelle geladen und keine Inferenz oder Messung gestartet. Das Repository blieb unverändert.

## Entscheidungsvorschlag

Genau zwei vollständige Modellpaare kommen in die abschließende Auswahl:

| Kandidat | Gemeinsamer DE/EN-Bildraum | Dateibudget | Verifizierter Lizenzstand | Empfehlung |
| --- | --- | --- | --- | --- |
| Multilingualer Sentence-Transformers-Textencoder plus originales CLIP ViT-B/32-Bildmodell | Von den Textmodellautoren ausdrücklich dokumentiert; 512 Dimensionen | Originale CLIP-Datei plus erforderliche Textdateien: 895 499 849 Bytes, rund 854,02 MiB | Textgewichte Apache 2.0; CLIP-Code MIT; eine ausdrückliche gewichtsbezogene Lizenz für das originale CLIP-Checkpoint konnte nicht bestätigt werden | Technisch der kleinere und einfachere Versuch, wenn diese letzte Lizenzzuordnung belegt wird |
| Google SigLIP 2 Base Patch32 256, beide Türme derselben Revision | Gepaarte mehrsprachige Encoder; 768 Dimensionen | Originales FP32-Checkpoint allein 1 507 473 288 Bytes; geplante FP16-Core-ML-Artefakte voraussichtlich kleiner als 1 GiB, aber noch nicht erzeugt | Exakte Google-Modellkarte deklariert Apache 2.0; Referenzcode ebenfalls Apache 2.0 | Bevorzugter Konvertierungsversuch bei weiterhin ungeklärter CLIP-Gewichtenlizenz; keine Freigabe der übergroßen FP32-Datei als App-Modellpaket |

Damit ist derzeit kein Kandidat vollständig gatefertig: beim ersten fehlen belegte Bildgewichtenrechte und die native Konvertierungsprüfung, beim zweiten tatsächliche Größe und Prüfsummen der abgeleiteten FP16-Artefakte. Sprachqualität, RSS und Latenzen sind bei beiden ungemessen. Ein bestandenes Gate oder ein allgemeines technisches No-Go wird nicht behauptet.

Das ≤1-GiB-Ziel muss auf die tatsächlich an PicEdit verteilten und installierten Modelldateien einschließlich Tokenizer angewendet werden. Entwicklungsdownloads, Referenzgewichte und Konvertierungskopien separat ausweisen. Falls das Budget auch jeden einmaligen Entwickler-Quelldownload begrenzen soll, scheidet das originale FP32-SigLIP-Paket zunächst aus; die Grenze darf nicht still umgedeutet werden.

## Kandidat A: Multilingualer DistilBERT und originales CLIP ViT-B/32

### Belegte Paarung und Grenzen

Die [Autorenkarte des konkreten Textmodells](https://huggingface.co/sentence-transformers/clip-ViT-B-32-multilingual-v1/blob/58edf8cada9e398793dca955574a48cbb7f18be2/README.md) verbindet diesen Textencoder ausdrücklich mit dem unveränderten CLIP-Bildencoder. Deutsch und Englisch stehen in der Trainingssprachenliste. Die Architektur ist DistilBERT mit maskiertem Mean-Pooling und einer notwendigen linearen 768→512-Projektion. Das ist ein gemeinsamer Vektorraum; ein beliebiger deutscher Textencoder wird nicht ausgetauscht. Die Autorenangabe ersetzt das eigene 30-Bilder-/20-Query-Gate nicht.

Die originale CLIP-Textseite wird nicht für deutsche Queries verwendet. Ihre 77-Token-Grenze und englischen Trainingsgrenzen sind daher nicht der Textvertrag dieses Paars. Der multilingualen Textseite gelten 128 Tokens einschließlich Spezialtokens, auch wenn die allgemeine Tokenizerkonfiguration 512 nennt. Maßgeblich ist das gepinnte `sentence_bert_config.json`.

### Revisionen und Lizenznachweis

- Multilinguales Modell: `sentence-transformers/clip-ViT-B-32-multilingual-v1`, Revision `58edf8cada9e398793dca955574a48cbb7f18be2`. Die exakte Modellkarte deklariert Apache 2.0 für dieses Modell.
- Originaler CLIP-Code: `openai/CLIP`, Commit `d05afc436d78f1c48dc0dbf8e5980a9d471f35f6`. [LICENSE](https://github.com/openai/CLIP/blob/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6/LICENSE) ist MIT und verlangt Erhalt des Copyright-/Lizenzhinweises.
- Für die Gewichte wurden zusätzlich die [originale README](https://github.com/openai/CLIP/blob/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6/README.md), [originale Modellkarte](https://github.com/openai/CLIP/blob/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6/model-card.md), der [originale Downloadcode](https://github.com/openai/CLIP/blob/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6/clip/clip.py) und der [OpenAI-Veröffentlichungsbeitrag](https://openai.com/index/clip/) geprüft. In diesen Quellen wurde keine ausdrückliche Aussage gefunden, dass Code **und Modellgewichte** unter MIT stehen. Die MIT-Datei spricht von Software und Dokumentation. Das ist ein offener Nachweispunkt, keine behauptete gesonderte Verbotslizenz.
- Die OpenAI-Modellkarte begrenzt ihre ursprünglichen Evaluationen und empfiehlt anwendungsspezifische Prüfung. Diese dokumentierten Modellgrenzen getrennt von der Frage der Gewichtenlizenz behandeln.
- Der Hugging-Face-Bild-Repack `sentence-transformers/clip-ViT-B-32`, Revision `327ab6726d33c0e22f920c83f2ff9e4bd38ca37f`, hat in seiner exakten Modellkarte keinen Lizenz-Tag. Er löst den Gewichten-Nachweis daher nicht. Seine FP32-Safetensors-Datei mit 605 157 884 Bytes wäre außerdem unnötig größer.

Apache-2.0-Lizenztexte, Copyright-/gegebenenfalls NOTICE-Angaben sowie ein Hinweis auf die Core-ML-Konvertierung müssen mit später verteilten Ableitungen erhalten bleiben. Für CLIP darf die Weiterverteilung der abgeleiteten Bildgewichte erst als geklärt dokumentiert werden, wenn die Gewichten-Zuordnung belegt ist.

### Konkretes Quellmanifest

HF-Dateibasis: `https://huggingface.co/sentence-transformers/clip-ViT-B-32-multilingual-v1/resolve/58edf8cada9e398793dca955574a48cbb7f18be2/`.

Die folgende minimale Liste enthält eine einzige Textgewichtedarstellung, ihre Projektion und das für die native WordPiece-Route notwendige Vokabular. Sie enthält keine redundanten PyTorch-/TensorFlow-/ONNX-/OpenVINO-Kopien.

| Datei | Bytes | Veröffentlichte Prüfsumme |
| --- | ---: | --- |
| `model.safetensors` | 538 947 416 | `SHA-256: 7b968c09938603158413ea2c91af82e82158ebb6db901a6cf97c28ce7d7ebc6d` |
| `2_Dense/model.safetensors` | 1 572 984 | `SHA-256: d12568dc7300970a4d3dbb49068ad16cd89b99840b74b026f8e48071e9414f74` |
| `config.json` | 572 | `Git-Blob-SHA-1: 1ab64f94053fdfbd5f943b451df1cd02140e7e70` |
| `sentence_bert_config.json` | 53 | `Git-Blob-SHA-1: 5fd10429389515d3e5cccdeda08cae5fea1ae82e` |
| `1_Pooling/config.json` | 190 | `Git-Blob-SHA-1: 4e09f293dfe90bba49f87cfe7996271f07be2666` |
| `2_Dense/config.json` | 115 | `Git-Blob-SHA-1: 94855c4d00a61b152e3713bd9701adb6d87b2672` |
| `tokenizer_config.json` | 371 | `Git-Blob-SHA-1: 00d4a90ed3ab11cb356ddc3c64c3858a7ace82ff` |
| `special_tokens_map.json` | 112 | `Git-Blob-SHA-1: e7b0375001f109a6b8873d756ad4f7bbb15fbaa5` |
| `vocab.txt` | 995 526 | `Git-Blob-SHA-1: e837bab60a5d204e29622d127c2dafe508aa0731` |
| `modules.json` | 341 | `Git-Blob-SHA-1: 8885f9a958fdc9be2d592c125ff53438ec8b04d8` |
| `README.md` | 5 647 | `Git-Blob-SHA-1: 4b5316fd1c30c686639975a610ca80aa50987aa1` |

Summe dieser Liste: 541 523 327 Bytes. Dazu kommt genau diese originale Bildmodellquelle:

- URL: `https://openaipublic.azureedge.net/clip/models/40d365715913c9da98579312b702a82c18be219cc2a73407c4526f58eba950af/ViT-B-32.pt`
- Dateigröße: **353 976 522 Bytes**, per HTTP-HEAD bestätigt. Kein Dateikörper geladen.
- Erwartetes SHA-256: `40d365715913c9da98579312b702a82c18be219cc2a73407c4526f58eba950af`. Der originale Loader nutzt den URL-Verzeichnisnamen selbst als erwartetes SHA-256. Die tatsächlichen Bytes wurden hier nicht nachgerechnet.
- Die Datei enthält auch die hier unnötige englische Textseite; bei der Konvertierung nur die Bildseite samt visueller Projektion exportieren. Weder diese TorchScript-Datei noch Python müssen im App-Laufzeitpaket bleiben.

Gesamt: 895 499 849 Bytes, rund 854,02 MiB. Die alternativ vorliegende `tokenizer.json` wäre weitere 1 961 847 Bytes groß und besitzt Git-Blob-SHA-1 `f930bdc88c40a163884a6264ebd3bd10688ae1af`; sie ist für einen vollständig geprüften Vokabular-/BasicTokenizer-/WordPiece-Pfad nicht zusätzlich erforderlich. Sie kann als Referenzressource dienen, muss dann aber explizit in die Dateisumme aufgenommen werden.

Die Original-Code-/Lizenzbelege wurden als kleine Textdateien tatsächlich gelesen und gehasht:

| Datei im gepinnten CLIP-Repository | Bytes | SHA-256 |
| --- | ---: | --- |
| `LICENSE` | 1 064 | `987e63b32f6c89ff5160e429458a872ff048e6860b590a3912e938f9da8f14db` |
| `README.md` | 7 306 | `f82c5c75e140532eb37a7d943921e1bdd57d740c6b40d0030985bc5b5d11d6f1` |
| `model-card.md` | 7 733 | `7baf04f60c6234b301ec2c9ca39e67a3ca54b47c05e9509bddf732cbcbec8b7f` |
| `clip/clip.py` | 9 644 | `9540f200fbf8145479fa655382a56dab048d238cc698b9cbd8df3b6d86d3f1b6` |

### Native Eingaben und Konvertierungsroute

**Text:** DistilBERT, sechs Blöcke, Breite 768, zwölf Attention-Heads; `input_ids` und `attention_mask` als Int32 `[1,128]`, keine Segment-IDs. Cased WordPiece mit 119 547 Vokabulareinträgen: kein generelles Lowercasing, keine erfundene Akzentbereinigung. `[CLS]`, `[SEP]`, `[PAD]`, `[UNK]` exakt aus den gepinnten Tokenizerdateien. Inhalt auf höchstens 126 Tokens vor `[CLS]`/`[SEP]` begrenzen. Pooling ist die durch `attention_mask` gewichtete Summe aller gültigen Token-Repräsentationen dividiert durch die Anzahl gültiger Tokens; Spezialtokens mit gesetzter Maske bleiben eingeschlossen. Danach die bereitgestellte Dense-Projektion ohne Bias und ohne Aktivierungsfunktion. Abschließend L2-Normalisierung in Float32 und feste Prüfung auf endliche Werte, Dimension 512 und Norm >0.

**Bild:** Unveränderte CLIP-Visionseite mit visueller Projektion auf 512 Werte. Das [gepinnt dokumentierte Originalpreprocessing](https://github.com/openai/CLIP/blob/d05afc436d78f1c48dc0dbf8e5980a9d471f35f6/clip/clip.py#L79) skaliert die kurze Kante bikubisch auf 224, nimmt den mittigen 224×224-Ausschnitt, wandelt in RGB um und normalisiert Kanalwerte mit Mittelwert `(0.48145466, 0.4578275, 0.40821073)` und Standardabweichung `(0.26862954, 0.26130258, 0.27577711)`. Eingabe ist CHW `[1,3,224,224]`, RGB-Werte zunächst in `[0,1]`. Die Bildmodellkonfiguration des oben gepinnten HF-Repack bestätigt 224 und 512, ohne dass dessen Gewichte bezogen werden müssen. QuickGELU darf bei der Konvertierung nicht still durch ein anderes GELU ersetzt werden.

**App-Rastervertrag:** Originalquelle ohne Reglerwerte über die vorhandene Previewpipeline beziehen, `allowsEmbeddedPreview=false`; bereits angewendete EXIF-Orientierung nicht ein zweites Mal drehen. Farbprofile vor Normalisierung kontrolliert nach kodiertem sRGB RGB konvertieren, nicht ungekennzeichnet Display P3 oder lineares sRGB einspeisen. Der Modellvertrag hat keinen Alpha-Kanal. Ein transparenzspezifischer App-Schritt, etwa weiße sRGB-Matte vor Referenzpreprocessing, muss ausdrücklich versioniert und in Python und Swift gleich ausgeführt werden; er ist keine zugesagte upstream Alpha-Semantik. Digest über das tatsächlich normalisierte Eingaberaster speichern. Resampling und Crop-Rundung mit Referenzfixtures prüfen, insbesondere ungerade Maße und alle acht EXIF-Orientierungen.

**Konverter:** Referenzencoder in PyTorch lokal mit geprüften Dateien laden, `eval()`, Inferenzmodus und feste Shapes. DistilBERT inklusive Pooling und Dense in einem Graph exportieren; originale CLIP-Visionseite separat. Mit `coremltools` in zwei ML-Program-Pakete mit FP16-Gewichten, Float32-I/O und Deploymentziel macOS 14 konvertieren. Der Referenzcode für CLIP muss aus dem gepinnten Commit stammen; keine beliebige ähnlich benannte CLIP-Implementierung laden. Die abgeleiteten Pakete dürften deutlich kleiner als die Quellen sein; konkrete Größen und SHA-256 sind vor Konvertierung unbekannt und dürfen nicht erfunden werden.

**Tokenizer in Swift:** Ein kleiner lokaler BasicTokenizer-/WordPiece-Adapter ist technisch überschaubar, aber noch nicht implementiert oder validiert. Alternativ liefert [HF swift-transformers](https://github.com/huggingface/swift-transformers/blob/e37cacea74498bba66002bb83ecafee3e4ab8884/Sources/Tokenizers/BertTokenizer.swift) eine reale BERT-Tokenizerimplementierung. Der gepinnte Stand `e37cacea74498bba66002bb83ecafee3e4ab8884` deklariert Tools 5.9, macOS 13 und Apache 2.0, bringt jedoch weitere Swift-Paketabhängigkeiten mit. Für PicEdit bevorzugt zunächst den begrenzten lokalen WordPiece-Pfad prüfen. Token-IDs müssen auf DE/EN-Goldenfällen exakt zur Pythonreferenz passen, einschließlich Umlauten, ß, Großschreibung, Satzzeichen, mehrfachen Leerzeichen, zusammengesetzten/dekomponierten Unicodezeichen, unbekannten Wörtern und Trunkierung. Keine automatische HF-Hub-Verbindung im App-Pfad.

## Kandidat B: Google SigLIP 2 Base Patch32 256

### Provenienz, Paarung und Lizenz

Modell: `google/siglip2-base-patch32-256`, Revision `94dffa8cb1179de3e03f091dbc3917e5d5a9ae84`. Die [exakte Google-Modellkarte](https://huggingface.co/google/siglip2-base-patch32-256/blob/94dffa8cb1179de3e03f091dbc3917e5d5a9ae84/README.md) deklariert Apache 2.0. Das ist eine Gewichtedeklaration des konkreten Modells, nicht eine aus dem Familiennamen abgeleitete Lizenz. Referenzimplementierungen sind Googles [big_vision](https://github.com/google-research/big_vision/blob/0127fb6b337ee2a27bf4e54dea79cff176527356/LICENSE), Commit `0127fb6b337ee2a27bf4e54dea79cff176527356`, und HF Transformers 4.51.3, Commit `5f4ecf2d9f867a1255131d2461d75793c0cf1db2`, jeweils Apache 2.0. Hinweise und Änderungen der späteren Konvertierung mitliefern.

Das [Autorenpaper](https://arxiv.org/html/2502.14786v1#S2.SS1) beschreibt gemeinsam trainierte Bild-/Textencoder, die mehrsprachige Gemma-Tokenisierung und 109 Trainingssprachen bei 90 % englischem und 10 % nichtenglischem WebLI-Text. Deutsch/Englisch werden mit derselben Textseite und Bildseite kodiert. Diese Belege zeigen die Paarung und Mehrsprachigkeit, keine erreichte PicEdit-Recallquote. Beide Türme liefern hier 768 Werte. Keine CLIP-, ST- oder fremde Textseite an diesen Bildencoder anschließen.

### Quellmanifest und Größenentscheidung

HF-Dateibasis: `https://huggingface.co/google/siglip2-base-patch32-256/resolve/94dffa8cb1179de3e03f091dbc3917e5d5a9ae84/`.

| Datei | Bytes | Veröffentlichte Prüfsumme |
| --- | ---: | --- |
| `model.safetensors` | 1 507 473 288 | `SHA-256: 7d241bb3becad218f211f480487f491df4f8c0a472ecf7afdec5615815a301f1` |
| `config.json` | 298 | `Git-Blob-SHA-1: 0ee4ecf4f0d59ccba70b5ddc66da7cc61a294309` |
| `preprocessor_config.json` | 394 | `Git-Blob-SHA-1: 130986149eee6a6fd9a2eb53da12fbc1a415c0e6` |
| `special_tokens_map.json` | 636 | `Git-Blob-SHA-1: 8d6368f7e735fbe4781bf6e956b7c6ad0586df80` |
| `tokenizer.model` | 4 241 003 | `SHA-256: 61a7b147390c64585d6c3543dd6fc636906c9af3865a5548f27f31aee1d4c8e2` |
| `tokenizer_config.json` | 47 164 | `Git-Blob-SHA-1: d97c5412159422c3b56fbc99076b1dcc25dd7856` |
| `README.md` | 3 375 | `Git-Blob-SHA-1: 09073837b4ad23e2cd45caedeae665b031cf5f71` |

Summe dieser vorgesehenen Route mit dem originalen SentencePiece-Modell: 1 511 766 158 Bytes. Die alternative HF-Fast-Tokenizerdatei `tokenizer.json` ist **34 363 039 Bytes**, SHA-256 `cb9140fae3ac5122c972d37adf83e1248471a38147ad76f8215c8872c6fd8322`. Sie wird anstelle, nicht gedankenlos zusätzlich zum SentencePiece-Modell in ein alternatives Laufzeitmanifest aufgenommen. Referenzprüfungen können beide benötigen; deren zusätzlichen Entwicklerbedarf getrennt ausweisen.

Das originale FP32-Checkpoint bleibt über dem Startbudget. Vorgeschlagen ist, auf einer ausdrücklich gewählten Entwicklerroute nur die beiden benötigten Encoder in FP16-Core-ML-Pakete zu konvertieren. Die Gewichtenbytes könnten sich näherungsweise halbieren; zusammen mit dem 4,24-MB-Tokenizer wären etwa 0,76 GB plausibel. Das ist eine Planungsschätzung. Dateisystemgröße des gesamten erzeugten Pakets, Metadaten und Tokenizer sind anschließend tatsächlich zu summieren und zu hashen. Ohne vorhandene abgeleitete Artefakte ist derzeit kein vollständiges ≤1-GiB-Downloadmanifest verfügbar.

### Native Route und notwendige Paritätsprüfung

Die konkrete Konfiguration hat `model_type=siglip`, also den festen SigLIP-Encoderpfad, nicht die NaFlex-Variante. Bildgröße 256×256, Patchgröße 32, Textlänge 64. Textvorverarbeitung ist lowercase mit dem gepinnten Gemma-Tokenizer, kein BERT-WordPiece und keine Übersetzung. Kein BOS, EOS hinzufügen und auf die tatsächlich trainierte Länge 64 auffüllen; die gigantische allgemeine `model_max_length`-Zahl in der Tokenizerkonfiguration darf nicht als erlaubte Kontextlänge verwendet werden. Die [Referenzdokumentation](https://huggingface.co/docs/transformers/model_doc/siglip#notes) verlangt Padding auf die maximale Länge. EOS-/Pad-IDs und endgültiges Pooling durch Goldenwerte aus genau der gepinnten Referenz bestimmen, nicht aus CLIP-Konventionen übernehmen.

Das gepinnte Bildpreprocessing skaliert mit bilinearer Interpolation (`resample=2`) direkt auf 256×256, `rescale=1/255`, Mittelwert und Standardabweichung je Kanal 0,5. Das ist ein anderer Geometrievertrag als CLIPs Center-Crop. Für Bildorientierung, sRGB und Alpha gilt der oben explizite App-Rastervertrag; die Pythonreferenz muss denselben App-Schritt erhalten. Nicht das CLIP-Preprocessing unverändert wiederverwenden.

Native Laufzeit: beide Encoder über `MLModel`, zunächst feste Tensorformen `[1,3,256,256]` und `[1,64]`, zwei getrennte Pakete, Float32-Ergebnisse und L2-Normalisierung auf beiden Seiten. `get_image_features` und `get_text_features` der gepinnten Referenz samt Pooling/Projektion abbilden. Der skalierte Sigmoid-Logit ist kein kalibrierter Suchwahrscheinlichkeitswert; Ranking nutzt konsistent normalisierte Vektoren.

Für Tokenisierung ist ein schmaler C++-/Swift-Wrapper um [SentencePiece](https://github.com/google/sentencepiece) eine reale lokale Route; dessen Code ist [Apache 2.0](https://github.com/google/sentencepiece/blob/master/LICENSE). Für den Versuch SentencePiece **v0.2.0**, Commit `17d7580d6407802f85855d2cc9190634e2c95624`, pinnen; vor Übernahme gebündelte Drittbibliotheken samt ihren Hinweisen erfassen. Im aktuellen PATH wurde kein CMake gefunden; entweder einen kontrollierten Entwickler-Buildweg bereitstellen oder die minimalen Inferenzquellen gezielt in ein natives Buildtarget integrieren. Das Modell enthält Normalisierung und Vokabular. Swift- oder C++-Tokenisierung ist dennoch gegen den HF-Gemma-Pfad zu prüfen, einschließlich Lowercasing, EOS und Padding. Alternativ den 34,36-MB-JSON-Tokenizer mit einem explizit geprüften nativen Enginepfad verwenden. Unterstützung für diese konkrete Gemma-Konfiguration ist hier noch nicht nachgewiesen.

## Tatsächliche Laufzeitvoraussetzungen

Die vorangegangene Gerätekontrolle dokumentiert Apple M2 Pro mit 16 GB RAM und macOS 27.0.1. Aktuell erneut geprüft: Swift 6.4, System-Python 3.15.0 und gebündeltes Python 3.12.14. System-Python hat weder torch, coremltools, transformers, tokenizers, numpy noch Pillow. Das gebündelte Python hat numpy/Pillow, aber kein torch, coremltools, transformers oder tokenizers. Eine funktionsfähige Modellkonvertierungsumgebung existiert damit noch nicht.

Für den nächsten Versuch ein getrenntes Python-3.12-Venv verwenden und einen Lock mit konkreten Wheels und Hashes erzeugen. Ein nachvollziehbarer Ausgangspunkt ist `coremltools==8.3` (Commit `07ffd86005e385d8eddfd22072836cfb457f7350`) plus `torch==2.5.0`, passende torchvision 0.20.0, Transformers 4.51.3 und safetensors; Tokenizer-/NumPy-/Pillow-/SentencePiece-Versionen und transitive Abhängigkeiten ebenfalls festhalten. Die [coremltools-8.3-Abhängigkeitsprüfung](https://github.com/apple/coremltools/blob/07ffd86005e385d8eddfd22072836cfb457f7350/coremltools/_deps/__init__.py#L143) nennt PyTorch 2.5.0 als getestete Obergrenze. Diese Kombination wurde hier noch nicht installiert oder als konvertierungstauglich bestätigt. Konvertercode ist BSD-3-Clause; Referenzframework und Tokenizer bringen ihre eigenen Lizenzen mit.

`xcrun --find coremlcompiler` schlägt in der aktuellen CLT-Installation fehl. Das ist kein bewiesenes Core-ML-No-Go: macOS bietet [MLModel.compileModel(at:)](https://developer.apple.com/documentation/coreml/mlmodel/compilemodel(at:)) für eine native Kompilierungsroute, die noch praktisch zu prüfen ist. Volles Xcode kann ein alternativer Entwicklerweg sein. PicEdit selbst kann auf macOS 14 bleiben und Core ML aus dem Systemframework verwenden; Python ist ein Konvertierungs-/Referenzwerkzeug, keine geplante App-Abhängigkeit.

Auf Apple Silicon `computeUnits=.all` zulassen und Core ML selbst wählen lassen. Einen `cpuOnly`-Pfad separat auf Funktionsgleichheit, Ladeverhalten und akzeptable Qualität prüfen. Intel/macOS 14 nicht durch die aktuelle M2-Pro-Konfiguration als getestet ausgeben. Falls der konkrete Graph keinen nutzbaren CPU-Pfad bietet, verständliche Nichtverfügbarkeit anzeigen. Ein paralleler zweiter CPU-Encoder ist kein Fallbackplan.

## Prüfsummenstatus und Installation

Die oben genannten LFS-SHA-256 stammen aus der öffentlichen Hub-Metadatenantwort, nicht aus hier geladenen Gewichtedateien. Git-Blob-SHA-1 ist ausdrücklich ein Git-Objektdigest über Header plus Dateikörper und **kein** rohes Dateibody-SHA-256. Die unveränderliche Revision, Größe und dieser Digest pinnen die kleinen Git-Dateien; ein späteres Downloadwerkzeug muss das Format korrekt behandeln.

Vor einem produktiven Installationsmanifest sämtliche tatsächlich verteilten Dateien mit rohem SHA-256 und genauer Bytegröße festhalten, einschließlich konvertierter Modellpakete, Tokenizer, Lizenz-/Attributionsdateien und Vorverarbeitungsmetadaten. Zusammengesetzte Pakete über eine kanonisch sortierte Dateiliste prüfen; keine bloßen `main`-URLs oder unkontrollierten Manifestpfade akzeptieren. Atomic Download in temporäres Ziel, erwartete Größe und Prüfsumme vor Laden verifizieren, dann atomar veröffentlichen. Kein App-Download aus dieser Vorbereitungsnotiz.

Die Rohmetadaten sind unter `/private/tmp/picedit-semantic-text-metadata.json`, `/private/tmp/picedit-semantic-image-metadata.json` und `/private/tmp/picedit-semantic-siglip-metadata.json` erhalten. Sie wurden von den primären öffentlichen HF-API-Endpunkten mit `blobs=true` abgerufen. Modellgewichte blieben unangetastet.

## Ausführbarer nächster Gateplan nach Root-Entscheidung

1. Zuerst die offene Gewichten-Lizenzzuordnung von Kandidat A entscheiden. Falls belegt, seine 854-MiB-Quellroute bevorzugen; ansonsten Kandidat B ausschließlich als Konvertierungsversuch mit dokumentierter größerer Entwicklerquelle und strikt gemessenem späterem Laufzeitpaket wählen. Ohne erfüllte Lizenzbedingung keine Gewichte weiterverteilen.
2. Vor Gewichten und Inferenz 30 eindeutig für die Prüfung erzeugte synthetische Motive, mindestens 20 festgeschriebene deutsche/englische Querypaare und fünf negative Queries erstellen. Relevante Asset-IDs und Bild-/Query-Digests vor der ersten Messung einfrieren. Keine Klassennamen aus Dateinamen oder Metadaten einspeisen. Bei Fehlmessungen keine stillen nachträglichen Ground-Truth-Anpassungen.
3. Separates Venv/Lock, geprüfter atomarer Gewichtenbezug und Konverterskript erstellen. Native Tokenisierung zuerst exakt gegen Referenz-Token-IDs prüfen. FP32-Referenzvektoren für beide Encoder sichern; Core-ML-FP16-Abweichungen und Cosinusabweichungen mit einer vorab festgelegten Toleranz messen. CPU- und automatische Core-ML-Ausführung getrennt prüfen.
4. Verteilte Artefakte nach Konvertierung vollständig hashen und summieren. Stoppen, wenn das gemeinsame Laufzeitpaket >1 GiB ist; keine Modellhälfte oder der Tokenizer aus der Summe weglassen. Verschiedene Konverter-/Tokenizer-/Vorverarbeitungsversionen erzeugen unterschiedliche Indexgenerationen.
5. Erst danach Retrieval messen: mindestens 80 % der Queries mit relevantem Treffer unter Top-5 und höchstens zehn Prozentpunkte DE/EN-Differenz. Treffer, Ränge, Rohscores und Fehlerfälle pro Query sichern. Die fünf negativen Queries unverändert berichten; aus deren Scores keine universelle Wahrscheinlichkeitsschwelle ableiten.
6. Kalt-/warme Ladezeit, Bildindizierung pro Sekunde, Textencoding, linearen Vektorvergleich und Querycache getrennt messen. Bei 10 000 vorab synthetisch erzeugten und normalisierten Vektoren p50/p95 für reine Suche und vollständige warme Query ausweisen. Zusätzlichen Peak-RSS gegenüber dokumentiertem App-Baselinewert messen; Ziel ≤1,5 GiB und warme Query-p95 ≤500 ms. Das sind Ziele, keine jetzigen Ergebnisse. Messläufe seriell und ohne konkurrierende Modell-/GPU-Arbeit ausführen.
7. Erst bei bestandenem oder ausdrücklich neu begründetem Gate reale semantische Suche freischalten. Die wörtliche Suche bleibt Standard. Fakevektoren bleiben Tests vorbehalten. Bei Scheitern ist die reale Fähigkeit mit dem konkreten Grund nicht verfügbar; kein Cloudersatz und keine erfundenen Treffer aus Metadaten.

Nicht abgedeckt sind bisher echte Qualität, Performance, RAM, Konvertierbarkeit, native Tokenizerparität und große Kamera-RAWs. Keine privaten Bibliotheken wurden geöffnet. Diese offenen Punkte gehören in den späteren Issue-/PR-Abschlussbericht.
