import Foundation

public enum LevelsPickerMode: String, CaseIterable, Hashable, Sendable {
    case setTone, neutralizeRGB
}

public enum LevelsPickerPoint: String, CaseIterable, Hashable, Sendable {
    case black, gray, white
}

/// Alpha-weighted straight RGB in the signed-sRGB domain immediately before
/// the entire levels node. Negative gamut coordinates and HDR are not clamped.
public struct LevelsPickerSample: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    public func validate() throws {
        guard [red, green, blue].allSatisfy({ $0.isFinite && Float($0).isFinite }) else {
            throw LevelsPickerError.invalidSample
        }
    }
}

public enum LevelsPickerError: Error, Equatable, Sendable, LocalizedError {
    case invalidSample
    case invalidSettings
    case invalidEndpoints
    case degenerateMidtone
    case gammaOutsideRange
    case differentOutputBounds
    case nonInvertibleTarget
    case unreachableTarget

    public var errorDescription: String? {
        switch self {
        case .invalidSample: "Die Probe enthält keine darstellbaren Tonwerte. Wähle eine andere Bildstelle."
        case .invalidSettings: "Die vorhandene Tonwertkorrektur ist ungültig. Der bisherige Stand bleibt erhalten."
        case .invalidEndpoints: "Dieser Schwarz- oder Weißpunkt ergibt ungültige Eingangsgrenzen. Wähle eine andere Bildstelle."
        case .degenerateMidtone: "Diese Probe liegt zu nahe an Schwarz oder Weiß. Wähle einen Mittelton innerhalb der Eingangsgrenzen."
        case .gammaOutsideRange: "Für diese Probe wäre ein Gamma außerhalb von 0,1 bis 10 nötig. Wähle einen anderen Mittelton."
        case .differentOutputBounds: "RGB neutralisieren benötigt gleiche Ausgangsgrenzen in Rot, Grün und Blau. Der bisherige Stand bleibt erhalten."
        case .nonInvertibleTarget: "Die vorhandenen Ausgangsgrenzen oder Begrenzungen erlauben keine eindeutige RGB-Neutralisierung."
        case .unreachableTarget: "Mit den vorhandenen Eingangs- und Ausgangsgrenzen ist der gemeinsame Mittelton 50 % nicht erreichbar."
        }
    }
}
