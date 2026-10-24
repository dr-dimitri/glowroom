# Grundeinstellungen, Weißabgleich und Profile

Die Grundeinstellungen gelten nicht destruktiv für die aktive Bildquelle. Vorschau
und Export verwenden denselben Core-Image-Graphen; die Originaldatei bleibt
unverändert. Die Bildoperationen laufen in den vorhandenen begrenzten
Hintergrund-Renderern. Die bisherige Weißabgleichspipette verwendet die bereits
vorhandene kleine Analyse. Die präzisen Levels-Pipetten lesen dagegen ein
begrenztes Float-Fenster aus ihrem eigenen festgelegten Messknoten.

## Weißabgleich

Temperatur reicht von 2000 bis 12000 K, Tönung von −150 bis +150. **6500 K und
Tönung 0 sind die Neutralstellung.** Die Zahlen beschreiben einen relativen
Weißpunkt auf dem bereits entwickelten Bild. Bei RAW hat ImageIO den
kameraseitigen Weißabgleich schon angewendet. Glowroom zeigt deshalb keinen
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

- **Glowroom Farbe** erhält den vorhandenen Farbeindruck der entwickelten Quelle.
- **Glowroom Lebendig** verstärkt Farbe und einen sanften Helligkeitskontrast.
- **Glowroom Porträt** reduziert beide zurückhaltend. Dies ist ein fester kreativer
  Stil ohne Gesichtserkennung.

Diese Profile sind Glowroom-Bildstile. Sie sind keine Adobe- oder
herstellerspezifischen Kameraprofile. Das eingebettete Quellfarbprofil wird bei
SDR-Vorschauen bewahrt; beim Export gelten die gewählten Ausgabefarbraumregeln.

Schwarzweiß ist ein eigener Schalter mit einer luminanzbasierten Umrechnung im
linearen Arbeitsraum. Er verändert den gespeicherten Sättigungsregler oder
Weißabgleich nicht. Beim Zurückschalten stehen die bisherigen Farbwerte wieder
zur Verfügung.

## HDR-Verarbeitung

HDR ist eine gesondert gespeicherte Einstellung. Der Rendergraph kann Werte über
SDR-Weiß erhalten: die Ausgabe verwendet erweitertes lineares sRGB, bei V2 oder
aktiven Levels mit Float32, bei V1 ohne Levels mit Halbpräzision.
Weißabgleich, Profile, globale Regler und lokale Maskenkorrekturen
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

## Versionierte Tonwertverarbeitung

Neue Bearbeitungen verwenden **sRGB Float (V2)**. Gespeicherte Bearbeitungen
ohne `toneProcessingVersion` behalten **Bisherig (V1)** einschließlich der
bisherigen Gamma-2,2-Kennlinien und Automatik. Im Inspector stellt der Befehl
**Auf sRGB Float (V2) umstellen** ausschließlich die Prozessversion um; die
Reglerwerte bleiben erhalten. Der sichtbare Farbeindruck kann sich dadurch
ändern. Einmal Rückgängig stellt die bisherige Version wieder her. Reset und
Rückkehr zum Original erhalten die gewählte Prozessversion. Auch neue
generierte Bildquellen beginnen mit neutralen V2-Einstellungen.

Die Versionskennung gehört zu Settings-Gleichheit, Cacheidentitäten,
Verlauf, Bildständen, Export und Backups. Eine fehlende Kennung bedeutet V1;
V1 wird weiterhin ohne zusätzliches Versionsfeld gespeichert. So bleiben
historische kanonische Snapshot- und Provenienzbytes samt Hashes erhalten.
Unbekannte Prozessversionen werden abgewiesen. Eine neutrale V2-Bearbeitung
überspringt die Bildoperationen vollständig, bleibt aber als eigener
Verarbeitungsvertrag gespeichert.

### Farb- und Präzisionsvertrag von V2

Core Image arbeitet in **extended linear sRGB**, mit RGBA-Float32-Zwischenwerten.
Nach Entrauschung, Bildausgleich sowie Profil und Weißabgleich folgen:

