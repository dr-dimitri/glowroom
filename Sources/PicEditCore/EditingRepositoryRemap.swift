import Foundation
import CSQLite

struct EditingRemapWire:Codable {
    let proposal:AssetRemapProposal
    let requestSHA256:ArtifactDigest,coordinatorRequestSHA256:ArtifactDigest
    let nonce:UUID
    var phase:AssetRemapPhase
    var receipt:EditingStateWire?
    var prepared:PreparedAssetRemap {.init(proposal:proposal,requestSHA256:requestSHA256,coordinatorRequestSHA256:coordinatorRequestSHA256,nonce:nonce)}
    func value() throws -> AssetRemapInspection {
        let receipt = try self.receipt.map {try AssetRemapReceipt(operationID:proposal.operationID,requestSHA256:requestSHA256,state:$0.value())}
        return .init(prepared:prepared,phase:phase,databaseReceipt:receipt)
    }
}

extension EditingRepository {
    static func decodeRemap(_ s:OpaquePointer) throws -> EditingRemapWire {
        let wire = try ArtifactJSONCodec.decode(EditingRemapWire.self,from:EditingSQLite.blob(s,2,maximum:67_108_864),maximum:67_108_864)
        try ArtifactValueValidation.remap(wire.proposal)
        guard try EditingSQLite.text(s,0,maximum:36) == wire.proposal.operationID.canonicalString,
              try EditingSQLite.text(s,1,maximum:32) == wire.phase.rawValue,
              try ArtifactJSONCodec.digest(wire.proposal) == wire.requestSHA256,
              (wire.receipt != nil) == [.databaseCommitted,.catalogCommitted,.completed].contains(wire.phase) else {throw EditingRepositoryError.invalidDatabase}
        if let receipt = wire.receipt {let state = try receipt.value();guard state.storeEpoch == wire.proposal.expectedStoreEpoch else {throw EditingRepositoryError.invalidDatabase}}
        return wire
    }
    static func remapWire(_ id:EditingRemapID,on db:OpaquePointer) throws -> EditingRemapWire? {
        try EditingSQLite.statement(db,"SELECT id,phase,journal FROM editing_remaps WHERE id=?") {s in
            try EditingSQLite.bind(id.canonicalString,1,s);var result:EditingRemapWire?;try EditingSQLite.consume(s){result = try decodeRemap($0)};return result
        }
    }
    func saveRemap(_ wire:EditingRemapWire,on db:OpaquePointer) throws {
        let bytes = try ArtifactJSONCodec.encode(wire);guard bytes.count <= 67_108_864 else {throw ArtifactContractError.limitExceeded}
        // Never commit a wire representation that its own bounded restart
        // decoder cannot admit (large global remap receipt snapshots included).
        _ = try ArtifactJSONCodec.decode(EditingRemapWire.self,from:bytes,maximum:67_108_864)
        try EditingSQLite.statement(db,"INSERT INTO editing_remaps(id,phase,journal) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET phase=excluded.phase,journal=excluded.journal") {s in
            try EditingSQLite.bind(wire.proposal.operationID.canonicalString,1,s);try EditingSQLite.bind(wire.phase.rawValue,2,s);try EditingSQLite.bind(bytes,3,s);try EditingSQLite.done(s)
        }
    }
    func ensureNoRemap(_ id:String?,on db:OpaquePointer) throws {
        try EditingSQLite.rows(db,"SELECT id,phase,journal FROM editing_remaps WHERE phase NOT IN ('completed','aborted')") {s in
            let wire = try Self.decodeRemap(s)
            if id == nil || wire.proposal.expectedByAsset[id!] != nil {throw CatalogCoordinationError.recoveryRequired}
        }
    }
    func validateEditingEvidence(_ journal:ValidatedCatalogCoordinatorJournal,proposal:AssetRemapProposal,digest:ArtifactDigest,on db:OpaquePointer) throws {
        let body = journal.value.body
        guard body.operationID == proposal.operationID.rawValue,body.catalog == proposal.catalog,
              let descriptor = body.requiredParticipants.first(where:{$0.store.kind == .editing}),
              descriptor.store == (try Self.identity(db)),descriptor.operationID == proposal.operationID.rawValue,
              descriptor.requestSHA256 == digest,descriptor.requestSchemaVersion == 1,
              descriptor.canonicalByteCount == Int64(try ArtifactJSONCodec.encode(proposal).count) else {throw CatalogCoordinationError.originalRequestMismatch(.editing)}
    }
    public func prepareAssetRemap(_ plan:VerifiedAssetRemap,preparingBy cap:CatalogParticipantPreparation) async throws -> PreparedAssetRemap {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.prepareRemap(plan,cap:cap)}
    }
    func prepareRemap(_ plan:VerifiedAssetRemap,cap:CatalogParticipantPreparation) async throws -> PreparedAssetRemap {
        try ArtifactValueValidation.remap(plan.proposal);let digest = try ArtifactJSONCodec.digest(plan.proposal)
        guard plan.verifiedFileEvidenceSHA256 == digest else {throw ArtifactContractError.invalidCapability}
        try await acquireMutation();defer{releaseMutation()};let db = try connection()
        let previous = try sql.read(db) { () throws -> PreparedAssetRemap? in
            try validateEditingEvidence(cap.journal,proposal:plan.proposal,digest:digest,on:db)
            if let prior = try Self.remapWire(plan.proposal.operationID,on:db) {
                guard prior.requestSHA256 == digest,prior.coordinatorRequestSHA256 == cap.journal.value.requestSHA256 else {throw ArtifactContractError.conflictingCommit};return prior.prepared
            };return nil
        }
        if let previous {return previous}
        guard cap.journal.value.phase == .prepared,cap.journal.value.disposition == .active else {throw CatalogCoordinationError.invalidPhase}
        return try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            try ensureNoRemap(nil,on:db)
            for (id,expected) in plan.proposal.expectedByAsset {try Self.require(expected,id:id,on:db)}
            let wire = EditingRemapWire(proposal:plan.proposal,requestSHA256:digest,coordinatorRequestSHA256:cap.journal.value.requestSHA256,nonce:UUID(),phase:.prepared,receipt:nil)
            try saveRemap(wire,on:db);return wire.prepared
        }
    }
    /// Pure inspection can run while startup is fenced. It never opens writable,
    /// mints missing state, migrates a participant or changes journal phases.
    public func inspectAssetRemap(_ id:EditingRemapID,expectedRequestSHA256:ArtifactDigest) throws -> AssetRemapInspection? {
        try EditingSQLite.readOnly(fileURL) {db,version in
            guard version == 2 else {throw EditingRepositoryError.recoveryRequired};try Self.validateRows(db,version)
            guard let wire = try Self.remapWire(id,on:db) else {return nil}
            guard wire.requestSHA256 == expectedRequestSHA256 else {throw ArtifactContractError.conflictingCommit};return try wire.value()
        } ?? nil
    }
    func requirePrepared(_ cap:PreparedAssetRemap,on db:OpaquePointer) throws -> EditingRemapWire {
        guard let wire = try Self.remapWire(cap.operationID,on:db),wire.nonce == cap.nonce,
              wire.requestSHA256 == cap.requestSHA256,wire.coordinatorRequestSHA256 == cap.coordinatorRequestSHA256,
              try ArtifactJSONCodec.encode(wire.proposal) == ArtifactJSONCodec.encode(cap.proposal) else {throw ArtifactContractError.invalidCapability};return wire
    }
    public func remapAssets(_ prepared:PreparedAssetRemap,armedBy cap:ArmedCatalogCoordination) async throws -> AssetRemapReceipt {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.executeRemap(prepared,cap:cap)}
    }
    func executeRemap(_ prepared:PreparedAssetRemap,cap:ArmedCatalogCoordination) async throws -> AssetRemapReceipt {
        try await acquireMutation();defer{releaseMutation()};let db = try connection()
        var wire = try sql.read(db) { () throws -> EditingRemapWire in
            let current = try requirePrepared(prepared,on:db)
            try validateEditingEvidence(cap.journal,proposal:current.proposal,digest:current.requestSHA256,on:db);return current
        }
        guard cap.journal.value.requestSHA256 == wire.coordinatorRequestSHA256,cap.journal.value.disposition == .active,
              [.armed,.editingCommitted,.catalogPublished].contains(cap.journal.value.phase) else {throw CatalogCoordinationError.invalidPhase}
        if let receipt = wire.receipt {return try .init(operationID:prepared.operationID,requestSHA256:wire.requestSHA256,state:receipt.value())}
        guard wire.phase == .prepared else {throw CatalogCoordinationError.invalidPhase}
        // Native authorization is freshly reproved against the ORIGINAL command.
        _ = try await AssetRemapVerifier().verify(wire.proposal)
        return try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            wire = try requirePrepared(prepared,on:db)
            if let receipt = wire.receipt {return try .init(operationID:prepared.operationID,requestSHA256:wire.requestSHA256,state:receipt.value())}
            for (id,expected) in wire.proposal.expectedByAsset {try Self.require(expected,id:id,on:db)}
            // The SQL transaction is short and synchronous. Stat one final time
            // before writes; do not await a file worker while holding SQL locks.
            for e in wire.proposal.entries {
                let fresh = try AssetRemapVerifier.capture(URL(fileURLWithPath:e.relocated.standardizedPath),referenceDate:e.relocated.modifiedAt)
                guard fresh.nativeRevision == e.relocated.nativeRevision else {throw ArtifactContractError.sourceChanged}
            }
            for e in wire.proposal.entries {
                let old = try Self.current(e.oldAssetID,on:db),target = try Self.current(e.newAssetID,on:db)
                guard target.snapshot == nil,try countVariants(e.newAssetID,on:db) == 0 else {throw ArtifactContractError.staleSnapshot}
                let revision = max(old.revision ?? -1,target.revision ?? -1)
                guard revision < Int64.max else {throw ArtifactContractError.limitExceeded}
                try Self.write(old.snapshot,id:e.newAssetID,revision:revision+1,on:db)
                try Self.write(nil,id:e.oldAssetID,revision:revision+1,on:db)
                try EditingSQLite.statement(db,"UPDATE editing_variants SET asset_id=? WHERE asset_id=?") {s in
                    try EditingSQLite.bind(e.newAssetID,1,s);try EditingSQLite.bind(e.oldAssetID,2,s);try EditingSQLite.done(s)
                }
            }
            let state = try Self.readState(db,version:2);wire.phase = .databaseCommitted;wire.receipt = EditingStateWire(state)
            try saveRemap(wire,on:db)
            return .init(operationID:prepared.operationID,requestSHA256:wire.requestSHA256,state:state)
        }
    }
    func countVariants(_ id:String,on db:OpaquePointer) throws -> Int {
        try EditingSQLite.statement(db,"SELECT count(*) FROM editing_variants WHERE asset_id=?") {s in
            try EditingSQLite.bind(id,1,s);var result = 0;try EditingSQLite.consume(s){result = Int(sqlite3_column_int64($0,0))};return result
        }
    }
    public func confirmCatalogRemap(_ prepared:PreparedAssetRemap,publication:CatalogPublicationEvidence) async throws {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.advanceRemap(prepared,publication:publication,completed:false)}
    }
    public func completeAssetRemap(_ prepared:PreparedAssetRemap,publication:CatalogPublicationEvidence) async throws -> AssetRemapReceipt {
        try await gate.withRepositoryAccess(domain:.editing) {
            try await self.advanceRemap(prepared,publication:publication,completed:true)
            return try await self.remapReceipt(prepared)
        }
    }
    func remapReceipt(_ prepared:PreparedAssetRemap) throws -> AssetRemapReceipt {
        let db = try connection()
        return try sql.read(db) {
            let wire = try requirePrepared(prepared,on:db)
            guard let receipt = wire.receipt else {throw CatalogCoordinationError.recoveryRequired}
            return try .init(operationID:prepared.operationID,requestSHA256:wire.requestSHA256,state:receipt.value())
        }
    }
    func advanceRemap(_ prepared:PreparedAssetRemap,publication:CatalogPublicationEvidence,completed:Bool) async throws {
        try await acquireMutation();defer{releaseMutation()};let db = try connection()
        let initial = try sql.read(db) { () throws -> EditingRemapWire in
            let current = try requirePrepared(prepared,on:db)
            try validateEditingEvidence(publication.journal,proposal:current.proposal,digest:current.requestSHA256,on:db);return current
        }
        guard publication.journal.value.requestSHA256 == initial.coordinatorRequestSHA256,publication.published == initial.proposal.catalog.after,
              [.catalogPublished,.completed].contains(publication.journal.value.phase) else {throw CatalogCoordinationError.invalidPhase}
        try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            var wire = try requirePrepared(prepared,on:db)
            guard wire.receipt != nil,[.databaseCommitted,.catalogCommitted,.completed].contains(wire.phase) else {throw CatalogCoordinationError.recoveryRequired}
            if wire.phase == .completed {return}
            wire.phase = completed ? .completed : .catalogCommitted;try saveRemap(wire,on:db)
        }
    }
    public func cancelPreparedAssetRemap(_ prepared:PreparedAssetRemap,abortedBy decision:CatalogCoordinationAbort) async throws {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.abortRemap(prepared,decision:decision)}
    }
    func abortRemap(_ prepared:PreparedAssetRemap,decision:CatalogCoordinationAbort) async throws {
        try await acquireMutation();defer{releaseMutation()};let db = try connection()
        let wire = try sql.read(db) { () throws -> EditingRemapWire in
            let current = try requirePrepared(prepared,on:db)
            try validateEditingEvidence(decision.journal,proposal:current.proposal,digest:current.requestSHA256,on:db);return current
        }
        guard decision.journal.value.requestSHA256 == wire.coordinatorRequestSHA256,decision.journal.value.phase == .prepared,
              decision.journal.value.disposition == .aborted else {throw CatalogCoordinationError.invalidPhase}
        try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            var current = try requirePrepared(prepared,on:db)
            if current.phase == .aborted {return}
            guard current.phase == .prepared,current.receipt == nil else {throw CatalogCoordinationError.recoveryRequired}
            current.phase = .aborted;try saveRemap(current,on:db)
        }
    }
}
