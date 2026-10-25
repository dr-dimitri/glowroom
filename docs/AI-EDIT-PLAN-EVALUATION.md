# Gemeinsamer KI-Maskenauftrag (#221)

**Entscheidung am 25. Oktober 2026: No-Go für die Produktfreigabe.**
Der Forschungskandidat verbindet genau eine semantische Zielauswahl mit
einer lokalen Korrektur. Der vorhandene
Weg **Maske erzeugen → Auswahl prüfen → lokal korrigieren** bleibt verfügbar.
Eine erfolgreiche technische Contract-Prüfung ersetzt das Qualitätsgate nicht.

## Native Entscheidung und Grenzen

Alle 20 synthetischen Fälle wurden vor Inferenz festgehalten. Nach fünf vollständig
gemessenen Fällen einschließlich kalter/warmer App-Caches und separatem explizitem
Referenzlauf war ein Go bereits unmöglich: Drei Himmelsfälle bestanden, beide
anschließenden Motivfälle scheiterten. Selbst wenn die sieben übrigen positiven
Fälle bestünden, wären höchstens **10 von 12** erfolgreich; gefordert bleiben
unverändert **11 von 12** und alle acht Negativfälle. Weitere minutenlange
Modellarbeit wurde deshalb beendet. **15 Fälle, darunter alle acht Negativfälle,
bleiben ausdrücklich ungemessen.** Es wird keine Negativfall-Genauigkeit behauptet.

| Fall | Erkannter Zieltyp | Soft-IoU kalt/warm | Explizite Maskenreferenz | Ergebnis |
| --- | --- | --- | --- | --- |
| `sky-0` bis `sky-2` | Himmel | 0,992–0,994 | 0,992–0,994 | Auswahl und Belichtungsrichtung richtig |
| `subject-0` | Hintergrund statt Motiv | 0,0925 | 0,0000972 | Falsches Ziel und falsche Auswahl |
| `subject-1` | Hintergrund statt Motiv | 0,0923 | 0,00000730 | Falsches Ziel und falsche Auswahl |

Damit betrifft das No-Go sowohl die sprachliche Zielwahl als auch die automatische
Motivauswahl auf diesen synthetischen Szenen. Die explizite Referenz macht die
bereits vorhandene Modellgrenze sichtbar; sie wird nicht als Fehlerfreiheit des
bisherigen Modells vorausgesetzt. Originale, Katalog und bestätigte Bearbeitungen
wurden durch die Evaluation nicht verändert. Der unterbrochene Forschungsprozess
wurde anschließend nachweislich beendet; dies ist kein bestandener nativer
Abbruch-Latenznachweis der Produktfunktion.

Median der fünf vollständigen Planläufe: kalt **117,4 s**, warm **111,5 s**;
explizite Referenz **63,6 s**. Höchster nach Planläufen erfasster kumulativer
Prozess-Peak-RSS: **3,29 GiB**; nach Referenzen erfolgte keine eigene RSS-Probe.
Parallel
lief begrenzte Entwicklerkompilierung; diese Zeiten sind beschreibende Messungen
unter dieser Last und kein isolierter Leistungsbenchmark. Es gab in den zehn
gemessenen Planläufen keine Schemafehler. Abbruch-/Lease-Invarianten werden
gesondert mit kontrollierten Diensten geprüft.

Die [eingefrorenen Aufträge](issue-221/frozen-cases.json),
[Beobachtungen je Stufe und Referenz](issue-221/native-observations.json) und die
[erneut berechnete Entscheidung](issue-221/native-summary.json) enthalten nur
synthetische beziehungsweise inhaltsfreie Daten. Der Quellgenerator bleibt im
Test; private Testbilder oder Modellgewichte werden nicht veröffentlicht.
Eine Wiederaufnahme benötigt neue qualifizierte Ziel-/Maskenevidenz und erneut
das vollständige Go-Gate. Der Kandidaten-UI-Code bleibt deaktiviert.

## Eingefrorener Vertrag

`AIEditPlan` Version 1 bindet Foto, Quellenfingerabdruck, Bearbeitungs- und
Auswahlepochen, genau ein Ziel, die tatsächliche Rastermaske, zehn bekannte
Korrekturwerte sowie Modell- und Vorverarbeitungsversionen. Unbekannte Felder,
falsche Typen, ungültige Zahlen, leere Auswahlen und unwirksame Korrekturen
werden vollständig abgewiesen. Es gibt keine globale Ersatzkorrektur und keine
Rechteckmaske als Ersatz für Segmentierung.

`AIEditPlanService` verwendet die bestehenden Qwen-, automatischen Masken- und
Objektmaskendienste. Erst nach der Segmentierung erhält Qwen den tatsächlich
ausgewählten Bereich nach dem bestehenden abgedunkelten Masken-Eingabevertrag.
Die abhängigen Stufen laufen seriell und geben ihre gemeinsame
`AIResourceBudget`-Lease jeweils erst nach nativer Rückkehr frei. Es gibt keinen
neuen Workerpool. Quellprüfung und Vorschau verwenden die vorhandenen begrenzten
Caches. Maskenkoordinaten bleiben im vollständigen orientierten Quellbild vor
Beschnitt, Drehung und Spiegelung.

