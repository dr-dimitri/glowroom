import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import GlowroomCore

enum DevelopRepairAIContextError: Error, LocalizedError, Equatable, Sendable {
    case insufficientMemory
    var errorDescription: String? {
        "Die vorhandenen Reparaturen benötigen zu viel Speicher für einen weiteren lokalen KI-Schritt. Entferne einige Korrekturen oder verwende Heilen."
    }
}

/// Fixed local model work stays serial off MainActor. The shared admission is
/// retained until synchronous Core ML actually returns; cancellation discards
/// its output and never starts a second native call beside the canceled one.
actor DevelopRepairAIService {
    static let shared = DevelopRepairAIService()
    static let residentBytes: Int64 = 6 * 1_024 * 1_024 * 1_024
    static let maximumPriorGraphBytes: UInt64 = 3 * 1_024 * 1_024 * 1_024
    typealias Predictor = @Sendable (DevelopRepairAIInstallation, DevelopRepairAIPrepared) async throws -> Data
    private let store: DevelopRepairAIModelStore
    private let budget: AIResourceBudget
    private let predictor: Predictor?

    init(store: DevelopRepairAIModelStore = .shared, budget: AIResourceBudget = .shared,
         predictor: Predictor? = nil) {
        self.store = store; self.budget = budget; self.predictor = predictor
    }

    func replace(_ bitmap: PreviewBitmap, mask: LocalMaskRaster,
                 priorRepairs: [DevelopRetouchStroke] = []) async throws -> DevelopRetouchReplacement {
        try Task.checkCancellation()
        let lease = try await budget.acquireLocalInference(residentBytes: Self.residentBytes)
        do {
            guard let installation = try await store.installedModel() else { throw DevelopRepairAIError.modelNotInstalled }
            try Task.checkCancellation()
            // The already accepted repairs are model context. Materialize only
            // its small ROI, then release the lazy graph/native intermediates
            // before loading model weights. Both phases retain the same lease.
            let prepared = try autoreleasepool {
                let geometry = DevelopGeometry(retouchStrokes: priorRepairs)
                try geometry.validate()
                guard let priorBytes = DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: geometry,
                    width: bitmap.image.width, height: bitmap.image.height),
                      priorBytes <= Self.maximumPriorGraphBytes else {
                    throw DevelopRepairAIContextError.insufficientMemory
                }
                var graph: CIImage?
                if priorRepairs.contains(where: { $0.opacity > 0 }) {
                    let input = CIImage(cgImage: bitmap.image), extent = input.extent
                    // Preserve accepted operation order and immutable donor
                    // pixels, without tone, crop, rotation or red-eye edits.
                    graph = try DevelopGeometryRenderer.apply(to: input, geometry: geometry, extent: extent)
                }
                return try DevelopRepairAIPrepared(bitmap, mask: mask, graph: graph)
            }
            try Task.checkCancellation()
            var pixels: Data
            if let predictor { pixels = try await predictor(installation, prepared) }
            else { pixels = try autoreleasepool { try predict(installation, prepared) } }
            try Task.checkCancellation()
            guard pixels.count == prepared.width * prepared.height * 4 else { throw DevelopRepairAIError.unavailable }
            // The network only supplies RGB. Original alpha is independent of
            // the mask and is retained before any preview or persistent output.
            for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = prepared.rgba[index] }
            let result = try DevelopRetouchReplacement(bounds: prepared.bounds, width: prepared.width,
                height: prepared.height, rgba: pixels)
            await budget.release(lease)
            return result
        } catch {
            await budget.release(lease)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? DevelopRepairAIContextError { throw error }
            throw (error as? DevelopRepairAIError) ?? .unavailable
        }
    }

    private func predict(_ installation: DevelopRepairAIInstallation, _ prepared: DevelopRepairAIPrepared) throws -> Data {
        let stamps = try DevelopRepairAIModelStore.verifyInstallation(installation)
        // The model is scoped to this admitted operation. Retaining weights in
        // a global cache after releasing admission would undercount residency.
        let interface = try DevelopRepairAIModelInterface.load(installation.directory.appendingPathComponent("model.mlmodelc"))
        try verify(stamps)
        let mapping = try LaMaEvaluationMapping(width: prepared.width, height: prepared.height)
        let image = try LaMaEvaluationPixels.buffer(format: interface.imageFormat)
        let mask = try LaMaEvaluationPixels.buffer(format: kCVPixelFormatType_OneComponent8)
        try LaMaEvaluationPixels.fill(image, mask, pixels: prepared.rgba, weights: prepared.mask, mapping: mapping)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: image),
                                                                "mask": MLFeatureValue(pixelBuffer: mask)])
        func prediction(_ interface: DevelopRepairAIModelInterface.Loaded) throws -> Data {
            try autoreleasepool {
                let output = try interface.model.prediction(from: input)
                guard let pixels = output.featureValue(for: interface.outputName)?.imageBufferValue else {
                    throw DevelopRepairAIError.unavailable
                }
                return try LaMaEvaluationPixels.crop(pixels, mapping: mapping)
            }
        }
        let bytes: Data
        do { bytes = try prediction(interface) }
        catch {
            try Task.checkCancellation()
            // Core ML normally selects CPU fallback itself. If the all-device
            // invocation fails, try the same interface explicitly on CPU once.
            let cpu = try DevelopRepairAIModelInterface.load(installation.directory.appendingPathComponent("model.mlmodelc"),
                                                           computeUnits: .cpuOnly)
            guard cpu.imageFormat == interface.imageFormat else { throw DevelopRepairAIError.invalidModel }
            bytes = try prediction(cpu)
        }
        try Task.checkCancellation()
        try verify(stamps)
        return bytes
    }

    private func verify(_ stamps: [(URL, String)]) throws {
        for (url, stamp) in stamps {
            guard try SemanticInstallationIO.stamp(url) == stamp else { throw DevelopRepairAIError.invalidModel }
        }
    }

    /// A compact global mask freezes the complete gesture. Each capsule only
    /// visits its bounding box; the bounded scalar work avoids a nested worker
    /// pool inside the selected-image pipeline.
    nonisolated static func brushMask(path: [LocalMaskPoint], radius: Double, sourceSize: CGSize) throws -> LocalMaskRaster {
        guard !path.isEmpty, path.count <= DevelopRetouchStroke.maximumPathPoints,
              radius.isFinite, (0.000_001...0.5).contains(radius),
              sourceSize.width.isFinite, sourceSize.height.isFinite, sourceSize.width > 0, sourceSize.height > 0,
              sourceSize.width <= 65_536, sourceSize.height <= 65_536 else {
            throw DevelopRepairAIError.invalidMask
        }
        let scale = min(1, 256 / max(sourceSize.width, sourceSize.height))
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        let sourceWidth = Double(sourceSize.width), sourceHeight = Double(sourceSize.height)
        let r = radius * min(sourceWidth, sourceHeight)
        let antialias = max(sourceWidth / Double(width), sourceHeight / Double(height))
        var bytes = Data(count: width * height)
        for index in path.indices {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            let a = path[max(0, index - 1)], b = path[index]
            let ax = a.x * sourceWidth, ay = a.y * sourceHeight, bx = b.x * sourceWidth, by = b.y * sourceHeight
            let x0 = max(0, Int(floor((min(ax, bx) - r - antialias) / sourceWidth * Double(width))))
            let x1 = min(width - 1, Int(ceil((max(ax, bx) + r + antialias) / sourceWidth * Double(width))))
            let y0 = max(0, Int(floor((min(ay, by) - r - antialias) / sourceHeight * Double(height))))
            let y1 = min(height - 1, Int(ceil((max(ay, by) + r + antialias) / sourceHeight * Double(height))))
            let dx = bx - ax, dy = by - ay, square = dx * dx + dy * dy
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 {
                let px = (Double(x) + 0.5) / Double(width) * sourceWidth
                let py = (Double(y) + 0.5) / Double(height) * sourceHeight
                let t = square > 0 ? min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / square)) : 0
                let distance = hypot(px - ax - t * dx, py - ay - t * dy)
                let weight = UInt8((min(1, max(0, (r - distance) / antialias + 0.5)) * 255).rounded())
                bytes[y * width + x] = max(bytes[y * width + x], weight)
            } }
        }
        guard bytes.contains(where: { $0 >= 128 }) else { throw DevelopRepairAIError.invalidMask }
        return try LocalMaskRaster(width: width, height: height, bytes: bytes)
    }
}

