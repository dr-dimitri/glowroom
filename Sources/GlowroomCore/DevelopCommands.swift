import Foundation

/// The first product command schema deliberately exposes only EditParameter.
/// Other tools keep their own typed adapters until their semantics are specified.
public enum DevelopCommandID: String, CaseIterable, Codable, Sendable {
    case get = "develop.get", controls = "develop.controls", patch = "develop.patch"
    case undo = "develop.undo", redo = "develop.redo", reset = "develop.reset"
    public var isMutation: Bool { self != .get && self != .controls }
}

public struct DevelopCommandRequestID: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let sequence: UInt64
    public init(sessionID: UUID, sequence: UInt64) { self.sessionID = sessionID; self.sequence = sequence }
}

/// An explicit immutable address, including A→B→A and restore protection.
/// Adapters serialize this opaque app-issued context; they never invent it from
/// the currently selected asset at mutation time.
public struct DevelopCommandTarget: Hashable, Sendable {
    public let snapshot: AIEditingSnapshot
    public let localRevision: Int64
    public init(snapshot: AIEditingSnapshot, localRevision: Int64) {
        self.snapshot = snapshot; self.localRevision = localRevision
    }
    public var assetID: String { snapshot.assetID }
}

public struct DevelopNumericValue: Codable, Hashable, Sendable {
    public let control: String
    public let value: Double
    public init(control: String, value: Double) { self.control = control; self.value = value }
    public init(_ parameter: EditParameter, _ value: Double) { self.init(control: parameter.rawValue, value: value) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.control == rhs.control && lhs.value.bitPattern == rhs.value.bitPattern
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(control); hasher.combine(value.bitPattern)
    }
}

/// An array, rather than a dictionary, preserves duplicate fields for rejection.
public struct DevelopNumericPatch: Codable, Hashable, Sendable {
    public let values: [DevelopNumericValue]
    public init(_ values: [DevelopNumericValue]) { self.values = values }
    public func applying(to settings: EditSettings) throws -> EditSettings {
        guard values.count <= EditParameter.allCases.count else { throw DevelopCommandError.invalidPatch }
        var seen = Set<String>(), result = settings
        for item in values {
            guard seen.insert(item.control).inserted, let control = EditParameter(rawValue: item.control),
                  item.value.isFinite, control.range.contains(item.value) else { throw DevelopCommandError.invalidPatch }
            result = try control.applying(item.value, to: result)
        }
        return result
    }
    public static func difference(from baseline: EditSettings, to settings: EditSettings) -> Self {
        Self(EditParameter.allCases.compactMap { parameter in
            let value = parameter.value(in: settings)
            return value == parameter.value(in: baseline) ? nil : DevelopNumericValue(parameter, value)
        })
    }
}

public struct DevelopCommandRequest: Hashable, Sendable {
    public static let schemaVersion = 1
    public let version: Int
    public let command: String
    public let id: DevelopCommandRequestID
    public let target: DevelopCommandTarget
    public let patch: DevelopNumericPatch?
    public init(_ command: DevelopCommandID, id: DevelopCommandRequestID, target: DevelopCommandTarget,
                patch: DevelopNumericPatch? = nil, version: Int = schemaVersion) {
        self.init(command: command.rawValue, id: id, target: target, patch: patch, version: version)
    }
    public init(command: String, id: DevelopCommandRequestID, target: DevelopCommandTarget,
                patch: DevelopNumericPatch? = nil, version: Int = schemaVersion) {
        self.version = version; self.command = command; self.id = id; self.target = target; self.patch = patch
    }
    public func validate() throws -> DevelopCommandID {
        guard version == Self.schemaVersion else { throw DevelopCommandError.unsupportedVersion }
        guard let command = DevelopCommandID(rawValue: command) else { throw DevelopCommandError.unknownCommand }
        guard (command == .patch) == (patch != nil) else { throw DevelopCommandError.invalidPatch }
        if let patch { _ = try patch.applying(to: target.snapshot.settings) }
        return command
    }
}

public enum DevelopCommandUnavailableReason: String, Codable, Sendable {
    case available, noPhoto, readOnly, loading, maintenance, comparison, activeTool, activeInput, noHistory
}

public struct DevelopCommandAvailability: Codable, Equatable, Sendable {
    public let reason: DevelopCommandUnavailableReason
    public var isAvailable: Bool { reason == .available }
    public init(_ reason: DevelopCommandUnavailableReason = .available) { self.reason = reason }
}

