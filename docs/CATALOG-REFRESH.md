# Ordneraktualisierung und nicht verfügbare Originale

**Ordner aktualisieren** ergänzt neu gefundene Fotos und aktualisiert die
Datei-/Aufnahmedaten erfolgreich gelesener Originale. Bereits bekannte Fotos,
die bei einem Scan fehlen oder nicht gelesen werden können, bleiben im Katalog.
Dies gilt auch für vorübergehend verschobene Unterordner und überlappend
eingebundene Fotoordner.

Die gespeicherte Bildkennung, Original-URL und Ordnerzuordnung bleiben erhalten,
ebenso Sterne, Favorit, Bearbeitung und Bildinformationen einschließlich
bestätigter Texte und manueller Entwürfe. Diese Einträge bleiben auch in der
Bibliothek und ihrem Ordnerbaum sichtbar. Beim Öffnen eines fehlenden Originals
gilt die bestehende Fehleranzeige der Vorschau; es entsteht kein neuer
Verfügbarkeitszustand im Katalogformat. Ein gespeicherter Rasterstand kann
weiterhin unabhängig von seinem Original angezeigt werden.

Der vollständige Katalog wird gespeichert. Dadurch erhält auch die
Startbereinigung nach einem Neustart während der Nichtverfügbarkeit die
zugehörigen Datensätze. Das bloße Auslassen eines Cleanup-Aufrufs würde diesen
Schutz nicht bieten.

Erst **Ordner entfernen** beendet die Katalogzuordnung ausdrücklich. Ist das Foto
weiterhin durch einen anderen eingebundenen Ordner abgedeckt, übernimmt dieser
die Zuständigkeit und die Daten bleiben erhalten. Mit dem letzten zuständigen
Ordner werden die aktiven Bearbeitungs- und Bildinformationsdaten weiterhin
bereinigt. Originaldateien bleiben unverändert.

## Regressionen

`CatalogRefreshRetentionTests` verwendet ausschließlich synthetische PNGs in
temporären Ordnern, den produktiven `FolderScanner`, `LibraryModel`,
`CatalogWriter` und echte Editing-/Metadaten-Repositories. Geprüft werden:

- Verschieben, Aktualisieren und Zurücklegen mit Bewertung, Favorit,
  Belichtung, bestätigtem Titel/Tags und manuellem Entwurf.
- Neustart mit neu geöffneten Repositories während der Nichtverfügbarkeit,
  jeweils mit einfachem und überlappend eingebundenem Unterordner.
- Erhalt bei beschädigtem Bild und vollständig unerreichbarem Stammordner.
- Neue Fotos und aktualisierte Bildmaße nach einem erfolgreichen späteren Scan.
- Datenübernahme durch einen verbleibenden Ordner sowie vollständige Bereinigung
  nach dessen ausdrücklichem Entfernen; bytegleiche Originale im Verschiebeablauf.

Die bisherigen Workflow-, Alias- und Projektionsprüfungen erwarten denselben
Erhaltvertrag. Die Reconciliation bleibt seriell auf ihrem bestehenden
Hintergrund-Actor, da jeder neue Katalog auf dem vorherigen Zustand beruht.
Unabhängige Bildmetadaten liest der Scanner weiterhin begrenzt parallel;
Editing- und Textbereinigung laufen wie bisher unabhängig voneinander.
