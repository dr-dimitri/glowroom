import Foundation
import CSQLite

extension PhotoMetadataRepository {
    static func decodeJournal(_ s:OpaquePointer) throws -> PhotoMetadataJournal {
        let id = try PhotoMetadataSQLite.text(s,0,maximum:36), state = try PhotoMetadataSQLite.text(s,1,maximum:16)
        let journal = try PhotoMetadataInternalCodec.decode(PhotoMetadataJournal.self,from:PhotoMetadataSQLite.blob(s,2,maximum:PhotoMetadataLimits.maximumJournalBytes),maximum:PhotoMetadataLimits.maximumJournalBytes)
        do { try PhotoMetadataValidation.change(journal.change) } catch { throw PhotoMetadataError.corruptStore }
        guard UUID(uuidString:id) == journal.change.id, journal.receipt.changeID == journal.change.id,
              journal.receipt.state.rawValue == state, journal.receipt.revision > 0,
              journal.receipt.payloadSHA256 == (try PhotoMetadataInternalCodec.digest(kind:"catalogChange",payload:journal.change)),
              Set(journal.receipt.blockedAssetIDs).count == journal.receipt.blockedAssetIDs.count else { throw PhotoMetadataError.corruptStore }
        return journal
    }
    func journals(on db:OpaquePointer,pendingOnly:Bool = false) throws -> [PhotoMetadataJournal] {
        let suffix = pendingOnly ? " WHERE state IN ('staged','conflicted')" : ""
        var result:[PhotoMetadataJournal] = []
        try PhotoMetadataSQLite.rows(db,"SELECT id,state,journal FROM metadata_catalog_changes\(suffix) ORDER BY id") { s in
            result.append(try Self.decodeJournal(s))
            if pendingOnly, result.count > 1 { throw PhotoMetadataError.corruptStore }
        }; return result
    }
    func journal(_ id:UUID,on db:OpaquePointer) throws -> PhotoMetadataJournal? {
        try PhotoMetadataSQLite.statement(db,"SELECT id,state,journal FROM metadata_catalog_changes WHERE id=?") { s in
            try PhotoMetadataSQLite.bind(id.uuidString.lowercased(),1,s); var result:PhotoMetadataJournal?
            try PhotoMetadataSQLite.consume(s) { result = try Self.decodeJournal($0) }; return result
        }
    }
    func saveJournal(_ value:PhotoMetadataJournal,on db:OpaquePointer) throws {
        let bytes = try PhotoMetadataInternalCodec.encode(value)
        guard bytes.count <= PhotoMetadataLimits.maximumJournalBytes else { throw PhotoMetadataError.limitExceeded(.catalogChange) }
        try PhotoMetadataSQLite.statement(db,"INSERT INTO metadata_catalog_changes(id,state,journal) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,journal=excluded.journal") { s in
            try PhotoMetadataSQLite.bind(value.change.id.uuidString.lowercased(),1,s)
            try PhotoMetadataSQLite.bind(value.receipt.state.rawValue,2,s); try PhotoMetadataSQLite.bind(bytes,3,s); try PhotoMetadataSQLite.done(s)
        }
    }
    func rowPage(after:String?,on db:OpaquePointer) throws -> [PhotoMetadataRow] {
        let suffix = after == nil ? "" : " WHERE asset_id>?"
        return try PhotoMetadataSQLite.statement(db,"SELECT record FROM metadata_records\(suffix) ORDER BY asset_id COLLATE BINARY LIMIT 256") { s in
            if let after { try PhotoMetadataSQLite.bind(after,1,s) }
            var result:[PhotoMetadataRow] = []
            try PhotoMetadataSQLite.consume(s) { row in
                let value = try PhotoMetadataInternalCodec.decode(PhotoMetadataRow.self,from:PhotoMetadataSQLite.blob(row,0,maximum:PhotoMetadataLimits.maximumStoredRecordBlobBytes))
                try PhotoMetadataValidation.row(value); result.append(value)
            }; return result
        }
    }
    func verifyCatalogFile(_ snapshot:MetadataCatalogSnapshot) throws {
        try PhotoMetadataValidation.catalog(snapshot)
        guard try PhotoMetadataFiles.reference(fileURL.deletingLastPathComponent().appendingPathComponent("catalog.json")) == snapshot.persistedReference else { throw PhotoMetadataError.catalogConflict }
    }
    func validateCatalogToken(_ snapshot:MetadataCatalogSnapshot) throws {
        if let catalog {
            guard snapshot.catalogSessionID == catalog.catalogSessionID, snapshot.catalogGeneration >= catalog.catalogGeneration else { throw PhotoMetadataError.staleCatalog }
            if snapshot.catalogGeneration == catalog.catalogGeneration, snapshot != catalog { throw PhotoMetadataError.staleCatalog }
        }
    }
    func bindCatalog(_ snapshot:MetadataCatalogSnapshot) {
        catalog = snapshot; catalogByID = Dictionary(uniqueKeysWithValues:snapshot.assets.map { ($0.assetID,$0.source) })
    }
    /// Update flags only when their meaning changed. Never manufacture a row for
    /// an undescribed catalog image, nor drop data for unreadable originals.
    func reconcileRows(_ snapshot:MetadataCatalogSnapshot,on db:OpaquePointer) throws {
        let byID = Dictionary(uniqueKeysWithValues:snapshot.assets.map { ($0.assetID,$0.source) })
        var after:String?, changed = false
        while true {
            let page = try rowPage(after:after,on:db); if page.isEmpty { break }
            for var row in page {
                let orphan = byID[row.assetID] == nil
                let association = row.associationSource ?? row.confirmedSource
                let sourceChanged = row.sourceChanged || row.version.confirmedRevision > 0 && byID[row.assetID].map { current in
                    association.map { !Self.sameCurrentSource($0,current) } ?? false
                } == true
                let staleDraft = row.draft.map { draft in
                    [.pending,.edited].contains(draft.state) && byID[row.assetID].map { !Self.sameCurrentSource(draft.source,$0) } == true
                } == true
                guard row.isOrphaned != orphan || row.sourceChanged != sourceChanged || staleDraft else { continue }
                let searchable = row.isOrphaned != orphan || row.sourceChanged != sourceChanged
                try row.advance(ai:staleDraft); row.isOrphaned = orphan; row.sourceChanged = sourceChanged
                if staleDraft, let d = row.draft {
                    row.draft = .init(id:d.id,revision:row.version.aiDraftRevision,baseConfirmedRevision:d.baseConfirmedRevision,
                        fields:d.fields,source:d.source,state:.outdated,createdAt:d.createdAt,modifiedAt:Date(),editedFields:d.editedFields)
                }
                try saveRow(row,on:db); changed = changed || searchable
            }
            after = page.last!.assetID
        }
        if changed || catalogReference != snapshot.persistedReference { try bumpSearch(db) }
        try setCatalogReference(snapshot.persistedReference,on:db)
    }
    public func reconcile(_ snapshot:MetadataCatalogSnapshot) throws -> MetadataReconciliationResult {
        try validateCatalogToken(snapshot)
        let db = try connection()
        if snapshot == catalog { return .init(searchState:state,changes:try journals(on:db,pendingOnly:true).map(\.receipt)) }
        try verifyCatalogFile(snapshot)
        guard try journals(on:db,pendingOnly:true).isEmpty else { throw PhotoMetadataError.relocationInProgress }
        try sql.transaction(db,beforeCommit:hooks.beforeCommit) { try reconcileRows(snapshot,on:db) }
        bindCatalog(snapshot); refreshSearch(db)
        return .init(searchState:state,changes:[])
    }
    public func stageCatalogChange(_ change:MetadataCatalogChange) throws -> MetadataCatalogChangeReceipt {
        try PhotoMetadataValidation.change(change)
        let digest = try PhotoMetadataInternalCodec.digest(kind:"catalogChange",payload:change), db = try connection()
        // Durable identity is checked before current-file preconditions: an
        // already completed request remains replayable after later catalog edits.
        if let existing = try journal(change.id,on:db) {
            guard existing.receipt.payloadSHA256 == digest else { throw PhotoMetadataError.operationIDCollision }
            return existing.receipt
        }
        guard try PhotoMetadataFiles.reference(fileURL.deletingLastPathComponent().appendingPathComponent("catalog.json")) == change.before else { throw PhotoMetadataError.catalogConflict }
        return try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            if let existing = try journal(change.id,on:db) {
                guard existing.receipt.payloadSHA256 == digest else { throw PhotoMetadataError.operationIDCollision }; return existing.receipt
            }
            guard catalogReference == change.before else { throw PhotoMetadataError.catalogConflict }
            guard try journals(on:db,pendingOnly:true).isEmpty else { throw PhotoMetadataError.relocationInProgress }
            for expected in change.expectedRecords {
                guard (try readRow(expected.assetID,on:db)?.version ?? .absent) == expected.version else { throw PhotoMetadataError.revisionConflict }
            }
            let ids = change.expectedRecords.map(\.assetID).sorted()
            let urls = change.relocations.flatMap { [URL(fileURLWithPath:$0.oldSource.original.standardizedPath,isDirectory:false),URL(fileURLWithPath:$0.newSource.original.standardizedPath,isDirectory:false)] }
            let receipt = MetadataCatalogChangeReceipt(changeID:change.id,payloadSHA256:digest,revision:1,state:.staged,blockedAssetIDs:ids,protectedSourceURLs:urls,conflicts:[])
            try saveJournal(.init(change:change,receipt:receipt),on:db); return receipt
        }
    }
    func updatedReceipt(_ journal:PhotoMetadataJournal,state:MetadataCatalogChangeState,conflicts:[MetadataRelocationConflict]) throws -> MetadataCatalogChangeReceipt {
        guard journal.receipt.revision < Int64.max else { throw PhotoMetadataError.limitExceeded(.revisionExhausted) }
        let pending = [.staged,.conflicted].contains(state)
        return .init(changeID:journal.change.id,payloadSHA256:journal.receipt.payloadSHA256,revision:journal.receipt.revision+1,
            state:state,blockedAssetIDs:pending ? journal.receipt.blockedAssetIDs : [],
            protectedSourceURLs:pending ? journal.receipt.protectedSourceURLs : [],conflicts:conflicts)
    }
    func moveRow(_ move:MetadataRelocation,on db:OpaquePointer) throws -> [MetadataAffectedRecord] {
        guard var source = try readRow(move.oldAssetID,on:db) else { return [] }
        let target = try readRow(move.newAssetID,on:db)
        guard (target?.version.confirmedRevision ?? 0) == 0, target?.draft == nil, target?.manualDraft == nil else { throw PhotoMetadataError.importConflict }
        var relocated = source; relocated.assetID = move.newAssetID
        let v = target?.version ?? .absent, old = source.version
        relocated.version = .init(recordRevision:max(old.recordRevision,v.recordRevision),confirmedRevision:max(old.confirmedRevision,v.confirmedRevision),
            aiDraftRevision:max(old.aiDraftRevision,v.aiDraftRevision),manualDraftRevision:max(old.manualDraftRevision,v.manualDraftRevision))
        try relocated.advance(confirmed:old.confirmedRevision > 0,ai:source.draft != nil,manual:source.manualDraft != nil)
        // A verified path association does not confirm text against changed pixels.
        // Keep a previously observed overwrite warning until explicit confirmation.
        relocated.isOrphaned = false; relocated.sourceChanged = source.sourceChanged; relocated.associationSource = move.newSource
        if let d = relocated.draft {
            relocated.draft = .init(id:d.id,revision:relocated.version.aiDraftRevision,baseConfirmedRevision:d.baseConfirmedRevision,
                fields:d.fields,source:d.source,state:d.state == .pending || d.state == .edited ? .outdated : d.state,
                createdAt:d.createdAt,modifiedAt:Date(),appliedFields:d.appliedFields,editedFields:d.editedFields)
        }
        if let d = relocated.manualDraft {
            relocated.manualDraft = .init(revision:relocated.version.manualDraftRevision,baseConfirmedRevision:d.baseConfirmedRevision,fields:d.fields,modifiedAt:d.modifiedAt)
        }
        try source.advance(confirmed:old.confirmedRevision > 0,ai:source.draft != nil,manual:source.manualDraft != nil)
        source.confirmed = .empty; source.confirmedProvenance = .init(); source.draft = nil; source.manualDraft = nil
        source.isOrphaned = true; source.sourceChanged = false
        try saveRow(source,on:db); try saveRow(relocated,on:db)
        return [.init(assetID:source.assetID,version:source.version),.init(assetID:relocated.assetID,version:relocated.version)]
    }
    func complete(_ journal:inout PhotoMetadataJournal,snapshot:MetadataCatalogSnapshot,on db:OpaquePointer) throws {
        var conflicts:[MetadataRelocationConflict] = []
        let expected = Dictionary(uniqueKeysWithValues:journal.change.expectedRecords.map { ($0.assetID,$0.version) })
        for move in journal.change.relocations {
            let old = try readRow(move.oldAssetID,on:db), new = try readRow(move.newAssetID,on:db)
            var reason:MetadataRelocationConflictReason?
            if (old?.version ?? .absent) != expected[move.oldAssetID] || (new?.version ?? .absent) != expected[move.newAssetID] { reason = .recordRevisionChanged }
            else if (new?.version.confirmedRevision ?? 0) > 0 { reason = .destinationHasConfirmedContent }
            else if new?.draft != nil || new?.manualDraft != nil { reason = .destinationHasDraft }
            else if !PhotoMetadataValidation.verified(move,row:old) { reason = .unverifiedSource }
            if let reason {
                conflicts.append(.init(id:UUID(),changeID:journal.change.id,oldAssetID:move.oldAssetID,newAssetID:move.newAssetID,reason:reason,
                    sourceVersion:old?.version ?? .absent,destinationVersion:new?.version ?? .absent))
            } else { _ = try moveRow(move,on:db) }
        }
        journal.receipt = try updatedReceipt(journal,state:conflicts.isEmpty ? .completed : .conflicted,conflicts:conflicts)
        try saveJournal(journal,on:db); try bumpSearch(db)
        try reconcileRows(snapshot,on:db)
        try refreshConflictVersions(&journal,on:db)
    }
    func refreshConflictVersions(_ journal:inout PhotoMetadataJournal,on db:OpaquePointer) throws {
        guard journal.receipt.state == .conflicted else { return }
        let conflicts = try journal.receipt.conflicts.map { c in
            MetadataRelocationConflict(id:c.id,changeID:c.changeID,oldAssetID:c.oldAssetID,newAssetID:c.newAssetID,reason:c.reason,
                sourceVersion:try readRow(c.oldAssetID,on:db)?.version ?? .absent,
                destinationVersion:try readRow(c.newAssetID,on:db)?.version ?? .absent)
        }
        journal.receipt = .init(changeID:journal.receipt.changeID,payloadSHA256:journal.receipt.payloadSHA256,revision:journal.receipt.revision,state:.conflicted,blockedAssetIDs:journal.receipt.blockedAssetIDs,protectedSourceURLs:journal.receipt.protectedSourceURLs,conflicts:conflicts)
        try saveJournal(journal,on:db)
    }
    public func completeCatalogChange(id:UUID,persistedCatalog snapshot:MetadataCatalogSnapshot) throws -> MetadataReconciliationResult {
        try validateCatalogToken(snapshot); try verifyCatalogFile(snapshot)
        let db = try connection()
        try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            guard var journal = try journal(id,on:db) else { throw PhotoMetadataError.catalogConflict }
            if journal.receipt.state == .completed || journal.receipt.state == .abandoned { return }
            guard snapshot.persistedReference == journal.change.after else { throw PhotoMetadataError.catalogConflict }
            if journal.receipt.state == .staged { try complete(&journal,snapshot:snapshot,on:db) }
        }
        bindCatalog(snapshot); refreshSearch(db)
        return .init(searchState:state,changes:try journals(on:db,pendingOnly:true).map(\.receipt))
    }
    public func recoverCatalogChanges(persistedCatalog snapshot:MetadataCatalogSnapshot) throws -> MetadataReconciliationResult {
        try validateCatalogToken(snapshot); try verifyCatalogFile(snapshot)
        let db = try connection()
        try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            for var journal in try journals(on:db,pendingOnly:true) {
                if snapshot.persistedReference == journal.change.before, journal.receipt.state == .staged {
                    journal.receipt = try updatedReceipt(journal,state:.abandoned,conflicts:[]); try saveJournal(journal,on:db)
                } else if snapshot.persistedReference == journal.change.after, journal.receipt.state == .staged {
                    try complete(&journal,snapshot:snapshot,on:db)
                } else if snapshot.persistedReference != journal.change.after {
                    let conflicts = try journal.change.relocations.map { move in
                        MetadataRelocationConflict(id:UUID(),changeID:journal.change.id,oldAssetID:move.oldAssetID,newAssetID:move.newAssetID,
                            reason:.catalogDigestMismatch,sourceVersion:try readRow(move.oldAssetID,on:db)?.version ?? .absent,
                            destinationVersion:try readRow(move.newAssetID,on:db)?.version ?? .absent)
                    }
                    journal.receipt = try updatedReceipt(journal,state:.conflicted,conflicts:conflicts); try saveJournal(journal,on:db)
                }
            }
            // Even a conflicted mapping leaves all existing content intact.
            // Reconciliation updates source/orphan flags, never transfers it.
            try reconcileRows(snapshot,on:db)
            for var current in try journals(on:db,pendingOnly:true) { try refreshConflictVersions(&current,on:db) }
        }
        bindCatalog(snapshot); refreshSearch(db)
        return .init(searchState:state,changes:try journals(on:db,pendingOnly:true).map(\.receipt))
    }
    public func resolveCatalogChange(_ operation:MetadataCatalogResolutionOperation) throws -> MetadataReconciliationResult {
        try PhotoMetadataValidation.reference(operation.persistedReference)
        guard !operation.decisions.isEmpty, Set(operation.decisions.map(\.conflictID)).count == operation.decisions.count else { throw PhotoMetadataError.validation(.invalidDecision) }
        let hash = try PhotoMetadataInternalCodec.digest(kind:"catalogResolution",payload:operation), db = try connection()
        if let prior = try receipt(operation.id,digest:hash,on:db) {
            if snapshotAttemptedGeneration != searchGeneration { refreshSearch(db) }
            return .init(receipt:prior,searchState:state,changes:try journals(on:db,pendingOnly:true).map(\.receipt))
        }
        guard try PhotoMetadataFiles.reference(fileURL.deletingLastPathComponent().appendingPathComponent("catalog.json")) == operation.persistedReference else { throw PhotoMetadataError.catalogConflict }
        let receipt = try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            if let receipt = try receipt(operation.id,digest:hash,on:db) { return receipt }
            guard var journal = try journal(operation.changeID,on:db), journal.receipt.state == .conflicted,
                  journal.receipt.revision == operation.expectedChangeRevision else { throw PhotoMetadataError.revisionConflict }
            var remaining = journal.receipt.conflicts, affected:[MetadataAffectedRecord] = []
            for decision in operation.decisions {
                guard let conflict = remaining.first(where:{ $0.id == decision.conflictID }),
                      let move = journal.change.relocations.first(where:{ $0.oldAssetID == conflict.oldAssetID && $0.newAssetID == conflict.newAssetID }),
                      (try readRow(move.oldAssetID,on:db)?.version ?? .absent) == decision.sourceVersion,
                      (try readRow(move.newAssetID,on:db)?.version ?? .absent) == decision.destinationVersion else { throw PhotoMetadataError.revisionConflict }
                if decision.action == .assignIfDestinationVacant {
                    guard catalogByID[move.newAssetID].map({ Self.sameCurrentSource($0,move.newSource) }) == true else { throw PhotoMetadataError.sourceChanged }
                    affected += try moveRow(move,on:db)
                }
                remaining.removeAll { $0.id == decision.conflictID }
            }
            journal.receipt = try updatedReceipt(journal,state:remaining.isEmpty ? .completed : .conflicted,conflicts:remaining)
            try saveJournal(journal,on:db); try bumpSearch(db)
            let value = MetadataWriteReceipt(operationID:operation.id,payloadSHA256:hash,committedAt:Date(),affected:affected,disposition:.applied)
            try saveReceipt(value,on:db); return value
        }
        refreshSearch(db)
        return .init(receipt:receipt,searchState:state,changes:try journals(on:db,pendingOnly:true).map(\.receipt))
    }
}
