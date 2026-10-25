import SwiftUI
import GlowroomCore

@MainActor
struct DevelopTransferView: View {
    @ObservedObject var model: DevelopTransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Einstellungen übertragen").font(.title2.weight(.semibold))
            LabeledContent("Quelle", value: model.sourceName)
                .lineLimit(2).accessibilityIdentifier("develop-transfer.source")
            Text("\(model.rows.count) ausgewählte Zielfotos").font(.headline)
                .accessibilityIdentifier("develop-transfer.targets")
            if model.isPreparing { ProgressView("Zielfotos prüfen") }
            DevelopPresetGroupPicker(groups: $model.groups)
                .disabled(model.isRunning || model.didFinish)
            if !model.didFinish {
                if model.rows.contains(where: \.changesHistoryFunction) {
                    Text("Die Übernahme wechselt Zielfotos zu Entwickeln. Der bisherige Verlauf für Masken, Zuschnitt oder Reparatur wird dabei beendet.")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("develop-transfer.history-warning")
                }
                if model.rows.count >= 100 {
                    Button("Vor der Serie eine Sicherung erstellen") { model.createBackup() }
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("develop-transfer.backup")
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            List(model.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Text(row.status.title).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.status == .changed {
                        if model.canUndo(row) {
                            Button("Rückgängig") { model.undo(row) }
                                .accessibilityLabel("Übernahme für \(row.name) rückgängig")
                        } else if !model.isRunning {
                            Text("Rückgängig nicht mehr verfügbar").foregroundStyle(Theme.muted)
                        }
                    }
                }.padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("develop-transfer.row.\(row.id)")
            }.listStyle(.plain)
                .accessibilityIdentifier("develop-transfer.results")
            if model.didFinish || model.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Übernommen: \(model.changedCount) · Unverändert: \(model.unchangedCount)")
                    Text("Übersprungen: \(model.skippedCount) · Fehlgeschlagen: \(model.failedCount) · Abgebrochen: \(model.cancelledCount)")
                }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("develop-transfer.summary")
            }
            Text("Jedes Foto wird einzeln gespeichert. Abbrechen erhält bereits gespeicherte Ergebnisse. Rückgängig gilt pro Foto und solange der Verlauf verfügbar ist.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Abbrechen") { model.cancel() }
                        .accessibilityIdentifier("develop-transfer.cancel")
                }
                Spacer()
                Button(model.didFinish ? "Schließen" : "Verwerfen") { model.dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(model.isRunning)
                    .accessibilityIdentifier("develop-transfer.dismiss")
                if !model.didFinish {
                    Button("Übernehmen") { model.start() }
                        .keyboardShortcut(.defaultAction).disabled(!model.canStart)
                        .buttonStyle(AccentButton())
                        .accessibilityIdentifier("develop-transfer.apply")
                }
            }
        }.padding(24)
            .frame(minWidth: 420, idealWidth: 560, maxWidth: 680, minHeight: 540, idealHeight: 650)
            .font(.system(size: 13))
            .background(Theme.background).foregroundStyle(.white.opacity(0.9))
            .preferredColorScheme(.dark).tint(Theme.accent)
            .interactiveDismissDisabled(model.isRunning)
            .onDisappear { model.presentationDidClose() }
    }
}
