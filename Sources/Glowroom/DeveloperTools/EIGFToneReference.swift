import Foundation
import GlowroomCore

/// Independent, evaluation-only statistical reference for issue #173. Equations
/// are specified in docs/EIGF-TONE-EVALUATION.md; no darktable code is ported.
/// Uses only LC's existing bounded row executor, not its tone-base algorithm.
struct EIGFToneReference: Sendable {
    enum Basis: String, Codable, Sendable, CaseIterable { case simple, eigf }
    enum Failure: Error { case invalid(String), memoryBudget }
    static let processID = "eigf-tone-experiment-v1"
    static let floor: Float = 1e-7
    let basis: Basis
    let nativeLong: Int?
    let outputLong: Double?
    let memoryBudgetBytes: Int

    init(basis: Basis = .eigf, nativeLong: Int? = nil, outputLong: Double? = nil,
         memoryBudgetBytes: Int = 1_610_612_736) {
        self.basis = basis; self.nativeLong = nativeLong; self.outputLong = outputLong
        self.memoryBudgetBytes = memoryBudgetBytes
    }

    struct Identity: Equatable, Sendable {
        let sourceSHA256: String
        let width: Int, height: Int, nativeLong: Int
        let outputLong: Double
        let process: String
        let basis: Basis
        // The isolated reference accepts a complete upright raster, never a
        // partial ROI. A production cache would also need prefix/mask identity.
    }
    struct Prepared: Sendable {
        let input: AlgorithmEvaluationRaster
        let control: [Float]
        let identity: Identity
        let radius: Int
        let plannedPeakBytes: Int
    }

