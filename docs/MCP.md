# Lokaler MCP-Zugang

Glowroom kann einen externen MCP-Client mit der bereits geöffneten Bibliothek verbinden. **Ansicht → Lokaler MCP-Zugang …** zeigt die betroffene Bibliothek und die verfügbaren Daten. **Zugang für diese Sitzung aktivieren** schaltet den Zugang ausdrücklich ein. Der Standard ist aus; ein App-Neustart, das Schließen der Bibliothek oder **Zugang beenden** widerruft ihn. Die Freigabe wird nicht als Voreinstellung gespeichert und gilt nicht automatisch für eine andere Bibliothek.

Die getrennte Option **Auch Bildvorschauen freigeben** erlaubt die Übertragung gerenderter PNG-Vorschauen. Sie lässt sich bei aktivem Zugang einzeln widerrufen. Ein externer Client kann empfangene Daten und Bilder an seinen eigenen Anbieter senden; Glowroom legt weder dessen Verarbeitung noch dessen Aufbewahrung fest.

## Adapter einrichten

`./scripts/build-app.sh` baut App und `GlowroomMCP` und legt den Adapter unter `dist/Glowroom.app/Contents/MacOS/GlowroomMCP` ab. Alternativ baut `swift build --product GlowroomMCP` nur den Adapter. Er besitzt keine eigene MLX-Abhängigkeit und öffnet keinen zweiten Katalog.

Im Freigabedialog **Verbindungspfad kopieren** wählen. Den Adapter als stdio-Server im gewünschten Client einrichten, beispielsweise:

```json
{
  "mcpServers": {
    "glowroom": {
      "command": "/absoluter/Pfad/Glowroom.app/Contents/MacOS/GlowroomMCP",
      "args": ["--connection", "/private/tmp/glowroom-mcp-UID-SITZUNG/connection.json"]
    }
  }
}
```

Den tatsächlich kopierten Verbindungspfad einsetzen. Die Datei enthält die kurzlebige Sitzungskennung und ein zufälliges Zugangstoken. Datei und Socket sind nur für den angemeldeten Benutzer zugänglich (`0600`), ihr eigens angelegtes Verzeichnis hat `0700`. Beide Seiten prüfen die Benutzerkennung des Unix-Socket-Peers. Der Adapter akzeptiert ausschließlich eine private reguläre Verbindungsdatei desselben Benutzers. Die App entfernt den Endpunkt beim Widerruf; bereits verbundene Zugriffe dürfen keine spätere Antwort oder Vorschlagsübernahme veröffentlichen.

