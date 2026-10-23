import Foundation

/// A persisted rendering contract. Missing settings metadata always means V1;
/// new editing sessions opt into V2 without changing any saved image implicitly.
public enum ToneProcessingVersion: Int, Codable, CaseIterable, Hashable, Sendable {
    case legacyV1 = 1
    case consistentV2 = 2

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        guard let version = Self(rawValue: raw) else { throw ArtifactContractError.unsupportedVersion(raw) }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The V2 perceptual domain uses the IEC sRGB transfer function extended
/// symmetrically to negative gamut coordinates. It never clamps extended range.
/// These scalar operations are intentionally serial; parallel scheduling costs
/// more than one transfer evaluation and callers already own bounded workers.
public enum SignedSRGB {
    public static func encode(_ linear: Double) -> Double {
        let magnitude = abs(linear)
        let encoded = magnitude <= 0.003_130_8 ? 12.92 * magnitude
            : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return linear.sign == .minus ? -encoded : encoded
    }

    public static func decode(_ encoded: Double) -> Double {
        let magnitude = abs(encoded)
        let linear = magnitude <= 0.040_45 ? magnitude / 12.92
            : pow((magnitude + 0.055) / 1.055, 2.4)
        return encoded.sign == .minus ? -linear : linear
    }
}
