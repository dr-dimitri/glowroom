import Foundation
import CoreImage
import CoreGraphics
import CoreFoundation
import Dispatch
import Darwin

/// Shared by the developer harness and model-free regressions. A missing or
/// invalid latency is JSON null, never a synthetic zero-second measurement.
struct ImageGenerationPreviewStatistics {
    let report: [String: Any]

    init(latencies: [Double], renderDurations: [Double]) {
        let valid = latencies.count == renderDurations.count &&
            latencies.allSatisfy { $0.isFinite && $0 >= 0 } &&
            renderDurations.allSatisfy { $0.isFinite && $0 >= 0 }
        // At most 2,500 samples: a separate worker pool would cost more than
        // this bounded sort, which runs after the background renderer drains.
        let sorted = valid ? latencies.sorted() : []
        func quantile(_ q: Double) -> Any {
            guard !sorted.isEmpty else { return NSNull() }
            return sorted[Int(ceil(Double(sorted.count - 1) * q))]
        }
        report = [
            "sampleCount": latencies.count,
            "measurementStatus": !valid ? "invalid-latencies" : (sorted.isEmpty ? "missing-samples" : "measured"),
            "p50Seconds": quantile(0.5), "p95Seconds": quantile(0.95), "p99Seconds": quantile(0.99),
            "maximumSeconds": sorted.last.map { $0 as Any } ?? NSNull(),
            "maximumRenderOnlySeconds": (valid ? renderDurations.max() : nil).map { $0 as Any } ?? NSNull()
        ]
    }
}

enum ImageGenerationPreviewGate {
    struct Result {
        let passed: Bool
        let failureReasons: [String]
    }

    static func evaluate(baseline: [String: Any], concurrent: [String: Any]) -> Result {
        var reasons: [String] = []
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let result = value.doubleValue
            return result.isFinite ? result : nil
        }
        func p95(_ measurement: [String: Any], phase: String) -> Double? {
            guard let count = number(measurement["sampleCount"]),
                  let integer = Int(exactly: count), integer > 0 else {
                reasons.append("\(phase)-missing-or-invalid-sample-count")
                return nil
            }
            guard let value = number(measurement["p95Seconds"]), value >= 0 else {
                reasons.append("\(phase)-missing-or-invalid-p95")
                return nil
            }
            return value
        }
        let baselineP95 = p95(baseline, phase: "baseline")
        let concurrentP95 = p95(concurrent, phase: "concurrent")
        if let concurrentP95 {
            if concurrentP95 > 0.25 { reasons.append("absolute-p95-exceeded") }
            if let baselineP95, concurrentP95 > baselineP95 * 2 { reasons.append("baseline-multiplier-exceeded") }
        }
        return Result(passed: reasons.isEmpty, failureReasons: reasons)
    }
}

private func previewNow() -> Double {
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
    return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
}

/// One bounded background renderer; Core Image chooses its execution backend.
/// The caller orders start/stop/release. Only requestStop may run concurrently;
/// worker-owned samples/context are read or released only after group.wait().
final class ImageGenerationPreviewProbe: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock(), group = DispatchGroup(), colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var context: CIContext? = CIContext(options: [.cacheIntermediates: false])
    private var stopped = true, samples: [Double] = [], renderSamples: [Double] = [], skipped = 0, checksum: UInt64 = 0
    private let image: CIImage

    /// An injected queue must be serial, just like the default renderer queue.
    init(queue: DispatchQueue = DispatchQueue(label: "picedit.synthetic-preview", qos: .userInitiated)) {
        self.queue = queue
        image = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 23,
            "inputColor0": CIColor(red: 0.2, green: 0.45, blue: 0.7),
            "inputColor1": CIColor(red: 0.8, green: 0.3, blue: 0.1)])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
    }

    private func render(_ index: Int) -> Double {
        let begin = previewNow()
        let processed = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": sin(Double(index) * 0.13) * 0.5])
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.9, "inputContrast": 1.05])
        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context!.render(processed, toBitmap: bytes.baseAddress!, rowBytes: 256 * 4,
                bounds: CGRect(x: 0, y: 0, width: 256, height: 256), format: .RGBA8, colorSpace: colorSpace)
        }
        for index in stride(from: 0, to: pixels.count, by: 4096) { checksum = (checksum &* 1099511628211) ^ UInt64(pixels[index]) }
        return previewNow() - begin
    }

    func start() {
        lock.lock(); stopped = false; samples = []; renderSamples = []; skipped = 0; checksum = 0; lock.unlock()
        group.enter(); queue.async {
            defer { self.group.leave() }
            let origin = previewNow(); var previous = -1
            while true {
                self.lock.lock(); let stop = self.stopped; self.lock.unlock(); if stop { break }
                let index = max(previous + 1, Int((previewNow() - origin) / 0.1))
                if previous >= 0 { self.skipped += max(0, index - previous - 1) }; previous = index
                let elapsed = autoreleasepool { self.render(index) }
                self.renderSamples.append(elapsed)
                self.samples.append(max(elapsed, previewNow() - (origin + Double(index) * 0.1)))
                if self.samples.count >= 2500 { break }
                let delay = origin + Double(index + 1) * 0.1 - previewNow()
                if delay > 0 { Thread.sleep(forTimeInterval: min(delay, 0.1)) }
            }
        }
    }

    func requestStop() { lock.lock(); stopped = true; lock.unlock() }

    func stop() -> [String: Any] {
        requestStop(); group.wait()
        var result = ImageGenerationPreviewStatistics(latencies: samples, renderDurations: renderSamples).report
        result.merge([
            "coalescedFrameCount": skipped, "checksum": String(checksum),
            "source": "procedural256x256-checkerboard", "targetIntervalSeconds": 0.1,
            "execution": "CIContext-auto-single-background-renderer", "actualPicEditUIOrRAWTest": false,
            "latencyDefinition": "scheduled-coalesced-request-to-render-return; includes scheduling and GPU wait"
        ]) { _, value in value }
        return result
    }

    func baseline() -> [String: Any] {
        for index in 0..<5 { _ = autoreleasepool { render(index) } }
        start(); Thread.sleep(forTimeInterval: 3); var value = stop(); value["discardedWarmupRenders"] = 5
        value["modelContextResidentButNoModelCompute"] = true; return value
    }

    func release() { context?.clearCaches(); context = nil }
}
