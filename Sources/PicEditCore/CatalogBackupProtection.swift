import Foundation

extension CatalogRepository {
    /// User exports cannot be placed into app storage, even if a dialog was
    /// opened before that storage directory existed. The same catalog lock
    /// protects the final original check and exclusive package publication.
    func withBackupExportProtection<Result>(destination: URL, operation: () throws -> Result) throws -> Result {
        try withBackupPruningProtection(deletionRoots: [destination]) { protected in
            guard protected == [false] else { throw PhotoMetadataError.protectedPath }
            try PhotoMetadataFiles.checkDestination(destination,
                protection: CatalogManagedStoragePaths.protection(in: directory), extra: [])
            return try operation()
        }
    }

    /// Gate maintenance drains already accepted imports before this call. The
    /// native publication lock then prevents a cooperative publisher from
    /// introducing a new original between this fresh inventory and deletion.
    /// Call on a background executor; never await from the operation.
    func withBackupPruningProtection<Result>(deletionRoots: [URL],
        operation: ([Bool]) throws -> Result) throws -> Result {
        guard deletionRoots.count <= 64 else { throw ArtifactContractError.limitExceeded }
        return try CatalogFileIO.withSnapshotLock(directory: directory) { contents, validateBoundary in
            let catalog: LibraryCatalog
            if let bytes = contents.data {
                do { catalog = try JSONDecoder().decode(LibraryCatalog.self, from: bytes) }
                catch { throw CatalogRepositoryError.corruptCatalog(fileURL) }
            } else { catalog = LibraryCatalog() }
            try validate(catalog)
            var rootIndices: [String: [Int]] = [:]
            for (index, root) in deletionRoots.enumerated() {
                guard root.isFileURL, let key = FilePathComparison.protectionKey(root) else {
                    throw PhotoMetadataError.protectedPath
                }
                rootIndices[key, default: []].append(index)
            }
            var protected = Array(repeating: false, count: deletionRoots.count)
            // Resolve each original only once. Walking its parents looks up the
            // at-most-64 roots without a second full catalog URL/key array or a
            // native filesystem lookup for every original/package pair.
            for asset in catalog.assets {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard var key = FilePathComparison.protectionKey(asset.fileURL) else {
                        throw PhotoMetadataError.protectedPath
                    }
                    if asset.fileURL.hasDirectoryPath {
                        for (root, indices) in rootIndices where root == key || root.hasPrefix(key == "/" ? "/" : key + "/") {
                            for index in indices { protected[index] = true }
                        }
                    }
                    for _ in 0..<4_096 {
                        if let indices = rootIndices[key] { for index in indices { protected[index] = true } }
                        if key == "/" { break }
                        let parent = (key as NSString).deletingLastPathComponent
                        guard parent.hasPrefix("/"), parent.utf8.count < key.utf8.count else {
                            throw PhotoMetadataError.protectedPath
                        }
                        key = parent
                    }
                    guard key == "/" else { throw PhotoMetadataError.protectedPath }
                }
            }
            try validateBoundary()
            return try operation(protected)
        }
    }
}
