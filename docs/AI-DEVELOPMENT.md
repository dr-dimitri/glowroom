# AI Entwickeln

**AI Entwickeln** ist ein eigener Arbeitsbereich neben **Bibliothek** und
**Entwickeln**. Er verwendet dasselbe ausgewählte Foto, dieselbe Vorschau und
dieselben gespeicherten Bearbeitungen. Der Einstieg in der Kopfzeile und unter
**Darstellung** funktioniert auch ohne Foto, damit Modelle vorher eingerichtet
werden können. Im Bildfokus bleibt der Arbeitsbereich erreichbar.

Die rechte Seite bündelt Qwen-Entwicklung, **Bildtexte und Tags vorschlagen**,
semantische Bildsuche samt Suchmodell, automatische Masken und KI-Reparatur.
Bestehende Masken-/Suchzugänge bleiben als direkte Bedienwege erhalten.
Manuelle Bildinformationen bleiben in Bibliothek und Entwickeln;
KI-Metadatenvorschläge werden im neuen Arbeitsbereich bearbeitet. Die Funktionen
verwenden ihre jeweiligen Modelle; Qwen ersetzt weder Masken-/Suchmodelle noch
den lokalen Systemanbieter für Bildtexte.

## Qwen einrichten und entfernen

**Modelle → LLM-Modelle verwalten** zeigt Qwen3.5-4B in der lokalen
4-Bit-Variante `mlx-community/Qwen3.5-4B-4bit`. Der erste Katalog enthält genau
dieses Modell; weitere Modelle benötigen einen eigenen geprüften Deskriptor und
Laufzeitadapter. Revision und Dateiprüfsummen stehen im `LLMModelDescriptor`.

- **Download:** 3.061.129.077 Byte, etwa 3,06 GB. Der Dialog zeigt zusätzlich die
  logische Größe der vorhandenen Modelldateien im privaten Verzeichnis und den für die
  Einrichtung erforderlichen freien Speicher.
- **Herunterladen** benötigt Internetzugang zu Hugging Face. Höchstens zwei
  Dateien werden gleichzeitig auf Platte übertragen; große Gewichte werden
  gestreamt und nicht vollständig in den Arbeitsspeicher geladen.
- Downloadfortschritt, Abbruch und Fehler sind sichtbar. Erst nach Prüfung aller
  Größen und SHA-256-Digests wird eine vollständige Installation atomar
  veröffentlicht. Abbruch oder Netzfehler aktivieren kein Teilmodell. Temporäre
  Dateien brauchen zusätzlichen Speicher; die Kapazität wird vorab geprüft.
- **Modell löschen** entfernt die von Glowroom verwaltete Installation. Ein
  aktiver Modellaufruf hält eine Lease und verhindert die Löschung. Fotos und
  bereits übernommene Bearbeitungen benötigen das Modell anschließend nicht.

Die Gewichte liegen unter `~/Library/Application Support/Glowroom/Models/LLM/`.
Sie gehören weder zum Git-Repository noch zum App-Bundle. Export- und Sicherungsziele schützen den Modellordner auch bei einem abweichenden Katalogverzeichnis. Apple Silicon und
Metal sind Voraussetzung für Qwen. Die native Swift-Laufzeit und ihre separaten
App-Ressourcen stehen unter [Qwen-Laufzeit](AI-QWEN-RUNTIME.md). Nach dem
Download arbeitet die Inferenz offline; Fotos werden nicht hochgeladen.

## Bildwirkung steuern

Ein Auftrag in eigenen Worten und die Regler **Helligkeit**, **Kontrast**,
**Wärme** und **Farbkraft** beschreiben die gewünschte Richtung. Ihre Mitte
bedeutet keine zusätzliche Vorgabe. **Stärke** mischt geprüfte Zielwerte mit den
aktuellen Einstellungen; 0 erhält den aktuellen Stand, 100 % übernimmt den
vollständigen Modellvorschlag. Die anfängliche Stärke beträgt 50 %.
Der Abschnitt heißt ausdrücklich **Auftrag für den nächsten Vorschlag**:
Reglerbewegungen allein verändern die laufende Bildvorschau nicht. Um einen
geänderten Auftrag anzuwenden, erneut **Vorschlag erstellen** und anschließend
**Übernehmen** wählen. Direkte Bildkorrekturen erfolgen unter **Entwickeln**.

