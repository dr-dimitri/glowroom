import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Lightcraft isolated colour reference")
struct LightcraftColorReferenceTests {
    typealias Reference = LightcraftColorReference

    @Test func originalRustCasesVerifyBothBridgesSignedTransformsControlsAndGamutPolicy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/lightcraft-evaluation/lc05-reference-oracle/vectors.json")
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.upstream_commit == "f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15")
        #expect(oracle.cases.count == 24)
        #expect(Reference.skinHue == oracle.skin_hue)
        for item in oracle.cases {
            #expect(item.input.count == 20)
            if item.domain == "rec2020" {
                for (input, expected) in zip(item.input, item.raw) {
                    let actual = Reference.applyRec2020(SIMD3(input[0], input[1], input[2]),
                                                        vibrance: Float(item.vibrance), saturation: Float(item.saturation))
                    let error = (0..<3).map { abs(actual[$0] - expected[$0]) }.max() ?? .infinity
                    #expect(error <= oracle.absolute_float_tolerance,
                            "Rec.2020 input \(input), V=\(item.vibrance), S=\(item.saturation): error \(error)")
                }
            } else {
                #expect(item.domain == "linear-srgb")
                let input = try raster(item.input.map { SIMD3($0[0], $0[1], $0[2]) })
                for policy in Reference.OutputPolicy.allCases {
                    let result = try Reference(outputPolicy: policy).render(input,
                        settings: settings(vibrance: item.vibrance * 100, saturation: item.saturation * 100))
                    let expected = policy == .unbounded ? item.raw : item.mapped
                    let error = expected.indices.flatMap { i in (0..<3).map { abs(result.pixels[i * 4 + $0] - expected[i][$0]) } }.max() ?? .infinity
                    #expect(error <= oracle.absolute_float_tolerance,
                            "sRGB \(policy), V=\(item.vibrance), S=\(item.saturation): error \(error)")
                }
            }
        }
    }

    @Test func bothSignsOfNeutralAreExactForBothPoliciesIncludingSignedP3AndHiddenRGB() throws {
        var input = try AlgorithmEvaluationRaster(width: 4, height: 1, pixels: [3, 1, -2, 0,
            1.4, -0.25, 0.7, 0.03125, -0.1, 0.6, 1.2, 0.5, 0.2, 0.3, 0.4, 1])
        let canonical = input
        input.pixels[0] = 9; input.pixels[1] = -4; input.pixels[2] = 2
        for policy in Reference.OutputPolicy.allCases {
            for zero in [0.0, -0.0] {
                let result = try Reference(outputPolicy: policy).render(input, settings: settings(vibrance: zero, saturation: zero))
                #expect(result.pixels == canonical.pixels)
                #expect(result.sha256 == canonical.sha256)
            }
        }
    }

    @Test func signedCubeRootsAndRawOutputsArePreservedInsteadOfSilentlyClamped() throws {
        for rgb in [SIMD3<Float>(-0.6, -0.2, -0.1), SIMD3(-1, 0.1, 0.3), SIMD3(-0.2, 0.4, 1.3), SIMD3(2, 1.5, 0.3)] {
            let lab = Reference.rec2020ToOKLab(rgb)
            let restored = Reference.oklabToRec2020(lab)
            for channel in 0..<3 { #expect(abs(restored[channel] - rgb[channel]) < 0.000005) }
        }
        let input = try raster([SIMD3(-0.6, -0.2, -0.1), SIMD3(2, 1.5, 0.3)])
        let raw = try Reference(outputPolicy: .unbounded).render(input, settings: settings(saturation: 50))
        #expect(raw.pixels[0] < 0 && raw.pixels[1] < 0 && raw.pixels[2] < 0)
        #expect(raw.pixels[4] > 1)
        #expect(raw.pixels.allSatisfy { $0.isFinite })
        let mapped = try Reference().render(input, settings: settings(saturation: 50))
        for p in stride(from: 0, to: mapped.pixels.count, by: 4) {
            for c in 0..<3 { #expect(mapped.pixels[p + c] >= -0.000005 && mapped.pixels[p + c] <= 1.000005) }
        }
        #expect(Array(mapped.pixels.prefix(3)) == [0, 0, 0])
    }

    @Test func gamutMappingPreservesInRangePixelsAndLuminanceWhenPossible() {
        let unchanged = SIMD3<Float>(0.2, 0.4, 0.7)
        #expect(Reference.gamutMapSRGB(unchanged).rgb == unchanged)
        #expect(Reference.gamutMapSRGB(unchanged).chromaScale == 1)
        let outside = SIMD3<Float>(-0.2, 0.6, 1.4)
        let result = Reference.gamutMapSRGB(outside)
        #expect(result.chromaScale > 0 && result.chromaScale < 1)
        #expect(abs(luma(result.rgb) - luma(outside)) < 0.000001)
        #expect(result.rgb.x >= -0.000001 && result.rgb.z <= 1.000001)
        #expect(result.rgb.y != outside.y, "The original mapper compresses chroma, rather than clipping channels independently")
        #expect(Reference.gamutMapSRGB(SIMD3(-1, -2, -3)).rgb == .zero)
        #expect(Reference.gamutMapSRGB(SIMD3(2, 3, 4)).rgb == SIMD3(repeating: 1))
    }

    @Test func saturationMinus100RemovesNativeLabChromaWithoutAnInventedGrayCorrection() throws {
        for rgb in [SIMD3<Float>(0.4, 0.1, 0.05), SIMD3(0.03, 0.05, 0.4), SIMD3(-0.6, -0.2, -0.1)] {
            let before = Reference.rec2020ToOKLab(rgb)
            for vibrance in [Float(-1), 0, 1] {
                let after = Reference.rec2020ToOKLab(Reference.applyRec2020(rgb, vibrance: vibrance, saturation: -1))
                #expect(abs(after.x - before.x) < 0.000005)
                #expect(abs(after.y) < 0.000005 && abs(after.z) < 0.000005)
            }
        }
        // The pinned XYZ/D65 matrices have a small gray-axis residual in sRGB.
        // Preserve and expose it to the quality gate; do not silently replace
        // upstream output with a hand-selected equal-channel gray.
        let white = try raster([SIMD3(repeating: 1)])
        let raw = try Reference(outputPolicy: .unbounded).render(white, settings: settings(saturation: -100))
        #expect(abs(raw.pixels[0] - raw.pixels[2]) > 0.001)
        #expect(abs(raw.pixels[0] - raw.pixels[2]) < 0.0013)
        #expect(raw.pixels[0] > 1)
    }

    @Test func positiveVibranceHueHeuristicIsNotAppliedToNegativeVibrance() {
        func pixel(hue: Float) -> SIMD3<Float> {
            Reference.oklabToRec2020(SIMD3(0.6, 0.05 * cos(hue), 0.05 * sin(hue)))
        }
        let near = pixel(hue: Reference.skinHue), far = pixel(hue: Reference.skinHue + .pi)
        let boostedNear = chroma(Reference.rec2020ToOKLab(Reference.applyRec2020(near, vibrance: 0.8, saturation: 0)))
        let boostedFar = chroma(Reference.rec2020ToOKLab(Reference.applyRec2020(far, vibrance: 0.8, saturation: 0)))
        #expect(boostedNear > 0.05 && boostedFar > boostedNear + 0.01)
        let reducedNear = chroma(Reference.rec2020ToOKLab(Reference.applyRec2020(near, vibrance: -0.8, saturation: 0)))
        let reducedFar = chroma(Reference.rec2020ToOKLab(Reference.applyRec2020(far, vibrance: -0.8, saturation: 0)))
        #expect(reducedNear < 0.05)
        #expect(abs(reducedNear - reducedFar) < 0.000005)
        let saturated = pixel(hue: Reference.skinHue + 1)
        let lab = Reference.rec2020ToOKLab(saturated)
        let highChroma = Reference.oklabToRec2020(SIMD3(lab.x, lab.y * 6, lab.z * 6))
        let result = Reference.applyRec2020(highChroma, vibrance: 1, saturation: 0)
        for c in 0..<3 { #expect(abs(result[c] - highChroma[c]) < 0.000005) }
    }

    @Test func alphaNeverAffectsVisibleStraightRGBAndHiddenColoursStayAbsent() throws {
        let rgb = SIMD3<Float>(0.6, 0.15, 0.04)
        let input = try raster([rgb, rgb, rgb, rgb], alpha: [0, 0.00001, 0.25, 1])
        for policy in Reference.OutputPolicy.allCases {
            let result = try Reference(outputPolicy: policy).render(input, settings: settings(vibrance: 75, saturation: 30))
            #expect(Array(result.pixels.prefix(4)) == [0, 0, 0, 0])
            for i in 1..<4 {
                #expect(result.pixels[i * 4 + 3] == input.pixels[i * 4 + 3])
                for c in 0..<3 { #expect(result.pixels[i * 4 + c] == result.pixels[12 + c]) }
            }
        }
    }

    @Test func grayAndNearBlackRampsRemainFiniteAndOrderedAtControlExtremes() throws {
        let input = try raster([Float(0), 1e-9, 0.0001, 0.01, 0.18, 0.5, 1].map { SIMD3(repeating: $0) })
        for policy in Reference.OutputPolicy.allCases {
            for value in [-100.0, 100] {
                for edit in [settings(vibrance: value), settings(saturation: value), settings(vibrance: value, saturation: value)] {
                    let output = try Reference(outputPolicy: policy).render(input, settings: edit)
                    #expect(output.pixels.allSatisfy { $0.isFinite })
                    #expect(Array(output.pixels.prefix(3)) == [0, 0, 0])
                    var previous: Float = -1
                    for i in 0..<input.width {
                        let value = luma(SIMD3(output.pixels[i * 4], output.pixels[i * 4 + 1], output.pixels[i * 4 + 2]))
                        #expect(value > previous)
                        previous = value
                    }
                }
            }
        }
    }

    @Test func sharedBoundedRowsAreDeterministicAndNeverMutateTheInput() throws {
        let colors: [SIMD3<Float>] = (0..<(256 * 96)).map { i in
            let red: Float = Float(i % 251) / 250
            let green: Float = Float((i * 7) % 127) / 126
            let blue: Float = Float((i * 13) % 97) / 96
            return SIMD3<Float>(red, green, blue)
        }
        let input = try AlgorithmEvaluationRaster(width: 256, height: 96, pixels: colors.flatMap { [$0.x, $0.y, $0.z, 1] })
        let before = input.sha256
        let reference = Reference(outputPolicy: .unbounded), edit = settings(vibrance: 35, saturation: -15)
        let first = try reference.render(input, settings: edit), second = try reference.render(input, settings: edit)
        #expect(first.sha256 == second.sha256)
        #expect(input.sha256 == before)
        #expect(first.sha256 != before)
    }

    @Test func invalidControlsAndMutatedRasterFailBeforePublishingOutput() throws {
        let input = try raster([SIMD3(0.4, 0.2, 0.1)])
        let reference = Reference()
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: Reference.Failure.self) { _ = try reference.render(input, settings: settings(vibrance: value)) }
            #expect(throws: Reference.Failure.self) { _ = try reference.render(input, settings: settings(saturation: value)) }
        }
        for key in [\EditSettings.exposure, \.contrast, \.shadows, \.highlights, \.whites, \.blacks,
                    \.texture, \.clarity, \.dehaze, \.luminanceNoiseReduction, \.colorNoiseReduction, \.autoToneAmount] {
            var edit = settings(vibrance: 20); edit[keyPath: key] = 1
            #expect(throws: Reference.Failure.self) { _ = try reference.render(input, settings: edit) }
        }
        #expect(try reference.render(input, settings: settings(vibrance: 1000, saturation: -1000)).pixels
                == reference.render(input, settings: settings(vibrance: 100, saturation: -100)).pixels)
        var invalid = input; invalid.pixels[0] = .nan
        #expect(throws: Reference.Failure.self) { _ = try reference.render(invalid, settings: .neutral) }
        invalid = input; invalid.pixels[3] = -0.1
        #expect(throws: Reference.Failure.self) { _ = try reference.render(invalid, settings: settings(vibrance: 20)) }
        invalid = input; invalid.pixels.removeLast()
        #expect(throws: Reference.Failure.self) { _ = try reference.render(invalid, settings: .neutral) }
    }

    @Test func cancelledActiveAndNeutralRequestsPublishNoResult() async throws {
        let input = try raster([SIMD3(0.4, 0.2, 0.1)])
        for edit in [EditSettings.neutral, settings(vibrance: 50)] {
            let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try Reference().render(input, settings: edit) }
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    @Test(arguments: [8, 16], [false, true])
    func frozenProfileAndDepthInputsRetainTheirSeparateAlphaContract(bits: Int, p3: Bool) throws {
        let samples: [UInt16] = [255, 0, 0, 255, 0, 255, 0, 128, 20, 40, 70, 255,
                                 55, 65, 75, 255, 75, 85, 95, 192, 90, 100, 110, 0]
        var bytes = Data()
        for sample in samples {
            if bits == 8 { bytes.append(UInt8(sample)) }
            else { let value = sample * 257; bytes.append(UInt8(truncatingIfNeeded: value >> 8)); bytes.append(UInt8(truncatingIfNeeded: value)) }
        }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try #require(CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
        let source = try #require(CGImage(width: 3, height: 2, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: 3 * 4 * (bits / 8), space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(bits == 16 ? .byteOrder16Big : []),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        let input = try AlgorithmEvaluationRaster.freeze(source)
        if p3 { #expect(input.pixels.contains { $0 < 0 }) }
        for policy in Reference.OutputPolicy.allCases {
            let reference = Reference(outputPolicy: policy)
            #expect(try reference.render(input, settings: .neutral).pixels == input.pixels)
            let output = try reference.render(input, settings: settings(vibrance: 60, saturation: 20))
            for p in stride(from: 0, to: input.pixels.count, by: 4) {
                #expect(output.pixels[p + 3] == input.pixels[p + 3])
                if input.pixels[p + 3] == 0 { #expect(Array(output.pixels[p..<(p + 4)]) == [0, 0, 0, 0]) }
                if policy == .gamutMappedSRGB {
                    for c in 0..<3 { #expect(output.pixels[p + c] >= -0.000005 && output.pixels[p + c] <= 1.000005) }
                }
            }
        }
    }

    private func settings(vibrance: Double = 0, saturation: Double = 0) -> EditSettings {
        var value = EditSettings.neutral; value.vibrance = vibrance; value.saturation = saturation; return value
    }
    private func raster(_ colors: [SIMD3<Float>], alpha: [Float]? = nil) throws -> AlgorithmEvaluationRaster {
        try .init(width: colors.count, height: 1, pixels: colors.enumerated().flatMap { i, c in [c.x, c.y, c.z, alpha?[i] ?? 1] })
    }
    private func chroma(_ lab: SIMD3<Float>) -> Float { (lab.y * lab.y + lab.z * lab.z).squareRoot() }
    private func luma(_ rgb: SIMD3<Float>) -> Float { 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z }
    private struct Oracle: Decodable {
        let upstream_commit: String
        let absolute_float_tolerance: Float
        let skin_hue: Float
        let cases: [Case]
        struct Case: Decodable {
            let domain: String
            let vibrance: Double, saturation: Double
            let input: [[Float]], raw: [[Float]], mapped: [[Float]]
        }
    }
}
