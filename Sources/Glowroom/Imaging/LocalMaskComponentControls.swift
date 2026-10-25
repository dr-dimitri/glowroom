import GlowroomCore
import SwiftUI

/// Component actions share the selected mask's accepted write and undo path.
@MainActor
struct LocalMaskComponentControls: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    @ObservedObject var model: LocalAdjustmentEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bestandteile").fontWeight(.semibold)
                Spacer(minLength: 0)
                Menu("Bestandteil hinzufügen") {
                    ForEach(LocalMaskOperation.allCases, id: \.self) { operation in
                        Menu(operation.title) {
                            ForEach(LocalMaskCreation.allCases) { kind in
                                Button(kind.title, systemImage: kind.symbol) {
                                    workspace.finishGesture()
                                    model.addComponent(kind, operation: operation)
                                    workspace.showsSelectedComponentOverlay = true
                                }
                            }
                        }
                    }
                }.disabled(!workspace.canCreateComponent)
                    .accessibilityIdentifier("local-mask.component.add")
            }
            if let component = model.selectedComponent {
                TextField("Name des Bestandteils", text: Binding(get: { model.selectedComponent?.name ?? "" }, set: { name in
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    model.updateComponent(component.id) { $0.name = String(name.prefix(64)) }
                }), onEditingChanged: { editing in if editing { model.beginChange() } else { model.endChange() } })
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Name des Bestandteils")
                    .accessibilityIdentifier("local-mask.component.name")
                Picker("Verknüpfung", selection: Binding(get: { model.selectedComponent?.operation ?? .add }, set: { operation in
                    workspace.finishGesture(); model.updateComponent(component.id) { $0.operation = operation }
                })) {
                    ForEach(LocalMaskOperation.allCases, id: \.self) { operation in Text(operation.title).tag(operation) }
                }.accessibilityIdentifier("local-mask.component.operation")
                Toggle("Bestandteil umkehren", isOn: Binding(get: { model.selectedComponent?.isInverted ?? false }, set: { value in
                    workspace.finishGesture(); model.updateComponent(component.id) { $0.isInverted = value }
                })).toggleStyle(.checkbox).accessibilityIdentifier("local-mask.component.invert")
                Picker("Überlagerung", selection: $workspace.showsSelectedComponentOverlay) {
                    Text("Bestandteil").tag(true)
                    Text("Gesamtmaske").tag(false)
                }.pickerStyle(.segmented).accessibilityIdentifier("local-mask.component.overlay-mode")
                Text("Pinsel und Griffe bearbeiten „\(component.name)“.")
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if model.selected?.mask.composition != nil {
                Text("Kein Bestandteil ausgewählt. Neue Bestandteile beginnen mit Hinzufügen.")
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Der erste zusätzliche Bestandteil übernimmt die bisherige Auswahl ohne Änderung.")
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Text("Überlagerung: \(workspace.overlayModeTitle)").foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("local-mask.component.overlay-label")
        }.font(.system(size: 13)).controlSize(.small)
    }
}