1. Vorzeichenrichtiges stückweises sRGB-Encoding.
2. Kontrast und Tonbereiche, deren Gewichtung vor der Belichtung bestimmt wird.
3. sRGB-Decoding, linearer Faktor `2^EV`, danach erneutes Encoding.
4. Dehaze und Farbregler nach den bestehenden Formeln, danach Decoding.
5. Globale Tonwertkorrektur (Levels) in vorzeichenrichtiger sRGB-Domäne, danach
   wieder Decoding. Neutrale Levels überspringen diese zusätzliche Stufe.
6. Präsenz, Schwarzweiß und Schärfen; lokale Masken erben dieselbe Prozessversion.

Für das Encoding gilt betragsweise `12.92*x` bis `0.0031308`, sonst
`1.055*x^(1/2.4)-0.055`; das Vorzeichen bleibt erhalten. Das Decoding verwendet
`x/12.92` bis `0.04045`, sonst `((x+0.055)/1.055)^2.4`, ebenfalls mit erhaltenem
Vorzeichen. Alpha wird getrennt verarbeitet; vollständig transparente Pixel
werden kanonisch schwarz-transparent. Negative Gamutkanäle und Werte über 1
werden innerhalb dieser V2-Stufen erhalten. Eine gültige SDR-P3-Farbe kann in
extended sRGB solche Komponenten haben und ist deshalb kein HDR-Nachweis.

Die SDR-Begrenzung erfolgt bei der Ausgabe in das gewählte Zielprofil und
anschließende ganzzahlige Rasterformat, nicht bereits im sRGB-Arbeitswürfel.
Vorschau und Export bauen denselben versionierten Graphen auf. Zielprofil,
Ausgabequantisierung und Verkleinerung können Unterschiede zwischen einer
Vorschau und dem Vollbild erklären. Die angeforderte Core-Image-Softwareoption
ist eine Diagnosepräferenz und kein Nachweis tatsächlicher CPU-Ausführung.

V2 verwendet für räumliche Glättungen zwei separierbare Float-Kernel mit
normalisierten Gaußgewichten und ganzzahligen Abtastpositionen. Dies vermeidet
die in der lokalen Stufendiagnose beobachtete Halbpräzisionsrundung des nativen
Gaußfilters. Der Kernelcache enthält höchstens acht Varianten, keine Bildraster.
Sigma ist auf 128 Quellpixel und der Stützbereich je Richtung auf 512 Pixel
begrenzt. Der größere experimentelle Shader mit 1.024 Taps benötigte auf der
lokalen Maschine mehr als zwei Minuten Kompilierzeit; die Grenze schützt die
Reaktionsfähigkeit und die Größe der erzeugten Shader. Darüber endet der Renderauftrag mit einem erklärenden Fehler; der
bisherige Bildstand bleibt erhalten. Die Grenze betrifft sehr große Quellen
mit aktiven räumlichen Korrekturen, keinen normalen Reglerwertebereich.

### Float-Analyse und Automatikgrenzen

V2 analysiert den aktiven globalen Graphen vor Ausgabequantisierung. Profil,
Weißabgleich, Bildausgleich und übrige globale Regler bleiben aktiv; nur der
jeweils geschätzte Regler wird für Baseline und absolute Kandidaten neutralisiert.
Masken, Retusche und Geometrie sind ausgeschlossen. Die bereits decodierte
Quelle, Prefix-Caches und der bestehende begrenzte Analyseworker werden
wiederverwendet; ein Reglerauftrag startet keinen neuen RAW-Decode.

Die Analyse liest höchstens 256×256 RGBA-Float32-Pixel in extended linear sRGB
und im erweiterten linearen Zielprofil. Die perzeptuellen SDR-Ziele verwenden
vorzeichenrichtig sRGB-kodierte lineare Luminanz; Clipping und Überschreitungen
werden separat im tatsächlichen Zielprofil vor der SDR-Begrenzung geprüft.
Alpha gewichtet die kleine serielle CPU-Reduktion. Transparente Flächen tragen
keine Masse bei. Zwei Float-Proxys und Histogramme haben einen expliziten
Speicherplan; es gibt keinen Readback pro Histogramm-Bin.

