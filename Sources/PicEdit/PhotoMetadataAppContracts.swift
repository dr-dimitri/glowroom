import Foundation
import PicEditCore

// Shared metadata contracts; Core values are defined in PhotoTextMetadata.
// Existing AIOriginalSourceFingerprint/ImageAnalysisAvailability remain unchanged.

public struct PhotoMetadataSelectionContext: Equatable, Sendable {
    public let assetID: String
    public let source: AIOriginalSourceFingerprint
    public let selectionSessionID: UUID
    public let selectionGeneration: UInt64
    public let catalogSessionID: UUID
    public let catalogGeneration: Int
    public let canModify: Bool
    public let isClosing: Bool
    public init(assetID: String, source: AIOriginalSourceFingerprint, selectionSessionID: UUID,
                selectionGeneration: UInt64, catalogSessionID: UUID, catalogGeneration: Int,
                canModify: Bool, isClosing: Bool) {
        self.assetID = assetID; self.source = source
        self.selectionSessionID = selectionSessionID; self.selectionGeneration = selectionGeneration
        self.catalogSessionID = catalogSessionID; self.catalogGeneration = catalogGeneration
        self.canModify = canModify; self.isClosing = isClosing
    }
}

public enum PhotoMetadataRasterPolicy: String, Sendable { case reuseValidated, refreshRaster }

public struct PhotoMetadataSuggestionRequest: Sendable {
    public let id: UUID
    public let context: PhotoMetadataSelectionContext
    public let lifecycleID: UUID
    public let formGeneration: UInt64
    public let expectedVersion: MetadataRecordVersion
    public let rasterPolicy: PhotoMetadataRasterPolicy
    public let language: String
    public init(id: UUID = UUID(), context: PhotoMetadataSelectionContext, lifecycleID: UUID,
                formGeneration: UInt64, expectedVersion: MetadataRecordVersion,
                rasterPolicy: PhotoMetadataRasterPolicy = .reuseValidated, language: String = "de_DE") {
        self.id = id; self.context = context; self.lifecycleID = lifecycleID
        self.formGeneration = formGeneration; self.expectedVersion = expectedVersion
        self.rasterPolicy = rasterPolicy; self.language = language
    }
}

public struct PhotoMetadataSuggestionResult: Sendable {
    public let request: PhotoMetadataSuggestionRequest
    public let fields: PhotoTextFields
    public let source: MetadataSourceReference
    public init(request: PhotoMetadataSuggestionRequest, fields: PhotoTextFields, source: MetadataSourceReference) {
        self.request = request; self.fields = fields; self.source = source
    }
}

public protocol PhotoMetadataSuggesting: Sendable {
    func availability() async -> ImageAnalysisAvailability
    func suggest(_ request: PhotoMetadataSuggestionRequest) async throws -> PhotoMetadataSuggestionResult
}

// C converts request.rasterPolicy to the Root-approved ImageAnalysisCachePolicy
// extension of the existing #6 request/preparer contract. Default remains reuse;
// refresh must bypass both decoder/render and analysis result keys, even if
// native file stamps equal the previous request. This file introduces no second
// analysis service, worker pool, cloud route or modifications to #8 contracts.