Der bewusst festgelegte Protokollstand ist **MCP 2025-06-18**. Die kleine, auf Tools begrenzte Implementierung verwendet **kein externes MCP-SDK**. [Stdio-Transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports), [Versionsaushandlung](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle) und [Tool-Vertrag](https://modelcontextprotocol.io/specification/2025-06-18/server/tools) sind die Protokollgrundlage. Auch bei einer neueren vom Client angebotenen Version gibt der Server seinen unterstützten Stand zurück; der Client entscheidet, ob er fortfahren kann. Nachrichten sind mit Zeilenumbruch getrennte JSON-RPC-2.0-Objekte; stdout enthält ausschließlich Protokollantworten. Benutzungsfehler beim Start gehen an stderr. `initialize`, `ping`, `tools/list` und `tools/call` werden unterstützt; Ressourcen, Prompts, HTTP und frei ausführbare Befehle werden nicht angeboten.

## Tools und Ablauf

Alle Eingabeschemas sind geschlossen (`additionalProperties: false`), einschließlich des verschachtelten Reglerobjekts. Die Reglerdefinitionen und Wertebereiche kommen unmittelbar aus dem typisierten `EditParameter`-Katalog aus #213.

| Tool | Eingabe und Ergebnis |
| --- | --- |
| `session_inspect` | Aktive Sitzung, Bibliotheksname, Fotozahl, undurchsichtige aktive Foto-ID, Arbeitsbereich und Bildfreigabe |
| `photos_query` | `offset` und `limit` (höchstens 100); Foto-ID, Dateiname, Sterne und Favorit; `next_offset` für die nächste Seite |
| `controls_list` | Verfügbare globale numerische Regler mit Minimum und Maximum |
| `snapshot_get` | `photo_id`; unveränderliche undurchsichtige `snapshot_id`, aktuelle numerische Werte und Quellenart |
| `preview_render` | `photo_id`, `snapshot_id`, optional `maximum_size` (1–2048) und `request_id`; PNG des angenommenen Stands oder des noch prüfbaren Vorschlags |
| `proposal_create` | Aktives Entwickeln-Foto, erwartete `snapshot_id`, eindeutige `request_id` und `values` mit absoluten Reglerzielwerten; bereitet eine sichtbare Korrektur vor |
| `proposal_get` | `request_id`; Auftragszustand ohne erneute Vorbereitung oder Schreibaktion |
| `proposal_discard` | `request_id`; verwirft ausschließlich noch nicht angenommene Vorschläge |

Abfragen wechseln weder Auswahl noch Arbeitsbereich und verändern keine Bearbeitung. Keine Originalpfade oder Kamera-/GPS-Quellmetadaten werden ausgegeben. Bildvorschauen werden aus dem regulären Renderer mit ihrem Farbprofil erzeugt, ohne Quellmetadaten anzuhängen; ImageIO kann im PNG reine Ausgabeangaben zu Farbraum und Pixelabmessungen als EXIF-Felder erzeugen. Die Vorschau wird nicht in eine vom Client angegebene Datei geschrieben.

Für einen Vorschlag muss das Foto bereits rechts beziehungsweise allein im Arbeitsbereich **Entwickeln** aktiv sein, die endgültige Vorschau vorliegen und kein anderes Werkzeug oder noch aktives Eingabefeld den Edit beanspruchen. Der Client erfasst zunächst den Snapshot und sendet dann unterstützte globale numerische Zielwerte. Der Vorschlag erscheint in **KI-Korrektur**. Dort lassen sich **Aktueller Stand** und **Vorschlag** auf derselben Bildfläche betrachten. Erst **Übernehmen** schreibt über den bestehenden Editor; es entsteht genau ein Undo-Schritt. Ein Qwen-Modell ist für einen numerischen MCP-Vorschlag nicht erforderlich.

Masken, Temperatur/Tönung, freie Geometrie-, Datei- oder Shelloperationen, Modellinstallation, Bildlöschung, Serienänderungen und unbeaufsichtigte Übernahme gehören nicht zur Schnittstelle. Abfragen anderer Fotos sind auf dieselbe ausdrücklich freigegebene Bibliothek beschränkt; ein Vorschlag für ein inaktives Foto liefert `inactive_target`.

## Konflikte, Grenzen und Beendigung

Snapshots binden Foto, native Quellenrevision, Einstellungen, persistierte Revision und App-/Auswahl-/Arbeitsbereichtokens. Auch A → B → A, Entwickeln → Bibliothek → Entwickeln, ein kurz aktiviertes anderes Werkzeug, manuelle Änderung/Undo oder ein Quellenersatz machen einen alten Snapshot unbrauchbar. Die Arbeitsbereichsepoche wird synchron an den Publisher-Grenzen erneuert; gleich gebliebene Endwerte erlauben keine verspätete Veröffentlichung. Vor der Vorschlagsvorbereitung und vor der sichtbaren Übernahme wird die native Quelle erneut geprüft. Es gibt keine stille Anpassung an einen neueren Stand.

Strukturierte Tool-Fehler enthalten `code` und `message`, unter anderem `access_denied`, `image_access_denied`, `invalid_arguments`, `unknown_photo`, `inactive_target`, `conflict`, `busy`, `request_conflict`, `outcome_unknown` und `limit`. Toolfehler verwenden den MCP-Status `isError: true`; Protokollfehler bleiben JSON-RPC-Fehler. Ein fehlender oder beendeter Endpunkt öffnet keinen Katalog.

- Höchstens 1 MiB eingehende JSON-Nachricht und 16 MiB ausgehende Antwort. Ein PNG, das einschließlich Base64 die Antwortgrenze überschreiten könnte, wird mit einem Größenfehler abgewiesen; eine kleinere Vorschau kann ausdrücklich neu angefordert werden.
- Höchstens ein aktiver Vorschlag und ein aktiver IPC-/Vorschauauftrag pro Freigabesitzung. Modellarbeit wird für diesen numerischen Adapter nicht gestartet. Decodierung und Rendering verwenden `ImagePreviewPipeline` und `AdjustedPreviewPipeline` mit deren vorhandenen Budgets, Caches und Prioritäten.
- Sitzungsgebundene Begrenzung auf 4.096 ausgegebene Fotoidentitäten, 128 erfasste Snapshots und 256 zurückbehaltene alte Auftragskennungen. Identische Snapshots werden zusammengefasst; zusätzlich begrenzt eine konservative 64-MiB-Kostenschätzung die von Snapshots gehaltenen Einstellungen einschließlich Masken-/Retuscherastern und persistierter Ausgangsstände. Bei Erreichen einer Grenze die Freigabe ausdrücklich beenden und neu starten; alte Kennungen bleiben ungültig.
- Ein alter `request_id` wird niemals blind erneut ausgeführt. Bei Verbindungsverlust nach Versand ist das Ergebnis zunächst unbekannt: mit derselben Kennung `proposal_get` abfragen. `ready`, `accepted`, `discarded` und `failed` unterscheiden den noch prüfbaren Vorschlag von seinem Abschluss. Ein App-Neustart oder Sitzungswiderruf beendet die kurzlebige Abfragemöglichkeit; danach den sichtbaren angenommenen Stand erneut prüfen.
- Abbruch oder Widerruf kann Vorschläge verwerfen. Bereits angenommene Editor-Speicheraufträge laufen über die normalen geordneten Persistenzpfade zu Ende. Nicht unterbrechbare Decoder-/Renderarbeit gibt ihre vorhandenen Ressourcenplätze erst bei tatsächlicher Rückkehr frei.

Zum Beenden im Freigabedialog **Zugang beenden** wählen und den Client-Server bei Bedarf stoppen. Das Beenden des Adapters allein hebt die in Glowroom sichtbare Freigabe nicht automatisch auf; es bestätigt und übernimmt auch keinen Vorschlag.

## Prüfung

Die normalen Tests benötigen kein Modell, Netz und keine privaten Testbilder. `MCPContractTests` prüft die geschlossenen Schemas, ungültige Zahlen/Regler, private Dateirechte, echte Unix-IPC-Kommunikation und Widerruf. Ein Cross-Process-Test startet das reale `GlowroomMCP`-Executable als MCP-Testclient-Gegenstelle, prüft `initialize`, Toolauflistung und Abfrage vor/nach Widerruf sowie reine Protokollausgabe. `LocalMCPControllerTests` verwendet synthetische PNGs und einen isolierten realen Editorstore für Standard-aus, Katalogwechsel, Foto-/Regler-/Snapshotabfragen, Bildfreigabe und PNG-Farbprofil ohne Kamera-/GPS-Quellmetadaten, inaktive Ziele, Auswahl-/Arbeitsbereich-/Werkzeug-ABA, Deduplizierung und angenommene oder verworfene Vorschläge. Der spätere lokale Qwen-Entwurf bleibt bei Widerruf eines alten externen Vorschlags erhalten. Die UI-Tests des `AIDevelopmentModel` prüfen einen externen Vorschlag über den nativen sichtbaren Übernehmen-Button, genau einen Undo-Schritt und den Schutz bei A → B → A.

Gezielter Lauf im üblichen Test-Buildverzeichnis:

```sh
./scripts/test.sh --filter MCPContractTests
./scripts/test.sh --filter LocalMCPControllerTests
./scripts/test.sh --filter AIDevelopmentModelTests/external
```

Ein optionaler Smoke mit einem eigenen MCP-Client verwendet denselben Freigabedialog und Protokollstand. Clientname, Clientversion und tatsächlich verwendete Datenfreigabe im Prüfbericht festhalten. Der Standardtest verwendet den kleinen eingebauten JSON-RPC-Testclient, keinen Drittanbieter und keinen externen Dienst.
