import SwiftUI

typealias ViewState<Value> = SwiftUI.State<Value>

enum Theme {
    // Neutral surfaces keep the surrounding UI from tinting the perceived image colors.
    static let background = Color(white: 0.12)
    static let chrome = Color(white: 0.145)
    static let sidebar = Color(white: 0.19)
    static let panel = Color(white: 0.215)
    static let elevated = Color(white: 0.26)
    static let canvas = Color(white: 0.52)
    static let line = Color.black.opacity(0.45)
    static let text = Color(white: 0.88)
    static let muted = Color(white: 0.67)
    static let accent = Color(white: 0.94)
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.muted)
                .frame(width: 32, height: 30)
                .background(active ? Theme.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.background).padding(.horizontal, 17).padding(.vertical, 11)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted) }
}

struct RatingStars: View {
    let rating: Int
    var size: CGFloat = 10
    var onChange: ((Int) -> Void)?
    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                if let onChange {
                    Button { onChange(star == rating ? 0 : star) } label: { starImage(star) }
                        .buttonStyle(.plain).help("\(star) Sterne").accessibilityLabel("\(star) Sterne bewerten")
                } else { starImage(star) }
            }
        }.accessibilityElement(children: onChange == nil ? .ignore : .contain)
            .accessibilityLabel("Bewertung: \(rating) von 5 Sternen")
    }
    private func starImage(_ value: Int) -> some View {
        Image(systemName: value <= rating ? "star.fill" : "star")
            .font(.system(size: size)).foregroundStyle(value <= rating ? Theme.accent : Theme.muted.opacity(0.45))
    }
}
