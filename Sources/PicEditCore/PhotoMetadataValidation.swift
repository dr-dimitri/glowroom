import Foundation

/// Internal mutable row; immutable public values never grant write authority.
struct PhotoMetadataRow: Codable {
    var schemaVersion = 1
    var assetID: String
    var version: MetadataRecordVersion = .absent
    var confirmed: PhotoTextFields = .empty
    var confirmedAt: Date?
    var confirmedSource: MetadataSourceReference?
    var confirmedProvenance = MetadataConfirmedProvenance()
    var draft: PhotoMetadataDraft?
    var manualDraft: PhotoMetadataManualDraft?
    var isOrphaned = true
    var sourceChanged = false
    /// Current verified association after relocation. Historical analysis/source
    /// paths above remain unchanged and never become a new analysis assertion.
    var associationSource: MetadataSourceReference?
    init(assetID:String) { self.assetID = assetID }
    var value: PhotoMetadataRecord {
        .init(assetID:assetID,version:version,confirmed:confirmed,confirmedAt:confirmedAt,
            confirmedSource:confirmedSource,confirmedProvenance:confirmedProvenance,draft:draft,
            manualDraft:manualDraft,isOrphaned:isOrphaned,sourceChanged:sourceChanged,associationSource:associationSource)
    }
    mutating func advance(confirmed:Bool = false, ai:Bool = false, manual:Bool = false) throws {
        func next(_ value:Int64,_ change:Bool) throws -> Int64 {
            guard !change || value < Int64.max else { throw PhotoMetadataError.limitExceeded(.revisionExhausted) }; return value + (change ? 1 : 0)
        }
        version = try .init(recordRevision:next(version.recordRevision,true),confirmedRevision:next(version.confirmedRevision,confirmed),
            aiDraftRevision:next(version.aiDraftRevision,ai),manualDraftRevision:next(version.manualDraftRevision,manual))
    }
}

struct PhotoMetadataJournal: Codable {
    let change: MetadataCatalogChange
    var receipt: MetadataCatalogChangeReceipt
}

