import Foundation
import Testing
import GlowroomCore
@testable import Glowroom

@Suite("Independent EIGF tone evaluation contracts")
struct EIGFToneReferenceTests {
    @Test func neutralAndExposureAllocateNoSpatialBasis() throws {
        let input = try raster([0.03, 0.18, 2])
        let reference = EIGFToneReference(memoryBudgetBytes: 0)
        var s = settings()
        #expect(try reference.render(input, settings: s).pixels == input.pixels)
        s.exposure = 1
        let output = try reference.render(input, settings: s)
        for p in stride(from: 0, to: input.pixels.count, by: 4) {
            for c in 0..<3 { #expect(output.pixels[p + c] == input.pixels[p + c] * 2) }
            #expect(output.pixels[p + 3] == input.pixels[p + 3])
        }
        s.shadows = 20
        #expect(throws: EIGFToneReference.Failure.self) { _ = try reference.render(input, settings: s) }
    }

    @Test func baseIsExposureCovariantAwayFromFloor() throws {
        let input = try raster((0..<85).map { Float(($0 * 11) % 29 + 1) / 35 }, width: 17)
        for basis in EIGFToneReference.Basis.allCases {
            let reference = EIGFToneReference(basis: basis), normal = try reference.prepare(input)
            for scale: Float in [0.125, 0.5, 2, 8] {
                var scaled = input
                for p in stride(from: 0, to: input.pixels.count, by: 4) { for c in 0..<3 { scaled.pixels[p + c] *= scale } }
                let transformed = try reference.prepare(scaled)
                let error = zip(normal.control, transformed.control).map { abs($0 * scale - $1) }.max()!
                #expect(error <= 0.00001 * max(1, scale))
            }
        }
    }

    @Test func simpleBoxHasExplicitReplicatedBordersAndAlphaNormalization() throws {
        let input = try raster([0.03, 0.3, 0.9])
        let simple = try EIGFToneReference(basis: .simple).prepare(input)
        #expect(simple.radius == 1)
        for (value, expected) in zip(simple.control, [Float(0.12), 0.41, 0.7]) {
            #expect(abs(value - expected) < 0.000001)
        }
        var transparent = try AlgorithmEvaluationRaster(width: 3, height: 1,
            pixels: [0.03, 0.03, 0.03, 1, 0.03, 0.03, 0.03, 0.5, 0, 0, 0, 0])
        transparent.pixels[8] = 100; transparent.pixels[9] = -20
        for basis in EIGFToneReference.Basis.allCases {
            let result = try EIGFToneReference(basis: basis).prepare(transparent)
            // Fully hidden pixels have no defined visible control brightness;
            // the EIGF floor may alter their coefficient. They cannot feed the
            // visible statistics or gain, and their output RGB stays zero.
            for i in 0..<2 { #expect(abs(result.control[i] - 0.03) < 0.000001) }
            #expect(result.control[2].isFinite)
            #expect(result.input.pixels[8] == 0 && result.input.pixels[9] == 0)
        }
    }

    @Test func signedGamutHDRAndAlphaSurviveOneCommonFiniteGain() throws {
        let input = try AlgorithmEvaluationRaster(width: 4, height: 1,
            pixels: [1.4, -0.25, 0.7, 0.5, -0.1, 0.6, 1.2, 1, 2, 2, 2, 1, 0, 0, 0, 0.125])
        var s = settings(); s.shadows = 30; s.highlights = -40
        let output = try EIGFToneReference().render(input, settings: s)
        for p in stride(from: 0, to: 12, by: 4) {
            let gain = output.pixels[p] / input.pixels[p]
            #expect(gain > 0 && gain <= 16)
            for c in 1..<3 { #expect(abs(output.pixels[p + c] - input.pixels[p + c] * gain) < 0.000005) }
        }
        for p in stride(from: 3, to: input.pixels.count, by: 4) { #expect(output.pixels[p] == input.pixels[p]) }
        #expect(output.pixels[1] < 0 && output.pixels[4] < 0)
        #expect(output.pixels.allSatisfy { $0.isFinite })
        #expect(output.pixels[12] == 0)
        #expect(EIGFToneReference.energy(-0.1, 0.6, 1.2) > 0)
    }

    @Test func strengthsAreMonotoneAndCachedBasePrecedesExposure() throws {
        let input = try raster([0.003, 0.03, 0.18, 0.7, 2])
        let reference = EIGFToneReference(), prepared = try reference.prepare(input)
        for key in [\EditSettings.shadows, \.highlights] {
            var previous = [Float](repeating: -.infinity, count: input.pixels.count)
            for value in [-100.0, -40, 0, 20, 100] {
                var s = settings(); s[keyPath: key] = value
                let output = try reference.apply(prepared, settings: s)
                for p in stride(from: 0, to: input.pixels.count, by: 4) {
                    #expect(output.pixels[p] >= previous[p]); previous[p] = output.pixels[p]
                }
                s.exposure = 1
                let exposed = try reference.apply(prepared, settings: s)
                #expect(try reference.render(input, settings: s).pixels == exposed.pixels)
                for p in stride(from: 0, to: input.pixels.count, by: 4) {
                    // Adding EV to a Float exponent can round once before
                    // exp2; compare within four Float relative ulps.
                    let expected = output.pixels[p] * 2
                    #expect(abs(exposed.pixels[p] - expected) <= 4 * Float.ulpOfOne * max(1, abs(expected)))
                }
            }
        }
    }

    @Test func finiteBoundaryFloorsAndNullEnergyAreExplicit() throws {
        let input = try raster([0, 1e-12, 1e-8, 1e-7, 1e-6])
        var s = settings(); s.shadows = 100; s.highlights = -100
        let output = try EIGFToneReference().render(input, settings: s)
        #expect(output.pixels.allSatisfy { $0.isFinite })
        #expect(output.pixels[0] == 0)
        // The absolute floor is intentionally not claimed exposure invariant.
        let near = try EIGFToneReference().prepare(input)
        #expect(near.control.allSatisfy { $0 >= 0 && $0.isFinite })
        for bad: Float in [.nan, .infinity, -.infinity, 1e20] {
            var invalid = input; invalid.pixels[0] = bad
            #expect(throws: EIGFToneReference.Failure.self) { _ = try EIGFToneReference().prepare(invalid) }
        }
    }

    @Test func immutableIdentityRejectsOtherBasisGeometryAndStages() throws {
        let input = try raster([0.03, 0.18, 0.9])
        let reference = EIGFToneReference(nativeLong: 6000, outputLong: 300)
        let prepared = try reference.prepare(input)
        #expect(prepared.identity.sourceSHA256 == input.sha256)
        #expect(prepared.identity.nativeLong == 6000)
        #expect(prepared.radius == 3, "Radius is bounded to the actual raster's long edge")
        #expect(throws: EIGFToneReference.Failure.self) {
            _ = try EIGFToneReference(basis: .simple, nativeLong: 6000, outputLong: 300).apply(prepared, settings: settings())
        }
        #expect(throws: EIGFToneReference.Failure.self) {
            _ = try EIGFToneReference(nativeLong: 4000, outputLong: 300).apply(prepared, settings: settings())
        }
        for invalid in [Double.nan, .infinity, -1, 0] {
            #expect(throws: EIGFToneReference.Failure.self) { _ = try EIGFToneReference(outputLong: invalid).prepare(input) }
        }
        var legacy = settings(); legacy.toneProcessingVersion = .legacyV1
        #expect(throws: EIGFToneReference.Failure.self) { _ = try reference.apply(prepared, settings: legacy) }
        for key in [\EditSettings.contrast, \.whites, \.blacks, \.naturalBalanceAmount, \.autoToneAmount, \.clarity] {
            var unsupported = settings(); unsupported[keyPath: key] = 1
            #expect(throws: EIGFToneReference.Failure.self) { _ = try reference.apply(prepared, settings: unsupported) }
        }
    }

    @Test func cancellationAndRapidSelectionKeepSnapshotsSeparate() async throws {
        let a = try raster([0.03, 0.18, 0.9]), b = try raster([0.02, 0.3, 2])
        let reference = EIGFToneReference()
        async let aPrepared = reference.prepare(a)
        async let bPrepared = reference.prepare(b)
        let (pa, pb) = try await (aPrepared, bPrepared)
        var s = settings(); s.shadows = 40
        let frozen = s
        for (input, prepared) in [(a, pa), (b, pb), (a, pa)] {
            #expect(try reference.apply(prepared, settings: frozen).sha256 == reference.render(input, settings: frozen).sha256)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try reference.apply(pa, settings: frozen)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        let cancelledPreparation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try reference.prepare(a)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelledPreparation.value }
    }

    @Test func frozenManifestAndAdditionalProfileFixturesAreIndependent() throws {
        let m = try EIGFToneComparison.Manifest.load(manifestURL)
        #expect(m.sceneClasses.count == 12)
        let p3 = try EIGFToneComparison.fixture("p3", split: .acceptance, width: 64, height: 40).input
        #expect(p3.pixels.contains { $0 < 0 })
        #expect(EIGFToneComparison.targetGamutIncrease(baseline: p3, candidate: p3, p3: true) == 0)
        var boosted = p3
        for p in stride(from: 0, to: p3.pixels.count, by: 4) { for c in 0..<3 { boosted.pixels[p + c] *= 4 } }
        #expect(EIGFToneComparison.targetGamutIncrease(baseline: p3, candidate: boosted, p3: true) > 0.02)
        let hdr = try EIGFToneComparison.fixture("hdr", split: .acceptance, width: 64, height: 40).input
        #expect(hdr.pixels.contains { $0 == 8 })
        for scene in ["p3", "hdr"] {
            let a = try EIGFToneComparison.fixture(scene, split: .tuning, width: 64, height: 40).input
            let b = try EIGFToneComparison.fixture(scene, split: .acceptance, width: 64, height: 40).input
            #expect(a.sha256 != b.sha256, "P3/HDR tuning cannot reuse identical acceptance pixels")
        }
        let tuning = try EIGFToneComparison.fixture("branches", split: .tuning, width: 64, height: 40).input
        let acceptance = try EIGFToneComparison.fixture("branches", split: .acceptance, width: 64, height: 40).input
        #expect(tuning.sha256 != acceptance.sha256)
    }

    @Test func changedAcceptanceGatesAreRejected() throws {
        var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        value["maximumNoiseGainRatio"] = 1.2
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eigf-invalid-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: value).write(to: url)
        #expect(throws: EIGFToneReference.Failure.self) { _ = try EIGFToneComparison.Manifest.load(url) }
    }

    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/eigf-evaluation/manifest.json")
    }
    private func settings() -> EditSettings {
        var s = EditSettings.neutral; s.toneProcessingVersion = .consistentV2; return s
    }
    private func raster(_ values: [Float], width: Int? = nil) throws -> AlgorithmEvaluationRaster {
        let width = width ?? values.count
        return try .init(width: width, height: values.count / width,
            pixels: values.flatMap { [$0, $0, $0, Float(1)] })
    }
}
