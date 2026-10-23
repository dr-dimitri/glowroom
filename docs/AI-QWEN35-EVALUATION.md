# Lokale Qwen3.5-4B-Prüfung vom 23. Oktober 2026

**Ergebnis: keine Freigabe als automatische Fotokorrektur für die geprüfte
Konfiguration.** Bildbeschreibung funktioniert grundsätzlich; im vollständigen
Lauf mit kontrolliertem Antwortformat lässt das Modell jedoch alle zwölf Bilder
unverändert. Es verfehlt damit alle drei vorab festgelegten Pflichtkorrekturen:
zu dunkel wiedergegebenen Schnee, Innenschatten vor hellem Fenster und das
schattige Gesicht im Gegenlicht. Dies ist ein Befund zu diesem kleinen
synthetischen Datensatz, Prompt und Laufzeitweg, keine allgemeine Aussage über
das Modell oder seine Eignung nach anderer Kalibrierung.

## Konfiguration und Grenzen

- Modell: `mlx-community/Qwen3.5-4B-4bit`, Snapshot
  `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`, affine 4-Bit-Quantisierung mit
  Gruppengröße 64. Heruntergeladene und gehashte Modelldateien: 3.061.129.077 Byte.
- Gerät: MacBook Pro, Apple M2 Pro, 16 GB Unified Memory, macOS 27.0.1.
- Laufzeit: MLX-VLM 0.7.10, MLX 0.32.4, Transformers 5.20.2, Python 3.12,
  Pillow 13.0.0, llguidance 1.9.1. Vollständige Abhängigkeiten je Lauf lokal
  eingefroren; die App erhält keine dieser Abhängigkeiten.
- Eingaben: zwölf unveränderte lokale RGB-PNGs, 1536 × 1024 Pixel, explizite
  sRGB-Interpretation. Für das Modell LANCZOS-Verkleinerung auf 1024 × 683 Pixel;
  der Modellprozessor verwendet Grid `[1,42,64]` und 672 Bildtokens. Gesamte
  Eingabe je Bild: 1611 Tokens. Dateiname und Oracle werden nicht übergeben.
- Greedy-Decoding, Seed 0, Thinking aus, höchstens 768 Ausgabetokens,
  Prefill-Blöcke von 512, neuer KV-Zustand je Bild, ein Modellworker.
  Keine Antwortreparatur, keine selektiven Wiederholungen.
- Der Inferenzprozess arbeitet mit Offline-Schaltern an einem lokalen Snapshot.
  Nur Modell-/Paketdownloads benötigen Netzwerk; Bilder gehen nicht an einen
  Inferenzanbieter. Originale und der eingefrorene Erwartungsvertrag bleiben
  unverändert.

Der gemeinsame Prompt hat SHA-256
`ed09169664eecc31103275181e2f249fcc4cb1b2de9b2acafc24e6d4a2b41f3d`.
Erwartungsvertrag:
`3fd1165f16353fcd90a9f4aa258324d708166a912d2b77ec5e3613dbd66fed63`;
Antwortschema:
`5a1596489f6b53f5d00dde878f97156ec23a5fa1ead445a3d137bff1db57429e`.
Beide vollständigen Durchläufe verwenden dieselben Prompts und Sollregeln.

## Zwei getrennte vollständige Durchläufe

**Run 01 ohne erzwungenes Format:** Alle zwölf Antworten beginnen mit einer
Wiedergabe des JSON-Schemas statt mit einer ausgefüllten Bildbeurteilung. Alle
erreichen das Limit von 768 Tokens und enden mit `finish_reason=length`.
Ergebnis: zwölf `schemaError`, kein verwertbarer fachlicher Korrekturplan.
Dieser Fehlschlag bleibt vollständig erhalten und wird nicht durch den zweiten
Lauf ersetzt. Die erste Zeitangabe `load_seconds` dieses Piloten enthält auch
Template-/Versionsinitialisierung und ist keine isolierte Modellladezeit.

