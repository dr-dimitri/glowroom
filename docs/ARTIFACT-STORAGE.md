# Dauerhafte Rasterquellen und Bearbeitungspakete

Issue 10 führt eine dauerhafte Bildquelle neben dem importierten Original ein. Diese Grundlage schaltet noch keine generative Endnutzerfunktion frei. Der JPEG-Export für aktive Rastervarianten bleibt bis zur gesonderten Variantenexport-Integration gesperrt.

## Bedienung und gespeicherter Stand

Ein `EditingSnapshot` enthält Quelle und Regler gemeinsam. Kataloganker und `PhotoAsset.id` bezeichnen weiterhin das importierte Original. Ein übernommenes flaches Raster enthält bereits die gerenderte Eingabe; die neuen Regler beginnen neutral. Frühere Regler werden dadurch nicht doppelt angewendet.

- **Zurücksetzen** neutralisiert nur die Regler der aktiven Quelle.
- **Zum importierten Original zurückkehren** wechselt die Quelle mit einem eigenen Undo-Schritt.
- **Importiertes Original anzeigen** zeigt das Original ohne Regler.
- **Aktuelle Quelle ohne Regler** zeigt die aktive Quelle ohne zusätzliche Regler.
- Vergleiche ändern keinen gespeicherten Stand. Undo/Redo umfasst Quelle und Regler; der Verlauf gilt für die Sitzung. Aktiver Stand und angenommene Varianten sind dauerhaft.

Ein gespeichertes Artefakt bleibt bei fehlender Originaldatei verfügbar. Grid, Filmstreifen, Einzelbildansicht und die kleine Vorschau im Info-Inspector verwenden dieselbe aktive Bildquelle. Die Inspector-Vorschau behält die höhere Ladepriorität des ausgewählten Fotos. Ein fehlendes oder beschädigtes Artefakt zeigt einen Fehler; es wird nicht still durch das Original ersetzt. Cache-Identitäten enthalten Store, Artefakt, Manifest, Raster und Geometrie. Regleränderungen verwenden die decodierte aktive Basis erneut.

Ein begrenzter Speicher mit 128 erfolgreichen Payloadprüfungen hält ausschließlich native Stempel und Manifest-/Rollenidentitäten. Jedes Öffnen eines Readhandles öffnet Pfad und Manifest frisch; nur ein exakt unveränderter bereits geprüfter Inode spart erneutes Hashing und PNG-Decodieren. Reader prüfen die tatsächliche Bindung weiter vor und nach jedem Lesen. Veröffentlichung, Commit- und Paketvalidierung bleiben vollständig. Unter Speicherdruck werden entbehrliche Artefakt-Cachebezüge freigegeben; tatsächliche Leser bleiben angerechnet. Begrenzte Wiederholung und eine sichtbare Ladeaktion ersetzen unbegrenztes Warten.

## Format und Ressourcen

`GeneratedArtifacts/<UUID>/` enthält `artifact.json`, `raster.png` und gegebenenfalls typisierte Masken-PNGs. Die positive Store-Identität steht in `.owner.json`. Rollen ergeben ausschließlich feste relative Dateinamen; JSON autorisiert keine freien Pfade.

Raster sind orientierte SDR-PNGs mit ganzzahligen RGB- oder geraden RGBA-Komponenten, jeweils 8 oder 16 Bit, und exakten eingebetteten sRGB- oder Display-P3-ICC-Bytes. Ein `iCCP`-Chunk enthält das Profil; konkurrierende Farbraum-Chunks werden entfernt. Der Samplehash berücksichtigt RGB auch bei vollständig transparenten Pixeln. HDR/Gleitkomma, CMYK, indizierte Farben, fremde Profile und vormultiplizierte Eingabepuffer werden abgewiesen. Es findet keine versteckte Konvertierung statt. Masken verwenden normales Gray8-PNG ohne Farbprofil und keine invertierte Quartz-Bildmaske.

Geometriegrenzen sind 16.384 Pixel Kantenlänge und 16.777.216 Pixel. Ein Payload darf höchstens 512 MiB, ein ICC-Profil 1 MiB umfassen. Zusätzlich gilt die Speicherzulassung einschließlich nativer Zeilenbreite, Eingabepuffern und Codec-Scratch. Auch eine geometrisch zulässige Eingabe kann deshalb am Speicherbudget scheitern.

