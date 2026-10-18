import Combine
import Foundation
import PicEditCore

/// Owns forms and accepted user commands. Analysis observers may be canceled;
/// admitted persistence tasks are held separately until commit or rollback.
@MainActor
final class PhotoMetadataModel: ObservableObject {
    struct Recovery: Identifiable {
        let id = UUID()
        let context: PhotoMetadataSelectionContext
        let fields: PhotoTextFields
        let proposalID: UUID?
        let message: String
    }
    struct CatalogReview: Identifiable, Sendable {
        let id = UUID()
        let change: MetadataCatalogChangeReceipt
        let reference: MetadataCatalogFileReference
    }
    struct CatalogComparison: Sendable {
        let conflictID: UUID
        let source: PhotoMetadataRecord?
        let destination: PhotoMetadataRecord?
    }
    private struct DraftIntent {
        let context: PhotoMetadataSelectionContext
        let fields: PhotoTextFields
        let generation: UInt64
        let proposalID: UUID?
        let baseConfirmedRevision: Int64
        var version: MetadataRecordVersion
        let admission: CatalogAcceptedWriteAdmission?
    }

    @Published private(set) var context: PhotoMetadataSelectionContext?
    @Published private(set) var record: PhotoMetadataRecord?
    @Published private(set) var manualFields = PhotoTextFields.empty {
        didSet { manualTagEditor.synchronize(manualFields.tags) }
    }
    @Published private(set) var proposalFields = PhotoTextFields.empty {
        didSet { proposalTagEditor.synchronize(proposalFields.tags) }
    }
    // Raw text belongs to the current form, including a trailing empty tag
    // line. Dock groups can unmount their editors without ending that form.
    @Published private(set) var manualTagEditor = MetadataTagEditorState()
    @Published private(set) var proposalTagEditor = MetadataTagEditorState()
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasPendingRetry = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isCheckingAvailability = false
    @Published private(set) var isClosing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var recovery: Recovery?
    @Published private(set) var importReview: MetadataImportReview?
    @Published private(set) var catalogReview: CatalogReview?
    @Published private(set) var catalogComparison: CatalogComparison?
    @Published private(set) var availability: ImageAnalysisAvailability = .unavailable(.unknown)
    @Published var manualSelection = Set(PhotoMetadataField.allCases)
    @Published var proposalSelection: Set<PhotoMetadataField> = [.title, .description, .tags]
    @Published var manualTagPolicy: MetadataTagPolicy = .append
    @Published var proposalTagPolicy: MetadataTagPolicy = .append
    @Published var manualConflictReviewed = false

    private let lifecycle: CatalogLifecycleGate?
    private var startup: CatalogStartupAdmission?
    private let store: any PhotoMetadataStoring
    private let suggestor: any PhotoMetadataSuggesting
    private let currentContext: @MainActor () -> PhotoMetadataSelectionContext?
    private let canModifyLibrary: @MainActor () -> Bool
    private let protection: @MainActor () -> MetadataFileProtectionSnapshot
    private let selectAsset: @MainActor (String) -> Void
    private let coordinatedRecovery: @MainActor () -> Bool
    private let comparisonLoader: (@MainActor (UUID, UUID) async throws -> CatalogMetadataConflictRecords)?
    private let canResolveCatalog: @MainActor () -> Bool
    private let catalogResolver: (@MainActor (MetadataCatalogResolutionOperation) async throws -> MetadataReconciliationResult)?
    private var reviewedConflicts = Set<UUID>()
    private var subscriptions = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var needsLoadResumption = false
    private var availabilityID = UUID()
    private var suggestionTask: Task<Void, Never>?
    private var suggestionID: UUID?
    private var lifecycleID = UUID()
    private var formGeneration: UInt64 = 0
    private var manualTagDraftPresent = false
    private var proposalTagDraftID: UUID?
    private var storeReady = false
    private var lastWriteFailed = false
    private var manualDirty = false
    private var proposalDirty = false
    private var draftIntent: DraftIntent?
    private var draftWriter: Task<Bool, Never>?
    private var writerAssetID: String?
    private var writerProposalID: UUID?
    private var acceptedAction: Task<Bool, Never>?
    private var acceptedRetry: (context: PhotoMetadataSelectionContext?, generation: UInt64,
        operation: @MainActor @Sendable () async throws -> MetadataCommitResult)?
    private var readAction: Task<Void, Never>?
    private var readActionID = UUID()

    init(store: any PhotoMetadataStoring, suggestor: any PhotoMetadataSuggesting, lifecycle: CatalogLifecycleGate? = nil,
         currentContext: @escaping @MainActor () -> PhotoMetadataSelectionContext?,
         canModifyLibrary: @escaping @MainActor () -> Bool,
         protection: @escaping @MainActor () -> MetadataFileProtectionSnapshot,
         selectAsset: @escaping @MainActor (String) -> Void = { _ in },
         canResolveCatalog: @escaping @MainActor () -> Bool = { false },
         coordinatedRecovery: @escaping @MainActor () -> Bool = { false },
         comparisonLoader: (@MainActor (UUID, UUID) async throws -> CatalogMetadataConflictRecords)? = nil,
         catalogResolver: (@MainActor (MetadataCatalogResolutionOperation) async throws -> MetadataReconciliationResult)? = nil) {
        self.lifecycle = lifecycle
        self.store = store; self.suggestor = suggestor; self.currentContext = currentContext
        self.canModifyLibrary = canModifyLibrary; self.protection = protection; self.selectAsset = selectAsset
        self.coordinatedRecovery = coordinatedRecovery; self.comparisonLoader = comparisonLoader
        self.canResolveCatalog = canResolveCatalog; self.catalogResolver = catalogResolver
        synchronizeContext()
        if loadTask == nil { loadRecord() }
    }

