import Foundation

public enum CatalogRepositoryError: LocalizedError {
    case corruptCatalog(URL)
    case unsupportedVersion(Int)
    case invalidCatalog(String)

    public var errorDescription: String? {
        switch self {
        case .corruptCatalog(let url):
            return "Der Katalog „\(url.lastPathComponent)“ ist beschädigt und konnte nicht geladen werden. Die vorhandene Datei bleibt erhalten."
        case .unsupportedVersion(let version):
            return "Dieser Katalog verwendet die nicht unterstützte Version \(version)."
        case .invalidCatalog(let reason):
            return "Der Katalog ist ungültig: \(reason)"
        }
    }
}

/// Callers serialize writes. Saving replaces only the catalog, never original images.
public struct CatalogRepository: Sendable {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("catalog.json", isDirectory: false) }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicEdit", isDirectory: true)
    }

    public func load() throws -> LibraryCatalog {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LibraryCatalog() }
        // File access errors are kept distinct from malformed JSON so the UI can report them accurately.
        let data = try Data(contentsOf: fileURL)
        let catalog: LibraryCatalog
        do {
            catalog = try JSONDecoder().decode(LibraryCatalog.self, from: data)
        } catch {
            throw CatalogRepositoryError.corruptCatalog(fileURL)
        }
        try validate(catalog)
        return catalog
    }

    public func save(_ catalog: LibraryCatalog) throws {
        try validate(catalog)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func validate(_ catalog: LibraryCatalog) throws {
        guard catalog.version == LibraryCatalog.currentVersion else {
            throw CatalogRepositoryError.unsupportedVersion(catalog.version)
        }
        let folderIDs = Set(catalog.folders.map(\.id))
        guard folderIDs.count == catalog.folders.count else {
            throw CatalogRepositoryError.invalidCatalog("Ordner sind mehrfach enthalten.")
        }
        guard Set(catalog.assets.map(\.id)).count == catalog.assets.count else {
            throw CatalogRepositoryError.invalidCatalog("Bilder sind mehrfach enthalten.")
        }
        guard catalog.folders.allSatisfy({ $0.url.isFileURL }),
              catalog.assets.allSatisfy({ $0.fileURL.isFileURL && folderIDs.contains($0.folderID) && (0...5).contains($0.rating) }) else {
            throw CatalogRepositoryError.invalidCatalog("Dateiverweise oder Bewertungen sind ungültig.")
        }
    }
}
