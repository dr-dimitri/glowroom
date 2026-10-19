import CryptoKit
import Foundation

public enum CatalogCoordinationCheckpoint: Sendable {
    case preparedJournal, editingPrepared, metadataPrepared, armedJournal
    case editingCommitted, catalogPublished, metadataCompleted, completedJournal
}

/// Serializes whole dependent operations across actor awaits. Each native file
/// lock and each SQL transaction has ended before another participant is called.
public actor JointCatalogCoordinator: CatalogMutationCoordinating {
    private let repository: CatalogRepository
    private let editing: any CoordinatedEditingStoring
    private let metadata: (any CoordinatedPhotoMetadataStoring)?
    private let gate: CatalogLifecycleGate
    private let checkpoint: @Sendable (CatalogCoordinationCheckpoint) throws -> Void
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var preparations: [UUID: CatalogParticipantPreparation] = [:]
    private var armedCapabilities: [UUID: ArmedCatalogCoordination] = [:]
    private var maintenanceByID: [UUID: CatalogMaintenanceAdmission] = [:]
    private let sessionID = UUID()
    private var generation = 0
    private var initializationFailures: [CatalogParticipantKind: String] = [:]

    public init(repository: CatalogRepository, editing: any CoordinatedEditingStoring,
                metadata: (any CoordinatedPhotoMetadataStoring)? = nil, gate: CatalogLifecycleGate,
                checkpoint: @escaping @Sendable (CatalogCoordinationCheckpoint) throws -> Void = { _ in }) {
        self.repository = repository; self.editing = editing; self.metadata = metadata
        self.gate = gate; self.checkpoint = checkpoint
    }
    private func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    private func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func prepare(catalog: PreparedLibraryCatalog, expected: MetadataCatalogFileReference,
                        editing plan: VerifiedAssetRemap?, metadata change: MetadataCatalogChange?,
                        maintenance: CatalogMaintenanceAdmission) async throws -> CatalogParticipantPreparation {
        await enter(); defer { leave() }
        return try await gate.withMaintenance(maintenance) {
            try await self.prepareInside(catalog: catalog, expected: expected, plan: plan, change: change, maintenance: maintenance)
        }
    }
    private func prepareInside(catalog: PreparedLibraryCatalog, expected: MetadataCatalogFileReference,
                               plan: VerifiedAssetRemap?, change: MetadataCatalogChange?,
                               maintenance: CatalogMaintenanceAdmission) async throws -> CatalogParticipantPreparation {
        let before = try repository.loadStored()
        guard before.reference == expected else { throw CatalogCoordinationError.externallyModifiedCatalog }
        if let plan { try validateCatalogMapping(plan.proposal, before: before.catalog, after: catalog.catalog) }
        else if let change {
            let current = try await editing.loadState()
            for id in Set(change.relocations.flatMap { [$0.oldAssetID, $0.newAssetID] }) {
                guard current.byAsset[id] == nil, try await editing.variants(for: id).isEmpty else {
                    throw CatalogCoordinationError.requiredParticipantMissing(.editing)
                }
            }
        }
        let rootID = try repository.coordinationRootIdentity()
        guard let id = plan?.proposal.operationID.rawValue ?? change?.id,
              change == nil || change?.id == id else { throw CatalogCoordinationError.invalidCapability }
        let identity = CatalogPreparedPayloadIdentity(operationID: id, rootOwnerID: rootID, before: expected, after: catalog.reference)
        var descriptors: [CatalogParticipantCommandDescriptor] = []
        var editingBytes: Data?, metadataBytes: Data?
        if let plan {
            guard plan.proposal.catalog == identity else { throw CatalogCoordinationError.originalRequestMismatch(.editing) }
            let store = try await editing.participantStoreIdentity()
            guard store.kind == .editing else { throw CatalogCoordinationError.participantIdentityMismatch(.editing) }
            let bytes = try EditingContractJSON.encoder().encode(plan.proposal)
            guard bytes.count <= EditSettings.maximumEncodedBytes else { throw ArtifactContractError.limitExceeded }
            editingBytes = bytes
            descriptors.append(.init(store: store, operationID: id, requestSchemaVersion: 1,
                requestSHA256: try digest(bytes), canonicalByteCount: Int64(bytes.count)))
        }
        if let change {
            guard let metadata else { throw CatalogCoordinationError.requiredParticipantMissing(.photoMetadata) }
            guard change.before == expected, change.after == catalog.reference else {
                throw CatalogCoordinationError.originalRequestMismatch(.photoMetadata)
            }
            let store = try await metadata.participantStoreIdentity()
            guard store.kind == .photoMetadata else { throw CatalogCoordinationError.participantIdentityMismatch(.photoMetadata) }
            let bytes = try PhotoMetadataInternalCodec.encode(change)
            guard bytes.count <= 67_108_864 else { throw ArtifactContractError.limitExceeded }
            metadataBytes = bytes
            descriptors.append(.init(store: store, operationID: id, requestSchemaVersion: 1,
                requestSHA256: try ArtifactDigest(sha256: PhotoMetadataInternalCodec.digest(kind: "catalogChange", payload: change)),
                canonicalByteCount: Int64(bytes.count)))
        }
        descriptors.sort { $0.store.kind.rawValue < $1.store.kind.rawValue }
        let body = CatalogCoordinationRequestBody(operationID: id, catalog: identity, requiredParticipants: descriptors)
        let value = CatalogCoordinationJournalValue(body: body, requestSHA256: try digest(EditingContractJSON.encoder().encode(body)),
            revision: 1, phase: .prepared, disposition: .active)
        try gate.requireDurableCompletion(maintenance, operationID: id)
        maintenanceByID[id] = maintenance
        // Keep the fence even on an ambiguous disk error; no participant mutates
        // before the complete original commands and prepared journal are durable.
        _ = try repository.coordinationFiles.create(value, prepared: catalog, editing: editingBytes, metadata: metadataBytes)
        let journal = validated(value)
        let preparation = CatalogParticipantPreparation(journal: journal, nonce: UUID())
        preparations[id] = preparation
        try checkpoint(.preparedJournal)
        if let plan { _ = try await editing.prepareAssetRemap(plan, preparingBy: preparation); try checkpoint(.editingPrepared) }
        if let change, let metadata {
            _ = try await metadata.stageCoordinatedCatalogChange(change, preparingBy: preparation)
            try checkpoint(.metadataPrepared)
        }
        return preparation
    }

    public func arm(_ prepared: CatalogParticipantPreparation) async throws -> ArmedCatalogCoordination {
        await enter(); defer { leave() }
        let id = prepared.journal.value.body.operationID
        guard preparations[id] === prepared, let maintenance = maintenanceByID[id] else { throw CatalogCoordinationError.invalidCapability }
        return try await gate.withMaintenance(maintenance) { try await self.armInside(prepared) }
    }
    private func armInside(_ prepared: CatalogParticipantPreparation) async throws -> ArmedCatalogCoordination {
        guard prepared.journal.value.phase == .prepared, prepared.journal.value.disposition == .active else {
            throw CatalogCoordinationError.invalidPhase
        }
        let originalParticipants = try await participants(prepared.journal, allowMissingPrepared: false)
        guard originalParticipants.editing.map({ $0.phase == .prepared }) != false,
              originalParticipants.metadata.map({ $0.receipt.state == .staged }) != false else {
            throw CatalogCoordinationError.invalidPhase
        }
        guard case .exactBefore = try repository.inspectCatalogRecovery(prepared.journal) else {
            throw CatalogCoordinationError.externallyModifiedCatalog
        }
        let value = try repository.coordinationFiles.advance(prepared.journal, phase: .armed)
        let armed = ArmedCatalogCoordination(journal: validated(value), nonce: UUID())
        armedCapabilities[value.body.operationID] = armed
        try checkpoint(.armedJournal)
        return armed
    }

    public func finish(_ armed: ArmedCatalogCoordination) async throws -> CatalogCoordinationOutcome {
        await enter(); defer { leave() }
        let id = armed.journal.value.body.operationID
        guard armedCapabilities[id] === armed, let maintenance = maintenanceByID[id] else { throw CatalogCoordinationError.invalidCapability }
        return try await gate.withMaintenance(maintenance) { try await self.finishInside(armed, maintenance: maintenance) }
    }
    private func finishInside(_ armed: ArmedCatalogCoordination,
                              maintenance: CatalogMaintenanceAdmission) async throws -> CatalogCoordinationOutcome {
        var journal = armed.journal
        guard journal.value.disposition == .active, journal.value.phase != .prepared else { throw CatalogCoordinationError.invalidPhase }
        let participant = try await participants(journal, allowMissingPrepared: false)
        let recovery = try repository.inspectCatalogRecovery(journal)
        var editingReceipt: AssetRemapReceipt?
        switch recovery {
        case .conflict: throw CatalogCoordinationError.externallyModifiedCatalog
        case .exactAfter:
            // An after-catalog is insufficient evidence that our SQL committed.
            if let value = participant.editing {
                guard let receipt = value.databaseReceipt else { throw CatalogCoordinationError.recoveryRequired }
                editingReceipt = receipt
            }
        case .exactBefore:
            if let value = participant.editing {
                editingReceipt = try await editing.remapAssets(value.prepared, armedBy: armed)
            }
        }
        if journal.value.phase == .armed {
            journal = validated(try repository.coordinationFiles.advance(journal, phase: .editingCommitted))
            try checkpoint(.editingCommitted)
        }
        let currentArmed = ArmedCatalogCoordination(journal: journal, nonce: UUID())
        switch try repository.inspectCatalogRecovery(journal) {
        case .exactBefore(let stage): _ = try repository.publishDurableCatalogStage(stage, armedBy: currentArmed)
        case .exactAfter: break
        case .conflict: throw CatalogCoordinationError.externallyModifiedCatalog
        }
        if journal.value.phase == .editingCommitted {
            journal = validated(try repository.coordinationFiles.advance(journal, phase: .catalogPublished))
            try checkpoint(.catalogPublished)
        }
        // Bind participant confirmation to the now-durable published phase.
        guard case .exactAfter(let publication) = try repository.inspectCatalogRecovery(journal) else {
            throw CatalogCoordinationError.externallyModifiedCatalog
        }
        if let value = participant.editing {
            try await editing.confirmCatalogRemap(value.prepared, publication: publication)
        }
        var metadataResult: MetadataReconciliationResult?
        if participant.metadata != nil, let metadata {
            let actual = try repository.loadStored()
            guard actual.reference == journal.value.body.catalog.after else { throw CatalogCoordinationError.externallyModifiedCatalog }
            let result = try await metadata.completeCoordinatedCatalogChange(id: journal.value.body.operationID,
                publication: publication, persistedCatalog: await snapshot(actual))
            metadataResult = result
            guard let own = result.changes.first(where: { $0.changeID == journal.value.body.operationID }), own.state == .completed else {
                throw CatalogCoordinationError.recoveryRequired
            }
            try checkpoint(.metadataCompleted)
        }
        if let value = participant.editing {
            editingReceipt = try await editing.completeAssetRemap(value.prepared, publication: publication)
        }
        journal = validated(try repository.coordinationFiles.advance(journal, phase: .completed, disposition: .completed))
        try checkpoint(.completedJournal)
        try gate.durableWorkCompleted(maintenance, operationID: journal.value.body.operationID)
        preparations.removeValue(forKey: journal.value.body.operationID)
        armedCapabilities.removeValue(forKey: journal.value.body.operationID)
        maintenanceByID.removeValue(forKey: journal.value.body.operationID)
        // Final payloads are already consumed; receipts remain for inspection.
        // Retain final receipts and any harmless owned staging in v1.
        return CatalogCoordinationOutcome(publication: publication, metadata: metadataResult, editing: editingReceipt, disposition: .completed)
    }

    public func abort(_ prepared: CatalogParticipantPreparation) async throws -> CatalogCoordinationOutcome {
        await enter(); defer { leave() }
        let id = prepared.journal.value.body.operationID
        guard preparations[id] === prepared, let maintenance = maintenanceByID[id] else { throw CatalogCoordinationError.invalidCapability }
        return try await gate.withMaintenance(maintenance) { try await self.abortInside(prepared, maintenance: maintenance) }
    }
    private func abortInside(_ prepared: CatalogParticipantPreparation,
                             maintenance: CatalogMaintenanceAdmission) async throws -> CatalogCoordinationOutcome {
        var journal = prepared.journal
        guard journal.value.phase == .prepared,
              journal.value.disposition == .active || journal.value.disposition == .aborted,
              case .exactBefore(let stage) = try repository.inspectCatalogRecovery(journal) else {
            throw CatalogCoordinationError.invalidPhase
        }
        let participant = try await participants(journal, allowMissingPrepared: true)
        if journal.value.disposition == .active {
            journal = validated(try repository.coordinationFiles.advance(journal, phase: .prepared, disposition: .aborted))
        }
        let abort = CatalogCoordinationAbort(journal: journal, nonce: UUID())
        if let item = participant.editing {
            guard item.phase == .prepared || item.phase == .aborted, item.databaseReceipt == nil else { throw CatalogCoordinationError.invalidPhase }
            try await editing.cancelPreparedAssetRemap(item.prepared, abortedBy: abort)
        }
        if let item = participant.metadata, let metadata {
            guard item.receipt.state == .staged || item.receipt.state == .abandoned else { throw CatalogCoordinationError.invalidPhase }
            try await metadata.abortCoordinatedCatalogChange(id: journal.value.body.operationID, decision: abort)
        }
        guard try repository.loadStored().reference == journal.value.body.catalog.before else { throw CatalogCoordinationError.externallyModifiedCatalog }
        let terminal = validated(try repository.coordinationFiles.advance(journal, phase: .completed, disposition: .aborted))
        _ = terminal; _ = stage // Conservative retention; no automatic final GC.
        try gate.durableWorkCompleted(maintenance, operationID: journal.value.body.operationID)
        preparations.removeValue(forKey: journal.value.body.operationID)
        maintenanceByID.removeValue(forKey: journal.value.body.operationID)
        return CatalogCoordinationOutcome(publication: nil, metadata: nil, editing: nil, disposition: .aborted)
    }

    public func pending() async throws -> [ValidatedCatalogCoordinatorJournal] {
        // Pure durable lookup remains possible while the normal models are fenced.
        try repository.coordinationFiles.pendingValues().map { validated($0) }
    }

    public func recoverAndOpen() async throws -> CatalogStartupAdmission {
        await enter(); defer { leave() }
        do {
            var values = try repository.coordinationFiles.pendingValues()
            if values.isEmpty, let retainedID = maintenanceByID.keys.first {
                values = [try repository.coordinationFiles.value(id: retainedID)]
            }
            if let value = values.first {
                let id = value.body.operationID
                let maintenance: CatalogMaintenanceAdmission
                if let retained = maintenanceByID[id] { maintenance = retained }
                else {
                    maintenance = try await gate.beginMaintenance(.coordination(id))
                    maintenanceByID[id] = maintenance
                    try gate.requireDurableCompletion(maintenance, operationID: id)
                }
                try await gate.withMaintenance(maintenance) {
                    let journal = self.validated(value)
                    if value.phase == .completed {
                        _ = try await self.finishTerminal(journal, maintenance: maintenance)
                    } else if value.phase == .prepared {
                        let prepared = CatalogParticipantPreparation(journal: journal, nonce: UUID())
                        await self.retainPrepared(prepared)
                        _ = try await self.abortInside(prepared, maintenance: maintenance)
                    } else {
                        let armed = ArmedCatalogCoordination(journal: journal, nonce: UUID())
                        await self.retainArmed(armed)
                        _ = try await self.finishInside(armed, maintenance: maintenance)
                    }
                }
                try await gate.finishMaintenance(maintenance)
            } else {
                // Only a brand-new/known legacy store may initialize here. A
                // required journal participant is always inspected without writes.
                let maintenance = try await gate.beginMaintenance(.coordination(UUID()))
                do {
                    try await gate.withMaintenance(maintenance) {
                        await self.initializeIndependentParticipants()
                    }
                    try await gate.finishMaintenance(maintenance)
                } catch {
                    try? await gate.finishMaintenance(maintenance)
                    throw error
                }
            }
            return try gate.openAfterRecovery()
        } catch { gate.blockStartup(); throw error }
    }
    private func finishTerminal(_ journal: ValidatedCatalogCoordinatorJournal,
                                maintenance: CatalogMaintenanceAdmission) async throws -> CatalogCoordinationOutcome {
        let state = try await participants(journal, allowMissingPrepared: journal.value.disposition == .aborted)
        guard (journal.value.disposition == .completed && state.editing.map({ $0.phase == .completed }) != false &&
               state.metadata.map({ $0.receipt.state == .completed }) != false) ||
              (journal.value.disposition == .aborted && state.editing.map({ $0.phase == .aborted }) != false &&
               state.metadata.map({ $0.receipt.state == .abandoned }) != false) else { throw CatalogCoordinationError.invalidPhase }
        try gate.durableWorkCompleted(maintenance, operationID: journal.value.body.operationID)
        maintenanceByID.removeValue(forKey: journal.value.body.operationID)
        preparations.removeValue(forKey: journal.value.body.operationID)
        armedCapabilities.removeValue(forKey: journal.value.body.operationID)
        return CatalogCoordinationOutcome(publication: nil, metadata: nil, editing: state.editing?.databaseReceipt,
                                          disposition: journal.value.disposition)
    }
    private func initializeIndependentParticipants() async {
        // With a fully verified terminal/empty inventory these are independent
        // stores. A damaged editor must not disable manual photo metadata, and
        // unavailable metadata must not prevent viewing/editing an original.
        // Pending required participants NEVER pass through this branch.
        initializationFailures.removeAll()
        do { _ = try await editing.participantStoreIdentity() }
        catch { initializationFailures[.editing] = error.localizedDescription }
        if let metadata {
            do { _ = try await metadata.participantStoreIdentity() }
            catch { initializationFailures[.photoMetadata] = error.localizedDescription }
        }
    }
    public func participantInitializationFailures() -> [CatalogParticipantKind: String] { initializationFailures }
    public func recoverEditingDatabase(from url: URL) async throws -> EditingStoreState {
        await enter(); defer { leave() }
        // Unknown/missing journals and an armed participant block this before
        // any backup import, store initialization or database family replacement.
        _ = try repository.loadStored()
        _ = try repository.coordinationFiles.recoveryInventory()
        let maintenance = try await gate.beginMaintenance(.restore(UUID()))
        do {
            let result = try await gate.withMaintenance(maintenance) {
                let inventory = try self.repository.coordinationFiles.recoveryInventory()
                let permit = CatalogEditingRecoveryPermit(files: self.repository.coordinationFiles, gate: self.gate,
                    maintenance: maintenance, inventory: inventory)
                return try await self.editing.recoverDamagedDatabase(from: url, authorizedBy: permit)
            }
            try await gate.finishMaintenance(maintenance)
            initializationFailures.removeValue(forKey: .editing)
            _ = try gate.openAfterRecovery()
            return result
        } catch {
            try? await gate.finishMaintenance(maintenance)
            throw error
        }
    }
    private func retainPrepared(_ value: CatalogParticipantPreparation) { preparations[value.journal.value.body.operationID] = value }
    private func retainArmed(_ value: ArmedCatalogCoordination) { armedCapabilities[value.journal.value.body.operationID] = value }

    public func inspectMetadataConflict(coordinationID: UUID, conflictID: UUID) async throws -> CatalogMetadataConflictRecords {
        await enter(); defer { leave() }
        guard let metadata, let maintenance = maintenanceByID[coordinationID],
              let value = try repository.coordinationFiles.pendingValues().first(where: { $0.body.operationID == coordinationID }),
              value.phase == .catalogPublished else { throw CatalogCoordinationError.invalidPhase }
        return try await gate.withMaintenance(maintenance) {
            let participants = try await self.participants(self.validated(value), allowMissingPrepared: false)
            guard let original = participants.metadata,
                  let conflict = original.receipt.conflicts.first(where: { $0.id == conflictID }) else {
                throw CatalogCoordinationError.invalidCapability
            }
            return CatalogMetadataConflictRecords(receipt: original.receipt, conflict: conflict,
                source: try await metadata.record(assetID: conflict.oldAssetID),
                destination: try await metadata.record(assetID: conflict.newAssetID))
        }
    }

    public func resolveMetadataConflict(_ operation: MetadataCatalogResolutionOperation,
                                        coordinationID: UUID) async throws -> CatalogCoordinationOutcome {
        await enter(); defer { leave() }
        guard let metadata, let maintenance = maintenanceByID[coordinationID],
              let value = try repository.coordinationFiles.pendingValues().first(where: { $0.body.operationID == coordinationID }),
              value.phase == .catalogPublished, operation.changeID == coordinationID else {
            throw CatalogCoordinationError.invalidPhase
        }
        return try await gate.withMaintenance(maintenance) {
            let journal = self.validated(value)
            _ = try await self.participants(journal, allowMissingPrepared: false)
            guard case .exactAfter(let publication) = try self.repository.inspectCatalogRecovery(journal) else {
                throw CatalogCoordinationError.externallyModifiedCatalog
            }
            _ = try await metadata.resolveCoordinatedCatalogChange(operation, publication: publication)
            let armed = ArmedCatalogCoordination(journal: journal, nonce: UUID())
            let result = try await self.finishInside(armed, maintenance: maintenance)
            try await self.gate.finishMaintenance(maintenance)
            _ = try self.gate.openAfterRecovery()
            return result
        }
    }

    private func validateCatalogMapping(_ plan: AssetRemapProposal, before: LibraryCatalog, after: LibraryCatalog) throws {
        try ArtifactValueValidation.remap(plan)
        guard let oldFolder = before.folders.first(where: { $0.id == plan.folderID }),
              let newFolder = after.folders.first(where: { $0.id == plan.folderID }),
              oldFolder.bookmarkData == plan.bookmarkData,
              plan.resolvedBookmarkData == nil || newFolder.bookmarkData == plan.resolvedBookmarkData,
              FilePathComparison.canonicalPath(newFolder.url) == FilePathComparison.canonicalPath(plan.resolvedFolderURL) else {
            throw CatalogCoordinationError.originalRequestMismatch(.editing)
        }
        let oldAssets = Dictionary(uniqueKeysWithValues: before.assets.map { ($0.id, $0) })
        let newAssets = Dictionary(uniqueKeysWithValues: after.assets.map { ($0.id, $0) })
        for entry in plan.entries {
            guard let old = oldAssets[entry.oldAssetID], let new = newAssets[entry.newAssetID],
                  old.folderID == plan.folderID, new.folderID == plan.folderID,
                  FilePathComparison.canonicalPath(old.fileURL) == FilePathComparison.canonicalPath(URL(fileURLWithPath: entry.previous.standardizedPath)),
                  FilePathComparison.canonicalPath(new.fileURL) == FilePathComparison.canonicalPath(URL(fileURLWithPath: entry.relocated.standardizedPath)),
                  FilePathComparison.canonicalPath(new.fileURL) == FilePathComparison.canonicalPath(plan.resolvedFolderURL.appendingPathComponent(entry.relativePath)) else {
                throw CatalogCoordinationError.originalRequestMismatch(.editing)
            }
        }
    }
    private struct Participants: Sendable {
        var editing: AssetRemapInspection?
        var metadata: MetadataCatalogParticipantInspection?
    }
    private func participants(_ journal: ValidatedCatalogCoordinatorJournal,
                              allowMissingPrepared: Bool) async throws -> Participants {
        var output = Participants()
        for descriptor in journal.value.body.requiredParticipants {
            let bytes = try repository.coordinationFiles.command(journal, kind: descriptor.store.kind)
            switch descriptor.store.kind {
            case .editing:
                guard try await editing.inspectParticipantIdentity() == descriptor.store else {
                    throw CatalogCoordinationError.participantIdentityMismatch(.editing)
                }
                let proposal = try EditingContractJSON.decoder().decode(AssetRemapProposal.self, from: bytes)
                guard try EditingContractJSON.encoder().encode(proposal) == bytes, try digest(bytes) == descriptor.requestSHA256,
                      proposal.catalog == journal.value.body.catalog, proposal.operationID.rawValue == descriptor.operationID else {
                    throw CatalogCoordinationError.originalRequestMismatch(.editing)
                }
                let inspection = try await editing.inspectAssetRemap(.init(rawValue: descriptor.operationID), expectedRequestSHA256: descriptor.requestSHA256)
                if let inspection {
                    guard inspection.prepared.coordinatorRequestSHA256 == journal.value.requestSHA256,
                          inspection.prepared.requestSHA256 == descriptor.requestSHA256,
                          try EditingContractJSON.encoder().encode(inspection.prepared.proposal) == bytes else {
                        throw CatalogCoordinationError.invalidCapability
                    }
                } else if !allowMissingPrepared { throw CatalogCoordinationError.requiredParticipantMissing(.editing) }
                output.editing = inspection
            case .photoMetadata:
                guard let metadata else { throw CatalogCoordinationError.requiredParticipantMissing(.photoMetadata) }
                guard try await metadata.inspectParticipantIdentity() == descriptor.store else { throw CatalogCoordinationError.participantIdentityMismatch(.photoMetadata) }
                let change = try PhotoMetadataInternalCodec.decode(MetadataCatalogChange.self, from: bytes, maximum: 67_108_864)
                guard try PhotoMetadataInternalCodec.encode(change) == bytes,
                      try PhotoMetadataInternalCodec.digest(kind: "catalogChange", payload: change) == descriptor.requestSHA256.sha256,
                      change.id == descriptor.operationID, change.before == journal.value.body.catalog.before,
                      change.after == journal.value.body.catalog.after else { throw CatalogCoordinationError.originalRequestMismatch(.photoMetadata) }
                let inspection = try await metadata.inspectCatalogChange(id: descriptor.operationID, expectedRequestSHA256: descriptor.requestSHA256.sha256)
                if let inspection {
                    guard inspection.store == descriptor.store, inspection.coordinatorRequestSHA256 == journal.value.requestSHA256,
                          inspection.originalChange == change else { throw CatalogCoordinationError.invalidCapability }
                } else if !allowMissingPrepared { throw CatalogCoordinationError.requiredParticipantMissing(.photoMetadata) }
                output.metadata = inspection
            }
        }
        return output
    }
    private func snapshot(_ stored: StoredLibraryCatalog) async -> MetadataCatalogSnapshot {
        generation += 1
        return MetadataCatalogSnapshot(catalogSessionID: sessionID, catalogGeneration: generation,
            persistedReference: stored.reference, assets: await MetadataCatalogSourceReader.assets(stored.catalog.assets))
    }
    private nonisolated func validated(_ value: CatalogCoordinationJournalValue) -> ValidatedCatalogCoordinatorJournal {
        ValidatedCatalogCoordinatorJournal(value: value, ownerID: value.body.catalog.rootOwnerID, nonce: UUID())
    }
    private nonisolated func digest(_ bytes: Data) throws -> ArtifactDigest {
        try ArtifactDigest(sha256: CatalogFileIO.digest(bytes))
    }
}
