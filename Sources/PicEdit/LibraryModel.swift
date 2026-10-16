import AppKit
import Combine
import PicEditCore

enum LibrarySelection: Hashable, Sendable {
    case all, favorites, recent, folder(UUID), subfolder(UUID, String)
}

enum PhotoSort: String, CaseIterable, Identifiable, Sendable {
    case date = "Aufnahmedatum", name = "Dateiname", rating = "Bewertung"
    var id: String { rawValue }
}

private actor CatalogWriter {
    let repository: CatalogRepository
    private var lastRevision = -1
    init(repository: CatalogRepository) { self.repository = repository }
    struct LoadedCatalog: Sendable {
        var catalog: LibraryCatalog
        var scopes: [UUID: URL]
        var updated: Bool
    }

    func load() async throws -> LoadedCatalog {
        let stored = try repository.load()
        // Bookmark resolution and directory-only backfills are independent. Two
        // workers overlap disk waits without nesting the metadata scanner's pool.
        let resolved = await withTaskGroup(of: (Int, LibraryFolder, URL?).self) { group in
            var next = 0
            var results: [(Int, LibraryFolder, URL?)] = []
            func enqueue() {
                guard next < stored.folders.count else { return }
                let index = next, folder = stored.folders[index]
                next += 1
                group.addTask { await Self.resolve(folder, index: index) }
            }
            for _ in 0..<min(2, stored.folders.count) { enqueue() }
            while let result = await group.next() { results.append(result); enqueue() }
            return results.sorted { $0.0 < $1.0 }
        }
        var catalog = stored
        var scopes: [UUID: URL] = [:]
        var moved: [UUID: (String, URL)] = [:]
        for (index, folder, scope) in resolved {
            catalog.folders[index] = folder
            if let scope { scopes[folder.id] = scope }
            let old = stored.folders[index]
            if folder.url != old.url { moved[folder.id] = (LibraryProjectionWorker.directoryPrefix(old.url), folder.url) }
        }
        for index in catalog.assets.indices {
            let asset = catalog.assets[index]
            if let (prefix, destination) = moved[asset.folderID], asset.fileURL.path.hasPrefix(prefix) {
                let url = destination.appendingPathComponent(String(asset.fileURL.path.dropFirst(prefix.count)))
                catalog.assets[index].fileURL = url
                catalog.assets[index].id = url.resolvingSymlinksInPath().standardizedFileURL.path
            }
        }
        return LoadedCatalog(catalog: catalog, scopes: scopes, updated: catalog != stored)
    }

    private nonisolated static func resolve(_ original: LibraryFolder, index: Int) async -> (Int, LibraryFolder, URL?) {
        var folder = original
        if let data = folder.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                folder.url = url
                if stale {
                    folder.bookmarkData = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data
                }
            }
        }
        let scope = folder.url.startAccessingSecurityScopedResource() ? folder.url : nil
        if folder.subdirectoryPaths.isEmpty,
           let paths = try? await FolderScanner().scanSubdirectories(folder: folder), !paths.isEmpty {
            folder.subdirectoryPaths = paths
        }
        return (index, folder, scope)
    }
    func save(_ catalog: LibraryCatalog, revision: Int) throws {
        guard revision > lastRevision else { return }
        try repository.save(catalog)
        lastRevision = revision
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var catalog = LibraryCatalog() {
        didSet { catalogGeneration += 1; treeOverrides = [:]; scheduleProjection() }
    }
    @Published var selection: LibrarySelection = .all { didSet { scheduleProjection() } }
    @Published var selectedID: String?
    @Published var search = "" { didSet { scheduleProjection() } }
    @Published var sort: PhotoSort = .date { didSet { scheduleProjection() } }
    @Published var minimumRating = 0 { didSet { scheduleProjection() } }
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
    private let catalogWorker = LibraryCatalogWorker()
    private var mutationTask: Task<Void, Never>?
    @Published private(set) var isUpdatingCatalog = false
    private let writer: CatalogWriter
    private var revision = 0
    private var importTask: Task<Void, Never>?
    private var activeScopes: [UUID: URL] = [:]
    private var queuedFolders: [URL] = []
    private let now: () -> Date

    @Published private(set) var isProjecting = false
    private let projectionWorker = LibraryProjectionWorker()
    private var deferredProjectionTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var projection: LibraryProjection?
    private var projectionRevision = 0
    private var catalogGeneration = 0
    private var treeOverrides: [UUID: LibraryFolder] = [:]
    var gridColumnCount = 3

    init(repository: CatalogRepository = CatalogRepository(), now: @escaping () -> Date = Date.init) {
        writer = CatalogWriter(repository: repository)
        self.now = now
        Task { await load() }
    }

    var folders: [LibraryFolder] { catalog.folders }
    var assets: [PhotoAsset] { catalog.assets }
    var favoriteCount: Int { projection?.favoriteCount ?? 0 }
    var selectedAsset: PhotoAsset? {
        guard let selectedID else { return nil }
        if let index = projection?.indices[selectedID], assets.indices.contains(index), assets[index].id == selectedID {
            return assets[index]
        }
        // Only the brief catalog replacement window needs a single-ID lookup.
        return assets.first { $0.id == selectedID }
    }
    var canModify: Bool { !isLoading && !isReadOnly && !isClosing && !isUpdatingCatalog }
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
        refreshRecentProjectionIfNeeded()
        return projection?.assets ?? []
    }

    private func refreshRecentProjectionIfNeeded() {
        guard selection == .recent, !isProjecting, let projection else { return }
        let date = now()
        if date < projection.evaluatedAt || projection.expiresAt.map({ date >= $0 }) == true {
            deferProjection()
        }
    }

    // Getters can be read during SwiftUI body evaluation. Never publish from
    // that stack; defer only their invalidations until the next actor turn.
    private func deferProjection() {
        guard deferredProjectionTask == nil else { return }
        deferredProjectionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            deferredProjectionTask = nil
            scheduleProjection()
        }
    }

    private func scheduleProjection() {
        deferredProjectionTask?.cancel()
        deferredProjectionTask = nil
        projectionRevision += 1
        let number = projectionRevision
        projectionTask?.cancel()
        isProjecting = true
        projectionTask = Task { [weak self] in
            // Coalesce synchronous UI changes before copying the catalog snapshot.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            let key = LibraryProjectionKey(selection: selection, query: search.trimmingCharacters(in: .whitespacesAndNewlines),
                                           sort: sort, minimumRating: minimumRating)
            do {
                let result = try await projectionWorker.project(catalog, generation: catalogGeneration,
                                                                key: key, date: now(), overrides: treeOverrides)
                guard !Task.isCancelled, number == projectionRevision else { return }
                projection = result
                isProjecting = false
                projectionTask = nil
                reconcileSelection()
            } catch is CancellationError { }
            catch {
                guard number == projectionRevision else { return }
                isProjecting = false
                projectionTask = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Also used by imports and tests to wait for the latest, not an obsolete, request.
    func waitForProjection() async {
        if let mutationTask { await mutationTask.value }
        refreshRecentProjectionIfNeeded()
        while deferredProjectionTask != nil || projectionTask != nil {
            if let task = deferredProjectionTask { await task.value }
            if let task = projectionTask { await task.value }
        }
    }

    private func directoryPrefix(_ url: URL) -> String { LibraryProjectionWorker.directoryPrefix(url) }

    private func load() async {
        var updatedFolderStructure = false
        do {
            let loaded = try await writer.load()
            activeScopes = loaded.scopes
            catalog = loaded.catalog
            updatedFolderStructure = loaded.updated
            await waitForProjection()
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
                importStatus = "\(offset + 1)/\(urls.count) · \(originalURL.lastPathComponent) wird eingelesen …"
                let prepared = await catalogWorker.prepareImport(originalURL, folders: folders)
                let folder = prepared.folder, started = prepared.startedScope, url = folder.url
                do {
                    let result = try await FolderScanner().scan(folder: folder)
                    try Task.checkCancellation()
                    // Overlapping folders are committed in input order; their shared
                    // asset ownership depends on the preceding result. Parallelism
                    // lives in the scanner rather than a second nested worker pool.
                    while true {
                        let generation = catalogGeneration
                        let merged = try await catalogWorker.merge(result, folder: folder, into: catalog)
                        try Task.checkCancellation()
                        // Ratings/favorites may change while the merge runs. Retry
                        // against the latest snapshot so accepted edits survive.
                        guard generation == catalogGeneration else { continue }
                        catalog = merged.catalog
                        total += merged.addedCount
                        break
                    }
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
                    persist()
                    await waitForProjection()
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
        isUpdatingCatalog = true
        let snapshot = catalog
        mutationTask = Task {
            catalog = await catalogWorker.removing(id, from: snapshot)
            activeScopes.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
            switch selection {
            case .folder(let selectedFolder), .subfolder(let selectedFolder, _):
                if selectedFolder == id { selection = .all }
            default: break
            }
            isUpdatingCatalog = false
            mutationTask = nil
            persist()
            notice = "Ordner aus der Bibliothek entfernt. Originaldateien bleiben erhalten."
        }
    }

    private func assetIndex(for id: String?) -> Int? {
        guard let id else { return nil }
        if let index = projection?.indices[id], assets.indices.contains(index), assets[index].id == id { return index }
        return assets.firstIndex { $0.id == id }
    }

    func setRating(_ rating: Int, for id: String? = nil) {
        guard canModify, let index = assetIndex(for: id ?? selectedID) else { return }
        catalog.assets[index].rating = min(5, max(0, rating))
        persist()
    }

    func toggleFavorite(_ id: String? = nil) {
        guard canModify, let index = assetIndex(for: id ?? selectedID) else { return }
        catalog.assets[index].isFavorite.toggle()
        persist()
    }

    func contains(_ asset: PhotoAsset, in folder: LibraryFolder) -> Bool {
        contains(asset, below: folder.url)
    }
    private func contains(_ asset: PhotoAsset, below url: URL) -> Bool {
        asset.fileURL.path.hasPrefix(directoryPrefix(url))
    }
    func count(in folder: LibraryFolder) -> Int { folderTree(for: folder).photoCount }
    func folderTree(for folder: LibraryFolder) -> FolderTreeNode {
        if projection?.treeFolders[folder.id] == folder, let node = projection?.trees[folder.id] { return node }
        if folders.contains(where: { $0.id == folder.id }), treeOverrides[folder.id] != folder {
            treeOverrides[folder.id] = folder
            deferProjection()
        }
        return FolderTreeNode(relativePath: "", name: folder.name, photoCount: 0, children: [])
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
        guard !isProjecting else { return }
        if case .subfolder(let id, let path) = selection {
            if let folder = folders.first(where: { $0.id == id }) {
                if !folderTree(for: folder).contains(relativePath: path) { selection = .folder(id) }
            } else { selection = .all }
        }
        guard !isProjecting else { return }
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
        if let importTask { await importTask.value }
        if let mutationTask { await mutationTask.value }
        guard !isLoading && !isReadOnly else { return true }
        revision += 1
        do { try await writer.save(catalog, revision: revision); return true }
        catch { errorMessage = "Der Katalog konnte nicht gespeichert werden: \(error.localizedDescription)"; return false }
    }
}
