import Testing
@testable import Glowroom

@Suite("Native LaMa evaluation geometry")
struct LaMaEvaluationMappingTests {
    @Test func asymmetricOddCanvasKeepsTopLeftRowsAndClampsOnlyContext() throws {
        let mapping = try LaMaEvaluationMapping(width: 3, height: 5)
        #expect(mapping.offsetX == 398 && mapping.offsetY == 397)
        let golden: [(Int, Int, LaMaEvaluationMapping.Sample)] = [
            (398, 397, .init(sourceX: 0, sourceY: 0, isInside: true)),
            (400, 397, .init(sourceX: 2, sourceY: 0, isInside: true)),
            (398, 401, .init(sourceX: 0, sourceY: 4, isInside: true)),
            (400, 401, .init(sourceX: 2, sourceY: 4, isInside: true)),
            (399, 399, .init(sourceX: 1, sourceY: 2, isInside: true)),
            (397, 399, .init(sourceX: 0, sourceY: 2, isInside: false)),
            (401, 399, .init(sourceX: 2, sourceY: 2, isInside: false)),
            (399, 396, .init(sourceX: 1, sourceY: 0, isInside: false)),
            (399, 402, .init(sourceX: 1, sourceY: 4, isInside: false)),
            (0, 0, .init(sourceX: 0, sourceY: 0, isInside: false)),
            (799, 799, .init(sourceX: 2, sourceY: 4, isInside: false))
        ]
        for (x, y, expected) in golden {
            #expect(mapping.sample(modelX: x, modelY: y) == expected)
        }
        #expect(mapping.modelPoint(sourceX: 0, sourceY: 4) == .init(x: 398, y: 401))
        #expect(mapping.modelPoint(sourceX: 2, sourceY: 0) == .init(x: 400, y: 397))
    }

    @Test func spareOddPixelsBelongToRightAndBottomPadding() throws {
        let one = try LaMaEvaluationMapping(width: 1, height: 1)
        #expect(one.modelPoint(sourceX: 0, sourceY: 0) == .init(x: 399, y: 399))
        #expect(one.sample(modelX: 399, modelY: 399)?.isInside == true)
        #expect(one.sample(modelX: 400, modelY: 399)?.isInside == false)
        #expect(one.sample(modelX: 399, modelY: 400)?.isInside == false)
        let wide = try LaMaEvaluationMapping(width: 799, height: 3)
        #expect(wide.modelPoint(sourceX: 0, sourceY: 0) == .init(x: 0, y: 398))
        #expect(wide.modelPoint(sourceX: 798, sourceY: 2) == .init(x: 798, y: 400))
        #expect(wide.sample(modelX: 798, modelY: 399)?.isInside == true)
        #expect(wide.sample(modelX: 799, modelY: 399) == .init(sourceX: 798, sourceY: 1, isInside: false))
        let native = try LaMaEvaluationMapping(width: 640, height: 384)
        #expect(native.modelPoint(sourceX: 0, sourceY: 0) == .init(x: 80, y: 208))
        #expect(native.modelPoint(sourceX: 639, sourceY: 383) == .init(x: 719, y: 591))
    }

    @Test(arguments: [(1, 1), (799, 3), (640, 384), (800, 800)])
    func paddingAndCroppingPreserveAnAsymmetricCoordinateGrid(size: (Int, Int)) throws {
        let (width, height) = size
        let mapping = try LaMaEvaluationMapping(width: width, height: height)
        // Each pixel carries a unique row/column label, so swaps, flips and
        // duplicate edges are visible without involving a model or color codec.
        let original = (0..<height).flatMap { y in
            (0..<width).map { x in UInt32((y + 1) * 1_000 + x + 1) }
        }
        var canvas = [UInt32](repeating: 0, count: 800 * 800)
        var replaceablePixels = 0
        // This preparation is deliberately serial: these small independent
        // arrays test coordinates and starting worker pools would dominate it.
        for y in 0..<800 { for x in 0..<800 {
            guard let sample = mapping.sample(modelX: x, modelY: y) else {
                Issue.record("A valid model pixel has no source sample")
                return
            }
            canvas[y * 800 + x] = original[sample.sourceY * width + sample.sourceX]
            if sample.isInside { replaceablePixels += 1 }
        } }
        #expect(replaceablePixels == original.count, "The native crop contains each source pixel exactly once")
        #expect(canvas.first == original.first && canvas.last == original.last)
        var cropped: [UInt32] = []
        cropped.reserveCapacity(original.count)
        for y in 0..<height { for x in 0..<width {
            guard let point = mapping.modelPoint(sourceX: x, sourceY: y) else {
                Issue.record("A valid source pixel has no model point")
                return
            }
            cropped.append(canvas[point.y * 800 + point.x])
        } }
        #expect(cropped == original)
    }

    @Test func invalidDimensionsAndOutOfRangePointsNeverOverflowOrClampIntoTheCanvas() throws {
        for (width, height) in [(0, 1), (1, 0), (-1, 3), (3, -1), (801, 1), (1, 801),
                                (Int.max, 1), (1, Int.max), (Int.min, 1), (1, Int.min)] {
            #expect(throws: LaMaEvaluationMapping.Failure.invalidDimensions) {
                _ = try LaMaEvaluationMapping(width: width, height: height)
            }
        }
        let mapping = try LaMaEvaluationMapping(width: 3, height: 5)
        for invalid in [-1, 800, Int.min, Int.max] {
            #expect(mapping.sample(modelX: invalid, modelY: 0) == nil)
            #expect(mapping.sample(modelX: 0, modelY: invalid) == nil)
        }
        for invalid in [-1, 3, Int.min, Int.max] {
            #expect(mapping.modelPoint(sourceX: invalid, sourceY: 0) == nil)
        }
        for invalid in [-1, 5, Int.min, Int.max] {
            #expect(mapping.modelPoint(sourceX: 0, sourceY: invalid) == nil)
        }
    }
}
