import Foundation

/// A strict, bounded input boundary. JSONDecoder alone cannot reject duplicate/unknown keys.
/// The small parser recognizes all JSON syntax and decodes escaped keys before comparison.
/// Parsing is synchronous CPU work and must be invoked away from MainActor by callers.
public struct EditProposalValidator: Sendable {
    public let maximumResponseBytes: Int
    public let maximumExplanationBytes: Int
    public let maximumNestingDepth: Int
    public let maximumJSONValues: Int

    public init(maximumResponseBytes: Int = 65_536, maximumExplanationBytes: Int = 2_048,
                maximumNestingDepth: Int = 8, maximumJSONValues: Int = 256) {
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumExplanationBytes = maximumExplanationBytes
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumJSONValues = maximumJSONValues
    }

    public func validate(_ data: Data, against settings: EditSettings) throws -> EditProposalValidationResult {
        try validateLimits()
        guard data.count <= maximumResponseBytes else { throw invalid(.responseTooLarge) }
        var parser = BoundedJSONParser(bytes: Array(data), maximumDepth: maximumNestingDepth,
                                       maximumValues: maximumJSONValues)
        let value = try parser.parse()
        return try validate(proposal(from: value), against: settings)
    }

    private func proposal(from value: JSONValue) throws -> EditProposal {
        guard case .object(let root) = value else { throw invalid(.invalidType) }
        try requireFields(root, allowed: ["schemaVersion", "changes", "explanation"],
                          required: ["schemaVersion", "changes"])
        guard case .number(let versionText) = root["schemaVersion"],
              let version = Int(versionText) else { throw invalid(.invalidType) }
        guard version == EditProposal.currentSchemaVersion else { throw invalid(.unsupportedSchemaVersion) }
        guard case .array(let rawChanges) = root["changes"] else { throw invalid(.invalidType) }
        guard rawChanges.count <= EditParameter.allCases.count else { throw invalid(.tooManyChanges) }
        let changes = try rawChanges.map { change -> EditParameterChange in
            guard case .object(let fields) = change else { throw invalid(.invalidType) }
            try requireFields(fields, allowed: ["parameter", "value"], required: ["parameter", "value"])
            guard case .string(let parameterID) = fields["parameter"] else { throw invalid(.invalidType) }
            guard let parameter = EditParameter(rawValue: parameterID) else { throw invalid(.unknownParameter) }
            guard case .number(let valueText) = fields["value"] else { throw invalid(.invalidType) }
            guard let value = Double(valueText), value.isFinite else { throw invalid(.nonFiniteValue) }
            return EditParameterChange(parameter: parameter, value: value)
        }
        let explanation: String?
        if let rawExplanation = root["explanation"] {
            guard case .string(let text) = rawExplanation else { throw invalid(.invalidType) }
            explanation = text
        } else {
            explanation = nil
        }
        return EditProposal(schemaVersion: version, changes: changes, explanation: explanation)
    }

    /// Uses the same bounded parser as single edits: nested patches do not cross a
    /// second, more permissive JSONDecoder boundary. Whole-group validation is atomic.
    public func validateLookGroup(_ data: Data, against settings: EditSettings) throws -> AIValidatedLookGroup {
        try validateLimits()
        guard data.count <= maximumResponseBytes else { throw invalid(.responseTooLarge) }
        var parser = BoundedJSONParser(bytes: Array(data), maximumDepth: maximumNestingDepth,
                                       maximumValues: maximumJSONValues)
        guard case .object(let root) = try parser.parse() else { throw invalid(.invalidType) }
        try requireFields(root, allowed: ["schemaVersion", "variants"], required: ["schemaVersion", "variants"])
        guard case .number(let rawVersion) = root["schemaVersion"], let version = Int(rawVersion) else {
            throw invalid(.invalidType)
        }
        guard version == AILookProposalGroup.currentSchemaVersion else { throw invalid(.unsupportedSchemaVersion) }
        guard case .array(let variants) = root["variants"] else { throw invalid(.invalidType) }
        guard variants.count == AILookID.allCases.count else { throw invalid(.invalidLookCount) }
        let looks = try variants.map { value -> AILookProposal in
            guard case .object(let fields) = value else { throw invalid(.invalidType) }
            try requireFields(fields, allowed: ["id", "name", "proposal"], required: ["id", "name", "proposal"])
            guard case .string(let rawID) = fields["id"] else { throw invalid(.invalidType) }
            guard let id = AILookID(rawValue: rawID) else { throw invalid(.invalidLookID) }
            guard case .string(let name) = fields["name"], let patch = fields["proposal"] else {
                throw invalid(.invalidType)
            }
            return AILookProposal(id: id, name: name, proposal: try proposal(from: patch))
        }
        return try validateLookGroup(AILookProposalGroup(schemaVersion: version, variants: looks), against: settings)
    }

