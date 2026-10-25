# Achtband-Farbmischer: Entwickler-Evaluation

Die Kandidaten sind für die Produktion **No-Go**. Das feste numerische HDR-Gate
wird von beiden Versionen überschritten. Die Anwendung lädt diese Dateien
nicht; es gibt keine neuen Einstellungen oder Regler im Produkt.

Spezifikation, Messergebnis und Grenzen:
[docs/COLOR-MIXER-EVALUATION.md](../../docs/COLOR-MIXER-EVALUATION.md).

```sh
python3 -m unittest discover -s tools/color-mixer-evaluation -p 'test_*.py'
python3 tools/color-mixer-evaluation/evaluate.py --output /tmp/color-mixer-results.json
```

Die skalaren Tests benötigen nur Python 3.11 oder neuer. Die native Evaluation
benötigt macOS mit Core Image, Apple Command Line Tools und Zugriff auf den
Fensterserver. Eine verweigerte native Ausführung ist kein bestandenes Gate.
`fixtures.json` ist eingecheckt und reproduzierbar mit
`python3 tools/color-mixer-evaluation/generate_fixtures.py`. Die Tests benötigen
weder lokale Testfotos noch Modelle oder eine Netzwerkverbindung.

`reference.py` ist ein unabhängiges Double-Orakel. Der Swift-Runner kompiliert
und rendert den tatsächlichen `CIColorKernel` in RGBAf. Er beantragt kein
bestimmtes CPU-/GPU-Gerät; Core Image wählt das unterstützte Backend. Der kleine
Controller bleibt seriell, die Pixelarbeit wird vom CI-Graphen parallelisiert.
Die Ausgabeentscheidung kann bei fehlender Produkt-/Sichtprüfung höchstens
`blocked` lauten, auch bei vollständig bestandenen numerischen Prüfungen.

Die linearen sRGB/OkLab-Matrizen folgen den am 25.01.2021 aktualisierten
[Formeln von Björn Ottosson](https://bottosson.github.io/posts/oklab/).
Sein dort gezeigter Konvertierungscode ist Public Domain, alternativ MIT.
Es werden keine Rec.2020-Matrizen und kein Lightcraft-Code übernommen.
