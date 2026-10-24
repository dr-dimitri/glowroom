import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import GlowroomCore

/// One immutable image and at most one 4-MiB matte. Holding the image itself
/// prevents object-identity reuse after cache eviction elsewhere. Subject and
/// background creation share this result; different images/models miss it.
struct SubjectMattingResultCache {
    // Preserve the source's artifact memory reservation for as long as this
    // additional image reference is alive, including after preview-cache eviction.
    private var bitmap: PreviewBitmap?
    private var modelID: String?
    private var raster: LocalMaskRaster?

    func value(for image: CGImage, modelID: String) -> LocalMaskRaster? {
        guard let cachedImage = bitmap?.image, cachedImage === image, self.modelID == modelID else { return nil }
        return raster
    }

    mutating func store(_ raster: LocalMaskRaster, for bitmap: PreviewBitmap, modelID: String) {
        self.bitmap = bitmap; self.modelID = modelID; self.raster = raster
    }

    mutating func clear() { bitmap = nil; modelID = nil; raster = nil }
}

/// The imported model owns normalization and sigmoid. Image coverage is scalar
/// data, not display gray; retain its fractional edges without gamma or erosion.
enum SubjectMattingModelInterface {
    static let side = LocalModelRegistry.subjectSide
    static let residentBytes: Int64 = 6 * 1_024 * 1_024 * 1_024
    static let contract = LocalModelRegistry.subjectContract
    static let sourceRevision = LocalModelRegistry.subjectRevision
    static let weightsSHA256 = LocalModelRegistry.subjectWeightsSHA256

    private struct PinnedPackage: Decodable {
        let schemaVersion: Int
        let contract: String
        let sourceRevision: String
        let weightsSHA256: String
        let files: [SemanticManifestFile]
    }

    static func approvedFiles(mainBundle: Bundle = .main) throws -> [SemanticManifestFile] {
        try pinnedFiles(resourceName: "SubjectMattingApprovedPackage", mainBundle: mainBundle)
    }

    /// This historical identity only permits recognizing an existing install
    /// for controlled replacement/removal. Runtime and imports use approvedFiles.
    static func legacyFiles(mainBundle: Bundle = .main) throws -> [SemanticManifestFile] {
        try pinnedFiles(resourceName: "SubjectMattingLegacyPackage", mainBundle: mainBundle)
    }

