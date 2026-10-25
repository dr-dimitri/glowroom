import Foundation

/// A deliberately small JSON-RPC/MCP boundary. No model output is deserialized
/// as an app command, source path, or database identifier.
public enum MCPJSON: Codable, Equatable, Sendable {
    case object([String: MCPJSON]), array([MCPJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: MCPJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([MCPJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: MCPJSON]? { if case .object(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public subscript(_ key: String) -> MCPJSON { object?[key] ?? .null }
    public static func encoded<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

public struct MCPFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var json: MCPJSON { .object(["code": .string(code), "message": .string(message)]) }
}

public enum MCPContract {
    public static let protocolVersion = "2025-06-18"
    public static let maximumRequestBytes = 1_024 * 1_024
    public static let maximumResponseBytes = 16 * 1_024 * 1_024
    public static let tools = ["session_inspect", "photos_query", "controls_list", "snapshot_get", "preview_render", "proposal_create", "proposal_get", "proposal_discard"]

    public static func decodeMessage(_ data: Data, maximum: Int = maximumRequestBytes) throws -> MCPJSON {
        guard data.count <= maximum else { throw MCPFailure("message_too_large", "Message limit exceeded.") }
        // JSONDecoder accepts duplicate object keys by retaining one value.
        // Reject that ambiguity before schema validation, including escaped keys.
        var scanner = MCPJSONStructure(bytes: Array(data))
        try scanner.validate()
        do { return try JSONDecoder().decode(MCPJSON.self, from: data) }
        catch { throw MCPFailure("invalid_json", "Invalid JSON message.") }
    }

    public static func validate(tool: String, arguments: MCPJSON) throws -> [String: MCPJSON] {
        guard tools.contains(tool), let args = arguments.object else { throw MCPFailure("invalid_arguments", "Unknown tool or invalid arguments.") }
        let allowed: Set<String>
        let required: Set<String>
        switch tool {
        case "photos_query": allowed = ["offset", "limit"]; required = []
        case "snapshot_get": allowed = ["photo_id"]; required = allowed
        case "preview_render": allowed = ["photo_id", "snapshot_id", "maximum_size", "request_id"]; required = ["photo_id", "snapshot_id"]
        case "proposal_create": allowed = ["photo_id", "snapshot_id", "request_id", "values"]; required = allowed
        case "proposal_get", "proposal_discard": allowed = ["request_id"]; required = allowed
        default: allowed = []; required = []
        }
        guard Set(args.keys).isSubset(of: allowed), required.isSubset(of: Set(args.keys)) else { throw MCPFailure("invalid_arguments", "Missing or unknown fields.") }
        for key in ["photo_id", "snapshot_id", "request_id"] where args[key] != nil {
            guard let s = args[key]?.string, !s.isEmpty, s.utf8.count <= 128 else { throw MCPFailure("invalid_arguments", "Invalid identifier.") }
        }
        for (key, range) in [("offset", 0...1_000_000_000), ("limit", 1...100), ("maximum_size", 1...2048)] where args[key] != nil {
            guard let n = args[key]?.number, n.isFinite, n.rounded() == n,
                  n >= Double(range.lowerBound), n <= Double(range.upperBound) else { throw MCPFailure("invalid_arguments", "Invalid pagination or image size.") }
        }
        if tool == "proposal_create" { _ = try patch(args["values"] ?? .null) }
        return args
    }

    public static func patch(_ value: MCPJSON) throws -> DevelopNumericPatch {
        guard let object = value.object, !object.isEmpty, object.count <= EditParameter.allCases.count else { throw MCPFailure("invalid_arguments", "Provide supported numeric controls.") }
        let values = try object.keys.sorted().map { key -> DevelopNumericValue in
            guard let parameter = EditParameter(rawValue: key), let number = object[key]?.number,
                  number.isFinite, parameter.range.contains(number) else { throw MCPFailure("invalid_arguments", "Unknown control or invalid value.") }
            return .init(parameter, number)
        }
        return DevelopNumericPatch(values)
    }

    public static var toolSchemas: MCPJSON {
        .array(tools.map { name in
            let string: MCPJSON = .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(128)])
            func integer(_ minimum: Int, _ maximum: Int) -> MCPJSON { .object(["type": .string("integer"), "minimum": .number(Double(minimum)), "maximum": .number(Double(maximum))]) }
            var properties: [String: MCPJSON] = [:], required: [String] = []
            switch name {
            case "photos_query": properties = ["offset": integer(0, 1_000_000_000), "limit": integer(1, 100)]
            case "snapshot_get": properties = ["photo_id": string]; required = ["photo_id"]
            case "preview_render": properties = ["photo_id": string, "snapshot_id": string, "maximum_size": integer(1, 2048), "request_id": string]; required = ["photo_id", "snapshot_id"]
            case "proposal_create":
                let controls = Dictionary(uniqueKeysWithValues: EditParameter.allCases.map { p in
                    (p.rawValue, MCPJSON.object(["type": .string("number"), "minimum": .number(p.range.lowerBound), "maximum": .number(p.range.upperBound)]))
                })
                properties = ["photo_id": string, "snapshot_id": string, "request_id": string,
                    "values": .object(["type": .string("object"), "properties": .object(controls), "additionalProperties": .bool(false), "minProperties": .number(1)])]
                required = ["photo_id", "snapshot_id", "request_id", "values"]
            case "proposal_get", "proposal_discard": properties = ["request_id": string]; required = ["request_id"]
            default: break
            }
            let readOnly = !["proposal_create", "proposal_discard"].contains(name)
            return .object(["name": .string(name), "description": .string(name == "proposal_create" ? "Prepare a global numeric correction for visible user review. Never applies edits." : name),
                "inputSchema": .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(MCPJSON.string)), "additionalProperties": .bool(false)]),
                "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(false), "idempotentHint": .bool(readOnly || name == "proposal_discard"), "openWorldHint": .bool(false)])])
        })
    }

    public static func textResult(_ json: MCPJSON, isError: Bool = false) -> MCPJSON {
        let text = (try? JSONEncoder().encode(json)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }
}

private struct MCPJSONStructure {
    let bytes: [UInt8]
    var offset = 0
    mutating func validate() throws {
        try value(depth: 0); whitespace()
        guard offset == bytes.count else { throw invalid }
    }
    private var invalid: MCPFailure { MCPFailure("invalid_json", "Invalid, excessively nested, or duplicate-key JSON.") }
    private mutating func whitespace() {
        while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    private mutating func string() throws -> String {
        guard offset < bytes.count, bytes[offset] == 34 else { throw invalid }
        let start = offset; offset += 1
        while offset < bytes.count {
            if bytes[offset] == 92 { offset += 2; continue }
            if bytes[offset] == 34 {
                offset += 1
                guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else { throw invalid }
                return result
            }
            offset += 1
        }
        throw invalid
    }
    private mutating func value(depth: Int) throws {
        guard depth < 64 else { throw invalid }
        whitespace(); guard offset < bytes.count else { throw invalid }
        switch bytes[offset] {
        case 123:
            offset += 1; whitespace()
            if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
            var keys = Set<String>()
            while true {
                whitespace(); let key = try string()
                guard keys.insert(key).inserted else { throw invalid }
                whitespace(); guard offset < bytes.count, bytes[offset] == 58 else { throw invalid }
                offset += 1; try value(depth: depth + 1); whitespace()
                guard offset < bytes.count else { throw invalid }
                if bytes[offset] == 125 { offset += 1; return }
                guard bytes[offset] == 44 else { throw invalid }; offset += 1
            }
        case 91:
            offset += 1; whitespace()
            if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                guard offset < bytes.count else { throw invalid }
                if bytes[offset] == 93 { offset += 1; return }
                guard bytes[offset] == 44 else { throw invalid }; offset += 1
            }
        case 34: _ = try string()
        default:
            let start = offset
            while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            guard offset > start else { throw invalid }
        }
    }
}
