# Aktueller Compositor, echte archivierte Rohbilder

Am 17. Oktober wurden die sieben unterschiedlichen Rohoutputs der historischen Inferenz erneut mit `MaskCompositor.compose(..., backend: .cpu)` verarbeitet. Input- und Rohdateien sind bytegleiche Kopien; die SHA256 stehen im Report. Keine Modellinferenz, kein Kontextfarbabgleich und keine Änderung der originalen harten/weichen Masken wurden bei diesem Replay ausgeführt.

`current-compositor-report.json` beschreibt Normalisierung, Alpha, Profil, Geometrie, Originalhashes, Endbildhashes und die vollständige Pixelprüfung. Alle 1.308.781 Pixel mit Maske null sowie 98.304 native Canvas-ROI-Pixel bleiben exakt erhalten. Die halbtransparente historische Fixture deklariert eine separate Policy: Ihr unverändertes Quellalpha wird vor Composition auf den weißmattierten RGB-Kandidaten gelegt. `candidate-source-alpha.png` legt diesen Schritt offen. Die übrigen Fälle verwenden die tatsächliche opaque Modell-RGB-Ausgabe.

`visual-review.json` ist das abschließende manuelle Qualitätsurteil und bindet jedes tatsächlich betrachtete beschriftete Bild per SHA256. Alle sieben Fälle fallen weiterhin durch das Qualitätsgate. Drei aktuelle Vergleiche wurden unabhängig erneut visuell geprüft. Die `pending`-Angabe im ursprünglichen automatisch erzeugten Report bleibt als Zeitpunktstatus unverändert erhalten.
