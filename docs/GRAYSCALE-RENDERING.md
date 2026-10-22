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
entwickelten Ergebnisse. Decoder und gespeichertes Basisformat ändern sich
nicht, daher ist keine Cache-Versionsanhebung nötig. Entwickelte RAM-Caches
leben nur bis zum Prozessende und verrechnen die tatsächliche Rastergröße.

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
