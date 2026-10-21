import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Bounded repair source and candidate analysis")
struct DevelopRepairAnalyzerTests {
    @Test func proxyKeepsAspectAndTopLeftCoordinatesWithin512Pixels() throws {
        let bitmap = try image(width: 800, height: 400) { x, y in [UInt8(x * 255 / 800), UInt8(y * 255 / 400), 0, 255] }
        let pixels = try DevelopRepairPixels(bitmap)
        #expect(pixels.width == 512)
        #expect(pixels.height == 256)
        #expect(pixels.rgba[1] < 4)
        #expect(pixels.rgba[((pixels.height - 1) * pixels.width) * 4 + 1] > 245)
        #expect(pixels.luma.allSatisfy { $0.isFinite })
    }

    @Test func sourceIsDeterministicAndNeverCopiesThePaintedPath() async throws {
        let bitmap = try image(width: 160, height: 100) { _, _ in [160, 170, 180, 255] }
        let analyzer = DevelopRepairAnalyzer()
        let path = try [point(0.35, 0.5), point(0.55, 0.5)]
        let a = try await analyzer.source(for: bitmap, path: path, radius: 0.04)
        let b = try await analyzer.source(for: bitmap, path: path, radius: 0.04)
        #expect(a == b)
        let dx = (a.x - path[0].x) * 160, dy = (a.y - path[0].y) * 100
        // Either vertical clearance or horizontal clearance separates capsules.
        #expect(abs(dy) >= 8 || abs(dx) >= 40)
        #expect(a.x >= 0 && a.x + 0.2 <= 1 && a.y >= 0 && a.y <= 1)
    }

