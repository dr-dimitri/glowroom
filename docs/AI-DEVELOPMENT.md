# KI-Korrektur in Entwickeln

**KI-Korrektur** ist eine Gruppe im gemeinsamen Arbeitsbereich **Entwickeln**. Kopfzeile und Darstellungsmenü bieten **Bibliothek** und **Entwickeln**. Der Gruppenwechsel zu **Licht**, **Farbe** oder **Details** verwendet dasselbe Foto, dieselbe Vorschau, denselben Bildstand und dieselbe Speicherung. Im Bildfokus öffnen Menü und Dock dieselben Gruppen.

Die KI-Gruppe enthält den ausdrücklich auszulösenden Qwen-Auftrag. Vorhandene Zugänge zu Bildtexten, Suche und Modellverwaltung bleiben erreichbar, bis die zugehörigen Navigationsissues sie konsolidieren. Die Funktionen verwenden ihre jeweiligen Modelle; Qwen ersetzt weder Masken-/Suchmodelle noch den lokalen Systemanbieter für Bildtexte.

Ein reiner Gruppen-/Panelwechsel startet keine Inferenz. Beim Einklappen von KI-Korrektur, Verbergen der rechten Spalte oder Wechsel zum Bildwerkzeug werden laufende Vorschläge abgebrochen und unbestätigte Ergebnisse verworfen. Die Rückkehr benötigt einen neuen ausdrücklichen Auftrag. Bereits angenommene Bearbeitungen und Speicheraufträge laufen weiter. Ein Fokuswechsel erhält den gemeinsamen Bearbeitungskontext; wenn er die KI-Gruppe verbirgt, gilt derselbe Vorschlagsabbruch. Veraltete Ergebnisse werden zusätzlich anhand von Quelle, Auswahl und Bearbeitungsgeneration abgewiesen.

## Qwen einrichten und entfernen

**Modelle → LLM-Modelle verwalten** zeigt Qwen3.5-4B in der lokalen
4-Bit-Variante `mlx-community/Qwen3.5-4B-4bit`. Der erste Katalog enthält genau
dieses Modell; weitere Modelle benötigen einen eigenen geprüften Deskriptor und
Laufzeitadapter. Revision und Dateiprüfsummen stehen im `LLMModelDescriptor`.

- **Download:** 3.061.129.077 Byte, etwa 3,06 GB. Der Dialog zeigt zusätzlich die
  logische Größe der vorhandenen Modelldateien im privaten Verzeichnis und den für die
  Einrichtung erforderlichen freien Speicher.
- **Herunterladen** benötigt Internetzugang zu Hugging Face. Höchstens zwei
  Dateien werden gleichzeitig auf Platte übertragen; große Gewichte werden
  gestreamt und nicht vollständig in den Arbeitsspeicher geladen.
- Downloadfortschritt, Abbruch und Fehler sind sichtbar. Erst nach Prüfung aller
  Größen und SHA-256-Digests wird eine vollständige Installation atomar
  veröffentlicht. Abbruch oder Netzfehler aktivieren kein Teilmodell. Temporäre
  Dateien brauchen zusätzlichen Speicher; die Kapazität wird vorab geprüft.
- **Modell löschen** entfernt die von Glowroom verwaltete Installation. Ein
  aktiver Modellaufruf hält eine Lease und verhindert die Löschung. Fotos und
  bereits übernommene Bearbeitungen benötigen das Modell anschließend nicht.

Die Gewichte liegen unter `~/Library/Application Support/Glowroom/Models/LLM/`.
Sie gehören weder zum Git-Repository noch zum App-Bundle. Export- und Sicherungsziele schützen den Modellordner auch bei einem abweichenden Katalogverzeichnis. Apple Silicon und
Metal sind Voraussetzung für Qwen. Die native Swift-Laufzeit und ihre separaten
App-Ressourcen stehen unter [Qwen-Laufzeit](AI-QWEN-RUNTIME.md). Nach dem
Download arbeitet die Inferenz offline; Fotos werden nicht hochgeladen.

## Bildwirkung steuern

