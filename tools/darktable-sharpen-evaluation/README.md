# #174 — unabhängige Mehrskalenschärfung

Protokoll und Gates stehen vorab in [manifest.json](manifest.json), Methodik,
Quellen, Grenzen und Ergebnisse im
[Bericht](../../docs/DARKTABLE-SHARPEN-EVALUATION.md).

```sh
./scripts/evaluate-sharpening.sh /private/tmp/glowroom-dt174-run
python3 -m unittest discover -s tools/darktable-sharpen-evaluation -p 'test_*.py'
```

Optional `--timing --scale` für die vollständige serielle Matrix oder
`--photo /ABSOLUTE/DEVELOPED.tiff` für explizite private Fotodiagnosen.
Keine persönlichen Bilder oder Resultate ins Repository übernehmen.
`summary.json` unterscheidet belastbares No-Go von fehlender Evidenz.
Synthetische CPU-Referenzen können kein Produktions-Go erhalten.
Es gibt keine kopierten GPL-Quellen oder darktable-Laufzeitabhängigkeit.

Stand 24. Oktober 2026: Beide CPU-Kandidaten erhalten **No-Go** durch belegte,
wirkungsgematchte Halo-/Rauschregressionen. Die kleinen synthetischen
[Ergebnisse](results/summary.json) und [Messprovenienz](results/provenance.json)
sind versioniert; Glowrooms Produktionsschärfung bleibt unverändert.
