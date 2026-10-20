import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import GlowroomCore
import Vision

enum AutomaticMaskKind: String, CaseIterable, Identifiable, Sendable {
    case subject, sky
    var id: String { rawValue }
    var title: String { self == .subject ? "Motiv" : "Himmel" }
}

enum AutomaticMaskError: Error, LocalizedError, Equatable {
    case noSubject, noSky, skyModelNotInstalled, invalidModel, invalidMask, unavailable, setupInProgress
    var errorDescription: String? {
        switch self {
        case .noSubject: return "Es wurde kein freistellbares Motiv erkannt. Verwende den Pinsel oder einen Verlauf."
        case .noSky: return "Es wurde kein Himmel erkannt. Verwende den Pinsel oder einen Verlauf."
        case .skyModelNotInstalled: return "Richte zuerst das lokale Himmelsmodell über „Himmelsmodell einrichten …“ ein."
        case .invalidModel: return "Das lokale Himmelsmodell ist unvollständig oder verändert. Starte die Einrichtung erneut."
        case .invalidMask: return "Die Bilderkennung hat keine gültige Maske geliefert."
        case .unavailable: return "Die automatische Maskierung ist für dieses Bild oder auf diesem Mac nicht verfügbar."
        case .setupInProgress: return "Das Himmelsmodell wird bereits eingerichtet."
        }
    }
}

/// A single shared AI lease covers the actual native return, including canceled
/// Vision/Core ML work. The caller owns source/session guards before accepting
/// a result: this service never publishes image state or saves edits itself.
actor AutomaticMaskService {
    static let shared = AutomaticMaskService()
    typealias Generator = @Sendable (PreviewBitmap, AutomaticMaskKind, URL?) async throws -> LocalMaskRaster
    private let budget: AIResourceBudget
    private let generator: Generator

    init(budget: AIResourceBudget = .shared, generator: Generator? = nil) {
        self.budget = budget
        self.generator = generator ?? { bitmap, kind, url in
            try await AutomaticMaskWorker.shared.generate(bitmap, kind: kind, sourceURL: url)
        }
    }

    func generate(_ bitmap: PreviewBitmap, kind: AutomaticMaskKind, sourceURL: URL? = nil) async throws -> LocalMaskRaster {
        try Task.checkCancellation()
        // Reserve the largest eligible subject path before admission: setup can
        // publish a matting model while this request waits in the shared queue.
        let residentBytes = kind == .subject ? SubjectMattingModelInterface.residentBytes : 384 * 1_024 * 1_024
        let lease = try await budget.acquireLocalInference(priority: .interactive, residentBytes: residentBytes)
        do {
            let result = try await generator(bitmap, kind, sourceURL)
            try Task.checkCancellation()
            await budget.release(lease)
            return result
        } catch {
            await budget.release(lease)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? SubjectMattingError { throw error }
            throw (error as? AutomaticMaskError) ?? .unavailable
        }
    }
}

private final class AutomaticVisionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func register(_ request: VNRequest) throws {
        lock.lock(); self.request = request; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { request.cancel(); throw CancellationError() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let active = request; lock.unlock()
        active?.cancel()
    }
}