Die Provenienz enthält eingefrorene Elternquelle und vollständigen Snapshot, gerenderte Eingabe mit Pixelhash, Ausgabegeometrie/Platzierung, Pipeline-/Parameterversion, Modell-/Providerkennung, Parameter, gegebenenfalls Seed/Prompt, Zeitpunkt und lokale oder Cloud-Ausführung. Zugangsdaten gehören nicht zum Vertrag. Öffnen und Restore benötigen weder Modell noch Netzwerk.

Ein gemeinsamer Ressourcenowner begrenzt angerechnete eigene Raster-/Codec-Puffer auf 512 MiB, tatsächliche Codec-Arbeit auf eins und Transfers auf zwei. Wartende Arbeit bleibt angerechnet und begrenzt. Geteilte Reservierungen zählen dieselbe Allokation einmal; verschiedene Bildpuffer müssen zusammen hineinpassen. Native Slots bleiben bis zur tatsächlichen Rückkehr gehalten. Die Grenze ist kein Gesamt-RSS- oder GPU-Speicherdeckel. Bildarbeit läuft außerhalb des MainActor. Abhängige SQLite-/Katalogübergänge bleiben seriell; unabhängige Kopien und Prüfungen verwenden begrenzte Parallelität.

## Aktivierung, Migration und Wiederanlauf

Der Speicher schreibt zuerst in eigenes Staging, prüft PNG-Struktur, Samples, Profil, Maße und Hashes und publiziert anschließend unveränderlich. Erst danach aktiviert die SQLite-Transaktion Quelle, neutrale Regler, Revision, Varianten und Commit-Receipt gemeinsam. Dateisystem und SQLite bilden keine gemeinsame ACID-Transaktion. Ein SQL-Fehler erhält den alten aktiven Stand; veröffentlichte Orphans werden konservativ behalten. Wiederholungen verwenden dieselbe Commit-ID und denselben Requesthash; eine andere Anfrage unter derselben ID wird abgewiesen.

Angenommene Schreibaufträge werden synchron vor Taskstart registriert und bis zur tatsächlichen Rückkehr stark gehalten. Aktivierung vergleicht Quellenfingerprint, Quelle, Regler, Store-Epoch und Revision mit dem eingefrorenen Ausgangsstand. Ein spätes Ergebnis darf neuere Änderungen oder einen Restore nicht überschreiben. Ein Vorschauabbruch widerruft keinen angenommenen Commit.

Schema 2 übernimmt Schema-1-Regler, Revisionen und Tombstones als Originalquellen. Alte WAL-Familien werden zuerst auf einer privaten Kopie logisch validiert und bytegenau unter `EditMigrationArchives` archiviert; erst danach erfolgen Checkpoint und Migration. Unbekannte/fremde Schemata und beschädigte Daten werden nicht automatisch neu initialisiert.

Kooperierende Datenbankinstanzen desselben App-Prozesses ordnen ihre synchronen SQL-Abschnitte mit einem Prozessmutex anhand der tatsächlichen Geräte-/Inodeidentität. Das gilt auch für Pfadaliase und bereits geöffnete Reader. Fremde Journaldateien bleiben nach der Zulassung strikt abgewiesen. Kein SQL-Lock bleibt über ein `await` gehalten. Die nicht blockierenden Zulassungsversuche prüfen Abbruch und haben eine Frist von zwei Sekunden; ein Ablauf meldet eine beschäftigte Datenbank und gilt nicht als Beschädigungsnachweis.

Native Dateideskriptoren für Datenbank-, Paket- und Quellenprüfungen reservieren ihren Platz vor dem Öffnen. Höchstens 256 reservierte, geöffnete oder zur Schließung zurückgestellte Deskriptoren teilen denselben begrenzten Bestand. Ein Hilfsdeskriptor desselben Inodes wird erst nach tatsächlichem Ende des aktiven SQL-Abschnitts geschlossen: POSIX kann beim Schließen eines solchen Deskriptors sonst auch laufende SQLite-Sperren des Prozesses lösen. Der Drain erfolgt vor neuer SQL-Zulassung; Abbruch eines wartenden Beobachters gibt keinen noch benötigten Deskriptor vorzeitig frei. Reine Metadatenstempel benötigen keinen geöffneten Dateideskriptor.

Normale SQL-Arbeit verwendet keinen eigenen `flock` auf der Hauptdatei: Dieser kollidiert auf macOS mit SQLites nativen Sperren. Ausschließlich der abschließende, vollständig SQL-freie Recoverytausch erwirbt zusätzlich einen Kernel-Lock auf dem alten Main-Inode. Seine Sperrreihenfolge lautet Coordinator → Katalog → Prozessmutex → alter Main-Kernellock; danach wird die ursprüngliche Familie frisch geprüft. Ein noch aktiver externer SQLite-Zugriff darf den Dateitausch damit verhindern.

