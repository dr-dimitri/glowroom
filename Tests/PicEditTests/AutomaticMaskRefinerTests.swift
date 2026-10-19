import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Automatic mask edge refinement", .timeLimit(.minutes(2)))
struct AutomaticMaskRefinerTests {
    @Test(arguments: [UInt8(0), 96, 255])
    func constantCoverageRemainsConstantAcrossImageEdges(_ coverage: UInt8) throws {
        let width = 256, height = 128
        let guide = try image(width: width, height: height) { x, y in
            (UInt8(x), UInt8(y * 2), x < 100 ? 220 : 35)
        }
        let input = try LocalMaskRaster(width: width, height: height,
                                       bytes: Data(repeating: coverage, count: width * height))
        let refined = try AutomaticMaskRefiner.refine(input, guide: guide)
        #expect(refined.width == width && refined.height == height)
        let maximumError = refined.bytes.map { abs(Int($0) - Int(coverage)) }.max() ?? 0
        // Image texture must not become an invented selection, and scalar
        // coverage must not acquire a display-gray gamma curve.
        #expect(maximumError <= 2)
    }

    @Test func keepsTopLeftOrientationAndAThinEnclosedBackgroundGap() throws {
        let width = 256, height = 128
        func selected(_ x: Int, _ y: Int) -> Bool {
            x < 173 && y < 87 && !(x >= 97 && x < 99 && y >= 23 && y < 65)
        }
        let input = try mask(width: width, height: height) { x, y in selected(x, y) ? 255 : 0 }
        let guide = try image(width: width, height: height) { x, y in
            selected(x, y) ? (45, 139, 45) : (220, 65, 55)
        }
        let refined = try AutomaticMaskRefiner.refine(input, guide: guide)
        #expect(refined.bytes[10 * width + 10] >= 250)
        #expect(refined.bytes[110 * width + 10] <= 5)
        #expect(refined.bytes[10 * width + 230] <= 5)
        // A two-pixel background opening is surrounded by foreground. An
        // isotropic blur would fill it, even though the image has clear edges.
        for y in [27, 43, 60] {
            #expect(refined.bytes[y * width + 97] <= 12)
            #expect(refined.bytes[y * width + 98] <= 12)
            #expect(refined.bytes[y * width + 95] >= 243)
            #expect(refined.bytes[y * width + 100] >= 243)
        }
    }

    @Test func uncertainBoundaryFollowsAnAlmostEqualLuminanceColorEdge() throws {
        let fixture = try chromaticEdge()
        // These sRGB colors differ in hue, with nearly identical linear-light
        // Rec.709 luminance. A luminance-only guide misses this boundary.
        let redLuminance = luminance((220, 65, 55))
        let greenLuminance = luminance((45, 139, 45))
        #expect(abs(redLuminance - greenLuminance) < 0.004)
        let refined = try AutomaticMaskRefiner.refine(fixture.mask, guide: fixture.guide)
        let row = 64 * fixture.mask.width
        let inputContrast = Int(fixture.mask.bytes[row + 127]) - Int(fixture.mask.bytes[row + 128])
        let outputContrast = Int(refined.bytes[row + 127]) - Int(refined.bytes[row + 128])
        #expect(outputContrast >= inputContrast + 15)
        #expect(refined.bytes[row + 127] <= fixture.mask.bytes[row + 127])
        #expect(refined.bytes[row + 128] < fixture.mask.bytes[row + 128])
        #expect(zip(refined.bytes, fixture.mask.bytes).allSatisfy { $0 <= $1 },
                "Refinement must not extend a loose semantic silhouette into definite background")
        #expect(refined.bytes[row + 100] >= 250)
        #expect(refined.bytes[row + 155] <= 5)
    }

    @Test func softwarePreferenceAndAutomaticDeviceAgreeOnChromaticEdges() throws {
        let fixture = try chromaticEdge()
        let automatic = try AutomaticMaskRefiner.refine(fixture.mask, guide: fixture.guide)
        let software = try AutomaticMaskRefiner.refine(fixture.mask, guide: fixture.guide,
                                                       softwareRenderer: true)
        let errors = zip(automatic.bytes, software.bytes).map { abs(Int($0) - Int($1)) }
        #expect((errors.max() ?? 0) <= 4)
        #expect(Double(errors.reduce(0, +)) / Double(errors.count) <= 0.5)
    }

    @Test func alreadyCancelledWorkDoesNotPublishARefinedRaster() async throws {
        let task = Task {
            let fixture = try chromaticEdge()
            withUnsafeCurrentTask { $0?.cancel() }
            return try AutomaticMaskRefiner.refine(fixture.mask, guide: fixture.guide)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func chromaticEdge() throws -> (mask: LocalMaskRaster, guide: CGImage) {
        let width = 256, height = 128
        let input = try mask(width: width, height: height) { x, _ in
            UInt8(min(255, max(0, (130 - x) * 51)))
        }
        let guide = try image(width: width, height: height) { x, _ in
            x < 128 ? (220, 65, 55) : (45, 139, 45)
        }
        return (input, guide)
    }

    private func mask(width: Int, height: Int, pixel: (Int, Int) -> UInt8) throws -> LocalMaskRaster {
        var bytes = Data(count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = pixel(x, y) } }
        return try LocalMaskRaster(width: width, height: height, bytes: bytes)
    }

    private func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = Data(count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let color = pixel(x, y), offset = (y * width + x) * 4
            bytes[offset] = color.0; bytes[offset + 1] = color.1
            bytes[offset + 2] = color.2; bytes[offset + 3] = 255
        } }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func luminance(_ color: (UInt8, UInt8, UInt8)) -> Double {
        func linear(_ value: UInt8) -> Double {
            let v = Double(value) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
    }
}
