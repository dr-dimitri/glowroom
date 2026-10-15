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

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                texture: Double = 0, clarity: Double = 0, dehaze: Double = 0,
                vibrance: Double = 0, saturation: Double = 0,
                luminanceNoiseReduction: Double = 0, colorNoiseReduction: Double = 0) {
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
                    colorNoiseReduction: clamp(colorNoiseReduction, 0...100))
    }

    public var isNeutral: Bool { normalized == .neutral }
}