Die kurze Erstcreation-Sperre schließt das Nullbyte-Initialisierungsfenster innerhalb desselben Prozesses. Andere Prozesse nehmen am Prozessmutex nicht teil. Bei gleichzeitigem allererstem Öffnen aus verschiedenen Prozessen kann eine Instanz weiterhin kontrolliert eine ungültige, noch nicht initialisierte Datenbank melden; ein fremder aktiver Writer kann zur konservativen Verweigerung führen. Vorhandene Daten werden dabei nicht verworfen und fremde Journaldateien nicht als eigene angenommen.

Katalogumzüge mit geänderten pfadbasierten IDs verwenden einen gemeinsamen langlebigen Coordinator. Unter `CatalogCoordination` bleiben exakte einmal codierte Katalogbytes, ursprüngliche Teilnehmerbefehle und deren Hashes, erwartete Zustände sowie dauerhafte Store-UUIDs erhalten. Reihenfolge: vorbereitet → bewaffnet → Editing-SQL übernommen → Katalog veröffentlicht → abgeschlossen. Eine vorbereitete Abbruchentscheidung bleibt ausstehend, bis alle Teilnehmer sie bestätigen. Veröffentlichung verwendet weiterhin den einzigen `CatalogWriter`, dessen native Sperre und exakten Vorzustandsvergleich.

Startup und Wiederholung beenden oder melden gemeinsame ausstehende Vorgänge, bevor normale Änderungen zugelassen werden. Eine nachträglich fehlende erforderliche Datenbank darf einen aufgezeichneten Vorgang nicht herabstufen. Redaktionelle Metadaten sind für neue Editing-only-Pläne optional. Ohne gemeinsamen ausstehenden Vorgang bleiben manuelle Metadaten bei unabhängig beschädigter Editing-Datenbank verwendbar.

Ein unabhängig defekter Artefaktstore sperrt gesunde manuelle Bildinformationen ebenfalls nicht. Der echte SQL-/Journal-Coordinator bleibt aktiv, während ein ausdrücklich nicht verfügbarer Adapter jede Artefaktoperation verweigert und keinerlei Dateicapabilities erteilt. Original-only-Bearbeitungen können mit sichtbarer Speicherwarnung weiterarbeiten; ein gemischter Editorzustand bleibt bei fehlenden Artefakten schreibgeschützt.

Name oder Größe/Datum allein belegen keinen Umzug. Erforderlich sind native Datei-/Volumeidentität oder ein vorhandener Inhaltsnachweis. Alter Bookmark-Payload und Hash bleiben im ursprünglichen Plan; ein erneuerter Bookmark ersetzt diesen Verlauf nicht. Unbeweisbare Legacy-Zuordnungen bleiben als sichtbarer Konflikt erhalten.

Abgeschlossene Coordinator-/Teilnehmer-Receipts bleiben erhalten. Die gemeinsame Inventur ist auf 4.096 Vorgänge begrenzt; automatische Historienarchivierung ist noch nicht enthalten. Ein ausgeschöpftes Limit wird gemeldet und erteilt keine Löschberechtigung.

## Sicherungen und Recovery

Ein `.piceditbackup` ist ein Verzeichnispaket mit Manifest, geschlossenem SQLite-Online-Snapshot und allen transitiv referenzierten Artefakten, Masken und Provenienzdaten. Auch eine zulässige Kette aus 4.096 Artefakten wird iterativ geprüft, ohne den nativen Workerstack mit rekursiven Aufrufen zu belasten. **Originale, `catalog.json`, redaktionelle Bildinformationen, Caches, Schlüssel und Cloudnutzungsdaten sind nicht enthalten.** Originale und passender Katalog müssen separat gesichert werden. Bestätigte Bildinformationen behalten ihren eigenen JSON-Export; Entwürfe sind darin nicht enthalten.

Paketgrenzen: 20 GiB Gesamtinhalt, 4.096 Artefakte, 16.384 Dateien, 8 MiB Manifest und 512 MiB je Payload. Validierung verlangt den exakten Rollenbaum, begrenzte relative Pfade, Hashes, Schema, vollständige SQL-Referenzclosure und decodierbare Raster. Symlinks, Hardlinks, Traversal und zusätzliche unbekannte Paketdateien werden abgewiesen. Kopien verwenden höchstens zwei Worker mit je 64 KiB. Benutzerexporte erhalten einen neuen Namen; bestehende Ziele werden nicht ersetzt.

