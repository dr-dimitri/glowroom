# Kantenbewusste Schärfung (#174)

Protokoll `DT174-sharpen-v1`, vor Messbeginn am 24. Oktober 2026 festgeschrieben.
Die [maschinenlesbaren Gates](../tools/darktable-sharpen-evaluation/manifest.json)
legen Matching, Problemfälle, Toleranzen und Ressourcenbudgets fest. Eine
komplexere Methode zählt ohne gemessenen Gewinn nicht als Verbesserung.

Unveränderte Eingabe und Glowrooms tatsächliche `DevelopSharpening`-USM sind die
Kontrollen. Isoliert wird ausschließlich die feine Schärfung; keine Wiederholung
von LC-04-Klarheit/Textur, keine Entrauschstufe, keine neuen Regler. Eingaben sind
identische entwickelte Float32-Pixel in extended linear sRGB, Alpha separat.
Die Evaluation verwendet den tatsächlich gemergten `consistentV2`-Vertrag und
ruft die vorhandene Schärfungsstufe direkt auf. Andere Tonwertstufen werden
nicht als Methodenunterschied gezählt. Bestehende Bearbeitungen und ihr
Produktionsgraph bleiben unverändert.

## Herkunft und unabhängige Formeln

Konzeptquellen sind darktable
[`diffuse.c`](https://github.com/darktable-org/darktable/blob/ff93cf64c5e393a903c57ebf9accf655091bf972/src/iop/diffuse.c#L949-L978),
[Varianzregularisierung](https://github.com/darktable-org/darktable/blob/ff93cf64c5e393a903c57ebf9accf655091bf972/src/iop/diffuse.c#L1110-L1129)
und [skalenabhängige Verstärkung](https://github.com/darktable-org/darktable/blob/ff93cf64c5e393a903c57ebf9accf655091bf972/src/iop/atrous.c#L236-L261),
fest auf `ff93cf64c5e393a903c57ebf9accf655091bf972`. Sie motivieren die Frage,
liefern keinen Qualitätsnachweis. Es wird kein GPL-Code, Kernel, Preset oder
Parameterbestand übernommen; es gibt keine darktable-Laufzeitabhängigkeit.

Die eigenen CPU-Formeln begrenzen Arbeit auf zwei Gaußskalen beziehungsweise
höchstens drei iterative Rückwärtsdiffusionsschritte. Die zweite Variante ist
eine begrenzte inverse Gaußdiffusion mit fester Kantendämpfung, keine
Reimplementierung oder numerische Paritätsbehauptung für darktable. Der
vorhandene begrenzte Row-Scheduler wird wiederverwendet; unabhängige Zeilen
laufen bei großen Rastern parallel, abhängige Skalen/Iterationen geordnet. Ein
zusätzlicher Workerpool würde Speicher und konkurrierende Last erhöhen.

## Vorab festgelegter Vergleich

Schräge und breite Kanten, Linienpaare, Impuls, feine Textur, verrauschte Fläche,
bekannte weichgezeichnete Ground Truth und Alpha/signed/HDR sind Pflicht.
Tuning und Abnahme besitzen verschiedene Kantenphase und Rauschseeds. Nur die
Schrägkante im Tuning-Split bestimmt die Kandidatenstärke; diese wird vor der
Abnahme gehasht und niemals auf Abnahmebildern nachgestellt. Betrag, Radius,
Details und Maskieren der USM bleiben unverändert. Die Kandidaten müssen die
zentrale Kantensteilheit innerhalb 3 % bzw. absolut 0,0001 treffen. Dieses Maß
ist ausdrücklich keine MTF50-Messung. Unpassende Wirkung liefert keine
Qualitätsfreigabe und keinen durch geringere Wirkung erzeugten Halogewinn.

Overshoot und Undershoot, Halobreite in Pixeln, Detailkontrast, flache
Rauschstandardabweichung und Ground-Truth-RMSE werden getrennt ausgegeben.
Go verlangt mindestens 10 % Verbesserung beider informativen Halomaße bei
vollständigem Matching aller Problemfälle und bestandenen Einzelgrenzen.
Textur darf höchstens 3 % Kontrast verlieren, Rauschen höchstens 2 % zunehmen;
Ground-Truth-RMSE darf höchstens 0,001 steigen. Nullwirkung, fehlende Messwerte,
unvollständige Matrizen oder fehlende unabhängige Sichtprüfung blockieren Go.
Nachträgliche Grenzabsenkung ist ausgeschlossen.

Native Originalregion und Vorschau sind getrennte Evidenz. Die 2400-Pixel-Lupe
und ihre 200-%-Anzeige beweisen keine native Qualität. Die Skalenmatrix vergleicht
bekannte flächengemittelte Eingaben mit heruntergerechneter nativer Ausgabe.
CPU-Referenzen sind kein beschleunigter Produktionspfad; eine angeforderte
Softwareausführung beweist keine physische Backendwahl. Originale bleiben
unverändert; persönliche Bilder werden weder gesucht noch hochgeladen.

## Reproduzierbarer Aufruf

```sh
./scripts/evaluate-sharpening.sh /private/tmp/glowroom-dt174-run
# Vollständige, getrennt zu planende Kosten-/Skalenmatrix:
./scripts/evaluate-sharpening.sh /private/tmp/glowroom-dt174-full --timing --scale
# Explizite private, bereits entwickelte Bilder bleiben lokal:
./scripts/evaluate-sharpening.sh /private/tmp/glowroom-dt174-private \
  --photo /absolute/path/developed.tiff
python3 -m unittest discover -s tools/darktable-sharpen-evaluation -p 'test_*.py'
```

Der Wrapper verwendet den vorhandenen Editing-Harness. Bereits gebaute Binaries
lassen sich direkt mit `python3 tools/darktable-sharpen-evaluation/run.py
/EXTERNAL/NEW/DIRECTORY --binary /ABSOLUTE/EDITING/BINARY` verwenden. Die Modi
`sharpen-tune`, `sharpen-quality`, `sharpen-timing`, `sharpen-scale` und
`sharpen-photo` verwenden dieselben Options-/Build-Einstiege wie LC-01. Ein
neues, externes Ausgabeverzeichnis ist Pflicht. Private Eingaben werden nur auf
explizite Pfadangabe kopiert, gehasht und gegen Änderungen geschützt. Der
Fotomodus akzeptiert ausschließlich entwickelte PNG/TIFF/JPEG bis 32 MP und
8192 Pixel je Achse; er behauptet weder RAW-Entwicklung noch Ground Truth.

Das gesamte v1-Manifest ist im Runner kanonisch gepinnt. Quellen, Skripte,
Binary und exakte Manifestbytes werden vor dem Tuning gehasht. Der danach
festgeschriebene Kalibrierungshash wird vor/nach jedem Abnahmeschritt geprüft.
Nachträgliche Eingabeänderungen brechen den Lauf ab. `quality/quality.json`
enthält 64 getrennte Abnahmezeilen; `labeled.html` zeigt Eingang, Ground Truth,
USM, Kandidat, gleiche Zahlenwerte, Differenz und Alpha-Komposite. `blind.html`
verwendet neutral kopierte A/B-Dateien; deren Erzeugung ist keine Sichtfreigabe.
`blind-key.json` bleibt bis zur protokollierten unabhängigen Sichtung geschlossen.
PNG-Ansichten sind sRGB-Diagnosen, keine verlustfreien Float-/HDR-Belege.

Die optionale Timingmatrix führt je fünf unabhängige Prozesse für
512×320, 2400×1600, 4096×2731 und 4608×3072 pro Adapter seriell aus.
Prozesskalt, ein ausgeschlossener Warmup und fünf warme Samples bleiben
getrennt. Vorbereitung, Konvertierung, Materialisierung und Readback liegen
innerhalb des Timers; Hashes, PNGs und die winzige Kantenmessung außerhalb.
Die native Timingkante prüft die Wirkung auch bei der tatsächlichen Größe.
Medianquotienten für kalt/warm/Peak-RSS müssen ≤1,25/1,20/1,25 bleiben;
ungematchte Kosten bleiben Diagnosen. Die Zeilen werden begrenzt parallel
berechnet, Vergleichsprozesse bleiben wegen geteilter CPU/GPU seriell.
Während dieser Reihe dürfen keine Builds, Tests oder konkurrierenden Benchmarks
laufen. Prozesskalt bedeutet keine geleerten System-/Shadercaches. Dieser
isolierte Stufentest ersetzt keine End-to-End-Messung von RAW-Decode, UI und
Abbruchreaktion der späteren Produktionsintegration.

Die Skalenreihe verwendet ein natives 4096×2731-Raster und getrennte
512×341-/2400×1600-Vorschauen. Exakte fraktionale Flächenüberlappung in
premultipliziertem RGBA vermeidet die Behauptung einer unbekannten
Decoderresampling-Varianz. Der gesamte RGB-RMSE wird zusätzlich zu den
LC-Diagnosen ausgewiesen und am vorab fixierten Grenzwert 0,002 geprüft.

## Funktionsnachweis und verbleibende Abnahme

Die sechs Swift-Vertragstests der Referenz bestanden im integrierten gezielten
Testlauf: Nullidentität, signed RGB/HDR und Alpha, konstante Fläche an
Transparenzgrenzen, Wiederholbarkeit, voneinander getrennte Tuning-/Abnahmedaten,
synthetisch nachgewiesene Halo-Erkennung, bekannte weichgezeichnete Ground
Truth, Rauschseeds, ungültige Parameter, Abbruch und extreme Portraitgeometrie.
Vierzehn Python-Selbsttests bestanden für Matching, No-Go/Blockierung,
Manifest-/Kalibrierungsprovenienz, unvollständige Matrizen, NaN, Duplikate,
Timing-Pixelidentität, Stärke-/Budgetgrenzen und native Skalen-RMSE.
Diese Funktionsprüfungen sind noch kein Qualitäts- oder Leistungsergebnis.

Die lokalen RAW-Originale `IMG_8724.CR3` und `IMG_8477.CR3` sind vorhanden.
Davon getrennt erzeugte 4096×2731-TIFFs sind tatsächlich 8-Bit-SDR-Thumbnails
aus ImageIO-Entwicklung. Sie eignen sich für private Paarbilddiagnosen, liefern
aber keine native Sensor-/Float-RAW-Ground-Truth und ersetzen keine qualifizierten
Aufnahmen von Haut, Haaren, Zweigen vor Himmel und Textilien. Ihre Originale und
abgeleiteten Bilddateien gehören nicht ins Repository.

## Messergebnis vom 24. Oktober 2026

**No-Go für beide Kandidaten; Glowrooms Produktions-USM bleibt unverändert.**
Die [synthetischen Rohdaten](../tools/darktable-sharpen-evaluation/results/quality.json),
[Kalibrierung](../tools/darktable-sharpen-evaluation/results/calibration.json),
[Entscheidung](../tools/darktable-sharpen-evaluation/results/summary.json) und
[anonymisierte Provenienz](../tools/darktable-sharpen-evaluation/results/provenance.json)
liegen getrennt von privaten Bildern im Repository. Gemessen wurde isoliert
auf Apple M2 Pro mit 16 GiB RAM und macOS 27.0.1 / Swift 6.4. Automatische Core-
Image-Ausführung der tatsächlichen V2-USM wurde mit den CPU-Referenzen verglichen;
eine bestimmte physische GPU-/CPU-Backendwahl wird daraus nicht abgeleitet.

Der Fall `fine-50` trifft bei beiden Kandidaten **beide** Problemkanten innerhalb
der vorab erlaubten 3 %. An der Schrägkante betragen die Steilheitsabweichungen
−0,030 % und +0,058 %. Trotzdem wachsen die Halos und das Rauschen:

| Verfahren | Kantensteilheit | Overshoot / Undershoot, normiert | Halobreite, Pixel | Rauschstandardabweichung der flachen Fläche |
| --- | ---: | ---: | ---: | ---: |
| Tatsächliche Glowroom-USM | 0,416377 | 0,022417 / 0,007763 | 3,500 | 0,003772 |
| Zweiskalenreferenz | 0,416251 | 0,034475 / 0,008698 | 5,875 | 0,004052 (+7,4 %) |
| Begrenzte inverse Diffusion | 0,416619 | 0,025186 / 0,011889 | 3,625 | 0,006124 (+62,3 %) |

Die Zunahme von Overshoot plus Undershoot liegt schon in diesem gematchten
Fall über der absoluten Veto-Grenze 0,0005; die Halobreitenzunahme über 0,1 Pixel.
Auch das 2-%-Rauschlimit wird überschritten. Weitere gematchte Einzelkanten
verletzen Halogrenzen; bei der Diffusionsreferenz kommen Ground-Truth-RMSE-
Regressionen hinzu. Diese nachgewiesenen Einzelvetos reichen zum No-Go.
Ein Leistungsgewinn oder ein besserer Qualitäts-/Kostenkompromiss wird nicht
behauptet.

Je Kandidat sind nur fünf der acht Problemkanten innerhalb der Matchinggrenze.
Über nicht gematchte Zeilen wird **kein** gemeinsamer Qualitätsgewinn und kein
aggregiertes Qualitätsurteil berechnet; sie bleiben als Evidenzlücken erhalten.
Alle 64 Abnahmezeilen wurden ausgegeben, keine fehlerhaften Fälle entfernt.
Ein vor dem finalen Lauf gefundenes Python-Entscheiderproblem hatte gematchte
Einzelvetos verdeckt, sobald irgendeine andere Kante nicht gematcht war. Die
Korrektur wendet dieselben vorab festgelegten Grenzen pro geeignetem Fall an;
zwei adversariale Selbsttests verhindern das erneute Verdecken. Anschließend
wurden Tuning und Qualität mit neu eingefrorenem Runner erneut ausgeführt.
Kalibrierung und sämtliche numerischen Qualitätsdaten stimmten im Nachlauf
exakt mit dem vorangegangenen Lauf überein. Grenzwerte und Swift-Algorithmen
wurden dabei unverändert belassen.

Beide ausdrücklich freigegebenen privaten 4096×2731-TIFFs wurden zusätzlich
lokal mit allen vier Fällen und beiden Referenzen verarbeitet: je acht
Vergleichszeilen und 21 PNG-Diagnosen. Diese Bilder, ihre Hashes und privaten
Pfade werden nicht versioniert. Eine qualifizierte Motivabdeckung, Ground Truth,
angeglichene Fotowirkung oder unabhängige Blindfreigabe wird damit nicht behauptet.

Die vorab beschriebene vollständige Timing-/Skalenmatrix wurde nach den
belegten Qualitätsvetos nicht ausgeführt. Native Qualitätsregionen,
beschleunigte Backend-Parität, UI-Reaktionszeit und Peak-RSS der späteren
Produktionsintegration bleiben daher ungemessen. Auch Abbruch zwischen
Produktionsiterationen, Reglerfolgen, A→B→A, Undo/Redo, Cache-/Persistenz- und
Exportversionierung bleiben Voraussetzungen einer neuen, separat zu
qualifizierenden Produktionsvariante. Das No-Go aktiviert keinen neuen Filter,
keine zweite Reglergruppe und keine Migration vorhandener Bearbeitungen.

In der eingeschränkten Codex-Sandbox war Core Image zunächst nicht verfügbar;
der erste Versuch brach ohne Messdaten mit `EditRenderError.unavailable` ab.
Die erfolgreichen Messreihen liefen anschließend mit Ausführungsfreigabe für
den macOS-Fensterserver in neuen Ergebnisverzeichnissen. Dieser anfängliche
Umgebungsfehler wurde nicht als Qualitätsbefund oder erfolgreicher CPU-Fallback
gewertet.
