import Foundation

/// A location in the oriented canvas, measured in pixels from its top-left edge.
/// Pixel centers are at (x + 0.5, y + 0.5), independent of display backing scale.
public struct MaskPoint: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else {
            throw ArtifactContractError.invalidValue("mask point")
        }
        self.x = x; self.y = y
    }
    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: values.decode(Double.self, forKey: .x), y: values.decode(Double.self, forKey: .y))
    }
}

public enum MaskStrokeMode: String, Codable, Hashable, Sendable { case brush, erase }

public struct MaskStroke: Codable, Hashable, Sendable {
    public static let maximumPoints = 8_192
    public let points: [MaskPoint]
    /// Brush radius in native oriented pixels; hardness is the fully covered fraction.
    public let radius: Double
    public let hardness: Double
    public let mode: MaskStrokeMode
    public init(points: [MaskPoint], radius: Double, hardness: Double = 1, mode: MaskStrokeMode = .brush) throws {
        guard !points.isEmpty, points.count <= Self.maximumPoints,
              radius.isFinite, radius > 0, radius <= 16_384,
              hardness.isFinite, (0...1).contains(hardness) else {
            throw ArtifactContractError.invalidValue("mask stroke")
        }
        self.points = points; self.radius = radius; self.hardness = hardness; self.mode = mode
    }
    private enum CodingKeys: String, CodingKey { case points, radius, hardness, mode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(points: values.decode([MaskPoint].self, forKey: .points),
                      radius: values.decode(Double.self, forKey: .radius),
                      hardness: values.decode(Double.self, forKey: .hardness),
                      mode: values.decode(MaskStrokeMode.self, forKey: .mode))
    }
    fileprivate var inverted: Self {
        // Existing values have already passed the same initializer's validation.
        try! .init(points: points, radius: radius, hardness: hardness, mode: mode == .brush ? .erase : .brush)
    }
}

/// Immutable, versioned editing input. No preview bitmap or display coordinates
/// are persisted. Limits keep its canonical JSON comfortably below 8 MiB.
public struct MaskDocument: Codable, Hashable, Sendable {
    public static let maximumStrokes = 1_024
    public static let maximumTotalPoints = 16_384
    public static let maximumEncodedBytes = 1_048_576
    public let schemaVersion: Int
    public let canvasSize: ArtifactPixelSize
    public let strokes: [MaskStroke]
    /// Initial canvas coverage. `inverted()` also reverses existing stroke modes,
    /// so subsequent brush/erase strokes keep their ordinary meaning.
    public let isInverted: Bool
    public init(canvasSize: ArtifactPixelSize, strokes: [MaskStroke] = [], isInverted: Bool = false) throws {
        schemaVersion = 1; self.canvasSize = canvasSize; self.strokes = strokes; self.isInverted = isInverted
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ArtifactContractError.unsupportedVersion(schemaVersion) }
        guard strokes.count <= Self.maximumStrokes else { throw ArtifactContractError.limitExceeded }
        var total = 0
        for stroke in strokes {
            total += stroke.points.count
            guard total <= Self.maximumTotalPoints,
                  stroke.points.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= Double(canvasSize.width) && $0.y <= Double(canvasSize.height) }) else {
                throw ArtifactContractError.invalidValue("mask canvas points")
            }
        }
    }
    public func appending(_ stroke: MaskStroke) throws -> Self {
        try .init(canvasSize: canvasSize, strokes: strokes + [stroke], isInverted: isInverted)
    }
    public func cleared() -> Self { try! .init(canvasSize: canvasSize) }
    public func inverted() -> Self {
        try! .init(canvasSize: canvasSize, strokes: strokes.map(\.inverted), isInverted: !isInverted)
    }
    public func canonicalData() throws -> Data {
        try validate()
        let bytes = try EditingContractJSON.encoder().encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw ArtifactContractError.limitExceeded }
        return bytes
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, canvasSize, strokes, isInverted }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ArtifactContractError.unsupportedVersion(version) }
        try self.init(canvasSize: values.decode(ArtifactPixelSize.self, forKey: .canvasSize),
                      strokes: values.decode([MaskStroke].self, forKey: .strokes),
                      isInverted: values.decode(Bool.self, forKey: .isInverted))
    }
}
