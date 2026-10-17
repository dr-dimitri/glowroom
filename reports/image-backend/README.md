# Bildbackend-Gate zu Issue #12

Entscheidung vom 17. Oktober 2026: **`fullNoGo` wegen nachgewiesener Qualitätsmängel**. Der Produktpfad bleibt unavailable. Ein erfolgreicher nativer Modellaufruf gibt keine Bildfunktion frei. [Entscheidung, Grenzen, Quellen und Reproduktion](../../docs/AI-IMAGE-BACKEND-DECISION.md).

- `historical-2026-10-16/`: ursprüngliche sechs synthetische Motive, sieben Maskenfälle, zehn tatsächliche Inferenzbilder, Parameter, Ereignisse, Ressourcen-/Abbruchmessungen, Lizenzen und Quellnachweise. Ein durch Systemschlaf unterbrochener Warmlauf bleibt als solcher ausgewiesen.
- `current-compositor-2026-10-17/`: erneute Verarbeitung dieser echten Rohoutputs mit dem heutigen `MaskCompositor.cpu`; beschriftete Vergleiche, exakte Pixelprüfung und abschließendes visuelles Review. Dies ist keine neue Inferenzzeitmessung.
- `picedit-issue12-benchmark-20261017/` und `picedit-issue12-benchmark-20261017-compositor/`: neue echte kalte Generierung plus drei warme Wiederholungen und eigener Abbruchtest, anschließend aktuelles Compositing. Die erste Fixture wurde viermal tatsächlich gerechnet; vollständige unterschiedliche Motive stehen separat im historischen Set. Gewichte, ausführbare Helper und vollständige SDK-Archive gehören nicht in dieses Repository.

Die maschinenlesbaren Teilberichte erhalten ihre ursprünglichen Mess- und Reviewstatus. Ein `pending` in einem früheren Zwischenbericht wird durch das getrennte abschließende `visual-review.json` eingeordnet, nicht still umgeschrieben. Die kleinen Contract-Fixtures aus `ImageGenerationFixtures` und ihre Golden-Geometrie-Tests sind deterministische Schnittstellentests und keine simulierten Modellergebnisse.
