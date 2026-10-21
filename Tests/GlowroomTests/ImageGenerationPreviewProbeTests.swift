import Dispatch
import Foundation
import Testing
@testable import Glowroom

@Suite("Image generation preview measurement and admission")
struct ImageGenerationPreviewProbeTests {
    private let latencyKeys = ["p50Seconds", "p95Seconds", "p99Seconds", "maximumSeconds", "maximumRenderOnlySeconds"]

    @Test func measuredStatisticsKeepExistingUpperIndexQuantilesAndSerialize() throws {
        let latencies = (0...100).reversed().map { Double($0) / 1_000 }
        let renderDurations = latencies.map { $0 / 2 }
        let report = ImageGenerationPreviewStatistics(latencies: latencies, renderDurations: renderDurations).report
        #expect(report["sampleCount"] as? Int == 101)
        #expect(report["measurementStatus"] as? String == "measured")
        #expect(report["p50Seconds"] as? Double == 0.05)
        #expect(report["p95Seconds"] as? Double == 0.095)
        #expect(report["p99Seconds"] as? Double == 0.099)
        #expect(report["maximumSeconds"] as? Double == 0.1)
        #expect(report["maximumRenderOnlySeconds"] as? Double == 0.05)
        let restored = try jsonRoundTrip(report)
        #expect((restored["sampleCount"] as? NSNumber)?.intValue == 101)
        #expect((restored["p95Seconds"] as? NSNumber)?.doubleValue == 0.095)
    }

    @Test func emptyStatisticsPublishNullInsteadOfFabricatedZeroLatency() throws {
        let report = ImageGenerationPreviewStatistics(latencies: [], renderDurations: []).report
        #expect(report["sampleCount"] as? Int == 0)
        #expect(report["measurementStatus"] as? String == "missing-samples")
        expectNullLatencies(report)
        expectNullLatencies(try jsonRoundTrip(report))
    }

