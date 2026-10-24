import Foundation
import Testing
@testable import Glowroom

@Suite("Independent multiscale denoise #175")
struct MultiscaleDenoiseTests {
    typealias Candidate = MultiscaleDenoiseCandidate
    typealias Comparison = MultiscaleDenoiseComparison
    typealias Raster = AlgorithmEvaluationRaster
    @Test func opponentTransformIsInvertibleForSignedAndHDRValues() {
        let values: [SIMD3<Float>] = [.init(0, 0, 0), .init(-0.2, 0.4, 1.4), .init(2, 2, 2), .init(0.2, -0.1, 0.3)]
        for rgb in values {
            let out = Candidate.inverse(Candidate.forward(rgb))
            for c in 0..<3 { #expect(abs(out[c] - rgb[c]) < 0.000001) }
        }
        #expect(Candidate.soft(-0.03, threshold: 0.02) < 0)
        #expect(abs(Candidate.soft(-0.03, threshold: 0.02) + 0.01) < 0.000001)
        #expect(Candidate.soft(0.01, threshold: 0.02) == 0)
    }
    @Test func zeroIsExactAndTinySignedConstantRastersArePreserved() throws {
        for dimensions in [(1,1), (2,3), (32,24)] {
            let (w,h) = dimensions
            let input = try Raster(width: w, height: h, pixels: (0..<(w*h)).flatMap { _ in [Float(-0.1), 0.3, 2, 0.5] })
            #expect(try Candidate.render(input, luminance: 0, chroma: 0).sha256 == input.sha256)
            let output = try Candidate.render(input, luminance: 100, chroma: 100)
            for p in input.pixels.indices { #expect(abs(output.pixels[p] - input.pixels[p]) < 0.000001) }
        }
    }
    @Test func controlsChangeOnlyTheirOpponentComponentsAndCompose() throws {
        let f = try Comparison.make("texture", split: .acceptance, width: 64, height: 48), input = f.input
        let luma = try Candidate.render(input, luminance: 60, chroma: 0)
        let chroma = try Candidate.render(input, luminance: 0, chroma: 60)
        let joint = try Candidate.render(input, luminance: 60, chroma: 60)
        for p in stride(from: 0, to: input.pixels.count, by: 4) {
            func lc(_ r: Raster) -> SIMD3<Float> { Candidate.forward(SIMD3(r.pixels[p], r.pixels[p+1], r.pixels[p+2])) }
            let a = lc(input), b = lc(luma), c = lc(chroma), d = lc(joint)
            #expect(abs(a.y - b.y) < 0.000001 && abs(a.z - b.z) < 0.000001)
            #expect(abs(a.x - c.x) < 0.000001)
            for k in 0..<3 { #expect(abs(d[k] - (b[k] + c[k] - a[k])) < 0.000001) }
        }
    }
    @Test func matchingUsesIndependentSeedsAndBothNoiseComponents() throws {
        for scene in Comparison.sceneClasses {
            let a = try Comparison.make(scene, split: .tuning, width: 64, height: 48)
            let b = try Comparison.make(scene, split: .acceptance, width: 64, height: 48)
            #expect(a.seed != b.seed && a.input.sha256 != b.input.sha256)
            #expect(try #require(a.groundTruth).sha256 == #require(b.groundTruth).sha256)
            let out = try Candidate.render(b.input, luminance: 60, chroma: 60)
            let clean = try #require(b.groundTruth)
            for control in ["luminance", "chroma"] {
                #expect(try LightcraftDenoiseComparison.strength(noisy: b.input, clean: clean, output: out, control: control) > 0)
            }
        }
    }
    @Test func alphaAndHiddenPixelsRemainCanonicalAndSourceUnchanged() throws {
        let f = try Comparison.make("transparency", split: .acceptance, width: 64, height: 48), hash = f.input.sha256
        let out = try Candidate.render(f.input, luminance: 100, chroma: 100)
        for p in stride(from: 0, to: out.pixels.count, by: 4) {
            #expect(out.pixels[p+3] == f.input.pixels[p+3])
            if out.pixels[p+3] == 0 { #expect(out.pixels[p] == 0 && out.pixels[p+1] == 0 && out.pixels[p+2] == 0) }
        }
        #expect(f.input.sha256 == hash)
    }
    @Test func targetProfileSeparatesValidP3AndHDRFromSRGBCubeDiagnostic() throws {
        for scene in ["p3-dark", "hdr"] {
            let f = try Comparison.make(scene, split: .acceptance, width: 64, height: 48), clean = try #require(f.groundTruth)
            let metrics = try Comparison.measure(noisy: clean, clean: clean, output: clean, scene: scene)
            #expect(metrics["target_outside_fraction"] == 0)
            #expect(metrics["target_new_outside_fraction"] == 0)
            #expect(try #require(metrics["extended_srgb_cube_diagnostic_gamut_fraction"]) > 0)
        }
        let p3 = Comparison.target(.init(1.22494017628056 * 0.2 - 0.22494017628056 * 0.008,
                                         -0.04205695470969 * 0.2 + 1.04205695470969 * 0.008,
                                         -0.01963755459033 * 0.2 - 0.07863604555063 * 0.008 + 1.09827360014096 * 0.004), scene: "p3-dark")
        #expect(abs(p3.x - 0.2) < 0.0000001 && abs(p3.y - 0.008) < 0.0000001 && abs(p3.z - 0.004) < 0.0000001)
    }
    @Test func repeatedSourcesNeverReuseStaleStateAndCancellationReturnsNoResult() async throws {
        let a = try Comparison.make("color-lines", split: .acceptance, width: 256, height: 160).input
        let b = try Comparison.make("hdr", split: .acceptance, width: 256, height: 160).input
        let first = try Candidate.render(a, luminance: 60, chroma: 60)
        _ = try Candidate.render(b, luminance: 60, chroma: 60)
        #expect(try Candidate.render(a, luminance: 60, chroma: 60).sha256 == first.sha256)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try Candidate.render(a, luminance: 60, chroma: 60) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test func conservativeMemoryPreflightRejectsOverBudgetBeforeAllocation() throws {
        #expect(try Candidate.plannedPeakBytes(width: 4608, height: 3072, budgetBytes: 1_879_048_192) > 1_000_000_000)
        #expect(throws: Error.self) { _ = try Candidate.plannedPeakBytes(width: 8192, height: 4096) }
        #expect(throws: Error.self) { _ = try Candidate.plannedPeakBytes(width: 256, height: 160, budgetBytes: 1_000_000) }
        var hidden = try Raster(width: 1, height: 1, pixels: [0, 0, 0, 0]); hidden.pixels[0] = 0.4
        #expect(throws: Error.self) { _ = try Candidate.render(hidden, luminance: 0, chroma: 0) }
    }
    @Test func invalidControlsAndMutatedNonfiniteInputsAreRejected() throws {
        let input = try Raster(width: 1, height: 1, pixels: [0.1, 0.2, 0.3, 1])
        for value in [Double.nan, .infinity, -1, 101] {
            #expect(throws: Error.self) { _ = try Candidate.render(input, luminance: value, chroma: 0) }
        }
        var bad = input; bad.pixels[0] = .nan
        #expect(throws: Error.self) { _ = try Candidate.render(bad, luminance: 0, chroma: 0) }
    }
}
