import CoreGraphics
import Foundation
import Testing
@testable import PicEdit

@Suite("Reusable automatic tone analysis")
struct AutoToneAnalysisCacheTests {
    @Test
    func cachedCurvesMatchFreshAnalysisAcrossAmountsProfilesAndTransparency() throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let image = try fixture(space: CGColorSpace(name: name)!)
            let original = try AutoToneAnalysis.analyze(image)
            for amount in [-10.0, 0, 1, 15, 50, 99, 100, 200, .nan, .infinity] {
                let normalized = amount.isFinite ? min(1, max(0, amount / 100)) : 0
                let expected = AutoToneCurve(ordinates: zip(AutoToneCurve.abscissae, original.offsets).map { $0 + normalized * $1 })
                let actual = try AutoToneCurve.analyze(image, amount: amount)
                #expect(actual.ordinates == expected.ordinates)
                #expect(actual.coefficients == expected.coefficients)
            }
        }
    }

    @Test
    func repeatedAnalysisUsesIdentityAndEvictsTheLeastRecentlyUsedSource() throws {
        let probe = AnalysisProbe()
        let cache = AutoToneAnalysisCache(maximumEntries: 2, analyze: { try probe.analyze($0) })
        let first = try fixture(), second = try fixture(), third = try fixture()
        _ = try cache.analysis(for: first)
        _ = try cache.analysis(for: second)
        _ = try cache.analysis(for: first)
        #expect(probe.count == 2, "Equal pixels in separate images must not alias an identity entry")
        _ = try cache.analysis(for: third)
        _ = try cache.analysis(for: first)
        #expect(probe.count == 3)
        _ = try cache.analysis(for: second)
        #expect(probe.count == 4, "The cache must remain bounded while all source images are alive")
    }

    @Test
    func analysisCacheDoesNotKeepTheDecodedSourceAlive() throws {
        let cache = AutoToneAnalysisCache()
        weak var released: CGImage?
        try autoreleasepool {
            let image = try fixture()
            released = image
            _ = try cache.analysis(for: image)
            #expect(released != nil)
        }
        #expect(released == nil)
    }

    @Test
    func concurrentRequestsShareAnalysisWhileIndependentSourcesProceed() async throws {
        let probe = AnalysisProbe(blockFirst: true)
        let cache = AutoToneAnalysisCache(maximumEntries: 1, analyze: { try probe.analyze($0) })
        let first = try fixture(), second = try fixture()
        let producer = Task.detached { try cache.analysis(for: first) }
        defer { probe.release() }
        try await waitUntil { probe.count == 1 }
        let shared = Task.detached { try cache.analysis(for: first) }
        let independent = Task.detached { try cache.analysis(for: second) }
        let independentResult = try await independent.value
        #expect(probe.count == 2, "The cache lock must not serialize independent image analysis")
        probe.release()
        let produced = try await producer.value
        let joined = try await shared.value
        #expect(produced.offsets == joined.offsets)
        #expect(independentResult.offsets == produced.offsets)
        #expect(probe.count == 2)
    }

    @Test
    func cancelledWaiterDoesNotCancelOrRemoveTheSharedAnalysis() async throws {
        let probe = AnalysisProbe(blockFirst: true)
        let cache = AutoToneAnalysisCache(analyze: { try probe.analyze($0) })
        let image = try fixture()
        let producer = Task.detached { try cache.analysis(for: image) }
        defer { probe.release() }
        try await waitUntil { probe.count == 1 }
        let waiter = Task.detached { try cache.analysis(for: image) }
        // Give the second caller an opportunity to join the in-flight entry.
        try await Task.sleep(for: .milliseconds(25))
        waiter.cancel()
        do { _ = try await waiter.value; Issue.record("Canceled waiter unexpectedly succeeded") }
        catch is CancellationError { }
        #expect(probe.count == 1)
        probe.release()
        let produced = try await producer.value
        #expect(try cache.analysis(for: image).offsets == produced.offsets)
        #expect(probe.count == 1)
    }

    @Test
    func cancelledProducerLetsTheRemainingWaiterRetry() async throws {
        let probe = AnalysisProbe(blockFirst: true)
        let cache = AutoToneAnalysisCache(analyze: { try probe.analyze($0) })
        let image = try fixture()
        let producer = Task.detached { try cache.analysis(for: image) }
        defer { probe.release() }
        try await waitUntil { probe.count == 1 }
        let waiter = Task.detached { try cache.analysis(for: image) }
        producer.cancel()
        probe.release()
        do { _ = try await producer.value; Issue.record("Canceled producer unexpectedly succeeded") }
        catch is CancellationError { }
        let recovered = try await waiter.value
        #expect(recovered.offsets.count == 7)
        #expect(probe.count == 2)
        _ = try cache.analysis(for: image)
        #expect(probe.count == 2)
    }

    @Test
    func failedAnalysisIsNotCached() throws {
        let probe = AnalysisProbe(failFirst: true)
        let cache = AutoToneAnalysisCache(analyze: { try probe.analyze($0) })
        let image = try fixture()
        #expect(throws: AnalysisProbeError.failed) { try cache.analysis(for: image) }
        let recovered = try cache.analysis(for: image)
        #expect(recovered.offsets.count == 7)
        #expect(probe.count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_AUTOTONE_BENCHMARK"] == "1"))
    func benchmarkRepeatedLargePreviewAnalysis() throws {
        let image = try fixture(width: 3072, height: 2048)
        let cache = AutoToneAnalysisCache()
        let iterations = 60
        let clock = ContinuousClock()
        func duration(_ work: () throws -> Void) rethrows -> Double {
            let start = clock.now
            try work()
            let elapsed = start.duration(to: clock.now).components
            return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        }
        let cold = try duration { _ = try cache.analysis(for: image) }
        let fresh = try duration { for _ in 0..<iterations { _ = try AutoToneAnalysis.analyze(image) } }
        let cached = try duration { for _ in 0..<iterations { _ = try cache.analysis(for: image) } }
        print("AutoTone analysis benchmark 3072x2048 RGBA, \(iterations) iterations: first cached \(cold) ms, repeated fresh \(fresh) ms, repeated cached \(cached) ms")
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw AnalysisProbeError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func fixture(width: Int = 256, height: Int = 128,
                         space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = y < height / 8 ? 0 : y < height / 4 ? 128 : 255
                let value = x * 255 / max(1, width - 1)
                pixels[offset] = UInt8(value * alpha / 255)
                pixels[offset + 1] = UInt8(min(255, value + 12) * alpha / 255)
                pixels[offset + 2] = UInt8(max(0, value - 20) * alpha / 255)
                pixels[offset + 3] = UInt8(alpha)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}

private enum AnalysisProbeError: Error { case timeout, failed }

private final class AnalysisProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockFirst: Bool
    private let failFirst: Bool
    private var calls = 0

    init(blockFirst: Bool = false, failFirst: Bool = false) {
        self.blockFirst = blockFirst
        self.failFirst = failFirst
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func release() { gate.signal() }

    func analyze(_ image: CGImage) throws -> AutoToneAnalysis {
        lock.lock()
        calls += 1
        let first = calls == 1
        lock.unlock()
        if blockFirst && first, gate.wait(timeout: .now() + 5) == .timedOut { throw AnalysisProbeError.timeout }
        if failFirst && first { throw AnalysisProbeError.failed }
        return try AutoToneAnalysis.analyze(image)
    }
}
