import Foundation
import Darwin
import CryptoKit

/// Immutable evidence is copied before any original-family rename. Raw recovery
/// archives are forensic local data, not validated restorable backup packages.
final class EditingRecoveryArchive:@unchecked Sendable {
    struct FileEvidence:Codable {let path:String;let bytes:Int64;let sha256:ArtifactDigest}
    let source:ArtifactDirectory,archive:ArtifactDirectory,originals:ArtifactDirectory
    let family:[String:ArtifactPinnedFile]
    let priorIntent:ArtifactPinnedFile?
    private let artifactRoot:ArtifactDirectory?
    private var artifactEvidence:[([String],ArtifactNativeStamp)] = []
    private var files:[FileEvidence] = []
    private var totalBytes:Int64 = 0
    private var entries = 0
    init(directory:URL) throws {
        source = try ArtifactFileIO.root(directory,create:false)
        let archives = try ArtifactFileIO.child(source,"EditingRecoveryArchives",create:true)
        let name = UUID().uuidString.lowercased()
        guard mkdirat(archives.fd.value,name,0o700) == 0 else {throw EditingRepositoryError.storageFailure}
        archive = try ArtifactFileIO.child(archives,name)
        originals = try Self.newDirectory(archive,"original-inodes")
        var family:[String:ArtifactPinnedFile] = [:]
        for suffix in ["","-journal","-wal","-shm"] {
            let leaf = "edits.sqlite"+suffix;var s = stat()
            if fstatat(source.fd.value,leaf,&s,AT_SYMLINK_NOFOLLOW) == 0 {family[leaf] = try ArtifactFileIO.openFile(source,leaf)}
            else {guard errno == ENOENT else {throw EditingRepositoryError.storageFailure}}
        }
        var intentInfo = stat()
        if fstatat(source.fd.value,EditingRecoveryIntent.leaf,&intentInfo,AT_SYMLINK_NOFOLLOW) == 0 {
            priorIntent = try ArtifactFileIO.openFile(source,EditingRecoveryIntent.leaf,limit:65_536)
        } else {guard errno == ENOENT else {throw EditingRepositoryError.recoveryRequired};priorIntent = nil}
        // Main may be absent ONLY under an existing native-pinned barrier and
        // this explicit Root-authorized recovery, never an ordinary open.
        guard family["edits.sqlite"] != nil || priorIntent != nil else {throw EditingRepositoryError.invalidDatabase}
        self.family = family
        var s = stat()
        if fstatat(source.fd.value,"GeneratedArtifacts",&s,AT_SYMLINK_NOFOLLOW) == 0 {artifactRoot = try ArtifactFileIO.child(source,"GeneratedArtifacts")}
        else {guard errno == ENOENT else {throw EditingRepositoryError.storageFailure};artifactRoot = nil}
    }
    func capture() throws {
        for name in family.keys.sorted() {try copy(family[name]!,to:archive,name:name,path:name)}
        if let priorIntent {try copy(priorIntent,to:archive,name:EditingRecoveryIntent.leaf,path:EditingRecoveryIntent.leaf)}
        if let artifactRoot {
            let target = try Self.newDirectory(archive,"GeneratedArtifacts")
            try copyTree(artifactRoot,to:target,path:[],depth:0)
        }
        let data = try EditingContractJSON.encoder().encode(files)
        try ArtifactFileIO.writeSmall(archive,"raw-family-and-artifacts.json",bytes:data,limit:8_388_608)
        try sync(archive);if let parent = archive.parent {try sync(parent)};try sync(source)
        try validateOriginalFamily()
    }
    private func copyTree(_ from:ArtifactDirectory,to:ArtifactDirectory,path:[String],depth:Int) throws {
        guard depth <= 4 else {throw ArtifactContractError.limitExceeded}
        for name in try ArtifactFileIO.names(from,maximum:16_384) {
            guard entries < 32_768 else {throw ArtifactContractError.limitExceeded};entries += 1
            var s = stat();guard fstatat(from.fd.value,name,&s,AT_SYMLINK_NOFOLLOW) == 0 else {throw EditingRepositoryError.storageFailure}
            let stamp = ArtifactNativeStamp(s)
            if stamp.isDirectory {
                try copyTree(ArtifactFileIO.child(from,name),to:Self.newDirectory(to,name),path:path+[name],depth:depth+1)
            } else {
                guard stamp.isRegular else {throw EditingRepositoryError.invalidDatabase}
                let file = try ArtifactFileIO.openFile(from,name)
                try copy(file,to:to,name:name,path:(["GeneratedArtifacts"]+path+[name]).joined(separator:"/"))
                artifactEvidence.append((path+[name],file.stamp))
            }
        }
        try sync(to)
    }
    private func copy(_ file:ArtifactPinnedFile,to:ArtifactDirectory,name:String,path:String) throws {
        guard files.count < 16_384,file.stamp.bytes <= 21_474_836_480-totalBytes else {throw ArtifactContractError.limitExceeded}
        try to.validate()
        let out = openat(to.fd.value,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o400)
        guard out >= 0 else {throw EditingRepositoryError.storageFailure};defer{close(out)}
        var offset:Int64 = 0,hash = SHA256()
        while offset < file.stamp.bytes {
            try autoreleasepool {
                let data = try file.read(offset:offset,count:Int(min(65_536,file.stamp.bytes-offset)))
                guard !data.isEmpty else {throw EditingRepositoryError.storageFailure}
                try ArtifactFileIO.writeAll(out,data)
                hash.update(data:data);offset += Int64(data.count)
            }
        }
        guard fsync(out) == 0 else {throw EditingRepositoryError.storageFailure}
        try file.validate();try to.validate()
        files.append(.init(path:path,bytes:file.stamp.bytes,sha256:try ArtifactFileIO.digest(hash.finalize())))
        totalBytes += file.stamp.bytes
    }
    func validateOriginalFamily() throws {
        try source.validate()
        if let priorIntent {try priorIntent.validate()}
        else {var entry = stat();guard fstatat(source.fd.value,EditingRecoveryIntent.leaf,&entry,AT_SYMLINK_NOFOLLOW) != 0,errno == ENOENT else {throw EditingRepositoryError.recoveryRequired}}
        for suffix in ["","-journal","-wal","-shm"] {
            let name = "edits.sqlite"+suffix
            if let file = family[name] {try file.validate()}
            else {var s = stat();guard fstatat(source.fd.value,name,&s,AT_SYMLINK_NOFOLLOW) != 0,errno == ENOENT else {throw EditingRepositoryError.recoveryRequired}}
        }
    }
    func validateArchivedArtifactSources() throws {
        guard let artifactRoot else {return}
        for (parts,stamp) in artifactEvidence {
            var directory = artifactRoot
            for name in parts.dropLast() {directory = try ArtifactFileIO.child(directory,name)}
            let file = try ArtifactFileIO.openFile(directory,parts.last!)
            guard file.stamp == stamp else {throw EditingRepositoryError.recoveryRequired}
        }
    }
    /// Called only inside the root's final journal+catalog critical section.
    /// No accepted original file is deleted: original inodes are moved aside.
    func install(candidate:ArtifactPinnedFile,checkpoint:@Sendable(EditingRecoveryCheckpoint)->Void = {_ in}) throws {
        // Order: Root coordination -> Catalog -> process identity mutex ->
        // main kernel lock. This last scope is entirely SQL-free, so the kernel
        // lock safely refuses even an external active SQLite writer.
        // Missing main is admitted only by the already pinned prior intent.
        let mainAdmission:EditingDatabaseAccess?
        if let main = family["edits.sqlite"] {
            mainAdmission = try EditingDatabaseAccess.acquire(fd:main.fd.value,url:main.directory.url.appendingPathComponent(main.leaf,isDirectory:false))
        } else {mainAdmission = nil}
        defer{mainAdmission?.release()}
        let nativeAdmission:EditingDatabaseNativeReplacementLock?
        if let main = family["edits.sqlite"] {
            nativeAdmission = try EditingDatabaseNativeReplacementLock.acquire(fd:main.fd.value,url:main.directory.url.appendingPathComponent(main.leaf,isDirectory:false))
        }else{nativeAdmission = nil}
        defer{nativeAdmission?.release()}
        try validateOriginalFamily();try candidate.validate();try archive.validate();try originals.validate()
        let intent = try EditingRecoveryIntent(root:source,archive:archive,prior:priorIntent,family:family,candidate:candidate)
        checkpoint(.intentDurable)
        var moved:[String] = []
        do {
            for name in family.keys.sorted() {
                guard renameatx_np(source.fd.value,name,originals.fd.value,name,UInt32(RENAME_EXCL)) == 0 else {throw EditingRepositoryError.storageFailure}
                moved.append(name)
                var s = stat();guard fstatat(originals.fd.value,name,&s,AT_SYMLINK_NOFOLLOW) == 0,
                    let old = family[name],ArtifactNativeStamp(s).isRegular,ArtifactNativeStamp(s).sameObject(old.stamp) else {throw EditingRepositoryError.recoveryRequired}
                checkpoint(.memberMoved(name))
            }
            // Exclusive rename cannot replace a new unknown entry at edits.sqlite.
            guard renameatx_np(candidate.directory.fd.value,candidate.leaf,source.fd.value,"edits.sqlite",UInt32(RENAME_EXCL)) == 0 else {throw EditingRepositoryError.storageFailure}
        } catch {
            for name in moved.reversed() {
                var s = stat()
                guard fstatat(source.fd.value,name,&s,AT_SYMLINK_NOFOLLOW) != 0,errno == ENOENT else {throw EditingRepositoryError.recoveryRequired}
                guard renameatx_np(originals.fd.value,name,source.fd.value,name,UInt32(RENAME_EXCL)) == 0 else {throw EditingRepositoryError.recoveryRequired}
            }
            throw error
        }
        // The namespace commit is now complete. A sync failure is explicitly
        // ambiguous, never represented as a clean rollback or lost originals.
        guard fsync(source.fd.value) == 0,fsync(originals.fd.value) == 0,fsync(candidate.directory.fd.value) == 0 else {throw ArtifactContractError.ambiguousCommit}
        checkpoint(.candidateInstalled)
        try intent.finish();checkpoint(.intentRemoved)
    }
    private static func newDirectory(_ parent:ArtifactDirectory,_ leaf:String) throws -> ArtifactDirectory {
        try ArtifactFileIO.validLeaf(leaf);try parent.validate()
        guard mkdirat(parent.fd.value,leaf,0o700) == 0 else {throw EditingRepositoryError.storageFailure}
        return try ArtifactFileIO.child(parent,leaf)
    }
    private func sync(_ directory:ArtifactDirectory) throws {try directory.validate();guard fsync(directory.fd.value) == 0 else {throw EditingRepositoryError.storageFailure}}
}
