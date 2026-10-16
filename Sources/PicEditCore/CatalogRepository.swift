import Foundation

public enum CatalogRepositoryError: LocalizedError {
    case corruptCatalog(URL)
    case unsupportedVersion(Int)
    case invalidCatalog(String)
    case concurrentModification
    case invalidStage
    case sizeLimit

    public var errorDescription: String? {
        switch self {
        case .corruptCatalog(let url):
            return "Der Katalog „\(url.lastPathComponent)“ ist beschädigt und konnte nicht geladen werden. Die vorhandene Datei bleibt erhalten."
        case .unsupportedVersion(let version):
            return "Dieser Katalog verwendet die nicht unterstützte Version \(version)."
        case .invalidCatalog(let reason):
            return "Der Katalog ist ungültig: \(reason)"
        case .concurrentModification:
            return "Die gespeicherte Bibliothek wurde inzwischen geändert. Bitte neu laden; der bestehende Katalog bleibt erhalten."
        case .invalidStage:
            return "Die vorbereiteten Katalogdaten sind nicht mehr gültig. Die bestehende Bibliothek bleibt erhalten."
        case .sizeLimit:
            return "Die Katalogdatei überschreitet die unterstützte Größe von 512 MiB. Sie bleibt unverändert erhalten."
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

    public func load() throws -> LibraryCatalog { try loadStored().catalog }

    public func loadStored() throws -> StoredLibraryCatalog {
        let contents = try CatalogFileIO.readCatalog(directory: directory)
        guard let data = contents.data else {
            return StoredLibraryCatalog(catalog: LibraryCatalog(), reference: .absent)
        }
        let catalog: LibraryCatalog
        do { catalog = try JSONDecoder().decode(LibraryCatalog.self, from: data) }
        catch { throw CatalogRepositoryError.corruptCatalog(fileURL) }
        try validate(catalog)
        return StoredLibraryCatalog(catalog: catalog, reference: contents.reference)
    }

    /// Encode once; these same immutable bytes determine the journal's after
    /// reference and the later publication. Default Date coding preserves the
    /// exact reference-epoch Double, including adjacent representable values.
    public func prepare(_ catalog: LibraryCatalog) throws -> PreparedLibraryCatalog {
        try validate(catalog)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(catalog)
        guard bytes.count <= CatalogFileIO.maximumBytes else { throw CatalogRepositoryError.sizeLimit }
        return PreparedLibraryCatalog(catalog: catalog, bytes: bytes)
    }

    public func stage(_ prepared: PreparedLibraryCatalog, id: UUID = UUID()) throws -> StagedLibraryCatalog {
        try CatalogFileIO.stage(prepared, directory: directory, id: id)
    }

    /// Cooperative processes share a native lock. Exact before-byte identity is
    /// checked immediately before replacing the fixed catalog directory entry.
    public func publish(_ stage: StagedLibraryCatalog, expected: MetadataCatalogFileReference) throws {
        try CatalogFileIO.publish(stage, directory: directory, expected: expected)
    }

    /// A narrow synchronous cross-process barrier for metadata export's final
    /// catalog-reference check and atomic rename. Never await or call this
    /// repository recursively inside the closure.
    public func withPublicationLock<Result>(_ operation: (MetadataCatalogFileReference) throws -> Result) throws -> Result {
        try CatalogFileIO.withPublicationLock(directory: directory, operation: operation)
    }

    public func discard(_ stage: StagedLibraryCatalog) { CatalogFileIO.discard(stage) }

    /// Legacy callers still serialize their own catalog snapshots. New app
    /// writes retain loadStored's exact reference and use publish(expected:).
    public func save(_ catalog: LibraryCatalog) throws {
        let expected = try loadStored().reference
        let prepared = try prepare(catalog)
        let stage = try self.stage(prepared)
        defer { discard(stage) }
        try publish(stage, expected: expected)
    }

    private func validate(_ catalog: LibraryCatalog) throws {
        guard catalog.version == LibraryCatalog.currentVersion else {
            throw CatalogRepositoryError.unsupportedVersion(catalog.version)
        }
        guard catalog.assets.count <= PhotoMetadataLimits.maximumCatalogAssets else {
            throw CatalogRepositoryError.sizeLimit
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
