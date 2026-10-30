# Qualität der lokalen Reparatur

Stand: 31. Oktober 2026. Gilt für Heilen und Entfernen ohne KI; Bedienung und technische Grenzen stehen in [REPAIR-TOOLS.md](REPAIR-TOOLS.md).

## Änderung und Referenz

Der bisherige Renderer korrigierte einen ganzen Pinselzug oder eine ganze Maske mit einem einzigen RGB-Mittelwert. Bei wechselnder Beleuchtung konnte das nur einen Teil der Reparatur passend einfärben. Zusätzlich konnte der Vergleichsrand einer nahen Quelle in das zu entfernende Objekt hineinragen und dessen Farbe erneut einbringen.

Die neue Anpassung berechnet einen örtlich gewichteten Farbunterschied aus sauberen Quell-/Zielpaaren außerhalb beider Auswahlen. Eine normalisierte Gauß-Glättung verteilt diesen Unterschied über die Reparatur; die eigentliche Quelltextur bleibt ungeschärft und ungeglättet. Ein gemeinsamer Umgebungsmittelwert dient als weicher Rückfall bei fehlendem lokalem Kontext. LightCrafts `crates/pipeline/src/spots.rs` im gelesenen Stand `8aabf61449bc736d10f1d753b5497b54a55e9365` gab die Anregung; die Implementierung nutzt Glowrooms Core-Image-Graphen und Ressourcenplanung.

Vorhandene Pinsel-/Maskenreparaturen ohne eingefrorene Ersatzpixel profitieren beim erneuten Rendern ebenfalls von dieser Änderung. Historische Punktkorrekturen ohne diese Felder, Kopierstempel und KI-Ersatzpixel behalten ihre Bedeutung.

## Reproduzierbare Qualitätsprüfungen

`./scripts/test.sh --filter 'DevelopRepairQualityTests|DevelopGeometryRendererTests'` prüft bekannte synthetische Bildfelder: dunkle und rote Defekte neben einer nahen Quelle, einen langen Helligkeitsverlauf bei erhaltener Quelltextur, getrennte Maskenflächen, Alpha und unveränderte Außenpixel, Vorschau-/Exportskalierung sowie große oder vollständig ausgewählte Flächen ohne lokale Vergleichspixel. Ein zusätzlicher Vergleich fordert gleiche Ergebnisse mit normalem und softwarebevorzugtem Core-Image-Kontext. Core Image entscheidet über die tatsächlich verwendeten Geräte; dies ist kein Nachweis einer bestimmten Hardwareausführung.

Gültige äußere Ringpixel werden gleich gewichtet, bevor das gemeinsame Alpha berücksichtigt wird; dadurch werden sehr kleine Gewichte aus der weichen Kante nicht verstärkt. Die vollständige Testreferenz konditioniert ihre dünn besetzten Farbdifferenzen vor der Mittelwertbildung, damit Half-Float-Rundung nicht den Ausschnittvergleich verfälscht. Die Pixel-Toleranzen bleiben unverändert.

Zusätzlich wurde ein Maskenfehler am Bildrand behoben: Die Skalierung konnte außerhalb des Maskenrasters transparente Werte einbeziehen und dadurch selbst eine vollständig weiße Maske abschwächen. Der Renderer setzt jetzt die Rasterrandwerte vor der Skalierung fort und beschneidet danach auf die Bildfläche. Der Regressionstest prüft bei einer vollständig ausgewählten Fläche jeden einzelnen Ausgabepixel gegen seine analytisch bekannte Quelle; dafür werden exakt darstellbare Farbwerte verwendet. Vier feste Masken-/Quellvarianten und ein vollständig gefüllter Pinselpfad laufen mit unveränderten Toleranzen. Die bereits vorhandenen Rasterbytes liefern zudem einen eindeutigen Nachweis, wenn es keine freien Umgebungspixel gibt: In diesem Fall ist die Farbanpassung exakt null und der unnötige native Korrekturgraph entfällt. Für alle übrigen Auswahlen schützt eine ausdrückliche Koordinatenprüfung die Grenze des Vergleichsausschnitts auch bei zusammengefassten Filtern.

Die Maskenrandtests prüfen zusätzlich die Begrenzung des Rechengraphen bei Bildrändern, interpolierten Maskenzellen, weichen Pfaden und verkleinertem Pfadraster. Die bisherige globale Anpassung bleibt ausschließlich als Vergleich für die Fotodiagnose im Testcode erhalten.

## Vergleich auf lokalen Fotos

Aus drei unveränderten lokalen JPEGs wurde jeweils eine Vorschau mit höchstens 1.024 Pixeln langer Kante erzeugt. In eine Wand, einen Himmel und eine Wasserfläche wurde für die Prüfung ein schmaler roter Defekt eingefügt. Vorheriger und neuer Renderer verwendeten dieselbe Auswahl und dieselbe Quelle. Pro Motiv wurde eine festgelegte manuelle sowie die automatisch ermittelte Quelle geprüft.

