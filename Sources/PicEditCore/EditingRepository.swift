import Foundation
import CSQLite
import Darwin

struct EditingRepositoryHooks:Sendable {
    var beforeCommit:@Sendable () throws -> Void = {}
    var databaseContention:@Sendable () -> Void = {}
    var afterPublication:@Sendable () throws -> Void = {}
    var legacyMigration:@Sendable(EditingLegacyMigrationCheckpoint)throws->Void = {_ in}
    var beforeRecoveryInstall:@Sendable () throws -> Void = {}
    var recoveryCheckpoint:@Sendable(EditingRecoveryCheckpoint) -> Void = {_ in}
}
struct EditingCommitWire:Codable {
    let commitID:EditingCommitID, assetID:String, requestSHA256:ArtifactDigest
    let previous:EditingExpectedState, snapshot:EditingSnapshot, version:EditingStoreVersion, artifactID:GeneratedArtifactID
    var value:ArtifactCommitReceipt { .init(commitID:commitID,assetID:assetID,requestSHA256:requestSHA256,previous:previous,
        stored:.init(snapshot:snapshot,version:version),artifactID:artifactID) }
}
struct EditingVariantWire:Codable {
    let id:EditingVariantID,assetID:String,snapshot:EditingSnapshot,createdAt:Date
    var value:EditingVariant {.init(id:id,assetID:assetID,snapshot:snapshot,createdAt:createdAt)}
}
struct EditingStateWire:Codable {
    struct Entry:Codable {let snapshot:EditingSnapshot;let version:EditingStoreVersion}
    let storeEpoch:UUID,byAsset:[String:Entry],tombstones:[String:Int64]
    init(_ state:EditingStoreState) {storeEpoch = state.storeEpoch;byAsset = state.byAsset.mapValues{.init(snapshot:$0.snapshot,version:$0.version)};tombstones = state.tombstones}
    func value() throws -> EditingStoreState {
        guard byAsset.count <= 1_000_000,tombstones.count <= 1_000_000 else {throw ArtifactContractError.limitExceeded}
        for (id,e) in byAsset {try ArtifactValueValidation.identifier(id);try ArtifactValueValidation.snapshot(e.snapshot);guard e.version.revision >= 0 else {throw EditingRepositoryError.invalidDatabase}}
        for id in tombstones.keys {try ArtifactValueValidation.identifier(id)}
        return try .init(storeEpoch:storeEpoch,byAsset:byAsset.mapValues{.init(snapshot:$0.snapshot,version:$0.version)},tombstones:tombstones)
    }
}

