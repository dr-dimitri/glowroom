# Schatten/Lichter mit belichtungsunabhängiger Steuerbasis (#173)

Stand: 24. Oktober 2026. Eigenständige, isolierte Evaluation auf dem gemergten
`consistentV2`-Farbvertrag aus [#168](https://github.com/dr-dimitri/glowroom/issues/168).
Der Produktionsgraph bleibt unverändert. Das historische
[LC-03-No-Go](LIGHTCRAFT-TONE-EVALUATION.md) bleibt gültig; seine Referenz wird
nicht erneut qualifiziert und seine Ergebnisse werden nicht als EIGF-Evidenz benutzt.

## Kandidat und Lizenzgrenze

Die fachliche Hypothese aus
[#173](https://github.com/dr-dimitri/glowroom/issues/173) ist eine vom Bildsignal
getrennte Steuerbasis mit belichtungsnormalisierter Varianz und gemeinsamem
linearem RGB-Gain. Die konzeptionellen Quellen sind darktable
`ff93cf64c5e393a903c57ebf9accf655091bf972`,
[`eigf.h`, Filterkommentar](https://github.com/darktable-org/darktable/blob/ff93cf64c5e393a903c57ebf9accf655091bf972/src/common/eigf.h#L24-L61)
und
[`toneequal.c`, Basis/Gain](https://github.com/darktable-org/darktable/blob/ff93cf64c5e393a903c57ebf9accf655091bf972/src/iop/toneequal.c#L844-L1003).
Diese Quellen sind GPL-3.0-or-later. Es wurde kein Code, Shader, Quelltextport,
Neun-Zonen-Modell oder RAW-Entwickler übernommen. Die folgenden selbst
festgelegten Gleichungen definieren den MIT-Evaluationskandidaten vollständig;
er beansprucht keine numerische Gleichheit zu darktable.

`EIGFToneReference` übernimmt nur den bereits vorhandenen begrenzten
LC-Zeilenexecutor. LC-Fixtures, signed Effekt-Matching, Feinlinien- und
Plateau-Halomessungen sowie die strenge Entscheidungslogik werden wiederverwendet.

Für sichtbare Straight-Float-Pixel in extended linear sRGB wird
`I = 0.2126 |R| + 0.7152 |G| + 0.0722 |B|` verwendet. Für nichtnegative RGB ist
dies die bisherige lineare Steuerhelligkeit. Bei signierten Gamutkoordinaten
verhindert die Betragsfortsetzung eine Auslöschung der Steuerenergie; sie ist
keine Messung tatsächlicher HDR-Luminanz. Nominales SDR-Weiß ist linear 1.
RGB, einschließlich negativer Kanäle und Werten über 1, bleibt unangetastet.

Die einfache Ablation nutzt `B = mean(I)`. Der EIGF-Kandidat verwendet
`v = max(0, mean(I²) - mean(I)²)`,
`a = v / (v + 0.5 max(I², 1e-14))`,
`B = a I + (1-a) mean(I)`.
Die Mittel sind alpha-normalisierte, separable Boxmittel mit replizierten
Rändern. Es gibt keine abschließende Koeffizientenglättung. Anders als bei
darktable werden weder Gaussian-Statistiken noch Downsampling noch iterative
Filterdurchläufe benutzt. Diese Abweichungen sind Teil dieses Kandidaten;
ein späterer anderer Filter erfordert ein neues eingefrorenes Experiment.

Bei positiver Skalierung `k` gilt außerhalb des Floors analytisch:
`mean(kI)=k mean(I)`, `v(kI)=k² v(I)`, `a(kI)=a(I)` und `B(kI)=k B(I)`.
Der absolute Floor, minimale Alphastützung `1e-12`, Float-Rundung und diskrete
Geometrie sind ausdrücklich Grenzbereiche. Tests prüfen die normale Kovarianz
für Faktoren 1/8, 1/2, 2 und 8 separat von Null und den Floorwerten.

Mit `z = log2(max(B,1e-7)/0.18)` und kubischem Smoothstep gilt
`ws = 1-smoothstep(-6,0,z)`, `wh = smoothstep(-1,3,z)` und
`localEV = clamp(2 shadows/100 ws + 2 highlights/100 wh,-4,4)`.
Alle drei RGB-Kanäle erhalten denselben Faktor `2^(localEV+exposure)`.
Bei fester Basis ist der Gain positiv, begrenzt und monoton in jedem Regler;
die Regler besitzen beide Richtungen. Die Tonbereichsauswahl geschieht vor
Belichtung. Belichtung wird genau einmal angewandt. Die Steuerbasis ist
belichtungskovariant; das feste Tonbereichsmapping wird damit ausdrücklich
nicht insgesamt belichtungsinvariant.

## Einbaupunkt und Ressourcen

Die Vergleichsbaseline rendert den aktuellen Produktionsgraphen ausdrücklich
als `consistentV2` mit Float32-CI-Arbeitsformat und Float-Readback. Beide
Referenzen erhalten dieselben bereits entwickelten, orientierten Float-Pixel.
Alpha wird separat erhalten; Alpha null hat kanonisches RGB null. Nullenergie
bleibt null, nichtendliche/zu große (`abs(channel)>1e12`) Eingaben werden
kontrolliert abgewiesen. Es gibt weder Würfelclamp noch Rekonstruktionsbehauptung
für schon ausgebrannte Quellen.

Der isolierte Adapter akzeptiert ausschließlich Schatten, Lichter und
Belichtung in V2. Aktive Weiß-/Schwarz-/Kontrastregler, NaturalBalance,
Einzelreglerautomatik, Präsenz und weitere Einstellungen werden explizit
abgewiesen. Die Kandidateneinordnung wäre nach dem vorhandenen Prefix und vor
Belichtung; das genaue Zusammenspiel mit diesen weiteren Stufen ist noch
offene Produktionsevidenz. Sie werden hier nicht doppelt angewandt oder still
anders interpretiert. Eine vollständige lokale Maske wird nicht durch diese
isolierte Referenz simuliert.

Der nominelle Radius beträgt 1,5 % der nativen langen Kante. Erst danach wird
er über `outputLong/nativeLong` in Ausgabepixel umgerechnet und gerundet
(mindestens ein Pixel, maximal die vorhandene lange Kante). Der Adapter nimmt
nur vollständige entwickelte Raster entgegen; ein Produktions-ROI-Vertrag ist
noch nicht implementiert. Die unveränderliche Basisidentität enthält Quellhash,
Maße, native Größe, Ausgabeskala, Prozessversion und Basisart. Reglerstärken
und Belichtung gehören nicht hinein. Andere vorgelagerte Parameter sind im
isolierten Adapter unzulässig; eine Produktionsidentität müsste auch diese
und ROI-/Maskenabhängigkeiten enthalten.

Neutral und reine Belichtung erzeugen keine Basis. Bei aktiven Tonreglern
kann dieselbe Basis bei schnellen Stärke-/EV-Änderungen wiederverwendet werden.
Es gibt keinen RAW-Aufruf und keinen globalen veränderlichen Cache. Ein
konservativer Referenzplan reserviert 80 Byte/Pixel für Ein-/Ausgabe und alle
Statistik-/Filtertemporaries und weist Anforderungen oberhalb 1,5 GiB ab.
Dies ersetzt die gemessene Prozess-RSS nicht; CI-/Treiberkosten gehören in die
separate Performanceabnahme. Zeilen und Spalten laufen mit höchstens vier
vorhandenen Workern; abhängige Statistikschritte bleiben geordnet. Kleine
Raster bleiben wegen des Startaufwands seriell. Abbruch verwirft Teilergebnisse.
Die Referenz veröffentlicht keinen UI-Zustand; veraltete UI-Resultate und
gemeinsame Renderlanes müssen vor einer Integration separat geprüft werden.

## Vorab fixierte Abnahme

Das eigene [Manifest](../tools/eigf-evaluation/manifest.json) fixiert vor Tuning
und Abnahme acht Fälle (Schatten/Lichter jeweils ±20 und ±40), 512 × 320 Pixel,
12 Klassen und zwei Basisarten. Die neun LC-Klassen decken Rampen, Konstanten,
feine helle/dunkle Linien, Kanten, Textur, Haut/Farbfelder, Sättigung, Alpha und
Rauschen ab; hinzu kommen verzweigte Linien, Display-P3 und explizite
synthetische HDR-Graufelder bis linear 8. Auch P3 und HDR besitzen verschiedene
vorab festgelegte Float-Pixel: der Tuning-Split skaliert P3 um 0,96 und HDR
um 0,97; die Abnahme verwendet die ursprünglichen Werte. Hash-Tests verhindern,
dass identische analytische Eingaben als unabhängige Abnahme ausgegeben werden.

Die signed mittlere ΔY-Wirkung in ausschließlich eingangsdefinierten ROIs
(Schatten Y<0,25, Lichter Y>0,5) wird nur auf dem Tuning-Split gesucht:
33 grobe plus 33 lokale Stufen, Werte 0…100 mit der jeweiligen Richtung.
Ein eingefrorener Parameter je Klasse/Richtung/Basis wird unverändert auf
der unabhängigen Abnahme verwendet. Das ist keine universelle
Reglerübersetzung. Matching braucht denselben von null verschiedenen Sinn,
mindestens |ΔY|=0,002 und Fehler ≤max(0,003,5 % |Ziel|).
Unerreichbare/fehlende ROIs sind Evidenzlücken.

Der Feinlinien-Logkontrastfehler muss im gleich gewichteten Mittel der vier
moderaten Richtungen mindestens 10 % sinken; jede helle/dunkle Region darf
höchstens 0,05 zusätzlichen relativen Fehler erhalten. Kritische Grenzen
bleiben Halo ±0,02 linear Y, Hue-Differenz zur Baseline 3°, zusätzlicher
Gamut-/Clippinganteil 0,02 und Alphaabweichung 0,001. Das Rauschen wird gegen
die mit denselben Einstellungen verarbeitete saubere Szene gemessen;
seine RMSE darf höchstens 1,10× Baseline betragen. Intendierte Tonänderung
gilt dadurch nicht als Rauschminderung. Textur hat noch keine eigenständig
qualifizierte fotografische Primärabnahme und bleibt als Lücke sichtbar.

Gamut/Clipping werden für SDR in sRGB beziehungsweise für die P3-Klasse nach
der expliziten linearen D65-P3-Konvertierung beurteilt. Nettozunahme und neue
Koordinatenüberschreitungen werden getrennt ausgewiesen und gegatet. Die
historischen extended-sRGB-Zähler bleiben Diagnostik. HDR ist hier unbeschränkt;
die grauen HDR-Felder liefern keinen SDR-Würfel-/Clippingpass. Ein vollständiger
definierter HDR-Ausgabevergleich bleibt erforderlich. Die Hue-Metrik vergleicht
Looks zur Baseline, sie beweist keine ursprüngliche Objektfarbtreue.

Kalt-/Warmlatenz/RSS-Budgets bleiben 1,25×/1,20×/1,25× bei gleicher Wirkung.
Die vollständige Matrix umfasst 512×320, 2400×1600, 4096×2731, 4608×3072 mit
je fünf Prozessen und fünf warmen Samples sowie separatem Warmup. Die
Zeitgrenze umfasst CI-Kontextinitialisierung im Kaltlauf, Konvertierungen,
Basis/Gain und Float-Readback. Fixture-Erzeugung, Qualitätsmetriken, PNGs,
RAW-Decode und UI sind ausgeschlossen. Die Basis wird warm wiederverwendet.
Effektgleichheit wird pro tatsächlicher Sample-/Größenphase erneut geprüft;
unterschiedliche Tonwirkung darf kein Performance-Go/No-Go begründen.
Benchmarks laufen seriell ohne konkurrierende Builds/Tests. Ein neuer Prozess
leert weder Betriebssystem- noch Shadercache und beweist keine GPU-Ausführung.

## Reproduktion und Entscheidung

Nach dem gemeinsamen Editing-Harness-Build:

```sh
python3 -m unittest discover -s tools/eigf-evaluation -p 'test_*.py'
python3 tools/eigf-evaluation/run.py /private/tmp/glowroom-eigf-173 --binary /absoluter/pfad/Glowroom
```

`--timing --scale` ergänzt die volle serielle Performance- und
2400×1600/Preview-Skalenmatrix. Der Runner friert Manifest, Swift-Quellen,
Tests, Messskripte und Binary vor Tuning ein; Kalibrierung wird vor der
getrennten Abnahme gehasht. Änderungen brechen den Lauf ab. Bestehende
Ergebnisordner werden nicht überschrieben. Rohdaten, exakte Aufrufe, Hostdaten,
Hashes und die unabhängigen Entscheidungen für `simple` und `eigf` stehen im
gewählten externen Ordner. `labeled.html`, `blind.html` und der getrennte
Zuordnungsschlüssel unterstützen Sichtprüfung; ihre Erzeugung ist keine
protokollierte Sichtfreigabe. PNGs sind begrenzte SDR-Diagnostik, Float-Metriken
arbeiten vor der Ausgabequantisierung.

Der Python-Bericht prüft die nativen Matchingflags erneut gegen die
eingefrorene Tuning-Kalibrierung und die tatsächlichen Abnahme-ΔY-Werte,
verhindert nachträglich geänderte Kandidatenparameter und rekonstruiert die
kritischen Gatefehler aus den numerischen Metriken. Fehlende/nichtendliche
Metriken oder widersprüchliche Flags brechen ab. Alpha ist zusätzlich ein
unbedingter Transportvertrag; fehlendes Effekt-Matching verdeckt keine
Alphaänderung. Acht Python-Selbsttests sichern diese Entscheidungsfälle ab.

Optional kann ein ausdrücklich genanntes, zuvor entwickeltes Float-TIFF
unverändert diagnostisch verglichen werden:

```sh
/absoluter/pfad/Glowroom --scenario evaluation --evaluation-mode eigf-photo \
  --input /privater/pfad/entwickeltes-foto.tiff --manifest /private/tmp/glowroom-eigf-173/manifest.json \
  --calibration /private/tmp/glowroom-eigf-173/tuning/calibration.json \
  --output /private/tmp/glowroom-eigf-photo --backend default --workers 1
```

Die lokalen CR3-Dateien `IMG_8724.CR3` und `IMG_8477.CR3` sind vorhanden,
aber bislang keine qualifizierten Abnahmeszenen mit registrierten ROIs,
Entwicklungs-/Range-Provenienz, Ground Truth und protokollierter Sichtabnahme.
`eigf-photo` akzeptiert nur entwickelte PNG/JPEG/TIFF, zeichnet File-/Float-Hash,
Profil, Bittiefe und Diagnosepaare auf und markiert `acceptance=false`.
Die Fine-lines-Kalibrierung wird ausdrücklich nicht als universelles
Fotomapping interpretiert. Die sieben privaten JPEGs werden nicht automatisch
gelesen; Originale und private Ergebnisse werden nicht committet.

Die numerische Qualitätsentscheidung unterscheidet ein belegtes No-Go von
fehlender Evidenz. Unabhängig davon bleibt die Produktionsintegration gesperrt,
bis reale Foto-/RAW-Abnahme, Textur-/HDR-/Profilfreigabe, Sichtprüfung,
vollständige Ressourcenmessungen, Backendgleichwertigkeit sowie die
versionierte Einbindung inklusive lokaler Korrekturen, Undo und Backups
vollständig nachgewiesen sind. Kein synthetischer Lauf kann allein ein Go
erteilen; Legacy-Bytes, Hashes und Looks bleiben dadurch unverändert.

## Gemessenes Ergebnis am 24. Oktober 2026

**No-Go für EIGF und die einfache Boxbasis. Die Produktion bleibt unverändert.**
Die separat gespeicherten
[synthetischen Qualitätsdaten](../tools/eigf-evaluation/results/quality.json),
[Kalibrierung](../tools/eigf-evaluation/results/calibration.json),
[Entscheidung](../tools/eigf-evaluation/results/summary.json) und
[relative Provenienz](../tools/eigf-evaluation/results/provenance.json)
enthalten keine privaten Bilder oder lokalen Benutzerpfade. Der erfolgreiche
serielle Lauf nutzte den finalen Release-Harness auf Apple M2 Pro mit 16 GiB
RAM und macOS 27.0.1, Binary-SHA256
`f76bc30ece9a06f9ab93bb21fb9804f535d63e96fd919437fe6b431a6b911280`.
Das Manifest wurde als
`c8f722e9064f9490ec58d772094392f9a449e1fa0625df8baa0f74f23cc7907e`
vor Tuning eingefroren, danach die Kalibrierung als
`60ab763a0c4aca5863e7701862d4113f240ffbb6a959597be6fc4d7d4c93ea4a`.

Alle 192 Qualitätszeilen wurden ausgewertet. EIGF erreicht 44/96,
die einfache Basis 40/96 passende Tonwirkungen. Unpassende/fehlende ROIs
werden weder weggelassen noch als Qualitätsfehler gewertet. Die vier
moderaten Feinlinienfälle sind bei EIGF vollständig angeglichen:

| Fall | eingefrorener EIGF-Wert | Baseline ΔY | EIGF ΔY | Baseline Kontrastfehler | EIGF Kontrastfehler |
| --- | ---: | ---: | ---: | ---: | ---: |
| Schatten +20 | 69,140625 | 0,0129672 | 0,0129733 | 0,0964111 | 0,0899311 |
| Schatten −20 | −79,6875 | −0,0106522 | −0,0106537 | 0,1110133 | 0,1036494 |
| Lichter +20 | 8,7890625 | 0,0982406 | 0,0974391 | 0,0310361 | 0,0219276 |
| Lichter −20 | −9,375 | −0,0924779 | −0,0931131 | 0,0324065 | 0,0233894 |

Das gleich gewichtete mittlere Logkontrastfehlermaß sinkt von 0,067716753 auf
0,059724378, also um **11,8027 %**, ohne Verletzung der regionalen
Regressionsgrenze. Das besteht nur die synthetische Primärmetrik und ist
wegen der folgenden kritischen Vetos kein freigegebener Qualitätsgewinn.

Der neutrale Graukantenfall `hard-edge / highlights-negative-40` ist bereits
ein eigenständiger, belastbarer Gegenbeleg: Eingang 0,04/0,86 linear,
Baseline ΔY −0,171799541, eingefrorener Kandidatenparameter −17,7734375,
Kandidat ΔY −0,172073172. Bei dieser passenden Lichterabsenkung entsteht ein
Plateau-bereinigtes Überschwingen von **0,025825322 linear Y**, über der
vorab festgelegten Grenze **0,02**. Die Baseline liegt numerisch bei null.
Dieser Fall braucht weder eine Interpretation gesättigter Farben noch eine
HDR-/Ausgabeclippingbehauptung, um das No-Go zu begründen. Auch die passende
positive 40er-Lichterkante überschreitet mit 0,034896731 Unterschwingen das
Gate. Die einfache Basis verletzt Halogrenzen bereits in moderaten Fällen.

Weitere Baseline-relative Randwert-Vetos entstehen in der Farbklasse bei
Lichter +20/+40 (0,087438965/0,090089925 zusätzliche Koordinaten am Rand 0/1).
Die Metrik zählt auch exakte Nullen: ein gemeinsamer Gain kann vorhandene
Nullkanäle erhalten, während die additive Baseline sie anhebt. Diese Zahlen
beweisen deshalb keine neu verlorenen Quelldetails oder schlechtere
Objektfarbtreue; das No-Go stützt sich unabhängig davon auf die grauen Kanten.
Netto- und neu gegenüber der Baseline erreichte Gamut-/Randwertanteile sind
in den Rohdaten getrennt. Die maximale Alphaabweichung ist in allen 192
Vergleichen exakt null. Für die einfache Basis bleibt das vollständige
moderate Primärmittel wegen fehlenden Matchings gesperrt.

Die zehn Swift-Vertragstests bestanden im integrierten Testlauf. Zwei
fehlerhafte Testannahmen wurden dabei korrigiert: ein EV-Vergleich berücksichtigt
Float-Rundung bis vier relativen Float-ULPs, und der Alpha-Konstantentest
fordert nur bei sichtbaren Pixeln eine definierte Steuerbasis. Die numerischen
Abnahmegates und Referenzformeln wurden dabei nicht verändert. Acht
Python-Selbsttests und die unabhängige Quell-/Entscheiderprüfung bestanden.

Beide ausdrücklich freigegebenen privaten 4096×2731-TIFFs wurden anschließend
mit beiden Basisarten und allen vier moderaten Richtungen diagnostisch
verarbeitet. Es handelt sich um **8-Bit-sRGB-SDR-Thumbnails** aus ImageIO,
keine native Float-RAW-Ground-Truth. Pro Bild bleiben acht Vergleichszeilen
und 17 PNG-Diagnosen ausschließlich lokal; `acceptance=false` wird nicht
als qualitative Freigabe umgedeutet. Originale bleiben unverändert.

Nach den belegten Qualitätsvetos wurde die vollständige Timing-/Skalenmatrix
nicht ausgeführt. Kalte/warme Latenz, Durchsatz, Peak-RSS, große native
RAW-Regionen, beschleunigte Backend-Parität und visuelle Fotoabnahme bleiben
damit ungemessen. Es wird kein Performancegewinn behauptet. Ein späterer
anderer Filter oder ein anderes Mapping benötigt ein neues vorab fixiertes
Protokoll; die vorhandenen Gates werden nicht nachträglich angepasst.