Mittlerer absoluter RGB-Fehler gegenüber dem bekannten sauberen Original, gemessen nur im künstlichen Defekt, auf der 8-Bit-Skala 0–255 (kleiner ist besser):

| Motiv | Quelle | Bisher | Verbessert |
| --- | --- | ---: | ---: |
| Wand | Manuell | 5,90 | 4,22 |
| Wand | Automatisch | 5,92 | 1,79 |
| Himmel | Manuell | 1,02 | 0,50 |
| Himmel | Automatisch | 0,47 | 0,48 |
| Wasser | Manuell | 52,70 | 16,23 |
| Wasser | Automatisch | 16,21 | 14,45 |

Die automatische Himmelsquelle war schon sehr passend; dort gibt es keine Verbesserung. Die schwierigere Wasserstruktur bleibt trotz geringeren Farbfehlers sichtbar anders als das Original. Das Verfahren kann verdeckte Details nicht rekonstruieren. Der Vergleich belegt diese sechs Fälle, keine allgemeine Freigabe für große Objekte, beliebige Motive oder RAW-Auflösungen. Es wird kein Geschwindigkeitsgewinn behauptet.

Die erzeugten Ausschnitte wurden visuell geprüft. In allen sechs Reparaturen blieb der Bereich außerhalb der Maske innerhalb eines 8-Bit-Rundungsschritts unverändert; SHA-256-Prüfungen bestätigten unveränderte Originaldateien. Die drei privaten JPEGs und sämtliche Ableitungen werden nicht eingecheckt oder hochgeladen.

Reproduktion mit vorhandenen lokalen Testbildern und einem **neuen** temporären Ausgabeverzeichnis:

```sh
GLOWROOM_REPAIR_FIXTURES="$PWD/Fixtures/LocalTestImages" \
GLOWROOM_REPAIR_FIXTURES_OUTPUT=/private/tmp/glowroom-repair-comparison \
./scripts/test.sh --filter DevelopRepairLocalPhotoTests
```

Die Diagnose schreibt `report.json` und PNG-Ausschnitte für Original, künstlichen Defekt, bisherige und verbesserte Reparatur. Ohne die ausdrückliche Fixture-Variable wird sie übersprungen; die privaten Bilder stehen in CI und frischen Checkouts nicht zur Verfügung.

## Zusätzlich behobener Decoderfehler

Die breitere Regression fand außerdem leere Core-Image-Vorschauen bei bestimmten
16-Bit-Graustufen-Thumbnails mit Transparenz. Der Decoder verwendet für deren
unveränderte native Pixel jetzt einen normalen Datenprovider. Profil, Präzision
und Alpha bleiben erhalten; Details zu Reproduktion, Speicherbedarf und
Cache-Kompatibilität stehen in [GRAYSCALE-RENDERING.md](GRAYSCALE-RENDERING.md).

## Abschlussprüfung

- 312 Tests in 34 Suites für Reparieren, Geometrie, Retusche-Abtastung,
  angepasste Vorschauen, Bildkorrekturen, lokale Anpassungen, Graustufen und
  JPEG-Export bestanden.
- Zusätzlich 73 gezielte Tests in sieben Suites, einschließlich Vorschau-
  Pipeline und Festplattencache, bestanden; optionale externe Bild-/Modelltests
  bleiben ohne ausdrückliche Umgebungsvariablen übersprungen.
- Die sechs Fotodiagnosen wurden auf dem endgültigen Quellstand separat
  ausgeführt und visuell geprüft.
- Der separate native Exporttest mit 6.000 × 4.000 Pixeln und festem
  4-GiB-Zulassungsbudget bestand, einschließlich Reparaturpixeln und
  unveränderten Originalbytes. Das Budget ist keine Messung des Spitzenverbrauchs.
- Das unabhängige Review von Renderer, Masken, Decoder, Tests und Dokumentation
  ergab keine offenen Befunde.

Unabhängige Analyse und Reviews wurden parallel bearbeitet. Die kleine
Maskenprüfung nutzt seriell bereits vorhandene Bytes; abhängige Reparaturen,
ressourcenintensive Exporttests sowie Bereinigung und anschließender Build
bleiben geordnet. Der saubere vollständige App-Build ist wegen der Änderungen
am Renderer und Decoder erforderlich. Er wurde nach Entfernung von `.build/`
und des bisherigen `dist/Glowroom.app` mit `GLOWROOM_BUILD_JOBS=4` erfolgreich
ausgeführt; das neue App-Bundle wurde erstellt und signiert.
