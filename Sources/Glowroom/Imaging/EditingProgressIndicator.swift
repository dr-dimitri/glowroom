import SwiftUI

/// Shared presentation for image edits, preview rendering and automatic tools.
/// It overlays the image without dimming it or changing its layout.
@MainActor
struct EditingProgressIndicator: View {
    var accessibilityPrefix = "editing.progress"
    var cancelLabel = "Bearbeitung abbrechen"
    var cancel: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if reducesMotion {
                    Image(systemName: "hourglass").font(.system(size: 13, weight: .medium))
                } else {
                    ProgressView().controlSize(.small)
                }
            }.frame(width: 16, height: 16).accessibilityHidden(true)
            Text("Bild wird bearbeitet …")
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                .accessibilityIdentifier(accessibilityPrefix + "-status")
            if let cancel {
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help(cancelLabel).accessibilityLabel(cancelLabel)
                    .accessibilityIdentifier(accessibilityPrefix + "-cancel")
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, 12).padding(.trailing, cancel == nil ? 12 : 6).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityPrefix + "-indicator")
        .transaction { $0.animation = nil }
    }
}

private struct EditingProgressIsCoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A higher-priority tool already presents the shared progress indicator.
    var editingProgressIsCovered: Bool {
        get { self[EditingProgressIsCoveredKey.self] }
        set { self[EditingProgressIsCoveredKey.self] = newValue }
    }
}
