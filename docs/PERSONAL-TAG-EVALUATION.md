# Persönliche Tagzentroide: Qualifizierung #184

Stand 24.10.2026: **No-Go für Produktfreigabe, lokales Experiment verfügbar.**
Es liegt kein eingefrorener, unabhängig kontrollierter privater Lern-/Tuning-/
Abnahmesatz mit SigLIP2-Vektoren und separaten Bildanalysevorschlägen vor. Daher
sind tatsächliche Motivqualität, Nutzerbestätigungsnutzen und native Ressourcen
offen. Es wird kein persönliches Modell veröffentlicht und keine automatische
Metadatenänderung aktiviert. Die vorhandene Bildanalyse bleibt verfügbar.

Das ausführbare [Evaluationswerkzeug](../tools/personal-tag-evaluation/README.md)
implementiert die bestätigte Taxonomie, versionierte Snapshotbindung, deterministische
Mittelung/L2-Normalisierung, Mindestbeispiele, Enthaltung, Top-K und einen vom
Abnahmesatz getrennten Tuning-Schritt. Report und Plan enthalten denselben
Modell-/Index-/Metadatenbezug. Die vollständigen notwendigen numerischen Gates
stehen vor dem ersten Fotolauf fest. Fehlende Daten sind eine Freigabesperre,
kein negatives Ergebnis einer tatsächlich ausgeführten Modellmessung.

Synthetische Tests prüfen Entwurfausschluss, bestätigte KI-Herkunft, unveränderte
Schreibweisen und getrennte deutsche/englische Begriffe, Duplikate, Serienleakage,
Mindestbeispiele, verschwindende Mittelwerte, ungültige/fehlende Vektoren,
Quellenrevisionen, falsche Generationen sowie Unabhängigkeit von Abnahmedaten.
Sie belegen Rechen- und Auswertungsverträge, keine Fotogenauigkeit. Der öffentliche
synthetische Ergebnisbericht ist [hier](PERSONAL-TAG-SYNTHETIC.json) hinterlegt;
seine Messung umfasst nur den Python-Snapshot, weder Index-I/O noch Modellinferenz.

Vor einer erneuten Produktentscheidung ist ein lokaler Snapshotadapter mit
begrenzten SQLite-Lesezugriffen und aktueller nativer Quellenprüfung zu qualifizieren.
Eine zukünftige bewusst ausgelöste Aktion muss Vorschläge getrennt anzeigen und
ausgewählte Tags über den bestehenden Metadatenpfad bestätigen. Ergänzen bleibt
Standard, Ersetzen eine ausdrückliche Wahl. A→B→A, Abbruch und zwischenzeitliche
manuelle Bestätigung benötigen dann UI-/CAS-Regressionen. Die Offlineauswertung
kann solche Belege nicht ersetzen und besitzt deshalb keine App-Schreibschnittstelle.

Architekturvorbild ist ausschließlich der Ablauf in der
[gepinnten darktable-ai-Modellkarte](https://github.com/darktable-org/darktable-ai/blob/76513a1e379b4265007bae768825b9a581944ff8/models/embedding-openclip-rn101-yfcc15m/README.md).
Deren OpenCLIP-Modell, 512er-Vektoren, Qualitäts- und Lizenzbehauptungen werden
nicht übernommen. Glowrooms bestehende [SigLIP2-Verträge](SEMANTIC-SEARCH.md)
und [Metadatenverträge](PHOTO-METADATA.md) bleiben maßgeblich.
