# Präzise globale Tonwertkorrektur prüfen

Die synthetischen Tests benötigen keine lokalen Fotos. Ausführung mit
`./scripts/test.sh --jobs 3 --no-parallel --filter 'Levels|ToneMemoryBudgetTests'`.
Die geordneten Testfälle vermeiden Konkurrenz um den globalen macOS-Fensterserver
und native Metal-Kompilierung. Anwendung und Nebenläufigkeitstests behalten ihre
begrenzten parallelen Worker.

Für den vollständigen Katalog steht `./scripts/test-isolated.py` zur Verfügung
(Python 3). Das Skript kompiliert einmal und führt anschließend Core-Tests
gemeinsam sowie jede App-Testsuite in einem frischen Prozess aus. Nach einem
bereits vollständigen Testbuild kann `--skip-build` verwendet werden. Der
SDK-Katalog, disjunkte Testauswahl, regulärer Testabschluss und vollständige
xUnit-Ergebnisse werden gegeneinander geprüft; fehlende oder vorzeitig beendete
Tests gelten als Fehler. Berichte liegen in einem neuen temporären Verzeichnis.
Die Prozesse bleiben geordnet: AppKit-Animationen können auch bei seriellen
Testfällen prozessweite Ressourcen ansammeln und einen langen Einzelprozess
blockieren. Die Isolation behebt diese Testumgebungsgrenze, ohne Tests auszulassen.
Standardausgabe und Diagnoseausgabe werden getrennt erfasst, damit eine
SwiftPM-Warnung keine reguläre Abschlusszeile unterbricht.

Abnahme vom 24.10.2026: 1.676 SDK-Katalogmethoden in 171 disjunkten Gruppen sind
vollständig verifiziert. Zwei durch vermischte Diagnoseausgabe markierte Gruppen
wurden nach der Ausgabekorrektur erneut ausgeführt. Eine HDR-Vergleichsreferenz
wurde auf den tatsächlichen Float32-Ausgabevertrag korrigiert und ebenfalls
erneut geprüft; die numerische Toleranz bleibt unverändert. Die übrigen
abgeschlossenen Ergebnisse wurden per XML und Katalog erneut abgeglichen.
Optionale lokale Foto-/Modellprüfungen ohne ihre ausdrücklich gesetzten
Voraussetzungen bleiben als solche im Katalog mit dokumentiertem Skip erfasst.

## Numerische und integrative Abnahme

- Mindestens 1.024 Grauwerte sowie Farbfelder vergleichen den Float-Graphen mit
  einer unabhängigen skalaren Formel. Gamma 0,1/1/10, Einzelkanäle vor Master,
  beide Clamps, konstante Ausgänge, kleine gültige Eingangsspannen, negative
  Werte und HDR bis mindestens 4 sind eingeschlossen. Die Toleranz bleibt
  `1e-4 + 1e-5 * abs(reference)`.
- Alpha 0/0,25/1, feine Float-Bereichsgrenzen, einzelne nicht abgetastete
  Ausreißer, NaN/Inf, Potenz- und sRGB-Decodierungsüberläufe sowie ein Überlauf
  durch spätere Präsenz werden geprüft. Die HDR-Rasterausgabe muss auch große
  endliche Werte über 65.504 ohne Half-Float-Verlust erhalten.
- Neutrale Levels erhalten alte kanonische Bytes und den bisherigen Renderpfad.
  Vorschau und Export verwenden denselben Graphen, einschließlich SDR-P3;
  lokale Masken und eingefrorene Ersatzpixel wenden globale Levels einmal an.
- Der Eingangsbeweis wird bei reinen Levels-Änderungen wiederverwendet. Gleiche
  direkte Resizes teilen ihn; neue Quelle, geänderte Vorgänger, andere Maße,
  Half-/Float-Präzision und mehrstufiges Resampling entwerten ihn.
