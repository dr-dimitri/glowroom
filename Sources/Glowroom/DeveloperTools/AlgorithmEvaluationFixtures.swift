import CoreGraphics
import CryptoKit
import Foundation

enum AlgorithmEvaluationFixtureError: Error {
    case invalidRaster
    case unsupportedImage
    case unknownScene
}

/// Developed, upright pixels shared by every candidate. RGB is straight,
/// extended-linear sRGB (including negative and >1 components); alpha is [0,1].
/// Rows follow CGImage's top-left raster order. Hidden RGB is canonical zero.
struct AlgorithmEvaluationRaster: Sendable {
    let width: Int
    let height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32 * 1_024 * 1_024, pixels.count == width * height * 4,
              pixels.allSatisfy(\.isFinite) else { throw AlgorithmEvaluationFixtureError.invalidRaster }
        var canonical = pixels
        for offset in stride(from: 0, to: canonical.count, by: 4) {
            guard (0...1).contains(canonical[offset + 3]) else { throw AlgorithmEvaluationFixtureError.invalidRaster }
            if canonical[offset + 3] == 0 {
                canonical[offset] = 0; canonical[offset + 1] = 0; canonical[offset + 2] = 0
                canonical[offset + 3] = 0
            }
        }
        self.width = width; self.height = height; self.pixels = canonical
    }

    /// Convert the already-developed source exactly once, before branching into
    /// algorithms. A float CGContext performs profile conversion while preserving
    /// extended gamut. Its premultiplied output is explicitly unpremultiplied.
    /// EXIF is applied once to these frozen pixels, never inside a candidate.
    static func freeze(_ image: CGImage, orientation: UInt32 = 1) throws -> Self {
        guard (1...8).contains(orientation), image.width > 0, image.height > 0,
              image.width <= 16_384, image.height <= 16_384,
              image.width * image.height <= 32 * 1_024 * 1_024,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 32, bytesPerRow: image.width * 16, space: space,
                bitmapInfo: floatBitmapInfo.rawValue) else { throw AlgorithmEvaluationFixtureError.unsupportedImage }
        try Task.checkCancellation()
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { throw AlgorithmEvaluationFixtureError.unsupportedImage }
        let source = data.assumingMemoryBound(to: Float.self)
        let swapsAxes = orientation >= 5
        let width = swapsAxes ? image.height : image.width
        let height = swapsAxes ? image.width : image.height
        var pixels = [Float](repeating: 0, count: width * height * 4)
        // Pixel permutation and unpremultiplication share a pass. Small fixtures
        // stay serial; the owning harness bounds concurrency across scenes.
        for y in 0..<height {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<width {
                let sx: Int, sy: Int
                switch orientation {
                case 2: (sx, sy) = (image.width - 1 - x, y)
                case 3: (sx, sy) = (image.width - 1 - x, image.height - 1 - y)
                case 4: (sx, sy) = (x, image.height - 1 - y)
                case 5: (sx, sy) = (y, x)
                case 6: (sx, sy) = (y, image.height - 1 - x)
                case 7: (sx, sy) = (image.width - 1 - y, image.height - 1 - x)
                case 8: (sx, sy) = (image.width - 1 - y, x)
                default: (sx, sy) = (x, y)
                }
                let input = (sy * image.width + sx) * 4, output = (y * width + x) * 4
                let alpha = source[input + 3]
                pixels[output + 3] = alpha
                if alpha > 0 {
                    for channel in 0..<3 { pixels[output + channel] = source[input + channel] / alpha }
                }
            }
        }
        return try Self(width: width, height: height, pixels: pixels)
    }

    /// The same float image can be handed to Glowroom's existing CI graph. This
    /// is an explicit premultiply boundary, not an extra developed source.
    func cgImage() throws -> CGImage {
        var premultiplied = pixels
        for offset in stride(from: 0, to: premultiplied.count, by: 4) {
            if offset.isMultiple(of: 65_536) { try Task.checkCancellation() }
            for channel in 0..<3 { premultiplied[offset + channel] *= premultiplied[offset + 3] }
        }
        let data = premultiplied.withUnsafeBytes { Data($0) }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                bytesPerRow: width * 16, space: space, bitmapInfo: Self.floatBitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric)
        else { throw AlgorithmEvaluationFixtureError.unsupportedImage }
        return image
    }

    /// sRGB8 is only for inspectable PNGs. Quality metrics use the unclipped
    /// float raster. A specified neutral background is composited in linear
    /// light before encoding; nil retains straight alpha for PNG diagnostics.
    func previewImage(background: Float? = nil) throws -> CGImage {
        if let background, !background.isFinite || !(0...1).contains(background) {
            throw AlgorithmEvaluationFixtureError.invalidRaster
        }
        var bytes = [UInt8](repeating: 0, count: pixels.count)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if offset.isMultiple(of: 65_536) { try Task.checkCancellation() }
            let alpha = pixels[offset + 3]
            for channel in 0..<3 {
                let value = background.map { pixels[offset + channel] * alpha + $0 * (1 - alpha) }
                    ?? (alpha > 0 ? pixels[offset + channel] : 0)
                let clipped = min(1, max(0, value))
                let encoded = clipped <= 0.0031308 ? 12.92 * clipped : 1.055 * pow(clipped, 1 / 2.4) - 0.055
                bytes[offset + channel] = UInt8((encoded * 255).rounded())
            }
            bytes[offset + 3] = background == nil ? UInt8((alpha * 255).rounded()) : 255
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric)
        else { throw AlgorithmEvaluationFixtureError.unsupportedImage }
        return image
    }

    /// Dimensions and representation are part of the hash. Supported macOS
    /// architectures use little-endian IEEE Float32; no huge hash copy is made.
    var sha256: String {
        var hash = SHA256()
        hash.update(data: Data("Glowroom/LC01/straight-extended-linear-sRGB/RGBA-f32le/v1\n\(width)x\(height)\n".utf8))
        pixels.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let floatBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        .union(.floatComponents).union(.byteOrder32Little)
}

