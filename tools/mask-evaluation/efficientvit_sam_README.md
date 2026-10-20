# Offizieller EfficientViT-SAM-L1-Vergleich

`efficientvit_sam.py` ist ein separates Prüfwerkzeug. Es verwendet den unveränderten
offiziellen `EfficientViTSamPredictor`, einen über Hugging Face Hub geladenen
L1-Checkpoint und manuelle Punkt-/Boxprompts. Es gehört nicht zur App.

## Quellen und feste Versionen

| Bestandteil | Version / Integrität |
|---|---|
| [EfficientViT-SAM-Referenz vor DC-AE](https://github.com/mit-han-lab/efficientvit/tree/e81ebbe761b2c75fc99b7827cb7dbd30a76c0ace) | `e81ebbe761b2c75fc99b7827cb7dbd30a76c0ace`, 15.10.2024 |
| EfficientViT-Quellarchiv | SHA-256 `0e45211a243cb342a2156f7da0d3b1e07f98dbd9c6761f1b40fda313a3a76636` |
| [SAM-Abhängigkeit](https://github.com/facebookresearch/segment-anything/tree/dca509fe793f601edb92606367a655c15ac00fdf) | `dca509fe793f601edb92606367a655c15ac00fdf` |
| SAM-Quellarchiv | SHA-256 `b693c2358e9e1c63589a322b1baa6a6dc384df0013ff455d933d9a8e23549dab` |
| [Offizielles HF-Modell](https://huggingface.co/mit-han-lab/efficientvit-sam/tree/a2f0c5929196a13ef1ffc9338d3f9e482e1e0e68) | `a2f0c5929196a13ef1ffc9338d3f9e482e1e0e68`, Apache-2.0 |
| `efficientvit_sam_l1.pt` | 190.916.834 Bytes; SHA-256 `fa151df2b9b96896accd505470755cdd293a4c50cdabac95478f3fbd86d9152b` |

L1 ist die offizielle klassische SAM-Variante mit 512-Pixel-Bildencoder. Eine
Version namens „EfficientViT-SAM 3.1“ wird hier nicht behauptet. Das Referenzrepo
wird laut seiner letzten README-Aktualisierung seit September 2025 nicht weiter
gepflegt. Der aktuelle Quellstand `de7d7733cc0329f391b33f1f459271562ec27bd5`
scheitert auf diesem Mac bereits beim Import am unbedingten CUDA/Triton-Import
der später ergänzten DC-AE-RMSNorm. Deshalb verwendet der Test den oben gepinnten
unveränderten offiziellen SAM-Stand vor dieser Erweiterung. Dessen Factory heißt
`create_sam_model("l1", pretrained=False)` und setzt Norm-Epsilon auf `1e-6`.
Es werden keine CUDA-Stubs oder Predictor-Patches eingeführt. Die aktuellen
Laufzeitbibliotheken und der ältere offizielle Quellstand werden getrennt erfasst.

Hugging Face stellt für diese Veröffentlichung Gewichte und ONNX-Dateien bereit;
ein Transformers-`AutoModel`-Vertrag mit `config.json` fehlt. Die geprüfte aktuelle
Ultralytics-SAM-Registry bietet keinen EfficientViT-SAM-Builder. Dieser Test
verwendet `huggingface_hub.hf_hub_download` für den Download und den offiziellen
MIT-Predictor für die Inferenz. Quelle für die SAM-Registry:
[Ultralytics build.py](https://github.com/ultralytics/ultralytics/blob/main/ultralytics/models/sam/build.py).

## Isolierte Umgebung

Die geprüfte Umgebung verwendet CPython 3.11 auf macOS ARM64. Keine globalen
Pakete werden verändert. PyTorch 2.14.1 / torchvision 0.29.1 besitzen passende
macOS-14+-ARM64-Wheels. Hugging Face Hub 2.2.0 übernimmt den Gewichtsdownload.
Die vollständigen tatsächlich installierten Versionen werden mit `pip freeze`
bei den privaten Messergebnissen gesichert.

```sh
python3.11 -m venv /private/tmp/picedit-efficientvit-sam-evaluation-20261020/venv
/private/tmp/picedit-efficientvit-sam-evaluation-20261020/venv/bin/python -m pip install torch==2.14.1 torchvision==0.29.1 huggingface-hub==2.2.0 numpy==2.4.6 pillow==13.0.0 omegaconf==2.4.0 timm==1.0.30 einops==0.8.2 opencv-python-headless==5.0.0.93 tqdm==4.70.1 scipy==1.17.1 torchprofile==0.1.0
/private/tmp/picedit-efficientvit-sam-evaluation-20261020/venv/bin/python -m pip install onnx==1.23.2 onnxsim==0.8.1 torchmetrics==1.9.0 torchdiffeq==0.2.5 torch-fidelity==0.4.0 matplotlib==3.11.2
```

Die offiziellen Quellarchive müssen unter `sources/efficientvit` und
`sources/segment-anything` innerhalb dieser Messwurzel ausgepackt sein. Nur die
oberen Archivverzeichnisse entfernen; die Python-Paketstruktur erhalten. Quellen:

- `https://codeload.github.com/mit-han-lab/efficientvit/tar.gz/e81ebbe761b2c75fc99b7827cb7dbd30a76c0ace`
- `https://codeload.github.com/facebookresearch/segment-anything/tar.gz/dca509fe793f601edb92606367a655c15ac00fdf`

Der Harness prüft die oben genannten Archivhashes und vergleicht anschließend
jede Python-Quelldatei der beiden importierten Upstream-Pakete mit dem verifizierten
Archiv. Abweichende oder zusätzlich eingefügte Python-Dateien verhindern den Lauf.
Keine Upstreamdatei muss für die Inferenz verändert werden. Die Paketliste enthält die benötigten
Inferenzimporte; einige ONNX- und Trainingsbibliotheken werden wegen der breiten
Upstream-Modulimporte benötigt, obwohl dieser Test weder exportiert noch trainiert.
CUDA-, TensorRT- und Webdemo-Abhängigkeiten werden nicht eingebunden.

## Download und Ausführung

```sh
env HF_HUB_DISABLE_TELEMETRY=1 HF_HOME=/private/tmp/picedit-efficientvit-sam-evaluation-20261020/hf-home /private/tmp/picedit-efficientvit-sam-evaluation-20261020/venv/bin/python tools/mask-evaluation/efficientvit_sam.py download /private/tmp/picedit-efficientvit-sam-evaluation-20261020

env PYTORCH_ENABLE_MPS_FALLBACK=0 HF_HUB_DISABLE_TELEMETRY=1 MPLCONFIGDIR=/private/tmp/picedit-efficientvit-sam-evaluation-20261020/mpl /private/tmp/picedit-efficientvit-sam-evaluation-20261020/venv/bin/python tools/mask-evaluation/efficientvit_sam.py run /private/tmp/picedit-efficientvit-sam-evaluation-20261020 /private/tmp/picedit-efficientvit-sam-evaluation-20261020/prompts.json /private/tmp/picedit-efficientvit-sam-evaluation-20261020/results-mps --device mps
```

Für explizite CPU-Prüfungen `--device cpu` und einen eigenen Ausgabeordner nutzen.
`--only test_picture6` beschränkt eine Vergleichsprobe auf das Fuchsbild.
MPS-Ausführungen benötigen Zugriff auf Metal außerhalb einer einschränkenden
Sandbox. Der Harness verlangt `PYTORCH_ENABLE_MPS_FALLBACK=0` vor dem Torch-Import;
fehlende Operationen werden damit sichtbar, ohne einen stillen CPU-Fallback.
CPU und MPS werden niemals als gleichzeitige Benchmarkprozesse gestartet.

Der Checkpoint wird vor dem Aufbau erneut geprüft, mit
`torch.load(..., weights_only=True, map_location="cpu")` gelesen und mit
`load_state_dict(..., strict=True)` übernommen. Beide Geräte verwenden Float32,
keinen Autocast und begrenzte CPU-Parallelität (vier Intraop-, ein Interop-Thread).

## Geometrie und Messwerte

- Fertige, bereits orientierte sRGB-Proxies werden unverändert eingelesen.
- Der offizielle Bildpfad erhält das Seitenverhältnis, verkleinert die längste
  Kante auf 512, normalisiert mit ImageNet-Werten und füllt rechts/unten auf 512².
- Der Promptframe hat weiterhin die längste Kante 1024 mit eigener Rundung. Punkte
  und Boxen werden aus normalisierten Testannotationen zunächst in Pixel des
  Originalproxies umgerechnet. Der offizielle Predictor skaliert sie weiter.
- `predict(..., multimask_output=True, return_logits=True)` wird unverändert
  aufgerufen. Der Kandidat mit dem höchsten modellinternen Score wird ausgewählt.
  Diese Scores sind keine geprüften Qualitätswerte gegenüber Ground Truth.
- Die offizielle Wiederherstellung interpoliert zunächst auf 1024², entfernt die
  Paddingfläche anhand des 1024-Promptframes und interpoliert zur Quellgeometrie.
  Der Schwellwert null erzeugt die binäre Segmentierung; dies ist keine Alphamatte.
- Zwei gleiche Promptläufe nutzen denselben Bildfeaturecache. `mask_input` wird
  nicht zur Verfeinerung verwendet. Der optionale erneute Encoderlauf des ersten
  Bildes ist eine getrennt erfasste Probe auf Featurestabilität.
- Vor und nach jedem gemessenen Modul synchronisieren Forward-Hooks MPS.
  `encoderKernelSeconds`, `promptEncoderKernelSeconds` und
  `maskDecoderKernelSeconds` beschreiben diese Modulphasen.
  `setImageSeconds` enthält zusätzlich die offizielle Vorverarbeitung und den
  Transfer. `predictSeconds` enthält Promptbehandlung, Modulphasen, Wiederherstellung
  der Quellauflösung und NumPy-Transfer zur CPU; es ist keine reine Decoderzeit.
- `imageRequestToFirstValidatedMaskSeconds` enthält Decode, `set_image` und den
  ersten validierten Promptlauf, bei der ersten Probe gegebenenfalls auch den
  zusätzlichen Encoderlauf. Datei-Export steht separat in `exportSeconds`.
- OS- und MPS-Caches werden nicht geleert. Erstgebrauch ist kein kontrollierter
  Kaltstart. Prozess-Peak-RSS erfasst GPU-/Treiberanteile nur teilweise;
  MPS-Driver-Allocations werden nur an benannten Punkten abgetastet.

Pro Bild entstehen `target-mask.png` in Quellgeometrie, native 256²-Logits als
`target-native-logits.npy` und `target-logits.f32` (Little Endian Float32), sowie
`benchmark.json`. Der Gesamtreport enthält Versionen, Pins, Phasen, Wiederholungs-
und Speicherwerte. Alle Fotos und daraus abgeleiteten Ergebnisse bleiben lokal
und werden nicht committed oder hochgeladen.
