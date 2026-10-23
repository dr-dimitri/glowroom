# Lokaler Vergleich automatischer Fotokorrektur

Dieses optionale Werkzeug führt einen lokalen MLX-VLM-Kandidaten auf den zwölf
[Korrektur-Fixtures](../../docs/AI-AUTO-CORRECTION-TESTS.md) aus. Es lädt keine
Modelle automatisch und verändert weder Testbilder noch deren Erwartungsvertrag.
Ein Korrekturadapter wird nicht ausgeführt.

`run_jarvis.py` ergänzt einen getrennten lokalen llama.cpp-Pfad für JarvisArt.
Die [JarvisArt-Prüfung](../../docs/AI-JARVISART-EVALUATION.md) dokumentiert
Modell, Laufzeit, Ergebnisse und die Grenzen dieses Vergleichs.

Die geprüfte Konfiguration und ihre tatsächlichen Ergebnisse stehen unter
[Qwen3.5-4B-Evaluation](../../docs/AI-QWEN35-EVALUATION.md). Diese ist keine
Produktintegration und kein allgemeiner Leistungsnachweis für beliebige Macs.

## Voraussetzungen

- Apple Silicon mit erreichbarem Metal-Gerät; geprüft auf M2 Pro mit 16 GB RAM
  und macOS 27.0.1, Python 3.12.
- Separate Python-Umgebung mit den Paketen aus `requirements.txt`. Der komplette
  tatsächlich installierte Abhängigkeitsstand wird je Lauf eingefroren.
- Die ausdrücklich lokal bereitgestellten zwölf PNGs samt `expectations.json`
  und `response.schema.json`. Frische Checkouts und CI besitzen sie nicht.
- Der separat heruntergeladene Snapshot von
  `mlx-community/Qwen3.5-4B-4bit`, Revision
  `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`. Seine JSON-Provenienz enthält
  `repo`, `revision` und `files`, je Datei `file`, `bytes`, `sha256`.
  Der Runner überprüft alle Dateien vor dem Laden. Der vorhandene lokale Lauf
  enthält diese Provenienz ebenfalls unter `run.json.model`.

Installieren und ausführen, vom Repository aus:

```sh
python3 -m venv /tmp/glowroom-qwen35-venv
/tmp/glowroom-qwen35-venv/bin/python -m pip install -r tools/auto-correction-evaluation/requirements.txt
/tmp/glowroom-qwen35-venv/bin/python tools/auto-correction-evaluation/run.py \
  --fixtures Fixtures/LocalTestImages \
  --model /tmp/glowroom-qwen35-model \
  --model-provenance /tmp/glowroom-qwen35-model-provenance.json \
  --output Fixtures/LocalTestImages/Evaluations/new-run \
  --constrained-decoding
/tmp/glowroom-qwen35-venv/bin/python tools/auto-correction-evaluation/evaluate.py \
  --fixtures Fixtures/LocalTestImages \
  --responses Fixtures/LocalTestImages/Evaluations/new-run/responses \
  --output Fixtures/LocalTestImages/Evaluations/new-run/evaluation.json
```

Die temporären Modellpfade stammen aus der lokalen Probe; auf einem anderen
Rechner sind Modell und Provenienz ausdrücklich vorzubereiten und anzugeben.
`--output` muss ein neues separates Verzeichnis sein. `evaluate.py` darf einen
Bericht außerhalb des Fixture-Wurzelordners neu schreiben. Exitcode 0 des
Runners bedeutet vollständige technische Inferenz, der des Evaluators „Bericht
geschrieben“; keiner bedeutet „Modell bestanden“.

## Blindheit, Grenzen und Auswertung

Der globale Prompt erlaubt nur Aufgabe, Wortschatz/Begriffsdefinitionen und das
für alle Bilder identische Antwortschema. Dateinamen, Fallkennungen, Sollwerte,
Messregionen und Generierungsprompts gelangen nicht in den Modellkontext. Der
Modellprozess erhält nur anonymisierte RGB-Bytes und die gemeinsame Aufgabe.
Quellhash und Decodierung beziehen sich auf denselben unveränderlichen
Byte-Snapshot. Raster werden auf höchstens 1024 Pixel lange Kante begrenzt.

