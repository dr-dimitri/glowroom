import Foundation
import Testing
@testable import Glowroom

@Suite("Independent bounded sharpening evaluation")
struct DarktableSharpenEvaluationTests {
    @Test func zeroIdentitySignedAlphaAndHDR() throws {
        let f = try DarktableSharpenFixtures.make(scene: "alpha-signed-hdr", acceptance: true, width: 80, height: 40)
        for variant in DarktableSharpenReference.Variant.allCases {
            let p = try DarktableSharpenReference.prepare(f.input, variant: variant)
            #expect(try DarktableSharpenReference.apply(p, amount: 0).sha256 == f.input.sha256)
            let output = try DarktableSharpenReference.apply(p, amount: 1)
            #expect(output.pixels.allSatisfy { $0.isFinite })
            for i in stride(from: 0, to: output.pixels.count, by: 4) {
                #expect(output.pixels[i + 3] == f.input.pixels[i + 3])
                if output.pixels[i + 3] > 0 {
                    #expect(output.pixels[i] < 0)
                    #expect(abs(output.pixels[i + 1] / output.pixels[i + 2] - 1.75) < 0.00001)
                } else { #expect(output.pixels[i] == 0) }
            }
            #expect(output.pixels.max()! > 1)
        }
    }
    @Test func constantAlphaBoundaryAndReproducibility() throws {
        var values = [Float](repeating: 0, count: 80 * 40 * 4)
        for i in 0..<(80 * 40) {
            let alpha: Float = i % 80 < 20 ? 0 : 0.4
            values[i * 4] = 0.3; values[i * 4 + 1] = 0.3; values[i * 4 + 2] = 0.3; values[i * 4 + 3] = alpha
        }
        let input = try AlgorithmEvaluationRaster(width: 80, height: 40, pixels: values)
        for variant in DarktableSharpenReference.Variant.allCases {
            let p = try DarktableSharpenReference.prepare(input, variant: variant, radius: 2)
            let a = try DarktableSharpenReference.apply(p, amount: 3)
            let b = try DarktableSharpenReference.apply(p, amount: 3)
            #expect(a.sha256 == b.sha256)
            #expect(zip(input.pixels, a.pixels).allSatisfy { abs($0.0 - $0.1) < 0.00001 })
        }
    }
    @Test func disjointSplitsAndMetricsDetectHalos() throws {
        let tuning = try DarktableSharpenFixtures.make(scene: "slanted-edge", acceptance: false, width: 80, height: 40)
        let acceptance = try DarktableSharpenFixtures.make(scene: "slanted-edge", acceptance: true, width: 80, height: 40)
        #expect(tuning.input.sha256 != acceptance.input.sha256)
        let unchanged = try DarktableSharpenMetrics.measure(acceptance.input, fixture: acceptance)
        #expect(unchanged["halo_total"]! < 0.00001)
        #expect(unchanged["halo_width_pixels"] == 0)
        var halo = acceptance.input
        for y in 8..<32 {
            let x = Int(DarktableSharpenFixtures.edgeX(y: y, width: 80, height: 40, acceptance: true)) + 8
            for c in 0..<3 { halo.pixels[(y * 80 + x) * 4 + c] = 0.7 }
        }
        let measured = try DarktableSharpenMetrics.measure(halo, fixture: acceptance)
        #expect(measured["overshoot"]! > 0.15)
        #expect(measured["halo_width_pixels"]! >= 1)
    }
    @Test func invalidAndCancelledWorkIsRejected() async throws {
        let input = try DarktableSharpenFixtures.make(scene: "fine-texture", acceptance: false, width: 80, height: 40).input
        #expect(throws: (any Error).self) { try DarktableSharpenReference.prepare(input, variant: .diffusion, radius: .nan) }
        #expect(throws: (any Error).self) { try DarktableSharpenReference.prepare(input, variant: .diffusion, scale: 0) }
        let prepared = try DarktableSharpenReference.prepare(input, variant: .multiscale)
        #expect(throws: (any Error).self) { try DarktableSharpenReference.apply(prepared, amount: 7) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DarktableSharpenReference.prepare(input, variant: .diffusion)
        }
        do { _ = try await task.value; Issue.record("Cancelled preparation returned a result") }
        catch is CancellationError { }
    }
    @Test func extremePortraitGeometryKeepsMeasuredEdgeInsideRaster() throws {
        let f = try DarktableSharpenFixtures.make(scene: "slanted-edge", acceptance: true, width: 64, height: 1024)
        let metrics = try DarktableSharpenMetrics.measure(f.input, fixture: f)
        #expect(metrics["edge_rows"] == 1008)
        #expect(metrics["edge_slope"]! > 0)
        #expect(abs(metrics["edge_slope"]! - DarktableSharpenMetrics.edgeSlope(f.input, acceptance: true)) < 1e-12)
        for y in [0, 512, 1023] {
            let center = DarktableSharpenFixtures.edgeX(y: y, width: 64, height: 1024, acceptance: true)
            #expect(center >= 24 && center <= 39)
        }
    }
    @Test func knownBlurredTruthAndIndependentNoiseSeeds() throws {
        let f = try DarktableSharpenFixtures.make(scene: "blurred-truth", acceptance: true, width: 80, height: 40)
        #expect(try DarktableSharpenMetrics.measure(f.input, fixture: f)["truth_rmse"]! > 0)
        let a = try DarktableSharpenFixtures.make(scene: "noisy-flat", acceptance: false, width: 80, height: 40)
        let b = try DarktableSharpenFixtures.make(scene: "noisy-flat", acceptance: true, width: 80, height: 40)
        #expect(a.input.sha256 != b.input.sha256)
        #expect(a.truth.sha256 == b.truth.sha256)
        #expect(try DarktableSharpenMetrics.measure(a.input, fixture: a)["noise_std"]! > 0.003)
    }
}
