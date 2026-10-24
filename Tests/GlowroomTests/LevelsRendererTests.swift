import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Global levels Float rendering and graph integration")
struct LevelsRendererTests {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false
    ])

    @Test(arguments: [0.1, 1.0, 10.0])
    func atLeast1024GrayValuesMatchAnIndependentReference(gamma: Double) throws {
        let source = try encodedFixture(width: 1_024, height: 3) { x, row in
            let value = Double(x) / 1_023
            return (value, value, value, [0.0, 0.25, 1.0][row])
        }
        let levels = LevelsSettings(master: .init(gamma: gamma))
        let output = try apply(source, levels: levels)
        var previous = -Double.infinity
        for row in 0..<3 {
            let alpha = [0.0, 0.25, 1.0][row]
            for x in 0..<1_024 {
                let offset = (row * 1_024 + x) * 4
                let expected = decode(reference(Double(x) / 1_023, curve: levels.master)) * alpha
                for channel in 0..<3 { expectClose(output[offset + channel], expected) }
                expectClose(output[offset + 3], alpha)
                if row == 2 {
                    #expect(Double(output[offset]) >= previous - 0.000_001)
                    previous = Double(output[offset])
                }
                if row == 0 { #expect(Array(output[offset..<(offset + 4)]) == [0, 0, 0, 0]) }
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func colorFieldsUseIndividualChannelsBeforeTheMasterAndIndependentClamps(inputClamp: Bool, outputClamp: Bool) throws {
        let levels = LevelsSettings(
            master: .init(inputBlack: 0.02, inputWhite: 0.98, gamma: 1.15,
                          outputBlack: 0.01, outputWhite: 0.99, clampInput: inputClamp, clampOutput: outputClamp),
            red: .init(inputBlack: 0.05, inputWhite: 0.95, gamma: 1.3,
                       outputBlack: 0.02, outputWhite: 0.98, clampInput: inputClamp, clampOutput: outputClamp),
            green: .init(inputBlack: 0.03, inputWhite: 0.9, gamma: 0.75,
                         outputBlack: 0.01, outputWhite: 0.92, clampInput: inputClamp, clampOutput: outputClamp),
            blue: .init(gamma: 2, outputWhite: 0.96, clampInput: inputClamp, clampOutput: outputClamp))
        let source = try encodedFixture(width: 1_024) { x, _ in
            let value = Double(x) / 1_023
            return (1.5 * value - 0.2, 0.9 - 1.1 * value, 4 * value, 1)
        }
        let output = try apply(source, levels: levels)
        for x in 0..<1_024 {
            let value = Double(x) / 1_023
            let input = [1.5 * value - 0.2, 0.9 - 1.1 * value, 4 * value]
            let curves = [levels.red, levels.green, levels.blue]
            for channel in 0..<3 {
                let expected = reference(reference(input[channel], curve: curves[channel]), curve: levels.master)
                expectClose(output[x * 4 + channel], decode(expected))
            }
            expectClose(output[x * 4 + 3], 1)
        }
    }

    @Test(arguments: [0.1, 1.0, 10.0])
    func exactInputAnchorsAndConstantOutputsRemainWellDefined(gamma: Double) throws {
        let source = try encodedFixture(width: 4) { x, _ in
            let value = [0.1, 0.9, -0.25, 4.0][x]
            return (value, value, value, 1)
        }
        let anchored = LevelsSettings(master: .init(inputBlack: 0.1, inputWhite: 0.9,
            gamma: gamma, outputBlack: 0.2, outputWhite: 0.8))
        let output = try apply(source, levels: anchored)
        for channel in 0..<3 {
            expectClose(output[channel], decode(0.2))
            expectClose(output[4 + channel], decode(0.8))
        }
        let constant = LevelsSettings(master: .init(gamma: gamma, outputBlack: 0.4, outputWhite: 0.4))
        let flat = try apply(source, levels: constant)
        for index in stride(from: 0, to: flat.count, by: 4) {
            for channel in 0..<3 { expectClose(flat[index + channel], decode(0.4)) }
        }
    }

    @Test func unclampedHDRAndNegativeValuesSurviveWithoutChangingAlpha() throws {
        let source = try encodedFixture(width: 5, height: 3) { x, row in
            let value = [-0.25, 0, 0.25, 1, 4.0][x]
            return (value, value * 0.7, value * 0.4, [0.0, 0.25, 1.0][row])
        }
        let levels = LevelsSettings(master: .init(gamma: 2))
        let output = try apply(source, levels: levels)
        #expect(output[(2 * 5) * 4] < 0)
        #expect(output[(2 * 5 + 4) * 4] > 1)
        for row in 0..<3 {
            let alpha = [0.0, 0.25, 1.0][row]
            for x in 0..<5 {
                let value = [-0.25, 0, 0.25, 1, 4.0][x]
                for (channel, factor) in [1.0, 0.7, 0.4].enumerated() {
                    expectClose(output[(row * 5 + x) * 4 + channel], decode(reference(value * factor, curve: levels.master)) * alpha)
                }
                expectClose(output[(row * 5 + x) * 4 + 3], alpha)
            }
        }
    }

    @Test(arguments: [1.0, 10.0])
    func aSmallValidInputSpanRetainsFiniteHDRAndNegativeValues(gamma: Double) throws {
        // This span remains above 1e-4 after conversion to actual Float uniforms.
        let white = 0.000_100_01
        let source = try encodedFixture(width: 5) { x, _ in
            let value = [-0.25, 0, white, 1, 4][x]
            return (value, value, value, 1)
        }
        let levels = LevelsSettings(master: .init(inputWhite: white, gamma: gamma))
        let output = try apply(source, levels: levels)
        for x in 0..<5 {
            let value = [-0.25, 0, white, 1, 4][x]
            for channel in 0..<3 {
                expectClose(output[x * 4 + channel], decode(reference(value, curve: levels.master)))
            }
            expectClose(output[x * 4 + 3], 1)
        }
    }

    @Test func unsafePowersAndTheFollowingSRGBDecodeFailBeforeReturningAGraph() throws {
        let input = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let safeRange = LevelsRenderer.InputRange(red: 0...4, green: 0...4, blue: 0...4)
        for curve in [LevelsCurve(inputWhite: 0.000_100_01, gamma: 0.1),
                      LevelsCurve(inputWhite: 0.000_100_01, gamma: 0.1, clampOutput: true),
                      LevelsCurve(inputWhite: 0.000_100_01, gamma: 0.1, outputBlack: 0.5, outputWhite: 0.5)] {
            try curve.validate()
            #expect(throws: EditRenderError.unrepresentableLevels) {
                try LevelsRenderer.apply(to: input, settings: .init(master: curve), extent: input.extent,
                                         context: Self.context, inputRange: safeRange)
            }
            #expect(throws: EditRenderError.unrepresentableLevels) {
                try LevelsRenderer.apply(to: input, settings: .init(master: .init(outputBlack: 0.5, outputWhite: 0.5), red: curve),
                    extent: input.extent, context: Self.context, inputRange: safeRange)
            }
        }
        // 100^10 fits Float, but decoding that encoded value to linear sRGB
        // raises it to 2.4 and overflows. The lazy graph must be refused too.
        let decodeRange = LevelsRenderer.InputRange(red: 0...100, green: 0...100, blue: 0...100)
        #expect(throws: EditRenderError.unrepresentableLevels) {
            try LevelsRenderer.apply(to: input, settings: .init(master: .init(gamma: 0.1)),
                extent: input.extent, context: Self.context, inputRange: decodeRange)
        }
        let measured = try encodedFixture(width: 2) { x, _ in
            let value = x == 0 ? 0.25 : 100.0
            return (value, value, value, 1)
        }
        let graph = CIImage(cgImage: measured.image)
        #expect(throws: EditRenderError.unrepresentableLevels) {
            try LevelsRenderer.apply(to: graph, settings: .init(master: .init(gamma: 0.1)),
                extent: graph.extent, context: Self.context)
        }
    }

    @Test func theCertifiedInputRangeContainsFineFloatValuesAndUnsampledOutliers() throws {
        let source = try linearFixture(width: 1_024) { x, _ in
            let fine = 0.180_001 + Double(x % 7) * 0.000_001
            return (x == 1 ? 4 : fine, x == 1_022 ? -0.123_4 : fine + 0.000_002, fine - 0.000_003, 1)
        }
        let graph = CIImage(cgImage: source.image)
        let range = try LevelsRenderer.inputRange(of: graph, extent: graph.extent, context: Self.context)
        let pixels = try read(graph)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            #expect(range.red.contains(encode(Double(pixels[offset]))))
            #expect(range.green.contains(encode(Double(pixels[offset + 1]))))
            #expect(range.blue.contains(encode(Double(pixels[offset + 2]))))
        }
        #expect(range.red.upperBound >= encode(4))
        #expect(range.green.lowerBound <= encode(Double(Float(-0.123_4))))
        #expect(range.blue.upperBound - range.blue.lowerBound < 0.000_1,
            "The source must retain Float differences smaller than native half precision")
    }

    @Test func aLaterPresenceOverflowIsRejectedEvenWhenLevelsAloneAreRepresentable() throws {
        let source = try linearFixture(width: 65, height: 65) { x, y in
            let value = x == 32 && y == 32 ? 4.0 : 0.0
            return (value, value, value, 1)
        }
        let levels = LevelsSettings(master: .init(inputWhite: 0.0455, gamma: 0.1))
        // At the HDR pixel these levels produce about 2.6367e38 linear RGB,
        // below Floatmax. Positive texture then adds enough encoded detail to
        // overflow the following sRGB decode against the black surroundings.
        let expectedPeak = decode(reference(encode(4), curve: levels.master))
        #expect(expectedPeak > Double(Float.greatestFiniteMagnitude) * 0.7)
        #expect(expectedPeak < Double(Float.greatestFiniteMagnitude) * 0.8)
        let baseline = try apply(source, levels: levels)
        #expect(baseline[(32 * 65 + 32) * 4] > Float.greatestFiniteMagnitude * 0.7)
        let settings = EditSettings(texture: 100, levels: levels, toneProcessingVersion: .consistentV2)
        #expect(throws: EditRenderError.unrepresentableLevels) {
            try EditRenderer.filterGraph(source.image, settings: settings)
        }
        #expect(throws: EditRenderError.unrepresentableLevels) {
            try EditRenderer.render(source, settings: settings)
        }
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func anIsolatedNonFiniteVisiblePixelCannotHideInARangeReduction(invalid: Double) throws {
        let source = try linearFixture(width: 1_024) { x, _ in
            (x == 1 ? invalid : 0.18, 0.18, 0.18, 1)
        }
        let graph = CIImage(cgImage: source.image)
        #expect(throws: EditRenderError.unrepresentableLevels) {
            try LevelsRenderer.apply(to: graph, settings: .init(master: .init(gamma: 2)),
                                     extent: graph.extent, context: Self.context)
        }
    }

    @Test func aFullyTransparentSourceRemainsCanonicalWithoutVisibleRangeEvidence() throws {
        let source = try encodedFixture(width: 8) { _, _ in (0.8, 0.4, 4, 0) }
        let output = try apply(source, levels: .init(master: .init(gamma: 2, outputBlack: 0.1)))
        #expect(output == [Float](repeating: 0, count: 8 * 4))
    }

    @Test func neutralLevelsReturnTheSameGraphAndPreserveLegacyPixelsExactly() throws {
        let source = try byteFixture(width: 64, height: 8)
        let original = CIImage(cgImage: source.image)
        let unchanged = try LevelsRenderer.apply(to: original, settings: .neutral,
            extent: original.extent, context: Self.context)
        #expect(unchanged === original)
        let legacy = EditSettings(exposure: 0.4, contrast: 15, shadows: 20, texture: 10,
            autoToneAmount: 35, developColor: .init(temperature: 7_500, tint: -12))
        let bytes = try ArtifactJSONCodec.encode(legacy)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("levels"))
        let restored = try ArtifactJSONCodec.decode(EditSettings.self, from: bytes)
        #expect(restored.toneProcessingVersion == .legacyV1 && restored.levels == .neutral)
        let old = try EditRenderer.render(source, settings: legacy)
        let reopened = try EditRenderer.render(source, settings: restored)
        #expect(try rgba8(old.image) == rgba8(reopened.image))
    }

    @Test func theNamedInputGraphIncludesUpstreamGlobalsAndExcludesLevelsAndLaterStages() throws {
        let source = try byteFixture(width: 64, height: 8)
        let raster = try LocalMaskRaster(width: 1, height: 1, bytes: Data([255]))
        let layer = try LocalAdjustment(name: "Excluded local", mask: .init(shape: .subject(raster), feather: 0), settings: .init(exposure: 2))
        let geometry = DevelopGeometry(crop: try .init(x: 0.2, y: 0.1, width: 0.5, height: 0.6),
                                      quarterTurns: 1, flipHorizontal: true)
        let settings = EditSettings(exposure: 0.5, contrast: 20, shadows: 15, texture: 30, clarity: 20,
            naturalBalanceAmount: 25, localAdjustments: [layer],
            developColor: .init(temperature: 7_500, tint: 12, profile: .vivid, isMonochrome: true),
            developGeometry: geometry, levels: .init(master: .init(gamma: 2)), toneProcessingVersion: .consistentV2)
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        let actualGraph = try EditRenderer.globalLevelsInputGraph(source, settings: settings, session: session)
        var prefixOnly = settings
        prefixOnly.levels = .neutral; prefixOnly.texture = 0; prefixOnly.clarity = 0
        prefixOnly.developColor.isMonochrome = false
        prefixOnly.localAdjustments = []; prefixOnly.developGeometry = .neutral
        let expectedGraph = try EditRenderer.globalGraph(source, settings: prefixOnly, session: session)
        #expect(actualGraph.extent == CGRect(x: 0, y: 0, width: 64, height: 8))
        let actual = try read(actualGraph), expected = try read(expectedGraph)
        for index in actual.indices { expectClose(actual[index], Double(expected[index])) }
        let raw = try read(CIImage(cgImage: source.image))
        #expect(zip(actual, raw).contains { abs($0 - $1) > 0.001 }, "The fixture must exercise active upstream corrections")
    }

    @Test func rangeValidationIsReusedOnlyWhileItsUpstreamInputRemainsTheSame() throws {
        let source = try byteFixture(width: 64, height: 8)
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        var settings = EditSettings(levels: .init(master: .init(gamma: 1.2)), toneProcessingVersion: .consistentV2)
        _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics() == .init(measurements: 1, cacheHits: 0))
        settings.levels.master.gamma = 1.5
        _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics() == .init(measurements: 1, cacheHits: 1))

        let coverage = try LocalMaskRaster(width: 1, height: 1, bytes: Data([255]))
        settings.texture = 10; settings.clarity = 10; settings.developColor.isMonochrome = true
        settings.localAdjustments = [try .init(name: "Excluded", mask: .init(shape: .subject(coverage), feather: 0), settings: .init(exposure: 1))]
        settings.developGeometry = .init(crop: try .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8), quarterTurns: 1)
        _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics() == .init(measurements: 1, cacheHits: 2))

        settings.exposure = 0.25
        _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics().measurements == 2)
        settings.developColor.temperature = 7_000
        _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics().measurements == 3)
        settings.toneProcessingVersion = .legacyV1
        _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics().measurements == 4)
        let replacementSource = try byteFixture(width: 64, height: 8)
        _ = try EditRenderer.globalGraph(replacementSource, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics().measurements == 5)
        settings.levels = .neutral
        _ = try EditRenderer.globalGraph(replacementSource, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics().measurements == 5, "Neutral levels must skip range analysis entirely")
    }

    @Test func equivalentResizedRastersShareProofWhileNewDimensionsOrSourcesDoNot() throws {
        let source = try byteFixture(width: 64, height: 16)
        let first = try EditRenderer.resized(source, width: 32, height: 8, priority: .selected,
                                            toneProcessingVersion: .consistentV2)
        let second = try EditRenderer.resized(source, width: 32, height: 8, priority: .selected,
                                             toneProcessingVersion: .consistentV2)
        #expect(first.image !== second.image)
        #expect(first.rangeSourceIdentity != source.rangeSourceIdentity)
        #expect(first.rangeSourceIdentity == second.rangeSourceIdentity)
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        let settings = EditSettings(levels: .init(master: .init(gamma: 1.3)), toneProcessingVersion: .consistentV2)
        _ = try EditRenderer.globalGraph(first, settings: settings, session: session)
        _ = try EditRenderer.globalGraph(second, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics() == .init(measurements: 1, cacheHits: 1))
        let smaller = try EditRenderer.resized(source, width: 16, height: 4, priority: .selected,
                                              toneProcessingVersion: .consistentV2)
        _ = try EditRenderer.globalGraph(smaller, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics().measurements == 2)
        let twoStep = try EditRenderer.resized(first, width: 16, height: 4, priority: .selected,
                                              toneProcessingVersion: .consistentV2)
        #expect(twoStep.rangeSourceIdentity != smaller.rangeSourceIdentity,
            "The same final dimensions do not make two resampling paths equivalent")
        _ = try EditRenderer.globalGraph(twoStep, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics().measurements == 3)
        let otherSource = try byteFixture(width: 64, height: 16)
        let otherProxy = try EditRenderer.resized(otherSource, width: 32, height: 8, priority: .selected,
                                                 toneProcessingVersion: .consistentV2)
        #expect(otherProxy.rangeSourceIdentity != source.rangeSourceIdentity)
        #expect(otherProxy.rangeSourceIdentity != first.rangeSourceIdentity)
        _ = try EditRenderer.globalGraph(otherProxy, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics().measurements == 4)
    }

    @Test func halfAndFloatResizesNeverReuseEachOthersCertifiedRange() throws {
        let source = try linearFixture(width: 64, height: 16) { x, y in
            let value = 0.180_001 + Double(x + y) * 0.000_001
            return (value, value + 0.000_002, value - 0.000_003, 1)
        }
        let half = try EditRenderer.resized(source, width: 32, height: 8, priority: .selected,
                                           toneProcessingVersion: .legacyV1)
        let otherHalf = try EditRenderer.resized(source, width: 32, height: 8, priority: .selected,
                                                toneProcessingVersion: .legacyV1)
        let precise = try EditRenderer.resized(source, width: 32, height: 8, priority: .selected,
                                              toneProcessingVersion: .consistentV2)
        #expect(half.image.bitsPerComponent == 16 && precise.image.bitsPerComponent == 32)
        #expect(half.rangeSourceIdentity == otherHalf.rangeSourceIdentity)
        #expect(half.rangeSourceIdentity != precise.rangeSourceIdentity)
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        let settings = EditSettings(levels: .init(master: .init(gamma: 1.3)), toneProcessingVersion: .consistentV2)
        _ = try EditRenderer.globalGraph(half, settings: settings, session: session)
        _ = try EditRenderer.globalGraph(otherHalf, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics() == .init(measurements: 1, cacheHits: 1))
        _ = try EditRenderer.globalGraph(precise, settings: settings, session: session)
        #expect(session.levelsRangeDiagnostics() == .init(measurements: 2, cacheHits: 1))
    }

    @Test(arguments: [UInt8(0), 128, 255])
    func everyLocalBlendBranchUsesGlobalLevelsExactlyOnce(coverage: UInt8) throws {
        let source = try encodedFixture(width: 128, height: 3) { x, row in
            let value = 0.1 + 0.7 * Double(x) / 127
            return (value, value * 0.75, value * 0.5, [0.0, 0.25, 1.0][row])
        }
        let levels = LevelsSettings(master: .init(gamma: 2))
        let raster = try LocalMaskRaster(width: 1, height: 1, bytes: Data([coverage]))
        let correction = LocalAdjustmentSettings(exposure: 0.7)
        let layer = try LocalAdjustment(name: "Levels once", mask: .init(shape: .subject(raster), feather: 0), settings: correction)
        let settings = EditSettings(localAdjustments: [layer], levels: levels, toneProcessingVersion: .consistentV2)
        let actual = try read(EditRenderer.filterGraph(source.image, settings: settings))
        let baseline = try apply(source, levels: levels)
        let gain = 1 + Double(coverage) / 255 * (exp2(0.7) - 1)
        for offset in stride(from: 0, to: actual.count, by: 4) {
            for channel in 0..<3 { expectClose(actual[offset + channel], Double(baseline[offset + channel]) * gain) }
            expectClose(actual[offset + 3], Double(baseline[offset + 3]))
        }
    }

    @Test func previewAndExportUseTheSameLevelsAndSDRTargetProfileBoundary() throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = try #require(CGColorSpace(name: name))
            let source = try byteFixture(width: 64, height: 16, space: space)
            let levels = LevelsSettings(master: .init(inputBlack: 0.03, inputWhite: 0.96, gamma: 1.4), red: .init(gamma: 0.8))
            let settings = EditSettings(exposure: 0.2, shadows: 10, levels: levels, toneProcessingVersion: .consistentV2)
            let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
            let preview = try EditRenderer.render(source, settings: settings, session: session)
            let graph = try EditRenderer.filterGraph(source.image, settings: settings)
            let exported = try #require(session.context(for: settings).createCGImage(graph, from: graph.extent,
                format: .RGBA8, colorSpace: space, deferred: false))
            #expect(preview.image.colorSpace?.name == space.name)
            let actual = try rgba8(preview.image), expected = try rgba8(exported)
            #expect(actual.count == expected.count)
            for index in actual.indices { #expect(abs(Int(actual[index]) - Int(expected[index])) <= 1) }
        }
    }

    @Test(arguments: [ToneProcessingVersion.legacyV1, .consistentV2])
    func hdrRasterRetainsCertifiedLevelsAboveTheHalfFloatCeiling(version: ToneProcessingVersion) throws {
        let source = try linearFixture(width: 3) { x, _ in
            (4, 4, 4, [0.0, 0.25, 1.0][x])
        }
        let levels = LevelsSettings(master: .init(inputWhite: 0.3, gamma: 0.1))
        let settings = EditSettings(developColor: .init(hdrEnabled: true), levels: levels,
                                    toneProcessingVersion: version)
        let rendered = try EditRenderer.render(source, settings: settings)
        #expect(rendered.image.bitsPerComponent == 32)
        #expect(rendered.image.bitmapInfo.contains(.floatComponents))
        let output = try read(CIImage(cgImage: rendered.image))
        let peak = decode(reference(encode(4), curve: levels.master))
        #expect(peak > 65_504)
        for x in 0..<3 {
            let alpha = [0.0, 0.25, 1.0][x]
            for channel in 0..<3 { expectClose(output[x * 4 + channel], peak * alpha) }
            expectClose(output[x * 4 + 3], alpha)
        }
    }

    @Test func hdrV2RasterRetainsFloatPrecisionWithoutAnyLevels() throws {
        let source = try linearFixture(width: 3) { x, _ in
            (4_096, 4_096, 4_096, [0.0, 0.25, 1.0][x])
        }
        let settings = EditSettings(exposure: 5, developColor: .init(hdrEnabled: true), toneProcessingVersion: .consistentV2)
        let rendered = try EditRenderer.render(source, settings: settings)
        #expect(rendered.image.bitsPerComponent == 32)
        #expect(rendered.image.bitmapInfo.contains(.floatComponents))
        let output = try read(CIImage(cgImage: rendered.image))
        for x in 0..<3 {
            let alpha = [0.0, 0.25, 1.0][x]
            for channel in 0..<3 { expectClose(output[x * 4 + channel], 4_096 * exp2(5) * alpha) }
            expectClose(output[x * 4 + 3], alpha)
        }
        #expect(output[8] > 65_504)
    }

    @Test func automaticAndRequestedSoftwareRastersMatchTheIndependentLevelsReference() throws {
        let samples: [[Double]] = [[-0.08, 0.25, 4], [0.25, 1, -0.04], [1, 4, 0.25], [4, -0.02, 1]]
        let source = try linearFixture(width: samples.count, height: 3) { x, row in
            (samples[x][0], samples[x][1], samples[x][2], [0.0, 0.25, 1.0][row])
        }
        let levels = LevelsSettings(
            master: .init(inputBlack: 0.01, inputWhite: 0.99, gamma: 1.2, outputBlack: 0.01, outputWhite: 0.98),
            red: .init(inputBlack: 0.02, inputWhite: 0.9, gamma: 1.3, outputBlack: 0.01, outputWhite: 0.95),
            green: .init(inputBlack: 0.01, inputWhite: 0.93, gamma: 0.75, outputBlack: 0.02, outputWhite: 0.98),
            blue: .init(gamma: 2, outputWhite: 0.96))
        let settings = EditSettings(developColor: .init(hdrEnabled: true), levels: levels, toneProcessingVersion: .consistentV2)
        let automatic = EditRenderer.Session(lowPriority: true, softwareRenderer: false)
        let requestedSoftware = EditRenderer.Session(lowPriority: true, softwareRenderer: true)
        let normalRaster = try EditRenderer.render(source, settings: settings, session: automatic)
        let requestedRaster = try EditRenderer.render(source, settings: settings, session: requestedSoftware)
        for raster in [normalRaster.image, requestedRaster.image] {
            #expect(raster.bitsPerComponent == 32 && raster.bitmapInfo.contains(.floatComponents))
            #expect(raster.colorSpace?.name == Self.space.name)
        }
        // Read actual output CGImages, rather than rendering one common lazy
        // graph twice. Software preference does not prove actual CPU execution.
        let normal = try read(CIImage(cgImage: normalRaster.image))
        let requested = try read(CIImage(cgImage: requestedRaster.image))
        let input = try read(CIImage(cgImage: source.image))
        let curves = [levels.red, levels.green, levels.blue]
        for offset in stride(from: 0, to: input.count, by: 4) {
            let alpha = Double(input[offset + 3])
            for channel in 0..<3 {
                let straight = alpha > 0 ? Double(input[offset + channel]) / alpha : 0
                let encoded = reference(reference(encode(straight), curve: curves[channel]), curve: levels.master)
                let expected = alpha > 0 ? decode(encoded) * alpha : 0
                // The documented Levels Float tolerance is 1e-4 + 1e-5*abs(ref).
                expectClose(normal[offset + channel], expected)
                expectClose(requested[offset + channel], expected)
                expectClose(requested[offset + channel], Double(normal[offset + channel]))
            }
            expectClose(normal[offset + 3], alpha)
            expectClose(requested[offset + 3], alpha)
            if alpha == 0 {
                #expect(Array(normal[offset..<(offset + 4)]) == [0, 0, 0, 0])
                #expect(Array(requested[offset..<(offset + 4)]) == [0, 0, 0, 0])
            }
        }
        #expect(normal.contains { $0 < 0 } && requested.contains { $0 < 0 })
        #expect(normal.contains { $0 > 1 } && requested.contains { $0 > 1 })
    }

    @Test func frozenReplacementPixelsReceiveTheSameGlobalLevelsAndLocalSuffix() throws {
        let source = try byteFixture(width: 64, height: 32, constant: [48, 48, 48, 128])
        let donor = [UInt8(100), 140, 180, 255]
        let replacement = try DevelopRetouchReplacement(bounds: .init(x: 0.5, y: 0, width: 0.5, height: 1),
            width: 2, height: 2, rgba: Data(Array(repeating: donor, count: 4).flatMap { $0 }))
        let patchMask = try LocalMaskRaster(width: 2, height: 1, bytes: Data([0, 255]))
        let stroke = try DevelopRetouchStroke(source: .init(x: 0.1, y: 0.5), target: .init(x: 0.75, y: 0.5),
            radius: 0.1, mask: patchMask, replacement: replacement)
        let full = try LocalMaskRaster(width: 1, height: 1, bytes: Data([255]))
        let layer = try LocalAdjustment(name: "Same suffix", mask: .init(shape: .subject(full), feather: 0), settings: .init(exposure: 0.25))
        let settings = EditSettings(exposure: 0.2, localAdjustments: [layer],
            developGeometry: .init(retouchStrokes: [stroke]), levels: .init(master: .init(gamma: 1.7)),
            toneProcessingVersion: .consistentV2)
        let actual = try read(EditRenderer.filterGraph(source.image, settings: settings))
        // Frozen bytes are straight RGB. Avoid introducing a second 8-bit
        // premultiplication quantization in the independent donor reference.
        let donorSource = try encodedFixture(width: 64, height: 32) { _, _ in
            (100.0 / 255, 140.0 / 255, 180.0 / 255, 128.0 / 255)
        }
        var referenceSettings = settings; referenceSettings.developGeometry = .neutral
        let expected = try read(EditRenderer.filterGraph(donorSource.image, settings: referenceSettings))
        let baseline = try read(EditRenderer.filterGraph(source.image, settings: referenceSettings))
        for channel in 0..<4 {
            expectClose(actual[(16 * 64 + 48) * 4 + channel], Double(expected[(16 * 64 + 48) * 4 + channel]))
            expectClose(actual[(16 * 64 + 8) * 4 + channel], Double(baseline[(16 * 64 + 8) * 4 + channel]))
        }
    }

    private func apply(_ source: PreviewBitmap, levels: LevelsSettings) throws -> [Float] {
        let image = CIImage(cgImage: source.image)
        return try read(LevelsRenderer.apply(to: image, settings: levels, extent: image.extent, context: Self.context))
    }

    private func encodedFixture(width: Int, height: Int = 1,
                                pixel: (Int, Int) -> (Double, Double, Double, Double)) throws -> PreviewBitmap {
        try linearFixture(width: width, height: height) { x, y in
            let (red, green, blue, alpha) = pixel(x, y)
            return (decode(red), decode(green), decode(blue), alpha)
        }
    }

    private func linearFixture(width: Int, height: Int = 1,
                               pixel: (Int, Int) -> (Double, Double, Double, Double)) throws -> PreviewBitmap {
        var pixels = [Float]()
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue, alpha) = pixel(x, y)
                pixels += [Float(red * alpha), Float(green * alpha), Float(blue * alpha), Float(alpha)]
            }
        }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width * 16, space: Self.space,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image, rangeProvenance: .extended(nominalSDRWhite: 1))
    }

    private func byteFixture(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                             constant: [UInt8]? = nil) throws -> PreviewBitmap {
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let rgba = constant ?? [UInt8(30 + x * 190 / max(1, width - 1)), UInt8(40 + y * 150 / max(1, height - 1)), 120, 255]
                let alpha = Int(rgba[3])
                pixels += rgba.prefix(3).map { UInt8(Int($0) * alpha / 255) } + [rgba[3]]
            }
        }
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image, rangeProvenance: .sdrDecoded)
    }

    private func read(_ graph: CIImage) throws -> [Float] {
        let width = Int(graph.extent.width), height = Int(graph.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { buffer in
            Self.context.render(graph, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                bounds: graph.extent, format: .RGBAf, colorSpace: Self.space)
        }
        #expect(values.allSatisfy { $0.isFinite })
        return values
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try values.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return values
    }

    private func expectClose(_ actual: Float, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.isFinite && expected.isFinite && abs(Double(actual) - expected) <= 0.000_1 + 0.000_01 * abs(expected),
            "Levels Float output \(actual) differs from independent reference \(expected)", sourceLocation: sourceLocation)
    }

    /// Independent scalar definition. It intentionally calls neither the
    /// production LevelsCurve evaluator nor the shared transfer helpers.
    private func reference(_ input: Double, curve: LevelsCurve) -> Double {
        var u = (input - curve.inputBlack) / (curve.inputWhite - curve.inputBlack)
        if curve.clampInput { u = min(max(u, 0), 1) }
        let v = u > 0 ? pow(u, 1 / curve.gamma) : u
        let output = curve.outputBlack + v * (curve.outputWhite - curve.outputBlack)
        return curve.clampOutput ? min(max(output, 0), 1) : output
    }

    private func decode(_ encoded: Double) -> Double {
        let a = abs(encoded)
        let linear = a <= 0.040_45 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return encoded < 0 ? -linear : linear
    }

    private func encode(_ linear: Double) -> Double {
        let a = abs(linear)
        let encoded = a <= 0.003_130_8 ? 12.92 * a : 1.055 * pow(a, 1 / 2.4) - 0.055
        return linear < 0 ? -encoded : encoded
    }
}
