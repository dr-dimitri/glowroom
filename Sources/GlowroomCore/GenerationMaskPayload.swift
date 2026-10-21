import Foundation
import CoreGraphics

/// Pixel-edge coordinates in the EXIF-oriented, top-left input canvas. Model
/// pixel centres map back through this SAME crop/scale; preview size is irrelevant.
public struct MaskRasterTransform: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let canvasSize: ArtifactPixelSize
    public let crop: ArtifactPixelRect
    public let modelSize: ArtifactPixelSize

    public init(canvasSize: ArtifactPixelSize, crop: ArtifactPixelRect? = nil,
                modelSize: ArtifactPixelSize) throws {
        let selected = try crop ?? ArtifactPixelRect(x: 0, y: 0, size: canvasSize)
        _ = try ArtifactPixelRect(x: selected.x, y: selected.y, size: selected.size)
        guard selected.x <= canvasSize.width - selected.size.width,
              selected.y <= canvasSize.height - selected.size.height else {
            throw ArtifactContractError.invalidValue("Maskenausschnitt")
        }
        schemaVersion = 1; self.canvasSize = canvasSize; self.crop = selected; self.modelSize = modelSize
    }

    public func modelPoint(from point: MaskPoint) throws -> MaskPoint {
        try MaskPoint(x: (point.x - Double(crop.x)) * Double(modelSize.width) / Double(crop.size.width),
                      y: (point.y - Double(crop.y)) * Double(modelSize.height) / Double(crop.size.height))
    }
    public func canvasPoint(from point: MaskPoint) throws -> MaskPoint {
        try MaskPoint(x: Double(crop.x) + point.x * Double(crop.size.width) / Double(modelSize.width),
                      y: Double(crop.y) + point.y * Double(crop.size.height) / Double(modelSize.height))
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ArtifactContractError.unsupportedVersion(schemaVersion) }
        _ = try Self(canvasSize: canvasSize, crop: crop, modelSize: modelSize)
    }
}

/// Small manifest reference to TWO immutable payloads. The native Gray8 PNG is
/// authoritative; the document records provenance and never regenerates it on read.
public struct GenerationMaskBinding: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let resourceID: ArtifactResourceID
    public let documentFile: ArtifactFileDescriptor
    public let rasterSHA256: ArtifactDigest
    public let transform: MaskRasterTransform

    public init(resourceID: ArtifactResourceID, documentFile: ArtifactFileDescriptor,
                rasterSHA256: ArtifactDigest, transform: MaskRasterTransform) throws {
        guard documentFile.bytes <= 1_048_576 else { throw ArtifactContractError.limitExceeded }
        try transform.validate()
        schemaVersion = 1; self.resourceID = resourceID; self.documentFile = documentFile
        self.rasterSHA256 = rasterSHA256; self.transform = transform
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ArtifactContractError.unsupportedVersion(schemaVersion) }
        try ArtifactValueValidation.file(documentFile)
        _ = try Self(resourceID: resourceID, documentFile: documentFile, rasterSHA256: rasterSHA256, transform: transform)
    }
}

/// Capture outside MainActor. A snapshot owns its native raster, so future UI
/// strokes, zoom changes and preview resolution changes cannot alter job inputs.
public struct FrozenGenerationMask: Sendable {
    public let document: MaskDocument
    public let raster: MaskRaster
    public let binding: GenerationMaskBinding

    public static func capture(document: MaskDocument, modelSize: ArtifactPixelSize,
                               crop: ArtifactPixelRect? = nil, resourceID: ArtifactResourceID = .init()) throws -> Self {
        let bytes = try document.canonicalData()
        let raster = try MaskRasterizer.rasterize(document)
        let transform = try MaskRasterTransform(canvasSize: document.canvasSize, crop: crop, modelSize: modelSize)
        let binding = try GenerationMaskBinding(resourceID: resourceID,
            documentFile: .init(sha256: ArtifactJSONCodec.digestBytes(bytes), bytes: Int64(bytes.count)),
            rasterSHA256: raster.canonicalSHA256(), transform: transform)
        return Self(document: document, raster: raster, binding: binding)
    }

    public func artifactInput() throws -> ArtifactMaskInput {
        guard let provider = CGDataProvider(data: raster.bytes as CFData),
              let image = CGImage(width: raster.size.width, height: raster.size.height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: raster.size.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ArtifactContractError.unsupportedFormat
        }
        return ArtifactMaskInput(id: binding.resourceID, coordinateSpace: .inputCanvas,
                                 immutableImage: image, document: document)
    }
    public func modelRaster() throws -> MaskRaster {
        try raster.resampled(to: binding.transform.modelSize, crop: binding.transform.crop)
    }
}

