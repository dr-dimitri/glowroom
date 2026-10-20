import Foundation
import Darwin
import CSQLite

extension EditingRepository {
    public func recoverDamagedDatabase(from url:URL,authorizedBy permit:CatalogEditingRecoveryPermit) async throws -> EditingStoreState {
        try permit.validateGate(gate)
        try await acquireMutation();defer{releaseMutation()}
        let verified = try await packages.validate(from:url,limits:EditingPackageLimits())
        // A valid current DB uses regular transactional Restore, never a native
        // replacement path. A failed diagnostic only admits explicit recovery.
        let healthy:Bool
        do {
            healthy = try EditingSQLite.readOnly(fileURL,onContention:sql.onContention,{db,version in try Self.validateRows(db,version);return true}) ?? false
        } catch is CancellationError {throw CancellationError()}
        catch EditingRepositoryError.databaseBusy {throw EditingRepositoryError.databaseBusy}
        catch {healthy = false}
        if healthy {throw ArtifactContractError.invalidValue("Bitte reguläre Wiederherstellung verwenden")}
        let raw = try EditingRecoveryArchive(directory:fileURL.deletingLastPathComponent())
        let source = raw.family["edits.sqlite"]
        // A recognizable SQLite header never falls through as opaque bytes.
        // Newer/fremd application schemas must remain at their existing path.
        let prefix:Data
        if let source,source.stamp.bytes > 0 {prefix = try source.read(offset:0,count:Int(min(100,source.stamp.bytes)))}
        else {prefix = Data()}
        let recognizable = prefix.count >= 100 && Array(prefix.prefix(16)) == Array("SQLite format 3\0".utf8)
        if recognizable {
            guard prefix.count >= 100 else {throw EditingRepositoryError.invalidDatabase}
            func n(_ i:Int)->UInt32 {prefix[i..<(i+4)].reduce(0){$0<<8|UInt32($1)}}
            guard n(68) == UInt32(EditingSQLite.applicationID) else {throw EditingRepositoryError.invalidDatabase}
            guard n(60) == 1 || n(60) == 2 else {throw EditingRepositoryError.unsupportedVersion(Int(n(60)))}
        }
        if let source {guard source.stamp.mode & (S_IWUSR|S_IWGRP|S_IWOTH) != 0 else {throw EditingRepositoryError.readOnly}}
        let priorIdentity:UUID?
        if let resources {
            let transfer = try await resources.acquire(kind:.transfer,bytes:65_536,priority:.background,retaining:[])
            try raw.capture();priorIdentity = try recognizable ? recoveryIdentity(from:raw) : nil
            withExtendedLifetime(transfer){}
        } else {try raw.capture();priorIdentity = try recognizable ? recoveryIdentity(from:raw) : nil}
        let restored = try await readRestore(verified)
        let materialized = try await artifacts.materialize(verified)
        guard Set(materialized.artifacts) == Set(verified.snapshot.referencedArtifacts) else {throw ArtifactContractError.invalidCapability}
        let candidates = try ArtifactFileIO.child(raw.source,"EditingSnapshots",create:true)
        let candidateName = "recovery-"+UUID().uuidString.lowercased()
        guard mkdirat(candidates.fd.value,candidateName,0o700) == 0 else {throw EditingRepositoryError.storageFailure}
        let candidateDirectory = try ArtifactFileIO.child(candidates,candidateName)
        let candidateSQL = EditingSQLite(directory:candidateDirectory.url)
        let db = try candidateSQL.open(validateRows:Self.validateRows)
        let recovered = try candidateSQL.transaction(db,beforeCommit:hooks.beforeCommit) {
            let newEpoch = UUID(),identity = priorIdentity ?? UUID()
            try EditingSQLite.statement(db,"UPDATE editing_state SET store_id=?,store_epoch=? WHERE singleton=1") {s in
                try EditingSQLite.bind(identity.uuidString.lowercased(),1,s);try EditingSQLite.bind(newEpoch.uuidString.lowercased(),2,s);try EditingSQLite.done(s)
            }
            for a in materialized.artifacts {
                try ArtifactValueValidation.artifact(a)
                try EditingSQLite.statement(db,"INSERT INTO generated_artifacts(id,descriptor) VALUES(?,?)") {s in
                    try EditingSQLite.bind(a.id.canonicalString,1,s);try EditingSQLite.bind(ArtifactJSONCodec.encode(a),2,s);try EditingSQLite.done(s)
                }
            }
            let revisions = restored.0.byAsset.mapValues(\.version.revision).merging(restored.0.tombstones,uniquingKeysWith:max)
            for (id,revision) in revisions {
                guard revision < Int64.max else {throw ArtifactContractError.limitExceeded}
                try Self.write(restored.0.byAsset[id]?.snapshot,id:id,revision:revision+1,on:db)
            }
            for variant in restored.1 {
                try EditingSQLite.statement(db,"INSERT INTO editing_variants(id,asset_id,snapshot,created_at) VALUES(?,?,?,?)") {s in
                    try EditingSQLite.bind(variant.id.canonicalString,1,s);try EditingSQLite.bind(variant.assetID,2,s);try EditingSQLite.bind(ArtifactJSONCodec.encode(variant.snapshot),3,s)
                    guard sqlite3_bind_double(s,4,variant.createdAt.timeIntervalSinceReferenceDate) == SQLITE_OK else {throw EditingRepositoryError.storageFailure};try EditingSQLite.done(s)
                }
            }
            try Self.validateRows(db,2);return try Self.readState(db,version:2)
        }
        try candidateSQL.closeForReplacement()
        let candidate = try ArtifactFileIO.openFile(candidateDirectory,"edits.sqlite")
        // Probe every old archived payload before the final short native CAS;
        // only metadata is retained, never thousands of simultaneously open FDs.
        try raw.validateArchivedArtifactSources()
        try raw.validateOriginalFamily()
        try sql.closeForReplacement()
        try hooks.beforeRecoveryInstall()
        try permit.validateGate(gate)
        try permit.withCriticalSection {
            try raw.install(candidate:candidate,checkpoint:hooks.recoveryCheckpoint)
        }
        // SQL activation is already durable. Return its prevalidated state;
        // later lazy open must not turn a completed install into false failure.
        return recovered
    }
    /// Read ownership only from a disposable native-family copy. Even SQLite's
    /// private hot-journal/SHM work can never change the raw safety archive.
    func recoveryIdentity(from archive:EditingRecoveryArchive) throws -> UUID? {
        let temporary = try EditingPrivateSQLiteStage(prefix:"Glowroom-Recovery-Identity-")
        for (name,source) in archive.family {
            let fd = try temporary.createFile(name)
            var offset:Int64 = 0
            while offset < source.stamp.bytes {
                let bytes = try source.read(offset:offset,count:Int(min(65_536,source.stamp.bytes-offset)))
                try ArtifactFileIO.writeAll(fd,bytes)
                offset += Int64(bytes.count)
            }
        }
        try temporary.prepareAbsentWALFiles()
        let db = try EditingSQLite.connect(temporary.url("edits.sqlite"),readOnly:true);defer{sqlite3_close(db)}
        let version:Int
        do {version = Int(try EditingSQLite.scalar(db,"PRAGMA user_version"))}
        catch {
            if archive.family["edits.sqlite-wal"] != nil {throw EditingRepositoryError.recoveryRequired}
            return nil
        }
        guard version == 1 || version == 2 else {throw EditingRepositoryError.unsupportedVersion(version)}
        guard try EditingSQLite.scalar(db,"PRAGMA application_id") == Int64(EditingSQLite.applicationID) else {throw EditingRepositoryError.invalidDatabase}
        if version == 1 {return nil}
        return try? Self.identity(db).durableStoreID
    }
}