public struct DevelopControlDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let minimum: Double
    public let maximum: Double
    public init(_ parameter: EditParameter) {
        id = parameter.rawValue; minimum = parameter.range.lowerBound; maximum = parameter.range.upperBound
    }
}

public struct DevelopCommandDescriptor: Codable, Equatable, Sendable {
    public let id: DevelopCommandID
    public let schemaVersion: Int
    public let titleKey: String
    public let argumentType: String
    public let resultType: String
    public let isMutation: Bool
    public let availability: DevelopCommandAvailability
    public init(_ id: DevelopCommandID, availability: DevelopCommandAvailability = .init()) {
        self.id = id; schemaVersion = DevelopCommandRequest.schemaVersion; titleKey = id.rawValue
        argumentType = id == .patch ? "target+absoluteNumericPatch" : "target"
        resultType = id == .controls ? "numericControls" : "developmentSnapshot"
        isMutation = id.isMutation; self.availability = availability
    }
}

public struct DevelopCommandResult: Hashable, Sendable {
    public let resultID: UUID
    public let target: DevelopCommandTarget
    public let didChange: Bool
    public let controls: [DevelopControlDescriptor]
    public init(resultID: UUID = UUID(), target: DevelopCommandTarget, didChange: Bool,
                controls: [DevelopControlDescriptor] = []) {
        self.resultID = resultID; self.target = target; self.didChange = didChange; self.controls = controls
    }
}

public enum DevelopCommandError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedVersion, unknownCommand, invalidPatch, staleTarget, requestConflict, outcomeUnknown
    case unavailable(DevelopCommandUnavailableReason)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Die Version des Entwicklungsbefehls wird nicht unterstützt."
        case .unknownCommand: "Dieser Entwicklungsbefehl ist unbekannt."
        case .invalidPatch: "Die Korrektur enthält unbekannte, doppelte oder ungültige Reglerwerte."
        case .staleTarget: "Foto, Quelle oder Bearbeitung wurden geändert. Prüfe den aktuellen Zustand erneut."
        case .requestConflict: "Diese Anforderungskennung wurde bereits für einen anderen Auftrag verwendet."
        case .outcomeUnknown: "Ausgang unbekannt – Zustand erneut prüfen. Der Auftrag wird nicht erneut ausgeführt."
        case .unavailable: "Die Entwicklung ist gerade gesperrt. Beende aktive Werkzeuge oder Speicheroperationen."
        }
    }
}

/// Bounded session memory, not a persistent exactly-once journal. The high-water
/// mark recognizes all retired sequence numbers without retaining an ID set.
public struct DevelopCommandLedger: Sendable {
    public let sessionID: UUID
    public private(set) var highWater: UInt64 = 0
    public private(set) var retainedBytes = 0
    public var count: Int { entries.count }
    private struct Entry: Sendable {
        let request: DevelopCommandRequest
        let result: Result<DevelopCommandResult, DevelopCommandError>
        let bytes: Int
    }
    private var entries: [UInt64: Entry] = [:]
    private var order: [UInt64] = []
    public init(sessionID: UUID = UUID()) { self.sessionID = sessionID }
    public func cached(_ request: DevelopCommandRequest) throws -> Result<DevelopCommandResult, DevelopCommandError>? {
        guard request.id.sessionID == sessionID, request.id.sequence > 0 else { throw DevelopCommandError.outcomeUnknown }
        if let entry = entries[request.id.sequence] {
            guard entry.request == request else { throw DevelopCommandError.requestConflict }
            return entry.result
        }
        guard request.id.sequence > highWater else { throw DevelopCommandError.outcomeUnknown }
        return nil
    }
    public mutating func complete(_ request: DevelopCommandRequest, result: Result<DevelopCommandResult, DevelopCommandError>,
                                  retainedBytes: Int = 1_024) {
        precondition(request.id.sessionID == sessionID && request.id.sequence > highWater)
        highWater = request.id.sequence
        let cost = min(max(0, retainedBytes), Int.max - self.retainedBytes)
        entries[request.id.sequence] = Entry(request: request, result: result, bytes: cost); order.append(request.id.sequence)
        self.retainedBytes += cost
        // A second, conservative byte bound also retires large mask/repair
        // contexts. Their sequence remains unknown and can never execute again.
        while order.count > 256 || self.retainedBytes > 64 * 1_024 * 1_024 {
            if let entry = entries.removeValue(forKey: order.removeFirst()) { self.retainedBytes -= entry.bytes }
        }
    }
}
