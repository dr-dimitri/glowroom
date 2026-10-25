import Foundation
import Testing
@testable import GlowroomCore

@Suite("Portable selective development presets")
struct DevelopPresetTests {
    private func fixture() throws -> DevelopPreset {
        try DevelopPreset(name: " Abends ", patch: .init(settings: .init(exposure: 1.25, texture: 19, sharpeningAmount: 40,
            toneProcessingVersion: .consistentV2), groups: [.light, .details]))
    }

    @Test func selectedGroupsPreserveEveryExcludedValueAndTargetVersion() throws {
        var source = EditSettings(exposure: 1.25, contrast: -12, texture: 19, vibrance: 33, sharpeningAmount: 40,
            developColor: .init(temperature: 7_500, tint: 20, profile: .vivid, isMonochrome: true),
            levels: .init(master: .init(gamma: 1.3)), toneProcessingVersion: .consistentV2)
        source.developGeometry = .init(straightenAngle: 12)
        let mask = try LocalAdjustment(name: "Behalten", mask: .init(shape: .linear(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1))))
        var target = EditSettings(exposure: -1, texture: -20, vibrance: -16, developColor: .init(hdrEnabled: true),
            levels: .init(red: .init(gamma: 0.8)), toneCurves: .init(master: .init(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 1)])),
            toneProcessingVersion: .consistentV2)
        target.localAdjustments = [mask]; target.developGeometry = .init(straightenAngle: -9)
        let patch = try DevelopSettingsPatch(settings: source, groups: [.light, .details])
        let result = try patch.applying(to: target)
        var expected = target
        for parameter in EditParameter.allCases where [.light, .details].contains(DevelopPresetGroup.group(for: parameter)) {
            expected = try parameter.applying(parameter.value(in: source), to: expected)
        }
        #expect(result == expected)
        #expect(result.developColor == target.developColor)
        #expect(result.levels == target.levels)
        #expect(result.toneCurves == target.toneCurves)
        #expect(result.developGeometry == target.developGeometry)
        #expect(result.localAdjustments == target.localAdjustments)
        #expect(result.toneProcessingVersion == target.toneProcessingVersion)
        let color = try DevelopSettingsPatch(settings: source, groups: [.color]).applying(to: target)
        #expect(color.developColor.hdrEnabled)
        #expect(color.developColor.temperature == 7_500 && color.developColor.profile == .vivid && color.developColor.isMonochrome)
        #expect(color.exposure == target.exposure && color.texture == target.texture)
    }

    @Test func omittedControlDiffersFromExplicitNeutralAndSelectingIsStrict() throws {
        let patch = try DevelopSettingsPatch(toneProcessingVersion: .consistentV2, groups: [.light],
            controls: [.init(parameter: .exposure, value: 0)])
        let result = try patch.applying(to: .init(exposure: 2, contrast: 25, toneProcessingVersion: .consistentV2))
        #expect(result.exposure == 0 && result.contrast == 25)
        let whole = try fixture().patch
        #expect(try whole.selecting([.details]).groups == [.details])
        #expect(throws: DevelopPresetError.invalidPatch) { try whole.selecting([]) }
        #expect(throws: DevelopPresetError.invalidPatch) { try whole.selecting([.color]) }
        #expect(throws: DevelopPresetError.incompatibleToneProcessing) { try whole.applying(to: .neutral) }
        #expect(DevelopPresetGroup.allCases.flatMap(\.parameters).count == EditParameter.allCases.count)
        #expect(Set(DevelopPresetGroup.allCases.flatMap(\.parameters)) == Set(EditParameter.allCases))
    }

    @Test func namesAreTrimmedWithGraphemeAndByteLimitsAndDescriptionsBounded() throws {
        let base = try fixture()
        #expect(base.name == "Abends")
        #expect(try DevelopPreset(name: String(repeating: "👩🏽‍💻", count: 20), patch: base.patch).name.count == 20)
        for name in [" \n ", String(repeating: "a", count: 121), String(repeating: "👩🏽‍💻", count: 40)] {
            #expect(throws: DevelopPresetError.invalidName) { try DevelopPreset(name: name, patch: base.patch) }
        }
        #expect(throws: DevelopPresetError.invalidDescription) { try DevelopPreset(name: "A", description: String(repeating: "a", count: 2_001), patch: base.patch) }
        #expect(throws: DevelopPresetError.invalidDescription) { try DevelopPreset(name: "A", description: String(repeating: "👩🏽‍💻", count: 600), patch: base.patch) }
        #expect(try base.replacingName("Neu").id == base.id)
        #expect(try base.importedCopy().id != base.id)
    }

    @Test func strictRoundtripRejectsUnknownFieldsControlsVersionsDuplicatesAndWrongTypes() throws {
        let preset = try fixture(); let bytes = try preset.encoded()
        #expect(try DevelopPreset.decode(bytes) == preset)
        let original = try #require(String(data: bytes, encoding: .utf8))
        let invalid = [
            original.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99"),
            original.replacingOccurrences(of: "\"name\":\"Abends\"", with: "\"name\":\"Abends\",\"name\":\"B\""),
            original.replacingOccurrences(of: "\"name\":\"Abends\"", with: "\"name\":\"Abends\",\"n\\u0061me\":\"B\""),
            original.replacingOccurrences(of: "\"name\":\"Abends\"", with: "\"name\":22"),
            original.replacingOccurrences(of: "\"parameter\":\"exposure\"", with: "\"parameter\":\"unknown\""),
            original.replacingOccurrences(of: "\"value\":1.25", with: "\"value\":999"),
            original.replacingOccurrences(of: "\"value\":1.25", with: "\"value\":1e999"),
            original.replacingOccurrences(of: "\"value\":1.25", with: "\"value\":true"),
            original.replacingOccurrences(of: "\"name\":\"Abends\"", with: "\"name\":\"Abends\",\"sourceID\":\"not portable\""),
            original.replacingOccurrences(of: "\"patch\":{", with: "\"patch\":{\"developGeometry\":{},"),
            original.replacingOccurrences(of: "\"groups\":[\"details\",\"light\"]", with: "\"groups\":[\"light\",\"light\"]")
        ]
        for text in invalid { #expect(throws: (any Error).self) { try DevelopPreset.decode(Data(text.utf8)) } }
        #expect(throws: DevelopPresetError.fileTooLarge) { try DevelopPreset.decode(Data(repeating: 32, count: DevelopPreset.maximumFileBytes + 1)) }
        #expect(throws: (any Error).self) { try DevelopPreset.decode(Data("{\"name\":".utf8)) }
        let colorPreset = try DevelopPreset(name: "Farbe", patch: .init(settings: .newEditingSettings, groups: [.color, .levels]))
        let colorJSON = String(decoding: try colorPreset.encoded(), as: UTF8.self)
        #expect(throws: DevelopPresetError.invalidFile) {
            try DevelopPreset.decode(Data(colorJSON.replacingOccurrences(of: "\"temperature\":6500", with: "\"temperature\":6500,\"hdrEnabled\":true").utf8))
        }
        #expect(throws: DevelopPresetError.invalidFile) {
            try DevelopPreset.decode(Data(colorJSON.replacingOccurrences(of: "\"gamma\":1", with: "\"gamma\":1,\"mystery\":0").utf8))
        }
    }

    @Test func directPatchConstructionRejectsInvalidValuesAndDuplicatesWithoutClamping() throws {
        for value in [Double.nan, .infinity, -.infinity, 5.001, -5.001] {
            #expect(throws: DevelopPresetError.invalidPatch) {
                try DevelopSettingsPatch(toneProcessingVersion: .consistentV2, groups: [.light], controls: [.init(parameter: .exposure, value: value)])
            }
        }
        #expect(throws: DevelopPresetError.invalidPatch) {
            try DevelopSettingsPatch(toneProcessingVersion: .consistentV2, groups: [.light], controls: [.init(parameter: .exposure, value: 1), .init(parameter: .exposure, value: 2)])
        }
        #expect(throws: DevelopPresetError.invalidPatch) {
            try DevelopSettingsPatch(toneProcessingVersion: .consistentV2, groups: [.light], controls: [.init(parameter: .saturation, value: 1)])
        }
        #expect(throws: DevelopPresetError.invalidPatch) {
            try DevelopSettingsPatch(toneProcessingVersion: .consistentV2, groups: [.color], controls: [], color: .init(temperature: 99, tint: 0, profile: .neutral, isMonochrome: false))
        }
        #expect(throws: DevelopPresetError.invalidPatch) {
            try DevelopSettingsPatch(toneProcessingVersion: .consistentV2, groups: [.light], controls: [])
        }
    }
}
