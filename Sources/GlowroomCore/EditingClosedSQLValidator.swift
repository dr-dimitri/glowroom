import Foundation
import Darwin
import CSQLite
import CryptoKit

/// Validates only B's closed, private staged SQL copy. The returned capability
/// keeps exactly B's original pinned input handle; never substitute a live DB.
enum EditingClosedSQLValidator {
    static func validate(privateStagedSQLURL url:URL,pinnedOwnership handle:ArtifactFileReadHandle) async throws -> ClosedEditingSQLSnapshot {
        try Task.checkCancellation()
        let reservation = try EditingDatabaseAccess.reserveNativeFile()
        let fd = Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd >= 0 else {throw EditingRepositoryError.invalidDatabase}
        let ownership = reservation.own(fd);defer{ownership.close()}
        try EditingSQLite.sidecars(url);try EditingSQLite.checkFile(fd,url:url);try EditingSQLite.header(fd)
        var before = stat();guard fstat(fd,&before) == 0,Int64(before.st_size) == handle.bytes else {throw EditingRepositoryError.invalidDatabase}
        var hasher = SHA256(),offset:Int64 = 0
        while offset < handle.bytes {
            try Task.checkCancellation()
            let count = Int(min(65_536,handle.bytes-offset))
            var bytes = Data(count:count)
            guard try bytes.withUnsafeMutableBytes({try ArtifactFileIO.preadAll(fd,into:$0.baseAddress!,count:count,offset:offset)}) == count else {throw EditingRepositoryError.storageFailure}
            let claimed = try handle.read(offset:offset,maximumCount:count)
            guard claimed == bytes else {throw EditingRepositoryError.invalidDatabase}
            hasher.update(data:bytes);offset += Int64(count)
        }
        let hash = try ArtifactDigest(sha256:hasher.finalize().map{String(format:"%02x",$0)}.joined())
        guard hash == handle.sha256 else {throw EditingRepositoryError.invalidDatabase}
        let db = try EditingSQLite.connect(url,readOnly:true);defer{sqlite3_close(db)}
        try EditingSQLite.checkFile(fd,url:url,db:db)
        let version = Int(try EditingSQLite.scalar(db,"PRAGMA user_version"))
        try EditingSQLite.schema(db,version:version);try EditingSQLite.integrity(db);try EditingRepository.validateRows(db,version)
        let state = try EditingRepository.readState(db,version:version)
        let descriptors = version == 2 ? try closure(db,state:state) : []
        var after = stat()
        guard fstat(fd,&after) == 0,before.st_size == after.st_size,before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {throw EditingRepositoryError.invalidDatabase}
        try EditingSQLite.checkFile(fd,url:url,db:db)
        // A legacy file has no stored epoch. Bind its virtual read-only identity
        // to these already verified immutable bytes so package revalidation of
        // the same copy never invents a different source generation.
        let sourceEpoch:UUID
        if version == 1 {
            let h = hash.sha256
            let raw = String(h.prefix(8))+"-"+String(h.dropFirst(8).prefix(4))+"-"+String(h.dropFirst(12).prefix(4))+"-"+String(h.dropFirst(16).prefix(4))+"-"+String(h.dropFirst(20).prefix(12))
            guard let value = UUID(uuidString:raw) else {throw EditingRepositoryError.invalidDatabase};sourceEpoch = value
        } else {sourceEpoch = state.storeEpoch}
        return ClosedEditingSQLSnapshot(sourceStoreEpoch:sourceEpoch,database:handle,referencedArtifacts:descriptors,snapshotID:UUID())
    }
    static func closure(_ db:OpaquePointer,state:EditingStoreState) throws -> [GeneratedArtifact] {
        try Task.checkCancellation()
        var roots = Set<GeneratedArtifactID>()
        for entry in state.byAsset.values {
            try Task.checkCancellation()
            if case .artifact(let id) = entry.snapshot.source {roots.insert(id)}
        }
        try EditingSQLite.rows(db,"SELECT snapshot FROM editing_variants") {s in
            try Task.checkCancellation()
            let value = try ArtifactJSONCodec.decode(EditingSnapshot.self,from:EditingSQLite.blob(s,0,maximum:EditSettings.maximumEncodedBytes))
            if case .artifact(let id) = value.source {roots.insert(id)}
        }
        var result:[GeneratedArtifactID:GeneratedArtifact] = [:],visiting = Set<GeneratedArtifactID>()
        for root in roots {
            // A valid provenance chain may contain all 4096 artifacts. Keep
            // pending postorder work on the heap, never on a GCD/task stack.
            var pending:[GeneratedArtifact] = []
            var next:GeneratedArtifactID? = root
            while let id = next {
                try Task.checkCancellation()
                guard !visiting.contains(id) else {throw ArtifactContractError.corruptArtifact}
                if result[id] != nil {break}
                guard result.count + visiting.count < 4_096,
                      let descriptor = try EditingRepository.descriptor(id,on:db) else {throw ArtifactContractError.missingArtifact}
                try ArtifactValueValidation.artifact(descriptor)
                visiting.insert(id);pending.append(descriptor)
                if case .artifact(let parent) = descriptor.provenance.parentSource {next = parent.artifactID}
                else {next = nil}
            }
            while let descriptor = pending.popLast() {
                try Task.checkCancellation()
                if case .artifact(let parent) = descriptor.provenance.parentSource {
                    guard let reached = result[parent.artifactID],reached.manifestSHA256 == parent.manifestSHA256,
                          reached.raster == parent.raster else {throw ArtifactContractError.corruptArtifact}
                }
                visiting.remove(descriptor.id);result[descriptor.id] = descriptor
            }
        }
        return result.values.sorted{$0.id.canonicalString < $1.id.canonicalString}
    }
}