Jedes Bild beginnt mit einem neuen Konversations-/KV-Zustand, Thinking ist aus,
Sampling ist greedy bei Seed 0. Es gibt keine selektiven Wiederholungen oder
nachträgliche JSON-Reparaturen. Ein Modell verarbeitet die Bilder seriell, um
GPU-Speicher und Messung nicht durch konkurrierende Modelle zu verfälschen;
unabhängige Quellenprüfung und Rastervorbereitung laufen mit drei Workern.

`--constrained-decoding` erzwingt eine allgemeine syntaktische Antwortform.
llguidance 1.9.1 unterstützt `uniqueItems` und die verwendeten bedingten
`allOf`-Regeln nicht. Nur die **Decoderansicht** lässt diese Regeln aus; der
Evaluator prüft weiterhin das unveränderte vollständige Originalschema,
Eindeutigkeit, bedingte Edit-Regeln und alle fallbezogenen Erwartungen. Frische
Decoderinstanzen verhindern Zustandsübernahme zwischen Bildern. Syntaxtreue
unter dieser Option ist kein selbständiger Qualitätsnachweis des Modells.

Fehlende Quellen, geänderte Hashes, Timeouts, abgeschnittene Antworten,
Schemafehler, fachliche Fehler, Enthaltungen und offene Sichtung sind getrennte
Zustände. Unbekannte Zusatz-Tags verlangen Sichtung; explizit falsche Tags
scheitern. Beschreibungen müssen auch nach automatisch bestandenen Regeln
unabhängig auf falsche Aussagen geprüft werden. Render- und End-to-End-Status
bleiben `notRun`.

Je Lauf werden Prompt, Template-Prompt, Schemas, Quell-/Rasterhashes,
Modellrevision und Dateihashes, Paketversionen, rohe Antworten sowie Laufzeit und
Speicherzähler lokal gespeichert. MLX-Allokatorpeak und Prozess-RSS überlappen
auf Unified Memory und dürfen nicht addiert werden. OS-Dateicaches werden nicht
geleert; ein erster Prozessaufruf ist kein belegter Kaltcache-Lauf. Der aktuelle
Rechner hat 16 GB, daher beweist ein Modellpeak unter 8 GB keinen vollständigen
8-GB-Mac-Betrieb.

Die Quellen und Ausgaben bleiben im ignorierten lokalen Fixture-Bereich oder
einem ausdrücklich getrennten privaten Ausgabeordner. Keine Bilder, Gewichte,
Rohantworten oder privaten Provenienzdateien committen oder ins App-Bundle
aufnehmen.

## Isolierte Werkzeugtests

```sh
/tmp/glowroom-qwen35-venv/bin/python -m unittest discover \
  -s tools/auto-correction-evaluation -p 'test_*.py'
```

Diese Tests erzeugen eigene kleine synthetische Dateien und benötigen weder
Modellgewichte noch lokale Fotofiles, GPU-Inferenz oder Netzwerk. Änderungen
dieses externen Werkzeugs beeinflussen die Kompilierung, Paketierung und Laufzeit
der App nicht und erfordern deshalb keinen vollständigen App-Build.

## JarvisArt über einen lokalen llama.cpp-Server

Dieser Pfad benötigt separat bereitgestellte GGUF-Gewichte **und** deren
Vision-Projektor. Der geprüfte Snapshot ist
`mradermacher/JarvisArt-1208-GGUF` bei Revision
`0abebb0c1c4a8e7745b9383f174df884b7662a4d`; die zugehörige offizielle
Modellrevision steht im Prüfbericht. Die nichtkommerzielle JarvisArt-Lizenz gilt
auch für diese experimentelle Verwendung; Gewichte und Upstream-Prompts werden
nicht im Glowroom-Repository verteilt.

Modell- und Laufzeitprovenienz sind JSON-Objekte mit `root` und `files`;
jeder Dateieintrag enthält relativen `file`-Pfad, `bytes` und `sha256`.
Die Modellliste muss die tatsächlich verwendeten beiden GGUFs enthalten,
die Laufzeitliste mindestens das tatsächlich gestartete Serverbinary.
Der Runner prüft alle aufgeführten Dateien und bindet sie über die verpflichtende
`--server-pid` an Executable, Modellpfad, Projektorpfad und einen ausdrücklich
konfigurierten Server-Slot. Private Eingaben werden nur an eine wörtliche
Loopback-Adresse übermittelt; Proxies und Weiterleitungen sind deaktiviert.

