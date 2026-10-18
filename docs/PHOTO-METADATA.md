# Bildinformationen und manuelle Sicherung

Titel, Beschreibung, Schlagwörter und Sprache sind eigene redaktionelle Daten. Sie stehen weder im JSON-Bildkatalog noch in EXIF/XMP, der Bearbeitungsdatenbank oder dem entbehrlichen Vorschaucache. Das Original bleibt unverändert. Ein bestätigter Text beweist nicht, dass die KI das Bild richtig erkannt hat.

## Pflege und Bildvorschläge

Im Inspector **Bildinformationen** wählen. Manuelle Eingabe funktioniert unabhängig von Apple Intelligence und einer funktionierenden Bearbeitungsdatenbank. Ein gesperrter oder schließender Katalog erlaubt keine neuen Änderungen. Fehler dieses Speichers werden getrennt angezeigt; die übrige Bibliothek bleibt nutzbar.

- **Vorschlagen** fordert genau einen lokalen bildgestützten Vorschlag für Titel, Beschreibung, Tags und Sprache an. Voraussetzung sind die tatsächliche lokale Bildfähigkeit, macOS 27, SDK-27-Build sowie ein bereites Systemmodell mit Deutschunterstützung. Es gibt keinen automatischen Download und keinen Cloudfallback.
- Das Modell erhält die bereinigte, orientierte Originalvorschau, maximal 1024 Pixel lange Kante und 16 MiB Rasterbytes. Dateipfade, Dateinamen, EXIF, Zugangsdaten und Regler werden nicht übergeben. Der Metadatenauftrag teilt Vorbereitung, begrenzten Scheduler und tatsächliche Modelllease mit der vorhandenen Bildanalyse.
- Vorschlag und bestätigte Inhalte bleiben getrennt. Änderungen am Vorschlag kennzeichnen ihn als bearbeitet. **Übernehmen** bestätigt ausdrücklich gewählte Felder gemeinsam als eine Metadatenrevision; Sprache ist ein eigenes Feld. Tags werden ergänzt, bis ausdrücklich Ersetzen gewählt wird. Bereits vorhandene Tagherkunft bleibt beim Ergänzen erhalten.
- **Verwerfen** verwirft ausschließlich den Vorschlag. **Neu erstellen** erfasst frische Eingabepixel und berechnet den Rasterdigest neu, selbst wenn Dateigröße und Stempel gleich aussehen. Es ersetzt keine bestätigten Texte.
- Nicht übernommene manuelle Formulare werden als Entwurf am ursprünglichen Foto erhalten. Ein bewusst angenommener Speichervorgang bleibt an dieses Foto gebunden und läuft auch nach einem Auswahlwechsel zu Ende. Bewertungen, Favoriten und ein beginnendes Beenden verhindern die Übernahme einer erfolgreich gespeicherten Entwurfsrevision nicht. Beim Beenden werden diese Vorgänge abgewartet. Neuere Formulareingaben, geänderte Bildquellen und bereits geladene neuere Revisionen bleiben vor älteren Ergebnissen geschützt. Verspätete Modellantworten dürfen neuere Formulare oder bestätigte Inhalte nicht überschreiben.

Grenzen nach NFC-/Whitespace-Normalisierung: 120 Zeichen/1024 UTF-8-Bytes Titel, 2000 Zeichen/16 KiB Beschreibung, höchstens 20 Tags mit je 60 Zeichen/512 Bytes und insgesamt 24 KiB Feldtext. Tags werden nach einer festen sprachunabhängigen Groß-/Kleinschreibung dedupliziert; die erste Darstellung bleibt. Bewusst geleerte bestätigte Inhalte bleiben als Revision erhalten und werden nicht als fehlender Importeintrag behandelt. Ungültige Modellantworten werden vollständig abgelehnt, weder gekürzt noch teilweise gespeichert. Nach einem fehlgeschlagenen Entwurfsspeichern bleibt der genaue Formulartext sichtbar; bis zur Korrektur, Übernahme oder ausdrücklichem Verwerfen sind fremde Formularaktionen gesperrt.

## Dauerhafter Speicher und Suchbezug

`photo-metadata.sqlite` liegt im konfigurierten Katalogverzeichnis. Es besitzt eine eigene Application-ID, Schema-Version, atomare Transaktionen, monotone Record-/Confirm-/Draftrevisionen und dauerhafte Operationsreceipts. Wiederholen derselben Operations-ID mit identischem normalisiertem Inhalt erzeugt keine zweite Revision; anderer Inhalt unter derselben ID wird abgelehnt. Ein Suchsnapshotfehler nach erfolgreichem Commit macht diesen Commit nicht rückgängig und bleibt sichtbar.

