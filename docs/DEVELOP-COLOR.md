# Grundeinstellungen, Weißabgleich und Profile

Die Grundeinstellungen gelten nicht destruktiv für die aktive Bildquelle. Vorschau
und Export verwenden denselben Core-Image-Graphen; die Originaldatei bleibt
unverändert. Die Bildoperationen laufen in den vorhandenen begrenzten
Hintergrund-Renderern. Der kleine Weißpunkt-/Pipettenalgorithmus braucht keine
zusätzlichen Worker oder GPU-Rücklesevorgänge.

## Weißabgleich

Temperatur reicht von 2000 bis 12000 K, Tönung von −150 bis +150. **6500 K und
Tönung 0 sind die Neutralstellung.** Die Zahlen beschreiben einen relativen
Weißpunkt auf dem bereits entwickelten Bild. Bei RAW hat ImageIO den
kameraseitigen Weißabgleich schon angewendet. PicEdit zeigt deshalb keinen
vermeintlich ausgelesenen Kamera-Kelvinwert und behauptet keine erneute
sensorseitige RAW-Entwicklung.

Höhere Temperaturwerte wärmen das Bild, niedrigere kühlen es ab. Positive Tönung
korrigiert einen Grünstich in Richtung Magenta. Die Umsetzung verwendet einen
an D65 verankerten Planck-Weißpunkt mit Tönungsversatz im CIE-1960-uv-Raum und
eine Bradford-Anpassung im linearen RGB-Arbeitsraum. Bei Neutralstellung wird
die Anpassung vollständig übersprungen.

Die aktive Neutralpipette zeigt innerhalb des tatsächlich dargestellten Bildes
dasselbe Pipettensymbol wie ihre Schaltfläche. Außerhalb des Bildrechtecks gilt
der normale Zeiger; ein Klick im Randbereich nimmt keine Probe. Ausschalten,
Bildwechsel oder eine noch nicht bereite Bildquelle beenden die aktive Eingabe.
Die Neutralpipette benötigt eine im Motiv tatsächlich neutrale graue oder weiße
Fläche. Sie berechnet Temperatur und Tönung gemeinsam aus der unkorrektierten,
entwickelten Quelle in sRGB; wiederholtes Anklicken addiert die vorherige
Korrektur nicht. Schwarze, ausgefressene oder überwiegend transparente Proben
werden zurückgewiesen. Stark farbige Flächen können keine verlässliche
Neutralreferenz liefern. Werte außerhalb des unterstützten Bereichs werden an
die Reglergrenzen angepasst und sind als begrenzte Berechnung erkennbar.

## Profile und Schwarzweiß

- **PicEdit Farbe** erhält den vorhandenen Farbeindruck der entwickelten Quelle.
- **PicEdit Lebendig** verstärkt Farbe und einen sanften Helligkeitskontrast.
- **PicEdit Porträt** reduziert beide zurückhaltend. Dies ist ein fester kreativer
  Stil ohne Gesichtserkennung.

Diese Profile sind PicEdit-Bildstile. Sie sind keine Adobe- oder
herstellerspezifischen Kameraprofile. Das eingebettete Quellfarbprofil wird bei
SDR-Vorschauen bewahrt; beim Export gelten die gewählten Ausgabefarbraumregeln.

Schwarzweiß ist ein eigener Schalter mit einer luminanzbasierten Umrechnung im
linearen Arbeitsraum. Er verändert den gespeicherten Sättigungsregler oder
Weißabgleich nicht. Beim Zurückschalten stehen die bisherigen Farbwerte wieder
zur Verfügung.

## HDR-Verarbeitung

HDR ist eine gesondert gespeicherte Einstellung. Der Rendergraph kann Werte über
SDR-Weiß erhalten: die Ausgabe verwendet Halbpräzisions-Fließkomma in erweitertem
linearem sRGB. Weißabgleich, Profile, globale Regler und lokale Maskenkorrekturen
schneiden diese Werte im HDR-Modus nicht an der SDR-Grenze ab. Auch die
Verkleinerung einer Vorschau behält Fließkommawerte.

HDR stellt in einem gewöhnlichen SDR-Original keine verlorenen Lichter wieder
her. Sichtbare zusätzliche Helligkeit setzt eine geeignete Anzeige und deren
aktuell verfügbare EDR-Helligkeitsreserve voraus. Der bestehende JPEG-Export
bleibt SDR; eine HDR-fähige Darstellung darf deshalb nicht aus einer
JPEG-Vorschau oder einem gewöhnlichen PNG-Diskcache abgeleitet werden.

## Speicherung und Kompatibilität

`EditSettings.developColor` enthält Temperatur, Tönung, Profil, Schwarzweiß und
HDR. Die ganze Komponente fehlt im JSON, solange alle Werte neutral sind. Das
erhält die kanonischen Bytes und Prüfsummen historischer Snapshots und
Artefakt-Manifeste. Bei vorhandener Komponente sind alle fünf Felder erforderlich;
unbekannte Schlüssel, falsche Typen und ungültige Werte werden an der strikten
Persistenzgrenze abgewiesen. Eine ausdrücklich gespeicherte neutrale Komponente
ist keine kanonische Repräsentation.

Einzelne numerische Parameteränderungen über `EditParameter` erhalten den übrigen
Bearbeitungsstand vollständig: Profil, Weißabgleich, Schwarzweiß, HDR, Geometrie
und Masken bleiben unverändert. Die gemeinsamen Bearbeitungssnapshots erfassen
auch diese Komponenten.

Die Regressionstests prüfen alte Snapshotbytes und Hashes, neue strikte
Roundtrips, SQL-Sicherung und Wiederherstellung, erhaltene Ausgangswerte bei einzelnen Parameteränderungen,
bekannte Neutralreferenzen, Alpha, Vorschau-/Exportgleichheit und HDR-Lichter
einschließlich lokaler Masken und zwischengespeicherter Renderpräfixe.
