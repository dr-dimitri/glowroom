import Foundation

public struct AutomaticLevelsChannelStatistics: Codable, Equatable, Sendable {
    public let q006: Double
    public let q25: Double
    public let median: Double
    public let q75: Double
    public let q994: Double
    public let belowZero: Double
    public let aboveOne: Double
    public var robustSpan: Double { q994 - q006 }
    public var interquartileRange: Double { q75 - q25 }
}

public struct AutomaticLevelsRGBStatistics: Codable, Equatable, Sendable {
    public let red: AutomaticLevelsChannelStatistics
    public let green: AutomaticLevelsChannelStatistics
    public let blue: AutomaticLevelsChannelStatistics
    /// A named proxy from the three marginal encoded-RGB medians. This is
    /// neither the median of luminance nor a spatial noise measurement.
    public var keyProxy: Double { 0.2126 * red.median + 0.7152 * green.median + 0.0722 * blue.median }
    public var maximumRobustSpan: Double { max(red.robustSpan, max(green.robustSpan, blue.robustSpan)) }
    public var maximumInterquartileRange: Double {
        max(red.interquartileRange, max(green.interquartileRange, blue.interquartileRange))
    }
}

/// Three fixed histograms of straight signed-sRGB immediately before Levels.
/// Out-of-domain SDR gamut coordinates are recorded as mass in the edge bin
/// and in separate counters. Their presence alone is NOT evidence of HDR.
public struct AutomaticLevelsHistogram: Equatable, Sendable {
    public let redBins: [Double]
    public let greenBins: [Double]
    public let blueBins: [Double]
    public let visibleEquivalent: Double
    public let validPixelCount: Int
    public let invisiblePixelCount: Int
    public let invalidPixelCount: Int
    public let statistics: AutomaticLevelsRGBStatistics

    fileprivate init(red: [Double], green: [Double], blue: [Double], mass: Double,
                     valid: Int, invisible: Int, invalid: Int,
                     below: (Double, Double, Double), above: (Double, Double, Double)) {
        redBins = red; greenBins = green; blueBins = blue
        visibleEquivalent = mass; validPixelCount = valid
        invisiblePixelCount = invisible; invalidPixelCount = invalid
        statistics = AutomaticLevelsRGBStatistics(
            red: Self.statistics(red, mass: mass, below: below.0, above: above.0),
            green: Self.statistics(green, mass: mass, below: below.1, above: above.1),
            blue: Self.statistics(blue, mass: mass, below: below.2, above: above.2))
    }

    private static func statistics(_ bins: [Double], mass: Double,
                                   below: Double, above: Double) -> AutomaticLevelsChannelStatistics {
        // First occupied bin whose CDF reaches p*N. Empty input has zero
        // quantiles; the production sample gate rejects it before use.
        func quantile(_ probability: Double) -> Double {
            guard mass > 0 else { return 0 }
            let target = probability * mass
            var cumulative = 0.0, last = 0
            for (index, weight) in bins.enumerated() where weight > 0 {
                cumulative += weight; last = index
                if cumulative >= target { return Double(index) / Double(AutomaticLevelsPolicy.binCount - 1) }
            }
            // Different summation order (per-pixel N vs. per-bin CDF) can leave
            // a last-bit deficit. The last occupied bin is the exact q1 bound.
            return Double(last) / Double(AutomaticLevelsPolicy.binCount - 1)
        }
        return AutomaticLevelsChannelStatistics(q006: quantile(AutomaticLevelsPolicy.tailFraction),
            q25: quantile(0.25), median: quantile(0.5), q75: quantile(0.75),
            q994: quantile(1 - AutomaticLevelsPolicy.tailFraction), belowZero: below, aboveOne: above)
    }
}

/// A single streaming pass over the existing bounded Float raster. No second
/// per-pixel sample array, sort, worker pool or pixel-owner retention is needed.
/// The small histogram reduction stays serial to avoid atomic bin updates and
/// scheduling overhead; Core Image handles the preceding image operations.
public struct AutomaticLevelsHistogramBuilder: Sendable {
    private var red = [Double](repeating: 0, count: AutomaticLevelsPolicy.binCount)
    private var green = [Double](repeating: 0, count: AutomaticLevelsPolicy.binCount)
    private var blue = [Double](repeating: 0, count: AutomaticLevelsPolicy.binCount)
    private var mass = 0.0
    private var valid = 0, invisible = 0, invalid = 0
    private var below = (0.0, 0.0, 0.0), above = (0.0, 0.0, 0.0)

    public init() {}

    /// Components have already been unpremultiplied and signed-sRGB encoded.
    /// Do not divide by nominal SDR white here: these are actual Levels inputs.
    public mutating func add(encodedRed: Double, green encodedGreen: Double, blue encodedBlue: Double, alpha: Double) {
        guard alpha.isFinite, alpha >= 0, alpha <= 1 else { invalid += 1; return }
        guard alpha > 0 else { invisible += 1; return }
        guard encodedRed.isFinite, encodedGreen.isFinite, encodedBlue.isFinite,
              Float(encodedRed).isFinite, Float(encodedGreen).isFinite, Float(encodedBlue).isFinite else {
            invalid += 1; return
        }
        red[Self.index(encodedRed)] += alpha
        green[Self.index(encodedGreen)] += alpha
        blue[Self.index(encodedBlue)] += alpha
        if encodedRed < 0 { below.0 += alpha }; if encodedRed > 1 { above.0 += alpha }
        if encodedGreen < 0 { below.1 += alpha }; if encodedGreen > 1 { above.1 += alpha }
        if encodedBlue < 0 { below.2 += alpha }; if encodedBlue > 1 { above.2 += alpha }
        mass += alpha; valid += 1
    }

    public func finish() -> AutomaticLevelsHistogram {
        AutomaticLevelsHistogram(red: red, green: green, blue: blue, mass: mass,
            valid: valid, invisible: invisible, invalid: invalid, below: below, above: above)
    }

    private static func index(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * Double(AutomaticLevelsPolicy.binCount - 1)).rounded())
    }
}
