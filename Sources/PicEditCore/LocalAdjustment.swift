import Foundation

/// Top-left oriented coordinates independent of preview and export resolution.
public struct LocalMaskPoint: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw ArtifactContractError.invalidValue("local mask point")
        }
        self.x = x; self.y = y
    }
    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: values.decode(Double.self, forKey: .x), y: values.decode(Double.self, forKey: .y))
    }
}

/// Frozen automatic selection, tightly packed Gray8 in top-left row order.
/// Persisting the result makes subsequent edits independent of model versions.
public struct LocalMaskRaster: Codable, Hashable, Sendable {
    public static let maximumDimension = 512
    public let width: Int
    public let height: Int
    public let bytes: Data
    public init(width: Int, height: Int, bytes: Data) throws {
        guard (1...Self.maximumDimension).contains(width), (1...Self.maximumDimension).contains(height),
              bytes.count == width * height else { throw ArtifactContractError.invalidValue("local mask raster") }
        self.width = width; self.height = height; self.bytes = bytes
    }
    private enum CodingKeys: String, CodingKey { case width, height, bytes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: values.decode(Int.self, forKey: .width), height: values.decode(Int.self, forKey: .height),
                      bytes: values.decode(Data.self, forKey: .bytes))
    }
}

public enum LocalMaskShape: Hashable, Sendable, Codable {
    /// The document keeps its native aspect ratio; points and radii are scaled
    /// from its oriented canvas to each render rather than display coordinates.
    case brush(MaskDocument)
    /// Coverage is one at start and zero at end, clamped beyond both handles.
    case linear(start: LocalMaskPoint, end: LocalMaskPoint)
    /// Radii are fractions of width/height. Rotation is clockwise radians in
    /// top-left coordinates. Inside is selected; the exterior is unselected.
    case radial(center: LocalMaskPoint, radiusX: Double, radiusY: Double, rotation: Double)
    case subject(LocalMaskRaster)
    case sky(LocalMaskRaster)

    private enum CodingKeys: String, CodingKey { case kind, document, start, end, center, radiusX, radiusY, rotation, raster }
    private enum Kind: String, Codable { case brush, linear, radial, subject, sky }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .brush: self = .brush(try values.decode(MaskDocument.self, forKey: .document))
        case .linear: self = .linear(start: try values.decode(LocalMaskPoint.self, forKey: .start), end: try values.decode(LocalMaskPoint.self, forKey: .end))
        case .radial: self = .radial(center: try values.decode(LocalMaskPoint.self, forKey: .center), radiusX: try values.decode(Double.self, forKey: .radiusX), radiusY: try values.decode(Double.self, forKey: .radiusY), rotation: try values.decode(Double.self, forKey: .rotation))
        case .subject: self = .subject(try values.decode(LocalMaskRaster.self, forKey: .raster))
        case .sky: self = .sky(try values.decode(LocalMaskRaster.self, forKey: .raster))
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .brush(let document): try values.encode(Kind.brush, forKey: .kind); try values.encode(document, forKey: .document)
        case .linear(let start, let end):
            try values.encode(Kind.linear, forKey: .kind); try values.encode(start, forKey: .start); try values.encode(end, forKey: .end)
        case .radial(let center, let x, let y, let rotation):
            try values.encode(Kind.radial, forKey: .kind); try values.encode(center, forKey: .center)
            try values.encode(x, forKey: .radiusX); try values.encode(y, forKey: .radiusY); try values.encode(rotation, forKey: .rotation)
        case .subject(let raster): try values.encode(Kind.subject, forKey: .kind); try values.encode(raster, forKey: .raster)
        case .sky(let raster): try values.encode(Kind.sky, forKey: .kind); try values.encode(raster, forKey: .raster)
        }
    }
    public func validate() throws {
        switch self {
        case .brush(let document): try document.validate()
        case .linear(let start, let end):
            guard hypot(end.x - start.x, end.y - start.y) >= 0.000_001 else { throw ArtifactContractError.invalidValue("local linear gradient") }
        case .radial(_, let x, let y, let rotation):
            guard x.isFinite, y.isFinite, rotation.isFinite, (0.000_001...2).contains(x), (0.000_001...2).contains(y),
                  (-Double.pi * 2...Double.pi * 2).contains(rotation) else { throw ArtifactContractError.invalidValue("local radial gradient") }
        case .subject(let raster), .sky(let raster):
            _ = try LocalMaskRaster(width: raster.width, height: raster.height, bytes: raster.bytes)
        }
    }
}

