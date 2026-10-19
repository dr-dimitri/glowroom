import SwiftUI

/// Anchored to the viewport so a request never shifts or dims the photograph.
@MainActor
struct InlineMaskCalculationStatus: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        if workspace.showsCalculationStatus {
            HStack(spacing: 9) {
                Group {
                    if reducesMotion {
                        Image(systemName: "hourglass").font(.system(size: 13, weight: .medium))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }.frame(width: 16, height: 16).accessibilityHidden(true)
                Text("Maske wird berechnet …")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .accessibilityIdentifier("local-mask.calculation-status")
                Button { workspace.model?.cancelInference() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("Maskenberechnung abbrechen")
                    .accessibilityLabel("Maskenberechnung abbrechen")
                    .accessibilityIdentifier("local-mask.calculation-cancel")
            }
            .foregroundStyle(Theme.text)
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("local-mask.calculation-indicator")
            // No entrance/exit motion, including animations inherited from a
            // surrounding workspace transition. The system spinner is native.
            .transaction { $0.animation = nil }
        }
    }
}

/// Palette and status occupy opposite corners without resizing the photo.
/// The compact lower inset leaves the minimum-height viewport usable, too.
@MainActor
struct InlineMaskViewportOverlays: View {
    @ObservedObject var workspace: InlineMaskWorkspace
    var showsMaskList = true

    var body: some View {
        ZStack {
            if showsMaskList {
                InlineMaskList(workspace: workspace).frame(width: 250)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }
            InlineMaskCalculationStatus(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 14).padding(.vertical, 4)
        }
    }
}
