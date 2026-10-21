import CoreGraphics
import Foundation
import Testing
@testable import Glowroom

@Suite("Crop canvas rotation and level geometry")
struct DevelopCropCanvasPresentationTests {
    @Test func originalImageRectKeepsSourceAspectAndCentersLetterboxing() {
        let source = CGSize(width: 6000, height: 4000)
        let rect = DevelopCropCanvasPresentation.imageRect(sourceSize: source, viewport: CGSize(width: 800, height: 800))
        expect(rect.width, 800); expect(rect.height, 1600 / 3)
        expect(rect.midX, 400); expect(rect.midY, 400)
        expect(DevelopCropCanvasPresentation.fittingScale(sourceSize: source, viewport: CGSize(width: 800, height: 800), angle: 0), 1)
    }

    @Test func rotatedSourceCornersFitWideTallAndSquareViewports() {
        for source in [CGSize(width: 6000, height: 4000), CGSize(width: 4000, height: 6000), CGSize(width: 16000, height: 400)] {
            for viewport in [CGSize(width: 900, height: 500), CGSize(width: 500, height: 900), CGSize(width: 700, height: 700)] {
                let rect = DevelopCropCanvasPresentation.imageRect(sourceSize: source, viewport: viewport)
                for angle in [-45.0, -44.9, -20, 0, 20, 44.9, 45] {
                    let scale = DevelopCropCanvasPresentation.fittingScale(sourceSize: source, viewport: viewport, angle: angle)
                    #expect(scale > 0 && scale <= 1)
                    for point in corners(rect) {
                        let displayed = transformed(point, viewport: viewport, angle: angle, scale: scale)
                        #expect(displayed.x >= -1e-9 && displayed.x <= viewport.width + 1e-9)
                        #expect(displayed.y >= -1e-9 && displayed.y <= viewport.height + 1e-9)
                    }
                    expect(scale, DevelopCropCanvasPresentation.fittingScale(sourceSize: source, viewport: viewport, angle: -angle))
                }
            }
        }
    }

    @Test func nativeViewportPointsMapBackToTheSameSourcePositionsAfterRotation() throws {
        let viewport = CGSize(width: 900, height: 500)
        let source = CGSize(width: 4000, height: 6000)
        let rect = DevelopCropCanvasPresentation.imageRect(sourceSize: source, viewport: viewport)
        for angle in [-45.0, -17, 0, 17, 45] {
            let scale = DevelopCropCanvasPresentation.fittingScale(sourceSize: source, viewport: viewport, angle: angle)
            for point in corners(rect) + [CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.7)] {
                let displayed = transformed(point, viewport: viewport, angle: angle, scale: scale)
                let restored = try #require(DevelopCropCanvasPresentation.canvasPoint(from: displayed, viewport: viewport, angle: angle, scale: scale))
                expect(restored.x, point.x); expect(restored.y, point.y)
            }
        }
    }

    @Test func levelLineCorrectsHorizontalAndVerticalFeaturesInSourcePixels() throws {
        let source = CGSize(width: 6000, height: 4000)
        let pairs = [
            (CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.4)),
            (CGPoint(x: 0.1, y: 0.4), CGPoint(x: 0.9, y: 0.2)),
            (CGPoint(x: 0.4, y: 0.1), CGPoint(x: 0.5, y: 0.9)),
            (CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.4, y: 0.9))
        ]
        for (start, end) in pairs {
            let angle = try #require(DevelopCropCanvasPresentation.straighteningAngle(from: start, to: end, sourceSize: source))
            #expect((-45...45).contains(angle))
            let reversed = try #require(DevelopCropCanvasPresentation.straighteningAngle(from: end, to: start, sourceSize: source))
            expect(angle, reversed)
            let x = (end.x - start.x) * source.width, y = (end.y - start.y) * source.height
            let radians = angle * .pi / 180
            let rotatedX = x * cos(radians) - y * sin(radians)
            let rotatedY = x * sin(radians) + y * cos(radians)
            #expect(min(abs(rotatedX), abs(rotatedY)) < 1e-9)
        }
        let angle = try #require(DevelopCropCanvasPresentation.straighteningAngle(from: pairs[0].0, to: pairs[0].1, sourceSize: source))
        expect(angle, -atan2(800, 4800) * 180 / .pi)
    }

    @Test func levelLinesOnEitherAxisNeedNoRotationAndDiagonalTiesAreStable() throws {
        let source = CGSize(width: 6000, height: 4000)
        for (start, end) in [(CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)),
                             (CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.9))] {
            #expect(DevelopCropCanvasPresentation.straighteningAngle(from: start, to: end, sourceSize: source) == 0)
            #expect(DevelopCropCanvasPresentation.straighteningAngle(from: end, to: start, sourceSize: source) == 0)
        }
        let diagonal = CGPoint(x: 0.5, y: 0.75)
        let forward = try #require(DevelopCropCanvasPresentation.straighteningAngle(from: .zero, to: diagonal, sourceSize: source))
        let reversed = try #require(DevelopCropCanvasPresentation.straighteningAngle(from: diagonal, to: .zero, sourceSize: source))
        expect(forward, -45); expect(reversed, -45)
    }

    @Test func incompleteOrInvalidGeometryCannotPublishANaNAngleOrTransform() {
        let source = CGSize(width: 6000, height: 4000), viewport = CGSize(width: 900, height: 500)
        #expect(DevelopCropCanvasPresentation.straighteningAngle(from: .zero, to: .zero, sourceSize: source) == nil)
        #expect(DevelopCropCanvasPresentation.straighteningAngle(from: .zero, to: CGPoint(x: CGFloat.nan, y: 1), sourceSize: source) == nil)
        #expect(DevelopCropCanvasPresentation.straighteningAngle(from: .zero, to: CGPoint(x: 2, y: 1), sourceSize: source) == nil)
        #expect(DevelopCropCanvasPresentation.straighteningAngle(from: .zero, to: CGPoint(x: 1, y: 1), sourceSize: .zero) == nil)
        #expect(DevelopCropCanvasPresentation.imageRect(sourceSize: .zero, viewport: viewport) == .zero)
        #expect(DevelopCropCanvasPresentation.imageRect(sourceSize: source, viewport: CGSize(width: CGFloat.infinity, height: 500)) == .zero)
        #expect(DevelopCropCanvasPresentation.fittingScale(sourceSize: source, viewport: viewport, angle: .nan) == 1)
        #expect(DevelopCropCanvasPresentation.canvasPoint(from: .zero, viewport: viewport, angle: 10, scale: 0) == nil)
        #expect(DevelopCropCanvasPresentation.canvasPoint(from: CGPoint(x: CGFloat.nan, y: 0), viewport: viewport, angle: 10, scale: 1) == nil)
    }

    private func transformed(_ point: CGPoint, viewport: CGSize, angle: Double, scale: CGFloat) -> CGPoint {
        let x = point.x - viewport.width / 2, y = point.y - viewport.height / 2
        let radians = angle * .pi / 180
        return CGPoint(x: viewport.width / 2 + (x * cos(radians) - y * sin(radians)) * scale,
                       y: viewport.height / 2 + (x * sin(radians) + y * cos(radians)) * scale)
    }

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private func expect(_ actual: CGFloat, _ expected: CGFloat) { #expect(abs(actual - expected) < 1e-9) }
    private func expect(_ actual: Double, _ expected: Double) { #expect(abs(actual - expected) < 1e-9) }
}
