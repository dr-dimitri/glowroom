import Foundation

/// The exhaustive mapping between persisted IDs and the numeric controls.
public enum EditParameter: String, CaseIterable, Codable, Hashable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case texture, clarity, dehaze, vibrance, saturation
    case luminanceNoiseReduction, colorNoiseReduction, autoToneAmount
    case sharpeningAmount, sharpeningRadius, sharpeningDetail, sharpeningMasking
    case naturalBalanceAmount, naturalBalanceColorAmount

    public var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -5...5
        case .sharpeningAmount: return 0...150
        case .sharpeningRadius: return 0.5...3
        case .luminanceNoiseReduction, .colorNoiseReduction, .autoToneAmount,
             .naturalBalanceAmount, .naturalBalanceColorAmount,
             .sharpeningDetail, .sharpeningMasking: return 0...100
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
        case .sharpeningAmount: return \.sharpeningAmount
        case .sharpeningRadius: return \.sharpeningRadius
        case .sharpeningDetail: return \.sharpeningDetail
        case .sharpeningMasking: return \.sharpeningMasking
        case .autoToneAmount: return \.autoToneAmount
        case .naturalBalanceAmount: return \.naturalBalanceAmount
        case .naturalBalanceColorAmount: return \.naturalBalanceColorAmount
        }
    }

    public func value(in settings: EditSettings) -> Double { settings[keyPath: keyPath] }

    /// Applies an absolute target without normalizing or modifying any other control.
    public func applying(_ value: Double, to settings: EditSettings) throws -> EditSettings {
        guard value.isFinite else { throw ArtifactContractError.invalidValue("nonfinite edit parameter") }
        guard range.contains(value) else { throw ArtifactContractError.invalidValue("edit parameter out of range") }
        var result = settings
        result[keyPath: keyPath] = value
        return result
    }
}
