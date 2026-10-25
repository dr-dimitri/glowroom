# Parallele Scheduling-Tests

## Vollständige native Abnahme

Für die vollständige native Workspace-Abnahme steht `scripts/test-isolated.py`
bereit. Der Runner entdeckt den gesamten SDK-Testkatalog, prüft dessen vollständige
und überschneidungsfreie Aufteilung und führt App-Suites in frischen Prozessen
aus. Er verlangt erfolgreichen Exit, den tatsächlichen Swift-Testing-Abschluss
und passende xUnit-Einträge; ein früher Exit 0 ist kein bestandener Test. Für einen
bereits gebauten Teststand:

```sh
GLOWROOM_TEST_BUILD_PATH=.build-224-tests python3 scripts/test-isolated.py \
  --skip-build --report-directory /private/tmp/glowroom-isolated-new-run
```

Der Ausgabeordner muss neu sein. Der gewöhnliche parallele Testlauf bleibt
unverändert. Die zusätzliche Isolation ist bei AppKit-Fokus, Popuptracking und
Fensteranimationen sinnvoll, weil diese Ressourcen pro Prozess geteilt sind.
Der [Abschluss aus #224](issue-224/README.md) dokumentiert den gesamten grünen
Katalog, getrennte optionale Modellfälle sowie den vorausgehenden Parallelstress.

Die neuen nativen Vergleichs-/Variantenprüfungen treiben den ganzen asynchronen
Ablauf über einen begrenzten CFRunLoop-perform-Block weiter. So kann ein Ende der
AppKit-Tracking-Schleife nicht den äußeren Testprozess vorzeitig erfolgreich
beenden. Kindprozesse brauchen zusätzlich einen sitzungsgebundenen Endbeleg nach
allen fatalen UI-Assertions und geordneten Checkpoints. Echte Feldklicks prüfen
ihren tatsächlichen nativen Texteditor als FirstResponder; reine SwiftUI-Hitproxy-
Identität ersetzt diesen Funktionsnachweis nicht.

## Suspendierende Scheduling-Fakes

Die Testkorrektur zu [Issue #62](https://github.com/dr-dimitri/glowroom/issues/62) trennt das Warten auf eine kontrollierte Fake-Operation vom Blockieren eines Betriebssystemthreads. Ein synchrones `DispatchSemaphore.wait` innerhalb mehrerer `Task.detached`-Fakes kann die kooperativen Threads belegen, auf denen auch die Teststeuerung ihre Freigaben ausführen müsste. Ein längerer Timeout oder ein serieller Gesamtlauf behebt diese Abhängigkeit nicht.

Die Preview- und Adjusted-Preview-Tests verwenden dafür suspendierende Fakes. `TestAsyncLatch` ignoriert bewusst den Abbruch der simulierten nativen Arbeit, bis der Test `releaseAll()` ausführt. Die Pipelines halten ihren Workerplatz weiterhin bis zur tatsächlichen Rückkehr. Die vorhandenen synchronen Decoder und Renderer laufen unverändert innerhalb derselben begrenzten Hintergrundworker; optionale interne `asyncDecoder`-/`asyncRenderer`-Abhängigkeiten ermöglichen die suspendierenden Testdoubles. Kurze separate Tests prüfen auch die synchronen Pfade, Fehler, Priorität und Ausführung außerhalb des MainActor.

`TestStateSignal` speichert Ereignisse auch vor einer Warteanmeldung. Anmeldung, Ereignis, Timeout und Abbruch treffen ihre Entscheidung unter demselben kurzen Lock und entnehmen die jeweilige Fortsetzung genau einmal. Continuations werden außerhalb des Locks fortgesetzt. Eine vor der atomaren Watchdogentscheidung publizierte erfüllte Vorbedingung bleibt erfolgreich, auch wenn ihre Fortsetzung erst nach der nominalen Schlaffrist läuft; der Watchdog wird bereits bei dieser Entscheidung abgebrochen. Die kurze Schlaffrist ist ein diagnostischer Hangwächter und kein absolutes Anwendungslimit: Wird auch der Watchdog vom Executor verspätet ausgeführt, entscheidet der tatsächliche Gatezustand unter dem Lock. Der Watchdog schläft weiterhin unverändert drei beziehungsweise vier Sekunden. Cancellation entfernt wartende Testfortsetzungen. Ein Test-Timeout hält Bezeichnung, Zustand sowie dessen Publikationszeit und den Entscheidungszeitpunkt relativ zur Deadline atomar fest. Negative Zeitdifferenzen bezeichnen Zeitpunkte vor dem nominalen Schlafende; positive Entscheidungsdifferenzen machen verzögerte Executor-Wiederaufnahme sichtbar. So lassen sich tatsächlich unerfüllte Voraussetzungen von verspäteter Publikation unterscheiden, ohne bei einem Zustand wie `images == 0` einen Signalverlust zu behaupten. Der Timeout stoppt Folgeassertionen mit unerfüllter Vorbedingung. `TestAsyncLatch` wird dagegen ausdrücklich vom Test freigegeben, auch in dessen Cleanup. Gestartete Caller werden bei vorzeitigem Testende abgebrochen.

Der synthetische Compiler in `SemanticModelInstallerTests` bleibt als begründete Ausnahme synchron: Die serialisierte Suite hält höchstens einen solchen Fake, und die synchrone Ausführung erhält die vorhandene, nicht reentrante Actor-Reihenfolge des Installers. Sein Eintrittssignal suspendiert die Teststeuerung, statt einen zusätzlichen kooperativen Thread durch ein Semaphore-Warten zu belegen. Ein fehlgeschlagenes Eintrittsprädikat bricht den Caller ab, gibt den nativen Fake ausdrücklich frei und wartet vor dem Entfernen der Fixture auf dessen tatsächliche Rückkehr. Der bisherige Zehnsekunden-Hangwächter dieser Kontrolle bleibt unverändert.

Die semantischen Service-Tests warten auf Text-/Bild-/Installations-/Vorbereitungsereignisse ihrer Fakes. Die drei Regressionen für Katalogentfernung, Quellenänderung während der Bildinferenz und abgebrochenen Neuaufbau warten auf das direkte, abbruchfähige erste Bild-Eintrittsereignis. Ein noch nicht gestarteter Encoder (`images == 0`) unter paralleler Last ist keine verletzte fachliche Deadline. Eine äußere Testgrenze von einer Minute dient als Hangwächter statt einer Annahme über drei Sekunden Einreihungszeit. Die beiden korrigierten Quellenänderungs-/Neuaufbautests brechen bei fehlgeschlagener Voraussetzung den Caller ab und warten nach expliziter Fake-Freigabe auf seine Rückkehr. Eine zusätzliche Kontrolle hält den Start über 3100 ms hinter einer geschlossenen Barriere zurück, entfernt einen abgebrochenen Beobachter und belegt dann den tatsächlichen Eintritt sowie die weiterhin gehaltene Inferenzlease bis zur nativen Freigabe. Das gemeinsame Inferenzbudget liefert seine vorhandenen Zustandsereignisse. Für wenige interne Actor-Zustände ohne Ereignisschnittstelle liest `waitForTestState` den tatsächlichen Zustand; seine Frist ist ein Hangwächter, kein Beweis einer Einreihung. Die übrigen Drei-/Viersekundenfristen der Signal- und Zustandskontrollen bleiben bestehen. Der semantische Bibliotheks-Fixture wartet auf die kombinierten Modellpublisher und beschreibt fehlende Bereitschaft ausdrücklich als Test-Wartefehler, nicht als Providerfehler.

Ein-/Ausreihen, gemeinsame Waiter, ausgewählte gegenüber Hintergrundarbeit, schnelle Änderungen, Abbruch ohne vorzeitige Slot-/Leasefreigabe und Quellenwechsel bleiben Gegenstand der Tests. Produktionslimits und Deadlineprüfungen werden dafür nicht gelockert. Die normale parallele Swift-Testing-Ausführung bleibt eingeschaltet.

## Kontrollprobe und Prüfkommandos

Die kleine Kontrollprobe startet in einem eigenen Prozess die doppelte Anzahl aktiver CPUs als Fake-Worker, begrenzt auf mindestens acht und höchstens 64, und lässt die Steuerung nach 20 ms wieder aufwachen. Auf Rechnern mit mindestens 64 aktiven CPUs liegt die begrenzte Anzahl deshalb nicht über der CPU-Anzahl. Der erste Modus reproduziert den alten synchronen Fünfsekunden-Semaphore-Fake, der zweite verwendet denselben suspendierenden Latch wie die Tests. Beide melden tatsächlich beobachtete Controller-Wartezeit, gestartete Worker und Fake-Timeouts als JSON. Sie messen keine Bildoperation und erlauben keine Aussage über die Laufzeit oder Threadzahl der Anwendung. Die Modi nacheinander ohne zusätzlichen Build oder Benchmark ausführen:

```sh
swiftc -parse-as-library -module-cache-path /tmp/glowroom-scheduling-modules \
  Tests/GlowroomTests/TestSchedulingGates.swift \
  tools/test-scheduling/cooperative-pool-probe.swift \
  -o /tmp/glowroom-cooperative-pool-probe
/tmp/glowroom-cooperative-pool-probe --blocking
/tmp/glowroom-cooperative-pool-probe --suspending
```

Die Regressionen und danach die vollständige parallele Suite verwenden denselben Test-Buildpfad nacheinander. Andere gleichzeitig laufende Builds benötigen getrennte Verzeichnisse und ein gemeinsames CPU-/Speicherbudget.

```sh
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-scheduling-tests ./scripts/test.sh --jobs 4 \
  --filter 'PreviewPipelineTests|SemanticSearchServiceTests|SemanticLibraryTests|TestSchedulingGatesTests'
GLOWROOM_TEST_BUILD_PATH=/tmp/glowroom-scheduling-tests ./scripts/test.sh --jobs 4
```

Die Gate-Tests prüfen früh eingetroffene Ereignisse, Abbruch vor/nach Anmeldung, Timeout-Cleanup und absichtlich bis zur Freigabe weiterlaufende native Fakes. Eine virtuelle Uhr, explizite Deadlinefreigabe und zurückgehaltene Fortsetzungen ordnen die Konkurrenz kontrolliert: Publikation vor verspäteter Zustellung, Timeout vor späterer Publikation, erfüllte Publikation vor einem verzögert ausgeführten Watchdog, unerfüllte verspätete Publikation und Abbruch als jeweiliger Gewinner. Die Tests prüfen dabei genau eine Zustellung, entfernte Waiter und abgeräumte Watchdogs; die übrigen Signalfristen bleiben unverändert.

Die synchronen Native-Cache-Fakes aus Issue #135 verwenden einen Dispatch-gestützten eigenen `SerialExecutor` je Caller, begrenzt auf drei Caller. Dadurch bleiben Task-Abbruch und die tatsächlich synchrone Rückkehr prüfbar, ohne kooperative Executor-Threads zu belegen. Ein testinterner `didJoinInFlight`-Callback belegt den Eintritt eines gemeinsamen Waiters. Der Fake wird ausdrücklich über eine `NSCondition` freigegeben und im Fehler-Cleanup bis zur Rückkehr abgeräumt. Die kontrollierte Verzögerung von 5100 ms überschreitet bewusst den früheren selbstständigen Fake-Abbruch nach fünf Sekunden; die Testkorrektur vergrößert keine Frist. Der Maskenstatus-Test aus Issue #136 wartet auf das tatsächliche Zustandsprädikat `!isPresented`; bloßes Warten auf Layout ist kein Schließnachweis.

Die beim Vollvergleich zusätzlich gefundenen Compiler-Fakes für Sky, Subject-Matting und lokale Reparatur verwenden optionale interne `asyncCompiler`-Abhängigkeiten und suspendierende Latches. Reguläre Core-ML-Compiler und ihre Produktionslimits bleiben unverändert. Tests halten Admission und Ressourcen bis zur tatsächlichen Rückkehr und räumen Task, temporäre Compilerergebnisse und Fixtures auch bei fehlgeschlagenen Voraussetzungen vollständig auf. Dieselbe Cache-Korrektur wie bei AutoTone gilt für die natürliche Bildbalance; beide nutzen den gemeinsamen `TestSynchronousWorker`.

Native Zoom-Popups teilen sich AppKit-Tracking und den Prozess-Runloop. Die vier Fokus-/Ausschnittwahl-Kombinationen laufen deshalb jeweils in einem eigenen nativen Testprozess; ihr Eltern-Test verlangt sowohl erfolgreichen Exit als auch einen eindeutigen Abschlussnachweis. Ein vorzeitiger Exit 0 wird als Fehler erkannt. Der Eltern-Test wartet asynchron, während die übrigen Suites normal parallel weiterlaufen. Innerhalb des Childs hält ein begrenzter verschachtelter Runloop die asynchrone SwiftUI-AX-Menüöffnung unter Kontrolle; Escape wird als natives Ereignis zugestellt, die montierten Workspace-/Canvas-Monitorpfade werden während tatsächlichen Menütrackings geprüft.

Vollständiger sauberer App-Build und finales Diffreview bleiben zusätzlich nach `AGENTS.md` erforderlich; konkrete Kontroll- und Testresultate stehen im jeweiligen Pull Request.

Auch gezielte Prüfungen mehrerer nativer Workspace-Suites verwenden getrennte Prozesse entsprechend `scripts/test-isolated.py`. Ein kombinierter Filter konnte bei der Seitenleistenprüfung vorhandene Zoomtests mit festen Zwischenframe-Fristen stören; die isolierten Zoomprüfungen bestanden. Die native Workspace-Geometrieprüfung wartete zusätzlich nur 80 ms nach Beginn einer 240-ms-Vergrößerung und verglich diesen Zwischenstand mit dem nach einem Panelwechsel beendeten Zoom. Sie wartet jetzt auf den tatsächlichen nativen Zielmaßstab, bevor sie die unverändert geforderte Bildgröße erfasst und vergleicht.

## Beim Performance-Vollvergleich gefundene Test-Rennen (#44)

Die JPEG-Controller-Tests verwenden gepufferte Ereignisse des Export-Fakes und der vorhandenen Modellpublisher statt einer Fünfsekunden-Pollingfrist. Im parallelen Vollvergleich konnte der MainActor erst nach dieser Frist fortgesetzt werden, obwohl die geprüfte Zustandsfolge korrekt war. Registrierung und erster Zählerstand des Fakes sind actor-atomar; zu viele Exportaufrufe bleiben ein Fehler. Abbruch entfernt die Beobachter. Das Cleanup bricht den Controller ab, schließt den Fake, gibt eine absichtlich suspendierte Exportfortsetzung genau einmal frei und weist verspätete neue Exporte zurück. Eine äußere Minutengrenze erkennt einen echten Test-Hang; sie verändert keine Produktionsdeadline.

Der semantische Bibliothekstest wartet beim Öffnen der Steuerelemente auf die tatsächlich angenommene Statusversion des Service-Fakes. `semanticScopeIsReady` wird bereits vor dessen asynchroner Statusantwort gesetzt und konnte deshalb die anschließende Zählerassertion nicht absichern. Der gepufferte Publisher liefert auch eine vor der Anmeldung abgeschlossene Antwort. Die bisherigen fachlichen Assertions und Produktionsabläufe bleiben erhalten.

Der native Schärfungs-Workspace-Fixture schließt das erste Speichern einschließlich Tagesbackup vor dem Mounten ab und wartet vor weiteren Eingaben auf `editor.canEdit` und den aktivierten nativen Regler. Ein bloß publizierter Radiuswert belegt diese Freigabe nicht: während einer automatischen Backup-Wartung wird der Inspector absichtlich deaktiviert und ignoriert Mausklicks. Undo/Redo werden weiterhin durch den tatsächlich fokussierten Regler und die montierte Tastaturschnittstelle geleitet. Direkt nach jedem Shortcut wird der Testfokus freigegeben, bevor asynchrone Enabled-Änderungen oder erzwungenes Snapshot-Layout AppKits Key-View-Suche auslösen. Das vermeidet die im nativen Stack beobachtete SwiftUI-Fokus-/Layout-Reentranz. Nach der Prüfung wird auch das abschließende Backup vor dem Entfernen der temporären Daten abgewartet. Native Fenstertests benötigen die normale macOS-Grafiksitzung; eine Sandbox ohne WindowServer-Zuordnung kann synthetischen Ereignissen kein Fenster zuordnen.

## Private Artefakt-Stages: Abschlussereignis statt Polling

Die drei Bereinigungstests für private Artefakt-Stages warten auf den vorhandenen `onCleanup`-Callback über einen gepufferten `AsyncStream`. Der frühere Fünfsekunden-Poll prüfte nach einer verzögerten Executor-Wiederaufnahme zuerst die Uhr und konnte dadurch ein bereits veröffentlichtes Ergebnis übergehen. Ein Callback vor der Warteanmeldung bleibt jetzt erhalten; ein zusätzlicher Test prüft beide Ergebnisse (`true` und `false`) mit einem spät registrierten Beobachter. Die äußere Minutengrenze erkennt einen echten Test-Hang. Die normale parallele Ausführung, die Produktionswarteschlange mit höchstens 16 Bereinigungsaufträgen und die Sicherheitsprüfungen bleiben unverändert: Ein offener Lesehandle hält seinen Stage, unbekannte Dateien und gleich große Dateiersetzungen verhindern die vollständige Bereinigung bereits vor dem ersten Unlink.

Der PNG-Codec-Test verwendet ebenfalls gepufferte Eintritts-, Speicherreservierungs- und Abschlussereignisse. Er belegt weiterhin, dass die wartende Eingabe ihre tatsächlichen Bytes reserviert und ihr abgebrochener Beobachter bereits zurückkehrt, während der erste Codec noch bewusst blockiert ist. Ein Fünfsekunden-Poll misst diese kausale Reihenfolge unter Last nicht zuverlässig.

Die SQLite-Kooperationsprobe hält ihre echte Transaktion bis zur ausdrücklichen Freigabe. Der frühere künstliche Commitfehler nach 1,5 Sekunden konnte vor dem verspätet ausgeführten Testtreiber auftreten. Beim Alias-CAS-Test gibt jetzt der tatsächliche Contention-Callback den Writer direkt frei. Produktionsdeadlines, Inode-Schutz und CAS-Erwartungen bleiben unverändert. Die serialisierte Suite hält höchstens einen synchronen Testhook; bei abgebrochenen asynchronen Checkpoints gibt das Test-Cleanup ihn frei. Die äußere Minutengrenze dient als Hangwächter und ersetzt keine Produktionsfrist.

Die Bibliotheksfälle in `CatalogCleanupIntegrationTests` beobachten die vorhandenen Publisher für Laden, Import, Projektion und Katalogänderung gemeinsam. Ein gepufferter Zustandsstrom ersetzt die feste Zehnsekunden-Pollingfrist, die im parallelen Volltest vor dem tatsächlich eingeplanten Startup-Abschluss ablaufen konnte. Nach einem Bereitschaftsereignis werden die reale Mutation/Projektion abgewartet und die gespeicherten Flags nochmals geprüft, weil `@Published` vor der Wertänderung sendet. Bei Testabbruch werden Beobachter entfernt und bereits angenommene Katalogoperationen vor dem Löschen der temporären Fixture zu Ende geführt. Produktionsdeadlines und Erwartungen an die vollständige Datenbankbereinigung ändern sich nicht; die Suite behält parallele Ausführung und eine äußere Minutengrenze als Hangwächter.

Weitere im vollständigen AI-Entwicklungslauf sichtbar gewordene Bereitschaftsrennen betreffen den Artefakt-Controller, die Bibliothekskopfzeile und den Tonwert-Abbruchtest. Der Artefakt-Controller beobachtet die Modellpublisher und den tatsächlichen Commit-Eintritt seines Fakes; Abbruch gibt diesen Commit frei und wartet vor Fixture-Löschung auf Persistenz. Die Kopfzeilen-Fixture wartet direkt auf die abgeschlossene Katalog-Ladeoperation, anschließend bleiben sämtliche Layout- und Bedienungsassertions erhalten. Die Tonwertprobe signalisiert den Eintritt in die parallele Zeilenverarbeitung über einen gepufferten Stream und hält die Zeile bis zum tatsächlichen Task-Abbruch. Ihr synchroner Worker verwendet den vorhandenen separaten `TestSynchronousWorker`, damit er keinen kooperativen Executor-Thread blockiert. Die Prüfungen für Abbruch, genau einen Undo-Schritt und das Layout bleiben erhalten; äußere Minutengrenzen erkennen echte Hänger statt Bereitschaft mit kurzen Performancefristen gleichzusetzen.
