import CoreImage
import Foundation
import Testing
@testable import Glowroom

@Suite("Float Gaussian spatial processing")
struct PreciseGaussianBlurTests {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: space, .workingFormat: CIFormat.RGBAf
    ])

    @Test(arguments: [0.125, 0.45, 1.0, 3.0, 18.0])
    func integerTapsMatchAnIndependentDiscreteGaussian(sigma: Double) throws {
        let width = 17, height = 9
        var pixels: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                let alpha = Float(x + y) / Float(width + height - 2)
                let red = Float(x) / Float(width - 1) - 0.25
                let green: Float = x >= width / 2 ? 2 : 0.18
                let blue: Float = x == width / 2 && y == height / 2 ? 4 : 0
                pixels += [red * alpha, green * alpha, blue * alpha, alpha]
            }
        }
        // An upstream sampling preference must not alter discrete-tap semantics.
        let input = image(pixels, width: width, height: height).samplingNearest()
        let graph = try PreciseGaussianBlur.apply(image: input, radius: sigma, extent: input.extent)
        let output = read(graph)
        let expected = reference(pixels.map(Double.init), width: width, height: height, sigma: sigma)
        for index in output.indices {
            #expect(output[index].isFinite)
            #expect(abs(Double(output[index]) - expected[index]) <= 0.000_03 + abs(expected[index]) * 0.000_01,
                "sigma \(sigma), component \(index): \(output[index]) differs from Gaussian \(expected[index])")
        }
    }

    @Test func constantLogLuminanceRetainsSubHalfPrecisionAtTheLargestSupportedRadius() throws {
        // The native Gaussian rounded this field to -0.53125 even with an RGBAf
        // context; a genuine Float path must preserve the original value.
        let pixels: [Float] = [-0.132_901_82, -0.132_901_82, -0.132_901_82, 0.25]
        let input = image(pixels, width: 1, height: 1)
        for sigma in [3.0, PreciseGaussianBlur.maximumRadius] {
            let graph = try PreciseGaussianBlur.apply(image: input, radius: sigma, extent: input.extent)
            let output = read(graph)
            for channel in 0..<4 { #expect(abs(output[channel] - pixels[channel]) <= 0.000_001) }
        }
    }

    @Test func unsupportedOrNonFiniteRadiusFailsBeforeGraphConstruction() throws {
        let input = image([0.2, 0.2, 0.2, 1], width: 1, height: 1)
        for sigma in [-1, Double.infinity, Double.nan, PreciseGaussianBlur.maximumRadius.nextUp] {
            #expect(throws: EditRenderError.unsupportedSpatialRadius) {
                try PreciseGaussianBlur.apply(image: input, radius: sigma, extent: input.extent)
            }
        }
        #expect(throws: EditRenderError.unavailable) {
            try PreciseGaussianBlur.apply(image: input, radius: 1,
                extent: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        }
        let neutral = try PreciseGaussianBlur.apply(image: input, radius: 0, extent: input.extent)
        #expect(read(neutral) == read(input))
    }

    private func image(_ pixels: [Float], width: Int, height: Int) -> CIImage {
        CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: Self.space)
    }
    private func read(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var output = [Float](repeating: 0, count: width * height * 4)
        output.withUnsafeMutableBytes { buffer in
            Self.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                bounds: image.extent, format: .RGBAf, colorSpace: Self.space)
        }
        return output
    }

    /// Direct 2D convolution independently checks the production separable,
    /// integer-tap implementation, including replicated edges and premultiplied alpha.
    private func reference(_ pixels: [Double], width: Int, height: Int, sigma: Double) -> [Double] {
        let support = Int(ceil(sigma * 4))
        let weights = (-support...support).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let denominator = pow(weights.reduce(0, +), 2)
        var output = [Double](repeating: 0, count: pixels.count)
        // Small fixtures keep this independent exact reference serial. They do
        // not compete with the application's bounded native render workers.
        for y in 0..<height {
            for x in 0..<width {
                for dy in -support...support {
                    let row = min(max(y + dy, 0), height - 1)
                    for dx in -support...support {
                        let column = min(max(x + dx, 0), width - 1)
                        let weight = weights[dy + support] * weights[dx + support] / denominator
                        for channel in 0..<4 {
                            output[(y * width + x) * 4 + channel] += pixels[(row * width + column) * 4 + channel] * weight
                        }
                    }
                }
            }
        }
        return output
    }
}
