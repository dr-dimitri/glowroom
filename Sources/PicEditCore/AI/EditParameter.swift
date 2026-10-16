import Foundation

/// The exhaustive mapping between model-visible IDs and the fourteen existing controls.
public enum EditParameter: String, CaseIterable, Codable, Hashable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case texture, clarity, dehaze, vibrance, saturation
    case luminanceNoiseReduction, colorNoiseReduction, autoToneAmount

    public var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .luminanceNoiseReduction, .colorNoiseReduction, .autoToneAmount: return 0...100
        default: return -100...100
        }
    }

    private var keyPath: WritableKeyPath<EditSettings, Double> {
        switch self {
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .whites: return \.whites
        case .blacks: return \.blacks
        case .texture: return \.texture
        case .clarity: return \.clarity
        case .dehaze: return \.dehaze
        case .vibrance: return \.vibrance
        case .saturation: return \.saturation
        case .luminanceNoiseReduction: return \.luminanceNoiseReduction
        case .colorNoiseReduction: return \.colorNoiseReduction
        case .autoToneAmount: return \.autoToneAmount
        }
    }

    public func value(in settings: EditSettings) -> Double { settings[keyPath: keyPath] }

    /// Applies an absolute target without normalizing or modifying any other control.
    public func applying(_ value: Double, to settings: EditSettings) throws -> EditSettings {
        guard value.isFinite else { throw AIEditingError.invalidResponse(.nonFiniteValue) }
        guard range.contains(value) else { throw AIEditingError.invalidResponse(.outOfRange) }
        var result = settings
        result[keyPath: keyPath] = value
        return result
    }
}