Der Modelldienst hat keinen Schreibzugriff auf Katalog, Bearbeitungen, Backup
oder Export. Der Kandidat besitzt eine integrierte Prüfoberfläche hinter
`AIEditPlanQualification.productEnabled = false`; ein Umgebungsflag kann diese
Grenze nicht öffnen. Kontrollierte Tests injizieren den Planprovider ausdrücklich.
**Neue Maske mit Korrektur** benötigt genau einen Textauftrag, blendet die für
diesen Modus nicht verwendeten bisherigen Zielbereich-/Stärkefelder aus und
zeigt **Neue Maske**, Zielname und lokale Wertänderungen. **Auswahl**,
**Aktueller Stand** und **Vorschlag** verwenden dieselbe Bildfläche und bereits
berechnete Bitmaps. Die Überlagerung folgt Beschnitt, Optik, Drehung und
Spiegelung. **Übernehmen** setzt den vollständigen Ergebnis-Snapshot über den
normalen Editor mit einem Undo-Schritt; Redo verwendet die gespeicherte Maske.
Für die Produktfreigabe müssen Modellgate und native Lifecycle-/Persistenzabnahme
gemeinsam bestehen. Ein No-Go lässt den neuen Einstieg verborgen.

## Reproduzierbare Prüfung

Die Standardtests `AIEditPlanTests`, `AIEditPlanServiceTests` und die
Matrixprüfung in `AIEditPlanNativeGateTests` verwenden kontrollierte Antworten
ohne Modelle oder Netzwerk. Sie prüfen strikte Grenzen, vollständige Snapshots,
unveränderte bestehende Einstellungsgruppen, A→B→A-/Undo-Epochen, vollständige
Quellkoordinaten, Fehler zwischen den Stufen und Lease-Erhalt bei Abbruch.

Die native Probe ist ausdrücklich optional und benötigt die bereits geprüften
lokalen Qwen-, Himmel- und Motivmodelle. Sie lädt keine Modelle herunter und
ändert keine Installationen. Ein neuer temporärer Ausgabeordner ist Pflicht:

```sh
GLOWROOM_EDIT_PLAN_GATE_OUTPUT=/private/tmp/glowroom-edit-plan-new-run \
  ./scripts/test.sh --jobs 4 \
  --filter AIEditPlanNativeGateTests/installedModelsEvaluateFrozenMatrix
```

Vor der ersten Inferenz schreibt der Runner alle 20 festgelegten Fälle nach
`frozen-cases.json`: je drei positive Fälle für Himmel, Motiv, Hintergrund und
beschriebenes Objekt; vier nicht vorhandene Ziele; vier Mehrzielaufträge.
384 × 256 Pixel große synthetische Szenen und ihre pixelgenaue Annotation
entstehen deterministisch aus dem eingecheckten Generator. Die Szenen enthalten
keine persönlichen Bilder; alle erzeugten Szenen sind für diese Prüfung
gemeinfrei freigegeben (CC0).

Positive Fälle benötigen das vorab benannte Ziel, mindestens 0,6 Soft-IoU zur
Annotation und die beauftragte Belichtungsrichtung. Mindestens 11 von 12 müssen
bestehen, alle acht Negativfälle müssen ausdrücklich abgewiesen werden.
Infrastruktur-/Modellfehler zählen nicht als korrekte Zielverweigerung. Ein
getrennter expliziter Referenzlauf überspringt nur die sprachliche Zielwahl;
Masken- und Korrekturmodelle bleiben identisch. Jeder Fall erhält kalte und warme
App-Cache-Proben, getrennte Stufenzeiten und den kumulativen Prozess-Peak-RSS.
OS-, Shader- und Installationsprüfungscaches werden nicht geleert. Es handelt
sich weder um eine generelle Fotoqualitätszusage noch um isolierte GPU-/
Stufenspeichermessungen. Native Inferenz bleibt für das gemeinsame Speicherbudget
und die geordneten Planstufen seriell; zusätzliche CPU-Kompilierung ist im
konkreten Ergebnisbericht ausdrücklich benannt.

`report.json` wird nach jedem abgeschlossenen Fall atomar aktualisiert. Ein
positiver Zahlenbefund hieße lediglich `numerical-pass-unqualified`; die
vollständige Produktabnahme bleibt erforderlich. Ein No-Go ist ein zulässiger
Evaluationsabschluss aus #221 und gibt den gemeinsamen Bedienweg nicht frei.

Der Runner beendet standardmäßig weitere Inferenz, sobald das unveränderte Gate
mathematisch nicht mehr erreichbar ist. `GLOWROOM_EDIT_PLAN_GATE_COMPLETE_MATRIX=1`
erzwingt für eine ausdrücklich gewünschte vollständige Fehlermatrix alle 20 Fälle;
dieser Schalter erteilt keine Produktfreigabe. `--early-no-go` am Summarizer akzeptiert
unvollständige Messungen nur bei nachgewiesen unerreichbarer Go-Schwelle. Normale
Teilläufe werden abgewiesen; Anzahl und IDs ungemessener Fälle bleiben sichtbar.

`python3 tools/ai-edit-plan-evaluation/summarize.py AUSGABEORDNER` wertet beide
Cache-Durchläufe gegen die vorab gespeicherten Annotationen erneut aus. Ein
korrekter kalter Lauf mit falschem oder übernehmbarem warmem Negativergebnis
zählt ausdrücklich nicht als bestandener Fall. Der Bericht unterscheidet
Schemafehler, falsch positive Pläne, Referenzläufe, Latenzen und Messgrenzen.

Die eingecheckte Entscheidung lässt sich ohne Modelle oder Bilddateien erneut
berechnen:

```sh
evaluation_replay="$(mktemp -d /private/tmp/glowroom-plan-replay.XXXXXX)"
cp docs/issue-221/frozen-cases.json "$evaluation_replay/frozen-cases.json"
cp docs/issue-221/native-observations.json "$evaluation_replay/report.json"
python3 tools/ai-edit-plan-evaluation/summarize.py "$evaluation_replay" --early-no-go
python3 -m unittest discover -s tools/ai-edit-plan-evaluation -p 'test_*.py'
```
