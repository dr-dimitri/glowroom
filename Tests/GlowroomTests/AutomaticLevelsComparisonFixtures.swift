import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import GlowroomCore
import ImageIO
import UniformTypeIdentifiers
@testable import Glowroom

enum AutomaticLevelsComparisonError: Error { case invalidManifest, invalidRaster, unavailableProfile }

struct AutomaticLevelsComparisonManifest: Decodable {
    enum Gate: String, Decodable { case spread, safe, lowKey, highKey, unchanged }
    struct Scene: Decodable {
        let id: String
        let title: String
        let gate: Gate
        let profile: String
    }
    struct Gates: Decodable {
        let newClippingFraction: Double
        let newClippingAllowance: Double
        let minimumGraySpanImprovement: Double
        let maximumLowKeyMedian: Double
        let minimumHighKeyMedian: Double
        let maximumGrayChannelSpread: Double
        let maximumAlphaError: Double
    }
    let schemaVersion: Int
    let generatorVersion: Int
    let width: Int
    let height: Int
    let seed: UInt64
    let reference: String
    let gates: Gates
    let scenes: [Scene]

    static var url: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/levels-evaluation/manifest.json")
    }
    static func load() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        // These are the preregistered acceptance gates, not adjustable report
        // options. A changed manifest must not quietly weaken ordinary CI.
        let expected = ["gray-midrange", "color-midrange", "backlit", "low-key", "high-key",
                        "saturated-srgb", "saturated-p3", "alpha-edges", "isolated-highlights",
                        "flat", "nearly-flat-noise", "transparent"]
        guard value.schemaVersion == 1, value.generatorVersion == 1,
              value.width == 128, value.height == 96, value.seed == 17_120_261_024,
              value.scenes.map(\.id) == expected,
              value.scenes.map({ $0.gate.rawValue }) == ["spread", "safe", "safe", "lowKey", "highKey", "safe", "safe", "safe", "spread", "unchanged", "unchanged", "unchanged"],
              value.scenes.map(\.profile) == expected.map({ $0 == "saturated-p3" ? "displayP3" : "sRGB" }),
              value.gates.newClippingFraction == 0.006, value.gates.newClippingAllowance == 1,
              value.gates.minimumGraySpanImprovement == 0.05,
              value.gates.maximumLowKeyMedian == 0.25, value.gates.minimumHighKeyMedian == 0.75,
              value.gates.maximumGrayChannelSpread == 0.0001,
              value.gates.maximumAlphaError == 0.000001 else { throw AutomaticLevelsComparisonError.invalidManifest }
        return value
    }
}

struct AutomaticLevelsComparisonFixture {
    let scene: AutomaticLevelsComparisonManifest.Scene
    let bitmap: PreviewBitmap
    let inputSHA256: String

