# Lokale Testbilder für automatische KI-Fotokorrektur

Die zwölf synthetischen Foto-Fixtures ergänzen `test_picture1.jpg` bis
`test_picture7.jpg` unter `Fixtures/LocalTestImages/`. Sie prüfen, ob eine künftige
KI-Korrektur Motiv, beabsichtigte Bildstimmung und tatsächlichen Korrekturbedarf
unterscheidet. Ein Modell, das jedes Bild heller, kontrastreicher oder neutraler
macht, soll diese Prüfung ausdrücklich nicht bestehen.

Die Bilder sind durch Bildgenerierung erzeugte, entwickelte Raster und keine
Kamera-RAWs. Sie haben weder eine physikalisch bekannte Aufnahmebelichtung noch
eine objektiv richtige Anzahl von Belichtungsstufen. Der Erwartungshorizont ist
ein vor dem Modellvergleich festgelegter Testvertrag für eine zurückhaltende,
natürlich wirkende Korrektur. Er ist kein Nachweis der ursprünglichen
fotografischen Absicht oder eine allgemeine Qualitätsrangliste.

## Ablage und Ausführung

Die neuen Eingaben heißen neutral `ai_correction_01.png` bis
`ai_correction_12.png`. Im selben lokalen Ordner liegen:

- `README.md`: lesbarer Erwartungshorizont und Hinweise zur Auswertung;
- `expectations.json`: maschinenlesbare Fallzuordnung, Quellenidentität und
  Bewertungskriterien;
- `response.schema.json`: JSON-Schema des experimentellen Antwortvertrags;
- `generation-prompts.json`: verwendete Generierungsanweisungen und Herkunft;
- `validation-report.json`: tatsächlich ausgeführte Fixture- und Vertragsprüfung,
  ausdrücklich ohne Modell- oder Korrekturergebnis.

Alle zwölf Eingaben sind verlustfreie RGB-PNGs mit 1536 × 1024 Pixeln und ohne
eingebettetes ICC-Profil oder EXIF. Der Test interpretiert sie ausdrücklich als
sRGB IEC61966-2-1, ohne die gespeicherten Originalbytes zu verändern. Der
vollständige tatsächlich verwendete Prompt-Satz bleibt in der lokalen
Herkunftsdatei erhalten; interne Generatormodellversion und Seed wurden vom
Bildwerkzeug nicht offengelegt.

Der gesamte Ordner bleibt gemäß `AGENTS.md` ignoriert. Bilder, Prompts,
Erwartungsdatei und abgeleitete Ergebnisse werden nicht committet, nicht nach
GitHub übertragen und nicht in das App-Bundle aufgenommen. Die vorhandenen sieben
Originale bleiben unverändert. Diese öffentliche Anleitung enthält keine
Bilddateien und ersetzt die lokalen Begleitdateien nicht.

Frische Checkouts und CI besitzen diese Dateien nicht. Eine spätere Modellprobe
muss deshalb explizit aktiviert werden und ein vorhandenes Fixture-Verzeichnis
verlangen. Fehlende Dateien müssen als `missingFixtures` beziehungsweise
übersprungene lokale Probe ausgewiesen werden; sie sind niemals ein bestandenes
Modellergebnis. Normale Unit-Tests dürfen weder diese Dateien voraussetzen noch
Modelle herunterladen oder echte Inferenz starten.

Diese Änderung stellt Testmaterial und dessen Bewertungsgrundlage bereit. Sie
implementiert keinen automatischen Korrekturprovider und keinen Modelltestrunner.
Ein sauberer App-Build ist für reine Dokumentations- und lokale
Fixture-Änderungen nicht erforderlich.

## Gemeinsame Modellaufgabe

Alle Kandidaten erhalten dieselbe neutrale Aufgabe, zum Beispiel:

> Beurteile das sichtbare Foto für eine zurückhaltende, natürlich wirkende
> Fotokorrektur. Beschreibe Motiv, Licht und auffällige Probleme. Erhalte
> erkennbare Bildstimmung sowie natürliche Material- und Objektfarben. Schlage nur
> notwendige globale oder lokale Korrekturen vor. Ein bereits gelungenes Bild
> darf unverändert bleiben. Benenne Unsicherheit und Grenzen der verfügbaren
> Bildinformation. Gib einen strukturierten Plan aus.