- Strikte JSON-Daten, Normalisierung, Backup/Restore, V1/V2-Erhalt, bewusste
  Umstellung, Reset und gruppiertes Undo/Persistenz werden geprüft. Montierte
  native Zahlenfelder decken Fokus ohne Rundung, zweimal Enter, Kanalwechsel,
  ersten Reset bei neutralem gespeicherten Wert und verspätete Ereignisse ab.

## Pipetten und akzeptierte Vorschau prüfen

Die Pipetten-Abnahme läuft mit
`./scripts/test.sh --jobs 3 --no-parallel --filter 'Levels|DevelopGeometry|AdjustedPreview|ArtifactPreview|DevelopPreviewIdentity|PreviewComparisonViewTests|AIDevelopmentAcceptanceTests'`.
Am 24.10.2026 bestehen 201 gezielte Tests in 26 Suites. Der vollständige
isolierte SDK-Katalog ist mit 1752 von 1752 Methoden in 180 Batches verifiziert.
Im ersten Gesamtlauf bestanden 1748 Methoden; zwei parametrisierte Fälle der
vier Methoden umfassenden Schärfungs-Suite enthielten noch die alte
Speicher-Sollrechnung. Nach ausschließlich dieser Testkorrektur wurden alle
vier Methoden erneut erfolgreich ausgeführt und die XML-Abdeckung sämtlicher
180 Batches erneut streng geprüft. Die Originalberichte bleiben erhalten.
Die aktuelle Resizephase zählt beide neuen Provider mit insgesamt 64 statt
32 Bytes pro Pixel; die exakte Gleichheitsprüfung und alle Budgetgrenzen
bleiben bestehen. Der saubere vollständige Release-Build besteht (437,33 s).
Zum Abschluss von #170 wurden seit diesem Build nur diese Testrechnung und
Dokumentation verändert; für diesen historischen #170-Stand war deshalb kein
weiterer App-Build erforderlich. #171 erhält einen eigenen sauberen Build. Der unabhängige finale
Diff-/Schnittstellenreview enthält keine offenen Befunde.

- Unabhängige skalare Fälle prüfen Schwarz/Weiß, `0.25 → Gamma 2`, Value nach
  aktiven Einzelkurven, die vollständige vorgeschlagene Masterinverse,
  unveränderte Fremdparameter, Wiederholung und atomare RGB-Neutralisierung.
- Float-Uniforms mit separater sowie kontrahierter Multiplikation/Addition und
  der tatsächliche native Levels-Knoten müssen das RGB-Grauziel innerhalb von
  acht Float-Einheits-ULPs treffen. Enge instabile Kurven werden abgelehnt;
  endliche Werte allein reichen für diese Neutralitätszusage nicht aus.
- Tatsächliche 5×5-Readbacks prüfen sRGB/P3, Alpha 0/0,25/1, Coveragegrenzen,
  abgeschnittene Randfenster, feinste Floatwerte, NaN/HDR und Encoding vor
  Mittelung. Ganze Originalbilder werden dafür nicht zur CPU zurückgelesen.
- Gerenderte Markierungsraster und native AppKit-Klicks prüfen gerundete
  adaptive Crops, Vierteldrehungen, Spiegelungen, freie Rotation, transparente
  Ecken, Zoom/Pan/Retina-Koordinaten und schmale geklemmte Crop-Ränder.
- Tests verzögern Sampling und vollständige Graphvalidierung unabhängig:
  Revisionen einschließlich Undo/Redo, Selection-A→B→A, Quelle, Profil,
  Geometrie, Retry/Pending, Read-only und Escape entwerten Erfolge und Fehler.
  Eingebettete Kameravorschauen und progressive Zwischenframes bleiben gesperrt.
- Ein akzeptierter Klick bildet genau einen Undo-/Persistenzschritt. Ein
  außerhalb des Messfensters liegender echter Float-Überlauf wird vor Übernahme
  erkannt. Speicherfehler bleiben sichtbar, angenommene lokale Änderungen
  können nach dem bestehenden Vertrag erneut gespeichert werden.
