import Foundation
import Testing
@testable import Glowroom

@Suite("Movable mask palette geometry")
struct InlineMaskPaletteLayoutTests {
    @Test func paletteStartsAtTheUpperRightAndDraggingKeepsEveryEdgeReachable() {
        let layout = InlineMaskPaletteLayout(viewport: CGSize(width: 900, height: 600))
        let palette = layout.size(layerCount: 16)
        let initial = layout.defaultOrigin(paletteSize: palette)
        #expect(initial == CGPoint(x: 640, y: 10))
        #expect(layout.translatedOrigin(initial, by: CGSize(width: -10_000, height: -10_000), paletteSize: palette)
            == CGPoint(x: 10, y: 10))
        let oppositeCorner = layout.translatedOrigin(initial, by: CGSize(width: 10_000, height: 10_000), paletteSize: palette)
        #expect(oppositeCorner.x + palette.width == 890)
        #expect(oppositeCorner.y + palette.height == 590)
        let moved = layout.translatedOrigin(initial, by: CGSize(width: -175, height: 85), paletteSize: palette)
        #expect(moved == CGPoint(x: 465, y: 95), "Translation is measured in the fixed viewport, independent of the palette's moving origin")
    }

    @Test func paletteGrowthAndViewportResizeClampTheExistingUserPosition() {
        let large = InlineMaskPaletteLayout(viewport: CGSize(width: 900, height: 600))
        let userPosition = CGPoint(x: 500, y: 490)
        let grown = large.size(layerCount: 16)
        let adjusted = large.clamp(userPosition, paletteSize: grown)
        #expect(adjusted.x == userPosition.x)
        #expect(adjusted.y + grown.height == 590)

        let small = InlineMaskPaletteLayout(viewport: CGSize(width: 220, height: 140))
        let compact = small.size(layerCount: 16)
        #expect(compact == CGSize(width: 200, height: 120))
        #expect(small.listHeight(layerCount: 16) >= 28, "At least one full mask row remains available with scrolling")
        let resized = small.clamp(adjusted, paletteSize: compact)
        #expect(resized == CGPoint(x: 10, y: 10))
        #expect(CGRect(origin: .zero, size: small.viewport).contains(CGRect(origin: resized, size: compact)))
    }
}
