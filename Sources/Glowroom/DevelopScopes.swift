import Foundation
import SwiftUI

// Display preferences deliberately have no connection to EditSettings/history.
enum DevelopScopeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case histogram, waveform, parade
    var id: Self { self }
    var title: String {
        switch self { case .histogram: "Histogramm"; case .waveform: "Waveform"; case .parade: "RGB-Parade" }
    }
}
enum DevelopScopeScale: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear, logarithmic
    var id: Self { self }
    var title: String { self == .linear ? "linear" : "logarithmisch" }
    func height(mass: Int, peak: Int) -> Double {
        guard peak > 0, mass > 0 else { return 0 }
        // Work in opaque-pixel equivalents, independent of integer storage units.
        let value = Double(min(mass, peak)) / 255, maximum = Double(peak) / 255
        return self == .linear ? value / maximum : log1p(value) / log1p(maximum)
    }
}
struct DevelopScopePreferences: Codable, Equatable, Sendable {
    static let key = "workspace.scopes.v1"
    var mode: DevelopScopeMode = .histogram
    var scale: DevelopScopeScale = .logarithmic
    var channelMask = 7
    var visibleChannels: [Int] { (0..<3).filter { channelMask & (1 << $0) != 0 } }
    init() {}
    private enum CodingKeys: String, CodingKey { case version, mode, scale, channelMask }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? values.decode(Int.self, forKey: .version)) == 1 else { return }
        mode = (try? values.decode(DevelopScopeMode.self, forKey: .mode)) ?? .histogram
        scale = (try? values.decode(DevelopScopeScale.self, forKey: .scale)) ?? .logarithmic
        if let mask = try? values.decode(Int.self, forKey: .channelMask), (0...7).contains(mask) { channelMask = mask }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(mode, forKey: .mode); try values.encode(scale, forKey: .scale)
        try values.encode((0...7).contains(channelMask) ? channelMask : 7, forKey: .channelMask)
    }
    func peak(in channels: [[Int]]) -> Int {
        visibleChannels.reduce(0) { peak, channel in max(peak, channels.indices.contains(channel) ? channels[channel].max() ?? 0 : 0) }
    }
}

/// RGB density, column-major, in exact 1/255 opaque-pixel mass units.
/// One accepted 384² proxy, at most 128 columns × 256 values × 3 UInt32:
/// 393,216 bytes. Waveform and parade share this same immutable reduction.
struct DevelopSpatialScope: Sendable {
    static let maximumColumns = 128
    static let bins = 256
    let columns: Int
    let channels: [[UInt32]]
    func peak(for preferences: DevelopScopePreferences) -> Int {
        preferences.visibleChannels.reduce(0) { max($0, Int(channels[$1].max() ?? 0)) }
    }
}
actor DevelopScopeReducer {
    func reduce(_ analysis: DevelopPreviewAnalysis) throws -> DevelopSpatialScope {
        try Task.checkCancellation()
        guard analysis.width > 0, analysis.height > 0, analysis.width <= 384, analysis.height <= 384,
              analysis.pixels.count == analysis.width * analysis.height * 4 else {
            return .init(columns: 0, channels: [[], [], []])
        }
        let columns = min(DevelopSpatialScope.maximumColumns, analysis.width)
        var channels = [[UInt32]](repeating: [UInt32](repeating: 0, count: columns * DevelopSpatialScope.bins), count: 3)
        // <=147,456 pixels: one bounded actor pass avoids another pool and the
        // transfer/startup overhead of GPU work. No decode, render or unpremultiply.
        for y in 0..<analysis.height {
            try Task.checkCancellation()
            for x in 0..<analysis.width {
                let index = (y * analysis.width + x) * 4
                let alpha = UInt32(analysis.pixels[index + 3])
                guard alpha > 0 else { continue }
                let column = x * columns / analysis.width
                for c in 0..<3 { channels[c][column * 256 + Int(analysis.pixels[index + c])] += alpha }
            }
        }
        try Task.checkCancellation()
        return .init(columns: columns, channels: channels)
    }
}

struct DevelopScopePlot: View {
    let analysis: DevelopPreviewAnalysis?
    let spatial: DevelopSpatialScope?
    let preferences: DevelopScopePreferences
    private let colors: [Color] = [.red, .green, .blue]
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard size.width > 0, size.height > 0 else { return }
            context.blendMode = .plusLighter
            if preferences.mode == .histogram, let analysis {
                let peak = preferences.peak(in: analysis.channels)
                for channel in preferences.visibleChannels where analysis.channels.indices.contains(channel) {
                    let bins = analysis.channels[channel]
                    var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                    for (bin, count) in bins.enumerated() {
                        let value = preferences.scale.height(mass: count, peak: peak)
                        path.addLine(to: CGPoint(x: Double(bin) / Double(max(1, bins.count - 1)) * size.width, y: (1 - value) * size.height))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                    context.fill(path, with: .color(colors[channel].opacity(0.45)))
                }
            } else if let spatial, spatial.columns > 0 {
                let peak = spatial.peak(for: preferences)
                for channel in preferences.visibleChannels {
                    // Quantized display brightness bounds draw calls to 32/channel.
                    // The exact density remains in the shared reduction.
                    var paths = [Path](repeating: Path(), count: 32)
                    let panels = preferences.mode == .parade ? 3.0 : 1.0
                    let offset = preferences.mode == .parade ? Double(channel) * size.width / 3 : 0
                    let cellWidth = size.width / panels / Double(spatial.columns)
                    let cellHeight = size.height / 256
                    for (index, mass) in spatial.channels[channel].enumerated() where mass > 0 {
                        let intensity = preferences.scale.height(mass: Int(mass), peak: peak)
                        let level = min(31, max(0, Int(ceil(intensity * 32)) - 1))
                        let x = offset + Double(index / 256) * cellWidth
                        let y = Double(255 - index % 256) * cellHeight
                        paths[level].addRect(CGRect(x: x, y: y, width: cellWidth + 0.2, height: max(1, cellHeight)))
                    }
                    for level in 0..<32 { context.fill(paths[level], with: .color(colors[channel].opacity(Double(level + 1) / 32))) }
                }
            }
        }.background(Color.black.opacity(0.25))
            .overlay {
                if preferences.channelMask == 0 { Text("Kein Kanal ausgewählt").font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityLabel(preferences.mode.title + " der bearbeiteten sRGB-SDR-Vorschau")
            .accessibilityValue(preferences.visibleChannels.map { ["Rot", "Grün", "Blau"][$0] }.joined(separator: ", ") + "; Zählerskala " + preferences.scale.title)
    }
}
