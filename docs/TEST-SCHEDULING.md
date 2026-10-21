# Parallele Scheduling-Tests

Die Testkorrektur zu [Issue #62](https://github.com/dr-dimitri/glowroom/issues/62) trennt das Warten auf eine kontrollierte Fake-Operation vom Blockieren eines Betriebssystemthreads. Ein synchrones `DispatchSemaphore.wait` innerhalb mehrerer `Task.detached`-Fakes kann die kooperativen Threads belegen, auf denen auch die Teststeuerung ihre Freigaben ausführen müsste. Ein längerer Timeout oder ein serieller Gesamtlauf behebt diese Abhängigkeit nicht.

Die Preview- und Adjusted-Preview-Tests verwenden dafür suspendierende Fakes. `TestAsyncLatch` ignoriert bewusst den Abbruch der simulierten nativen Arbeit, bis der Test `releaseAll()` ausführt. Die Pipelines halten ihren Workerplatz weiterhin bis zur tatsächlichen Rückkehr. Die vorhandenen synchronen Decoder und Renderer laufen unverändert innerhalb derselben begrenzten Hintergrundworker; optionale interne `asyncDecoder`-/`asyncRenderer`-Abhängigkeiten ermöglichen die suspendierenden Testdoubles. Kurze separate Tests prüfen auch die synchronen Pfade, Fehler, Priorität und Ausführung außerhalb des MainActor.

`TestStateSignal` speichert Ereignisse auch vor einer Warteanmeldung. Anmeldung, Ereignis und Abbruch sind durch kurze Locks geordnet; Continuations werden außerhalb des Locks fortgesetzt. Cancellation entfernt wartende Testfortsetzungen. Ein Test-Timeout wirft mit Bezeichnung und zuletzt beobachtetem Zustand, statt Folgeassertionen mit unerfüllter Vorbedingung auszuführen. `TestAsyncLatch` wird dagegen ausdrücklich vom Test freigegeben, auch in dessen Cleanup. Gestartete Caller werden bei vorzeitigem Testende abgebrochen.

Die semantischen Service-Tests warten auf Text-/Bild-/Installations-/Vorbereitungsereignisse ihrer Fakes. Das gemeinsame Inferenzbudget liefert seine vorhandenen Zustandsereignisse. Für wenige interne Actor-Zustände ohne Ereignisschnittstelle liest `waitForTestState` den tatsächlichen Zustand; seine Frist ist ein Hangwächter, kein Beweis einer Einreihung. Die bisherigen Drei-/Viersekundenfristen bleiben bestehen. Der semantische Bibliotheks-Fixture wartet auf die kombinierten Modellpublisher und beschreibt fehlende Bereitschaft ausdrücklich als Test-Wartefehler, nicht als Providerfehler.

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

Die neuen Gate-Tests prüfen früh eingetroffene Ereignisse, Abbruch vor/nach Anmeldung, Timeout-Cleanup und absichtlich bis zur Freigabe weiterlaufende native Fakes. Vollständiger sauberer App-Build und finales Diffreview bleiben zusätzlich nach `AGENTS.md` erforderlich; konkrete Kontroll- und Testresultate stehen im jeweiligen Pull Request.
