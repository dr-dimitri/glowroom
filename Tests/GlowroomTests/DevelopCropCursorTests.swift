import AppKit
import Testing
@testable import Glowroom

@Suite("Crop resize cursor orientation")
@MainActor
struct DevelopCropCursorTests {
    @Test func unrotatedHandlesKeepTheFourResizeAxes() {
        #expect(DevelopCropCursor.cursor(for: .right) === NSCursor.resizeLeftRight)
        #expect(DevelopCropCursor.cursor(for: .top) === NSCursor.resizeUpDown)
        #expect(DevelopCropCursor.cursor(for: .topLeft) !== DevelopCropCursor.cursor(for: .topRight))
        #expect(DevelopCropCursor.cursor(for: .topLeft) !== NSCursor.resizeUpDown)
        #expect(DevelopCropCursor.cursor(for: .topLeft) !== NSCursor.resizeLeftRight)
    }

    @Test func clockwiseAndCounterclockwiseRotationFollowTheVisibleHandleAxes() {
        #expect(DevelopCropCursor.cursor(for: .right, angle: 45) === DevelopCropCursor.cursor(for: .topLeft))
        #expect(DevelopCropCursor.cursor(for: .top, angle: 45) === DevelopCropCursor.cursor(for: .topRight))
        #expect(DevelopCropCursor.cursor(for: .topLeft, angle: 45) === NSCursor.resizeUpDown)
        #expect(DevelopCropCursor.cursor(for: .topRight, angle: 45) === NSCursor.resizeLeftRight)
        #expect(DevelopCropCursor.cursor(for: .right, angle: -45) === DevelopCropCursor.cursor(for: .topRight))
        #expect(DevelopCropCursor.cursor(for: .top, angle: -45) === DevelopCropCursor.cursor(for: .topLeft))
        #expect(DevelopCropCursor.cursor(for: .topLeft, angle: -45) === NSCursor.resizeLeftRight)
        #expect(DevelopCropCursor.cursor(for: .topRight, angle: -45) === NSCursor.resizeUpDown)
    }

    @Test func oppositeHandlesShareTheirAxisAndIntermediateAnglesChooseTheNearestShape() {
        let pairs: [(DevelopCropHandle, DevelopCropHandle)] = [
            (.top, .bottom), (.left, .right), (.topLeft, .bottomRight), (.topRight, .bottomLeft)
        ]
        for angle in [-45.0, -23, 0, 23, 45] {
            for (first, second) in pairs {
                #expect(DevelopCropCursor.cursor(for: first, angle: angle) === DevelopCropCursor.cursor(for: second, angle: angle))
            }
        }
        #expect(DevelopCropCursor.cursor(for: .right, angle: 22.49) === NSCursor.resizeLeftRight)
        #expect(DevelopCropCursor.cursor(for: .right, angle: 22.51) === DevelopCropCursor.cursor(for: .topLeft))
        #expect(DevelopCropCursor.cursor(for: .right, angle: -22.49) === NSCursor.resizeLeftRight)
        #expect(DevelopCropCursor.cursor(for: .right, angle: -22.51) === DevelopCropCursor.cursor(for: .topRight))
    }

    @Test func halfTurnsWrapAndInvalidAnglesFallBackWithoutOverflow() {
        for handle in DevelopCropHandle.allCases {
            for angle in [-540.0, -360, -180, 180, 360, 540] {
                #expect(DevelopCropCursor.cursor(for: handle, angle: angle) === DevelopCropCursor.cursor(for: handle))
                #expect(DevelopCropCursor.cursor(for: handle, angle: angle + 30) === DevelopCropCursor.cursor(for: handle, angle: 30))
            }
            for angle in [Double.nan, .infinity, -.infinity] {
                #expect(DevelopCropCursor.cursor(for: handle, angle: angle) === DevelopCropCursor.cursor(for: handle))
            }
            #expect(DevelopCropCursor.cursor(for: handle, angle: 1e308) === DevelopCropCursor.cursor(for: handle, angle: (1e308).truncatingRemainder(dividingBy: 180)))
        }
    }
}