/// Immutable provider-independent job input. A provider may resample the mask
/// using this recorded transform, but only the canonical native mask authorizes
/// replacement at final composition. Feature-specific validation decides whether
/// an empty/full mask is meaningful; this foundation accepts both.
public struct GenerationRequest: Sendable {
    public let id: UUID
    public let snapshot: AIEditingSnapshot
    public let input: ArtifactRasterInput
    public let renderedInput: RenderedInputFingerprint
    public let mask: FrozenGenerationMask
    public var token: GenerationMaskJobToken {
        GenerationMaskJobToken(requestID: id, snapshot: snapshot, canvasSize: mask.raster.size,
                               renderedInput: renderedInput, rasterSHA256: mask.binding.rasterSHA256, transform: mask.binding.transform)
    }
    public init(id: UUID = UUID(), snapshot: AIEditingSnapshot, immutableInput: ArtifactRasterInput,
                mask: FrozenGenerationMask, pipelineVersion: Int = 1) throws {
        try snapshot.validate(); try mask.binding.validate()
        let shape = try ArtifactPNGCodec.shape(immutableInput.image)
        guard shape.size == mask.raster.size else { throw ArtifactContractError.invalidValue("Maskeneingabe") }
        let format = ArtifactRasterFormat(size: shape.size, bitDepth: ArtifactBitDepth(rawValue: shape.bits)!,
            channels: shape.channels, profile: shape.profile!, iccSHA256: try ArtifactJSONCodec.digestBytes(shape.icc!))
        renderedInput = try RenderedInputFingerprint(format: format,
            canonicalPixelSHA256: ArtifactPNGCodec.pixelHash(immutableInput.image, shape: shape), pipelineVersion: pipelineVersion)
        if case .artifact(let source) = snapshot.source {
            guard source.raster.format.size == mask.raster.size else { throw ArtifactContractError.invalidValue("Maskenquelle") }
        }
        self.id = id; self.snapshot = snapshot; self.mask = mask; input = immutableInput
    }
}

public struct GenerationMaskJobToken: Hashable, Sendable {
    public let requestID: UUID
    public let snapshot: AIEditingSnapshot
    public let canvasSize: ArtifactPixelSize
    public let renderedInput: RenderedInputFingerprint
    public let rasterSHA256: ArtifactDigest
    public let transform: MaskRasterTransform
}

internal enum MaskPayloadValidation {
    static func validateDocument(_ file: ArtifactPinnedFile, binding: GenerationMaskBinding,
                                 resources: any ArtifactResourceAdmitting) async throws {
        guard file.stamp.bytes == binding.documentFile.bytes, file.stamp.bytes <= 1_048_576 else { throw ArtifactContractError.corruptArtifact }
        let admission = try await resources.acquire(kind: .retainedMemory, bytes: file.stamp.bytes * 16 + 1_048_576,
                                                    priority: .background, retaining: [])
        defer { withExtendedLifetime(admission) {} }
        var bytes = Data(); var offset: Int64 = 0
        while offset < file.stamp.bytes {
            try Task.checkCancellation()
            let block = try file.read(offset: offset, count: 65_536)
            guard !block.isEmpty else { throw ArtifactContractError.corruptArtifact }
            bytes.append(block); offset += Int64(block.count)
        }
        try document(bytes, binding: binding); try file.validate()
    }
    static func document(_ bytes: Data, binding: GenerationMaskBinding) throws {
        guard bytes.count == binding.documentFile.bytes,
              try ArtifactJSONCodec.digestBytes(bytes) == binding.documentFile.sha256 else { throw ArtifactContractError.corruptArtifact }
        let value = try ArtifactJSONCodec.decode(MaskDocument.self, from: bytes, maximum: 1_048_576)
        guard value.canvasSize == binding.transform.canvasSize, try value.canonicalData() == bytes else {
            throw ArtifactContractError.corruptArtifact
        }
    }
    static func raster(_ image: CGImage, binding: GenerationMaskBinding) throws {
        let shape = try ArtifactPNGCodec.shape(image, gray: true)
        guard shape.size == binding.transform.canvasSize, let source = image.dataProvider?.data else { throw ArtifactContractError.corruptArtifact }
        let bytes = source as Data
        guard bytes.count >= image.bytesPerRow * image.height else { throw ArtifactContractError.corruptArtifact }
        var packed = Data(capacity: shape.size.width * shape.size.height)
        for row in 0..<image.height {
            try Task.checkCancellation()
            packed.append(bytes.subdata(in: row * image.bytesPerRow ..< row * image.bytesPerRow + image.width))
        }
        guard try MaskRaster(size: shape.size, bytes: packed).canonicalSHA256() == binding.rasterSHA256 else {
            throw ArtifactContractError.corruptArtifact
        }
    }
}