Ein gemeinsamer Bereichsvertrag beschreibt ausschließlich die decodierte
Rendition. SDR-Decodierung verspricht keine Sensor-HDR-Information. Für
erweiterte relative RGB-Räume ist das nominale SDR-Weiß explizit angegeben.
Die Quellenluminanz wird zusätzlich im bestehenden CI-Graphen auf ein Maximum
reduziert, damit ein kleines HDR-Licht beim Downsampling nicht verloren geht.
Tatsächliche Luminanz über nominalem SDR-Weiß, ein aktiver HDR-Ausgabepfad,
fehlende Bereichsinformation und nicht unterstützte Profile liefern keinen
SDR-Automatikvorschlag. Erweiterte P3-Gamutkanäle allein führen nicht zur
Ablehnung. LUT-, PQ- und HLG-Profile benötigen einen eigenen Vertrag.

V2 unterscheidet einen gültigen Wert (auch 0), keinen Vorschlag und einen
Berechnungsfehler. Kein Vorschlag erhält den aktuellen Reglerwert und erzeugt
keine neue Revision oder Undo-Stufe. Veraltete Erfolge und Fehler werden anhand
von Quelle, Snapshot, Revision und Edit-Session verworfen. Das sichtbare
Histogramm bleibt ausdrücklich eine sRGB-RGBA8-SDR-Anzeige und ist kein
Float-Analyse- oder RAW-Sensor-Clippingnachweis.

Reproduzierbare Prüfungen und die Grenzen der optionalen lokalen RAW-Messung
stehen in [TONE-PIPELINE-VALIDATION.md](TONE-PIPELINE-VALIDATION.md).

## Globale Tonwertkorrektur (Levels)

Die globale Tonwertkorrektur besitzt eine gemeinsame RGB-Kurve
und drei Einzelkanalkurven. Jede Kurve beschreibt Eingangsschwarz/-weiß,
Gamma, Ausgangsschwarz/-weiß sowie getrennte Eingangs- und Ausgangsclamps.
Der Neutralzustand (0/1, Gamma 1, 0/1, Clamps aus) wird nicht als zusätzlicher
`levels`-Schlüssel gespeichert. Alte Bearbeitungen und kanonische Snapshots
behalten so ihre bisherige Darstellung und Serialisierung.

In der vorzeichenrichtigen sRGB-Domäne gilt pro Kurve
`u = (x - inputBlack) / (inputWhite - inputBlack)`, danach optional der
Eingangsclamp, `v = u > 0 ? pow(u, 1 / gamma) : u` und
`y = outputBlack + v * (outputWhite - outputBlack)`, danach optional der
Ausgangsclamp. Gamma größer 1 hellt Mitteltöne auf. Einzelkanäle werden vor
der gemeinsamen Kurve ausgewertet; diese komponentenweise gemeinsame Kurve
verspricht keine Farbtonerhaltung. Alpha gehört nicht zur RGB-Kurve.

Eingangs- und Ausgangspunkte liegen zwischen 0 und 1, Gamma zwischen 0,1
und 10. Der Eingang benötigt mindestens `1e-4` Abstand; invertierte Ausgänge
sind unzulässig, gleiche Ausgänge erlauben eine konstante Abbildung. Die
CPU-Referenz und Intervallprüfung weisen nicht darstellbare Float-Zwischenwerte
kontrolliert zurück, auch wenn ein späterer Clamp das Ergebnis begrenzen würde.
Persistierte ungültige Werte werden abgewiesen; Normalisierung ist eine
gesonderte deterministische Funktion für bearbeitbare Werte. Der Mindestabstand
muss sowohl als Double als auch nach Umwandlung der Endpunkte in Float gelten.
Unbekannte Levels-Versionen und Transferfunktionen werden abgewiesen.

