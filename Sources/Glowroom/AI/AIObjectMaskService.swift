import CoreGraphics
import Foundation
import GlowroomCore

struct AIObjectMaskResponse: Sendable {
    let layer: LocalAdjustment
    let sourceStamp: ImageAnalysisSourceStamp
    let summary: String
    let preview: PreviewBitmap?
}

/// Uses the existing local Qwen installation and shared inference admission.
/// No catalog write occurs here: the caller reviews and accepts the frozen mask.
struct AIObjectMaskService: Sendable {
    typealias Infer = @Sendable (CGImage, String, String) async throws -> Data
    typealias Segment = @Sendable (PreviewBitmap) async throws -> LocalMaskRaster
    let preparer: any ImageAnalysisPreparing
    private let budget: AIResourceBudget
    private let infer: Infer
    private let segment: Segment
    private let checksSubjectInstallation: Bool

    init(store: LLMModelStore = .shared, budget: AIResourceBudget = .shared,
         preparer: any ImageAnalysisPreparing = ImageAnalysisPreparer(), infer: Infer? = nil, segment: Segment? = nil) {
        self.preparer = preparer; self.budget = budget
        self.checksSubjectInstallation = segment == nil
        self.segment = segment ?? { try await AutomaticMaskService.shared.generate($0, kind: .subject) }
        self.infer = infer ?? { image, prompt, schema in
            try await store.withModel { model in
                try await QwenDevelopmentBackend().propose(modelDirectory: model.directory,
                    image: image, prompt: prompt, schema: schema, suppressesWhitespaceRuns: true)
            }
        }
    }

    /// The snapshot retains accepted color, local corrections and repairs, but
    /// renders the full source before crop, straightening, rotation or mirroring.
    /// Model coordinates therefore match the persisted mask coordinate space.
    static func preparationRequest(snapshot: AIEditingSnapshot) -> ImageAnalysisRequest {
        var settings = snapshot.settings
        settings.developGeometry = DevelopGeometry(retouchStrokes: settings.developGeometry.retouchStrokes,
            redEyeCorrections: settings.developGeometry.redEyeCorrections)
        let fullSource = AIEditingSnapshot(assetID: snapshot.assetID, source: snapshot.source,
            settings: settings, token: snapshot.token, persistedVersion: snapshot.persistedVersion)
        // editedPreview supports both originals and immutable generated sources.
        return ImageAnalysisRequest(snapshot: fullSource, inputKind: .editedPreview, lifecycleID: UUID())
    }

    func propose(snapshot: AIEditingSnapshot, instruction: String) async throws -> AIObjectMaskResponse {
        let prompt = try AIObjectMaskProposal.prompt(instruction: instruction)
        try snapshot.validate()
        guard snapshot.settings.localAdjustments.count < LocalAdjustment.maximumCount else { throw AIObjectMaskError.maskLimit }
        if checksSubjectInstallation, try await SubjectMattingModelStore.shared.installedModel() == nil {
            throw SubjectMattingError.modelNotInstalled
        }
        let request = Self.preparationRequest(snapshot: snapshot)
        let input = try await preparer.prepare(request)
        let lease = try await budget.acquireLocalInference(priority: .interactive,
            residentBytes: 5 * 1_024 * 1_024 * 1_024)
        let proposal: AIObjectMaskProposal
        do {
            let bytes = try await infer(input.bitmap.image, prompt, AIObjectMaskProposal.schema)
            try Task.checkCancellation()
            proposal = try AIObjectMaskProposal.decode(bytes)
            // Cancellation never releases admission before native work returns.
            await budget.release(lease)
        } catch {
            await budget.release(lease)
            throw error
        }
        try Task.checkCancellation()
        guard try await preparer.sourceStamp(for: request) == input.sourceStamp else { throw AIDevelopmentError.staleContext }
        let crop = try AIObjectMaskProjection.crop(input.bitmap, bounds: proposal.bounds)
        // The language-model lease has returned before BiRefNet acquires its
        // own shared admission; overlapping both native models would deadlock
        // the single inference lane and unnecessarily retain their working sets.
        let matte = try await segment(crop.bitmap)
        try Task.checkCancellation()
        let raster = try AIObjectMaskProjection.project(matte, from: crop.rect,
            width: input.bitmap.image.width, height: input.bitmap.image.height)
        let layer = try LocalAdjustment(name: proposal.name,
            mask: LocalAdjustmentMask(shape: .subject(raster), feather: 0), settings: .neutral)
        var candidate = snapshot.settings
        candidate.localAdjustments.append(layer)
        do { _ = try EditingSnapshot(settings: candidate) }
        catch { throw AIObjectMaskError.maskLimit }
        let preview = try await Self.preview(input.bitmap, mask: layer.mask)
        guard try await preparer.sourceStamp(for: request) == input.sourceStamp else { throw AIDevelopmentError.staleContext }
        try Task.checkCancellation()
        return AIObjectMaskResponse(layer: layer, sourceStamp: input.sourceStamp,
            summary: proposal.summary, preview: preview)
    }

