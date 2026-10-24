import AppKit
import Foundation
import GlowroomCore
import Testing
import Darwin
@testable import Glowroom

@Suite("SDR display scopes")
struct DevelopScopeTests {
    @Test func analysisTimingAndStorageBoundary() async throws {
        for width in [32, 4_096] {
            let height = width / 2
            var pixels = [UInt8](repeating: 128, count: width * height * 4)
            for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
            let input = try bitmap(width: width, height: height, pixels: pixels)
            let analyzer = DevelopPreviewAnalyzer(), reducer = DevelopScopeReducer()
            var times: [Double] = []
            for _ in 0..<9 {
                let start = ContinuousClock.now
                let a = try await analyzer.analyze(input)
                let s = try await reducer.reduce(a)
                let elapsed = start.duration(to: .now).components
                times.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                #expect(s.channels.reduce(0) { $0 + $1.count * MemoryLayout<UInt32>.size } <= 393_216)
                #expect(a.pixels.count <= 384 * 384 * 4)
            }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("SCOPE-MEASUREMENT input=\(width)x\(height) coldMS=\(times[0]) warmMeanMS=\(times.dropFirst().reduce(0,+)/8) processPeakRSSBytes=\(usage.ru_maxrss) densityLimitBytes=393216 (proxy analysis+reduction; no decode/render)")
        }
    }
    @Test func exactStraightAlphaMassAndSpatialBins() async throws {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 1, 0, 0, 0, 0]
        let a = analysis(width: 4, height: 1, pixels: pixels)
        let result = try await DevelopScopeReducer().reduce(a)
        #expect(result.columns == 4)
        #expect(result.channels.map { $0.reduce(0, +) } == [384, 384, 384])
        #expect(result.channels[0][255] == 255)
        #expect(result.channels[1][256 + 255] == 128, "Already straight RGB must not be unpremultiplied again")
        #expect(result.channels[2][512 + 255] == 1, "No opacity threshold for visible statistics")
        #expect(result.channels.allSatisfy { $0[768..<1024].allSatisfy { $0 == 0 } })
    }
    @Test func rampUsesEveryEightBitValueAndBoundedColumns() async throws {
        var pixels: [UInt8] = []
        for value in 0..<256 { pixels += [UInt8(value), UInt8(255 - value), 100, 255] }
        let bitmap = try bitmap(width: 256, height: 1, pixels: pixels)
        let a = try await DevelopPreviewAnalyzer().analyze(bitmap)
        #expect(a.channels[0] == [Int](repeating: 255, count: 256))
        #expect(a.channels[1] == a.channels[0])
        #expect(a.channels[2][100] == 256 * 255)
        let spatial = try await DevelopScopeReducer().reduce(a)
        #expect(spatial.columns == 128)
        #expect(spatial.channels.allSatisfy { $0.count == 128 * 256 })
        #expect(spatial.channels[0][0] == 255 && spatial.channels[0][1] == 255)
        #expect(spatial.channels[0][127 * 256 + 255] == 255)
    }
    @Test func scaleAndChannelNormalizationUseVisibleChannelsOnly() {
        var p = DevelopScopePreferences()
        let bins = [[255, 510], [2_550, 0], [0, 255]]
        #expect(p.peak(in: bins) == 2_550)
        p.channelMask = 5
        #expect(p.peak(in: bins) == 510)
        #expect(DevelopScopeScale.linear.height(mass: 255, peak: 510) == 0.5)
        #expect(abs(DevelopScopeScale.logarithmic.height(mass: 255, peak: 510) - log(2) / log(3)) < 1e-12)
        #expect(p.scale.height(mass: 0, peak: 0) == 0)
        p.channelMask = 0
        #expect(p.visibleChannels.isEmpty && p.peak(in: bins) == 0)
        #expect(bins == [[255, 510], [2_550, 0], [0, 255]])
    }
    @Test func zeroAndOnePixelDimensionsAndCancellationAreSafe() async throws {
        let reducer = DevelopScopeReducer()
        let empty = analysis(width: 0, height: 0, pixels: [])
        #expect(empty.rgb(at: .zero) == nil)
        #expect(try await reducer.reduce(empty).columns == 0)
        let one = try await reducer.reduce(analysis(width: 1, height: 1, pixels: [100, 50, 20, 255]))
        #expect(one.columns == 1 && one.channels[0][100] == 255)
        let malformed = analysis(width: Int.max, height: 1, pixels: [])
        #expect(try await reducer.reduce(malformed).columns == 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reducer.reduce(empty)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test @MainActor func preferencesPersistValidateAndNeverRequestNewPreviewAnalysis() async throws {
        let suite = "scope-tests-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let spy = ScopeSpy()
        let workspace = DevelopWorkspace(analyze: { await spy.analyze($0) }, scopeDefaults: defaults,
                                         reduceScope: { try await spy.reduce($0) })
        let source = try bitmap(width: 1, height: 1, pixels: [90, 80, 70, 255])
        workspace.receive(source, sourceBitmap: source)
        try await wait { workspace.analysis != nil }
        let initial = await spy.analyses
        let bins = workspace.analysis?.channels
        workspace.scopePreferences.scale = .linear
        workspace.scopePreferences.channelMask = 0
        workspace.scopePreferences.mode = .waveform
        try await wait { workspace.spatialScope != nil }
        workspace.scopePreferences.mode = .parade
        workspace.scopePreferences.channelMask = 2
        #expect(await spy.analyses == initial)
        #expect(await spy.reductions == 1)
        #expect(workspace.analysis?.channels == bins)
        let restored = DevelopWorkspace(scopeDefaults: defaults)
        #expect(restored.scopePreferences == workspace.scopePreferences)
        workspace.clear()
        #expect(workspace.scopePreferences.mode == .parade)
        let invalid = Data(#"{"version":1,"mode":"future","scale":"oops","channelMask":-1}"#.utf8)
        let p = try JSONDecoder().decode(DevelopScopePreferences.self, from: invalid)
        #expect(p == DevelopScopePreferences())
        let emptyMask = Data(#"{"version":1,"mode":"waveform","scale":"linear","channelMask":0}"#.utf8)
        #expect(try JSONDecoder().decode(DevelopScopePreferences.self, from: emptyMask).channelMask == 0)
    }
    @Test @MainActor func lateSpatialSuccessAndFailureCannotReplaceNewFrame() async throws {
        let gate = ScopeGate()
        let suite = "scope-gate-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = DevelopWorkspace(scopeDefaults: defaults, reduceScope: { try await gate.reduce($0) })
        workspace.scopePreferences.mode = .waveform
        let a = try bitmap(width: 1, height: 1, pixels: [20, 40, 60, 255])
        let b = try bitmap(width: 2, height: 1, pixels: [100, 80, 60, 255, 100, 80, 60, 255])
        workspace.receive(a, sourceBitmap: a)
        try await wait { await gate.pending == 1 }
        workspace.scopePreferences.mode = .histogram
        workspace.scopePreferences.mode = .parade
        try await wait { await gate.pending == 2 }
        workspace.receive(b, sourceBitmap: b)
        try await wait { await gate.pending == 3 }
        await gate.release(width: 2, fail: false)
        try await wait { workspace.spatialScope?.columns == 2 }
        await gate.release(width: 1, fail: false)
        await gate.release(width: 1, fail: true)
        try await wait { await gate.completed == 3 }
        #expect(workspace.spatialScope?.columns == 2)
        #expect(workspace.analysis?.width == 2)
        workspace.clear()
    }
    @Test func spatialPositionsFollowRenderedCropFlipAndQuarterTurns() async throws {
        let w = 12, h = 8
        var pixels: [UInt8] = []
        for _ in 0..<h { for x in 0..<w { pixels += x < w / 2 ? [255, 0, 0, 255] : [0, 255, 0, 255] } }
        let original = try bitmap(width: w, height: h, pixels: pixels)
        for geometry in [DevelopGeometry(), DevelopGeometry(flipHorizontal: true),
                         DevelopGeometry(quarterTurns: 1), DevelopGeometry(quarterTurns: 2),
                         DevelopGeometry(crop: try DevelopCropRect(x: 0.5, y: 0, width: 0.5, height: 1))] {
            var settings = EditSettings.neutral; settings.developGeometry = geometry
            let rendered = try EditRenderer.render(original, settings: settings)
            let a = try await DevelopPreviewAnalyzer().analyze(rendered)
            let s = try await DevelopScopeReducer().reduce(a)
            // Independent column oracle from the accepted oriented raster.
            for x in 0..<a.width {
                let column = x * s.columns / a.width
                let redAtTop = Int(a.pixels[x * 4])
                #expect(s.channels[0][column * 256 + redAtTop] > 0)
            }
            if geometry.flipHorizontal { #expect(s.channels[1][255] == UInt32(a.height * 255)) }
            if geometry.crop != nil { #expect(s.channels[0].enumerated().filter { $0.offset % 256 == 255 }.allSatisfy { $0.element == 0 }) }
        }
    }
    private func analysis(width: Int, height: Int, pixels: [UInt8]) -> DevelopPreviewAnalysis {
        .init(width: width, height: height, pixels: pixels, channels: [[], [], []], shadows: 0, highlights: 0)
    }
    private func bitmap(width: Int, height: Int, pixels: [UInt8]) throws -> PreviewBitmap {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return PreviewBitmap(image: try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
    }
    @MainActor private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate())
    }
}
private actor ScopeSpy {
    var analyses = 0, reductions = 0
    func analyze(_ bitmap: PreviewBitmap) -> DevelopPreviewAnalysis {
        analyses += 1
        return .init(width: 1, height: 1, pixels: [90, 80, 70, 255], channels: [[255], [255], [255]], shadows: 0, highlights: 0)
    }
    func reduce(_ analysis: DevelopPreviewAnalysis) async throws -> DevelopSpatialScope {
        reductions += 1
        return try await DevelopScopeReducer().reduce(analysis)
    }
}
private actor ScopeGate {
    struct Request { let width: Int; let continuation: CheckedContinuation<DevelopSpatialScope, Error> }
    var requests: [Request] = []
    var completed = 0
    var pending: Int { requests.count }
    func reduce(_ a: DevelopPreviewAnalysis) async throws -> DevelopSpatialScope {
        defer { completed += 1 }
        return try await withCheckedThrowingContinuation { requests.append(.init(width: a.width, continuation: $0)) }
    }
    func release(width: Int, fail: Bool) {
        guard let i = requests.firstIndex(where: { $0.width == width }) else { return }
        let request = requests.remove(at: i)
        if fail { request.continuation.resume(throwing: EditRenderError.unavailable) }
        else { request.continuation.resume(returning: .init(columns: width, channels: [[], [], []])) }
    }
}