/// Native work is serial on an actor off MainActor. Neural inference is already
/// parallel inside Vision/Core ML; another photo worker pool increases peak
/// memory and competes with the interactive renderer.
actor AutomaticMaskWorker {
    static let shared = AutomaticMaskWorker()
    typealias SubjectGenerator = @Sendable (CGImage, SubjectMattingInstalledModel) throws -> LocalMaskRaster
    private let skyModelStore: SkyMaskModelStore
    private let subjectModelStore: SubjectMattingModelStore
    private let cachesSubjectResults: Bool
    private var subjectCache = SubjectMattingResultCache()
    private let subjectGenerator: SubjectGenerator

    init(skyModelStore: SkyMaskModelStore = .shared, subjectModelStore: SubjectMattingModelStore = .shared,
         cachesSubjectResults: Bool = true,
         subjectGenerator: @escaping SubjectGenerator = { try SubjectMattingInference.generate($0, installation: $1) }) {
        self.skyModelStore = skyModelStore
        self.subjectModelStore = subjectModelStore
        self.cachesSubjectResults = cachesSubjectResults
        self.subjectGenerator = subjectGenerator
    }

    func generate(_ bitmap: PreviewBitmap, kind: AutomaticMaskKind, sourceURL: URL?) async throws -> LocalMaskRaster {
        try Task.checkCancellation()
        switch kind {
        case .subject:
            if let installation = try await subjectModelStore.installedModel() {
                if cachesSubjectResults, let cached = subjectCache.value(for: bitmap.image, modelID: installation.receiptSHA256) {
                    // A cached matte must not hide a changed installation. This
                    // bounded hash check is much cheaper than another inference.
                    _ = try SubjectMattingModelStore.verifyInstallation(installation)
                    return cached
                }
                subjectCache.clear()
                let raster = try autoreleasepool { try subjectGenerator(bitmap.image, installation) }
                try Task.checkCancellation()
                if cachesSubjectResults { subjectCache.store(raster, for: bitmap, modelID: installation.receiptSHA256) }
                return raster
            }
            subjectCache.clear()
            let cancellation = AutomaticVisionCancellation()
            return try await withTaskCancellationHandler {
                try autoreleasepool { try subject(bitmap.image, cancellation: cancellation) }
            } onCancel: { cancellation.cancel() }
        case .sky:
            // Always segment the immutable bitmap supplied by the editor. A
            // fresh auxiliary-matte read could refer to a different file version
            // than the source retained in the preview cache.
            let installed = try await skyModelStore.installedModel()
            guard let installed else { throw AutomaticMaskError.skyModelNotInstalled }
            return try autoreleasepool { try sky(bitmap.image, installation: installed) }
        }
    }

    private func subject(_ image: CGImage, cancellation: AutomaticVisionCancellation) throws -> LocalMaskRaster {
        try Task.checkCancellation()
        let proxy = try Self.proxy(image, maximumDimension: LocalMaskRaster.maximumDimension)
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
        request.preferBackgroundProcessing = true
        try cancellation.register(request)
        let handler = VNImageRequestHandler(cgImage: proxy, orientation: .up, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw AutomaticMaskError.noSubject
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let raster = try AutomaticMaskRasterConverter.raster(buffer)
        return try AutomaticMaskRefiner.refine(raster, guide: proxy)
    }

    private func sky(_ image: CGImage, installation: SkyMaskInstalledModel) throws -> LocalMaskRaster {
        // Each one-shot request releases model weights after completion.
        // Repeated slider movement never triggers inference.
        let stamps = try SkyMaskModelStore.verifyInstallation(installation)
        let input = try Self.squarePixelBuffer(image, side: 448)
        let outputSize = AutomaticMaskRasterConverter.outputSize(width: image.width, height: image.height)
        let raster: LocalMaskRaster
        do { raster = try inferSky(input, installation: installation, outputSize: outputSize, computeUnits: .all) }
        catch {
            try Task.checkCancellation()
            if error as? AutomaticMaskError == .invalidModel { throw error }
            // Release accelerated model temporaries before the functional CPU
            // fallback. Loading and prediction can both fail on a device.
            raster = try inferSky(input, installation: installation, outputSize: outputSize, computeUnits: .cpuOnly)
        }
        for (url, expected) in stamps {
            guard try SemanticInstallationIO.stamp(url) == expected else { throw AutomaticMaskError.invalidModel }
        }
        guard raster.bytes.contains(where: { $0 != 0 }) else { throw AutomaticMaskError.noSky }
        return try AutomaticMaskRefiner.refine(raster, guide: image)
    }

    private func inferSky(_ input: CVPixelBuffer, installation: SkyMaskInstalledModel,
                          outputSize: (width: Int, height: Int), computeUnits: MLComputeUnits) throws -> LocalMaskRaster {
        try autoreleasepool {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let model = try MLModel(contentsOf: installation.directory.appendingPathComponent("model.mlmodelc"), configuration: configuration)
            let skyClass = try AutomaticMaskRasterConverter.skyClass(in: model)
            try Task.checkCancellation()
            let features = try MLDictionaryFeatureProvider(dictionary: ["image": input])
            let prediction = try model.prediction(from: features)
            try Task.checkCancellation()
            guard let classes = prediction.featureValue(for: "semanticPredictions")?.multiArrayValue else { throw AutomaticMaskError.invalidModel }
            return try AutomaticMaskRasterConverter.skyRaster(classes, skyClass: skyClass, outputSize: outputSize)
        }
    }

    private static func proxy(_ image: CGImage, maximumDimension: Int) throws -> CGImage {
        let size = AutomaticMaskRasterConverter.outputSize(width: image.width, height: image.height, maximumDimension: maximumDimension)
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AutomaticMaskError.unavailable }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let proxy = context.makeImage() else { throw AutomaticMaskError.unavailable }
        return proxy
    }

    private static func squarePixelBuffer(_ image: CGImage, side: Int) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32ARGB,
                                 [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                 &optional) == kCVReturnSuccess, let buffer = optional else { throw AutomaticMaskError.unavailable }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw AutomaticMaskError.unavailable }
        // Full-image resize, not a center crop: the returned class map is scaled
        // back to the oriented image aspect ratio, retaining edge content.
        context.interpolationQuality = .high
        // Model input has no alpha. A deterministic black backing avoids
        // sampling uninitialized destination bytes through transparent sources.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}

