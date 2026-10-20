import Foundation
import Darwin

public enum EditingRecoveryCheckpoint:Equatable,Sendable {
    case intentDurable,memberMoved(String),candidateInstalled,intentRemoved
}

/// A durable barrier, never decoded as authority. Even unknown intent bytes
/// fence ordinary opens. Explicit recovery retains a prior regular intent as
/// raw evidence, then atomically replaces it using our own creation FD.
final class EditingRecoveryIntent {
    static let leaf = "edits.sqlite-recovery.json"
    private struct Value:Codable {
        let schemaVersion:Int,application:String,operationID:UUID,archive:String
        let originalFamily:[String:ArtifactNativeStamp]
        let previousIntent:ArtifactNativeStamp?
        let candidate:ArtifactNativeStamp
    }
    private let root:ArtifactDirectory,fd:ArtifactNativeFD
    private let bound:ArtifactNativeStamp
    init(root:ArtifactDirectory,archive:ArtifactDirectory,prior:ArtifactPinnedFile?,family:[String:ArtifactPinnedFile],candidate:ArtifactPinnedFile) throws {
        self.root = root;try root.validate();try archive.validate();try candidate.validate()
        let value = Value(schemaVersion:1,application:"Glowroom.EditingRecovery",operationID:UUID(),archive:archive.leaf!,
            originalFamily:family.mapValues(\.stamp),previousIntent:prior?.stamp,candidate:candidate.stamp)
        let bytes = try EditingContractJSON.encoder().encode(value)
        guard bytes.count <= 65_536 else {throw ArtifactContractError.limitExceeded}
        let pending = "recovery-intent.pending"
        let opened = openat(archive.fd.value,pending,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard opened >= 0 else {throw EditingRepositoryError.recoveryRequired}
        let ownership = ArtifactNativeFD(opened)
        try ArtifactFileIO.writeAll(opened,bytes)
        guard fsync(opened) == 0 else {throw EditingRepositoryError.storageFailure}
        let created = try ArtifactPinnedFile(fd:ownership,directory:archive,leaf:pending)
        try created.validate()
        if let prior {
            try prior.validate()
            // An atomic exchange has no absent-barrier window. The old actual
            // inode remains in this new archive; it is never deleted/adopted.
            guard renameatx_np(archive.fd.value,pending,root.fd.value,Self.leaf,UInt32(RENAME_SWAP)) == 0 else {throw EditingRepositoryError.recoveryRequired}
        } else {
            guard renameatx_np(archive.fd.value,pending,root.fd.value,Self.leaf,UInt32(RENAME_EXCL)) == 0 else {throw EditingRepositoryError.recoveryRequired}
        }
        var installed = stat(),named = stat()
        guard fstat(opened,&installed) == 0,ArtifactNativeStamp(installed).sameObject(created.stamp),
              fstatat(root.fd.value,Self.leaf,&named,AT_SYMLINK_NOFOLLOW) == 0,
              ArtifactNativeStamp(installed) == ArtifactNativeStamp(named),ArtifactNativeStamp(installed).isRegular else {throw EditingRepositoryError.recoveryRequired}
        fd = ownership;bound = ArtifactNativeStamp(installed)
        guard fsync(archive.fd.value) == 0,fsync(root.fd.value) == 0 else {throw EditingRepositoryError.recoveryRequired}
    }
    func finish() throws {
        try root.validate();var own = stat(),named = stat()
        guard fstat(fd.value,&own) == 0,ArtifactNativeStamp(own) == bound,
              fstatat(root.fd.value,Self.leaf,&named,AT_SYMLINK_NOFOLLOW) == 0,
              ArtifactNativeStamp(named) == bound else {throw EditingRepositoryError.recoveryRequired}
        guard unlinkat(root.fd.value,Self.leaf,0) == 0,fsync(root.fd.value) == 0 else {throw ArtifactContractError.ambiguousCommit}
    }
    static func requireAbsent(for database:URL) throws {
        var entry = stat()
        if lstat(database.path+"-recovery.json",&entry) == 0 {throw EditingRepositoryError.recoveryRequired}
        guard errno == ENOENT else {throw EditingRepositoryError.storageFailure}
    }
}
