import Foundation
import CryptoKit

/// One recursive validation boundary for typed values as well as decoded bytes.
/// Codable synthesis is representation only; it must never bypass this boundary.
public enum ArtifactValueValidation {
    public static func identifier(_ id:String) throws {
        guard !id.isEmpty, id.utf8.count <= 16_384, !id.utf8.contains(0) else { throw ArtifactContractError.invalidValue("asset ID") }
    }
    static func version(_ n:Int,_ expected:Int = 1) throws { guard n == expected else { throw ArtifactContractError.unsupportedVersion(n) } }
    public static func expected(_ v:EditingExpectedState) throws {
        _ = try EditingExpectedState(storeEpoch:v.storeEpoch,revision:v.revision,snapshot:v.snapshot)
        if let s = v.snapshot { try snapshot(s) }
    }
    public static func snapshot(_ v:EditingSnapshot) throws { try version(v.schemaVersion,2); _ = try EditingSnapshot(source:v.source,settings:v.settings) }
    public static func file(_ v:ArtifactFileDescriptor) throws { _ = try ArtifactFileDescriptor(sha256:v.sha256,bytes:v.bytes) }
    public static func format(_ v:ArtifactRasterFormat) throws {
        try version(v.schemaVersion); _ = try ArtifactPixelSize(width:v.size.width,height:v.size.height)
        guard v.alpha == (v.channels == .rgba ? .straight : .none), v.orientation == .up else { throw ArtifactContractError.unsupportedFormat }
    }
    public static func raster(_ v:RasterDescriptor) throws {
        try version(v.schemaVersion); try version(v.codecVersion); try format(v.format); try file(v.file)
    }
    public static func original(_ v:OriginalSourceFingerprint) throws {
        try version(v.schemaVersion); let r = v.nativeRevision
        _ = try OriginalSourceRevision(device:r.device,inode:r.inode,fileSize:r.fileSize,modifiedSeconds:r.modifiedSeconds,
            modifiedNanoseconds:r.modifiedNanoseconds,changedSeconds:r.changedSeconds,changedNanoseconds:r.changedNanoseconds)
        _ = try OriginalSourceFingerprint(standardizedPath:v.standardizedPath,fileSize:v.fileSize,modifiedAt:v.modifiedAt,
            nativeRevision:r,resourceIdentifier:v.resourceIdentifier,volumeIdentifier:v.volumeIdentifier,contentSHA256:v.contentSHA256)
        guard !v.standardizedPath.utf8.contains(0) else { throw ArtifactContractError.invalidValue("source path") }
    }
    public static func source(_ v:EditingSourceFingerprint) throws {
        switch v { case .original(let o): try original(o)
        case .artifact(let a): try version(a.schemaVersion); try raster(a.raster) }
    }
    public static func provenance(_ v:GenerationProvenance) throws {
        try version(v.schemaVersion); try source(v.parentSource); try snapshot(v.parentSnapshot)
        try version(v.renderedInput.schemaVersion); try format(v.renderedInput.format)
        _ = try RenderedInputFingerprint(format:v.renderedInput.format,canonicalPixelSHA256:v.renderedInput.canonicalPixelSHA256,pipelineVersion:v.renderedInput.pipelineVersion)
        try version(v.placement.schemaVersion)
        _ = try ArtifactPixelSize(width:v.placement.inputSize.width,height:v.placement.inputSize.height)
        _ = try ArtifactPixelSize(width:v.placement.outputSize.width,height:v.placement.outputSize.height)
        _ = try ArtifactCanvasPlacement(inputSize:v.placement.inputSize,outputSize:v.placement.outputSize,inputOriginX:v.placement.inputOriginX,inputOriginY:v.placement.inputOriginY)
        try version(v.parameters.schemaVersion); _ = try GenerationParameters(values:v.parameters.values)
        _ = try GenerationProviderIdentity(providerID:v.provider.providerID,modelID:v.provider.modelID,modelRevision:v.provider.modelRevision)
        _ = try GenerationProvenance(parentSource:v.parentSource,parentSnapshot:v.parentSnapshot,renderedInput:v.renderedInput,placement:v.placement,
            pipelineVersion:v.pipelineVersion,parameterVersion:v.parameterVersion,parameters:v.parameters,provider:v.provider,seed:v.seed,
            prompt:v.prompt,createdAt:v.createdAt,execution:v.execution,maskResourceIDs:v.maskResourceIDs,maskBindings:v.maskBindings)
        switch (v.parentSnapshot.source,v.parentSource) {
        case (.original,.original): break
        case (.artifact(let id),.artifact(let a)) where id == a.artifactID: break
        default: throw ArtifactContractError.invalidValue("parent source mismatch")
        }
    }
    public static func artifact(_ v:GeneratedArtifact) throws {
        try version(v.schemaVersion); try raster(v.raster); try provenance(v.provenance)
        _ = try GeneratedArtifact(id:v.id,raster:v.raster,provenance:v.provenance,resources:v.resources,manifestSHA256:v.manifestSHA256)
        for m in v.resources {
            try version(m.schemaVersion); try file(m.file)
            let expected = m.coordinateSpace == .inputCanvas ? v.provenance.placement.inputSize : v.provenance.placement.outputSize
            guard m.size == expected else { throw ArtifactContractError.invalidValue("mask geometry") }
            if (v.provenance.maskBindings ?? []).contains(where: { $0.resourceID == m.id }) {
                guard m.coordinateSpace == .inputCanvas else { throw ArtifactContractError.invalidValue("mask document space") }
            }
        }
        let body = GeneratedArtifactManifest(id:v.id,raster:v.raster,provenance:v.provenance,resources:v.resources)
        guard try ArtifactJSONCodec.digest(body) == v.manifestSHA256 else { throw ArtifactContractError.corruptArtifact }
    }
    public static func manifest(_ v:GeneratedArtifactManifest) throws {
        try version(v.schemaVersion)
        let hash = try ArtifactJSONCodec.digest(v)
        try artifact(GeneratedArtifact(id:v.id,raster:v.raster,provenance:v.provenance,resources:v.resources,manifestSHA256:hash))
    }
    public static func backup(_ v:EditingBackupManifest) throws {
        try version(v.schemaVersion); try file(v.database)
        guard v.createdAt.timeIntervalSinceReferenceDate.isFinite,v.artifacts.count <= 4_096,
              Set(v.artifacts.map(\.id)).count == v.artifacts.count else { throw ArtifactContractError.limitExceeded }
        for a in v.artifacts { try artifact(a) }
    }
    public static func remap(_ p:AssetRemapProposal) throws {
        try version(p.schemaVersion); try version(p.catalog.schemaVersion)
        guard p.entries.count <= 4_096,!p.entries.isEmpty,p.expectedByAsset.count <= 8_192,
              p.bookmarkData.count <= 1_048_576,(p.resolvedBookmarkData?.count ?? 0) <= 1_048_576,p.resolvedFolderURL.isFileURL,p.catalog.operationID == p.operationID.rawValue,
              Set(p.entries.map(\.oldAssetID)).count == p.entries.count,
              Set(p.entries.map(\.newAssetID)).count == p.entries.count,
              Set(p.entries.map(\.oldAssetID)).isDisjoint(with:Set(p.entries.map(\.newAssetID))) else { throw ArtifactContractError.limitExceeded }
        guard try ArtifactJSONCodec.digestBytes(p.bookmarkData) == p.bookmarkSHA256 else { throw ArtifactContractError.invalidValue("bookmark digest") }
        for e in p.entries {
            try identifier(e.oldAssetID); try identifier(e.newAssetID); try original(e.previous); try original(e.relocated)
            guard e.oldAssetID != e.newAssetID,!e.relativePath.isEmpty,!e.relativePath.hasPrefix("/"),
                  !e.relativePath.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0 == "." || $0 == ".."}),
                  !e.relativePath.utf8.contains(0),e.relativePath.utf8.count <= 16_384,
                  p.expectedByAsset[e.oldAssetID] != nil,p.expectedByAsset[e.newAssetID] != nil else { throw ArtifactContractError.invalidValue("remap entry") }
        }
        for (id,e) in p.expectedByAsset { try identifier(id); try expected(e); guard e.storeEpoch == p.expectedStoreEpoch else { throw ArtifactContractError.staleEpoch } }
    }
}

