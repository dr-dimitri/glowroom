# Integrierte Entwickeln-Ansicht

Die rechte Seitenleiste folgt der Reihenfolge Histogramm, Aufnahmedaten, Werkzeugleiste und aktive Werkzeuge. Die gemeinsame Bildfläche bleibt beim Wechsel zwischen globaler Bearbeitung, Masken, Zuschnitt und Retusche erhalten. Masken öffnen kein Sheet und kein zusätzliches Fenster.

## Grundeinstellungen

Das RGB-Histogramm folgt der tatsächlich dargestellten Vorschau. Es verwendet ein begrenztes sRGB-Raster bis 384 Pixel langer Kante; die logarithmische Höhe macht dünn besetzte Tonwerte sichtbar. Die Dreiecke schalten blaue Schatten- und rote Lichterwarnungen ein. Dies sind SDR-Vorschauwarnungen, kein RAW-Sensor-Clippingnachweis. ISO, Brennweite, Blende und Zeit stammen aus den bereits vorhandenen Metadaten. **Originalfoto** zeigt das importierte Original; die Bearbeitung bleibt gespeichert.

**Autom.** aktiviert den vorhandenen natürlichen Bildausgleich. **S/W** bewahrt vorherige Farbeinstellungen. Profile sind PicEdit-eigene kreative Profile, keine Adobe-Kameraprofile. Temperatur und Tönung arbeiten relativ auf bereits entwickelten Pixeln; 6500/0 entspricht der unveränderten Kamera-/ImageIO-Entwicklung. Das Weißabgleichmenü bietet zusätzlich relative Vorgaben für Tageslicht, Bewölkt, Schatten, Glühlampe und Leuchtstoff. Die Pipette verwendet dieselbe decodierte Quelle vor den Korrekturen, mittelt eine kleine graue Fläche und verwirft transparente, schwarze oder ausgefressene Proben. Es erfolgt kein zweites RAW-Decode. Details und HDR-Vertrag stehen unter [Farbkorrekturen](DEVELOP-COLOR.md) und [Export](JPEG-EXPORT.md).

Ein Doppelklick auf die Reglerfläche oder den Reglerknopf stellt den Neutralwert wieder her. Für normale Korrekturen ist das 0, für Temperatur 6500, Maskenstärke 100 %, weiche Kante 50 %, Pinselhärte 80 % und Radius 30. Ein reiner Einzelklick wird bis zum systemweiten Doppelklickfenster zusammengefasst; Ziehen und Tastatur bleiben unmittelbar. Ein Reset bildet einen eigenen Undo-Schritt. Zahlenfelder und Gruppen-Reset bleiben verfügbar.

## Maskieren

Die Maskenpalette enthält die Liste, **Neue Maske**, lokale Regler und **Fertig/Abbrechen**. Pinsel, lineare/radiale Verläufe, Motiv und Himmel werden direkt auf dem Bild bearbeitet. Verschiebbare Verlaufsgriffe, radiale Drehung, Pinsel-/Radiererverfeinerung, Reihenfolge, Sichtbarkeit, Duplizieren und Löschen sind verfügbar. **Fertig** übernimmt einen gesamten Maskenentwurf als einen normalen Rückgängig-Schritt. Internes Undo gilt nur für den Entwurf. Seitenbereiche dürfen verborgen werden, ohne ihn zu verlieren. **Abbrechen**, Wechsel zum Raster oder Wechsel von Foto/Quelle verwirft unbestätigte Änderungen. Bereits angenommene Speicheraufträge bleiben erhalten.

Ein Sprung über Dock oder Werkzeugmenü zu Grundeinstellungen, Assistent, Bildanalyse, Bildinformationen oder Bildständen übernimmt einen gültigen Maskenentwurf und öffnet die gewählte Gruppe. Während einer automatischen Auswahl wartet der Sprung auf deren Abschluss. Wird die Speicherung abgewiesen, bleiben Palette und Entwurf erhalten; das Ziel kann nach Behebung erneut gewählt werden. Auch Zuschnitt- und Retuschepaletten geben beim Gruppensprung die normale Seitenleiste frei. Scrollposition und Tastaturfokus werden erst nach dem Einblenden der Zielgruppe gesetzt.

Schlägt die automatische Auswahl fehl, bleiben Fehlermeldung und Entwurf sichtbar; erst ein neuer ausdrücklicher Gruppensprung übernimmt den gültigen Stand, und spätere Auswahlen führen das frühere Sprungziel nicht erneut aus.

Die Maskengeometrie bezieht sich auf die orientierte, unbeschnittene Quelle. Während der Bearbeitung zeigen die Bildwerkzeuge diese Quelle; **Fertig** zeigt wieder den gespeicherten Zuschnitt und die Ausrichtung. [Maskenvertrag](MASK-EDITING.md).

## Zuschneiden und Ausrichten

Einen Rahmen aufziehen, seine Ecken ziehen oder mit ⌘-Ziehen verschieben. Die Palette bietet frei, Original, 1:1, 3:2, 4:3, 16:9 und 2:3. Zusätzlich lassen sich 90°-Drehungen und horizontales/vertikales Spiegeln speichern. Die Werkzeugansicht bleibt unbeschnitten; **Fertig** zeigt das ausgerichtete Ergebnis. Jede abgeschlossene Geste ist ein Undo-Schritt. Vorschau und Export verwenden denselben gespeicherten Ausschnitt; Originaldateien werden nicht geändert.

