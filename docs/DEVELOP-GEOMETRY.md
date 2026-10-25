# Radiale Verzeichnung und gemeinsame Koordinaten

Unter **Zuschneiden → Verzeichnung** korrigiert der Regler −100…100 manuell
tonnen- oder kissenförmige Verzeichnung. 0 überspringt den neuen Warp vollständig.
Das Drittelraster des Zuschneidewerkzeugs dient als gerade Referenz.
**Verzeichnung zurücksetzen** setzt nur die Optik zurück; **Zurücksetzen** im
Zuschneidewerkzeug setzt die gesamte räumliche Geometrie zurück und erhält
Retusche und globale Korrekturen. Ein Reglerzug bildet einen Undo-Schritt.

**Auf gültige Bildfläche begrenzen** beschränkt die Ausgabe auf ein konservativ
berechnetes Rechteck innerhalb der verfügbaren Quelle, zusätzlich zum bisherigen
Begradigungs-Constrain. Ohne Begrenzung bleiben ungedeckte Flächen transparent.
JPEG verwendet danach seinen bestehenden weißen Transparenzhintergrund.
Es gibt keine Objektivdatenbank, automatische Objektivwahl, CA-Korrektur,
Vignettierung, Perspektivautomatik oder veränderte Interpretation von EXIF.

## Version 1 und Reihenfolge

`DevelopGeometry.optics` enthält `version: 1` und `distortion`. Die neutrale
Komponente fehlt im kanonischen JSON. Alte Snapshotbytes, Manifesthashes und der
vollständige bisherige affine Renderpfad bleiben bei 0 erhalten. Der gespeicherte
Tonwertvertrag wird nicht geändert.

Der Bezug ist das vollständig orientierte Bild **vor** Zuschnitt. Mit Mittelpunkt
`c`, halber Bilddiagonale `d`, `k = −0,002 × distortion` und `r² = |p−c|²/d²` gilt:

```
p_source = c + (p_warp − c) × (1 + k × r²)
```

Quellbezogene lokale Korrekturen, Retusche und rote Augen werden zuerst berechnet.
Die Optik folgt vor der bisherigen Folge aus Zuschnitt, zentrierter Begradigung,
Spiegelung und Vierteldrehungen. `DevelopGeometryPlan` beschreibt diesen gesamten
räumlichen Pfad für Renderer und Eingaben. Bei aktiver Optik berechnet ein
`CIKernel` die inverse affine Abbildung und danach die radiale Abbildung;
beide verwenden **ein** Resampling der bereits korrigierten Quelle.
Vor diesem Sample prüft der Kernel die Quell- und Zuschnittgrenzen und gibt
außerhalb explizit transparentes Schwarz zurück. Ein bloßes Cropping vor einem
`CIWarpKernel` genügt hierfür nicht: dessen implizites Sampling verlängert
Randpixel auch außerhalb der zugeschnittenen Quelle. Die explizite Prüfung
gilt gleichermaßen für Rasterbilder und analytische Core-Image-Quellen.

Die Ausgabe bleibt auf die ursprüngliche optische Bildfläche beschränkt. Bei
`k > 0` löst die Begrenzung `s × (1 + k × s²) = 1` für das zentrierte Rechteck mit
ursprünglichem Seitenverhältnis. Seine Kanten werden nach innen auf Pixelgrenzen
gerundet und mit dem gewählten Zuschnitt geschnitten. Das ist eine konservative
rechteckige Grenze, keine Suche nach einem maximalen beliebig geformten Ausschnitt.
Ein darin vollständig leerer Zuschnitt wird vor der Ausgabe abgelehnt.

## Quellkoordinaten und Werkzeuge

Gespeicherte Masken, Pinselstriche, Verlaufsgriffe und Retuschepunkte bleiben
normierte Koordinaten des ursprünglichen orientierten Quellbildes. Bestehende
Punkte werden nicht umgeschrieben. `DevelopCanvasCoordinateMapping` verbindet
normierte Quellpunkte, den gemeinsamen Geometrieplan und das sichtbare Rechteck.

