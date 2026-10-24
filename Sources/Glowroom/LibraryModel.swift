import AppKit
import Combine
import GlowroomCore

enum LibrarySelection: Hashable, Sendable {
    case all, favorites, recent, folder(UUID), subfolder(UUID, String)
}

enum PhotoSort: String, CaseIterable, Identifiable, Sendable {
    case date = "Aufnahmedatum", name = "Dateiname", rating = "Bewertung"
    var id: String { rawValue }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var catalog = LibraryCatalog() {
        didSet {
            advanceAISelectionGeneration()
            catalogGeneration += 1; treeOverrides = [:]; scheduleProjection()
        }
    }
    @Published var selection: LibrarySelection = .all {
        didSet {
            if oldValue != selection { advanceAISelectionGeneration() }
            scheduleProjection()
        }
    }
    /// The active photo drives the inspector; the set also contains the other
    /// selected photos. Keep direct assignments compatible with single selection.
    @Published var selectedID: String? {
        didSet {
            if oldValue != selectedID { advanceAISelectionGeneration() }
            guard !isApplyingSelection else { return }
            selectedIDs = selectedID.map { [$0] } ?? []
            selectionAnchorID = selectedID
            emptySelectionKey = selectedID == nil ? projection?.key : nil
            if selectedID == nil { showsDetail = false }
        }
    }
    @Published private(set) var selectedIDs: Set<String> = []
    private var selectionAnchorID: String?
    private var isApplyingSelection = false
    private var emptySelectionKey: LibraryProjectionKey?
    @Published var search = "" { didSet { scheduleProjection() } }
    @Published var searchMode: LibrarySearchMode = .literal {
        didSet { if searchMode == .literal { similarityReference = nil }; scheduleProjection() }
    }
    @Published private(set) var similarityReference: PhotoAsset?
    @Published var semanticQuery = "" { didSet { similarityReference = nil; scheduleProjection() } }
    @Published var semanticLiteralFilter = "" { didSet { scheduleProjection() } }
    @Published var semanticTopK = 100 { didSet { scheduleProjection() } }
    enum SemanticScope: String, CaseIterable, Identifiable {
        case filtered, all
        var id: Self { self }
        var label: String { self == .filtered ? "Aktuell gefilterte Ansicht" : "Gesamte Bibliothek" }
    }
    @Published var semanticScope: SemanticScope = .filtered { didSet { refreshSemanticStatus() } }
    @Published var semanticControlsExpanded = false {
        didSet { refreshSemanticStatus() }
    }
    @Published private(set) var semanticState = SemanticSearchState.notInstalled
    @Published private(set) var semanticError: String?
    @Published private(set) var semanticScopeCount = 0
    @Published private(set) var semanticScopeIsReady = false
    @Published private(set) var semanticOperationLabel: String?
    @Published private(set) var semanticActiveScopeLabel: String?
    @Published private(set) var semanticImportReview: SemanticModelImportReview?
    private let semanticSearch: (any SemanticSearchServing)?
    private let semanticCatalogSessionID = UUID()
    private var semanticUpdatesTask: Task<Void, Never>?
    private var semanticStatusTask: Task<Void, Never>?
    private var semanticOperationTask: Task<Void, Never>?
    private var semanticShutdownTask: Task<Void, Never>?
    private var semanticStatusID = UUID()
    private var semanticOperationID = UUID()
    @Published var sort: PhotoSort = .date { didSet { scheduleProjection() } }
    @Published var minimumRating = 0 { didSet { scheduleProjection() } }
    @Published var gridSize: Double = 210
    @Published var workspaceMode: LibraryWorkspace = .library {
        didSet {
            // Accept legacy callers/preferences without recreating a third workspace.
            if workspaceMode == .aiDevelop { workspaceMode = .develop }
        }
    }
    var isDeveloping: Bool {
        get { workspaceMode != .library }
        set { if !newValue { workspaceMode = .library } else if workspaceMode == .library { workspaceMode = .develop } }
    }
    @Published var comparesOriginal = false {
        didSet { if comparesOriginal { comparesCurrentSourceWithoutSettings = false; previewComparisonLayout = .single } }
    }
    @Published var comparesCurrentSourceWithoutSettings = false {
        didSet { if comparesCurrentSourceWithoutSettings { comparesOriginal = false; previewComparisonLayout = .single } }
    }
    @Published var previewComparisonLayout: PreviewComparisonLayout = .single
    private(set) var lastPreviewComparisonLayout: PreviewComparisonLayout = .leftRight
    func showPreviewComparison(_ layout: PreviewComparisonLayout) {
        comparesOriginal = false
        comparesCurrentSourceWithoutSettings = false
        if layout != .single { lastPreviewComparisonLayout = layout }
        previewComparisonLayout = layout
    }
    var editingRenderIntent: EditingRenderIntent { comparesOriginal ? .importedOriginal : comparesCurrentSourceWithoutSettings ? .currentSourceWithoutSettings : .currentEditing }
    @Published var showsDetail = false
    @Published var showsInspector = true
    @Published private(set) var isLoading = true
    @Published private(set) var isImporting = false
    @Published private(set) var importStatus = ""
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published private(set) var isReadOnly = false {
        didSet {
            jpegExportProtection.setUnavailable(isReadOnly)
            if oldValue != isReadOnly { advanceAISelectionGeneration() }
        }
    }
    @Published private(set) var isClosing = false {
        didSet { if oldValue != isClosing { advanceAISelectionGeneration() } }
    }
    private let catalogWorker = LibraryCatalogWorker()
    private var mutationTask: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    @Published private(set) var isUpdatingCatalog = false {
        didSet { if oldValue != isUpdatingCatalog { advanceAISelectionGeneration() } }
    }
    var synchronizeEditing: (@MainActor () async throws -> Void)?
    var prepareCatalogCleanup: (@MainActor () async throws -> Void)?
    var invalidateEditingSources: (@MainActor () -> Void)?
    let lifecycle: CatalogLifecycleGate?
    private let coordinatorLoader: (@Sendable () async throws -> any CatalogMutationCoordinating)?
    @Published private(set) var coordinationError: String?
    private var coordinationIDs = Set<UUID>()
    var hasCoordinatedRecovery: Bool { !coordinationIDs.isEmpty }
    @Published private(set) var isRetryingCoordination = false
    private let writer: CatalogWriter
    let jpegExportProtection: JPEGExportCatalogProtection
    var canExportJPEG: Bool { !isLoading && !isImporting && !isUpdatingCatalog && !isRetryingCoordination && !isClosing && !isReadOnly }
    @Published private(set) var metadataSearchState: PhotoMetadataSearchState = .loading(version: .initial)
    @Published private(set) var metadataGeneration: PhotoMetadataVersion = .initial
    @Published private(set) var metadataCatalogReference: MetadataCatalogFileReference = .absent
    @Published private(set) var metadataCatalogChanges: [MetadataCatalogChangeReceipt] = []
    @Published private(set) var metadataError: PhotoMetadataError?
    private let metadataStore: (any PhotoMetadataStoring)?
    private let metadataDirectory: URL
    private let metadataCatalogSessionID: UUID
    private var metadataUpdatesTask: Task<Void, Never>?
    private var metadataReceivedState: PhotoMetadataSearchState = .loading(version: .initial)
    private var metadataRetiredSessions: Set<UUID> = []
    private var metadataProjectionID = UUID()
    private var metadataWriterSequence: UInt64 = 0
    private var metadataCatalogError: PhotoMetadataError?
    private var metadataBlockedAssetIDs: Set<String> = []
    private var metadataProtectedSourceURLs: [URL] = [] {
        didSet { jpegExportProtection.updateProtectedSources(metadataProtectedSourceURLs) }
    }
    private var catalogSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var revision = 0
    private var catalogNeedsSave = false
    private var importTask: Task<Void, Never>?
    private var activeScopes: [UUID: URL] = [:]
    private struct AcceptedImport {
        let urls: [URL]
        let previousSelection: LibrarySelection?
        let admission: CatalogAcceptedWriteAdmission?
        let exportProtection: JPEGExportCatalogProtection.Admission
    }
    private var queuedImports: [AcceptedImport] = []
    private let folderScanner: @Sendable (LibraryFolder) async throws -> ScanResult
    private let now: () -> Date