Nach konsistentem SQL-Snapshot und Erwerb aller Artefakt-Leases kann die unveränderliche Kopie mit weiterer Bearbeitung überlappen. Der tägliche automatische Auftrag läuft nach dem Editor-Speicherbatch separat und verwendet eine vollständig geprüfte Sicherung desselben Tages erneut. Eine vorübergehend belegte Verarbeitung oder fehlender freier Bildspeicher meldet eine verständliche Warnung; gespeicherte Bearbeitungen bleiben erhalten. Erst eine erfolgreiche Sicherung zählt für den Tag. Die nächste Speicheraktion versucht eine zuvor fehlgeschlagene automatische Sicherung erneut. Vor Rotation werden angenommene Katalogänderungen tatsächlich abgeschlossen und aktuelle Originalreferenzen unter der Katalog-Publikationssperre erneut geprüft.

Die sieben neuesten eindeutig eigenen automatischen Pakete bleiben erhalten. Eigentumsbelege binden die bei Erstellung erfassten nativen Verzeichnis-/Dateiidentitäten vor Veröffentlichung. Kopierte, ausgetauschte, veränderte und unbekannte Inhalte sowie als Original verwendete Pakete bleiben erhalten. Alte `.sqlite`-, manuelle und Sicherheitsbackups werden nicht rotiert. Grenzen sind 64 Belege, 8 MiB je Beleg und 64 MiB insgesamt. Ein ausgeschöpftes Limit verhindert eine neue automatische Sicherung kontrolliert mit Warnung; ein erfolgreicher Bearbeitungscommit bleibt erfolgreich.

Restore prüft vollständig in privatem Staging, erstellt eine Sicherheitssicherung, stellt fehlende unveränderliche Payloads bereit und wechselt danach den SQL-Zustand. Die Store-Epoch ändert sich und entwertet alte ausstehende Writes. Ältere `.sqlite`-Reglerbackups stellen Originalquellen her.

Bei beschädigter Editing-Datenbank verlangt Recovery eine ausdrückliche Benutzeraktion und einen geschlossenen Permit des gemeinsamen Coordinators. Vor finaler Installation werden Katalog-/Journalbelege und Originalschutz erneut geprüft. Vorherige Datenbankfamilie und Artefaktbaum bleiben unter `EditingRecoveryArchives`; ursprüngliche Datenbank-Inodes werden zusätzlich beiseitegelegt. Erkennbare fremde oder neuere SQLite-Schemata werden nicht ersetzt. Roharchive sind forensische Daten und keine validierten Restorepakete. Die Rohinventur begrenzt sich auf 20 GiB, 16.384 Dateien, 32.768 Einträge und Tiefe vier.

Vor der ersten nativen Familienbewegung wird `edits.sqlite-recovery.json` dauerhaft publiziert. Ein Prozessabbruch lässt damit normale Opens sichtbar gesperrt, statt eine inzwischen fehlende Hauptdatei als leere neue Datenbank zu initialisieren. Ein ausdrücklicher neuer Restore erhält den alten regulären Intent und die verbleibende Familie als Rohbelege und ersetzt die Barriere atomar. Alte Candidates und Archive bleiben erhalten. Intent-JSON wird niemals als Datei-/Löschautorität dekodiert. Erst nach vollständig installierter und synchronisierter neuer Datenbank wird die eigene unveränderte Barriere entfernt.

Konservative Grenze: Bei einem beschädigten frühesten Legacy-WAL-Zustand mit noch nicht übernommenem Mainheader (`application_id`/Version 0), dessen logische Ownership nicht mehr hinreichend nachweisbar ist, bleibt ausdrückliche Recovery gesperrt. Gültige First-open-WAL-Familien werden normal migriert; unbekannte SQLite-Daten werden nicht als leere oder eigene Datenbank interpretiert.

Startup inventarisiert Artefakte konservativ. Endgültige Artefakte und nach Neustart gefundene Stagingreste werden nicht automatisch gelöscht. Private temporäre Paketkopien können nach Ende ihrer letzten tatsächlichen Leser-/Lease-Lebensdauer bereinigt werden. Dabei werden das bei Erstellung gebundene Gesamtinventar und jede native Datei unmittelbar vor dem Unlink geprüft. Unbekannte oder ersetzte Inhalte bleiben erhalten. Höchstens 16 laufende/ausstehende Bereinigungen verhindern eine unbeschränkte Warteschlange; darüber bleiben Reste diagnostizierbar liegen.

