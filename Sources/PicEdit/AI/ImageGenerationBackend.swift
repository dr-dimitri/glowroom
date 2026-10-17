import Foundation
import PicEditCore

/// An implementation advertises only operation types exercised through this
/// exact adapter. Model installation is explicit and separate from generate.
protocol ImageGenerationBackend: Sendable {
    var descriptor: ImageGenerationBackendDescriptor { get }
    func availability() async -> ImageGenerationAvailability
    func generate(_ job: ImageGenerationJob) async throws -> ImageGenerationOutput
}

/// Full No-Go is a product decision, not a fake generator or automatic cloud
/// fallback. Keeping this executable route makes every later feature fail closed.
struct UnavailableImageGenerationBackend: ImageGenerationBackend {
    let descriptor: ImageGenerationBackendDescriptor

    init() {
        descriptor = try! ImageGenerationBackendDescriptor(
            identity: .init(providerID: "picedit.image-generation.unavailable"),
            operations: Dictionary(uniqueKeysWithValues: ImageGenerationOperation.allCases.map { ($0, .unsupported) }),
            residentMemoryBytes: 0, maximumOutputPixels: 1)
    }

    func availability() async -> ImageGenerationAvailability { .unavailable(.qualityGateFailed) }
    func generate(_ job: ImageGenerationJob) async throws -> ImageGenerationOutput {
        throw ImageGenerationError.unavailable(.qualityGateFailed)
    }
}