enum PhotoMetadataValidation {
    static func identifier(_ value:String,maximum:Int = PhotoMetadataLimits.maximumAssetIDBytes) throws {
        guard !value.isEmpty, value.utf8.count <= maximum, !value.utf8.contains(0),
              !value.unicodeScalars.contains(where:{ $0.value < 32 || (127...159).contains($0.value) }) else { throw PhotoMetadataError.validation(.invalidIdentifier) }
    }
    static func digest(_ value:String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func version(_ v:MetadataRecordVersion) throws {
        guard [v.recordRevision,v.confirmedRevision,v.aiDraftRevision,v.manualDraftRevision].allSatisfy({ $0 >= 0 && $0 <= v.recordRevision }) else { throw PhotoMetadataError.validation(.invalidRevision) }
    }
    static func fingerprint(_ source:MetadataSourceFingerprint) throws {
        try identifier(source.standardizedPath,maximum:PhotoMetadataLimits.maximumSourcePathBytes)
        guard source.isFileURL, source.standardizedPath.hasPrefix("/"),
              URL(fileURLWithPath:source.standardizedPath,isDirectory:false).standardizedFileURL.path == source.standardizedPath,
              source.fileSize >= 0, source.modifiedAt.timeIntervalSinceReferenceDate.isFinite else { throw PhotoMetadataError.validation(.invalidSource) }
    }
    static func native(_ stamp:MetadataNativeSourceStamp) throws {
        guard stamp.byteCount >= 0, stamp.identity.inode > 0 else { throw PhotoMetadataError.validation(.invalidSource) }
        for t in [stamp.modifiedAt,stamp.changedAt] + [stamp.birthTime].compactMap({$0}) {
            guard (0..<1_000_000_000).contains(t.nanoseconds) else { throw PhotoMetadataError.validation(.invalidSource) }
        }
    }
    static func raster(_ r:MetadataRasterIdentity) throws {
        guard digest(r.sha256), r.colorProfileSHA256.map(digest) != false,
              (1...PhotoMetadataLimits.maximumRasterPixelSize).contains(r.pixelWidth),
              (1...PhotoMetadataLimits.maximumRasterPixelSize).contains(r.pixelHeight),
              r.byteCount >= r.pixelWidth*r.pixelHeight, r.byteCount <= PhotoMetadataLimits.maximumRasterBytes,
              r.preprocessingVersion > 0 else { throw PhotoMetadataError.validation(.invalidProvenance) }
        try identifier(r.colorProfile,maximum:PhotoMetadataLimits.maximumProfileLabelBytes)
        try identifier(r.orientation,maximum:PhotoMetadataLimits.maximumOrientationBytes)
    }
    static func analysis(_ a:MetadataAnalysisProvenance) throws {
        for value in [a.providerID,a.modelID] { try identifier(value,maximum:PhotoMetadataLimits.maximumProviderIdentifierBytes) }
        if let version = a.modelVersion { try identifier(version,maximum:PhotoMetadataLimits.maximumProviderIdentifierBytes) }
        try fingerprint(a.source); try raster(a.raster)
        guard a.analyzedAt.timeIntervalSinceReferenceDate.isFinite, a.analysisTaskVersion > 0,
              a.analysisSchemaVersion == 1, a.metadataPromptVersion == 1, a.metadataSchemaVersion == 1 else { throw PhotoMetadataError.validation(.invalidProvenance) }
    }
    static func source(_ s:MetadataSourceReference) throws {
        try fingerprint(s.original)
        if let stamp = s.nativeStamp { try native(stamp); guard stamp.byteCount == s.original.fileSize else { throw PhotoMetadataError.validation(.invalidSource) } }
        if let a = s.analyzedRaster { try analysis(a); guard a.source == s.original else { throw PhotoMetadataError.validation(.invalidProvenance) } }
    }
    static func origin(_ o:MetadataFieldOrigin) throws {
        switch o {
        case .manual: break
        case .confirmedAI(let a): try analysis(a.analysis)
        case .imported(let i):
            guard i.originalRevision > 0 else { throw PhotoMetadataError.validation(.invalidRevision) }
            if let a = i.originalAI { try analysis(a.analysis) }
        }
    }
    static func provenance(_ p:MetadataConfirmedProvenance,fields:PhotoTextFields) throws {
        try origin(p.title); try origin(p.description); try origin(p.language)
        guard p.tags.count == fields.tags.count, p.tags.map(\.value) == fields.tags else { throw PhotoMetadataError.validation(.invalidProvenance) }
        for tag in p.tags { try origin(tag.origin) }
    }
    static func row(_ row:PhotoMetadataRow) throws {
        try identifier(row.assetID); try version(row.version)
        guard row.schemaVersion == 1, row.version.recordRevision > 0, try PhotoTextNormalization.normalize(row.confirmed) == row.confirmed else { throw PhotoMetadataError.validation(.invalidRevision) }
        try provenance(row.confirmedProvenance,fields:row.confirmed)
        guard (row.version.confirmedRevision > 0) == (row.confirmedAt != nil),
              row.confirmedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw PhotoMetadataError.validation(.invalidRevision) }
        if let source = row.confirmedSource { try self.source(source) }
        if let source = row.associationSource { try self.source(source) }
        if let d = row.draft {
            guard d.revision > 0, d.revision == row.version.aiDraftRevision,
                  d.baseConfirmedRevision <= row.version.confirmedRevision,
                  d.baseConfirmedRevision >= 0, d.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  d.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
                  try PhotoTextNormalization.normalize(d.fields,requireSuggestionContent:true) == d.fields,
                  (d.state == .accepted) == !d.appliedFields.isEmpty else { throw PhotoMetadataError.validation(.invalidDraftTransition) }
            try source(d.source)
            guard d.source.analyzedRaster != nil else { throw PhotoMetadataError.validation(.invalidProvenance) }
        }
        if let d = row.manualDraft {
            guard d.revision == row.version.manualDraftRevision, d.revision > 0,
                  d.baseConfirmedRevision >= 0, d.baseConfirmedRevision <= row.version.confirmedRevision,
                  d.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
                  try PhotoTextNormalization.normalize(d.fields) == d.fields else { throw PhotoMetadataError.validation(.invalidRevision) }
        }
    }
    static func reference(_ reference:MetadataCatalogFileReference) throws {
        if case .present(let hash,let bytes) = reference { guard digest(hash), bytes >= 0 else { throw PhotoMetadataError.validation(.invalidDigest) } }
    }
    static func catalog(_ snapshot:MetadataCatalogSnapshot) throws {
        try reference(snapshot.persistedReference)
        guard snapshot.catalogGeneration >= 0, snapshot.assets.count <= PhotoMetadataLimits.maximumCatalogAssets,
              Set(snapshot.assets.map(\.assetID)).count == snapshot.assets.count else { throw PhotoMetadataError.validation(.duplicateIdentity) }
        for asset in snapshot.assets { try identifier(asset.assetID); try source(asset.source) }
    }
    static func portableEntry(_ entry:MetadataJSONEntry) throws {
        try identifier(entry.assetID)
        guard entry.originalRevision > 0, entry.confirmedAt.timeIntervalSinceReferenceDate.isFinite,
              try PhotoTextNormalization.normalize(entry.fields) == entry.fields else { throw PhotoMetadataError.validation(.invalidRevision) }
        try provenance(entry.provenance,fields:entry.fields)
        if let s = entry.source {
            try fingerprint(s.original)
            if let a = s.analyzedRaster { try analysis(a); guard a.source == s.original else { throw PhotoMetadataError.validation(.invalidProvenance) } }
        }
    }
    static func change(_ change:MetadataCatalogChange) throws {
        try reference(change.before); try reference(change.after)
        guard case .present = change.after, change.before != change.after,
              !change.relocations.isEmpty, change.relocations.count <= PhotoMetadataLimits.maximumRelocationsPerChange else { throw PhotoMetadataError.validation(.invalidRelocation) }
        let old = change.relocations.map(\.oldAssetID), new = change.relocations.map(\.newAssetID)
        guard Set(old).count == old.count, Set(new).count == new.count,
              Set(old).isDisjoint(with:Set(new)),
              Set(change.expectedRecords.map(\.assetID)) == Set(old+new),
              Set(change.expectedRecords.map(\.assetID)).count == change.expectedRecords.count else { throw PhotoMetadataError.validation(.duplicateIdentity) }
        for expected in change.expectedRecords { try identifier(expected.assetID); try version(expected.version) }
        for move in change.relocations {
            try identifier(move.oldAssetID); try identifier(move.newAssetID); try source(move.oldSource); try source(move.newSource)
            let p = move.proof
            guard digest(p.bookmarkSHA256), p.oldRoot.isFileURL, p.newRoot.isFileURL,
                  !p.relativePath.isEmpty, !p.relativePath.hasPrefix("/"),
                  !p.relativePath.utf8.contains(0), !p.relativePath.split(separator:"/",omittingEmptySubsequences:false).contains(where:{ $0.isEmpty || $0 == "." || $0 == ".." }),
                  FilePathComparison.canonicalPath(p.oldRoot.appendingPathComponent(p.relativePath)) == FilePathComparison.canonicalPath(URL(fileURLWithPath:move.oldSource.original.standardizedPath,isDirectory:false)),
                  FilePathComparison.canonicalPath(p.newRoot.appendingPathComponent(p.relativePath)) == FilePathComparison.canonicalPath(URL(fileURLWithPath:move.newSource.original.standardizedPath,isDirectory:false)) else { throw PhotoMetadataError.validation(.invalidRelocation) }
            switch p.verification {
            case .sameNativeIdentity(let before,let after): try native(before); try native(after)
            case .sameAnalyzedRaster(let before,let after): try raster(before); try raster(after)
            case .userConfirmed,.unresolved: break
            }
        }
    }
    static func verified(_ move:MetadataRelocation,row:PhotoMetadataRow?) -> Bool {
        switch move.proof.verification {
        case .unresolved: return false
        case .userConfirmed: return true
        case .sameAnalyzedRaster(let before,let after):
            return before == after && move.oldSource.analyzedRaster?.raster == before && move.newSource.analyzedRaster?.raster == after
        case .sameNativeIdentity(let before,let after):
            let historical = row?.associationSource ?? row?.confirmedSource ?? row?.draft?.source
            let birthMatches = before.birthTime != nil && before.birthTime == after.birthTime && before.birthTime != .init(seconds:0,nanoseconds:0)
            let generationMatches = before.fileGeneration != nil && before.fileGeneration != 0 && before.fileGeneration == after.fileGeneration
            guard before.identity == after.identity, birthMatches || generationMatches,
                  before.byteCount == after.byteCount, before.modifiedAt == after.modifiedAt,
                  move.oldSource.nativeStamp == before, move.newSource.nativeStamp == after,
                  historical?.nativeStamp == before,
                  (try? PhotoMetadataFiles.nativeStamp(move.newSource.original)) == after else { return false }
            return true
        }
    }
}