    private static func preview(_ bitmap: PreviewBitmap, mask: LocalAdjustmentMask) async throws -> PreviewBitmap {
        let width = bitmap.image.width, height = bitmap.image.height
        let overlay = try await LocalMaskOverlayWorker.shared.image(mask,
            size: ArtifactPixelSize(width: width, height: height))
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditRenderError.unavailable }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(bitmap.image, in: rect)
        context.setAlpha(0.45)
        context.draw(overlay, in: rect)
        guard let image = context.makeImage() else { throw EditRenderError.unavailable }
        return PreviewBitmap(image: image, sourceLongEdge: bitmap.sourceLongEdge)
    }
}

/// Qwen only locates the crop. The persisted coverage comes exclusively from
/// the subject model's matte, never from filling the proposed rectangle.
/// The bounded CPU reprojection preserves top-left coordinates and fractional
/// edges. Its at most 1024 rows do not justify another nested worker pool.
enum AIObjectMaskProjection {
    struct Crop: Sendable {
        let bitmap: PreviewBitmap
        let rect: CGRect
    }

    static func crop(_ bitmap: PreviewBitmap, bounds: DevelopCropRect) throws -> Crop {
        try Task.checkCancellation()
        let image = bitmap.image
        let padX = bounds.width * 0.05, padY = bounds.height * 0.05
        let left = floor(max(0, bounds.x - padX) * Double(image.width))
        let top = floor(max(0, bounds.y - padY) * Double(image.height))
        let right = ceil(min(1, bounds.x + bounds.width + padX) * Double(image.width))
        let bottom = ceil(min(1, bounds.y + bounds.height + padY) * Double(image.height))
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
            throw AIObjectMaskError.invalidResponse
        }
        // CGImage crops may share their parent's backing storage. Retain the
        // same memory reservation if the shared subject cache keeps this crop.
        return Crop(bitmap: PreviewBitmap(image: cropped, sourceLongEdge: bitmap.sourceLongEdge,
            memoryOwnership: bitmap.memoryOwnership, resourceOwner: bitmap.resourceOwner), rect: rect)
    }

    static func project(_ matte: LocalMaskRaster, from rect: CGRect, width: Int, height: Int) throws -> LocalMaskRaster {
        try Task.checkCancellation()
        guard width > 0, height > 0, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.minX >= 0, rect.minY >= 0,
              rect.width >= 1, rect.height >= 1, rect.maxX <= Double(width), rect.maxY <= Double(height) else {
            throw AIObjectMaskError.invalidResponse
        }
        let size = AutomaticMaskRasterConverter.outputSize(width: width, height: height, maximumDimension: 1_024)
        var bytes = Data(count: size.width * size.height)
        var hasCoverage = false
        try bytes.withUnsafeMutableBytes { storage in
            let output = storage.bindMemory(to: UInt8.self)
            for y in 0..<size.height {
                try Task.checkCancellation()
                let sourceY = (Double(y) + 0.5) * Double(height) / Double(size.height)
                guard sourceY >= rect.minY, sourceY < rect.maxY else { continue }
                let py = min(Double(matte.height - 1), max(0,
                    (sourceY - rect.minY) * Double(matte.height) / rect.height - 0.5))
                let y0 = Int(py), y1 = min(y0 + 1, matte.height - 1), fy = py - Double(y0)
                for x in 0..<size.width {
                    let sourceX = (Double(x) + 0.5) * Double(width) / Double(size.width)
                    guard sourceX >= rect.minX, sourceX < rect.maxX else { continue }
                    let px = min(Double(matte.width - 1), max(0,
                        (sourceX - rect.minX) * Double(matte.width) / rect.width - 0.5))
                    let x0 = Int(px), x1 = min(x0 + 1, matte.width - 1), fx = px - Double(x0)
                    let a = Double(matte.bytes[y0 * matte.width + x0]) * (1 - fx)
                        + Double(matte.bytes[y0 * matte.width + x1]) * fx
                    let b = Double(matte.bytes[y1 * matte.width + x0]) * (1 - fx)
                        + Double(matte.bytes[y1 * matte.width + x1]) * fx
                    let value = UInt8(min(255, max(0, (a * (1 - fy) + b * fy).rounded())))
                    output[y * size.width + x] = value
                    hasCoverage = hasCoverage || value > 0
                }
            }
        }
        guard hasCoverage else { throw AIObjectMaskError.emptyMask }
        return try LocalMaskRaster(width: size.width, height: size.height, bytes: bytes)
    }
}
