import Foundation
import PicEditCore

/// Pure catalog reconciliation and filesystem access have a single background
/// owner. The MainActor applies a result only if its input generation is current.
actor LibraryCatalogWorker {
    struct PreparedImport: Sendable {
        let folder: LibraryFolder
        let startedScope: Bool
    }
    struct MergedImport: Sendable {
        let catalog: LibraryCatalog
        let addedCount: Int
    }

    func prepareImport(_ originalURL: URL, folders: [LibraryFolder]) -> PreparedImport {
        let started = originalURL.startAccessingSecurityScopedResource()
        let url = originalURL.resolvingSymlinksInPath().standardizedFileURL
        let path = LibraryProjectionWorker.filePath(originalURL)
        let existing = folders.first { LibraryProjectionWorker.filePath($0.url) == path }
        var folder = existing ?? LibraryFolder(url: url)
        folder.bookmarkData = (try? originalURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? folder.bookmarkData
        return PreparedImport(folder: folder, startedScope: started)
    }

    func merge(_ result: ScanResult, folder original: LibraryFolder, into catalog: LibraryCatalog) throws -> MergedImport {
        try Task.checkCancellation()
        var old: [String: PhotoAsset] = [:]
        var oldByPath: [String: PhotoAsset] = [:]
        var ambiguousPaths: Set<String> = []
        for (index, asset) in catalog.assets.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            if old[asset.id] == nil { old[asset.id] = asset }
            let path = LibraryProjectionWorker.filePath(asset.fileURL)
            if let previous = oldByPath[path], previous.id != asset.id { ambiguousPaths.insert(path) }
            else { oldByPath[path] = asset }
        }
        var imported: [PhotoAsset] = []
        var added = 0
        for (index, original) in result.assets.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            var asset = original
            let path = LibraryProjectionWorker.filePath(asset.fileURL)
            if ambiguousPaths.contains(path) {
                throw CatalogRepositoryError.invalidCatalog("Mehrere gespeicherte Bildkennungen verweisen auf dieselbe Datei. Die Bibliothek bleibt unverändert.")
            }
            if let previous = old[asset.id] ?? oldByPath[path] {
                asset.id = previous.id
                asset.fileURL = previous.fileURL
                asset.folderID = previous.folderID
                asset.rating = previous.rating
                asset.isFavorite = previous.isFavorite
            } else { added += 1 }
            imported.append(asset)
        }
        let prefix = LibraryProjectionWorker.directoryPrefix(original.url)
        let skippedPaths = Set(result.skippedURLs.map { LibraryProjectionWorker.filePath($0) })
        var next = catalog
        next.assets = []
        var retained: [PhotoAsset] = []
        for (index, asset) in catalog.assets.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            if !LibraryProjectionWorker.filePath(asset.fileURL).hasPrefix(prefix) { next.assets.append(asset) }
            // Temporarily undecodable originals retain their saved metadata.
            else if skippedPaths.contains(LibraryProjectionWorker.filePath(asset.fileURL)) { retained.append(asset) }
        }
        next.assets.append(contentsOf: imported)
        next.assets.append(contentsOf: retained)
        var folder = original
        folder.lastScannedAt = Date()
        folder.subdirectoryPaths = result.subdirectoryPaths
        if let index = next.folders.firstIndex(where: { $0.id == folder.id }) { next.folders[index] = folder }
        else { next.folders.append(folder) }
        try Task.checkCancellation()
        return MergedImport(catalog: next, addedCount: added)
    }

    func removing(_ id: UUID, from catalog: LibraryCatalog) -> LibraryCatalog {
        var next = catalog
        next.folders.removeAll { $0.id == id }
        let replacements = next.folders.map { ($0.id, LibraryProjectionWorker.directoryPrefix($0.url)) }
            .sorted { $0.1.count > $1.1.count }
        next.assets = catalog.assets.compactMap { asset in
            guard asset.folderID == id else { return asset }
            let path = LibraryProjectionWorker.filePath(asset.fileURL)
            guard let replacement = replacements.first(where: { path.hasPrefix($0.1) }) else { return nil }
            var retained = asset
            retained.folderID = replacement.0
            return retained
        }
        return next
    }
}
