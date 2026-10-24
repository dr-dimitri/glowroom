import SwiftUI

/// Anchored to the viewport so a request never shifts or dims the photograph.
@MainActor
struct InlineMaskCalculationStatus: View {
    @ObservedObject var workspace: InlineMaskWorkspace

    var body: some View {
        if workspace.showsCalculationStatus {
            EditingProgressIndicator(accessibilityPrefix: "local-mask.calculation",
                cancelLabel: "Maskenberechnung abbrechen") {
                    if workspace.objectMask.isRunning { workspace.discardObjectMask() }
                    else { workspace.model?.cancelInference() }
                }
        }
    }
}
