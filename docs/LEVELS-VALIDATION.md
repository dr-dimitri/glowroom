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
Seit diesem Build wurden nur diese Testrechnung und Dokumentation verändert;
ein weiterer App-Build ist deshalb nicht erforderlich. Der unabhängige finale
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
