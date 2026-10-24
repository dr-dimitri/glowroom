# RawNIND: RAW-Entrauschung als Machbarkeitsstudie — Issue #187

**Entscheidung am 24. Oktober 2026: No-Go für beide Produktvarianten.** Die
Bayer- und lineare Variante besitzen explizite, lokal ausführbare
Tensor-/Sensormetadaten-/Kachel-/Gainverträge. Es fehlt bereits ein qualifizierter
nativer Eingabeprovider; Modell-/RAW-Referenzbelege fehlen ebenfalls. Diese
Studie baut keinen neuen RAW-Entwickler und ändert weder Originale noch
vorhandene Entwicklung oder gespeicherte Einstellungen.

`PreviewDecoder` liest mit ImageIO ein entwickeltes `CGImage` und gegebenenfalls
eine eingebettete Vorschau. `EditRenderer` arbeitet mit extended linear sRGB.
Beide liefern weder schwarze/weiße Sensorpegel noch kontrollierte aktive
Sensordaten oder nachgewiesen lineares Rec.2020 vor Tonwerten/Clipping.
Eine Umrechnung dieses entwickelten Rasters nach Rec.2020 rekonstruiert diese
Information nicht. Ein zusätzlicher nativer Decoder müsste Kamerasupport,
Sensormetadaten, Orientierung, Crop, linearen Entwicklungszustand und Lizenz
nachweisen. Es gibt keinen belastbaren bereits vorhandenen Zugriff, auf den der
Adapter eine Produktfreigabe stützen könnte.

