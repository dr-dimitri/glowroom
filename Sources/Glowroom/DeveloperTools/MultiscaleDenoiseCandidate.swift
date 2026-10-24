import Foundation

/// Independently authored evaluation candidate for #175. No darktable/Lightcraft
/// code or constants are used. Three ordered undecimated edge-aware bands are
/// thresholded in an invertible linear D65 opponent space, never RGB/Y or Lab.
/// No production renderer calls this type.
enum MultiscaleDenoiseCandidate {
    typealias Raster = AlgorithmEvaluationRaster
    struct Parameters: Codable, Equatable, Sendable {
        let luminance: Double
        let chroma: Double
        // Frozen profile-free developed-raster units; not sensor variances.
        static let strides = [1, 2, 4]
        static let thresholds: [Float] = [0.04, 0.028, 0.018]
        static let lumaEdge: Float = 0.06
        static let chromaEdge: Float = 0.06
    }
    static func forward(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let y = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        return SIMD3(y, rgb.x - y, rgb.z - y)
    }
    static func inverse(_ lc: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(lc.x + lc.y, lc.x - (0.2126 * lc.y + 0.0722 * lc.z) / 0.7152, lc.x + lc.z)
    }
    static func soft(_ value: Float, threshold: Float) -> Float {
        copysign(max(0, abs(value) - threshold), value)
    }