Ein Auftrag in eigenen Worten beschreibt die gewünschte Korrektur. Kurze
Auftragsvorgaben füllen das Auftragsfeld aus. Sie gelten ausschließlich für den nächsten
mit **Vorschlag erstellen** gestarteten Auftrag und ändern weder die aktuelle
Bildvorschau noch gespeicherte Einstellungen. Es gibt einen Satz direkter
Licht-/Farbregler: die regulären Gruppen **Licht** und **Farbe** sowie die lokalen
Regler einer Maske. Die erweiterten Vorgaben enthalten die ausdrücklich benannte
Stärke für den nächsten Vorschlag; anfänglich werden geprüfte Zielwerte zu
50 % mit dem aktuellen Stand gemischt. 0 erhält den aktuellen Stand,
100 % verwendet den vollständigen Modellvorschlag.

Vor dem Start sind **Auftrag** und **Zielbereich** sichtbar: **Gesamtes Bild** oder
der Name einer vorhandenen aktiven Maske. Fehlende Fotos, unzugängliche Masken
und ein fehlendes Modell bieten die zugehörige nächste Aktion. Der Startknopf
wird während der Arbeit an derselben Stelle durch Fortschritt und **Abbrechen**
ersetzt. Solange nur eine vorläufige Bildstufe geladen ist, bleibt der Start
bis zur vollständigen Vorschau gesperrt. Panelöffnung und die Auswahl einer
Auftragsvorgabe starten keine Inferenz.

**Vorschlag erstellen** übergibt die aktuelle entwickelte Vorschau und die
unterstützten aktuellen Reglerwerte an das Modell. Die Vorbereitung verwendet
die vorhandenen begrenzten Decoder- und Vorschau-Caches mit maximal
1024 Pixeln langer Kante. Wiederverwendung setzt dieselbe native Dateiversion
voraus; ein extern ersetztes Foto darf auch bei erhaltener Größe und Änderungszeit
keine alten Pixel an das Modell liefern. Fehlt eine so geprüfte Basis im Cache,
wird sie beim ausdrücklichen Auftrag geladen. Eine Reglerbewegung startet weder
Inferenz noch RAW-Decodierung.

Ein gültiger Korrekturvorschlag wird auf derselben Bildfläche mit demselben
Zoom, Beschnitt und derselben Quelle gerendert. **Aktueller Stand** und
**Vorschlag** wechseln die Ansicht; die Bildfläche kennzeichnet den Vorschlag
ausdrücklich. Navigator, Originalvergleich, Export und Speicherung verwenden bis zur Übernahme weiterhin die angenommenen
Einstellungen. Der Vorschlag bleibt ein flüchtiger Prüfstand. Seine Darstellung
verwendet die bereits decodierte Bildbasis und den begrenzten Vorschau-Renderer;
der Ansichtswechsel benötigt weder Modellinferenz noch erneute RAW-Decodierung.

Unterstützt sind Belichtung, Kontrast, Lichter, Tiefen, Weiß, Schwarz, Dynamik,
Sättigung, Temperatur und Tönung. Alle anderen Einstellungen bleiben erhalten.
Der **Zielbereich** begrenzt die Korrektur auf das gesamte Bild oder die benannte
aktive Maske. Qwen erzeugt keine neuen Bildpixel oder Retuschen.

**Übernehmen** aktiviert genau die geprüften Werte mit der normalen Speicherung
und einem gemeinsamen Rückgängig-Schritt. Ein bereits gerenderter gültiger
Vorschlag benötigt dafür keine weiterhin installierten Modellgewichte; das
Modell ist nur für einen neuen Auftrag erforderlich. Die regulären Licht-/Farbregler zeigen
danach diese tatsächlich angenommenen Werte. **Rückgängig** stellt den gesamten
vorherigen Bildstand wieder her. Die Vorgaben in KI-Korrektur bleiben Vorgaben
für einen späteren Auftrag. Enthält die Antwort keine wirksame Wertänderung
(auch bei Stärke 0), bleibt **Übernehmen** deaktiviert und **Keine Änderung
vorgeschlagen** ist von Fehler und Abbruch unterscheidbar. Es entsteht kein
leerer Bearbeitungs- oder Erfolgseintrag.

