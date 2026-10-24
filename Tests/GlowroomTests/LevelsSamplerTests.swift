import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Bounded Float levels sampling")
struct LevelsSamplerTests {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false
    ])

    @Test(arguments: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1),
                      CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)])
    func theFiveByFiveWindowUsesTopLeftCoordinatesAndClipsAtProxyEdges(point: CGPoint) throws {
        let graph = try coordinateGrid()
        let actual = try LevelsSampler.sample(graph: graph, normalizedTopLeft: point, context: Self.context)
        let centerX = min(8, Int(floor(point.x * 9))), centerY = min(8, Int(floor(point.y * 9)))
        let left = max(0, centerX - 2), right = min(9, centerX + 3)
        let top = max(0, centerY - 2), bottom = min(9, centerY + 3)
        #expect(actual.proxyWidth == 9 && actual.proxyHeight == 9)
        #expect(actual.windowX == left && actual.windowY == top)
        #expect(actual.windowWidth == right - left && actual.windowHeight == bottom - top)
        #expect(actual.windowPixelCount == ((point.x == 0.5) ? 25 : 9))
        #expect(actual.validPixelCount == actual.windowPixelCount)
        #expect(actual.visibleEquivalent == Double(actual.windowPixelCount))
        let expectedRed = (left..<right).map { encode(0.1 + 0.05 * Double($0)) }.reduce(0, +) / Double(right - left)
        let expectedGreen = (top..<bottom).map { encode(0.1 + 0.04 * Double($0)) }.reduce(0, +) / Double(bottom - top)
        expectClose(actual.sample.red, expectedRed)
        expectClose(actual.sample.green, expectedGreen)
        expectClose(actual.sample.blue, encode(0.2))
        #expect(actual.windowPixelCount * 4 * MemoryLayout<Float>.stride <= LevelsSampler.maximumReadbackBytes)
    }

    @Test func translatedInputExtentsUseTheSameRelativePixelWindow() throws {
        let graph = try coordinateGrid()
        let moved = graph.transformed(by: .init(translationX: 17, y: 31))
        let point = CGPoint(x: 0.2, y: 0.8)
        let original = try LevelsSampler.sample(graph: graph, normalizedTopLeft: point, context: Self.context)
        let shifted = try LevelsSampler.sample(graph: moved, normalizedTopLeft: point, context: Self.context)
        #expect(original.proxyWidth == shifted.proxyWidth && original.proxyHeight == shifted.proxyHeight)
        #expect(original.windowX == shifted.windowX && original.windowY == shifted.windowY)
        expectClose(original.sample.red, shifted.sample.red)
        expectClose(original.sample.green, shifted.sample.green)
        expectClose(original.sample.blue, shifted.sample.blue)
    }

    @Test func eachPixelIsUnpremultipliedAndEncodedBeforeAlphaWeightedAveraging() throws {
        let graph = try image(width: 5, height: 5) { x, y in
            let low = (x + y) % 2 == 0
            return (low ? 0.04 : 0.81, low ? 0.25 : 0.64, low ? -0.02 : 2, low ? 0.25 : 1)
        }
        let actual = try LevelsSampler.sample(graph: graph, normalizedTopLeft: .init(x: 0.5, y: 0.5), context: Self.context)
        // Thirteen quarter-alpha low pixels and twelve opaque high pixels.
        let mass = 13 * 0.25 + 12.0
        #expect(actual.visibleEquivalent == mass && actual.validPixelCount == 25)
        expectClose(actual.sample.red, (13 * 0.25 * encode(0.04) + 12 * encode(0.81)) / mass)
        expectClose(actual.sample.green, (13 * 0.25 * encode(0.25) + 12 * encode(0.64)) / mass)
        expectClose(actual.sample.blue, (13 * 0.25 * encode(-0.02) + 12 * encode(2)) / mass)
        let wrongEncodingAfterMean = encode((13 * 0.25 * 0.04 + 12 * 0.81) / mass)
        #expect(abs(actual.sample.red - wrongEncodingAfterMean) > 0.02)
    }

    @Test(arguments: [0.25, 1.0])
    func signedAndHDRSamplesRetainFloatPrecisionAndAlphaDoesNotDarkenThem(alpha: Double) throws {
        let graph = try image(width: 5, height: 5) { _, _ in (-0.18, 0.180_001, 4, alpha) }
        let actual = try LevelsSampler.sample(graph: graph, normalizedTopLeft: .init(x: 0.5, y: 0.5), context: Self.context)
        expectClose(actual.sample.red, encode(-0.18))
        expectClose(actual.sample.green, encode(0.180_001))
        expectClose(actual.sample.blue, encode(4))
        #expect(actual.sample.red < 0 && actual.sample.blue > 1)
        #expect(actual.visibleEquivalent == 25 * alpha)
        let fine = try image(width: 5, height: 5) { _, _ in (-0.18, 0.180_003, 4, alpha) }
        let next = try LevelsSampler.sample(graph: fine, normalizedTopLeft: .init(x: 0.5, y: 0.5), context: Self.context)
        #expect(next.sample.green > actual.sample.green)
        #expect(next.sample.green - actual.sample.green < 1 / 65_535)
    }

    @Test func transparentAndNonfinitePixelsDoNotContaminateAValidProbe() throws {
        let validPixel: [Float] = [0.18, 0.25, 0.4, 1]
        var pixels: [Float] = Array(repeating: validPixel, count: 25).flatMap { $0 }
        let invalid: [[Float]] = [[.nan, 0.2, 0.3, 1], [.infinity, 0.2, 0.3, 1],
            [0.1, 0.2, 0.3, .nan], [0.1, 0.2, 0.3, -.infinity],
            [.nan, .infinity, -.infinity, 0], [0.1, 0.2, 0.3, -0.1],
            [0.1, 0.2, 0.3, 2], [.greatestFiniteMagnitude, 0, 0, .leastNonzeroMagnitude]]
        for (index, value) in invalid.enumerated() { pixels.replaceSubrange(index * 4..<(index + 1) * 4, with: value) }
        let result = try reduce(pixels)
        #expect(result.validPixelCount == 17 && result.visibleEquivalent == 17)
        expectClose(result.sample.red, encode(Double(Float(0.18))))
        expectClose(result.sample.green, encode(0.25))
        expectClose(result.sample.blue, encode(Double(Float(0.4))))
        let transparent = try image(width: 5, height: 5) { _, _ in (4, -1, 0.5, 0) }
        #expect(throws: LevelsSamplingError.insufficientCoverage) {
            try LevelsSampler.sample(graph: transparent, normalizedTopLeft: .init(x: 0.5, y: 0.5), context: Self.context)
        }
    }

    @Test func coverageUsesActualClippedWindowAndOneOpaqueEquivalentMinimum() throws {
        var pixels = [Float](repeating: 0, count: 100)
        for index in 0..<6 { pixels[index * 4 + 3] = 1 }
        pixels[6 * 4 + 3] = 0.25
        #expect(try reduce(pixels).visibleEquivalent == 6.25)
        pixels[6 * 4 + 3] = Float(0.25).nextDown
        #expect(throws: LevelsSamplingError.insufficientCoverage) { try reduce(pixels) }
        let corner = try image(width: 9, height: 9) { _, _ in (0.18, 0.18, 0.18, 0.25) }
        let clipped = try LevelsSampler.sample(graph: corner, normalizedTopLeft: .zero, context: Self.context)
        #expect(clipped.windowPixelCount == 9 && clipped.visibleEquivalent == 2.25)
        let small = try image(width: 1, height: 1) { _, _ in (0.18, 0.18, 0.18, 0.25) }
        #expect(throws: LevelsSamplingError.insufficientCoverage) {
            try LevelsSampler.sample(graph: small, normalizedTopLeft: .zero, context: Self.context)
        }
        let opaque = try image(width: 1, height: 1) { _, _ in (0.18, 0.18, 0.18, 1) }
        #expect(try LevelsSampler.sample(graph: opaque, normalizedTopLeft: .zero, context: Self.context).visibleEquivalent == 1)
    }

    @Test func aNonfiniteNativePixelIsMarkedInvisibleBeforeReadback() throws {
        let graph = try image(width: 5, height: 5) { x, y in
            (x == 2 && y == 2 ? .nan : 0.18, 0.25, 0.4, 1)
        }
        let result = try LevelsSampler.sample(graph: graph, normalizedTopLeft: .init(x: 0.5, y: 0.5), context: Self.context)
        #expect(result.validPixelCount == 24 && result.visibleEquivalent == 24)
        expectClose(result.sample.red, encode(0.18))
        expectClose(result.sample.green, encode(0.25))
        expectClose(result.sample.blue, encode(0.4))
    }

    @Test(arguments: ["sRGB", "displayP3"])
    func sourceICCConversionPrecedesTheSignedSRGBMeasurement(profile: String) throws {
        let space = try #require(CGColorSpace(name: profile == "sRGB" ? CGColorSpace.sRGB : CGColorSpace.displayP3))
        let values: [Double] = [0.2, 0.8, 0.3]
        let graph = try image(width: 5, height: 5, space: space) { _, _ in (values[0], values[1], values[2], 0.25) }
        let actual = try LevelsSampler.sample(graph: graph, normalizedTopLeft: .init(x: 0.5, y: 0.5), context: Self.context)
        let source = try #require(CGColor(colorSpace: space, components: values.map { CGFloat($0) } + [1]))
        let converted = try #require(source.converted(to: Self.space, intent: .relativeColorimetric, options: nil)?.components)
        for (measured, linear) in zip([actual.sample.red, actual.sample.green, actual.sample.blue], converted.prefix(3)) {
            expectClose(measured, encode(Double(linear)), tolerance: 0.000_5)
        }
    }

    @Test func validSDRP3GamutCoordinatesAreNotMistakenForHDRClipping() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let graph = try image(width: 5, height: 5, space: p3) { _, _ in (0, 1, 0, 1) }
        let sample = try LevelsSampler.sample(graph: graph, normalizedTopLeft: .init(x: 0.5, y: 0.5), context: Self.context).sample
        #expect(sample.red < 0 && sample.green > 1 && sample.blue < 0)
    }

    @Test func invalidCoordinatesDimensionsAndWindowsAreControlledErrors() throws {
        let graph = try coordinateGrid()
        for point in [CGPoint(x: -0.01, y: 0.5), .init(x: 0.5, y: 1.01), .init(x: .nan, y: 0.5)] {
            #expect(throws: LevelsSamplingError.invalidGeometry) {
                try LevelsSampler.sample(graph: graph, normalizedTopLeft: point, context: Self.context)
            }
        }
        for extent in [CGRect.zero, .init(x: 0, y: 0, width: 10, height: 9), .init(x: 0.5, y: 0, width: 5, height: 5)] {
            #expect(throws: LevelsSamplingError.invalidGeometry) {
                try LevelsSampler.sample(graph: graph, extent: extent, normalizedTopLeft: .zero, context: Self.context)
            }
        }
        #expect(throws: LevelsSamplingError.invalidGeometry) {
            try LevelsSampler.reduce(pixels: [], proxyWidth: 5, proxyHeight: 5,
                windowX: 0, windowY: 0, windowWidth: 5, windowHeight: 5)
        }
    }

    @Test func cancellationPreventsAnySamplePublication() async throws {
        let graph = try coordinateGrid()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LevelsSampler.sample(graph: graph, normalizedTopLeft: .zero, context: Self.context)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func coordinateGrid() throws -> CIImage {
        let kernel = try #require(CIColorKernel(source: """
            kernel vec4 levelsSamplingGrid() {
                vec2 p = floor(destCoord());
                return vec4(0.1 + 0.05 * p.x, 0.1 + 0.04 * (8.0 - p.y), 0.2, 1.0);
            }
            """))
        return try #require(kernel.apply(extent: CGRect(x: 0, y: 0, width: 9, height: 9), arguments: []))
    }

    private func image(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                       pixel: (Int, Int) -> (Double, Double, Double, Double)) throws -> CIImage {
        var pixels = [Float]()
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                pixels += [Float(r * a), Float(g * a), Float(b * a), Float(a)]
            }
        }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width * 16, space: space,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        return CIImage(cgImage: image)
    }

    private func reduce(_ pixels: [Float]) throws -> LevelsSampleReport {
        try LevelsSampler.reduce(pixels: pixels, proxyWidth: 5, proxyHeight: 5,
            windowX: 0, windowY: 0, windowWidth: 5, windowHeight: 5)
    }

    private func encode(_ linear: Double) -> Double {
        let magnitude = abs(linear)
        let encoded = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return linear < 0 ? -encoded : encoded
    }

    private func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.000_01,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.isFinite && abs(actual - expected) < tolerance,
                "Sample \(actual) differs from reference \(expected)", sourceLocation: sourceLocation)
    }
}
