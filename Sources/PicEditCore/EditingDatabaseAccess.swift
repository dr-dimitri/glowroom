import Foundation
import Darwin

/// Only cooperating actors WITHIN THIS PROCESS share these synchronous scopes.
/// Kernel flock on main conflicts with Apple's SQLite fcntl locks and MUST NOT
/// surround SQL. External journals remain fail-closed, never adopted as ours.
final class EditingDatabaseAccess {
    private struct Identity:Hashable {let device:Int64,inode:UInt64}
    private final class Registry:@unchecked Sendable {
        let lock = NSLock()
        // Active owners only: no URL cache, waiting entries or historic inodes.
        // Scope release removes entries immediately; capacity is a hard bound.
        var active = Set<Identity>()
        struct NativeFile {var fd:Int32?;var closingIdentity:Identity?;var unknownClose = false}
        var files:[UUID:NativeFile] = [:]
        func closeLocked(_ nonce:UUID) {
            guard var file = files[nonce] else {return}
            guard let fd = file.fd else {files.removeValue(forKey:nonce);return}
            if file.closingIdentity != nil || file.unknownClose {return}
            var stamp = stat(),result:Int32 = -1
            // close cannot fail/throw or honor observer cancellation. A failed
            // stat must not turn into an unsafe immediate close of SQL's inode.
            for _ in 0..<8 {result = fstat(fd,&stamp);if result == 0 || errno != EINTR {break}}
            if result == 0 {
                let key = Identity(device:Int64(stamp.st_dev),inode:UInt64(stamp.st_ino))
                if active.contains(key) {file.closingIdentity = key;files[nonce] = file;return}
            } else if !active.isEmpty {
                file.unknownClose = true;files[nonce] = file;return
            }
            Darwin.close(fd);files.removeValue(forKey:nonce)
        }
        func releaseLocked(_ identity:Identity) {
            active.remove(identity)
            // Close BEFORE another scope can be admitted. POSIX close(any
            // native fd for an inode) drops this process's SQLite fcntl locks.
            let ready = files.compactMap { $0.value.closingIdentity == identity || (active.isEmpty && $0.value.unknownClose) ? $0.key : nil }
            for nonce in ready {
                if let fd = files[nonce]?.fd {Darwin.close(fd)}
                files.removeValue(forKey:nonce)
            }
        }
        func admitLocked(_ identity:Identity) throws -> Bool {
            if active.contains(identity) {return false}
            guard active.count < 256 else {throw ArtifactContractError.limitExceeded}
            active.insert(identity);return true
        }
    }
    private static let registry = Registry()
    static func reserveNativeFile() throws -> EditingNativeFileReservation {
        try registry.lock.withLock {
            // Reserved, retained AND deferred descriptors share one hard cap.
            // Admission happens before open, never after allocation failed.
            guard registry.files.count < 256 else {throw ArtifactContractError.limitExceeded}
            let nonce = UUID();registry.files[nonce] = .init(fd:nil,closingIdentity:nil)
            return EditingNativeFileReservation(nonce:nonce)
        }
    }
    fileprivate static func ownNativeFile(_ fd:Int32,nonce:UUID) {
        registry.lock.withLock {
            precondition(fd >= 0 && registry.files[nonce]?.fd == nil && registry.files[nonce] != nil)
            registry.files[nonce]?.fd = fd
        }
    }
    fileprivate static func closeNativeFile(_ nonce:UUID) {registry.lock.withLock{registry.closeLocked(nonce)}}
    private static func identity(_ fd:Int32,url:URL) throws -> Identity {
        try EditingSQLite.checkFile(fd,url:url)
        var value = stat();guard fstat(fd,&value) == 0 else {throw EditingRepositoryError.storageFailure}
        return .init(device:Int64(value.st_dev),inode:UInt64(value.st_ino))
    }
    struct Pinned {let fd:Int32;let created:Bool;let admission:EditingDatabaseAccess;let ownership:EditingNativeFileReservation}
    static func pin(_ url:URL,creating:Bool,onContention:@Sendable () -> Void = {}) throws -> Pinned? {
        try Task.checkCancellation()
        let reservation = try reserveNativeFile()
        var fd:Int32 = -1,created = false,admission:EditingDatabaseAccess?
        do {
            // Open + FIRST registry try are atomic only within this process,
            // closing its zero-byte first-creation window. The registry lock
            // never spans SQLite, a contention wait or an async suspension.
            try registry.lock.withLock {
                guard registry.active.count < 256 else {throw ArtifactContractError.limitExceeded}
                if creating {
                    fd = Darwin.open(url.path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                    if fd >= 0 {created = true}
                    else if errno != EEXIST {throw EditingRepositoryError.storageFailure}
                }
                if fd < 0 {fd = Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)}
                if fd < 0 {
                    if !creating && errno == ENOENT {return}
                    throw EditingRepositoryError.invalidDatabase
                }
                // Already holding registry.lock: bind before any validation
                // can reject/close an alias of another active SQL main inode.
                precondition(registry.files[reservation.nonce] != nil)
                registry.files[reservation.nonce]?.fd = fd
                let key = try identity(fd,url:url)
                if try registry.admitLocked(key) {admission = EditingDatabaseAccess(identity:key)}
            }
            guard fd >= 0 else {return nil}
            if admission == nil {admission = try acquire(fd:fd,url:url,onContention:onContention)}
            guard let admission else {throw EditingRepositoryError.storageFailure}
            return Pinned(fd:fd,created:created,admission:admission,ownership:reservation)
        } catch {
            reservation.close()
            admission?.release()
            throw error
        }
    }
    private let identity:Identity
    private var held = true
    private init(identity:Identity){self.identity = identity}
    deinit{release()}
    func release(){
        if held {held = false;Self.registry.lock.withLock{Self.registry.releaseLocked(identity)}}
    }
    static func acquire(fd:Int32,url:URL,onContention:@Sendable () -> Void = {},
                        timeout:Duration = .seconds(2)) throws -> EditingDatabaseAccess {
        let key = try identity(fd,url:url)
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by:timeout)
        var reported = false
        while try !registry.lock.withLock({try registry.admitLocked(key)}) {
            if !reported {reported = true;onContention()}
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {throw EditingRepositoryError.databaseBusy}
            // Short bounded background admission wait, no additional pool.
            Thread.sleep(forTimeInterval:0.001)
        }
        let admission = EditingDatabaseAccess(identity:key)
        do {
            try Task.checkCancellation();try EditingSQLite.checkFile(fd,url:url)
            return admission
        }catch{admission.release();throw error}
    }
}