**Verwerfen** verändert kein Foto. Ein Ergebnis nach
Foto-/Quellenwechsel, zwischenzeitlicher Bearbeitung (auch nach Undo), neuem
Auftrag oder Abbruch darf nicht übernommen werden. Vor der Übernahme wird die
native Quellenidentität erneut im Hintergrund geprüft. Wurde die Datei außerhalb
von Glowroom ersetzt, verhindert diese Prüfung die Übernahme; **Foto neu laden**
lädt anschließend die neue Quelle. Bei geänderter Dateigröße oder Änderungszeit
bietet **Ordner aktualisieren** die passende Aktion. Anschließend wird auch der
Bearbeitungskontext erneut geprüft. Der Abschluss einer Hintergrundspeicherung derselben
bereits angenommenen Einstellungen entwertet einen Vorschlag nicht. Quelle,
Einstellungen, Bearbeitungs- und Auswahlgeneration sowie Store-Epoch müssen
unverändert bleiben; die strikten Persistenzprüfungen der Datenbank gelten
weiterhin. Auch während der kurzen exklusiven Phasen eines automatischen
Backups bleibt der Vorschlag erhalten. Übernehmen ist in dieser Zeit gesperrt;
beginnt die Sperre während der Quellenprüfung, bleibt der Vorschlag für eine
erneute Übernahme verfügbar. Abgebrochene native Arbeit behält ihren Inferenzplatz
bis zum tatsächlichen Ende; vorher wird keine neue Anfrage gestartet.

## Vorhandene Masken gezielt entwickeln

Unter **KI-Korrektur → Zielbereich** stehen **Gesamtes Bild** und alle am Foto
vorhandenen Masken. Wähle beispielsweise die Maske **Blumenstrauß** und gib
„Etwas heller und wärmer“ ein. **Vorschlag erstellen** und **Übernehmen** ändern
nur die Regler dieser gewählten Maske. Name, Form, Pinselkorrekturen, Invertierung,
Deckkraft, Reihenfolge und die übrigen Masken bleiben erhalten; globale Werte
werden nicht verändert. Für mehrere Masken nacheinander die jeweilige Maske
wählen. Ausgeblendete Masken und Masken mit Deckkraft 0 müssen vor dem Auftrag
im Werkzeug **Maskieren** aktiviert werden.

Der Vorschlag nennt die Zielmaske und zeigt die lokale Bildwirkung auf der gemeinsamen Bildfläche.
Auch **Wärme** ist lokal verfügbar: **Masken → Farbe → Weißabgleich** enthält
Temperatur und Tönung. 6500/0 sind neutrale relative Werte auf dem bereits
entwickelten Bild. Alte Masken erhalten diese neutralen Werte; vorhandene
Speicherbytes bleiben ohne Farbänderung identisch.

Das Modell erhält die entwickelte vollständige Bildbasis ohne Beschnitt,
Drehung oder Spiegelung; die Umgebung außerhalb der gewählten Maske wird nur
für diese Analyse abgedunkelt. Der Auftrag erklärt diese Markierung ausdrücklich.
Gespeicherte Bilddaten bleiben davon unberührt. Eine entfernte, ausgeblendete
oder zwischenzeitlich veränderte Maske führt zu einem neuen Auftrag oder einer
Fehlermeldung, niemals zum stillen Wechsel auf eine globale Korrektur.

## Objektmasken im gemeinsamen Maskenwerkzeug

Neue Masken entstehen unter **Entwickeln → Maskieren**. **Objekt beschreiben**
fordert dort eine Auswahl per Auftrag an; Überlagerung, **Übernehmen**,
**Verwerfen**, Maskenliste und Pinselverfeinerung bleiben in diesem Werkzeug.
Die frühere Aufgabe **Neue Maske** in KI-Korrektur entfällt. Den vollständigen
Ablauf beschreibt [Masken bearbeiten](MASK-EDITING.md); Modellpfad, Einrichtung
und Grenzen stehen unter [Automatische Masken](AUTOMATIC-MASKS.md).

Für eine anschließende KI-Korrektur dieselbe angenommene Maske unter
**Zielbereich** wählen. KI-Korrektur verändert nur deren lokale Regler;
Maskenname, Auswahl, Pinselkorrekturen, Invertierung, Deckkraft und Reihenfolge
bleiben erhalten. Neue Objektmasken und Korrekturvorschläge nutzen dieselben
Quellen-, Auswahl- und Bearbeitungsgarantien, werden aber jeweils im zugehörigen
Werkzeug geprüft und ausdrücklich übernommen.

## Qualität und Ressourcen

