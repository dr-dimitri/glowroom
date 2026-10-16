# JPEG-Export

Eine unverbindliche KI-Vorschau ist kein übernommener Bearbeitungsstand. Der Exportdialog erfasst weiterhin ausschließlich `EditingModel.settings(for:)`; erst nach „Übernehmen“ fließen die vorgeschlagenen Regler in einen neu geöffneten Export ein. Der Originalvergleich und der Vergleich mit dem KI-Ausgangsstand ändern die Exportquelle nicht.

Seit der Einführung dauerhafter Rasterquellen wird der Dialog für eine Auswahl mit aktiver Artefaktquelle ausdrücklich gesperrt. Der bisherige Exportpfad gilt für Originalquellen; der Variantenexport wird separat integriert. Dadurch kann kein scheinbar erfolgreicher Export versehentlich das importierte Original anstelle des gewählten Rasterstands verwenden.

Der Dialog orientiert sich an den Bereichen Speicherort, Dateieinstellungen und Bildgröße des [Lightroom-Exportdialogs](https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-files-disk-or-cd.html). Er exportiert die ausgewählten Fotos mit den beim Öffnen erfassten Bearbeitungsständen. Raster, Einzelansicht und Filmstreifen bieten den Export im Kontextmenü an. Ein Kontextklick auf ein ausgewähltes Bild verwendet die bestehende Auswahl; ein nicht ausgewähltes Bild wird einzeln ausgewählt und exportiert.

## Verarbeitung

`JPEGExportModel` hält Eingaben, Status, Abbruch und Bestätigung für vorhandene Zieldateien auf dem MainActor. Ein unveränderlicher `JPEGExportRequest` enthält Original, Bearbeitungen, Ausgabemaße, Qualität, Farbraum und Ziel. Bei einer Überschreibbestätigung wird genau dieser Auftrag erneut verwendet. Der Originalschutz bleibt dagegen aktuell: Jeder Auftrag behält den Zugriff auf die Schutzinstanz seiner Bibliothek, auch bei Stapelfortsetzung und erneutem Versuch.

Mehrere Bilder erhalten gemeinsame Exportoptionen und automatisch eindeutige Dateinamen auf Basis von `Originalname-bearbeitet.jpg`. Namenskollisionen innerhalb der Auswahl werden unabhängig von Groß-/Kleinschreibung und Unicode-Normalisierung durch Zahlenzusätze aufgelöst. Die sichtbare Bildreihenfolge bestimmt die Reihenfolge der Aufträge. Bei Namenskonflikten mit vorhandenen Dateien wird jeder betroffene Auftrag ausdrücklich bestätigt; die übrige Warteschlange behält ihre angenommenen Ziele und Optionen. Ein Fehler pausiert den Stapel für einen erneuten Versuch. Ein Abbruch stoppt die verbleibenden Aufträge und zeigt bereits erfolgreich veröffentlichte Ergebnisse weiter an.

`JPEGExporter` führt Decodierung, Rendering und Dateiarbeit auf einem eigenen Actor aus. Vollauflösende Exporte bleiben wegen ihres Speicherbedarfs seriell; die bestehende Vorschauverarbeitung, UI und Speicherung können parallel weiterlaufen. Der Exportkontext hat niedrige Priorität und keinen Zwischenbild-Cache.