**Run 02 mit erzwungener allgemeiner Antwortsyntax:** Alle zwölf Antworten sind
vollständig, enden regulär und bestehen das unveränderte vollständige
Antwortschema. Die Decoderansicht erzwingt Form und Feldvokabular, enthält aber
keine fallspezifischen Sollwerte. Nicht unterstützte Decoderregeln werden
weiterhin vollständig nachträglich validiert; Einzelheiten unter
[Werkzeugablauf](../tools/auto-correction-evaluation/README.md).

Automatische Auswertung des zweiten Laufs:

| Automatischer Zustand | Anzahl |
| --- | ---: |
| Alle maschinellen Kriterien erfüllt | 1 (Fall 09) |
| Zusätzliche Tags benötigen Sichtung | 4 (01, 05, 08, 11) |
| Pflichtkriterien verletzt | 7 (02, 03, 04, 06, 07, 10, 12) |
| Schemafehler, Timeout oder Enthaltung | 0 |

Die anschließende unabhängige Sichtprüfung aller zwölf Beschreibungen bestätigt
die Korrekturfehler. Plausible Zusatz-Tags in 05 und 08 können manuell akzeptiert
werden; die Zusatzbehauptungen in 01 und 11 bleiben teilweise uneindeutig.
Automatische Zustände werden dadurch nicht rückwirkend verändert; die lokale
`manual-review.json` dokumentiert die getrennte Sichtung. Ein automatischer
Treffer allein ist keine Produktfreigabe. Fehlende Labels sind von fachlich
falschen Korrekturentscheidungen zu unterscheiden:

| Fall | Beobachtung |
| --- | --- |
| 01 Landschaft | Motiv und ausgeglichene Belichtung beschrieben; `no_op` passend, zusätzliches `cool_daylight` verlangt Sichtung. |
| 02 heller Schnee | Schnee und Winter erkannt; `no_op` passend, das erforderliche `high_key`-/`bright_scene`-Label fehlt. |
| 03 dunkler Schnee | Winter erkannt, die dunkle Wiedergabe als angemessene Stimmung bewertet; keine erforderliche Aufhellung. |
| 04 Innenraum | Wohnzimmer erkannt, dunkle Möbel als gewollte Atmosphäre rationalisiert; Fenster-/Schattenkonflikt und lokale Korrektur fehlen. |
| 05 Nacht | Nacht, Straßenlaternen und dunkle Stimmung erkannt; `no_op` passend, zusätzliche Belichtungsaussage braucht Sichtung. |
| 06 Gegenlichtporträt | Person und Gegenlicht erkannt, Gesichtsschatten übersehen und Belichtung als ausgeglichen bewertet; lokale Aufhellung fehlt. |
| 07 Mischlicht | Tageslicht und warme Lampe im Text erwähnt; explizites Mischlicht/kühles Tageslicht fehlt. Zusätzlich wird unzutreffend atmosphärischer Dunst getaggt. |
| 08 Sonnenuntergang | Warme Abendstimmung erkannt und erhalten; zusätzliches Tageslicht-Tag braucht Sichtung. |
| 09 Nebel | Landschaft, Nebel und niedriger Kontrast erkannt; `no_op` erfüllt die maschinellen Erwartungen. |
| 10 naheweißes Fenster | Fehlende sichtbare Außenzeichnung und erforderlicher Informationshinweis fehlen; stattdessen ausgewogene Belichtung behauptet. |
| 11 schwarzer Hund | Tier und schwarze Fellfarbe erkannt, `no_op` passend; zusätzliche Tags zu Gegenlicht/Landschaft/weißem Material benötigen Sichtung. |
| 12 High-Key-Produkt | Weiße Keramik und passende unveränderte Darstellung beschrieben; erforderliches `high_key`-/`bright_scene`-Label fehlt. |

Die beiden Schneeaufnahmen sind keine pixelgleichen Belichtungspaare. Bei Fall
03 ist die gewünschte Aufhellung eine vorab festgelegte Testabsicht, keine aus
einem Wetterbild bewiesene Kamera-Fehlbelichtung. Die klaren selektiven Fälle 04
und 06 stützen den negativen Korrekturbefund unabhängig davon. Es wurde kein
Bild gerendert; Maskenqualität, Hautfarbe nach einer Korrektur und Bildqualität
des Ergebnisses bleiben `notRun`.