- Frame-/Provider-Tests prüfen schwachen Inputcache, Rekonstruktion in der
  besetzten begrenzten Lane, gemeinsame Aliasreservation sowie deren Freigabe.
  Schärfung, Retusche und lokale Stufen zählen in der vollständigen Admission.
  Die kleinen injizierten Speicherfixtures wurden rechnerisch um den neuen
  Eingangs-/Ausgangs-/Altframeplan erweitert; Ablehnungs-, Resize-, Float32-
  und Budgetprüfungen bleiben erhalten.

Ein vollständig deckendes einzelnes eingefrorenes Retuscheersatzfenster muss
denselben Original-Balancebezug und dieselbe Pre-Levels-Stufe wie der normale
Renderer verwenden. Unberührte/deaktivierte Stellen sind erlaubt, Mischungen,
Feather-/Clone-/Heal- und überlappende Bereiche werden kontrolliert abgelehnt.
Für diese synthetischen Abnahmen sind keine privaten Fotos oder RAWs erforderlich.

## Optionale lokale RAW-Messung

Nach dem normalen Testbuild, ohne konkurrierenden Build oder Benchmark:

```sh
GLOWROOM_TONE_RAW=/absoluter/pfad/zum/eigenen-bild.CR3 \
GLOWROOM_TONE_EDGE=4096 GLOWROOM_TONE_LEVELS=1 \
./scripts/test.sh --skip-build --no-parallel --filter ToneProcessingPerformanceTests
```

Die Datei muss ein tatsächliches Kamera-RAW sein; ohne `GLOWROOM_TONE_RAW` wird
nur diese optionale Messung übersprungen. `GLOWROOM_TONE_LEVELS=1` variiert
Master-Gamma statt Belichtung. Gemessen werden frische App-Caches, geänderte
warme Einstellungen, Ausgabecache, 24 schnelle Änderungen mit Zusammenfassung
sowie Prozess-Spitzenspeicher. Betriebssystem-/ImageIO-/Shader-Caches werden
nicht geleert. Ein Range-Nachweis und danach Cachetreffer sowie genau ein RAW-
Decode und ausschließlich die letzte angenommene Revision sind verbindlich.

Die temporäre JSON-Datei enthält private Quellidentitäten und bleibt lokal.
Originale, private Messdateien und abgeleitete Bilder gehören nicht in Git.
Anonyme Messwerte dürfen dokumentiert werden. Adaptive Auflösung und bestehende
Cachegrenzen bleiben aktiv; Cachemisses großer Ausgaben werden ausgewiesen.
Es werden weder UI-Latenz noch GPU-Residenz, Gerätevergleiche oder ein allgemeiner
Geschwindigkeitsgewinn gemessen.

### Lokale Messung vom 24.10.2026

Zwei tatsächliche Kamera-RAWs, nacheinander und ohne konkurrierenden Build oder
Benchmark; private Quellen und JSON-Berichte bleiben lokal. Unterschiedliche
Bildinhalte und Auflösungen erlauben keinen direkten Geräte-/Leistungsvergleich.

| Messung | A | B |
| --- | ---: | ---: |
| angeforderte maximale Kante | 4096 | 2048 |
| tatsächliche adaptive Ausgabe | 3546 × 2364 | 2048 × 1365 |
| Decode, frische App-Caches | 367 ms | 249 ms |
| erster zugelassener Render | 6684 ms | 190 ms |
| warme geänderte Gammawerte, vier Render | 2562–2629 ms | 39–48 ms |
| Float-Tonwertanalyse kalt / warm | 16617 / 16094 ms | 1148 / 1050 ms |
| letzter Render nach letztem Ereignis inklusive Zusammenfassung | 2722 ms | 109 ms |
| Ausgabecachetreffer | nein | ja |
| Prozess-Spitzenspeicher | 1088 MiB | 225 MiB |