    convenience init(store: any PhotoMetadataStoring, suggestor: any PhotoMetadataSuggesting,
                     library: LibraryModel, editor: EditingModel) {
        self.init(store: store, suggestor: suggestor, lifecycle: library.lifecycle,
            currentContext: { library.photoMetadataSelectionContext() }, canModifyLibrary: { library.canModify },
            protection: { library.photoMetadataFileProtection() }, selectAsset: { library.selectedID = $0 },
            canResolveCatalog: { library.canResolvePhotoMetadataCatalogChanges },
            coordinatedRecovery: { library.hasCoordinatedRecovery },
            comparisonLoader: { try await library.inspectCoordinatedMetadataConflict(coordinationID: $0, conflictID: $1) },
            catalogResolver: { try await library.resolvePhotoMetadataCatalogChange($0, alreadyAccepted: true) })
        library.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.synchronizeContext() }
        }.store(in: &subscriptions)
        editor.$isRestoring.merge(with: editor.$isBackingUp, editor.$isClosing, library.$isClosing)
            .sink { [weak self] blocked in if blocked { self?.invalidateAnalysis() } }
            .store(in: &subscriptions)
    }

    deinit { loadTask?.cancel(); suggestionTask?.cancel(); readAction?.cancel() }

    private var canAdmitAction: Bool {
        !isClosing && canModifyLibrary() && !isSaving && !hasPendingRetry && storeReady && recovery == nil
    }
    // A failed autosave leaves the exact raw form visible. Only correction,
    // confirmation or explicit discard of that form may consume it; another
    // form's successful result must never replace these unsaved fields.
    var canManage: Bool { canAdmitAction && !manualDirty && !proposalDirty }
    var hasManualDraft: Bool { record?.manualDraft != nil || manualDirty }
    var canDiscardManualDraft: Bool {
        canAdmitAction && currentMatchesContext() && !proposalDirty && hasManualDraft
    }
    var canUseProposalAsManual: Bool {
        canAdmitAction && currentMatchesContext() && !isLoading && !manualDirty && record?.draft != nil
    }
    var canEditManual: Bool { editable(proposalID: nil) }
    var canEditProposal: Bool {
        guard let draft = record?.draft, draft.state == .pending || draft.state == .edited else { return false }
        return editable(proposalID: draft.id)
    }
    var canSuggest: Bool { canManage && currentMatchesContext() && availability == .available && !isLoading && !isAnalyzing }
    var manualHasConflict: Bool {
        guard let draft = record?.manualDraft, let record else { return false }
        return draft.baseConfirmedRevision != record.confirmedRevision
    }
    var canConfirmManual: Bool {
        canAdmitAction && !proposalDirty && currentMatchesContext() && !isLoading && !manualSelection.isEmpty &&
        (!manualHasConflict || manualConflictReviewed)
    }
    var canConfirmProposal: Bool {
        canAdmitAction && !manualDirty && currentMatchesContext() && !isLoading && !proposalSelection.isEmpty &&
        record?.draft.map { $0.state == .pending || $0.state == .edited } == true
    }
    var canRejectProposal: Bool {
        canAdmitAction && !manualDirty && currentMatchesContext() && record?.draft.map { $0.state == .pending || $0.state == .edited || $0.state == .outdated } == true
    }

    func refreshAvailability() async {
        guard !isCheckingAvailability else { return }
        isCheckingAvailability = true
        let id = UUID(); availabilityID = id
        let value = await suggestor.availability()
        if id == availabilityID && !isClosing { availability = value }
        if id == availabilityID { isCheckingAvailability = false }
    }

    func synchronizeContext() {
        let next = currentContext()
        if let old = context, old != next { invalidateAnalysis() }
        let changedSource = context?.assetID != next?.assetID || context?.source != next?.source
        if changedSource, let old = context, recovery == nil, draftWriter == nil {
            if manualDirty { recovery = Recovery(context: old, fields: manualFields, proposalID: nil,
                message: errorMessage ?? "Der manuelle Entwurf ist noch nicht gesichert.") }
            else if proposalDirty { recovery = Recovery(context: old, fields: proposalFields, proposalID: record?.draft?.id,
                message: errorMessage ?? "Die Entwurfskorrektur ist noch nicht gesichert.") }
        }
        context = next
        if changedSource {
            manualTagEditor = MetadataTagEditorState(); proposalTagEditor = MetadataTagEditorState()
            manualTagDraftPresent = false; proposalTagDraftID = nil
            loadRecord()
        }
        else { objectWillChange.send() }
    }

    func retryLoading() {
        guard !isSaving else { return }
        if recovery == nil, let context {
            if manualDirty { recovery = Recovery(context: context, fields: manualFields, proposalID: nil,
                message: "Der ungesicherte manuelle Entwurf bleibt erhalten.") }
            else if proposalDirty { recovery = Recovery(context: context, fields: proposalFields, proposalID: record?.draft?.id,
                message: "Die ungesicherte Entwurfskorrektur bleibt erhalten.") }
        }
        errorMessage = nil; loadRecord()
    }

    private func loadRecord() {
        guard !isClosing else { needsLoadResumption = true; return }
        loadID = UUID(); let id = loadID
        loadTask?.cancel(); record = nil; storeReady = false; manualConflictReviewed = false
        // These observers outlive the UI event that triggered them. Detached
        // tasks avoid inheriting its short-lived catalog/maintenance admission;
        // repository access acquires its own slot. Keep UI state on MainActor
        // and retain the handles for cancellation and stale-result checks.
        guard let context else {
            isLoading = false
            loadTask = Task.detached { @MainActor [weak self, store] in
                do { try await self?.waitForStartup() }
                catch { self?.errorMessage = Self.message(error); return }
                let state = await store.searchState()
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                if case .unavailable(_, let reason) = state {
                    self.errorMessage = Self.message(reason)
                    if reason == .limitExceeded(.searchSnapshot) { self.storeReady = true }
                } else { self.storeReady = true }
            }
            return
        }
        isLoading = true
        loadTask = Task.detached { @MainActor [weak self, store] in
            do {
                try await self?.waitForStartup()
                let value = try await store.record(assetID: context.assetID)
                guard let self, !Task.isCancelled, self.loadID == id else { return }
                if let current = self.record, current.version.recordRevision > (value?.version.recordRevision ?? 0) {
                    self.storeReady = true; self.isLoading = false; return
                }
                self.record = value; self.storeReady = true; self.isLoading = false
                if !self.manualDirty && !self.proposalDirty && !self.hasPendingRetry && self.recovery == nil { self.lastWriteFailed = false }
                self.manualFields = value?.manualDraft?.fields ?? value?.confirmed ?? .empty
                self.proposalFields = value?.draft?.fields ?? .empty
                self.synchronizeTagDrafts(value)
                self.manualDirty = false; self.proposalDirty = false
                self.errorMessage = nil
            } catch {
                guard let self, !Task.isCancelled, self.loadID == id else { return }
                self.isLoading = false; self.errorMessage = Self.message(error)
            }
        }
    }

    private func editable(proposalID: UUID?) -> Bool {
        guard !isClosing, recovery == nil, !hasPendingRetry, storeReady, !isLoading, acceptedAction == nil,
              let current = currentContext(), current == context, current.canModify, !current.isClosing else { return false }
        if manualDirty && proposalID != nil { return false }
        if proposalDirty && proposalID == nil { return false }
        return writerAssetID == nil || (writerAssetID == current.assetID && writerProposalID == proposalID)
    }

    func editManualFields(_ value: PhotoTextFields) {
        guard canEditManual, let context else { return }
        manualFields = value; manualDirty = true; advanceForm(); invalidateAnalysis()
        enqueueDraft(context: context, fields: value, proposalID: nil)
    }

    func editManualTags(_ text: String) {
        guard canEditManual else { return }
        let tags = manualTagEditor.edit(text)
        guard tags != manualFields.tags else { return }
        var fields = manualFields; fields.tags = tags
        editManualFields(fields)
    }

    func editProposalFields(_ value: PhotoTextFields) {
        guard canEditProposal, let context, let draft = record?.draft else { return }
        proposalFields = value; proposalDirty = true; advanceForm(); invalidateAnalysis()
        enqueueDraft(context: context, fields: value, proposalID: draft.id)
    }

    func editProposalTags(_ text: String) {
        guard canEditProposal else { return }
        let tags = proposalTagEditor.edit(text)
        guard tags != proposalFields.tags else { return }
        var fields = proposalFields; fields.tags = tags
        editProposalFields(fields)
    }

    private func synchronizeTagDrafts(_ value: PhotoMetadataRecord?) {
        if manualTagDraftPresent, value?.manualDraft == nil {
            manualTagEditor = MetadataTagEditorState()
            manualTagEditor.synchronize(manualFields.tags)
        }
        if proposalTagDraftID != value?.draft?.id {
            proposalTagEditor = MetadataTagEditorState()
            proposalTagEditor.synchronize(proposalFields.tags)
        }
        manualTagDraftPresent = value?.manualDraft != nil
        proposalTagDraftID = value?.draft?.id
    }

    private func enqueueDraft(context: PhotoMetadataSelectionContext, fields: PhotoTextFields, proposalID: UUID?) {
        // Admission happens synchronously while the library context authorizes
        // this exact asset. Selection/closing afterwards cannot cancel it.
        guard context == currentContext(), context.canModify, !context.isClosing else { return }
        let admission: CatalogAcceptedWriteAdmission?
        do { admission = try registerMetadataWrite() }
        catch { errorMessage = Self.message(error); return }
        draftIntent = DraftIntent(context: context, fields: fields, generation: formGeneration, proposalID: proposalID,
            baseConfirmedRevision: record?.manualDraft?.baseConfirmedRevision ?? record?.confirmedRevision ?? 0,
            version: record?.version ?? .absent, admission: admission)
        guard draftWriter == nil else { return }
        writerAssetID = context.assetID; writerProposalID = proposalID; updateSaving()
        draftWriter = Task { await self.drainDrafts() }
        updateSaving()
    }

    private func drainDrafts() async -> Bool {
        // One short debounce coalesces typing. It is owned accepted work, not
        // the cancellable analysis observer or the currently selected photo.
        try? await Task.sleep(for: .milliseconds(160))
        var success = true
        while let intent = draftIntent {
            draftIntent = nil
            let header = MetadataCommandHeader(assetID: intent.context.assetID, expectedVersion: intent.version)
            do {
                let result = try await execute(intent.admission) { [store] in
                    if let proposalID = intent.proposalID {
                        return try await store.saveAIDraft(MetadataAIDraftOperation(header: header,
                            mutation: .editExisting(draftID: proposalID, fields: intent.fields)))
                    } else {
                        return try await store.saveManualDraft(MetadataManualDraftOperation(header: header,
                            mutation: .save(fields: intent.fields, baseConfirmedRevision: intent.baseConfirmedRevision)))
                    }
                }
                if let target = result.receipt.affected.first(where: { $0.assetID == intent.context.assetID })?.version,
                   var pending = draftIntent, pending.context.assetID == intent.context.assetID, pending.version == intent.version {
                    // Only chain this controller's own committed draft version;
                    // never silently rebase over a foreign confirmed revision.
                    pending.version = target; draftIntent = pending
                }
                apply(result, context: intent.context, generation: intent.generation)
            } catch {
                let failed = draftIntent ?? intent; draftIntent = nil
                if currentContext()?.assetID != failed.context.assetID || currentContext()?.source != failed.context.source {
                    recovery = Recovery(context: failed.context, fields: failed.fields,
                        proposalID: failed.proposalID, message: Self.message(error))
                }
                lastWriteFailed = true
                errorMessage = Self.message(error); success = false; break
            }
        }
        draftWriter = nil; writerAssetID = nil; writerProposalID = nil; updateSaving()
        return success
    }

    func recoverUnsavedDraft() {
        guard let recovery else { return }
        selectAsset(recovery.context.assetID)
        synchronizeContext()
        let recoveryID = recovery.id
        Task { [weak self] in
            guard let self else { return }
            if let loadTask { await loadTask.value }
            guard self.recovery?.id == recoveryID, self.currentContext()?.assetID == recovery.context.assetID else { return }
            self.recovery = nil
            if recovery.proposalID != nil { self.proposalFields = recovery.fields; self.proposalDirty = true }
            else { self.manualFields = recovery.fields; self.manualDirty = true }
            self.advanceForm()
            self.errorMessage = "Der ungesicherte Entwurf bleibt erhalten. Bitte korrigieren und übernehmen."

        }
    }

    func discardRecovery() { recovery = nil; errorMessage = nil; lastWriteFailed = false }

    func acceptManualFields() {
        guard canConfirmManual, let context else { return }
        if manualDirty {
            let header = MetadataCommandHeader(assetID: context.assetID, expectedVersion: record?.version ?? .absent)
            let values = manualFields, fields = manualSelection, policy = manualTagPolicy
            let reviewed = record?.confirmedRevision ?? 0
            let draft = MetadataManualDraftOperation(header: header,
                mutation: .save(fields: values, baseConfirmedRevision: record?.manualDraft?.baseConfirmedRevision ?? reviewed))
            let confirmationID = UUID()
            accept(context: context) {
                let saved = try await self.store.saveManualDraft(draft)
                guard let target = saved.receipt.affected.first(where: { $0.assetID == context.assetID })?.version else {
                    throw PhotoMetadataError.storageFailure
                }
                return try await self.store.confirm(MetadataConfirmOperation(
                    header: MetadataCommandHeader(id: confirmationID, assetID: context.assetID, expectedVersion: target),
                    values: values, fields: fields, tagPolicy: policy,
                    source: MetadataSourceReference(original: .metadata(context.source)),
                    origin: .manual(expectedManualDraftRevision: target.manualDraftRevision, reviewedConfirmedRevision: reviewed)))
            }
            return
        }
        let operation = MetadataConfirmOperation(header: MetadataCommandHeader(assetID: context.assetID, expectedVersion: record?.version ?? .absent),
            values: manualFields, fields: manualSelection, tagPolicy: manualTagPolicy,
            source: MetadataSourceReference(original: .metadata(context.source)),
            origin: .manual(expectedManualDraftRevision: record?.manualDraft?.revision,
                            reviewedConfirmedRevision: record?.confirmedRevision ?? 0))
        accept(context: context) { try await self.store.confirm(operation) }
    }

    func acceptProposal() {
        guard canConfirmProposal, let context, let record, let draft = record.draft else { return }
        if proposalDirty {
            let edit = MetadataAIDraftOperation(header: MetadataCommandHeader(assetID: context.assetID, expectedVersion: record.version),
                mutation: .editExisting(draftID: draft.id, fields: proposalFields))
            let values = proposalFields, fields = proposalSelection, policy = proposalTagPolicy
            let confirmationID = UUID()
            accept(context: context) {
                let saved = try await self.store.saveAIDraft(edit)
                guard let target = saved.receipt.affected.first(where: { $0.assetID == context.assetID })?.version else {
                    throw PhotoMetadataError.storageFailure
                }
                return try await self.store.confirm(MetadataConfirmOperation(
                    header: MetadataCommandHeader(id: confirmationID, assetID: context.assetID, expectedVersion: target),
                    values: values, fields: fields, tagPolicy: policy, source: draft.source,
                    origin: .proposal(draftID: draft.id, expectedDraftRevision: target.aiDraftRevision)))
            }
            return
        }
        let operation = MetadataConfirmOperation(header: MetadataCommandHeader(assetID: context.assetID, expectedVersion: record.version),
            values: proposalFields, fields: proposalSelection, tagPolicy: proposalTagPolicy, source: draft.source,
            origin: .proposal(draftID: draft.id, expectedDraftRevision: draft.revision))
        accept(context: context) { try await self.store.confirm(operation) }
    }

    func discardProposal() {
        invalidateAnalysis()
        guard canRejectProposal, let context, let record, let draft = record.draft else { return }
        let operation = MetadataDraftStateOperation(header: MetadataCommandHeader(assetID: context.assetID, expectedVersion: record.version),
            draftID: draft.id, expectedDraftRevision: draft.revision)
        accept(context: context) { try await self.store.setDraftState(operation) }
    }

    func discardManualDraft() {
        guard canDiscardManualDraft, let context else { return }
        if record?.manualDraft == nil {
            // The invalid/raw form was never stored. Its explicit discard needs
            // no database revision and must remain possible after validation failure.
            manualFields = record?.confirmed ?? .empty; manualDirty = false
            manualTagEditor = MetadataTagEditorState(); manualTagEditor.synchronize(manualFields.tags)
            lastWriteFailed = false; errorMessage = nil; advanceForm(); invalidateAnalysis()
            return
        }
        let operation = MetadataManualDraftOperation(header: MetadataCommandHeader(assetID: context.assetID, expectedVersion: record?.version ?? .absent), mutation: .discard)
        accept(context: context) { try await self.store.saveManualDraft(operation) }
    }

    func useProposalAsManual() {
        guard canUseProposalAsManual else { return }
        // This explicit action transfers the displayed raw correction, including
        // a recovered/outdated one, into the current asset's manual form. It is
        // never a confirmation or a claim of current model/source provenance.
        let fields = proposalFields
        proposalDirty = false
        editManualFields(fields)
    }

    func suggest(refresh: Bool = false) {
        guard canSuggest, let context else { return }
        invalidateAnalysis()
        let request = PhotoMetadataSuggestionRequest(context: context, lifecycleID: lifecycleID,
            formGeneration: formGeneration, expectedVersion: record?.version ?? .absent,
            rasterPolicy: refresh ? .refreshRaster : .reuseValidated)
        suggestionID = request.id; isAnalyzing = true; errorMessage = nil
        suggestionTask = Task { [weak self, suggestor] in
            do {
                let result = try await suggestor.suggest(request)
                try Task.checkCancellation()
                guard let self else { return }
                guard self.suggestionIsCurrent(request), result.request.id == request.id,
                      result.request.context == request.context,
                      result.source.original == .metadata(request.context.source) else {
                    if self.suggestionID == request.id { self.invalidateAnalysis() }
                    return
                }
                self.suggestionID = nil; self.isAnalyzing = false; self.suggestionTask = nil
                let operation = MetadataAIDraftOperation(header: MetadataCommandHeader(assetID: context.assetID, expectedVersion: request.expectedVersion),
                    mutation: .createSuggested(draftID: UUID(), fields: result.fields, source: result.source))
                self.accept(context: context) { try await self.store.saveAIDraft(operation) }
            } catch {
                guard let self, self.suggestionID == request.id else { return }
                self.suggestionID = nil; self.suggestionTask = nil; self.isAnalyzing = false
                if !(error is CancellationError), (error as? ImageAnalysisError) != .cancelled,
                   (error as? ImageAnalysisError) != .superseded {
                    self.errorMessage = Self.message(error)
                    if case .unavailable(let reason) = error as? ImageAnalysisError { self.availability = .unavailable(reason) }
                }
            }
        }
    }

    func invalidateAnalysis() {
        lifecycleID = UUID(); suggestionID = nil
        suggestionTask?.cancel(); suggestionTask = nil; isAnalyzing = false
    }

    private func suggestionIsCurrent(_ request: PhotoMetadataSuggestionRequest) -> Bool {
        !isClosing && suggestionID == request.id && lifecycleID == request.lifecycleID &&
        formGeneration == request.formGeneration && request.context == currentContext() &&
        request.expectedVersion == (record?.version ?? .absent) && currentMatchesContext() && !isSaving
    }

    private func accept(context: PhotoMetadataSelectionContext?,
                        operation: @escaping @MainActor @Sendable () async throws -> MetadataCommitResult) {
        guard acceptedAction == nil, draftWriter == nil, !hasPendingRetry, !isClosing, recovery == nil, canModifyLibrary() else { return }
        if let context { guard context == currentContext(), context.canModify, !context.isClosing else { return } }
        startAccepted(context: context, generation: formGeneration, operation: operation)
    }

    private func startAccepted(context: PhotoMetadataSelectionContext?, generation: UInt64,
                               operation: @escaping @MainActor @Sendable () async throws -> MetadataCommitResult) {
        let admission: CatalogAcceptedWriteAdmission?
        do { admission = try registerMetadataWrite() }
        catch { errorMessage = Self.message(error); return }
        acceptedAction = Task {
            var success = false
            do {
                let result = try await execute(admission, operation: operation)
                self.notice = "Bildinformationen gespeichert."
                self.apply(result, context: context, generation: generation)
                self.lastWriteFailed = false; self.acceptedRetry = nil; self.hasPendingRetry = false
                self.errorMessage = nil; success = true
            } catch {
                // The frozen closure retains its original UUID and exact
                // payload. Retry never invents a new accepted transaction.
                self.acceptedRetry = (context, generation, operation)
                self.hasPendingRetry = true; self.lastWriteFailed = true
                self.errorMessage = Self.message(error)
            }
            self.acceptedAction = nil; self.updateSaving()
            return success
        }
        updateSaving()
    }

    var canRetryAcceptedWrite: Bool { hasPendingRetry && !isSaving && !isClosing && canModifyLibrary() }
    func retryAcceptedWrite() {
        guard canRetryAcceptedWrite, let retry = acceptedRetry else { return }
        startAccepted(context: retry.context, generation: retry.generation, operation: retry.operation)
    }
    func discardAcceptedWrite() {
        guard !isSaving, hasPendingRetry else { return }
        acceptedRetry = nil; hasPendingRetry = false; lastWriteFailed = false; errorMessage = nil
    }

    private func apply(_ result: MetadataCommitResult, context expected: PhotoMetadataSelectionContext?, generation: UInt64) {
        if case .unavailable(_, let reason) = result.searchState {
            notice = "Gespeichert. Die Textsuche ist derzeit nicht verfügbar: " + Self.message(reason)
        }
        guard let expected, let current = result.currentRecord, context?.assetID == expected.assetID,
              current.assetID == expected.assetID else { return }
        // This result belongs to an already accepted write, not to a cancellable
        // analysis. Rating/filter/closing epochs may change while the same
        // source is displayed; they must not strand its durable revision or
        // dirty form. Actual source/catalog changes still require a fresh load.
        guard matchesRecordSource(context, expected), matchesRecordSource(currentContext(), expected) else {
            if !manualDirty && !proposalDirty { loadRecord() }
            return
        }
        guard current.version.recordRevision >= (record?.version.recordRevision ?? 0) else { return }
        record = current
        guard formGeneration == generation else { return }
        lastWriteFailed = false
        manualFields = current.manualDraft?.fields ?? current.confirmed
        proposalFields = current.draft?.fields ?? .empty
        synchronizeTagDrafts(current)
        manualDirty = false; proposalDirty = false; manualConflictReviewed = false; errorMessage = nil
    }

    private func matchesRecordSource(_ context: PhotoMetadataSelectionContext?, _ expected: PhotoMetadataSelectionContext) -> Bool {
        guard let context else { return false }
        return context.assetID == expected.assetID && context.source == expected.source &&
            context.catalogSessionID == expected.catalogSessionID
    }

    private func currentMatchesContext() -> Bool {
        guard let current = currentContext() else { return false }
        return current == context && current.canModify && !current.isClosing
    }
    private func advanceForm() {
        if formGeneration == .max { lifecycleID = UUID(); formGeneration = 0 } else { formGeneration += 1 }
    }
    private func updateSaving() { isSaving = draftWriter != nil || acceptedAction != nil }

    func beginTermination() {
        needsLoadResumption = needsLoadResumption || isLoading || !storeReady
        isClosing = true; invalidateAnalysis(); loadTask?.cancel(); readAction?.cancel()
        loadTask = nil; importReview = nil; catalogReview = nil; catalogComparison = nil; readActionID = UUID()
    }
    func cancelTermination() {
        isClosing = false
        let previousLoad = loadID
        synchronizeContext()
        if needsLoadResumption && previousLoad == loadID { loadRecord() }
        needsLoadResumption = false
        Task { await refreshAvailability() }
    }
    func drainAcceptedWrites() async -> Bool {
        let drafted = await draftWriter?.value ?? true
        let accepted = await acceptedAction?.value ?? true
        return drafted && accepted && recovery == nil && !hasPendingRetry && !lastWriteFailed && !manualDirty && !proposalDirty
    }

    func finishSaving() async -> Bool {
        let accepted = await drainAcceptedWrites()
        let saved = await store.finishSaving()
        return accepted && saved
    }

    func inspectImport(source: URL) {
        guard canManage else { return }
        readAction?.cancel(); readActionID = UUID(); let id = readActionID
        let protection = protection()
        readAction = Task {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                let review = try await store.prepareImport(source: source, protection: protection)
                guard !Task.isCancelled, readActionID == id, !isClosing else {
                    await store.discardImport(reviewID: review.id); return
                }
                importReview = review
            } catch { if !Task.isCancelled, readActionID == id { errorMessage = Self.message(error) } }
            readAction = nil
        }
    }

    func dismissImport(id: UUID) {
        guard importReview?.id == id else { return }
        importReview = nil
        Task { await store.discardImport(reviewID: id) }
    }

    func confirmImport(id: UUID, decisions: [MetadataImportDecision]) {
        guard canManage, let review = importReview, review.id == id else { return }
        let operation = MetadataImportOperation(reviewID: id, reviewContentSHA256: review.contentSHA256, decisions: decisions)
        importReview = nil
        accept(context: nil) {
            let result = try await self.store.commitImport(operation)
            self.loadRecord()
            return result
        }
    }

    func exportConfirmed(destination: URL) {
        guard canManage else { return }
        let protection = protection()
        let admission: CatalogAcceptedWriteAdmission?
        do { admission = try registerMetadataWrite() }
        catch { errorMessage = Self.message(error); return }
        acceptedAction = Task {
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            var success = false
            do {
                let result = try await execute(admission) { [store] in try await store.exportConfirmed(destination: destination, protection: protection) }
                notice = "\(result.entryCount) bestätigte Bildinformationen exportiert."
                success = true
            } catch { errorMessage = Self.message(error) }
            acceptedAction = nil; updateSaving()
            return success
        }
        updateSaving()
    }

    func inspectCatalogChange(_ change: MetadataCatalogChangeReceipt, reference: MetadataCatalogFileReference) {
        guard !isClosing, !isSaving, !hasPendingRetry, !manualDirty, !proposalDirty,
              canResolveCatalog(), catalogResolver != nil, recovery == nil else { return }
        catalogComparison = nil; reviewedConflicts = []
        catalogReview = CatalogReview(change: change, reference: reference)
    }

    func compareCatalogConflict(reviewID: UUID, conflictID: UUID) {
        guard let review = catalogReview, review.id == reviewID,
              let conflict = review.change.conflicts.first(where: { $0.id == conflictID }) else { return }
        readAction?.cancel(); let id = UUID(); readActionID = id; catalogComparison = nil
        readAction = Task {
            do {
                let old: PhotoMetadataRecord?, new: PhotoMetadataRecord?
                if coordinatedRecovery(), let comparisonLoader {
                    let records = try await comparisonLoader(review.change.changeID, conflictID)
                    guard records.receipt.changeID == review.change.changeID, records.conflict.id == conflictID else { throw PhotoMetadataError.revisionConflict }
                    old = records.source; new = records.destination
                } else {
                    old = try await store.record(assetID: conflict.oldAssetID)
                    new = try await store.record(assetID: conflict.newAssetID)
                }
                guard !Task.isCancelled, !isClosing, readActionID == id, catalogReview?.id == reviewID else { return }
                guard (old?.version ?? .absent) == conflict.sourceVersion,
                      (new?.version ?? .absent) == conflict.destinationVersion else { throw PhotoMetadataError.revisionConflict }
                catalogComparison = CatalogComparison(conflictID: conflictID, source: old, destination: new)
                reviewedConflicts.insert(conflictID)
            } catch { if !Task.isCancelled, readActionID == id { errorMessage = Self.message(error) } }
        }
    }

    func dismissCatalogReview(id: UUID) {
        guard catalogReview?.id == id else { return }
        catalogReview = nil; catalogComparison = nil; reviewedConflicts = []
        readAction?.cancel(); readActionID = UUID()
    }

    func confirmCatalogReview(id: UUID, assignments: Set<UUID>) {
        guard let review = catalogReview, review.id == id, !isClosing, !isSaving, !hasPendingRetry,
              !manualDirty, !proposalDirty, canResolveCatalog(), let resolver = catalogResolver,
              assignments.isSubset(of: reviewedConflicts) else { return }
        let admission: CatalogAcceptedWriteAdmission?
        do { admission = coordinatedRecovery() ? nil : try registerMetadataWrite(domain: .catalog) }
        catch { errorMessage = Self.message(error); return }
        catalogReview = nil; catalogComparison = nil
        acceptedAction = Task {
            let operation = await Task.detached {
                MetadataCatalogResolutionOperation(changeID: review.change.changeID,
                    expectedChangeRevision: review.change.revision, persistedReference: review.reference,
                    decisions: review.change.conflicts.map { conflict in
                        MetadataRelocationResolution(conflictID: conflict.id, sourceVersion: conflict.sourceVersion,
                            destinationVersion: conflict.destinationVersion,
                            action: assignments.contains(conflict.id) ? .assignIfDestinationVacant : .keepSeparate)
                    })
            }.value
            var success = false
            do {
                let result = try await execute(admission) { try await resolver(operation) }
                if case .unavailable(_, let reason) = result.searchState {
                    notice = "Zuordnung abgeschlossen; Textsuche nicht verfügbar: " + Self.message(reason)
                } else { notice = "Bildinformationen ausdrücklich zugeordnet oder getrennt erhalten." }
                lastWriteFailed = false; loadRecord(); success = true
            } catch { lastWriteFailed = true; errorMessage = Self.message(error) }
            acceptedAction = nil; updateSaving()
            return success
        }
        updateSaving()
    }

    private func waitForStartup() async throws {
        if let lifecycle, startup == nil { startup = try await lifecycle.waitForStartup() }
    }
    private func registerMetadataWrite(domain: CatalogWriterDomain = .photoMetadata) throws -> CatalogAcceptedWriteAdmission? {
        guard let lifecycle else { return nil }
        guard let startup else { throw ArtifactContractError.staleEpoch }
        return try lifecycle.registerAcceptedWrite(domain: domain, session: startup)
    }
    private func execute<T: Sendable>(_ admission: CatalogAcceptedWriteAdmission?,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        if let lifecycle, let admission { return try await lifecycle.withAcceptedWrite(admission) { try await operation() } }
        return try await operation()
    }

    static func message(_ error: Error) -> String {
        if let image = error as? ImageAnalysisError { return image.localizedDescription }
        guard let metadata = error as? PhotoMetadataError else { return "Die Bildinformationen konnten nicht verarbeitet werden. Bitte erneut versuchen." }
        switch metadata {
        case .validation(let reason):
            switch reason {
            case .emptyTag: return "Ein Tag besteht nur aus Leerraum. Bitte korrigieren oder entfernen."
            case .emptySuggestion: return "Das Bildmodell hat keinen verwendbaren Textvorschlag geliefert."
            case .invalidLanguage: return "Die Sprachangabe darf nur Buchstaben, Ziffern, Unterstrich und Bindestrich enthalten."
            case .invalidControlCharacter: return "Die Eingabe enthält unzulässige Steuerzeichen."
            case .invalidSource, .invalidProvenance: return "Der Quellen- oder Analysebezug ist nicht gültig. Bitte erneut prüfen."
            case .invalidRevision: return "Die gespeicherte Revision ist ungültig. Die vorhandenen Daten bleiben erhalten."
            case .invalidFieldSelection: return "Wähle mindestens ein Feld zur Übernahme."
            case .invalidDraftTransition: return "Dieser Vorschlag wurde bereits übernommen oder verworfen."
            case .duplicateKey, .unknownField, .malformedJSON: return "Die gewählte Datei enthält keine gültigen begrenzten Bildinformationen."
            case .invalidRelocation: return "Die Ordnerzuordnung ist nicht gültig. Beide Datensätze bleiben erhalten."
            case .duplicateIdentity: return "Die Datei enthält mehrfach zugeordnete Bildkennungen."
            case .invalidIdentifier, .invalidDigest, .invalidDecision: return "Der Metadatenauftrag ist nicht mehr gültig. Bitte erneut prüfen."
            }
        case .limitExceeded(let limit):
            let names: [MetadataLimit: String] = [.titleCharacters: "120 Zeichen für den Titel", .titleBytes: "zulässige Titelgröße",
                .descriptionCharacters: "2000 Zeichen für die Beschreibung", .descriptionBytes: "zulässige Beschreibungsgröße",
                .tagCount: "20 Tags", .tagCharacters: "60 Zeichen je Tag", .tagBytes: "zulässige Taggröße",
                .textFieldsBytes: "zulässige Gesamttextgröße", .languageBytes: "zulässige Größe der Sprachangabe",
                .modelResponse: "zulässige Modellantwortgröße", .searchSnapshot: "zulässige Größe der Textsuche",
                .jsonDocument: "64 MiB für die JSON-Datei", .jsonEntries: "25.000 JSON-Einträge",
                .jsonEntry: "zulässige Größe eines JSON-Eintrags", .jsonDepth: "zulässige Dateiverschachtelung",
                .jsonValues: "zulässige Zahl von Dateiwerten", .detailRecord: "zulässige Datensatzgröße",
                .importReview: "zulässige Importprüfung", .catalogChange: "zulässige Ordnerzuordnung",
                .pageSize: "zulässige Verarbeitungsgröße", .revisionExhausted: "verfügbare Revisionsnummern"]
            return "Grenze überschritten: " + (names[limit] ?? "zulässige Größe") + ". Die Eingabe bleibt erhalten."
        case .unsupportedVersion: return "Diese Metadatendatei verwendet eine nicht unterstützte Version."
        case .corruptStore: return "Die Metadatenbank ist beschädigt. Die vorhandene Datei bleibt erhalten."
        case .recoveryRequired: return "Die Metadatenbank benötigt eine bewusste Wiederherstellung. Die vorhandenen Dateien bleiben erhalten."
        case .readOnly: return "Die Metadatenbank ist schreibgeschützt."
        case .catalogReadOnly: return "Der Bibliothekskatalog ist schreibgeschützt."
        case .closing: return "PicEdit wird beendet; neue Metadatenänderungen sind gesperrt."
        case .revisionConflict: return "Die Bildinformationen wurden inzwischen geändert. Bitte erneut laden und die Eingaben vergleichen."
        case .sourceChanged: return "Die Bildquelle hat sich geändert. Bitte den Ordner aktualisieren und den Entwurf prüfen."
        case .operationIDCollision: return "Die gespeicherte Auftragskennung gehört zu einem anderen Inhalt."
        case .staleCatalog: return "Der Katalogbezug ist nicht mehr aktuell. Bitte erneut laden."
        case .relocationInProgress: return "Für dieses Bild wird eine Ordnerzuordnung abgeschlossen."
        case .catalogConflict: return "Eine Ordnerzuordnung muss ausdrücklich geprüft werden."
        case .reviewMissingOrExpired: return "Die Importprüfung ist nicht mehr gültig. Bitte die Datei erneut auswählen."
        case .importConflict: return "Ein Importkonflikt hat sich inzwischen geändert. Bitte den Import erneut prüfen."
        case .protectedPath: return "Originale und verwaltete Anwendungsdateien dürfen hier nicht ersetzt oder importiert werden."
        case .storageFailure: return "Die Metadatenbank konnte nicht gelesen oder geschrieben werden. Bitte Zugriff und freien Speicher prüfen und erneut versuchen."
        case .exportFailure: return "Der Metadatenexport konnte nicht veröffentlicht werden. Das bisherige Ziel bleibt erhalten."
        case .cancelled: return "Der Metadatenauftrag wurde abgebrochen."
        }
    }
}
