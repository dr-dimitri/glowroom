import AppKit
import Combine
import Darwin
import Foundation
import GlowroomCore

struct EditingModelDependencies: Sendable {
    let database: any EditingPersistence
    let artifacts: (any GeneratedArtifactStoring)?
    let gate: CatalogLifecycleGate?
    let resources: (any ArtifactResourceAdmitting)?
    let recoverDatabase: (@Sendable (URL) async throws -> EditingStoreState)?
    let artifactStoreError: String?
    init(database: any EditingPersistence, artifacts: (any GeneratedArtifactStoring)? = nil, gate: CatalogLifecycleGate? = nil, resources: (any ArtifactResourceAdmitting)? = nil, artifactStoreError: String? = nil, recoverDatabase: (@Sendable (URL) async throws -> EditingStoreState)? = nil) {
        self.database = database; self.artifacts = artifacts; self.gate = gate; self.resources = resources
        self.recoverDatabase = recoverDatabase; self.artifactStoreError = artifactStoreError
    }
}

/// Immutable key for the one expanded variants view task. Selection epochs
/// also distinguish A -> B -> A before an old SQL observer returns.
struct ArtifactVariantsLoadIdentity: Hashable {
    let assetID: String
    let expanded: Bool
    let generation: UUID
    let storeEpoch: UUID?
    let selectionSessionID: UUID?
    let selectionGeneration: UInt64?
    let isReady: Bool
}

@MainActor
final class EditingModel: ObservableObject, GeneratedArtifactAccepting {
    @Published private(set) var snapshotsByAsset: [String: EditingSnapshot] = [:]
    @Published private(set) var artifactFingerprints: [GeneratedArtifactID: ArtifactSourceFingerprint] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var isCommitting = false { didSet { if oldValue != isCommitting { advanceAIEditGeneration() } } }
    @Published private(set) var isRestoring = false
    @Published private(set) var isBackingUp = false { didSet { if oldValue != isBackingUp { advanceAIEditGeneration() } } }
    @Published private(set) var isReadOnly = false { didSet { if oldValue != isReadOnly { advanceAIEditGeneration() } } }
    @Published private(set) var isClosing = false { didSet { if oldValue != isClosing { advanceAIEditGeneration() } } }
    @Published private(set) var hasPendingChanges = false
    @Published private(set) var variants: [EditingVariant] = []
    @Published private(set) var isLoadingVariants = false
    @Published private(set) var variantsReloadID = UUID()
    private var variantsAssetID: String?
    private var variantLoadID = UUID()
    private var completedCommitIDs: [EditingCommitID] = []
    @Published var errorMessage: String?
    @Published var notice: String?
    var settingsByAsset: [String: EditSettings] { snapshotsByAsset.mapValues(\.settings) }

    private struct PendingEdit {
        let snapshot: EditingSnapshot
        let revision: Int64
        let admission: CatalogAcceptedWriteAdmission?
    }
    private final class Commit {
        let id: EditingCommitID
        let draft: ArtifactDraft
        let token: GenerationSnapshotToken
        var request: GenerationCommitRequest?
        var observer: AcceptedArtifactCommit?
        var task: Task<ArtifactCommitReceipt, Error>?
        var published = false
        var failed = false
        init(id: EditingCommitID, draft: ArtifactDraft, token: GenerationSnapshotToken) {
            self.id = id; self.draft = draft; self.token = token
        }
    }
    private var database: (any EditingPersistence)?
    private var recoverDatabase: (@Sendable (URL) async throws -> EditingStoreState)?
    private var artifactStoreWarning: String?
    private var artifacts: (any GeneratedArtifactStoring)?
    private var artifactStoreID: ArtifactStoreID?
    private var gate: CatalogLifecycleGate?
    private var startup: CatalogStartupAdmission?
    private let directory: URL?
    private let repositoryLoader: @Sendable () async throws -> EditingModelDependencies
    private var baselines: [String: EditingExpectedState] = [:]
    private var storeEpoch: UUID?
    private var sourceStateIsCoherent = true
    private var startupAllowsOriginalPreview = false
    private var revisionsByAsset: [String: Int64] = [:]
    private var pending: [String: PendingEdit] = [:]
    let sliderPersistenceSession = SliderPersistenceSession()
    private var histories = BoundedEditingHistory<EditingSnapshot>(footprint: EditingHistoryFootprint.snapshot)
    var historyStateCount: Int { histories.count }
    var historyByteCount: Int { histories.byteCount }
    private var leases: [GeneratedArtifactID: ArtifactLease] = [:]
    private var commits: [EditingCommitID: Commit] = [:]
    private var activeCommitID: EditingCommitID?
    private var loadingTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var automaticBackupTask: Task<Void, Never>?
    private var automaticBackupDay: Date?
    private var automaticBackupWarning: String?
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    private let retainedCommitLimit = 100
    private var editingFunctions: [String: EditingFunction] = [:]
    weak var library: LibraryModel?
    private(set) var aiEditSessionID = UUID()
    private(set) var aiEditGeneration: UInt64 = 0

