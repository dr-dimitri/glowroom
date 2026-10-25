# Persönliche Entwicklungsvorgaben

Entwicklungsvorgaben speichern direkt reproduzierbare Einstellungen ohne KI-Modell.
Sie sind von kreativen Farbprofilen (ein Teil der Farbgruppe) und KI-Auftragsvorgaben
(eine Anweisung für den nächsten Modellvorschlag) getrennt.

## Bedienung

Im Entwickeln-Inspektor enthält „Entwicklungsvorgaben“ die persönliche Liste und
vier Gruppenschalter. „Speichern …“ hält die gewählten Gruppen des aktuellen
Bildstands fest. „Verwalten“ bietet Umbenennen, Löschen, Import und Export.
Eine ausgewählte Vorgabe lässt sich auf eine Teilmenge ihrer gespeicherten Gruppen
beschränken. „Vorschau“ entwickelt diesen unverbindlichen Entwurf über den
bestehenden Quell-/Rendercache. „Verwerfen“ ändert weder Speicherung noch Undo;
erst „Übernehmen“ erzeugt einen regulären Entwicklungsschritt. Ein wirkungsloser
Entwurf fügt keinen Undo-Schritt hinzu. Ein Foto- oder Vorgabenwechsel verwirft
veraltete Vorschauen. Vor Annahme werden Bildquelle und Zielkontext erneut geprüft.
Undo/Redo, Bildspeicherung und Bildexport verwenden den angenommenen normalen Bildstand.

## Selektive Gruppen und Kompatibilität

Das erste Austauschformat enthält ausschließlich diese Gruppen:

| Gruppe | Enthaltene Einstellungen |
|---|---|
| Licht | Belichtung, Kontrast, Lichter, Schatten, Weiß, Schwarz, historische automatische Tonwerte und Stärke der natürlichen Balance |
| Tonwertkorrektur | Globale Master-/RGB-Levels samt Gamma und expliziten Begrenzungen |
| Farbe | Weißabgleich, kreatives Profil, Schwarzweiß, Dynamik, Sättigung und Farbanteil der natürlichen Balance |
| Details | Textur, Klarheit, Dunst entfernen, Luminanz-/Farbrauschen und alle vier Schärferegler |

Punktkurven benötigen eine spätere ausdrückliche Formaterweiterung. HDR-/Ausgabemodus,
Zuschnitt und Geometrie, Masken, Reparaturen sowie Quellen, Kataloge und Artefakte
sind ausgeschlossen. Nicht gewählte Gruppen bleiben im Ziel wertgleich erhalten.
Explizite neutrale Werte werden angewandt; ein ausgelassener Regler bleibt erhalten.

Die Vorgabe enthält die verwendete `toneProcessingVersion`. Vorschau und Annahme
sind nur bei derselben Zielversion möglich. Die Anwendung verändert diesen Prozess
niemals. Eine gewünschte bestehende Prozessaktualisierung ist eine separate Aktion.

## Austausch und persönliche Bibliothek

Eine `.glowroompreset` ist eine JSON-Datei mit `schemaVersion: 1`, UUID, Name,
optionalem Beschreibungstext und versioniertem `DevelopSettingsPatch`. Die äußere
und die Patchversion werden unabhängig geprüft. Namen werden außen getrimmt,
enthalten 1–120 Graphemcluster und höchstens 512 UTF-8-Bytes. Beschreibungen sind
auf 2000 Graphemcluster und 8 KiB begrenzt. Die gesamte Datei darf maximal 1 MiB
umfassen. Exportziele müssen die Endung `.glowroompreset` haben; Originalbilder oder
andere Dateitypen können über diese Aktion nicht überschrieben werden.
Es besteht keine XMP-/Lightroom-Kompatibilität.

Unbekannte Felder oder Controls, falsche Versionen/Typen, doppelte JSON-Schlüssel
(auch identisch nach Unicode-Escape-Decodierung), doppelte Controls/Gruppen,
NaN/Unendlich und Werte außerhalb der vorhandenen Reglergrenzen werden vollständig
abgelehnt. Es findet weder stilles Klemmen noch ein Teilimport statt. Die begrenzte
JSON-Prüfung erfolgt vor Codable, die Feldstruktur wird danach rekursiv geprüft.
Unvertrauenswürdige Austauschdaten müssen über `DevelopPreset.decode(_:)` laufen.

Die persönliche Bibliothek liegt unter
`~/Library/Application Support/Glowroom/DevelopPresets/`. CRUD und Austausch laufen
geordnet auf einem eigenen Actor, ohne Bilddecodierung oder Zugriff auf Katalog,
Backups und Modelle. Jede einzelne Datei wird atomar ersetzt; ein fehlgeschlagener
Import veröffentlicht keine halbe Vorgabe. Die Bibliothek ist auf 1024 Dateien
begrenzt. Beschädigte Bibliotheksdateien werden ausdrücklich gemeldet.

Jeder Import erhält eine neue UUID. Ein bereits vorhandener Name wird ohne
Beachtung der Groß-/Kleinschreibung als Kollision behandelt und bekommt den Zusatz
` (Importiert 1)`, dann ` (Importiert 2)` usw.; der Stamm wird dabei innerhalb der
Namensgrenzen gekürzt. Umbenennen behält die ID. Importierte Dateien überschreiben
keine gleichnamige persönliche Vorgabe.

## Prüfung

`DevelopPresetTests` prüft selektive Übernahme und den Erhalt ausgeschlossener Werte,
explizite Neutralwerte gegenüber Omission, Prozesskompatibilität, Roundtrip,
Namens-/Bytegrenzen sowie ungültige/duplizierte/unbekannte JSON-Inhalte.
`DevelopPresetStoreTests` prüft Neustart, CRUD, ID-/Namenskollisionen, atomaren
Austausch, Importfehler und Symlink-Abweisung. Die Tests verwenden ausschließlich
synthetische Settings und temporäre Dateien.
