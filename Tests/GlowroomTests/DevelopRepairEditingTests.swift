import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

struct DevelopRepairEditingTests {
    private let rect = CGRect(x: 10, y: 20, width: 200, height: 100)

    @Test func pinsTakePrecedenceOverNewerBodiesAndNewestPinsWin() throws {
        let first = try stroke(target: point(0.3, 0.4))
        let covering = try stroke(target: point(0.5, 0.4), radius: 0.5)
        let hit = DevelopRepairEditing.hit(at: CGPoint(x: 70, y: 60), strokes: [first, covering], imageRect: rect, handleRadius: 6)
        #expect(hit?.id == first.id && hit?.handle == .target)
        let newest = try stroke(target: first.target)
        #expect(DevelopRepairEditing.hit(at: CGPoint(x: 70, y: 60), strokes: [first, newest], imageRect: rect, handleRadius: 6)?.id == newest.id)
    }

    @Test func pathSegmentsAndFrozenMasksCanBeHitAwayFromTheirPins() throws {
        let path = try stroke(target: point(0.2, 0.5), path: [point(0.8, 0.5)])
        #expect(DevelopRepairEditing.hit(at: CGPoint(x: 110, y: 70), strokes: [path], imageRect: rect, handleRadius: 4)?.id == path.id)
        var bytes = Data(repeating: 0, count: 16); bytes[10] = 255
        let mask = try LocalMaskRaster(width: 4, height: 4, bytes: bytes)
        let masked = try stroke(target: point(0.1, 0.1), mask: mask)
        #expect(DevelopRepairEditing.hit(at: CGPoint(x: 135, y: 82.5), strokes: [path, masked], imageRect: rect, handleRadius: 4)?.id == masked.id)
        #expect(DevelopRepairEditing.hit(at: CGPoint(x: 90, y: 70), strokes: [masked], imageRect: rect, handleRadius: 4) == nil)
        #expect(DevelopRepairEditing.hit(at: CGPoint(x: -1, y: 70), strokes: [path], imageRect: rect, handleRadius: 4) == nil)
    }

    @Test func sourceMovesIndependentlyAndClampsAtImageEdges() throws {
        let original = try stroke(target: point(0.5, 0.5), path: [point(0.6, 0.5)])
        let moved = try DevelopRepairEditing.moved(original, handle: .source, translation: CGSize(width: 2, height: -2))
        #expect(moved.source == (try point(1, 0)))
        #expect(moved.target == original.target && moved.path == original.path && moved.id == original.id)
        #expect(moved.mode == original.mode && moved.radius == original.radius && moved.feather == original.feather && moved.opacity == original.opacity)
    }