Die [geprüfte Modellkarte](https://github.com/darktable-org/darktable-ai/blob/76513a1e379b4265007bae768825b9a581944ff8/models/rawdenoise-nind/README.md)
und [Source-Audit](dtai-evaluation/source-audit.json) beziehen sich auf
darktable-ai `76513a1e379b4265007bae768825b9a581944ff8`, Vendor-Gitlink
`4d455aa8ada69214eafa6a91ac0b2e011cf9dcb7`. Der Vendor ist nicht
initialisiert, beide Checkpoints/ONNX-Dateien fehlen an den festgelegten Pfaden.
Konverter-/Karten-/YAML-/Demo-SHA-256 sind eingefroren; Gewichts-/Exporthashes
und tatsächlich ausgeführte Konvertierungswerkzeuge fehlen und werden nicht
erfunden. Upstream nennt GPL-3.0 und akademischen Stand; die dokumentierte
Trainingsdatenherkunft nennt RawNIND/Wikimedia mit CC BY 4.0/CC0 je Bild.
Konkrete Gewichts-/Quellcode-/Datenrechte und der Integrationsmodus müssen
getrennt vor einer Produktentscheidung geprüft werden. Der neue Code ist
eigenständig; die GPL-Pipeline wird weder kopiert noch importiert.

Die Quellenabweichung ist reproduziert: README nennt einen `cpu_only`-Schutz
für Bayer auf Core ML wegen FP16-NaN/Inf auf Apple GPU/ANE; die gepinnte
[model.yaml](https://github.com/darktable-org/darktable-ai/blob/76513a1e379b4265007bae768825b9a581944ff8/models/rawdenoise-nind/model.yaml)
enthält keinen solchen Block. Der Audit meldet beide Tatsachen. Der
Forschungsadapter lässt ausschließlich ONNX CPU FP32 zu; ein GPU-/ANE-/Core-ML-
Pfad wird damit nicht als sicher behauptet. FP16-Überläufe wurden ohne Modell
nicht reproduziert oder ausgeschlossen. Endliche Outputs allein beweisen keine
endlichen nativen Zwischentensoren.

| Variante | Expliziter Forschungsinput | Output | Produktentscheidung und Voraussetzung |
| --- | --- | --- | --- |
| Bayer | FP32 `[1,4,H,W]`, gepackt `[R,G1,G2,B]`, Tiles 512² | Camera-RGB `[1,3,2H,2W]` plus Gain-Match | No-Go: nativer Sensor-/Metadatenprovider, Kamera-/RAW-GT und CPU-Parität fehlen |
| Linear | FP32 `[1,3,H,W]`, lineares Rec.2020, Tiles 512² | lineares Rec.2020 gleicher Ausdehnung plus Gain-Match | No-Go: kontrollierter pre-tone/pre-clipping Rec.2020-Provider und native/RAW-Parität fehlen |

Bayer verdoppelt das gepackte Halbauflösungsraster auf Sensorgröße; dies ist
keine Super-Resolution-Funktion. `pack_bayer` verlangt explizit unrotiertes RGGB
mit unterscheidbaren G1/G2-Phasen, vier Schwarz-/Weißpegelpaaren und einer geraden
aktiven Sensorfläche mit geradem Ursprung. Ungerade/verschobene CFA-Flächen,
andere Phasen, EXIF-Drehungen und unbekannte Sensoren werden abgelehnt.
Sensorwerte werden pro Phase nach [0,1] normalisiert/geclippt; Sättigungs- und
Belichtungsmetadaten muss der künftige Decoder zusätzlich erhalten. Es gibt
kein stilles Weißabgleich-Normalisieren. Weißabgleichsbezug und Gain des
Eingangs müssen zum trainierten Modell qualifiziert werden. X-Trans und Foveon
sind durch die generische Demo-Verzweigung ausdrücklich nicht freigegeben.

Der [lokale Adapter](../tools/dtai-evaluation/README.md) prüft Modellhash,
Konvertierungsreceipt und statische FP32-Tensoren. 512er Kacheln mit 64 Pixel
Spiegelhalo schreiben die vollständige Ausgabe ohne Mod-16-Crop oder verlorene
Sensorzeilen. Der Bayer-Output braucht eine ausdrücklich gerichtete,
endliche/nichtsinguläre Camera-RGB→XYZ-D65-Matrix; anschließend erfolgt die
Rec.2020-Umrechnung. Die Richtung einer Kameramatrix wird nicht geraten.
Beide Varianten matchen den Outputmittelwert gegen den Eingabemittelwert,
nicht gegen eine saubere Ground Truth. Nichtpositive/degenerierte oder
nichtendliche Mittelwerte führen zum Fehler. Das ist bewusst strenger als die
Vorzeichenumkehr der Upstream-Demo: Negative physische Lichtwerte dürfen nicht
durch einen negativen Gain in scheinbar gültige RAW-Ausgabe umgewandelt werden.
Output wird nicht nachträglich geclippt oder gegen GT belichtet,
um Modellfehler zu verdecken. Vollständiger Bildpuffer plus ein begrenztes Tile
wird vorab abgeschätzt; das ersetzt keine Peak-RSS-Messung.

Die nächsten notwendigen Belege sind getrennt je Variante: kontrollierte
Referenz-RAW-/Clean-Paare mit Sensorfläche/CFA/Orientierung/Schwarz-/Weißpegeln,
Weißabgleich, Kameramatrix, Gain-/Belichtungsbezug und Sättigungsbehandlung;
CPU-Original-/ONNX-/nativer Vergleich; dunkle/gesättigte Flächen, Farbtafel und
feine Strukturen; Gain, Farbe, Padding, Überlappung und unverlorene Zeilen;
kalte/warme Latenz, Peak-RSS sowie RAW-Vorschau-/Exportkonsistenz. Native
GPU/ANE-Messung bleibt von CPU getrennt und benötigt konkrete FP16-/Endlichkeits-
prüfung. Der Integrationsaufwand umfasst einen zusätzlichen fachlich und
lizenzrechtlich geprüften Decoder samt Metadatenprovider, Render-/Export-
Verknüpfung, Ressourcenkoordination und kamerabezogene Validierung. Ohne diese
Eingangsvoraussetzungen wäre ein kleiner nativer Prototyp kein korrekter
RAW-Denoising-Nachweis; deshalb bleibt es beim konkreten Architektur-No-Go.

Verifikation: 40 gemeinsame Tests prüfen u.a. Phasen-/Pegelvalidierung,
Original-Unveränderheit, Matrixablehnung, positives Gain-Matching,
Null-/NaN-/Inf-Ablehnung, 2×-Ausgabedimension, vollständige Randzeilen,
Speicherbegrenzung und Abbruch nach tatsächlicher Rückkehr. Die Tests verwenden
synthetische Tensoren und keine privaten Fotos oder RAW-Ground-Truth. Native
Sensorqualität und Performance bleiben unqualifiziert. Source-Audit: Exit 2
(No-Go). Dieser Forschungs-/Dokumentationsteil ist nicht App-buildwirksam;
der gesamte Aufgabenbranch erhält die eigene Integrationsprüfung.