Nur bestätigte, aktuell zugeordnete Inhalte sind suchbar. Die Bibliothek übergibt einen unveränderlichen Snapshot mit eigener Generation an den Hintergrund-Projektionsworker. Titel, Beschreibung und Tags ergänzen Dateiname/Kamera/Format; Ordner, Bewertung und Favoriten sowie ein wörtlicher Filter gelten vor der semantischen Top-K-Auswahl. Entwürfe bleiben außerhalb der Suche. Eine Textänderung erzeugt keine neuen Bildembeddings.

Beim Refresh bleiben bestätigte Inhalte vorhandener Katalogbilder erhalten. Eine Originaländerung kennzeichnet die vorherige Analyse und ihren Quellenbezug als veraltet; ein vorübergehend nicht lesbares Original löscht keine Texte. Vollständig aus dem Katalog entfernte Fotos verlieren ihre Datensätze einschließlich bestätigter Texte, manueller/KI-Entwürfe, Operationsbelege und abgeschlossener Zuordnungsjournale in der aktiven Datenbank. Beim Start werden auch alte verwaiste Datensätze bereinigt. Erneutes Hinzufügen beginnt ohne frühere Bildinformationen. Laufende oder ungeklärte Zuordnungsänderungen verhindern die Bereinigung. Überlappende Ordner und Wechsel der Ordnerzuständigkeit duplizieren keine Angaben und erhalten weiterhin eingebundene Bilder.

Bookmark-Relocation verwendet ein ausdrücklich geprüftes Mapping zwischen alten und neuen Asset-IDs. Ein gleicher Dateiname genügt nie. Native historische Identität verlangt zusätzliche belastbare Belege; andernfalls bleibt die Zuordnung offen oder bedarf bewusster Auswahl. Bestehender Zielinhalt wird niemals automatisch überschrieben. Getrennt behalten erhält beide Datensätze; Übertragen ist nur auf ein tatsächlich unbestätigtes und entwurfsfreies Ziel möglich.

Katalog und Metadaten sind zwei unabhängige Dateien. Deshalb wird ein ausstehendes Mapping zuerst dauerhaft mit vorherigem/nachfolgendem Katalogdigest gesichert, danach werden exakt vorbereitete Katalogbytes veröffentlicht und zuletzt die Zuordnung abgeschlossen. Ein Neustart erkennt beide eindeutigen Zustände; ein abweichender Katalogstand bleibt ein sichtbarer Konflikt. Betroffene IDs bleiben währenddessen gegen widersprechende Writes gesperrt.

Unbekannte, zukünftige oder beschädigte Datenbanken werden vor verändernden SQLite-Einstellungen erkannt und bewahrt. Es gibt kein automatisches Löschen oder Ersetzen durch eine leere Metadatenbank. Unerwartete Begleitdateien oder eine erforderliche Journal-Recovery werden als gesonderter Wiederherstellungsbedarf gemeldet. Dies ist kein Vorschaucache-Neuaufbau.

## JSON-Export und -Import

**Bildinformationen exportieren** schreibt ausschließlich bestätigte Einträge samt Herkunft, ursprünglicher Revision und Quellenbezug. Auch ausdrücklich geleerte bestätigte Einträge gehören dazu. Keine KI-/manuellen Entwürfe, Originalbilder, Bookmarks, nativen Vertrauensstamps, Schlüssel, Regler oder Katalogdaten werden exportiert. Die bisherigen Bearbeitungsbackups enthalten diese Datenbank nicht; beide Sicherungen haben getrennte Umfänge.

Der Export schreibt zuerst in eine eigene temporäre Datei und veröffentlicht nur nach vollständigem Erfolg. Fehler und Größenüberschreitungen erhalten ein bisheriges Ziel. Aktive Datenbanken, Modelle, Artefakte, geschützte Verzeichnisfamilien und Originale sind auch über Symlinks/Hardlinks keine Exportziele. Fehlende Pfade werden über ihren erreichbaren nativen Präfix verglichen; der Schutz berücksichtigt die tatsächliche Groß-/Kleinschreibungssemantik des Volumes. Bestehende Aliaswurzeln einer geschützten Verzeichnisfamilie werden ohne Unterverzeichnis-Crawl in höchstens 4096 direkten Verzeichniseinträgen geprüft. Eine unbekannte Volumeeigenschaft, unauflösbare Aliasstruktur oder überschrittene Prüfgrenze bricht den Dateivorgang ab, statt einen möglicherweise geschützten Pfad freizugeben.

