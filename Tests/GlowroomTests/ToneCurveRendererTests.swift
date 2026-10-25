import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Point curves Float renderer quality gate")
struct ToneCurveRendererTests {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    @Test func documented4097ValueMatrixMatchesIndependentDoubleReference() throws {
        let s = ToneCurve(points: [.init(x: 0, y: 0.02), .init(x: 0.25, y: 0.15), .init(x: 0.75, y: 0.85), .init(x: 1, y: 0.98)])
        let channel = ToneCurve(points: [.init(x: 0, y: 0.05), .init(x: 0.4, y: 0.5), .init(x: 1, y: 0.95)])
        let fixtures = [ToneCurveSettings.neutral, .init(master: s), .init(red: channel), .init(green: channel), .init(blue: channel), .init(master: s, red: channel, green: s)]
        for settings in fixtures {
            let pixels = (0...4096).flatMap { index -> [Float] in
                let value = SignedSRGB.decode(Double(index) / 4096)
                return [Float(value), Float(value), Float(value), 1]
            }
            let output = try render(pixels, settings: settings)
            var maximumError = 0.0
            for index in 0...4096 {
                let x = Double(index) / 4096
                for (component, curve) in [settings.red, settings.green, settings.blue].enumerated() {
                    let expected = reference(reference(x, curve: curve), curve: settings.master)
                    let actual = SignedSRGB.encode(Double(output[index * 4 + component]))
                    maximumError = max(maximumError, abs(actual - expected))
                }
                #expect(output[index * 4 + 3] == 1)
            }
            #expect(maximumError <= 0.0001)
        }
    }

