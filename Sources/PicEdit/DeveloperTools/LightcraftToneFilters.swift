import Foundation

// Developer-only Swift adaptation of Lightcraft at
// f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15:
// crates/pipeline/src/local.rs (guided*, median_hv, tone_base), and
// crates/raster/src/{blur,resample}.rs. License and adaptations are recorded in
// tools/lightcraft-evaluation/THIRD-PARTY-NOTICES.txt.
// Opaque planes retain the source's Float arithmetic, tap order and borders.
// Coverage weighting is a PicEdit adaptation, not part of the RGB-only source.
enum LightcraftToneFilters {
    struct Plane: Sendable {
        let width: Int
        let height: Int
        let values: [Float]

        init(width: Int, height: Int, values: [Float]) {
            self.width = width; self.height = height; self.values = values
        }
    }

    enum Filter { case box, bilinear }

    static func validate(_ p: Plane) throws {
        guard p.width > 0, p.height > 0, p.width <= 16_384, p.height <= 16_384,
              p.width * p.height <= 32 * 1_024 * 1_024,
              p.values.count == p.width * p.height, p.values.allSatisfy(\.isFinite) else {
            throw LightcraftToneReference.Failure.invalid("Invalid tone plane")
        }
        try Task.checkCancellation()
    }

    static func boxRadii(sigma: Float) -> [Int] {
        let sigma = sigma.isNaN ? 0 : min(65_536, max(0, sigma))
        let n: Float = 3
        let ideal = (12 * sigma * sigma / n + 1).squareRoot()
        var lower = Int(ideal.rounded(.down))
        if lower % 2 == 0 { lower -= 1 }
        let upper = lower + 2
        let middle = (12 * sigma * sigma - n * Float(Int64(lower) * Int64(lower)) - 4 * n * Float(lower) - 3 * n)
            / (-4 * Float(lower) - 4)
        let split = Int(middle.rounded(.toNearestOrAwayFromZero))
        return (0..<3).map { max(0, (($0 < split ? lower : upper) - 1) / 2) }
    }

    static func gaussian(_ p: Plane, sigma: Float) throws -> Plane {
        try validate(p)
        guard !sigma.isNaN, sigma > 0.3 else { return p }
        let radii = boxRadii(sigma: min(sigma, max(1, Float(max(p.width, p.height)) * 2)))
        let width = p.width, height = p.height
        var a = try rows(width: width, height: height) { y, row in
            var source = Array(p.values[(y * width)..<((y + 1) * width)])
            for radius in radii where radius > 0 {
                let old = source
                let inverse = 1 / Float(2 * radius + 1)
                var sum: Float = 0
                for i in 0...(2 * radius) { sum += old[min(width - 1, max(0, i - radius))] }
                for x in 0..<width {
                    source[x] = sum * inverse
                    sum = sum + old[min(width - 1, x + radius + 1)] - old[max(0, x - radius)]
                }
            }
            for x in 0..<width { row[x] = source[x] }
        }
        for radius in radii where radius > 0 {
            let source = a
            // Lightcraft re-primes each 32-row band. Keeping that boundary also
            // preserves its floating-point rounding, independently of workers.
            let bands = (height + 31) / 32
            a = try elements(count: width * height, jobs: bands) { band, output in
                let start = band * 32, end = min(height, start + 32)
                let inverse = 1 / Float(2 * radius + 1)
                var sum = [Float](repeating: 0, count: width)
                for i in 0...(2 * radius) {
                    let offset = min(height - 1, max(0, start + i - radius)) * width
                    for x in 0..<width { sum[x] += source[offset + x] }
                }
                for y in start..<end {
                    let add = min(height - 1, y + radius + 1) * width
                    let subtract = max(0, y - radius) * width
                    for x in 0..<width {
                        output[y * width + x] = sum[x] * inverse
                        sum[x] = sum[x] + source[add + x] - source[subtract + x]
                    }
                }
            }
        }
        return Plane(width: width, height: height, values: a)
    }