**Bildinformationen importieren** prüft das gesamte Dokument vor dem ersten Write: genau unterstützte Version, bekannte und eindeutige Keys, Typen, Revisionswerte, Herkunft und Feldgrenzen. Standard ist ausschließlich fehlende Einträge ergänzen. Bestehende Bestätigungen und Leertombstones werden als Konflikte zur bewussten Entscheidung angezeigt. Die Übernahme prüft die aktuellen Revisionen und erfolgt als eine Transaktion. Unbekannte Asset-IDs bleiben unzugeordnet; es gibt keine Dateinamenheuristik und keinen Dateicrawl aus fremden Importpfaden.

JSON v1 enthält `schemaVersion`, `normalizationVersion`, `exportID`, `exportedAt` und `entries`. Portable Zeitangaben sind endliche UTC-/Unix-Sekunden seit 1970; sie werden nicht als neue lokale Identitätsbelege verwendet. Interne Quellen-/CAS-Zeitwerte werden dagegen bitgenau im nativen Reference-Date-Intervall gespeichert, ohne Epochwechsel. Dadurch bleiben auch aufeinanderfolgende darstellbare Double-Zeitwerte nach Neustart unterscheidbar.

Ein Import/Export ist auf 64 MiB, 25.000 Einträge und 128 KiB je Eintrag begrenzt. Eine Importprüfung belegt höchstens 128 MiB berechnete Kosten und verfällt nach 15 Minuten Inaktivität einschließlich Schlafphasen des Rechners; es bleibt höchstens eine Prüfung offen. Kein Limit erzeugt eine stille Teilmenge. Der lokale Datenbestand bleibt bei Überschreitung erhalten. Suchsnapshots sind separat auf 100.000 nichtleere zugeordnete Einträge, 64 MiB UTF-8-Text und 96 MiB berechnete Kosten begrenzt. Diese Budgets sind keine exakten Prozess-RSS-Zusagen.

## Prüfung

Die Tests verwenden isolierte Katalogverzeichnisse, synthetische Raster und Fakes. Wesentliche Fälle sind CAS/Receipt-Replay, Neustart, beschädigte/fremde Dateien und Byteerhalt, Konfliktimport, Leerbestätigungen, Quellenwechsel, A → B → A, verzögerte Antworten und angenommene Writes beim Beenden. Der Katalog-Journaltest unterbricht zwischen Katalogveröffentlichung und Mappingabschluss. Native Visionprüfung und tatsächliche Peakmessungen sind getrennte ausdrücklich aktivierbare Läufe; deren ausgeführte Ergebnisse werden im Abschluss des Pull Requests benannt.

Die getrennten optionalen Prüfungen lassen sich so starten:

```sh
PICEDIT_RUN_PHOTO_METADATA_EVALUATION=1 ./scripts/test.sh --filter LocalPhotoMetadataEvaluationTests
PICEDIT_RUN_METADATA_LOAD_EVALUATION=1 ./scripts/test.sh --filter PhotoMetadataLoadEvaluationTests
```

Der native Lauf verwendet zwei anonym benannte synthetische Raster sowie eine explizite Neuanforderung. Ein bei ausdrücklicher Aktivierung nicht verfügbares Modell ist ein sichtbarer Fehler. Der Speicherlauf erzeugt einen eigenen UUID-Testordner (optional unter `PICEDIT_METADATA_EVALUATION_OUTPUT`) und bewahrt JSON-Bericht und synthetische Dateien zur Prüfung auf. Er misst 10.000 unzugeordnete Texte einschließlich tatsächlichem Import-/Export-Roundtrip, große Importprüfungen, Eintrags-/Bytegrenzen und den Byteerhalt eines bestehenden Ziels bei zu großem Export. Prozess-RSS ist ein kumulativer Höchststand des Testprozesses; dies ist kein Foto-, RAW-, GUI- oder Suchgeschwindigkeitsbenchmark. Beide Läufe bleiben im gewöhnlichen Testlauf ausdrücklich deaktiviert.

Der [ausgeführte Prüfbericht auf M2 Pro](../reports/photo-metadata/2026-10-16-m2-pro.json) enthält Testumfang, tatsächliche native Ausgaben, Speicher-/Lastmessungen und ihre Grenzen.