    // A separate selection generation rejects A → B → A even when both assets
    // have identical settings. Catalog/refresh changes invalidate this too.
    private(set) var aiSelectionSessionID = UUID()
    private(set) var aiSelectionGeneration: UInt64 = 0

    @Published private(set) var isProjecting = false
    private let projectionWorker = LibraryProjectionWorker()
    private var deferredProjectionTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var projection: LibraryProjection?
    private var projectionRevision = 0
    // A canceled exit only restarts work that closing actually interrupted or
    // invalidated. A settled view remains immediately usable by AI snapshots.
    private var projectionNeedsResumption = false
    private var catalogGeneration = 0
    private var treeOverrides: [UUID: LibraryFolder] = [:]
    var gridColumnCount = 3

    init(repository: CatalogRepository = CatalogRepository(), now: @escaping () -> Date = Date.init,
         semanticSearch: (any SemanticSearchServing)? = nil,
         metadataStore: (any PhotoMetadataStoring)? = nil,
         lifecycle: CatalogLifecycleGate? = nil,
         coordinator: (@Sendable () async throws -> any CatalogMutationCoordinating)? = nil,
         editingDependencies: (@Sendable () async throws -> EditingModelDependencies)? = nil,
         catalogCleanup: CatalogWriter.Cleanup? = nil,
         folderScanner: @escaping @Sendable (LibraryFolder) async throws -> ScanResult = { try await FolderScanner().scan(folder: $0) }) {
        self.lifecycle = lifecycle; self.coordinatorLoader = coordinator
        let metadataSession = UUID()
        metadataCatalogSessionID = metadataSession
        self.metadataStore = metadataStore; metadataDirectory = repository.directory
        jpegExportProtection = JPEGExportCatalogProtection(repository: repository)
        writer = CatalogWriter(repository: repository, metadataStore: metadataStore, sessionID: metadataSession,
            lifecycle: lifecycle, coordinator: coordinator, editingDependencies: editingDependencies, cleanup: catalogCleanup)
        self.now = now; self.folderScanner = folderScanner
        self.semanticSearch = semanticSearch
        if let semanticSearch {
            semanticUpdatesTask = Task { [weak self] in
                for await state in await semanticSearch.updates() {
                    guard !Task.isCancelled, let self else { return }
                    self.applySemanticState(state)
                }
            }
        }
        if let metadataStore {
            metadataUpdatesTask = Task { [weak self] in
                for await state in await metadataStore.updates() {
                    guard !Task.isCancelled, let self else { return }
                    self.applyPhotoMetadataSearchState(state)
                }
            }
        }
        loadingTask = Task { await load() }
    }

