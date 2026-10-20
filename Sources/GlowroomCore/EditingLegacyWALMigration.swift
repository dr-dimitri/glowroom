import Foundation
import Darwin
import CSQLite
import CryptoKit

public enum EditingLegacyMigrationCheckpoint:Equatable,Sendable {case archived,checkpointed,beforeCommit,beforeSharedMemoryCleanup}

/// Schema-1 used WAL even after orderly close. Prove the logical legacy schema
/// on a disposable copy, retain the exact native family separately, and only
/// then let SQLite checkpoint the positively owned original under its locks.
/// Unknown schemas/journals are never recovered or reset as a side effect.
enum EditingLegacyWALMigration {
    struct Stamp:Codable,Equatable {
        let device:Int64,inode:UInt64,size:Int64,mtimeSeconds:Int64,mtimeNanos:Int64,ctimeSeconds:Int64,ctimeNanos:Int64
        init(_ s:stat) {device = Int64(s.st_dev);inode = UInt64(s.st_ino);size = Int64(s.st_size);mtimeSeconds = Int64(s.st_mtimespec.tv_sec);mtimeNanos = Int64(s.st_mtimespec.tv_nsec);ctimeSeconds = Int64(s.st_ctimespec.tv_sec);ctimeNanos = Int64(s.st_ctimespec.tv_nsec)}
    }
    final class Member {
        let fd:Int32,url:URL,stamp:Stamp
        private let nativeFile:EditingNativeFileReservation
        init(_ url:URL) throws {
            let reservation = try EditingDatabaseAccess.reserveNativeFile()
            self.url = url;fd = Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
            guard fd >= 0 else {throw EditingRepositoryError.recoveryRequired}
            nativeFile = reservation.own(fd)
            var s = stat();guard fstat(fd,&s) == 0,s.st_mode & S_IFMT == S_IFREG,s.st_nlink == 1,s.st_size >= 0,s.st_size <= 536_870_912 else {nativeFile.close();throw EditingRepositoryError.recoveryRequired}
            stamp = Stamp(s)
        }
        deinit {nativeFile.close()}
        func check() throws {
            var a = stat(),b = stat()
            guard fstat(fd,&a) == 0,lstat(url.path,&b) == 0,a.st_mode & S_IFMT == S_IFREG,b.st_mode & S_IFMT == S_IFREG,
                  a.st_nlink == 1,b.st_nlink == 1,Stamp(a) == stamp,Stamp(b) == stamp else {throw EditingRepositoryError.recoveryRequired}
        }
        func copy(name:String,in directory:ArtifactDirectory,privateStage:EditingPrivateSQLiteStage? = nil) throws -> ArtifactDigest {
            try ArtifactFileIO.validLeaf(name);try directory.validate()
            let out:Int32
            if let privateStage {out = try privateStage.createFile(name)}
            else {out = openat(directory.fd.value,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o400)}
            guard out >= 0 else {throw EditingRepositoryError.storageFailure};defer{if privateStage == nil {close(out)}}
            var hash = SHA256(),offset:Int64 = 0
            while offset < stamp.size {
                try autoreleasepool {
                    var bytes = Data(count:Int(min(65_536,stamp.size-offset)))
                    let n = try bytes.withUnsafeMutableBytes{try ArtifactFileIO.preadAll(fd,into:$0.baseAddress!,count:$0.count,offset:offset)}
                    guard n == bytes.count else {throw EditingRepositoryError.storageFailure}
                    try ArtifactFileIO.writeAll(out,bytes)
                    hash.update(data:bytes);offset += Int64(n)
                }
            }
            guard fsync(out) == 0 else {throw EditingRepositoryError.storageFailure}
            try check();try directory.validate()
            return try .init(sha256:hash.finalize().map{String(format:"%02x",$0)}.joined())
        }
    }
    /// SQLite's exclusive WAL mode can leave a SHM entry after journal_mode
    /// becomes DELETE. Bind either the already archived inode or OUR exclusive
    /// creation before opening SQLite; a later scan can never establish ownership.
    final class SharedMemoryOwnership {
        let directory:ArtifactDirectory,fd:ArtifactNativeFD,device:dev_t,inode:ino_t
        private let name = "edits.sqlite-shm"
        init(directory:ArtifactDirectory,archived:Member?) throws {
            self.directory = directory;try directory.validate()
            let reservation = try EditingDatabaseAccess.reserveNativeFile()
            let opened:Int32
            if let archived {
                try archived.check();opened = dup(archived.fd)
            } else {
                opened = openat(directory.fd.value,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            }
            guard opened >= 0 else {throw EditingRepositoryError.recoveryRequired}
            let ownership = ArtifactNativeFD(opened,editingOwnership:reservation.own(opened));var stamp = stat()
            guard fstat(opened,&stamp) == 0,stamp.st_mode & S_IFMT == S_IFREG,stamp.st_nlink == 1 else {throw EditingRepositoryError.recoveryRequired}
            fd = ownership;device = stamp.st_dev;inode = stamp.st_ino
            try validateNamed()
        }
        private func validateNamed() throws {
            try directory.validate();var own = stat(),named = stat()
            guard fstat(fd.value,&own) == 0,own.st_mode & S_IFMT == S_IFREG,own.st_nlink == 1,
                  own.st_dev == device,own.st_ino == inode,
                  fstatat(directory.fd.value,name,&named,AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_mode & S_IFMT == S_IFREG,named.st_nlink == 1,named.st_dev == device,named.st_ino == inode else {throw EditingRepositoryError.recoveryRequired}
        }
        func removeIfRemaining() throws {
            try directory.validate();var named = stat()
            if fstatat(directory.fd.value,name,&named,AT_SYMLINK_NOFOLLOW) != 0 {
                var own = stat()
                guard errno == ENOENT,fstat(fd.value,&own) == 0,own.st_nlink == 0 else {throw EditingRepositoryError.recoveryRequired}
                return // SQLite already removed exactly our last linked inode.
            }
            try validateNamed()
            guard unlinkat(directory.fd.value,name,0) == 0,fsync(directory.fd.value) == 0 else {throw EditingRepositoryError.storageFailure}
        }
    }
    struct Evidence:Codable {let schemaVersion:Int;let files:[String:Stamp];let sha256:[String:ArtifactDigest]}
    static func isLegacyWAL(_ fd:Int32) throws -> Bool {
        var b = [UInt8](repeating:0,count:100)
        guard try b.withUnsafeMutableBytes({try ArtifactFileIO.preadAll(fd,into:$0.baseAddress!,count:100,offset:0)}) == 100,Array(b.prefix(16)) == Array("SQLite format 3\0".utf8) else {throw EditingRepositoryError.invalidDatabase}
        // On the first legacy open, WAL is enabled BEFORE the transaction
        // which sets application_id/user_version. A crash can therefore leave
        // both identifiers as zero in main while committed WAL owns GLOW1.
        // Native WAL form admits ONLY a disposable read-only probe. prepare()
        // proves the exact logical GLOW1 schema/rows before archives or any
        // original-family mutation; foreign/future logical schemas still reject.
        return b[18] == 2 && b[19] == 2
    }
    static func prepare(_ url:URL,mainFD:Int32,validateRows:(OpaquePointer,Int)throws->Void,checkpoint:(EditingLegacyMigrationCheckpoint)throws->Void) throws {
        try EditingSQLite.writable(mainFD)
        var journal = stat()
        guard lstat(url.path+"-journal",&journal) != 0,errno == ENOENT else {throw EditingRepositoryError.recoveryRequired}
        var members:[String:Member] = ["edits.sqlite":try Member(url)]
        for suffix in ["-wal","-shm"] {
            var info = stat()
            if lstat(url.path+suffix,&info) == 0 {members["edits.sqlite"+suffix] = try Member(URL(fileURLWithPath:url.path+suffix))}
            else {guard errno == ENOENT else {throw EditingRepositoryError.recoveryRequired}}
        }
        var original = stat();guard fstat(mainFD,&original) == 0,members["edits.sqlite"]!.stamp == Stamp(original) else {throw EditingRepositoryError.recoveryRequired}
        // Bound simultaneous disk staging as well as each file; buffers stay64K.
        guard members.values.reduce(Int64(0),{$0+$1.stamp.size}) <= 1_073_741_824 else {throw ArtifactContractError.limitExceeded}
        let probe = try EditingPrivateSQLiteStage(prefix:"Glowroom-Legacy-WAL-Probe-")
        for (name,member) in members { _ = try member.copy(name:name,in:probe.directory,privateStage:probe) }
        try probe.prepareAbsentWALFiles()
        for member in members.values {try member.check()}
        let copied = try EditingSQLite.connect(probe.url("edits.sqlite"),readOnly:true)
        do {
            try EditingSQLite.schema(copied,version:1);try EditingSQLite.integrity(copied);try validateRows(copied,1)
            sqlite3_close(copied)
        } catch {sqlite3_close(copied);throw error}
        let catalogRoot = try ArtifactFileIO.root(url.deletingLastPathComponent(),create:false)
        let archives = try ArtifactFileIO.child(catalogRoot,"EditMigrationArchives",create:true)
        let name = UUID().uuidString.lowercased()
        guard mkdirat(archives.fd.value,name,0o700) == 0 else {throw EditingRepositoryError.storageFailure}
        let archive = try ArtifactFileIO.child(archives,name)
        var hashes:[String:ArtifactDigest] = [:]
        for (name,member) in members {hashes[name] = try member.copy(name:name,in:archive)}
        let evidence = Evidence(schemaVersion:1,files:members.mapValues(\.stamp),sha256:hashes)
        let encoded = try EditingContractJSON.encoder().encode(evidence)
        try ArtifactFileIO.writeSmall(archive,"family-evidence.json",bytes:encoded,limit:65_536)
        // Every newly created namespace edge is durable before SQLite may
        // checkpoint or migrate the original family.
        for directory in [archive,archives,catalogRoot] {
            try directory.validate();guard fsync(directory.fd.value) == 0 else {throw EditingRepositoryError.storageFailure}
        }
        try checkpoint(.archived)
        for member in members.values {try member.check()}
        func validateOriginalSidecarAbsences() throws {
            try catalogRoot.validate()
            for name in ["edits.sqlite-journal","edits.sqlite-wal"] {
                if let member = members[name] {try member.check()}
                else {
                    var entry = stat()
                    guard fstatat(catalogRoot.fd.value,name,&entry,AT_SYMLINK_NOFOLLOW) != 0,errno == ENOENT else {throw EditingRepositoryError.recoveryRequired}
                }
            }
        }
        // An .archived callback/external writer may have introduced a hot
        // journal or WAL. Never let SQLite implicitly replay unknown entries.
        try validateOriginalSidecarAbsences()
        let sharedMemory = try SharedMemoryOwnership(directory:catalogRoot,archived:members["edits.sqlite-shm"])
        try validateOriginalSidecarAbsences()
        let db = try EditingSQLite.connect(url,readOnly:false)
        do {
            try EditingSQLite.checkFile(mainFD,url:url,db:db)
            try EditingSQLite.exec(db,"PRAGMA locking_mode=EXCLUSIVE;BEGIN EXCLUSIVE")
            do {
                try EditingSQLite.schema(db,version:1);try EditingSQLite.integrity(db);try validateRows(db,1)
                try EditingSQLite.exec(db,"COMMIT")
            } catch {try? EditingSQLite.exec(db,"ROLLBACK");throw error}
            // Exclusive locking mode retains ownership between COMMIT and the
            // journal transition; a competing legacy writer cannot slip in.
            var mode:String?
            try EditingSQLite.rows(db,"PRAGMA journal_mode=DELETE") {mode = try EditingSQLite.text($0,0,maximum:16)}
            guard mode == "delete" else {throw EditingRepositoryError.recoveryRequired}
            try EditingSQLite.checkFile(mainFD,url:url,db:db);try EditingSQLite.header(mainFD)
            guard sqlite3_get_autocommit(db) == 1 else {throw EditingRepositoryError.recoveryRequired}
            var wal = stat()
            guard fstatat(catalogRoot.fd.value,"edits.sqlite-wal",&wal,AT_SYMLINK_NOFOLLOW) != 0,errno == ENOENT else {throw EditingRepositoryError.recoveryRequired}
            // EXCLUSIVE DELETE can retain its inactive rollback-journal until
            // SQLite closes. A never removes/accepts it: strict sidecars() below
            // still requires EVERY journal/WAL/SHM to be absent after close.
            try checkpoint(.beforeSharedMemoryCleanup)
            // Keep SQLite's exclusive main-file lock through the final bound
            // cleanup, so another SQLite writer cannot race this transition.
            try sharedMemory.removeIfRemaining()
            guard sqlite3_close(db) == SQLITE_OK else {throw EditingRepositoryError.storageFailure}
        } catch {sqlite3_close(db);throw error}
        try EditingSQLite.sidecars(url);try checkpoint(.checkpointed)
    }
}
