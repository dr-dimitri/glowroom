import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

/// Synthetic checkerboard plus coordinate-grid landmarks. The oracle below
/// derives its own top-left affine sequence and solves the radial cubic with
/// Newton iteration; it never calls DevelopGeometryPlan/DevelopRadialMapping.
@Suite("Radial grid landmarks and shared preview/export geometry")
struct DevelopRadialGridTests {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [.workingColorSpace: space,
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    @Test func nativeGridLandmarksMatchTheIndependentCoordinateOracle() throws {
        let source = try checkerboard(width: 256, height: 192)
        for distortion in [-100.0, 100] {
            for turns in [1, 3] { for mirror in [false, true] {
                let geometry = DevelopGeometry(crop: try .init(x: 0.125, y: 0.125, width: 0.75, height: 0.75),
                    quarterTurns: turns, straightenAngle: 11, constrainToImage: false,
                    flipHorizontal: mirror, flipVertical: !mirror, optics: try .init(distortion: distortion))
                let graph = try DevelopGeometryRenderer.apply(to: CIImage(cgImage: source), geometry: geometry,
                    extent: CGRect(x: 0, y: 0, width: 256, height: 192))
                let oracle = GridOracle(width: 256, height: 192, geometry: geometry)
                #expect(graph.extent.size == oracle.outputSize)
                // Crossings of a regular 16-pixel grid, all retained by this
                // crop at both radial extremes. R/G encode source landmarks.
                for input in [CGPoint(x: 64, y: 48), CGPoint(x: 128, y: 96), CGPoint(x: 192, y: 144)] {
                    let location = try #require(oracle.output(fromSource: input))
                    let pixel = sample(graph, atTopLeft: location)
                    #expect(abs(Double(pixel[0]) * 256 - input.x) <= 0.1)
                    #expect(abs(Double(pixel[1]) * 192 - input.y) <= 0.1)
                    #expect(abs(pixel[3] - 1) <= 0.000_01)
                }
                // Cell centers distinguish alternating checkerboard squares;
                // resampling at discontinuous cell boundaries is deliberately
                // separate from the landmark coordinate-error criterion.
                for input in [CGPoint(x: 72.5, y: 56.5), CGPoint(x: 88.5, y: 56.5)] {
                    let location = try #require(oracle.output(fromSource: input))
                    let pixel = sample(graph, atTopLeft: location)
                    let square = (Int(input.x) / 16 + Int(input.y) / 16).isMultiple(of: 2)
                    #expect(abs(pixel[2] - (square ? 0.75 : 0)) < 0.000_01)
                }
            } }
        }
    }

    @Test func previewAndExportGraphsKeepGridLandmarksWithinHalfAPixelAtCommonResolution() throws {
        let source = try checkerboard(width: 256, height: 192)
        for distortion in [-100.0, 100] {
            let geometry = DevelopGeometry(crop: try .init(x: 0.125, y: 0.125, width: 0.75, height: 0.75),
                quarterTurns: 1, straightenAngle: -9, constrainToImage: false,
                flipHorizontal: true, optics: try .init(distortion: distortion))
            let settings = EditSettings(developColor: .init(hdrEnabled: true), developGeometry: geometry,
                                        toneProcessingVersion: .consistentV2)
            let bitmap = PreviewBitmap(image: source, rangeProvenance: .extended(nominalSDRWhite: 1))
            let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
            let preview = CIImage(cgImage: try EditRenderer.render(bitmap, settings: settings, session: session).image)
            let exported = try EditRenderer.filterGraph(source, settings: settings, context: Self.context)
            #expect(preview.extent == exported.extent)
            let oracle = GridOracle(width: 256, height: 192, geometry: geometry)
            for input in [CGPoint(x: 64, y: 48), CGPoint(x: 128, y: 96), CGPoint(x: 192, y: 144)] {
                let location = try #require(oracle.output(fromSource: input))
                let a = sample(preview, atTopLeft: location), b = sample(exported, atTopLeft: location)
                // Coordinate ramps are exact subpixel landmark probes, avoiding
                // a threshold/centroid ambiguity on antialiased checker edges.
                #expect(abs(Double(a[0] - b[0])) * 256 <= 0.5)
                #expect(abs(Double(a[1] - b[1])) * 192 <= 0.5)
                #expect(abs(Double(a[0]) * 256 - input.x) <= 0.5)
                #expect(abs(Double(a[1]) * 192 - input.y) <= 0.5)
            }
        }
    }

    @Test func sourceCanvasKeepsStoredPointsWhileFinalCanvasUsesFullGeometry() throws {
        let points = [try LocalMaskPoint(x: 0.3, y: 0.4), try LocalMaskPoint(x: 0.6, y: 0.55)]
        let stroke = try DevelopRetouchStroke(source: points[0], target: points[1], radius: 0.03)
        let view = CGRect(x: 30, y: 20, width: 768, height: 512)
        let sourceCanvas = try DevelopCanvasCoordinateMapping(sourceSize: CGSize(width: 1536, height: 1024))
        for turns in 0...3 { for mirror in [false, true] {
            let geometry = DevelopGeometry(crop: try .init(x: 0.125, y: 0.125, width: 0.75, height: 0.75),
                quarterTurns: turns, straightenAngle: 11, constrainToImage: false,
                flipHorizontal: mirror, flipVertical: !mirror, optics: try .init(distortion: -100),
                retouchStrokes: [stroke])
            let snapshot = try EditingSnapshot(settings: .init(developGeometry: geometry))
            let accepted = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: ArtifactJSONCodec.encode(snapshot))
            #expect(accepted.settings.developGeometry.retouchStrokes[0].source == points[0])
            #expect(accepted.settings.developGeometry.retouchStrokes[0].target == points[1])
            let finalCanvas = try DevelopCanvasCoordinateMapping(sourceSize: CGSize(width: 1536, height: 1024), geometry: geometry)
            for point in points {
                let originalView = try #require(sourceCanvas.viewPoint(for: point, in: view))
                #expect(abs(originalView.x - (view.minX + point.x * view.width)) < 1e-9)
                #expect(abs(originalView.y - (view.minY + point.y * view.height)) < 1e-9)
                #expect(sourceCanvas.sourcePoint(at: originalView, in: view) == point)
                let finalView = try #require(finalCanvas.viewPoint(for: point, in: view))
                let restored = try #require(finalCanvas.sourcePoint(at: finalView, in: view))
                #expect(abs(restored.x - point.x) * 1536 <= 0.1)
                #expect(abs(restored.y - point.y) * 1024 <= 0.1)
            }
        } }
    }