Das Modell erhält das orientierte, farbverwaltete Bildraster, diese gemeinsame
Aufgabe sowie dasselbe Antwortschema und denselben allgemeinen Wortschatz für
alle Fälle. Dateiname, Fallnummer, Verzeichnis, Erwartungshorizont, Prompt der
Bildgenerierung, Prüferkommentare und andere Sollhinweise bleiben dem Modell
verborgen. Der Runner transportiert die interne Fallkennung getrennt und nennt
das Attachment gegebenenfalls `image.png`. Sonst könnte das Modell das Soll aus
der Testbeschreibung statt aus dem Bild ableiten.

Der Vergleich hält Modellversion, Quantisierung, Laufzeit, Seed beziehungsweise
Samplingkonfiguration, Eingabeauflösung, Bildtokenbudget, Kontext und
Ausgabelimit fest. Alle Modelle sehen zunächst denselben Ausschnitt in derselben
Auflösung. Zusätzliche Detailansichten sind nur in einer getrennten, für alle
Kandidaten gleich festgelegten Versuchsbedingung erlaubt. Eine aufgehellte
Diagnoseansicht muss als solche markiert bleiben und darf die Originalbeurteilung
nicht ersetzen.

## Erwartung pro Bild

| Fall | Sichtbare Situation | Erwartete Entscheidung | Wesentliche Fehlkriterien |
| --- | --- | --- | --- |
| 01 | Gut belichtete Landschaft mit erkennbaren Schatten und Lichtern | Landschaft und ausgewogene Belichtung erkennen; keine notwendige Korrektur | Pauschales Aufhellen, künstlicher HDR-Kontrast oder zusätzliche Sättigung ohne sichtbaren Anlass |
| 02 | Korrekt helle Schneelandschaft | Schnee und helle Winterstimmung erkennen; Helligkeit und Schneestruktur erhalten | Helle Motivfarbe als Überbelichtung einstufen, Schnee grau machen oder bläuliche Schatten vollständig neutralisieren |
| 03 | Dunkel beziehungsweise grau wiedergegebene Schneelandschaft | Schnee erkennen und eine begrenzte Aufhellung vorschlagen; erkennbare Schneestruktur schützen | Unverändert lassen trotz klarer dunkler Wiedergabe, weitere Abdunklung oder Aufhellung bis zur flächigen Weißsättigung |
| 04 | Innenraum mit dunklen Möbeln vor hellem Fenster | Innenraum und großen Helligkeitsumfang erkennen; problematische Innenschatten selektiv öffnen | Ganzes Bild stark aufhellen, Fenster und bereits helle Flächen auswaschen oder dunkle Materialien vollständig grau machen |
| 05 | Absichtlich dunkle Nachtaufnahme mit kleinen Lichtquellen | Nacht und gewollt dunklen Gesamteindruck erkennen; keine automatische Tageslichtwirkung | Gesamtes Bild auf mittlere Helligkeit heben, Schwarztöne beseitigen oder Lichtquellen ausfressen lassen |
| 06 | Person im Gegenlicht mit dunklerem Gesicht und hellem Hintergrund | Gegenlicht erkennen; Gesicht beziehungsweise Person begrenzt und lokal aufhellen | Hintergrund im selben Maß aufhellen, Haut unnatürlich verfärben oder Gesichtszüge und Motivinhalt ändern |
| 07 | Innenraum mit warmer Lampe und kühlem Fensterlicht | Unterschiedliche Lichtfarben benennen; vorhandene Lichtstimmung erhalten; `no_op` oder `limitations_only` mit leerer Bearbeitungsliste | Einen starken globalen Weißabgleich erzwingen, einen nicht vorhandenen lokalen Weißabgleich ausführen oder kühle Bereiche stark einfärben |
| 08 | Warmer Sonnenuntergang | Sonnenuntergang und warme Lichtfarbe erkennen; Wärme erhalten | Orange und Rot als pauschalen Farbstich beseitigen, Szene kühl neutralisieren oder aggressive Sättigung hinzufügen |
| 09 | Neblige Landschaft mit absichtlich geringem Kontrast | Nebel beziehungsweise atmosphärischen Dunst erkennen; Tiefe und weiche Kontraste erhalten | Fehlenden Kontrast automatisch als Fehler behandeln, starke Klarheit oder starkes Dehazing erzwingen |
| 10 | Innenraum mit naheweißer Fensterfläche ohne erkennbare Außenzeichnung | Sichtbar fehlende Außenzeichnung und Grenzen des entwickelten Rasters benennen; nur vorhandene Zeichnung bearbeiten | Nicht sichtbare Außendetails als sicher wiederherstellbar behaupten, Inhalte erfinden oder eine vollständig geclippte Sensoraufnahme aus dem Raster ableiten |
| 11 | Schwarzes Tier vor hellerem Hintergrund | Dunkle Fellfarbe als Objektfarbe erkennen; Fell, Augen und Kontur unterscheiden | Schwarzes Fell allein als allgemeine Unterbelichtung deuten, Fell grau machen oder den hellen Hintergrund pauschal aufhellen |
| 12 | Weißes Produkt in korrekt heller High-Key-Umgebung | Helles Motiv und helle Gestaltung erkennen; Form und vorhandene Struktur erhalten | Weiße Flächen wegen ihrer Helligkeit pauschal abdunkeln, Grauwelt-Abgleich erzwingen oder zusätzlichen Kontrast ohne Bedarf anwenden |