Levels folgt den bisherigen globalen Tonwert- und Farbreglern und liegt vor
Präsenz, Schwarzweiß und Schärfen. Diese eigene Stufe verwendet für V1 und V2
dieselbe vorzeichenrichtige sRGB-Transferfunktion. Die davorliegende V1-Stufe
behält ihre historische Gamma-2,2-Kennlinie. Vor der Kurvenauswertung werden
RGB-Werte von Alpha entkoppelt; anschließend wird Alpha unverändert wieder
angewendet. Neutrale Levels fügen keinen Kernel und keine Bereichsanalyse ein.

Vor der Ausführung aktiver Levels reduziert der vorhandene Core-Image-Graph
seine Eingangsbereiche. Die konservative Float-Intervallprüfung umfasst jede
Rechenstufe der Einzelkanäle, der anschließenden gemeinsamen Kurve und des
Rückwegs durch die sRGB-Decodierung. Dadurch
werden überlaufende Zwischenwerte vor dem Aufbau des Levels-Kernels als
Renderfehler zurückgewiesen; der letzte gültige Bildstand bleibt sichtbar.
Die Bereichsprüfung begrenzt keine gültigen negativen oder erweiterten Werte.
Sie ersetzt keinen HDR-Quellvertrag für spätere Automatiken.

Der Nachweis liest nur acht Float-Werte aus vollständigen Min-/Max-Reduktionen
zurück, kein Histogramm und keinen CPU-Bildraster. Eine einzelne kleine
Cacheposition bindet ihn an die UUID der decodierten Quelle, tatsächliche
Proxymaße, Präzision und vorgelagerte Einstellungen. Resizes leiten aus der
Elternidentität, Eingangs-/Zielmaßen und Rasterformat einen deterministischen
Token ab. Identische direkte Resizes teilen den Beweis; unterschiedliche
Präzision oder mehrstufiges Resampling teilen ihn nicht. Speicherbesitz-Wrapper
erhalten den Token; ein neuer Decode bekommt eine neue UUID. Levels-Regler
und spätere Stufen entwerten den Eingangsbeweis nicht.
Der Beweis hält keine Bild- oder Artefaktressource zusätzlich fest. Auch die
kleinen Analysen des bisherigen und natürlichen Bildausgleichs verwenden die
stabile Rasteridentität. Dadurch lösen gleiche, neu materialisierte Proxys bei
Levels-Reglerbewegungen keine erneute Histogramm-/Szenenanalyse aus. Beide
Analysescaches bleiben auf acht Einträge begrenzt und halten keine Pixel fest.

Nachgelagerte Präsenz, Masken, Schärfung oder Geometrie können extreme, zuvor
noch endliche Werte erneut überlaufen lassen. In diesen Fällen prüft eine
abschließende native Reduktion den gesamten Ausgabegrafen; nur vier Float-Werte
werden zurückgelesen. Ungültige Ergebnisse werden vor Vorschauübernahme oder
Export zurückgewiesen. Zwei zusätzliche RGBAf-Ebenen sind konservativ im
Speicherplan berücksichtigt. Aktive Levels verwenden auch bei V1 Float32,
ohne dessen Tonwertversion umzuschalten. Die HDR-Vorschau verwendet für V2
oder aktive Levels ebenfalls Float32 und verliert daher große endliche Werte
nicht an der bisherigen Half-Float-Ausgabegrenze von 65.504.

Levels gehört ausschließlich zur globalen Bearbeitung. Lokale Masken wenden
den globalen Levels-Schritt nicht erneut an; ihre Korrekturen arbeiten auf der
global entwickelten Grundlage. Vorschau, Export und entwickelte Ersatzpixel
verwenden denselben Levels-Graphen. Die bestehenden Weiß-/Schwarzregler sowie
ihre Umschalt-Doppelklick-Automatik bleiben eigenständige Funktionen. Die
Endpunkt-Automatik folgt in #171.

### Präzise Levels-Pipetten

