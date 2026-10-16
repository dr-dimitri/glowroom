import Foundation
import PicEditCore

struct LibraryProjectionKey: Equatable, Sendable {
    let selection: LibrarySelection
    let query: String
    let sort: PhotoSort
    let minimumRating: Int
}

struct LibraryProjection: Sendable {
    let key: LibraryProjectionKey
    let assets: [PhotoAsset]
    let indices: [String: Int]
    let favoriteCount: Int
    let trees: [UUID: FolderTreeNode]
    let treeFolders: [UUID: LibraryFolder]
    let evaluatedAt: Date
    let expiresAt: Date?
}

/// One CPU worker per library. Sharing this actor bounds rapid filter changes to
/// one calculation; cancelled queued requests exit before touching the catalog.
/// Sorting and tree construction run alongside image workers, never on MainActor.
actor LibraryProjectionWorker {
    private var cachedGeneration = -1
    private var indices: [String: Int] = [:]
    private var favoriteCount = 0
    private var trees: [UUID: FolderTreeNode] = [:]
    private var treeFolders: [UUID: LibraryFolder] = [:]

    func project(_ catalog: LibraryCatalog, generation: Int, key: LibraryProjectionKey,
                 date: Date, overrides: [UUID: LibraryFolder]) throws -> LibraryProjection {
        try Task.checkCancellation()
        if cachedGeneration != generation {
            var nextIndices: [String: Int] = [:]
            nextIndices.reserveCapacity(catalog.assets.count)
            var favorites = 0
            for (index, asset) in catalog.assets.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                if nextIndices[asset.id] == nil { nextIndices[asset.id] = index }
                if asset.isFavorite { favorites += 1 }
            }
            indices = nextIndices
            favoriteCount = favorites
            trees = [:]
            treeFolders = [:]
            cachedGeneration = generation
        }
        for original in catalog.folders {
            try Task.checkCancellation()
            let folder = overrides[original.id] ?? original
            if treeFolders[folder.id] != folder {
                trees[folder.id] = try FolderTreeNode.makeCancellable(folder: folder, assets: catalog.assets)
                treeFolders[folder.id] = folder
            }
        }
        var recentIDs: Set<UUID> = []
        var expiresAt: Date?
        if key.selection == .recent {
            for folder in catalog.folders {
                let expiration = folder.addedAt.addingTimeInterval(7 * 86400)
                if expiration > date {
                    recentIDs.insert(folder.id)
                    expiresAt = min(expiresAt ?? expiration, expiration)
                }
            }
        }
        let prefix: String?
        switch key.selection {
        case .folder(let id): prefix = catalog.folders.first { $0.id == id }.map { Self.directoryPrefix($0.url) }
        case .subfolder(let id, let path):
            prefix = catalog.folders.first { $0.id == id }.map { Self.directoryPrefix($0.url.appendingPathComponent(path)) }
        default: prefix = nil
        }
        var visible: [PhotoAsset] = []
        for (index, asset) in catalog.assets.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            let included: Bool
            switch key.selection {
            case .all: included = true
            case .favorites: included = asset.isFavorite
            case .recent: included = recentIDs.contains(asset.folderID)
            case .folder, .subfolder: included = prefix.map { asset.fileURL.path.hasPrefix($0) } ?? false
            }
            if included && asset.rating >= key.minimumRating && (key.query.isEmpty ||
                [asset.fileName, asset.cameraModel ?? "", asset.format].contains { $0.localizedStandardContains(key.query) }) {
                visible.append(asset)
            }
        }
        // Swift's sort is not interruptible; only one sort can run on this actor.
        visible.sort { lhs, rhs in
            switch key.sort {
            case .date:
                let l = lhs.captureDate ?? lhs.createdAt, r = rhs.captureDate ?? rhs.createdAt
                if l != r { return l > r }
            case .rating:
                if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
            case .name: break
            }
            let order = lhs.fileName.localizedStandardCompare(rhs.fileName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        try Task.checkCancellation()
        return LibraryProjection(key: key, assets: visible, indices: indices, favoriteCount: favoriteCount,
                                 trees: trees, treeFolders: treeFolders, evaluatedAt: date, expiresAt: expiresAt)
    }

    static func directoryPrefix(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }
}