public struct LocalAdjustmentMask: Codable, Hashable, Sendable {
    public var shape: LocalMaskShape
    /// Ordered brush/erase corrections on top of the original selection.
    /// Its initial canvas stays empty; strokes refine rather than replace shape.
    public var refinement: MaskDocument?
    public var isInverted: Bool
    public var opacity: Double
    /// Radial falloff spans the outer feather fraction of its radius. Brush and
    /// automatic selections use a small resolution-independent soft edge.
    public var feather: Double
    public init(shape: LocalMaskShape, isInverted: Bool = false, opacity: Double = 1, feather: Double = 0.5,
                refinement: MaskDocument? = nil) throws {
        self.shape = shape; self.isInverted = isInverted; self.opacity = opacity; self.feather = feather
        self.refinement = refinement
        try validate()
    }
    public func validate() throws {
        try shape.validate()
        if let refinement {
            try refinement.validate()
            guard !refinement.isInverted else { throw ArtifactContractError.invalidValue("local mask refinement") }
        }
        guard opacity.isFinite, feather.isFinite, (0...1).contains(opacity), (0...1).contains(feather) else {
            throw ArtifactContractError.invalidValue("local mask coverage")
        }
    }
    public var normalized: Self {
        var result = self
        result.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 0
        result.feather = feather.isFinite ? min(max(feather, 0), 1) : 0
        return result
    }
    private enum CodingKeys: String, CodingKey { case shape, isInverted, opacity, feather, refinement }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(shape: values.decode(LocalMaskShape.self, forKey: .shape), isInverted: values.decode(Bool.self, forKey: .isInverted),
                      opacity: values.decode(Double.self, forKey: .opacity), feather: values.decode(Double.self, forKey: .feather),
                      refinement: values.decodeIfPresent(MaskDocument.self, forKey: .refinement))
    }
}

/// Local corrections contain no recursive edit settings or adaptive global
/// operations. Conversion reuses the same tone/color/presence filter graph.
public struct LocalAdjustmentSettings: Codable, Hashable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var texture: Double
    public var clarity: Double
    public var dehaze: Double
    public var vibrance: Double
    public var saturation: Double
    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
                whites: Double = 0, blacks: Double = 0, texture: Double = 0, clarity: Double = 0,
                dehaze: Double = 0, vibrance: Double = 0, saturation: Double = 0) {
        self.exposure = exposure; self.contrast = contrast; self.highlights = highlights; self.shadows = shadows
        self.whites = whites; self.blacks = blacks; self.texture = texture; self.clarity = clarity
        self.dehaze = dehaze; self.vibrance = vibrance; self.saturation = saturation
    }
    public var editSettings: EditSettings {
        .init(exposure: exposure, contrast: contrast, highlights: highlights, shadows: shadows, whites: whites,
              blacks: blacks, texture: texture, clarity: clarity, dehaze: dehaze, vibrance: vibrance, saturation: saturation)
    }
    public var normalized: Self {
        let value = editSettings.normalized
        return .init(exposure: value.exposure, contrast: value.contrast, highlights: value.highlights,
                     shadows: value.shadows, whites: value.whites, blacks: value.blacks, texture: value.texture,
                     clarity: value.clarity, dehaze: value.dehaze, vibrance: value.vibrance, saturation: value.saturation)
    }
    public static let neutral = Self()
    public var isNeutral: Bool { normalized == .neutral }
}

public struct LocalAdjustment: Codable, Hashable, Identifiable, Sendable {
    public static let maximumCount = 16
    public static let maximumTotalRasterBytes = 1_048_576
    public static let maximumTotalBrushPoints = MaskDocument.maximumTotalPoints
    public static let maximumTotalBrushStrokes = MaskDocument.maximumStrokes
    public var id: UUID
    public var name: String
    public var mask: LocalAdjustmentMask
    public var settings: LocalAdjustmentSettings
    public var isEnabled: Bool
    public init(id: UUID = UUID(), name: String, mask: LocalAdjustmentMask,
                settings: LocalAdjustmentSettings = .neutral, isEnabled: Bool = true) throws {
        self.id = id; self.name = name; self.mask = mask; self.settings = settings; self.isEnabled = isEnabled
        try validate()
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              !name.utf8.contains(0), settings == settings.normalized else { throw ArtifactContractError.invalidValue("local adjustment") }
        try mask.validate()
    }
    public var normalized: Self {
        var result = self; result.settings = settings.normalized
        result.mask = mask.normalized
        return result
    }
    public var isEffective: Bool { isEnabled && mask.opacity > 0 && !settings.isNeutral }
    private enum CodingKeys: String, CodingKey { case id, name, mask, settings, isEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      mask: values.decode(LocalAdjustmentMask.self, forKey: .mask),
                      settings: values.decode(LocalAdjustmentSettings.self, forKey: .settings),
                      isEnabled: values.decode(Bool.self, forKey: .isEnabled))
    }
}
