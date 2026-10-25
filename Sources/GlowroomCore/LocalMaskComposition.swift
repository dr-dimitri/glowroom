import Foundation

/// Ordered soft-mask algebra. Coverage remains continuous throughout composition.
public enum LocalMaskOperation: String, CaseIterable, Codable, Hashable, Sendable {
    case add, subtract, intersect

    public var title: String {
        switch self { case .add: "Hinzufügen"; case .subtract: "Abziehen"; case .intersect: "Schneiden" }
    }
    public func combine(_ accumulated: Double, _ component: Double) -> Double {
        switch self {
        case .add: max(accumulated, component)
        case .subtract: accumulated * (1 - component)
        case .intersect: accumulated * component
        }
    }
}

/// One independently editable selection, stored in original oriented source coordinates.
public struct LocalMaskComponent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var operation: LocalMaskOperation
    public var shape: LocalMaskShape
    public var refinement: MaskDocument?
    public var feather: Double
    public var isInverted: Bool

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true,
                operation: LocalMaskOperation = .add, shape: LocalMaskShape,
                refinement: MaskDocument? = nil, feather: Double = 0.5, isInverted: Bool = false) throws {
        self.id = id; self.name = name; self.isEnabled = isEnabled; self.operation = operation
        self.shape = shape; self.refinement = refinement; self.feather = feather; self.isInverted = isInverted
        try validate()
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 256, !name.utf8.contains(0), feather.isFinite, (0...1).contains(feather) else {
            throw ArtifactContractError.invalidValue("local mask component")
        }
        try shape.validate()
        if let refinement {
            try refinement.validate()
            guard !refinement.isInverted else { throw ArtifactContractError.invalidValue("local mask refinement") }
        }
    }
    public func selectionMask() throws -> LocalAdjustmentMask {
        // A validated component is exactly the legacy renderer's selection path.
        try LocalAdjustmentMask(shape: shape, isInverted: isInverted, feather: feather, refinement: refinement)
    }
    private enum CodingKeys: String, CodingKey { case id, name, isEnabled, operation, shape, refinement, feather, isInverted }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: v.decode(UUID.self, forKey: .id), name: v.decode(String.self, forKey: .name),
            isEnabled: v.decode(Bool.self, forKey: .isEnabled), operation: v.decode(LocalMaskOperation.self, forKey: .operation),
            shape: v.decode(LocalMaskShape.self, forKey: .shape), refinement: v.decodeIfPresent(MaskDocument.self, forKey: .refinement),
            feather: v.decode(Double.self, forKey: .feather), isInverted: v.decode(Bool.self, forKey: .isInverted))
    }
}

/// Flat v1 list; deliberately no references to other masks or recursive graphs.
public struct LocalMaskComposition: Codable, Hashable, Sendable {
    public static let maximumComponents = 16
    public let schemaVersion: Int
    public var components: [LocalMaskComponent]
    public init(components: [LocalMaskComponent]) throws {
        schemaVersion = 1; self.components = components
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ArtifactContractError.unsupportedVersion(schemaVersion) }
        guard components.count <= Self.maximumComponents,
              Set(components.map(\.id)).count == components.count else { throw ArtifactContractError.limitExceeded }
        for component in components { try component.validate() }
        if let first = components.first(where: \.isEnabled), first.operation != .add {
            let precedingAdd = components.prefix { $0.id != first.id }.first { $0.operation == .add }
            let instruction = precedingAdd.map { " „\($0.name)“ muss davor aktiv bleiben." } ?? " „\(first.name)“ muss Hinzufügen verwenden."
            throw ArtifactContractError.invalidValue("Erster aktiver Bestandteil muss Hinzufügen verwenden." + instruction)
        }
    }
    /// Independent scalar reference used by numeric fixtures and developer tools.
    public func coverage(_ values: [Double], isInverted: Bool = false, opacity: Double = 1) throws -> Double {
        try validate()
        guard values.count == components.count, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              opacity.isFinite, (0...1).contains(opacity) else { throw ArtifactContractError.invalidValue("mask coverage samples") }
        var result = 0.0
        for (component, value) in zip(components, values) where component.isEnabled {
            result = component.operation.combine(result, component.isInverted ? 1 - value : value)
        }
        return (isInverted ? 1 - result : result) * opacity
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, components }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let version = try v.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ArtifactContractError.unsupportedVersion(version) }
        // Bound the list before materializing any further raster payloads.
        var list = try v.nestedUnkeyedContainer(forKey: .components)
        if let count = list.count, count > Self.maximumComponents { throw ArtifactContractError.limitExceeded }
        var components: [LocalMaskComponent] = []
        while !list.isAtEnd {
            guard components.count < Self.maximumComponents else { throw ArtifactContractError.limitExceeded }
            components.append(try list.decode(LocalMaskComponent.self))
        }
        try self.init(components: components)
    }
}

public struct LocalMaskResourceUsage: Sendable {
    public var rasterBytes = 0
    public var brushPoints = 0
    public var brushStrokes = 0

    mutating func include(shape: LocalMaskShape, refinement: MaskDocument?) {
        func points(_ document: MaskDocument) -> Int { document.strokes.reduce(0) { $0 + $1.points.count } }
        switch shape {
        case .subject(let raster), .sky(let raster): rasterBytes += raster.bytes.count
        case .brush(let document): brushStrokes += document.strokes.count; brushPoints += points(document)
        case .linear, .radial: break
        }
        if let refinement { brushStrokes += refinement.strokes.count; brushPoints += points(refinement) }
    }
}
