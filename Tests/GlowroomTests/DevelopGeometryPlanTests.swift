import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Shared rendered geometry and inverse sampling")
struct DevelopGeometryPlanTests {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false
    ])

    @Test func adaptiveInputDimensionsUseTheActualRoundedCropEdges() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let geometry = DevelopGeometry(crop: crop)
        let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 37, height: 23), geometry: geometry)
        // Independent integer anchors: floor(7.4), ceil(22.2), floor(4.6), ceil(13.8).
        #expect(plan.cropRect == CGRect(x: 7, y: 9, width: 16, height: 10))
        #expect(plan.outputExtent == CGRect(x: 0, y: 0, width: 16, height: 10))
        expect(try #require(plan.inputPoint(fromOutputTopLeft: CGPoint(x: 0.5, y: 0.5))), CGPoint(x: 7.5, y: 4.5))
        expect(try #require(plan.inputPoint(fromOutputTopLeft: CGPoint(x: 15.5, y: 9.5))), CGPoint(x: 22.5, y: 13.5))

        let larger = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 100, height: 100), geometry: geometry)
        #expect(larger.cropRect == CGRect(x: 20, y: 40, width: 40, height: 40))
        #expect(larger != plan, "A frame cannot use its asset's larger dimensions to invert an adaptive raster")
        let equivalent = try DevelopGeometryPlan(sourceExtent: plan.sourceExtent, geometry: geometry)
        #expect(Set([plan, equivalent]).count == 1)
    }

    @Test func nonzeroSourceOriginsDoNotShiftTopLeftPixelCoordinates() throws {
        let geometry = DevelopGeometry(crop: try .init(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 13, y: -7, width: 37, height: 23), geometry: geometry)
        #expect(plan.cropRect == CGRect(x: 20, y: 2, width: 16, height: 10))
        let first = try #require(plan.inputPoint(fromOutputTopLeft: CGPoint(x: 0.5, y: 0.5)))
        expect(first, CGPoint(x: 7.5, y: 4.5))
        expect(try #require(plan.outputPoint(fromInputTopLeft: first)), CGPoint(x: 0.5, y: 0.5))
    }

    @Test func allQuarterTurnsAndMirrorsFollowIndependentPixelCenterAnchors() throws {
        let crop = try DevelopCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        for turns in 0...3 {
            for horizontal in [false, true] {
                for vertical in [false, true] {
                    let geometry = DevelopGeometry(crop: crop, quarterTurns: turns,
                        flipHorizontal: horizontal, flipVertical: vertical)
                    let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 12, height: 8), geometry: geometry)
                    let x = horizontal ? 5.5 : 0.5, y = vertical ? 3.5 : 0.5
                    let expected: CGPoint = switch turns {
                    case 0: CGPoint(x: x, y: y)
                    case 1: CGPoint(x: 4 - y, y: x)
                    case 2: CGPoint(x: 6 - x, y: 4 - y)
                    default: CGPoint(x: y, y: 6 - x)
                    }
                    let original = CGPoint(x: 3.5, y: 2.5)
                    expect(try #require(plan.outputPoint(fromInputTopLeft: original)), expected)
                    expect(try #require(plan.inputPoint(fromOutputTopLeft: expected)), original)
                }
            }
        }
    }

    @Test func renderedMarkedPixelsAgreeWithTheInverseForEveryTurnAndMirror() throws {
        let width = 16, height = 12
        let source = try fixture(width: width, height: height, marked: true)
        for turns in 0...3 {
            for horizontal in [false, true] {
                for vertical in [false, true] {
                    let geometry = DevelopGeometry(crop: try .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                        quarterTurns: turns, flipHorizontal: horizontal, flipVertical: vertical)
                    let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: width, height: height), geometry: geometry)
                    let graph = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: source), geometry: geometry, extent: plan.sourceExtent)
                    #expect(graph.extent == plan.outputExtent)
                    let pixels = try read(graph)
                    for row in 0..<plan.outputSize.height {
                        for column in 0..<plan.outputSize.width {
                            let input = try #require(plan.inputPoint(fromOutputTopLeft:
                                CGPoint(x: Double(column) + 0.5, y: Double(row) + 0.5)))
                            let x = Int(floor(input.x)), y = Int(floor(input.y))
                            let expected = markedPixel(x: x, y: y, width: width, height: height)
                            let offset = (row * plan.outputSize.width + column) * 4
                            for channel in 0..<4 { expect(pixels[offset + channel], expected[channel], tolerance: 0.000_002) }
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [-45.0, -17, 17, 45])
    func freeAnglesUseTheRenderedCropAndRoundedCanvas(angle: Double) throws {
        let source = try fixture(width: 96, height: 64)
        let crop = try DevelopCropRect(x: 0.125, y: 0.125, width: 0.75, height: 0.75)
        for constrained in [false, true] {
            for turns in 0...3 {
                for horizontal in [false, true] {
                    for vertical in [false, true] {
                        let geometry = DevelopGeometry(crop: crop, quarterTurns: turns,
                            straightenAngle: angle, constrainToImage: constrained,
                            flipHorizontal: horizontal, flipVertical: vertical)
                        let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 96, height: 64), geometry: geometry)
                        let size = try DevelopGeometryRenderer.outputSize(width: 96, height: 64, geometry: geometry)
                        #expect(size.width == plan.outputSize.width && size.height == plan.outputSize.height)
                        let graph = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: source), geometry: geometry, extent: plan.sourceExtent)
                        #expect(graph.extent == plan.outputExtent)
                        let pixels = try read(graph)
                        let center = CGPoint(x: plan.outputExtent.midX, y: plan.outputExtent.midY)
                        expect(try #require(plan.inputPoint(fromOutputTopLeft: center)), CGPoint(x: 48, y: 32))
                        var checked = 0
                        for row in [size.height / 4, size.height / 2, size.height * 3 / 4] {
                            for column in [size.width / 4, size.width / 2, size.width * 3 / 4] {
                                let output = CGPoint(x: Double(column) + 0.5, y: Double(row) + 0.5)
                                guard let input = plan.inputPoint(fromOutputTopLeft: output),
                                      (14...82).contains(input.x), (10...54).contains(input.y) else { continue }
                                let offset = (row * size.width + column) * 4
                                // Linear coordinate ramps give an independent
                                // pixel oracle even after subpixel interpolation.
                                expect(pixels[offset], Float(input.x / 96), tolerance: 0.000_1)
                                expect(pixels[offset + 1], Float(input.y / 64), tolerance: 0.000_1)
                                expect(pixels[offset + 3], 1, tolerance: 0.000_01)
                                expect(try #require(plan.outputPoint(fromInputTopLeft: input)), output)
                                checked += 1
                            }
                        }
                        #expect(checked > 0, "Each rotation/mirror case must test an opaque interior sample")
                    }
                }
            }
        }
    }

    @Test(arguments: [-30.0, 30])
    func transparentRotationCornersAreRejectedAndTheEstablishedCanvasIsUnchanged(angle: Double) throws {
        let source = try fixture(width: 100, height: 50)
        for constrained in [false, true] {
            for turns in 0...3 {
                let geometry = DevelopGeometry(quarterTurns: turns, straightenAngle: angle, constrainToImage: constrained)
                let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 100, height: 50), geometry: geometry)
                let base = constrained ? (53, 26) : (112, 94)
                #expect(plan.outputSize.width == (turns.isMultiple(of: 2) ? base.0 : base.1))
                #expect(plan.outputSize.height == (turns.isMultiple(of: 2) ? base.1 : base.0))
                let graph = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: source), geometry: geometry, extent: plan.sourceExtent)
                let pixels = try read(graph)
                for (column, row) in [(0, 0), (plan.outputSize.width - 1, 0),
                                      (0, plan.outputSize.height - 1), (plan.outputSize.width - 1, plan.outputSize.height - 1)] {
                    let point = CGPoint(x: Double(column) + 0.5, y: Double(row) + 0.5)
                    let alpha = pixels[(row * plan.outputSize.width + column) * 4 + 3]
                    if constrained {
                        #expect(plan.inputPoint(fromOutputTopLeft: point) != nil)
                        expect(alpha, 1, tolerance: 0.000_01)
                    } else {
                        #expect(plan.inputPoint(fromOutputTopLeft: point) == nil)
                        expect(alpha, 0, tolerance: 0.000_01)
                    }
                }
            }
        }
    }

    @Test func logicalZoomPanAndRetinaLocationsSelectTheSameMarkedSourcePixel() throws {
        let geometry = DevelopGeometry(crop: try .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5), quarterTurns: 1)
        let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 12, height: 8), geometry: geometry)
        let canvas = try CanvasGeometry(canvasSize: .init(width: 4, height: 6),
            viewportWidth: 400, viewportHeight: 300, zoom: 2, panX: 17, panY: -11)
        // Known view anchor: origin (17,-161), scale100, output center(1.5,2.5).
        // Backing pixels are converted to local logical points exactly once.
        for backingScale in [1.0, 2.0] {
            let local = try MaskPoint(x: (167 * backingScale) / backingScale,
                                      y: (89 * backingScale) / backingScale)
            let output = try #require(canvas.viewToCanvas(local))
            expect(try #require(plan.inputPoint(fromOutputTopLeft: CGPoint(x: output.x, y: output.y))), CGPoint(x: 5.5, y: 4.5))
        }
        let fit = try CanvasGeometry(canvasSize: .init(width: 4, height: 6), viewportWidth: 600, viewportHeight: 600)
        #expect(fit.viewToCanvas(try .init(x: 50, y: 300)) == nil, "Letterboxing must never become an image sample")
    }

    @Test func tinyClampedImagesAndInvalidCoordinatesHaveControlledMappings() throws {
        let plan = try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: 1, height: 20),
            geometry: .init(straightenAngle: 45))
        #expect(plan.outputSize.width == 1 && plan.outputSize.height == 1)
        expect(try #require(plan.inputPoint(fromOutputTopLeft: CGPoint(x: 0.5, y: 0.5))), CGPoint(x: 0.5, y: 10))
        let edge = try #require(plan.inputPoint(fromOutputTopLeft: CGPoint(x: 0, y: 0)))
        #expect((0...1).contains(edge.x) && (0...20).contains(edge.y))
        for point in [CGPoint(x: -0.01, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
            #expect(plan.inputPoint(fromOutputTopLeft: point) == nil)
            #expect(plan.outputPoint(fromInputTopLeft: point) == nil)
        }
        #expect(throws: EditRenderError.unavailable) {
            try DevelopGeometryPlan(sourceExtent: .zero, geometry: .neutral)
        }
        #expect(throws: EditRenderError.unavailable) {
            try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1), geometry: .neutral)
        }
    }

    @Test func constrainedCropExtensionSelectsTheEdgePixelCenterIncludingTheExactMaximum() throws {
        let extent = CGRect(x: 0, y: 0, width: 100, height: 100)
        let source = try fixture(width: 100, height: 100)
        for narrowHorizontal in [false, true] {
            let crop = try DevelopCropRect(x: narrowHorizontal ? 0 : 0.5,
                y: narrowHorizontal ? 0.5 : 0, width: narrowHorizontal ? 1 : 0.01,
                height: narrowHorizontal ? 0.01 : 1)
            let geometry = DevelopGeometry(crop: crop, straightenAngle: 45, constrainToImage: true)
            let plan = try DevelopGeometryPlan(sourceExtent: extent, geometry: geometry)
            #expect(plan.outputSize.width == 1 && plan.outputSize.height == 1)
            let lower = narrowHorizontal ? plan.cropRect.minY : plan.cropRect.minX
            let upper = narrowHorizontal ? plan.cropRect.maxY : plan.cropRect.maxX
            for edge in [lower - 0.1, lower, upper, upper + 0.1] {
                // These inverse coordinates lie inside the rounded 1×1
                // output but on/beyond its one-pixel source strip.
                let extended = narrowHorizontal ? CGPoint(x: 50, y: edge) : CGPoint(x: edge, y: 50)
                let ciOutput = extended.applying(plan.inputToOutput)
                let output = CGPoint(x: ciOutput.x, y: plan.outputExtent.maxY - ciOutput.y)
                let input = try #require(plan.inputPoint(fromOutputTopLeft: output))
                let coordinate = narrowHorizontal ? input.y : input.x
                #expect(coordinate == 50.5)
                #expect(Int(floor(coordinate)) == 50,
                    "A clamped crop edge must never select a discarded neighboring pixel")
            }
            let graph = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: source), geometry: geometry, extent: extent)
            let pixel = try read(graph)
            expect(pixel[narrowHorizontal ? 1 : 0], 0.505, tolerance: 0.000_1)
        }
    }

    private func markedPixel(x: Int, y: Int, width: Int, height: Int) -> [Float] {
        let alpha: Float = [0.25, 0.5, 1][(x + y) % 3]
        return [Float(Double(x) + 0.5) / Float(width) * alpha,
                Float(Double(y) + 0.5) / Float(height) * alpha,
                Float((x * 7 + y * 11) % 31) / 31 * alpha, alpha]
    }

    private func fixture(width: Int, height: Int, marked: Bool = false) throws -> CGImage {
        var pixels = [Float]()
        for y in 0..<height {
            for x in 0..<width {
                pixels += marked ? markedPixel(x: x, y: y, width: width, height: height)
                    : [Float(Double(x) + 0.5) / Float(width), Float(Double(y) + 0.5) / Float(height), 0.3, 1]
            }
        }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width * 16, space: Self.space,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    private func read(_ graph: CIImage) throws -> [Float] {
        let width = Int(graph.extent.width), height = Int(graph.extent.height)
        let image = try #require(Self.context.createCGImage(graph, from: graph.extent,
            format: .RGBAf, colorSpace: Self.space, deferred: false))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 32, bytesPerRow: width * 16, space: Self.space,
                bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        #expect(pixels.allSatisfy { $0.isFinite })
        return pixels
    }

    private func expect(_ actual: CGPoint, _ expected: CGPoint, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual.x - expected.x) <= 1e-8 && abs(actual.y - expected.y) <= 1e-8,
            "Mapped point \(actual) differs from known source \(expected)", sourceLocation: sourceLocation)
    }

    private func expect(_ actual: Float, _ expected: Float, tolerance: Float, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.isFinite && abs(actual - expected) <= tolerance,
            "Rendered coordinate \(actual) differs from inverse source \(expected)", sourceLocation: sourceLocation)
    }
}
