import Foundation
import Testing
@testable import GlowroomCore

@Suite("Editable ordered mask components")
struct LocalMaskCompositionTests {
    @Test func softCoverageUsesOrderedMaxProductAndComplementWithoutThresholds() throws {
        let composition = try LocalMaskComposition(components: [component(.add), component(.intersect), component(.subtract)])
        #expect(abs(try composition.coverage([0.6, 0.5, 0.2]) - 0.24) < 1e-12)
        #expect(abs(try composition.coverage([0.6, 0.5, 0.2], isInverted: true, opacity: 0.7) - 0.532) < 1e-12)
        var inverted = composition
        inverted.components[0].isInverted = true
        #expect(abs(try inverted.coverage([0.6, 0.5, 0.2]) - 0.16) < 1e-12)
        inverted.components[1].isEnabled = false
        #expect(abs(try inverted.coverage([0.6, 0.5, 0.2]) - 0.32) < 1e-12)
        #expect(try LocalMaskComposition(components: []).coverage([]) == 0)
        var disabled = composition
        disabled.components = disabled.components.map { var c = $0; c.isEnabled = false; return c }
        #expect(try disabled.coverage([0.6, 0.5, 0.2]) == 0)
        #expect(throws: ArtifactContractError.self) { try composition.coverage([.nan, 0, 0]) }
    }

    @Test func firstEnabledComponentMustAddAndInvalidActionsRetainPreviousValue() throws {
        var components = try [component(.add), component(.intersect), component(.subtract)]
        let original = try LocalMaskComposition(components: components)
        components[0].isEnabled = false
        #expect(throws: ArtifactContractError.self) { try LocalMaskComposition(components: components) }
        #expect(original.components[0].isEnabled)
        components.removeFirst()
        #expect(throws: ArtifactContractError.self) { try LocalMaskComposition(components: components) }
        components[0].isEnabled = false; components[1].isEnabled = false
        _ = try LocalMaskComposition(components: components)
    }

