import Foundation

/// V1 radial correction in the oriented, complete source canvas. A positive
/// slider value pulls corners inward (k < 0). No camera/lens profile is implied.
public struct DevelopOpticsSettings: Codable, Hashable, Sendable {
    public let version: Int
    public let distortion: Double

    public init(distortion: Double = 0, version: Int = 1) throws {
        guard version == 1 else { throw ArtifactContractError.unsupportedVersion(version) }
        guard distortion.isFinite, (-100...100).contains(distortion) else {
            throw ArtifactContractError.invalidValue("radial distortion")
        }
        self.version = version
        self.distortion = distortion == 0 ? 0 : distortion
    }

    public static let neutral = try! Self()
    public var isNeutral: Bool { distortion == 0 }
    public var coefficient: Double { -0.002 * distortion }

    private enum CodingKeys: String, CodingKey { case version, distortion }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(distortion: values.decode(Double.self, forKey: .distortion),
                      version: values.decode(Int.self, forKey: .version))
    }
}
