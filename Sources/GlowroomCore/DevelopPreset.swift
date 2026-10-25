import Foundation

public enum DevelopPresetError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion, invalidName, invalidDescription, invalidPatch, invalidFile, fileTooLarge
    case incompatibleToneProcessing, missingPreset, libraryFull

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "Diese Version der Entwicklungsvorgabe wird nicht unterstützt."
        case .invalidName: return "Der Name muss 1 bis 120 Zeichen und höchstens 512 UTF-8-Bytes enthalten."
        case .invalidDescription: return "Die Beschreibung ist zu lang."
        case .invalidPatch: return "Die Entwicklungsvorgabe enthält ungültige oder unbekannte Einstellungen."
        case .invalidFile: return "Die Datei ist keine gültige Glowroom-Entwicklungsvorgabe."
        case .fileTooLarge: return "Eine Entwicklungsvorgabe darf höchstens 1 MiB groß sein."
        case .incompatibleToneProcessing: return "Die Vorgabe verwendet eine andere Tonwertverarbeitung. Aktualisiere den Bildprozess bei Bedarf separat."
        case .missingPreset: return "Diese Entwicklungsvorgabe ist nicht mehr vorhanden."
        case .libraryFull: return "Die Bibliothek enthält bereits 1024 Entwicklungsvorgaben."
        }
    }
}

public enum DevelopPresetGroup: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case light, levels, color, details
    public var id: String { rawValue }
    public var title: String {
        switch self { case .light: return "Licht"; case .levels: return "Tonwertkorrektur"; case .color: return "Farbe"; case .details: return "Details" }
    }
    public static let all = Set(allCases)
    public var parameters: [EditParameter] {
        EditParameter.allCases.filter { Self.group(for: $0) == self }
    }
    public static func group(for parameter: EditParameter) -> Self {
        switch parameter {
        case .exposure, .contrast, .highlights, .shadows, .whites, .blacks, .autoToneAmount, .naturalBalanceAmount: return .light
        case .vibrance, .saturation, .naturalBalanceColorAmount: return .color
        case .texture, .clarity, .dehaze, .luminanceNoiseReduction, .colorNoiseReduction,
             .sharpeningAmount, .sharpeningRadius, .sharpeningDetail, .sharpeningMasking: return .details
        }
    }
}

/// An explicit value is different from an omitted control, including zero.
public struct DevelopPresetControlValue: Codable, Hashable, Sendable {
    public let parameter: EditParameter
    public let value: Double
    public init(parameter: EditParameter, value: Double) { self.parameter = parameter; self.value = value }
}

/// Deliberately excludes HDR/output mode from the portable color group.
public struct DevelopPresetColor: Codable, Hashable, Sendable {
    public let temperature: Double
    public let tint: Double
    public let profile: DevelopColorProfile
    public let isMonochrome: Bool
    public init(temperature: Double, tint: Double, profile: DevelopColorProfile, isMonochrome: Bool) {
        self.temperature = temperature; self.tint = tint; self.profile = profile; self.isMonochrome = isMonochrome
    }
    public init(_ settings: DevelopColorSettings) {
        self.init(temperature: settings.temperature, tint: settings.tint, profile: settings.profile, isMonochrome: settings.isMonochrome)
    }
    public func validate() throws {
        guard temperature.isFinite, DevelopColorSettings.temperatureRange.contains(temperature),
              tint.isFinite, DevelopColorSettings.tintRange.contains(tint) else { throw DevelopPresetError.invalidPatch }
    }
}

