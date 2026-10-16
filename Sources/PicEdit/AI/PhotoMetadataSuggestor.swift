import Foundation
import PicEditCore

/// A typed observer of the existing shared vision scheduler. It has no worker,
/// model pool, cloud route or independent inference admission of its own.
struct LocalPhotoMetadataSuggestor: PhotoMetadataSuggesting {
    static let promptVersion = 1
    static let schemaVersion = 1
    let service: ImageAnalysisService

    func availability() async -> ImageAnalysisAvailability { await service.availability() }

    func suggest(_ request: PhotoMetadataSuggestionRequest) async throws -> PhotoMetadataSuggestionResult {
        guard request.language == "de_DE" else { throw ImageAnalysisError.unavailable(.unsupportedLanguage) }
        guard request.context.canModify, !request.context.isClosing else { throw ImageAnalysisError.invalidRequest }
        let token = AIEditingToken(editSessionID: request.context.catalogSessionID, editGeneration: 0,
            selectionSessionID: request.context.selectionSessionID, selectionGeneration: request.context.selectionGeneration)
        let snapshot = AIEditingSnapshot(assetID: request.context.assetID, source: .original(request.context.source),
            settings: .neutral, token: token)
        let analysis = ImageAnalysisRequest(id: request.id, snapshot: snapshot, inputKind: .originalPreview,
            language: request.language, lifecycleID: request.lifecycleID,
            cachePolicy: request.rasterPolicy == .refreshRaster ? .refreshRaster : .reuseValidated)
        let payload = try await service.metadata(analysis)
        try Task.checkCancellation()
        guard payload.request == analysis, payload.provenance.source == .original(request.context.source),
              payload.provenance.inputKind == .originalPreview else { throw ImageAnalysisError.staleSource }
        let fields = try PhotoMetadataModelResponseValidator.validate(payload.data)
        guard case .original(let observed) = payload.sourceStamp else { throw ImageAnalysisError.invalidRequest }
        let native = MetadataNativeSourceStamp(identity: MetadataFileIdentity(device: Int64(observed.device), inode: observed.inode),
            byteCount: observed.byteCount,
            modifiedAt: MetadataTimestamp(seconds: observed.modifiedSeconds, nanoseconds: Int32(observed.modifiedNanoseconds)),
            changedAt: MetadataTimestamp(seconds: observed.changedSeconds, nanoseconds: Int32(observed.changedNanoseconds)))
        return PhotoMetadataSuggestionResult(request: request, fields: fields,
            source: MetadataSourceReference(original: .metadata(request.context.source), nativeStamp: native,
                analyzedRaster: .metadata(payload.provenance)))
    }
}

extension MetadataSourceFingerprint {
    static func metadata(_ source: AIOriginalSourceFingerprint) -> Self {
        Self(standardizedPath: source.standardizedPath, isFileURL: source.isFileURL,
            modifiedAt: source.modifiedAt, fileSize: source.fileSize)
    }
}

extension MetadataAnalysisProvenance {
    static func metadata(_ source: ImageAnalysisProvenance) -> Self {
        guard case .original(let original) = source.source else { preconditionFailure("Metadata requires imported-original provenance") }
        return Self(providerID: source.providerID, modelID: source.modelID, modelVersion: source.modelVersion,
            analyzedAt: source.analyzedAt, source: .metadata(original),
            raster: MetadataRasterIdentity(sha256: source.rasterSHA256, pixelWidth: source.pixelWidth,
                pixelHeight: source.pixelHeight, byteCount: source.byteCount, colorProfile: source.colorProfile,
                colorProfileSHA256: source.colorProfileSHA256, orientation: source.orientation,
                preprocessingVersion: source.preprocessingVersion),
            analysisTaskVersion: source.taskVersion, analysisSchemaVersion: source.schemaVersion,
            metadataPromptVersion: LocalPhotoMetadataSuggestor.promptVersion,
            metadataSchemaVersion: LocalPhotoMetadataSuggestor.schemaVersion)
    }
}