Wie bisher zeigen **Maskieren**, **Reparieren**, **Rote Augen** und die
Weißabgleichspipette zur Bearbeitung die vollständige Quelle ohne räumliche
Korrekturen. Hier ist der ausdrücklich gewählte inverse Plan die Identität;
Formen und Retusche stimmen mit dem sichtbaren Quellmotiv überein. Der Abschluss
dieser Werkzeuge zeigt wieder die vollständige gespeicherte Geometrie. Das
Zuschneidewerkzeug zeigt die vollständige optische Fläche mit seinem Raster vor
dem endgültigen Zuschnitt und der bestehenden UI-Begradigung.

Levels-Pipette und Detailauswahl arbeiten auf der fertig korrigierten Vorschau.
Sie verwenden deren tatsächlich zugelassenes Eingaberaster, statt vom nativen
Dateimaß auf eine herunterskalierte Vorschau zu schließen. Transparente Ränder
sind keine gültige Mess-/Detailquelle. Die Vorwärtsrichtung für Quell-Landmarken
invertiert den streng monotonen radialen Radius mit 64 begrenzten
Bisektionsschritten; außerhalb der sichtbaren Fläche liefert sie keinen Punkt.
Vergleichsansichten verwenden die gerenderten Bilder und deren Ausgabeabmessungen.

## Fehler, Speicher und Nebenläufigkeit

Im benutzten Bereich `r ≤ 1` bleibt `1 + 3kr² ≥ 0,4` positiv. Nichtendliche Werte,
unbekannte Versionen und Regler außerhalb des Vertrags werden zurückgewiesen.
Der optische Plan begrenzt Seiten auf 131.072 Pixel, die Quellfläche auf
268.435.456 Pixel und absolute Rasterursprünge auf 1.048.576 Pixel, bevor ein Warp
angelegt wird. Die vorhandene Speicherzulassung berücksichtigt zusätzlich eine
Float-Quellfläche und die geplante Float-Ausgabefläche; diese rechnerische Reserve
ist keine Messung tatsächlichen GPU-Verbrauchs.

Der Warp bleibt im bestehenden CI-Auftrag mit vorhandenem Kontext, Quellcache,
Abbruchprüfung und Schutz vor veralteten Ergebnissen. Es gibt keinen neuen
Workerpool, keine RAW-Decodierung pro Reglerwert und kein zusätzliches
CPU-Readback. Die wenigen Koordinatenschritte und die begrenzte Bisektion bleiben
wegen ihrer geringen Arbeit seriell. Alpha wird durch premultipliziertes
Resampling erhalten; außerhalb der Quelle werden keine Randpixel wiederholt.

## Prüfung und Grenzen

`DevelopOpticsSettingsTests` prüft Versionierung, ungültige Werte, kanonische
Neutralbytes und Snapshot-Roundtrips. `DevelopRadialMappingTests` vergleicht
unabhängige Koordinatenformeln, Vorwärts-/Rückwärtsmapping und den tatsächlichen
Float-Warp einschließlich HDR, Teilalpha, transparenter Ränder, Grenzen und
Kombinationen mit Zuschnitt, Drehung und Spiegelung. Die nativen
`DevelopCropInspectorTests` prüfen erreichbare Bedienelemente und Undo des Resets.
Diese synthetischen Prüfungen benötigen keine lokalen Fotos.

Die sieben optionalen JPEGs unter `Fixtures/LocalTestImages/` bleiben unverändert
und fehlen in CI. Sie sind kein Ersatz für eine große RAW-Quelle. Es wird kein
Performancegewinn behauptet; konkrete Messungen zu Decodezahl, kalten/warmen
Caches und Spitzenmemory sind nur mit einer tatsächlich verfügbaren RAW-Datei
aussagekräftig.
