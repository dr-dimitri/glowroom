import Foundation
import Darwin
import CryptoKit

struct PhotoMetadataFileStamp: Equatable {
    let device: Int64, inode: UInt64, size: Int64
    let mtimeSeconds: Int64, mtimeNanos: Int64, ctimeSeconds: Int64, ctimeNanos: Int64
    init(_ s: stat) {
        device = Int64(s.st_dev); inode = UInt64(s.st_ino); size = s.st_size
        mtimeSeconds = Int64(s.st_mtimespec.tv_sec); mtimeNanos = Int64(s.st_mtimespec.tv_nsec)
        ctimeSeconds = Int64(s.st_ctimespec.tv_sec); ctimeNanos = Int64(s.st_ctimespec.tv_nsec)
    }
}

/// Synchronous bounded I/O called only on the repository actor. No new worker
/// pool: SQLite and its dependent publication are intentionally serialized.
enum PhotoMetadataFiles {
    static func nativeStamp(_ source: MetadataSourceFingerprint) throws -> MetadataNativeSourceStamp {
        let url = URL(fileURLWithPath:source.standardizedPath,isDirectory:false)
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fd = Darwin.open(url.path,O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw PhotoMetadataError.sourceChanged }; defer { Darwin.close(fd) }
        var s = stat()
        guard fstat(fd,&s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size == source.fileSize else { throw PhotoMetadataError.sourceChanged }
        let time = Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec)/1_000_000_000
        guard abs(time-source.modifiedAt.timeIntervalSince1970) <= 0.000_005 else { throw PhotoMetadataError.sourceChanged }
        func stamp(_ t: timespec) -> MetadataTimestamp { .init(seconds:Int64(t.tv_sec),nanoseconds:Int32(t.tv_nsec)) }
        return .init(identity:.init(device:Int64(s.st_dev),inode:UInt64(s.st_ino)),byteCount:s.st_size,
            modifiedAt:stamp(s.st_mtimespec),changedAt:stamp(s.st_ctimespec),
            birthTime:s.st_birthtimespec.tv_sec == 0 && s.st_birthtimespec.tv_nsec == 0 ? nil : stamp(s.st_birthtimespec),
            fileGeneration:s.st_gen == 0 ? nil : UInt64(s.st_gen))
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let opened = try openRegular(url)
        defer { Darwin.close(opened.fd) }
        guard opened.stamp.size >= 0, opened.stamp.size <= maximum else { throw PhotoMetadataError.limitExceeded(.jsonDocument) }
        var result = Data(); result.reserveCapacity(Int(opened.stamp.size))
        var buffer = [UInt8](repeating:0,count:65_536)
        while true {
            if Task.isCancelled { throw PhotoMetadataError.cancelled }
            let count = Darwin.read(opened.fd,&buffer,buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw PhotoMetadataError.storageFailure }
            guard result.count <= maximum-count else { throw PhotoMetadataError.limitExceeded(.jsonDocument) }
            result.append(contentsOf:buffer.prefix(count))
        }
        try unchanged(opened.fd,url:url,stamp:opened.stamp)
        return result
    }
    static func reference(_ url: URL) throws -> MetadataCatalogFileReference {
        var leaf = stat()
        if lstat(url.path,&leaf) != 0 {
            guard errno == ENOENT else { throw PhotoMetadataError.storageFailure }; return .absent
        }
        let opened = try openRegular(url); defer { Darwin.close(opened.fd) }
        guard opened.stamp.size <= 536_870_912 else { throw PhotoMetadataError.limitExceeded(.catalogChange) }
        var hash = SHA256(), bytes: Int64 = 0, buffer = [UInt8](repeating:0,count:65_536)
        while true {
            if Task.isCancelled { throw PhotoMetadataError.cancelled }
            let count = Darwin.read(opened.fd,&buffer,buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw PhotoMetadataError.storageFailure }
            guard bytes <= Int64.max-Int64(count) else { throw PhotoMetadataError.storageFailure }
            hash.update(data:Data(buffer.prefix(count))); bytes += Int64(count)
        }
        try unchanged(opened.fd,url:url,stamp:opened.stamp)
        return .present(sha256:hash.finalize().map { String(format:"%02x",$0) }.joined(),byteCount:bytes)
    }
    private static func openRegular(_ url: URL) throws -> (fd:Int32,stamp:PhotoMetadataFileStamp) {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw PhotoMetadataError.protectedPath }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fd = Darwin.open(url.path,O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw PhotoMetadataError.storageFailure }
        var s = stat(), path = stat()
        guard fstat(fd,&s) == 0, lstat(url.path,&path) == 0,
              s.st_mode & S_IFMT == S_IFREG, path.st_mode & S_IFMT == S_IFREG,
              s.st_nlink == 1, s.st_dev == path.st_dev, s.st_ino == path.st_ino else {
            Darwin.close(fd); throw PhotoMetadataError.protectedPath
        }
        return (fd,.init(s))
    }
    private static func unchanged(_ fd: Int32, url: URL, stamp: PhotoMetadataFileStamp) throws {
        var current = stat(), path = stat()
        guard fstat(fd,&current) == 0, lstat(url.path,&path) == 0,
              current.st_nlink == 1, PhotoMetadataFileStamp(current) == stamp,
              path.st_mode & S_IFMT == S_IFREG, path.st_dev == current.st_dev, path.st_ino == current.st_ino else { throw PhotoMetadataError.storageFailure }
    }
    /// Fixed-size target identity. Candidates can be checked one at a time,
    /// so a large catalog/orphan history never needs a second full URL array.
    struct DestinationCheck {
        let canonicalPath: String
        let identity: (dev_t,ino_t)?
        init(_ url: URL) throws {
            guard url.isFileURL, !url.path.utf8.contains(0) else { throw PhotoMetadataError.protectedPath }
            canonicalPath = FilePathComparison.canonicalPath(url)
            var target = stat()
            if lstat(url.path,&target) == 0 {
                guard target.st_mode & S_IFMT == S_IFREG, target.st_nlink == 1 else { throw PhotoMetadataError.protectedPath }
                identity = (target.st_dev,target.st_ino)
            } else {
                guard errno == ENOENT else { throw PhotoMetadataError.storageFailure }; identity = nil
            }
        }
        func checkFile(_ candidate: URL) throws {
            if Task.isCancelled { throw PhotoMetadataError.cancelled }
            guard candidate.isFileURL else { return }
            if candidate.hasDirectoryPath, try PhotoMetadataFiles.contains(canonicalPath,in:candidate) { throw PhotoMetadataError.protectedPath }
            if FilePathComparison.canonicalPath(candidate) == canonicalPath { throw PhotoMetadataError.protectedPath }
            if let identity, let other = PhotoMetadataFiles.fileIdentity(candidate), identity.0 == other.0, identity.1 == other.1 { throw PhotoMetadataError.protectedPath }
        }
    }
    static func checkDestination(_ url: URL, protection: MetadataFileProtectionSnapshot, extra: [URL],
                                 additionalProtection: (DestinationCheck) throws -> Void = { _ in }) throws {
        let check = try DestinationCheck(url)
        // Do not concatenate these arrays: caller snapshots can already contain
        // a large catalog. Iterate their existing storage directly.
        for candidate in protection.originalURLs { try autoreleasepool { try check.checkFile(candidate) } }
        for candidate in protection.managedFileURLs { try autoreleasepool { try check.checkFile(candidate) } }
        for candidate in extra { try autoreleasepool { try check.checkFile(candidate) } }
        for directory in protection.managedDirectoryURLs {
            if try contains(check.canonicalPath,in:directory) { throw PhotoMetadataError.protectedPath }
        }
        for family in protection.managedDirectoryFamilies {
            guard !family.childNamePrefix.isEmpty else { throw PhotoMetadataError.protectedPath }
            if try visitPathAndParentDirectories(of:check.canonicalPath, { current in
                guard current.path != "/" else { return false }
                let parent = URL(fileURLWithPath:(current.path as NSString).deletingLastPathComponent,isDirectory:true)
                return (FilePathComparison.canonicalPath(parent) == FilePathComparison.canonicalPath(family.parent) || sameDirectory(parent,family.parent)) && current.lastPathComponent.hasPrefix(family.childNamePrefix)
            }) { throw PhotoMetadataError.protectedPath }
        }
        try additionalProtection(check)
    }
    private static func fileIdentity(_ url: URL) -> (dev_t,ino_t)? {
        let descriptor = Darwin.open(url.path,O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }; defer { Darwin.close(descriptor) }
        var s = stat(); guard fstat(descriptor,&s) == 0 else { return nil }; return (s.st_dev,s.st_ino)
    }
    private static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let l = fileIdentity(lhs), let r = fileIdentity(rhs) else { return false }; return l.0 == r.0 && l.1 == r.1
    }
    private static func contains(_ path: String, in directory: URL) throws -> Bool {
        let rootPath = FilePathComparison.canonicalPath(directory)
        if path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") { return true }
        return try visitPathAndParentDirectories(of:path) { current in sameDirectory(current,directory) }
    }
    /// Ascend lexical absolute paths, not Foundation's URL parent operation:
    /// that operation can append `..` after reaching a root URL. Both callers
    /// share strict progress and a fail-closed bound, including the root itself.
    private static func visitPathAndParentDirectories(of path: String, _ visit: (URL) -> Bool) throws -> Bool {
        guard path.hasPrefix("/") else { throw PhotoMetadataError.protectedPath }
        // Include the leaf itself: a reserved directory/family root must not
        // become an export file merely because the directory is currently absent.
        var current = path
        for _ in 0..<4_096 {
            guard current.hasPrefix("/"), !current.isEmpty else { throw PhotoMetadataError.protectedPath }
            if visit(URL(fileURLWithPath:current,isDirectory:true)) { return true }
            if current == "/" { return false }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent.utf8.count < current.utf8.count else { throw PhotoMetadataError.protectedPath }
            current = parent
        }
        throw PhotoMetadataError.protectedPath
    }
    static func atomicExport(_ url: URL, protection: MetadataFileProtectionSnapshot, extra: [URL],
                             additionalProtection: @escaping (DestinationCheck) throws -> Void = { _ in },
                             beforePublish: @escaping () throws -> Void,
                             publication: (_ operation: () throws -> Void) throws -> Void = { try $0() },
                             body: (_ write: (Data) throws -> Void) throws -> Void) throws -> (Int64,String) {
        try checkDestination(url,protection:protection,extra:extra,additionalProtection:additionalProtection)
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let parentURL = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let parent = Darwin.open(parentURL.path,O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard parent >= 0 else { throw PhotoMetadataError.exportFailure }; defer { Darwin.close(parent) }
        var targetBefore = stat(); let existed = fstatat(parent,url.lastPathComponent,&targetBefore,AT_SYMLINK_NOFOLLOW) == 0
        let leaf = ".photo-metadata-export-\(UUID().uuidString).tmp"
        let fd = openat(parent,leaf,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw PhotoMetadataError.exportFailure }
        var published = false
        defer {
            if !published {
                var owned = stat(), current = stat()
                if fstat(fd,&owned) == 0, fstatat(parent,leaf,&current,AT_SYMLINK_NOFOLLOW) == 0,
                   owned.st_dev == current.st_dev, owned.st_ino == current.st_ino, current.st_nlink == 1 { _ = unlinkat(parent,leaf,0) }
            }
            Darwin.close(fd)
        }
        var bytes: Int64 = 0, hash = SHA256()
        try body { data in
            if Task.isCancelled { throw PhotoMetadataError.cancelled }
            guard bytes <= Int64(PhotoMetadataLimits.maximumJSONDocumentBytes)-Int64(data.count) else { throw PhotoMetadataError.limitExceeded(.jsonDocument) }
            try data.withUnsafeBytes { raw in
                var position = 0
                while position < raw.count {
                    let count = Darwin.write(fd,raw.baseAddress!.advanced(by:position),min(65_536,raw.count-position))
                    if count < 0 { if errno == EINTR { continue }; throw PhotoMetadataError.exportFailure }
                    guard count > 0 else { throw PhotoMetadataError.exportFailure }; position += count
                }
            }
            bytes += Int64(data.count); hash.update(data:data)
        }
        guard fsync(fd) == 0 else { throw PhotoMetadataError.exportFailure }
        var initialStage = stat()
        guard fstat(fd,&initialStage) == 0, initialStage.st_size == bytes, initialStage.st_nlink == 1 else { throw PhotoMetadataError.exportFailure }
        let expectedHash = hash.finalize().map { String(format:"%02x",$0) }.joined()
        try publication {
        try beforePublish()
        try checkDestination(url,protection:protection,extra:extra,additionalProtection:additionalProtection)
        // Revalidate parent identity and the pre-existing leaf immediately before
        // rename, so /var, parent symlinks, hardlinks and changed destinations do
        // not convert an overwrite confirmation into a different-file write.
        let namedParent = Darwin.open(url.deletingLastPathComponent().path,O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard namedParent >= 0 else { throw PhotoMetadataError.protectedPath }
        defer { Darwin.close(namedParent) }
        var pinnedParent = stat(), currentParent = stat()
        guard fstat(parent,&pinnedParent) == 0, fstat(namedParent,&currentParent) == 0,
              pinnedParent.st_dev == currentParent.st_dev, pinnedParent.st_ino == currentParent.st_ino else { throw PhotoMetadataError.protectedPath }
        var now = stat(); let exists = fstatat(parent,url.lastPathComponent,&now,AT_SYMLINK_NOFOLLOW) == 0
        guard exists == existed, !exists || (PhotoMetadataFileStamp(now) == PhotoMetadataFileStamp(targetBefore) && now.st_nlink == 1) else { throw PhotoMetadataError.protectedPath }
        // The stage name itself must still designate the exact private inode
        // we wrote, not a replacement introduced while a hook/lock ran.
        var stageNow = stat(), namedStage = stat()
        guard fstat(fd,&stageNow) == 0, fstatat(parent,leaf,&namedStage,AT_SYMLINK_NOFOLLOW) == 0,
              stageNow.st_mode & S_IFMT == S_IFREG, namedStage.st_mode & S_IFMT == S_IFREG,
              stageNow.st_nlink == 1, namedStage.st_nlink == 1,
              PhotoMetadataFileStamp(stageNow) == PhotoMetadataFileStamp(initialStage),
              PhotoMetadataFileStamp(namedStage) == PhotoMetadataFileStamp(initialStage) else { throw PhotoMetadataError.protectedPath }
        var verified = SHA256(), position:Int64 = 0
        var buffer = [UInt8](repeating:0,count:65_536)
        while position < bytes {
            let amount = pread(fd,&buffer,min(buffer.count,Int(bytes-position)),off_t(position))
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw PhotoMetadataError.exportFailure }
            verified.update(data:Data(buffer.prefix(amount))); position += Int64(amount)
        }
        guard verified.finalize().map({ String(format:"%02x",$0) }).joined() == expectedHash,
              fstat(fd,&stageNow) == 0, PhotoMetadataFileStamp(stageNow) == PhotoMetadataFileStamp(initialStage),
              fstatat(parent,leaf,&namedStage,AT_SYMLINK_NOFOLLOW) == 0,
              PhotoMetadataFileStamp(namedStage) == PhotoMetadataFileStamp(initialStage), namedStage.st_nlink == 1 else { throw PhotoMetadataError.protectedPath }
        if existed {
            guard renameat(parent,leaf,parent,url.lastPathComponent) == 0 else { throw PhotoMetadataError.exportFailure }
        } else {
            guard renameatx_np(parent,leaf,parent,url.lastPathComponent,UInt32(RENAME_EXCL)) == 0 else { throw PhotoMetadataError.exportFailure }
        }
        published = true
        }
        // Rename has succeeded: an unsupported directory fsync must not report
        // an unchanged target. The completed file is already fully fsynced.
        _ = fsync(parent)
        return (bytes,expectedHash)
    }
}