/// Kernel main-file locking is deliberately restricted to the final SQL-FREE
/// recovery rename/fsync scope, after all SQLite handles were closed. Here its
/// conflict with SQLite is useful: an external active writer cannot be moved
/// aside. Never use this capability around SQLite queries/opens/transactions.
final class EditingDatabaseNativeReplacementLock {
    private let fd:Int32
    private var held = true
    private init(fd:Int32){self.fd = fd}
    deinit{release()}
    func release(){if held{held = false;_ = flock(fd,LOCK_UN)}}
    static func acquire(fd:Int32,url:URL) throws -> EditingDatabaseNativeReplacementLock {
        try EditingSQLite.checkFile(fd,url:url);try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by:.seconds(2))
        while flock(fd,LOCK_EX|LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EAGAIN || failure == EINTR else {throw EditingRepositoryError.storageFailure}
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {throw EditingRepositoryError.databaseBusy}
            if failure != EINTR {Thread.sleep(forTimeInterval:0.001)}
        }
        let admission = EditingDatabaseNativeReplacementLock(fd:fd)
        do {try Task.checkCancellation();try EditingSQLite.checkFile(fd,url:url);return admission}
        catch{admission.release();throw error}
    }
}

/// Pre-open native descriptor reservation. Once own(fd) succeeds, this is the
/// ONLY closer. A canceled observer may release its reference while a bounded
/// registry entry keeps the real descriptor alive until the SQL owner returns.
final class EditingNativeFileReservation:@unchecked Sendable {
    fileprivate let nonce:UUID
    fileprivate init(nonce:UUID){self.nonce = nonce}
    @discardableResult func own(_ fd:Int32) -> EditingNativeFileReservation {
        EditingDatabaseAccess.ownNativeFile(fd,nonce:nonce);return self
    }
    func close(){EditingDatabaseAccess.closeNativeFile(nonce)}
    deinit{close()}
}
