import CoreGraphics
import Foundation
import Testing
@testable import Glowroom

@Suite("Reusable automatic tone analysis", .timeLimit(.minutes(1)))
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
        try await withBlockedAnalysis(maximumEntries: 1) { scenario in
            let first = try fixture(), second = try fixture()
            let producer = scenario.start(first)
            try await scenario.probe.started.wait("first tone producer entered", until: { $0 == 1 })
            let shared = scenario.start(first)
            try await scenario.joined.wait("second tone caller joined the in-flight entry", until: { $0 == 1 })
            let independent = scenario.start(second)
            let independentResult = try await independent.value
            #expect(scenario.probe.count == 2, "The cache lock must not serialize independent image analysis")
            scenario.probe.release()
            let produced = try await producer.value
            let joined = try await shared.value
            #expect(produced.offsets == joined.offsets)
            #expect(independentResult.offsets == produced.offsets)
            #expect(scenario.probe.count == 2)
        }
    }

    @Test
    func cancelledWaiterDoesNotCancelOrRemoveTheSharedAnalysis() async throws {
        try await withBlockedAnalysis { scenario in
            let image = try fixture()
            let producer = scenario.start(image)
            try await scenario.probe.started.wait("tone producer entered before waiter cancellation", until: { $0 == 1 })
            let waiter = scenario.start(image)
            try await scenario.joined.wait("cancelled tone caller joined the in-flight entry", until: { $0 == 1 })
            waiter.cancel()
            do { _ = try await waiter.value; Issue.record("Canceled waiter unexpectedly succeeded") }
            catch is CancellationError { }
            #expect(scenario.probe.count == 1)
            scenario.probe.release()
            let produced = try await producer.value
            #expect(try scenario.cache.analysis(for: image).offsets == produced.offsets)
            #expect(scenario.probe.count == 1)
        }
    }

    @Test
    func cancelledProducerLetsTheRemainingWaiterRetry() async throws {
        try await withBlockedAnalysis { scenario in
            let image = try fixture()
            let producer = scenario.start(image)
            try await scenario.probe.started.wait("tone producer entered before producer cancellation", until: { $0 == 1 })
            let waiter = scenario.start(image)
            try await scenario.joined.wait("remaining tone caller joined the in-flight entry", until: { $0 == 1 })
            producer.cancel()
            scenario.probe.release()
            do { _ = try await producer.value; Issue.record("Canceled producer unexpectedly succeeded") }
            catch is CancellationError { }
            let recovered = try await waiter.value
            #expect(recovered.offsets.count == 7)
            #expect(scenario.probe.count == 2)
            _ = try scenario.cache.analysis(for: image)
            #expect(scenario.probe.count == 2)
        }
    }

    @Test
    func fakeProducerStaysHeldPastItsFormerTimeoutUntilExplicitRelease() async throws {
        try await withBlockedAnalysis { scenario in
            let image = try fixture()
            let producer = scenario.start(image)
            try await scenario.probe.started.wait("delayed tone producer entered", until: { $0 == 1 })
            let waiter = scenario.start(image)
            try await scenario.joined.wait("delayed tone caller joined", until: { $0 == 1 })
            // Intentionally exceed the old fake's five-second lifetime. This
            // delay exercises the former failure, not an admission prerequisite.
            try await Task.sleep(for: .milliseconds(5_100))
            #expect(scenario.probe.count == 1)
            #expect(!scenario.probe.returned.value)
            scenario.probe.release()
            let produced = try await producer.value
            #expect(try await waiter.value.offsets == produced.offsets)
            #expect(scenario.probe.count == 1)
        }
    }

    private func withBlockedAnalysis(maximumEntries: Int = 8,
        _ body: (BlockedAnalysisScenario) async throws -> Void) async throws {
        let scenario = BlockedAnalysisScenario(maximumEntries: maximumEntries)
        do {
            try await body(scenario)
            await scenario.finish()
        } catch {
            await scenario.finish()
            throw error
        }
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_AUTOTONE_BENCHMARK"] == "1"))
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

private enum AnalysisProbeError: Error { case failed }

private final class AnalysisProbe: @unchecked Sendable {
    private let gate = NSCondition()
    private let blockFirst: Bool
    private let failFirst: Bool
    private var calls = 0
    private var released = false
    let started = TestStateSignal(0)
    let returned = TestStateSignal(false)

    init(blockFirst: Bool = false, failFirst: Bool = false) {
        self.blockFirst = blockFirst
        self.failFirst = failFirst
    }

    var count: Int { gate.withLock { calls } }

    func release() {
        gate.lock()
        released = true
        gate.broadcast()
        gate.unlock()
    }

    func analyze(_ image: CGImage) throws -> AutoToneAnalysis {
        gate.lock()
        calls += 1
        let count = calls
        gate.unlock()
        started.update { $0 = count }
        if blockFirst && count == 1 {
            gate.lock()
            while !released { gate.wait() }
            gate.unlock()
        }
        defer { returned.update { $0 = true } }
        if failFirst && count == 1 { throw AnalysisProbeError.failed }
        return try AutoToneAnalysis.analyze(image)
    }
}

private final class BlockedAnalysisScenario {
    let probe = AnalysisProbe(blockFirst: true)
    let joined = TestStateSignal(0)
    let cache: AutoToneAnalysisCache
    private var tasks: [Task<AutoToneAnalysis, Error>] = []

    init(maximumEntries: Int) {
        let probe = probe, joined = joined
        cache = AutoToneAnalysisCache(maximumEntries: maximumEntries,
            didJoinInFlight: { joined.update { $0 += 1 } }, analyze: { try probe.analyze($0) })
    }

    func start(_ image: CGImage) -> Task<AutoToneAnalysis, Error> {
        let worker = TestSynchronousWorker(), cache = cache
        let task = Task { try await worker.run { try cache.analysis(for: image) } }
        tasks.append(task)
        return task
    }

    func finish() async {
        // Release before draining even on a failed prerequisite. Cancellation
        // alone deliberately cannot interrupt a held native producer.
        tasks.forEach { $0.cancel() }
        probe.release()
        for task in tasks { _ = await task.result }
    }
}