Beide Messungen bestätigen genau einen RAW-Decode, höchstens einen gleichzeitig
aktiven Render, 23 verworfene von 24 schnellen Anfragen und ausschließlich
angenommene Revision 24. Die Levels-Bereichsanalyse läuft genau einmal; danach
folgen sieben beziehungsweise fünf Cachetreffer. Originaldateien bleiben laut
lokalem Vorher-/Nachher-Vergleich unverändert. Große Ergebnisse überschreiten
absichtlich den unveränderten 32-MiB-Ausgabecache. Die Laufzeit des großen Falls
und der separaten automatischen Tonwertanalyse ist ausdrücklich eine Grenze
dieser Arbeitslast; diese Messung verspricht keine interaktive Bildrate.

## Automatische Levels-Endpunkte (#171)

Die feste Richtlinie steht in `AutomaticLevelsPolicy`; sie ist zugleich die
Quelle für den reproduzierbaren Vergleichsbericht. Qualitätsgrenzen werden
nicht anhand nachträglicher Bildresultate gelockert. Die Referenz folgt nur
GIMPs dokumentiertem 0,6-%-Prinzip im ausdrücklich anderen Glowroom-Arbeitsraum;
rohe Minima/Maxima nach dem untersuchten darktable-Pfad ersetzen sie nicht.

Die obligatorische synthetische Abnahme benötigt keine privaten Bilder:

```sh
./scripts/test.sh --jobs 3 --no-parallel --filter 'AutomaticLevels|PairedLevelsClipping|AutomaticToneEstimatorTests|DevelopAutomaticToneTests'
```

Histogramm-Goldens stammen aus rationalen Binmassen, einschließlich exakter
Gleichstände, leerer Plateaus, Ausreißer und kleiner Probenzahlen. Paarweise
Clipping-Fixtures prüfen zusätzlich die Grenze 0,006N+1 und den Fall, dass
verschwundene alte Clip-Pixel neue Clip-Pixel an anderen Stellen nicht aufheben.
Die Bildfälle enthalten unter anderem flaue Rampen, Gegenlicht, Low-/High-Key,
gesättigte sRGB-/P3-Farben, unterschiedliche Alphaabdeckung, Glanzpunkte, Flat-
Fields und nahezu flache verrauschte Flächen. V1/V2 bleiben getrennt benannt.
Ungeeignete Referenzendpunkte werden ausdrücklich als nicht verfügbar/degeneriert
berichtet, statt durch Normalisierung in eine vorgetäuschte Referenz überzugehen.

Der optionale Vergleich schreibt lokale JSON-/HTML-/PNG-Artefakte in einen
frischen temporären Ordner. Er erfasst Eingaben, Profil/TRC, Endpunkte, Gates,
Clippingmassen und Gründe für ausbleibende Vorschläge. Private Testfotos sind
nur nach ausdrücklicher lokaler Auswahl einzubeziehen; Originale und abgeleitete
Fotodateien bleiben außerhalb von Git und GitHub. Synthetische Vergleichsbilder
sind kein Ersatz für eine benannte Fotoauswahl und begründen keine Überlegenheit
gegenüber GIMP oder darktable. Es werden keine Leistungsgewinne behauptet.

Nach einem erfolgreichen Testbuild lassen sich die Vergleiche ausdrücklich
lokal erzeugen:

```sh
GLOWROOM_LEVELS_REPORT=1 ./scripts/test.sh --skip-build --no-parallel \
  --filter optionalSyntheticPNGAndHTMLReport
GLOWROOM_LEVELS_LOCAL_IMAGES=/absoluter/pfad/zu/Fixtures/LocalTestImages \
  GLOWROOM_LEVELS_LOCAL_COVERAGE=/privater/pfad/motivzuordnung.json \
  ./scripts/test.sh --skip-build --no-parallel \
  --filter optionalPrivateJPEGReportIsSeparateAndLeavesEveryOriginalUnchanged
```

Die optionale private Zuordnung ist ein JSON-Objekt von Dateinamen auf
Motivlisten mit `lowContrast`, `backlit`, `lowKey`, `highKey`, `saturated`.
Sie ist eine manuelle Sichtannotation und keine numerische Groundtruth.
Fehlende Dateien, Fehler und fehlende Fotomotive stehen ausdrücklich im Bericht.
Keine dieser privaten Eingaben oder Ausgaben wird committet.

