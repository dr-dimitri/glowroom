import Foundation
import CSQLite

extension PhotoMetadataRepository {
    static func metadataIdentity(_ db:OpaquePointer) throws -> CatalogParticipantStoreIdentity {
        guard try PhotoMetadataSQLite.version(db) == 2 else {throw PhotoMetadataError.recoveryRequired}
        var id:UUID?
        try PhotoMetadataSQLite.rows(db,"SELECT singleton,store_id FROM metadata_identity") {s in
            let text = try PhotoMetadataSQLite.text(s,1,maximum:36)
            guard sqlite3_column_type(s,0) == SQLITE_INTEGER,sqlite3_column_int64(s,0) == 1,
                  let value = UUID(uuidString:text),text == value.uuidString.lowercased(),id == nil else {throw PhotoMetadataError.corruptStore};id = value
        }
        guard let id else {throw PhotoMetadataError.corruptStore};return .init(kind:.photoMetadata,durableStoreID:id)
    }
    public func participantStoreIdentity() async throws -> CatalogParticipantStoreIdentity {
        try await withMetadataAccess {try await self.currentMetadataIdentity()}
    }
    func currentMetadataIdentity() throws -> CatalogParticipantStoreIdentity {try Self.metadataIdentity(connection())}
    public func inspectParticipantIdentity() throws -> CatalogParticipantStoreIdentity? {
        try PhotoMetadataSQLite.inspect(at:fileURL) {db,version in
            guard version == 2 else {throw PhotoMetadataError.recoveryRequired}
            try Self.validateDatabase(db);return try Self.metadataIdentity(db)
        }
    }
    static func coordinationLink(_ id:UUID,on db:OpaquePointer) throws -> String? {
        try PhotoMetadataSQLite.statement(db,"SELECT coordinator_sha FROM metadata_coordinations WHERE id=?") {s in
            try PhotoMetadataSQLite.bind(id.uuidString.lowercased(),1,s);var result:String?
            try PhotoMetadataSQLite.consume(s) {result = try PhotoMetadataSQLite.text($0,0,maximum:64)};return result
        }
    }
    func ensureNoCoordinatedPending() throws {
        let db = try connection();var blocked = false
        try PhotoMetadataSQLite.rows(db,"SELECT c.id FROM metadata_coordinations c JOIN metadata_catalog_changes j ON j.id=c.id WHERE j.state IN ('staged','conflicted') LIMIT 1") {_ in blocked = true}
        guard !blocked else {throw PhotoMetadataError.recoveryRequired}
    }
    func validateMetadataEvidence(_ journal:ValidatedCatalogCoordinatorJournal,id:UUID,digest:String,bytes:Int? = nil,on db:OpaquePointer) throws {
        let body = journal.value.body
        guard body.operationID == id,body.catalog.operationID == id,
              let descriptor = body.requiredParticipants.first(where:{$0.store.kind == .photoMetadata}),
              descriptor.store == (try Self.metadataIdentity(db)),descriptor.operationID == id,
              descriptor.requestSchemaVersion == 1,descriptor.requestSHA256.sha256 == digest,
              bytes.map({descriptor.canonicalByteCount == Int64($0)}) ?? true else {throw CatalogCoordinationError.originalRequestMismatch(.photoMetadata)}
    }
    public func stageCoordinatedCatalogChange(_ change:MetadataCatalogChange,preparingBy cap:CatalogParticipantPreparation) async throws -> MetadataCatalogChangeReceipt {
        try await withMetadataAccess {try await self.stageMetadata(change,cap:cap)}
    }
    func stageMetadata(_ change:MetadataCatalogChange,cap:CatalogParticipantPreparation) throws -> MetadataCatalogChangeReceipt {
        let db = try connection(),digest = try PhotoMetadataInternalCodec.digest(kind:"catalogChange",payload:change)
        try validateMetadataEvidence(cap.journal,id:change.id,digest:digest,bytes:PhotoMetadataInternalCodec.encode(change).count,on:db)
        guard cap.journal.value.phase == .prepared,cap.journal.value.disposition == .active,
              cap.journal.value.body.catalog.before == change.before,cap.journal.value.body.catalog.after == change.after else {throw CatalogCoordinationError.invalidPhase}
        return try _metadata_stageCatalogChange(change,coordinatorSHA:cap.journal.value.requestSHA256.sha256)
    }
    public func inspectCatalogChange(id:UUID,expectedRequestSHA256:String) throws -> MetadataCatalogParticipantInspection? {
        try PhotoMetadataSQLite.inspect(at:fileURL) {db,version in
            guard version == 2 else {throw PhotoMetadataError.recoveryRequired};try Self.validateDatabase(db)
            let journal:PhotoMetadataJournal? = try PhotoMetadataSQLite.statement(db,"SELECT id,state,journal FROM metadata_catalog_changes WHERE id=?") {s in
                try PhotoMetadataSQLite.bind(id.uuidString.lowercased(),1,s);var value:PhotoMetadataJournal?
                try PhotoMetadataSQLite.consume(s){value = try Self.decodeJournal($0)};return value
            }
            guard let journal else {return nil}
            guard journal.receipt.payloadSHA256 == expectedRequestSHA256 else {throw PhotoMetadataError.operationIDCollision}
            guard let link = try Self.coordinationLink(id,on:db) else {throw PhotoMetadataError.recoveryRequired}
            return MetadataCatalogParticipantInspection(store:try Self.metadataIdentity(db),originalChange:journal.change,receipt:journal.receipt,
                coordinatorRequestSHA256:try ArtifactDigest(sha256:link))
        } ?? nil
    }
    func validateMetadataPublication(_ id:UUID,publication:CatalogPublicationEvidence,on db:OpaquePointer) throws {
        guard let j = try journal(id,on:db),let sha = try Self.coordinationLink(id,on:db),sha == publication.journal.value.requestSHA256.sha256,
              publication.published == j.change.after,publication.journal.value.body.catalog.after == j.change.after,
              [.catalogPublished,.completed].contains(publication.journal.value.phase) else {throw CatalogCoordinationError.invalidPhase}
        try validateMetadataEvidence(publication.journal,id:id,digest:j.receipt.payloadSHA256,on:db)
    }
    public func completeCoordinatedCatalogChange(id:UUID,publication:CatalogPublicationEvidence,persistedCatalog snapshot:MetadataCatalogSnapshot) async throws -> MetadataReconciliationResult {
        try await withMetadataAccess {try await self.completeMetadata(id,publication:publication,snapshot:snapshot)}
    }
    func completeMetadata(_ id:UUID,publication:CatalogPublicationEvidence,snapshot:MetadataCatalogSnapshot) throws -> MetadataReconciliationResult {
        let db = try connection();try validateMetadataPublication(id,publication:publication,on:db)
        let result = try _metadata_completeCatalogChange(id:id,persistedCatalog:snapshot,coordinated:true)
        // Coordinator sessions are not UI sessions. Require the Library's next
        // explicit reconcile before admitting ordinary source-sensitive writes.
        // Retain only the verified current map for explicit conflict resolution.
        catalog = nil
        let own = try journal(id,on:db)?.receipt
        return .init(searchState:result.searchState,changes:result.changes.filter{$0.changeID != id} + (own.map{[$0]} ?? []))
    }
    public func abortCoordinatedCatalogChange(id:UUID,decision:CatalogCoordinationAbort) async throws {
        try await withMetadataAccess {try await self.abortMetadata(id,decision:decision)}
    }
    func abortMetadata(_ id:UUID,decision:CatalogCoordinationAbort) throws {
        let db = try connection()
        guard let existing = try journal(id,on:db) else {throw PhotoMetadataError.recoveryRequired}
        try validateMetadataEvidence(decision.journal,id:id,digest:existing.receipt.payloadSHA256,on:db)
        guard decision.journal.value.phase == .prepared,decision.journal.value.disposition == .aborted,
              try Self.coordinationLink(id,on:db) == decision.journal.value.requestSHA256.sha256 else {throw CatalogCoordinationError.invalidPhase}
        try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            guard var current = try journal(id,on:db) else {throw PhotoMetadataError.recoveryRequired}
            if current.receipt.state == .abandoned {return}
            guard current.receipt.state == .staged else {throw PhotoMetadataError.recoveryRequired}
            current.receipt = try updatedReceipt(current,state:.abandoned,conflicts:[]);try saveJournal(current,on:db)
        }
    }
    public func resolveCoordinatedCatalogChange(_ operation:MetadataCatalogResolutionOperation,publication:CatalogPublicationEvidence) async throws -> MetadataReconciliationResult {
        try await withMetadataAccess {try await self.resolveMetadata(operation,publication:publication)}
    }
    func resolveMetadata(_ operation:MetadataCatalogResolutionOperation,publication:CatalogPublicationEvidence) throws -> MetadataReconciliationResult {
        try validateMetadataPublication(operation.changeID,publication:publication,on:connection())
        return try _metadata_resolveCatalogChange(operation)
    }
}