**Vorschlag erstellen** übergibt die aktuelle entwickelte Vorschau und die
unterstützten aktuellen Reglerwerte an das Modell. Die Vorbereitung verwendet
die vorhandenen begrenzten Decoder- und Vorschau-Caches mit maximal
1024 Pixeln langer Kante. Wiederverwendung setzt dieselbe native Dateiversion
voraus; ein extern ersetztes Foto darf auch bei erhaltener Größe und Änderungszeit
keine alten Pixel an das Modell liefern. Fehlt eine so geprüfte Basis im Cache,
wird sie beim ausdrücklichen Auftrag geladen. Eine Reglerbewegung startet weder
Inferenz noch RAW-Decodierung.

Das Ergebnis zeigt eine Erläuterung sowie die tatsächlich zur Übernahme
vorgesehenen Werte (vorher → nachher, einschließlich Stärke). Unterstützt sind
Belichtung, Kontrast, Lichter, Tiefen, Weiß, Schwarz, Dynamik, Sättigung,
Temperatur und Tönung. Alle anderen Einstellungen bleiben erhalten. Qwen
erzeugt hier keine Bildpixel, Retuschen oder lokalen Masken.

**Übernehmen** verwendet die normale Speicherung und erzeugt einen gemeinsamen
Rückgängig-Schritt. Die Vorschau wird mit den übernommenen Werten neu gerendert;
dieselben Werte stehen anschließend in den normalen Reglern unter **Entwickeln**.
Die Richtungsregler im AI-Bereich beschreiben weiterhin den Auftrag und werden
durch die Übernahme nicht zurückgesetzt. Enthält der Vorschlag keine wirksame
Wertänderung (auch bei Stärke 0), bleibt **Übernehmen** deaktiviert und die
Statusmeldung erklärt, dass keine Änderung vorgeschlagen wird. Ein solcher
Vorschlag erzeugt weder eine Bearbeitung noch eine Erfolgsmeldung.

**Verwerfen** verändert kein Foto. Ein Ergebnis nach
Foto-/Quellenwechsel, zwischenzeitlicher Bearbeitung (auch nach Undo), neuem
Auftrag oder Abbruch darf nicht übernommen werden. Vor der Übernahme wird die
native Quellenidentität erneut im Hintergrund geprüft, anschließend nochmals
der Bearbeitungskontext. Der Abschluss einer Hintergrundspeicherung derselben
bereits angenommenen Einstellungen entwertet einen Vorschlag nicht. Quelle,
Einstellungen, Bearbeitungs- und Auswahlgeneration sowie Store-Epoch müssen
unverändert bleiben; die strikten Persistenzprüfungen der Datenbank gelten
weiterhin. Auch während der kurzen exklusiven Phasen eines automatischen
Backups bleibt der Vorschlag erhalten. Übernehmen ist in dieser Zeit gesperrt;
beginnt die Sperre während der Quellenprüfung, bleibt der Vorschlag für eine
erneute Übernahme verfügbar. Abgebrochene native Arbeit behält ihren Inferenzplatz
bis zum tatsächlichen Ende; vorher wird keine neue Anfrage gestartet.

## Qualität und Ressourcen

Die [frühere Evaluation](AI-QWEN35-EVALUATION.md) war keine Freigabe für
unbeaufsichtigte automatische Korrektur. Der neue Bereich ist eine ausdrücklich
ausgelöste Vorschlagsfunktion mit Übernahmeprüfung. Fachliche Fehleinschätzungen
und unveränderte Vorschläge sind möglich. Ein technischer Produkttest belegt
keine allgemein zuverlässige fotografische Automatik.

Der Modelloutput ist durch eine JSON-Grammatik begrenzt und wird anschließend
erneut auf bekannte Felder, Zahlen, Wertebereiche und Größe geprüft. Ungültige
oder unvollständige Antworten werden vollständig abgelehnt; es gibt keine
automatische Antwortreparatur. Das Modell hat keine Schreib-, Shell- oder
Werkzeugrechte.

Die lokale Modellarbeit teilt eine einzelne `AIResourceBudget`-Lease mit anderen
KI-Diensten. Die deklarierte Reservierung von 5 GiB ist eine Zulassung, keine
harte Speichergrenze. Es werden keine Leistungsversprechen aus den historischen
Python-Messwerten abgeleitet. Dateiübertragungen und unabhängige Vorbereitung
laufen begrenzt parallel; Veröffentlichung, Übernahme und Löschung bleiben
wegen ihrer Abhängigkeiten geordnet.