    public func validateLookGroup(_ group: AILookProposalGroup, against settings: EditSettings) throws -> AIValidatedLookGroup {
        try validateLimits()
        guard group.schemaVersion == AILookProposalGroup.currentSchemaVersion else { throw invalid(.unsupportedSchemaVersion) }
        guard group.variants.count == AILookID.allCases.count else { throw invalid(.invalidLookCount) }
        guard Set(group.variants.map(\.id)) == Set(AILookID.allCases) else { throw invalid(.invalidLookID) }
        let patchValidator = EditProposalValidator(maximumResponseBytes: maximumResponseBytes,
                                                  maximumExplanationBytes: min(512, maximumExplanationBytes),
                                                  maximumNestingDepth: maximumNestingDepth,
                                                  maximumJSONValues: maximumJSONValues)
        var targets = Set<EditSettings>()
        var validated: [AILookID: AIValidatedLook] = [:]
        // Three tiny dependent validations remain serial: each must succeed before publishing
        // any group, and scheduling workers would cost more than these bounded scalar checks.
        for look in group.variants {
            guard !look.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  look.name.utf8.count <= 64 else { throw invalid(.invalidLookName) }
            guard case .changes(_, let target) = try patchValidator.validate(look.proposal, against: settings) else {
                throw invalid(.ineffectiveLook)
            }
            guard targets.insert(target).inserted else { throw invalid(.duplicateLookTargets) }
            validated[look.id] = AIValidatedLook(proposal: look, target: target)
        }
        return AIValidatedLookGroup(variants: AILookID.allCases.compactMap { validated[$0] })
    }

    public func validate(_ proposal: EditProposal, against settings: EditSettings) throws -> EditProposalValidationResult {
        try validateLimits()
        guard proposal.schemaVersion == EditProposal.currentSchemaVersion else { throw invalid(.unsupportedSchemaVersion) }
        guard proposal.changes.count <= EditParameter.allCases.count else { throw invalid(.tooManyChanges) }
        guard (proposal.explanation?.utf8.count ?? 0) <= maximumExplanationBytes else { throw invalid(.explanationTooLong) }
        guard EditParameter.allCases.allSatisfy({
            let value = $0.value(in: settings)
            return value.isFinite && $0.range.contains(value)
        }) else { throw invalid(.invalidBaseline) }
        var seen = Set<EditParameter>()
        // Validate the whole patch before deriving any target. Never partially accept a response.
        for change in proposal.changes {
            guard seen.insert(change.parameter).inserted else { throw invalid(.duplicateParameter) }
            guard change.value.isFinite else { throw invalid(.nonFiniteValue) }
            guard change.parameter.range.contains(change.value) else { throw invalid(.outOfRange) }
        }
        var target = settings
        for change in proposal.changes {
            target = try change.parameter.applying(change.value, to: target)
        }
        return target == settings ? .noChange : .changes(proposal: proposal, settings: target)
    }

    private func validateLimits() throws {
        guard maximumResponseBytes > 0, maximumExplanationBytes >= 0,
              maximumNestingDepth > 0, maximumNestingDepth <= 64,
              maximumJSONValues > 0 else { throw AIEditingError.invalidRequest }
    }

    private func requireFields(_ object: [String: JSONValue], allowed: Set<String>, required: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw invalid(.unknownField) }
        guard required.isSubset(of: Set(object.keys)) else { throw invalid(.missingField) }
    }
}

private func invalid(_ category: AIProposalValidationError) -> AIEditingError { .invalidResponse(category) }

/// Reuses the bounded JSON grammar, without treating a model string as trusted
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
    case boolean
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
        guard offset == bytes.count else { throw invalid(.malformedJSON) }
        return result
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth <= maximumDepth else { throw invalid(.nestingTooDeep) }
        guard values < maximumValues else { throw invalid(.tooManyJSONValues) }
        values += 1
        whitespace()
        guard let byte = current else { throw invalid(.malformedJSON) }
        switch byte {
        case 123: return try object(depth: depth) // {
        case 91: return try array(depth: depth) // [
        case 34: return .string(try string())
        case 116: try literal([116, 114, 117, 101]); return .boolean
        case 102: try literal([102, 97, 108, 115, 101]); return .boolean
        case 110: try literal([110, 117, 108, 108]); return .null
        case 45, 48...57: return .number(try number())
        default: throw invalid(.malformedJSON)
        }
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        offset += 1
        whitespace()
        if consume(125) { return .object([:]) }
        var result: [String: JSONValue] = [:]
        while true {
            guard current == 34 else { throw invalid(.malformedJSON) }
            let key = try string()
            // Decode escapes before checking uniqueness: "value" and "\u0076alue" collide.
            guard result[key] == nil else { throw invalid(.duplicateField) }
            whitespace()
            guard consume(58) else { throw invalid(.malformedJSON) } // :
            result[key] = try value(depth: depth + 1)
            whitespace()
            if consume(125) { return .object(result) }
            guard consume(44) else { throw invalid(.malformedJSON) } // ,
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
            guard consume(44) else { throw invalid(.malformedJSON) }
            whitespace()
        }
    }

    private mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw invalid(.malformedJSON) }
        while let byte = current {
            guard byte >= 32 else { throw invalid(.malformedJSON) }
            offset += 1
            if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw invalid(.malformedJSON) }
            }
            if byte == 92 {
                guard current != nil else { throw invalid(.malformedJSON) }
                offset += 1
            }
        }
        throw invalid(.malformedJSON)
    }

    private mutating func number() throws -> String {
        let start = offset
        _ = consume(45)
        if !consume(48) {
            guard let first = current, (49...57).contains(first) else { throw invalid(.malformedJSON) }
            offset += 1
            digits()
        }
        if consume(46) {
            guard let first = current, (48...57).contains(first) else { throw invalid(.malformedJSON) }
            digits()
        }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            guard let first = current, (48...57).contains(first) else { throw invalid(.malformedJSON) }
            digits()
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private mutating func digits() {
        while let byte = current, (48...57).contains(byte) { offset += 1 }
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        guard bytes.count - offset >= expected.count,
              Array(bytes[offset..<(offset + expected.count)]) == expected else { throw invalid(.malformedJSON) }
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
