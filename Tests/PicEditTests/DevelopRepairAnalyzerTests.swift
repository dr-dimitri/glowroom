import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

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

    @Test func selectionAtImageCornerStillChoosesAnInBoundsSource() async throws {
        let bitmap = try image(width: 100, height: 100) { _, _ in [180, 180, 180, 255] }
        let target = try point(0.02, 0.02)
        let source = try await DevelopRepairAnalyzer().source(for: bitmap, path: [target], radius: 0.035)
        #expect(source.x >= target.x && source.y >= target.y)
        #expect(hypot(source.x - target.x, source.y - target.y) > 0.04)
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
