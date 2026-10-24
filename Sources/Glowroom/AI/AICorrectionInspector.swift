import SwiftUI

/// Correction and setup reuse the common develop context.
/// The enclosing inspector owns scrolling, histogram and editing history.
struct AICorrectionInspector: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        AIDevelopmentView(library: library)
            .font(.system(size: 13))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ai-correction.inspector")
    }
}
