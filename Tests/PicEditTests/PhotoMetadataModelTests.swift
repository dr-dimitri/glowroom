import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Photo metadata forms, explicit confirmation and lifecycle", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct PhotoMetadataModelTests {
    @Test func nilSelectionStillLoadsStoreForExplicitImportExport() async throws {
        let f = fixture(selected: false)
        try await wait { f.model.canManage }
        #expect(!f.model.canConfirmManual)
        #expect(await f.store.searchReads > 0)
    }

    @Test func manualMetadataWorksWithoutVisionAndOnlySelectedFieldsAreConfirmed() async throws {
        let f = fixture()
        await f.suggestor.setUnavailable()
        await f.model.refreshAvailability()
        try await wait { !f.model.isLoading && f.model.canEditManual }
        f.model.editManualFields(PhotoTextFields(title: "Morgensonne", description: "Manuelle Beschreibung", tags: ["Licht"], language: "en"))
        try await wait { !f.model.isSaving }
        #expect(await f.store.confirms.isEmpty)
        f.model.manualSelection = [.title]
        f.model.acceptManualFields()
        try await wait { !f.model.isSaving }
        let command = try #require(await f.store.confirms.first)
        #expect(command.fields == [.title])
        #expect(command.origin == .manual(expectedManualDraftRevision: 1, reviewedConfirmedRevision: 0))
        #expect(f.model.record?.confirmed.title == "Morgensonne")
        #expect(f.model.record?.confirmed.description == "")
        #expect(f.model.record?.confirmed.language == "de_DE")
        #expect(await f.suggestor.requests.isEmpty)
        #expect(await f.model.finishSaving())
    }

    @Test func acceptedDraftForARunsToCompletionAfterSelectionBAndClosing() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.store.setWritesBlocked(true)
        f.model.editManualFields(PhotoTextFields(title: "Nur Bild A"))
        try await wait { await f.store.hasBlockedWrite }
        f.context.value = metadataContext("b", selection: 2)
        f.model.synchronizeContext()
        try await wait { !f.model.isLoading }
        f.model.beginTermination()
        var drained = false
        let draining = Task { let result = await f.model.finishSaving(); drained = true; return result }
        await Task.yield()
        #expect(!drained)
        await f.store.releaseWrite()
        #expect(await draining.value)
        #expect(await f.store.records["a"]?.manualDraft?.fields.title == "Nur Bild A")
        #expect(await f.store.records["b"] == nil)
        #expect(f.model.context?.assetID == "b" && f.model.manualFields.title.isEmpty)
        #expect(await f.store.confirms.isEmpty)
    }

    @Test(arguments: [false, true])
    func acceptedDraftTracksItsRevisionAcrossSameSourceCatalogChanges(proposal: Bool) async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        if proposal { try await prepareProposal(f) }
        await f.store.setWritesBlocked(true)
        let first = PhotoTextFields(title: "Angenommener Entwurf")
        if proposal { f.model.editProposalFields(first) } else { f.model.editManualFields(first) }
        try await wait { await f.store.hasBlockedWrite }
        f.context.value = metadataContext("a", selection: 2, catalog: 2, canModify: false)
        f.model.synchronizeContext()
        await f.store.releaseWrite()
        try await wait { !f.model.isSaving }
        #expect(f.model.record?.version == (await f.store.records["a"]?.version))
        #expect(await f.model.finishSaving())

        f.context.value = metadataContext("a", selection: 3, catalog: 2)
        f.model.synchronizeContext()
        #expect(f.model.canManage)
        let next = PhotoTextFields(title: "Nächster Entwurf")
        if proposal { f.model.editProposalFields(next) } else { f.model.editManualFields(next) }
        try await wait { !f.model.isSaving }
        #expect(f.model.errorMessage == nil)
        if proposal { f.model.acceptProposal() } else { f.model.acceptManualFields() }
        try await wait { !f.model.isSaving }
        #expect(f.model.record?.confirmed.title == next.title)
        #expect(!f.model.hasPendingRetry)
        #expect(await f.model.finishSaving())
    }

    @Test(arguments: [false, true])
    func olderAcceptedDraftAdvancesRevisionWithoutReplacingNewerRawInput(proposal: Bool) async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        if proposal { try await prepareProposal(f) }
        await f.store.setWritesBlocked(true)
        let first = PhotoTextFields(title: "Erster Entwurf")
        if proposal { f.model.editProposalFields(first) } else { f.model.editManualFields(first) }
        try await wait { await f.store.hasBlockedWrite }
        f.context.value = metadataContext("a", selection: 2, catalog: 2)
        f.model.synchronizeContext()
        let latest = PhotoTextFields(title: "Neuere Eingabe")
        if proposal { f.model.editProposalFields(latest) } else { f.model.editManualFields(latest) }
        await f.store.releaseWrite(keepingBlocked: true)
        try await wait {
            let stored = await f.store.records["a"]
            return await f.store.hasBlockedWrite && (proposal ? stored?.draft?.fields : stored?.manualDraft?.fields) == first
        }
        #expect((proposal ? f.model.proposalFields : f.model.manualFields) == latest)
        #expect(f.model.record?.version == (await f.store.records["a"]?.version))
        await f.store.releaseWrite()
        try await wait { !f.model.isSaving }
        #expect((proposal ? f.model.record?.draft?.fields : f.model.record?.manualDraft?.fields) == latest)
        #expect(f.model.errorMessage == nil)
        #expect(await f.model.finishSaving())
    }

    @Test func sourceChangeStillRejectsTheOldAcceptedDraftDisplay() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.store.setWritesBlocked(true)
        f.model.editManualFields(PhotoTextFields(title: "Alte Quelle"))
        try await wait { await f.store.hasBlockedWrite }
        await f.store.setReadsBlocked(true)
        f.context.value = metadataContext("a", selection: 2, modified: 101)
        f.model.synchronizeContext()
        try await wait { await f.store.pendingLoadIDs.count == 1 }
        await f.store.completeLoad(try #require(await f.store.pendingLoadIDs.first), value: metadataRecord("a", title: "Neue Quelle"))
        try await wait { !f.model.isLoading }
        await f.store.releaseWrite()
        try await wait { !f.model.isSaving }
        #expect(f.model.manualFields.title == "Neue Quelle")
        // A source mismatch refreshes the record instead of publishing the old
        // source's receipt into the new form, even when its revision is higher.
        try await wait { await f.store.pendingLoadIDs.count == 1 }
        await f.store.completeLoad(try #require(await f.store.pendingLoadIDs.first), value: metadataRecord("a", title: "Neue Quelle", revision: 2))
        try await wait { !f.model.isLoading }
        #expect(f.model.record?.confirmed.title == "Neue Quelle")
    }

    @Test func acceptedDraftAfterSelectionABAStillCannotReplaceANewerLoadedRevision() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.store.setWritesBlocked(true)
        f.model.editManualFields(PhotoTextFields(title: "Früherer Auftrag für A"))
        try await wait { await f.store.hasBlockedWrite }
        f.context.value = metadataContext("b", selection: 2); f.model.synchronizeContext()
        try await wait { !f.model.isLoading }
        await f.store.setReadsBlocked(true)
        f.context.value = metadataContext("a", selection: 3); f.model.synchronizeContext()
        try await wait { await f.store.pendingLoadIDs.count == 1 }
        await f.store.completeLoad(try #require(await f.store.pendingLoadIDs.first), value: metadataRecord("a", title: "Neuere Revision für A", revision: 9))
        try await wait { !f.model.isLoading }
        await f.store.releaseWrite()
        try await wait { !f.model.isSaving }
        #expect(f.model.record?.version.recordRevision == 9)
        #expect(f.model.manualFields.title == "Neuere Revision für A")
        #expect(await f.model.finishSaving())
    }

    @Test func realLibraryClosingContextDrainsPendingSQLiteDraftWithoutFalseSaveFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Metadata-Quit-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = directory.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let original = photos.appendingPathComponent("synthetic.png")
        try Data("synthetic metadata source".utf8).write(to: original)
        let folder = LibraryFolder(url: photos)
        let asset = PhotoAsset(folderID: folder.id, fileURL: original)
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog", isDirectory: true))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let store = PhotoMetadataRepository(directory: repository.directory)
        let library = LibraryModel(repository: repository, metadataStore: store)
        try await wait { !library.isLoading && !library.isProjecting }
        library.select(asset)
        // Metadata editing is independent of editor storage availability.
        let editor = EditingModel(loader: { throw PhotoMetadataError.storageFailure })
        let model = PhotoMetadataModel(store: store, suggestor: MetadataUISuggestor(), library: library, editor: editor)
        try await wait { model.canEditManual }
        model.editManualFields(PhotoTextFields(title: "Vor dem Beenden angenommen"))
        #expect(model.isSaving)
        model.beginTermination(); library.beginTermination(); editor.beginTermination()
        try await wait { model.context?.isClosing == true }
        let saved = await AppDelegate.finishSaving(catalog: { await library.finishSaving() }, edits: { true },
            metadata: { await model.drainAcceptedWrites() }, finalize: { await model.finishSaving() })
        #expect(saved)
        #expect(try await store.record(assetID: asset.id)?.manualDraft?.fields.title == "Vor dem Beenden angenommen")
        #expect(model.errorMessage == nil)
        library.cancelTermination(); editor.cancelTermination(); model.cancelTermination()
        try await wait { model.canManage }
        #expect(model.recovery == nil)
    }

    @Test func canceledExitRestartsAnInterruptedDetailLoadAndRejectsItsOldReply() async throws {
        let store = MetadataUIStore()
        await store.setReadsBlocked(true)
        let f = fixture(store: store)
        try await wait { await store.pendingLoadIDs.count == 1 }
        let old = try #require(await store.pendingLoadIDs.first)
        f.model.beginTermination()
        f.model.cancelTermination()
        try await wait { await store.pendingLoadIDs.count == 2 }
        let current = try #require(await store.pendingLoadIDs.last)
        let newest = metadataRecord("a", title: "Aktuell", revision: 9)
        await store.completeLoad(current, value: newest)
        try await wait { !f.model.isLoading && f.model.record?.confirmed.title == "Aktuell" }
        await store.completeLoad(old, value: metadataRecord("a", title: "Veraltet", revision: 1))
        await Task.yield()
        #expect(f.model.record?.version.recordRevision == 9)
        #expect(f.model.manualFields.title == "Aktuell")
    }

    @Test func roundTripSelectionRejectsNoncooperativeEarlierLoads() async throws {
        let store = MetadataUIStore()
        await store.setReadsBlocked(true)
        let f = fixture(store: store)
        try await wait { await store.pendingLoadIDs.count == 1 }
        let oldA = try #require(await store.pendingLoadIDs.first)
        f.context.value = metadataContext("b", selection: 2); f.model.synchronizeContext()
        try await wait { await store.pendingLoadIDs.count == 2 }
        let oldB = try #require(await store.pendingLoadIDs.last)
        f.context.value = metadataContext("a", selection: 3); f.model.synchronizeContext()
        try await wait { await store.pendingLoadIDs.count == 3 }
        let current = try #require(await store.pendingLoadIDs.last)
        await store.completeLoad(current, value: metadataRecord("a", title: "Neu A", revision: 8))
        try await wait { !f.model.isLoading }
        await store.completeLoad(oldB, value: metadataRecord("b", title: "Alt B", revision: 6))
        await store.completeLoad(oldA, value: metadataRecord("a", title: "Alt A", revision: 2))
        await Task.yield()
        #expect(f.model.record?.confirmed.title == "Neu A")
        #expect(f.model.record?.version.recordRevision == 8)
    }

    @Test func lateVisionCannotOverwriteManualInputOrCreateASearchableConfirmation() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.model.refreshAvailability()
        f.model.suggest()
        try await wait { await f.suggestor.requests.count == 1 }
        let request = try #require(await f.suggestor.requests.first)
        f.model.editManualFields(PhotoTextFields(title: "Menschliche Eingabe"))
        await f.suggestor.complete(request.id)
        try await wait { !f.model.isSaving }
        #expect(f.model.manualFields.title == "Menschliche Eingabe")
        #expect(await f.store.aiDrafts.isEmpty)
        #expect(await f.store.confirms.isEmpty)
    }

    @Test func selectionSourceAndRestoreEpochInvalidateVisionWithoutCancelingAcceptedWrites() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.model.refreshAvailability()
        for event in 0..<4 {
            f.model.suggest(refresh: event == 3)
            try await wait { await f.suggestor.requests.count == event + 1 }
            let request = try #require(await f.suggestor.requests.last)
            switch event {
            case 0:
                f.context.value = metadataContext("b", selection: 2); f.model.synchronizeContext()
                f.context.value = metadataContext("a", selection: 3); f.model.synchronizeContext()
            case 1:
                f.context.value = metadataContext("a", selection: 4, modified: 101); f.model.synchronizeContext()
            case 2: f.model.invalidateAnalysis() // Restore/maintenance epoch, even if final settings match.
            default: f.model.beginTermination(); f.model.cancelTermination()
            }
            await f.suggestor.complete(request.id)
            try await wait { !f.model.isLoading && !f.model.isAnalyzing }
            #expect(await f.store.aiDrafts.isEmpty)
        }
        #expect(await f.suggestor.requests.last?.rasterPolicy == .refreshRaster)
    }

    @Test func partialProposalConfirmationConsumesExactlyOnceAndKeepsUnselectedFieldsVisible() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.model.refreshAvailability()
        f.model.suggest()
        try await wait { await f.suggestor.requests.count == 1 }
        await f.suggestor.complete(try #require(await f.suggestor.requests.first?.id))
        try await wait { f.model.record?.draft != nil && !f.model.isSaving }
        #expect(f.model.record?.confirmedRevision == 0)
        f.model.proposalSelection = [.title]
        f.model.acceptProposal()
        try await wait { !f.model.isSaving }
        #expect(await f.store.confirms.count == 1)
        #expect(await f.store.confirms.first?.fields == [.title])
        #expect(f.model.record?.draft?.state == .accepted)
        #expect(!f.model.canConfirmProposal)
        #expect(f.model.proposalFields.description == "Sichtbarer synthetischer Inhalt")
        f.model.acceptProposal()
        #expect(await f.store.confirms.count == 1)
    }

    @Test func staleImportActionsAndDismissalCannotConsumeANewerReview() async throws {
        let f = fixture(selected: false)
        try await wait { f.model.canManage }
        f.model.inspectImport(source: URL(fileURLWithPath: "/synthetic/a.json"))
        try await wait { f.model.importReview != nil }
        let old = try #require(f.model.importReview)
        f.model.inspectImport(source: URL(fileURLWithPath: "/synthetic/b.json"))
        try await wait { f.model.importReview?.id != old.id }
        let current = try #require(f.model.importReview)
        f.model.dismissImport(id: old.id)
        f.model.confirmImport(id: old.id, decisions: [])
        #expect(f.model.importReview?.id == current.id)
        #expect(await f.store.imports == 0)
        f.model.confirmImport(id: current.id, decisions: [])
        try await wait { !f.model.isSaving }
        #expect(await f.store.imports == 1)
    }

    @Test func retryRetainsTheOriginalAcceptedUUIDAndPayload() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        f.model.editManualFields(PhotoTextFields(title: "Ein Auftrag"))
        try await wait { !f.model.isSaving }
        await f.store.failNextConfirmation()
        f.model.acceptManualFields()
        try await wait { f.model.hasPendingRetry && !f.model.isSaving }
        let original = try #require(await f.store.confirms.first)
        f.model.retryAcceptedWrite()
        try await wait { !f.model.hasPendingRetry && !f.model.isSaving }
        let retry = try #require(await f.store.confirms.last)
        #expect(original == retry)
        #expect(f.model.record?.confirmedRevision == 1)
        #expect(f.model.errorMessage == nil)
        #expect(await f.model.finishSaving())
    }

    @Test func readOnlyAndClosingRejectNewManualAndVisionCommands() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        f.context.value = metadataContext("a", selection: 2, canModify: false)
        f.model.synchronizeContext()
        f.model.editManualFields(PhotoTextFields(title: "Gesperrt")); f.model.acceptManualFields(); f.model.suggest()
        #expect(await f.store.manualDrafts.isEmpty)
        #expect(await f.suggestor.requests.isEmpty)
        f.context.value = metadataContext("a", selection: 3)
        f.model.synchronizeContext(); f.model.beginTermination()
        f.model.editManualFields(PhotoTextFields(title: "Schließen")); f.model.suggest()
        #expect(await f.store.manualDrafts.isEmpty)
    }

    @Test(arguments: [false, true])
    func failedAutosavePreservesItsRawFormAndBlocksOtherFormActions(manual: Bool) async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.model.refreshAvailability()
        f.model.suggest()
        try await wait { await f.suggestor.requests.count == 1 }
        await f.suggestor.complete(try #require(await f.suggestor.requests.first?.id))
        try await wait { f.model.canEditProposal && !f.model.isSaving }
        let invalid = PhotoTextFields(title: String(repeating: "x", count: 121), description: "Ungesicherter Rohtext")
        if manual { f.model.editManualFields(invalid) } else { f.model.editProposalFields(invalid) }
        try await wait { !f.model.isSaving && f.model.errorMessage != nil }
        #expect((manual ? f.model.manualFields : f.model.proposalFields) == invalid)
        #expect(!f.model.canManage && !f.model.canSuggest)
        #expect(manual ? f.model.canEditManual : f.model.canEditProposal)
        #expect(manual ? !f.model.canEditProposal : !f.model.canEditManual)
        let manualWrites = await f.store.manualDrafts.count
        let aiWrites = await f.store.aiDrafts.count
        if manual {
            #expect(!f.model.canConfirmProposal && !f.model.canRejectProposal)
            f.model.editProposalFields(PhotoTextFields(title: "Fremde Aktion"))
            f.model.acceptProposal(); f.model.discardProposal()
        } else {
            #expect(!f.model.canConfirmManual && !f.model.canDiscardManualDraft)
            f.model.editManualFields(PhotoTextFields(title: "Fremde Aktion"))
            f.model.acceptManualFields(); f.model.discardManualDraft()
        }
        f.model.suggest(refresh: true)
        f.model.inspectImport(source: URL(fileURLWithPath: "/synthetic/foreign.json"))
        #expect(f.model.importReview == nil)
        #expect(await f.suggestor.requests.count == 1)
        #expect(await f.store.manualDrafts.count == manualWrites)
        #expect(await f.store.aiDrafts.count == aiWrites)
        #expect(await f.store.confirms.isEmpty)
        #expect((manual ? f.model.manualFields : f.model.proposalFields) == invalid)
        // Correcting the same raw form remains available and restores all normal actions.
        let corrected = PhotoTextFields(title: "Korrigiert", description: "Geretteter Rohtext")
        if manual { f.model.editManualFields(corrected) } else { f.model.editProposalFields(corrected) }
        try await wait { !f.model.isSaving && f.model.errorMessage == nil }
        #expect((manual ? f.model.manualFields : f.model.proposalFields) == corrected)
        #expect(f.model.canEditManual && f.model.canEditProposal && f.model.canManage)
        if manual { f.model.acceptManualFields() } else { f.model.acceptProposal() }
        try await wait { !f.model.isSaving }
        #expect(f.model.record?.confirmed.title == "Korrigiert")
        #expect(await f.model.finishSaving())
    }

    @Test(arguments: [false, true])
    func failedAutosaveCanBeExplicitlyDiscardedWithoutBlockingCorrection(manual: Bool) async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.model.refreshAvailability(); f.model.suggest()
        try await wait { await f.suggestor.requests.count == 1 }
        await f.suggestor.complete(try #require(await f.suggestor.requests.first?.id))
        try await wait { f.model.canEditProposal && !f.model.isSaving }
        let invalid = PhotoTextFields(title: String(repeating: "x", count: 121))
        if manual { f.model.editManualFields(invalid) } else { f.model.editProposalFields(invalid) }
        try await wait { !f.model.isSaving && f.model.errorMessage != nil }
        if manual {
            #expect(f.model.hasManualDraft && f.model.canDiscardManualDraft)
            f.model.discardManualDraft()
        } else {
            #expect(f.model.canRejectProposal)
            f.model.discardProposal()
        }
        try await wait { !f.model.isSaving && f.model.canManage }
        #expect(f.model.canEditManual)
        #expect((manual ? f.model.manualFields : f.model.proposalFields).title != invalid.title)
        #expect(await f.model.finishSaving())
    }

    @Test(arguments: [MetadataDraftState.pending, .edited, .accepted, .rejected, .outdated])
    func relocationDetailIncludesAllFieldsAndBothDraftTypes(state: MetadataDraftState) {
        let confirmed = PhotoTextFields(title: "Bestätigt", description: "Bestätigte Beschreibung", tags: ["Bestätigtes Tag"], language: "fr")
        let manual = PhotoTextFields(title: "Manuell", description: "Manueller Rohtext", tags: ["Manuelles Tag"], language: "en")
        let proposed = PhotoTextFields(title: "KI", description: "KI-Beschreibung", tags: ["KI-Tag"], language: "de_DE")
        let manualDraft = PhotoMetadataManualDraft(revision: 2, baseConfirmedRevision: 0, fields: manual, modifiedAt: Date())
        let aiDraft = PhotoMetadataDraft(id: UUID(), revision: 2, baseConfirmedRevision: 0, fields: proposed,
            source: MetadataSourceReference(original: .metadata(metadataContext("a").source)), state: state,
            createdAt: Date(), modifiedAt: Date())
        let source = PhotoMetadataRecord(assetID: "a",
            version: MetadataRecordVersion(recordRevision: 4, aiDraftRevision: 2, manualDraftRevision: 2),
            confirmed: .empty, confirmedProvenance: MetadataConfirmedProvenance(), draft: aiDraft,
            manualDraft: manualDraft, isOrphaned: true, sourceChanged: true)
        let sourceSections = MetadataCatalogRecordDetails.sections(for: source)
        #expect(sourceSections.map(\.id) == [.manualDraft, .aiDraft], "Draft-only source cannot look empty")
        #expect(sourceSections.first?.fields == manual)
        #expect(sourceSections.last?.fields == proposed)
        #expect(sourceSections.allSatisfy { !$0.heading.isEmpty && !$0.status.isEmpty })
        let target = PhotoMetadataRecord(assetID: "b", version: MetadataRecordVersion(recordRevision: 8, confirmedRevision: 1),
            confirmed: confirmed, confirmedProvenance: MetadataConfirmedProvenance(), draft: aiDraft,
            manualDraft: manualDraft, isOrphaned: false, sourceChanged: false)
        let targetSections = MetadataCatalogRecordDetails.sections(for: target)
        #expect(targetSections.map(\.id) == [.confirmed, .manualDraft, .aiDraft])
        #expect(targetSections.map(\.fields) == [confirmed, manual, proposed])
        #expect(MetadataCatalogRecordDetails.sections(for: nil).isEmpty)
    }

    @Test func recoveredOutdatedRawProposalCanBeExplicitlyTransferredToManualWithoutConfirmation() async throws {
        let f = fixture()
        try await wait { f.model.canEditManual }
        await f.model.refreshAvailability(); f.model.suggest()
        try await wait { await f.suggestor.requests.count == 1 }
        await f.suggestor.complete(try #require(await f.suggestor.requests.first?.id))
        try await wait { f.model.canEditProposal && !f.model.isSaving }
        let raw = PhotoTextFields(title: String(repeating: "x", count: 121), description: "Meine ungesicherte KI-Korrektur", tags: ["Rohtext"])
        f.model.editProposalFields(raw)
        try await wait { !f.model.isSaving && f.model.errorMessage != nil }
        let draftID = try #require(f.model.record?.draft?.id)
        await f.store.markDraftOutdated(assetID: "a")
        f.context.value = metadataContext("a", selection: 2, modified: 101)
        f.model.synchronizeContext()
        try await wait { !f.model.isLoading && f.model.record?.draft?.state == .outdated }
        #expect(f.model.recovery?.proposalID == draftID)
        f.model.recoverUnsavedDraft()
        try await wait { f.model.recovery == nil }
        #expect(f.model.proposalFields == raw)
        #expect(!f.model.canEditProposal && !f.model.canEditManual)
        #expect(f.model.canUseProposalAsManual)
        f.model.useProposalAsManual()
        #expect(f.model.context?.source.modifiedAt == Date(timeIntervalSince1970: 101))
        #expect(f.model.manualFields == raw)
        try await wait { !f.model.isSaving }
        #expect(f.model.canEditManual, "The invalid transferred text remains correctable in the manual form")
        #expect(await f.store.confirms.isEmpty)
        let corrected = PhotoTextFields(title: "Bewusst manuell gerettet", description: raw.description, tags: raw.tags)
        f.model.editManualFields(corrected)
        try await wait { !f.model.isSaving && f.model.errorMessage == nil }
        #expect(f.model.record?.manualDraft?.fields == corrected)
        #expect(f.model.record?.draft?.id == draftID && f.model.record?.draft?.state == .outdated)
        #expect(await f.store.confirms.isEmpty)
        #expect(await f.model.finishSaving())
    }

    @Test func admittedMetadataDraftDrainsBeforeSharedMaintenanceEvenAfterClosing() async throws {
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let f = fixture(lifecycle: gate)
        try await wait { f.model.canEditManual }
        await f.store.setWritesBlocked(true)
        f.model.editManualFields(PhotoTextFields(title: "Angenommen"))
        var granted = false
        let maintenance = Task {
            let admission = try await gate.beginMaintenance(.backup(UUID()))
            granted = true
            return admission
        }
        try await wait { await f.store.hasBlockedWrite }
        #expect(!granted)
        f.model.beginTermination()
        await f.store.releaseWrite()
        #expect(await f.model.finishSaving())
        let admission = try await maintenance.value
        #expect(granted)
        #expect(await f.store.records["a"]?.manualDraft?.fields.title == "Angenommen")
        try await gate.finishMaintenance(admission)
    }

    @Test func maintenanceRejectsNewMetadataDraftBeforeTaskAndPreservesRawCorrection() async throws {
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let f = fixture(lifecycle: gate)
        try await wait { f.model.canEditManual }
        let admission = try await gate.beginMaintenance(.backup(UUID()))
        let fields = PhotoTextFields(title: "Noch nicht angenommen")
        f.model.editManualFields(fields)
        #expect(!f.model.isSaving && f.model.errorMessage != nil)
        #expect(f.model.manualFields == fields)
        #expect(await f.store.manualDrafts.isEmpty)
        try await gate.finishMaintenance(admission)
        f.model.editManualFields(fields)
        try await wait { !f.model.isSaving }
        #expect(await f.store.manualDrafts.count == 1)
        #expect(await f.store.records["a"]?.manualDraft?.fields == fields)
    }

    private func prepareProposal(_ f: MetadataUIFixture) async throws {
        await f.model.refreshAvailability()
        f.model.suggest()
        try await wait { await f.suggestor.requests.count == 1 }
        await f.suggestor.complete(try #require(await f.suggestor.requests.first?.id))
        try await wait { f.model.canEditProposal && !f.model.isSaving }
    }

    private func fixture(store: MetadataUIStore = MetadataUIStore(), selected: Bool = true, lifecycle: CatalogLifecycleGate? = nil) -> MetadataUIFixture {
        let context = MetadataUIContext(value: selected ? metadataContext("a") : nil)
        let suggestor = MetadataUISuggestor()
        let model = PhotoMetadataModel(store: store, suggestor: suggestor, lifecycle: lifecycle, currentContext: { context.value },
            canModifyLibrary: { context.value?.canModify ?? true },
            protection: { MetadataFileProtectionSnapshot(originalURLs: [], managedFileURLs: [], managedDirectoryURLs: []) },
            selectAsset: { if context.value?.assetID != $0 { context.value = metadataContext($0, selection: 100) } })
        return MetadataUIFixture(model: model, store: store, suggestor: suggestor, context: context)
    }
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw MetadataUITestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum MetadataUITestError: Error { case timeout }
@MainActor private struct MetadataUIFixture {
    let model: PhotoMetadataModel; let store: MetadataUIStore; let suggestor: MetadataUISuggestor; let context: MetadataUIContext
}
@MainActor private final class MetadataUIContext {
    var value: PhotoMetadataSelectionContext?
    init(value: PhotoMetadataSelectionContext?) { self.value = value }
}
private func metadataContext(_ id: String, selection: UInt64 = 1, modified: TimeInterval = 100, catalog: Int = 1, canModify: Bool = true) -> PhotoMetadataSelectionContext {
    PhotoMetadataSelectionContext(assetID: id,
        source: AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/synthetic/\(id).png"), modifiedAt: Date(timeIntervalSince1970: modified), fileSize: 10),
        selectionSessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, selectionGeneration: selection,
        catalogSessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, catalogGeneration: catalog,
        canModify: canModify, isClosing: false)
}
private func metadataRecord(_ id: String, title: String = "", revision: Int64 = 0) -> PhotoMetadataRecord {
    PhotoMetadataRecord(assetID: id, version: MetadataRecordVersion(recordRevision: revision, confirmedRevision: revision),
        confirmed: PhotoTextFields(title: title), confirmedProvenance: MetadataConfirmedProvenance(), isOrphaned: false, sourceChanged: false)
}

private actor MetadataUISuggestor: PhotoMetadataSuggesting {
    private(set) var requests: [PhotoMetadataSuggestionRequest] = []
    private var pending: [UUID: CheckedContinuation<PhotoMetadataSuggestionResult, Error>] = [:]
    private var available = true
    func setUnavailable() { available = false }
    func availability() -> ImageAnalysisAvailability { available ? .available : .unavailable(.sdkUnavailable) }
    func suggest(_ request: PhotoMetadataSuggestionRequest) async throws -> PhotoMetadataSuggestionResult {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[request.id] = $0 }
    }
    func complete(_ id: UUID) {
        guard let continuation = pending.removeValue(forKey: id), let request = requests.first(where: { $0.id == id }) else { return }
        let source = MetadataSourceFingerprint.metadata(request.context.source)
        let raster = MetadataRasterIdentity(sha256: String(repeating: "a", count: 64), pixelWidth: 16, pixelHeight: 16, byteCount: 1_024,
            colorProfile: "sRGB", orientation: "up", preprocessingVersion: 1)
        let provenance = MetadataAnalysisProvenance(providerID: "synthetic-vision", modelID: "synthetic", analyzedAt: Date(), source: source,
            raster: raster, analysisTaskVersion: 1, analysisSchemaVersion: 1, metadataPromptVersion: 1, metadataSchemaVersion: 1)
        continuation.resume(returning: PhotoMetadataSuggestionResult(request: request,
            fields: PhotoTextFields(title: "Modelltitel", description: "Sichtbarer synthetischer Inhalt", tags: ["Synthetisch"]),
            source: MetadataSourceReference(original: source, analyzedRaster: provenance)))
    }
}

private actor MetadataUIStore: PhotoMetadataStoring {
    private(set) var records: [String: PhotoMetadataRecord] = [:]
    private(set) var manualDrafts: [MetadataManualDraftOperation] = []
    private(set) var aiDrafts: [MetadataAIDraftOperation] = []
    private(set) var confirms: [MetadataConfirmOperation] = []
    private(set) var imports = 0
    private(set) var searchReads = 0
    private var readsBlocked = false
    private var writesBlocked = false
    private var confirmationFails = false
    private var nextRead = 0
    private var loads: [Int: CheckedContinuation<PhotoMetadataRecord?, Error>] = [:]
    private var blockedWrite: CheckedContinuation<Void, Never>?
    var pendingLoadIDs: [Int] { loads.keys.sorted() }
    var hasBlockedWrite: Bool { blockedWrite != nil }
    func setReadsBlocked(_ value: Bool) { readsBlocked = value }
    func setWritesBlocked(_ value: Bool) { writesBlocked = value }
    func failNextConfirmation() { confirmationFails = true }
    func completeLoad(_ id: Int, value: PhotoMetadataRecord?) { loads.removeValue(forKey: id)?.resume(returning: value) }
    func releaseWrite(keepingBlocked: Bool = false) { writesBlocked = keepingBlocked; blockedWrite?.resume(); blockedWrite = nil }
    func markDraftOutdated(assetID: String) {
        guard let old = records[assetID], let draft = old.draft else { return }
        let v = old.version
        records[assetID] = PhotoMetadataRecord(assetID: old.assetID,
            version: MetadataRecordVersion(recordRevision: v.recordRevision + 1, confirmedRevision: v.confirmedRevision,
                aiDraftRevision: v.aiDraftRevision + 1, manualDraftRevision: v.manualDraftRevision),
            confirmed: old.confirmed, confirmedProvenance: old.confirmedProvenance,
            draft: PhotoMetadataDraft(id: draft.id, revision: v.aiDraftRevision + 1, baseConfirmedRevision: draft.baseConfirmedRevision,
                fields: draft.fields, source: draft.source, state: .outdated, createdAt: draft.createdAt, modifiedAt: Date()),
            manualDraft: old.manualDraft, isOrphaned: false, sourceChanged: true)
    }
    func searchState() -> PhotoMetadataSearchState { searchReads += 1; return .available(.empty) }
    func updates() -> AsyncStream<PhotoMetadataSearchState> { AsyncStream { $0.finish() } }
    func record(assetID: String) async throws -> PhotoMetadataRecord? {
        nextRead += 1
        if readsBlocked { let id = nextRead; return try await withCheckedThrowingContinuation { loads[id] = $0 } }
        return records[assetID]
    }
    private func base(_ header: MetadataCommandHeader) throws -> PhotoMetadataRecord {
        let value = records[header.assetID] ?? metadataRecord(header.assetID)
        guard value.version == header.expectedVersion else { throw PhotoMetadataError.revisionConflict }
        return value
    }
    private func result(_ header: MetadataCommandHeader, _ record: PhotoMetadataRecord) -> MetadataCommitResult {
        records[header.assetID] = record
        return MetadataCommitResult(receipt: MetadataWriteReceipt(operationID: header.id, payloadSHA256: String(repeating: "b", count: 64), committedAt: Date(),
            affected: [MetadataAffectedRecord(assetID: record.assetID, version: record.version)], disposition: .applied), currentRecord: record, searchState: .available(.empty))
    }
    func saveManualDraft(_ operation: MetadataManualDraftOperation) async throws -> MetadataCommitResult {
        manualDrafts.append(operation)
        if writesBlocked { await withCheckedContinuation { blockedWrite = $0 } }
        let old = try base(operation.header), v = old.version
        let version = MetadataRecordVersion(recordRevision: v.recordRevision + 1, confirmedRevision: v.confirmedRevision,
            aiDraftRevision: v.aiDraftRevision, manualDraftRevision: v.manualDraftRevision + 1)
        let draft: PhotoMetadataManualDraft?
        switch operation.mutation {
        case .discard: draft = nil
        case .save(let fields, let base): draft = PhotoMetadataManualDraft(revision: version.manualDraftRevision,
            baseConfirmedRevision: base, fields: try PhotoTextNormalization.normalize(fields), modifiedAt: Date())
        }
        return result(operation.header, PhotoMetadataRecord(assetID: old.assetID, version: version, confirmed: old.confirmed,
            confirmedProvenance: old.confirmedProvenance, draft: old.draft, manualDraft: draft, isOrphaned: false, sourceChanged: false))
    }
    func saveAIDraft(_ operation: MetadataAIDraftOperation) async throws -> MetadataCommitResult {
        aiDrafts.append(operation)
        if writesBlocked { await withCheckedContinuation { blockedWrite = $0 } }
        let old = try base(operation.header), v = old.version
        let version = MetadataRecordVersion(recordRevision: v.recordRevision + 1, confirmedRevision: v.confirmedRevision,
            aiDraftRevision: v.aiDraftRevision + 1, manualDraftRevision: v.manualDraftRevision)
        let draft: PhotoMetadataDraft
        switch operation.mutation {
        case .createSuggested(let id, let fields, let source):
            draft = PhotoMetadataDraft(id: id, revision: version.aiDraftRevision, baseConfirmedRevision: v.confirmedRevision,
                fields: try PhotoTextNormalization.normalize(fields), source: source, state: .pending, createdAt: Date(), modifiedAt: Date())
        case .editExisting(let id, let fields):
            guard let previous = old.draft, previous.id == id else { throw PhotoMetadataError.revisionConflict }
            draft = PhotoMetadataDraft(id: id, revision: version.aiDraftRevision, baseConfirmedRevision: previous.baseConfirmedRevision,
                fields: try PhotoTextNormalization.normalize(fields), source: previous.source, state: .edited, createdAt: previous.createdAt, modifiedAt: Date(), editedFields: [.title])
        }
        return result(operation.header, PhotoMetadataRecord(assetID: old.assetID, version: version, confirmed: old.confirmed,
            confirmedProvenance: old.confirmedProvenance, draft: draft, manualDraft: old.manualDraft, isOrphaned: false, sourceChanged: false))
    }
    func confirm(_ operation: MetadataConfirmOperation) throws -> MetadataCommitResult {
        confirms.append(operation)
        if confirmationFails { confirmationFails = false; throw PhotoMetadataError.storageFailure }
        let old = try base(operation.header), v = old.version
        var confirmed = old.confirmed
        for field in operation.fields {
            switch field {
            case .title: confirmed.title = operation.values.title
            case .description: confirmed.description = operation.values.description
            case .tags: confirmed.tags = try PhotoTextNormalization.mergingTags(existing: confirmed.tags, incoming: operation.values.tags, policy: operation.tagPolicy)
            case .language: confirmed.language = operation.values.language
            }
        }
        let draft = old.draft.map { PhotoMetadataDraft(id: $0.id, revision: $0.revision, baseConfirmedRevision: $0.baseConfirmedRevision,
            fields: $0.fields, source: $0.source, state: .accepted, createdAt: $0.createdAt, modifiedAt: Date(), appliedFields: operation.fields) }
        let version = MetadataRecordVersion(recordRevision: v.recordRevision + 1, confirmedRevision: v.confirmedRevision + 1,
            aiDraftRevision: v.aiDraftRevision, manualDraftRevision: v.manualDraftRevision)
        return result(operation.header, PhotoMetadataRecord(assetID: old.assetID, version: version, confirmed: confirmed, confirmedAt: Date(),
            confirmedSource: operation.source, confirmedProvenance: old.confirmedProvenance, draft: draft, isOrphaned: false, sourceChanged: false))
    }
    func setDraftState(_ operation: MetadataDraftStateOperation) throws -> MetadataCommitResult {
        let old = try base(operation.header), v = old.version
        guard let draft = old.draft, draft.id == operation.draftID, draft.revision == operation.expectedDraftRevision else {
            throw PhotoMetadataError.revisionConflict
        }
        let rejected = PhotoMetadataDraft(id: draft.id, revision: v.aiDraftRevision + 1, baseConfirmedRevision: draft.baseConfirmedRevision,
            fields: draft.fields, source: draft.source, state: .rejected, createdAt: draft.createdAt, modifiedAt: Date())
        return result(operation.header, PhotoMetadataRecord(assetID: old.assetID,
            version: MetadataRecordVersion(recordRevision: v.recordRevision + 1, confirmedRevision: v.confirmedRevision,
                aiDraftRevision: v.aiDraftRevision + 1, manualDraftRevision: v.manualDraftRevision),
            confirmed: old.confirmed, confirmedProvenance: old.confirmedProvenance, draft: rejected,
            manualDraft: old.manualDraft, isOrphaned: false, sourceChanged: false))
    }
    func reconcile(_ snapshot: MetadataCatalogSnapshot) -> MetadataReconciliationResult { MetadataReconciliationResult(searchState: .available(.empty), changes: []) }
    func stageCatalogChange(_ change: MetadataCatalogChange) throws -> MetadataCatalogChangeReceipt { throw PhotoMetadataError.cancelled }
    func recoverCatalogChanges(persistedCatalog: MetadataCatalogSnapshot) -> MetadataReconciliationResult { MetadataReconciliationResult(searchState: .available(.empty), changes: []) }
    func completeCatalogChange(id: UUID, persistedCatalog: MetadataCatalogSnapshot) -> MetadataReconciliationResult { MetadataReconciliationResult(searchState: .available(.empty), changes: []) }
    func resolveCatalogChange(_ operation: MetadataCatalogResolutionOperation) throws -> MetadataReconciliationResult { throw PhotoMetadataError.cancelled }
    func prepareImport(source: URL, protection: MetadataFileProtectionSnapshot) -> MetadataImportReview {
        MetadataImportReview(id: UUID(), sourceURL: source, exportID: UUID(), contentSHA256: String(repeating: "c", count: 64),
            sourceByteCount: 100, entryCount: 1, missingCount: 1, unassignedCount: 1, conflicts: [])
    }
    func discardImport(reviewID: UUID) {}
    func commitImport(_ operation: MetadataImportOperation) -> MetadataCommitResult {
        imports += 1
        return MetadataCommitResult(receipt: MetadataWriteReceipt(operationID: operation.id, payloadSHA256: String(repeating: "c", count: 64),
            committedAt: Date(), affected: [], disposition: .applied), searchState: .available(.empty))
    }
    func exportConfirmed(destination: URL, protection: MetadataFileProtectionSnapshot) throws -> MetadataExportResult { throw PhotoMetadataError.cancelled }
    func finishSaving() -> Bool { true }
}
