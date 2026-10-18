# SD-1.5-Preview-Sample-Audit zu Issue #78

Am 18. Oktober 2026 wurden die archivierten JSON-Berichte unter `reports/image-backend/` nach `previewBaseline` und `previewConcurrent` durchsucht und die beiden SD-1.5-Berichte ausgewertet. Beide enthalten tatsächlich positive Samplezahlen in beiden Phasen. Der in Issue #78 nachgewiesene logische Fehlerpfad mit leeren Messreihen ist damit für keinen dieser archivierten Läufe belegt. Es wurden ausschließlich vorhandene Berichte gelesen, keine Modelle geladen und keine neuen Inferenz- oder Vorschauläufe gemessen. Historische Rohberichte bleiben bytegleich.

| Rohbericht | Baseline `sampleCount` | Konkurrenz `sampleCount` | Baseline P95 (s) | Konkurrenz P95 (s) | Prüfung |
| --- | ---: | ---: | ---: | ---: | --- |
| [16. Oktober, vollständige Serie](historical-2026-10-16/series-report.json) | 30 | 1365 | 0,0077604166581295431 | 0,0061931666568852961 | Positive Samplezahlen; beide P95 endlich und nichtnegativ; Konkurrenz ≤ 0,25 s und ≤ 2 × Baseline |
| [17. Oktober, kalter Lauf und drei warme Wiederholungen](picedit-issue12-benchmark-20261017/benchmark.json) | 30 | 1417 | 0,012733666691929102 | 0,011420708149671555 | Positive Samplezahlen; beide P95 endlich und nichtnegativ; Konkurrenz ≤ 0,25 s und ≤ 2 × Baseline |

Das gespeicherte `previewGatePassed = true` beider Berichte bleibt bei dieser zusätzlichen Sample-/Werteprüfung nachvollziehbar. Die Prüfung bestätigt nur die Gültigkeit dieser synthetischen Konkurrenzprobe im Hinblick auf Issue #78. Die jeweils fünf verworfenen Baseline-Warmup-Renderings sind separat als `discardedWarmupRenders = 5` ausgewiesen und werden hier nicht zur Samplezahl addiert.

Beide Berichte kennzeichnen die Quelle als `procedural256x256-checkerboard`, die Ausführung als `CIContext-auto-single-background-renderer` und `actualPicEditUIOrRAWTest = false`. Die Latenz schließt Scheduling und GPU-Wartezeit ein; die Baseline hält den Modellkontext ohne Modellrechnung vor. Daraus folgt weder eine Freigabe der tatsächlichen UI-/RAW-Vorschau noch ein nachgewiesener Leistungsgewinn. Die [Systemschlaf-/Uhrgrenzen des historischen Laufs](historical-2026-10-16/timebase-review.json) und die [bestehende Qualitätsentscheidung `fullNoGo`](../../docs/AI-IMAGE-BACKEND-DECISION.md) gelten unverändert. Die SDXL-Berichte und deren getrennte Gates sind nicht Gegenstand dieses SD-1.5-Audits.

Die geprüften unveränderten Dateibytes haben folgende SHA256-Werte:

| Rohbericht | SHA256 |
| --- | --- |
| `historical-2026-10-16/series-report.json` | `93574685e4fa48406d91281d3f1baa57141eddb5c99feecdbbad63a710bab1d8` |
| `picedit-issue12-benchmark-20261017/benchmark.json` | `ae0d4ebbd38e2664339b773ace9b5bc895ad0a0c79b14cd8a241d5d5de729dee` |

Die Sample-/P95-Prüfung lässt sich ohne Modell, Gewichte, Compiler oder Netzwerk aus dem Repository-Root wiederholen:

```sh
python3 - <<'PY'
import json
import math
from pathlib import Path

root = Path("reports/image-backend")
paths = [
    root / "historical-2026-10-16/series-report.json",
    root / "picedit-issue12-benchmark-20261017/benchmark.json",
]
for path in paths:
    report = json.loads(path.read_text())
    baseline = report["previewBaseline"]
    concurrent = report["previewConcurrent"]
    for phase in (baseline, concurrent):
        assert type(phase["sampleCount"]) is int and phase["sampleCount"] > 0
        p95 = phase["p95Seconds"]
        assert type(p95) in (int, float) and math.isfinite(p95) and p95 >= 0
    assert concurrent["p95Seconds"] <= 0.25
    assert concurrent["p95Seconds"] <= baseline["p95Seconds"] * 2
    print(path, baseline["sampleCount"], concurrent["sampleCount"], "PASS")
PY
```
