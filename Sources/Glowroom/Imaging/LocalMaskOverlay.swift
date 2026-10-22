import AppKit
import CoreImage
import GlowroomCore

struct LocalMaskOverlayRequest: Equatable, Sendable {
    let source: AISourceIdentity
    let canvas: ArtifactPixelSize
    let layerID: UUID
    let mask: LocalAdjustmentMask

    func sharesCanvas(with other: Self) -> Bool {
        source == other.source && canvas == other.canvas && layerID == other.layerID
    }
}

/// Keep drawing responsive even when pointer events arrive faster than a frame
/// can render. One in-flight frame and one replaceable pending frame bound work.
@MainActor
final class LocalMaskOverlayModel: ObservableObject {
    typealias Renderer = @Sendable (LocalMaskOverlayRequest) async throws -> CGImage
    @Published private(set) var image: CGImage?
    @Published private(set) var errorMessage: String?
    private let renderer: Renderer
    private var latest: LocalMaskOverlayRequest?
    private var pending: LocalMaskOverlayRequest?
    private var worker: Task<Void, Never>?
    private var rendering: Task<CGImage, Error>?
    private var generation = UUID()

    init(renderer: @escaping Renderer = { request in
        try await LocalMaskOverlayWorker.shared.image(request.mask, size: request.canvas)
    }) {
        self.renderer = renderer
    }

    func update(_ request: LocalMaskOverlayRequest?) {
        guard request != latest else { return }
        if request == nil || latest.map({ request?.sharesCanvas(with: $0) != true }) != false {
            generation = UUID()
            rendering?.cancel()
            image = nil
            errorMessage = nil
        }
        latest = request
        pending = request
        guard request != nil, worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let request = self.pending {
                self.pending = nil
                let generation = self.generation
                let renderer = self.renderer
                let rendering = Task { try await renderer(request) }
                self.rendering = rendering
                do {
                    let image = try await rendering.value
                    // A same-canvas frame remains useful while newer input is
                    // pending. Serial completion cannot replace a newer frame,
                    // and continuous drawing never starves the visible overlay.
                    if generation == self.generation {
                        self.image = image
                        self.errorMessage = nil
                    }
                } catch is CancellationError { }
                catch {
                    if generation == self.generation, self.latest == request {
                        self.errorMessage = error.localizedDescription
                    }
                }
                self.rendering = nil
            }
            self.worker = nil
        }
    }

    func waitForRendering() async {
        while let worker { await worker.value }
    }
}

actor LocalMaskOverlayWorker {
    static let shared = LocalMaskOverlayWorker()
    static let maximumDimension = 1_600
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let maskCache: LocalMaskImageCache?
    private let alphaKernel = CIColorKernel(source: """
        kernel vec4 maskOverlay(__sample mask) {
            float weight = clamp(mask.r, 0.0, 1.0);
            return vec4(weight, 0.0, 0.0, weight);
        }
        """)

    init(enableIncrementalCaching: Bool = true) {
        maskCache = enableIncrementalCaching ? LocalMaskImageCache() : nil
    }

    func image(_ mask: LocalAdjustmentMask, size: ArtifactPixelSize) throws -> CGImage {
        try Task.checkCancellation()
        // The overlay is display-only. Keep its geometry aspect-preserving and
        // its bitmap bounded independently of the camera's native resolution.
        let factor = min(1, Double(Self.maximumDimension) / Double(max(size.width, size.height)))
        let width = max(1, Int((Double(size.width) * factor).rounded()))
        let height = max(1, Int((Double(size.height) * factor).rounded()))
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let image = try PipelineTrace.measure(.maskOverlayGraph) {
            let scalar = try LocalAdjustmentRenderer.maskImage(mask, extent: extent, cache: maskCache)
            guard let image = alphaKernel?.apply(extent: extent, arguments: [scalar]) else { throw EditRenderError.unavailable }
            return image
        }
        let bitmap = try PipelineTrace.measure(.maskOverlayImage) {
            // Materialize here on the serial background actor, never lazily
            // when SwiftUI draws the bitmap on the main thread.
            guard let bitmap = context.createCGImage(image, from: extent, format: .RGBA8,
                colorSpace: nil, deferred: false) else { throw EditRenderError.unavailable }
            return bitmap
        }
        try Task.checkCancellation()
        return bitmap
    }
}