Die Bildgenerierung allein bestätigt diese Beschreibungen nicht. Vor der
Verwendung werden die tatsächlich gespeicherten Raster visuell geprüft und der
Erwartungshorizont gegebenenfalls an sichtbare Eigenschaften angepasst. Ein
misslungener Fixture darf kein Modellversagen verursachen. Fälle 02/03,
04/05 und 02/12 prüfen verwandte Entscheidungen, sind aber unabhängig erzeugte
Szenen und keine pixelgleichen Vorher-/Nachher-Paare.

Fall 07 berücksichtigt die tatsächlich vorhandene Regleroberfläche:
`LocalAdjustmentSettings` enthält keinen ausführbaren lokalen Weißabgleich.
Ein Hinweis auf eine mögliche lokale Farbangleichung darf daher nur als
nicht ausführbare Empfehlung erscheinen. Der Plan bleibt `no_op` oder
`limitations_only` und enthält keine aktiven Bearbeitungen; ein neu erfundener
Regler ist ein Vertragsfehler.

Fall 10 ist bewusst eine Prüfung fehlender sichtbarer Information und keine
physikalische Clipping-Referenz. In der festgelegten Fenster-Messregion liegen
die RGB-Kanäle mindestens bei 250 von 255; nur etwa 0,56 % der Pixel sind in allen
drei Kanälen exakt 255. Die Fläche ist damit naheweiß und ohne erkennbare
Außenzeichnung, aber nicht vollständig digital gesättigt. Eine Aussage über
Sensorreserven oder die ursprüngliche Belichtung lässt sich aus dieser
generierten PNG-Datei nicht ableiten.

## Getrennte Bewertung von Analyse, Plan und gerendertem Bild

### 1. Quellen- und Antwortvertrag

Vor einem Lauf werden Dateivollständigkeit, PNG-Decodierung, Maße, Orientierung,
Farbprofil beziehungsweise dokumentierte Farbrauminterpretation und der lokale
SHA-256 gegen die Erwartungsdatei geprüft. Ein verändertes Fixture benötigt eine
neue Version samt erneuter Sichtprüfung. Seine alten Sollwerte dürfen nicht
stillschweigend weitergelten.

Die Modellantwort muss das vereinbarte Schema mit gültigen Typen und endlichen,
begrenzten Werten erfüllen. Unbekannte Regler, ungültige Koordinaten oder
unverständliche Antworten sind Vertragsfehler. Sie werden nicht als unverändertes
Bild und damit als erfolgreiches No-op behandelt. Abbruch, Timeout und
Nichtverfügbarkeit werden getrennt von fachlichen Fehlern protokolliert.

Der lokale experimentelle Antwortvertrag verlangt `schema_version`, positive
`tags`, `description_de`, `decision`, `edits` und `warnings`. Edit-Regeln beziehen
sich auf `scope`, `target`, `operation`, `direction` und `strength`. Diese
qualitativen Stärken sind keine unmittelbar ausführbaren Glowroom-Reglerwerte.
Ein späterer Adapter muss ihre konkrete Abbildung separat versionieren.
`description_de` ist zusätzlich auf 2048 UTF-8-Bytes begrenzt; JSON Schemas
`maxLength` zählt Zeichen und ersetzt diese Byteprüfung nicht.