    @Test func extremeKnotsRemainFiniteMonotoneAndAlphaIsUnchanged() throws {
        let extreme = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.001, y: 0.7), .init(x: 0.501, y: 0.7), .init(x: 0.502, y: 1), .init(x: 1, y: 1)])
        let settings = ToneCurveSettings(master: extreme)
        for alpha: Float in [0, 0.25, 1] {
            let pixels = (0...4096).flatMap { index -> [Float] in
                let v = Float(SignedSRGB.decode(Double(index) / 4096)) * alpha
                return [v, v, v, alpha]
            }
            let output = try render(pixels, settings: settings)
            var previous: Float = -.infinity
            for index in 0...4096 {
                #expect(output[index * 4].isFinite)
                #expect(output[index * 4] >= previous - 0.000_001)
                #expect(output[index * 4 + 3] == alpha)
                previous = output[index * 4]
            }
        }
    }

    @Test func negativeP3CoordinatesHDRGrayAndPartialTransparencyRetainExtendedRange() throws {
        let settings = ToneCurveSettings(master: .init(points: [.init(x: 0, y: 0.02), .init(x: 0.5, y: 0.55), .init(x: 1, y: 0.98)]))
        // Fixed P3-red/green converted to the linear-sRGB working coordinates,
        // plus HDR gray and translucent extended-gamut input. No 8-bit fixture.
        let straight: [[Float]] = [[1.224745, -0.042058, -0.019642], [-0.224904, 1.042081, -0.078655], [4, 4, 4], [-0.25, 0.2, 2]]
        for alpha: Float in [0.25, 1] {
            let pixels = straight.flatMap { $0.map { $0 * alpha } + [alpha] }
            let output = try render(pixels, settings: settings)
            for (index, rgb) in straight.enumerated() {
                for channel in 0..<3 {
                    let expected = SignedSRGB.decode(reference(SignedSRGB.encode(Double(rgb[channel])), curve: settings.master)) * Double(alpha)
                    #expect(abs(Double(output[index * 4 + channel]) - expected) < 0.0001)
                }
                #expect(output[index * 4 + 3] == alpha)
            }
            #expect(output[1] < 0)
            #expect(output[2 * 4] / alpha > 1)
            #expect(abs(output[2 * 4] - output[2 * 4 + 1]) < 0.000001)
        }
    }

    @Test func neutralPathReturnsTheExactInputGraph() throws {
        let pixels: [Float] = [-0.2, 0.1, 2, 0.5]
        let source = image(pixels)
        #expect(try ToneCurveRenderer.apply(to: source, settings: .neutral, extent: source.extent, context: Self.context) === source)
    }

    @Test func curveDraggingReusesTheUpstreamRangeAndLevelsChangesInvalidateIt() throws {
        let pixels: [Float] = [0.04, 0.1, 0.3, 1, 1.2, 0.2, -0.1, 1]
        let source = try bitmap(pixels)
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        var settings = EditSettings(toneCurves: .init(master: .init(points: [.init(x: 0, y: 0.02), .init(x: 1, y: 0.98)])), toneProcessingVersion: .consistentV2)
        _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        #expect(session.toneCurveRangeDiagnostics().measurements == 1)
        for value in [0.04, 0.06, 0.08] {
            settings.toneCurves.master.points[0].y = value
            _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        }
        #expect(session.toneCurveRangeDiagnostics().measurements == 1)
        #expect(session.toneCurveRangeDiagnostics().cacheHits == 3)
        settings.levels.master.gamma = 1.1
        _ = try EditRenderer.globalGraph(source, settings: settings, session: session)
        #expect(session.toneCurveRangeDiagnostics().measurements == 2)
        _ = try EditRenderer.globalGraph(try bitmap(pixels), settings: settings, session: session)
        #expect(session.toneCurveRangeDiagnostics().measurements == 3)
    }

    @Test func channelsThenMasterFollowLevelsAndPreviewMatchesTheExportGraph() throws {
        let source = try bitmap([0.1, 0.2, 0.3, 1, 0.4, 0.1, 0.6, 1])
        let curve = ToneCurve(points: [.init(x: 0, y: 0.02), .init(x: 0.5, y: 0.6), .init(x: 1, y: 0.98)])
        let settings = EditSettings(levels: .init(master: .init(gamma: 1.2)), toneCurves: .init(master: curve, red: curve), toneProcessingVersion: .consistentV2)
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        let preview = try EditRenderer.render(source, settings: settings, session: session)
        let graph = try EditRenderer.filterGraph(source.image, settings: settings)
        let exported = try #require(session.context(for: settings).createCGImage(graph, from: graph.extent,
            format: .RGBAf, colorSpace: Self.space, deferred: false))
        let actual = read(CIImage(cgImage: preview.image)), expected = read(CIImage(cgImage: exported))
        for index in actual.indices { #expect(abs(actual[index] - expected[index]) < 0.0001) }
        let raw = [0.1, 0.2, 0.3, 1, 0.4, 0.1, 0.6, 1]
        for pixel in 0..<2 {
            for (channel, curve) in [settings.toneCurves.red, settings.toneCurves.green, settings.toneCurves.blue].enumerated() {
                let encoded = SignedSRGB.encode(raw[pixel * 4 + channel])
                let leveled = pow(encoded, 1 / 1.2)
                let result = SignedSRGB.decode(reference(reference(leveled, curve: curve), curve: settings.toneCurves.master))
                #expect(abs(Double(expected[pixel * 4 + channel]) - result) < 0.0001)
            }
        }
    }

    @Test func frozenRetouchRangeProofsAreReusedAndPrunedWhenPixelsOrPlacementChange() throws {
        let source = try bitmap([0.1, 0.2, 0.3, 1, 0.4, 0.1, 0.6, 1])
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: true)
        let id = UUID(), bounds = try DevelopCropRect(x: 0, y: 0, width: 0.5, height: 1)
        func stroke(byte: UInt8, offset: Double = 0) throws -> DevelopRetouchStroke {
            try DevelopRetouchStroke(id: id, source: .init(x: 0.1, y: 0.2), target: .init(x: 0.3, y: 0.4), radius: 0.1,
                replacement: .init(bounds: bounds, width: 1, height: 1, rgba: Data([byte, 64, 128, 255]), offsetX: offset))
        }
        var settings = EditSettings(levels: .init(master: .init(gamma: 1.1)),
            toneCurves: .init(master: .init(points: [.init(x: 0, y: 0.02), .init(x: 1, y: 0.98)])), toneProcessingVersion: .consistentV2)
        settings.developGeometry.retouchStrokes = [try stroke(byte: 128)]
        _ = try EditRenderer.render(source, settings: settings, session: session)
        #expect(session.replacementToneCurveRangeDiagnostics().measurements == 2)
        for value in [0.04, 0.06, 0.08] {
            settings.toneCurves.master.points[0].y = value
            _ = try EditRenderer.render(source, settings: settings, session: session)
        }
        #expect(session.replacementToneCurveRangeDiagnostics().measurements == 2)
        #expect(session.replacementToneCurveRangeDiagnostics().cacheHits == 6)
        #expect(session.replacementRangeEntryCount() == 2)
        let rematerialized = try bitmap([0.1, 0.2, 0.3, 1, 0.4, 0.1, 0.6, 1])
        let sameRangeSource = PreviewBitmap(image: rematerialized.image, rangeProvenance: source.rangeProvenance,
                                            rangeSourceIdentity: source.rangeSourceIdentity)
        _ = try EditRenderer.render(sameRangeSource, settings: settings, session: session)
        #expect(session.replacementToneCurveRangeDiagnostics().measurements == 2)
        #expect(session.replacementToneCurveRangeDiagnostics().cacheHits == 8)
        settings.developGeometry.retouchStrokes = [try stroke(byte: 160)]
        _ = try EditRenderer.render(source, settings: settings, session: session)
        #expect(session.replacementToneCurveRangeDiagnostics().measurements == 4)
        settings.developGeometry.retouchStrokes = [try stroke(byte: 160, offset: 0.1)]
        _ = try EditRenderer.render(source, settings: settings, session: session)
        #expect(session.replacementToneCurveRangeDiagnostics().measurements == 6)
        #expect(session.replacementRangeEntryCount() == 2)
        _ = try EditRenderer.render(source, settings: .neutral, session: session)
        #expect(session.replacementRangeEntryCount() == 0)
        let duplicate = try stroke(byte: 128)
        settings.developGeometry.retouchStrokes = [duplicate, duplicate]
        #expect(throws: (any Error).self) { try EditRenderer.render(source, settings: settings, session: session) }
    }

    @Test @MainActor func aPointDragFormsOneUndoStepAndPersistsAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Curves-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditingModel(directory: directory)
        try await waitLoaded(editor)
        let baseline = EditSettings(exposure: 0.4, toneProcessingVersion: .consistentV2)
        editor.setSettings(baseline, for: "A")
        editor.selectEditingFunction(.crop, assetID: "A"); editor.selectEditingFunction(.adjustments, assetID: "A")
        editor.beginEditing(assetID: "A")
        for value in [0.45, 0.5, 0.6] {
            var next = editor.settings(for: "A")
            next.toneCurves.master = .init(points: [.init(x: 0, y: 0), .init(x: 0.5, y: value), .init(x: 1, y: 1)])
            editor.setSettings(next, for: "A")
        }
        editor.endEditing(assetID: "A")
        let accepted = editor.settings(for: "A")
        editor.undo(assetID: "A"); #expect(editor.settings(for: "A") == baseline)
        #expect(!editor.canUndo(assetID: "A"))
        editor.redo(assetID: "A"); #expect(editor.settings(for: "A") == accepted)
        #expect(await editor.flush())
        let reopened = EditingModel(directory: directory); try await waitLoaded(reopened)
        #expect(reopened.settings(for: "A") == accepted)
        let footprint = EditingHistoryFootprint.snapshot(try EditingSnapshot(settings: accepted))
        let baseFootprint = EditingHistoryFootprint.snapshot(try EditingSnapshot(settings: baseline))
        #expect(footprint.metadataBytes - baseFootprint.metadataBytes == MemoryLayout<ToneCurvePoint>.stride)
    }

    @MainActor private func waitLoaded(_ editor: EditingModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while editor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!editor.isLoading && editor.canEdit)
    }
    private func bitmap(_ values: [Float]) throws -> PreviewBitmap {
        let bytes = values.withUnsafeBytes { Data($0) }
        let image = try #require(CGImage(width: values.count / 4, height: 1, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: values.count * 4, space: Self.space,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image, rangeProvenance: .extended(nominalSDRWhite: 1))
    }
    private func read(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        values.withUnsafeMutableBytes {
            Self.context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(image.extent.width) * 16,
                                bounds: image.extent, format: .RGBAf, colorSpace: Self.space)
        }
        return values
    }

    private func image(_ values: [Float]) -> CIImage {
        let data = values.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: values.count * MemoryLayout<Float>.stride,
                       size: CGSize(width: values.count / 4, height: 1), format: .RGBAf, colorSpace: Self.space)
    }
    private func render(_ values: [Float], settings: ToneCurveSettings) throws -> [Float] {
        let source = image(values)
        let graph = try ToneCurveRenderer.apply(to: source, settings: settings, extent: source.extent, context: Self.context)
        var output = [Float](repeating: 0, count: values.count)
        output.withUnsafeMutableBytes { Self.context.render(graph, toBitmap: $0.baseAddress!, rowBytes: values.count * MemoryLayout<Float>.stride,
                                                            bounds: source.extent, format: .RGBAf, colorSpace: Self.space) }
        return output
    }

    /// Standalone oracle: derives tangents from the point list and evaluates
    /// the Hermite basis directly. It calls no production curve preparation.
    private func reference(_ x: Double, curve: ToneCurve) -> Double {
        let points = curve.points
        if x < 0 { return x + points[0].y }
        if x > 1 { return points.last!.y + x - 1 }
        let slopes = zip(points, points.dropFirst()).map { ($1.y - $0.y) / ($1.x - $0.x) }
        var derivatives = [slopes.first!] + zip(slopes, slopes.dropFirst()).map { ($0 + $1) / 2 } + [slopes.last!]
        for index in slopes.indices {
            if slopes[index] == 0 { derivatives[index] = 0; derivatives[index + 1] = 0; continue }
            let a = derivatives[index] / slopes[index], b = derivatives[index + 1] / slopes[index]
            if a*a + b*b > 9 {
                let factor = 3 / sqrt(a*a + b*b)
                derivatives[index] *= factor; derivatives[index + 1] *= factor
            }
        }
        let end = max(1, points.firstIndex { $0.x >= x }!)
        let start = end - 1, width = points[end].x - points[start].x
        let t = (x - points[start].x) / width
        let a = 2*t*t*t - 3*t*t + 1, b = t*t*t - 2*t*t + t
        let c = -2*t*t*t + 3*t*t, d = t*t*t - t*t
        return a*points[start].y + b*width*derivatives[start] + c*points[end].y + d*width*derivatives[end]
    }
}