## Prüfungen

Standardtests verwenden temporäre Stores, synthetische Bilder und kontrollierte
Modellantworten. Sie laden keine Gewichte herunter und führen keine echte
Inferenz aus. Geprüft werden Antwortgrenzen, Stärke, Erhalt übriger Einstellungen,
explizite Übernahme/Undo/Redo, persistierte Werte, veraltete Antworten, Abbruch,
Installationsprüfsummen, atomare Veröffentlichung und Schutz aktiver Modelle.
Zusätzliche Regressionen prüfen unveränderte Vorschläge und den Speicherabschluss
während Inferenz, Vorschlagsprüfung und Übernahme. Ein gemounteter nativer Test
bedient die tatsächlichen Schaltflächen mit kontrollierter Modellantwort,
echter Quellenprüfung und synthetischer PNG-Datei. Er prüft Reglerwerte,
geänderte Vorschaupixel, Undo/Redo und Speicherung ohne echte Modellinferenz.

Ein optionaler nativer Produkttest mit einem bereits vorhandenen lokalen
Qwen-Snapshot lässt sich ausdrücklich aktivieren:

```sh
GLOWROOM_QWEN_MODEL_PATH=/absoluter/pfad/zum/qwen-snapshot \
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-ai-tests \
./scripts/test.sh --jobs 4 --filter QwenNativeModelTests
```

Er verwendet ein synthetisches Bild und die tatsächliche Swift-/Metal-Inferenz
einschließlich JSON-Grammatik und Antwortvalidierung. Die lokalen Testfotos
sind dafür nicht erforderlich. Ein sauberer vollständiger App-Build bleibt für
Änderungen an dieser Produktfunktion gemäß `AGENTS.md` erforderlich.

## Integrationsprüfung am 23. Oktober 2026

Der vollständige Standardlauf bestand mit **1512 Tests in 202 Suites**. Zuvor
bestanden die zuletzt betroffenen 54 Regressionstests separat. Die echte native
Qwen-Inferenz wurde zusätzlich mit vorhandenen lokalen Gewichten ausgeführt;
Einzelheiten und Grenzen stehen im [Laufzeitnachweis](AI-QWEN-RUNTIME.md).
Die native Oberfläche wurde bei 1000 × 660 und 1440 × 900 geprüft und visuell
kontrolliert. Dafür kamen synthetische Bilder zum Einsatz, keine privaten Fotos.

Das abschließende unabhängige Review umfasste UI/Workspace, Metadatenentwürfe,
Installations- und Löschpfade, Quellenbindung, Antwortvertrag, Abbruch,
Ressourcenfreigabe und Paketierung. Gefundene Lücken bei wiedergeöffneten
Metadatenentwürfen, dem Schutz des gemeinsamen Modellverzeichnisses und der
Zuordnung von Pixeln zur nativen Dateiversion wurden behoben und nachgeprüft;
es blieben keine offenen Befunde. Beim vollständigen Lauf gefundene bestehende
Bereitschaftsrennen in Tests wurden ebenfalls behoben, ohne fachliche Assertions
oder Produktionsfristen zu lockern; siehe [Testsynchronisierung](TEST-SCHEDULING.md).

Die Tests laufen intern parallel. Der abschließende Release-Build folgt der
Vollsuite geordnet, damit deren native UI-/Abbruchproben nicht mit der vollständigen
C++-/Swift-Kompilierung um CPU und Speicher konkurrieren. Die Implementation und
Reviews wurden nach getrennten Dateiverantwortungen parallel bearbeitet.

Der abschließende saubere Release-Build mit `./scripts/build-app.sh` war
erfolgreich (SwiftPM-Kompilierung 322,23 Sekunden). Zuvor wurden laufende Prozesse
geprüft und die generierten Buildverzeichnisse sowie das alte App-Bundle entfernt.
`codesign --verify --strict` und die SHA-256-Prüfung der gebündelten
Metal-Bibliothek bestanden. Das Executable bindet Systembibliotheken, keine
lokale Python- oder Testing-Laufzeit. Ein vorläufiger sauberer Build wurde wegen
der zwischenzeitlich gefundenen Testkorrekturen bewusst abgebrochen; sein
Teilstand wurde vor diesem erfolgreichen Abschluss vollständig entfernt.

