import AppKit
import Combine
import PicEditCore

enum LibrarySelection: Hashable {
    case all, favorites, recent, folder(UUID), subfolder(UUID, String)
}

enum PhotoSort: String, CaseIterable, Identifiable {
    case date = "Aufnahmedatum", name = "Dateiname", rating = "Bewertung"
    var id: String { rawValue }
}

private actor CatalogWriter {
    let repository: CatalogRepository
    private var lastRevision = -1
    init(repository: CatalogRepository) { self.repository = repository }
    func load() throws -> LibraryCatalog { try repository.load() }
    func save(_ catalog: LibraryCatalog, revision: Int) throws {
        guard revision > lastRevision else { return }
        try repository.save(catalog)
        lastRevision = revision
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var catalog = LibraryCatalog() {
        didSet { invalidateCatalogProjections() }
    }
    @Published var selection: LibrarySelection = .all
    @Published var selectedID: String?
    @Published var search = ""
    @Published var sort: PhotoSort = .date
    @Published var minimumRating = 0
    @Published var gridSize: Double = 210
    @Published var isDeveloping = false
    @Published var comparesOriginal = false
    @Published var showsDetail = false
    @Published var showsInspector = true
    @Published private(set) var isLoading = true
    @Published private(set) var isImporting = false
    @Published private(set) var importStatus = ""
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published private(set) var isReadOnly = false
    @Published private(set) var isClosing = false
    private let writer: CatalogWriter
    private var revision = 0
    private var importTask: Task<Void, Never>?
    private var activeScopes: [UUID: URL] = [:]
    private var queuedFolders: [URL] = []
    private let now: () -> Date

    private struct VisibleProjectionKey: Equatable {
        let selection: LibrarySelection
        let query: String
        let sort: PhotoSort
        let minimumRating: Int
    }
    private struct VisibleProjection {
        let key: VisibleProjectionKey
        let assets: [PhotoAsset]
        let evaluatedAt: Date?
        let expiresAt: Date?
    }
    private struct AssetSummary {
        let indices: [String: Int]
        let favoriteCount: Int
    }
    private struct TreeProjection {
        let url: URL
        let name: String
        let paths: [String]
        let node: FolderTreeNode
    }
    // These projections are shared by the grid, sidebar and inspector. Selection,
    // thumbnail-size and panel changes do not change the underlying catalog.
    private var visibleProjection: VisibleProjection?
    private var assetSummary: AssetSummary?
    private var treeProjections: [UUID: TreeProjection] = [:]
    var gridColumnCount = 3

    init(repository: CatalogRepository = CatalogRepository(), now: @escaping () -> Date = Date.init) {
        writer = CatalogWriter(repository: repository)
        self.now = now
        Task { await load() }
    }

    var folders: [LibraryFolder] { catalog.folders }
    var assets: [PhotoAsset] { catalog.assets }
    var favoriteCount: Int { catalogSummary().favoriteCount }
    var selectedAsset: PhotoAsset? {
        guard let selectedID, let index = catalogSummary().indices[selectedID] else { return nil }
        return assets[index]
    }
    var canModify: Bool { !isLoading && !isReadOnly && !isClosing }
    var title: String {
        switch selection {
        case .all: "Alle Fotos"
        case .favorites: "Favoriten"
        case .recent: "Zuletzt hinzugefügt"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Ordner"
        case .subfolder(_, let path): (path as NSString).lastPathComponent
        }
    }
    var subtitle: String {
        switch selection {
        case .all: "Deine Bilder. Ein Ort."
        case .favorites: "Die Bilder, die bleiben."
        case .recent: "Ordner aus den letzten 7 Tagen"
        case .folder(let id): folders.first { $0.id == id }?.url.path ?? ""
        case .subfolder(let id, let path): folders.first { $0.id == id }?.url.appendingPathComponent(path).path ?? ""
        }
    }
    var visibleAssets: [PhotoAsset] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = VisibleProjectionKey(selection: selection, query: query, sort: sort, minimumRating: minimumRating)
        let currentDate = selection == .recent ? now() : nil
        if let cached = visibleProjection, cached.key == key {
            if let currentDate, let evaluatedAt = cached.evaluatedAt {
                // Rolling seven-day membership also changes without a catalog mutation.
                if currentDate >= evaluatedAt && (cached.expiresAt.map { currentDate < $0 } ?? true) {
                    return cached.assets
                }
            } else { return cached.assets }
        }

        var recentIDs: Set<UUID> = []
        var expiresAt: Date?
        if let currentDate {
            for folder in folders {
                let expiration = folder.addedAt.addingTimeInterval(7 * 86400)
                if expiration > currentDate {
                    recentIDs.insert(folder.id)
                    expiresAt = min(expiresAt ?? expiration, expiration)
                }
            }
        }
        // Resolve and standardize the selected folder once, not for every photo.
        let selectedPrefix: String?
        switch selection {
        case .folder(let id):
            selectedPrefix = folders.first(where: { $0.id == id }).map { directoryPrefix($0.url) }
        case .subfolder(let id, let path):
            selectedPrefix = folders.first(where: { $0.id == id }).map { directoryPrefix($0.url.appendingPathComponent(path)) }
        default: selectedPrefix = nil
        }
        let result = assets.filter { asset in
            let included: Bool
            switch selection {
            case .all: included = true
            case .favorites: included = asset.isFavorite
            case .recent: included = recentIDs.contains(asset.folderID)
            case .folder, .subfolder: included = selectedPrefix.map { asset.fileURL.path.hasPrefix($0) } ?? false
            }
            return included && asset.rating >= minimumRating && (query.isEmpty ||
                [asset.fileName, asset.cameraModel ?? "", asset.format].contains { $0.localizedStandardContains(query) })
        }.sorted { lhs, rhs in
            switch sort {
            case .date:
                let l = lhs.captureDate ?? lhs.createdAt, r = rhs.captureDate ?? rhs.createdAt
                if l != r { return l > r }
            case .rating:
                if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
            case .name: break
            }
            let comparison = lhs.fileName.localizedStandardCompare(rhs.fileName)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
        visibleProjection = VisibleProjection(key: key, assets: result, evaluatedAt: currentDate, expiresAt: expiresAt)
        return result
    }

    private func invalidateCatalogProjections() {
        visibleProjection = nil
        assetSummary = nil
        treeProjections.removeAll(keepingCapacity: true)
    }

    private func catalogSummary() -> AssetSummary {
        if let assetSummary { return assetSummary }
        var indices: [String: Int] = [:]
        indices.reserveCapacity(assets.count)
        var favorites = 0
        for (index, asset) in assets.enumerated() {
            if indices[asset.id] == nil { indices[asset.id] = index }
            if asset.isFavorite { favorites += 1 }
        }
        let summary = AssetSummary(indices: indices, favoriteCount: favorites)
        assetSummary = summary
        return summary
    }

    private func directoryPrefix(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func load() async {
        var updatedFolderStructure = false
        do {
            catalog = try await writer.load()
            for index in catalog.folders.indices {
                let folder = catalog.folders[index]
                var resolved = folder.url
                if let data = folder.bookmarkData {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        resolved = url
                        if stale {
                            catalog.folders[index].bookmarkData = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data
                        }
                    }
                }
                if resolved.startAccessingSecurityScopedResource() { activeScopes[folder.id] = resolved }
                if resolved.standardizedFileURL != folder.url.standardizedFileURL {
                    let oldPrefix = folder.url.path.hasSuffix("/") ? folder.url.path : folder.url.path + "/"
                    for i in catalog.assets.indices where catalog.assets[i].folderID == folder.id {
                        let oldPath = catalog.assets[i].fileURL.path
                        if oldPath.hasPrefix(oldPrefix) {
                            let url = resolved.appendingPathComponent(String(oldPath.dropFirst(oldPrefix.count)))
                            catalog.assets[i].fileURL = url
                            catalog.assets[i].id = url.resolvingSymlinksInPath().standardizedFileURL.path
                        }
                    }
                    catalog.folders[index].url = resolved
                }
                // Older catalogs only stored image paths. Discover empty folders too,
                // without re-decoding images or changing the existing photo records.
                if catalog.folders[index].subdirectoryPaths.isEmpty,
                   let paths = try? await FolderScanner().scanSubdirectories(folder: catalog.folders[index]),
                   !paths.isEmpty {
                    catalog.folders[index].subdirectoryPaths = paths
                    updatedFolderStructure = true
                }
            }
            selectedID = visibleAssets.first?.id
        } catch {
            isReadOnly = true
            errorMessage = "Der Katalog konnte nicht geöffnet werden. Die vorhandene Datei bleibt unverändert.\n\n\(error.localizedDescription)"
        }
        isLoading = false
        if updatedFolderStructure { persist() }
    }

    func chooseFolders() {
        guard canModify, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Ordner zur Bibliothek hinzufügen"
        panel.message = "Bilder und Unterordner werden eingelesen. Deine Originale bleiben an ihrem Speicherort."
        panel.prompt = "Hinzufügen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importFolders(panel.urls) }
    }

    func importFolders(_ urls: [URL], preservingSelection previousSelection: LibrarySelection? = nil) {
        guard canModify, !isImporting, !urls.isEmpty else { return }
        isImporting = true
        notice = nil
        importTask = Task {
            var total = 0
            var skipped = 0
            var failures: [String] = []
            defer {
                isImporting = false
                importStatus = ""
                importTask = nil
                let queued = queuedFolders
                queuedFolders = []
                if !Task.isCancelled && !queued.isEmpty { importFolders(queued) }
            }
            for (offset, originalURL) in urls.enumerated() {
                if Task.isCancelled { break }
                let url = originalURL.resolvingSymlinksInPath().standardizedFileURL
                importStatus = "\(offset + 1)/\(urls.count) · \(url.lastPathComponent) wird eingelesen …"
                let existing = catalog.folders.first { $0.url.resolvingSymlinksInPath().standardizedFileURL == url }
                var folder = existing ?? LibraryFolder(url: url)
                let started = originalURL.startAccessingSecurityScopedResource()
                folder.bookmarkData = (try? originalURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? folder.bookmarkData
                do {
                    let result = try await FolderScanner().scan(folder: folder)
                    try Task.checkCancellation()
                    let old = Dictionary(catalog.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    let imported = result.assets.map { asset in
                        var asset = asset
                        if let previous = old[asset.id] {
                            asset.folderID = previous.folderID
                            asset.rating = previous.rating
                            asset.isFavorite = previous.isFavorite
                        }
                        return asset
                    }
                    // A temporarily undecodable original must not erase its catalog metadata.
                    let skippedIDs = Set(result.skippedURLs.map { $0.path })
                    let retained = catalog.assets.filter { contains($0, in: folder) && skippedIDs.contains($0.id) }
                    folder.lastScannedAt = Date()
                    folder.subdirectoryPaths = result.subdirectoryPaths
                    // Reconcile the scanned path, including photos also shown by an overlapping folder.
                    catalog.assets.removeAll { contains($0, in: folder) }
                    catalog.assets.append(contentsOf: imported + retained)
                    if let index = catalog.folders.firstIndex(where: { $0.id == folder.id }) { catalog.folders[index] = folder }
                    else { catalog.folders.append(folder) }
                    total += imported.filter { old[$0.id] == nil }.count
                    skipped += result.skippedFiles
                    if started {
                        if activeScopes[folder.id] == nil { activeScopes[folder.id] = originalURL }
                        else { originalURL.stopAccessingSecurityScopedResource() }
                    }
                    if previousSelection == nil {
                        selection = .folder(folder.id)
                        search = ""
                        minimumRating = 0
                    }
                    reconcileSelection()
                    persist()
                } catch is CancellationError {
                    if started { originalURL.stopAccessingSecurityScopedResource() }
                    break
                } catch {
                    if started { originalURL.stopAccessingSecurityScopedResource() }
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            notice = Task.isCancelled ? "Import abgebrochen. Bereits eingelesene Ordner bleiben erhalten." : "\(total) neue Fotos hinzugefügt" + (skipped > 0 ? " · \(skipped) nicht lesbare Bilder übersprungen" : "")
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    func enqueueFolders(_ urls: [URL]) {
        guard canModify else { return }
        if isImporting {
            queuedFolders.append(contentsOf: urls.filter { !queuedFolders.contains($0) })
        } else { importFolders(urls) }
    }

    func refreshCurrentFolder() {
        let selectedFolderID: UUID?
        switch selection {
        case .folder(let id), .subfolder(let id, _): selectedFolderID = id
        default: selectedFolderID = nil
        }
        if let folder = folders.first(where: { $0.id == selectedFolderID }) {
            importFolders([folder.url], preservingSelection: selection)
        } else { importFolders(folders.map(\.url), preservingSelection: selection) }
    }

    func cancelImport() { importTask?.cancel() }

    func removeFolder(_ id: UUID) {
        guard canModify, !isImporting else { return }
        catalog.folders.removeAll { $0.id == id }
        catalog.assets = catalog.assets.compactMap { asset in
            guard asset.folderID == id else { return asset }
            guard let replacement = catalog.folders.filter({ contains(asset, in: $0) }).max(by: { $0.url.path.count < $1.url.path.count }) else { return nil }
            var retained = asset
            retained.folderID = replacement.id
            return retained
        }
        activeScopes.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        switch selection {
        case .folder(let selectedFolder), .subfolder(let selectedFolder, _):
            if selectedFolder == id { selection = .all }
        default: break
        }
        reconcileSelection()
        persist()
        notice = "Ordner aus der Bibliothek entfernt. Originaldateien bleiben erhalten."
    }

    func setRating(_ rating: Int, for id: String? = nil) {
        guard canModify, let index = catalog.assets.firstIndex(where: { $0.id == (id ?? selectedID) }) else { return }
        catalog.assets[index].rating = min(5, max(0, rating))
        persist()
        reconcileSelection()
    }

    func toggleFavorite(_ id: String? = nil) {
        guard canModify, let index = catalog.assets.firstIndex(where: { $0.id == (id ?? selectedID) }) else { return }
        catalog.assets[index].isFavorite.toggle()
        persist()
        reconcileSelection()
    }

    func contains(_ asset: PhotoAsset, in folder: LibraryFolder) -> Bool {
        contains(asset, below: folder.url)
    }
    private func contains(_ asset: PhotoAsset, below url: URL) -> Bool {
        asset.fileURL.path.hasPrefix(directoryPrefix(url))
    }
    func count(in folder: LibraryFolder) -> Int { folderTree(for: folder).photoCount }
    func folderTree(for folder: LibraryFolder) -> FolderTreeNode {
        if let cached = treeProjections[folder.id], cached.url == folder.url,
           cached.name == folder.name, cached.paths == folder.subdirectoryPaths {
            return cached.node
        }
        // The builder already filters by folder prefix, so a second full scan is unnecessary.
        let node = FolderTreeNode.make(folder: folder, assets: assets)
        if folders.contains(where: { $0.id == folder.id }) {
            treeProjections[folder.id] = TreeProjection(url: folder.url, name: folder.name, paths: folder.subdirectoryPaths, node: node)
        }
        return node
    }
    func selectFolder(_ folder: LibraryFolder, relativePath: String) {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        selection = relativePath.isEmpty ? .folder(folder.id) : .subfolder(folder.id, relativePath)
        reconcileSelection()
    }
    func select(_ asset: PhotoAsset) {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        selectedID = asset.id
    }
    func reconcileSelection() {
        if case .subfolder(let id, let path) = selection {
            if let folder = folders.first(where: { $0.id == id }) {
                if !folderTree(for: folder).contains(relativePath: path) { selection = .folder(id) }
            } else { selection = .all }
        }
        let visible = visibleAssets
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
        if visible.isEmpty { showsDetail = false }
    }
    func navigate(_ delta: Int) {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        let visible = visibleAssets
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[min(visible.count - 1, max(0, index + delta))].id
    }
    func reveal(_ asset: PhotoAsset? = nil) {
        if let asset = asset ?? selectedAsset { NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL]) }
    }

    private func persist() {
        guard canModify else { return }
        revision += 1
        let snapshot = catalog, number = revision
        Task {
            do { try await writer.save(snapshot, revision: number) }
            catch { errorMessage = "Änderungen konnten nicht gespeichert werden.\n\n\(error.localizedDescription)" }
        }
    }

    func beginTermination() { isClosing = true; importTask?.cancel(); queuedFolders = [] }
    func cancelTermination() { isClosing = false }

    func finishSaving() async -> Bool {
        importTask?.cancel()
        guard !isLoading && !isReadOnly else { return true }
        revision += 1
        do { try await writer.save(catalog, revision: revision); return true }
        catch { errorMessage = "Der Katalog konnte nicht gespeichert werden: \(error.localizedDescription)"; return false }
    }
}
