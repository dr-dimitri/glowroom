import Foundation

/// These are separate claims. Image-to-image or an encoder alone never proves
/// masked editing, preservation-mask backgrounds or canvas extension.
public enum ImageGenerationOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case textToImage, imageToImage, inpaint, backgroundEdit, outpaint
}

public enum ImageGenerationCapabilityStatus: String, Codable, Hashable, Sendable {
    case supported, unsupported, unverified
}

public struct ImageGenerationBackendDescriptor: Hashable, Sendable {
    public let identity: GenerationProviderIdentity
    public let operations: [ImageGenerationOperation: ImageGenerationCapabilityStatus]
    /// Includes model weights and the maximum admitted working memory, not just
    /// the serialized download. A real route must obtain this from evaluation.
    public let residentMemoryBytes: Int64
    public let maximumOutputPixels: Int

    public init(identity: GenerationProviderIdentity,
                operations: [ImageGenerationOperation: ImageGenerationCapabilityStatus],
                residentMemoryBytes: Int64, maximumOutputPixels: Int) throws {
        guard residentMemoryBytes >= 0, maximumOutputPixels > 0, maximumOutputPixels <= 268_435_456 else {
            throw ImageGenerationError.invalidRequest
        }
        self.identity = identity; self.operations = operations
        self.residentMemoryBytes = residentMemoryBytes; self.maximumOutputPixels = maximumOutputPixels
    }

    public func status(for operation: ImageGenerationOperation) -> ImageGenerationCapabilityStatus {
        operations[operation] ?? .unverified
    }
}

public enum ImageGenerationUnavailableReason: String, Codable, CaseIterable, Hashable, Sendable {
    case qualityGateFailed, unverifiedCapability, unsupportedOperation
    case sdkUnavailable, unsupportedSystem, unsupportedHardware
    case missingWeights, corruptWeights, hashMismatch, memoryPressure
}

public enum ImageGenerationAvailability: Hashable, Sendable {
    case available
    case unavailable(ImageGenerationUnavailableReason)
}

public enum ImageGenerationError: Error, Hashable, Sendable {
    case unavailable(ImageGenerationUnavailableReason)
    case invalidRequest, invalidOutput, staleInput, cancelled, superseded, timedOut, backendFailure
}

extension ImageGenerationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason.localizedDescription
        case .invalidRequest: return "Die Anfrage für die Bildgeneration ist ungültig."
        case .invalidOutput: return "Das Bildmodell hat kein gültiges Bild mit den vereinbarten Maßen und Farbwerten geliefert."
        case .staleInput: return "Bild, Bearbeitungsstand oder Maske haben sich inzwischen geändert."
        case .cancelled: return "Die Bildgeneration wurde abgebrochen."
        case .superseded: return "Eine neuere Anfrage hat diese Bildgeneration ersetzt."
        case .timedOut: return "Die Bildgeneration hat das Zeitlimit überschritten."
        case .backendFailure: return "Das Bildmodell konnte die Anfrage nicht ausführen."
        }
    }
}

extension ImageGenerationUnavailableReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .qualityGateFailed: return "Bildgeneration ist deaktiviert: Der geprüfte Backendpfad hat die geforderte Bildqualität nicht erreicht."
        case .unverifiedCapability: return "Diese Bildfunktion wurde für den Backendpfad noch nicht nachgewiesen."
        case .unsupportedOperation: return "Dieser Backendpfad unterstützt diese Bildfunktion nicht."
        case .sdkUnavailable: return "Dieser Build enthält keine ausführbare Bildmodell-Schnittstelle."
        case .unsupportedSystem: return "Das Bildmodell unterstützt diese macOS-Version nicht."
        case .unsupportedHardware: return "Das Bildmodell unterstützt diesen Mac nicht."
        case .missingWeights: return "Die benötigten Bildmodell-Dateien fehlen."
        case .corruptWeights: return "Die Bildmodell-Dateien sind beschädigt."
        case .hashMismatch: return "Die Prüfsumme der Bildmodell-Dateien stimmt nicht."
        case .memoryPressure: return "Für das Bildmodell steht derzeit nicht genügend Speicher zur Verfügung."
        }
    }
}