## Gemessene Ressourcen des zweiten Laufs

| Messung | Ergebnis |
| --- | ---: |
| Isolierte Modellladung, bereits heruntergeladene Dateien | 1,53 s |
| Erste Bildantwort einschließlich Modellvorverarbeitung | 7,66 s |
| Median über zwölf Bildantworten | 6,02 s |
| Minimum / Maximum | 5,73 / 7,66 s |
| Summe der zwölf Antwortzeiten | 74,01 s |
| Größter MLX-Allokatorpeak | 4.128.529.246 Byte = 4,13 GB / 3,85 GiB |
| Größter im 50-ms-Raster beobachteter Prozess-RSS | 890.175.488 Byte |
| Prozesslebenszeit-High-Water-RSS, einschließlich Initialisierung | 1.881.538.560 Byte |

Zeitgrenzen verwenden vor/nach GPU-Arbeit `mx.synchronize()`. Der MLX-Peak wird
vor jedem Bild zurückgesetzt; das Modell bleibt geladen. Die Vorbereitung im
Elternprozess und der Modelldownload sind nicht in den Bildantwortzeiten.
Die erste Antwort enthält auch Decoder-Tokenizerinitialisierung.

**MLX-Speicher und RSS nicht addieren:** Unified-Memory-Bereiche und Framework-
Allokationen überlappen beziehungsweise werden verschieden verbucht. Diese
Zähler sind keine vollständige Systembilanz. Andere Anwendungen blieben offen;
der systemweite Swap veränderte sich und ist dem Testprozess nicht eindeutig
zuzuordnen. Das Gerät hat 16 GB. Der Modellpeak ist für das 8-GB-Ziel
vielversprechend, belegt aber keinen Betrieb von macOS, Glowroom und großen
RAW-Vorschauen zusammen auf einem 8-GB-Gerät.

Es wurde kein OS-Dateicache geleert und keine identische Arbeitslast mehrfach
für einen Kalt-/Warmcachevergleich ausgeführt. Die Zahlen beschreiben diese
beiden tatsächlichen Läufe und sind keine zugesagte Leistung.

## Ablage und nächste Entscheidung

Die vollständigen Daten liegen ausschließlich lokal unter
`Fixtures/LocalTestImages/Evaluations/`, in
`qwen35-4b-4bit-2026-10-23-run01` und
`qwen35-4b-4bit-2026-10-23-run02-constrained`.
Jeder Ordner enthält unveränderte Rohantworten, Laufprovenienz, Eingabedigest,
Paketstand und maschinenlesbare Auswertung. Fotos, Gewichte und Rohantworten
werden weder committet noch ins App-Bundle aufgenommen.

Die konservative Aufgabenformulierung und die synthetische Stichprobe begrenzen
das Urteil. Eine weitere Kalibrierung wäre ein eigener vollständig protokollierter
Versuch mit unverändertem Oracle. Für den aktuellen Vergleich lautet die
Entscheidung: **Motivbeschreibung grundsätzlich möglich, automatische
Korrekturplanung in dieser Konfiguration nicht ausreichend.**

Der finale Testcode samt betroffenen Schnittstellen und Dokumentation wurde
unabhängig reviewt; keine offenen Befunde. Dabei gefundene Quellenrennen
zwischen Hashprüfung und Decodierung
wurden durch gemeinsame Byte-Snapshots behoben und durch isolierte
Regressionstests abgesichert; Fehlerantworten aus dem Modellworker werden
korrekt als Inferenzfehler klassifiziert. 29 isolierte Werkzeugtests bestanden;
beide gespeicherten Auswertungen wurden unabhängig unverändert reproduziert.
Die verwendete Decoderbibliothek ist ebenfalls auf llguidance 1.9.1 gepinnt.
Kein sauberer App-Build erforderlich:
nur optionale externe Python-Evaluationswerkzeuge und Dokumentation, keine
App-, Ressourcen-, Paketierungs- oder Buildkonfigurationsänderung.
