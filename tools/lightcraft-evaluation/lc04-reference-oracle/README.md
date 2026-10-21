# LC-04: unabhängiges numerisches Referenzoracle

Die zwölf Fälle in `vectors.json` stammen aus unveränderten Rust-Funktionen und
den isolierten Klarheits-/Textur-Anweisungen von Lightcraft
`f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15`. Swift-Tests lesen diese Datei;
die Anwendung und ihr normaler Build benötigen weder Rust noch Lightcraft.

Optionale Reproduktion mit Python 3, `rustc` und vorhandenem Checkout:

```sh
python3 tools/lightcraft-evaluation/lc04-reference-oracle/generate.py /path/to/lightcraft
```

`--write` ersetzt die eingefrorenen Vektoren ausdrücklich. Der Generator liest
den gepinnten Commit mit `git show`, prüft die SHA256 jeder Quelle und verändert
den Checkout nicht. Er verwendet die Speicher-/Scheduler-Hülle des LC-03-Oracle;
die kleinen numerischen Fälle bleiben seriell, damit keine zusätzliche Laufzeit
oder Parallelitätsbibliothek erforderlich ist.

Geprüft werden Guided-Klarheit ohne und mit Subsampling (`CLARITY_EPS=0.8`),
Gauß-Textur mit kleinem und größerem Radius sowie negative, neutrale und positive
Stärken. Die unveränderten `finish_with`-Anweisungen prüfen separat ±2,5-EV-
Klarheitsbegrenzung/Mittengewicht und ±1-EV-Texturbegrenzung/`tame`. Die
Klarheitsmittengewichtung verwendet `log_l` als Basis, wie `local::prepare` bei
inaktiven Schatten-/Lichterreglern. Die Swift-Absoluttoleranz beträgt `5e-6`.
Das Oracle ist kein Vergleich mit Lightcrafts vollständigem Tonemapping.

Die synthetischen Eingänge sind selbst erzeugt. Die Swift-Ablationen
`clarityGaussianLog`, `textureGaussianExistingDomain` und `textureGaussianLog`
sind Versuchsvarianten von Glowroom und werden nicht als upstream Original
ausgegeben. Alpha-Abdeckung ist ebenfalls eine Glowroom-Erweiterung und wird
durch eigene Swift-Vertragstests geprüft.

Für die übernommenen Algorithmen gilt MIT; Copyright (c) 2026 ArtCraft Team and
the LightCraft contributors. Quellen, Änderungen, vollständige Lizenz und NOTICE
stehen in [THIRD-PARTY-NOTICES.txt](../THIRD-PARTY-NOTICES.txt) und
[`licenses/lightcraft`](../licenses/lightcraft).
