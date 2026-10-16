import Foundation
import CSQLite

struct PhotoMetadataRepositoryHooks: Sendable {
    var beforeCommit: @Sendable () throws -> Void = {}
    var beforeSearchSnapshot: @Sendable () throws -> Void = {}
    var didReadProtectionRecord: @Sendable () -> Void = {}
    var beforeExportPublish: @Sendable () throws -> Void = {}
    var searchEntryLimit = PhotoMetadataLimits.maximumSearchEntries
}

/// Durable editorial metadata only. This actor serializes short accepted SQL
/// writes; independently prepared image analysis/catalog work remains outside it.
/// No file I/O occurs in init, so one shared instance can be composed on MainActor.
public actor PhotoMetadataRepository: CoordinatedPhotoMetadataStoring {
    public nonisolated let fileURL: URL
    let lifecycleGate:CatalogLifecycleGate?
    let sql: PhotoMetadataSQLite
    let hooks: PhotoMetadataRepositoryHooks
    let session = UUID()
    var searchGeneration: Int64 = 0
    var catalogReference: MetadataCatalogFileReference = .absent
    var catalog: MetadataCatalogSnapshot?
    var catalogByID: [String:MetadataSourceReference] = [:]
    var state: PhotoMetadataSearchState
    var loaded = false
    var snapshotAttemptedGeneration: Int64?
    var observers: [UUID:AsyncStream<PhotoMetadataSearchState>.Continuation] = [:]
    var retainedReview: PhotoMetadataRetainedReview?
    public init(directory:URL,gate:CatalogLifecycleGate? = nil) {
        lifecycleGate = gate
        sql = PhotoMetadataSQLite(directory:directory); fileURL = sql.fileURL
        hooks = .init(); state = .loading(version:.initial)
    }
    init(directory:URL,hooks:PhotoMetadataRepositoryHooks) {
        lifecycleGate = nil
        sql = PhotoMetadataSQLite(directory:directory); fileURL = sql.fileURL
        self.hooks = hooks; state = .loading(version:.initial)
    }
    func _metadata_record(assetID:String) throws -> PhotoMetadataRecord? {
        try PhotoMetadataValidation.identifier(assetID)
        let db = try connection(); return try readRow(assetID,on:db)?.value
    }
    func _metadata_searchState() -> PhotoMetadataSearchState {
        do {
            let db = try connection()
            if !loaded || state.version.generation != UInt64(searchGeneration) { refreshSearch(db) }
        } catch { publishUnavailable(error) }
        return state
    }
    func _metadata_updates() -> AsyncStream<PhotoMetadataSearchState> {
        let id = UUID(), initial = _metadata_searchState()
        return AsyncStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    func removeObserver(_ id:UUID) { observers.removeValue(forKey:id) }
    func _metadata_finishSaving() -> Bool {
        // UI owns and drains accepted Tasks before calling this barrier. Actor
        // transactions themselves never suspend and cannot remain half-finished.
        do { _ = try connection(); return true } catch { publishUnavailable(error); return false }
    }
    func connection() throws -> OpaquePointer {
        let db = try sql.open(validateRows:Self.validateDatabase)
        try readState(db)
        return db
    }
    func readState(_ db:OpaquePointer) throws {
        var count = 0
        try PhotoMetadataSQLite.rows(db,"SELECT singleton,search_generation,catalog_reference FROM metadata_state") { s in
            guard sqlite3_column_type(s,0) == SQLITE_INTEGER, sqlite3_column_int64(s,0) == 1,
                  sqlite3_column_type(s,1) == SQLITE_INTEGER, sqlite3_column_int64(s,1) >= 0 else { throw PhotoMetadataError.corruptStore }
            count += 1; searchGeneration = sqlite3_column_int64(s,1)
            catalogReference = try PhotoMetadataInternalCodec.decode(MetadataCatalogFileReference.self,from:PhotoMetadataSQLite.blob(s,2,maximum:4_096))
            try PhotoMetadataValidation.reference(catalogReference)
        }
        guard count == 1 else { throw PhotoMetadataError.corruptStore }
    }
    static func validateDatabase(_ db:OpaquePointer) throws {
        var count = 0
        try PhotoMetadataSQLite.rows(db,"SELECT singleton,search_generation,catalog_reference FROM metadata_state") { s in
            guard sqlite3_column_type(s,0) == SQLITE_INTEGER, sqlite3_column_int64(s,0) == 1,
                  sqlite3_column_type(s,1) == SQLITE_INTEGER, sqlite3_column_int64(s,1) >= 0 else { throw PhotoMetadataError.corruptStore }
            count += 1
            let reference = try PhotoMetadataInternalCodec.decode(MetadataCatalogFileReference.self,from:PhotoMetadataSQLite.blob(s,2,maximum:4_096))
            try PhotoMetadataValidation.reference(reference)
        }
        guard count == 1 else { throw PhotoMetadataError.corruptStore }
        try PhotoMetadataSQLite.rows(db,"SELECT asset_id,record FROM metadata_records") { s in
            let id = try PhotoMetadataSQLite.text(s,0,maximum:PhotoMetadataLimits.maximumAssetIDBytes)
            let row = try PhotoMetadataInternalCodec.decode(PhotoMetadataRow.self,from:PhotoMetadataSQLite.blob(s,1,maximum:PhotoMetadataLimits.maximumStoredRecordBlobBytes))
            guard row.assetID == id else { throw PhotoMetadataError.corruptStore }
            do { try PhotoMetadataValidation.row(row) } catch { throw PhotoMetadataError.corruptStore }
        }
        try PhotoMetadataSQLite.rows(db,"SELECT id,digest,receipt FROM metadata_receipts") { s in
            _ = try decodeReceipt(s)
        }
        var pending = 0
        try PhotoMetadataSQLite.rows(db,"SELECT id,state,journal FROM metadata_catalog_changes") { s in
            let journal = try decodeJournal(s)
            if [.staged,.conflicted].contains(journal.receipt.state) { pending += 1 }
        }
        guard pending <= 1 else { throw PhotoMetadataError.corruptStore }
        if try PhotoMetadataSQLite.version(db) == 2 {
            _ = try metadataIdentity(db)
            try PhotoMetadataSQLite.rows(db,"SELECT c.id,c.coordinator_sha,j.id FROM metadata_coordinations c LEFT JOIN metadata_catalog_changes j ON j.id=c.id") {s in
                let id = try PhotoMetadataSQLite.text(s,0,maximum:36),sha = try PhotoMetadataSQLite.text(s,1,maximum:64)
                guard let uuid = UUID(uuidString:id),id == uuid.uuidString.lowercased(),PhotoMetadataValidation.digest(sha),
                      try PhotoMetadataSQLite.text(s,2,maximum:36) == id else {throw PhotoMetadataError.corruptStore}
            }
        }
    }
    func readRow(_ id:String,on db:OpaquePointer) throws -> PhotoMetadataRow? {
        try PhotoMetadataSQLite.statement(db,"SELECT record FROM metadata_records WHERE asset_id=?") { s in
            try PhotoMetadataSQLite.bind(id,1,s); var result:PhotoMetadataRow?
            try PhotoMetadataSQLite.consume(s) { row in
                let value = try PhotoMetadataInternalCodec.decode(PhotoMetadataRow.self,from:PhotoMetadataSQLite.blob(row,0,maximum:PhotoMetadataLimits.maximumStoredRecordBlobBytes))
                guard value.assetID == id else { throw PhotoMetadataError.corruptStore }
                do { try PhotoMetadataValidation.row(value) } catch { throw PhotoMetadataError.corruptStore }; result = value
            }; return result
        }
    }
    func saveRow(_ row:PhotoMetadataRow,on db:OpaquePointer) throws {
        try PhotoMetadataValidation.row(row)
        let data = try PhotoMetadataInternalCodec.encode(row)
        guard data.count <= PhotoMetadataLimits.maximumStoredRecordBlobBytes else { throw PhotoMetadataError.limitExceeded(.detailRecord) }
        try PhotoMetadataSQLite.statement(db,"INSERT INTO metadata_records(asset_id,record) VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET record=excluded.record") { s in
            try PhotoMetadataSQLite.bind(row.assetID,1,s); try PhotoMetadataSQLite.bind(data,2,s); try PhotoMetadataSQLite.done(s)
        }
    }
    func allRows(_ db:OpaquePointer,_ body:(PhotoMetadataRow) throws -> Void) throws {
        try PhotoMetadataSQLite.rows(db,"SELECT asset_id,record FROM metadata_records ORDER BY asset_id COLLATE BINARY") { s in
            let id = try PhotoMetadataSQLite.text(s,0,maximum:PhotoMetadataLimits.maximumAssetIDBytes)
            let row = try PhotoMetadataInternalCodec.decode(PhotoMetadataRow.self,from:PhotoMetadataSQLite.blob(s,1,maximum:PhotoMetadataLimits.maximumStoredRecordBlobBytes))
            guard row.assetID == id else { throw PhotoMetadataError.corruptStore }
            try PhotoMetadataValidation.row(row); try body(row)
        }
    }
    func bumpSearch(_ db:OpaquePointer) throws {
        var current:Int64 = 0
        try PhotoMetadataSQLite.rows(db,"SELECT search_generation FROM metadata_state WHERE singleton=1") { current = sqlite3_column_int64($0,0) }
        guard current >= 0, current < Int64.max else { throw PhotoMetadataError.limitExceeded(.revisionExhausted) }
        try PhotoMetadataSQLite.exec(db,"UPDATE metadata_state SET search_generation=\(current+1) WHERE singleton=1")
    }
    func setCatalogReference(_ reference:MetadataCatalogFileReference,on db:OpaquePointer) throws {
        try PhotoMetadataSQLite.statement(db,"UPDATE metadata_state SET catalog_reference=? WHERE singleton=1") { s in
            try PhotoMetadataSQLite.bind(PhotoMetadataInternalCodec.encode(reference),1,s); try PhotoMetadataSQLite.done(s)
        }
    }
    func refreshSearch(_ db:OpaquePointer) {
        do {
            try readState(db); snapshotAttemptedGeneration = searchGeneration
            try hooks.beforeSearchSnapshot()
            var fields:[String:PhotoTextFields] = [:], utf8 = 0, accounted = 0
            try allRows(db) { row in
                guard row.version.confirmedRevision > 0, !row.isOrphaned,
                      !row.confirmed.title.isEmpty || !row.confirmed.description.isEmpty || !row.confirmed.tags.isEmpty else { return }
                let bytes = row.assetID.utf8.count + row.confirmed.title.utf8.count + row.confirmed.description.utf8.count + row.confirmed.tags.reduce(0) { $0+$1.utf8.count }
                guard fields.count < hooks.searchEntryLimit,
                      utf8 <= PhotoMetadataLimits.maximumSearchUTF8Bytes-bytes,
                      accounted <= PhotoMetadataLimits.maximumSearchAccountedCost-bytes*2-512 else { throw PhotoMetadataError.limitExceeded(.searchSnapshot) }
                utf8 += bytes; accounted += bytes*2+512; fields[row.assetID] = row.confirmed
            }
            let value = PhotoMetadataSearchState.available(.init(version:.init(sessionID:session,generation:UInt64(searchGeneration)),catalogReference:catalogReference,confirmedByAssetID:fields))
            loaded = true; publish(value)
        } catch { publishUnavailable(error) }
    }
    func publish(_ next:PhotoMetadataSearchState) {
        guard next != state else { return }; state = next
        for continuation in observers.values { continuation.yield(next) }
    }
    func publishUnavailable(_ error:Error) {
        loaded = false
        publish(.unavailable(version:.init(sessionID:session,generation:UInt64(max(0,searchGeneration))),reason:Self.error(error)))
    }
    static func error(_ error:Error) -> PhotoMetadataError {
        if let value = error as? PhotoMetadataError { return value }
        if error is CancellationError { return .cancelled }; return .storageFailure
    }
    static func decodeReceipt(_ s:OpaquePointer) throws -> MetadataWriteReceipt {
        let id = try PhotoMetadataSQLite.text(s,0,maximum:36), digest = try PhotoMetadataSQLite.text(s,1,maximum:64)
        let receipt = try PhotoMetadataInternalCodec.decode(MetadataWriteReceipt.self,from:PhotoMetadataSQLite.blob(s,2,maximum:PhotoMetadataLimits.maximumJournalBytes),maximum:PhotoMetadataLimits.maximumJournalBytes)
        guard UUID(uuidString:id) == receipt.operationID, PhotoMetadataValidation.digest(digest), receipt.payloadSHA256 == digest,
              receipt.payloadSchemaVersion == 1, receipt.committedAt.timeIntervalSinceReferenceDate.isFinite,
              receipt.disposition == .applied,
              Set(receipt.affected.map(\.assetID)).count == receipt.affected.count else { throw PhotoMetadataError.corruptStore }
        for record in receipt.affected { try PhotoMetadataValidation.identifier(record.assetID); try PhotoMetadataValidation.version(record.version) }
        return receipt
    }
    func receipt(_ id:UUID,digest:String,on db:OpaquePointer) throws -> MetadataWriteReceipt? {
        try PhotoMetadataSQLite.statement(db,"SELECT id,digest,receipt FROM metadata_receipts WHERE id=?") { s in
            try PhotoMetadataSQLite.bind(id.uuidString.lowercased(),1,s); var result:MetadataWriteReceipt?
            try PhotoMetadataSQLite.consume(s) { row in
                let receipt = try Self.decodeReceipt(row)
                guard receipt.payloadSHA256 == digest else { throw PhotoMetadataError.operationIDCollision }
                result = .init(operationID:receipt.operationID,payloadSHA256:receipt.payloadSHA256,committedAt:receipt.committedAt,affected:receipt.affected,disposition:.replayed)
            }; return result
        }
    }
    func saveReceipt(_ value:MetadataWriteReceipt,on db:OpaquePointer) throws {
        let bytes = try PhotoMetadataInternalCodec.encode(value)
        guard bytes.count <= PhotoMetadataLimits.maximumJournalBytes else { throw PhotoMetadataError.limitExceeded(.catalogChange) }
        try PhotoMetadataSQLite.statement(db,"INSERT INTO metadata_receipts(id,digest,receipt) VALUES(?,?,?)") { s in
            try PhotoMetadataSQLite.bind(value.operationID.uuidString.lowercased(),1,s); try PhotoMetadataSQLite.bind(value.payloadSHA256,2,s)
            try PhotoMetadataSQLite.bind(bytes,3,s); try PhotoMetadataSQLite.done(s)
        }
    }
    func ensureNotBlocked(_ id:String,on db:OpaquePointer) throws {
        if try journals(on:db,pendingOnly:true).contains(where:{ $0.receipt.blockedAssetIDs.contains(id) }) { throw PhotoMetadataError.relocationInProgress }
    }
    static func sameCurrentSource(_ lhs:MetadataSourceReference,_ rhs:MetadataSourceReference) -> Bool {
        guard lhs.original == rhs.original else { return false }
        if let l = lhs.nativeStamp, let r = rhs.nativeStamp {
            guard l.identity == r.identity, l.byteCount == r.byteCount, l.modifiedAt == r.modifiedAt, l.changedAt == r.changedAt else { return false }
            if let l = l.birthTime, let r = r.birthTime, l != r { return false }
            if let l = l.fileGeneration, let r = r.fileGeneration, l > 0, r > 0, l != r { return false }
        }
        if let l = lhs.analyzedRaster, let r = rhs.analyzedRaster, l.raster != r.raster { return false }
        return true
    }
    func ensureCatalogSourceMapCurrent(on db:OpaquePointer) throws {
        // A second repository may have reconciled a new catalog. Reading its
        // SQL reference does not supply this actor with that complete source map.
        // Source-sensitive writes call this inside their admitted transaction.
        try readState(db)
        guard (catalog?.persistedReference ?? .absent) == catalogReference else { throw PhotoMetadataError.catalogConflict }
    }
    func ensureSource(_ source:MetadataSourceReference,assetID:String,on db:OpaquePointer) throws {
        try ensureCatalogSourceMapCurrent(on:db)
        try PhotoMetadataValidation.source(source)
        if catalog != nil {
            guard let current = catalogByID[assetID], Self.sameCurrentSource(source,current) else { throw PhotoMetadataError.sourceChanged }
        }
    }
    func perform<T:Encodable>(id:UUID,assetID:String,expected:MetadataRecordVersion,kind:String,payload:T,
                              searchable:Bool,mutate:(inout PhotoMetadataRow,OpaquePointer) throws -> Void) throws -> MetadataCommitResult {
        try PhotoMetadataValidation.identifier(assetID); try PhotoMetadataValidation.version(expected)
        let hash = try PhotoMetadataInternalCodec.digest(kind:kind,payload:payload), db = try connection()
        let result = try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            if let prior = try receipt(id,digest:hash,on:db) { return prior }
            try ensureNotBlocked(assetID,on:db)
            var row = try readRow(assetID,on:db) ?? PhotoMetadataRow(assetID:assetID)
            guard row.version == expected else { throw PhotoMetadataError.revisionConflict }
            try mutate(&row,db); try saveRow(row,on:db)
            if searchable { try bumpSearch(db) }
            let result = MetadataWriteReceipt(operationID:id,payloadSHA256:hash,committedAt:Date(),affected:[.init(assetID:assetID,version:row.version)],disposition:.applied)
            try saveReceipt(result,on:db); return result
        }
        do {
            try readState(db)
            if snapshotAttemptedGeneration != searchGeneration { refreshSearch(db) }
        } catch { publishUnavailable(error) }
        var current:PhotoMetadataRecord?
        do { current = try readRow(assetID,on:db)?.value } catch { publishUnavailable(error) }
        return .init(receipt:result,currentRecord:current,searchState:state)
    }
    func _metadata_saveManualDraft(_ operation:MetadataManualDraftOperation) throws -> MetadataCommitResult {
        let mutation:MetadataManualDraftMutation
        switch operation.mutation {
        case .save(let fields,let base): mutation = .save(fields:try PhotoTextNormalization.normalize(fields),baseConfirmedRevision:base)
        case .discard: mutation = .discard
        }
        let normalized = MetadataManualDraftOperation(header:operation.header,mutation:mutation)
        return try perform(id:operation.header.id,assetID:operation.header.assetID,expected:operation.header.expectedVersion,
            kind:"manualDraft",payload:normalized,searchable:false) { row,_ in
            try row.advance(manual:true)
            switch mutation {
            case .save(let fields,let base):
                guard base >= 0, base <= row.version.confirmedRevision else { throw PhotoMetadataError.revisionConflict }
                row.manualDraft = .init(revision:row.version.manualDraftRevision,baseConfirmedRevision:base,fields:fields,modifiedAt:Date())
            case .discard: row.manualDraft = nil
            }
        }
    }
    func _metadata_saveAIDraft(_ operation:MetadataAIDraftOperation) throws -> MetadataCommitResult {
        let mutation:MetadataAIDraftMutation
        switch operation.mutation {
        case .createSuggested(let id,let fields,let source):
            try PhotoMetadataValidation.source(source)
            guard source.analyzedRaster != nil else { throw PhotoMetadataError.validation(.invalidProvenance) }
            mutation = .createSuggested(draftID:id,fields:try PhotoTextNormalization.normalize(fields,requireSuggestionContent:true),source:source)
        case .editExisting(let id,let fields): mutation = .editExisting(draftID:id,fields:try PhotoTextNormalization.normalize(fields,requireSuggestionContent:true))
        }
        let normalized = MetadataAIDraftOperation(header:operation.header,mutation:mutation)
        return try perform(id:operation.header.id,assetID:operation.header.assetID,expected:operation.header.expectedVersion,
            kind:"aiDraft",payload:normalized,searchable:false) { row,db in
            let now = Date()
            switch mutation {
            case .createSuggested(let id,let fields,let source):
                try ensureSource(source,assetID:row.assetID,on:db); try row.advance(ai:true)
                row.isOrphaned = catalog != nil ? catalogByID[row.assetID] == nil : row.isOrphaned
                row.draft = .init(id:id,revision:row.version.aiDraftRevision,baseConfirmedRevision:row.version.confirmedRevision,
                    fields:fields,source:source,state:.pending,createdAt:now,modifiedAt:now)
            case .editExisting(let id,let fields):
                guard let draft = row.draft, draft.id == id, [.pending,.edited].contains(draft.state) else { throw PhotoMetadataError.validation(.invalidDraftTransition) }
                var changed = draft.editedFields
                for field in PhotoMetadataField.allCases where Self.fieldChanged(field,draft.fields,fields) { changed.insert(field) }
                try row.advance(ai:true)
                row.draft = .init(id:id,revision:row.version.aiDraftRevision,baseConfirmedRevision:draft.baseConfirmedRevision,
                    fields:fields,source:draft.source,state:.edited,createdAt:draft.createdAt,modifiedAt:now,editedFields:changed)
            }
        }
    }
    func _metadata_setDraftState(_ operation:MetadataDraftStateOperation) throws -> MetadataCommitResult {
        try perform(id:operation.header.id,assetID:operation.header.assetID,expected:operation.header.expectedVersion,
            kind:"draftState",payload:operation,searchable:false) { row,_ in
            guard let draft = row.draft, draft.id == operation.draftID, draft.revision == operation.expectedDraftRevision,
                  [.pending,.edited,.outdated].contains(draft.state) else { throw PhotoMetadataError.validation(.invalidDraftTransition) }
            try row.advance(ai:true)
            row.draft = .init(id:draft.id,revision:row.version.aiDraftRevision,baseConfirmedRevision:draft.baseConfirmedRevision,
                fields:draft.fields,source:draft.source,state:.rejected,createdAt:draft.createdAt,modifiedAt:Date(),editedFields:draft.editedFields)
        }
    }
    func _metadata_confirm(_ operation:MetadataConfirmOperation) throws -> MetadataCommitResult {
        guard !operation.fields.isEmpty else { throw PhotoMetadataError.validation(.invalidFieldSelection) }
        let fields = try PhotoTextNormalization.normalize(operation.values)
        try PhotoMetadataValidation.source(operation.source)
        let normalized = MetadataConfirmOperation(header:operation.header,values:fields,fields:operation.fields,tagPolicy:operation.tagPolicy,source:operation.source,origin:operation.origin)
        return try perform(id:operation.header.id,assetID:operation.header.assetID,expected:operation.header.expectedVersion,
            kind:"confirm",payload:normalized,searchable:true) { row,db in
            try ensureSource(operation.source,assetID:row.assetID,on:db)
            let origin:MetadataFieldOrigin
            var proposal:PhotoMetadataDraft?
            var clearManual = false
            switch operation.origin {
            case .manual(let revision,let reviewed):
                guard reviewed == row.version.confirmedRevision, row.manualDraft?.revision == revision else { throw PhotoMetadataError.revisionConflict }
                origin = .manual; clearManual = row.manualDraft != nil && operation.fields == Set(PhotoMetadataField.allCases)
            case .proposal(let id,let revision):
                guard let draft = row.draft, draft.id == id, draft.revision == revision,
                      draft.baseConfirmedRevision == row.version.confirmedRevision, [.pending,.edited].contains(draft.state),
                      Self.sameCurrentSource(draft.source,operation.source),
                      let analysis = draft.source.analyzedRaster else { throw PhotoMetadataError.revisionConflict }
                proposal = draft
                let edited = draft.wasHumanEdited || operation.fields.contains(where:{ Self.fieldChanged($0,draft.fields,fields) })
                origin = .confirmedAI(.init(draftID:id,analysis:analysis,wasHumanEdited:edited))
            }
            var next = row.confirmed
            if operation.fields.contains(.title) { next.title = fields.title }
            if operation.fields.contains(.description) { next.description = fields.description }
            if operation.fields.contains(.language) { next.language = fields.language }
            if operation.fields.contains(.tags) { next.tags = try PhotoTextNormalization.mergingTags(existing:row.confirmed.tags,incoming:fields.tags,policy:operation.tagPolicy) }
            next = try PhotoTextNormalization.normalize(next)
            var tags = row.confirmedProvenance.tags
            if operation.fields.contains(.tags) {
                tags = next.tags.map { tag in
                    if operation.tagPolicy == .append, let existing = row.confirmedProvenance.tags.first(where:{ PhotoTextNormalization.tagKey($0.value) == PhotoTextNormalization.tagKey(tag) }) { return existing }
                    return .init(value:tag,origin:origin)
                }
            }
            row.confirmedProvenance = .init(title:operation.fields.contains(.title) ? origin : row.confirmedProvenance.title,
                description:operation.fields.contains(.description) ? origin : row.confirmedProvenance.description,tags:tags,
                language:operation.fields.contains(.language) ? origin : row.confirmedProvenance.language)
            try row.advance(confirmed:true,ai:proposal != nil,manual:clearManual)
            row.confirmed = next; row.confirmedAt = Date(); row.confirmedSource = operation.source
            let currentAssociation = catalogByID[row.assetID] ?? operation.source
            if currentAssociation.nativeStamp != nil { row.associationSource = currentAssociation }
            else if operation.source.nativeStamp != nil { row.associationSource = operation.source }
            else if row.associationSource?.original != currentAssociation.original { row.associationSource = currentAssociation }
            row.sourceChanged = false
            row.isOrphaned = catalog != nil ? catalogByID[row.assetID] == nil : row.isOrphaned
            if clearManual { row.manualDraft = nil }
            if let d = proposal {
                row.draft = .init(id:d.id,revision:row.version.aiDraftRevision,baseConfirmedRevision:d.baseConfirmedRevision,
                    fields:d.fields,source:d.source,state:.accepted,createdAt:d.createdAt,modifiedAt:Date(),appliedFields:operation.fields,editedFields:d.editedFields)
            }
        }
    }
    static func fieldChanged(_ field:PhotoMetadataField,_ a:PhotoTextFields,_ b:PhotoTextFields) -> Bool {
        switch field { case .title:return a.title != b.title;case .description:return a.description != b.description;case .tags:return a.tags != b.tags;case .language:return a.language != b.language }
    }
}