/// Strict syntax/shape preflight precedes Codable. Each persisted blob has an
/// explicit byte/value/depth cap. No authority is minted by a decoded DTO.
public enum ArtifactJSONCodec {
    public static func encode<T:Encodable>(_ value:T) throws -> Data {
        let bytes = try EditingContractJSON.encoder().encode(value)
        if value is EditSettings || value is EditingSnapshot || value is GeneratedArtifact || value is GeneratedArtifactManifest {
            guard bytes.count <= EditSettings.maximumEncodedBytes else { throw ArtifactContractError.limitExceeded }
        }
        return bytes
    }
    public static func digest<T:Encodable>(_ value:T) throws -> ArtifactDigest { try digestBytes(encode(value)) }
    public static func digestBytes(_ bytes:Data) throws -> ArtifactDigest {
        try ArtifactDigest(sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
    }
    private static func validateDecoded<T>(_ value:T) throws {
        switch value {
        case let v as GeneratedArtifact: try ArtifactValueValidation.artifact(v)
        case let v as GeneratedArtifactManifest: try ArtifactValueValidation.manifest(v)
        case let v as EditingBackupManifest: try ArtifactValueValidation.backup(v)
        case let v as AssetRemapProposal: try ArtifactValueValidation.remap(v)
        case let v as EditingSnapshot: try ArtifactValueValidation.snapshot(v)
        case let v as EditingExpectedState: try ArtifactValueValidation.expected(v)
        case let v as ArtifactFileDescriptor: try ArtifactValueValidation.file(v)
        case let v as ArtifactRasterFormat: try ArtifactValueValidation.format(v)
        case let v as RasterDescriptor: try ArtifactValueValidation.raster(v)
        case let v as OriginalSourceFingerprint: try ArtifactValueValidation.original(v)
        case let v as EditingSourceFingerprint: try ArtifactValueValidation.source(v)
        case let v as ArtifactSourceFingerprint: try ArtifactValueValidation.source(.artifact(v))
        case let v as GenerationProvenance: try ArtifactValueValidation.provenance(v)
        case let v as MaskDocument: try v.validate()
        case let v as GenerationMaskBinding: try v.validate()
        case let v as MaskRasterTransform: try v.validate()
        case let v as LocalAdjustment: try v.validate()
        case let v as LocalAdjustmentMask: try v.validate()
        case let v as LocalMaskShape: try v.validate()
        case let v as LocalAdjustmentSettings:
            guard v == v.normalized else { throw ArtifactContractError.invalidValue("local adjustment settings") }
        case let v as EditSettings:
            guard v == v.normalized else { throw ArtifactContractError.invalidValue("settings") }
            try v.validateLocalAdjustments()
            try v.developGeometry.validate()
        case let v as DevelopColorSettings:
            guard v == v.normalized else { throw ArtifactContractError.invalidValue("develop color settings") }
        case let v as DevelopGeometry:
            guard v == v.normalized else { throw ArtifactContractError.invalidValue("develop geometry") }
            try v.validate()
        case let v as OriginalSourceRevision:
            _ = try OriginalSourceRevision(device:v.device,inode:v.inode,fileSize:v.fileSize,modifiedSeconds:v.modifiedSeconds,modifiedNanoseconds:v.modifiedNanoseconds,changedSeconds:v.changedSeconds,changedNanoseconds:v.changedNanoseconds)
        case let v as GenerationParameters: try ArtifactValueValidation.version(v.schemaVersion);_ = try GenerationParameters(values:v.values)
        case let v as GenerationProviderIdentity: _ = try GenerationProviderIdentity(providerID:v.providerID,modelID:v.modelID,modelRevision:v.modelRevision)
        case let v as ArtifactCanvasPlacement:
            try ArtifactValueValidation.version(v.schemaVersion);_ = try ArtifactCanvasPlacement(inputSize:v.inputSize,outputSize:v.outputSize,inputOriginX:v.inputOriginX,inputOriginY:v.inputOriginY)
        case let v as ArtifactPixelRect: _ = try ArtifactPixelRect(x:v.x,y:v.y,size:v.size)
        case let v as ArtifactMaskDescriptor: try ArtifactValueValidation.version(v.schemaVersion);try ArtifactValueValidation.file(v.file)
        case let v as RenderedInputFingerprint:
            try ArtifactValueValidation.version(v.schemaVersion);try ArtifactValueValidation.format(v.format);_ = try RenderedInputFingerprint(format:v.format,canonicalPixelSHA256:v.canonicalPixelSHA256,pipelineVersion:v.pipelineVersion)
        default: break // private SQL wire envelopes recursively validate below
        }
    }
    public static func decode<T:Codable>(_ type:T.Type,from data:Data,maximum:Int? = nil) throws -> T {
        // Only envelopes that actually contain editing snapshots receive the
        // larger budget. Small ownership/capability DTO limits stay unchanged.
        let editEnvelope = type == EditingSnapshot.self || type == EditSettings.self || type == EditingExpectedState.self
            || type == GeneratedArtifact.self || type == GeneratedArtifactManifest.self || type == GenerationProvenance.self
            || type == LocalAdjustment.self || type == LocalAdjustmentMask.self || type == LocalMaskShape.self
            || type == LocalMaskRaster.self || type == DevelopGeometry.self
        let maximum = maximum ?? (editEnvelope ? EditSettings.maximumEncodedBytes : 65_536)
        guard maximum > 0, maximum <= 67_108_864,data.count <= maximum else { throw ArtifactContractError.limitExceeded }
        do {
            var scan = ArtifactJSONScanner(data,maximum:maximum); try scan.validate()
            let value = try EditingContractJSON.decoder().decode(type,from:data)
            try PhotoMetadataJSONShape.check(data,encoded:encode(value))
            try validateDecoded(value)
            return value
        } catch let error as ArtifactContractError { throw error }
        catch { throw ArtifactContractError.invalidValue("malformed artifact JSON") }
    }
}

struct ArtifactJSONScanner {
    private let bytes: Data
    private(set) var rootMembers: [String:Range<Int>] = [:]
    private(set) var entryRanges: [Range<Int>] = []
    private var offset = 0, values = 0
    private let depthLimit: Int, valueLimit: Int
    init(_ data:Data,maximum:Int) { bytes = data; depthLimit = 64; valueLimit = 2_000_000 }
    mutating func validate() throws {
        try value(depth:0,path:[]); whitespace()
        guard offset == bytes.count else { throw PhotoMetadataError.validation(.malformedJSON) }
    }
    private mutating func whitespace() { while offset < bytes.count, [9,10,13,32].contains(bytes[offset]) { offset += 1 } }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace(); guard offset < bytes.count, bytes[offset] == byte else { return false }; offset += 1; return true
    }
    private mutating func value(depth: Int, path: [String]) throws {
        guard depth <= depthLimit else { throw PhotoMetadataError.limitExceeded(.jsonDepth) }
        values += 1; guard values <= valueLimit else { throw PhotoMetadataError.limitExceeded(.jsonValues) }
        whitespace(); guard offset < bytes.count else { throw PhotoMetadataError.validation(.malformedJSON) }
        switch bytes[offset] {
        case 123:
            offset += 1; var keys = Set<String>()
            if take(125) { return }
            while true {
                let key = try string()
                guard keys.insert(key).inserted else { throw PhotoMetadataError.validation(.duplicateKey) }
                // Every supported metadata object has fewer than 32 members;
                // reject broad malformed objects before their key set grows.
                guard keys.count <= 1_000_000 else { throw PhotoMetadataError.validation(.unknownField) }
                guard take(58) else { throw PhotoMetadataError.validation(.malformedJSON) }
                whitespace(); let memberStart = offset
                try value(depth:depth+1,path:path+[key])
                if depth == 0 { rootMembers[key] = memberStart..<offset }
                if take(125) { break }; guard take(44) else { throw PhotoMetadataError.validation(.malformedJSON) }
            }
        case 91:
            offset += 1; var count = 0
            if take(93) { return }
            while true {
                whitespace(); let start = offset
                try value(depth:depth+1,path:path+["[]"]); count += 1
                if false {
                    guard count <= 4_096 else { throw PhotoMetadataError.limitExceeded(.jsonEntries) }
                    guard offset-start <= 2_097_152 else { throw PhotoMetadataError.limitExceeded(.jsonEntry) }
                    entryRanges.append(start..<offset)
                }
                if take(93) { break }; guard take(44) else { throw PhotoMetadataError.validation(.malformedJSON) }
            }
        case 34: _ = try string()
        case 110: try literal("null")
        case 116: try literal("true")
        case 102: try literal("false")
        default: try number(key:path.last)
        }
    }
    private mutating func literal(_ text: String) throws {
        let wanted = Array(text.utf8)
        guard bytes.count-offset >= wanted.count, Array(bytes[offset..<(offset+wanted.count)]) == wanted else { throw PhotoMetadataError.validation(.malformedJSON) }
        offset += wanted.count
    }
    private mutating func string() throws -> String {
        whitespace(); let start = offset
        guard offset < bytes.count, bytes[offset] == 34 else { throw PhotoMetadataError.validation(.malformedJSON) }
        offset += 1
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 {
                guard offset-start <= 2_097_152,
                      let result = try? JSONDecoder().decode(String.self,from:Data(bytes[start..<offset])) else { throw PhotoMetadataError.validation(.malformedJSON) }
                return result
            }
            guard byte >= 32 else { throw PhotoMetadataError.validation(.malformedJSON) }
            if byte == 92 {
                guard offset < bytes.count else { throw PhotoMetadataError.validation(.malformedJSON) }
                let escaped = bytes[offset]; offset += 1
                if escaped == 117 {
                    guard bytes.count-offset >= 4, bytes[offset..<(offset+4)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw PhotoMetadataError.validation(.malformedJSON) }
                    offset += 4
                } else { guard [34,47,92,98,102,110,114,116].contains(escaped) else { throw PhotoMetadataError.validation(.malformedJSON) } }
            }
            guard offset-start <= 2_097_152 else { throw PhotoMetadataError.limitExceeded(.jsonEntry) }
        }
        throw PhotoMetadataError.validation(.malformedJSON)
    }
    private mutating func number(key: String?) throws {
        let start = offset
        if offset < bytes.count, bytes[offset] == 45 { offset += 1 }
        guard offset < bytes.count else { throw PhotoMetadataError.validation(.malformedJSON) }
        if bytes[offset] == 48 { offset += 1 }
        else {
            guard (49...57).contains(bytes[offset]) else { throw PhotoMetadataError.validation(.malformedJSON) }
            while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
        }
        var integral = true
        if offset < bytes.count, bytes[offset] == 46 {
            integral = false; offset += 1; let first = offset
            while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
            guard first < offset else { throw PhotoMetadataError.validation(.malformedJSON) }
        }
        if offset < bytes.count, bytes[offset] == 101 || bytes[offset] == 69 {
            integral = false; offset += 1
            if offset < bytes.count, bytes[offset] == 43 || bytes[offset] == 45 { offset += 1 }
            let first = offset
            while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
            guard first < offset else { throw PhotoMetadataError.validation(.malformedJSON) }
        }
        guard offset-start <= 128 else { throw PhotoMetadataError.validation(.malformedJSON) }
        let text = String(decoding:bytes[start..<offset],as:UTF8.self)
        let integerKeys: Set<String> = ["schemaVersion","normalizationVersion","originalRevision","fileSize","pixelWidth","pixelHeight","byteCount","preprocessingVersion","analysisTaskVersion","analysisSchemaVersion","metadataPromptVersion","metadataSchemaVersion","recordRevision","confirmedRevision","aiDraftRevision","manualDraftRevision","revision","baseConfirmedRevision","generation","catalogGeneration","seconds","nanoseconds","device","inode","fileGeneration"]
        if let key, integerKeys.contains(key) {
            guard integral, Int64(text) != nil || UInt64(text) != nil else { throw PhotoMetadataError.validation(.invalidRevision) }
        } else { guard let value = Double(text), value.isFinite else { throw PhotoMetadataError.validation(.malformedJSON) } }
    }
}