public struct ImageGenerationParameters: Hashable, Sendable {
    public static let version = 1
    public let steps: Int
    public let guidanceScale: Double
    public let strength: Double
    public init(steps: Int = 20, guidanceScale: Double = 7.5, strength: Double = 1) throws {
        guard (1...100).contains(steps), guidanceScale.isFinite, (0...30).contains(guidanceScale),
              strength.isFinite, (0...1).contains(strength) else { throw ImageGenerationError.invalidRequest }
        self.steps = steps; self.guidanceScale = guidanceScale; self.strength = strength
    }
}

/// Product-facing masked job, bound to the existing immutable AI-09/10 source,
/// rendered pixels, edit/selection epochs, native mask hash and model transform.
/// Text-to-image, ordinary image-to-image and output-canvas masks for outpainting
/// need their own proven route before constructing jobs. Their capability status
/// is still reported independently in the descriptor.
public struct ImageGenerationJob: Sendable {
    public static let preprocessingVersion = 1
    public let request: GenerationRequest
    public let operation: ImageGenerationOperation
    public let placement: ArtifactCanvasPlacement
    public let prompt: String
    public let parameters: ImageGenerationParameters
    /// A seed is a backend input, never a promise of cross-device reproducibility.
    public let seed: UInt64

    public init(request: GenerationRequest, operation: ImageGenerationOperation,
                placement: ArtifactCanvasPlacement, prompt: String,
                parameters: ImageGenerationParameters, seed: UInt64) throws {
        guard [.inpaint, .backgroundEdit].contains(operation),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 16_384,
              placement.schemaVersion == 1, placement.inputSize == request.renderedInput.format.size else {
            throw ImageGenerationError.invalidRequest
        }
        _ = try ArtifactCanvasPlacement(inputSize: placement.inputSize, outputSize: placement.outputSize,
            inputOriginX: placement.inputOriginX, inputOriginY: placement.inputOriginY)
        guard placement.outputSize == placement.inputSize,
              placement.inputOriginX == 0, placement.inputOriginY == 0 else { throw ImageGenerationError.invalidRequest }
        self.request = request; self.operation = operation; self.placement = placement
        self.prompt = prompt; self.parameters = parameters; self.seed = seed
    }
}

/// No mutable bitmap, path or model-selected identity crosses this boundary.
/// The product adapter must convert its output back to the agreed native canvas,
/// original profile/bit depth before constructing this value. RGB sources may
/// expand to straight RGBA for final composition; their preserved pixels get
/// opaque alpha. RGBA sources must retain their straight-alpha representation.
public struct ImageGenerationOutput: Sendable {
    public let raster: ArtifactRasterInput
    public let token: GenerationMaskJobToken
    public let fingerprint: RenderedInputFingerprint

    public init(immutableRaster: ArtifactRasterInput, token: GenerationMaskJobToken) throws {
        do {
            let shape = try ArtifactPNGCodec.shape(immutableRaster.image)
            guard let depth = ArtifactBitDepth(rawValue: shape.bits), let profile = shape.profile, let icc = shape.icc else {
                throw ImageGenerationError.invalidOutput
            }
            let format = ArtifactRasterFormat(size: shape.size, bitDepth: depth, channels: shape.channels,
                profile: profile, iccSHA256: try ArtifactJSONCodec.digestBytes(icc))
            fingerprint = try RenderedInputFingerprint(format: format,
                canonicalPixelSHA256: ArtifactPNGCodec.pixelHash(immutableRaster.image, shape: shape),
                pipelineVersion: ImageGenerationJob.preprocessingVersion)
        } catch is CancellationError { throw ImageGenerationError.cancelled }
        catch { throw ImageGenerationError.invalidOutput }
        raster = immutableRaster; self.token = token
    }

    public func validate(for job: ImageGenerationJob, descriptor: ImageGenerationBackendDescriptor) throws {
        guard token == job.request.token else { throw ImageGenerationError.staleInput }
        let format = fingerprint.format, input = job.request.renderedInput.format
        guard format.size == job.placement.outputSize,
              format.size.width <= descriptor.maximumOutputPixels / format.size.height,
              format.bitDepth == input.bitDepth,
              (format.channels == input.channels || input.channels == .rgb && format.channels == .rgba),
              format.profile == input.profile, format.iccSHA256 == input.iccSHA256 else {
            throw ImageGenerationError.invalidOutput
        }
    }
}