    /// Common LC-03/LC-04 normalized convolution. The opaque path retains the
    /// pinned arithmetic; uncovered pixels cannot contribute hidden colour.
    static func gaussian(_ p: Plane, sigma: Float, coverage: Plane?) throws -> Plane {
        try validate(p)
        try validateCoverage(coverage, for: p)
        let blurredCoverage = try coverage.map { try gaussian($0, sigma: sigma) }
        return try weightedGaussian(p, sigma: sigma, coverage: coverage, blurredCoverage: blurredCoverage)
    }

    static func resize(_ p: Plane, width: Int, height: Int, filter: Filter) throws -> Plane {
        try validate(p)
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32 * 1_024 * 1_024 else {
            throw LightcraftToneReference.Failure.invalid("Invalid resize geometry")
        }
        if p.width == width, p.height == height { return p }
        let horizontal = weights(source: p.width, destination: width, filter: filter)
        let temporary = try rows(width: width, height: p.height) { y, row in
            for x in 0..<width {
                let tap = horizontal[x]
                var value: Float = 0
                for k in tap.values.indices { value += p.values[y * p.width + tap.first + k] * tap.values[k] }
                row[x] = value
            }
        }
        let vertical = weights(source: p.height, destination: height, filter: filter)
        let output = try rows(width: width, height: height) { y, row in
            let tap = vertical[y]
            for k in tap.values.indices {
                let offset = (tap.first + k) * width
                for x in 0..<width { row[x] += temporary[offset + x] * tap.values[k] }
            }
        }
        return Plane(width: width, height: height, values: output)
    }

    private struct Tap: Sendable { let first: Int; let values: [Float] }

    private static func weights(source: Int, destination: Int, filter: Filter) -> [Tap] {
        let scale = Float(source) / Float(destination), filterScale = max(1, scale)
        let support: Float = (filter == .box ? 0.5 : 1) * filterScale
        return (0..<destination).map { i in
            let center = (Float(i) + 0.5) * scale
            let low = max(0, Int((center - support).rounded(.down)))
            let high = min(source, Int((center + support).rounded(.up)))
            var values = (low..<high).map { j -> Float in
                let distance = abs((Float(j) + 0.5 - center) / filterScale)
                return filter == .box ? (distance <= 0.5 ? 1 : 0) : max(0, 1 - distance)
            }
            let sum = values.reduce(Float(0), +)
            if abs(sum) > 1e-8 {
                for j in values.indices { values[j] /= sum }
            } else if !values.isEmpty {
                let inverse = 1 / Float(values.count)
                for j in values.indices { values[j] = inverse }
            }
            return Tap(first: low, values: values)
        }
    }

    static func medianHV(_ p: Plane, radius: Int, coverage: Plane? = nil) throws -> Plane {
        try validate(p)
        try validateCoverage(coverage, for: p)
        guard (0...24).contains(radius) else { throw LightcraftToneReference.Failure.invalid("Invalid median radius") }
        if radius == 0 { return p }
        if coverage == nil {
            func medianRows(_ source: Plane) throws -> Plane {
                let values = try rows(width: source.width, height: source.height) { y, row in
                    let offset = y * source.width
                    func at(_ x: Int) -> Float { source.values[offset + min(source.width - 1, max(0, x))] }
                    func ordered(_ a: Float, _ b: Float) -> Bool {
                        a < b || (a == b && a.sign == .minus && b.sign == .plus)
                    }
                    var window = (-radius...radius).map(at).sorted(by: ordered)
                    func insertionIndex(_ value: Float) -> Int {
                        var low = 0, high = window.count
                        while low < high {
                            let middle = (low + high) / 2
                            if ordered(window[middle], value) { low = middle + 1 } else { high = middle }
                        }
                        return low
                    }
                    for x in 0..<source.width {
                        row[x] = window[radius]
                        let old = at(x - radius), new = at(x + radius + 1)
                        if old.bitPattern != new.bitPattern {
                            window.remove(at: insertionIndex(old))
                            window.insert(new, at: insertionIndex(new))
                        }
                    }
                }
                return Plane(width: source.width, height: source.height, values: values)
            }
            func transpose(_ source: Plane) throws -> Plane {
                let values = try rows(width: source.height, height: source.width) { x, row in
                    for y in 0..<source.height { row[y] = source.values[y * source.width + x] }
                }
                return Plane(width: source.height, height: source.width, values: values)
            }
            var current = try medianRows(p)
            current = try transpose(current)
            current = try medianRows(current)
            return try transpose(current)
        }
        guard let coverage else { return p }
        func pass(_ source: Plane, vertical: Bool) throws -> Plane {
            let output = try rows(width: source.width, height: source.height) { y, row in
                for x in 0..<source.width {
                    var taps: [(value: Float, weight: Float)] = []
                    var total: Float = 0
                    for k in -radius...radius {
                        let sx = vertical ? x : min(source.width - 1, max(0, x + k))
                        let sy = vertical ? min(source.height - 1, max(0, y + k)) : y
                        let offset = sy * source.width + sx, weight = coverage.values[offset]
                        if weight > 0 { taps.append((source.values[offset], weight)); total += weight }
                    }
                    taps.sort { $0.value < $1.value }
                    var sum: Float = 0, value: Float = 0
                    for tap in taps {
                        sum += tap.weight
                        if sum >= total * 0.5 { value = tap.value; break }
                    }
                    row[x] = value
                }
            }
            return Plane(width: source.width, height: source.height, values: output)
        }
        let horizontal = try pass(p, vertical: false)
        return try pass(horizontal, vertical: true)
    }