extension ArtifactContractError: LocalizedError {
    public var errorDescription:String? {
        switch self {
        case .staleEpoch: return "Die Bearbeitungsdaten wurden wiederhergestellt oder neu geladen. Bitte den aktuellen Stand neu laden."
        case .staleSnapshot: return "Quelle oder Regler wurden inzwischen geändert. Das verspätete Ergebnis wurde nicht übernommen."
        case .conflictingCommit: return "Diese Vorgangskennung gehört bereits zu einem anderen Auftrag. Vorhandene Daten bleiben erhalten."
        case .sourceChanged: return "Der aktuelle Quellenbezug ist geändert oder nicht mehr sicher nachweisbar. Bitte das Bild neu laden."
        case .missingArtifact: return "Die gespeicherte Rasterquelle fehlt. Bitte eine vollständige Bearbeitungssicherung wiederherstellen."
        case .corruptArtifact: return "Die gespeicherte Rasterquelle oder ihre Prüfsumme ist beschädigt."
        case .invalidCapability: return "Die sichere Dateifreigabe ist nicht mehr gültig. Bitte den Vorgang neu starten."
        case .unsupportedFormat: return "Dieses Rasterformat, Farbprofil oder diese Bittiefe wird nicht unterstützt."
        case .limitExceeded: return "Der Vorgang überschreitet eine Speicher-, Raster- oder Dateigrenze."
        case .ambiguousCommit: return "Der dauerhafte Abschluss konnte nicht eindeutig bestätigt werden. Bitte vor einem neuen Auftrag den gespeicherten Stand neu laden."
        case .unsupportedVersion(let n): return "Die gespeicherten Bearbeitungsdaten verwenden die nicht unterstützte Version \(n)."
        case .invalidValue: return "Die Bearbeitungsdaten enthalten ungültige oder unvollständige Werte. Vorhandene Daten bleiben erhalten."
        }
    }
}