    /// Conservative peak plan includes input/result, three scratch rasters,
    /// one possible canonicalization CoW copy and 64 MiB worker/array overhead.
    /// Limit the evaluation to at most one quarter of RAM and 1.75 GiB.
    static let memoryBudgetBytes = min(UInt64(1_879_048_192), ProcessInfo.processInfo.physicalMemory / 4)
    static func plannedPeakBytes(width: Int, height: Int, budgetBytes: UInt64 = memoryBudgetBytes) throws -> UInt64 {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw AlgorithmEvaluationMetricError.invalid("Invalid multiscale memory geometry")
        }
        let bytes = UInt64(width) * UInt64(height) * 96 + 64 * 1_024 * 1_024
        guard bytes <= budgetBytes else {
            throw AlgorithmEvaluationMetricError.invalid("Multiscale denoise evaluation memory budget exceeded")
        }
        return bytes
    }

    static func render(_ input: Raster, luminance: Double, chroma: Double) throws -> Raster {
        try LightcraftDenoiseComparison.validate(input)
        guard luminance.isFinite, chroma.isFinite, (0...100).contains(luminance), (0...100).contains(chroma) else {
            throw AlgorithmEvaluationMetricError.invalid("Invalid multiscale denoise parameter")
        }
        for p in stride(from: 0, to: input.pixels.count, by: 4) where input.pixels[p + 3] == 0 {
            guard input.pixels[p] == 0, input.pixels[p + 1] == 0, input.pixels[p + 2] == 0 else {
                throw AlgorithmEvaluationMetricError.invalid("Noncanonical hidden RGB in multiscale source")
            }
        }
        if luminance == 0 && chroma == 0 { return input }
        _ = try plannedPeakBytes(width: input.width, height: input.height)
        let width = input.width, height = input.height, count = input.pixels.count
        var current = [Float](repeating: 0, count: count)
        var scratch = current
        var removed = current
        try fill(&current, width: width, height: height) { y, row in
            for x in 0..<width {
                let p = (y * width + x) * 4, q = x * 4
                let lc = forward(.init(input.pixels[p], input.pixels[p + 1], input.pixels[p + 2]))
                row[q] = lc.x; row[q + 1] = lc.y; row[q + 2] = lc.z; row[q + 3] = input.pixels[p + 3]
            }
        }
        // Bands depend on their predecessor. Only disjoint pixel rows run in
        // parallel; the same two approximation buffers and residual are reused.
        for (band, stride) in Parameters.strides.enumerated() {
            let source = current
            try fill(&scratch, width: width, height: height) { y, row in
                for x in 0..<width {
                    let p = (y * width + x) * 4, q = x * 4
                    row[q + 3] = source[p + 3]
                    guard source[p + 3] > 0 else { row[q] = 0; row[q + 1] = 0; row[q + 2] = 0; continue }
                    var total: Float = 0, sum = SIMD3<Float>(repeating: 0)
                    for dy in -1...1 { for dx in -1...1 {
                        // Replicated borders; duplicate taps have their spatial
                        // weight and never read past tiny one-pixel rasters.
                        let nx = min(width - 1, max(0, x + dx * stride)), ny = min(height - 1, max(0, y + dy * stride))
                        let r = (ny * width + nx) * 4
                        guard source[r + 3] > 0 else { continue }
                        let dl = (source[r] - source[p]) / Parameters.lumaEdge
                        let da = (source[r + 1] - source[p + 1]) / Parameters.chromaEdge
                        let db = (source[r + 2] - source[p + 2]) / Parameters.chromaEdge
                        // Both L and C gate every low-pass: an isoluminant
                        // chromatic edge has its own protection.
                        let spatial: Float = Float((dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1))
                        let weight = spatial * source[r + 3] / ((1 + dl * dl) * (1 + da * da + db * db))
                        sum += SIMD3(source[r], source[r + 1], source[r + 2]) * weight; total += weight
                    } }
                    let value = sum / total
                    row[q] = value.x; row[q + 1] = value.y; row[q + 2] = value.z
                }
            }
            let low = scratch, threshold = Parameters.thresholds[band]
            let lumaAmount = Float(luminance / 100), chromaAmount = Float(chroma / 100)
            try fill(&removed, width: width, height: height) { y, row in
                for x in 0..<width {
                    let p = (y * width + x) * 4, q = x * 4
                    guard source[p + 3] > 0 else { continue }
                    for c in 0..<3 {
                        let detail = source[p + c] - low[p + c], amount = c == 0 ? lumaAmount : chromaAmount
                        row[q + c] += detail - soft(detail, threshold: threshold * amount)
                    }
                }
            }
            swap(&current, &scratch)
        }
        let residual = removed
        let result = try LightcraftToneFilters.rows(width: width * 4, height: height) { y, row in
            for x in 0..<width {
                let p = (y * width + x) * 4, q = x * 4, alpha = input.pixels[p + 3]
                row[q + 3] = alpha
                guard alpha > 0 else { continue }
                let delta = inverse(SIMD3(residual[p], residual[p + 1], residual[p + 2]))
                row[q] = input.pixels[p] - delta.x; row[q + 1] = input.pixels[p + 1] - delta.y; row[q + 2] = input.pixels[p + 2] - delta.z
            }
        }
        try Task.checkCancellation()
        return try Raster(width: width, height: height, pixels: result)
    }

    /// Reusable-buffer row executor, capped at four workers with cooperative
    /// cancellation. The synchronous caller owns the buffer through group wait.
    private static func fill(_ output: inout [Float], width: Int, height: Int,
                             _ body: @escaping @Sendable (Int, UnsafeMutableBufferPointer<Float>) -> Void) throws {
        try Task.checkCancellation()
        try output.withUnsafeMutableBufferPointer { buffer in
            let state = BufferState(buffer)
            if buffer.count < 65_536 || height < 2 {
                for y in 0..<height { try Task.checkCancellation(); body(y, state.row(y, width)) }
                return
            }
            let group = DispatchGroup(), workers = min(4, height, ProcessInfo.processInfo.activeProcessorCount)
            for worker in 0..<workers {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    for y in stride(from: worker, to: height, by: workers) {
                        if state.isCancelled { break }; body(y, state.row(y, width))
                    }
                }
            }
            while group.wait(timeout: .now() + .milliseconds(10)) == .timedOut { if Task.isCancelled { state.cancel() } }
            try Task.checkCancellation()
        }
    }
    private final class BufferState: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<Float>
        let lock = NSLock()
        private var cancelled = false
        init(_ buffer: UnsafeMutableBufferPointer<Float>) { self.buffer = buffer }
        func row(_ y: Int, _ width: Int) -> UnsafeMutableBufferPointer<Float> {
            UnsafeMutableBufferPointer(rebasing: buffer[(y * width * 4)..<((y + 1) * width * 4)])
        }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
}