    func prepare(_ input: AlgorithmEvaluationRaster) throws -> Prepared {
        try validate(input)
        let (native, output, radius) = try geometry(input)
        // Includes retained input+output, all scalar temporaries, and the hash
        // boundary. CI/driver/process memory is separately measured by RSS.
        let estimate = input.width * input.height * 80
        guard estimate <= memoryBudgetBytes else { throw Failure.memoryBudget }
        let input = try AlgorithmEvaluationRaster(width: input.width, height: input.height, pixels: input.pixels)
        let alpha = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
            for x in 0..<input.width { row[x] = input.pixels[(y * input.width + x) * 4 + 3] }
        }
        let signal = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
            for x in 0..<input.width {
                let p = (y * input.width + x) * 4
                // A homogeneous nonnegative extension of linear Y: cancellation
                // between signed gamut coordinates cannot make colour vanish.
                row[x] = alpha[y * input.width + x] > 0 ? Self.energy(input.pixels[p], input.pixels[p + 1], input.pixels[p + 2]) : 0
            }
        }
        let meanAlpha = try box(alpha, width: input.width, height: input.height, radius: radius)
        let mean = try weightedMean(signal, alpha: alpha, meanAlpha: meanAlpha,
                                    width: input.width, height: input.height, radius: radius)
        let control: [Float]
        if basis == .simple { control = mean }
        else {
            let squares = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
                for x in 0..<input.width { let i = y * input.width + x; row[x] = signal[i] * signal[i] }
            }
            let second = try weightedMean(squares, alpha: alpha, meanAlpha: meanAlpha,
                                          width: input.width, height: input.height, radius: radius)
            control = try LightcraftToneFilters.rows(width: input.width, height: input.height) { y, row in
                for x in 0..<input.width {
                    let i = y * input.width + x
                    let variance = max(0, second[i] - mean[i] * mean[i])
                    let regularizer = Float(0.5) * max(signal[i] * signal[i], Self.floor * Self.floor)
                    let a = variance / (variance + regularizer)
                    // Deliberately no final coefficient averaging; this tests
                    // the exposure-normalized variance hypothesis in isolation.
                    row[x] = a * signal[i] + (1 - a) * mean[i]
                }
            }
        }
        guard control.allSatisfy(\.isFinite) else { throw Failure.invalid("Nonfinite EIGF statistics") }
        try Task.checkCancellation()
        return Prepared(input: input, control: control,
            identity: .init(sourceSHA256: input.sha256, width: input.width, height: input.height,
                nativeLong: native, outputLong: output, process: Self.processID, basis: basis),
            radius: radius, plannedPeakBytes: estimate)
    }

    func apply(_ prepared: Prepared, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        try validateSettings(settings)
        try Task.checkCancellation()
        let (native, output, _) = try geometry(prepared.input)
        guard prepared.identity.process == Self.processID, prepared.identity.basis == basis,
              prepared.identity.nativeLong == native, prepared.identity.outputLong == output,
              prepared.control.count == prepared.input.width * prepared.input.height else {
            throw Failure.invalid("Prepared EIGF identity mismatch")
        }
        return try gain(prepared.input, control: prepared.control, settings: settings)
    }

    func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        try validate(input); try validateSettings(settings)
        _ = try geometry(input)
        if settings.shadows == 0 && settings.highlights == 0 {
            // Neutral/EV-only renders allocate no spatial base.
            return try gain(input, control: nil, settings: settings)
        }
        return try apply(prepare(input), settings: settings)
    }

    static func energy(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * abs(r) + 0.7152 * abs(g) + 0.0722 * abs(b)
    }

    private func gain(_ input: AlgorithmEvaluationRaster, control: [Float]?, settings: EditSettings) throws -> AlgorithmEvaluationRaster {
        let s = settings.normalized
        let result = try LightcraftToneFilters.rows(width: input.width * 4, height: input.height) { y, row in
            for x in 0..<input.width {
                let i = y * input.width + x, p = i * 4, q = x * 4
                let alpha = input.pixels[p + 3]
                row[q + 3] = alpha
                guard alpha > 0 else { continue }
                let ev = control.map { log2(max(Self.floor, $0[i]) / 0.18) } ?? 0
                let shadowWeight = 1 - Self.smooth(-6, 0, ev)
                let highlightWeight = Self.smooth(-1, 3, ev)
                // Positive, bounded and monotone in each slider at fixed base.
                // Base selection precedes EV; exposure is applied exactly once.
                let localEV = min(4, max(-4, 2 * Float(s.shadows / 100) * shadowWeight
                    + 2 * Float(s.highlights / 100) * highlightWeight))
                let factor = exp2(localEV + Float(s.exposure))
                for channel in 0..<3 { row[q + channel] = input.pixels[p + channel] * factor }
            }
        }
        guard result.allSatisfy(\.isFinite) else { throw Failure.invalid("Unreachable finite EIGF gain") }
        try Task.checkCancellation()
        return try .init(width: input.width, height: input.height, pixels: result)
    }

    private static func smooth(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }

    private func validateSettings(_ s: EditSettings) throws {
        guard s.toneProcessingVersion == .consistentV2,
              [s.shadows, s.highlights, s.exposure].allSatisfy(\.isFinite) else {
            throw Failure.invalid("EIGF requires V2 and finite tone controls")
        }
        var expected = EditSettings.neutral
        expected.toneProcessingVersion = .consistentV2
        expected.shadows = s.shadows; expected.highlights = s.highlights; expected.exposure = s.exposure
        guard s == expected else {
            throw Failure.invalid("Isolated EIGF accepts only Shadows/Highlights/Exposure; no silent double application of other stages")
        }
    }

    private func validate(_ input: AlgorithmEvaluationRaster) throws {
        guard input.width > 0, input.height > 0, input.width <= 16_384, input.height <= 16_384,
              input.width * input.height <= 32 * 1_024 * 1_024,
              input.pixels.count == input.width * input.height * 4,
              input.pixels.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }),
              stride(from: 3, to: input.pixels.count, by: 4).allSatisfy({ (0...1).contains(input.pixels[$0]) }) else {
            throw Failure.invalid("Invalid or unsupported EIGF Float raster")
        }
        try Task.checkCancellation()
    }

    private func geometry(_ input: AlgorithmEvaluationRaster) throws -> (Int, Double, Int) {
        let native = nativeLong ?? max(input.width, input.height)
        let output = outputLong ?? Double(max(input.width, input.height))
        guard native > 0, native <= 1_000_000, output.isFinite, output > 0, output <= 1_000_000 else {
            throw Failure.invalid("Invalid EIGF native geometry")
        }
        let nativeRadius = Double(native) * 0.015
        let radius = max(1, min(max(input.width, input.height), Int((nativeRadius * output / Double(native)).rounded())))
        return (native, output, radius)
    }

    private func weightedMean(_ p: [Float], alpha: [Float], meanAlpha: [Float], width: Int, height: Int, radius: Int) throws -> [Float] {
        let weighted = try LightcraftToneFilters.rows(width: width, height: height) { y, row in
            for x in 0..<width { let i = y * width + x; row[x] = p[i] * alpha[i] }
        }
        let numerator = try box(weighted, width: width, height: height, radius: radius)
        return try LightcraftToneFilters.rows(width: width, height: height) { y, row in
            for x in 0..<width { let i = y * width + x; row[x] = meanAlpha[i] > 1e-12 ? numerator[i] / meanAlpha[i] : 0 }
        }
    }

    /// Separable replicated-edge box mean, Double accumulation for stable
    /// variance on nearly constant Float planes. Independent rows/columns use
    /// the existing at-most-four-worker executor, without nested pools.
    private func box(_ p: [Float], width: Int, height: Int, radius: Int) throws -> [Float] {
        let denominator = Double(radius * 2 + 1)
        let horizontal = try LightcraftToneFilters.rows(width: width, height: height) { y, row in
            let start = y * width
            var sum = (-radius...radius).reduce(0.0) { $0 + Double(p[start + min(width - 1, max(0, $1))]) }
            for x in 0..<width {
                row[x] = Float(sum / denominator)
                sum += Double(p[start + min(width - 1, x + radius + 1)]) - Double(p[start + max(0, x - radius)])
            }
        }
        let transposed = try LightcraftToneFilters.rows(width: height, height: width) { x, column in
            var sum = (-radius...radius).reduce(0.0) { $0 + Double(horizontal[min(height - 1, max(0, $1)) * width + x]) }
            for y in 0..<height {
                column[y] = Float(sum / denominator)
                sum += Double(horizontal[min(height - 1, y + radius + 1) * width + x]) - Double(horizontal[max(0, y - radius) * width + x])
            }
        }
        return try LightcraftToneFilters.rows(width: width, height: height) { y, row in
            for x in 0..<width { row[x] = transposed[x * height + y] }
        }
    }
}
