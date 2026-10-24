# SegNext-HQ: interaktive Objektmasken — Issue #182

**Entscheidung am 24. Oktober 2026: No-Go für eine Produktintegration.** Ein
reproduzierbarer lokaler Evaluationsadapter und seine Vertragsprüfungen liegen
vor. Es gibt keine Modellmessung, keine qualifizierte native macOS-Route und
keinen eingefrorenen Satz aus zwölf lizenzierten Fotos mit unabhängig
kontrollierter binärer Ground Truth. Fehlende Fotobelege werden nicht durch
synthetische Maskentests ersetzt. BiRefNet, die bisherigen SAM-Entscheidungen,
gespeicherte Masken, Bedienung und Export bleiben unverändert.

Die [Quellprüfung](dtai-evaluation/source-audit.json) verifiziert tatsächlich den
lokalen darktable-ai-Checkout auf
`76513a1e379b4265007bae768825b9a581944ff8`, inklusive SHA-256 von Modellkarte,
Definition, Konverter, Demo und Referenz-Iterationsprotokoll. Der SegNext-Gitlink
ist `db045f6d6bab73029457e2ced4fec4a92cc69600`; der Vendor ist nicht
initialisiert. Checkpoint und Encoder-/Decoder-ONNX-Dateien fehlen an den
festgelegten Pipelinepfaden. Für sie existiert deshalb ausdrücklich kein
behaupteter SHA-256 oder Konvertierungs-/Core-ML-Paritätsbeleg. Die neue
Implementierung übernimmt weder Pipeline- noch Modellcode.

[Modellkarte](https://github.com/darktable-org/darktable-ai/blob/76513a1e379b4265007bae768825b9a581944ff8/models/mask-object-segnext-b2hq/README.md)
und Definition nennen MIT für Modell/Trainingcode. Das ist dokumentierte
Upstream-Angabe, keine pauschale Freigabe der konkreten Gewichtsdatei oder ihrer
Trainingsdaten. COCO/LVIS werden mit CC BY 4.0 geführt, HQSeg-44K mit gemischten
Einzelbedingungen. Ohne deren Prüfung und getrennte Herkunfts-/Attributionsbelege
für erworbene Gewichte bleibt auch diese Zulassung offen. Die GPL-3.0-lizenzierte
darktable-ai-Pipeline wurde nur als Quelle gelesen.

Der [ausführbare Adapter](../tools/dtai-evaluation/README.md) nimmt eine vorhandene
entwickelte FP32-SDR-sRGB-Bildbasis entgegen und führt keine RAW-Decodierung aus.
Sein versionierter Geometrievertrag bildet Original, alle EXIF-Orientierungen,
orientierten Ausschnitt, Vierteldrehungen, Vorschau und 1024er Promptframe ab.
Pixelmarker-, Rückprojektions-, Crop- und Besitztests verhindern, dass positive
oder negative Punkte auf eine andere Quelle/Präparation weiterwirken. Freie
Rotationswinkel und subpixelige Rasterausschnitte sind noch nicht qualifiziert.
Float-Lanczos statt des uint8-Resizers der Referenz ist ausdrücklich ein eigener,
noch nicht paritätsgeprüfter Vorbereitungspfad.

Der Tensorvertrag entspricht dem gelesenen
[Konverter](https://github.com/darktable-org/darktable-ai/blob/76513a1e379b4265007bae768825b9a581944ff8/models/mask-object-segnext-b2hq/convert.py):
Encoder RGB FP32 `[1,3,1024,1024]` in [0,1], Normalisierung im Encoder,
Merkmale `[1,768,64,64]`; Decoder Merkmale, `(x,y)`-Koordinaten `[1,N,2]`,
Labels `[1,N]` und `prev_mask [1,1,1024,1024]`; Ausgabe sind Logits.
Der begrenzte Encoder-LRU verwendet Quell-/Präparationsidentität,
Tensorhash und beide Modellhashes. Korrekturen verwenden die Merkmale wieder.
Die [Iteration](https://github.com/darktable-org/darktable-ai/blob/76513a1e379b4265007bae768825b9a581944ff8/darktable_ai/evaluation/mask.py)
führt binäre Float32-0/1-Masken zurück. Logits, fraktionale BiRefNet-Startmatten,
fremde Quellen und geänderte Klickpräfixe werden als Feedback abgewiesen.
Die Rückprojektion folgt `Logit > 0 -> uint8-Lanczos -> >127`; separate
Vorschlagsdateien ändern keine übernommene Rastermaske oder Undo-Historie.

Vor einer ersten Modellmessung fehlen weiterhin die zwölf offen lizenzierten
Fotos samt Rechtebelegen, Bild-/Maskenhashes, Startmasken, unabhängig bestätigter
binärer GT und fester Klickfolge (höchstens zehn Korrekturen). Ein eigener
Entwicklungssatz muss getrennt bleiben. Der implementierte diagnostische
Gate-Rechner veröffentlicht Einzel-IoUs, NoC@85, Nichterreichen und den auf elf
begrenzten Mittelwert. Die vorgeschlagenen Grenzen aus dem Issue bleiben
unverändert: zehn von zwölf Fällen bei ≥0,85 innerhalb fünf Klicks, mittlere
finale Verbesserung ≥0,05 und native/Referenz-Endmasken-IoU ≥0,99. Schon passende
Zahlen ergeben nur `quality-pass-unqualified`; ohne belegte Daten und native
Ausführung entsteht kein Go. Es werden keine Messwerte behauptet.

Eine spätere qualifizierte Integration benötigt außerdem Encoder-, erste/warme
Decoderzeit und Peak-RSS auf benanntem Mac, vorab festgelegte Ressourcenbudgets
sowie App-Prüfungen für Cacheverdrängung, Speicherdruck, schnelle Klicks,
Abbruch und Bildwechsel. Der synchrone lokale CPU-Referenzadapter hält die
Inferenz bis zur Rückkehr und verwirft abgebrochene Ergebnisse. Er ersetzt nicht
die gemeinsame `AIResourceBudget`-Zulassung der App. Die Entscheidung für
Core ML oder eine andere Runtime und CPU/GPU ist damit weiter offen. Binäre
Segmentierung belegt keine Alpha-Deckung von Haaren, Glas oder weichen Rändern.

Verifikation: Die gemeinsame Suite umfasst 40 erfolgreiche Vertrags-/Adaptertests
mit NumPy/Pillow, ohne Gewichte oder private Fotos. Der Source-Audit beendet sich
absichtlich mit Status 2 (Forschungs-No-Go). Diese Tool-/Dokumentationsänderung
wirkt nicht auf App-Kompilierung, Paketierung oder Laufzeit; für diesen Teil ist
kein neuer App-Build erforderlich. Der gesamte Aufgabenbranch wird separat
integriert geprüft.