    @Test func oneMeasuredZeroIsDistinctFromMissingSamples() throws {
        let report = ImageGenerationPreviewStatistics(latencies: [0], renderDurations: [0]).report
        #expect(report["sampleCount"] as? Int == 1)
        #expect(report["measurementStatus"] as? String == "measured")
        for key in latencyKeys { #expect(report[key] as? Double == 0) }
        let restored = try jsonRoundTrip(report)
        let gate = ImageGenerationPreviewGate.evaluate(baseline: restored, concurrent: restored)
        #expect(gate.passed)
        #expect(gate.failureReasons.isEmpty)
    }

    @Test func invalidStatisticsFailClosedAndRemainJSONSerializable() throws {
        for invalid in [-0.1, Double.nan, Double.infinity, -Double.infinity] {
            for invalidRenderDuration in [false, true] {
                let latencies = invalidRenderDuration ? [0.1, 0.2] : [0.1, invalid]
                let renderDurations = invalidRenderDuration ? [0.05, invalid] : [0.05, 0.1]
                let report = ImageGenerationPreviewStatistics(latencies: latencies, renderDurations: renderDurations).report
                #expect(report["sampleCount"] as? Int == 2)
                #expect(report["measurementStatus"] as? String == "invalid-latencies")
                expectNullLatencies(report)
                expectNullLatencies(try jsonRoundTrip(report))
                let gate = ImageGenerationPreviewGate.evaluate(baseline: measurement(), concurrent: report)
                #expect(!gate.passed)
                #expect(gate.failureReasons == ["concurrent-missing-or-invalid-p95"])
            }
        }
    }

    @Test func mismatchedLatencyAndRenderSamplesAreInvalidIncludingOneEmptyArray() throws {
        let mismatches: [([Double], [Double])] = [([0.1], []), ([], [0.05]), ([0.1, 0.2], [0.05])]
        for (latencies, renderDurations) in mismatches {
            let report = ImageGenerationPreviewStatistics(latencies: latencies, renderDurations: renderDurations).report
            #expect(report["sampleCount"] as? Int == latencies.count)
            #expect(report["measurementStatus"] as? String == "invalid-latencies")
            expectNullLatencies(report)
            expectNullLatencies(try jsonRoundTrip(report))
            let gate = ImageGenerationPreviewGate.evaluate(baseline: measurement(), concurrent: report)
            #expect(!gate.passed)
            #expect(gate.failureReasons == [latencies.isEmpty
                ? "concurrent-missing-or-invalid-sample-count" : "concurrent-missing-or-invalid-p95"])
        }
    }

    @Test func gateKeepsInclusiveAbsoluteAndBaselineLimits() {
        let atBothLimits = ImageGenerationPreviewGate.evaluate(
            baseline: measurement(p95: 0.125), concurrent: measurement(p95: 0.25))
        #expect(atBothLimits.passed)
        #expect(atBothLimits.failureReasons.isEmpty)
        let measuredZero = ImageGenerationPreviewGate.evaluate(
            baseline: measurement(p95: 0), concurrent: measurement(p95: 0))
        #expect(measuredZero.passed)
        #expect(measuredZero.failureReasons.isEmpty)

        let absoluteOnly = ImageGenerationPreviewGate.evaluate(
            baseline: measurement(p95: 0.2), concurrent: measurement(p95: 0.3))
        #expect(!absoluteOnly.passed)
        #expect(absoluteOnly.failureReasons == ["absolute-p95-exceeded"])
        let multiplierOnly = ImageGenerationPreviewGate.evaluate(
            baseline: measurement(p95: 0.1), concurrent: measurement(p95: 0.21))
        #expect(!multiplierOnly.passed)
        #expect(multiplierOnly.failureReasons == ["baseline-multiplier-exceeded"])
        let bothExceeded = ImageGenerationPreviewGate.evaluate(
            baseline: measurement(p95: 0.1), concurrent: measurement(p95: 0.3))
        #expect(!bothExceeded.passed)
        #expect(bothExceeded.failureReasons == ["absolute-p95-exceeded", "baseline-multiplier-exceeded"])
    }

    @Test func gateAcceptsNumericMeasurementsAfterJSONRoundTrip() throws {
        let baseline = try jsonRoundTrip(measurement(sampleCount: 7, p95: 0.125))
        let concurrent = try jsonRoundTrip(measurement(sampleCount: 3, p95: 0.25))
        let gate = ImageGenerationPreviewGate.evaluate(baseline: baseline, concurrent: concurrent)
        #expect(gate.passed)
        #expect(gate.failureReasons.isEmpty)
    }

    @Test func gateRejectsMissingAndMalformedSampleCountsInEitherPhase() {
        let invalidCounts: [Any?] = [nil, NSNull(), 0, -1, 0.5, true, false, "1", Double.nan,
                                     Double.infinity, -Double.infinity]
        for count in invalidCounts {
            // Even a plausible p95 cannot establish a measurement without samples.
            let invalid = measurement(sampleCount: count)
            let baseline = ImageGenerationPreviewGate.evaluate(baseline: invalid, concurrent: measurement())
            #expect(!baseline.passed)
            #expect(baseline.failureReasons == ["baseline-missing-or-invalid-sample-count"])
            let concurrent = ImageGenerationPreviewGate.evaluate(baseline: measurement(), concurrent: invalid)
            #expect(!concurrent.passed)
            #expect(concurrent.failureReasons == ["concurrent-missing-or-invalid-sample-count"])
        }
    }

    @Test func gateRejectsMissingAndMalformedP95InEitherPhase() {
        let invalidP95Values: [Any?] = [nil, NSNull(), -0.1, Double.nan, Double.infinity,
                                        -Double.infinity, true, false, "0.1"]
        for p95 in invalidP95Values {
            let invalid = measurement(p95: p95)
            let baseline = ImageGenerationPreviewGate.evaluate(baseline: invalid, concurrent: measurement())
            #expect(!baseline.passed)
            #expect(baseline.failureReasons == ["baseline-missing-or-invalid-p95"])
            let concurrent = ImageGenerationPreviewGate.evaluate(baseline: measurement(), concurrent: invalid)
            #expect(!concurrent.passed)
            #expect(concurrent.failureReasons == ["concurrent-missing-or-invalid-p95"])
        }
    }

    @Test func stoppingBeforeQueuedRendererStartsReportsMissingMeasurementAndFailsAllGatePositions() throws {
        let queue = DispatchQueue(label: "glowroom.preview-probe-test.\(UUID().uuidString)")
        let probe = ImageGenerationPreviewProbe(queue: queue)
        // Suspend this private serial queue before start so ordering, not elapsed
        // time or Swift cooperative-thread availability, guarantees zero renders.
        queue.suspend()
        var queueIsSuspended = true
        defer {
            if queueIsSuspended { queue.resume() }
            probe.release()
        }
        probe.start()
        probe.requestStop()
        queue.resume()
        queueIsSuspended = false
        let empty = probe.stop()
        #expect(empty["sampleCount"] as? Int == 0)
        #expect(empty["measurementStatus"] as? String == "missing-samples")
        expectNullLatencies(empty)
        expectNullLatencies(try jsonRoundTrip(empty))

        let emptyBaseline = ImageGenerationPreviewGate.evaluate(baseline: empty, concurrent: measurement())
        #expect(!emptyBaseline.passed)
        #expect(emptyBaseline.failureReasons == ["baseline-missing-or-invalid-sample-count"])
        let emptyConcurrent = ImageGenerationPreviewGate.evaluate(baseline: measurement(), concurrent: empty)
        #expect(!emptyConcurrent.passed)
        #expect(emptyConcurrent.failureReasons == ["concurrent-missing-or-invalid-sample-count"])
        let bothEmpty = ImageGenerationPreviewGate.evaluate(baseline: empty, concurrent: empty)
        #expect(!bothEmpty.passed)
        #expect(bothEmpty.failureReasons == ["baseline-missing-or-invalid-sample-count",
                                            "concurrent-missing-or-invalid-sample-count"])
    }

    private func measurement(sampleCount: Any? = 1, p95: Any? = 0.1) -> [String: Any] {
        var report: [String: Any] = [:]
        if let sampleCount { report["sampleCount"] = sampleCount }
        if let p95 { report["p95Seconds"] = p95 }
        return report
    }

    private func expectNullLatencies(_ report: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) {
        for key in latencyKeys {
            #expect(report[key] is NSNull, "\(key) must identify an absent latency", sourceLocation: sourceLocation)
        }
    }

    private func jsonRoundTrip(_ report: [String: Any]) throws -> [String: Any] {
        #expect(JSONSerialization.isValidJSONObject(report))
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
