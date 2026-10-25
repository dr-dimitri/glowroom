import AppKit
import SwiftUI
import GlowroomCore

/// Pointer positions only invalidate the loupe. Publishing them on the shared
/// workspace would rebuild LibraryView, both inspectors and the photo canvas
/// for every movement. These few UI scalars stay ordered on the main actor.
@MainActor
final class DevelopDetailPosition: ObservableObject {
    @Published var center = CGPoint(x: 0.5, y: 0.5)
}

/// A single workspace owns the active canvas tool; pixels are observed after
/// the normal preview pipeline, so histogram and picker never decode a RAW.
@MainActor
final class DevelopWorkspace: ObservableObject {
    @Published var tool: DevelopCanvasTool = .basic {
        didSet {
            if oldValue != tool { cancelAutomaticTone(); endLevelsPicker(); picksDetail = false }
            if oldValue.isRepairTool && oldValue != tool { cancelRepairWork(); repairSpotImage = nil }
        }
    }
    @Published var picksWhiteBalance = false {
        didSet { if picksWhiteBalance { picksDetail = false; endLevelsPicker() } }
    }
    @Published var picksDetail = false {
        didSet { if picksDetail { picksWhiteBalance = false; endLevelsPicker() } }
    }
    @Published var levelsPicker: DevelopLevelsPickerSelection?
    @Published var levelsDisplay: DevelopPreviewHandoff?
    @Published var levelsSampleDescription: String?
    @Published var automaticLevelsBusy = false
    var levelsTask: Task<Void, Never>?
    var levelsRequest = UUID()
    let detailPosition = DevelopDetailPosition()
    let photoViewport = PhotoViewportState()
    @Published var aiCorrectionPreview: AICorrectionPreview?
    @Published var showsAICorrectionProposal = true
    @Published var previewReloadID = UUID()
    @Published private(set) var isFinalPreviewReady = false
    var detailCenter: CGPoint {
        get { detailPosition.center }
        set { if detailPosition.center != newValue { detailPosition.center = newValue } }
    }
    @Published var detailMagnification = 1.0
    @Published var detailFitsImage = false
    @Published var showsShadows = false
    @Published var showsHighlights = false
    @Published var cropAspect = "free"
    @Published var isStraightening = false
    @Published var cropAspectLocked = false
    var lockedCropRatio: Double?
    @Published private(set) var isAutoStraightening = false
    @Published private(set) var sourceSize: CGSize?
    @Published private(set) var displayedMapping: DevelopCanvasMapping?
    @Published private(set) var hdrDisplayed = false
    var isOriginalCanvasReady: Bool { sourceIdentity != nil && displayedMapping == .original }
    func isCropCanvasReady(for optics: DevelopOpticsSettings) -> Bool {
        guard sourceIdentity != nil, let displayedMapping, displayedMapping.optics == optics else { return false }
        // A new slider value cannot accept crop input over an older optical
        // frame. The source tools keep their stricter identity-canvas gate.
        return displayedMapping == .original || displayedMapping.isCompleteOpticalCanvas
    }
    func markDisplayed(source: AISourceIdentity, settings: EditSettings) {
        guard source == sourceIdentity else { return }
        let mapping = DevelopCanvasMapping(settings.developGeometry)
        if let displayedMapping, displayedMapping != mapping {
            detailCenter = CGPoint(x: 0.5, y: 0.5)
            picksDetail = false
        }
        displayedMapping = mapping
        hdrDisplayed = settings.developColor.hdrEnabled
    }
    @Published var repairMode: DevelopRepairMode = .remove
    @Published var repairRadius = 0.035
    @Published var repairFeather = 0.5
    @Published var redEyeStrength = 1.0
    @Published var repairSource: LocalMaskPoint?
    @Published var repairChoosesSource = false
    @Published var repairSelectedStrokeID: UUID?
    // Small details often belong to a much larger foreground instance (a berry
    // to a whole tree). Keep the painted footprint unless explicitly requested.
    @Published var repairObjectDetection = false
    @Published var repairOverlay: DevelopRepairOverlay = .always
    @Published var repairVisualizesSpots = false { didSet { refreshRepairVisualization() } }
    @Published var repairSpotThreshold = 0.5 { didSet { refreshRepairVisualization() } }
    @Published var repairCandidates: [DevelopRepairCandidate] = []
    @Published var repairSelectedCandidateIDs: Set<UUID> = []
    @Published var repairBusy = false
    @Published var repairStatus: String?
    @Published var repairSpotImage: CGImage?
    @Published var repairUsesAI = false
    @Published var repairAIReady = false
    @Published var repairAIModelName: String?
    @Published var repairAISetupProgress: SkyMaskSetupProgress?
    var repairTriedSourceStrokeID: UUID?
    var repairTriedSources: [LocalMaskPoint] = []
    var repairTask: Task<Void, Never>?
    var repairSpotTask: Task<Void, Never>?
    var repairRequest = UUID()
    var repairAIAvailabilityRequest = UUID()
    let repairInputQueue = DevelopRepairInputQueue()
    var repairDisplayBitmap: PreviewBitmap?
    let repairServices: DevelopRepairServices
    let repairAIStore: DevelopRepairAIModelStore
    /// Reuse the accepted preview frame; the navigator never requests another decode.
    @Published private(set) var navigatorImage: CGImage?
    @Published private(set) var analysis: DevelopPreviewAnalysis?
    @Published var scopePreferences: DevelopScopePreferences {
        didSet {
            if let data = try? JSONEncoder().encode(scopePreferences) { scopeDefaults.set(data, forKey: DevelopScopePreferences.key) }
            if oldValue.mode != scopePreferences.mode { refreshScope() }
        }
    }
    @Published private(set) var spatialScope: DevelopSpatialScope?
    private let scopeDefaults: UserDefaults
    private var scopeTask: Task<Void, Never>?
    private var scopeIdentity = UUID()
    typealias ReduceScope = @Sendable (DevelopPreviewAnalysis) async throws -> DevelopSpatialScope
    private let reduceScope: ReduceScope
    @Published private(set) var isAnalyzing = false
    @Published private(set) var sourceAnalysis: DevelopPreviewAnalysis?
    private var baseIdentity: ObjectIdentifier?
    private(set) var sourceIdentity: AISourceIdentity?
    @Published var errorMessage: String?
    private var analysisTask: Task<Void, Never>?
    private var autoStraightenTask: Task<Double?, Error>?
    private var autoStraightenIdentity = UUID()
    var automaticToneTask: Task<Void, Never>?
    var automaticToneIdentity = UUID()
    private(set) var originalBitmap: PreviewBitmap?
    private(set) var originalSourceStamp: ImageAnalysisSourceStamp?
    private var identity = UUID()
    typealias Analyze = @Sendable (PreviewBitmap) async throws -> DevelopPreviewAnalysis
    typealias EstimateHorizon = @Sendable (PreviewBitmap) async throws -> Double?
    typealias EstimateTone = @Sendable (AutomaticToneControl, PreviewBitmap, EditSettings) async throws -> AutomaticToneEstimate
    typealias SampleLevels = @Sendable (PreviewBitmap, EditSettings, CGPoint) async throws -> LevelsSampleReport
    typealias EstimateLevels = @Sendable (PreviewBitmap, PreviewBitmap, EditSettings) async throws -> AutomaticLevelsEstimate
    typealias ValidateLevels = @Sendable (PreviewBitmap, EditSettings, LevelsPickerSample?) async throws -> Void
    private let analyze: Analyze
    private let estimateHorizon: EstimateHorizon
    let estimateTone: EstimateTone
    let sampleLevels: SampleLevels
    let validateLevels: ValidateLevels
    let estimateLevels: EstimateLevels

