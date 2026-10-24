# Persönliche SigLIP2-Tagzentroide (#184)

Lokales Entwicklerexperiment ohne Modellinferenz, SQLite-Schreibzugriff oder
App-Freigabe. Python ≥ 3.9, ausschließlich Standardbibliothek. Der bestehende
768-dimensionale SigLIP2-Raum wird über den vollständigen freigegebenen Descriptor
gebunden; 512-dimensionale OpenCLIP-Vektoren werden abgelehnt.

```sh
python3 -m unittest discover -s tools/personal-tag-evaluation -p 'test_*.py' -v
python3 tools/personal-tag-evaluation/make-synthetic-fixture.py /tmp/personal-tags-synthetic.json
python3 tools/personal-tag-evaluation/evaluate.py freeze /tmp/personal-tags-synthetic.json /tmp/personal-tags-plan.json
python3 tools/personal-tag-evaluation/evaluate.py evaluate /tmp/personal-tags-synthetic.json /tmp/personal-tags-plan.json --output /tmp/personal-tags-result.json
```

Dateien werden ausschließlich neu angelegt; für weitere Läufe neue Ausgabepfade
verwenden. `freeze` bindet Eingabebytes, Evaluator und vorab festgelegte Parameter
mit SHA-256. Erst danach messen. Ein geänderter Datensatz/Evaluator erfordert eine
neue, als solche kenntliche Studie. SIGINT beendet den lokalen Prozess; es gibt
keinen weiterlaufenden nativen Auftrag und keinen Katalogzustand zurückzurollen.

## Lokaler Eingabesnapshot

Das Fixture-Kommando zeigt das vollständige JSON-Schema. Für eine echte Studie
`dataset_kind: private_reviewed` setzen und unabhängig kontrollierte Beispiele
verwenden. Ein automatischer Export einer privaten Bibliothek gehört ausdrücklich
nicht zu diesem Werkzeug. Ein Snapshotadapter muss die folgenden Felder unter
aktuellen Metadaten-/Indexzulassungen lesen und Quellen unmittelbar prüfen;
erfundene aktuelle Revisionsfelder liefern keinen Quellennachweis.

| Feld | Vertrag |
| --- | --- |
| `schema_version` | Exakt 1 |
| `descriptor` | Exakt `SemanticApprovedPackage.json.descriptor`, alle Modell-/Vorverarbeitungsfelder |
| `catalog_session`, `index_generation`, `metadata_generation` | Aktuelle Katalogsitzung, aktive Index-UUID und Metadatensnapshotgeneration |
| `rows` | Höchstens 4096 verschiedene Asset-IDs; maximal 64 MiB JSON, 256 Tagidentitäten |
| `split`, `group` | `train`, `tune`, `test`; alle Serien/nahen Duplikate derselben Gruppe im gleichen Split |
| `associated`, `confirmed_revision` | Aktuell zugeordnet und ausdrücklich bestätigte Revision > 0 |
| `source_revision`, `embedding_source_revision` | Native aktuelle Quellenrevision und Revision des gespeicherten Vektors müssen gleich sein |
| `embedding_generation`, `vector` | Dieselbe aktive Generation; endlicher L2-Floatvektor, 768 Komponenten, Normtoleranz 0,001 |
| `confirmed_tags` | Nur bestätigte Tags als `value`, kanonischer `key` aus `PhotoTextNormalization.tagKey`, unveränderte `origin` (`manual`, `confirmedAI`, `imported`) |
| `baseline_keys` | Separat erzeugte Vorschläge der bestehenden Bildanalyse; kein Ground-Truth-Leak |
| `independently_reviewed` | Unabhängige inhaltliche Kontrolle, auch bestätigte KI-Tags können falsch sein |

Offene KI-Vorschläge und manuelle Entwürfe werden niemals gelesen. Das optionale
`draft_tags` im synthetischen Fixture belegt ihren Ausschluss. Die bestehende
Swift-Normalisierung wird am Exportpunkt verwendet; Python definiert keine eigene
Unicode-/Sprachnormalisierung. Schreibweise bleibt die erste nach stabiler Asset-ID;
„Bäume“ und „Trees“ bleiben getrennt. Herkunft und Sprachfeld werden nicht geändert.

## Eingefrorene Methode und Grenzen

Mindestens drei gültige Lernfotos je Tag; Mittelung ausschließlich des Lernsplit,
danach L2-Normalisierung. Mittelwertnorm < 1e-6 verwirft den Tag. Stabile Reihenfolge
nach Cosinus, bei Gleichstand kanonischer Tagidentität, höchstens fünf Kandidaten.
Cosinuswerte sind keine Wahrscheinlichkeiten. Die Enthaltungsschwelle wird nur auf
dem Tuning-Split unter `[0, .2, .4, .6, .8, .9, 1]` gewählt (F1, Präzision, höhere
Schwelle). Abnahmedaten sind an keinem Lern-/Schwellenschritt beteiligt.

Der Bericht enthält Precision/Recall/F1 und Enthaltung gesamt und pro Tag,
Baselinevergleich, sämtliche Abnahmefälle, ausgeschlossene Beispiele, ungeeignete
Tags, verwendete Bestätigungs-/Quellenrevisionen sowie Zeit, Peak-RSS, System und
Indexumfang. Seltene und widersprüchliche Tags verschwinden nicht aus der
Auswertung; visuell nicht erkennbare Begriffe gehören als Gegenbeispiele hinein.
Mindestens zwölf echte Abnahmefotos, Precision ≥ 0,80, Recall ≥ 0,40 und F1-Gewinn
≥ 0,05 gegenüber der Bildanalyse sind notwendige, allein nicht ausreichende Gates.
Tatsächlicher Bestätigungsnutzen, kalte/warme native Ressourcenmessungen und eine
unabhängige Beurteilung bleiben separate Voraussetzungen. Deshalb gibt der
Offlinebericht auch bei perfekten synthetischen Metriken keine Produktfreigabe.

Keine abgeleiteten Modelle werden gespeichert. Jeder Aufruf berechnet frisch,
bindet das Ergebnis an die Snapshotgeneration und listet Tagrevisionen. Änderungen,
Relocation, entfernte Quellen und Modell-/Indexwechsel verlangen einen neuen
Snapshot. Keine alten Vorschläge können Formulare überschreiben: Das Werkzeug
besitzt keine UI-/Metadaten-Schreibschnittstelle. Eine spätere Produktintegration
benötigt zusätzlich CAS-Prüfung, Abbruch-/A→B→A-Tests und ausdrückliche Übernahme
über den bestehenden Metadatenpfad (Standard Ergänzen, Ersetzen bewusst wählen).

Die Reduktion bleibt bei begrenzten Eingaben absichtlich seriell: eine deterministische
Summationsreihenfolge erhält Reproduzierbarkeit, zusätzliche Python-Prozesse würden
private 768er-Vektoren kopieren. Sie läuft außerhalb des App-MainActor. Unabhängige
Tests können parallel mit anderen Prüfungen laufen; Ressourcenmessungen isoliert.
Es erfolgen weder neue RAW-Decodierung noch KI-Zulassungen oder Modellpoolaufbau.

Private Datensätze und Berichte ausschließlich außerhalb von Git, beispielsweise
unter `reports/personal-tags/`, speichern. Sie enthalten eigene Tags und Asset-IDs.
Eine fehlende private Bibliothek wird niemals still vorausgesetzt. Siehe
[Qualifizierungsentscheidung](../../docs/PERSONAL-TAG-EVALUATION.md).
