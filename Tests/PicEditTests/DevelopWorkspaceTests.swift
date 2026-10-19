import AppKit
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Develop histogram and white-balance sampling")
struct DevelopWorkspaceTests {
    @Test func orientedPreviewRowsAndNormalizedPickerCoordinatesAgree() async throws {
        let width = 16, height = 12
        let topLeft: [UInt8] = [220, 30, 40, 255], topRight: [UInt8] = [20, 210, 50, 255]
        let bottomLeft: [UInt8] = [30, 40, 200, 255], bottomRight: [UInt8] = [100, 100, 100, 255]
        let bitmap = try bitmap(width: width, height: height) { x, y in
            if y < height / 2 { return x < width / 2 ? topLeft : topRight }
            return x < width / 2 ? bottomLeft : bottomRight
        }
        let analysis = try await DevelopPreviewAnalyzer().analyze(bitmap)
        #expect(analysis.width == width && analysis.height == height)
        for (point, color) in [(CGPoint(x: 0.15, y: 0.15), topLeft), (CGPoint(x: 0.85, y: 0.15), topRight),
                               (CGPoint(x: 0.15, y: 0.85), bottomLeft), (CGPoint(x: 0.85, y: 0.85), bottomRight)] {
            let rgb = try #require(analysis.rgb(at: point))
            #expect(abs(rgb.0 - Double(color[0]) / 255) < 0.01)
            #expect(abs(rgb.1 - Double(color[1]) / 255) < 0.01)
            #expect(abs(rgb.2 - Double(color[2]) / 255) < 0.01)
            #expect(rgb.3 == 1)
        }
        #expect(analysis.channels.map { $0.reduce(0, +) } == [width * height, width * height, width * height])
        #expect(analysis.shadows == 0 && analysis.highlights == 0)
    }

    @Test func histogramUnpremultipliesAndIgnoresTransparentPixelsWhilePickerRejectsThem() async throws {
        let colors: [[UInt8]] = [[0, 0, 0, 255], [255, 255, 255, 255], [120, 80, 40, 128], [255, 0, 0, 0]]
        let bitmap = try bitmap(width: 4, height: 1) { x, _ in colors[x] }
        let analysis = try await DevelopPreviewAnalyzer().analyze(bitmap)
        #expect(analysis.channels.map { $0.reduce(0, +) } == [3, 3, 3])
        #expect(analysis.shadows == 1 && analysis.highlights == 1)
        #expect(abs(Int(analysis.pixels[8]) - 120) <= 1)
        #expect(abs(Int(analysis.pixels[9]) - 80) <= 1)
        #expect(abs(Int(analysis.pixels[10]) - 40) <= 1)
        let transparent = try self.bitmap(width: 8, height: 8) { _, _ in [120, 80, 40, 128] }
        #expect(try await DevelopPreviewAnalyzer().analyze(transparent).rgb(at: CGPoint(x: 0.5, y: 0.5)) == nil)
        let overlay = try #require(analysis.clippingImage(shadows: true, highlights: true))
        #expect(overlay === analysis.clippingImage(shadows: true, highlights: true), "Warning toggles reuse a bitmap prepared on the analyzer actor")
        #expect(analysis.clippingImage(shadows: false, highlights: false) == nil)
        let bytes = try #require(overlay.dataProvider?.data) as Data
        #expect(Array(bytes.prefix(4)) == [0, 0, 255, 180])
        #expect(Array(bytes[4..<8]) == [255, 0, 0, 180])
        #expect(Array(bytes[8..<16]) == [UInt8](repeating: 0, count: 8))
    }