Die [frühere Evaluation](AI-QWEN35-EVALUATION.md) war keine Freigabe für
unbeaufsichtigte automatische Korrektur. Der neue Bereich ist eine ausdrücklich
ausgelöste Vorschlagsfunktion mit Übernahmeprüfung. Fachliche Fehleinschätzungen
und unveränderte Vorschläge sind möglich. Ein technischer Produkttest belegt
keine allgemein zuverlässige fotografische Automatik.

Der Modelloutput ist durch eine JSON-Grammatik begrenzt und wird anschließend
erneut auf bekannte Felder, Zahlen, Wertebereiche und Größe geprüft. Ungültige
oder unvollständige Antworten werden vollständig abgelehnt; es gibt keine
automatische Antwortreparatur. Das Modell hat keine Schreib-, Shell- oder
Werkzeugrechte.

Die lokale Modellarbeit teilt eine einzelne `AIResourceBudget`-Lease mit anderen
KI-Diensten. Die deklarierte Reservierung von 5 GiB ist eine Zulassung, keine
harte Speichergrenze. Es werden keine Leistungsversprechen aus den historischen
Python-Messwerten abgeleitet. Dateiübertragungen und unabhängige Vorbereitung
laufen begrenzt parallel; Veröffentlichung, Übernahme und Löschung bleiben
wegen ihrer Abhängigkeiten geordnet.

## Prüfungen

Standardtests verwenden temporäre Stores, synthetische Bilder und kontrollierte
Modellantworten. Sie laden keine Gewichte herunter und führen keine echte
Inferenz aus. Geprüft werden Antwortgrenzen, Stärke, Erhalt übriger Einstellungen,
explizite Übernahme/Undo/Redo, persistierte Werte, veraltete Antworten, Abbruch,
Installationsprüfsummen, atomare Veröffentlichung und Schutz aktiver Modelle.
Zusätzliche Regressionen prüfen unveränderte Vorschläge und den Speicherabschluss
während Inferenz, Vorschlagsprüfung und Übernahme. Ein gemounteter nativer Test
bedient die tatsächlichen Schaltflächen mit kontrollierter Modellantwort,
echter Quellenprüfung und synthetischer PNG-Datei. Er prüft Reglerwerte,
geänderte Vorschaupixel, Undo/Redo und Speicherung ohne echte Modellinferenz.

Ein optionaler nativer Produkttest mit einem bereits vorhandenen lokalen
Qwen-Snapshot lässt sich ausdrücklich aktivieren:

```sh
GLOWROOM_QWEN_MODEL_PATH=/absoluter/pfad/zum/qwen-snapshot \
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-ai-tests \
./scripts/test.sh --jobs 4 --filter QwenNativeModelTests
```

Er verwendet ein synthetisches Bild und die tatsächliche Swift-/Metal-Inferenz
einschließlich JSON-Grammatik und Antwortvalidierung. Die lokalen Testfotos
sind dafür nicht erforderlich. Ein sauberer vollständiger App-Build bleibt für
Änderungen an dieser Produktfunktion gemäß `AGENTS.md` erforderlich.

## Maskenprüfung und optionale Modelltests

Die Standardtests prüfen Maskenbindung, unveränderte globale Werte, lokale
Temperatur/Tönung, alte Speicherformate, Maskenstärke, Invertierung und
Pinselkorrekturen, Quellengeometrie, ungültige Objektregionen, Speichergrenzen,
Abbruch, native Übernahme und gemeinsame Undo-/Redo-/Speicherstände. Sie
benötigen keine privaten Testbilder und führen keine echte Modellinferenz aus.

`AIObjectMaskNativeTests` prüft mit gesetztem `GLOWROOM_QWEN_MODEL_PATH` zusätzlich
am synthetischen Bild die Lokalisierung eines asymmetrisch positionierten roten Ovals
bei einem grünen Ablenkungsobjekt. Für eine ausdrücklich gewünschte lokale
Fotoprüfung werden drei Pfade gesetzt; das Ausgabeziel muss ein neues Verzeichnis
unter einem bereits vorhandenen Elternordner sein:

```sh
GLOWROOM_QWEN_MODEL_PATH=/absoluter/pfad/zum/qwen-snapshot \
GLOWROOM_QWEN_MASK_TEST_IMAGE=/absoluter/pfad/zum/testfoto.jpg \
GLOWROOM_QWEN_MASK_TEST_OUTPUT=/tmp/glowroom-masken-neue-pruefung \
./scripts/test.sh --jobs 4 --filter AIObjectMaskNativeTests
```

Der optionale `GLOWROOM_QWEN_MASK_TEST_INSTRUCTION` überschreibt den Standardauftrag
„Maskiere den gelben Blumenstrauß im Vordergrund.“. Der Produkttest verwendet den
echten Vorbereitungs-/Inferenzpfad und prüft unveränderte Originalbytes. Er legt
`response.preview.png`, `response.json` und `Layer.json` ausschließlich im neuen
Ausgabeordner ab. Private Fotos und abgeleitete Prüfbilder werden nicht committet.
Für diesen vollständigen Fototest muss auch BiRefNet lokal eingerichtet sein.
Die Sichtprüfung bleibt notwendig: gültige Geometrie belegt keine genaue Auswahl.

Objektantworten enthalten nur Name, Zusammenfassung und eine Box
`[links, oben, rechts, unten]` mit vier ganzen Zahlen auf einer Skala von 0 bis
1000. Die Box dient der Lokalisierung, nicht als gespeicherte Maske. Ein kleiner
Rand von 5 % je Boxdimension bewahrt knapp lokalisierte Objektkanten; die
Segmentierungsmaske wird in die vollständigen Quellkoordinaten zurückprojiziert.
Antworten bleiben auf 768 Tokens und 16 KiB begrenzt. Für Objektantworten
unterdrückt die vorhandene native Laufzeit lange reine Leerraumfolgen; normale
Reglerantworten behalten ihren bisherigen Inferenzmodus. Teilantworten werden
weder ergänzt noch übernommen, JSON-Schließzeichen werden nicht erzwungen.
Die optionalen Qwen-Produkttests verwenden dieselbe Inferenzzulassung.

## Integrationsprüfung am 23. Oktober 2026

Der vollständige Standardlauf bestand mit **1512 Tests in 202 Suites**. Zuvor
bestanden die zuletzt betroffenen 54 Regressionstests separat. Die echte native
Qwen-Inferenz wurde zusätzlich mit vorhandenen lokalen Gewichten ausgeführt;
Einzelheiten und Grenzen stehen im [Laufzeitnachweis](AI-QWEN-RUNTIME.md).
Die native Oberfläche wurde bei 1000 × 660 und 1440 × 900 geprüft und visuell
kontrolliert. Dafür kamen synthetische Bilder zum Einsatz, keine privaten Fotos.

Das abschließende unabhängige Review umfasste UI/Workspace, Metadatenentwürfe,
Installations- und Löschpfade, Quellenbindung, Antwortvertrag, Abbruch,
Ressourcenfreigabe und Paketierung. Gefundene Lücken bei wiedergeöffneten
Metadatenentwürfen, dem Schutz des gemeinsamen Modellverzeichnisses und der
Zuordnung von Pixeln zur nativen Dateiversion wurden behoben und nachgeprüft;
es blieben keine offenen Befunde. Beim vollständigen Lauf gefundene bestehende
Bereitschaftsrennen in Tests wurden ebenfalls behoben, ohne fachliche Assertions
oder Produktionsfristen zu lockern; siehe [Testsynchronisierung](TEST-SCHEDULING.md).

Die Tests laufen intern parallel. Der abschließende Release-Build folgt der
Vollsuite geordnet, damit deren native UI-/Abbruchproben nicht mit der vollständigen
C++-/Swift-Kompilierung um CPU und Speicher konkurrieren. Die Implementation und
Reviews wurden nach getrennten Dateiverantwortungen parallel bearbeitet.

Der abschließende saubere Release-Build mit `./scripts/build-app.sh` war
erfolgreich (SwiftPM-Kompilierung 322,23 Sekunden). Zuvor wurden laufende Prozesse
geprüft und die generierten Buildverzeichnisse sowie das alte App-Bundle entfernt.
`codesign --verify --strict` und die SHA-256-Prüfung der gebündelten
Metal-Bibliothek bestanden. Das Executable bindet Systembibliotheken, keine
lokale Python- oder Testing-Laufzeit. Ein vorläufiger sauberer Build wurde wegen
der zwischenzeitlich gefundenen Testkorrekturen bewusst abgebrochen; sein
Teilstand wurde vor diesem erfolgreichen Abschluss vollständig entfernt.