    var semanticProtectedURLs: [URL] {
        guard let directory else { return [] }
        return ["semantic-index.sqlite", "semantic-index.sqlite-journal", "semantic-index.sqlite-wal", "semantic-index.sqlite-shm"]
            .map { directory.appendingPathComponent($0) } + [directory.appendingPathComponent("SemanticModels", isDirectory: true)]
    }
    var semanticProtectedDirectoryFamilies: [ManagedDirectoryFamily] {
        guard let directory else { return [] }
        return [ManagedDirectoryFamily(parent: directory, childNamePrefix: "semantic-index-quarantine-")]
    }
    var cloudProtectedURLs: [URL] {
        guard let directory else { return [] }
        return ["cloud-usage.sqlite", "cloud-usage.sqlite-journal", "cloud-usage.sqlite-wal", "cloud-usage.sqlite-shm"].map { directory.appendingPathComponent($0) }
    }
    var canEdit: Bool { !isLoading && !isReadOnly && !isRestoring && !isBackingUp && !isClosing && !isCommitting && !commits.values.contains(where: \.failed) && library?.isUpdatingCatalog != true && library?.isLoading != true && library?.isReadOnly != true }
    /// An unavailable store must not hide healthy imported originals. This is
    /// display-only and requires a successful shared startup recovery barrier;
    /// a failed/active catalog coordination never authorizes this fallback.
    var showsImportedOriginalFallback: Bool {
        !isLoading && isReadOnly && storeEpoch == nil && sourceStateIsCoherent && startupAllowsOriginalPreview
    }
    private var catalogAllowsEditingMaintenance: Bool {
        library?.isLoading != true && library?.isUpdatingCatalog != true && library?.isImporting != true
    }
    var canBackUp: Bool { !isLoading && !isRestoring && !isBackingUp && !isClosing && !isCommitting && database != nil && storeEpoch != nil && catalogAllowsEditingMaintenance }
    var canRestore: Bool { !isLoading && !isRestoring && !isBackingUp && !isClosing && !isCommitting && database != nil && (storeEpoch != nil || recoverDatabase != nil) && catalogAllowsEditingMaintenance }
    func beginTermination() { isClosing = true }
    func cancelTermination() { isClosing = false }

