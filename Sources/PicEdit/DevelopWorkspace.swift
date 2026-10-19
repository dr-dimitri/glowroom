import AppKit
import SwiftUI
import PicEditCore

/// A single workspace owns the active canvas tool; pixels are observed after
/// the normal preview pipeline, so histogram and picker never decode a RAW.
@MainActor
final class DevelopWorkspace: ObservableObject {
    @Published var tool: DevelopCanvasTool = .basic
    @Published var picksWhiteBalance = false
    @Published var showsShadows = false
    @Published var showsHighlights = false
    @Published var cropAspect = "free"
    @Published private(set) var sourceSize: CGSize?
    @Published private(set) var displayedMapping: DevelopCanvasMapping?
    @Published private(set) var hdrDisplayed = false
    var isOriginalCanvasReady: Bool { sourceIdentity != nil && displayedMapping == .original }
    func markDisplayed(source: AISourceIdentity, settings: EditSettings) {
        guard source == sourceIdentity else { return }
        displayedMapping = DevelopCanvasMapping(settings.developGeometry)
        hdrDisplayed = settings.developColor.hdrEnabled
    }
    @Published var repairMode: DevelopRetouchMode = .heal
    @Published var repairRadius = 0.035
    @Published var repairFeather = 0.5
    @Published var redEyeStrength = 1.0
    @Published var repairSource: LocalMaskPoint?
    @Published private(set) var analysis: DevelopPreviewAnalysis?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var sourceAnalysis: DevelopPreviewAnalysis?
    private var baseIdentity: ObjectIdentifier?
    private(set) var sourceIdentity: AISourceIdentity?
    @Published var errorMessage: String?
    private var analysisTask: Task<Void, Never>?
    private var identity = UUID()
    typealias Analyze = @Sendable (PreviewBitmap) async throws -> DevelopPreviewAnalysis
    private let analyze: Analyze

    init(analyze: Analyze? = nil) {
        if let analyze { self.analyze = analyze }
        else {
            let worker = DevelopPreviewAnalyzer()
            self.analyze = { try await worker.analyze($0) }
        }
    }

    func bind(source: AISourceIdentity?) {
        guard source != sourceIdentity else { return }
        if sourceIdentity != nil { clear() }
        sourceIdentity = source
    }
    func receive(_ bitmap: PreviewBitmap, sourceBitmap: PreviewBitmap) {
        sourceSize = CGSize(width: sourceBitmap.image.width, height: sourceBitmap.image.height)
        let baseID = ObjectIdentifier(sourceBitmap.image)
        let needsBase = baseIdentity != baseID || sourceAnalysis == nil
        if needsBase { sourceAnalysis = nil }
        analysisTask?.cancel()
        let token = UUID(); identity = token; isAnalyzing = true
        analysisTask = Task { [weak self, analyze] in
            do {
                let result = try await analyze(bitmap)
                try Task.checkCancellation()
                let base = needsBase ? try await analyze(sourceBitmap) : nil
                try Task.checkCancellation()
                guard let self, !Task.isCancelled, self.identity == token else { return }
                self.analysis = result; self.isAnalyzing = false; self.analysisTask = nil
                if let base { self.sourceAnalysis = base; self.baseIdentity = baseID }
            } catch is CancellationError { }
            catch { if let self, self.identity == token { self.isAnalyzing = false; self.analysisTask = nil } }
        }
    }
    func cropRatio(source: CGSize) -> Double {
        switch cropAspect {
        case "1:1": 1
        case "3:2": 1.5
        case "4:3": 4.0 / 3
        case "16:9": 16.0 / 9
        case "2:3": 2.0 / 3
        default: source.width / max(1, source.height)
        }
    }
    func clear() {
        identity = UUID(); analysisTask?.cancel(); analysisTask = nil
        displayedMapping = nil; hdrDisplayed = false
        analysis = nil; sourceAnalysis = nil; sourceSize = nil; baseIdentity = nil; sourceIdentity = nil; isAnalyzing = false; repairSource = nil
        picksWhiteBalance = false; tool = .basic; errorMessage = nil
    }
}

