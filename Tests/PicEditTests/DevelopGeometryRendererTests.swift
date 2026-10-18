import CoreGraphics
import CoreImage
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Develop crop and manual correction rendering")
struct DevelopGeometryRendererTests {
    @Test func cropAndClockwiseTurnsKeepSourceCoordinatesAndPixelEdges() throws {
        let source = try fixture(width: 12, height: 8) { x, y in (UInt8(x * 15), UInt8(y * 25), 40, 255) }
        let crop = try DevelopCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let plain = try render(source, geometry: .init(crop: crop))
        #expect(plain.width == 6 && plain.height == 4)
        let original = try pixels(source), cropped = try pixels(plain)
        #expect(pixel(cropped, width: 6, x: 0, y: 0) == pixel(original, width: 12, x: 3, y: 2))
        for turns in 0...3 {
            let geometry = DevelopGeometry(crop: crop, quarterTurns: turns)
            let result = try render(source, geometry: geometry)
            let size = try DevelopGeometryRenderer.outputSize(width: 12, height: 8, geometry: geometry)
            #expect(result.width == size.width && result.height == size.height)
            let resultPixels = try pixels(result)
            // Top-left source coordinate (3,2) follows each clockwise rotation.
            let corner: (Int, Int) = switch turns {
            case 0: (0, 0)
            case 1: (3, 0)
            case 2: (5, 3)
            default: (0, 5)
            }
            #expect(pixel(resultPixels, width: size.width, x: corner.0, y: corner.1) == pixel(cropped, width: 6, x: 0, y: 0))
        }
        let decimal = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let size = try DevelopGeometryRenderer.outputSize(width: 100, height: 100, geometry: .init(crop: decimal))
        #expect(size.width == 40 && size.height == 40)
    }

    @Test func mirrorsActInsideCropWithoutChangingAlpha() throws {
        let source = try fixture(width: 16, height: 8) { x, y in (UInt8(x * 10), UInt8(y * 15), 30, UInt8(100 + x * 5)) }
        let original = try pixels(source)
        for horizontal in [false, true] {
            for vertical in [false, true] {
                let result = try pixels(render(source, geometry: .init(flipHorizontal: horizontal, flipVertical: vertical)))
                for (x, y) in [(0, 0), (7, 3), (15, 7)] {
                    let expected = pixel(original, width: 16, x: horizontal ? 15 - x : x, y: vertical ? 7 - y : y)
                    #expect(pixel(result, width: 16, x: x, y: y) == expected)
                }
            }
        }
    }

    @Test func cloneCopiesChosenSourceAndDoesNotTouchOutsideThePatch() throws {
        let source = try fixture { x, y in
            x < 64 ? (20, UInt8(80 + y), 170, 255) : (190, 50, 30, 255)
        }
        let patch = try DevelopRetouchStroke(mode: .clone, source: .init(x: 0.25, y: 0.25),
            target: .init(x: 0.75, y: 0.75), radius: 0.1, feather: 0.25)
        let result = try pixels(render(source, geometry: .init(retouchStrokes: [patch])))
        let original = try pixels(source)
        let actual = pixel(result, width: 128, x: 96, y: 72)
        let expected = pixel(original, width: 128, x: 32, y: 24)
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 })
        #expect(pixel(result, width: 128, x: 96, y: 24) == pixel(original, width: 128, x: 96, y: 24))
        #expect(pixel(result, width: 128, x: 32, y: 24) == pixel(original, width: 128, x: 32, y: 24))
    }

    @Test func healMatchesTargetColorWhileCloneRetainsTheSourceColor() throws {
        let source = try fixture { x, y in
            let value: UInt8 = x < 64 ? (((x + y) % 2 == 0) ? 60 : 80) : ((abs(x - 96) < 3 && abs(y - 48) < 3) ? 220 : 150)
            return (value, value, value, 255)
        }
        var outputs: [DevelopRetouchMode: Int] = [:]
        for mode in [DevelopRetouchMode.clone, .heal] {
            let patch = try DevelopRetouchStroke(mode: mode, source: .init(x: 0.25, y: 0.5),
                target: .init(x: 0.75, y: 0.5), radius: 0.12, feather: 0.5)
            let result = try pixels(render(source, geometry: .init(retouchStrokes: [patch])))
            outputs[mode] = pixel(result, width: 128, x: 96, y: 48)[0]
        }
        #expect(try #require(outputs[.clone]) < 100)
        #expect((130...190).contains(try #require(outputs[.heal])))
    }

    @Test func redEyeOnlyChangesRedDominanceInsideTheSelectedEllipseAndPreservesAlpha() throws {
        let source = try fixture { x, _ in x < 64 ? (220, 35, 25, 180) : (30, 140, 100, 180) }
        let corrections = try [
            DevelopRedEyeCorrection(center: .init(x: 0.25, y: 0.25), radiusX: 0.1, radiusY: 0.15),
            DevelopRedEyeCorrection(center: .init(x: 0.75, y: 0.25), radiusX: 0.1, radiusY: 0.15)
        ]
        let result = try pixels(render(source, geometry: .init(redEyeCorrections: corrections)))
        let original = try pixels(source)
        let corrected = pixel(result, width: 128, x: 32, y: 24), before = pixel(original, width: 128, x: 32, y: 24)
        #expect(corrected[0] < before[0] / 2)
        #expect(abs(corrected[1] - before[1]) <= 1 && abs(corrected[2] - before[2]) <= 1 && corrected[3] == before[3])
        #expect(pixel(result, width: 128, x: 32, y: 72) == pixel(original, width: 128, x: 32, y: 72))
        #expect(pixel(result, width: 128, x: 96, y: 24) == pixel(original, width: 128, x: 96, y: 24))
    }

    @Test func memoryPlanningIsBoundedAndDoesNotOverflow() throws {
        let patch = try DevelopRetouchStroke(source: .init(x: 0.25, y: 0.25), target: .init(x: 0.75, y: 0.75), radius: 0.02)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .neutral, width: 128, height: 96) == 0)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [patch]), width: 128, height: 96) == 128 * 96 * 48)
        #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: .init(retouchStrokes: [patch]), width: Int.max, height: Int.max) == nil)
    }

    private func render(_ source: CGImage, geometry: DevelopGeometry) throws -> CGImage {
        let image = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: source), geometry: geometry,
            extent: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return try #require(EditRenderer.maskCompositingContext().createCGImage(image, from: image.extent,
            format: .RGBA8, colorSpace: source.colorSpace!, deferred: false))
    }

    private func fixture(width: Int = 128, height: Int = 96,
                         pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var data = [UInt8]()
        for y in 0..<height { for x in 0..<width {
            let (r, g, b, a) = pixel(x, y)
            data += [UInt8(Int(r) * Int(a) / 255), UInt8(Int(g) * Int(a) / 255), UInt8(Int(b) * Int(a) / 255), a]
        } }
        let provider = try #require(CGDataProvider(data: Data(data) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: image.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height * 4)).map { Int(bytes[$0]) }
    }

    private func pixel(_ data: [Int], width: Int, x: Int, y: Int) -> [Int] {
        let index = (y * width + x) * 4
        return Array(data[index..<(index + 4)])
    }
}
