import PicEditCore

protocol ImageAnalysisServing: Sendable {
    var descriptor: ImageAnalysisProviderDescriptor { get }
    func availability() async -> ImageAnalysisAvailability
    func analyze(_ request: ImageAnalysisRequest) async throws -> ImageAnalysisResult
    func invalidate() async
}