Der Review korrigiert außerdem die Gauß-Speicherplanung: je aktiver Struktur/
Klarheit zählen zwei RGBAf-Pässe mit 32 Bytes pro Pixel, sowohl in der
Endpunktanalyse als auch in der vollständigen Levels-Validierung.
`AutomaticLevelsAdmissionTests.precisePresenceCountsBothPassesOfEachActiveGaussian`
prüft beide Rechnungen exakt. Escape wird über den echten Workspace-Tastaturpfad
mit Fenster-, Button- und Textresponder sowie Fokus ein/aus geprüft.

Die Automatik-Schaltfläche bindet ihre eingefrorene Selection zusätzlich an die
**live** Session/Generation des Library-Modells. Ein synchroner A→B→A-Wechsel
muss bereits vor dem nächsten SwiftUI-Pending-Callback ablehnen. Der direkte
Library-Regressionstest prüft dies ohne View und ohne `await`; der ergänzende
native AX-Buttonfall prüft späte Worker-Erfolge und Fehler samt unveränderter
Persistenz. Ein alter Frame allein darf seine eigene alte Selection nicht als
aktuell bestätigen.

### Lokaler Vergleich vom 24.10.2026

24 synthetische Varianten (zwölf Motive jeweils V1/V2) und sieben ausdrücklich
lokale JPEGs bestehen die unveränderten unabhängigen Gates. Die mittlere
Graurampe wählt Stärke 0,875 mit B=0,1790598291 und W=0,8209401709; ihr
5–95-%-Value-Bereich wächst von 0,5433071 auf 0,8464303. Alle vier neu geclippten
Massen sind dabei null. Der volle Kandidat hätte je 96 neue Grenzpixel bei
höchstens 74,728 erlaubter Masse erzeugt und wurde deshalb verworfen.
Die Low-/High-Key-Rampen bleiben unverändert; gesättigte P3-Komponenten außerhalb
des sRGB-Würfels werden nicht als HDR fehlklassifiziert.

Sechs lokale JPEGs erhalten eine begrenzte Spreizung, eines bleibt wegen der
konservativen Verteilungsgates unverändert. Alle sieben Originalhashes sind
vor/nach dem Vergleich gleich. Flaue, Gegenlicht-, helle und gesättigte Motive
wurden lokal visuell zugeordnet; ein eindeutig absichtlich gestaltetes Low-Key-
Foto fehlt weiterhin und ist als fehlende Fotoabdeckung ausgewiesen. Der
Low-Key-Pflichtfall ist synthetisch abgedeckt. Die lokale Sichtprüfung ausgewählter
Vorher-/Nachher-Paare begründet keine allgemeine Qualitätsüberlegenheit. Private
Bilder, Ableitungen, Zuordnung und Hashberichte bleiben außerhalb des Repositorys.
RAW-Reaktionszeiten wurden für #171 nicht gemessen; die vorhandenen tatsächlichen
RAW-Messungen für #168/#169 sind getrennt und belegen keine Beschleunigung dieser
neuen Automatik.

### Abschließende Prüfungen für #171

Der vollständige isolierte Lauf besteht mit 1814/1814 SDK-Methoden. Danach
wurden ausschließlich die live Auswahlprüfung der Schaltfläche und zwei
zugehörige Testmethoden ergänzt. Die vier betroffenen Suites wurden mit dem
neu kompilierten Stand erneut einzeln ausgeführt; alle übrigen XML-Ergebnisse
wurden streng gegen den frisch entdeckten SDK-Katalog validiert. Damit sind
1816/1816 Methoden in 185 Batches vollständig verifiziert, ohne fehlende oder
unerwartete Methoden zu akzeptieren. Die zwei optionalen Bildbericht-Tests
liefen zusätzlich aktiviert im gezielten Lauf mit insgesamt 92 Tests in
14 Suites (46,406 s). Die Originalberichte bleiben nachvollziehbar erhalten.

