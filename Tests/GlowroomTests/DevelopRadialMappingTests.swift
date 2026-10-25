import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Shared radial warp and canvas coordinates")
struct DevelopRadialMappingTests {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [.workingColorSpace: space,
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    @Test func inverseAndForwardMatchIndependentFormulaAcrossAffineCombinations() throws {
        let extent = CGRect(x: 13, y: -7, width: 6000, height: 4000)
        for slider in [-100.0, -50, 50, 100] {
            for turns in 0...3 { for flip in [false, true] { for angle in [-17.0, 0, 17] {
                let geometry = DevelopGeometry(crop: try .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                    quarterTurns: turns, straightenAngle: angle, constrainToImage: false,
                    flipHorizontal: flip, flipVertical: !flip, optics: try .init(distortion: slider))
                let plan = try DevelopGeometryPlan(sourceExtent: extent, geometry: geometry)
                var affineOnly = geometry; affineOnly.optics = .neutral
                let affine = try DevelopGeometryPlan(sourceExtent: extent, geometry: affineOnly)
                for y in [0.0, 0.25, 0.5, 0.75, 1] { for x in [0.0, 0.25, 0.5, 0.75, 1] {
                    let output = CGPoint(x: x * plan.outputExtent.width, y: y * plan.outputExtent.height)
                    guard let warped = affine.inputPoint(fromOutputTopLeft: output) else { continue }
                    let dx = Double(warped.x) - 3000, dy = Double(warped.y) - 2000
                    let scale = 1 - 0.002 * slider * (dx * dx + dy * dy) / 13_000_000
                    let expected = CGPoint(x: 3000 + dx * scale, y: 2000 + dy * scale)
                    guard (0...6000).contains(expected.x), (0...4000).contains(expected.y) else {
                        #expect(plan.inputPoint(fromOutputTopLeft: output) == nil); continue
                    }
                    let actual = try #require(plan.inputPoint(fromOutputTopLeft: output))
                    #expect(hypot(actual.x - expected.x, actual.y - expected.y) < 0.000_001)
                    let back = try #require(plan.outputPoint(fromInputTopLeft: actual))
                    #expect(hypot(back.x - output.x, back.y - output.y) <= 0.1)
                } }
            } } }
        }
    }

    @Test func constrainedBoundsContainOnlySourcePixelsAndRejectHugePlans() throws {
        for slider in [-100.0, 100] {
            let geometry = DevelopGeometry(optics: try .init(distortion: slider))
            let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 6000, height: 4000), geometry: geometry)
            for x in 0...20 { for y in 0...20 {
                #expect(plan.inputPoint(fromOutputTopLeft: CGPoint(x: Double(x) / 20 * plan.outputExtent.width,
                    y: Double(y) / 20 * plan.outputExtent.height)) != nil)
            } }
            #expect(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: geometry, width: 6000, height: 4000)! >= 6000 * 4000 * 16)
            #expect(throws: EditRenderError.self) {
                try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 1e12, height: 1e12), geometry: geometry)
            }
        }
    }

    @Test func actualFloatWarpMatchesCoordinateReferenceAndPreservesHDRAndAlpha() throws {
        let extent = CGRect(x: 0, y: 0, width: 128, height: 96)
        let inputKernel = try #require(CIColorKernel(source: """
            kernel vec4 coordinateFixture() {
                vec2 p = destCoord();
                return vec4(p.x / 256.0, p.y / 192.0, 1.0, 0.5);
            }
            """))
        let source = try #require(inputKernel.apply(extent: extent, arguments: []))
        for slider in [-100.0, 100] {
            for constrained in [false, true] {
                let geometry = DevelopGeometry(quarterTurns: 1, straightenAngle: 13,
                    constrainToImage: constrained, flipHorizontal: true, optics: try .init(distortion: slider))
                let plan = try DevelopGeometryPlan(sourceExtent: extent, geometry: geometry)
                let output = try DevelopGeometryRenderer.apply(to: source, geometry: geometry, extent: extent)
                let width = plan.outputSize.width, height = plan.outputSize.height
                var pixels = [Float](repeating: 0, count: width * height * 4)
                pixels.withUnsafeMutableBytes {
                    Self.context.render(output, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                        bounds: output.extent, format: .RGBAf, colorSpace: Self.space)
                }
                var transparent = 0, checked = 0
                for row in stride(from: 0, to: height, by: 3) { for col in stride(from: 0, to: width, by: 3) {
                    let index = (row * width + col) * 4
                    // CIContext's bitmap rows are top-left first. The fixture
                    // itself encodes bottom-left destCoord(), hence only its
                    // green value (below), not the requested output row, flips.
                    let sourcePoint = plan.inputPoint(fromOutputTopLeft: CGPoint(x: Double(col) + 0.5,
                        y: Double(row) + 0.5))
                    if let p = sourcePoint, p.x > 2, p.x < 126, p.y > 2, p.y < 94 {
                        #expect(abs(Double(pixels[index]) - p.x / 256) < 0.0001)
                        #expect(abs(Double(pixels[index + 1]) - (96 - p.y) / 192) < 0.0001)
                        #expect(abs(pixels[index + 2] - 1) < 0.0001)
                        #expect(abs(pixels[index + 3] - 0.5) < 0.0001)
                        checked += 1
                    } else if pixels[index + 3] == 0 {
                        #expect(pixels[index] == 0 && pixels[index + 1] == 0 && pixels[index + 2] == 0)
                        transparent += 1
                    }
                } }
                #expect(checked > 100)
                if !constrained { #expect(transparent > 0) }
            }
        }
    }

    @Test func canvasAccessRoundtripsStoredSourceCoordinates() throws {
        let geometry = DevelopGeometry(crop: try .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            quarterTurns: 3, straightenAngle: 12, constrainToImage: false, flipHorizontal: true,
            optics: try .init(distortion: 100))
        let mapping = try DevelopCanvasCoordinateMapping(sourceSize: CGSize(width: 6000, height: 4000), geometry: geometry)
        let rect = CGRect(x: 20, y: 40, width: 700, height: 500)
        for point in [try LocalMaskPoint(x: 0.5, y: 0.5), try .init(x: 0.4, y: 0.6)] {
            let screen = try #require(mapping.viewPoint(for: point, in: rect))
            let source = try #require(mapping.sourcePoint(at: screen, in: rect))
            #expect(abs(source.x - point.x) * 6000 <= 0.1)
            #expect(abs(source.y - point.y) * 4000 <= 0.1)
        }
        let identity = try DevelopCanvasCoordinateMapping(sourceSize: CGSize(width: 6000, height: 4000))
        let lowerRight = try LocalMaskPoint(x: 1, y: 1)
        #expect(identity.sourcePoint(at: CGPoint(x: rect.maxX, y: rect.maxY), in: rect) == lowerRight)
        let center = try LocalMaskPoint(x: 0.5, y: 0.5)
        #expect(identity.sourcePoint(at: CGPoint(x: rect.midX, y: rect.midY), in: rect) == center)
    }

    @Test func originalPixelGraphIsExactlyPreservedAtZeroDistortion() throws {
        let extent = CGRect(x: 0, y: 0, width: 48, height: 32)
        let fixture = try #require(CIColorKernel(source: """
            kernel vec4 neutralWarpFixture() {
                vec2 p = destCoord();
                float alpha = p.x < 16.0 ? 0.0 : (p.x < 32.0 ? 0.25 : 1.0);
                return vec4(vec3(p.x / 16.0, -0.1, p.y / 8.0) * alpha, alpha);
            }
            """)?.apply(extent: extent, arguments: []))
        for angle in [0.0, 17] {
            let historical = DevelopGeometry(crop: try .init(x: 0.125, y: 0.125, width: 0.75, height: 0.75),
                quarterTurns: 1, straightenAngle: angle, flipHorizontal: true)
            var explicit = historical; explicit.optics = try .init(distortion: -0.0)
            let previous = try DevelopGeometryRenderer.apply(to: fixture, geometry: historical, extent: extent)
            let zero = try DevelopGeometryRenderer.apply(to: fixture, geometry: explicit, extent: extent)
            #expect(previous.extent == zero.extent)
            #expect(read(previous) == read(zero))
            #expect(try DevelopGeometryPlan(sourceExtent: extent, geometry: explicit).radial == nil)
        }
    }

    @Test func transparentWarpEdgesPreservePremultipliedHDRColorWithoutBlackFringes() throws {
        let extent = CGRect(x: 0, y: 0, width: 128, height: 96)
        // Straight RGB includes an HDR channel and an extended-gamut negative.
        let source = CIImage(color: CIColor(red: 2, green: 0.25, blue: -0.1, alpha: 1, colorSpace: Self.space)!)
            .cropped(to: extent)
        let geometry = DevelopGeometry(constrainToImage: false, optics: try .init(distortion: -100))
        let output = try DevelopGeometryRenderer.apply(to: source, geometry: geometry, extent: extent)
        let pixels = read(output)
        var opaque = 0, transparent = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[i + 3]
            #expect(alpha.isFinite && alpha >= 0 && alpha <= 1)
            if alpha == 0 {
                #expect(pixels[i] == 0 && pixels[i + 1] == 0 && pixels[i + 2] == 0)
                transparent += 1
            } else {
                #expect(abs(pixels[i] / alpha - 2) < 0.000_01)
                #expect(abs(pixels[i + 1] / alpha - 0.25) < 0.000_01)
                #expect(abs(pixels[i + 2] / alpha + 0.1) < 0.000_01)
                opaque += 1
            }
        }
        #expect(opaque > 100 && transparent > 100)
    }

    @Test func normalizedRadialContractDoesNotChangeWithPreviewResolution() throws {
        for distortion in [-100.0, 100] {
            let geometry = DevelopGeometry(crop: try .init(x: 0.125, y: 0.125, width: 0.75, height: 0.75),
                quarterTurns: 3, constrainToImage: false, flipHorizontal: true,
                optics: try .init(distortion: distortion))
            let preview = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 1536, height: 1024), geometry: geometry)
            let full = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 6144, height: 4096), geometry: geometry)
            for y in [0.1, 0.5, 0.9] { for x in [0.1, 0.5, 0.9] {
                let small = try #require(preview.inputPoint(fromOutputTopLeft: CGPoint(
                    x: x * preview.outputExtent.width, y: y * preview.outputExtent.height)))
                let large = try #require(full.inputPoint(fromOutputTopLeft: CGPoint(
                    x: x * full.outputExtent.width, y: y * full.outputExtent.height)))
                #expect(hypot(small.x - large.x / 4, small.y - large.y / 4) <= 0.5)
            } }
        }
    }

    private func read(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            Self.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                bounds: image.extent, format: .RGBAf, colorSpace: Self.space)
        }
        return pixels
    }
}