## Auftragsregler und Übernahmeprüfung am 23. Oktober 2026

Die Auftragsregler blieben nach der Übernahme absichtlich unverändert, wirkten
aber wie direkte Bildregler. Die Oberfläche benennt ihren Zweck jetzt ausdrücklich
und verweist auch in der Erfolgsmeldung auf die tatsächlichen Werte unter
**Entwickeln**. Die gemeldete Kombination Weiß 0 → 5, Dynamik 0 → 10 und
Temperatur 6500 → 6650 bei 50 % Stärke wird im nativen Test genau übernommen
und verändert die gerenderten Pixel. Diese dezenten Werte sind kein Nachweis
eines allgemeinen Rendererfehlers. Die irrtümlich umgekehrte Temperaturrichtung
im Modellprompt wurde an Renderer und vorhandene Farbtests angepasst: höhere
Werte wärmen, niedrigere kühlen das Bild.

Zusätzlich gefundene Übernahmefehler wurden behoben: unveränderte Vorschläge
können nicht mehr als erfolgreiche Bearbeitung angenommen werden. Ein reiner
Persistenzabschluss und die kurzen automatischen Backup-Sperren verwerfen
keinen weiterhin gültigen Vorschlag. Die Annahme bleibt während der Sperren
geschlossen; spätere Bild-/Quellenwechsel, Bearbeitungen, Undo und Abbruch
entwerten den Vorschlag weiterhin.

Die gezielte Prüfung bestand mit **28 Tests in 7 Suites**. Sie umfasst die
gemounteten nativen Übernahme-Buttons, normale Regler einschließlich Temperatur,
geänderte Vorschaupixel, Undo/Redo, echte Quellenprüfung, persistierte Werte und
erneutes Öffnen sowie kontrollierte Speicher- und Wartungsabläufe. Die Tests
nutzen synthetische PNG-Dateien und kontrollierte Modellantworten; sie benötigen
weder private Testbilder noch neue Modellinferenz.

Der erste vollständige Lauf scheiterte an einer fehlenden Testvorbedingung:
direktes Redo fiel in die reale automatische Backup-Sperre. Die native Regression
drainiert jetzt das Tagesbackup und prüft die unmittelbare Undo-/Redo-Annahme,
bevor sie die gerenderte Vorschau abwartet. Keine Frist wurde erhöht. Der
anschließende vollständige Paralleltest bestand mit **1516 Tests in 203 Suites**
in 44,541 Sekunden. Logs: `/tmp/glowroom-ai-apply-integration.log`,
`/tmp/glowroom-ai-apply-full.log` (Fehllauf) und
`/tmp/glowroom-ai-apply-full-verified.log` (erfolgreicher Vollvergleich).

Das unabhängige Diffreview umfasste Controller-/Persistenzgrenzen, UI,
Quellenbindung, Prompt, Tests und Dokumentation. Der dabei gefundene
Backup-Lebenszyklusfehler wurde korrigiert und durch beide exklusiven
Wartungsphasen nachgeprüft; es bleiben keine offenen Befunde. Implementierung
und Review liefen mit getrennten Dateiverantwortungen parallel. Vollsuite und
sauberer App-Build bleiben wegen CPU-/Speicherbedarf und nativer UI-Prüfungen
geordnet; es werden keine neuen Leistungsgewinne behauptet.

Ein sauberer vollständiger App-Build war erforderlich, weil Controller,
Oberfläche und Modellprompt das Laufzeitverhalten ändern. Nach Ende aller
Tests und dem durch den Nutzer vorgenommenen Beenden der laufenden App wurden
die generierten `.build`-Produkte, Compiler-/Icon-/Shader-Caches und das alte
`dist/Glowroom.app` entfernt. `GLOWROOM_BUILD_PATH` war nicht gesetzt,
`.build-app` war nicht vorhanden; Abhängigkeitsquellen und Lockdateien blieben
erhalten. **`GLOWROOM_BUILD_JOBS=4 ./scripts/build-app.sh` bestand als sauberer
vollständiger Release-Build** (SwiftPM-Kompilierung 297,41 Sekunden).
Info.plist-Validierung, ad-hoc Signierung und strikte Signaturprüfung bestanden.
Log: `/tmp/glowroom-ai-apply-clean-build.log`. Die abschließende Dokumentation
der Ergebnisse beeinflusst den Build nicht.

