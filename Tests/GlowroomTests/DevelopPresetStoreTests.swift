import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Development preset file storage")
struct DevelopPresetStoreTests {
    private func location() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-presets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func preset(_ name: String = "Abend") throws -> DevelopPreset {
        try .init(name: name, patch: .init(settings: .init(exposure: 1.2, texture: 25, toneProcessingVersion: .consistentV2), groups: [.light, .details]))
    }

    @Test func saveRenameRestartDeleteAndAtomicExchange() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DevelopPresetStore(directory: root.appendingPathComponent("Library"))
        #expect(try await store.load().isEmpty)
        let original = try preset()
        try await store.save(original)
        #expect(try await store.load() == [original])
        let renamed = try original.replacingName("Leise")
        try await store.save(renamed)
        let restarted = DevelopPresetStore(directory: root.appendingPathComponent("Library"))
        #expect(try await restarted.load() == [renamed])
        let exported = root.appendingPathComponent("Look.glowroompreset")
        try await store.export(renamed, to: exported)
        #expect(try DevelopPreset.decode(Data(contentsOf: exported)) == renamed)
        let imported = try await store.importFile(exported)
        #expect(imported.id != renamed.id && imported.patch == renamed.patch)
        #expect(imported.name == "Leise (Importiert 1)")
        let imported2 = try await store.importFile(exported)
        #expect(imported2.id != imported.id && imported2.name == "Leise (Importiert 2)")
        #expect(try await store.load().count == 3)
        try await store.delete(id: renamed.id)
        #expect(try await store.load().count == 2)
        await #expect(throws: DevelopPresetError.missingPreset) { try await store.delete(id: renamed.id) }
    }

    @Test func rejectedImportDoesNotChangeLibraryAndMalformedLibraryIsReported() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        let store = DevelopPresetStore(directory: directory)
        let initial = try preset(); try await store.save(initial)
        let invalid = root.appendingPathComponent("Invalid.glowroompreset")
        try Data("{}".utf8).write(to: invalid)
        await #expect(throws: DevelopPresetError.invalidFile) { try await store.importFile(invalid) }
        #expect(try await store.load() == [initial])
        try Data(repeating: 32, count: DevelopPreset.maximumFileBytes + 1).write(to: invalid)
        await #expect(throws: DevelopPresetError.fileTooLarge) { try await store.importFile(invalid) }
        #expect(try await store.load() == [initial])
        let wrongName = directory.appendingPathComponent("wrong.glowroompreset")
        try initial.encoded().write(to: wrongName)
        await #expect(throws: DevelopPresetError.invalidFile) { try await store.load() }
    }

    @Test func caseInsensitiveLongNameCollisionAndSymlinkRejection() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DevelopPresetStore(directory: root.appendingPathComponent("Library"))
        let lower = try preset(String(repeating: "a", count: 120)); try await store.save(lower)
        let upper = try preset(String(repeating: "A", count: 120))
        let input = root.appendingPathComponent("Input.glowroompreset")
        try upper.encoded().write(to: input)
        let imported = try await store.importFile(input)
        #expect(imported.name.count == 120 && imported.name.hasSuffix(" (Importiert 1)"))
        let link = root.appendingPathComponent("Link.glowroompreset")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        await #expect(throws: DevelopPresetError.invalidFile) { try await store.importFile(link) }
        await #expect(throws: DevelopPresetError.invalidFile) { try await store.export(lower, to: link) }
        #expect(try DevelopPreset.decode(Data(contentsOf: input)) == upper)
        let original = root.appendingPathComponent("Original.jpg")
        let originalBytes = Data([1, 2, 3, 4]); try originalBytes.write(to: original)
        await #expect(throws: DevelopPresetError.invalidFile) { try await store.export(lower, to: original) }
        #expect(try Data(contentsOf: original) == originalBytes)
    }
}