    @Test func conversionKeepsLegacyBytesAndSeparatesOverallStrengthFromComponentDefinition() throws {
        let raster = try LocalMaskRaster(width: 1, height: 1, bytes: Data([128]))
        let legacy = try LocalAdjustmentMask(shape: .sky(raster), isInverted: true, opacity: 0.7, feather: 0.3)
        let bytes = try ArtifactJSONCodec.encode(legacy)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("composition"))
        #expect(try ArtifactJSONCodec.encode(ArtifactJSONCodec.decode(LocalAdjustmentMask.self, from: bytes)) == bytes)
        let composition = try legacy.convertedToComposition(name: "Himmel")
        #expect(composition.components[0].shape == legacy.shape)
        #expect(composition.components[0].feather == legacy.feather)
        #expect(!composition.components[0].isInverted)
        let composed = try LocalAdjustmentMask(composition: composition, isInverted: legacy.isInverted, opacity: legacy.opacity)
        let encoded = try ArtifactJSONCodec.encode(composed)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["shape"] == nil && object["feather"] == nil && object["refinement"] == nil)
        #expect(try ArtifactJSONCodec.decode(LocalAdjustmentMask.self, from: encoded) == composed)
        var hidden = composed; hidden.shape = legacy.shape
        #expect(throws: ArtifactContractError.self) { try hidden.validate() }
        #expect(composed.resourceUsage.rasterBytes == 1)
        var mixed = object; mixed["shape"] = try JSONSerialization.jsonObject(with: ArtifactJSONCodec.encode(legacy.shape))
        #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(LocalAdjustmentMask.self, from: JSONSerialization.data(withJSONObject: mixed)) }
    }

    @Test func componentAndPhotoCountBoundariesAreStrictIncludingDormantComponents() throws {
        for count in [15, 16] { _ = try LocalMaskComposition(components: (0..<count).map { _ in try component(.add) }) }
        #expect(throws: ArtifactContractError.limitExceeded) {
            try LocalMaskComposition(components: (0..<17).map { _ in try component(.add) })
        }
        func layer(_ count: Int) throws -> LocalAdjustment {
            try LocalAdjustment(name: "Maske", mask: .init(composition: .init(components: (0..<count).map { _ in try component(.add) })))
        }
        let four = try (0..<4).map { _ in try layer(16) }
        _ = try EditingSnapshot(settings: .init(localAdjustments: four))
        let legacy = try LocalAdjustment(name: "Legacy", mask: .init(shape: .linear(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1))))
        #expect(legacy.mask.componentCount == 1)
        #expect(throws: ArtifactContractError.limitExceeded) { try EditingSnapshot(settings: .init(localAdjustments: four + [legacy])) }
        #expect(throws: ArtifactContractError.limitExceeded) { try ArtifactJSONCodec.encode(EditSettings(localAdjustments: four + [legacy])) }
        var under = four
        under[3] = try layer(15)
        _ = try EditingSnapshot(settings: .init(localAdjustments: under))
        #expect(throws: ArtifactContractError.limitExceeded) { try EditingSnapshot(settings: .init(localAdjustments: four + [layer(1)])) }
        let bytes = try ArtifactJSONCodec.encode(EditSettings(localAdjustments: four))
        #expect(try ArtifactJSONCodec.decode(EditSettings.self, from: bytes).localAdjustments.count == 4)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var layers = try #require(object["localAdjustments"] as? [[String: Any]])
        var fifth = layers[0]; fifth["id"] = UUID().uuidString
        var mask = try #require(fifth["mask"] as? [String: Any])
        var composition = try #require(mask["composition"] as? [String: Any])
        var entries = try #require(composition["components"] as? [[String: Any]])
        entries = [entries[0]]; entries[0]["id"] = UUID().uuidString
        composition["components"] = entries; mask["composition"] = composition; fifth["mask"] = mask
        layers.append(fifth); object["localAdjustments"] = layers
        #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func rasterAggregateAndStrictNestedPayloadsAreCheckedAcrossComponents() throws {
        let side = LocalMaskRaster.maximumDimension
        let raster = try LocalMaskRaster(width: side, height: side, bytes: Data(repeating: 100, count: side * side))
        let all = try (0..<4).map { _ in try LocalMaskComponent(name: "Motiv", shape: .subject(raster), feather: 0) }
        let layer = try LocalAdjustment(name: "Gesamt", mask: .init(composition: .init(components: all)))
        _ = try EditingSnapshot(settings: .init(localAdjustments: [layer]))
        let extra = try LocalMaskComponent(name: "Himmel", shape: .sky(.init(width: 1, height: 1, bytes: Data([1]))))
        let oversized = try LocalAdjustment(name: "Gesamt", mask: .init(composition: .init(components: all + [extra])))
        #expect(throws: ArtifactContractError.limitExceeded) { try EditingSnapshot(settings: .init(localAdjustments: [oversized])) }
        #expect(throws: ArtifactContractError.limitExceeded) { try ArtifactJSONCodec.encode(EditSettings(localAdjustments: [oversized])) }
        let small = try LocalAdjustment(name: "Maske", mask: .init(composition: .init(components: [component(.add)])))
        let bytes = try ArtifactJSONCodec.encode(EditSettings(localAdjustments: [small]))
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var layers = try #require(object["localAdjustments"] as? [[String: Any]])
        var mask = try #require(layers[0]["mask"] as? [String: Any])
        var composition = try #require(mask["composition"] as? [String: Any])
        var components = try #require(composition["components"] as? [[String: Any]])
        components[0]["unexpected"] = 1; composition["components"] = components
        mask["composition"] = composition; layers[0]["mask"] = mask; object["localAdjustments"] = layers
        #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    private func component(_ operation: LocalMaskOperation) throws -> LocalMaskComponent {
        try LocalMaskComponent(name: operation.title, operation: operation,
            shape: .linear(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1)), feather: 0)
    }
}