    @Test func entireGlobalMaskIsExcludedFromAutomaticSource() async throws {
        let width = 100, height = 80
        var bytes = Data(count: width * height)
        for y in 20..<60 { for x in 30..<58 { bytes[y * width + x] = 255 } }
        let mask = try LocalMaskRaster(width: width, height: height, bytes: bytes)
        let bitmap = try image(width: width, height: height) { _, _ in [180, 180, 180, 255] }
        let first = try point(0.44, 0.5)
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: [first], radius: 0.01, mask: mask)
        let dx = Int(((source.x - first.x) * Double(width)).rounded())
        let dy = Int(((source.y - first.y) * Double(height)).rounded())
        for y in 20..<60 { for x in 30..<58 {
            #expect((0..<width).contains(x + dx) && (0..<height).contains(y + dy))
            #expect(bytes[(y + dy) * width + x + dx] == 0)
        } }
    }

    @Test func sourcePrefersMatchingCleanSurroundingsOverNearbyDarkDetail() async throws {
        let bitmap = try image(width: 160, height: 100) { x, y in
            let targetSpot = hypot(Double(x) - 64, Double(y) - 50) < 3
            let value: UInt8 = targetSpot ? 20 : x >= 80 ? 55 : 190
            return [value, value, value, 255]
        }
        let target = try point(0.4, 0.5)
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.04)
        #expect(source.x < 0.48)
        #expect(hypot((source.x - target.x) * 160, (source.y - target.y) * 100) > 7)
    }

    @Test func sourceRejectsRedReplacementWithTheSameLuminanceAsGreenSurroundings() async throws {
        let mask = try rectangularSelection()
        let bitmap = try image(width: 192, height: 96) { x, y in
            if (80..<112).contains(x) && (20..<76).contains(y) { return [200, 60, 50, 255] }
            // This complete competing donor has an exact green boundary but
            // repeats red pixels with almost the same luminance as the green.
            if (44..<76).contains(x) && (20..<76).contains(y) { return [200, 60, 50, 255] }
            if x >= 112 { return [43, 110, 43, 255] }
            return [40, 108, 40, 255]
        }
        let target = try point(0.5, 0.5)
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.04, mask: mask)
        #expect(source.x > target.x, "Choose clean green texture instead of copying another iso-luminant red object")
    }

    @Test func sourcePreservesNeedleTextureInsteadOfChoosingItsFlatAverageColor() async throws {
        let mask = try rectangularSelection()
        let bitmap = try image(width: 192, height: 96) { x, y in
            if (80..<112).contains(x) && (20..<76).contains(y) { return [160, 20, 20, 255] }
            // The left donor's boundary matches the stripes perfectly, but its
            // interior is flat. The right donor retains the surrounding detail.
            if (44..<76).contains(x) && (20..<76).contains(y) { return [80, 120, 60, 255] }
            return x % 4 < 2 ? [30, 70, 20, 255] : [130, 170, 100, 255]
        }
        let target = try point(0.5, 0.5)
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.04, mask: mask)
        #expect(source.x > target.x, "Removing an object from foliage must retain the surrounding texture")
    }

    @Test func localRefinementFindsNearbySourcesBetweenTheCoarseSearchDirections() async throws {
        let bitmap = try image(width: 160, height: 100) { _, _ in [160, 170, 180, 255] }
        let target = try point(0.5, 0.5)
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.04)
        let dx = (source.x - target.x) * 160, dy = (source.y - target.y) * 100
        #expect(hypot(dx, dy) < 8, "Refine the coarse candidates instead of needlessly copying more distant texture")
        // The locally refined donor must still avoid every painted pixel.
        for y in 46..<54 { for x in 76..<84 where hypot(Double(x) + 0.5 - 80, Double(y) + 0.5 - 50) <= 4 {
            #expect(hypot(Double(x) + dx + 0.5 - 80, Double(y) + dy + 0.5 - 50) > 4)
        } }
    }

    @Test func longThinDiagonalStrokeUsesNearbySideTextureWithoutCopyingItself() async throws {
        let width = 200, height = 160, radius = 0.0125
        let bitmap = try image(width: width, height: height) { x, y in
            [UInt8(50 + x / 4), UInt8(90 + y / 4), 60, 255]
        }
        let path = try [point(0.25, 0.3), point(0.65, 0.8)]
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: path, radius: radius)
        let dx = (source.x - path[0].x) * Double(width), dy = (source.y - path[0].y) * Double(height)
        #expect(hypot(dx, dy) < 9, "Find a lateral donor near the thin brush instead of using the length of the entire branch")
        let alternative = try await DevelopRepairAnalyzer().source(for: bitmap, path: path, radius: radius, excluding: [source])
        let otherDX = (alternative.x - path[0].x) * Double(width), otherDY = (alternative.y - path[0].y) * Double(height)
        #expect(hypot(otherDX - dx, otherDY - dy) >= radius * Double(min(width, height)) - 0.000_001)
        #expect(hypot(otherDX, otherDY) < 15, "Trying another source should retain nearby lateral options for a thin diagonal")
        let ax = path[0].x * Double(width), ay = path[0].y * Double(height)
        let vx = (path[1].x - path[0].x) * Double(width), vy = (path[1].y - path[0].y) * Double(height)
        let lengthSquared = vx * vx + vy * vy
        func isPainted(_ x: Double, _ y: Double) -> Bool {
            let t = min(1, max(0, ((x - ax) * vx + (y - ay) * vy) / lengthSquared))
            return hypot(x - ax - t * vx, y - ay - t * vy) <= radius * Double(min(width, height))
        }
        var selected = 0
        for y in 0..<height { for x in 0..<width where isPainted(Double(x) + 0.5, Double(y) + 0.5) {
            selected += 1
            #expect(!isPainted(Double(x) + dx + 0.5, Double(y) + dy + 0.5), "Every translated pixel must avoid the complete original stroke")
            #expect(!isPainted(Double(x) + otherDX + 0.5, Double(y) + otherDY + 0.5), "The alternative source must also avoid the complete original stroke")
        } }
        #expect(selected > 100)
    }

    @Test func otherSourcesExcludePreviouslyTriedPatchesAndRemainDeterministic() async throws {
        let bitmap = try image(width: 160, height: 100) { _, _ in [160, 170, 180, 255] }
        let analyzer = DevelopRepairAnalyzer(), target = try point(0.5, 0.5)
        let first = try await analyzer.source(for: bitmap, path: [target], radius: 0.04)
        let second = try await analyzer.source(for: bitmap, path: [target], radius: 0.04, excluding: [first])
        let repeated = try await analyzer.source(for: bitmap, path: [target], radius: 0.04, excluding: [first])
        #expect(second == repeated)
        #expect(hypot((second.x - first.x) * 160, (second.y - first.y) * 100) >= 4 - 0.000_001)
        let third = try await analyzer.source(for: bitmap, path: [target], radius: 0.04, excluding: [first, second])
        for previous in [first, second] {
            #expect(hypot((third.x - previous.x) * 160, (third.y - previous.y) * 100) >= 4 - 0.000_001)
        }
    }

    @Test func selectionAtImageCornerStillChoosesAnInBoundsSource() async throws {
        let bitmap = try image(width: 100, height: 100) { _, _ in [180, 180, 180, 255] }
        let target = try point(0.02, 0.02)
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.035)
        #expect(source.x >= target.x && source.y >= target.y)
        #expect(hypot(source.x - target.x, source.y - target.y) > 0.04)
    }

    @Test func finestBrushAtExactCornerCanUseItsTwoAvailableRingSamples() async throws {
        let bitmap = try image(width: 100, height: 100) { _, _ in [180, 180, 180, 255] }
        let target = try point(0, 0)
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.0005)
        #expect((0...1).contains(source.x) && (0...1).contains(source.y))
        #expect(source != target, "A one-pixel corner selection still has valid neighboring donors")
    }

    @Test func fullSelectionAndTransparentSourcesProduceExplicitFailure() async throws {
        let bitmap = try image(width: 80, height: 80) { _, _ in [180, 180, 180, 255] }
        let target = try point(0.5, 0.5)
        let full = try LocalMaskRaster(width: 80, height: 80, bytes: Data(repeating: 255, count: 6_400))
        await #expect(throws: DevelopRepairAnalysisError.noSafeSource) {
            try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.1, mask: full)
        }
        let empty = try image(width: 80, height: 80) { _, _ in [0, 0, 0, 0] }
        await #expect(throws: DevelopRepairAnalysisError.noSafeSource) {
            try await DevelopRepairAnalyzer().source(for: empty, path: [target], radius: 0.05)
        }
    }

    @Test func invalidSelectionsAndCancelledAnalysisNeverReturnAResult() async throws {
        let bitmap = try image(width: 80, height: 80) { _, _ in [180, 180, 180, 255] }
        let target = try point(0.5, 0.5)
        await #expect(throws: DevelopRepairAnalysisError.invalidSelection) {
            try await DevelopRepairAnalyzer().source(for: bitmap, path: [], radius: 0.1)
        }
        await #expect(throws: DevelopRepairAnalysisError.invalidSelection) {
            try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: .nan)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.1)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func selectedObjectIsTappedInstanceRatherThanAllForeground() throws {
        let labels: [UInt8] = [0, 1, 1, 0, 2, 2, 0, 0]
        #expect(DevelopRepairPixels.selectedInstance(labels: labels, width: 4, height: 2,
            target: try point(0.1, 0.75), path: [try point(0.5, 0.1)]) == 2)
        #expect(DevelopRepairPixels.selectedInstance(labels: labels, width: 4, height: 2,
            target: try point(1, 1), path: [try point(0.4, 0.1), try point(0.5, 0.1)]) == 1)
        #expect(DevelopRepairPixels.selectedInstance(labels: labels, width: 4, height: 2,
            target: try point(1, 1), path: []) == nil)
        #expect(DevelopRepairPixels.selectedInstance(labels: labels, width: 3, height: 3,
            target: try point(0, 0), path: []) == nil)
    }

    @Test func frozenCandidateMaskIsSmallAndUsesSourceAspect() throws {
        var bytes = Data(count: 512 * 256)
        for y in 80..<120 { for x in 200..<280 { bytes[y * 512 + x] = 255 } }
        let mask = try LocalMaskRaster(width: 512, height: 256, bytes: bytes)
        let candidate = try DevelopRepairPixels.candidate(mask: mask, label: "Objekt")
        #expect(candidate.mask.width == 256 && candidate.mask.height == 128)
        #expect(abs(candidate.center.x - 240.0 / 512) < 0.01)
        #expect(abs(candidate.center.y - 100.0 / 256) < 0.01)
        #expect(candidate.radius > 0 && candidate.radius <= 0.5)
        #expect(candidate.label == "Objekt")
    }

    @Test func dustFindsSoftRoundSpotsOnSmoothBackgroundAndNoSpotsOnFlatImage() async throws {
        let centers = [(0.25, 0.3), (0.7, 0.65)]
        let bitmap = try image(width: 400, height: 300) { x, y in
            var value = 0.65 + Double(y) / 3_000
            for (cx, cy) in centers {
                let d2 = pow(Double(x) - cx * 400, 2) + pow(Double(y) - cy * 300, 2)
                value -= 0.10 * exp(-d2 / (2 * 2.5 * 2.5))
            }
            let v = UInt8((255 * value).rounded())
            return [v, v, v, 255]
        }
        let found = try await DevelopRepairAnalyzer().candidates(in: bitmap, kind: .dust)
        #expect(found.count == 2)
        for (x, y) in centers { #expect(found.contains { hypot($0.center.x - x, $0.center.y - y) < 0.02 }) }
        #expect(found.allSatisfy { $0.mask.width <= 256 && $0.mask.height <= 256 })
        let flat = try image(width: 100, height: 100) { _, _ in [170, 170, 170, 255] }
        await #expect(throws: DevelopRepairAnalysisError.noDust) {
            try await DevelopRepairAnalyzer().candidates(in: flat, kind: .dust)
        }
    }

    @Test func dustRejectsLinesAndDenseTextureAndCapsCandidates() async throws {
        let texture = try image(width: 200, height: 160) { x, y in
            let v: UInt8 = (x / 3 + y / 3).isMultiple(of: 2) ? 80 : 210
            return [v, v, v, 255]
        }
        await #expect(throws: DevelopRepairAnalysisError.noDust) {
            try await DevelopRepairAnalyzer().candidates(in: texture, kind: .dust)
        }
        let line = try image(width: 200, height: 160) { x, y in
            let v: UInt8 = x > 50 && x < 140 && abs(y - 80) < 2 ? 120 : 180
            return [v, v, v, 255]
        }
        await #expect(throws: DevelopRepairAnalysisError.noDust) {
            try await DevelopRepairAnalyzer().candidates(in: line, kind: .dust)
        }
        let many = try image(width: 480, height: 400) { x, y in
            let dx = Double(x % 60) - 30, dy = Double(y % 60) - 30
            let value = 0.7 - 0.13 * exp(-(dx * dx + dy * dy) / 8)
            let v = UInt8((255 * value).rounded())
            return [v, v, v, 255]
        }
        let candidates = try await DevelopRepairAnalyzer().candidates(in: many, kind: .dust)
        #expect(candidates.count == 16)
        #expect(Set(candidates.map(\.id)).count == candidates.count)
    }

    private func point(_ x: Double, _ y: Double) throws -> LocalMaskPoint { try LocalMaskPoint(x: x, y: y) }

    private func rectangularSelection() throws -> LocalMaskRaster {
        var bytes = Data(count: 192 * 96)
        for y in 20..<76 { for x in 80..<112 { bytes[y * 192 + x] = 255 } }
        return try LocalMaskRaster(width: 192, height: 96, bytes: bytes)
    }

    private func image(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) throws -> PreviewBitmap {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes.append(contentsOf: pixel(x, y)) } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }
}
