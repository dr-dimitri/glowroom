import Foundation

/// Rendering instructions only. Original pixels are never stored or replaced.
public struct EditSettings: Codable, Hashable, Sendable {
    /// An edit including bounded vector/raster selections remains a small blob.
    /// Allows 16 MiB of frozen Gray8 masks after Base64 expansion, plus bounded
    /// vector masks, settings and the surrounding persisted editing envelopes.
    public static let maximumEncodedBytes = 32 * 1_024 * 1_024
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
    public var luminanceNoiseReduction: Double
    public var colorNoiseReduction: Double
    /// Zero disables sharpening while retaining its subordinate preferences.
    public var sharpeningAmount: Double
    /// Radius in source-image pixels; previews scale the same physical radius.
    public var sharpeningRadius: Double
    public var sharpeningDetail: Double
    public var sharpeningMasking: Double
    /// Legacy tone balancing retained for existing edits. New balance takes precedence.
    public var autoToneAmount: Double
    /// Opt-in image-adaptive tone and color balance. Zero disables the whole effect.
    public var naturalBalanceAmount: Double
    /// Color contribution within natural balance; dormant while its amount is zero.
    public var naturalBalanceColorAmount: Double
    public var localAdjustments: [LocalAdjustment]
    public var developColor: DevelopColorSettings
    public var developGeometry: DevelopGeometry

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                texture: Double = 0, clarity: Double = 0, dehaze: Double = 0,
                vibrance: Double = 0, saturation: Double = 0,
                luminanceNoiseReduction: Double = 0, colorNoiseReduction: Double = 0,
                sharpeningAmount: Double = 0, sharpeningRadius: Double = 1,
                sharpeningDetail: Double = 25, sharpeningMasking: Double = 0,
                autoToneAmount: Double = 0, naturalBalanceAmount: Double = 0,
                naturalBalanceColorAmount: Double = 50, localAdjustments: [LocalAdjustment] = [],
                developColor: DevelopColorSettings = .neutral, developGeometry: DevelopGeometry = .neutral) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.vibrance = vibrance
        self.saturation = saturation
        self.luminanceNoiseReduction = luminanceNoiseReduction
        self.colorNoiseReduction = colorNoiseReduction
        self.sharpeningAmount = sharpeningAmount
        self.sharpeningRadius = sharpeningRadius
        self.sharpeningDetail = sharpeningDetail
        self.sharpeningMasking = sharpeningMasking
        self.autoToneAmount = autoToneAmount
        self.naturalBalanceAmount = naturalBalanceAmount
        self.naturalBalanceColorAmount = naturalBalanceColorAmount
        self.localAdjustments = localAdjustments
        self.developColor = developColor
        self.developGeometry = developGeometry
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, vibrance, saturation
        case luminanceNoiseReduction, colorNoiseReduction, autoToneAmount
        case sharpeningAmount, sharpeningRadius, sharpeningDetail, sharpeningMasking
        case naturalBalanceAmount, naturalBalanceColorAmount
        case localAdjustments
        case developColor, developGeometry
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try values.decode(Double.self, forKey: .exposure)
        contrast = try values.decode(Double.self, forKey: .contrast)
        highlights = try values.decode(Double.self, forKey: .highlights)
        shadows = try values.decode(Double.self, forKey: .shadows)
        whites = try values.decode(Double.self, forKey: .whites)
        blacks = try values.decode(Double.self, forKey: .blacks)
        texture = try values.decode(Double.self, forKey: .texture)
        clarity = try values.decode(Double.self, forKey: .clarity)
        dehaze = try values.decode(Double.self, forKey: .dehaze)
        vibrance = try values.decode(Double.self, forKey: .vibrance)
        saturation = try values.decode(Double.self, forKey: .saturation)
        luminanceNoiseReduction = try values.decode(Double.self, forKey: .luminanceNoiseReduction)
        colorNoiseReduction = try values.decode(Double.self, forKey: .colorNoiseReduction)
        // Existing databases and backups may predate these controls. Only an
        // absent key gets a legacy default; malformed values still fail.
        sharpeningAmount = values.contains(.sharpeningAmount)
            ? try values.decode(Double.self, forKey: .sharpeningAmount) : 0
        sharpeningRadius = values.contains(.sharpeningRadius)
            ? try values.decode(Double.self, forKey: .sharpeningRadius) : 1
        sharpeningDetail = values.contains(.sharpeningDetail)
            ? try values.decode(Double.self, forKey: .sharpeningDetail) : 25
        sharpeningMasking = values.contains(.sharpeningMasking)
            ? try values.decode(Double.self, forKey: .sharpeningMasking) : 0
        autoToneAmount = values.contains(.autoToneAmount)
            ? try values.decode(Double.self, forKey: .autoToneAmount) : 0
        naturalBalanceAmount = values.contains(.naturalBalanceAmount)
            ? try values.decode(Double.self, forKey: .naturalBalanceAmount) : 0
        naturalBalanceColorAmount = values.contains(.naturalBalanceColorAmount)
            ? try values.decode(Double.self, forKey: .naturalBalanceColorAmount) : 50
        localAdjustments = values.contains(.localAdjustments)
            ? try values.decode([LocalAdjustment].self, forKey: .localAdjustments) : []
        developColor = values.contains(.developColor)
            ? try values.decode(DevelopColorSettings.self, forKey: .developColor) : .neutral
        developGeometry = values.contains(.developGeometry)
            ? try values.decode(DevelopGeometry.self, forKey: .developGeometry) : .neutral
        try developGeometry.validate()
        try validateLocalAdjustments()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(exposure, forKey: .exposure); try values.encode(contrast, forKey: .contrast)
        try values.encode(highlights, forKey: .highlights); try values.encode(shadows, forKey: .shadows)
        try values.encode(whites, forKey: .whites); try values.encode(blacks, forKey: .blacks)
        try values.encode(texture, forKey: .texture); try values.encode(clarity, forKey: .clarity)
        try values.encode(dehaze, forKey: .dehaze); try values.encode(vibrance, forKey: .vibrance)
        try values.encode(saturation, forKey: .saturation)
        try values.encode(luminanceNoiseReduction, forKey: .luminanceNoiseReduction)
        try values.encode(colorNoiseReduction, forKey: .colorNoiseReduction)
        // Old snapshot bytes and digests stay unchanged until a preference is
        // edited. Persist dormant preferences too, so toggling amount is lossless.
        if sharpeningAmount != 0 || sharpeningRadius != 1 || sharpeningDetail != 25 || sharpeningMasking != 0 {
            try values.encode(sharpeningAmount, forKey: .sharpeningAmount)
            try values.encode(sharpeningRadius, forKey: .sharpeningRadius)
            try values.encode(sharpeningDetail, forKey: .sharpeningDetail)
            try values.encode(sharpeningMasking, forKey: .sharpeningMasking)
        }
        try values.encode(autoToneAmount, forKey: .autoToneAmount)
        try values.encode(naturalBalanceAmount, forKey: .naturalBalanceAmount)
        try values.encode(naturalBalanceColorAmount, forKey: .naturalBalanceColorAmount)
        // Absence preserves the exact historical settings/snapshot wire shape.
        if !localAdjustments.isEmpty { try values.encode(localAdjustments, forKey: .localAdjustments) }
        if !developColor.isNeutral { try values.encode(developColor, forKey: .developColor) }
        if !developGeometry.isNeutral { try values.encode(developGeometry, forKey: .developGeometry) }
    }

    public func validateLocalAdjustments() throws {
        guard localAdjustments.count <= LocalAdjustment.maximumCount,
              Set(localAdjustments.map(\.id)).count == localAdjustments.count else { throw ArtifactContractError.limitExceeded }
        var rasterBytes = 0, brushPoints = 0, brushStrokes = 0
        for adjustment in localAdjustments {
            try adjustment.validate()
            if let refinement = adjustment.mask.refinement {
                brushStrokes += refinement.strokes.count
                brushPoints += refinement.strokes.reduce(0) { $0 + $1.points.count }
            }
            switch adjustment.mask.shape {
            case .subject(let raster), .sky(let raster): rasterBytes += raster.bytes.count
            case .brush(let document):
                brushStrokes += document.strokes.count
                brushPoints += document.strokes.reduce(0) { $0 + $1.points.count }
            default: break
            }
        }
        guard rasterBytes <= LocalAdjustment.maximumTotalRasterBytes,
              brushPoints <= LocalAdjustment.maximumTotalBrushPoints,
              brushStrokes <= LocalAdjustment.maximumTotalBrushStrokes else { throw ArtifactContractError.limitExceeded }
    }

    public static let neutral = EditSettings()

    public var normalized: Self {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double = 0) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        return Self(exposure: clamp(exposure, -5...5), contrast: clamp(contrast, -100...100),
                    highlights: clamp(highlights, -100...100), shadows: clamp(shadows, -100...100),
                    whites: clamp(whites, -100...100), blacks: clamp(blacks, -100...100),
                    texture: clamp(texture, -100...100), clarity: clamp(clarity, -100...100),
                    dehaze: clamp(dehaze, -100...100), vibrance: clamp(vibrance, -100...100),
                    saturation: clamp(saturation, -100...100),
                    luminanceNoiseReduction: clamp(luminanceNoiseReduction, 0...100),
                    colorNoiseReduction: clamp(colorNoiseReduction, 0...100),
                    sharpeningAmount: clamp(sharpeningAmount, 0...150),
                    sharpeningRadius: clamp(sharpeningRadius, 0.5...3, fallback: 1),
                    sharpeningDetail: clamp(sharpeningDetail, 0...100, fallback: 25),
                    sharpeningMasking: clamp(sharpeningMasking, 0...100),
                    autoToneAmount: clamp(autoToneAmount, 0...100),
                    naturalBalanceAmount: clamp(naturalBalanceAmount, 0...100),
                    naturalBalanceColorAmount: clamp(naturalBalanceColorAmount, 0...100),
                    localAdjustments: localAdjustments.map(\.normalized), developColor: developColor.normalized,
                    developGeometry: developGeometry.normalized)
    }

    public var isNeutral: Bool {
        var effective = normalized
        // A saved color preference has no rendering effect until explicitly enabled.
        if effective.naturalBalanceAmount == 0 {
            effective.naturalBalanceColorAmount = Self.neutral.naturalBalanceColorAmount
        }
        if effective.sharpeningAmount == 0 {
            effective.sharpeningRadius = Self.neutral.sharpeningRadius
            effective.sharpeningDetail = Self.neutral.sharpeningDetail
            effective.sharpeningMasking = Self.neutral.sharpeningMasking
        }
        return effective == .neutral
    }
}