## Nachweise und Reproduktion

Die ursprüngliche ImageIO-Probe auf M2 Pro/macOS 27.0.1 prüft alle acht Kombinationen aus RGB/RGBA, 8/16 Bit und sRGB/P3. Ganzzahlwerte einschließlich transparenter RGB-Werte und decodierte ICC-Daten sind identisch. ImageIO allein schreibt für sRGB nur einen `sRGB`-Chunk. Die getrennte Zusatzprobe ergänzt exakte `iCCP`-Bytes und prüft Chunkgrenzen, CRC, Profile und Samples erneut. Beide historischen Nachweise bleiben erhalten:

- [ImageIO-Messdaten](../reports/artifact-codec/2026-10-16-m2-pro.json), [Probe](../scripts/verify-artifact-png.swift).
- [Explizite ICC-Messdaten](../reports/artifact-codec/2026-10-16-explicit-icc.json), [ICC-Probe](../scripts/verify-artifact-png-icc.swift).

Diese Proben verwenden ausschließlich synthetische 3×2-Raster und belegen keine Performance großer Bilder. Die abschließende Testsuite besteht mit 426 App- und 270 Core-Tests; 16 explizit optionale Modell-, RAW-, Last- und Child-Einstiegstests bleiben im normalen Lauf ausgelassen. Darin sind die zusammenhängende Kette aus 4.096 Artefakten und die Wiederladung einer aufgeklappten Variantenliste nach Restore enthalten. Am vorangehenden Quellcheckpoint besteht SDK 26.5 mit 423 App-/263 Core-Tests und der Build ohne Foundation Models mit 420 App-/263 Core-Tests. Diese Kompatibilitätsläufe wurden auf macOS 27.0.1 ausgeführt; die anschließenden Reviewkorrekturen wurden im vollständigen aktuellen SDK-Lauf geprüft. Das belegt keinen Lauf auf einem älteren macOS.

Der gesonderte echte Store-/SQL-/Paketroundtrip verwendet ein synthetisches 4096×4096-RGBA8-P3-Raster ohne Original oder Modell. Der aktuelle erfolgreiche Release-Quellcheckpoint benötigt insgesamt 26,658 Sekunden einschließlich testseitiger Verifikation. Pixelhash, ICC, Provenienz und Varianten bleiben nach frischem Restore identisch. Beobachtet werden höchstens 272.695.296 Byte angerechnete Pipelinepuffer, ein Codec und zwei Transfers; das Prozess-RSS einschließlich zusätzlicher Vergleichsdecodes erreicht 558.137.344 Byte. Diese Einzelmessung belegt weder einen Leistungsgewinn noch ein Gesamt-RSS-Limit oder RAW-Verhalten. Historische erfolgreiche und fehlgeschlagene Versuche sowie exakte Quellhashes stehen im [Integrationsbericht](../reports/artifact-storage/2026-10-16-m2-pro.json). Der endgültige saubere App-Build besteht mit unveränderten Quellhashes in 166,4 Sekunden. Die isolierte UI-Prüfung bestätigt Neustart ohne Original, automatischen Varianten-Refresh nach Restore sowie ausdrückliche Recovery einer beschädigten Testdatenbank mit erhaltenen Rohbelegen. Werkzeugprobleme und der unbeabsichtigte Start des Standardkatalogs mit logisch verlustfreier Migration sind im Bericht ausdrücklich erfasst.

```sh
./scripts/test.sh --jobs 3
PICEDIT_ARTIFACT_LOAD_EVALUATION=1 ./scripts/test.sh --jobs 3 --filter largeNativeArtifactPackageRoundtripWithoutOriginals
xcrun swiftc -module-cache-path /tmp/picedit-artifact-codec-modules scripts/verify-artifact-png-icc.swift -o /tmp/picedit-artifact-icc
/tmp/picedit-artifact-icc
```

Die optionale Lastprüfung nutzt ein deterministisches 4096×4096-RGBA8-P3-Raster, echte Artefakt-/SQL-/Paketimplementierungen und ein frisches Restoreverzeichnis ohne Original. Rohdaten bleiben unter einem neuen temporären UUID-Verzeichnis. Beobachtete Ressourcenreservierungen und Prozess-RSS werden getrennt ausgewiesen. Testseitige Vergleichsdecodierung gehört nicht zum Produktionsbudget; Timing beginnt nach Store-/Basiseinrichtung. Private Fotos, Kamera-RAWs und Modelle werden nicht verwendet.
