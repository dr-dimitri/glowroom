import Foundation
import GlowroomCore

protocol SemanticModelInstalling: Sendable {
    func inspect(source: URL) async throws -> SemanticModelImportReview
    func install(_ review: SemanticModelImportReview, progress: @escaping @Sendable (SemanticInstallProgress) -> Void) async throws -> SemanticInstalledModel
    func installedModel() async throws -> SemanticInstalledModel?
    func remove() async throws
}
extension SemanticModelInstaller: SemanticModelInstalling {}

/// Owns one actual query, one replaceable pending query and one serial indexing
/// task. Cancellation never releases a native model lease before actual return.
actor SemanticSearchService: SemanticSearchServing {
    typealias ProviderFactory = @Sendable (SemanticInstalledModel?) -> any SemanticEmbeddingProviding
    private struct CatalogToken: Hashable, Sendable { let session: UUID; let generation: Int; let epoch: UUID }
    private struct Signature: Hashable, Sendable {
        let query: String; let candidates: [SemanticIndexCandidate]; let topK: Int; let catalog: CatalogToken; let space: UUID
    }
    private struct Context: Sendable {
        let signature: Signature; let generation: SemanticIndexGeneration
        let installation: SemanticInstalledModel; let provider: any SemanticEmbeddingProviding
    }
    private struct Waiter { let continuation: CheckedContinuation<SemanticSearchResult, Error> }
    private struct QueryJob {
        let id: UUID; let signature: Signature; var waiters: [UUID: Waiter]
        var task: Task<Void, Never>?; var discarded = false
    }
    private struct Pending { let signature: Signature; var waiters: [UUID: Waiter] }
    private struct IndexJob {
        let id: UUID; let task: Task<Void, Error>
        var installationFingerprint: String?
    }
    private struct CacheKey: Hashable { let descriptor: SemanticModelDescriptor; let installation: String; let query: String }
    private struct Counts { var indexed = 0; var total = 0; var stale = 0; var missing = 0; var processed = 0 }

    private let store: SemanticIndexStore
    private let installer: any SemanticModelInstalling
    private let providerFactory: ProviderFactory
    private let preparer: any SemanticImagePreprocessing
    private let budget: AIResourceBudget
    private var installation: SemanticInstalledModel?
    private var provider: (any SemanticEmbeddingProviding)?
    private var invalidInstallationFingerprint: String?
    private var catalog: CatalogToken?
    private var assets: [String: PhotoAsset] = [:]
    private var latestSignature: Signature?
    private var querySpace = UUID()
    private var actualQuery: QueryJob?
    private var pendingQuery: Pending?
    private var indexJob: IndexJob?
    private var indexEpoch = UUID()
    private var preservedIndex: URL?
    private var statusEpoch = UUID()
    private var cache: [CacheKey: [Float]] = [:]
    private var cacheOrder: [CacheKey] = []
    private var maintaining = false
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribers: [UUID: AsyncStream<SemanticSearchState>.Continuation] = [:]
    private var state = SemanticSearchState.notInstalled
    private var version: UInt64 = 0
    private var availability: SemanticAvailability = .unavailable(.modelNotInstalled)
    private var counts = Counts()
    private var activeID: UUID?
    private var notice: String?

    /// Only value construction; model files and SQLite open lazily on this actor.
    init(directory: URL) throws {
        store = try SemanticIndexStore(directory: directory)
        installer = SemanticModelInstaller(directory: directory.appendingPathComponent("SemanticModels", isDirectory: true))
        providerFactory = { SemanticLocalProviderFactory.makeProvider(installation: $0) }
        preparer = SemanticPreparationAdmission(SemanticImagePreprocessor())
        budget = .shared
    }
    init(store: SemanticIndexStore, installer: any SemanticModelInstalling,
         providerFactory: @escaping ProviderFactory, preparer: any SemanticImagePreprocessing,
         budget: AIResourceBudget = .shared) {
        self.store = store; self.installer = installer; self.providerFactory = providerFactory
        self.preparer = SemanticPreparationAdmission(preparer); self.budget = budget
    }

    func updateCatalog(snapshotSessionID: UUID, generation: Int, assets incoming: [PhotoAsset]) async {
        guard generation >= 0 else { return }
        if let catalog {
            guard catalog.session == snapshotSessionID, generation > catalog.generation else { return }
        }
        guard incoming.count <= 1_000_000, Set(incoming.map(\.id)).count == incoming.count else { return }
        catalog = CatalogToken(session: snapshotSessionID, generation: generation, epoch: UUID())
        assets = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        statusEpoch = UUID(); indexEpoch = UUID()
        invalidateQueries(.superseded); indexJob?.task.cancel()
        counts = Counts(total: incoming.count, missing: incoming.count)
        notice = nil; publish()
    }

    func search(query: String, candidates: [PhotoAsset], topK: Int = 100) async throws -> SemanticSearchResult {
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        guard query.utf8.count <= 2_048, (1...500).contains(topK) else { throw SemanticEmbeddingError.invalidInput }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // LibraryModel handles empty semantic queries with the ordinary library
        // projection. This guard guarantees no empty-text inference at this API.
        guard !normalized.isEmpty, normalized.utf8.count <= 2_048 else { throw SemanticEmbeddingError.invalidInput }
        let token = try validateScope(candidates)
        let signature = Signature(query: normalized, candidates: candidates.map(Self.candidate), topK: topK, catalog: token, space: querySpace)
        latestSignature = signature
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(signature, waiter: waiter, continuation: continuation)
            }
        } onCancel: { Task { await self.cancel(waiter: waiter) } }
    }

    func status(scope: [PhotoAsset]) async throws -> SemanticSearchState {
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        if maintaining { return state }
        let token = try validateScope(scope), request = UUID(); statusEpoch = request
        do {
            let model = try await currentModel()
            let generation = try await store.activeGeneration()
            let compatible = generation.flatMap { Self.matches($0, model: model.installation) ? $0 : nil }
            if indexJob == nil {
                let measured = try await measure(scope: scope, generation: compatible)
                try ensureCurrent(token)
                guard statusEpoch == request else { throw SemanticEmbeddingError.superseded }
                counts = measured; activeID = compatible?.id
            }
            let measuredAvailability = await model.provider.availability()
            try ensureCurrent(token)
            guard statusEpoch == request else { throw SemanticEmbeddingError.superseded }
            availability = measuredAvailability
            publish(); return state
        } catch {
            let failure = Self.sanitized(error)
            if failure == .superseded || failure == .cancelled { throw failure }
            guard catalog == token, statusEpoch == request else { throw SemanticEmbeddingError.superseded }
            if case .unavailable(let reason) = failure { availability = .unavailable(reason) }
            else if [.corruptIndex, .unsupportedVersion, .indexUnavailable].contains(failure) {
                // A rejected regenerable index does not make the installed
                // model invalid. Keep explicit rebuild controls usable.
                availability = .available; notice = failure.localizedDescription
            } else { availability = .unavailable(.invalidInstallation); notice = failure.localizedDescription }
            counts = Counts(total: scope.count, missing: scope.count); activeID = nil
            publish(); return state
        }
    }

    func updates() async -> AsyncStream<SemanticSearchState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        }
    }

    func prepareIndex(scope: [PhotoAsset], rebuild: Bool) async throws {
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        let token = try validateScope(scope)
        guard !maintaining, indexJob == nil else { throw SemanticEmbeddingError.unavailable(.busy) }
        let id = UUID(), epoch = UUID(); indexEpoch = epoch
        counts = Counts(total: scope.count); notice = nil; preservedIndex = nil
        let task = Task { [weak self] in
            guard let self else { throw SemanticEmbeddingError.cancelled }
            do { try await self.runIndex(id: id, scope: scope, token: token, epoch: epoch, rebuild: rebuild); await self.finishIndex(id: id, failure: nil) }
            catch { let error = Self.sanitized(error); await self.finishIndex(id: id, failure: error); throw error }
        }
        indexJob = IndexJob(id: id, task: task); publish()
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func cancelIndexing() async {
        indexEpoch = UUID(); indexJob?.task.cancel()
        if indexJob != nil { notice = "Der Suchindex wird nach dem laufenden Modellschritt angehalten."; publish() }
    }

    func inspectModel(source: URL) async throws -> SemanticModelImportReview {
        guard !maintaining else { throw SemanticEmbeddingError.unavailable(.busy) }
        do { return try await installer.inspect(source: source) } catch { throw Self.sanitized(error) }
    }
    func installModel(_ review: SemanticModelImportReview) async throws {
        try await beginMaintenance()
        defer { endMaintenance() }
        do {
            notice = "Das geprüfte lokale Suchmodell wird installiert."; publish()
            let lease = try await budget.acquireLocalInference(priority: .interactive)
            let installed: SemanticInstalledModel
            do { installed = try await installer.install(review, progress: { _ in }); await budget.release(lease) }
            catch { await budget.release(lease); throw error }
            installation = installed; provider = providerFactory(installed); invalidInstallationFingerprint = nil
            availability = await provider!.availability(); activeID = nil; counts = Counts()
            notice = "Lokales Modell installiert. Den Suchindex für den gewünschten Umfang vorbereiten."
        } catch { notice = Self.sanitized(error).localizedDescription; throw Self.sanitized(error) }
    }
    func removeModel() async throws {
        try await beginMaintenance()
        defer { endMaintenance() }
        do {
            try await installer.remove()
            installation = nil; provider = nil; invalidInstallationFingerprint = nil; availability = .unavailable(.modelNotInstalled); activeID = nil
            counts = Counts(); notice = "Lokales Suchmodell entfernt. Die wörtliche Suche bleibt verfügbar."
        } catch { notice = Self.sanitized(error).localizedDescription; throw Self.sanitized(error) }
    }
    func deleteIndex() async throws {
        try await beginMaintenance()
        defer { endMaintenance() }
        do {
            let preserved = try await store.deleteAfterExplicitUserAction()
            activeID = nil; counts = Counts()
            notice = preserved.map { "Vorhandene Indexdateien wurden aufbewahrt: \($0.path)" } ?? "Die Indexeinträge wurden gelöscht."
        } catch { notice = Self.sanitized(error).localizedDescription; throw Self.sanitized(error) }
    }
    /// Stop actual native work before deleting vectors, so a late encoder
    /// cannot repopulate an asset removed from the durable catalog.
    func purgeRemovedAssets(retaining assetIDs: Set<String>) async throws {
        while maintaining { await withCheckedContinuation { maintenanceWaiters.append($0) } }
        try await beginMaintenance()
        defer { endMaintenance() }
        _ = try await store.retainOnlyCatalogAssets(assetIDs)
        assets = assets.filter { assetIDs.contains($0.key) }
        querySpace = UUID(); counts = Counts(total: assets.count, missing: assets.count)
    }
    func shutdown() async {
        // Termination can be cancelled; completing shutdown never permanently
        // closes this service. A later query may load its provider again.
        while maintaining { await withCheckedContinuation { maintenanceWaiters.append($0) } }
        do { try await beginMaintenance(); endMaintenance() } catch { }
    }

    private func currentModel() async throws -> (installation: SemanticInstalledModel, provider: any SemanticEmbeddingProviding) {
        guard !maintaining else { throw SemanticEmbeddingError.unavailable(.busy) }
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        let found: SemanticInstalledModel
        do {
            guard let value = try await installer.installedModel() else { throw SemanticEmbeddingError.unavailable(.modelNotInstalled) }
            found = value
        } catch { throw Self.sanitized(error) }
        guard !maintaining else { throw SemanticEmbeddingError.superseded }
        if invalidInstallationFingerprint == found.installationFingerprint { throw SemanticEmbeddingError.invalidInstallation }
        if let installation, installation != found { throw SemanticEmbeddingError.installationChanged }
        let needsAvailability = installation == nil || availability != .available
        if installation == nil { installation = found; provider = providerFactory(found) }
        guard let provider, provider.descriptor == found.descriptor else { throw SemanticEmbeddingError.invalidInstallation }
        let available: SemanticAvailability
        if needsAvailability { available = await provider.availability() }
        else { available = availability }
        guard !maintaining, installation == found else { throw SemanticEmbeddingError.superseded }
        guard available == .available else {
            if case .unavailable(let reason) = available { throw SemanticEmbeddingError.unavailable(reason) }
            throw SemanticEmbeddingError.invalidInstallation
        }
        availability = available
        return (found, provider)
    }

    private func enqueue(_ signature: Signature, waiter: UUID, continuation: CheckedContinuation<SemanticSearchResult, Error>) {
        guard !maintaining, latestSignature == signature, catalog == signature.catalog else { continuation.resume(throwing: SemanticEmbeddingError.superseded); return }
        let value = Waiter(continuation: continuation)
        if actualQuery?.signature == signature, actualQuery?.discarded == false {
            actualQuery?.waiters[waiter] = value; return
        }
        if pendingQuery?.signature == signature {
            pendingQuery?.waiters[waiter] = value; return
        }
        if actualQuery == nil { start(signature, waiters: [waiter: value]); return }
        discardActual(.superseded)
        if let pendingQuery { for waiter in pendingQuery.waiters.values { waiter.continuation.resume(throwing: SemanticEmbeddingError.superseded) } }
        pendingQuery = Pending(signature: signature, waiters: [waiter: value])
    }
    private func start(_ signature: Signature, waiters: [UUID: Waiter]) {
        let id = UUID()
        actualQuery = QueryJob(id: id, signature: signature, waiters: waiters)
        let task = Task { [weak self] in
            guard let self else { return }
            let result: Result<SemanticSearchResult, Error>
            do { result = .success(try await self.performQuery(signature)) }
            catch { result = .failure(Self.sanitized(error)) }
            await self.finishQuery(id: id, result: result)
        }
        actualQuery?.task = task
    }
    private func discardActual(_ error: SemanticEmbeddingError) {
        guard var job = actualQuery, !job.discarded else { return }
        job.discarded = true
        for waiter in job.waiters.values { waiter.continuation.resume(throwing: error) }
        job.waiters.removeAll(); job.task?.cancel(); actualQuery = job
    }
    private func invalidateQueries(_ error: SemanticEmbeddingError) {
        latestSignature = nil; discardActual(error)
        if let pendingQuery { for waiter in pendingQuery.waiters.values { waiter.continuation.resume(throwing: error) } }
        pendingQuery = nil
    }
    private func cancel(waiter: UUID) {
        if let value = actualQuery?.waiters.removeValue(forKey: waiter) {
            value.continuation.resume(throwing: SemanticEmbeddingError.cancelled)
            if actualQuery?.waiters.isEmpty == true { discardActual(.cancelled) }
        } else if let value = pendingQuery?.waiters.removeValue(forKey: waiter) {
            value.continuation.resume(throwing: SemanticEmbeddingError.cancelled)
            if pendingQuery?.waiters.isEmpty == true { pendingQuery = nil }
        }
    }
    private func finishQuery(id: UUID, result: Result<SemanticSearchResult, Error>) {
        guard let job = actualQuery, job.id == id else { return }
        let current = !maintaining && !job.discarded && catalog == job.signature.catalog && latestSignature == job.signature
        for waiter in job.waiters.values {
            if current { waiter.continuation.resume(with: result) }
            else { waiter.continuation.resume(throwing: SemanticEmbeddingError.superseded) }
        }
        if current, case .failure(let error) = result,
           let failure = error as? SemanticEmbeddingError,
           failure == .invalidInstallation || failure == .installationChanged {
            invalidInstallationFingerprint = installation?.installationFingerprint
            availability = .unavailable(.invalidInstallation); notice = failure.localizedDescription; publish()
        }
        actualQuery = nil
        if let pending = pendingQuery, !maintaining {
            pendingQuery = nil
            if latestSignature == pending.signature, catalog == pending.signature.catalog { start(pending.signature, waiters: pending.waiters) }
            else { for waiter in pending.waiters.values { waiter.continuation.resume(throwing: SemanticEmbeddingError.superseded) } }
        }
    }

    private func performQuery(_ signature: Signature) async throws -> SemanticSearchResult {
        try ensureCurrent(signature.catalog)
        guard latestSignature == signature else { throw SemanticEmbeddingError.superseded }
        let model = try await currentModel()
        guard let generation = try await store.activeGeneration(), Self.matches(generation, model: model.installation) else { throw SemanticEmbeddingError.indexUnavailable }
        let context = Context(signature: signature, generation: generation, installation: model.installation, provider: model.provider)
        try ensureQueryCurrent(context)
        let key = CacheKey(descriptor: context.generation.descriptor, installation: context.installation.installationFingerprint, query: context.signature.query)
        let vector: [Float]
        if let cached = cache[key] { vector = cached; touch(key) }
        else {
            let lease = try await budget.acquireLocalInference(priority: .interactive)
            do { vector = try await context.provider.encodeText(context.signature.query); await budget.release(lease) }
            catch { await budget.release(lease); throw error }
            try ensureQueryCurrent(context)
            try SemanticVectorSearch.validateVector(vector, dimension: context.generation.descriptor.dimension)
            cache[key] = vector; touch(key)
        }
        try ensureQueryCurrent(context)
        let stamps = try await sourceRevisions(candidates: context.signature.candidates)
        try ensureQueryCurrent(context)
        var worker = try SemanticVectorSearch(query: vector, dimension: context.generation.descriptor.dimension,
            candidates: context.signature.candidates, sourceRevisions: stamps, topK: context.signature.topK)
        var after: String?
        while true {
            let page = try await store.records(in: context.generation, afterAssetID: after, limit: 256)
            try ensureQueryCurrent(context)
            if page.isEmpty { break }
            try worker.consume(page); after = page.last?.assetID
            if page.count < 256 { break }
            await Task.yield()
        }
        // A source may change while vector I/O/ranking is in flight. Recheck
        // admitted hits before publication; no stale file is silently included.
        let admittedIDs = Set(worker.hits.map(\.assetID))
        let admitted = context.signature.candidates.filter { admittedIDs.contains($0.assetID) }
        let finalStamps = try await sourceRevisions(candidates: admitted)
        try ensureQueryCurrent(context)
        let hits = worker.hits.filter { finalStamps[$0.assetID] != nil && finalStamps[$0.assetID] == stamps[$0.assetID] }
        guard try await store.activeGeneration() == context.generation else { throw SemanticEmbeddingError.superseded }
        try ensureQueryCurrent(context)
        return SemanticSearchResult(catalogSessionID: context.signature.catalog.session,
            catalogGeneration: context.signature.catalog.generation, indexGenerationID: context.generation.id,
            modelDescriptor: context.generation.descriptor, candidateAssetIDs: context.signature.candidates.map(\.assetID), hits: hits)
    }
    private func ensureQueryCurrent(_ context: Context) throws {
        try ensureCurrent(context.signature.catalog)
        guard latestSignature == context.signature, !maintaining,
              installation == context.installation else { throw SemanticEmbeddingError.superseded }
    }
    private func touch(_ key: CacheKey) {
        cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
        while cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    private func runIndex(id: UUID, scope: [PhotoAsset], token: CatalogToken, epoch: UUID, rebuild: Bool) async throws {
        let model = try await currentModel()
        try ensureIndexCurrent(token, epoch: epoch)
        guard indexJob?.id == id else { throw SemanticEmbeddingError.superseded }
        indexJob?.installationFingerprint = model.installation.installationFingerprint
        var oldActive: SemanticIndexGeneration?
        let generation: SemanticIndexGeneration
        do {
            oldActive = try await store.activeGeneration()
            generation = try await store.prepareGeneration(for: model.installation.descriptor,
                installationFingerprint: model.installation.installationFingerprint, forceNew: rebuild)
        } catch let error as SemanticEmbeddingError where rebuild && (error == .corruptIndex || error == .unsupportedVersion) {
            preservedIndex = try await store.rebuildAfterExplicitUserAction()
            notice = preservedIndex.map { "Vorhandene Indexdateien wurden aufbewahrt: \($0.path)" }
            oldActive = nil
            generation = try await store.prepareGeneration(for: model.installation.descriptor, installationFingerprint: model.installation.installationFingerprint)
        }
        try ensureIndexCurrent(token, epoch: epoch)
        if oldActive == nil { try await store.activate(generation); changedActiveGeneration(generation.id) }
        else if Self.matches(oldActive!, model: model.installation) { activeID = oldActive?.id }
        var valid = 0, missing = 0, stale = 0
        for asset in scope {
            try ensureIndexCurrent(token, epoch: epoch)
            let source = Self.source(asset)
            do {
                let before = try await preparer.sourceStamp(source: source)
                try ensureIndexCurrent(token, epoch: epoch)
                let existing = try await store.metadata(in: generation, assetIDs: [asset.id]).first
                if let existing, existing.source == source, existing.sourceRevision == before { valid += 1 }
                else {
                    if existing != nil { stale += 1 }
                    let input: SemanticImageInput
                    do { input = try await preparer.prepare(source: source, priority: .thumbnail) }
                    catch is PreviewFailure { throw SemanticEmbeddingError.staleSource }
                    try ensureIndexCurrent(token, epoch: epoch)
                    guard input.sourceRevision == before else { throw SemanticEmbeddingError.staleSource }
                    let lease = try await budget.acquireLocalInference(priority: .background)
                    let vector: [Float]
                    do { vector = try await model.provider.encodeImage(input); await budget.release(lease) }
                    catch { await budget.release(lease); throw error }
                    try ensureIndexCurrent(token, epoch: epoch)
                    guard try await preparer.sourceStamp(source: source) == before else { throw SemanticEmbeddingError.staleSource }
                    try ensureIndexCurrent(token, epoch: epoch)
                    try await store.upsert(SemanticIndexRecord(assetID: asset.id, source: source, sourceRevision: before, inputRasterSHA256: input.rasterSHA256, vector: vector), in: generation)
                    valid += 1
                }
            } catch {
                let error = Self.sanitized(error)
                if error == .cancelled || error == .superseded { throw error }
                if error == .staleSource { missing += 1 }
                else { throw error }
            }
            try ensureIndexCurrent(token, epoch: epoch)
            counts = Counts(indexed: valid, total: scope.count, stale: stale, missing: missing, processed: valid + missing)
            publish(); await Task.yield()
        }
        try ensureIndexCurrent(token, epoch: epoch)
        // Every chosen source was processed. Recoverable per-photo read/decode
        // failures remain explicitly missing; they do not block usable photos
        // or mix the previous model's vectors into this new generation.
        guard valid + missing == scope.count else { throw SemanticEmbeddingError.indexUnavailable }
        try await store.activate(generation)
        // A completed DB activation is authoritative even if cancellation or a
        // catalog update raced its return. Always register that committed ID;
        // only UI counts for the old scope may be discarded.
        if oldActive?.id != generation.id, activeID != generation.id { changedActiveGeneration(generation.id) }
        else { activeID = generation.id }
        if catalog == token, indexEpoch == epoch { counts.stale = 0 }
        availability = .available
    }
    private func changedActiveGeneration(_ id: UUID) {
        activeID = id; querySpace = UUID(); invalidateQueries(.superseded)
    }
    private func finishIndex(id: UUID, failure: SemanticEmbeddingError?) {
        guard let job = indexJob, job.id == id else { return }
        indexJob = nil
        if let failure {
            notice = failure.localizedDescription
            // An image-encoder integrity failure is as authoritative as a text
            // query failure. Cheap directory/receipt availability must not make
            // these known-bad weights available again. Bind rejection to the
            // actual job's installation, never to a newer installed model.
            if failure == .invalidInstallation || failure == .installationChanged,
               let fingerprint = job.installationFingerprint,
               fingerprint == installation?.installationFingerprint {
                invalidInstallationFingerprint = fingerprint
                availability = .unavailable(.invalidInstallation)
            }
        }
        else if counts.missing > 0 { notice = "Suchindex vorbereitet: \(counts.indexed) gültig, \(counts.missing) nicht lesbar oder nicht verfügbar. Ähnlichkeitswerte sind keine Wahrscheinlichkeiten." }
        else { notice = "Suchindex vorbereitet. Ähnlichkeitswerte sind keine Wahrscheinlichkeiten." }
        if let preservedIndex { notice = (notice ?? "") + " Vorhandene Indexdateien wurden aufbewahrt: " + preservedIndex.path }
        preservedIndex = nil
        publish()
    }
    private func ensureIndexCurrent(_ token: CatalogToken, epoch: UUID) throws {
        try ensureCurrent(token)
        guard indexEpoch == epoch, !maintaining else { throw SemanticEmbeddingError.superseded }
    }

    private func measure(scope: [PhotoAsset], generation: SemanticIndexGeneration?) async throws -> Counts {
        guard let generation else { return Counts(total: scope.count, missing: scope.count) }
        let stamps = try await sourceRevisions(candidates: scope.map(Self.candidate))
        var result = Counts(total: scope.count)
        for start in stride(from: 0, to: scope.count, by: 512) {
            let chunk = Array(scope[start..<min(scope.count, start + 512)])
            let rows = try await store.metadata(in: generation, assetIDs: chunk.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.assetID, $0) })
            for asset in chunk {
                guard let stamp = stamps[asset.id] else { result.missing += 1; continue }
                guard let row = byID[asset.id] else { result.missing += 1; continue }
                if row.source == Self.source(asset), row.sourceRevision == stamp { result.indexed += 1 }
                else { result.stale += 1 }
            }
        }
        return result
    }
    private func sourceRevisions(candidates: [SemanticIndexCandidate]) async throws -> [String: String] {
        let preparer = preparer
        // Exactly two chunk workers, never one task per photo or another pool.
        // Every candidate still gets an open/fstat; a shared admission now spans
        // at most 64 sources instead of paying an actor round trip per source.
        let batchSize = SemanticSourceStampBatch.maximumCount
        let workerCount = min(2, (candidates.count + batchSize - 1) / batchSize)
        return try await withThrowingTaskGroup(of: [String: String].self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    var result: [String: String] = [:]
                    for start in stride(from: worker * batchSize, to: candidates.count, by: 2 * batchSize) {
                        try Task.checkCancellation()
                        let chunk = candidates[start..<min(candidates.count, start + batchSize)]
                        let values = try await preparer.sourceStamps(sources: chunk.map(\.source))
                        try Task.checkCancellation()
                        guard values.count == chunk.count else { throw SemanticEmbeddingError.providerFailure }
                        for (candidate, stamp) in zip(chunk, values) {
                            if let stamp { result[candidate.assetID] = stamp }
                        }
                        // Preserve interactive/cancellation admission between
                        // bounded synchronous batches, including final hit checks.
                        await Task.yield()
                    }
                    return result
                }
            }
            var result: [String: String] = [:]
            for try await values in group { result.merge(values) { _, new in new } }
            return result
        }
    }

    private func beginMaintenance() async throws {
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        guard !maintaining else { throw SemanticEmbeddingError.unavailable(.busy) }
        maintaining = true; indexEpoch = UUID(); statusEpoch = UUID()
        let queryTask = actualQuery?.task, indexingTask = indexJob?.task
        invalidateQueries(.superseded); indexingTask?.cancel(); publish()
        if let queryTask { await queryTask.value }
        if let indexingTask { _ = await indexingTask.result }
        if let provider { await provider.unload() }
        cache.removeAll(); cacheOrder.removeAll()
    }
    private func endMaintenance() {
        maintaining = false; publish()
        let waiting = maintenanceWaiters; maintenanceWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
    private func validateScope(_ scope: [PhotoAsset]) throws -> CatalogToken {
        guard !maintaining else { throw SemanticEmbeddingError.unavailable(.busy) }
        guard let catalog, scope.count <= 1_000_000, Set(scope.map(\.id)).count == scope.count else { throw SemanticEmbeddingError.invalidInput }
        for asset in scope {
            guard let current = assets[asset.id] else { throw SemanticEmbeddingError.superseded }
            // The library passes its immutable catalog values. Equal source
            // fields already imply equal normalized fingerprints; avoid doing
            // the same URL normalization twice per photo for every query.
            if current.fileURL == asset.fileURL, current.modifiedAt == asset.modifiedAt,
               current.fileSize == asset.fileSize { continue }
            // Preserve acceptance of differently spelled equivalent file URLs.
            guard Self.source(current) == Self.source(asset) else { throw SemanticEmbeddingError.superseded }
        }
        return catalog
    }
    private func ensureCurrent(_ token: CatalogToken) throws {
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        guard catalog == token else { throw SemanticEmbeddingError.superseded }
    }
    private static func source(_ asset: PhotoAsset) -> AIOriginalSourceFingerprint { AIOriginalSourceFingerprint(fileURL: asset.fileURL, modifiedAt: asset.modifiedAt, fileSize: asset.fileSize) }
    private static func candidate(_ asset: PhotoAsset) -> SemanticIndexCandidate { SemanticIndexCandidate(assetID: asset.id, source: source(asset)) }
    private static func matches(_ generation: SemanticIndexGeneration, model: SemanticInstalledModel) -> Bool { generation.descriptor == model.descriptor && generation.installationFingerprint == model.installationFingerprint }
    private static func sanitized(_ error: Error) -> SemanticEmbeddingError {
        if let value = error as? SemanticEmbeddingError { return value }
        if error is CancellationError { return .cancelled }
        return .providerFailure
    }
    /// Counts only: instrumentation contains no query, source path or pixels.
    func schedulingState() -> (actual: Int, pending: Int, waiters: Int, indexing: Bool) {
        (actualQuery == nil ? 0 : 1, pendingQuery == nil ? 0 : 1,
         (actualQuery?.waiters.count ?? 0) + (pendingQuery?.waiters.count ?? 0), indexJob != nil)
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func publish() {
        if version < .max { version += 1 }
        state = SemanticSearchState(version: version, availability: maintaining ? .unavailable(.busy) : availability,
            indexGenerationID: activeID, indexedCount: counts.indexed, totalCount: counts.total,
            staleCount: counts.stale, missingCount: counts.missing, processedCount: counts.processed,
            isIndexing: indexJob != nil, notice: notice,
            modelDescriptor: availability == .available ? installation?.descriptor : nil,
            installedBytes: availability == .available ? installation?.installedBytes : nil)
        for subscriber in subscribers.values { subscriber.yield(state) }
    }
}

/// Two shared preparation admissions bound concurrent stat batches and the
/// single index preparer together. This starts no decoder workers; raster work
/// still goes exclusively through ImagePreviewPipeline/AdjustedPreviewPipeline.
actor SemanticPreparationAdmission: SemanticImagePreprocessing {
    private let base: any SemanticImagePreprocessing
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var active = 0
    private var waiting: [Waiter] = []
    init(_ base: any SemanticImagePreprocessing) { self.base = base }
    func sourceStamp(source: AIOriginalSourceFingerprint) async throws -> String {
        try await acquire()
        do { let value = try await base.sourceStamp(source: source); release(); return value }
        catch { release(); throw error }
    }
    func sourceStamps(sources: [AIOriginalSourceFingerprint]) async throws -> [String?] {
        guard sources.count <= SemanticSourceStampBatch.maximumCount else { throw SemanticEmbeddingError.invalidInput }
        try Task.checkCancellation()
        if sources.isEmpty { return [] }
        try await acquire()
        do {
            let values = try await base.sourceStamps(sources: sources)
            try Task.checkCancellation()
            release(); return values
        }
        catch { release(); throw error }
    }
    func prepare(source: AIOriginalSourceFingerprint, priority: PreviewPriority) async throws -> SemanticImageInput {
        try await acquire()
        do { let value = try await base.prepare(source: source, priority: priority); release(); return value }
        catch { release(); throw error }
    }
    /// Counts only; tests can prove queued cancellation and actual-return slots.
    func schedulingState() -> (active: Int, waiting: Int) { (active, waiting.count) }
    private func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: SemanticEmbeddingError.cancelled) }
                else if active < 2 { active += 1; continuation.resume() }
                else { waiting.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        if Task.isCancelled { release(); throw SemanticEmbeddingError.cancelled }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: SemanticEmbeddingError.cancelled)
    }
    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().continuation.resume() }
    }
}
