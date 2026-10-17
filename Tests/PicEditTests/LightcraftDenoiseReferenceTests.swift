import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Lightcraft isolated denoise reference")
struct LightcraftDenoiseReferenceTests {
    typealias Reference = LightcraftDenoiseReference

    @Test func originalRustParametersAndOpaquePixelsMatchWithoutFastGuidedSubstitution() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/lightcraft-evaluation/lc06-reference-oracle/vectors.json")
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.upstream_commit == "f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15")
        #expect(oracle.cases.count == 40)
        for item in oracle.cases {
            let control = try #require(Reference.Control(rawValue: item.control))
            let reference = Reference(control: control, geometry: .init(nativeLong: 6000,
                pixelsPerLongEdge: item.scale * 6000, inputSampling: .areaAveraged))
            let params = try reference.parameters(amount: item.amount)
            #expect(params.sigma == item.sigma)
            #expect(abs(params.blend - item.blend) < 0.000001)
            if let epsilon = item.epsilon {
                let actualEpsilon = try #require(params.epsilon)
                #expect(abs(actualEpsilon - epsilon) < 0.0000001)
            } else { #expect(params.epsilon == nil) }
            let actual = try Reference.applyRec2020(item.input.flatMap { $0 }, width: item.width, height: item.height,
                                                    control: control, parameters: params)
            let expected = item.output.flatMap { $0 }
            #expect(actual.count == expected.count)
            for i in actual.indices {
                let tolerance = oracle.absolute_float_tolerance + oracle.relative_float_tolerance * abs(expected[i])
                #expect(abs(actual[i] - expected[i]) <= tolerance,
                        "\(item.control), amount \(item.amount), scale \(item.scale), pixel component \(i): \(actual[i]) vs \(expected[i])")
            }
        }
    }

    @Test func neutralAndSubpixelFadePreserveExactCanonicalSignedInput() throws {
        var input = try AlgorithmEvaluationRaster(width: 3, height: 1, pixels: [9, -2, 3, 0, 1.4, -0.3, 0.8, 0.5, -0.1, 0.4, 1.2, 1])
        let canonical = input
        input.pixels[0] = 8; input.pixels[1] = 12; input.pixels[2] = -4
        for control in Reference.Control.allCases {
            let reference = Reference(control: control, geometry: nativeGeometry(3))
            for amount in [0.0, -0.0, -100] {
                let result = try reference.render(input, settings: settings(control, amount))
                #expect(result.sha256 == canonical.sha256)
            }
            let faded = Reference(control: control, geometry: .init(nativeLong: 6000, pixelsPerLongEdge: 6, inputSampling: .areaAveraged))
            #expect(try faded.parameters(amount: 100).sigma == nil)
            #expect(try faded.render(input, settings: settings(control, 100)).sha256 == canonical.sha256)
        }
    }

    @Test func nativeAreaAveragedAndUnknownSamplingKeepDistinctVarianceAssumptions() throws {
        let native = Reference(control: .luminance, geometry: nativeGeometry(6000))
        let area = Reference(control: .luminance, geometry: .init(nativeLong: 6000, pixelsPerLongEdge: 1500, inputSampling: .areaAveraged))
        let unknown = Reference(control: .luminance, geometry: .init(nativeLong: 6000, pixelsPerLongEdge: 1500, inputSampling: .unknown))
        let noScale = Reference(control: .luminance, geometry: area.geometry, scaling: .unscaled)
        let n = try native.parameters(amount: 60), a = try area.parameters(amount: 60)
        let u = try unknown.parameters(amount: 60), unscaled = try noScale.parameters(amount: 60)
        #expect(a.radiusScale == 0.25 && a.epsilonScale == 0.25)
        #expect(u.radiusScale == 0.25 && u.epsilonScale == 1)
        #expect(a.sigma == u.sigma && a.blend == u.blend)
        let averagedEpsilon = try #require(a.epsilon), nativeEpsilon = try #require(n.epsilon)
        #expect(abs(averagedEpsilon - nativeEpsilon / 16) < 0.0000001)
        #expect(u.epsilon == n.epsilon)
        #expect(unscaled == n)
        let incorrect = Reference(control: .luminance, geometry: .init(nativeLong: 6000, pixelsPerLongEdge: 1500, inputSampling: .native))
        #expect(throws: Reference.Failure.self) { _ = try incorrect.parameters(amount: 0) }
        // Upstream detail_scale itself has a defined fallback, while the adapter
        // rejects nonfinite/unknown geometry instead of silently inventing it.
        #expect(Reference.detailScale(pixelsPerLongEdge: .nan, nativeLong: 6000) == 1)
        #expect(Reference.detailScale(pixelsPerLongEdge: 12_000, nativeLong: 6000) == 1)
        #expect(Reference.detailScale(pixelsPerLongEdge: -1, nativeLong: 6000) == 0)
    }

    @Test func radiusVarianceFadeAndFixedHiddenControlsMatchDocumentedConstants() throws {
        let radius = Reference.nrRadius(0.5)
        #expect(radius.sigma == 1)
        #expect(abs(radius.weight - 0.375) < 0.000001)
        let luma = try Reference(control: .luminance, geometry: nativeGeometry(100)).parameters(amount: 100)
        #expect(luma.sigma == 3.5 && luma.blend == 1)
        let epsilon = try #require(luma.epsilon)
        #expect(abs(epsilon - 0.1645) < 0.000001)
        let chroma = try Reference(control: .chroma, geometry: nativeGeometry(100)).parameters(amount: 100)
        #expect(chroma.sigma == 11.25 && chroma.blend == 0.75 && chroma.epsilon == nil)
    }

    @Test func tileDimensionsNeverSubstituteForFullOriginalGeometry() throws {
        let reference = Reference(control: .luminance, geometry: .init(nativeLong: 6000, pixelsPerLongEdge: 3000, inputSampling: .areaAveraged))
        let input = try pattern(width: 5, height: 3)
        let before = try reference.parameters(amount: 60)
        _ = try reference.render(input, settings: settings(.luminance, 60))
        #expect(try reference.parameters(amount: 60) == before)
        #expect(before.radiusScale == 0.5)
        #expect(before.sigma == 1.25)
    }

    @Test func originalClampAndNearBlackFloorRemainExplicitlyDifferentForEachControl() throws {
        let negative: [Float] = [-0.2, -0.1, -0.05]
        for control in Reference.Control.allCases {
            let params = try Reference(control: control, geometry: nativeGeometry(1)).parameters(amount: 60)
            let result = try Reference.applyRec2020(negative, width: 1, height: 1, control: control, parameters: params)
            if control == .chroma {
                #expect(result[0] > 24_000 && result[1] > 12_000 && result[2] > 6_000,
                        "Original negative Y divides by a positive floor, then multiplies by negative Y; do not hide this upstream limitation")
                let signedChannel = try Reference.applyRec2020([-0.2, 0.3, 0.1], width: 1, height: 1,
                                                               control: control, parameters: params)
                #expect(signedChannel[0] == 0 && signedChannel[1] > 0 && signedChannel[2] > 0)
            }
            else {
                for channel in 0..<3 { #expect(abs(result[channel] - negative[channel]) < 0.00001) }
            }
        }
        let params = try Reference(control: .chroma, geometry: nativeGeometry(1)).parameters(amount: 100)
        let tiny = try Reference.applyRec2020([1e-8, 1e-8, 1e-8], width: 1, height: 1, control: .chroma, parameters: params)
        #expect(tiny.allSatisfy { $0 > 0 && $0 < 2e-10 }, "The original RGB/Y floor can attenuate a constant field near black")
    }

    @Test func coveragePreventsHiddenBleedAndPreservesVisibleConstantColour() throws {
        let width = 13, height = 5
        var pixels: [Float] = []
        for y in 0..<height { for x in 0..<width {
            let alpha: Float = x < 4 ? 0 : (y % 2 == 0 ? 0.25 : 1)
            pixels += [0.5, 0.2, 0.07, alpha]
        } }
        let input = try AlgorithmEvaluationRaster(width: width, height: height, pixels: pixels)
        var poisoned = input
        for p in stride(from: 0, to: pixels.count, by: 4) where input.pixels[p + 3] == 0 {
            poisoned.pixels[p] = 100; poisoned.pixels[p + 1] = -40; poisoned.pixels[p + 2] = 25
        }
        for control in Reference.Control.allCases {
            let reference = Reference(control: control, geometry: nativeGeometry(width))
            let result = try reference.render(input, settings: settings(control, 100))
            let hidden = try reference.render(poisoned, settings: settings(control, 100))
            #expect(result.sha256 == hidden.sha256)
            for p in stride(from: 0, to: pixels.count, by: 4) {
                #expect(result.pixels[p + 3] == input.pixels[p + 3])
                if input.pixels[p + 3] == 0 { #expect(Array(result.pixels[p..<(p + 4)]) == [0, 0, 0, 0]) }
                else { for channel in 0..<3 { #expect(abs(result.pixels[p + channel] - input.pixels[p + channel]) < 0.00003) } }
            }
        }
    }

    @Test func sourceAndParameterChangesAreIndependentAndDeterministic() throws {
        let input = try pattern(width: 256, height: 96), before = input.sha256
        var changed = input; changed.pixels[1000] += 0.3
        for control in Reference.Control.allCases {
            let reference = Reference(control: control, geometry: nativeGeometry(256))
            let first = try reference.render(input, settings: settings(control, 20))
            let repeated = try reference.render(input, settings: settings(control, 20))
            let stronger = try reference.render(input, settings: settings(control, 80))
            let otherSource = try reference.render(changed, settings: settings(control, 20))
            #expect(first.sha256 == repeated.sha256)
            #expect(first.sha256 != stronger.sha256 && first.sha256 != otherSource.sha256)
            #expect(input.sha256 == before)
        }
    }

    @Test(arguments: [(1, 1), (1, 7), (7, 1), (2, 2)])
    func tinyAndTransparentInputsRemainFinite(size: (Int, Int)) throws {
        let input = try pattern(width: size.0, height: size.1)
        let transparent = try AlgorithmEvaluationRaster(width: size.0, height: size.1,
            pixels: [Float](repeating: 0, count: size.0 * size.1 * 4))
        for control in Reference.Control.allCases {
            let reference = Reference(control: control, geometry: nativeGeometry(max(size.0, size.1)))
            #expect(try reference.render(input, settings: settings(control, 100)).pixels.allSatisfy { $0.isFinite })
            #expect(try reference.render(transparent, settings: settings(control, 100)).sha256 == transparent.sha256)
        }
    }

    @Test func invalidControlsGeometryAndRasterFailBeforeOutputPublication() throws {
        let input = try pattern(width: 3, height: 2)
        for control in Reference.Control.allCases {
            let reference = Reference(control: control, geometry: nativeGeometry(3))
            for value in [Double.nan, .infinity, -.infinity] {
                #expect(throws: Reference.Failure.self) { _ = try reference.render(input, settings: settings(control, value)) }
            }
            for key in [\EditSettings.exposure, \.contrast, \.shadows, \.highlights, \.whites, \.blacks,
                        \.texture, \.clarity, \.dehaze, \.vibrance, \.saturation, \.autoToneAmount,
                        control == .luminance ? \.colorNoiseReduction : \.luminanceNoiseReduction] {
                var edit = settings(control, 40); edit[keyPath: key] = 1
                #expect(throws: Reference.Failure.self) { _ = try reference.render(input, settings: edit) }
            }
            #expect(try reference.render(input, settings: settings(control, 1000)).pixels == reference.render(input, settings: settings(control, 100)).pixels)
            var invalid = input; invalid.pixels[0] = .nan
            #expect(throws: Reference.Failure.self) { _ = try reference.render(invalid, settings: .neutral) }
            invalid = input; invalid.pixels[3] = 1.1
            #expect(throws: Reference.Failure.self) { _ = try reference.render(invalid, settings: .neutral) }
            invalid = input; invalid.pixels.removeLast()
            #expect(throws: Reference.Failure.self) { _ = try reference.render(invalid, settings: .neutral) }
        }
        for geometry in [Reference.Geometry(nativeLong: 0, pixelsPerLongEdge: 10, inputSampling: .unknown),
                         .init(nativeLong: 100, pixelsPerLongEdge: .nan, inputSampling: .unknown),
                         .init(nativeLong: 100, pixelsPerLongEdge: 0, inputSampling: .areaAveraged)] {
            #expect(throws: Reference.Failure.self) { _ = try Reference(control: .luminance, geometry: geometry).render(input, settings: .neutral) }
        }
    }

    @Test func cancelledActiveAndNeutralRequestsPublishNoResult() async throws {
        let input = try pattern(width: 13, height: 9)
        for control in Reference.Control.allCases { for amount in [0.0, 60] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try Reference(control: control, geometry: nativeGeometry(13)).render(input, settings: settings(control, amount))
            }
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        } }
    }

    @Test(arguments: [8, 16], [false, true])
    func frozenProfileDepthAndAlphaBoundary(bits: Int, p3: Bool) throws {
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
        for control in Reference.Control.allCases {
            let reference = Reference(control: control, geometry: nativeGeometry(3))
            #expect(try reference.render(input, settings: .neutral).sha256 == input.sha256)
            let result = try reference.render(input, settings: settings(control, 60))
            #expect(result.pixels.allSatisfy { $0.isFinite })
            for p in stride(from: 0, to: input.pixels.count, by: 4) {
                #expect(result.pixels[p + 3] == input.pixels[p + 3])
                if input.pixels[p + 3] == 0 { #expect(Array(result.pixels[p..<(p + 4)]) == [0, 0, 0, 0]) }
            }
        }
    }

    private func nativeGeometry(_ long: Int) -> Reference.Geometry { .init(nativeLong: long, pixelsPerLongEdge: Double(long), inputSampling: .native) }
    private func settings(_ control: Reference.Control, _ amount: Double) -> EditSettings {
        var value = EditSettings.neutral
        if control == .luminance { value.luminanceNoiseReduction = amount } else { value.colorNoiseReduction = amount }
        return value
    }
    private func pattern(width: Int, height: Int) throws -> AlgorithmEvaluationRaster {
        var values: [Float] = []
        for i in 0..<(width * height) {
            let red: Float = 0.1 + Float(i % 31) / 50
            let green: Float = 0.1 + Float((i * 7) % 23) / 40
            let blue: Float = 0.1 + Float((i * 13) % 17) / 30
            values += [red, green, blue, 1]
        }
        return try .init(width: width, height: height, pixels: values)
    }
    private struct Oracle: Decodable {
        let upstream_commit: String
        let absolute_float_tolerance: Float, relative_float_tolerance: Float
        let cases: [Case]
        struct Case: Decodable {
            let control: String
            let width: Int, height: Int
            let amount: Double, scale: Double
            let sigma: Float?, epsilon: Float?, blend: Float
            let input: [[Float]], output: [[Float]]
        }
    }
}