enum AutomaticMaskRasterConverter {
    static func outputSize(width: Int, height: Int, maximumDimension: Int = LocalMaskRaster.maximumDimension) -> (width: Int, height: Int) {
        let scale = min(1, Double(maximumDimension) / Double(max(1, max(width, height))))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    static func raster(_ buffer: CVPixelBuffer) throws -> LocalMaskRaster {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard width > 0, height > 0, width <= 2_048, height <= 2_048,
              format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8 else {
            throw AutomaticMaskError.invalidMask
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AutomaticMaskError.invalidMask }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixelBytes = format == kCVPixelFormatType_OneComponent32Float ? MemoryLayout<Float>.size : 1
        guard stride >= width * pixelBytes else { throw AutomaticMaskError.invalidMask }
        let size = outputSize(width: width, height: height)
        return try sampled(width: width, height: height, outputSize: size) { x, y in
            let row = base.advanced(by: y * stride)
            let value = format == kCVPixelFormatType_OneComponent32Float
                ? Double(row.assumingMemoryBound(to: Float.self)[x])
                : Double(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
            guard value.isFinite else { throw AutomaticMaskError.invalidMask }
            return min(1, max(0, value))
        }
    }

    static func skyClass(in model: MLModel) throws -> Int {
        struct Labels: Decodable { let labels: [String] }
        guard let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
              let params = metadata["com.apple.coreml.model.preview.params"]?.data(using: .utf8),
              let labels = try? JSONDecoder().decode(Labels.self, from: params),
              let index = labels.labels.firstIndex(of: "sky (other)") else { throw AutomaticMaskError.invalidModel }
        return index
    }

    static func skyRaster(_ classes: MLMultiArray, skyClass: Int, outputSize: (width: Int, height: Int)) throws -> LocalMaskRaster {
        guard classes.dataType == .int32, classes.shape.map(\.intValue) == [448, 448], classes.strides.count == 2 else {
            throw AutomaticMaskError.invalidModel
        }
        let sx = classes.strides[1].intValue, sy = classes.strides[0].intValue
        let values = classes.dataPointer.assumingMemoryBound(to: Int32.self)
        return try sampled(width: 448, height: 448, outputSize: outputSize) { x, y in
            values[y * sy + x * sx] == skyClass ? 1 : 0
        }
    }

    private static func sampled(width: Int, height: Int, outputSize: (width: Int, height: Int),
                                value: (Int, Int) throws -> Double) throws -> LocalMaskRaster {
        var bytes = Data(count: outputSize.width * outputSize.height)
        try bytes.withUnsafeMutableBytes { storage in
            let out = storage.bindMemory(to: UInt8.self)
            for y in 0..<outputSize.height {
                if y.isMultiple(of: 16) { try Task.checkCancellation() }
                let py = min(Double(height - 1), max(0, (Double(y) + 0.5) * Double(height) / Double(outputSize.height) - 0.5))
                let y0 = Int(py), y1 = min(y0 + 1, height - 1), fy = py - Double(y0)
                for x in 0..<outputSize.width {
                    let px = min(Double(width - 1), max(0, (Double(x) + 0.5) * Double(width) / Double(outputSize.width) - 0.5))
                    let x0 = Int(px), x1 = min(x0 + 1, width - 1), fx = px - Double(x0)
                    let a = try value(x0, y0) * (1 - fx) + value(x1, y0) * fx
                    let b = try value(x0, y1) * (1 - fx) + value(x1, y1) * fx
                    out[y * outputSize.width + x] = UInt8((255 * (a * (1 - fy) + b * fy)).rounded())
                }
            }
        }
        return try LocalMaskRaster(width: outputSize.width, height: outputSize.height, bytes: bytes)
    }

}