    init(analyze: Analyze? = nil, estimateHorizon: EstimateHorizon? = nil, estimateTone: EstimateTone? = nil,
         sampleLevels: SampleLevels? = nil,
         validateLevels: ValidateLevels? = nil, estimateLevels: EstimateLevels? = nil,
         repairServices: DevelopRepairServices = .live, repairAIStore: DevelopRepairAIModelStore = .shared,
         scopeDefaults: UserDefaults = .standard, reduceScope: ReduceScope? = nil) {
        self.scopeDefaults = scopeDefaults
        self.scopePreferences = scopeDefaults.data(forKey: DevelopScopePreferences.key)
            .flatMap { try? JSONDecoder().decode(DevelopScopePreferences.self, from: $0) } ?? .init()
        let scopeWorker = DevelopScopeReducer()
        self.reduceScope = reduceScope ?? { try await scopeWorker.reduce($0) }
        self.repairServices = repairServices
        self.repairAIStore = repairAIStore
        self.estimateHorizon = estimateHorizon ?? { try await DevelopHorizonEstimator.shared.estimate($0) }
        self.estimateTone = estimateTone ?? { try await AutomaticToneEstimator.shared.estimate(for: $0, bitmap: $1, settings: $2) }
        self.sampleLevels = sampleLevels ?? { try await AutomaticToneEstimator.shared.sampleLevels(bitmap: $0, settings: $1, normalizedTopLeft: $2) }
        self.estimateLevels = estimateLevels ?? { try await AutomaticToneEstimator.shared.estimateLevels(bitmap: $0, sourceBitmap: $1, settings: $2) }
        self.validateLevels = validateLevels ?? { try await AutomaticToneEstimator.shared.validateLevels(bitmap: $0, settings: $1, neutralGraySample: $2) }
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
    func receive(_ bitmap: PreviewBitmap, sourceBitmap: PreviewBitmap, sourceStamp: ImageAnalysisSourceStamp? = nil,
                 finalSourceReady: Bool = true) {
        isFinalPreviewReady = finalSourceReady
        navigatorImage = bitmap.image
        repairDisplayBitmap = bitmap
        if tool == .repair && repairVisualizesSpots { refreshRepairVisualization() }
        sourceSize = CGSize(width: sourceBitmap.image.width, height: sourceBitmap.image.height)
        let baseID = ObjectIdentifier(sourceBitmap.image)
        if originalBitmap.map({ ObjectIdentifier($0.image) }) != baseID {
            cancelAutoStraighten()
            cancelAutomaticTone()
        }
        originalBitmap = sourceBitmap
        originalSourceStamp = sourceStamp
        let needsBase = baseIdentity != baseID || sourceAnalysis == nil
        if needsBase { sourceAnalysis = nil }
        analysisTask?.cancel()
        analysis = nil; invalidateScope()
        let token = UUID(); identity = token; isAnalyzing = true
        analysisTask = Task { [weak self, analyze] in
            do {
                let result = try await analyze(bitmap)
                try Task.checkCancellation()
                let base = needsBase ? try await analyze(sourceBitmap) : nil
                try Task.checkCancellation()
                guard let self, !Task.isCancelled, self.identity == token else { return }
                self.analysis = result; self.isAnalyzing = false; self.analysisTask = nil
                self.invalidateScope(); self.refreshScope()
                if let base { self.sourceAnalysis = base; self.baseIdentity = baseID }
            } catch is CancellationError { }
            catch { if let self, self.identity == token { self.isAnalyzing = false; self.analysisTask = nil } }
        }
    }
    private func invalidateScope() {
        scopeIdentity = UUID(); scopeTask?.cancel(); scopeTask = nil; spatialScope = nil
    }
    private func refreshScope() {
        guard scopePreferences.mode != .histogram else { invalidateScope(); return }
        guard spatialScope == nil, scopeTask == nil, let analysis else { return }
        let token = UUID(); scopeIdentity = token
        scopeTask = Task { [weak self, reduceScope] in
            do {
                let result = try await reduceScope(analysis)
                try Task.checkCancellation()
                guard let self, self.scopeIdentity == token else { return }
                self.spatialScope = result; self.scopeTask = nil
            } catch {
                guard let self, self.scopeIdentity == token else { return }
                self.scopeTask = nil
            }
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
    /// Uses the decoded original already held by the preview pipeline. The
    /// shared actor bounds native analysis; source/base guards reject a late
    /// result after a photo or decoded source changes.
    func autoStraighten() async -> Double? {
        guard !isAutoStraightening, let bitmap = originalBitmap, let source = sourceIdentity else { return nil }
        let baseID = ObjectIdentifier(bitmap.image), token = UUID()
        autoStraightenIdentity = token; isAutoStraightening = true; errorMessage = nil
        let task = Task { [estimateHorizon] in try await estimateHorizon(bitmap) }
        autoStraightenTask = task
        defer {
            if autoStraightenIdentity == token { isAutoStraightening = false; autoStraightenTask = nil }
        }
        do {
            let angle = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard autoStraightenIdentity == token, sourceIdentity == source,
                  originalBitmap.map({ ObjectIdentifier($0.image) }) == baseID else { return nil }
            guard let angle else {
                errorMessage = "Es wurde kein verlässlicher Horizont erkannt. Stelle den Winkel manuell ein."
                return nil
            }
            return angle
        } catch is CancellationError { return nil }
        catch {
            if autoStraightenIdentity == token, !Task.isCancelled, !task.isCancelled {
                errorMessage = "Der Horizont konnte nicht automatisch ausgerichtet werden. Stelle den Winkel manuell ein."
            }
            return nil
        }
    }
    private func cancelAutoStraighten() {
        autoStraightenIdentity = UUID(); autoStraightenTask?.cancel(); autoStraightenTask = nil
        isAutoStraightening = false
    }
    func clear() {
        aiCorrectionPreview = nil
        showsAICorrectionProposal = true
        isFinalPreviewReady = false
        photoViewport.reset()
        endLevelsPicker(); levelsDisplay = nil; levelsSampleDescription = nil
        cancelAutomaticTone()
        cancelRepairWork(); repairSpotTask?.cancel(); repairSpotTask = nil
        repairDisplayBitmap = nil; repairSpotImage = nil; repairStatus = nil
        identity = UUID(); analysisTask?.cancel(); analysisTask = nil
        invalidateScope()
        cancelAutoStraighten(); originalBitmap = nil; originalSourceStamp = nil
        displayedMapping = nil; hdrDisplayed = false
        navigatorImage = nil
        analysis = nil; sourceAnalysis = nil; sourceSize = nil; baseIdentity = nil; sourceIdentity = nil; isAnalyzing = false; repairSource = nil
        picksWhiteBalance = false; picksDetail = false
        detailCenter = CGPoint(x: 0.5, y: 0.5)
        detailFitsImage = false
        tool = .basic; errorMessage = nil
        cropAspect = "free"; cropAspectLocked = false; lockedCropRatio = nil; isStraightening = false
    }

    func markPreviewPending(_ identity: DevelopPreviewRenderIdentity) {
        if !identity.finalSourceReady { isFinalPreviewReady = false }
    }
}

/// Only spatial presentation controls input readiness. Tone/brush updates may
/// keep the preceding frame while the next render is coalesced.
struct DevelopCanvasMapping: Hashable {
    let crop: DevelopCropRect?
    let turns: Int
    let flipsX: Bool
    let flipsY: Bool
    let angle: Double
    let constrainsToImage: Bool
    let optics: DevelopOpticsSettings
    init(_ geometry: DevelopGeometry) {
        crop = geometry.crop; turns = geometry.quarterTurns
        flipsX = geometry.flipHorizontal; flipsY = geometry.flipVertical
        angle = geometry.straightenAngle; constrainsToImage = geometry.constrainToImage
        optics = geometry.optics
    }
    var isCompleteOpticalCanvas: Bool {
        crop == nil && turns == 0 && !flipsX && !flipsY && angle == 0 && !constrainsToImage
    }
    static let original = Self(.neutral)
}

enum DevelopCanvasTool: String, CaseIterable, Identifiable {
    case basic, crop, repair, redEye, masks
    /// Red-eye input keeps its coordinate/history identity inside the single repair entry.
    static let toolbarCases: [Self] = [.basic, .crop, .repair, .masks]
    var isRepairTool: Bool { self == .repair || self == .redEye }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .basic: "Anpassen"
        case .crop: "Zuschneiden"
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
        guard width > 0, height > 0, width <= 384, height <= 384, pixels.count == width * height * 4,
              point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
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
        var channels = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
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
                    // Exact integer alpha mass: 255 units represent one opaque pixel.
                    channels[channel][Int(bytes[index + channel])] += alpha
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

typealias DevelopPreviewSink = @MainActor (DevelopPreviewHandoff) -> Void
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
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Picker("Anzeige", selection: $workspace.scopePreferences.mode) {
                    ForEach(DevelopScopeMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
                    .accessibilityLabel("Scope-Anzeige")
                    .accessibilityValue(workspace.scopePreferences.mode.title)
                Spacer(minLength: 0)
                if workspace.isAnalyzing { ProgressView().controlSize(.mini) }
                clipButton("Schattenwarnung", symbol: "triangle.fill", active: $workspace.showsShadows, count: workspace.analysis?.shadows ?? 0, color: .blue)
                clipButton("Lichterwarnung", symbol: "triangle.fill", active: $workspace.showsHighlights, count: workspace.analysis?.highlights ?? 0, color: .red)
            }
            HStack(spacing: 4) {
                ForEach(0..<3) { channel in
                    Toggle(["R", "G", "B"][channel], isOn: Binding(
                        get: { workspace.scopePreferences.channelMask & (1 << channel) != 0 },
                        set: { enabled in
                            if enabled { workspace.scopePreferences.channelMask |= 1 << channel }
                            else { workspace.scopePreferences.channelMask &= ~(1 << channel) }
                        }))
                        .toggleStyle(.button).controlSize(.mini)
                        .accessibilityLabel(["Rot", "Grün", "Blau"][channel] + " anzeigen")
                }
                Spacer(minLength: 0)
            }
            Picker("Zählerskala", selection: $workspace.scopePreferences.scale) {
                ForEach(DevelopScopeScale.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).controlSize(.mini)
                .help("Nur Höhe bzw. Dichte der alpha-gewichteten Häufigkeit. Die Kanalwerte bleiben sRGB-Codewerte. Gemeinsames Maximum der sichtbaren Kanäle.")
            ZStack(alignment: .top) {
                HStack(spacing: 2) {
                    if workspace.scopePreferences.mode != .histogram {
                        VStack { Text("100 %"); Spacer(); Text("50 %"); Spacer(); Text("0 %") }
                            .font(.system(size: 8)).foregroundStyle(Theme.muted).frame(width: 30)
                    }
                    DevelopScopePlot(analysis: workspace.analysis, spatial: workspace.spatialScope,
                                     preferences: workspace.scopePreferences)
                        .overlay {
                            if workspace.scopePreferences.mode != .histogram {
                                VStack { Divider(); Spacer(); Divider(); Spacer(); Divider() }.allowsHitTesting(false)
                            }
                        }
                }.frame(height: 96)
            }.overlay(Rectangle().stroke(Theme.line))
            HStack {
                if workspace.scopePreferences.mode == .parade {
                    ForEach(["R", "G", "B"], id: \.self) { Text($0).frame(maxWidth: .infinity) }
                } else {
                    Text("0 %"); Spacer(); Text("50 %"); Spacer(); Text("100 %")
                }
            }.font(.system(size: 8)).foregroundStyle(Theme.muted)
            HStack(spacing: 5) {
                Text(asset.iso.map { "ISO \($0)" } ?? "ISO —")
                Spacer(minLength: 0); Text(asset.focalLength ?? "— mm")
                Spacer(minLength: 0); Text(asset.aperture ?? "ƒ —")
                Spacer(minLength: 0); Text(asset.shutterSpeed ?? "— s")
            }.font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
        }.padding(8).background(Theme.panel)
    }
    private func clipButton(_ title: String, symbol: String, active: Binding<Bool>, count: Int, color: Color) -> some View {
        Button { active.wrappedValue.toggle() } label: {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(active.wrappedValue ? color : count > 0 ? Color.white : Theme.muted)
                .frame(width: 20, height: 18).background(.black.opacity(0.7))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityValue(active.wrappedValue ? "Ein" : "Aus")
    }
}