    @Test func targetMovesWholePathFromImmutableStartAndKeepsDonorFixed() throws {
        let original = try stroke(target: point(0.25, 0.25), path: [point(0.5, 0.75)])
        let bounds = DevelopRepairEditing.translationBounds(for: original, handle: .target)
        #expect(bounds == CGRect(x: -0.25, y: -0.25, width: 0.75, height: 0.5))
        let moved = try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: 1, height: 1))
        #expect(moved.target == (try point(0.75, 0.5)))
        #expect(moved.path == [try point(1, 1)])
        #expect(moved.source == original.source && moved.id == original.id)
        _ = try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: 0.1, height: 0.1))
        #expect(try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: 1, height: 1)) == moved)
    }

    @Test func frozenMaskAndReplacementMoveTogetherWithoutChangingModelPixels() throws {
        var bytes = Data(repeating: 0, count: 16); bytes[5] = 255
        let mask = try LocalMaskRaster(width: 4, height: 4, bytes: bytes)
        let replacement = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            width: 1, height: 1, rgba: Data([12, 34, 56, 78]))
        let original = try stroke(target: point(0.375, 0.375), mask: mask, replacement: replacement)
        let moved = try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: 0.25, height: -0.25))
        var expected = Data(repeating: 0, count: 16); expected[2] = 255
        #expect(moved.mask?.bytes == expected)
        #expect(moved.replacement?.bounds == replacement.bounds)
        #expect(moved.replacement?.offsetX == 0.25 && moved.replacement?.offsetY == -0.25)
        #expect(moved.replacement?.rgba == replacement.rgba)
        #expect(moved.replacement?.width == replacement.width && moved.replacement?.height == replacement.height)
        #expect(moved.target == (try point(0.625, 0.125)))
        #expect(moved.source == moved.target)
        #expect(try DevelopRepairEditing.moved(original, handle: .source, translation: CGSize(width: 0.1, height: 0.1)) == original)
    }

    @Test func fractionalMaskTranslationSnapsAllGeometryWithoutResamplingCoverage() throws {
        var bytes = Data(repeating: 0, count: 16); bytes[5] = 254
        let original = try stroke(target: point(0.375, 0.375), mask: LocalMaskRaster(width: 4, height: 4, bytes: bytes))
        let moved = try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: 0.125, height: 0))
        var expected = Data(repeating: 0, count: 16); expected[6] = 254
        #expect(moved.mask?.bytes == expected)
        #expect(moved.mask?.width == 4 && moved.mask?.height == 4)
        #expect(moved.target == (try point(0.625, 0.375)))
        #expect(DevelopRepairEditing.translation(for: original, handle: .target,
            requested: CGSize(width: 0.125, height: 0)) == CGSize(width: 0.25, height: 0))
        #expect(try DevelopRepairEditing.moved(original, handle: .target,
            translation: CGSize(width: 0.1, height: 0)) == original)
        var roundTrip = original
        for _ in 0..<10 {
            roundTrip = try DevelopRepairEditing.moved(roundTrip, handle: .target, translation: CGSize(width: 0.25, height: 0.25))
            roundTrip = try DevelopRepairEditing.moved(roundTrip, handle: .target, translation: CGSize(width: -0.25, height: -0.25))
        }
        #expect(roundTrip == original)
    }

    @Test(arguments: [1.0, -1.0])
    func fullFrameModelContextCanMoveWithSmallMaskWithoutCroppingPixels(direction: Double) throws {
        var bytes = Data(repeating: 0, count: 16); bytes[5] = 255
        let mask = try LocalMaskRaster(width: 4, height: 4, bytes: bytes)
        var pixels = Data()
        for row in 0..<4 { for column in 0..<4 {
            pixels.append(contentsOf: [UInt8(row * 40 + column * 10), 34, 56, UInt8(50 + row * 40 + column * 10)])
        } }
        let replacement = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0, y: 0, width: 1, height: 1),
            width: 4, height: 4, rgba: pixels)
        let original = try stroke(target: point(0.375, 0.375), mask: mask, replacement: replacement)
        let delta = 0.25 * direction
        let moved = try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: delta, height: delta))
        let patch = try #require(moved.replacement)
        #expect(patch.bounds == replacement.bounds)
        #expect(patch.offsetX == delta && patch.offsetY == delta)
        #expect(patch.width == 4 && patch.height == 4)
        #expect(patch.rgba == pixels)
        var expectedMask = Data(repeating: 0, count: 16)
        expectedMask[direction > 0 ? 10 : 0] = 255
        #expect(moved.mask?.bytes == expectedMask)
        #expect(moved.target == (try point(0.375 + delta, 0.375 + delta)))
        // The selected pixel keeps its sampling location relative to the ROI,
        // including straight alpha, even when most context is off-image.
        let originalX = (original.target.x - replacement.bounds.x) / replacement.bounds.width
        let movedX = (moved.target.x - patch.bounds.x - patch.offsetX) / patch.bounds.width
        let originalY = (original.target.y - replacement.bounds.y) / replacement.bounds.height
        let movedY = (moved.target.y - patch.bounds.y - patch.offsetY) / patch.bounds.height
        #expect(movedX == originalX && movedY == originalY)
    }

    @Test(arguments: [1, 3, 4, 7])
    func movingDifferentModelGridsBackAndForthKeepsEveryColorAndAlphaByte(dimension: Int) throws {
        var bytes = Data(repeating: 0, count: 16); bytes[5] = 255
        let mask = try LocalMaskRaster(width: 4, height: 4, bytes: bytes)
        let pixels = Data((0..<(dimension * dimension * 4)).map { UInt8(($0 * 43) % 256) })
        let replacement = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0, y: 0, width: 1, height: 1),
            width: dimension, height: dimension, rgba: pixels)
        let original = try stroke(target: point(0.375, 0.375), mask: mask, replacement: replacement)
        var moved = original
        for _ in 0..<10 {
            moved = try DevelopRepairEditing.moved(moved, handle: .target, translation: CGSize(width: 0.5, height: -0.25))
            #expect(moved.replacement?.rgba == pixels)
            #expect(moved.replacement?.bounds == replacement.bounds)
            #expect(moved.replacement?.offsetX == 0.5 && moved.replacement?.offsetY == -0.25)
            moved = try DevelopRepairEditing.moved(moved, handle: .target, translation: CGSize(width: -0.5, height: 0.25))
            #expect(moved == original)
        }
    }

    @Test func existingReplacementOffsetsAccumulateAndUnmaskedBoundsUseTheirEffectivePosition() throws {
        let replacement = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            width: 1, height: 1, rgba: Data([12, 34, 56, 78]), offsetX: -0.25, offsetY: 0.25)
        let original = try stroke(target: point(0.25, 0.75), replacement: replacement)
        #expect(DevelopRepairEditing.translationBounds(for: original, handle: .target)
            == CGRect(x: 0, y: -0.5, width: 0.5, height: 0.5))
        let moved = try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: -1, height: -0.25))
        let patch = try #require(moved.replacement)
        #expect(patch.bounds == replacement.bounds && patch.rgba == replacement.rgba)
        #expect(patch.offsetX == -0.25 && patch.offsetY == 0)
        #expect(moved.target == (try point(0.25, 0.5)))
    }

    @Test func maskAtImageEdgesAndFullCanvasReplacementDoNotLoseCoverage() throws {
        let mask = try LocalMaskRaster(width: 2, height: 2, bytes: Data([255, 0, 0, 255]))
        let original = try stroke(target: point(0.5, 0.5), mask: mask)
        #expect(DevelopRepairEditing.translationBounds(for: original, handle: .target) == .zero)
        #expect(try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: 1, height: 1)) == original)
        let replacement = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0, y: 0, width: 1, height: 1),
            width: 1, height: 1, rgba: Data([0, 0, 0, 255]))
        let full = try stroke(target: point(0.5, 0.5), replacement: replacement)
        #expect(try DevelopRepairEditing.moved(full, handle: .target, translation: CGSize(width: -1, height: -1)) == full)
    }

    @Test func modelReplacementHasNoSourceHandleAndItsUnmaskedContextDoesNotCaptureBrushInput() throws {
        let replacement = try DevelopRetouchReplacement(bounds: DevelopCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            width: 1, height: 1, rgba: Data([0, 0, 0, 255]))
        let original = try DevelopRetouchStroke(source: point(0.1, 0.1), target: point(0.5, 0.5), radius: 0.01,
                                                replacement: replacement)
        #expect(DevelopRepairEditing.hit(at: CGPoint(x: 30, y: 30), strokes: [original], imageRect: rect, handleRadius: 4) == nil)
        #expect(DevelopRepairEditing.hit(at: CGPoint(x: 70, y: 50), strokes: [original], imageRect: rect, handleRadius: 4) == nil)
    }

    @Test func invalidTranslationIsRejected() throws {
        let original = try stroke(target: point(0.5, 0.5))
        #expect(throws: ArtifactContractError.self) {
            try DevelopRepairEditing.moved(original, handle: .target, translation: CGSize(width: CGFloat.nan, height: 0))
        }
        #expect(DevelopRepairEditing.hit(at: .zero, strokes: [original], imageRect: .zero, handleRadius: 4) == nil)
    }

    private func point(_ x: Double, _ y: Double) throws -> LocalMaskPoint { try LocalMaskPoint(x: x, y: y) }
    private func stroke(target: LocalMaskPoint, radius: Double = 0.05, path: [LocalMaskPoint] = [],
                        mask: LocalMaskRaster? = nil, replacement: DevelopRetouchReplacement? = nil) throws -> DevelopRetouchStroke {
        try DevelopRetouchStroke(mode: .heal, source: replacement == nil ? point(0.1, 0.1) : target,
            target: target, radius: radius, feather: 0.3, opacity: 0.8, path: path, mask: mask, replacement: replacement)
    }
}
