import Foundation

/// Creative profiles applied to the developed image, not proprietary camera profiles.
public enum DevelopColorProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case neutral, vivid, portrait
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .neutral: return "PicEdit Farbe"
        case .vivid: return "PicEdit Lebendig"
        case .portrait: return "PicEdit Porträt"
        }
    }
}

/// White balance is relative to already developed pixels. 6500 K / tint 0
/// leaves the camera/ImageIO rendering unchanged; this is not the RAW camera's
/// measured illuminant. The component is absent from historical neutral edits.
public struct DevelopColorSettings: Codable, Hashable, Sendable {
    public static let temperatureRange = 2_000.0...12_000.0
    public static let tintRange = -150.0...150.0
    public var temperature: Double
    public var tint: Double
    public var profile: DevelopColorProfile
    public var isMonochrome: Bool
    public var hdrEnabled: Bool

    public init(temperature: Double = 6_500, tint: Double = 0, profile: DevelopColorProfile = .neutral,
                isMonochrome: Bool = false, hdrEnabled: Bool = false) {
        self.temperature = temperature; self.tint = tint; self.profile = profile
        self.isMonochrome = isMonochrome; self.hdrEnabled = hdrEnabled
    }
    public static let neutral = Self()
    public var normalized: Self {
        var value = self
        value.temperature = temperature.isFinite ? min(max(temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound) : 6_500
        value.tint = tint.isFinite ? min(max(tint, Self.tintRange.lowerBound), Self.tintRange.upperBound) : 0
        return value
    }
    public var isNeutral: Bool { normalized == .neutral }
}

/// Deterministic white-point math shared by the GPU graph and neutral pipette.
/// RGB inputs/outputs are linear sRGB unless a method explicitly says sRGB.
public enum DevelopWhiteBalance {
    public struct Correction: Hashable, Sendable {
        public let temperature: Double
        public let tint: Double
        public let isClamped: Bool
    }

    /// A Bradford chromatic-adaptation matrix in row-major linear-sRGB order.
    /// Its exact identity at the defaults avoids changing old developed pixels.
    public static func matrix(temperature: Double, tint: Double) -> [Double] {
        let value = DevelopColorSettings(temperature: temperature, tint: tint).normalized
        guard value.temperature != 6_500 || value.tint != 0 else { return identity }
        let source = xyz(uv: whitePoint(temperature: value.temperature, tint: value.tint))
        let reference = xyz(uv: d65)
        let sourceCone = multiply(bradford, source), targetCone = multiply(bradford, reference)
        let gain = zip(targetCone, sourceCone).map { $0 / max($1, 0.000_001) }
        var diagonal = identity
        diagonal[0] = gain[0]; diagonal[4] = gain[1]; diagonal[8] = gain[2]
        return multiply(xyzToRGB, multiply(inverseBradford, multiply(diagonal, multiply(bradford, rgbToXYZ))))
    }