/// Self-authored procedural scenes. These are controlled diagnostics, never
/// evidence for photographic quality or licensed real-photo coverage.
enum AlgorithmEvaluationFixtures {
    enum Split: String, Codable, Sendable, CaseIterable {
        case tuning, acceptance

        var seed: UInt64 {
            switch self {
            case .tuning: 0x4C43_3031_5455_4E45
            case .acceptance: 0x4C43_3031_4143_4350
            }
        }
    }

    struct Fixture: Sendable {
        let id: String
        let sceneClass: String
        let split: Split
        let seed: UInt64
        let input: AlgorithmEvaluationRaster
        let groundTruth: AlgorithmEvaluationRaster?
    }

    static let sceneClasses = ["ramp", "constants", "fine-lines", "hard-edge", "texture",
                               "colors", "saturation", "transparency", "noise"]

    static func make(split: Split, width: Int = 128, height: Int = 96) throws -> [Fixture] {
        try sceneClasses.map { try make(sceneClass: $0, split: split, width: width, height: height) }
    }

    /// Full-size workloads request one scene so nine large input buffers are
    /// never retained together. Each call owns its PRNG and mutable pixel array.
    static func make(sceneClass: String, split: Split, width: Int = 128, height: Int = 96) throws -> Fixture {
        guard let sceneIndex = sceneClasses.firstIndex(of: sceneClass) else { throw AlgorithmEvaluationFixtureError.unknownScene }
        guard width >= 8, height >= 8, width <= 16_384, height <= 16_384,
              width * height <= 32 * 1_024 * 1_024 else { throw AlgorithmEvaluationFixtureError.invalidRaster }
        let seed = split.seed ^ (UInt64(sceneIndex + 1) &* 0x9E37_79B9_7F4A_7C15)
        var random = Generator(state: seed)
        let phase = Int(random.next() % 29)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let swatches: [[Float]] = [[0.58, 0.32, 0.21], [0.27, 0.12, 0.07], [0.9, 0.62, 0.43],
                                   [1, 0, 0], [0, 1, 0], [0, 0, 1], [0.8, 0.1, 0.65], [0.04, 0.64, 0.85]]
        for y in 0..<height {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<width {
                let u = Float(x) / Float(width - 1), v = Float(y) / Float(height - 1)
                let offset = (y * width + x) * 4
                var red: Float = 0, green: Float = 0, blue: Float = 0, alpha: Float = 1
                switch sceneClass {
                case "ramp":
                    let value = split == .tuning ? u : u * (0.75 + 0.25 * v)
                    (red, green, blue) = (value, value, value)
                case "constants":
                    let level = [Float(0.015), 0.06, 0.18, 0.5, 0.9, 1][min(5, x * 6 / width)]
                    let value = split == .tuning ? level : level * 0.97
                    (red, green, blue) = (value, value, value)
                case "fine-lines":
                    let brightBackground = y >= height / 2
                    let line = (x + phase) % 11 == 0 || (x + y + phase) % 37 == 0
                    let value: Float = line != brightBackground ? 0.92 : 0.035
                    (red, green, blue) = (value, value, value)
                case "hard-edge":
                    let edge = width / 2 + (split == .acceptance ? width / 11 : 0)
                    let value: Float = x < edge ? 0.04 : 0.86
                    (red, green, blue) = (value, value, value)
                case "texture":
                    let triangle = Float(abs((x * 3 + y * 5 + phase) % 32 - 16)) / 16
                    let fine = Float((x + y + phase) % 2) * 0.035
                    red = 0.12 + triangle * 0.28 + fine
                    green = 0.17 + triangle * 0.24 + fine
                    blue = 0.08 + triangle * 0.19 + fine
                case "colors":
                    let swatch = min(swatches.count - 1, x * swatches.count / width)
                    let color = swatches[swatch]
                    let scale: Float = (0.6 + v * 0.4) * (split == .acceptance && swatch < 3 ? 0.93 : 1)
                    red = color[0] * scale; green = color[1] * scale; blue = color[2] * scale
                    // Acceptance retains actual skin hues; only the remaining
                    // primary/saturated swatches permute their channel order.
                    if split == .acceptance && swatch >= 3 { swap(&red, &blue) }
                case "saturation":
                    let sector = min(5, x * 6 / width)
                    let rising = Float((x * 6) % width) / Float(width)
                    let rgb: (Float, Float, Float)
                    switch sector {
                    case 0: rgb = (1, rising, 0)
                    case 1: rgb = (1 - rising, 1, 0)
                    case 2: rgb = (0, 1, rising)
                    case 3: rgb = (0, 1 - rising, 1)
                    case 4: rgb = (rising, 0, 1)
                    default: rgb = (1, 0, 1 - rising)
                    }
                    let saturation = split == .tuning ? v : 1 - v
                    red = 0.18 + saturation * (rgb.0 - 0.18)
                    green = 0.18 + saturation * (rgb.1 - 0.18)
                    blue = 0.18 + saturation * (rgb.2 - 0.18)
                case "transparency":
                    let edge = Float(width) * (split == .tuning ? 0.4 : 0.55)
                    alpha = min(1, max(0, (Float(x) - edge) / max(2, Float(width) * 0.12)))
                    if y < height / 4 { alpha = x < Int(edge) ? 0 : 0.5 }
                    red = 0.8; green = 0.15 + 0.3 * v; blue = 0.06
                case "noise":
                    let base: Float = x < width / 2 ? 0.12 : 0.58
                    let line: Float = (y + phase) % 19 == 0 ? 0.04 : 0
                    red = base + line; green = base * 0.85 + line; blue = base * 0.65 + line
                default: throw AlgorithmEvaluationFixtureError.unknownScene
                }
                pixels[offset] = red; pixels[offset + 1] = green
                pixels[offset + 2] = blue; pixels[offset + 3] = alpha
            }
        }
        let clean = try AlgorithmEvaluationRaster(width: width, height: height, pixels: pixels)
        if sceneClass == "noise" {
            // Fixed, bounded uniform components: signal-dependent independent
            // channel noise, shared luma noise, and zero-luma chroma noise.
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                if offset.isMultiple(of: 65_536) { try Task.checkCancellation() }
                let luma = 0.2126 * pixels[offset] + 0.7152 * pixels[offset + 1] + 0.0722 * pixels[offset + 2]
                let signalAmplitude: Float = 0.004 + 0.025 * luma
                let lumaNoise = random.signedUnit() * 0.014
                let chromaR = random.signedUnit() * 0.026, chromaB = random.signedUnit() * 0.026
                let chromaG = -(0.2126 * chromaR + 0.0722 * chromaB) / 0.7152
                for (channel, chroma) in [chromaR, chromaG, chromaB].enumerated() {
                    pixels[offset + channel] = min(1, max(0, pixels[offset + channel] + lumaNoise + chroma
                        + random.signedUnit() * signalAmplitude))
                }
            }
        }
        return Fixture(id: "\(split.rawValue)-\(sceneClass)", sceneClass: sceneClass, split: split, seed: seed,
            input: sceneClass == "noise" ? try .init(width: width, height: height, pixels: pixels) : clean,
            groundTruth: sceneClass == "noise" ? clean : nil)
    }

    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
        mutating func signedUnit() -> Float { Float(next() >> 40) / 8_388_608 - 1 }
    }
}