Ein bereits lokal gestarteter Server wird beispielsweise so geprüft:

```sh
/tmp/glowroom-jarvisart/build/bin/llama-server \
  --model /tmp/glowroom-jarvisart/model/JarvisArt-1208.Q4_K_M.gguf \
  --mmproj /tmp/glowroom-jarvisart/model/JarvisArt-1208.mmproj-f16.gguf \
  --alias jarvisart --host 127.0.0.1 --port 18082 \
  --ctx-size 8192 --n-gpu-layers 99 --threads 6 \
  --batch-size 512 --ubatch-size 512 --parallel 1 \
  --cache-ram 0 --no-cache-prompt --reasoning-format none \
  --image-min-tokens 1024 --image-max-tokens 1280 \
  --offline --no-webui --log-timestamps --no-context-shift
```

Der Server bleibt in diesem Terminal geöffnet. In einem zweiten Terminal seine
Prozess-ID als `SERVER_PID` einsetzen und den Runner aufrufen:

```sh
/tmp/glowroom-qwen35-venv/bin/python tools/auto-correction-evaluation/run_jarvis.py \
  --fixtures Fixtures/LocalTestImages \
  --output Fixtures/LocalTestImages/Evaluations/NEUER-JARVIS-LAUF \
  --server-url http://127.0.0.1:18082 \
  --server-pid SERVER_PID \
  --mode shared \
  --model-provenance /tmp/glowroom-jarvisart/model-provenance.json \
  --runtime-provenance /tmp/glowroom-jarvisart/runtime-provenance.json
```

`shared` verwendet dieselbe gemeinsame Aufgabe, dieselbe Decoderansicht und
dasselbe unveränderte Validierungsschema wie der kontrollierte Qwen-Lauf.
Die Antworten können mit `evaluate.py` ausgewertet werden. `native` verlangt
zusätzlich `--system-prompt` und `--user-prompt` als eingefrorene lokale Dateien;
es verwendet JarvisArts ursprüngliches Lightroom-Ausgabeformat. Diese Bedingung
hat eine getrennte fachliche Sichtung und besteht dadurch nicht den gemeinsamen
JSON-Vertrag. Rohe Antworten und Finish-Gründe bleiben unverändert erhalten.

Beide Modi prüfen alle zwölf Fälle in fester Reihenfolge, ohne selektive
Wiederholungen. `--limit N` kennzeichnet ausdrücklich einen getrennten Piloten
über die ersten N Fälle. Ein einzelner Slot verarbeitet die Bilder seriell;
Quellenprüfung und Rastervorbereitung verwenden drei Worker. Der Server muss
mit lokalen Dateien, `--offline`, `--parallel 1`, deaktiviertem Prompt-Cache
und ohne konkurrierende Anfragen laufen. Seine Startparameter, Revisionen,
Dateihashes und Logs gehören zur lokalen Laufprovenienz. `cache_prompt=false`
im Request ersetzt nicht die Prüfung der tatsächlichen Servermeldungen.

Der HTTP-Timeout begrenzt Socket-Inaktivität, keine gesamte Wall-Zeit. Nach
Timeout oder Inferenzfehler folgt kein weiterer Auftrag auf denselben
möglicherweise noch belegten Slot. Ein Server liefert nicht zwingend einen
Bildtokenzähler; nur positive ganzzahlige Zähler werden als solcher Nachweis
markiert. Vision-Aktivierung, Serverlogs und die tatsächlich übertragenen
Raster werden zusätzlich geprüft; ein Template-Marker ist kein Bildtoken.
Server-RSS und globale Speicher-/Swap-Zähler sind
unterschiedliche Messgrößen; fehlende OS-Messrechte werden separat ausgewiesen.
Es gibt keinen MLX-Allokatorpeak für diesen Laufzeitpfad und keinen Nachweis
vollständiger 8-GB-Systemtauglichkeit.

Die Jarvis-HTTP-Tests verwenden ausschließlich einen temporären lokalen
Testserver. In der eingeschränkten Sandbox benötigen sie eine Freigabe für
Loopback-Bindung, aber keine externen Netzwerkdienste oder Modellgewichte.