/// Versioned, image-independent absolute settings. Omission never resets a target
/// control. Curves, geometry, masks, sources and output settings are not V1 fields.
public struct DevelopSettingsPatch: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public let schemaVersion: Int
    public let toneProcessingVersion: ToneProcessingVersion
    public let groups: Set<DevelopPresetGroup>
    public let controls: [DevelopPresetControlValue]
    public let levels: LevelsSettings?
    public let color: DevelopPresetColor?

    public init(toneProcessingVersion: ToneProcessingVersion, groups: Set<DevelopPresetGroup>,
                controls: [DevelopPresetControlValue], levels: LevelsSettings? = nil, color: DevelopPresetColor? = nil) throws {
        schemaVersion = Self.currentVersion; self.toneProcessingVersion = toneProcessingVersion
        self.groups = groups; self.controls = controls.sorted { $0.parameter.rawValue < $1.parameter.rawValue }
        self.levels = levels; self.color = color
        try validate()
    }
    public init(settings: EditSettings, groups: Set<DevelopPresetGroup>) throws {
        try self.init(toneProcessingVersion: settings.toneProcessingVersion, groups: groups,
            controls: EditParameter.allCases.filter { groups.contains(DevelopPresetGroup.group(for: $0)) }
                .map { .init(parameter: $0, value: $0.value(in: settings)) },
            levels: groups.contains(.levels) ? settings.levels : nil,
            color: groups.contains(.color) ? DevelopPresetColor(settings.developColor) : nil)
    }
    public func validate() throws {
        guard schemaVersion == Self.currentVersion else { throw DevelopPresetError.unsupportedVersion }
        guard !groups.isEmpty, controls.count <= EditParameter.allCases.count,
              Set(controls.map(\.parameter)).count == controls.count else { throw DevelopPresetError.invalidPatch }
        for control in controls {
            guard groups.contains(DevelopPresetGroup.group(for: control.parameter)), control.value.isFinite,
                  control.parameter.range.contains(control.value) else { throw DevelopPresetError.invalidPatch }
        }
        guard (levels == nil || groups.contains(.levels)), (color == nil || groups.contains(.color)) else { throw DevelopPresetError.invalidPatch }
        for group in groups {
            let hasControls = controls.contains { DevelopPresetGroup.group(for: $0.parameter) == group }
            guard hasControls || (group == .levels && levels != nil) || (group == .color && color != nil) else { throw DevelopPresetError.invalidPatch }
        }
        try levels?.validate(); try color?.validate()
    }
    public func selecting(_ selected: Set<DevelopPresetGroup>) throws -> Self {
        guard selected.isSubset(of: groups), !selected.isEmpty else { throw DevelopPresetError.invalidPatch }
        return try Self(toneProcessingVersion: toneProcessingVersion, groups: selected,
            controls: controls.filter { selected.contains(DevelopPresetGroup.group(for: $0.parameter)) },
            levels: selected.contains(.levels) ? levels : nil, color: selected.contains(.color) ? color : nil)
    }
    public func applying(to target: EditSettings) throws -> EditSettings {
        try validate()
        guard target.toneProcessingVersion == toneProcessingVersion else { throw DevelopPresetError.incompatibleToneProcessing }
        var result = target
        for control in controls { result = try control.parameter.applying(control.value, to: result) }
        if let levels { result.levels = levels }
        if let color {
            result.developColor.temperature = color.temperature; result.developColor.tint = color.tint
            result.developColor.profile = color.profile; result.developColor.isMonochrome = color.isMonochrome
        }
        return result
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, toneProcessingVersion, groups, controls, levels, color }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        toneProcessingVersion = try c.decode(ToneProcessingVersion.self, forKey: .toneProcessingVersion)
        let groupList = try c.decode([DevelopPresetGroup].self, forKey: .groups)
        guard Set(groupList).count == groupList.count else { throw DevelopPresetError.invalidPatch }
        groups = Set(groupList)
        controls = try c.decode([DevelopPresetControlValue].self, forKey: .controls)
        levels = try c.decodeIfPresent(LevelsSettings.self, forKey: .levels)
        color = try c.decodeIfPresent(DevelopPresetColor.self, forKey: .color)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(toneProcessingVersion, forKey: .toneProcessingVersion)
        try c.encode(groups.sorted { $0.rawValue < $1.rawValue }, forKey: .groups)
        try c.encode(controls, forKey: .controls)
        try c.encodeIfPresent(levels, forKey: .levels); try c.encodeIfPresent(color, forKey: .color)
    }
}

public struct DevelopPreset: Codable, Hashable, Sendable, Identifiable {
    public static let currentVersion = 1
    public static let maximumFileBytes = 1_024 * 1_024
    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let description: String?
    public let patch: DevelopSettingsPatch
    public init(id: UUID = UUID(), name: String, description: String? = nil, patch: DevelopSettingsPatch) throws {
        schemaVersion = Self.currentVersion; self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description; self.patch = patch
        try validate()
    }
    public func replacingName(_ name: String) throws -> Self {
        try Self(id: id, name: name, description: description, patch: patch)
    }
    public func importedCopy(name: String? = nil) throws -> Self {
        try Self(name: name ?? self.name, description: description, patch: patch)
    }
    public func validate() throws {
        guard schemaVersion == Self.currentVersion else { throw DevelopPresetError.unsupportedVersion }
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines), (1...120).contains(name.count), name.utf8.count <= 512 else { throw DevelopPresetError.invalidName }
        if let description { guard description.count <= 2_000, description.utf8.count <= 8 * 1_024 else { throw DevelopPresetError.invalidDescription } }
        try patch.validate()
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileBytes else { throw DevelopPresetError.fileTooLarge }
        return data
    }
    /// Use this entry point for untrusted exchange files. The bounded scanner
    /// rejects duplicate keys before Codable, including escaped equivalents;
    /// roundtrip shape validation rejects unknown fields at every nesting level.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileBytes else { throw DevelopPresetError.fileTooLarge }
        do {
            var scanner = try PhotoMetadataJSONScanner(Data(data), maximum: maximumFileBytes, depth: 12, values: 1_024)
            try scanner.validate()
            let result = try JSONDecoder().decode(Self.self, from: data)
            try result.validate()
            try PhotoMetadataJSONShape.check(data, encoded: result.encoded())
            return result
        } catch let error as DevelopPresetError { throw error }
        catch { throw DevelopPresetError.invalidFile }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, description, patch }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion); id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name); description = try c.decodeIfPresent(String.self, forKey: .description)
        patch = try c.decode(DevelopSettingsPatch.self, forKey: .patch)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description); try c.encode(patch, forKey: .patch)
    }
}