/// Only spatial presentation controls input readiness. Tone/brush updates may
/// keep the preceding frame while the next render is coalesced.
struct DevelopCanvasMapping: Equatable {
    let crop: DevelopCropRect?
    let turns: Int
    let flipsX: Bool
    let flipsY: Bool
    init(_ geometry: DevelopGeometry) {
        crop = geometry.crop; turns = geometry.quarterTurns
        flipsX = geometry.flipHorizontal; flipsY = geometry.flipVertical
    }
    static let original = Self(.neutral)
}

enum DevelopCanvasTool: String, CaseIterable, Identifiable {
    case basic, crop, repair, redEye, masks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .basic: "Grundeinstellungen"
        case .crop: "Zuschneiden und Drehen"
        case .repair: "Reparieren"
        case .redEye: "Rote Augen"
        case .masks: "Maskieren"
        }
    }
    var symbol: String {
        switch self {
        case .basic: "slider.horizontal.3"
        case .crop: "crop.rotate"
        case .repair: "bandage"
        case .redEye: "eye"
        case .masks: "circle.dashed.inset.filled"
        }
    }
    var usesOriginalCanvas: Bool { self != .basic }
}

struct DevelopPreviewAnalysis: Sendable {
    let width: Int
    let height: Int
    /// Top-left row order, straight sRGB RGBA8. Bounded to 384 pixels per edge.
    let pixels: [UInt8]
    let channels: [[Int]]
    let shadows: Int
    let highlights: Int
    private let clippingImages: DevelopClippingImages