## Gemeinsame AI-Masken: Prüfung am 23. Oktober 2026

Die gezielte Integration besteht mit **57 Tests in 13 Suites**. Dazu gehören
die tatsächlichen Übernahme-Buttons, lokale Temperatur/Tönung, alte kanonische
Snapshotbytes, Quellengeometrie, Maskenwechsel und -löschung, Undo/Redo,
Speichergrenzen sowie Abbruch vor und während der getrennten Modellphasen.
Das unabhängige abschließende Diff-Review hat keine offenen Befunde ergeben.

Zwei ausdrücklich aktivierte native Produkttests mit bereits installierten
lokalen Modellen bestehen. Qwen lokalisiert das synthetische rote Oval mit
einer Box von [545,125,850,475] gegenüber [550,120,850,480]; der Test fordert
mindestens 0,6 IoU und schließt das Ablenkungsobjekt aus. Der vollständige
Fotopfad lokalisiert den gelben Blumenstrauß und erzeugt mit BiRefNet eine
sichtgeprüfte Maske mit Blüten, Stielen und Vase. Originalbytes bleiben
unverändert. Das belegt diese beiden Fälle, keine allgemeine semantische
Zuverlässigkeit; insbesondere gehört die Vase in diesem Vorschlag mit zur
Auswahl. Private Prüfbilder und Ergebnisse bleiben außerhalb von Git.

Die zuerst untersuchten frei erzeugten Qwen-Polygone wurden wegen ungenauer
Konturen verworfen. Ein vorheriger Modelllauf scheiterte an unvollständigem
JSON, weitere an der Zeitgrenze; die Untersuchung fand lange Leerraumfolgen.
Die finale kompakte Boxantwort und begrenzte Leerraumunterdrückung bestehen
den nativen Test. Frühere gezielte Testbuilds scheiterten außerdem an einer
Swift-Initialisierungsreihenfolge beziehungsweise parallel geänderten
Quelldateien. Diese Ursachen sind behoben; der erfolgreiche finale
Integrationslauf wurde mit eingefrorenen Quellen durchgeführt. Befunde zur
Palettenhöhe, nativen Slider-Ansteuerung und bilinearer Masken-Testgeometrie
wurden ebenfalls korrigiert und erneut geprüft.

Implementierung und Reviews liefen in getrennten Verantwortungsbereichen
parallel. Native Modellläufe, Vollsuite, Bereinigung und App-Build folgen
geordnet, weil sie gemeinsame Inferenz-, UI- oder Buildressourcen verwenden.

Die abschließende vollständige Suite besteht mit **1547 Tests in 210 Suites**.
Wegen der Änderungen an Laufzeit, Renderer und Oberfläche war ein sauberer
vollständiger App-Build erforderlich. Nach Prüfung auf laufende Builds/Tests
wurden die generierten Compiler-, Modul-, Icon- und Laufzeitergebnisse in
`.build/` sowie das alte `dist/Glowroom.app` entfernt; Paketquellen, Downloads
und Locks blieben erhalten. `GLOWROOM_BUILD_JOBS=4 ./scripts/build-app.sh`
bestand anschließend einschließlich Bundle-, Plist- und Signaturprüfung.
Das neue Release-Bundle liegt unter `dist/Glowroom.app`. Es bleiben keine
offenen Review-, Test- oder Buildhindernisse.

## KI-Korrektur am Foto prüfen (UX-02, Issue 194)

Die native visuelle Abnahme und ihr reproduzierbarer Testaufbau stehen im
[Prüfprotokoll zu Issue 194](issue-194/README.md). Die Standardprüfungen verwenden
kontrollierte Modellantworten, synthetische Bilder und echte Vorschau-, Quellen-,
Undo- und Speicherpfade. Sie belegen keine neue Modellqualität. Der neue Ablauf
ändert weder Modellgewichte noch Antwortvalidierung oder KI-Fähigkeitsgrenzen.
Objektmaskenerstellung bleibt der bestehende gesonderte Auftrag; ihre fachliche
Konsolidierung gehört zu UX-03.