Im Zuge des kontrollierten Abbruchs vor einer letzten Rückmeldungskorrektur
wurde ein Buildskript-Bug sichtbar: native Compiler können die Prozessgruppe
ihres Workers verlassen und nach dessen Ende kurz weiterarbeiten. Der
Abbruchpfad friert deshalb den nachgewiesenen eigenen Prozessbaum anhand von
Startdaten/Benutzerkennung vor der Baumaufnahme ein und beendet nur verifizierte
PIDs. Unvollständige Nachweise, verschwundene Worker oder fehlgeschlagene Waits
erhalten Lock und Staging für eine kontrollierte manuelle Prüfung. Die bisherige
App bleibt erhalten. Alle elf isolierten Skriptprüfungen bestehen, einschließlich
TERM-ignorierender Enkel in anderer Prozessgruppe, echtem exit-41-Orphan und
überlebendem fremdem Sentinel. Die betrieblichen Folgen stehen im README.

Anfängliche Test-Kompilierungen scheiterten an einem fehlenden `try` in einer
neuen Makroanforderung und einer untypisierten Int/Int64-Testrechnung; beides
wurde korrigiert. Der erste Releaseversuch wurde vor der letzten Quellkorrektur
kontrolliert abgebrochen und ist kein erfolgreicher Buildnachweis. Vor dem
abschließenden sauberen Build wurden Prozessruhe und fehlender aktiver Lock
erneut geprüft; anschließend wurden die generierten Ergebnisse vollständig
entfernt.

Der abschließende saubere vollständige Release-Build für #171 besteht
(435,51 s SwiftPM-Kompilierung), einschließlich Bundle-Plist, lokaler Signierung
und strikter Signaturprüfung. Der erfolgreiche Pfad entfernt seinen Build-Lock
und sein privates Staging. Seit diesem Build wurden nur die Prüfergebnisse in
Dokumentation/PR-Text ergänzt; ein weiterer App-Build ist dafür nicht erforderlich.
Der finale unabhängige Diff-, Schnittstellen-, Test-, Skript- und
Dokumentationsreview enthält keine offenen Befunde. Die vor Beginn vorhandene
fremde Teständerung im Haupt-Checkout ist bytegleich erhalten.

## Erweiterte Levels im Arbeitsbereich (#196)

**Licht → Erweiterte Levels** ist die einzige globale Levels-Palette. Sie beginnt geschlossen und speichert ihren Zustand im Workspace. Kanalwahl, fünf Regler/Zahlenfelder, beide Begrenzungsoptionen, Pipetten, **Levels automatisch setzen**, **Levels im Kanal zurücksetzen** und **Levels in allen Kanälen zurücksetzen** bleiben vollständig erreichbar. Bedienung, Zahlen und Status verwenden mindestens 13 pt; **Hilfe zu Levels …** öffnet die fachlichen Erläuterungen mit 14 pt. Präzise gespeicherte Werte werden durch Navigation oder die gröbere Anzeige nicht gerundet. Die neue Navigationstest-Suite prüft dies bei 300 pt Breite mit aktiven RGB-Kurven, HDR, V1 und beiden Clamps. Der vollständige Workspace-Test öffnet die gespeicherte Levels-Untergruppe ausdrücklich, bevor er die automatische Levels-Aktion prüft.

Gezielte Regression: `./scripts/test.sh --jobs 3 --no-parallel --filter 'LevelsInspector|LevelsNumeric|DevelopAutomaticToneTests|NaturalBalanceRendererTests|DevelopDetailWorkspaceIntegrationTests|WorkspaceLayoutTests|DevelopSharpeningWorkspaceTests|EditingModelTests'`. Native Suites bei Bedarf in getrennten Prozessen ausführen, damit gemeinsamer AppKit-Zustand den Abschluss nicht beeinflusst. Visuelle Nachweise und Grenzen stehen unter [Issue 196](issue-196/README.md).