    convenience init(directory: URL) {
        let bootstrap = ArtifactAppBootstrap(directory: directory)
        self.init(directory: directory, loader: { try await bootstrap.editingDependencies() })
    }
    init(directory: URL? = nil, loader: @escaping @Sendable () async throws -> EditingModelDependencies) {
        self.directory = directory; self.repositoryLoader = loader
        sliderPersistenceSession.onIdle = { [weak self] in self?.scheduleSave(immediately: true) }
        startLoading()
    }
    private func startLoading() {
        let loader = repositoryLoader
        startupAllowsOriginalPreview = false
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dependencies = try await loader()
                database = dependencies.database; artifacts = dependencies.artifacts; gate = dependencies.gate
                recoverDatabase = dependencies.recoverDatabase
                artifactStoreWarning = dependencies.artifactStoreError.map { "Die Ablage generierter Bilder ist nicht verfügbar. Bearbeitungen importierter Originale bleiben möglich.\n\n" + $0 }
                if let gate { startup = try await gate.waitForStartup() }
                startupAllowsOriginalPreview = true
                if let artifacts { artifactStoreID = await artifacts.storeID; if let resources = dependencies.resources { await ArtifactPreviewAccess.shared.register(artifacts, resources: resources) } }
                let state = try await dependencies.database.loadState()
                install(state)
                sourceStateIsCoherent = true
                try await loadArtifactMetadata(state)
                isReadOnly = false; errorMessage = artifactStoreWarning
                isLoading = false; loadingTask = nil
            } catch { finishLoadingWithError(error) }
        }
    }
    convenience init(database: any EditingPersistence) { self.init(loader: { EditingModelDependencies(database: database) }) }
    func invalidateSourcesForCoordination() {
        sourceStateIsCoherent = false; isReadOnly = true
        aiEditSessionID = UUID(); aiEditGeneration = 0
    }
    func reloadAfterCatalogChange() async throws {
        sourceStateIsCoherent = false
        if let loadingTask { await loadingTask.value }
        guard pending.isEmpty, !isCommitting, let database else {
            isReadOnly = true
            errorMessage = "Die Katalogzuordnung wurde geändert. Ungesicherte lokale Bearbeitungen bleiben erhalten; die Bildquelle kann noch nicht freigegeben werden."
            throw ArtifactContractError.staleSnapshot
        }
        aiEditSessionID = UUID(); aiEditGeneration = 0; isLoading = true
        defer { isLoading = false }
        do {
            let state = try await database.loadState()
            install(state); try await loadArtifactMetadata(state)
            histories.removeAll(); sourceStateIsCoherent = true; isReadOnly = false
        } catch { isReadOnly = true; errorMessage = error.localizedDescription; throw error }
    }
    func retryLoading() {
        guard !isLoading, !isSaving, !isCommitting, pending.isEmpty else { return }
        isLoading = true; startLoading()
    }
    deinit { debounceTask?.cancel() }

    func snapshot(for assetID: String) -> EditingSnapshot { snapshotsByAsset[assetID] ?? (try! EditingSnapshot()) }
    func settings(for assetID: String) -> EditSettings { snapshot(for: assetID).settings }
    func persistedState(for assetID: String) -> EditingExpectedState? {
        if let value = baselines[assetID] { return value }
        guard let storeEpoch else { return nil }
        return try? EditingExpectedState(storeEpoch: storeEpoch, revision: nil, snapshot: nil)
    }
    func localRevision(for assetID: String) -> Int64 { revisionsByAsset[assetID] ?? 0 }
    func resolvedSource(for asset: PhotoAsset, intent: EditingRenderIntent = .currentEditing) throws -> ResolvedEditingSource {
        if intent != .importedOriginal, storeEpoch == nil || !sourceStateIsCoherent {
            guard showsImportedOriginalFallback else { throw ArtifactContractError.invalidCapability }
            return try EditingSourceResolver.resolve(asset: asset, snapshot: try EditingSnapshot(), intent: .importedOriginal, artifacts: [:])
        }
        return try EditingSourceResolver.resolve(asset: asset, snapshot: snapshot(for: asset.id), intent: intent, artifacts: artifactFingerprints)
    }
    func sourceDimensions(for asset: PhotoAsset) -> String {
        if case .artifact(let id) = snapshot(for: asset.id).source, let value = artifactFingerprints[id] {
            return "\(value.raster.format.size.width) × \(value.raster.format.size.height) · PNG"
        }
        return "\(asset.pixelWidth) × \(asset.pixelHeight)"
    }
    func sourceFormat(for asset: PhotoAsset) -> String { snapshot(for: asset.id).source == .original ? asset.format.uppercased() : "PNG" }
    func variantsLoadIdentity(assetID: String, expanded: Bool) -> ArtifactVariantsLoadIdentity {
        ArtifactVariantsLoadIdentity(assetID: assetID, expanded: expanded, generation: variantsReloadID,
            storeEpoch: storeEpoch, selectionSessionID: library?.aiSelectionSessionID,
            selectionGeneration: library?.aiSelectionGeneration,
            isReady: database != nil && storeEpoch != nil && !isLoading && !isRestoring && !isClosing
                && library?.selectedID == assetID)
    }
    func loadVariants(_ identity: ArtifactVariantsLoadIdentity) async {
        guard identity.expanded, identity.isReady, !Task.isCancelled,
              identity == variantsLoadIdentity(assetID: identity.assetID, expanded: true), let database else { return }
        // A replaced/cancelled observer must not prevent the new asset/epoch
        // from loading. The repository keeps actual SQL work bounded/ordered.
        let id = UUID(); variantLoadID = id; variantsAssetID = identity.assetID; variants = []; isLoadingVariants = true
        defer { if variantLoadID == id { isLoadingVariants = false } }
        do {
            let loaded = try await database.variants(for: identity.assetID)
            guard !Task.isCancelled, variantLoadID == id,
                  identity == variantsLoadIdentity(assetID: identity.assetID, expanded: true) else { return }
            variants = loaded
        } catch {
            guard !Task.isCancelled, variantLoadID == id,
                  identity == variantsLoadIdentity(assetID: identity.assetID, expanded: true) else { return }
            errorMessage = error.localizedDescription
        }
    }
    private func invalidateVariants() {
        variantLoadID = UUID(); variantsReloadID = UUID()
        variants = []; variantsAssetID = nil; isLoadingVariants = false
    }
    func selectVariant(_ variant: EditingVariant) async {
        guard canEdit, variantsAssetID == variant.assetID, variants.contains(where: { $0.id == variant.id }),
              let library, library.selectedID == variant.assetID else { return }
        selectEditingFunction(.versions, assetID: variant.assetID)
        guard let expected = aiSnapshot(in: library), expected.assetID == variant.assetID else { return }
        do {
            if case .artifact(let id) = variant.snapshot.source {
                guard let artifacts, let storeID = artifactStoreID else { throw ArtifactContractError.missingArtifact }
                let descriptor = try await artifacts.descriptor(id)
                let lease = try await artifacts.acquireLease(ids: [id], purpose: .activeEditing)
                guard aiSnapshot(in: library) == expected else { return }
                artifactFingerprints[id] = .init(storeID: storeID, artifactID: id, manifestSHA256: descriptor.manifestSHA256, raster: descriptor.raster)
                leases[id] = lease
            }
            guard aiSnapshot(in: library) == expected else { return }
            let revision = localRevision(for: variant.assetID)
            endEditing(assetID: variant.assetID); setSnapshot(variant.snapshot, for: variant.assetID)
            if localRevision(for: variant.assetID) != revision { library.comparesOriginal = false; library.comparesCurrentSourceWithoutSettings = false }
        } catch { errorMessage = error.localizedDescription }
    }
    func setSettings(_ settings: EditSettings, for assetID: String) {
        guard let next = try? EditingSnapshot(source: snapshot(for: assetID).source, settings: settings.normalized) else { return }
        setSnapshot(next, for: assetID)
    }
    private func setSnapshot(_ value: EditingSnapshot, for assetID: String) {
        guard canEdit, !assetID.isEmpty, value != snapshot(for: assetID), nextRevisionAvailable(for: assetID) else { return }
        do {
            let admission = try registerWrite()
            histories.clearRedo(assetID)
            if histories.group(assetID) == nil { appendUndo(snapshot(for: assetID), for: assetID) }
            apply(value, for: assetID, admission: admission)
        } catch { errorMessage = "Die Bearbeitung ist während einer laufenden Speicheroperation gesperrt.\n\n" + error.localizedDescription }
    }
    func beginEditing(assetID: String) {
        guard canEdit, !assetID.isEmpty, histories.group(assetID) == nil else { return }
        advanceAIEditGeneration(); histories.beginGroup(snapshot(for: assetID), for: assetID)
    }
    func hasActiveEditing(assetID: String) -> Bool { histories.group(assetID) != nil }
    func editingFunction(assetID: String) -> EditingFunction { editingFunctions[assetID, default: .adjustments] }

    func selectEditingFunction(_ function: EditingFunction, assetID: String, cancelsActiveInput: Bool = true) {
        guard !assetID.isEmpty, function != editingFunctions[assetID, default: .adjustments] else { return }
        if cancelsActiveInput { ResettableNativeSlider.cancelInputs(in: NSApp?.keyWindow?.contentView) }
        // History and gesture boundaries must remain ordered with UI edits.
        // Background work here would allow an old gesture to enter a new function.
        endEditing(assetID: assetID)
        objectWillChange.send()
        histories.clear(assetID)
        editingFunctions[assetID] = function
        advanceAIEditGeneration()
    }
    func endEditing(assetID: String) {
        guard let start = histories.endGroup(assetID), start != snapshot(for: assetID) else { return }
        appendUndo(start, for: assetID)
    }
    func reset(assetID: String) {
        guard canEdit, !assetID.isEmpty else { return }
        advanceAIEditGeneration(); endEditing(assetID: assetID); setSettings(.neutral, for: assetID)
    }
    func returnToOriginal(assetID: String) {
        guard canEdit else { return }
        endEditing(assetID: assetID)
        if let value = try? EditingSnapshot(source: .original, settings: .neutral) { setSnapshot(value, for: assetID) }
    }
    func canUndo(assetID: String) -> Bool { canEdit && (histories.canUndo(assetID) || histories.group(assetID).map { $0 != snapshot(for: assetID) } == true) }
    func canRedo(assetID: String) -> Bool { canEdit && histories.canRedo(assetID) }
    func undo(assetID: String) {
        guard canUndo(assetID: assetID), nextRevisionAvailable(for: assetID) else { return }
        do {
            let admission = try registerWrite(); endEditing(assetID: assetID)
            guard let previous = histories.popUndo(assetID) else { return }
            histories.appendRedo(snapshot(for: assetID), for: assetID); apply(previous, for: assetID, admission: admission)
        } catch { errorMessage = error.localizedDescription }
    }
    func redo(assetID: String) {
        guard canRedo(assetID: assetID), nextRevisionAvailable(for: assetID) else { return }
        do {
            let admission = try registerWrite()
            guard let next = histories.popRedo(assetID) else { return }
            appendUndo(snapshot(for: assetID), for: assetID); apply(next, for: assetID, admission: admission)
        } catch { errorMessage = error.localizedDescription }
    }
    func flush() async -> Bool {
        await flush(includingActiveSliderEdits: true)
    }
    private func flush(includingActiveSliderEdits: Bool) async -> Bool {
        while isRestoring || isBackingUp { await withCheckedContinuation { maintenanceWaiters.append($0) } }
        guard await awaitAcceptedCommits() else { return false }
        return await flushPending(includingActiveSliderEdits: includingActiveSliderEdits)
    }
    private func flushPending(includingActiveSliderEdits: Bool = true) async -> Bool {
        if let loadingTask { await loadingTask.value }
        debounceTask?.cancel(); debounceTask = nil
        if let saveTask {
            guard await saveTask.value else { return false }
            // An explicit drain may have joined an automatic save which stopped
            // at a slider boundary. It must also persist the remaining edits.
            return await flushPending(includingActiveSliderEdits: includingActiveSliderEdits)
        }
        guard let database else { return false }
        guard !pending.isEmpty else { return !isReadOnly }
        guard includingActiveSliderEdits || !sliderPersistenceSession.hasActiveInput else { return true }
        do {
            for (id, edit) in pending where edit.admission == nil {
                pending[id] = PendingEdit(snapshot: edit.snapshot, revision: edit.revision, admission: try registerWrite())
            }
        } catch { errorMessage = error.localizedDescription; return false }
        let task = Task { await self.savePending(using: database, includingActiveSliderEdits: includingActiveSliderEdits) }; saveTask = task
        return await task.value
    }
    private func registerWrite() throws -> CatalogAcceptedWriteAdmission? {
        guard let gate else { return nil }
        guard let startup else { throw ArtifactContractError.staleEpoch }
        return try gate.registerAcceptedWrite(domain: .editing, session: startup)
    }
    private func apply(_ value: EditingSnapshot, for assetID: String, admission: CatalogAcceptedWriteAdmission?) {
        advanceAIEditGeneration()
        let revision = revisionsByAsset[assetID, default: 0] + 1
        revisionsByAsset[assetID] = revision; snapshotsByAsset[assetID] = value
        pending[assetID] = PendingEdit(snapshot: value, revision: revision, admission: admission)
        hasPendingChanges = true; scheduleSave()
    }
    private func savePending(using database: any EditingPersistence, includingActiveSliderEdits: Bool) async -> Bool {
        isSaving = true
        var savedBatch = false
        defer {
            isSaving = false; saveTask = nil
            // Maintenance must never wait on a later registered row that this
            // same serial flush still owns. Release the flush slot FIRST.
            if savedBatch && !isCommitting { scheduleAutomaticBackup() }
        }
        var backupWarning: String?
        repeat {
            let batch = pending
            for assetID in batch.keys.sorted() {
                // Recheck after each awaited write: a new gesture may have
                // started while a previously accepted snapshot was on disk.
                guard includingActiveSliderEdits || !sliderPersistenceSession.hasActiveInput else { return true }
                guard let edit = batch[assetID], let expected = persistedState(for: assetID) else { return false }
                do {
                    let result: StoredEditingState
                    if let gate, let admission = edit.admission {
                        result = try await gate.withAcceptedWrite(admission) {
                            try await database.saveSnapshot(edit.snapshot, for: assetID, expected: expected, revision: edit.revision)
                        }
                    } else { result = try await database.saveSnapshot(edit.snapshot, for: assetID, expected: expected, revision: edit.revision) }
                    guard result.snapshot == edit.snapshot, result.version.revision == edit.revision,
                          result.version.storeEpoch == expected.storeEpoch else { throw ArtifactContractError.staleSnapshot }
                    // Advance the durable baseline even if a newer local value waits.
                    baselines[assetID] = EditingExpectedState(result)
                    if pending[assetID]?.revision == edit.revision { pending.removeValue(forKey: assetID) }
                    hasPendingChanges = !pending.isEmpty
                } catch {
                    isReadOnly = true
                    errorMessage = "Bearbeitungen konnten nicht gespeichert werden. Die letzten Werte bleiben für einen erneuten Speicherversuch im Speicher erhalten.\n\n" + error.localizedDescription
                    // Failed execution admissions cannot run twice. Retry registers
                    // a new lease while preserving exact snapshot/revision/CAS.
                    for (id, value) in pending { pending[id] = PendingEdit(snapshot: value.snapshot, revision: value.revision, admission: nil) }
                    return false
                }
            }
            backupWarning = await database.backupWarning()
        } while !pending.isEmpty
        savedBatch = true
        isReadOnly = false; errorMessage = backupWarning ?? automaticBackupWarning ?? artifactStoreWarning; return true
    }
    private func scheduleAutomaticBackup() {
        guard automaticBackupTask == nil, let database, storeEpoch != nil else { return }
        let day = Calendar.current.startOfDay(for: Date())
        guard automaticBackupDay != day else { return }
        do {
            let admission: CatalogAcceptedWriteAdmission?
            if let gate {
                guard let startup else { throw CatalogLifecycleError.recoveryRequired }
                admission = try gate.registerAcceptedWrite(domain: .backupRestore, session: startup)
            } else { admission = nil }
            // One strongly held owner covers snapshot, immutable copy and the
            // later prune. Ordinary flushes never await it and remain runnable.
            automaticBackupTask = Task {
                defer { self.automaticBackupTask = nil }
                do {
                    if let gate = self.gate, let admission {
                        _ = try await gate.withAcceptedWrite(admission) { try await database.createBackup(automatic: true) }
                    } else { _ = try await database.createBackup(automatic: true) }
                    self.automaticBackupDay = day
                    self.automaticBackupWarning = await database.backupWarning()
                    if !self.isReadOnly { self.errorMessage = self.automaticBackupWarning ?? self.artifactStoreWarning }
                } catch {
                    self.automaticBackupWarning = "Das automatische Backup konnte nicht erstellt werden. Gespeicherte Bearbeitungen bleiben erhalten.\n\n" + error.localizedDescription
                    if !self.isReadOnly { self.errorMessage = self.automaticBackupWarning ?? self.artifactStoreWarning }
                }
            }
        } catch {
            automaticBackupWarning = "Das automatische Backup konnte noch nicht gestartet werden.\n\n" + error.localizedDescription
            if !isReadOnly { errorMessage = automaticBackupWarning }
        }
    }

    private func drainAutomaticBackup() async {
        if let automaticBackupTask { await automaticBackupTask.value }
    }

    func finishSaving() async -> Bool {
        // Explicit draining closes new UI acceptance before flushing. Waiting
        // for the automatic task while a serial flush slot is held deadlocks
        // when its prune is draining a newly accepted pending image.
        let wasClosing = isClosing
        isClosing = true
        defer { if !wasClosing { isClosing = false } }
        let commitsSaved = await awaitAcceptedCommits()
        let saved = await flushPending()
        await drainAutomaticBackup()
        return commitsSaved && (saved || (isReadOnly && pending.isEmpty))
    }

    private func scheduleSave(immediately: Bool = false) {
        debounceTask?.cancel()
        debounceTask = nil
        guard !pending.isEmpty, !sliderPersistenceSession.hasActiveInput else { return }
        debounceTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }; debounceTask = nil
            _ = await flush(includingActiveSliderEdits: false)
        }
    }
    private func nextRevisionAvailable(for assetID: String) -> Bool {
        guard revisionsByAsset[assetID, default: 0] < Int64.max else {
            isReadOnly = true; errorMessage = "Diese Bearbeitung kann nicht weiter gespeichert werden: Die maximale Versionsnummer wurde erreicht."; return false
        }; return true
    }
    private func appendUndo(_ value: EditingSnapshot, for assetID: String) {
        histories.appendUndo(value, for: assetID)
    }
    private func advanceAIEditGeneration() {
        objectWillChange.send()
        if aiEditGeneration == .max { aiEditSessionID = UUID(); aiEditGeneration = 0 } else { aiEditGeneration += 1 }
    }
    private func install(_ state: EditingStoreState) {
        invalidateVariants()
        storeEpoch = state.storeEpoch; baselines = state.byAsset.mapValues { EditingExpectedState($0) }
        for (id, revision) in state.tombstones { baselines[id] = try? EditingExpectedState(storeEpoch: state.storeEpoch, revision: revision, snapshot: nil) }
        snapshotsByAsset = state.byAsset.mapValues(\.snapshot)
        revisionsByAsset = state.byAsset.mapValues { $0.version.revision }.merging(state.tombstones, uniquingKeysWith: max)
    }
    private func loadArtifactMetadata(_ state: EditingStoreState) async throws {
        let ids = Set(state.byAsset.values.compactMap { value -> GeneratedArtifactID? in if case .artifact(let id) = value.snapshot.source { return id }; return nil })
        guard !ids.isEmpty else { return }
        guard let artifacts else { throw ArtifactContractError.missingArtifact }
        let storeID = await artifacts.storeID
        // One metadata-only manifest lookup at a time, never one raster/FD per grid cell.
        for id in ids {
            let value = try await artifacts.descriptor(id)
            artifactFingerprints[id] = ArtifactSourceFingerprint(storeID: storeID, artifactID: id, manifestSHA256: value.manifestSHA256, raster: value.raster)
        }
        let lease = try await artifacts.acquireLease(ids: ids, purpose: .activeEditing)
        for id in ids { leases[id] = lease }
    }
    private func finishLoadingWithError(_ error: Error) {
        isLoading = false; loadingTask = nil; isReadOnly = true
        errorMessage = "Die Bearbeitungsdatenbank konnte nicht geöffnet werden. Vorhandene Daten bleiben erhalten.\n\n" + error.localizedDescription
    }
    private func finishMaintenance() { let waiters = maintenanceWaiters; maintenanceWaiters.removeAll(); for waiter in waiters { waiter.resume() } }
}