## Reparieren und rote Augen

Für **Reparieren** zuerst einen sauberen Quellbereich anklicken, danach auf die Zielstelle klicken oder darüber malen. ⌥-Klick wählt eine neue Quelle. **Kopierstempel** kopiert die gewählte Stelle; **Reparieren** passt deren mittlere Farbe an die Zielumgebung an. Radius und weiche Kante bestimmen den Übergang. Dies ist manuelle Retusche und keine generative Füllung. Quell-/Zielpositionen bleiben vor Zuschnitt und Ausrichtung gebunden. Bis zu 256 Korrekturstellen werden gespeichert; die letzte oder alle lassen sich entfernen.

Für **Rote Augen** eine Ellipse um die rote Pupille ziehen. Der Filter verringert nur rote Dominanz innerhalb der gewählten Ellipse und bewahrt Alpha. Stärke gilt für neue Korrekturen. Bis zu 128 Augenbereiche sind möglich; letzte oder alle können entfernt werden.

## Verarbeitung und Datensicherheit

Histogramm, Vorschaurendering, Codec- und Bildarbeit laufen außerhalb des MainActor. Kleine Werkzeugaktionen und UI-Zustand bleiben auf dem MainActor. Histogrammaufträge werden zusammengefasst und veraltete Ergebnisse verworfen. Quellenwechsel invalidieren auch Pipettenpixel und Retuschequelle. Die vorhandenen begrenzten Vorschau-Worker und Decodes werden wiederverwendet. Pixelgraphen verwenden Core Image; Reihenfolge von Masken und Retuschestellen ist sichtbar und bleibt deshalb seriell. Komplexe Vorschauen verkleinern nur ihren Renderproxy innerhalb des gemeinsamen Speicherplans. Originale, gespeicherte Geometrie und Einstellungen bleiben erhalten.

Neue Farb- und Geometriekomponenten fehlen im neutralen Snapshot. Historische kanonische Bytes und Manifesthashes bleiben unverändert. Speicherung, Backup/Restore, Varianten, Undo und KI-Vorschlagsbaselines umfassen die neuen Werte. Der KI-Anbieter erhält dadurch keine zusätzlichen frei erfundenen Kameraprofile oder generativen Fähigkeiten.

## Prüfung und Review

Die automatisierten Fälle prüfen alte Snapshotbytes und Manifesthashes, echte SQL-/Backup-/Restore-Roundtrips, Masken- und KI-Ausgangswerte, weißpunktbezogene Farbkorrekturen, Alpha, Crop-/Rotationsabmessungen und den gemeinsamen Vorschau-/Exportgraphen. Der native HEIF-Test prüft tatsächlich 10-Bit-HLG und erhaltene Werte oberhalb von SDR-Weiß. Die Reglerfälle prüfen getrennte Undo-Gruppen, Doppelklick ohne Erstklickwert, Tastatur, native Zellerfassung ohne Target/Action sowie verspätete Rückmeldungen nach Abbruch und View-Abbau. Gesteuerte Fortsetzungen prüfen verspätete Histogrammergebnisse, Quellenwechsel und Basiswiederverwendung.

Der vollständige Lauf wird mit `PICEDIT_TEST_BUILD_PATH=/private/tmp/picedit-local-masks-tests ./scripts/test.sh --jobs 5` ausgeführt. Der abschließende vollständige Release-Build verwendet nach Prüfung und Bereinigung inaktiver generierter Ergebnisse `./scripts/build-app.sh`. Native UI-Prüfungen nutzen ausschließlich synthetische JPEGs im separaten Katalog `/private/tmp/PicEdit-LocalMasks-UI/PreparedCatalog`: Maskenpalette ohne Sheet, Zeichnen und Abbrechen, Zuschnittrahmen mit Drittelraster und Drehung, Retuschequelle und zusammenhängender Zug, Augenellipse und Regler-Neutralstellung.

Unabhängige Reviews umfassen Persistenz, HDR-/Exportvertrag, Canvasgeometrie, Ressourcenplanung, Quellenbindung und native Eingabe. Korrekturen betreffen insbesondere konservative volle Bildflächen pro Retuschestelle, getrennte HDR-Cacheidentitäten, bereitgestellte Canvasabbildung vor Zeichengesten, gepufferte Reglerwerte nach Kontext-/Wertwechsel und Abbruch verspäteter nativer Rückmeldungen.

Der dabei gefundene, unveränderte Bestandsfehler [#85](https://github.com/dr-dimitri/picedit/issues/85) betrifft kurzzeitig freigegebene Bearbeitungen während automatischem Backup-Prune. Er wird separat verfolgt. Ein nicht angenommener Maskenentwurf bleibt bei abgewiesener Speicherung erhalten; ein Werkzeugwechsel übernimmt ihn dann nicht still.

Die HDR-Anzeige folgt Apples [NSImageView-Dynamikumfang](https://developer.apple.com/documentation/appkit/nsimageview/preferredimagedynamicrange), die HDR-Dateiausgabe der [10-Bit-HEIF-Repräsentation von Core Image](https://developer.apple.com/documentation/coreimage/cicontext/heif10representation(of:colorspace:options:)). Zusätzliche Anzeigehelligkeit hängt von der aktuell verfügbaren EDR-Reserve ab; es werden keine allgemeinen Beschleunigungs- oder Lightroom-Qualitätsgewinne behauptet.
