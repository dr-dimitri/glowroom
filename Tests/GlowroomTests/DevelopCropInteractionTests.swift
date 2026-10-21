import CoreGraphics
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Crop pointer geometry")
struct DevelopCropInteractionTests {
    private let source = CGSize(width: 6000, height: 4000)

    @Test func allEightHandlesUseCornersAndSideCenters() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.7)
        let image = CGRect(x: 30, y: 50, width: 600, height: 400)
        let box = DevelopCropInteraction.box(crop: crop, imageRect: image)
        expect(box.minX, 150); expect(box.minY, 90); expect(box.width, 360); expect(box.height, 280)
        let positions: [DevelopCropHandle: CGPoint] = [
            .topLeft: CGPoint(x: 150, y: 90), .top: CGPoint(x: 330, y: 90), .topRight: CGPoint(x: 510, y: 90),
            .right: CGPoint(x: 510, y: 230), .bottomRight: CGPoint(x: 510, y: 370),
            .bottom: CGPoint(x: 330, y: 370), .bottomLeft: CGPoint(x: 150, y: 370), .left: CGPoint(x: 150, y: 230)
        ]
        for handle in DevelopCropHandle.allCases {
            let position = try #require(positions[handle])
            #expect(handle.position(in: box) == position)
            #expect(DevelopCropInteraction.handle(at: position, crop: crop, imageRect: image) == handle)
        }
    }

    @Test func forgivingHitRadiusRemainsFourteenViewPointsAtEveryZoom() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        for scale: CGFloat in [0.5, 1, 2, 4] {
            let image = CGRect(x: 40, y: 80, width: 600 * scale, height: 400 * scale)
            let box = DevelopCropInteraction.box(crop: crop, imageRect: image)
            for handle in DevelopCropHandle.allCases {
                let position = handle.position(in: box)
                #expect(DevelopCropInteraction.handle(at: CGPoint(x: position.x + 10, y: position.y + 9), crop: crop, imageRect: image) == handle)
            }
            let top = DevelopCropHandle.top.position(in: box)
            #expect(DevelopCropInteraction.handle(at: CGPoint(x: top.x, y: top.y - 14), crop: crop, imageRect: image) == .top)
            #expect(DevelopCropInteraction.handle(at: CGPoint(x: top.x, y: top.y - 14.1), crop: crop, imageRect: image) == nil)
            #expect(DevelopCropInteraction.handle(at: CGPoint(x: box.midX, y: box.midY), crop: crop, imageRect: image) == nil)
        }
        let image = CGRect(x: 10, y: 20, width: 600, height: 400)
        #expect(DevelopCropInteraction.handle(at: CGPoint(x: 4, y: 14), crop: nil, imageRect: image) == .topLeft)
    }

    @Test func overlappingHitTargetsChooseClosestHandleAndResolveTiesConsistently() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.02, height: 0.02)
        let image = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(DevelopCropInteraction.handle(at: CGPoint(x: 209, y: 199), crop: crop, imageRect: image) == .top)
        #expect(DevelopCropInteraction.handle(at: CGPoint(x: 201, y: 199), crop: crop, imageRect: image) == .topLeft)
        #expect(DevelopCropInteraction.handle(at: CGPoint(x: 205, y: 200), crop: crop, imageRect: image) == .topLeft)
    }

    @Test func freeResizeMovesOnlyTheSelectedEdgesAndPreservesTheirOpposites() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let delta = CGSize(width: 0.05, height: 0.07)
        let expected: [DevelopCropHandle: [Double]] = [
            .topLeft: [0.25, 0.37, 0.45, 0.33], .top: [0.2, 0.37, 0.5, 0.33],
            .topRight: [0.2, 0.37, 0.55, 0.33], .right: [0.2, 0.3, 0.55, 0.4],
            .bottomRight: [0.2, 0.3, 0.55, 0.47], .bottom: [0.2, 0.3, 0.5, 0.47],
            .bottomLeft: [0.25, 0.3, 0.45, 0.47], .left: [0.25, 0.3, 0.45, 0.4]
        ]
        for handle in DevelopCropHandle.allCases {
            let result = try #require(DevelopCropInteraction.resized(crop: crop, handle: handle, translation: delta, sourceSize: source, aspectRatio: nil))
            let values = try #require(expected[handle])
            expect(result.x, values[0]); expect(result.y, values[1]); expect(result.width, values[2]); expect(result.height, values[3])
            #expect(DevelopCropInteraction.resized(crop: crop, handle: handle, translation: .zero, sourceSize: source, aspectRatio: nil) == crop)
        }
    }

    @Test func freeResizeClampsToSourceAndCannotCrossOrCollapseAnOppositeEdge() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        for handle in DevelopCropHandle.allCases {
            for delta in [CGSize(width: -10, height: -10), CGSize(width: 10, height: 10)] {
                let result = try #require(DevelopCropInteraction.resized(crop: crop, handle: handle, translation: delta, sourceSize: source, aspectRatio: nil))
                expectValid(result)
            }
        }
        let left = try #require(DevelopCropInteraction.resized(crop: crop, handle: .left, translation: CGSize(width: 10, height: 0), sourceSize: source, aspectRatio: nil))
        expect(left.width, 0.005); expect(left.x + left.width, 0.7)
        let full = try #require(DevelopCropInteraction.resized(crop: nil, handle: .bottomRight, translation: CGSize(width: -0.1, height: -0.2), sourceSize: source, aspectRatio: nil))
        expect(full.x, 0); expect(full.y, 0); expect(full.width, 0.9); expect(full.height, 0.8)
    }

    @Test func tolerantHitUsesTranslationWithoutJumpingToThePointer() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let image = CGRect(x: 0, y: 0, width: 600, height: 400)
        let grab = CGPoint(x: 128, y: 86)
        let handle = try #require(DevelopCropInteraction.handle(at: grab, crop: crop, imageRect: image))
        #expect(handle == .topLeft)
        #expect(DevelopCropInteraction.resized(crop: crop, handle: handle, translation: .zero, sourceSize: source, aspectRatio: nil) == crop)
        let result = try #require(DevelopCropInteraction.resized(crop: crop, handle: handle, translation: CGSize(width: 6 / 600.0, height: 4 / 400.0), sourceSize: source, aspectRatio: nil))
        expect(result.x, 0.21); expect(result.y, 0.21)
    }

    @Test func constrainedCornersKeepOppositeCornerAndPixelAspectAtBoundsAndMinimum() throws {
        // A normalized square is 3:2 in this 6000x4000 source.
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        for handle in [DevelopCropHandle.topLeft, .topRight, .bottomRight, .bottomLeft] {
            let oldBox = DevelopCropInteraction.box(crop: crop, imageRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            let opposite: DevelopCropHandle = switch handle {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomRight: .topLeft
            default: .topRight
            }
            for delta in [CGSize(width: -10, height: -10), CGSize(width: 10, height: 10), CGSize(width: 0.1, height: 0)] {
                let result = try #require(DevelopCropInteraction.resized(crop: crop, handle: handle, translation: delta, sourceSize: source, aspectRatio: 1.5))
                expectValid(result); expectPixelRatio(result, 1.5)
                let newBox = DevelopCropInteraction.box(crop: result, imageRect: CGRect(x: 0, y: 0, width: 1, height: 1))
                expect(opposite.position(in: newBox).x, opposite.position(in: oldBox).x)
                expect(opposite.position(in: newBox).y, opposite.position(in: oldBox).y)
            }
        }
        let shrinking = try #require(DevelopCropInteraction.resized(crop: crop, handle: .bottomRight, translation: CGSize(width: -0.1, height: 0), sourceSize: source, aspectRatio: 1.5))
        expect(shrinking.width, 0.4); expect(shrinking.height, 0.4)
    }

    @Test func constrainedSideHandlesKeepOppositeEdgeAndPerpendicularCenter() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3)
        for handle in [DevelopCropHandle.top, .right, .bottom, .left] {
            for delta in [CGSize(width: -10, height: -10), CGSize(width: 10, height: 10), CGSize(width: 0.05, height: 0.05)] {
                let result = try #require(DevelopCropInteraction.resized(crop: crop, handle: handle, translation: delta, sourceSize: source, aspectRatio: 2))
                expectValid(result); expectPixelRatio(result, 2)
                if handle == .left || handle == .right {
                    expect(result.y + result.height / 2, crop.y + crop.height / 2)
                    expect(handle == .left ? result.x + result.width : result.x,
                           handle == .left ? crop.x + crop.width : crop.x)
                } else {
                    expect(result.x + result.width / 2, crop.x + crop.width / 2)
                    expect(handle == .top ? result.y + result.height : result.y,
                           handle == .top ? crop.y + crop.height : crop.y)
                }
            }
        }
    }

    @Test func newSelectionsWorkInEveryDirectionAndPreserveRatioAtImageEdges() throws {
        let start = CGPoint(x: 0.3, y: 0.4)
        for end in [CGPoint(x: -1, y: -1), CGPoint(x: 2, y: -1), CGPoint(x: 2, y: 2), CGPoint(x: -1, y: 2)] {
            let free = try #require(DevelopCropInteraction.created(from: start, to: end, sourceSize: source, aspectRatio: nil))
            expectValid(free)
            let constrained = try #require(DevelopCropInteraction.created(from: start, to: end, sourceSize: source, aspectRatio: 16 / 9.0))
            expectValid(constrained); expectPixelRatio(constrained, 16 / 9.0)
            expect(end.x < start.x ? constrained.x + constrained.width : constrained.x, Double(start.x))
            expect(end.y < start.y ? constrained.y + constrained.height : constrained.y, Double(start.y))
        }
        #expect(DevelopCropInteraction.created(from: start, to: CGPoint(x: 0.301, y: 0.401), sourceSize: source, aspectRatio: nil) == nil)
        #expect(DevelopCropInteraction.created(from: start, to: start, sourceSize: source, aspectRatio: 1) == nil)
    }

    @Test func invalidInputsDoNotProduceInvalidCrops() throws {
        let crop = try DevelopCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        #expect(DevelopCropInteraction.resized(crop: crop, handle: .right, translation: CGSize(width: CGFloat.infinity, height: 0), sourceSize: source, aspectRatio: nil) == crop)
        #expect(DevelopCropInteraction.resized(crop: crop, handle: .right, translation: CGSize(width: 0.1, height: 0), sourceSize: source, aspectRatio: -1) == crop)
        #expect(DevelopCropInteraction.created(from: .zero, to: CGPoint(x: 0.5, y: 0.5), sourceSize: .zero, aspectRatio: 1) == nil)
        #expect(DevelopCropInteraction.handle(at: .zero, crop: nil, imageRect: .zero) == nil)
    }

    private func expect(_ actual: Double, _ expected: Double) { #expect(abs(actual - expected) < 0.000_000_001) }
    private func expect(_ actual: CGFloat, _ expected: CGFloat) { #expect(abs(actual - expected) < 0.000_000_001) }
    private func expectPixelRatio(_ crop: DevelopCropRect, _ ratio: Double) {
        expect(crop.width * Double(source.width) / (crop.height * Double(source.height)), ratio)
    }
    private func expectValid(_ crop: DevelopCropRect) {
        #expect(crop.x >= 0 && crop.y >= 0 && crop.x + crop.width <= 1.000_000_001 && crop.y + crop.height <= 1.000_000_001)
        #expect(crop.width >= 0.004_999_999 && crop.height >= 0.004_999_999)
    }
}
