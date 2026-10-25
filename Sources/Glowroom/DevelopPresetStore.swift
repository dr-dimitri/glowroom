import Foundation
import GlowroomCore

/// Independent settings files, serialized off MainActor. No image or catalog
/// access and no nested worker pool; tiny ordered CRUD operations share an actor.
actor DevelopPresetStore {
    static let maximumCount = 1_024
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glowroom", isDirectory: true)
            .appendingPathComponent("DevelopPresets", isDirectory: true)
    }

    func load() throws -> [DevelopPreset] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "glowroompreset" }
        guard urls.count <= Self.maximumCount else { throw DevelopPresetError.libraryFull }
        var presets: [DevelopPreset] = []; presets.reserveCapacity(urls.count)
        var seen = Set<UUID>()
        for url in urls {
            let preset = try DevelopPreset.decode(readBounded(url))
            guard url.deletingPathExtension().lastPathComponent == preset.id.uuidString,
                  seen.insert(preset.id).inserted else { throw DevelopPresetError.invalidFile }
            presets.append(preset)
        }
        return presets.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }
    func save(_ preset: DevelopPreset) throws {
        let data = try preset.encoded()
        try ensureDirectory()
        let target = fileURL(preset.id)
        if !FileManager.default.fileExists(atPath: target.path) {
            let count = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "glowroompreset" }.count
            guard count < Self.maximumCount else { throw DevelopPresetError.libraryFull }
        }
        try writeAtomically(data, to: target)
    }
    func delete(id: UUID) throws {
        try ensureDirectory(); let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DevelopPresetError.missingPreset }
        try requireRegularFile(url)
        try FileManager.default.removeItem(at: url)
    }
    /// Every import is a distinct copy, even if the original ID is absent.
    /// Names collide case-insensitively and receive a bounded numbered suffix.
    func importFile(_ url: URL) throws -> DevelopPreset {
        let decoded = try DevelopPreset.decode(readBounded(url))
        let existing = try load()
        let names = Set(existing.map { $0.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) })
        var name = decoded.name; var number = 1
        while names.contains(name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))) {
            let suffix = " (Importiert \(number))"
            var stem = String(decoded.name.prefix(120 - suffix.count))
            while stem.utf8.count + suffix.utf8.count > 512 { stem.removeLast() }
            name = stem + suffix; number += 1
        }
        let imported = try decoded.importedCopy(name: name)
        try save(imported); return imported
    }
    func export(_ preset: DevelopPreset, to url: URL) throws {
        guard url.pathExtension.lowercased() == "glowroompreset" else { throw DevelopPresetError.invalidFile }
        try writeAtomically(preset.encoded(), to: url)
    }
    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("glowroompreset") }
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw DevelopPresetError.invalidFile }
    }
    private func requireRegularFile(_ url: URL) throws {
        guard url.isFileURL else { throw DevelopPresetError.invalidFile }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw DevelopPresetError.invalidFile }
    }
    private func readBounded(_ url: URL) throws -> Data {
        try requireRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        // Never map/read an unbounded input, even when its reported size changes.
        var data = Data()
        while data.count <= DevelopPreset.maximumFileBytes {
            let count = min(65_536, DevelopPreset.maximumFileBytes + 1 - data.count)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw DevelopPresetError.fileTooLarge
    }
    private func writeAtomically(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw DevelopPresetError.invalidFile }
        if FileManager.default.fileExists(atPath: url.path) { try requireRegularFile(url) }
        try data.write(to: url, options: [.atomic])
    }
}
