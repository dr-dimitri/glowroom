import SwiftUI

typealias ViewState<Value> = SwiftUI.State<Value>

enum Theme {
    static let background = Color(red: 0.087, green: 0.095, blue: 0.099)
    static let sidebar = Color(red: 0.103, green: 0.111, blue: 0.115)
    static let panel = Color(red: 0.121, green: 0.130, blue: 0.134)
    static let elevated = Color(red: 0.160, green: 0.171, blue: 0.175)
    static let line = Color.white.opacity(0.075)
    static let muted = Color(red: 0.55, green: 0.59, blue: 0.59)
    static let accent = Color(red: 0.82, green: 0.91, blue: 0.58)
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
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.background).padding(.horizontal, 17).padding(.vertical, 11)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.7).foregroundStyle(Theme.muted) }
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