    deinit {
        semanticUpdatesTask?.cancel(); semanticStatusTask?.cancel(); semanticOperationTask?.cancel()
        metadataUpdatesTask?.cancel()
        projectionTask?.cancel(); deferredProjectionTask?.cancel()
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
    /// Preserve display order when capturing a batch, independent of click order.
    var selectedAssets: [PhotoAsset] { visibleAssets.filter { selectedIDs.contains($0.id) } }
    var canModify: Bool { !isLoading && !isReadOnly && !isClosing && !isUpdatingCatalog }
    /// A pending relocation fences catalog writes, while unrelated editorial
    /// records remain editable. Resolution itself must remain reachable.
    var canModifyCatalog: Bool { canModify && !metadataCatalogChanges.contains { $0.state == .staged || $0.state == .conflicted } }
    var canResolvePhotoMetadataCatalogChanges: Bool { !isClosing && !isImporting && metadataStore != nil && (canModify || hasCoordinatedRecovery) }

    func photoMetadataSelectionContext(for assetID: String? = nil) -> PhotoMetadataSelectionContext? {
        let asset: PhotoAsset?
        if let assetID { asset = assetIndex(for: assetID).map { assets[$0] } }
        else { asset = selectedAsset }
        guard let asset else { return nil }
        return PhotoMetadataSelectionContext(assetID: asset.id,
            source: AIOriginalSourceFingerprint(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize),
            selectionSessionID: aiSelectionSessionID, selectionGeneration: aiSelectionGeneration,
            catalogSessionID: metadataCatalogSessionID, catalogGeneration: catalogGeneration,
            canModify: canModify && !metadataBlockedAssetIDs.contains(asset.id), isClosing: isClosing)
    }

    /// A synchronous value capture only. Native path/identity checks happen in
    /// the final background publisher, never while SwiftUI reads this value.
    func photoMetadataFileProtection() -> MetadataFileProtectionSnapshot {
        MetadataFileProtectionSnapshot(originalURLs: assets.map(\.fileURL) + metadataProtectedSourceURLs,
            managedFileURLs: ManagedFileProtection.managedFiles(in: metadataDirectory),
            managedDirectoryURLs: ManagedFileProtection.managedDirectories(in: metadataDirectory),
            managedDirectoryFamilies: ManagedFileProtection.managedFamilies(in: metadataDirectory).map {
                MetadataProtectedDirectoryFamily(parent: $0.parent, childNamePrefix: $0.childNamePrefix)
            })
    }

    func retryPhotoMetadataReconciliation() async throws {
        guard canResolvePhotoMetadataCatalogChanges else { throw isClosing ? PhotoMetadataError.closing : .catalogReadOnly }
        let exportProtection = jpegExportProtection.acceptCatalogChange()
        defer { withExtendedLifetime(exportProtection) {} }
        let accepted = try acceptedCatalogOperation { try await self.writer.retryMetadataReconciliation() }
        let id = UUID()
        catalogSaveTasks[id] = Task { _ = try? await accepted.value; catalogSaveTasks.removeValue(forKey: id) }
        do { applyPhotoMetadataCatalogResult(try await accepted.value) }
        catch { metadataError = (error as? PhotoMetadataError) ?? .storageFailure; throw error }
    }

    func resolvePhotoMetadataCatalogChange(_ operation: MetadataCatalogResolutionOperation, alreadyAccepted: Bool = false) async throws -> MetadataReconciliationResult {
        guard canResolvePhotoMetadataCatalogChanges else { throw isClosing ? PhotoMetadataError.closing : .catalogReadOnly }
        let exportProtection = jpegExportProtection.acceptCatalogChange()
        defer { withExtendedLifetime(exportProtection) {} }
        if coordinationIDs.contains(operation.changeID), let coordinatorLoader {
            isRetryingCoordination = true
            defer { isRetryingCoordination = false }
            let accepted = Task { () throws -> MetadataReconciliationResult in
                let coordinator = try await coordinatorLoader()
                let result = try await coordinator.resolveMetadataConflict(operation, coordinationID: operation.changeID)
                guard let metadata = result.metadata else { throw CatalogCoordinationError.recoveryRequired }
                _ = try await coordinator.recoverAndOpen()
                return metadata
            }
            let id = UUID()
            catalogSaveTasks[id] = Task { _ = try? await accepted.value; catalogSaveTasks.removeValue(forKey: id) }
            let result: MetadataReconciliationResult
            do { result = try await accepted.value }
            catch { await loadCoordinationInspection(); throw error }
            coordinationIDs.remove(operation.changeID); coordinationError = nil; isReadOnly = false; isLoading = true
            await load()
            return result
        }
        let accepted: Task<CatalogWriteMetadata, Error>
        if alreadyAccepted { accepted = Task { try await writer.resolve(operation) } }
        else { accepted = try acceptedCatalogOperation { try await self.writer.resolve(operation) } }
        let id = UUID()
        catalogSaveTasks[id] = Task { _ = try? await accepted.value; catalogSaveTasks.removeValue(forKey: id) }
        do {
            let value = try await accepted.value
            applyPhotoMetadataCatalogResult(value)
            guard let reconciliation = value.reconciliation else { throw value.error ?? .storageFailure }
            return reconciliation
        } catch { metadataError = (error as? PhotoMetadataError) ?? .storageFailure; throw error }
    }

    private var usablePhotoMetadataSnapshot: PhotoMetadataSearchSnapshot? {
        guard case .available(let snapshot) = metadataSearchState,
              snapshot.catalogReference == metadataCatalogReference else { return nil }
        return snapshot
    }

    private enum MetadataSearchIdentity: Equatable {
        case loading(PhotoMetadataVersion)
        case available(PhotoMetadataVersion, MetadataCatalogFileReference)
        case unavailable(PhotoMetadataVersion, PhotoMetadataError)
        init(_ state: PhotoMetadataSearchState) {
            switch state {
            case .loading(let version): self = .loading(version)
            case .available(let snapshot): self = .available(snapshot.version, snapshot.catalogReference)
            case .unavailable(let version, let reason): self = .unavailable(version, reason)
            }
        }
    }

    private func applyPhotoMetadataSearchState(_ state: PhotoMetadataSearchState) {
        guard !isClosing else { return }
        let previous = metadataReceivedState.version, next = state.version
        if next.sessionID == previous.sessionID {
            guard next.generation >= previous.generation else { return }
        } else {
            guard !metadataRetiredSessions.contains(next.sessionID) else { return }
            metadataRetiredSessions.insert(previous.sessionID)
        }
        metadataReceivedState = state
        refreshPhotoMetadataSearchState()
    }

    private func refreshPhotoMetadataSearchState() {
        let effective: PhotoMetadataSearchState
        if let error = metadataCatalogError {
            effective = .unavailable(version: metadataReceivedState.version, reason: error)
        } else if case .available(let snapshot) = metadataReceivedState, snapshot.catalogReference != metadataCatalogReference {
            // A saved catalog awaiting reconciliation must not borrow a complete
            // search claim from another catalog byte snapshot.
            effective = .loading(version: snapshot.version)
        } else { effective = metadataReceivedState }
        let changed = MetadataSearchIdentity(metadataSearchState) != MetadataSearchIdentity(effective)
        metadataSearchState = effective; metadataGeneration = effective.version
        if case .unavailable(_, let reason) = effective { metadataError = reason }
        else { metadataError = nil }
        if changed { metadataProjectionID = UUID(); scheduleProjection() }
    }

    private func applyPhotoMetadataCatalogResult(_ value: CatalogWriteMetadata) {
        guard value.sequence > metadataWriterSequence else { return }
        metadataWriterSequence = value.sequence
        metadataCatalogReference = value.reference; metadataCatalogChanges = value.changes
        metadataBlockedAssetIDs = value.blockedAssetIDs; metadataProtectedSourceURLs = value.protectedSourceURLs
        if value.reconciliation != nil || value.error != nil { metadataCatalogError = value.error }
        if let state = value.reconciliation?.searchState { applyPhotoMetadataSearchState(state) }
        refreshPhotoMetadataSearchState()
    }

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
        guard !isClosing else { projectionNeedsResumption = true; return }
        guard deferredProjectionTask == nil else { return }
        deferredProjectionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            deferredProjectionTask = nil
            scheduleProjection()
        }
    }

    private var projectionKey: LibraryProjectionKey {
        LibraryProjectionKey(selection: selection,
            query: (searchMode == .literal ? search : semanticLiteralFilter).trimmingCharacters(in: .whitespacesAndNewlines),
            sort: sort, minimumRating: minimumRating, searchMode: searchMode,
            semanticQuery: semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines), topK: semanticTopK,
            similarityReference: similarityReference)
    }

    private func scheduleProjection() {
        deferredProjectionTask?.cancel()
        deferredProjectionTask = nil
        projectionRevision += 1
        let number = projectionRevision
        projectionTask?.cancel()
        guard !isClosing else {
            projectionNeedsResumption = true
            isProjecting = false; projectionTask = nil
            return
        }
        projectionNeedsResumption = false
        isProjecting = true
        projectionTask = Task { [weak self] in
            // Coalesce synchronous UI changes before copying the catalog snapshot.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            let key = projectionKey, generation = catalogGeneration
            let metadataID = metadataProjectionID, metadata = usablePhotoMetadataSnapshot
            var candidates: LibraryProjectionCandidates?
            do {
                let current = try await projectionWorker.candidates(catalog, snapshotSessionID: semanticCatalogSessionID,
                    generation: generation, key: key, date: now(), overrides: treeOverrides, metadata: metadata)
                candidates = current
                try Task.checkCancellation()
                guard number == projectionRevision else { return }
                // Catalog invalidation is a lightweight actor snapshot update.
                // Ordinary typing never opens or scans the semantic index.
                if let semanticSearch {
                    await semanticSearch.updateCatalog(snapshotSessionID: semanticCatalogSessionID,
                        generation: generation, assets: catalog.assets)
                    try Task.checkCancellation()
                    guard number == projectionRevision else { return }
                }
                let result: LibraryProjection
                if key.usesSemanticRanking {
                    guard let semanticSearch else { throw SemanticEmbeddingError.unavailable(.modelNotInstalled) }
                    let scores: SemanticSearchResult
                    if let reference = key.similarityReference {
                        scores = try await semanticSearch.search(similarTo: reference, candidates: current.assets, topK: key.topK)
                    } else {
                        scores = try await semanticSearch.search(query: key.semanticQuery, candidates: current.assets, topK: key.topK)
                    }
                    try Task.checkCancellation()
                    guard number == projectionRevision,
                          (semanticState.indexGenerationID == nil || semanticState.indexGenerationID == scores.indexGenerationID),
                          (semanticState.modelDescriptor == nil || semanticState.modelDescriptor == scores.modelDescriptor) else {
                        throw SemanticEmbeddingError.installationChanged
                    }
                    result = try await projectionWorker.rank(current, result: scores, topK: key.topK)
                } else { result = current.base }
                try Task.checkCancellation()
                guard number == projectionRevision, generation == catalogGeneration, metadataID == metadataProjectionID else { return }
                if selection == .recent, now() < result.evaluatedAt || result.expiresAt.map({ self.now() >= $0 }) == true {
                    scheduleProjection(); return
                }
                projection = result
                semanticError = nil
                isProjecting = false
                projectionTask = nil
                reconcileSelection()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, !isClosing, number == projectionRevision else { return }
                if key.usesSemanticRanking, let candidates {
                    let empty = await projectionWorker.empty(candidates)
                    guard !Task.isCancelled, !isClosing, number == projectionRevision else { return }
                    projection = empty
                    if key.similarityReference != nil, (error as? SemanticEmbeddingError).map({ [.staleSource, .indexUnavailable, .superseded].contains($0) }) == true {
                        semanticError = "Für das Referenzfoto fehlt ein aktueller Vektor im aktiven Suchindex. Referenz gegebenenfalls erneut auswählen und den Suchindex einschließlich dieses Fotos ausdrücklich vorbereiten."
                    } else {
                        semanticError = (error as? SemanticEmbeddingError)?.localizedDescription ?? SemanticEmbeddingError.providerFailure.localizedDescription
                    }
                } else { errorMessage = error.localizedDescription }
                isProjecting = false
                projectionTask = nil
                reconcileSelection()
            }
        }
        refreshSemanticStatus()
    }

    var hasSemanticService: Bool { semanticSearch != nil }
    var canManageSemanticSearch: Bool { canModify && !isImporting && semanticSearch != nil }

    func findSimilarImages() {
        guard let reference = selectedAsset, hasSemanticService, !isClosing else { return }
        similarityReference = reference
        if searchMode == .literal { semanticLiteralFilter = search }
        searchMode = .semantic
        scheduleProjection()
    }

    func stopFindingSimilarImages() {
        similarityReference = nil
        searchMode = .literal
    }

    func useSemanticTextSearch() {
        similarityReference = nil
        searchMode = .semantic
    }

    var similarityScopeLabel: String {
        let scope: String
        switch selection {
        case .all: scope = "Gesamte Bibliothek"
        case .favorites: scope = "Favoriten"
        case .recent: scope = "Zuletzt hinzugefügt"
        case .folder(let id), .subfolder(let id, _):
            scope = catalog.folders.first { $0.id == id }?.name ?? "Gewählter Ordner"
        }
        let path: String
        if case .subfolder(_, let relativePath) = selection { path = " / \(relativePath)" } else { path = "" }
        let rating = minimumRating > 0 ? " · mindestens \(minimumRating) Sterne" : ""
        let literal = semanticLiteralFilter.isEmpty ? "" : " · wörtlich: \(semanticLiteralFilter)"
        return scope + path + rating + literal
    }

    private func semanticScopeKey(_ scope: SemanticScope) -> LibraryProjectionKey {
        if scope == .all { return LibraryProjectionKey(selection: .all, query: "", sort: sort, minimumRating: 0) }
        let key = projectionKey
        return LibraryProjectionKey(selection: key.selection, query: key.query, sort: key.sort, minimumRating: key.minimumRating)
    }

    private func applySemanticState(_ state: SemanticSearchState) {
        guard state.version >= semanticState.version, !isClosing else { return }
        let previous = semanticState
        semanticState = state
        if projectionKey.usesSemanticRanking,
           previous.indexGenerationID != state.indexGenerationID ||
           (previous.availability != .available && state.availability == .available) ||
           (previous.isIndexing && !state.isIndexing) {
            scheduleProjection()
        }
    }

    func refreshSemanticStatus() {
        let id = UUID(); semanticStatusID = id
        semanticStatusTask?.cancel()
        guard let semanticSearch, !isClosing,
              searchMode == .semantic || semanticControlsExpanded || semanticOperationLabel != nil || semanticState.isIndexing else { return }
        semanticScopeIsReady = false
        let key = semanticScopeKey(semanticScope), generation = catalogGeneration, snapshot = catalog
        let metadataID = metadataProjectionID, metadataSnapshot = usablePhotoMetadataSnapshot
        semanticStatusTask = Task { [weak self] in
            guard let self else { return }
            do {
                let scope = try await projectionWorker.candidates(snapshot, snapshotSessionID: semanticCatalogSessionID,
                    generation: generation, key: key, date: now(), overrides: treeOverrides, metadata: metadataSnapshot)
                try Task.checkCancellation()
                guard semanticStatusID == id, catalogGeneration == generation, metadataID == metadataProjectionID else { return }
                semanticScopeCount = scope.assets.count
                semanticScopeIsReady = true
                await semanticSearch.updateCatalog(snapshotSessionID: semanticCatalogSessionID, generation: generation, assets: snapshot.assets)
                try Task.checkCancellation()
                guard semanticStatusID == id else { return }
                let state = try await semanticSearch.status(scope: scope.assets)
                guard !Task.isCancelled, semanticStatusID == id, catalogGeneration == generation, metadataID == metadataProjectionID else { return }
                applySemanticState(state)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, !isClosing, semanticStatusID == id else { return }
                semanticError = (error as? SemanticEmbeddingError)?.localizedDescription ?? SemanticEmbeddingError.indexUnavailable.localizedDescription
            }
        }
    }

    func prepareSemanticIndex(rebuild: Bool = false) {
        runSemanticOperation(rebuild ? "Index wird neu aufgebaut" : "Index wird vorbereitet") { service, assets in
            try await service.prepareIndex(scope: assets, rebuild: rebuild)
        }
    }

    func deleteSemanticIndex() {
        runSemanticOperation("Index wird gelöscht") { service, _ in try await service.deleteIndex() }
    }

    func removeSemanticModel() {
        runSemanticOperation("Suchmodell wird entfernt") { service, _ in try await service.removeModel() }
    }

    func inspectSemanticModel(source: URL) {
        guard canManageSemanticSearch, semanticOperationTask == nil, let semanticSearch else { return }
        semanticImportReview = nil
        let id = UUID(); semanticOperationID = id
        semanticOperationLabel = "Modellpaket wird geprüft"
        semanticOperationTask = Task { [weak self] in
            do {
                let review = try await semanticSearch.inspectModel(source: source)
                try Task.checkCancellation()
                guard let self, self.semanticOperationID == id else { return }
                guard self.canManageSemanticSearch else { throw CancellationError() }
                self.semanticImportReview = review
                self.semanticOperationTask = nil; self.semanticOperationLabel = nil
            } catch { self?.finishSemanticOperation(id: id, error: error) }
        }
    }

    func dismissSemanticImport(id: UUID) {
        if semanticImportReview?.id == id { semanticImportReview = nil }
    }

    func installSemanticModel(reviewID: UUID) {
        guard let review = semanticImportReview, review.id == reviewID else { return }
        semanticImportReview = nil
        runSemanticOperation("Modell wird importiert") { service, _ in try await service.installModel(review) }
    }

    func cancelSemanticOperation() {
        semanticOperationTask?.cancel()
        semanticImportReview = nil
        if let semanticSearch { Task { await semanticSearch.cancelIndexing() } }
    }

    private func runSemanticOperation(_ label: String,
        operation: @escaping @Sendable (any SemanticSearchServing, [PhotoAsset]) async throws -> Void) {
        guard canManageSemanticSearch, semanticOperationTask == nil, let semanticSearch else { return }
        let id = UUID(); semanticOperationID = id
        let key = semanticScopeKey(semanticScope), scopeLabel = semanticScope.label
        let generation = catalogGeneration, snapshot = catalog
        let metadataID = metadataProjectionID, metadataSnapshot = usablePhotoMetadataSnapshot
        semanticError = nil; semanticOperationLabel = label
        semanticOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let scope = try await projectionWorker.candidates(snapshot, snapshotSessionID: semanticCatalogSessionID,
                    generation: generation, key: key, date: now(), overrides: treeOverrides, metadata: metadataSnapshot)
                try Task.checkCancellation()
                guard semanticOperationID == id, generation == catalogGeneration, metadataID == metadataProjectionID,
                      key == semanticScopeKey(semanticScope), canManageSemanticSearch else { throw CancellationError() }
                semanticActiveScopeLabel = "\(scopeLabel) · \(scope.assets.count) Bilder"
                await semanticSearch.updateCatalog(snapshotSessionID: semanticCatalogSessionID, generation: generation, assets: snapshot.assets)
                try Task.checkCancellation()
                guard semanticOperationID == id, generation == catalogGeneration, metadataID == metadataProjectionID, canManageSemanticSearch else { throw CancellationError() }
                try await operation(semanticSearch, scope.assets)
                finishSemanticOperation(id: id, error: nil)
                scheduleProjection()
            } catch { finishSemanticOperation(id: id, error: error) }
        }
    }

    private func finishSemanticOperation(id: UUID, error: Error?) {
        guard semanticOperationID == id else { return }
        semanticOperationTask = nil; semanticOperationLabel = nil
        if let error, !(error is CancellationError), (error as? SemanticEmbeddingError) != .cancelled,
           (error as? SemanticEmbeddingError) != .superseded {
            semanticError = (error as? SemanticEmbeddingError)?.localizedDescription ?? SemanticEmbeddingError.providerFailure.localizedDescription
        }
        refreshSemanticStatus()
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

    private func load() async {
        let exportProtection = jpegExportProtection.acceptCatalogChange()
        defer { withExtendedLifetime(exportProtection) {} }
        defer { loadingTask = nil; isLoading = false }
        do {
            if let lifecycle { startupAdmission = try await lifecycle.waitForStartup() }
            let admission = try registerCatalogWrite()
            try await withCatalogAdmission(admission) { try await self.loadAcceptedCatalog() }
        } catch {
            isReadOnly = true
            if coordinatorLoader != nil { invalidateEditingSources?(); coordinationError = error.localizedDescription; await loadCoordinationInspection() }
            errorMessage = "Der Katalog konnte nicht geöffnet werden. Die vorhandene Datei bleibt unverändert.\n\n\(error.localizedDescription)"
        }
    }

    private func loadAcceptedCatalog() async throws {
        try await prepareCatalogCleanup?()
        let loaded = try await writer.load()
        if loaded.editingRemapped || loaded.metadata.editingPruned { try await synchronizeEditing?() }
        activeScopes = loaded.scopes
        // Persist refreshed bookmark/tree metadata under the same admission as
        // loading. No later Task may lose the initial relocation's protection.
        let hasPendingRelocation = loaded.metadata.changes.contains { $0.state == .staged || $0.state == .conflicted }
        if loaded.updated && !hasPendingRelocation { applyPhotoMetadataCatalogResult(try await saveAcceptedCatalog(loaded.catalog)) }
        else { applyPhotoMetadataCatalogResult(loaded.metadata) }
        catalog = loaded.catalog; catalogNeedsSave = false
        reportCleanupFailure(loaded.metadata)
        await waitForProjection()
        reconcileSelection()
    }

    func chooseFolders() {
        guard canModifyCatalog, !isImporting else { return }
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
        guard canModifyCatalog, !isImporting, !urls.isEmpty else { return }
        do {
            let exportProtection = jpegExportProtection.acceptCatalogChange()
            let admission = try registerCatalogWrite()
            startImport(AcceptedImport(urls: urls, previousSelection: previousSelection, admission: admission,
                                      exportProtection: exportProtection))
        } catch { errorMessage = error.localizedDescription }
    }

    private func startImport(_ accepted: AcceptedImport) {
        advanceAISelectionGeneration()
        isImporting = true
        notice = nil
        importTask = Task {
            defer {
                withExtendedLifetime(accepted.exportProtection) {}
                isImporting = false; importStatus = ""; importTask = nil
                if Task.isCancelled { queuedImports = [] }
                else if !queuedImports.isEmpty {
                    // Already accepted while the first scan was active. Keep
                    // that exact registration even if maintenance is now waiting.
                    let next = queuedImports.removeFirst()
                    startImport(next)
                }
            }
            do {
                try await withCatalogAdmission(accepted.admission) { await self.importAcceptedFolders(accepted) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func importAcceptedFolders(_ accepted: AcceptedImport) async {
        var total = 0, skipped = 0
        var failures: [String] = []
        for (offset, originalURL) in accepted.urls.enumerated() {
            if Task.isCancelled { break }
            importStatus = "\(offset + 1)/\(accepted.urls.count) · \(originalURL.lastPathComponent) wird eingelesen …"
            let prepared = await catalogWorker.prepareImport(originalURL, folders: folders)
            let folder = prepared.folder, started = prepared.startedScope, url = folder.url
            do {
                let result = try await folderScanner(folder)
                try Task.checkCancellation()
                // Dependent overlapping folders commit in input order; the
                // existing scanner owns the bounded parallel metadata reads.
                while true {
                    let generation = catalogGeneration
                    let merged = try await catalogWorker.merge(result, folder: folder, into: catalog)
                    try Task.checkCancellation()
                    // Accepted ratings during the scan/merge must survive.
                    guard generation == catalogGeneration else { continue }
                    try await publishImportedCatalog(merged.catalog)
                    total += merged.addedCount
                    break
                }
                skipped += result.skippedFiles
                if started {
                    if activeScopes[folder.id] == nil { activeScopes[folder.id] = originalURL }
                    else { originalURL.stopAccessingSecurityScopedResource() }
                }
                if accepted.previousSelection == nil {
                    selection = .folder(folder.id); search = ""; minimumRating = 0
                }
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

    private func publishImportedCatalog(_ next: LibraryCatalog) async throws {
        // Block only this dependent commit, not the scan. On a failed save no
        // new original reference is published solely in the UI and then hidden
        // from a backup rotation's final persisted-catalog protection check.
        isUpdatingCatalog = true
        defer { isUpdatingCatalog = false }
        let value = try await saveAcceptedCatalog(next)
        catalog = next; catalogNeedsSave = false
        applyPhotoMetadataCatalogResult(value)
    }

    func enqueueFolders(_ urls: [URL]) {
        guard canModifyCatalog else { return }
        if isImporting {
            let queuedURLs = Set(queuedImports.flatMap(\.urls))
            let unique = urls.filter { !queuedURLs.contains($0) }
            guard !unique.isEmpty else { return }
            do {
                let exportProtection = jpegExportProtection.acceptCatalogChange()
                let admission = try registerCatalogWrite()
                queuedImports.append(AcceptedImport(urls: unique, previousSelection: nil, admission: admission,
                                                    exportProtection: exportProtection))
            } catch { errorMessage = error.localizedDescription }
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
        guard canModifyCatalog, !isImporting else { return }
        do {
            let admission = try registerCatalogWrite()
            let snapshot = catalog
            isUpdatingCatalog = true
            mutationTask = Task {
                defer { isUpdatingCatalog = false; mutationTask = nil }
                do {
                    try await withCatalogAdmission(admission) {
                        let next = await self.catalogWorker.removing(id, from: snapshot)
                        let value = try await self.saveAcceptedCatalog(next)
                        self.catalog = next; self.catalogNeedsSave = false
                        self.applyPhotoMetadataCatalogResult(value)
                        self.activeScopes.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
                        switch self.selection {
                        case .folder(let selectedFolder), .subfolder(let selectedFolder, _):
                            if selectedFolder == id { self.selection = .all }
                        default: break
                        }
                        self.notice = value.cleanupError == nil
                            ? "Ordner und zugehörige Daten aus der Bibliothek entfernt. Originaldateien bleiben erhalten."
                            : "Ordner entfernt. Die Datenbereinigung muss erneut ausgeführt werden."
                    }
                } catch { errorMessage = "Änderungen konnten nicht gespeichert werden.\n\n" + error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func assetIndex(for id: String?) -> Int? {
        guard let id else { return nil }
        if let index = projection?.indices[id], assets.indices.contains(index), assets[index].id == id { return index }
        return assets.firstIndex { $0.id == id }
    }

    func setRating(_ rating: Int, for id: String? = nil) {
        guard canModifyCatalog, let index = assetIndex(for: id ?? selectedID) else { return }
        do {
            let admission = try registerCatalogWrite()
            catalogNeedsSave = true
            catalog.assets[index].rating = min(5, max(0, rating))
            persist(admission: admission)
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleFavorite(_ id: String? = nil) {
        guard canModifyCatalog, let index = assetIndex(for: id ?? selectedID) else { return }
        do {
            let admission = try registerCatalogWrite()
            catalogNeedsSave = true
            catalog.assets[index].isFavorite.toggle()
            persist(admission: admission)
        } catch { errorMessage = error.localizedDescription }
    }

    func contains(_ asset: PhotoAsset, in folder: LibraryFolder) -> Bool {
        // Path I/O belongs to the sole projection worker. While loading, no
        // membership is published until that catalog's comparison map is ready.
        guard let projection, projection.treeFolders[folder.id] == folder,
              let path = projection.comparisonPaths[asset.fileURL],
              let folderPath = projection.comparisonPaths[folder.url] else { return false }
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return path.hasPrefix(prefix)
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
    func select(_ asset: PhotoAsset, extending: Bool = false, toggling: Bool = false) {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        let visible = visibleAssets
        guard let target = visible.firstIndex(where: { $0.id == asset.id }) else { return }
        if extending {
            let anchor = selectionAnchorID ?? selectedID ?? asset.id
            let start = visible.firstIndex { $0.id == anchor } ?? target
            let range = Set(visible[min(start, target)...max(start, target)].map(\.id))
            applySelection(toggling ? selectedIDs.union(range) : range, activeID: asset.id)
            selectionAnchorID = visible[start].id
        } else if toggling {
            var ids = selectedIDs
            if !ids.insert(asset.id).inserted { ids.remove(asset.id) }
            let active = ids.contains(asset.id) ? asset.id :
                (selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? visible.first { ids.contains($0.id) }?.id)
            applySelection(ids, activeID: active)
            selectionAnchorID = asset.id
        } else {
            applySelection([asset.id], activeID: asset.id)
            selectionAnchorID = asset.id
        }
    }
    func selectAll() {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        let visible = visibleAssets
        let ids = Set(visible.map(\.id))
        let active = selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? visible.first?.id
        applySelection(ids, activeID: active)
        selectionAnchorID = active
    }
    private func applySelection(_ ids: Set<String>, activeID: String?) {
        // Selection is short UI bookkeeping with shared focus/anchor state.
        // Keep it ordered on MainActor instead of starting background workers.
        isApplyingSelection = true
        selectedIDs = ids
        selectedID = activeID
        isApplyingSelection = false
        emptySelectionKey = ids.isEmpty ? projection?.key : nil
        if activeID == nil { showsDetail = false }
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
        let visibleIDs = Set(visible.map(\.id))
        var ids = selectedIDs.intersection(visibleIDs)
        let deliberatelyEmpty = selectedIDs.isEmpty && emptySelectionKey == projection?.key
        let clearedKey = emptySelectionKey
        if ids.isEmpty, !deliberatelyEmpty, let first = visible.first { ids.insert(first.id) }
        let active = selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? visible.first { ids.contains($0.id) }?.id
        applySelection(ids, activeID: active)
        emptySelectionKey = deliberatelyEmpty ? clearedKey : nil
        if selectionAnchorID.map({ !visibleIDs.contains($0) }) ?? true { selectionAnchorID = active }
        if active == nil { showsDetail = false }
    }
    func navigate(_ delta: Int, extending: Bool = false) {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        let visible = visibleAssets
        guard !visible.isEmpty else { return }
        let target: Int
        if let index = visible.firstIndex(where: { $0.id == selectedID }) {
            target = min(visible.count - 1, max(0, index + delta))
        } else { target = 0 }
        select(visible[target], extending: extending)
    }
    func reveal(_ asset: PhotoAsset? = nil) {
        if let asset = asset ?? selectedAsset { NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL]) }
    }

    private func saveAcceptedCatalog(_ snapshot: LibraryCatalog) async throws -> CatalogWriteMetadata {
        let membershipChanged = Set(snapshot.assets.map(\.id)) != Set(catalog.assets.map(\.id))
        if membershipChanged {
            // Previously accepted catalog/metadata/edit writes finish before
            // identity deletion. UI admission is closed by isUpdatingCatalog;
            // queued imports keep their existing serial input order.
            while !catalogSaveTasks.isEmpty {
                for task in Array(catalogSaveTasks.values) { await task.value }
            }
            try await prepareCatalogCleanup?()
        }
        revision += 1
        var value: CatalogWriteMetadata
        do { value = try await writer.save(snapshot, revision: revision) }
        catch {
            // A pre-import cleanup may already have committed another store's
            // epoch before a later participant failed. Never reuse that local
            // baseline for another edit or import until startup reconciliation.
            if membershipChanged { isReadOnly = true }
            throw error
        }
        if value.editingPruned {
            do { try await synchronizeEditing?() }
            catch { value.cleanupError = error.localizedDescription }
        }
        reportCleanupFailure(value)
        if catalog == snapshot { catalogNeedsSave = false }
        return value
    }

    private func reportCleanupFailure(_ value: CatalogWriteMetadata) {
        guard let error = value.cleanupError else { return }
        isReadOnly = true
        errorMessage = "Die Katalogdaten konnten noch nicht vollständig bereinigt werden. Weitere Änderungen sind gesperrt; beim nächsten Start wird die Bereinigung wiederholt.\n\n" + error
    }

    /// Restoring a backup may contain images removed since that backup. Apply
    /// current membership before exposing the restored state as editable.
    func reconcileAfterEditingRestore() async throws {
        guard !isUpdatingCatalog, !isImporting else { throw CatalogLifecycleError.maintenanceAlreadyPending }
        isUpdatingCatalog = true
        defer { isUpdatingCatalog = false }
        let admission = try registerCatalogWrite()
        try await withCatalogAdmission(admission) {
            let value = try await self.writer.cleanupCurrentCatalog()
            self.reportCleanupFailure(value)
            if value.cleanupError != nil { throw ArtifactContractError.staleSnapshot }
            if value.editingPruned { try await self.synchronizeEditing?() }
        }
    }

    private func persist(admission: CatalogAcceptedWriteAdmission?) {
        revision += 1
        let snapshot = catalog, number = revision, id = UUID()
        // Registration happened synchronously BEFORE the caller changed local
        // state. Keep it alive until this exact background publication returns.
        catalogSaveTasks[id] = Task {
            defer { catalogSaveTasks.removeValue(forKey: id) }
            do {
                let value = try await withCatalogAdmission(admission) { try await self.writer.save(snapshot, revision: number) }
                if catalog == snapshot { catalogNeedsSave = false }
                applyPhotoMetadataCatalogResult(value)
            } catch { errorMessage = "Änderungen konnten nicht gespeichert werden.\n\n" + error.localizedDescription }
        }
    }

    private func withCatalogAdmission<T: Sendable>(_ admission: CatalogAcceptedWriteAdmission?,
        operation: @MainActor @Sendable () async throws -> T) async throws -> T {
        if let lifecycle, let admission { return try await lifecycle.withAcceptedWrite(admission) { try await operation() } }
        return try await operation()
    }

    private func acceptedCatalogOperation<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> T) throws -> Task<T, Error> {
        let admission = try registerCatalogWrite()
        return Task { try await withCatalogAdmission(admission, operation: operation) }
    }

    func inspectCoordinatedMetadataConflict(coordinationID: UUID, conflictID: UUID) async throws -> CatalogMetadataConflictRecords {
        guard coordinationIDs.contains(coordinationID), let coordinatorLoader else { throw CatalogCoordinationError.invalidCapability }
        return try await (try await coordinatorLoader()).inspectMetadataConflict(coordinationID: coordinationID, conflictID: conflictID)
    }
    private func loadCoordinationInspection() async {
        guard let coordinatorLoader else { return }
        do {
            let coordinator = try await coordinatorLoader()
            let pending = try await coordinator.pending().filter { $0.value.disposition == .active }
            coordinationIDs = Set(pending.map { $0.value.body.operationID })
            let current = try await writer.recoveryCatalog()
            catalog = current.catalog; metadataCatalogReference = current.reference
            var receipts: [MetadataCatalogChangeReceipt] = []
            if let metadata = metadataStore as? any CoordinatedPhotoMetadataStoring {
                for journal in pending {
                    if let participant = journal.value.body.requiredParticipants.first(where: { $0.store.kind == .photoMetadata }),
                       let value = try await metadata.inspectCatalogChange(id: journal.value.body.operationID,
                           expectedRequestSHA256: participant.requestSHA256.sha256) { receipts.append(value.receipt) }
                }
            }
            metadataCatalogChanges = receipts
            metadataBlockedAssetIDs = Set(receipts.flatMap(\.blockedAssetIDs))
            metadataProtectedSourceURLs = receipts.flatMap(\.protectedSourceURLs)
            await waitForProjection()
        } catch { coordinationError = error.localizedDescription }
    }

    private var startupAdmission: CatalogStartupAdmission?
    private func registerCatalogWrite() throws -> CatalogAcceptedWriteAdmission? {
        guard let lifecycle else { return nil }
        guard let startupAdmission else { throw CatalogLifecycleError.recoveryRequired }
        return try lifecycle.registerAcceptedWrite(domain: .catalog, session: startupAdmission)
    }
    func retryCoordinatedRecovery() {
        guard !isClosing, !isRetryingCoordination, let coordinatorLoader else { return }
        let exportProtection = jpegExportProtection.acceptCatalogChange()
        isRetryingCoordination = true
        recoveryTask = Task {
            defer { withExtendedLifetime(exportProtection) {} }
            defer { isRetryingCoordination = false; recoveryTask = nil }
            do {
                let coordinator = try await coordinatorLoader()
                _ = try await coordinator.recoverAndOpen()
                isReadOnly = false; coordinationError = nil; isLoading = true
                await load()
            } catch { coordinationError = error.localizedDescription; await loadCoordinationInspection() }
        }
    }

    private func advanceAISelectionGeneration() {
        if aiSelectionGeneration == .max {
            aiSelectionSessionID = UUID()
            aiSelectionGeneration = 0
        } else {
            aiSelectionGeneration += 1
        }
    }

    func beginTermination() {
        projectionNeedsResumption = projectionNeedsResumption || projectionTask != nil || deferredProjectionTask != nil
        isClosing = true; importTask?.cancel(); queuedImports = []
        projectionTask?.cancel(); projectionTask = nil; isProjecting = false
        deferredProjectionTask?.cancel(); deferredProjectionTask = nil
        semanticStatusTask?.cancel(); semanticOperationTask?.cancel(); semanticImportReview = nil
        if let semanticSearch { semanticShutdownTask = Task { await semanticSearch.shutdown() } }
    }
    func cancelTermination() {
        isClosing = false
        if projectionNeedsResumption { scheduleProjection() }
        else { refreshSemanticStatus() }
        if let metadataStore { Task { applyPhotoMetadataSearchState(await metadataStore.searchState()) } }
    }

    func drainAcceptedCatalogOperations() async {
        // Initial bookmark loading can own an accepted joint relocation. A quit
        // observes its actual completion rather than cancelling or skipping it.
        if let loadingTask { await loadingTask.value }
        if let recoveryTask { await recoveryTask.value }
        if let semanticShutdownTask { await semanticShutdownTask.value }
        importTask?.cancel()
        if let importTask { await importTask.value }
        if let mutationTask { await mutationTask.value }
        while !catalogSaveTasks.isEmpty {
            let tasks = Array(catalogSaveTasks.values)
            for task in tasks { await task.value }
        }
    }

    func finishSaving() async -> Bool {
        await drainAcceptedCatalogOperations()
        guard !isLoading && !isReadOnly, catalogNeedsSave else { return true }
        do {
            let admission = try registerCatalogWrite()
            try await withCatalogAdmission(admission) { self.applyPhotoMetadataCatalogResult(try await self.saveAcceptedCatalog(self.catalog)) }
            return true
        }
        catch { errorMessage = "Der Katalog konnte nicht gespeichert werden: \(error.localizedDescription)"; return false }
    }
}
