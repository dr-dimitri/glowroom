import Foundation

/// Enforces a bounded JSON grammar without treating a model string as trusted
/// metadata or allowing duplicate/unknown keys and model-provided provenance.
public struct ImageAnalysisSuggestionValidator: Sendable {
    public let maximumResponseBytes: Int
    public init(maximumResponseBytes: Int = 16_384) { self.maximumResponseBytes = maximumResponseBytes }

    public func validate(_ data: Data) throws -> ImageAnalysisSuggestions {
        guard maximumResponseBytes > 0 else { throw ImageAnalysisError.invalidRequest }
        guard data.count <= maximumResponseBytes else { throw ImageAnalysisError.invalidResponse }
        do {
            var parser = BoundedJSONParser(bytes: Array(data), maximumDepth: 6, maximumValues: 96)
            guard case .object(let root) = try parser.parse(),
                  Set(root.keys) == ["schemaVersion", "description", "attributes"],
                  case .number("1") = root["schemaVersion"],
                  case .string(let description) = root["description"],
                  case .array(let entries) = root["attributes"], entries.count <= 12 else {
                throw ImageAnalysisError.invalidResponse
            }
            let attributes = try entries.map { entry -> ImageAnalysisAttribute in
                guard case .object(let fields) = entry, Set(fields.keys) == ["category", "value"],
                      case .string(let rawCategory) = fields["category"],
                      let category = ImageAnalysisAttributeCategory(rawValue: rawCategory),
                      case .string(let value) = fields["value"] else { throw ImageAnalysisError.invalidResponse }
                return ImageAnalysisAttribute(category: category, value: value)
            }
            let suggestions = ImageAnalysisSuggestions(description: description, attributes: attributes)
            try suggestions.validate()
            return suggestions
        } catch { throw ImageAnalysisError.invalidResponse }
    }
}

private indirect enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
}

/// This parser allocates only after the byte limit check; depth and value counts also bound
/// adversarial nesting and container growth. Foundation validates individual JSON strings,
/// including Unicode surrogate pairs, while the parser enforces the full JSON grammar.
private struct BoundedJSONParser {
    let bytes: [UInt8]
    let maximumDepth: Int
    let maximumValues: Int
    private var offset = 0
    private var values = 0

    init(bytes: [UInt8], maximumDepth: Int, maximumValues: Int) {
        self.bytes = bytes
        self.maximumDepth = maximumDepth
        self.maximumValues = maximumValues
    }

    mutating func parse() throws -> JSONValue {
        let result = try value(depth: 1)
        whitespace()
        guard offset == bytes.count else { throw ImageAnalysisError.invalidResponse }
        return result
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth <= maximumDepth else { throw ImageAnalysisError.invalidResponse }
        guard values < maximumValues else { throw ImageAnalysisError.invalidResponse }
        values += 1
        whitespace()
        guard let byte = current else { throw ImageAnalysisError.invalidResponse }
        switch byte {
        case 123: return try object(depth: depth) // {
        case 91: return try array(depth: depth) // [
        case 34: return .string(try string())
        case 116: try literal([116, 114, 117, 101]); return .boolean(true)
        case 102: try literal([102, 97, 108, 115, 101]); return .boolean(false)
        case 110: try literal([110, 117, 108, 108]); return .null
        case 45, 48...57: return .number(try number())
        default: throw ImageAnalysisError.invalidResponse
        }
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        offset += 1
        whitespace()
        if consume(125) { return .object([:]) }
        var result: [String: JSONValue] = [:]
        while true {
            guard current == 34 else { throw ImageAnalysisError.invalidResponse }
            let key = try string()
            // Decode escapes before checking uniqueness: "value" and "\u0076alue" collide.
            guard result[key] == nil else { throw ImageAnalysisError.invalidResponse }
            whitespace()
            guard consume(58) else { throw ImageAnalysisError.invalidResponse } // :
            result[key] = try value(depth: depth + 1)
            whitespace()
            if consume(125) { return .object(result) }
            guard consume(44) else { throw ImageAnalysisError.invalidResponse } // ,
            whitespace()
        }
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        offset += 1
        whitespace()
        if consume(93) { return .array([]) }
        var result: [JSONValue] = []
        while true {
            result.append(try value(depth: depth + 1))
            whitespace()
            if consume(93) { return .array(result) }
            guard consume(44) else { throw ImageAnalysisError.invalidResponse }
            whitespace()
        }
    }

    private mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw ImageAnalysisError.invalidResponse }
        while let byte = current {
            guard byte >= 32 else { throw ImageAnalysisError.invalidResponse }
            offset += 1
            if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw ImageAnalysisError.invalidResponse }
            }
            if byte == 92 {
                guard current != nil else { throw ImageAnalysisError.invalidResponse }
                offset += 1
            }
        }
        throw ImageAnalysisError.invalidResponse
    }

    private mutating func number() throws -> String {
        let start = offset
        _ = consume(45)
        if !consume(48) {
            guard let first = current, (49...57).contains(first) else { throw ImageAnalysisError.invalidResponse }
            offset += 1
            digits()
        }
        if consume(46) {
            guard let first = current, (48...57).contains(first) else { throw ImageAnalysisError.invalidResponse }
            digits()
        }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            guard let first = current, (48...57).contains(first) else { throw ImageAnalysisError.invalidResponse }
            digits()
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private mutating func digits() {
        while let byte = current, (48...57).contains(byte) { offset += 1 }
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        guard bytes.count - offset >= expected.count,
              Array(bytes[offset..<(offset + expected.count)]) == expected else { throw ImageAnalysisError.invalidResponse }
        offset += expected.count
    }

    private var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        offset += 1
        return true
    }

    private mutating func whitespace() {
        while let byte = current, byte == 32 || byte == 9 || byte == 10 || byte == 13 { offset += 1 }
    }
}