    @Test func analysisIsBoundedAndPickerHandlesEdgesAndInvalidCoordinates() async throws {
        let bitmap = try bitmap(width: 1_000, height: 500) { _, _ in [64, 128, 192, 255] }
        let analysis = try await DevelopPreviewAnalyzer().analyze(bitmap)
        #expect(analysis.width == 384 && analysis.height == 192)
        #expect(analysis.pixels.count == 384 * 192 * 4)
        for point in [CGPoint.zero, CGPoint(x: 1, y: 1)] {
            let rgb = try #require(analysis.rgb(at: point))
            #expect(abs(rgb.0 - 64.0 / 255) < 0.01)
            #expect(abs(rgb.1 - 128.0 / 255) < 0.01)
            #expect(abs(rgb.2 - 192.0 / 255) < 0.01)
        }
        #expect(analysis.rgb(at: CGPoint(x: -CGFloat.infinity, y: 0)) == nil)
        #expect(analysis.rgb(at: CGPoint(x: CGFloat.nan, y: 0)) == nil)
        #expect(analysis.rgb(at: CGPoint(x: 0.5, y: -0.01)) == nil)
        #expect(analysis.rgb(at: CGPoint(x: 1.01, y: 0.5)) == nil)
        #expect(analysis.channels.map { $0.reduce(0, +) } == [73_728, 73_728, 73_728])
    }

    @Test func cancelledAnalysisNeverReturnsAnObsoleteResult() async throws {
        let bitmap = try bitmap(width: 800, height: 400) { _, _ in [60, 100, 140, 255] }
        let analyzer = DevelopPreviewAnalyzer()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await analyzer.analyze(bitmap)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test @MainActor func sourceBindingClearsPickerAndRejectsLateAnalysisFromThePreviousImage() async throws {
        let gate = DevelopAnalysisGate()
        let workspace = DevelopWorkspace(analyze: { await gate.analyze($0) })
        let a = try bitmap(width: 20, height: 10) { _, _ in [20, 40, 60, 255] }
        let b = try bitmap(width: 40, height: 20) { _, _ in [40, 60, 80, 255] }
        workspace.bind(source: source("A"))
        workspace.receive(a, sourceBitmap: a)
        #expect(workspace.navigatorImage === a.image)
        try await wait { await gate.pending(width: 20) == 1 }
        workspace.picksWhiteBalance = true
        workspace.repairSource = try LocalMaskPoint(x: 0.2, y: 0.4)
        workspace.bind(source: source("B"))
        #expect(workspace.navigatorImage == nil)
        #expect(workspace.sourceAnalysis == nil && workspace.analysis == nil && workspace.sourceSize == nil)
        #expect(!workspace.picksWhiteBalance && workspace.repairSource == nil)
        workspace.receive(b, sourceBitmap: b)
        #expect(workspace.navigatorImage === b.image)
        try await wait { await gate.pending(width: 40) == 1 }
        await gate.release(width: 40)
        try await wait { await gate.started(width: 40) == 2 }
        await gate.release(width: 40)
        try await wait { workspace.analysis?.pixels.first == 40 && !workspace.isAnalyzing }
        await gate.release(width: 20)
        try await wait { await gate.returned(width: 20) == 1 }
        await Task.yield()
        #expect(workspace.sourceIdentity == source("B"))
        #expect(workspace.analysis?.pixels.first == 40 && workspace.sourceAnalysis?.pixels.first == 40)
        #expect(workspace.sourceSize == CGSize(width: 40, height: 20))
        #expect(await gate.started(width: 20) == 1, "Cancellation must not start a second obsolete base analysis")
        workspace.clear()
    }

    @Test @MainActor func sliderAnalysisReusesTheDecodedBaseAndClearPreventsLatePublication() async throws {
        let gate = DevelopAnalysisGate()
        let workspace = DevelopWorkspace(analyze: { await gate.analyze($0) })
        let sourceBitmap = try bitmap(width: 20, height: 10) { _, _ in [20, 40, 60, 255] }
        let first = try bitmap(width: 40, height: 20) { _, _ in [40, 60, 80, 255] }
        let second = try bitmap(width: 60, height: 30) { _, _ in [60, 80, 100, 255] }
        workspace.bind(source: source("A"))
        workspace.receive(first, sourceBitmap: sourceBitmap)
        #expect(workspace.navigatorImage === first.image)
        try await wait { await gate.pending(width: 40) == 1 }
        await gate.release(width: 40)
        try await wait { await gate.pending(width: 20) == 1 }
        await gate.release(width: 20)
        try await wait { workspace.sourceAnalysis?.pixels.first == 20 && workspace.analysis?.pixels.first == 40 }
        workspace.receive(second, sourceBitmap: sourceBitmap)
        #expect(workspace.navigatorImage === second.image)
        #expect(workspace.sourceAnalysis?.pixels.first == 20)
        try await wait { await gate.pending(width: 60) == 1 }
        await gate.release(width: 60)
        try await wait { workspace.analysis?.pixels.first == 60 && !workspace.isAnalyzing }
        #expect(await gate.started(width: 20) == 1, "A slider change reuses the existing source bitmap analysis")
        workspace.receive(first, sourceBitmap: sourceBitmap)
        try await wait { await gate.pending(width: 40) == 1 }
        workspace.clear()
        #expect(workspace.navigatorImage == nil)
        await gate.release(width: 40)
        try await wait { await gate.returned(width: 40) == 2 }
        await Task.yield()
        #expect(workspace.analysis == nil && workspace.sourceAnalysis == nil && !workspace.isAnalyzing)
        #expect(workspace.sourceIdentity == nil)
    }

    @Test @MainActor func replacementBaseCannotKeepOldPickerSamplesWhileItsAnalysisIsPending() async throws {
        let gate = DevelopAnalysisGate()
        let workspace = DevelopWorkspace(analyze: { await gate.analyze($0) })
        let a = try bitmap(width: 20, height: 10) { _, _ in [20, 40, 60, 255] }
        let b = try bitmap(width: 40, height: 20) { _, _ in [40, 60, 80, 255] }
        workspace.bind(source: source("A"))
        workspace.receive(a, sourceBitmap: a)
        try await wait { await gate.pending(width: 20) == 1 }; await gate.release(width: 20)
        try await wait { await gate.started(width: 20) == 2 }; await gate.release(width: 20)
        try await wait { workspace.sourceAnalysis != nil }
        workspace.receive(b, sourceBitmap: b)
        #expect(workspace.sourceAnalysis == nil)
        #expect(workspace.sourceSize == CGSize(width: 40, height: 20))
        try await wait { await gate.pending(width: 40) == 1 }
        workspace.clear(); await gate.release(width: 40)
    }

    private func source(_ name: String) -> AISourceIdentity {
        .original(.init(fileURL: URL(fileURLWithPath: "/tmp/develop-\(name).jpg"), modifiedAt: .distantPast, fileSize: 0))
    }
    @MainActor private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }

    private func bitmap(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) throws -> PreviewBitmap {
        var data = Data(); data.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { data.append(contentsOf: pixel(x, y)) } }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }
}

private actor DevelopAnalysisGate {
    private struct Pending { let width: Int; let continuation: CheckedContinuation<DevelopPreviewAnalysis, Never> }
    private var requests: [Pending] = []
    private var starts: [Int: Int] = [:]
    private var returns: [Int: Int] = [:]
    func analyze(_ bitmap: PreviewBitmap) async -> DevelopPreviewAnalysis {
        let width = bitmap.image.width
        starts[width, default: 0] += 1
        let result = await withCheckedContinuation { continuation in requests.append(.init(width: width, continuation: continuation)) }
        returns[width, default: 0] += 1
        return result
    }
    func pending(width: Int) -> Int { requests.filter { $0.width == width }.count }
    func started(width: Int) -> Int { starts[width, default: 0] }
    func returned(width: Int) -> Int { returns[width, default: 0] }
    func release(width: Int) {
        guard let index = requests.firstIndex(where: { $0.width == width }) else { return }
        let request = requests.remove(at: index)
        request.continuation.resume(returning: DevelopPreviewAnalysis(width: 1, height: 1,
            pixels: [UInt8(width), 0, 0, 255], channels: [[Int]](repeating: [Int](repeating: 0, count: 128), count: 3), shadows: 0, highlights: 0))
    }
}
