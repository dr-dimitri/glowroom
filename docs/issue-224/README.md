# Abschluss der Lightcraft-Erweiterungen aus #224

Die verbleibenden Arbeitspakete #220–#223 ergänzen den bereits über
[PR #225](https://github.com/dr-dimitri/glowroom/pull/225) und
[PR #226](https://github.com/dr-dimitri/glowroom/pull/226) integrierten Stand.
Qualitäts-No-Gos sind ausdrückliche Entscheidungen und keine freigegebenen
Produktfunktionen.

| Issues | Ergebnis | Vertrag und Bedienung |
| --- | --- | --- |
| #213, #218, #219 | Bereits integriert: Befehle, portable Teilvorgaben, Serienübernahme | [Architekturabnahme](../ARCHITECTURE-213-219-VALIDATION.md) |
| #214, #215, #217 | Bereits integriert: Punktkurven, Maskenkomponenten, radiale Optik | Bestehende Entwicklungs- und Maskendokumentation |
| #216 | Bereits entschieden: Farbmischer-No-Go, kein Produktanschluss | [Qualitätsentscheidung](../COLOR-MIXER-EVALUATION.md) |
| #220 | Lokaler MCP-Adapter, acht geschlossene Tools, Sitzung und eigene Bildfreigabe, sichtbare Vorschläge | [MCP](../MCP.md) |
| #221 | No-Go: Zielwahl und Motivmaske verfehlen das unveränderte Gate; neuer Produktmodus deaktiviert | [Evaluation und eingefrorene Daten](../AI-EDIT-PLAN-EVALUATION.md) |
| #222 | Fixierte Referenz, aktiver Kandidat, gekoppelter/freier Zoom, persistenzgebundene Weiterautomatik | [Entwickeln](../DEVELOP-WORKSPACE.md) |
| #223 | Benannte Bildstände, Miniaturen, reine Vorschau, Als-Vorher und ausdrückliche Wiederherstellung | [Speicherung](../ARTIFACT-STORAGE.md) |

Beim KI-Plan wurden 20 Fälle vorab festgelegt. Fünf wurden vollständig mit beiden
Cachezuständen und expliziter Referenz gemessen. Nach zwei fehlgeschlagenen
Positivfällen sind höchstens noch zehn statt der geforderten elf Erfolge möglich.
Weitere Inferenz wurde beendet; 15 Fälle einschließlich aller acht Negativfälle
bleiben ausdrücklich ungemessen. Der vorhandene explizite Masken-/Korrekturweg
bleibt nutzbar. Es gibt keine Freigabe nur für die bestandenen Himmelsbeispiele.

## Review und direkt behobene Befunde

Die unabhängig entwickelten Teile wurden einzeln und integriert gegengelesen.
Betrachtungszustände verändern weder Export noch angenommene Einstellungen;
Metadatenmigrationen lassen historische Snapshotbytes und Artefakthashes
unverändert. Neue SQL-Schreibzugriffe bleiben geordnet; Vorschauen verwenden
die vorhandenen begrenzten Dienste. Native Modellphasen halten keine Lease beim
Warten auf einen anderen Modelldienst. Gleichzeitige Dateischreib-/Gitoperationen
und native Fensterereignisse werden wegen ihres gemeinsamen Zustands geordnet.

Direkt während der Umsetzung beziehungsweise Abnahme behoben:

- Referenztausch bei ausgefilterter alter Referenz konnte dasselbe Foto links und
  rechts aktiv lassen. Vergleiche werden nun vor dem Tausch geschlossen und nur
  mit einem gültigen anderen Kandidaten geöffnet. Linke Kontextaktionen können
  keine unsichtbare rechte Änderung auslösen.
- Bewertungsabschluss, Filterprojektion und gleichzeitiges Ordnerentfernen konnten
  zyklisch aufeinander warten. Weiterautomatik wartet nur auf die abhängige
  Projektion; vollständige Projektionsschlüssel verhindern verspätete Sprünge.
  Mutationskennungen und bestätigte Katalogstände schützen Fehler-Rollbacks bei
  schnellen gleichen Werten. Die normale Bibliothek behält ihre bestehende
  Dirty-/Retry-Semantik.
- Angenommene Varianten-Metadatenwrites werden bei Beenden ausdrücklich abgewartet.
  Sichtbare Bitmaps behalten ihre Speicherreservierung. Quellenbasen werden
  zwischen Miniaturen geteilt; Referenz-Revalidierung zeigt keinen leeren Frame.
- MCP-Arbeitsbereichs-/Werkzeug-ABA, fremdes Verwerfen eines späteren lokalen
  Entwurfs, verlorene Abschlussauskunft und unbegrenzte Snapshotretention wurden
  abgesichert. Verbindungsdateien werden begrenzt über geprüfte Dateideskriptoren
  gelesen; doppelte JSON-Schlüssel werden abgewiesen. Eine Quellenablehnung beim
  sichtbaren Übernehmen setzt den extern abfragbaren Endstatus auf `failed` und
  lässt Bildstand, Revision und Undo unverändert.
- Gleichnamige Bildstände erhalten Sekunden und Millisekunden in der Anzeige;
  die frühere Minutenanzeige konnte schnelle Sicherungen nicht unterscheiden.
- Ein unveränderter numerischer Fokus-/Formatierungsecho konnte eine leere
  Edittransaktion und irreführende Konfliktmeldung auslösen. Identische Werte und
  höchstens vier ULP Rundungsrauschen werden vor Beginn der Undo-Gruppe verworfen;
  sichtbare Änderungen bleiben wirksam.
- Ein nicht zugelassener Buildworker konnte bei verweigerter Prozessprüfung
  unbegrenzt auf sein Startsignal warten, während ein Test seine Fixture entfernte.
  Prozessprüfung erfolgt jetzt vor dem Fork; das Startgate ist begrenzt und
  unsicher aktive Fixtures werden konservativ erhalten. Der nach Identitätsprüfung
  beendete alte Testworker und die Negativfälle sind dokumentiert/geprüft.

## Prüfungen und Grenzen

Der vollständige SDK-entdeckte Testkatalog wurde mit dem vorhandenen
`scripts/test-isolated.py` in frischen Prozessen geprüft: **2145/2145 Einträge**
über **231 Prüfgruppen**, **2103 ausgeführte Fälle bestanden**, **42 ausdrücklich
optionale Fälle übersprungen**, keine fehlgeschlagene Gruppe.
[Maschinenlesbare Zusammenfassung](isolated-test-summary.json).
Die optionalen Modell-/Privatbildtests werden nicht stillschweigend vorausgesetzt.
Nach den letzten Änderungen bestehen zusätzlich 32 Fälle in drei betroffenen
Suites für Zeitstempel und native Testfixtures sowie 38 Fälle in vier Suites für
MCP und die fehlgeschlagene sichtbare Übernahme. Der saubere App-Build enthält
auch diese letzten Produktkorrekturen.

Die [native Abnahme](native-acceptance.json) prüft #222 in beiden Fenstergrößen
mit strukturiertem Hoch-/Querformat, asymmetrischem Crop, gekoppeltem/freiem Pan,
echten Klicks ins sichtbare Belichtungsfeld und sauberem Speicherstatus. #223
durchläuft zwölf fatale Checkpoints von Name/Vorschau bis Restore, Undo/Redo,
Rename, Delete und Abschlussdrain. Beide Kindprozessprotokolle verlangen echte
Endbelege und den SDK-Erfolg. Der deaktivierte #221-Kandidatenpfad besteht seine
separate native Fake-Abnahme in beiden Größen; das hebt das Modell-No-Go nicht auf.

Visuell geprüfte Aufnahmen ausschließlich synthetischer Bilder:

- [Fotovergleich 1000 × 660](photo-comparison-1000.png), [1440 × 900](photo-comparison-1440.png)
- [Benannter Bildstand mit 120 Zeichen](named-variant-1000.png), [gesperrte reine Vorschau](variant-preview-1000.png)

Ein vorausgehender gemeinsamer Parallelstresslauf meldete 42 Issues bei 2142 Tests.
Die dabei nachgewiesene normale Katalog-Retry-Regression wurde behoben. Die übrigen
Lade-/AppKit-/Zwischenframefälle bestehen in den frischen Prozessen. Die bestehenden
Timing- und Fokusassertionen wurden dafür nicht abgeschwächt. Prozessglobales
AppKit-Tracking ist keine unabhängig parallelisierbare Testressource; der
gewöhnliche parallele Testlauf bleibt verfügbar. Anfängliche inkrementelle
Testcompiles scheiterten an einer inzwischen korrigierten SwiftUI-Makrodeklaration
beziehungsweise gleichzeitig geänderten Quellen; der endgültige Quellstand wurde
eingefroren und erfolgreich geprüft.

Zusätzlich bestehen fünf Python-Regressionsfälle für die konservative Gateauswertung
und 13 isolierte Buildskript-Prüfungen einschließlich verweigerter Prozessprüfung,
Startgate-Abbruch und MCP-Paketierung. Der [RAW-Cachelauf](../issue-222/raw-cache-validation.json)
weist bei A als Referenz und B → C → B genau drei Decodes nach. Alle Originalhashes
blieben identisch. Seine Latenzen und 533 MiB Prozess-Peak sind lokale Messwerte;
sie belegen keinen allgemeinen Geschwindigkeitsgewinn. Keine privaten Bilder,
abgeleiteten privaten Fotos oder Modellgewichte werden veröffentlicht.

Der vollständige lokale App-Build war erforderlich, weil Laufzeit-, Paketierungs-
und Buildcode geändert wurden. Vor dem Build waren `.build/`, `.build-app/` und
`dist/Glowroom.app` nach bestätigter Prozessruhe entfernt. Der aktive Testpfad
`.build-224-tests/` blieb unabhängig erhalten. `GLOWROOM_BUILD_JOBS=3
./scripts/build-app.sh` lief mit Netzwerkfreigabe für die festgelegten Pakete sauber
durch. Das Bundle enthält `GlowroomMCP`; `codesign --verify --deep --strict` ist
erfolgreich. `Package.resolved` blieb unverändert.