### 2. Semantische Analyse und Korrekturplan

Der Evaluator prüft Konzepte und Beziehungen, keine wortwörtliche Musterausgabe.
„Schnee“, „verschneit“ und „Winterlandschaft“ können zum selben Sollkonzept
gehören; „keine Schneelandschaft“ darf dagegen nicht durch bloßen Worttreffer als
Erkennung gelten. Lichtart, Motivfarbe, Korrekturbedarf, globale oder lokale
Wirkung und die Begründung müssen zusammenpassen. Ein strukturierter
Szenenklassifikator vereinfacht diese Prüfung; Freitext erfordert eine
nachvollziehbare semantische Sichtung oder ein getrennt validiertes Verfahren.

Positive Sollgruppen allein genügen nicht: `semantics.forbidden_tags` weist
explizit falsche oder widersprüchliche Behauptungen zurück. Zusätzliche Tags
außerhalb von `semantics.allowed_positive_tags` verlangen `manualReview` und
dürfen nicht automatisch bestehen. Die erlaubten Zusatz-Tags berücksichtigen
sichtbare Nebendetails, beispielsweise kleine Schneereste auf den Bergen in
Fall 01. Auch bei passenden Tags bleibt die Prüfung falscher Aussagen in der
Beschreibung erforderlich.

Ein unpassender Plan darf nicht allein deshalb bestehen, weil ein Renderer seine
Werte zufällig kaum sichtbar umsetzt. Umgekehrt ist ein fachlich guter Plan noch
kein Nachweis einer korrekt ausgeführten Maske oder Tonwertkurve.

Die klaren Korrekturfälle 03, 04 und 06 benötigen die vorgesehene
Korrekturrichtung. Ein Modell, das immer `no_op` oder immer Unsicherheit meldet,
besteht diese Fälle nicht. Bei Mischlicht oder geringer sichtbarer
Detailinformation ist eine begründete zurückhaltende Entscheidung zulässig;
unbelegte Sicherheit und erfundene Details sind es nicht.

### 3. Renderprüfung

Renderprüfungen setzen einen vorhandenen ausführbaren Korrekturadapter voraus.
Ohne ihn bleibt dieser Teil ausdrücklich `notRun`; die Analyseprobe darf nicht
als bestandene End-to-End-Korrektur ausgegeben werden.

Bewertet wird gegen einen unveränderten Referenzrender derselben Eingabedatei
mit identischer Farbverwaltung, Auflösung und Ausgabekodierung. Folgende Regeln
machen die Ziele messbar:

- **No-op:** Der Plan aktiviert keine Bearbeitung. Führt der Adapter trotzdem
  einen identischen Renderpfad aus, müssen dessen Pixel gegenüber dem
  unveränderten Referenzrender innerhalb der festgelegten numerischen Toleranz
  übereinstimmen. Eine andere Dateikodierung ist kein zuverlässiger
  Pixelvergleich.
- **Gezielte Aufhellung:** Die robuste mittlere Helligkeit der Zielregion steigt
  in der vorgesehenen Richtung. Der Anstieg in geschützten hellen Regionen muss
  wesentlich kleiner bleiben. Fall 04 verlangt diesen Unterschied ausdrücklich
  und kann nicht durch eine globale Belichtungserhöhung bestanden werden.
- **Lichter- und Schwarzschutz:** Zusätzliche gesättigte Pixel, verlorene
  Zeichnung sowie die Helligkeitsänderung geschützter Regionen werden gesondert
  gemessen. Die bloße Senkung des Weißpegels macht nicht sichtbare Außendetails
  in Fall 10 nicht wiederherstellbar und darf nicht als Wiederherstellung
  verlorener Sensordaten gewertet werden.
- **Farb- und Stimmungsschutz:** Schneeschatten, Haut, warmes Abendlicht,
  Lampenlicht und dunkles Fell werden getrennt betrachtet. Starke Änderungen
  von Farbton oder Chroma dürfen nicht durch eine bessere globale
  Helligkeitskennzahl verdeckt werden.