extension EditingModel {
    /// Capturing generation authority is an explicit background operation, never
    /// a SwiftUI/grid getter. Recheck all UI epochs after the native observation.
    func generationSnapshot(in library: LibraryModel) async throws -> GenerationSnapshotToken {
        self.library = library
        guard let initial = aiSnapshot(in: library), let baseline = initial.persistedVersion else { throw ArtifactContractError.staleSnapshot }
        let full = snapshot(for: initial.assetID)
        let revision = localRevision(for: initial.assetID)
        let source: EditingSourceFingerprint
        switch initial.source {
        case .original(let value): source = .original(try await GenerationOriginalReader.shared.capture(value))
        case .artifact(let value): source = .artifact(value)
        }
        guard aiSnapshot(in: library) == initial, localRevision(for: initial.assetID) == revision else { throw ArtifactContractError.staleSnapshot }
        return GenerationSnapshotToken(assetID: initial.assetID, snapshot: full, source: source,
            persistedAtCapture: baseline, localRevision: revision, uiToken: initial.token)
    }

    func applyGeneratedArtifact(_ draft: ArtifactDraft, expectedSnapshotToken token: GenerationSnapshotToken) -> ArtifactCommitAdmission {
        guard canEdit, activeCommitID == nil, !commits.values.contains(where: \.failed),
              artifactStoreID != nil, let library, let current = aiSnapshot(in: library), current.assetID == token.assetID,
              current.token == token.uiToken, current.persistedVersion == token.persistedAtCapture,
              snapshot(for: token.assetID) == token.snapshot, localRevision(for: token.assetID) == token.localRevision,
              draft.artifact.provenance.parentSnapshot == token.snapshot,
              draft.artifact.provenance.parentSource == token.source,
              token.localRevision < Int64.max else { return .rejected(.staleSnapshot) }
        switch (current.source, token.source) {
        case (.original(let weak), .original(let strong)):
            guard weak.standardizedPath == strong.standardizedPath, weak.fileSize == strong.fileSize,
                  weak.modifiedAt == strong.modifiedAt else { return .rejected(.sourceChanged) }
        case (.artifact(let current), .artifact(let expected)):
            guard current == expected else { return .rejected(.sourceChanged) }
        default: return .rejected(.sourceChanged)
        }
        do {
            let admission = try registerWrite()
            let commit = Commit(id: .init(), draft: draft, token: token)
            commits[commit.id] = commit
            return start(commit, admission: admission)
        } catch { return .rejected(.staleEpoch) }
    }
    func retryAcceptedArtifactCommit(_ id: EditingCommitID) -> ArtifactCommitAdmission {
        guard let commit = commits[id] else { return .rejected(.invalidCapability) }
        if commit.published, let observer = commit.observer { return .accepted(observer) }
        guard !isCommitting, !isRestoring, !isBackingUp, !isClosing else { return .rejected(.staleSnapshot) }
        do { return start(commit, admission: try registerWrite()) } catch { return .rejected(.staleEpoch) }
    }
    var failedArtifactCommitID: EditingCommitID? { commits.values.first(where: \.failed)?.id }
    func awaitAcceptedCommits() async -> Bool {
        if let id = activeCommitID, let task = commits[id]?.task {
            do { _ = try await task.value } catch { return false }
        }
        return !commits.values.contains(where: \.failed)
    }
    private func start(_ commit: Commit, admission: CatalogAcceptedWriteAdmission?) -> ArtifactCommitAdmission {
        isCommitting = true; activeCommitID = commit.id; commit.failed = false
        // This owner is created synchronously before returning acceptance. There
        // is no observer cancellation path into its task/admission.
        let task = Task<ArtifactCommitReceipt, Error> {
            defer { self.isCommitting = false; self.activeCommitID = nil }
            do {
                let receipt: ArtifactCommitReceipt
                if let gate = self.gate, let admission {
                    receipt = try await gate.withAcceptedWrite(admission) { try await self.performCommit(commit) }
                } else { receipt = try await self.performCommit(commit) }
                self.publish(receipt, for: commit)
                // The accepted generation capability has ended. Its inner
                // pending-settings flush deliberately did not start a backup.
                self.scheduleAutomaticBackup()
                if let database = self.database { self.errorMessage = await database.backupWarning() ?? self.automaticBackupWarning ?? self.artifactStoreWarning }
                else { self.errorMessage = nil }
                return receipt
            } catch {
                commit.failed = true
                self.errorMessage = "Der angenommene Bildstand konnte nicht vollständig gespeichert werden. Wiederholen verwendet denselben Auftrag.\n\n" + error.localizedDescription
                throw error
            }
        }
        commit.task = task
        let observer = AcceptedArtifactCommit(id: commit.id, task: task); commit.observer = observer
        return .accepted(observer)
    }
    private func performCommit(_ commit: Commit) async throws -> ArtifactCommitReceipt {
        guard let database else { throw ArtifactContractError.invalidCapability }
        if let previous = try await database.committed(commit.id) {
            if let request = commit.request, previous.requestSHA256 != request.requestSHA256 { throw ArtifactContractError.conflictingCommit }
            return try await retainCommitted(previous, commit: commit)
        }
        if commit.request == nil {
            let token = commit.token
            guard persistedState(for: token.assetID) == token.persistedAtCapture,
                  snapshot(for: token.assetID) == token.snapshot,
                  localRevision(for: token.assetID) == token.localRevision else { throw ArtifactContractError.staleSnapshot }
            let hadPending = pending[token.assetID] != nil
            guard await flushPending(), let baseline = persistedState(for: token.assetID) else { throw ArtifactContractError.staleSnapshot }
            if hadPending {
                guard baseline.storeEpoch == token.persistedAtCapture.storeEpoch,
                      baseline.revision == token.localRevision, baseline.snapshot == token.snapshot else { throw ArtifactContractError.staleSnapshot }
            } else { guard baseline == token.persistedAtCapture else { throw ArtifactContractError.staleSnapshot } }
            commit.request = try GenerationCommitRequest(commitID: commit.id, assetID: token.assetID, draft: commit.draft,
                expected: baseline, expectedParentSource: token.source, nextRevision: token.localRevision + 1)
        }
        guard let request = commit.request else { throw ArtifactContractError.invalidCapability }
        let receipt = try await database.commitGenerated(request)
        guard receipt.commitID == request.commitID, receipt.assetID == request.assetID,
              receipt.requestSHA256 == request.requestSHA256,
              receipt.stored.snapshot.source == .artifact(commit.draft.artifact.id),
              receipt.stored.snapshot.settings.isNeutral else { throw ArtifactContractError.conflictingCommit }
        return try await retainCommitted(receipt, commit: commit)
    }
    private func retainCommitted(_ receipt: ArtifactCommitReceipt, commit: Commit) async throws -> ArtifactCommitReceipt {
        guard let artifacts else { throw ArtifactContractError.invalidCapability }
        if leases[receipt.artifactID] == nil { leases[receipt.artifactID] = try await artifacts.acquireLease(ids: [receipt.artifactID], purpose: .activeEditing) }
        return receipt
    }
    private func publish(_ receipt: ArtifactCommitReceipt, for commit: Commit) {
        guard !commit.published else { return }
        let assetID = receipt.assetID
        // The retained draft owns a lease until this session/history retires.
        // A receipt may finish after selection changed, but always belongs to A.
        guard let storeID = artifactStoreID else { return }
        let fingerprint = ArtifactSourceFingerprint(storeID: storeID, artifactID: receipt.artifactID,
            manifestSHA256: commit.draft.artifact.manifestSHA256, raster: commit.draft.artifact.raster)
        artifactFingerprints[receipt.artifactID] = fingerprint
        endEditing(assetID: assetID)
        histories.clearRedo(assetID)
        appendUndo(commit.token.snapshot, for: assetID)
        snapshotsByAsset[assetID] = receipt.stored.snapshot
        revisionsByAsset[assetID] = receipt.stored.version.revision
        baselines[assetID] = EditingExpectedState(receipt.stored)
        commit.published = true; commit.failed = false
        completedCommitIDs.append(commit.id)
        while completedCommitIDs.count > retainedCommitLimit {
            let old = completedCommitIDs.removeFirst()
            if old != commit.id, commits[old]?.published == true { commits.removeValue(forKey: old) }
        }
        invalidateVariants()
        advanceAIEditGeneration(); notice = "Generierter Bildstand gespeichert."
    }