    /// The caller samples an unedited developed source in sRGB. Sampling the
    /// corrected display repeatedly would compound an existing white balance.
    /// Nearly transparent, black and clipped patches carry no reliable chroma.
    public static func neutralizing(sRGBRed red: Double, green: Double, blue: Double,
                                   alpha: Double = 1) -> Correction? {
        let channels = [red, green, blue]
        guard channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }), alpha.isFinite, (0.5...1).contains(alpha),
              channels.min()! > 0.01, channels.max()! < 0.99 else { return nil }
        return neutralizing(linearRed: linear(red), green: linear(green), blue: linear(blue))
    }

    public static func neutralizing(linearRed red: Double, green: Double, blue: Double) -> Correction? {
        let rgb = [red, green, blue]
        guard rgb.allSatisfy({ $0.isFinite && $0 > 0 }), max(red, green, blue) > 0.000_1 else { return nil }
        if max(red, green, blue) - min(red, green, blue) < 0.000_001 {
            return Correction(temperature: 6_500, tint: 0, isClamped: false)
        }
        // Chromaticity is scale invariant. Normalize first so finite HDR input
        // cannot overflow the XYZ reduction or turn a valid result into NaN.
        let maximum = max(red, green, blue)
        let sampleXYZ = multiply(rgbToXYZ, rgb.map { $0 / maximum })
        let denominator = sampleXYZ[0] + 15 * sampleXYZ[1] + 3 * sampleXYZ[2]
        guard denominator > 0 else { return nil }
        let uv = [4 * sampleXYZ[0] / denominator, 6 * sampleXYZ[1] / denominator]
        // The bounded, tiny search runs independently of photo dimensions. It
        // finds the closest supported locus plus tint, rather than guessing RGB
        // gains that the temperature/tint controls could not reproduce.
        func fit(_ temperature: Double) -> (error: Double, tint: Double) {
            let point = whitePoint(temperature: temperature, tint: 0)
            let normal = tintNormal(temperature)
            let tint = ((uv[0] - point[0]) * normal[0] + (uv[1] - point[1]) * normal[1]) / tintUnit
            let bounded = min(max(tint, -150), 150)
            let dx = uv[0] - point[0] - normal[0] * bounded * tintUnit
            let dy = uv[1] - point[1] - normal[1] * bounded * tintUnit
            return (dx * dx + dy * dy, tint)
        }
        var best = 6_500.0, error = Double.infinity
        for index in 0...100 {
            let candidate = 2_000.0 + Double(index) * 100
            let candidateError = fit(candidate).error
            if candidateError < error { best = candidate; error = candidateError }
        }
        var low = max(2_000, best - 100), high = min(12_000, best + 100)
        for _ in 0..<32 {
            let a = low + (high - low) / 3, b = high - (high - low) / 3
            if fit(a).error <= fit(b).error { high = b } else { low = a }
        }
        let temperature = (low + high) / 2, tint = fit(temperature).tint
        return Correction(temperature: temperature, tint: min(max(tint, -150), 150),
            isClamped: temperature < 2_001 || temperature > 11_999 || abs(tint) > 150)
    }

    /// Exposed for reproducible fixtures and color sampling; Y is normalized to1.
    public static func sourceWhiteLinearRGB(temperature: Double, tint: Double) -> [Double] {
        multiply(xyzToRGB, xyz(uv: whitePoint(temperature: temperature, tint: tint)))
    }

    private static let tintUnit = 0.000_1
    private static let d65 = [0.197_830_006_642_836_8, 0.312_213_329_959_194]
    private static let identity = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
    private static let rgbToXYZ = [0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750, 0.0193339, 0.1191920, 0.9503041]
    private static let xyzToRGB = [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252]
    private static let bradford = [0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296]
    private static let inverseBradford = [0.9869929, -0.1470543, 0.1599627, 0.4323053, 0.5183603, 0.0492912, -0.0085287, 0.0400428, 0.9684867]

    private static func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    private static func locus(_ temperature: Double) -> [Double] {
        let t = min(max(temperature, 2_000), 12_000)
        let x: Double
        if t <= 4_000 { x = -0.2661239e9 / pow(t, 3) - 0.2343580e6 / pow(t, 2) + 0.8776956e3 / t + 0.179910 }
        else { x = -3.0258469e9 / pow(t, 3) + 2.1070379e6 / pow(t, 2) + 0.2226347e3 / t + 0.240390 }
        let y: Double
        if t <= 2_222 { y = -1.1063814 * pow(x, 3) - 1.34811020 * x * x + 2.18555832 * x - 0.20219683 }
        else if t <= 4_000 { y = -0.9549476 * pow(x, 3) - 1.37418593 * x * x + 2.09137015 * x - 0.16748867 }
        else { y = 3.0817580 * pow(x, 3) - 5.87338670 * x * x + 3.75112997 * x - 0.37001483 }
        let denominator = -2 * x + 12 * y + 3
        return [4 * x / denominator, 6 * y / denominator]
    }
    private static func tintNormal(_ temperature: Double) -> [Double] {
        let left = locus(temperature - 1), right = locus(temperature + 1)
        let dx = right[0] - left[0], dy = right[1] - left[1]
        let length = max(hypot(dx, dy), 0.000_000_001)
        // Positive tint corrects a green cast toward magenta.
        return [dy / length, -dx / length]
    }
    private static func whitePoint(temperature: Double, tint: Double) -> [Double] {
        let base = locus(temperature), reference = locus(6_500), normal = tintNormal(temperature)
        return [base[0] - reference[0] + d65[0] + normal[0] * tint * tintUnit,
                base[1] - reference[1] + d65[1] + normal[1] * tint * tintUnit]
    }
    private static func xyz(uv: [Double]) -> [Double] {
        let denominator = max(2 * uv[1], 0.000_001)
        return [3 * uv[0] / (2 * uv[1]), 1, (4 - uv[0] - 10 * uv[1]) / denominator]
    }
    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        if b.count == 3 { return (0..<3).map { a[$0 * 3] * b[0] + a[$0 * 3 + 1] * b[1] + a[$0 * 3 + 2] * b[2] } }
        return (0..<9).map { index in
            let row = index / 3, column = index % 3
            return a[row * 3] * b[column] + a[row * 3 + 1] * b[column + 3] + a[row * 3 + 2] * b[column + 6]
        }
    }
}
