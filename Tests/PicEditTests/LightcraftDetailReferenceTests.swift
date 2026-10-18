import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Lightcraft isolated detail reference")
struct LightcraftDetailReferenceTests {
    @Test func originalRustVectorsCheckGuidedClarityAndTamedTexture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/lightcraft-evaluation/lc04-reference-oracle/vectors.json")
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.upstream_commit == "f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15")
        #expect(oracle.cases.count == 12)
        for item in oracle.cases {
            let variant = try #require(LightcraftDetailReference.Variant(rawValue: item.variant))
            let input = try raster(width: item.width, height: item.height) { x, y in (item.input[y * item.width + x], 1) }
            let reference = LightcraftDetailReference(variant: variant, sigmaOverride: item.sigma)
            let prepared = try reference.prepare(input)
            let output = try reference.apply(prepared, settings: settings(variant, item.strength * 100))
            let signalError = zip(prepared.signal, item.signal).map { abs($0 - $1) }.max() ?? .infinity
            let baseError = zip(prepared.base, item.base).map { abs($0 - $1) }.max() ?? .infinity
            let outputError = item.output.indices.map { abs(output.pixels[$0 * 4] - item.output[$0]) }.max() ?? .infinity
            #expect(signalError <= oracle.absolute_float_tolerance)
            #expect(baseError <= oracle.absolute_float_tolerance,
                    "\(item.variant) sigma \(item.sigma): base error \(baseError)")
            #expect(outputError <= oracle.absolute_float_tolerance,
                    "\(item.variant) sigma \(item.sigma) strength \(item.strength): RGB error \(outputError)")
        }
    }

    @Test func bothSignsOfZeroAreExactForSignedExtendedRGBAndAlpha() throws {
        let input = try AlgorithmEvaluationRaster(width: 4, height: 1, pixels: [3, 1, -2, 0,
            1.4, -0.25, 0.7, 0.03125, -0.1, 0.6, 1.2, 0.5, 0.2, 0.3, 0.4, 1])
        for variant in LightcraftDetailReference.Variant.allCases {
            let reference = LightcraftDetailReference(variant: variant)
            let prepared = try reference.prepare(input)
            for zero in [0.0, -0.0] {
                #expect(try reference.render(input, settings: settings(variant, zero)).pixels == input.pixels)
                #expect(try reference.apply(prepared, settings: settings(variant, zero)).pixels == input.pixels)
            }
        }
    }

    @Test func rapidSignedSliderChangesReuseImmutablePreparedPlanes() throws {
        let input = try scene()
        let original = input.sha256
        for variant in LightcraftDetailReference.Variant.allCases {
            let reference = LightcraftDetailReference(variant: variant, nativeLong: 6000, pixelsPerLongEdge: 1200)
            let prepared = try reference.prepare(input)
            for strength in [100.0, -100, 1, -1, 0, 60, -35, 0] {
                let edit = settings(variant, strength)
                let reused = try reference.apply(prepared, settings: edit)
                let fresh = try reference.render(input, settings: edit)
                #expect(reused.pixels == fresh.pixels)
                #expect(reused.pixels.allSatisfy { $0.isFinite })
            }
            #expect(prepared.input.sha256 == original)
        }
        #expect(input.sha256 == original)
    }

    @Test func alphaCoverageExcludesHiddenColourAndPreventsDarkRings() throws {
        let canonical = try raster(width: 64, height: 9) { x, _ in
            (0.18, x < 9 ? 0 : (x < 32 ? 0.125 : 1))
        }
        var hidden = canonical
        for index in stride(from: 0, to: hidden.pixels.count, by: 4) where hidden.pixels[index + 3] == 0 {
            hidden.pixels[index] = 64; hidden.pixels[index + 1] = -32; hidden.pixels[index + 2] = 17
        }
        for variant in LightcraftDetailReference.Variant.allCases {
            let reference = LightcraftDetailReference(variant: variant, sigmaOverride: 4)
            for strength in [-100.0, 0, 100] {
                let output = try reference.render(hidden, settings: settings(variant, strength))
                let clean = try reference.render(canonical, settings: settings(variant, strength))
                #expect(output.pixels == clean.pixels)
                for offset in stride(from: 0, to: output.pixels.count, by: 4) {
                    #expect(output.pixels[offset + 3] == canonical.pixels[offset + 3])
                    if output.pixels[offset + 3] > 0 { #expect(abs(output.pixels[offset] - 0.18) < 0.00001) }
                    else { #expect(Array(output.pixels[offset..<(offset + 4)]) == [0, 0, 0, 0]) }
                }
            }
        }
    }

    @Test func onePixelSingleAxisAndEmptyCoverageStayFinite() throws {
        for (width, height) in [(1, 1), (1, 13), (11, 1), (2, 2)] {
            for alpha in [Float(0), 0.03125, 1] {
                let input = try raster(width: width, height: height) { _, _ in (0.03, alpha) }
                for variant in LightcraftDetailReference.Variant.allCases {
                    let output = try LightcraftDetailReference(variant: variant, pixelsPerLongEdge: 6000)
                        .render(input, settings: settings(variant, -100))
                    #expect(output.width == width && output.height == height)
                    #expect(output.pixels.allSatisfy { $0.isFinite })
                    for offset in stride(from: 0, to: output.pixels.count, by: 4) {
                        #expect(output.pixels[offset + 3] == alpha)
                        #expect(abs(output.pixels[offset] - input.pixels[offset]) < 0.000005)
                    }
                }
            }
        }
    }

    @Test func gaussianAblationsUseExactlyTheSameRadiusAndLogBase() throws {
        let input = try scene()
        let existing = try LightcraftDetailReference(variant: .textureGaussianExistingDomain, pixelsPerLongEdge: 1200).prepare(input)
        let log = try LightcraftDetailReference(variant: .textureGaussianLog, pixelsPerLongEdge: 1200).prepare(input)
        let tamed = try LightcraftDetailReference(variant: .textureGaussianLogTamed, pixelsPerLongEdge: 1200).prepare(input)
        #expect(abs(existing.sigma - 2.16) < 0.000001)
        #expect(existing.sigma == log.sigma && log.sigma == tamed.sigma)
        #expect(log.signal == tamed.signal && log.base == tamed.base)
        #expect(existing.signal != log.signal && existing.base != log.base)
        let guided = try LightcraftDetailReference(pixelsPerLongEdge: 1200).prepare(input)
        let gaussian = try LightcraftDetailReference(variant: .clarityGaussianLog, pixelsPerLongEdge: 1200).prepare(input)
        #expect(guided.sigma == gaussian.sigma)
        #expect(guided.signal == gaussian.signal)
        #expect(guided.base != gaussian.base)
    }

    @Test func tamedTextureLimitsHardEdgeGainSeparatelyFromGaussianDomain() throws {
        let input = try raster(width: 80, height: 5) { x, _ in (x < 40 ? 0.0001 : 1, 1) }
        let plain = LightcraftDetailReference(variant: .textureGaussianLog, sigmaOverride: 3)
        let tamed = LightcraftDetailReference(variant: .textureGaussianLogTamed, sigmaOverride: 3)
        for strength in [-100.0, 100] {
            let output = try tamed.render(input, settings: settings(.textureGaussianLogTamed, strength))
            let unlimited = try plain.render(input, settings: settings(.textureGaussianLog, strength))
            var maxTamedEV: Float = 0, maxPlainEV: Float = 0
            for offset in stride(from: 0, to: output.pixels.count, by: 4) {
                maxTamedEV = max(maxTamedEV, abs(log2(output.pixels[offset] / input.pixels[offset])))
                maxPlainEV = max(maxPlainEV, abs(log2(unlimited.pixels[offset] / input.pixels[offset])))
            }
            #expect(maxTamedEV <= 1.10001)
            #expect(maxPlainEV > maxTamedEV + 1)
        }
    }

    @Test func existingDomainBlursLinearRGBBeforeGammaAndUsesProductionAdditiveGain() throws {
        let input = try scene()
        let variant = LightcraftDetailReference.Variant.textureGaussianExistingDomain
        let reference = LightcraftDetailReference(variant: variant, sigmaOverride: 2)
        let prepared = try reference.prepare(input)
        let plane = LightcraftToneFilters.Plane(width: input.width, height: input.height,
            values: stride(from: 0, to: input.pixels.count, by: 4).map { input.pixels[$0] })
        let blurred = try LightcraftToneFilters.gaussian(plane, sigma: 2)
        let result = try reference.apply(prepared, settings: settings(variant, 50))
        for i in blurred.values.indices {
            let original = pow(input.pixels[i * 4], 1 / Float(2.2))
            let base = pow(max(0, blurred.values[i]), 1 / Float(2.2))
            let expected = pow(min(1, max(0, original + 0.45 * (min(1, original) - base))), 2.2)
            #expect(abs(result.pixels[i * 4] - expected) < 0.000005)
        }
    }

    @Test func changedVariantGeometryAndInputCannotReuseAnUnrelatedPlane() throws {
        let input = try scene()
        let reference = LightcraftDetailReference(nativeLong: 6000, pixelsPerLongEdge: 1200)
        let prepared = try reference.prepare(input)
        for other in [LightcraftDetailReference(variant: .clarityGaussianLog, nativeLong: 6000, pixelsPerLongEdge: 1200),
                      LightcraftDetailReference(nativeLong: 4000, pixelsPerLongEdge: 1200),
                      LightcraftDetailReference(nativeLong: 6000, pixelsPerLongEdge: 600),
                      LightcraftDetailReference(nativeLong: 6000, pixelsPerLongEdge: 1200, sigmaOverride: 8)] {
            #expect(throws: LightcraftDetailReference.Failure.self) { _ = try other.apply(prepared, settings: settings(.clarityGuidedLog, 50)) }
        }
        var changed = input
        for offset in stride(from: 0, to: changed.pixels.count, by: 4) {
            for channel in 0..<3 { changed.pixels[offset + channel] *= 2 }
        }
        let updated = try reference.prepare(changed)
        #expect(updated.input.sha256 != prepared.input.sha256)
        #expect(updated.signal != prepared.signal)
        #expect(updated.base != prepared.base)
        #expect(try reference.apply(updated, settings: settings(.clarityGuidedLog, 50)).pixels
                == reference.render(changed, settings: settings(.clarityGuidedLog, 50)).pixels)
    }

    @Test func invalidControlsGeometryAndMutableRasterAreRejectedBeforeFiltering() throws {
        let input = try scene()
        for variant in LightcraftDetailReference.Variant.allCases {
            let reference = LightcraftDetailReference(variant: variant)
            for bad in [Double.nan, .infinity, -.infinity] {
                #expect(throws: LightcraftDetailReference.Failure.self) { _ = try reference.render(input, settings: settings(variant, bad)) }
            }
            for keyPath in [\EditSettings.exposure, \.contrast, \.shadows, \.highlights, \.whites, \.blacks,
                            \.dehaze, \.vibrance, \.saturation, \.luminanceNoiseReduction, \.colorNoiseReduction, \.autoToneAmount, \.naturalBalanceAmount] {
                var edit = settings(variant, 50); edit[keyPath: keyPath] = 1
                #expect(throws: LightcraftDetailReference.Failure.self) { _ = try reference.render(input, settings: edit) }
            }
            var wrong = settings(variant, 50)
            if variant.isClarity { wrong.texture = 1 } else { wrong.clarity = 1 }
            #expect(throws: LightcraftDetailReference.Failure.self) { _ = try reference.render(input, settings: wrong) }
            #expect(try reference.render(input, settings: settings(variant, 1000)).pixels
                    == reference.render(input, settings: settings(variant, 100)).pixels)
        }
        for reference in [LightcraftDetailReference(nativeLong: 0), LightcraftDetailReference(nativeLong: 1_000_001),
                          LightcraftDetailReference(pixelsPerLongEdge: .nan), LightcraftDetailReference(pixelsPerLongEdge: -1),
                          LightcraftDetailReference(sigmaOverride: .infinity), LightcraftDetailReference(sigmaOverride: 0),
                          LightcraftDetailReference(sigmaOverride: .leastNonzeroMagnitude)] {
            #expect(throws: LightcraftDetailReference.Failure.self) { _ = try reference.render(input, settings: .neutral) }
        }
        for invalidValue in [Float.nan, .infinity] {
            var broken = input; broken.pixels[0] = invalidValue
            #expect(throws: LightcraftDetailReference.Failure.self) { _ = try LightcraftDetailReference().prepare(broken) }
        }
        var brokenAlpha = input; brokenAlpha.pixels[3] = -0.1
        #expect(throws: LightcraftDetailReference.Failure.self) { _ = try LightcraftDetailReference().prepare(brokenAlpha) }
        var truncated = input; truncated.pixels.removeLast()
        #expect(throws: LightcraftDetailReference.Failure.self) { _ = try LightcraftDetailReference().prepare(truncated) }
    }

    @Test func cancelledPreparationApplicationAndNeutralRenderingPublishNoResult() async throws {
        let input = try scene()
        let reference = LightcraftDetailReference()
        let prepared = try reference.prepare(input)
        let preparing = Task { withUnsafeCurrentTask { $0?.cancel() }; return try reference.prepare(input) }
        await #expect(throws: CancellationError.self) { _ = try await preparing.value }
        let edit = settings(.clarityGuidedLog, 50)
        let applying = Task { withUnsafeCurrentTask { $0?.cancel() }; return try reference.apply(prepared, settings: edit) }
        await #expect(throws: CancellationError.self) { _ = try await applying.value }
        let neutral = Task { withUnsafeCurrentTask { $0?.cancel() }; return try reference.render(input, settings: .neutral) }
        await #expect(throws: CancellationError.self) { _ = try await neutral.value }
    }

    @Test(arguments: [8, 16], [false, true])
    func frozenSRGBAndP3SamplesRetainAlphaAndScalarColourGain(bits: Int, p3: Bool) throws {
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
        for variant in [LightcraftDetailReference.Variant.clarityGuidedLog, .textureGaussianLog, .textureGaussianLogTamed] {
            let reference = LightcraftDetailReference(variant: variant, sigmaOverride: 2)
            #expect(try reference.render(input, settings: .neutral).pixels == input.pixels)
            let output = try reference.render(input, settings: settings(variant, 65))
            for p in stride(from: 0, to: input.pixels.count, by: 4) {
                #expect(output.pixels[p + 3] == input.pixels[p + 3])
                guard input.pixels[p + 3] > 0 else { continue }
                let channel = (0..<3).max { abs(input.pixels[p + $0]) < abs(input.pixels[p + $1]) }!
                let gain = output.pixels[p + channel] / input.pixels[p + channel]
                #expect(gain > 0 && gain.isFinite)
                for c in 0..<3 { #expect(abs(output.pixels[p + c] - input.pixels[p + c] * gain) < 0.000005) }
            }
        }
    }

    private func settings(_ variant: LightcraftDetailReference.Variant, _ strength: Double) -> EditSettings {
        var result = EditSettings.neutral
        if variant.isClarity { result.clarity = strength } else { result.texture = strength }
        return result
    }

    private func scene() throws -> AlgorithmEvaluationRaster {
        try raster(width: 80, height: 11) { x, y in
            let region: Float = x < 40 ? 0.025 : 0.7
            return (region * (1 + Float((x * 7 + y * 13) % 7 - 3) * 0.08), 1)
        }
    }

    private func raster(width: Int, height: Int, value: (Int, Int) -> (Float, Float)) throws -> AlgorithmEvaluationRaster {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (v, a) = value(x, y), p = (y * width + x) * 4
            pixels[p] = v; pixels[p + 1] = v; pixels[p + 2] = v; pixels[p + 3] = a
        } }
        return try .init(width: width, height: height, pixels: pixels)
    }

    private struct Oracle: Decodable {
        let upstream_commit: String
        let absolute_float_tolerance: Float
        let cases: [Case]
        struct Case: Decodable {
            let variant: String
            let width: Int, height: Int
            let sigma: Double, strength: Double
            let input: [Float], signal: [Float], base: [Float], output: [Float]
        }
    }
}
