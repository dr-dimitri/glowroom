import Foundation

/// Explicit conservative Glowroom policy, fixed before evaluating the image
/// fixtures. These constants also provide the comparison report's provenance.
public enum AutomaticLevelsPolicy {
    public static let algorithmVersion = 1
    public static let referenceCommit = "7d518c7971e80719ce30f70ec44b55e49ab2aeb7"
    public static let binCount = 4_096
    public static let maximumHistogramBytes = 3 * binCount * MemoryLayout<Double>.stride
    public static let tailFraction = 0.006
    public static let minimumVisibleEquivalent = 64.0
    public static let minimumRobustSpan = 0.125
    public static let minimumInterquartileRange = 0.03125
    public static let keyRange = 0.3...0.7
    public static let gainRange = 1.01...3.0
    public static let maximumKeyShift = 0.075
    /// Evaluate this finite sequence in order. Neither clipping nor the rest
    /// of the active output graph is assumed to be monotonic in strength.
    public static let strengths: [Double] = [
        1, 0.875, 0.75, 0.625, 0.5, 0.375, 0.25,
        0.1875, 0.125, 0.09375, 0.0625, 0.046875, 0.03125
    ]
}

/// Raw reference endpoints may be equal, including the empty histogram's 0/0.
/// They become renderable curves only after ordinary Levels validation.
public struct AutomaticLevelsEndpoints: Codable, Hashable, Sendable {
    public let black: Double
    public let white: Double
    public init(black: Double, white: Double) { self.black = black; self.white = white }
}

public struct AutomaticLevelsRGBEndpoints: Codable, Hashable, Sendable {
    public let red: AutomaticLevelsEndpoints
    public let green: AutomaticLevelsEndpoints
    public let blue: AutomaticLevelsEndpoints
    public init(red: AutomaticLevelsEndpoints, green: AutomaticLevelsEndpoints, blue: AutomaticLevelsEndpoints) {
        self.red = red; self.green = green; self.blue = blue
    }
}
