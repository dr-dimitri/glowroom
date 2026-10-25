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
    public static let maximumDimension = 2_048
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
    /// Legacy fields are retained only for the legacy wire representation. New
    /// composition encoding contains no inactive duplicate shape or refinement.
    public var shape: LocalMaskShape
    public private(set) var composition: LocalMaskComposition?
    /// Ordered brush/erase corrections on top of the original selection.
    /// Its initial canvas stays empty; strokes refine rather than replace shape.
    public var refinement: MaskDocument?
    public var isInverted: Bool
    public var opacity: Double
    /// Radial falloff spans the outer feather fraction of its radius. Brush and
    /// automatic selections use a resolution-independent soft edge. The editor
    /// starts new automatic mattes at zero because they already contain edge
    /// coverage; this initializer and decoded values retain historic semantics.
    public var feather: Double
    public init(shape: LocalMaskShape, isInverted: Bool = false, opacity: Double = 1, feather: Double = 0.5,
                refinement: MaskDocument? = nil) throws {
        self.shape = shape; self.isInverted = isInverted; self.opacity = opacity; self.feather = feather
        self.refinement = refinement; self.composition = nil
        try validate()
    }
    public init(composition: LocalMaskComposition, isInverted: Bool = false, opacity: Double = 1) throws {
        // Empty fixed-size placeholder keeps unused legacy state small and stable.
        self.shape = .brush(try MaskDocument(canvasSize: .init(width: 1, height: 1)))
        self.refinement = nil; self.feather = 0
        self.composition = composition; self.isInverted = isInverted; self.opacity = opacity
        try validate()
    }
    public mutating func setComposition(_ composition: LocalMaskComposition) throws {
        self = try Self(composition: composition, isInverted: isInverted, opacity: opacity)
    }
    /// Conversion is invoked only when a second component is actually accepted.
    public func convertedToComposition(name: String) throws -> LocalMaskComposition {
        if let composition { return composition }
        return try .init(components: [.init(name: name, shape: shape, refinement: refinement, feather: feather)])
    }
    public var componentCount: Int { composition?.components.count ?? 1 }
    public var resourceUsage: LocalMaskResourceUsage {
        var result = LocalMaskResourceUsage()
        if let composition {
            for component in composition.components { result.include(shape: component.shape, refinement: component.refinement) }
        } else { result.include(shape: shape, refinement: refinement) }
        return result
    }
    /// Includes disabled components because they still own payloads and history.
    public var selectionMasks: [LocalAdjustmentMask] {
        get throws {
            if let composition { return try composition.components.map { try $0.selectionMask() } }
            return [self]
        }
    }
    public func validate() throws {
        if let composition {
            try composition.validate()
            let placeholder = LocalMaskShape.brush(try MaskDocument(canvasSize: .init(width: 1, height: 1)))
            guard feather == 0, refinement == nil, shape == placeholder else { throw ArtifactContractError.invalidValue("composed mask legacy fields") }
        } else { try shape.validate() }
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
    private enum CodingKeys: String, CodingKey { case shape, isInverted, opacity, feather, refinement, composition }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.composition) {
            guard !values.contains(.shape), !values.contains(.feather), !values.contains(.refinement) else {
                throw ArtifactContractError.invalidValue("mixed local mask representation")
            }
            try self.init(composition: values.decode(LocalMaskComposition.self, forKey: .composition),
                isInverted: values.decode(Bool.self, forKey: .isInverted), opacity: values.decode(Double.self, forKey: .opacity))
        } else {
            try self.init(shape: values.decode(LocalMaskShape.self, forKey: .shape), isInverted: values.decode(Bool.self, forKey: .isInverted),
                          opacity: values.decode(Double.self, forKey: .opacity), feather: values.decode(Double.self, forKey: .feather),
                          refinement: values.decodeIfPresent(MaskDocument.self, forKey: .refinement))
        }
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isInverted, forKey: .isInverted); try values.encode(opacity, forKey: .opacity)
        if let composition { try values.encode(composition, forKey: .composition) }
        else {
            try values.encode(shape, forKey: .shape); try values.encode(feather, forKey: .feather)
            try values.encodeIfPresent(refinement, forKey: .refinement)
        }
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
    /// Relative white balance applied only through this layer's mask.
    public var temperature: Double
    public var tint: Double
    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0,
                whites: Double = 0, blacks: Double = 0, texture: Double = 0, clarity: Double = 0,
                dehaze: Double = 0, vibrance: Double = 0, saturation: Double = 0,
                temperature: Double = 6_500, tint: Double = 0) {
        self.exposure = exposure; self.contrast = contrast; self.highlights = highlights; self.shadows = shadows
        self.whites = whites; self.blacks = blacks; self.texture = texture; self.clarity = clarity
        self.dehaze = dehaze; self.vibrance = vibrance; self.saturation = saturation
        self.temperature = temperature; self.tint = tint
    }
    public var editSettings: EditSettings {
        .init(exposure: exposure, contrast: contrast, highlights: highlights, shadows: shadows, whites: whites,
              blacks: blacks, texture: texture, clarity: clarity, dehaze: dehaze, vibrance: vibrance, saturation: saturation,
              developColor: .init(temperature: temperature, tint: tint))
    }
    public var normalized: Self {
        let value = editSettings.normalized
        return .init(exposure: value.exposure, contrast: value.contrast, highlights: value.highlights,
                     shadows: value.shadows, whites: value.whites, blacks: value.blacks, texture: value.texture,
                     clarity: value.clarity, dehaze: value.dehaze, vibrance: value.vibrance, saturation: value.saturation,
                     temperature: value.developColor.temperature, tint: value.developColor.tint)
    }
    public static let neutral = Self()
    public var isNeutral: Bool { normalized == .neutral }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, vibrance, saturation, temperature, tint
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(exposure: try values.decode(Double.self, forKey: .exposure),
                  contrast: try values.decode(Double.self, forKey: .contrast),
                  highlights: try values.decode(Double.self, forKey: .highlights),
                  shadows: try values.decode(Double.self, forKey: .shadows),
                  whites: try values.decode(Double.self, forKey: .whites),
                  blacks: try values.decode(Double.self, forKey: .blacks),
                  texture: try values.decode(Double.self, forKey: .texture),
                  clarity: try values.decode(Double.self, forKey: .clarity),
                  dehaze: try values.decode(Double.self, forKey: .dehaze),
                  vibrance: try values.decode(Double.self, forKey: .vibrance),
                  saturation: try values.decode(Double.self, forKey: .saturation),
                  temperature: values.contains(.temperature) ? try values.decode(Double.self, forKey: .temperature) : 6_500,
                  tint: values.contains(.tint) ? try values.decode(Double.self, forKey: .tint) : 0)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(exposure, forKey: .exposure); try values.encode(contrast, forKey: .contrast)
        try values.encode(highlights, forKey: .highlights); try values.encode(shadows, forKey: .shadows)
        try values.encode(whites, forKey: .whites); try values.encode(blacks, forKey: .blacks)
        try values.encode(texture, forKey: .texture); try values.encode(clarity, forKey: .clarity)
        try values.encode(dehaze, forKey: .dehaze); try values.encode(vibrance, forKey: .vibrance)
        try values.encode(saturation, forKey: .saturation)
        // Keep historical snapshot bytes and digests unchanged until edited.
        if temperature != 6_500 { try values.encode(temperature, forKey: .temperature) }
        if tint != 0 { try values.encode(tint, forKey: .tint) }
    }
}

public struct LocalAdjustment: Codable, Hashable, Identifiable, Sendable {
    public static let maximumCount = 16
    public static let maximumTotalComponents = 64
    /// Four maximum-size mattes fit without weakening the aggregate bound.
    /// Smaller selections may still occupy all sixteen local layers.
    public static let maximumTotalRasterBytes = 16 * 1_024 * 1_024
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