- **Motivtreue:** Geometrie, Alpha und Bildinhalt bleiben erhalten. Säume an
  Fenstern und Personen, Flecken und erfundene Details werden zusätzlich visuell
  geprüft. Ein einzelner globaler Qualitätsscore ersetzt diese Prüfung nicht.

Regionen werden im Erwartungsmanifest als normalisierte Rechtecke oder Masken
angegeben. Der Ursprung liegt links oben im orientierten Eingabebild, `x` wächst
nach rechts und `y` nach unten; die Koordinaten liegen zwischen 0 und 1. Für jede
Region wird dokumentiert, ob sie Ziel, Schutzbereich oder reine Messfläche ist.
Randbereiche und Motivkanten sind bei Messungen gegebenenfalls auszunehmen,
damit eine grobe Rechteckregion nicht andere Bildteile mitbewertet.

Messfarbraum, Transferfunktion, Helligkeitsdefinition, Quantile,
Clippinggrenzen, minimale Änderung und maximale zulässige Nebenwirkung gehören
zur Version des Testvertrags. Numerische Grenzen werden vor dem Modellvergleich
festgelegt und am tatsächlich gespeicherten Bild überprüft. Sie sind
Testtoleranzen, keine nachträglich erfundenen Kamera-EV oder allgemeingültigen
Fotogesetze. Planwerte sind erst nach der dokumentierten Zuordnung zu den
Glowroom-Reglern vergleichbar.

## Protokollierung und Aussagegrenzen

Ein Prüfbericht enthält je Bild die getrennten Ergebnisse für Quelle, Schema,
Motiv-/Lichterkennung, Plan, Render und Sichtprüfung. Jedes Pflichtkriterium wird
einzeln als bestanden, fehlgeschlagen, manuell zu prüfen oder nicht ausgeführt
ausgewiesen. Mittelwerte dürfen einen Fehler bei Schnee, Haut, No-op oder
selektiver Bearbeitung nicht verbergen. Modellantwort, verwendeter Plan und
gerenderte Ableitung bleiben getrennte lokale Artefakte; Originale werden nie
überschrieben.

Die maschinenlesbaren Zustände unterscheiden:

| Zustand | Bedeutung |
| --- | --- |
| `missingFixtures` | Benötigte lokale Dateien fehlen; keine fachliche Bewertung möglich. |
| `fixtureInvalid` | Ein vorhandenes Fixture verletzt Quellenidentität oder Eingabeprüfungen. |
| `schemaError` | Die Modellantwort verletzt den vereinbarten Antwort- oder Reglervertrag. |
| `failed` | Mindestens ein ausgewertetes Pflichtkriterium ist verletzt. |
| `notRun` | Der jeweilige Prüfschritt wurde nicht ausgeführt, etwa mangels Renderadapter. |
| `manualReview` | Für die Entscheidung fehlt noch eine erforderliche semantische oder visuelle Sichtung. |
| `abstained` | Das Modell enthält sich einer fachlichen Entscheidung; dies ist kein allgemeiner Erfolg. |
| `passed` | Alle Pflichtkriterien des ausgewiesenen Prüfschritts wurden tatsächlich geprüft und bestanden. |

Analyse, Plan und Render dürfen unterschiedliche Zustände haben. Eine in Fall 07
erlaubte Entscheidung `limitations_only` ist von einer in jedem Fall pauschal
ausgegebenen Enthaltung zu unterscheiden: Ihre Mischlichtanalyse und die leere
Bearbeitungsliste müssen trotzdem die erwarteten Kriterien erfüllen. Der Bericht
darf aus einem bestandenen Teil keinen vollständigen Korrekturerfolg ableiten.

Die Bilder prüfen weder RAW-Decodierung und Sensorreserven noch echtes
Sensorrauschen, Objektivfehler, HDR, Farbprofile verschiedener Kameras oder
vollständige Robustheit auf privaten Fotobibliotheken. Dafür bleiben die
vorhandenen Originalfotos und gesonderte, ausdrücklich gestartete reale
Fotoproben notwendig. Für Leistungsangaben müssen zusätzlich kalte und warme
Läufe, Bildvorbereitung, maximale Speichernutzung und die genaue Hardware
gemessen werden. Aus dem Vorhandensein der Fixtures folgt kein Qualitäts- oder
8-GB-Laufzeitnachweis eines Modells.