/// One durable source/snapshot owner. The mutation permit spans artifact/backup
/// awaits; actor isolation alone does not serialize those dependent operations.
public actor EditingRepository:CoordinatedEditingStoring {
    public nonisolated let fileURL:URL
    public nonisolated let backupsDirectory:URL
    let sql:EditingSQLite
    let artifacts:any GeneratedArtifactStoring
    let packages:any EditingBackupPackageIO
    let gate:CatalogLifecycleGate
    let resources:(any ArtifactResourceAdmitting)?
    public internal(set) var backupMaintenanceWarning:String?
    public internal(set) var artifactRecoveryReport:ArtifactRecoveryReport?
    let hooks:EditingRepositoryHooks
    var mutating = false
    var mutationWaiters:[(UUID,CheckedContinuation<Void,Error>)] = []
    public init(directory:URL,artifacts:any GeneratedArtifactStoring,packages:any EditingBackupPackageIO,gate:CatalogLifecycleGate,resources:(any ArtifactResourceAdmitting)? = nil) {
        sql = EditingSQLite(directory:directory);fileURL = sql.url
        backupsDirectory = directory.appendingPathComponent("EditBackups",isDirectory:true)
        self.artifacts = artifacts;self.packages = packages;self.gate = gate;self.resources = resources;hooks = .init()
    }
    init(directory:URL,artifacts:any GeneratedArtifactStoring,packages:any EditingBackupPackageIO,gate:CatalogLifecycleGate,hooks:EditingRepositoryHooks) {
        sql = EditingSQLite(directory:directory,legacyCheckpoint:hooks.legacyMigration,onContention:hooks.databaseContention);fileURL = sql.url;backupsDirectory = directory.appendingPathComponent("EditBackups",isDirectory:true)
        self.artifacts = artifacts;self.packages = packages;self.gate = gate;resources = nil;self.hooks = hooks
    }
    func connection() throws -> OpaquePointer { try sql.open(validateRows:Self.validateRows) }
    func acquireMutation() async throws {
        try Task.checkCancellation()
        if !mutating {mutating = true;return}
        guard mutationWaiters.count < 64 else {throw ArtifactContractError.limitExceeded}
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in mutationWaiters.append((id,continuation)) }
        } onCancel:{Task {await self.cancelMutation(id)}}
        if Task.isCancelled {releaseMutation();throw CancellationError()}
    }
    func cancelMutation(_ id:UUID) {if let i = mutationWaiters.firstIndex(where:{$0.0 == id}) {mutationWaiters.remove(at:i).1.resume(throwing:CancellationError())}}
    func releaseMutation() {if mutationWaiters.isEmpty {mutating = false} else {mutationWaiters.removeFirst().1.resume()}}
    public func loadState() async throws -> EditingStoreState {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.readCurrentState()}
    }
    func readCurrentState() throws -> EditingStoreState {let db = try connection();return try sql.read(db){try Self.readState(db,version:2)}}
    public func participantStoreIdentity() async throws -> CatalogParticipantStoreIdentity {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.identity()}
    }
    func identity() throws -> CatalogParticipantStoreIdentity {let db = try connection();return try sql.read(db){try Self.identity(db)}}
    static func identity(_ db:OpaquePointer) throws -> CatalogParticipantStoreIdentity {
        var result:UUID?
        try EditingSQLite.rows(db,"SELECT store_id FROM editing_state WHERE singleton=1") {s in
            let text = try EditingSQLite.text(s,0,maximum:36)
            guard let id = UUID(uuidString:text),text == id.uuidString.lowercased(),result == nil else {throw EditingRepositoryError.invalidDatabase};result = id
        }
        guard let result else {throw EditingRepositoryError.invalidDatabase}
        return .init(kind:.editing,durableStoreID:result)
    }
    public func inspectParticipantIdentity() throws -> CatalogParticipantStoreIdentity? {
        try EditingSQLite.readOnly(fileURL) {db,version in
            guard version == 2 else {throw EditingRepositoryError.recoveryRequired}
            try Self.validateRows(db,version);return try Self.identity(db)
        }
    }
    static func epoch(_ db:OpaquePointer) throws -> UUID {
        var result:UUID?
        try EditingSQLite.rows(db,"SELECT singleton,store_epoch FROM editing_state") {s in
            let text = try EditingSQLite.text(s,1,maximum:36)
            guard sqlite3_column_type(s,0) == SQLITE_INTEGER,sqlite3_column_int64(s,0) == 1,
                let id = UUID(uuidString:text),text == id.uuidString.lowercased(),result == nil else {throw EditingRepositoryError.invalidDatabase};result = id
        };guard let result else {throw EditingRepositoryError.invalidDatabase};return result
    }
    static func readState(_ db:OpaquePointer,version:Int) throws -> EditingStoreState {
        if sqlite3_get_autocommit(db) == 0 {return try readStateBody(db,version:version)}
        // Revisions, snapshots and epoch must describe ONE SQL read snapshot,
        // even when another repository/process commits between SELECTs.
        try EditingSQLite.exec(db,"BEGIN DEFERRED")
        do {let state = try readStateBody(db,version:version);try EditingSQLite.exec(db,"COMMIT");return state}
        catch {try? EditingSQLite.exec(db,"ROLLBACK");throw error}
    }
    static func readStateBody(_ db:OpaquePointer,version:Int) throws -> EditingStoreState {
        let epoch = try version == 2 ? epoch(db) : UUID()
        var revisions:[String:Int64] = [:],byAsset:[String:StoredEditingState] = [:]
        try EditingSQLite.rows(db,"SELECT asset_id,revision FROM edit_revisions") {s in
            let id = try EditingSQLite.text(s,0,maximum:16_384);try ArtifactValueValidation.identifier(id)
            let revision = sqlite3_column_int64(s,1)
            guard sqlite3_column_type(s,1) == SQLITE_INTEGER,revision >= 0,revisions.count < 1_000_000 else {throw EditingRepositoryError.invalidDatabase};revisions[id] = revision
        }
        let query = version == 2 ? "SELECT asset_id,snapshot FROM editing_snapshots" : "SELECT asset_id,settings FROM adjustments"
        try EditingSQLite.rows(db,query) {s in
            let id = try EditingSQLite.text(s,0,maximum:16_384),data = try EditingSQLite.blob(s,1,maximum:65_536)
            let snapshot:EditingSnapshot
            if version == 2 {snapshot = try ArtifactJSONCodec.decode(EditingSnapshot.self,from:data)}
            else {snapshot = try EditingSnapshot(settings:JSONDecoder().decode(EditSettings.self,from:data))}
            try ArtifactValueValidation.snapshot(snapshot)
            guard let revision = revisions.removeValue(forKey:id) else {throw EditingRepositoryError.invalidDatabase}
            byAsset[id] = .init(snapshot:snapshot,version:try .init(storeEpoch:epoch,revision:revision))
        }
        return try .init(storeEpoch:epoch,byAsset:byAsset,tombstones:revisions)
    }
    static func validateRows(_ db:OpaquePointer,_ version:Int) throws {
        let state = try readState(db,version:version)
        guard version == 2 else {return}
        _ = try identity(db)
        var descriptors:[GeneratedArtifactID:GeneratedArtifact] = [:]
        try EditingSQLite.rows(db,"SELECT id,descriptor FROM generated_artifacts") {s in
            let id = try EditingSQLite.text(s,0,maximum:36)
            let value = try ArtifactJSONCodec.decode(GeneratedArtifact.self,from:EditingSQLite.blob(s,1,maximum:65_536))
            try ArtifactValueValidation.artifact(value)
            guard id == value.id.canonicalString,descriptors.count < 4_096 else {throw EditingRepositoryError.invalidDatabase};descriptors[value.id] = value
        }
        func check(_ snapshot:EditingSnapshot) throws {
            if case .artifact(let id) = snapshot.source,descriptors[id] == nil {throw ArtifactContractError.missingArtifact}
        }
        for entry in state.byAsset.values {try check(entry.snapshot)}
        var variants = 0
        try EditingSQLite.rows(db,"SELECT id,asset_id,snapshot,created_at FROM editing_variants") {s in
            let id = try EditingSQLite.text(s,0,maximum:36),assetID = try EditingSQLite.text(s,1,maximum:16_384)
            guard let uuid = UUID(uuidString:id),id == uuid.uuidString.lowercased(),sqlite3_column_type(s,3) == SQLITE_FLOAT || sqlite3_column_type(s,3) == SQLITE_INTEGER,
                  sqlite3_column_double(s,3).isFinite,variants < 100_000 else {throw EditingRepositoryError.invalidDatabase}
            try ArtifactValueValidation.identifier(assetID);let snapshot = try ArtifactJSONCodec.decode(EditingSnapshot.self,from:EditingSQLite.blob(s,2,maximum:65_536));try check(snapshot);variants += 1
        }
        for a in descriptors.values {
            if case .artifact(let parent) = a.provenance.parentSource {
                guard let p = descriptors[parent.artifactID],p.manifestSHA256 == parent.manifestSHA256,p.raster == parent.raster else {throw ArtifactContractError.missingArtifact}
            }
        }
        // Detect a forged provenance cycle instead of looping during backup.
        for id in descriptors.keys {var seen = Set<GeneratedArtifactID>(),current:GeneratedArtifactID? = id
            while let c = current {guard seen.insert(c).inserted else {throw ArtifactContractError.corruptArtifact};if case .artifact(let p) = descriptors[c]?.provenance.parentSource {current = p.artifactID}else{current = nil}}
        }
        try EditingSQLite.rows(db,"SELECT id,request_sha,receipt FROM artifact_commits") {s in _ = try decodeCommit(s)}
        try EditingSQLite.rows(db,"SELECT id,phase,journal FROM editing_remaps") {s in _ = try decodeRemap(s)}
    }
    static func current(_ id:String,on db:OpaquePointer) throws -> EditingExpectedState {
        var result = try EditingExpectedState(storeEpoch:epoch(db),revision:nil,snapshot:nil)
        try EditingSQLite.statement(db,"SELECT r.revision,s.snapshot FROM edit_revisions r LEFT JOIN editing_snapshots s ON s.asset_id=r.asset_id WHERE r.asset_id=?") {s in
            try EditingSQLite.bind(id,1,s);try EditingSQLite.consume(s) {s in
                guard sqlite3_column_type(s,0) == SQLITE_INTEGER else {throw EditingRepositoryError.invalidDatabase}
                let snapshot = sqlite3_column_type(s,1) == SQLITE_NULL ? nil : try ArtifactJSONCodec.decode(EditingSnapshot.self,from:EditingSQLite.blob(s,1,maximum:65_536))
                result = try .init(storeEpoch:result.storeEpoch,revision:sqlite3_column_int64(s,0),snapshot:snapshot)
            }
        };return result
    }
    static func require(_ expected:EditingExpectedState,id:String,on db:OpaquePointer) throws {
        try ArtifactValueValidation.expected(expected);let actual = try current(id,on:db)
        guard expected.storeEpoch == actual.storeEpoch else {throw ArtifactContractError.staleEpoch}
        guard actual == expected else {throw ArtifactContractError.staleSnapshot}
    }
    static func write(_ snapshot:EditingSnapshot?,id:String,revision:Int64,on db:OpaquePointer) throws {
        guard revision >= 0 else {throw ArtifactContractError.invalidValue("revision")}
        try EditingSQLite.statement(db,"INSERT INTO edit_revisions(asset_id,revision) VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET revision=excluded.revision") {s in
            try EditingSQLite.bind(id,1,s);guard sqlite3_bind_int64(s,2,revision) == SQLITE_OK else {throw EditingRepositoryError.storageFailure};try EditingSQLite.done(s)
        }
        if let snapshot {
            try ArtifactValueValidation.snapshot(snapshot)
            try EditingSQLite.statement(db,"INSERT INTO editing_snapshots(asset_id,snapshot) VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET snapshot=excluded.snapshot") {s in
                try EditingSQLite.bind(id,1,s);try EditingSQLite.bind(ArtifactJSONCodec.encode(snapshot),2,s);try EditingSQLite.done(s)
            }
        } else {try EditingSQLite.statement(db,"DELETE FROM editing_snapshots WHERE asset_id=?") {s in try EditingSQLite.bind(id,1,s);try EditingSQLite.done(s)}}
    }
    public func saveSnapshot(_ snapshot:EditingSnapshot,for assetID:String,expected:EditingExpectedState,revision:Int64) async throws -> StoredEditingState {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.save(snapshot,for:assetID,expected:expected,revision:revision)}
    }
    func save(_ snapshot:EditingSnapshot,for id:String,expected:EditingExpectedState,revision:Int64) async throws -> StoredEditingState {
        try ArtifactValueValidation.identifier(id);try ArtifactValueValidation.snapshot(snapshot);try ArtifactValueValidation.expected(expected)
        try await acquireMutation();defer{releaseMutation()}
        let db = try connection()
        if case .artifact(let artifactID) = snapshot.source {
            let descriptor = try await artifacts.descriptor(artifactID)
            // The actor hop can outlive native-family changes. Validate the
            // live connection before the first post-await SQL descriptor read.
            let checked = try connection()
            guard checked == db else {throw EditingRepositoryError.recoveryRequired}
            try sql.read(checked){guard try Self.descriptor(artifactID,on:checked) == descriptor else {throw ArtifactContractError.missingArtifact}}
        }
        return try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            let actual = try Self.current(id,on:db)
            // Exact retry after an observer lost its successful response.
            if actual.storeEpoch == expected.storeEpoch,actual.revision == revision,actual.snapshot == snapshot {return .init(snapshot:snapshot,version:try .init(storeEpoch:actual.storeEpoch,revision:revision))}
            try Self.require(expected,id:id,on:db)
            guard revision >= 0,expected.revision.map({revision > $0}) != false else {throw ArtifactContractError.staleSnapshot}
            try ensureNoRemap(id,on:db);try Self.write(snapshot,id:id,revision:revision,on:db)
            return .init(snapshot:snapshot,version:try .init(storeEpoch:actual.storeEpoch,revision:revision))
        }
    }
    static func descriptor(_ id:GeneratedArtifactID,on db:OpaquePointer) throws -> GeneratedArtifact? {
        try EditingSQLite.statement(db,"SELECT descriptor FROM generated_artifacts WHERE id=?") {s in
            try EditingSQLite.bind(id.canonicalString,1,s);var result:GeneratedArtifact?
            try EditingSQLite.consume(s) {
                let value = try ArtifactJSONCodec.decode(GeneratedArtifact.self,from:EditingSQLite.blob($0,0,maximum:65_536))
                try ArtifactValueValidation.artifact(value);guard value.id == id else {throw EditingRepositoryError.invalidDatabase};result = value
            };return result
        }
    }
    static func register(_ descriptor:GeneratedArtifact,on db:OpaquePointer) throws {
        try ArtifactValueValidation.artifact(descriptor)
        if let previous = try self.descriptor(descriptor.id,on:db) {guard previous == descriptor else {throw ArtifactContractError.corruptArtifact};return}
        guard try EditingSQLite.scalar(db,"SELECT count(*) FROM generated_artifacts") < 4_096 else {throw ArtifactContractError.limitExceeded}
        if case .artifact(let p) = descriptor.provenance.parentSource {
            guard let parent = try self.descriptor(p.artifactID,on:db),parent.manifestSHA256 == p.manifestSHA256,parent.raster == p.raster else {throw ArtifactContractError.missingArtifact}
        }
        try EditingSQLite.statement(db,"INSERT INTO generated_artifacts(id,descriptor) VALUES(?,?)") {s in
            try EditingSQLite.bind(descriptor.id.canonicalString,1,s);try EditingSQLite.bind(ArtifactJSONCodec.encode(descriptor),2,s);try EditingSQLite.done(s)
        }
    }
    static func decodeCommit(_ s:OpaquePointer) throws -> EditingCommitWire {
        let value = try ArtifactJSONCodec.decode(EditingCommitWire.self,from:EditingSQLite.blob(s,2,maximum:131_072),maximum:131_072)
        guard try EditingSQLite.text(s,0,maximum:36) == value.commitID.canonicalString,
            try EditingSQLite.text(s,1,maximum:64) == value.requestSHA256.sha256,value.version.revision >= 0,
            value.snapshot.source == .artifact(value.artifactID),value.snapshot.settings == .neutral,
            value.previous.storeEpoch == value.version.storeEpoch else {throw EditingRepositoryError.invalidDatabase}
        try ArtifactValueValidation.identifier(value.assetID);try ArtifactValueValidation.expected(value.previous);try ArtifactValueValidation.snapshot(value.snapshot)
        return value
    }
    func commitWire(_ id:EditingCommitID,on db:OpaquePointer) throws -> EditingCommitWire? {
        try EditingSQLite.statement(db,"SELECT id,request_sha,receipt FROM artifact_commits WHERE id=?") {s in
            try EditingSQLite.bind(id.canonicalString,1,s);var result:EditingCommitWire?;try EditingSQLite.consume(s){result = try Self.decodeCommit($0)};return result
        }
    }
    public func committed(_ commitID:EditingCommitID) async throws -> ArtifactCommitReceipt? {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.lookupCommit(commitID)}
    }
    func lookupCommit(_ id:EditingCommitID) throws -> ArtifactCommitReceipt? {let db = try connection();return try sql.read(db){try commitWire(id,on:db)?.value}}
    public func commitGenerated(_ request:GenerationCommitRequest) async throws -> ArtifactCommitReceipt {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.commit(request)}
    }
    func commit(_ r:GenerationCommitRequest) async throws -> ArtifactCommitReceipt {
        try ArtifactValueValidation.identifier(r.assetID);try ArtifactValueValidation.expected(r.expected)
        try ArtifactValueValidation.source(r.expectedParentSource);try ArtifactValueValidation.artifact(r.draft.artifact)
        if case .original(let original) = r.expectedParentSource {
            guard r.assetID.hasPrefix("/"),FilePathComparison.canonicalPath(URL(fileURLWithPath:r.assetID)) == FilePathComparison.canonicalPath(URL(fileURLWithPath:original.standardizedPath)) else {throw ArtifactContractError.sourceChanged}
        }
        let parentSnapshot = try r.expected.snapshot ?? EditingSnapshot()
        guard r.draft.artifact.provenance.parentSource == r.expectedParentSource,r.draft.artifact.provenance.parentSnapshot == parentSnapshot else {throw ArtifactContractError.staleSnapshot}
        try await acquireMutation();defer{releaseMutation()};let db = try connection()
        let previous = try sql.read(db) { () throws -> ArtifactCommitReceipt? in
            if let prior = try commitWire(r.commitID,on:db) {guard prior.requestSHA256 == r.requestSHA256 else {throw ArtifactContractError.conflictingCommit};return prior.value}
            try Self.require(r.expected,id:r.assetID,on:db);try ensureNoRemap(r.assetID,on:db);return nil
        }
        if let previous {return previous}
        try await verifySource(r.expectedParentSource)
        let published = try await artifacts.publish(r.draft,commitID:r.commitID)
        try await artifacts.validatePublication(published);try hooks.afterPublication()
        try await verifySource(r.expectedParentSource)
        return try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            if let prior = try commitWire(r.commitID,on:db) {guard prior.requestSHA256 == r.requestSHA256 else {throw ArtifactContractError.conflictingCommit};return prior.value}
            try Self.require(r.expected,id:r.assetID,on:db);try ensureNoRemap(r.assetID,on:db)
            guard r.nextRevision >= 0,r.expected.revision.map({r.nextRevision > $0}) != false else {throw ArtifactContractError.staleSnapshot}
            try Self.register(published.artifact,on:db)
            let snapshot = try EditingSnapshot(source:.artifact(published.artifact.id)),epoch = try Self.epoch(db)
            if let old = r.expected.snapshot {try addVariant(old,id:r.assetID,on:db)}
            try addVariant(snapshot,id:r.assetID,on:db);try Self.write(snapshot,id:r.assetID,revision:r.nextRevision,on:db)
            let wire = EditingCommitWire(commitID:r.commitID,assetID:r.assetID,requestSHA256:r.requestSHA256,previous:r.expected,
                snapshot:snapshot,version:try .init(storeEpoch:epoch,revision:r.nextRevision),artifactID:published.artifact.id)
            try EditingSQLite.statement(db,"INSERT INTO artifact_commits(id,request_sha,receipt) VALUES(?,?,?)") {s in
                try EditingSQLite.bind(r.commitID.canonicalString,1,s);try EditingSQLite.bind(r.requestSHA256.sha256,2,s);try EditingSQLite.bind(ArtifactJSONCodec.encode(wire),3,s);try EditingSQLite.done(s)
            };return wire.value
        }
    }
    func verifySource(_ source:EditingSourceFingerprint) async throws {
        switch source {
        case .artifact(let a):
            guard a.storeID == (await artifacts.storeID) else {throw ArtifactContractError.sourceChanged}
            let handle = try await artifacts.openVerifiedRaster(a.artifactID)
            guard handle.artifact.manifestSHA256 == a.manifestSHA256,handle.artifact.raster == a.raster else {throw ArtifactContractError.sourceChanged}
        case .original(let o):
            let reservation = try EditingDatabaseAccess.reserveNativeFile()
            let fd = Darwin.open(o.standardizedPath,O_RDONLY|O_NONBLOCK|O_CLOEXEC)
            guard fd >= 0 else {throw ArtifactContractError.sourceChanged}
            let ownership = reservation.own(fd);defer{ownership.close()}
            var s = stat();guard fstat(fd,&s) == 0,s.st_mode & S_IFMT == S_IFREG else {throw ArtifactContractError.sourceChanged}
            let r = o.nativeRevision
            guard Int64(s.st_dev) == r.device,UInt64(s.st_ino) == r.inode,Int64(s.st_size) == r.fileSize,
                Int64(s.st_mtimespec.tv_sec) == r.modifiedSeconds,Int32(s.st_mtimespec.tv_nsec) == r.modifiedNanoseconds,
                Int64(s.st_ctimespec.tv_sec) == r.changedSeconds,Int32(s.st_ctimespec.tv_nsec) == r.changedNanoseconds else {throw ArtifactContractError.sourceChanged}
        }
    }
    func addVariant(_ snapshot:EditingSnapshot,id:String,on db:OpaquePointer) throws {
        guard try EditingSQLite.scalar(db,"SELECT count(*) FROM editing_variants") < 100_000 else {throw ArtifactContractError.limitExceeded}
        try EditingSQLite.statement(db,"INSERT INTO editing_variants(id,asset_id,snapshot,created_at) VALUES(?,?,?,?)") {s in
            try EditingSQLite.bind(EditingVariantID().canonicalString,1,s);try EditingSQLite.bind(id,2,s);try EditingSQLite.bind(ArtifactJSONCodec.encode(snapshot),3,s)
            guard sqlite3_bind_double(s,4,Date().timeIntervalSinceReferenceDate) == SQLITE_OK else {throw EditingRepositoryError.storageFailure};try EditingSQLite.done(s)
        }
    }
    public func variants(for assetID:String) async throws -> [EditingVariant] {
        try await gate.withRepositoryAccess(domain:.editing) {try await self.readVariants(assetID)}
    }
    func readVariants(_ id:String) throws -> [EditingVariant] {
        try ArtifactValueValidation.identifier(id);let db = try connection()
        return try sql.read(db) {try EditingSQLite.statement(db,"SELECT id,snapshot,created_at FROM editing_variants WHERE asset_id=? ORDER BY created_at,id") {s in
            try EditingSQLite.bind(id,1,s);var result:[EditingVariant] = []
            try EditingSQLite.consume(s) {s in
                let uuid = try EditingSQLite.text(s,0,maximum:36);guard let raw = UUID(uuidString:uuid),uuid == raw.uuidString.lowercased() else {throw EditingRepositoryError.invalidDatabase}
                let snapshot = try ArtifactJSONCodec.decode(EditingSnapshot.self,from:EditingSQLite.blob(s,1,maximum:65_536))
                result.append(.init(id:.init(rawValue:raw),assetID:id,snapshot:snapshot,createdAt:Date(timeIntervalSinceReferenceDate:sqlite3_column_double(s,2))))
            };return result
        }}
    }
}