    static func guidedFastStep(sigma: Float) -> Int {
        guard sigma.isFinite else { return sigma > 0 ? 16 : 1 }
        return Int(min(16, max(1, (sigma / 3).rounded(.down))))
    }

    static func toneBase(_ p: Plane, sigma: Float, detail: Int, coverage: Plane? = nil) throws -> Plane {
        let median = try medianHV(p, radius: detail, coverage: coverage)
        return try guidedFast(median, sigma: sigma, epsilon: 0.35, coverage: coverage)
    }

    static func guidedFast(_ p: Plane, sigma: Float, epsilon: Float, coverage: Plane? = nil) throws -> Plane {
        try validate(p)
        try validateCoverage(coverage, for: p)
        guard sigma.isFinite, sigma >= 0, epsilon.isFinite, epsilon > 0 else {
            throw LightcraftToneReference.Failure.invalid("Invalid guided-filter parameters")
        }
        let step = guidedFastStep(sigma: sigma)
        let low: Plane, lowCoverage: Plane?
        if step > 1 {
            let width = max(1, (p.width + step - 1) / step), height = max(1, (p.height + step - 1) / step)
            lowCoverage = try coverage.map { try resize($0, width: width, height: height, filter: .box) }
            low = try weightedResize(p, coverage: coverage, resizedCoverage: lowCoverage, width: width, height: height, filter: .box)
        } else { low = p; lowCoverage = coverage }
        let localSigma = sigma / Float(step)
        let blurredCoverage = try lowCoverage.map { try gaussian($0, sigma: localSigma) }
        // Each blur uses the same bounded row pool; independent blur pairs stay
        // serial to avoid nested pools and simultaneously retaining more planes.
        let mean = try weightedGaussian(low, sigma: localSigma, coverage: lowCoverage, blurredCoverage: blurredCoverage)
        let squared = try map(low) { $0 * $0 }
        let correlation = try weightedGaussian(squared, sigma: localSigma, coverage: lowCoverage, blurredCoverage: blurredCoverage)
        let a = try zip(correlation, mean) { c, m in
            let variance = max(0, c - m * m)
            return variance / (variance + epsilon)
        }
        let b = try zip(mean, a) { m, a in m - a * m }
        let meanA = try weightedGaussian(a, sigma: localSigma, coverage: lowCoverage, blurredCoverage: blurredCoverage)
        let meanB = try weightedGaussian(b, sigma: localSigma, coverage: lowCoverage, blurredCoverage: blurredCoverage)
        let upA: Plane, upB: Plane
        if step > 1 {
            let upCoverage = try lowCoverage.map { try resize($0, width: p.width, height: p.height, filter: .bilinear) }
            upA = try weightedResize(meanA, coverage: lowCoverage, resizedCoverage: upCoverage,
                                     width: p.width, height: p.height, filter: .bilinear)
            upB = try weightedResize(meanB, coverage: lowCoverage, resizedCoverage: upCoverage,
                                     width: p.width, height: p.height, filter: .bilinear)
        } else { upA = meanA; upB = meanB }
        let output = try rows(width: p.width, height: p.height) { y, row in
            for x in 0..<p.width {
                let i = y * p.width + x
                row[x] = upA.values[i] * p.values[i] + upB.values[i]
            }
        }
        return Plane(width: p.width, height: p.height, values: output)
    }

