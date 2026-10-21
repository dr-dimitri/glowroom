import Foundation
import CryptoKit

/// Reused by the vision task and the repository. It validates syntax, duplicate
/// keys, integer spelling and bounds before Codable can discard information.
struct PhotoMetadataJSONScanner {
    private let bytes: Data
    private(set) var rootMembers: [String:Range<Int>] = [:]
    private(set) var entryRanges: [Range<Int>] = []
    private var offset = 0, values = 0
    private let depthLimit: Int, valueLimit: Int
    init(_ data: Data, maximum: Int, depth: Int, values: Int) throws {
        guard data.count <= maximum else { throw PhotoMetadataError.limitExceeded(.jsonDocument) }
        bytes = data; depthLimit = depth; valueLimit = values
    }
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
                guard keys.count <= 64 else { throw PhotoMetadataError.validation(.unknownField) }
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
                if path == ["entries"] {
                    guard count <= PhotoMetadataLimits.maximumJSONEntries else { throw PhotoMetadataError.limitExceeded(.jsonEntries) }
                    guard offset-start <= PhotoMetadataLimits.maximumJSONEntryBytes else { throw PhotoMetadataError.limitExceeded(.jsonEntry) }
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
                guard offset-start <= PhotoMetadataLimits.maximumJSONEntryBytes,
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
            guard offset-start <= PhotoMetadataLimits.maximumJSONEntryBytes else { throw PhotoMetadataError.limitExceeded(.jsonEntry) }
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

/// Compare decoded wire shape with a freshly encoded typed value. Together with
/// the scanner this rejects unknown/inactive enum keys, duplicates, null-only
/// optional extras and wrong types; no untrusted dictionary grants authority.
enum PhotoMetadataJSONShape {
    static func check(_ input: Data, encoded: Data) throws {
        let a: Any, b: Any
        do { a = try JSONSerialization.jsonObject(with:input,options:[.fragmentsAllowed]); b = try JSONSerialization.jsonObject(with:encoded,options:[.fragmentsAllowed]) }
        catch { throw PhotoMetadataError.validation(.malformedJSON) }
        try match(a,b)
    }
    private static func match(_ a: Any, _ b: Any) throws {
        if let left = a as? [String:Any], let right = b as? [String:Any] {
            guard Set(left.keys) == Set(right.keys) else { throw PhotoMetadataError.validation(.unknownField) }
            for key in left.keys { try match(left[key]!,right[key]!) }; return
        }
        if let left = a as? [Any], let right = b as? [Any] {
            guard left.count == right.count else { throw PhotoMetadataError.validation(.malformedJSON) }
            for (l,r) in zip(left,right) { try match(l,r) }; return
        }
        if a is String, b is String { return }
        if a is NSNumber, b is NSNumber { return }
        if a is NSNull, b is NSNull { return }
        throw PhotoMetadataError.validation(.malformedJSON)
    }
}

enum PhotoMetadataInternalCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date,encoder in
            let value = date.timeIntervalSinceReferenceDate
            guard value.isFinite else { throw PhotoMetadataError.validation(.invalidSource) }
            var container = encoder.singleValueContainer(); try container.encode(String(format:"%016llx",value.bitPattern))
        }; return encoder
    }
    static func encode<T:Encodable>(_ value:T) throws -> Data { try encoder().encode(value) }
    static func decode<T:Codable>(_ type:T.Type,from data:Data,maximum:Int = PhotoMetadataLimits.maximumStoredRecordBlobBytes) throws -> T {
        do {
            var scanner = try PhotoMetadataJSONScanner(data,maximum:maximum,depth:32,values:PhotoMetadataLimits.maximumJSONValues)
            try scanner.validate()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let text = try decoder.singleValueContainer().decode(String.self)
                guard text.utf8.count == 16, let bits = UInt64(text,radix:16), text == String(format:"%016llx",bits), Double(bitPattern:bits).isFinite else { throw PhotoMetadataError.corruptStore }
                return Date(timeIntervalSinceReferenceDate:Double(bitPattern:bits))
            }
            let value = try decoder.decode(type,from:data)
            try PhotoMetadataJSONShape.check(data,encoded:encode(value)); return value
        } catch { throw PhotoMetadataError.corruptStore }
    }
    static func digest<T:Encodable>(kind:String,payload:T) throws -> String {
        let encoded = try encode(payload)
        var object = try JSONSerialization.jsonObject(with:encoded)
        func canonical(_ value:Any,key:String? = nil,root:Bool = false) -> Any {
            if var dictionary = value as? [String:Any] {
                if root || key == "header" { dictionary.removeValue(forKey:"id") }
                for name in dictionary.keys { dictionary[name] = canonical(dictionary[name]!,key:name) }
                return dictionary
            }
            if var array = value as? [Any] {
                array = array.map { canonical($0) }
                if ["fields","appliedFields","editedFields"].contains(key ?? ""), let strings = array as? [String] { return strings.sorted() }
                if ["decisions","expectedRecords","relocations"].contains(key ?? "") {
                    return array.sorted { a,b in
                        let l = a as? [String:Any] ?? [:], r = b as? [String:Any] ?? [:]
                        let field = key == "decisions" ? "conflictID" : key == "expectedRecords" ? "assetID" : "oldAssetID"
                        return (l[field] as? String ?? "") < (r[field] as? String ?? "")
                    }
                }; return array
            }
            if let text = value as? String, ["id","operationID","draftID","catalogSessionID","changeID","conflictID","exportID","reviewID","folderID"].contains(key ?? ""), let uuid = UUID(uuidString:text) { return uuid.uuidString.lowercased() }
            return value
        }
        object = canonical(object,root:true)
        let bytes = try JSONSerialization.data(withJSONObject:["operationKind":kind,"schemaVersion":1,"payload":object],options:[.sortedKeys,.withoutEscapingSlashes])
        return sha256(bytes)
    }
    static func sha256(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}