Die spätere Integration soll die vorhandenen Grundlagen für
[Bildanalyse](AI-IMAGE-ANALYSIS.md), [natürlichen Bildausgleich](NATURAL-BALANCE.md)
und [automatische Masken](AUTOMATIC-MASKS.md) berücksichtigen. Lokale
Modellinferenz verwendet weiterhin das gemeinsame Ressourcenbudget. Unabhängige
Dateiprüfung und Auswertung können begrenzt parallel laufen; gleichzeitiges
Laden mehrerer großer Modelle würde die Speicherprüfung verfälschen.

## Manifestkonvention

`expectations.json` verwendet `schema_version: 1` und eine Liste `cases`. Jede
Fallkennung ist eindeutig; Quelldateien und Regionskennungen werden relativ zum
expliziten Fixture-Verzeichnis beziehungsweise zum jeweiligen Fall aufgelöst.
Das Manifest gehört ausschließlich zum Evaluator und wird nicht an das Modell
weitergegeben.

| Feld | Vertrag |
| --- | --- |
| `source.file` | Neutraler lokaler Dateiname wie `ai_correction_07.png`; kein absoluter Pfad. |
| `source.sha256` | SHA-256 der tatsächlich gespeicherten vollständigen Quelldatei. |
| `source.width`, `source.height`, `source.mode` | Tatsächliche decodierte Bildmaße und Kanalmodus. |
| `source.color_interpretation` | Für diese unprofilierten Raster `assumed_sRGB_IEC61966-2-1`; eine dokumentierte sRGB-Annahme, kein nachgewiesenes eingebettetes Profil. |
| `source.embedded_icc` | `false`; ein später hinzugefügtes ICC-Profil ändert den Quellenvertrag. |
| `semantics.required_tag_groups` | Erforderliche Konzeptgruppen mit gleichwertigen akzeptierten Tags; je Gruppe muss mindestens eine passende positive Aussage belegt sein. Negationen zählen nicht als positiver Treffer. |
| `semantics.forbidden_tags` | Fallbezogene falsche oder widersprüchliche positive Behauptungen; ihr Auftreten ist `failed`. |
| `semantics.allowed_positive_tags` | Vorab geprüfte zutreffende Tags einschließlich sichtbarer Nebendetails; andere Zusatz-Tags benötigen `manualReview`. |
| `plan.accepted_decisions` | Für den Fall erlaubte Planentscheidungen, zum Beispiel `no_op` oder in Fall 07 `limitations_only`. |
| `plan.requires_empty_edits` | Verlangt eine leere Liste ausführbarer Bearbeitungen, wenn `true`. |
| `plan.required_edit_rules` | Fallbezogene Pflichtregeln für tatsächlich erforderliche Korrekturen; zusätzliche Grenzen werden im Manifest ausdrücklich benannt. |
| `regions[].id`, `regions[].role` | Eindeutige Kennung und Zweck einer Mess-, Ziel- oder Schutzregion. |
| `regions[].rect_xyxy` | Normalisierte Grenzen `[x_min, y_min, x_max, y_max]` im orientierten Bild mit Ursprung links oben; `x_min < x_max` und `y_min < y_max`. |
| `render.checks` | Benannte Renderprüfungen mit den benötigten Regionen, Messdefinitionen und Grenzen; keine bloßen Freitext-Erwartungen. |
| `fixture_validation` | Vorbedingungen an das tatsächliche Eingaberaster, etwa Helligkeit und erkennbare Kontraste. Sie verhindern die Bewertung gegen einen nicht passenden Fixture. |

Die Schemanummer bezeichnet den Vertrag, ersetzt aber keine Bildidentität.
Dateihash und Fixture-Validierung müssen für jeden Lauf übereinstimmen.
Ungültige Maße, nicht endliche Messgrenzen, fehlende referenzierte Regionen oder
Rechtecke außerhalb von `[0, 1]` sind `fixtureInvalid`. Eine Änderung der
Semantik-, Plan- oder Messregeln wird versioniert und vor dem nächsten
Modellvergleich erneut geprüft; sie darf nicht nach Kenntnis einzelner
Modellergebnisse stillschweigend erfolgen.