    static func make(_ scene: AutomaticLevelsComparisonManifest.Scene,
                     manifest: AutomaticLevelsComparisonManifest) throws -> Self {
        let width = manifest.width, height = manifest.height
        var pixels = [Float]()
        pixels.reserveCapacity(width * height * 4)
        let colors: [(Double, Double, Double)] = [
            (0.98, 0.03, 0.03), (0.03, 0.98, 0.03), (0.03, 0.03, 0.98), (0.9, 0.8, 0.02),
            (0.05, 0.7, 0.8), (0.6, 0.05, 0.8), (0.2, 0.2, 0.2), (0.75, 0.75, 0.75)
        ]
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let u = Double(x) / Double(width - 1), v = Double(y) / Double(height - 1)
                var red = 0.2 + 0.6 * u, green = red, blue = red, alpha = 1.0
                switch scene.id {
                case "gray-midrange": break
                case "color-midrange":
                    red = 0.25 + 0.5 * u; green = 0.28 + 0.4 * v; blue = 0.3 + 0.35 * (u + v) / 2
                case "backlit":
                    let subject = (20..<108).contains(x) && y >= 20
                    red = subject ? 0.06 + 0.15 * u : 0.7 + 0.25 * v
                    green = red; blue = red
                case "low-key": red = 0.02 + 0.14 * u; green = red; blue = red
                case "high-key": red = 0.84 + 0.14 * u; green = red; blue = red
                case "saturated-srgb", "saturated-p3":
                    (red, green, blue) = colors[min(7, x * 8 / width)]
                    let texture = 0.01 * (v - 0.5)
                    red += texture; green += texture; blue += texture
                case "alpha-edges":
                    if x < 8 || x >= width - 8 || y < 8 || y >= height - 8 { alpha = 0 }
                    else if x < 12 || x >= width - 12 || y < 12 || y >= height - 12 { alpha = 0.25 }
                case "isolated-highlights":
                    if x == 0 && y == 0 { red = 0; green = 0; blue = 0 }
                    if x == width - 1 && y == height - 1 { red = 1; green = 1; blue = 1 }
                case "flat": red = 0.4; green = red; blue = red
                case "nearly-flat-noise":
                    let noise = (UInt64(y * width + x) &* 6_364_136_223_846_793_005 &+ manifest.seed) >> 40
                    red = 0.5 + (Double(noise % 2_001) / 1_000 - 1) * 0.001
                    green = red; blue = red
                case "transparent": alpha = 0
                default: throw AutomaticLevelsComparisonError.invalidManifest
                }
                // These exact Float32 source samples are encoded in their
                // tagged matrix profile. Core Image performs the one decode.
                pixels += [Float(red * alpha), Float(green * alpha), Float(blue * alpha), Float(alpha)]
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let name = scene.profile == "displayP3" ? CGColorSpace.extendedDisplayP3 : CGColorSpace.extendedSRGB
        guard let space = CGColorSpace(name: name), let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                bytesPerRow: width * 16, space: space,
                bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric) else {
            throw AutomaticLevelsComparisonError.invalidRaster
        }
        var hash = SHA256()
        hash.update(data: Data("AutomaticLevelsComparison/v1/\(scene.profile)/\(width)x\(height)/premultiplied-encoded-RGBAf32le\n".utf8))
        hash.update(data: data)
        return Self(scene: scene, bitmap: PreviewBitmap(image: image, rangeProvenance: .sdrDecoded),
                    inputSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// Independent scalar metrics on corresponding pre-clamp target-profile
/// Float pixels. They intentionally do not call the production clipping helper.
struct AutomaticLevelsComparisonMetrics {
    struct Mass {
        var anyLower = 0.0, anyUpper = 0.0, allBlack = 0.0, allWhite = 0.0
        var values: [Double] { [anyLower, anyUpper, allBlack, allWhite] }
        var json: [String: Double] {
            ["any_lower": anyLower, "any_upper": anyUpper, "all_black": allBlack, "all_white": allWhite]
        }
        mutating func add(_ flags: [Bool], weight: Double) {
            if flags[0] { anyLower += weight }; if flags[1] { anyUpper += weight }
            if flags[2] { allBlack += weight }; if flags[3] { allWhite += weight }
        }
    }
    let visibleEquivalent: Double
    let baseline: Mass
    let candidate: Mass
    let newlyClipped: Mass
    let belowZeroMass: Double
    let aboveOneMass: Double
    let maximumLowerExcursion: Double
    let maximumUpperExcursion: Double
    let maximumAlphaError: Double
    let maximumGrayChannelSpread: Double
    /// Euclidean displacement of positive RGB chromaticity, dimensionless;
    /// this is a descriptive color-change metric, not a perceptual ΔE claim.
    let meanRGBChromaticityDistance: Double
    let median: Double?
    let robustSpan: Double?
    let monotoneGrayRamp: Bool

    static func measure(baseline: FloatAnalysisRaster, candidate: FloatAnalysisRaster) throws -> Self {
        guard baseline.width == candidate.width, baseline.height == candidate.height,
              baseline.pixels.count == candidate.pixels.count,
              baseline.pixels.count == baseline.width * baseline.height * 4 else {
            throw AutomaticLevelsComparisonError.invalidRaster
        }
        var n = 0.0, base = Mass(), output = Mass(), fresh = Mass(), below = 0.0, above = 0.0
        var lower = 0.0, upper = 0.0, alphaError = 0.0, graySpread = 0.0, colorDistance = 0.0, colorMass = 0.0
        var values: [(Double, Double)] = []
        var ramp = true
        for y in 0..<baseline.height {
            try Task.checkCancellation()
            var preceding: Double?
            for x in 0..<baseline.width {
                let i = (y * baseline.width + x) * 4
                let ba = Double(baseline.pixels[i + 3]), ca = Double(candidate.pixels[i + 3])
                guard ba.isFinite, ca.isFinite, (0...1).contains(ba), (0...1).contains(ca) else {
                    throw AutomaticLevelsComparisonError.invalidRaster
                }
                alphaError = max(alphaError, abs(ba - ca))
                guard ba > 0 else { continue }
                guard ca > 0 else { throw AutomaticLevelsComparisonError.invalidRaster }
                let b = (0..<3).map { Double(baseline.pixels[i + $0]) / ba }
                let c = (0..<3).map { Double(candidate.pixels[i + $0]) / ca }
                guard b.allSatisfy(\.isFinite), c.allSatisfy(\.isFinite) else {
                    throw AutomaticLevelsComparisonError.invalidRaster
                }
                func flags(_ rgb: [Double]) -> [Bool] {
                    [rgb.min()! <= 0, rgb.max()! >= 1, rgb.max()! <= 0, rgb.min()! >= 1]
                }
                let bf = flags(b), cf = flags(c)
                base.add(bf, weight: ba); output.add(cf, weight: ba)
                fresh.add(zip(bf, cf).map { !$0.0 && $0.1 }, weight: ba)
                if c.min()! < 0 { below += ba }; if c.max()! > 1 { above += ba }
                lower = max(lower, -c.min()!); upper = max(upper, c.max()! - 1)
                if b.max()! - b.min()! <= 0.000_01 { graySpread = max(graySpread, c.max()! - c.min()!) }
                let bp = b.map { max(0, $0) }, cp = c.map { max(0, $0) }
                let bs = bp.reduce(0, +), cs = cp.reduce(0, +)
                if bs > 0.000_001, cs > 0.000_001 {
                    colorDistance += sqrt(zip(bp, cp).map { pow($0.0 / bs - $0.1 / cs, 2) }.reduce(0, +)) * ba
                    colorMass += ba
                }
                let value = encode(c.max()!)
                values.append((value, ba)); n += ba
                if let preceding, value < preceding - 0.000_01 { ramp = false }
                preceding = value
            }
        }
        values.sort { $0.0 < $1.0 }
        func quantile(_ fraction: Double) -> Double? {
            guard n > 0 else { return nil }
            var cumulative = 0.0
            for (value, weight) in values { cumulative += weight; if cumulative >= fraction * n { return value } }
            return values.last?.0
        }
        let span = quantile(0.95).flatMap { high in quantile(0.05).map { high - $0 } }
        return Self(visibleEquivalent: n, baseline: base, candidate: output, newlyClipped: fresh,
            belowZeroMass: below, aboveOneMass: above, maximumLowerExcursion: lower, maximumUpperExcursion: upper,
            maximumAlphaError: alphaError, maximumGrayChannelSpread: graySpread,
            meanRGBChromaticityDistance: colorMass > 0 ? colorDistance / colorMass : 0,
            median: quantile(0.5), robustSpan: span, monotoneGrayRamp: ramp)
    }

    var json: [String: Any] {
        ["visible_equivalent": visibleEquivalent, "baseline_mass": baseline.json,
         "candidate_mass": candidate.json, "newly_clipped_mass": newlyClipped.json,
         "below_zero_mass": belowZeroMass, "above_one_mass": aboveOneMass,
         "maximum_lower_excursion": maximumLowerExcursion, "maximum_upper_excursion": maximumUpperExcursion,
         "maximum_alpha_error": maximumAlphaError, "maximum_gray_channel_spread": maximumGrayChannelSpread,
         "mean_positive_rgb_chromaticity_distance": meanRGBChromaticityDistance,
         "encoded_target_value_median": median.map { $0 as Any } ?? NSNull(),
         "encoded_target_value_p95_minus_p05": robustSpan.map { $0 as Any } ?? NSNull()]
    }
    private static func encode(_ linear: Double) -> Double {
        let value = abs(linear)
        let encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
        return linear < 0 ? -encoded : encoded
    }
}

enum AutomaticLevelsComparisonFiles {
    static func freshDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sourceHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func writeJSON(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AutomaticLevelsComparisonError.invalidRaster
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw AutomaticLevelsComparisonError.invalidRaster }
    }
    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
