# Lokale neuronale RGB-Entrauschung mit NAFNet — Issue #183

**Entscheidung am 24. Oktober 2026: No-Go für die Produktintegration.** Die lokale
FP32-Referenzroute, Tensor-/Farbverträge und Kachelprüfung sind ausführbar;
Gewichte, Konvertierungsbeleg, native Referenzparität und faire Fotopaare fehlen.
Es wird weder eine Qualitätsverbesserung noch ein Leistungsgewinn behauptet.
Die No-Go-Entscheidungen aus [LC-06/#55](LIGHTCRAFT-DENOISE-EVALUATION.md) und
[Multiskalen/#175](MULTISCALE-DENOISE-EVALUATION.md) bleiben unverändert.
NAFNet ist ein eigener neuronaler Kandidat; der Produktionsfilter ändert sich
nicht. Der optionale GPL-3.0-NIND-RGB-Vergleich wurde nicht übernommen.

Die [maschinenlesbare Quellenprüfung](dtai-evaluation/source-audit.json) und
[Source-Pins](../tools/dtai-evaluation/source-pins.json) binden darktable-ai an
`76513a1e379b4265007bae768825b9a581944ff8` und NAFNet an den Vendor-Gitlink
`2b4af71ebe098a92a75910c233a3965a3e93ede4`. Die tatsächlichen Karten-,
Konverter-, Definitions-, Demo- und Lockfilebytes wurden geprüft. Der Vendor
ist nicht initialisiert; Checkpoint `NAFNet-SIDD-width32.pth` und
`model.onnx` fehlen an den festgelegten Pfaden. Ihre SHA-256 und tatsächlich
verwendete Konverterwerkzeuge bleiben offen. Der Runner verwechselt diese
fehlenden Artefakte nicht mit unveränderlich gepinnten Gewichten.

Die [Upstream-Modellkarte](https://github.com/darktable-org/darktable-ai/blob/76513a1e379b4265007bae768825b9a581944ff8/models/denoise-nafnet/README.md)
nennt MIT für NAFNet/Trainingcode und SIDD-Daten. Diese Angaben sind als
Upstream-Herkunft dokumentiert. Eine erworbene konkrete Gewichtsdatei benötigt
separate Lizenz-/Attributionsprüfung. SIDD enthält Smartphone-Rauschpaare;
daraus folgt kein nachgewiesener Nutzen für entwickelte Kamerafotos. Die neue
Implementierung ist eigenständig; kein GPL-Pipelinecode wurde kopiert/importiert.

Der [Referenzadapter](../tools/dtai-evaluation/README.md) verlangt einen
SHA-256-gebundenen FP32/opset20-Konvertierungsbeleg und prüft das echte
ONNX-Tensormetadatum: `input` und `output` jeweils `[1,3,768,768]` FP32.
Es läuft ausschließlich ONNX CPU, mit einem begrenzten sequentiellen Tilepfad,
768er Kacheln, 64 Pixel Spiegelhalo und disjunktem Core-Write. Singletonachsen,
kleine/ungerade Maße und letzte Zeilen/Spalten werden in unabhängigen
Identitäts-Smokes geprüft. Ausgabe bleibt Float32 in nativer Bildgröße, ohne
Demo-Verkleinerung, uint8-Roundtrip oder verschleierndes Output-Clipping.

Die Demo liefert SDR-RGB [0,1], aber keinen vollständigen
Foto-Arbeitsraum-/Transfervertrag. Für die Forschung wird deshalb ausdrücklich
**gerades, entwickeltes, SDR-encoded-sRGB** verlangt. Eine explizite,
invertierbare Transferfunktion verbindet das nur für RGB innerhalb [0,1] mit
linearem SDR-sRGB. Glowrooms Arbeitsraum ist extended linear sRGB D65, mit
möglichen negativen, Wide-Gamut- und HDR-Werten. Diese werden abgewiesen,
nicht still in die Trainingsdomäne geclippt. Alpha wird nicht inferiert und kann
bitgenau mit `preserve_alpha` aus der ursprünglichen Basis übernommen werden.
Orientierung und Alpha gehören dem bereitstellenden Bildbasis-Cache. Ein
Produkteinbau vor NaturalBalance/Weißabgleich/Tonwerten muss seine sRGB-Transfer-
und Rücktransformationsentscheidung zusätzlich qualifizieren; ein früher
Core-ML-Metadateneintrag belegt dies nicht.

Für eine neue Go-Entscheidung fehlen native Core-ML-Konvertierung und numerische
Original-/ONNX-Parität auf den tatsächlich verwendeten CPU/GPU-Pfaden. Ebenso
fehlen getrennte Tuning-/Abnahmepaare mit gleichem Restrauchen oder Detailerhalt
gegen Glowrooms `consistentV2`-Produktionsfilter, eingefrorene Grenzwerte,
synthetische GT und echte entwickelte Kamerafotos mit unabhängigem Review.
Die vorhandenen Multiskalen-Fixtures/Metriken sind als spätere Baseline vorgesehen,
wurden hier aber nicht mit einem fehlenden Modell angeblich verglichen.
Rauschen, Textur/Haar/Haut, Farbe, Kanten, Kachelnähte und Alpha sowie
512/2400/4096-Vorschauen gegenüber nativer Ausgabe bleiben unqualifiziert.
Die Kachel-Identitätstests beweisen vollständiges Schreiben, keine nahtfreie
Wahrnehmungsqualität eines neuronalen Modells.

Ladezeit, erste/warme Modellzeit, gesamte App-Vorschau, Export und Peak-RSS sind
noch nicht gemessen. Der Runner protokolliert bei echtem Referenzlauf Modell-/
Eingabe-/Ausgabehash, Versionen, Provider, Lade- und einzelne Kachelzeiten.
Seine 512-MiB-Tensorabschätzung ist kein gemessenes RSS-Zulassungsbudget.
Eine App-Integration muss `AIResourceBudget`, Basis-Caches, Abbruch,
Bildwechsel und verspätete Ergebnisse prüfen. Die synchrone Referenz wartet
auf native Rückkehr und verwirft dann abgebrochene Ergebnisse; pro Regler wird
keine Quelle decodiert. Ressourcenaussagen erfordern isolierte Messungen.

Verifikation: 40 gemeinsame Vertrags-/Adaptertests erfolgreich, einschließlich
Float/Endlichkeit, SDR-Transfer, unverändertem Alpha, begrenzter Kachelarbeit,
Abbruch und Rändern. Ein tatsächlicher Modell-/Core-ML-Lauf ist mangels
Artefakten nicht erfolgt. Source-Audit: Status 2, No-Go. Dieser Teil ändert
Forschungstools und Dokumentation ohne App-Buildwirkung; der gesamte Branch
wird separat geprüft und gegebenenfalls gebaut.