## Auftragsregler und Übernahmeprüfung am 23. Oktober 2026

Die Auftragsregler blieben nach der Übernahme absichtlich unverändert, wirkten
aber wie direkte Bildregler. Die Oberfläche benennt ihren Zweck jetzt ausdrücklich
und verweist auch in der Erfolgsmeldung auf die tatsächlichen Werte unter
**Entwickeln**. Die gemeldete Kombination Weiß 0 → 5, Dynamik 0 → 10 und
Temperatur 6500 → 6650 bei 50 % Stärke wird im nativen Test genau übernommen
und verändert die gerenderten Pixel. Diese dezenten Werte sind kein Nachweis
eines allgemeinen Rendererfehlers. Die irrtümlich umgekehrte Temperaturrichtung
im Modellprompt wurde an Renderer und vorhandene Farbtests angepasst: höhere
Werte wärmen, niedrigere kühlen das Bild.

Zusätzlich gefundene Übernahmefehler wurden behoben: unveränderte Vorschläge
können nicht mehr als erfolgreiche Bearbeitung angenommen werden. Ein reiner
Persistenzabschluss und die kurzen automatischen Backup-Sperren verwerfen
keinen weiterhin gültigen Vorschlag. Die Annahme bleibt während der Sperren
geschlossen; spätere Bild-/Quellenwechsel, Bearbeitungen, Undo und Abbruch
entwerten den Vorschlag weiterhin.

Die gezielte Prüfung bestand mit **28 Tests in 7 Suites**. Sie umfasst die
gemounteten nativen Übernahme-Buttons, normale Regler einschließlich Temperatur,
geänderte Vorschaupixel, Undo/Redo, echte Quellenprüfung, persistierte Werte und
erneutes Öffnen sowie kontrollierte Speicher- und Wartungsabläufe. Die Tests
nutzen synthetische PNG-Dateien und kontrollierte Modellantworten; sie benötigen
weder private Testbilder noch neue Modellinferenz.

Der erste vollständige Lauf scheiterte an einer fehlenden Testvorbedingung:
direktes Redo fiel in die reale automatische Backup-Sperre. Die native Regression
drainiert jetzt das Tagesbackup und prüft die unmittelbare Undo-/Redo-Annahme,
bevor sie die gerenderte Vorschau abwartet. Keine Frist wurde erhöht. Der
anschließende vollständige Paralleltest bestand mit **1516 Tests in 203 Suites**
in 44,541 Sekunden. Logs: `/tmp/glowroom-ai-apply-integration.log`,
`/tmp/glowroom-ai-apply-full.log` (Fehllauf) und
`/tmp/glowroom-ai-apply-full-verified.log` (erfolgreicher Vollvergleich).

Das unabhängige Diffreview umfasste Controller-/Persistenzgrenzen, UI,
Quellenbindung, Prompt, Tests und Dokumentation. Der dabei gefundene
Backup-Lebenszyklusfehler wurde korrigiert und durch beide exklusiven
Wartungsphasen nachgeprüft; es bleiben keine offenen Befunde. Implementierung
und Review liefen mit getrennten Dateiverantwortungen parallel. Vollsuite und
sauberer App-Build bleiben wegen CPU-/Speicherbedarf und nativer UI-Prüfungen
geordnet; es werden keine neuen Leistungsgewinne behauptet.

Ein sauberer vollständiger App-Build war erforderlich, weil Controller,
Oberfläche und Modellprompt das Laufzeitverhalten ändern. Nach Ende aller
Tests und dem durch den Nutzer vorgenommenen Beenden der laufenden App wurden
die generierten `.build`-Produkte, Compiler-/Icon-/Shader-Caches und das alte
`dist/Glowroom.app` entfernt. `GLOWROOM_BUILD_PATH` war nicht gesetzt,
`.build-app` war nicht vorhanden; Abhängigkeitsquellen und Lockdateien blieben
erhalten. **`GLOWROOM_BUILD_JOBS=4 ./scripts/build-app.sh` bestand als sauberer
vollständiger Release-Build** (SwiftPM-Kompilierung 297,41 Sekunden).
Info.plist-Validierung, ad-hoc Signierung und strikte Signaturprüfung bestanden.
Log: `/tmp/glowroom-ai-apply-clean-build.log`. Die abschließende Dokumentation
der Ergebnisse beeinflusst den Build nicht.
