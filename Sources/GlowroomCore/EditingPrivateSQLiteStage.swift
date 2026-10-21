import Foundation
import Darwin

/// At most four SQLite-family FDs. Creation immediately registers the actual
/// owned FD; cleanup is shallow and removes only the still-named same inode.
/// SQLite may grow its already-owned WAL/SHM. Foreign entries/replacements are
/// always retained, including when that means retaining the private directory.
final class EditingPrivateSQLiteStage {
    let directory:ArtifactDirectory
    private let parent:ArtifactDirectory,leaf:String
    private var files:[String:ArtifactNativeFD] = [:]
    init(prefix:String) throws {
        parent = try ArtifactFileIO.root(FileManager.default.temporaryDirectory,create:false)
        leaf = prefix+UUID().uuidString.lowercased()
        guard mkdirat(parent.fd.value,leaf,0o700) == 0 else {throw EditingRepositoryError.storageFailure}
        var created = stat();guard fstatat(parent.fd.value,leaf,&created,AT_SYMLINK_NOFOLLOW) == 0 else {throw EditingRepositoryError.storageFailure}
        directory = try ArtifactFileIO.child(parent,leaf)
        var opened = stat();guard fstat(directory.fd.value,&opened) == 0,created.st_dev == opened.st_dev,created.st_ino == opened.st_ino else {throw EditingRepositoryError.recoveryRequired}
    }
    deinit{cleanup()}
    func createFile(_ name:String) throws -> Int32 {
        try ArtifactFileIO.validLeaf(name);guard files.count < 4,files[name] == nil else {throw EditingRepositoryError.invalidDatabase}
        try directory.validate()
        let reservation = try EditingDatabaseAccess.reserveNativeFile()
        let fd = openat(directory.fd.value,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else {throw EditingRepositoryError.storageFailure}
        files[name] = ArtifactNativeFD(fd,editingOwnership:reservation.own(fd))
        return fd
    }
    func url(_ name:String) -> URL {directory.url.appendingPathComponent(name,isDirectory:false)}
    func prepareAbsentWALFiles() throws {
        for name in ["edits.sqlite-wal","edits.sqlite-shm"] where files[name] == nil {_ = try createFile(name)}
    }
    func cleanup() {
        guard (try? directory.validate()) != nil else {return}
        for (name,handle) in files {
            var own = stat(),named = stat()
            guard fstat(handle.value,&own) == 0,fstatat(directory.fd.value,name,&named,AT_SYMLINK_NOFOLLOW) == 0,
                  own.st_mode & S_IFMT == S_IFREG,named.st_mode & S_IFMT == S_IFREG,
                  own.st_nlink == 1,named.st_nlink == 1,own.st_dev == named.st_dev,own.st_ino == named.st_ino else {continue}
            _ = unlinkat(directory.fd.value,name,0)
        }
        guard (try? directory.validate()) != nil else {return}
        // rmdir is nonrecursive: any unknown entry makes it fail safely.
        _ = unlinkat(parent.fd.value,leaf,AT_REMOVEDIR)
    }
}