/// Native source pixels are cropped, never stretched to fit the model. Padding
/// uses the already regression-tested V2 RGB/mask clamp sampler. The selection
/// must leave context and cover at most one quarter of the source mask cells.
struct DevelopRepairAIPrepared: Sendable {
    let bounds: DevelopCropRect
    let width: Int
    let height: Int
    let rgba: Data
    let mask: Data

    init(_ bitmap: PreviewBitmap, mask selection: LocalMaskRaster, graph: CIImage? = nil) throws {
        try Task.checkCancellation()
        let source = bitmap.image, sourceWidth = source.width, sourceHeight = source.height
        guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 65_536, sourceHeight <= 65_536 else {
            throw DevelopRepairAIError.invalidMask
        }
        let selected = selection.bytes.indices.filter { selection.bytes[$0] > 0 }
        guard selection.bytes.contains(where: { $0 >= 128 }) else { throw DevelopRepairAIError.invalidMask }
        guard selected.count * 4 <= selection.bytes.count else { throw DevelopRepairAIError.selectionTooLarge }
        let minX = selected.map { $0 % selection.width }.min()!, maxX = selected.map { $0 % selection.width }.max()!
        let minY = selected.map { $0 / selection.width }.min()!, maxY = selected.map { $0 / selection.width }.max()!
        let left = Int(floor(Double(minX) / Double(selection.width) * Double(sourceWidth)))
        let top = Int(floor(Double(minY) / Double(selection.height) * Double(sourceHeight)))
        let right = Int(ceil(Double(maxX + 1) / Double(selection.width) * Double(sourceWidth)))
        let bottom = Int(ceil(Double(maxY + 1) / Double(selection.height) * Double(sourceHeight)))
        let edge = max(32, max(right - left, bottom - top) * 2)
        guard edge <= 800 else { throw DevelopRepairAIError.selectionTooLarge }
        let width = min(edge, sourceWidth), height = min(edge, sourceHeight)
        let x = min(sourceWidth - width, max(0, (left + right - width) / 2))
        let y = min(sourceHeight - height, max(0, (top + bottom - height) / 2))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw DevelopRepairAIError.unavailable }
        let crop: CGImage
        if let graph {
            // The selection uses top-left rows; Core Image's source canvas has
            // a lower-left origin. Request only this <=800px context region,
            // never a full-image CPU render of the accumulated repair graph.
            let region = CGRect(x: x, y: sourceHeight - y - height, width: width, height: height)
            let context = CIContext(options: [.cacheIntermediates: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .workingFormat: CIFormat.RGBAh, .priorityRequestLow: true,
                .name: "Glowroom local repair context"])
            defer { context.clearCaches() }
            guard let rendered = context.createCGImage(graph.cropped(to: region), from: region,
                format: .RGBA8, colorSpace: colorSpace, deferred: false) else { throw DevelopRepairAIError.unavailable }
            crop = rendered
        } else {
            guard let rendered = source.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
                throw DevelopRepairAIError.unavailable
            }
            crop = rendered
        }
        var pixels = Data(count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw DevelopRepairAIError.unavailable }
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 { pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha)) }
            }
        }
        var weights = Data(count: width * height)
        for row in 0..<height {
            if row.isMultiple(of: 16) { try Task.checkCancellation() }
            for column in 0..<width {
                let sx = min(selection.width - 1, Int((Double(x + column) + 0.5) / Double(sourceWidth) * Double(selection.width)))
                let sy = min(selection.height - 1, Int((Double(y + row) + 0.5) / Double(sourceHeight) * Double(selection.height)))
                weights[row * width + column] = selection.bytes[sy * selection.width + sx]
            }
        }
        self.bounds = try DevelopCropRect(x: Double(x) / Double(sourceWidth), y: Double(y) / Double(sourceHeight),
            width: Double(width) / Double(sourceWidth), height: Double(height) / Double(sourceHeight))
        self.width = width; self.height = height; self.rgba = pixels; self.mask = weights
    }
}
