import Foundation

/// Rendering instructions only. Original pixels are never stored or replaced.
public struct EditSettings: Codable, Hashable, Sendable {
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
    /// Image-adaptive tone balancing, before the manual controls. Zero disables it.
    public var autoToneAmount: Double

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                texture: Double = 0, clarity: Double = 0, dehaze: Double = 0,
                vibrance: Double = 0, saturation: Double = 0,
                luminanceNoiseReduction: Double = 0, colorNoiseReduction: Double = 0,
                autoToneAmount: Double = 0) {
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
        self.autoToneAmount = autoToneAmount
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, vibrance, saturation
        case luminanceNoiseReduction, colorNoiseReduction, autoToneAmount
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
        // Existing databases and backups predate this field. Only its absence
        // is a legacy default; malformed values must still fail validation.
        autoToneAmount = values.contains(.autoToneAmount)
            ? try values.decode(Double.self, forKey: .autoToneAmount) : 0
    }

    public static let neutral = EditSettings()

    public var normalized: Self {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
        }
        return Self(exposure: clamp(exposure, -5...5), contrast: clamp(contrast, -100...100),
                    highlights: clamp(highlights, -100...100), shadows: clamp(shadows, -100...100),
                    whites: clamp(whites, -100...100), blacks: clamp(blacks, -100...100),
                    texture: clamp(texture, -100...100), clarity: clamp(clarity, -100...100),
                    dehaze: clamp(dehaze, -100...100), vibrance: clamp(vibrance, -100...100),
                    saturation: clamp(saturation, -100...100),
                    luminanceNoiseReduction: clamp(luminanceNoiseReduction, 0...100),
                    colorNoiseReduction: clamp(colorNoiseReduction, 0...100),
                    autoToneAmount: clamp(autoToneAmount, 0...100))
    }

    public var isNeutral: Bool { normalized == .neutral }
}