    private static func pinnedFiles(resourceName: String, mainBundle: Bundle) throws -> [SemanticManifestFile] {
        let resources: Bundle
        if mainBundle.bundleURL.pathExtension.lowercased() == "app" {
            guard let root = mainBundle.resourceURL?.appendingPathComponent("Glowroom_Glowroom.bundle"),
                  let packaged = Bundle(url: root) else { throw SubjectMattingError.invalidModel }
            resources = packaged
        } else { resources = .module }
        guard let url = resources.url(forResource: resourceName, withExtension: "json") else {
            throw SubjectMattingError.invalidModel
        }
        let package = try SemanticInstallationIO.decode(PinnedPackage.self, at: url, limit: 16_384)
        guard package.schemaVersion == 1, package.contract == contract, package.sourceRevision == sourceRevision,
              package.weightsSHA256 == weightsSHA256, package.files.count == 3,
              Set(package.files.map(\.path)) == Set(["Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                                                    "Data/com.apple.CoreML/weights/weight.bin"]),
              package.files.allSatisfy({ $0.bytes > 0 && $0.bytes <= 512 * 1_024 * 1_024 &&
                  SemanticInstallationIO.validHash($0.sha256) }) else { throw SubjectMattingError.invalidModel }
        return package.files
    }

    static func validateApprovedFiles(_ files: [SemanticManifestFile]) throws {
        guard Set(files) == Set(try approvedFiles()), files.count == 3 else { throw SubjectMattingError.invalidModel }
    }

    static func validateSourcePackage(_ source: URL) throws -> [SemanticManifestFile] {
        guard source.isFileURL, source.pathExtension.lowercased() == "mlpackage" else {
            throw SubjectMattingError.invalidModel
        }
        let files = try approvedFiles()
        try SemanticInstallationIO.verifyTree(source, files: files)
        return files
    }

    static func validateModel(_ directory: URL) throws {
        do { _ = try load(directory, computeUnits: .cpuAndGPU) }
        catch {
            try Task.checkCancellation()
            if error as? SubjectMattingError == .invalidModel { throw error }
            _ = try load(directory, computeUnits: .cpuOnly)
        }
    }

    static func load(_ directory: URL, computeUnits: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        // This qualified graph contains deformable sampling. ANE compilation
        // is deliberately excluded; CPU/GPU and CPU use the same learned graph.
        configuration.computeUnits = computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = false
        let model = try MLModel(contentsOf: directory, configuration: configuration)
        try validate(model.modelDescription)
        return model
    }

    static func validate(_ description: MLModelDescription) throws {
        let inputs = description.inputDescriptionsByName
        let outputs = description.outputDescriptionsByName
        guard Set(inputs.keys) == ["image"], Set(outputs.keys) == ["alpha"],
              let input = inputs["image"], !input.isOptional, input.type == .image,
              let image = input.imageConstraint, image.pixelsWide == side, image.pixelsHigh == side,
              image.pixelFormatType == kCVPixelFormatType_32BGRA,
              let output = outputs["alpha"], !output.isOptional, output.type == .multiArray,
              let alpha = output.multiArrayConstraint, alpha.dataType == .float32,
              alpha.shape.map(\.intValue) == [1, 1, side, side],
              let metadata = description.metadata[.creatorDefinedKey] as? [String: String],
              // These creator keys belong to the hash-pinned upstream conversion.
              // Preserve the package provenance independently of the app name.
              metadata["picedit.subjectMatting.contract"] == contract,
              metadata["picedit.subjectMatting.sourceRevision"] == sourceRevision,
              metadata["picedit.subjectMatting.weightsSHA256"] == weightsSHA256,
              metadata["picedit.subjectMatting.preprocessing"] == "srgb-rgb-imagenet-square" else {
            throw SubjectMattingError.invalidModel
        }
    }
}

enum SubjectMattingInference {
    static func generate(_ image: CGImage, installation: SubjectMattingInstalledModel) throws -> LocalMaskRaster {
        let stamps = try SubjectMattingModelStore.verifyInstallation(installation)
        let input = try inputBuffer(image)
        let size = AutomaticMaskRasterConverter.outputSize(width: image.width, height: image.height)
        let raster: LocalMaskRaster
        do { raster = try infer(input, installation: installation, size: size, computeUnits: .cpuAndGPU) }
        catch {
            try Task.checkCancellation()
            if error as? SubjectMattingError == .invalidModel { throw error }
            // Accelerated temporaries have left the autoreleasepool before
            // loading the identical graph for the functional CPU fallback.
            raster = try infer(input, installation: installation, size: size, computeUnits: .cpuOnly)
        }
        for (url, expected) in stamps {
            guard try SemanticInstallationIO.stamp(url) == expected else { throw SubjectMattingError.invalidModel }
        }
        guard raster.bytes.contains(where: { $0 > 0 }) else { throw AutomaticMaskError.noSubject }
        return raster
    }

    private static func infer(_ input: CVPixelBuffer, installation: SubjectMattingInstalledModel,
                              size: (width: Int, height: Int), computeUnits: MLComputeUnits) throws -> LocalMaskRaster {
        try autoreleasepool {
            try Task.checkCancellation()
            let model = try SubjectMattingModelInterface.load(
                installation.directory.appendingPathComponent("model.mlmodelc"), computeUnits: computeUnits)
            try Task.checkCancellation()
            let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
            try Task.checkCancellation()
            guard let alpha = prediction.featureValue(for: "alpha")?.multiArrayValue else {
                throw SubjectMattingError.invalidModel
            }
            do { return try raster(alpha, side: SubjectMattingModelInterface.side, outputSize: size) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // A validated graph can still encounter a device-specific
                // numerical failure. Retry the same graph on CPU before failing.
                throw SubjectMattingError.unavailable
            }
        }
    }

    static func inputBuffer(_ image: CGImage, side: Int = SubjectMattingModelInterface.side) throws -> CVPixelBuffer {
        guard (1...SubjectMattingModelInterface.side).contains(side) else { throw SubjectMattingError.invalidModel }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer) == kCVReturnSuccess, let buffer else { throw SubjectMattingError.unavailable }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo:
                CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw SubjectMattingError.unavailable
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // Full-image square resize matches the trained reference pipeline.
        // Orientation is already applied by the shared developed-preview cache.
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }

    static func raster(_ alpha: MLMultiArray, side: Int = SubjectMattingModelInterface.side,
                       outputSize: (width: Int, height: Int)) throws -> LocalMaskRaster {
        guard (1...SubjectMattingModelInterface.side).contains(side), alpha.dataType == .float32,
              alpha.shape.map(\.intValue) == [1, 1, side, side], alpha.strides.count == 4,
              (1...LocalMaskRaster.maximumDimension).contains(outputSize.width),
              (1...LocalMaskRaster.maximumDimension).contains(outputSize.height) else {
            throw SubjectMattingError.invalidModel
        }
        let sx = alpha.strides[3].intValue, sy = alpha.strides[2].intValue
        guard sx > 0, sx <= 16, sy >= side * sx, sy <= side * 16 else {
            throw SubjectMattingError.invalidModel
        }
        let values = alpha.dataPointer.assumingMemoryBound(to: Float.self)
        // Check all model pixels, including those omitted by aspect restoration.
        // A partly non-finite prediction must never become a saved selection.
        for y in 0..<side {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            for x in 0..<side where !values[y * sy + x * sx].isFinite { throw SubjectMattingError.invalidModel }
        }
        func value(_ x: Int, _ y: Int) -> Double { Double(min(1, max(0, values[y * sy + x * sx]))) }
        var bytes = Data(count: outputSize.width * outputSize.height)
        try bytes.withUnsafeMutableBytes { storage in
            let out = storage.bindMemory(to: UInt8.self)
            for y in 0..<outputSize.height {
                if y.isMultiple(of: 16) { try Task.checkCancellation() }
                let py = min(Double(side - 1), max(0, (Double(y) + 0.5) * Double(side) / Double(outputSize.height) - 0.5))
                let y0 = Int(py), y1 = min(y0 + 1, side - 1), fy = py - Double(y0)
                for x in 0..<outputSize.width {
                    let px = min(Double(side - 1), max(0, (Double(x) + 0.5) * Double(side) / Double(outputSize.width) - 0.5))
                    let x0 = Int(px), x1 = min(x0 + 1, side - 1), fx = px - Double(x0)
                    let a = value(x0, y0) * (1 - fx) + value(x1, y0) * fx
                    let b = value(x0, y1) * (1 - fx) + value(x1, y1) * fx
                    out[y * outputSize.width + x] = UInt8((255 * (a * (1 - fy) + b * fy)).rounded())
                }
            }
        }
        return try LocalMaskRaster(width: outputSize.width, height: outputSize.height, bytes: bytes)
    }
}
