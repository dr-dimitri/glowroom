# Graustufenquellen und Farbkorrekturen (#147)

Echte einkanalige PNG- und TIFF-Dateien bleiben beim unveränderten Anzeigen in
ihrem ursprünglichen Graustufenfarbraum. Sobald eine Bearbeitung gerendert wird,
verwendet die SDR-Vorschau für solche Quellen sRGB und ein RGBA-Raster. Core Image
liest das Profil der Graustufenquelle und konvertiert das Filterergebnis bewusst
in diesen RGB-Ausgaberaum. Dadurch sind Temperatur und Tönung auch bei gescannten
Schwarzweißfotos sichtbar und stimmen mit dem JPEG-Export überein.

8-Bit-Quellen werden als RGBA8, 16-Bit-Quellen als RGBA16 ausgegeben. Alpha bleibt
erhalten. Der ausdrücklich gewählte S/W-Modus wird weiterhin im Filtergraphen
angewendet; der Farbraum der Quelldatei schaltet diesen Modus nicht automatisch
ein. RGB-Quellen behalten ihr bisheriges Ausgabeprofil; HDR verwendet weiterhin
erweitertes lineares sRGB mit Half-Float-Komponenten.

Der zusätzliche RGB-Rasterbedarf monochromer SDR-Quellen fließt in dieselbe
begrenzte Vorschauplanung wie Schärfung, Masken und Retusche ein. Die bestehenden
Render-Lanes und Core-Image-Kontexte bleiben wiederverwendbar. Kleine
Formatentscheidungen erfolgen seriell; die datenparallele Pixelverarbeitung
übernimmt weiterhin Core Image.

Der persistente Vorschaucache enthält unveränderte Decoder-Basisbilder, keine
entwickelten Ergebnisse. Das gespeicherte Basisformat bleibt unverändert;
entwickelte RAM-Caches leben nur bis zum Prozessende und verrechnen die
tatsächliche Rastergröße.

Die Tests `GrayscaleSourceRenderingTests` erzeugen ihre PNG-/TIFF-Fixtures in
temporären Verzeichnissen. Sie prüfen echte monochrome Decoder-Ausgaben,
JPEG-Parität im gemeinsamen erweiterten linearen sRGB (pro Kanal höchstens
0,02 Abweichung einschließlich JPEG-/8-Bit-Quantisierung), 16 Bit, Alpha,
Neutralpfad, S/W, HDR, Größenwechsel und erneutes Entwickeln eines gespeicherten
Basisbildes. Private Testbilder und reale Kataloge sind nicht erforderlich.

```sh
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-tests-147 ./scripts/test.sh --jobs 2 \
  --filter 'GrayscaleSourceRenderingTests|DevelopColorAdjustmentTests|AdjustedPreviewPipelineTests|PreviewDiskCacheTests|EditRendererTests'
```

## Korrektur für transparente 16-Bit-Vorschauen (31. Oktober 2026)

Bei der Reparaturregression wurde ein ImageIO-Sonderfall reproduziert: Bestimmte
16-Bit-Graustufen-Thumbnails mit Alpha enthielten korrekte native Pixel, wurden
von Core Image aber als transparentes Schwarz eingelesen. Die vorhandenen
PNG-/TIFF-Tests erkannten dadurch leere Vorschauen und abweichende Ergebnisse
nach dem Wiederöffnen des Vorschaucaches.

Der Decoder überführt ausschließlich dieses Thumbnail-Layout in einen normalen
unveränderlichen Datenprovider. Native Bytes, Präzision, Alpha, Byteordnung,
Profil, bereits angewendete Orientierung und Rendering-Intent bleiben erhalten;
es erfolgt keine Farbkonvertierung. Das bloße Wiederverwenden des privaten
ImageIO-Providers reichte in der nativen Gegenprobe nicht aus.

Die Arbeit bleibt im begrenzten Hintergrunddecoder mit Abbruchprüfungen. Bei
höchstens 4.096 Pixeln je Kante entsteht vorübergehend ein weiterer
Graustufen-/Alpha-Puffer von höchstens 64 MiB zuzüglich Zeilenpadding. Der alte
Thumbnail wird mit dem Decoder-Autoreleasepool freigegeben, der dauerhafte
Cachebedarf bleibt `bytesPerRow * height`. Vorhandene persistente Basisbilder
werden bereits aus normalen PNG-Daten geöffnet und enthalten dieselben Pixel;
eine Cache-Versionsänderung ist deshalb nicht erforderlich. Die bestehenden
Präzisions-, Alpha-, HDR- und Cache-Prüfungen behalten ihre Toleranzen.