/// Private stage ownership binds reads and eventual cleanup to our original FD.
/// A replaced name is preserved and rejected rather than unlinked in cleanup.
final class EditingSQLCopy: @unchecked Sendable {
    let url:URL,fd:Int32
    private let nativeFile:EditingNativeFileReservation
    init(directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var info = stat();guard lstat(directory.path,&info) == 0,info.st_mode & S_IFMT == S_IFDIR else {throw EditingRepositoryError.invalidDatabase}
        url = directory.appendingPathComponent(".editing-snapshot-\(UUID().uuidString.lowercased()).sqlite",isDirectory:false)
        let reservation = try EditingDatabaseAccess.reserveNativeFile()
        fd = Darwin.open(url.path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else {throw EditingRepositoryError.storageFailure}
        nativeFile = reservation.own(fd)
    }
    deinit {
        if (try? EditingSQLite.checkFile(fd,url:url)) != nil,(try? EditingSQLite.sidecars(url)) != nil {_ = unlink(url.path)}
        nativeFile.close()
    }
    func handle() throws -> ArtifactFileReadHandle {
        try EditingSQLite.checkFile(fd,url:url)
        var s = stat();guard fstat(fd,&s) == 0,s.st_size > 0 else {throw EditingRepositoryError.invalidDatabase}
        let count = Int64(s.st_size);var hasher = SHA256(),offset:Int64 = 0
        while offset < count {let bytes = try read(offset:offset,count:Int(min(65_536,count-offset)));hasher.update(data:bytes);offset += Int64(bytes.count)}
        let digest = try ArtifactDigest(sha256:hasher.finalize().map{String(format:"%02x",$0)}.joined())
        return ArtifactFileReadHandle(bytes:count,sha256:digest,ownership:nil) {[self] offset,maximum in try read(offset:offset,count:Int(min(Int64(maximum),count-offset)))}
    }
    func read(offset:Int64,count:Int) throws -> Data {
        try EditingSQLite.checkFile(fd,url:url);var data = Data(count:count)
        guard try data.withUnsafeMutableBytes({try count == 0 ? 0 : ArtifactFileIO.preadAll(fd,into:$0.baseAddress!,count:count,offset:offset)}) == count else {throw EditingRepositoryError.storageFailure};return data
    }
    static func online(_ source:OpaquePointer,directory:URL) throws -> EditingSQLCopy {
        let owned = try EditingSQLCopy(directory:directory)
        let db = try EditingSQLite.connect(owned.url,readOnly:false)
        do {
            guard let backup = sqlite3_backup_init(db,"main",source,"main") else {throw EditingRepositoryError.storageFailure}
            let deadline = ContinuousClock.now.advanced(by:.seconds(5));var status:Int32
            repeat {
                status = sqlite3_backup_step(backup,128)
                if status == SQLITE_BUSY || status == SQLITE_LOCKED {Thread.sleep(forTimeInterval:0.01)}
            } while (status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED) && ContinuousClock.now < deadline
            let ended = sqlite3_backup_finish(backup)
            guard status == SQLITE_DONE,ended == SQLITE_OK else {throw EditingRepositoryError.storageFailure}
            try EditingSQLite.exec(db,"PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL")
            guard sqlite3_db_cacheflush(db) == SQLITE_OK else {throw EditingRepositoryError.storageFailure}
            guard sqlite3_close(db) == SQLITE_OK else {throw EditingRepositoryError.storageFailure}
        } catch {sqlite3_close(db);throw error}
        guard fsync(owned.fd) == 0 else {throw EditingRepositoryError.storageFailure}
        return owned
    }
}
