import Foundation

/// A crop in the oriented source's top-left coordinate system. All later
/// preview sizes use the same normalized rectangle; original files stay intact.
public struct DevelopCropRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width >= 0.000_001, height >= 0.000_001,
              x + width <= 1.000_000_000_1, y + height <= 1.000_000_000_1 else {
            throw ArtifactContractError.invalidValue("develop crop")
        }
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: value.decode(Double.self, forKey: .x), y: value.decode(Double.self, forKey: .y),
                      width: value.decode(Double.self, forKey: .width), height: value.decode(Double.self, forKey: .height))
    }
}

public enum DevelopRetouchMode: String, Codable, Hashable, Sendable { case clone, heal }

/// One circular sampled patch. Consecutive patches form a hand-painted stroke.
/// Radius is a fraction of the oriented source's shorter edge, independent of
/// zoom. Source and target positions always precede crop/rotation/mirroring.
public struct DevelopRetouchStroke: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let mode: DevelopRetouchMode
    public let source: LocalMaskPoint
    public let target: LocalMaskPoint
    public let radius: Double
    public let feather: Double
    public let opacity: Double

    public init(id: UUID = UUID(), mode: DevelopRetouchMode = .heal,
                source: LocalMaskPoint, target: LocalMaskPoint, radius: Double,
                feather: Double = 0.5, opacity: Double = 1) throws {
        guard radius.isFinite, feather.isFinite, opacity.isFinite,
              (0.000_001...0.5).contains(radius), (0...1).contains(feather), (0...1).contains(opacity) else {
            throw ArtifactContractError.invalidValue("develop retouch patch")
        }
        self.id = id; self.mode = mode; self.source = source; self.target = target
        self.radius = radius; self.feather = feather; self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey { case id, mode, source, target, radius, feather, opacity }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: value.decode(UUID.self, forKey: .id), mode: value.decode(DevelopRetouchMode.self, forKey: .mode),
                      source: value.decode(LocalMaskPoint.self, forKey: .source), target: value.decode(LocalMaskPoint.self, forKey: .target),
                      radius: value.decode(Double.self, forKey: .radius), feather: value.decode(Double.self, forKey: .feather),
                      opacity: value.decode(Double.self, forKey: .opacity))
    }
}

/// An explicit user-selected eye ellipse, with red-dominance based correction.
public struct DevelopRedEyeCorrection: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let center: LocalMaskPoint
    public let radiusX: Double
    public let radiusY: Double
    public let strength: Double

    public init(id: UUID = UUID(), center: LocalMaskPoint, radiusX: Double, radiusY: Double, strength: Double = 1) throws {
        guard radiusX.isFinite, radiusY.isFinite, strength.isFinite,
              (0.000_001...0.5).contains(radiusX), (0.000_001...0.5).contains(radiusY), (0...1).contains(strength) else {
            throw ArtifactContractError.invalidValue("develop red eye")
        }
        self.id = id; self.center = center; self.radiusX = radiusX; self.radiusY = radiusY; self.strength = strength
    }

    private enum CodingKeys: String, CodingKey { case id, center, radiusX, radiusY, strength }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: value.decode(UUID.self, forKey: .id), center: value.decode(LocalMaskPoint.self, forKey: .center),
                      radiusX: value.decode(Double.self, forKey: .radiusX), radiusY: value.decode(Double.self, forKey: .radiusY),
                      strength: value.decode(Double.self, forKey: .strength))
    }
}

/// Nondestructive geometry and manual spot corrections, in stored operation
/// order. Spot corrections precede crop, centered straightening, mirroring,
/// then clockwise quarter turns. Positive straightening angles turn clockwise.
public struct DevelopGeometry: Codable, Hashable, Sendable {
    public static let maximumRetouchStrokes = 256
    public static let maximumRedEyeCorrections = 128
    public var crop: DevelopCropRect?
    public var quarterTurns: Int
    public var straightenAngle: Double
    public var constrainToImage: Bool
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var retouchStrokes: [DevelopRetouchStroke]
    public var redEyeCorrections: [DevelopRedEyeCorrection]

    public init(crop: DevelopCropRect? = nil, quarterTurns: Int = 0,
                straightenAngle: Double = 0, constrainToImage: Bool = true,
                flipHorizontal: Bool = false, flipVertical: Bool = false,
                retouchStrokes: [DevelopRetouchStroke] = [], redEyeCorrections: [DevelopRedEyeCorrection] = []) {
        self.crop = crop; self.quarterTurns = quarterTurns
        self.straightenAngle = straightenAngle; self.constrainToImage = constrainToImage
        self.flipHorizontal = flipHorizontal; self.flipVertical = flipVertical
        self.retouchStrokes = retouchStrokes; self.redEyeCorrections = redEyeCorrections
    }

    public static let neutral = Self()
    public var isNeutral: Bool { normalized == .neutral }
    public var normalized: Self {
        var result = self
        result.quarterTurns = ((quarterTurns % 4) + 4) % 4
        if let crop, crop.x == 0, crop.y == 0, crop.width == 1, crop.height == 1 { result.crop = nil }
        return result
    }

    public func validate() throws {
        guard (0...3).contains(quarterTurns), straightenAngle.isFinite, (-45...45).contains(straightenAngle),
              retouchStrokes.count <= Self.maximumRetouchStrokes,
              redEyeCorrections.count <= Self.maximumRedEyeCorrections,
              Set(retouchStrokes.map(\.id)).count == retouchStrokes.count,
              Set(redEyeCorrections.map(\.id)).count == redEyeCorrections.count else {
            throw ArtifactContractError.invalidValue("develop geometry")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case crop, quarterTurns, straightenAngle, constrainToImage, flipHorizontal, flipVertical, retouchStrokes, redEyeCorrections
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self.init(crop: try value.decodeIfPresent(DevelopCropRect.self, forKey: .crop),
                  quarterTurns: try value.decode(Int.self, forKey: .quarterTurns),
                  straightenAngle: try value.decodeIfPresent(Double.self, forKey: .straightenAngle) ?? 0,
                  constrainToImage: try value.decodeIfPresent(Bool.self, forKey: .constrainToImage) ?? true,
                  flipHorizontal: try value.decode(Bool.self, forKey: .flipHorizontal),
                  flipVertical: try value.decode(Bool.self, forKey: .flipVertical),
                  retouchStrokes: try value.decode([DevelopRetouchStroke].self, forKey: .retouchStrokes),
                  redEyeCorrections: try value.decode([DevelopRedEyeCorrection].self, forKey: .redEyeCorrections))
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encodeIfPresent(crop, forKey: .crop)
        try value.encode(quarterTurns, forKey: .quarterTurns)
        // Omit the new defaults so historical snapshots and their digests keep
        // exactly the same canonical bytes when no straightening was selected.
        if straightenAngle != 0 { try value.encode(straightenAngle, forKey: .straightenAngle) }
        if !constrainToImage { try value.encode(constrainToImage, forKey: .constrainToImage) }
        try value.encode(flipHorizontal, forKey: .flipHorizontal)
        try value.encode(flipVertical, forKey: .flipVertical)
        try value.encode(retouchStrokes, forKey: .retouchStrokes)
        try value.encode(redEyeCorrections, forKey: .redEyeCorrections)
    }
}
