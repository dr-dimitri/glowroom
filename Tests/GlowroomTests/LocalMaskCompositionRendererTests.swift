import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Composed soft masks in the shared CI graph")
struct LocalMaskCompositionRendererTests {
    @Test func floatCoverageMatchesIndependentScalarAlgebraOnBothBackends() throws {
        for software in [false, true] {
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: software])
            let operations: [LocalMaskOperation] = [.add, .intersect, .subtract, .add]
            let bytes: [UInt8] = [153, 128, 51, 38]
            var components = try zip(operations, bytes).map { operation, byte in
                try LocalMaskComponent(name: operation.title, operation: operation,
                    shape: .sky(.init(width: 1, height: 1, bytes: Data([byte]))), feather: 0)
            }
            for inverted in [false, true] {
                components[0].isInverted = inverted
                let mask = try LocalAdjustmentMask(composition: .init(components: components), isInverted: true, opacity: 0.7)
                let first = inverted ? 1 - Double(bytes[0]) / 255 : Double(bytes[0]) / 255
                let expected = (1 - max(first * Double(bytes[1]) / 255 * (1 - Double(bytes[2]) / 255), Double(bytes[3]) / 255)) * 0.7
                let image = try LocalAdjustmentRenderer.maskImage(mask, extent: CGRect(x: 0, y: 0, width: 4, height: 4))
                var pixels = [Float](repeating: 0, count: 4 * 4 * 4)
                pixels.withUnsafeMutableBytes { values in
                    context.render(image, toBitmap: values.baseAddress!, rowBytes: 4 * 16,
                        bounds: CGRect(x: 0, y: 0, width: 4, height: 4), format: .RGBAf, colorSpace: nil)
                }
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    #expect(abs(Double(pixels[i]) - expected) <= 0.0001)
                    #expect(pixels[i + 3] == 1)
                }
            }
        }
    }

    @Test func singleComponentConversionPreservesExactLegacyCoverageAndEmptyListIsEmpty() throws {
        let center = try LocalMaskPoint(x: 0.4, y: 0.6)
        let legacy = try LocalAdjustmentMask(shape: .radial(center: center, radiusX: 0.3, radiusY: 0.5, rotation: 0.3),
            isInverted: true, opacity: 0.6, feather: 0.7)
        let composed = try LocalAdjustmentMask(composition: legacy.convertedToComposition(name: "Verlauf"),
            isInverted: legacy.isInverted, opacity: legacy.opacity)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        func pixels(_ mask: LocalAdjustmentMask) throws -> [Float] {
            let extent = CGRect(x: 0, y: 0, width: 40, height: 30)
            let image = try LocalAdjustmentRenderer.maskImage(mask, extent: extent)
            var result = [Float](repeating: 0, count: 40 * 30 * 4)
            result.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 40 * 16,
                bounds: extent, format: .RGBAf, colorSpace: nil) }
            return result
        }
        #expect(try pixels(legacy) == pixels(composed))
        let empty = try pixels(.init(composition: .init(components: [])))
        #expect(stride(from: 0, to: empty.count, by: 4).allSatisfy { empty[$0] == 0 })
    }

    @Test func memoryAdmissionIncludesEveryRetainedComponentPlane() throws {
        let shape = LocalMaskShape.radial(center: try .init(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.4, rotation: 0)
        let single = try LocalAdjustment(name: "Alt", mask: .init(shape: shape), settings: .init(exposure: 1))
        let components = try (0..<16).map { _ in try LocalMaskComponent(name: "Bestandteil", shape: shape) }
        let composed = try LocalAdjustment(name: "Neu", mask: .init(composition: .init(components: components)), settings: .init(exposure: 1))
        let legacyBytes = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [single], width: 1_000, height: 1_000))
        let composedBytes = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: [composed], width: 1_000, height: 1_000))
        #expect(composedBytes == legacyBytes + (3 * 16 + 1) * 1_000 * 1_000 * 8)
    }
}