    private static func weightedGaussian(_ p: Plane, sigma: Float, coverage: Plane?, blurredCoverage: Plane?) throws -> Plane {
        guard let coverage, let blurredCoverage else { return try gaussian(p, sigma: sigma) }
        let weighted = try zip(p, coverage) { $0 * $1 }
        return try divide(gaussian(weighted, sigma: sigma), by: blurredCoverage)
    }

    private static func weightedResize(_ p: Plane, coverage: Plane?, resizedCoverage: Plane?, width: Int, height: Int,
                                       filter: Filter) throws -> Plane {
        guard let coverage, let resizedCoverage else { return try resize(p, width: width, height: height, filter: filter) }
        let weighted = try zip(p, coverage) { $0 * $1 }
        return try divide(resize(weighted, width: width, height: height, filter: filter), by: resizedCoverage)
    }

    private static func divide(_ numerator: Plane, by denominator: Plane) throws -> Plane {
        try zip(numerator, denominator) { value, weight in weight > 1e-12 ? value / weight : 0 }
    }

    private static func validateCoverage(_ coverage: Plane?, for p: Plane) throws {
        guard let coverage else { return }
        try validate(coverage)
        guard coverage.width == p.width, coverage.height == p.height,
              coverage.values.allSatisfy({ (0...1).contains($0) }) else {
            throw LightcraftToneReference.Failure.invalid("Invalid alpha coverage")
        }
    }

    private static func map(_ p: Plane, _ body: @escaping @Sendable (Float) -> Float) throws -> Plane {
        let output = try rows(width: p.width, height: p.height) { y, row in
            for x in 0..<p.width { row[x] = body(p.values[y * p.width + x]) }
        }
        return Plane(width: p.width, height: p.height, values: output)
    }

    private static func zip(_ p: Plane, _ q: Plane, _ body: @escaping @Sendable (Float, Float) -> Float) throws -> Plane {
        let output = try rows(width: p.width, height: p.height) { y, row in
            for x in 0..<p.width {
                let i = y * p.width + x
                row[x] = body(p.values[i], q.values[i])
            }
        }
        return Plane(width: p.width, height: p.height, values: output)
    }

    static func rows(width: Int, height: Int, _ body: @escaping @Sendable (Int, UnsafeMutableBufferPointer<Float>) -> Void) throws -> [Float] {
        try elements(count: width * height, jobs: height) { y, output in
            body(y, UnsafeMutableBufferPointer(rebasing: output[(y * width)..<((y + 1) * width)]))
        }
    }

    /// Synchronous CPU reference, owned by the harness's background task. Four
    /// workers at most, no nested parallel calls, and no per-pixel tasks. The
    /// caller monitors Swift cancellation while GCD workers own disjoint bands.
    private static func elements(count: Int, jobs: Int,
                                 _ body: @escaping @Sendable (Int, UnsafeMutableBufferPointer<Float>) -> Void) throws -> [Float] {
        try Task.checkCancellation()
        var output = [Float](repeating: 0, count: count)
        try output.withUnsafeMutableBufferPointer { buffer in
            if count < 65_536 || jobs < 2 {
                for job in 0..<jobs { try Task.checkCancellation(); body(job, buffer) }
                return
            }
            let state = WorkState(buffer: buffer)
            let group = DispatchGroup()
            let workers = min(4, ProcessInfo.processInfo.activeProcessorCount, jobs)
            for worker in 0..<workers {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    for job in stride(from: worker, to: jobs, by: workers) {
                        if state.isCancelled { break }
                        body(job, state.buffer)
                    }
                }
            }
            while group.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
                if Task.isCancelled { state.cancel() }
            }
            try Task.checkCancellation()
        }
        return output
    }

    /// The array buffer outlives all workers, and their row/band ranges never
    /// overlap. Only cancellation is shared mutable state; the lock protects it.
    private final class WorkState: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<Float>
        private let lock = NSLock()
        private var cancelled = false
        init(buffer: UnsafeMutableBufferPointer<Float>) { self.buffer = buffer }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
}
