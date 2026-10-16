import Foundation
import PicEditCore

protocol ImageAnalysisProvider: Sendable {
    var descriptor: ImageAnalysisProviderDescriptor { get }
    func availability() async -> ImageAnalysisAvailability
    func analyze(_ input: PreparedImageAnalysisInput) async throws -> Data
    func metadata(_ input: PreparedImageAnalysisInput) async throws -> Data
}

extension ImageAnalysisProvider {
    // Older injected providers do not acquire an invented metadata capability.
    func metadata(_ input: PreparedImageAnalysisInput) async throws -> Data {
        throw ImageAnalysisError.unavailable(.unsupportedCapability)
    }
}

struct UnavailableImageAnalysisProvider: ImageAnalysisProvider {
    let descriptor = ImageAnalysisProviderDescriptor(providerID: "apple.system-language-model.vision.v1", modelID: "SystemLanguageModel.default")
    let reason: ImageAnalysisUnavailableReason
    func availability() async -> ImageAnalysisAvailability { .unavailable(reason) }
    func analyze(_ input: PreparedImageAnalysisInput) async throws -> Data { throw ImageAnalysisError.unavailable(reason) }
}

enum LocalImageAnalysisFactory {
    static func makeService() -> any ImageAnalysisServing { makeSharedService() }

    static func makeSharedService() -> ImageAnalysisService {
        ImageAnalysisService(provider: makeProvider())
    }

    static func makeProvider() -> any ImageAnalysisProvider {
        if #available(macOS 27.0, *) {
            #if compiler(>=6.4) && canImport(FoundationModels, _version: 2.0) && !PICEDIT_DISABLE_FOUNDATION_MODELS
            return AppleImageAnalysisProvider()
            #else
            return UnavailableImageAnalysisProvider(reason: .sdkUnavailable)
            #endif
        }
        return UnavailableImageAnalysisProvider(reason: .unsupportedSystem)
    }
}
