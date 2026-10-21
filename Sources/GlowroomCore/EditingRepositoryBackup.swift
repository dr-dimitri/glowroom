import Foundation
import CSQLite
import Darwin

struct PreparedEditingBackup:Sendable {
    let source:EditingBackupSource
    let destination:URL
}
extension EditingRepository {
    public func backupWarning() async -> String? {backupMaintenanceWarning}
    public func exportBackup(from source:URL,toNew destination:URL) async throws -> URL {
        try await gate.withRepositoryAccess(domain:.backupRestore) {
            let maintenance = try await self.gate.promoteCurrentAcceptedWrite(to:.backup(UUID()))
            do {
                let published = try await self.gate.withMaintenance(maintenance) {
                    try await self.packages.export(from:source,toNew:destination,limits:EditingPackageLimits())
                }
                try await self.gate.finishMaintenance(maintenance);return published.url
            } catch {try? await self.gate.finishMaintenance(maintenance);throw error}
        }
    }

    public func createBackup(automatic:Bool = false) async throws -> URL {
        try await createBackup(automatic:automatic,maintenance:{_ in})
    }
    public func createAutomaticBackup(maintenance:@escaping @Sendable(Bool) async throws -> Void) async throws -> URL {
        try await createBackup(automatic:true,maintenance:maintenance)
    }
    private func createBackup(automatic:Bool,maintenance:@escaping @Sendable(Bool) async throws -> Void) async throws -> URL {
        try await gate.withRepositoryAccess(domain:.backupRestore) {
            if automatic,let reused = try await self.reusableAutomaticBackup() {return reused}
            // The MainActor acknowledgement precedes closing gate admission, so
            // a synchronous UI edit cannot observe editable state then be refused.
            let prepared:PreparedEditingBackup
            do {
                try await maintenance(true)
                let admission = try await self.gate.promoteCurrentAcceptedWrite(to:.backup(UUID()))
                do {
                    prepared = try await self.gate.withMaintenance(admission) {try await self.prepareUserBackup(kind:automatic ? .automatic : .manual)}
                    try await self.gate.finishMaintenance(admission)
                } catch {try? await self.gate.finishMaintenance(admission);throw error}
                try await maintenance(false)
            } catch {try? await maintenance(false);throw error}
            // The accepted task remains registered until actual I/O returns,
            // but immutable SQL+artifact leases no longer fence live editing.
            return try await self.writePreparedBackup(prepared,maintenance:maintenance)
        }
    }
    func reusableAutomaticBackup() async throws -> URL? {
        try await packages.reusableAutomaticBackup(in:backupsDirectory,day:backupDay())
    }
    func prepareUserBackup(kind:EditingBackupKind) async throws -> PreparedEditingBackup {
        try await acquireMutation();defer{releaseMutation()}
        return try await prepareBackupSource(kind:kind)
    }
    func makeBackup(kind:EditingBackupKind) async throws -> URL {
        // Restore calls this while retaining its whole exclusive maintenance.
        let prepared = try await prepareBackupSource(kind:kind)
        return try await writePreparedBackup(prepared)
    }
    func prepareBackupSource(kind:EditingBackupKind) async throws -> PreparedEditingBackup {
        let db = try connection()
        let copy = try sql.read(db){try EditingSQLCopy.online(db,directory:fileURL.deletingLastPathComponent().appendingPathComponent("EditingSnapshots",isDirectory:true))}
        let closed = try await EditingClosedSQLValidator.validate(privateStagedSQLURL:copy.url,pinnedOwnership:copy.handle())
        let lease = try await artifacts.acquireLease(ids:Set(closed.referencedArtifacts.map(\.id)),purpose:.backup)
        let source = EditingBackupSource(snapshot:closed,kind:kind,lease:lease,artifactStore:artifacts)
        try FileManager.default.createDirectory(at:backupsDirectory,withIntermediateDirectories:true)
        let prefix = kind == .automatic ? "auto" : kind == .safety ? "safety" : "manual"
        let destination = backupsDirectory.appendingPathComponent("\(prefix)-\(backupDay())-\(UUID().uuidString.lowercased()).glowroombackup",isDirectory:true)
        return .init(source:source,destination:destination)
    }
    func writePreparedBackup(_ prepared:PreparedEditingBackup,maintenance:@escaping @Sendable(Bool) async throws -> Void = {_ in}) async throws -> URL {
        let published = try await packages.write(prepared.source,toNew:prepared.destination,limits:EditingPackageLimits())
        if prepared.source.kind == .automatic {
            do {
                try await maintenance(true)
                // Catalog mutations accepted during long immutable copy really
                // drain before B checks fresh originals under its catalog lock.
                let admission = try await gate.promoteCurrentAcceptedWrite(to:.backup(UUID()))
                do {
                    try await gate.withMaintenance(admission) {try await self.packages.pruneAutomaticBackups(in:self.backupsDirectory,keepingNewest:7)}
                    try await gate.finishMaintenance(admission)
                }catch{try? await gate.finishMaintenance(admission);throw error}
                backupMaintenanceWarning = nil
            }
            catch {backupMaintenanceWarning = "Die Sicherung wurde erstellt. Ältere automatische Sicherungen konnten nicht sicher ausgedünnt werden."}
            try? await maintenance(false)
        }
        return published.url
    }
    func backupDay() -> String {
        let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = .current;formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from:Date())
    }
    public func restoreBackup(from url:URL) async throws -> EditingStoreState {
        try await gate.withRepositoryAccess(domain:.backupRestore) {
            let maintenance = try await self.gate.promoteCurrentAcceptedWrite(to:.restore(UUID()))
            do {
                let value = try await self.gate.withMaintenance(maintenance) {try await self.restore(url)}
                try await self.gate.finishMaintenance(maintenance);return value
            } catch {try? await self.gate.finishMaintenance(maintenance);throw error}
        }
    }
    func restore(_ url:URL) async throws -> EditingStoreState {
        try await acquireMutation();defer{releaseMutation()}
        guard url.isFileURL,FilePathComparison.canonicalPath(url) != FilePathComparison.canonicalPath(fileURL) else {throw ArtifactContractError.invalidValue("backup path")}
        let verified = try await packages.validate(from:url,limits:EditingPackageLimits())
        let db = try connection();try sql.read(db){try ensureNoRemap(nil,on:db)}
        // Preserve the whole prior source/variant closure before any publication
        // or SQL replacement. A failure cannot discard the current source.
        _ = try await makeBackup(kind:.safety)
        let materialized = try await artifacts.materialize(verified)
        guard Set(materialized.artifacts) == Set(verified.snapshot.referencedArtifacts) else {throw ArtifactContractError.invalidCapability}
        // Read exactly the same private validated SQL copy through its retained
        // handle, not the user-selected mutable URL. The temporary copy closes
        // before the active transaction begins.
        let restored = try await readRestore(verified)
        return try sql.transaction(db,beforeCommit:hooks.beforeCommit) {
            try ensureNoRemap(nil,on:db)
            let old = try Self.readState(db,version:2),newEpoch = UUID()
            for descriptor in materialized.artifacts {
                if let prior = try Self.descriptor(descriptor.id,on:db) {guard prior == descriptor else {throw ArtifactContractError.corruptArtifact}}
                else {
                    try EditingSQLite.statement(db,"INSERT INTO generated_artifacts(id,descriptor) VALUES(?,?)") {s in
                        try EditingSQLite.bind(descriptor.id.canonicalString,1,s);try EditingSQLite.bind(ArtifactJSONCodec.encode(descriptor),2,s);try EditingSQLite.done(s)
                    }
                }
            }
            try EditingSQLite.exec(db,"DELETE FROM editing_snapshots;DELETE FROM editing_variants;DELETE FROM artifact_commits;DELETE FROM editing_remaps")
            let oldRevisions = old.byAsset.mapValues(\.version.revision).merging(old.tombstones,uniquingKeysWith:max)
            let restoredRevisions = restored.0.byAsset.mapValues(\.version.revision).merging(restored.0.tombstones,uniquingKeysWith:max)
            for id in Set(oldRevisions.keys).union(restoredRevisions.keys) {
                let previous = max(oldRevisions[id] ?? -1,restoredRevisions[id] ?? -1)
                guard previous < Int64.max else {throw ArtifactContractError.limitExceeded}
                try Self.write(restored.0.byAsset[id]?.snapshot,id:id,revision:previous+1,on:db)
            }
            for variant in restored.1 {
                try EditingSQLite.statement(db,"INSERT INTO editing_variants(id,asset_id,snapshot,created_at) VALUES(?,?,?,?)") {s in
                    try EditingSQLite.bind(variant.id.canonicalString,1,s);try EditingSQLite.bind(variant.assetID,2,s);try EditingSQLite.bind(ArtifactJSONCodec.encode(variant.snapshot),3,s)
                    guard sqlite3_bind_double(s,4,variant.createdAt.timeIntervalSinceReferenceDate) == SQLITE_OK else {throw EditingRepositoryError.storageFailure};try EditingSQLite.done(s)
                }
            }
            try EditingSQLite.statement(db,"UPDATE editing_state SET store_epoch=? WHERE singleton=1") {s in try EditingSQLite.bind(newEpoch.uuidString.lowercased(),1,s);try EditingSQLite.done(s)}
            try Self.validateRows(db,2)
            return try Self.readState(db,version:2)
        }
    }
    func readRestore(_ verified:ValidatedEditingBackup) async throws -> (EditingStoreState,[EditingVariant]) {
        let owned = try EditingSQLCopy(directory:fileURL.deletingLastPathComponent().appendingPathComponent("EditingSnapshots",isDirectory:true))
        var offset:Int64 = 0
        while offset < verified.snapshot.database.bytes {
            try Task.checkCancellation();let data = try verified.snapshot.database.read(offset:offset)
            guard !data.isEmpty else {throw EditingRepositoryError.invalidDatabase}
            try ArtifactFileIO.writeAll(owned.fd,data);offset += Int64(data.count)
        }
        let handle = try owned.handle()
        guard handle.sha256 == verified.snapshot.database.sha256,handle.bytes == verified.snapshot.database.bytes else {throw EditingRepositoryError.invalidDatabase}
        _ = try await EditingClosedSQLValidator.validate(privateStagedSQLURL:owned.url,pinnedOwnership:handle)
        guard let result = try EditingSQLite.readOnly(owned.url,{ db,version in
            let state = try Self.readState(db,version:version);var variants:[EditingVariant] = []
            if version == 2 {
                try EditingSQLite.rows(db,"SELECT id,asset_id,snapshot,created_at FROM editing_variants") {s in
                    let text = try EditingSQLite.text(s,0,maximum:36);guard let uuid = UUID(uuidString:text) else {throw EditingRepositoryError.invalidDatabase}
                    variants.append(.init(id:.init(rawValue:uuid),assetID:try EditingSQLite.text(s,1,maximum:16_384),snapshot:try ArtifactJSONCodec.decode(EditingSnapshot.self,from:EditingSQLite.blob(s,2,maximum:EditSettings.maximumEncodedBytes)),createdAt:Date(timeIntervalSinceReferenceDate:sqlite3_column_double(s,3))))
                }
            };return (state,variants)
        }) else {throw EditingRepositoryError.invalidDatabase}
        return result
    }
}