public enum PhotoMetadataModelResponseValidator {
    private struct Response: Codable { let schemaVersion:Int; let title:String; let description:String; let tags:[String]; let language:String }
    public static func validate(_ data:Data) throws -> PhotoTextFields {
        guard data.count <= PhotoMetadataLimits.maximumModelResponseBytes else { throw PhotoMetadataError.limitExceeded(.modelResponse) }
        var scanner = try PhotoMetadataJSONScanner(data,maximum:PhotoMetadataLimits.maximumModelResponseBytes,
            depth:PhotoMetadataLimits.maximumModelJSONDepth,values:PhotoMetadataLimits.maximumModelJSONValues)
        try scanner.validate()
        let response: Response
        do { response = try JSONDecoder().decode(Response.self,from:data) }
        catch { throw PhotoMetadataError.validation(.malformedJSON) }
        guard response.schemaVersion == 1 else { throw PhotoMetadataError.unsupportedVersion }
        try PhotoMetadataJSONShape.check(data,encoded:JSONEncoder().encode(response))
        let fields = try PhotoTextNormalization.normalize(.init(title:response.title,description:response.description,tags:response.tags,language:response.language),requireSuggestionContent:true)
        guard fields.language == "de_DE" else { throw PhotoMetadataError.validation(.invalidLanguage) }
        return fields
    }
}

enum PhotoMetadataPortableJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]; e.dateEncodingStrategy = .secondsSince1970; return e
    }
    static func decode(_ data:Data) throws -> (document:MetadataJSONDocument,accountedCost:Int) {
        var scanner = try PhotoMetadataJSONScanner(data,maximum:PhotoMetadataLimits.maximumJSONDocumentBytes,
            depth:PhotoMetadataLimits.maximumJSONDepth,values:PhotoMetadataLimits.maximumJSONValues)
        try scanner.validate()
        guard Set(scanner.rootMembers.keys) == ["schemaVersion","normalizationVersion","exportID","exportedAt","entries"],
              let entriesRange = scanner.rootMembers["entries"], data[entriesRange.lowerBound] == 91 else { throw PhotoMetadataError.validation(.unknownField) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        func member<T:Decodable>(_ key:String,_ type:T.Type) throws -> T {
            guard let range = scanner.rootMembers[key] else { throw PhotoMetadataError.validation(.malformedJSON) }
            do { return try decoder.decode(type,from:Data(data[range])) }
            catch { throw PhotoMetadataError.validation(.malformedJSON) }
        }
        let schema = try member("schemaVersion",Int.self), normalization = try member("normalizationVersion",Int.self)
        guard schema == 1, normalization == PhotoTextNormalization.version else { throw PhotoMetadataError.unsupportedVersion }
        let id = try member("exportID",UUID.self), date = try member("exportedAt",Date.self)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw PhotoMetadataError.validation(.invalidSource) }
        var entries: [MetadataJSONEntry] = [], ids = Set<String>(), retained = 0
        for range in scanner.entryRanges {
            // Reserve transient bounded entry decoding/shape checks BEFORE
            // allocating it. Never build a whole-document Foundation DOM.
            guard data.count + retained <= PhotoMetadataLimits.maximumRetainedImportCost - range.count*6 - 2_048 else { throw PhotoMetadataError.limitExceeded(.importReview) }
            let entry:MetadataJSONEntry = try autoreleasepool {
                let bytes = Data(data[range]), value:MetadataJSONEntry
                do { value = try decoder.decode(MetadataJSONEntry.self,from:bytes) }
                catch { throw PhotoMetadataError.validation(.malformedJSON) }
                try PhotoMetadataJSONShape.check(bytes,encoded:encoder().encode(value))
                try PhotoMetadataValidation.portableEntry(value)
                return value
            }
            guard ids.insert(entry.assetID).inserted else { throw PhotoMetadataError.validation(.duplicateIdentity) }
            retained += range.count*3 + 1_024
            guard data.count + retained <= PhotoMetadataLimits.maximumRetainedImportCost else { throw PhotoMetadataError.limitExceeded(.importReview) }
            entries.append(entry)
        }
        return (.init(exportID:id,exportedAt:date,entries:entries),retained)
    }
}
