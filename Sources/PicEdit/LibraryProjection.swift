import Foundation
import PicEditCore

enum LibrarySearchMode: String, CaseIterable, Identifiable, Sendable {
    case literal, semantic
    var id: Self { self }
    var label: String { self == .literal ? "Wörtlich" : "Semantisch" }
}

struct LibraryProjectionKey: Equatable, Sendable {
    let selection: LibrarySelection
    let query: String
    let sort: PhotoSort
    let minimumRating: Int
    let searchMode: LibrarySearchMode
    let semanticQuery: String
    let topK: Int

    init(selection: LibrarySelection, query: String, sort: PhotoSort, minimumRating: Int,
         searchMode: LibrarySearchMode = .literal, semanticQuery: String = "", topK: Int = 100) {
        self.selection = selection; self.query = query; self.sort = sort; self.minimumRating = minimumRating
        self.searchMode = searchMode; self.semanticQuery = semanticQuery
        self.topK = min(500, max(1, topK))
    }
    var usesSemanticRanking: Bool { searchMode == .semantic && !semanticQuery.isEmpty }
}

struct LibraryProjectionCandidates: Sendable {
    let snapshotSessionID: UUID
    let generation: Int
    let base: LibraryProjection
    var assets: [PhotoAsset] { base.assets }
}

struct LibraryProjection: Sendable {
    let key: LibraryProjectionKey
    let assets: [PhotoAsset]
    let indices: [String: Int]
    let favoriteCount: Int
    let trees: [UUID: FolderTreeNode]
    let treeFolders: [UUID: LibraryFolder]
    let comparisonPaths: [URL: String]
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
    private var comparisonPaths: [URL: String] = [:]

    func project(_ catalog: LibraryCatalog, generation: Int, key: LibraryProjectionKey,
                 date: Date, overrides: [UUID: LibraryFolder], metadata: PhotoMetadataSearchSnapshot? = nil) throws -> LibraryProjection {
        try Task.checkCancellation()
        if cachedGeneration != generation {
            var nextIndices: [String: Int] = [:]
            nextIndices.reserveCapacity(catalog.assets.count)
            var favorites = 0
            var nextPaths: [URL: String] = [:]
            nextPaths.reserveCapacity(catalog.assets.count + catalog.folders.count)
            for (index, asset) in catalog.assets.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                if nextIndices[asset.id] == nil { nextIndices[asset.id] = index }
                if asset.isFavorite { favorites += 1 }
                if nextPaths[asset.fileURL] == nil { nextPaths[asset.fileURL] = Self.filePath(asset.fileURL) }
            }
            indices = nextIndices
            favoriteCount = favorites
            comparisonPaths = nextPaths
            trees = [:]
            treeFolders = [:]
            cachedGeneration = generation
        }
        for original in catalog.folders {
            try Task.checkCancellation()
            let folder = overrides[original.id] ?? original
            if comparisonPaths[folder.url] == nil { comparisonPaths[folder.url] = Self.filePath(folder.url) }
            if treeFolders[folder.id] != folder {
                trees[folder.id] = try FolderTreeNode.makeCancellable(folder: folder, assets: catalog.assets, comparisonPaths: comparisonPaths)
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
        case .folder(let id): prefix = catalog.folders.first { $0.id == id }.flatMap { comparisonPaths[$0.url] }.map(Self.directoryPrefix)
        case .subfolder(let id, let path):
            prefix = catalog.folders.first { $0.id == id }.flatMap { comparisonPaths[$0.url] }.map { Self.directoryPrefix(Self.directoryPrefix($0) + path) }
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
            case .folder, .subfolder: included = prefix.map { comparisonPaths[asset.fileURL]?.hasPrefix($0) ?? false } ?? false
            }
            guard included, asset.rating >= key.minimumRating else { continue }
            if key.query.isEmpty { visible.append(asset); continue }
            var values = [asset.fileName, asset.cameraModel ?? "", asset.format]
            if let fields = metadata?.confirmedByAssetID[asset.id] {
                values += [fields.title, fields.description] + fields.tags
            }
            if values.contains(where: { $0.localizedStandardContains(key.query) }) { visible.append(asset) }
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
                                 trees: trees, treeFolders: treeFolders, comparisonPaths: comparisonPaths, evaluatedAt: date, expiresAt: expiresAt)
    }

    func candidates(_ catalog: LibraryCatalog, snapshotSessionID: UUID, generation: Int,
                    key: LibraryProjectionKey, date: Date, overrides: [UUID: LibraryFolder], metadata: PhotoMetadataSearchSnapshot? = nil) throws -> LibraryProjectionCandidates {
        // The existing sole worker applies every literal/navigation predicate
        // before scoring, and provides the stable fallback order at top-K ties.
        let base = try project(catalog, generation: generation, key: key, date: date, overrides: overrides, metadata: metadata)
        return LibraryProjectionCandidates(snapshotSessionID: snapshotSessionID, generation: generation, base: base)
    }

    func rank(_ candidates: LibraryProjectionCandidates, result: SemanticSearchResult, topK: Int) throws -> LibraryProjection {
        try Task.checkCancellation()
        guard result.catalogSessionID == candidates.snapshotSessionID,
              result.catalogGeneration == candidates.generation,
              result.candidateAssetIDs.count == candidates.assets.count else { throw SemanticEmbeddingError.staleSource }
        guard result.hits.count <= min(500, max(1, topK)) else { throw SemanticEmbeddingError.invalidVector }
        try result.modelDescriptor.validate()
        var ordinal: [String: Int] = [:]
        for (index, asset) in candidates.assets.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard result.candidateAssetIDs[index] == asset.id else { throw SemanticEmbeddingError.staleSource }
            ordinal[asset.id] = index
        }
        var seen: Set<String> = []
        for (index, hit) in result.hits.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard hit.score.isFinite, ordinal[hit.assetID] != nil, seen.insert(hit.assetID).inserted else {
                throw SemanticEmbeddingError.invalidVector
            }
        }
        let ranked = result.hits.sorted {
            $0.score == $1.score ? ordinal[$0.assetID]! < ordinal[$1.assetID]! : $0.score > $1.score
        }
        return replacingAssets(candidates.base, with: ranked.map { candidates.assets[ordinal[$0.assetID]!] })
    }

    func empty(_ candidates: LibraryProjectionCandidates) -> LibraryProjection {
        replacingAssets(candidates.base, with: [])
    }

    private func replacingAssets(_ base: LibraryProjection, with assets: [PhotoAsset]) -> LibraryProjection {
        LibraryProjection(key: base.key, assets: assets, indices: base.indices, favoriteCount: base.favoriteCount,
                          trees: base.trees, treeFolders: base.treeFolders, comparisonPaths: base.comparisonPaths, evaluatedAt: base.evaluatedAt, expiresAt: base.expiresAt)
    }

    // One shared native comparison implementation for catalog membership,
    // missing originals and durable metadata relocation proof validation.
    // The worker builds UI comparison maps; persisted paths stay unchanged.
    static func filePath(_ url: URL) -> String { FilePathComparison.canonicalPath(url) }

    static func directoryPrefix(_ url: URL) -> String { directoryPrefix(filePath(url)) }
    private static func directoryPrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}