    private func checkerboard(width: Int, height: Int) throws -> CGImage {
        var pixels = [Float](); pixels.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width {
            pixels += [Float(Double(x) + 0.5) / Float(width), Float(Double(y) + 0.5) / Float(height),
                       (x / 16 + y / 16).isMultiple(of: 2) ? 0.75 : 0, 1]
        } }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width * 16, space: Self.space,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    private func sample(_ graph: CIImage, atTopLeft point: CGPoint) -> [Float] {
        let translated = graph.transformed(by: CGAffineTransform(
            translationX: 0.5 - point.x, y: 0.5 - (graph.extent.height - point.y)))
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes {
            Self.context.render(translated, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: Self.space)
        }
        return values
    }

    private struct GridOracle {
        let width: Double
        let height: Double
        let geometry: DevelopGeometry
        let left: Double
        let top: Double
        let cropWidth: Double
        let cropHeight: Double
        let straightWidth: Double
        let straightHeight: Double
        var outputSize: CGSize {
            geometry.quarterTurns.isMultiple(of: 2)
                ? CGSize(width: straightWidth, height: straightHeight)
                : CGSize(width: straightHeight, height: straightWidth)
        }
        init(width: Double, height: Double, geometry: DevelopGeometry) {
            self.width = width; self.height = height; self.geometry = geometry
            let crop = geometry.crop
            left = floor((crop?.x ?? 0) * width + 1e-9)
            top = floor((crop?.y ?? 0) * height + 1e-9)
            cropWidth = ceil(((crop?.x ?? 0) + (crop?.width ?? 1)) * width - 1e-9) - left
            cropHeight = ceil(((crop?.y ?? 0) + (crop?.height ?? 1)) * height - 1e-9) - top
            let angle = abs(geometry.straightenAngle) * .pi / 180
            straightWidth = ceil(cropWidth * cos(angle) + cropHeight * sin(angle) - 1e-9)
            straightHeight = ceil(cropWidth * sin(angle) + cropHeight * cos(angle) - 1e-9)
        }
        func output(fromSource source: CGPoint) -> CGPoint? {
            let dx = source.x - width / 2, dy = source.y - height / 2
            let sourceRadius = hypot(dx, dy) / (hypot(width, height) / 2)
            let k = -0.002 * geometry.optics.distortion
            guard sourceRadius <= 1 + k else { return nil }
            var radius = sourceRadius
            // Independent Newton solve, while production uses bisection.
            for _ in 0..<20 {
                radius -= (radius + k * radius * radius * radius - sourceRadius) / (1 + 3 * k * radius * radius)
            }
            let ratio = sourceRadius == 0 ? 1 : radius / sourceRadius
            let x = width / 2 + dx * ratio - left, y = height / 2 + dy * ratio - top
            guard x >= 0, x <= cropWidth, y >= 0, y <= cropHeight else { return nil }
            let angle = geometry.straightenAngle * .pi / 180
            var px = straightWidth / 2 + cos(angle) * (x - cropWidth / 2) - sin(angle) * (y - cropHeight / 2)
            var py = straightHeight / 2 + sin(angle) * (x - cropWidth / 2) + cos(angle) * (y - cropHeight / 2)
            if geometry.flipHorizontal { px = straightWidth - px }
            if geometry.flipVertical { py = straightHeight - py }
            var w = straightWidth, h = straightHeight
            for _ in 0..<geometry.quarterTurns {
                (px, py) = (h - py, px); (w, h) = (h, w)
            }
            return CGPoint(x: px, y: py)
        }
    }
}