    init(width: Int, height: Int, pixels: [UInt8], channels: [[Int]], shadows: Int, highlights: Int,
         clippingImages: DevelopClippingImages = .empty) {
        self.width = width; self.height = height; self.pixels = pixels; self.channels = channels
        self.shadows = shadows; self.highlights = highlights; self.clippingImages = clippingImages
    }
    func rgb(at point: CGPoint) -> (Double, Double, Double, Double)? {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let x = min(width - 1, Int(point.x * Double(width)))
        let y = min(height - 1, Int(point.y * Double(height)))
        // Average a small neighborhood; isolated noise must not set the WB.
        var totals = [Double](repeating: 0, count: 4), count = 0.0
        for row in max(0, y - 2)...min(height - 1, y + 2) {
            for column in max(0, x - 2)...min(width - 1, x + 2) {
                let index = (row * width + column) * 4
                guard pixels[index + 3] >= 240 else { continue }
                for channel in 0..<4 { totals[channel] += Double(pixels[index + channel]) / 255 }
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (totals[0] / count, totals[1] / count, totals[2] / count, totals[3] / count)
    }
    /// Pixel work and image construction are completed by the analyzer. SwiftUI
    /// can redraw the inspector or toggle warnings without scanning the image.
    func clippingImage(shadows: Bool, highlights: Bool) -> CGImage? {
        switch (shadows, highlights) {
        case (true, true): clippingImages.combined
        case (true, false): clippingImages.shadows
        case (false, true): clippingImages.highlights
        default: nil
        }
    }
}

/// CGImages and their providers are immutable after construction on the worker.
struct DevelopClippingImages: @unchecked Sendable {
    let shadows: CGImage?
    let highlights: CGImage?
    let combined: CGImage?
    static let empty = Self(shadows: nil, highlights: nil, combined: nil)
}

actor DevelopPreviewAnalyzer {
    func analyze(_ bitmap: PreviewBitmap) throws -> DevelopPreviewAnalysis {
        try Task.checkCancellation()
        let image = bitmap.image
        let scale = min(1, 384.0 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let result = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard result else { throw EditRenderError.unavailable }
        var channels = [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3)
        var shadows = 0, highlights = 0
        var shadowPixels = [UInt8](repeating: 0, count: bytes.count)
        var highlightPixels = shadowPixels
        var combinedPixels = shadowPixels
        for row in 0..<height {
            try Task.checkCancellation()
            for column in 0..<width {
                let index = (row * width + column) * 4
                let alpha = Int(bytes[index + 3])
                guard alpha > 0 else { continue }
                for channel in 0..<3 {
                    bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
                    channels[channel][Int(bytes[index + channel]) / 2] += 1
                }
                let maximum = max(bytes[index], max(bytes[index + 1], bytes[index + 2]))
                if maximum <= 1 {
                    shadows += 1
                    shadowPixels[index + 2] = 255; shadowPixels[index + 3] = 180
                    combinedPixels[index + 2] = 255; combinedPixels[index + 3] = 180
                }
                if maximum >= 254 {
                    highlights += 1
                    highlightPixels[index] = 255; highlightPixels[index + 3] = 180
                    combinedPixels[index] = 255; combinedPixels[index + 3] = 180
                }
            }
        }
        try Task.checkCancellation()
        let shadowImage = shadows > 0 ? clippingImage(shadowPixels, width: width, height: height) : nil
        let highlightImage = highlights > 0 ? clippingImage(highlightPixels, width: width, height: height) : nil
        let combinedImage = shadows == 0 ? highlightImage : highlights == 0 ? shadowImage
            : clippingImage(combinedPixels, width: width, height: height)
        try Task.checkCancellation()
        return DevelopPreviewAnalysis(width: width, height: height, pixels: bytes, channels: channels,
            shadows: shadows, highlights: highlights,
            clippingImages: .init(shadows: shadowImage, highlights: highlightImage, combined: combinedImage))
    }
    private func clippingImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

typealias DevelopPreviewSink = @MainActor (PreviewRequest, EditSettings, PreviewBitmap, PreviewBitmap) -> Void
private struct DevelopPreviewSinkKey: EnvironmentKey {
    static let defaultValue: DevelopPreviewSink? = nil
}
extension EnvironmentValues {
    var developPreviewSink: DevelopPreviewSink? {
        get { self[DevelopPreviewSinkKey.self] }
        set { self[DevelopPreviewSinkKey.self] = newValue }
    }
}

struct DevelopHistogram: View {
    @ObservedObject var workspace: DevelopWorkspace
    let asset: PhotoAsset
    @ObservedObject var library: LibraryModel
    var allowsComparison = true
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(workspace.hdrDisplayed ? "Histogramm · SDR-Vorschau" : "Histogramm").font(.system(size: 12, weight: .semibold))
                Spacer()
                if workspace.isAnalyzing { ProgressView().controlSize(.mini) }
            }
            ZStack(alignment: .top) {
                Canvas { context, size in
                    guard let analysis = workspace.analysis else { return }
                    let colors: [Color] = [.red, .green, .blue]
                    let peak = max(1, analysis.channels.flatMap { $0 }.max() ?? 1)
                    for channel in 0..<3 {
                        var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                        for (bin, count) in analysis.channels[channel].enumerated() {
                            let value = log1p(Double(count)) / log1p(Double(peak))
                            path.addLine(to: CGPoint(x: Double(bin) / 127 * size.width, y: (1 - value) * size.height))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                        context.blendMode = .plusLighter
                        context.fill(path, with: .color(colors[channel].opacity(0.45)))
                    }
                }.frame(height: 80).background(Color.black.opacity(0.25))
                HStack {
                    clipButton("Schattenwarnung", symbol: "triangle.fill", active: $workspace.showsShadows, count: workspace.analysis?.shadows ?? 0, color: .blue)
                    Spacer()
                    clipButton("Lichterwarnung", symbol: "triangle.fill", active: $workspace.showsHighlights, count: workspace.analysis?.highlights ?? 0, color: .red)
                }.padding(5)
            }.overlay(Rectangle().stroke(Theme.line))
                .accessibilityLabel("RGB-Histogramm der aktuellen Vorschau")
            HStack(spacing: 5) {
                Text(asset.iso.map { "ISO \($0)" } ?? "ISO —")
                Spacer(minLength: 0); Text(asset.focalLength ?? "— mm")
                Spacer(minLength: 0); Text(asset.aperture ?? "ƒ —")
                Spacer(minLength: 0); Text(asset.shutterSpeed ?? "— s")
            }.font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
            Toggle("Originalfoto", isOn: $library.comparesOriginal).toggleStyle(.checkbox).disabled(!allowsComparison)
                .font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(8).background(Theme.panel)
    }
    private func clipButton(_ title: String, symbol: String, active: Binding<Bool>, count: Int, color: Color) -> some View {
        Button { active.wrappedValue.toggle() } label: {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(active.wrappedValue ? color : count > 0 ? Color.white : Theme.muted)
                .frame(width: 20, height: 18).background(.black.opacity(0.7))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityValue(active.wrappedValue ? "Ein" : "Aus")
    }
}
