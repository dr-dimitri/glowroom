import Foundation
import Testing
@testable import GlowroomCore

struct CanvasGeometryTests {
    @Test func allExifOrientationsPreserveAsymmetricPixelGridAndRoundTrip() throws {
        let raw = try MaskRaster(size: .init(width: 3, height: 2), bytes: Data([1, 2, 3, 4, 5, 6]))
        let expected: [[UInt8]] = [
            [1, 2, 3, 4, 5, 6], [3, 2, 1, 6, 5, 4], [6, 5, 4, 3, 2, 1], [4, 5, 6, 1, 2, 3],
            [1, 4, 2, 5, 3, 6], [4, 1, 5, 2, 6, 3], [6, 3, 5, 2, 4, 1], [3, 6, 2, 5, 1, 4]
        ]
        for orientation in MaskImageOrientation.allCases {
            let oriented = try orientation.orient(raw)
            #expect(Array(oriented.bytes) == expected[orientation.rawValue - 1])
            #expect(oriented.size.width == (orientation.rawValue < 5 ? 3 : 2))
            for point in try [MaskPoint(x: 0, y: 0), .init(x: 3, y: 2), .init(x: 0.5, y: 1.5), .init(x: 1.25, y: 0.75)] {
                let transformed = try orientation.orientedPoint(point, rawSize: raw.size)
                #expect(try orientation.rawPoint(transformed, rawSize: raw.size) == point)
            }
            for y in 0..<2 {
                for x in 0..<3 {
                    let point = try orientation.orientedPoint(.init(x: Double(x) + 0.5, y: Double(y) + 0.5), rawSize: raw.size)
                    #expect(oriented.bytes[Int(point.y) * oriented.size.width + Int(point.x)] == raw.bytes[y * 3 + x])
                }
            }
        }
    }

    @Test func aspectFitRejectsLetterboxAndAcceptsExactEdges() throws {
        let geometry = try CanvasGeometry(canvasSize: .init(width: 100, height: 100), viewportWidth: 400, viewportHeight: 200)
        #expect(geometry.scale == 2)
        #expect(geometry.originX == 100)
        #expect(try geometry.viewToCanvas(.init(x: 99, y: 100)) == nil)
        #expect(try geometry.viewToCanvas(.init(x: 100, y: 0)) == .init(x: 0, y: 0))
        #expect(try geometry.viewToCanvas(.init(x: 300, y: 200)) == .init(x: 100, y: 100))
        #expect(try geometry.viewToCanvas(.init(x: 301, y: 100)) == nil)
    }

    @Test func zoomPanResizingAndBackingScaleRoundTrip() throws {
        let size = try ArtifactPixelSize(width: 601, height: 347)
        let points = try [MaskPoint(x: 0, y: 0), .init(x: 601, y: 347), .init(x: 123.456, y: 234.567)]
        for viewport in [(800.0, 600.0), (401.0, 900.0)] {
            for zoom in [1.0, 2.0, 3.0] {
                let geometry = try CanvasGeometry(canvasSize: size, viewportWidth: viewport.0, viewportHeight: viewport.1, zoom: zoom, panX: 17, panY: -23)
                for point in points {
                    let view = try geometry.canvasToView(point)
                    for backingScale in [1.0, 2.0, 3.0] {
                        // AppKit/SwiftUI events return logical points. Converting
                        // simulated backing pixels back to points is identical.
                        let logical = try MaskPoint(x: view.x * backingScale / backingScale, y: view.y * backingScale / backingScale)
                        let roundTrip = try #require(geometry.viewToCanvas(logical))
                        #expect(abs(roundTrip.x - point.x) < 1e-8)
                        #expect(abs(roundTrip.y - point.y) < 1e-8)
                    }
                }
            }
        }
    }

    @Test func invalidGeometryAndOrientationCoordinatesReject() throws {
        let size = try ArtifactPixelSize(width: 3, height: 2)
        #expect(throws: ArtifactContractError.self) { _ = try CanvasGeometry(canvasSize: size, viewportWidth: 0, viewportHeight: 10) }
        #expect(throws: ArtifactContractError.self) { _ = try CanvasGeometry(canvasSize: size, viewportWidth: .leastNonzeroMagnitude, viewportHeight: 10) }
        #expect(throws: ArtifactContractError.self) { _ = try CanvasGeometry(canvasSize: size, viewportWidth: 10, viewportHeight: 10, zoom: .nan) }
        #expect(throws: ArtifactContractError.self) { _ = try MaskImageOrientation.right.orientedPoint(.init(x: 4, y: 1), rawSize: size) }
        #expect(throws: ArtifactContractError.self) { _ = try MaskImageOrientation.right.rawPoint(.init(x: 3, y: 1), rawSize: size) }
    }

    @Test func actualSizeSupportsSinglePixelCanvasAtRetinaScales() throws {
        let size = try ArtifactPixelSize(width: 1, height: 1)
        let fit = try CanvasGeometry(canvasSize: size, viewportWidth: 1_000_000, viewportHeight: 1_000_000)
        for backingScale in [1.0, 2.0, 3.0] {
            let actual = try CanvasGeometry(canvasSize: size, viewportWidth: fit.viewportWidth,
                viewportHeight: fit.viewportHeight, zoom: 1 / backingScale / fit.scale)
            #expect(abs(actual.scale * backingScale - 1) < 1e-12)
            let center = try MaskPoint(x: 0.5, y: 0.5)
            let roundTrip = try #require(actual.viewToCanvas(actual.canvasToView(center)))
            #expect(abs(roundTrip.x - center.x) <= 1e-6)
            #expect(abs(roundTrip.y - center.y) <= 1e-6)
        }
    }
}