Schwarz und Weiß setzen einen Eingangsanker; Grau berechnet
`gamma = log((x-B)/(W-B)) / log(t)`. Im Standardmodus gilt `t=0.5` für den
normalisierten Mittelton. Master verwendet `max(R,G,B)` nach den unveränderten
Einzelkurven. RGB-Neutralisierung bildet zuerst den vollständigen vorgeschlagenen
Master mit Gamma 1 und invertiert dessen übrige Parameter sowie gemeinsame
RGB-Ausgangsgrenzen auf das Ziel 0,5. Ungültige Logarithmen, Gammawerte,
Float-Spannen oder mehrdeutige Inversen werden vollständig abgelehnt.
Das RGB-Grauziel wird zusätzlich mit Float-Uniforms bei getrennter und
kontrahierter Multiplikation/Addition geprüft. Instabile Vorschläge mit mehr
als acht Float-Einheits-ULPs Abweichung (etwa `9.54e-7`) werden abgelehnt.
Vor der Übernahme prüft ein einzelner Float-Pixel denselben Levels-Knoten auch
auf dem tatsächlichen Core-Image-Backend; dadurch können native Potenz-/TRC-
Rundungen das zugesagte Ziel nicht unbemerkt verändern.

`globalLevelsInputGraph` ist die gemeinsame Messquelle vor dem gesamten Knoten.
Die Probe verwendet den tatsächlichen adaptiven Renderinput, kein Bildschirm-
RGBA8 und keinen zusätzlichen kleinen Proxy. Das feste 5×5-Fenster wird an
Rasterrändern gekürzt. Nach Entpremultiplikation wird jeder Pixel signiert-sRGB-
codiert; erst danach folgt die Alpha-Mittelung. Nicht endliche/unsichtbare Pixel
zählen nicht, mindestens `max(1, 0.25 * Fensterpixel)` sichtbare Pixeläquivalente
sind erforderlich. Nur maximal 400 Bytes gelangen pro Farbmessfenster zur CPU.
Diese kleine Reduktion bleibt seriell; die bestehende Analyse-Actor-Lane teilt
Kontext und decodierte Quelle mit anderen Tonwertanalysen.

Die inverse Geometrie verwendet dieselben geordneten Crop-/Clamp-/Transform-
Schritte wie der Renderer, einschließlich gerundeter adaptiver Rastermaße.
Retusche wird im tatsächlichen Messfenster aufgelöst: unberührt bleibt der
Originalgraph; genau eine vollständig deckende eingefrorene Ersatzfläche
verwendet `globalLevelsReplacementInputGraph` mit dem Originalbezug für Balance.
Gemischte und andere nicht eindeutig zuordenbare Reparaturproben werden abgelehnt.

Der angenommene Frame hält genau seinen tatsächlichen Input und Output. Der
32-MiB-Ausgabecache hält zusätzliche Inputs nur schwach; verlorene Inputs werden
in derselben begrenzten Renderlane ohne Decode rekonstruiert. Artefaktprovider
tragen die zugehörige Reservation auch nach Ende ihrer Renderphase; Planung
berücksichtigt Eingabe, Ausgabe, vorigen Frame, Cache und native Arbeitsflächen.
Ein unveränderter Input/Output teilt seine bestehende Reservation.

Asset-/Artefaktquelle, Quellrevision, Edit-/Selection-Session und Generation,
lokale Revision, komplette Einstellungen, Lade-Token und tatsächliche Raster-
Identität gehören zum Auftrag. Sie entstehen vor dem Rendern. Pending-Aufträge
entwerten alte Frames auch bei einem Retry ohne Bearbeitungsrevision. Eingebettete
RAW-Kameravorschauen und progressive Zwischenframes sind nicht messbereit.
Nach Probe und vollständiger Graphvalidierung wird derselbe Gültigkeitsbeweis
erneut geprüft, auch für Fehler. Der Renderer prüft mögliche Überläufe außerhalb
der Probe und in nachfolgenden Stufen vor der einzigen atomaren Settingsübernahme.
Bedienung und Grenzen beschreibt die [Workspace-Anleitung](DEVELOP-WORKSPACE.md#schwarz--grau--und-weißpipetten).