1. Optionen, Ziel und Speicherbedarf prüfen.
2. Das vollständige Original mit ImageIO decodieren und EXIF-Orientierung anwenden. `CreateThumbnailFromImageAlways` erzwingt die Originalquelle statt einer eingebetteten Kameravorschau; die maximal angeforderte Kantenlänge entspricht hier der Originalgröße. Die tatsächlich decodierten Maße müssen mit den orientierten Originalmaßen übereinstimmen.
3. Den gemeinsamen `EditRenderer.filterGraph` anwenden. Vorschau und Export teilen sich Filtergleichungen und Reihenfolge; der Export unterliegt nicht der Vorschaugrenze von 4096 Pixeln.
4. Bei Bedarf mit Lanczos skalieren, transparente Bereiche auf Weiß zusammensetzen und nach sRGB oder Display P3 umrechnen. Das Ergebnis wird als 8-Bit-JPEG mit der gewählten ppi-Angabe geschrieben. sRGB erhält die standardisierte EXIF-Kennzeichnung `ColorSpace=1`; Display P3 ein eingebettetes ICC-Profil. ImageIO entscheidet über die native Profileinbettung. Beide Arten der Farbraumkennzeichnung sind in der [ICC-Dokumentation](https://www.color.org/whitepapers/ICC_White_Paper36-Embedding_and_referencing_profiles.pdf) beschrieben.
5. Die fertige temporäre Datei atomar unter dem gewünschten Namen veröffentlichen.

Der Speichercheck schätzt Originalpixel mit 48 und Ausgabepixel mit 12 Byte pro Pixel. Das Budget beträgt ein Viertel des physischen Speichers, höchstens 8 GiB. Dies ist ein Planungsbudget, keine harte Grenze für interne ImageIO-/GPU-Allokationen. Zu große Aufträge scheitern verständlich und werden nicht still verkleinert. RAW-Unterstützung und Decodierung bleiben von macOS/ImageIO abhängig.

## Dateisicherheit und Abbruch

Ein exklusiv erzeugtes temporäres JPEG liegt im Zielordner; ImageIO schreibt über einen Datenkonsumenten direkt in dessen Dateideskriptor. Der Zielordner bleibt über einen geöffneten Deskriptor festgelegt. Vorhandene Dateien werden vor dem Rendern erkannt und nur nach ausdrücklicher Bestätigung ersetzt. Ohne Bestätigung verhindert `RENAME_EXCL` auch eine zwischenzeitlich neu angelegte Zieldatei.

Kanonische Pfade und Geräte-/Inode-Identitäten schützen das Quellbild und die bekannten importierten Originale auch bei alternativen Pfaden oder Hardlinks. Symbolische Links als Zieldatei werden abgewiesen. Ein fehlgeschlagener oder vor der Veröffentlichung abgebrochener Auftrag entfernt seine temporäre Datei und erhält eine bereits vorhandene Ausgabe. Nach erfolgreicher atomarer Veröffentlichung wird Erfolg gemeldet, auch wenn unmittelbar danach ein Abbruch eingeht.

Vor jedem Versuch und nach der Kodierung liest der Hintergrundexport den aktuellen gespeicherten Katalog und berücksichtigt zusätzliche Originalpfade aus laufender Wiederherstellung. Die abschließende Prüfung der Katalogreferenz und die atomare Veröffentlichung teilen sich den nativen Publikationslock mit allen kooperierenden Katalogschreibern. Ein neuer Katalogstand zwischen Schutzprüfung und Lock führt zu einem sicheren Fehler und kann erneut versucht werden.

Schon angenommene Imports werden vor dem Start ihres Scans registriert, einschließlich wartender Importbatches. Solange ein solcher Import oder eine Neuzuordnung von Originalpfaden läuft, veröffentlicht der Export keine Datei. Ein bereits offener Dialog bleibt erhalten und meldet, dass der Vorgang nach Abschluss wiederholt werden kann. Die Registrierung bleibt bei Abbruch bis zur tatsächlichen Rückkehr laufender Arbeit bestehen; noch nicht gestartete Batches geben sie frei. Eine kurze gemeinsame Sperre schützt die Generation dieser Registrierung bis zum finalen Dateicheck und Rename. Kataloglesen, Identitätsprüfung, Warten auf den nativen Lock und Rendering liegen außerhalb dieser Sperre und außerhalb des MainActors. Ein fehlerhaft geöffneter Katalog sperrt auch bereits offene Exportdialoge.

Synchrones Systemrendering ist nicht jederzeit unterbrechbar. Der Dialog bleibt während eines angeforderten Abbruchs deshalb beschäftigt, bis der Export tatsächlich zurückgekehrt ist. PicEdit verhindert das Beenden während dieser Phase. Andere Programme sollten Quelle und Ziel während eines Exports nicht gleichzeitig umbenennen oder ersetzen; es besteht keine prozessübergreifende Schreibsperre für externe Anwendungen.

## Prüfung

Regressionen für [Issue #27](https://github.com/dr-dimitri/picedit/issues/27) verwenden ausschließlich synthetische Bilder und eigene temporäre Kataloge: verspätete Imports bei offenem Dialog und Überschreibbestätigung, ein noch blockierter Scanner nach der Kodierung, wartende und abgebrochene Importbatches, neue Originale und Hardlinks vor Start/nach Rendering/nach dem finalen Snapshot, zwischenzeitlich abgeschlossene Annahmen sowie neue Wiederherstellungs-Schutzpfade. Sie prüfen erhaltene Originalbytes, entfernte temporäre JPEGs und die Möglichkeit eines späteren erlaubten Exports. Build- und Laufergebnisse des integrierten Standes stehen in [REVIEW.md](REVIEW.md).

Geprüft am 16. Oktober 2026 in einer normalen macOS-Sitzung mit Core Image:

- Gesamtsuite: **171 Tests bestanden**, zwei optionale Tests übersprungen (Analyse-Benchmark und Kamera-RAW-Export ohne freigegebene Eingabedatei). Die Mehrfachauswahl ergänzt zwölf Auswahltests und sechs Batch-Controller-Tests, unter anderem für eingefrorene Bearbeitungen/Optionen, Namenskollisionen und lange Unicode-Dateinamen, Überschreiben, Abbruch und Wiederholung nach Fehlern.
- Bildtests: volle Auflösung oberhalb der Vorschaugrenze, EXIF-Orientierung, maßhaltiges Skalieren, echte sRGB-/Display-P3-Pixelkonvertierung, Farbraumkennzeichnung, Weiß für Transparenz, ppi-Metadaten, Filtergleichheit und Qualität/Dateigröße.
- Zustands- und Dateitests: unveränderliche Bearbeitungsaufträge, Abbruch vor und nach Kodierung, Fehler nach Kodierung, bestätigtes Ersetzen, konkurrierende Zielerstellung, Schutz von Originalpfaden und Hardlinks, erneuerte Original-Inodes und Bereinigung temporärer Dateien.
- Dialogtest mit isoliertem Katalog: Display-P3-JPEG mit 600 × 400 Pixeln, Qualität 82 und 240 ppi; Ausgabe mit ImageIO/Systemwerkzeugen geprüft. Ordnerwahl, ungültige Qualität, gespeicherte Optionen, Tastenkürzel und Ersetzen-Bestätigung erfolgreich durchgespielt.
- Mehrfachauswahl im isolierten Testkatalog: kurze ⌘-/⇧-Klicks, ⌘A, Doppelklick und Abwahl des letzten Bildes im Filmstreifen geprüft. Drei Bilder über das Kontextmenü exportiert; Anzahl, Dateinamen und Originalabmessungen der JPEGs bestätigt. Modifikatoren werden am Klickereignis erfasst, damit ein Loslassen während der Doppelklickerkennung die Auswahl nicht verändert.
- Debug-Bundle erfolgreich erstellt und Signatur geprüft. Es bleiben die bereits vorhandenen Core-Image-Kernel- und lokalen Toolchain-Warnungen.

Ein zusätzlicher Versuch mit einer vorhandenen CR3-Datei (6000 × 4000 Pixel) im Cloud-Ordner scheiterte bereits beim Lesen an macOS-Zugriffsrechten (`EPERM`). Eine erfolgreiche Kamera-RAW-Exportprüfung wird daher nicht behauptet. Der optionale Test kann mit einer zugänglichen Kamera-RAW-Datei über `PICEDIT_RAW_EXPORT_TEST_FILE` ausgeführt werden; er prüft Originalauflösung, bearbeitete P3-Ausgabe und unveränderte Quelldaten.

```sh
PICEDIT_TEST_BUILD_PATH=/private/tmp/picedit-export-backend-tests scripts/test.sh --jobs 3
PICEDIT_BUILD_PATH=.build-app PICEDIT_BUILD_JOBS=4 scripts/build-app.sh
# Optional: zugängliche Kamera-RAW-Datei ausdrücklich angeben
PICEDIT_RAW_EXPORT_TEST_FILE=/absoluter/pfad/Bild.CR3 scripts/test.sh --filter explicitlySuppliedCameraRAW
```