    func createBackup(exportTo target: URL? = nil) async -> URL? {
        guard canBackUp, let database else { return nil }
        isBackingUp = true
        defer { isBackingUp = false; finishMaintenance() }
        let commitsSaved = await awaitAcceptedCommits()
        let saved = await flushPending()
        await drainAutomaticBackup()
        guard commitsSaved && saved else { return nil }
        do {
            if let target {
                let directory = self.directory
                let valid = await Task.detached { Self.isValidExportTarget(target, directory: directory) }.value
                guard valid else { throw ArtifactContractError.invalidValue("backup destination") }
            }
            let local = try await database.createBackup(automatic: false)
            guard let target else { notice = "Bearbeitungspaket erstellt: \(local.lastPathComponent)"; return local }
            do {
                let exported = try await database.exportBackup(from: local, toNew: target)
                notice = "Bearbeitungspaket exportiert: \(exported.lastPathComponent)"; return exported
            } catch {
                notice = "Lokales Bearbeitungspaket erstellt: \(local.lastPathComponent)"
                errorMessage = "Das lokale Backup bleibt unter \(local.path) erhalten.\n\n" + error.localizedDescription; return nil
            }
        } catch { errorMessage = "Das Backup konnte nicht erstellt werden.\n\n" + error.localizedDescription; return nil }
    }
    func restoreBackup(from url: URL) async -> Bool {
        guard canRestore, let database else { return false }
        aiEditSessionID = UUID(); aiEditGeneration = 0; isRestoring = true
        defer { isRestoring = false; finishMaintenance() }
        let commitsSaved = await awaitAcceptedCommits()
        let saved = await flushPending()
        await drainAutomaticBackup()
        guard commitsSaved && (saved || pending.isEmpty) else { return false }
        do {
            let requiresRecovery = storeEpoch == nil
            let restored: EditingStoreState
            if requiresRecovery {
                guard let recoverDatabase else { throw CatalogCoordinationError.recoveryRequired }
                let committed = try await recoverDatabase(url)
                // Reopen through the ordinary shared repository after the closed
                // coordinator has completed its journal-free recovery boundary.
                restored = try await database.loadState()
                guard restored.storeEpoch == committed.storeEpoch, restored.byAsset == committed.byAsset,
                      restored.tombstones == committed.tombstones else { throw ArtifactContractError.staleSnapshot }
                if let gate { startup = try await gate.waitForStartup() }
            } else { restored = try await database.restoreBackup(from: url) }
            install(restored)
            try await loadArtifactMetadata(restored)
            pending.removeAll(); hasPendingChanges = false
            histories.removeAll(); commits.removeAll()
            // Ordinary restore uses the already-open catalog admission. Damaged
            // database recovery must first reopen the library below; startup
            // may have failed before it could obtain that admission. Its normal
            // load then cleans against the current durable catalog.
            if !requiresRecovery { try await library?.reconcileAfterEditingRestore() }
            sourceStateIsCoherent = true; isReadOnly = false; errorMessage = artifactStoreWarning
            notice = requiresRecovery
                ? "Recovery abgeschlossen. Die beschädigte Datenbankfamilie und generierte Pixel wurden separat gesichert."
                : "Bearbeitungspaket wiederhergestellt. Der vorherige Stand wurde separat gesichert."
            if requiresRecovery { library?.retryCoordinatedRecovery() }
            return true
        } catch {
            errorMessage = "Das Backup konnte nicht wiederhergestellt werden.\n\n" + error.localizedDescription
            // Never bless a changed baseline after an ambiguous restore error.
            if let state = try? await database.loadState() {
                let unchanged = state.storeEpoch == storeEpoch && state.byAsset.mapValues(\.snapshot) == snapshotsByAsset
                isReadOnly = isReadOnly || !unchanged
            } else { isReadOnly = true }
            return false
        }
    }
    private nonisolated static func isValidExportTarget(_ target: URL, directory: URL?) -> Bool {
        guard target.isFileURL, target.pathExtension.lowercased() == "glowroombackup" else { return false }
        guard let directory else { return true }
        return !ManagedFileProtection.protects(target, directory: directory)
    }

}

/// A single metadata worker for explicit generation capture, without opening
/// every grid source or adding another raster/decoder pool.
private actor GenerationOriginalReader {
    static let shared = GenerationOriginalReader()
    func capture(_ source: AIOriginalSourceFingerprint) throws -> OriginalSourceFingerprint {
        let url = URL(fileURLWithPath: source.standardizedPath)
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let fingerprint = try AssetRemapVerifier.capture(url, referenceDate: source.modifiedAt)
        let observed = Double(fingerprint.nativeRevision.modifiedSeconds) - Date.timeIntervalBetween1970AndReferenceDate
            + Double(fingerprint.nativeRevision.modifiedNanoseconds) / 1_000_000_000
        guard fingerprint.fileSize == source.fileSize,
              abs(observed - source.modifiedAt.timeIntervalSinceReferenceDate) <= 0.000_005 else { throw ArtifactContractError.sourceChanged }
        return fingerprint
    }
}
