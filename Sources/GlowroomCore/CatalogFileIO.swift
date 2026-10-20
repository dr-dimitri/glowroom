import CryptoKit
import Darwin
import Foundation

public struct StoredLibraryCatalog: Sendable {
    public let catalog: LibraryCatalog
    public let reference: MetadataCatalogFileReference
    public init(catalog: LibraryCatalog, reference: MetadataCatalogFileReference) {
        self.catalog = catalog; self.reference = reference
    }
}

public final class PreparedLibraryCatalog: Sendable {
    public let catalog: LibraryCatalog
    public let reference: MetadataCatalogFileReference
    internal let bytes: Data
    internal init(catalog: LibraryCatalog, bytes: Data) {
        self.catalog = catalog; self.bytes = bytes
        reference = .present(sha256: CatalogFileIO.digest(bytes), byteCount: Int64(bytes.count))
    }
}

internal final class CatalogDirectoryHandle: @unchecked Sendable {
    let descriptor: Int32
    private let editingOwnership: EditingNativeFileReservation?
    init(_ descriptor: Int32, editingOwnership: EditingNativeFileReservation? = nil) {
        self.descriptor = descriptor; self.editingOwnership = editingOwnership
    }
    deinit {
        if let editingOwnership { editingOwnership.close() }
        else { close(descriptor) }
    }
}

/// Not Codable or publicly constructible: only the repository can mint a stage.
/// Retained directory FDs pin ownership even while a metadata actor is awaited.
public final class StagedLibraryCatalog: @unchecked Sendable {
    public let id: UUID
    public let prepared: PreparedLibraryCatalog
    internal let root: CatalogDirectoryHandle
    internal let stage: CatalogDirectoryHandle
    internal let name: String
    internal let payload: CatalogDirectoryHandle
    internal let validateAdditionalBoundary: @Sendable () throws -> Void
    internal init(id: UUID, prepared: PreparedLibraryCatalog, root: CatalogDirectoryHandle,
                     stage: CatalogDirectoryHandle, name: String, payload: CatalogDirectoryHandle,
                     validateAdditionalBoundary: @escaping @Sendable () throws -> Void = {}) {
        self.id = id; self.prepared = prepared; self.root = root; self.stage = stage; self.name = name; self.payload = payload
        self.validateAdditionalBoundary = validateAdditionalBoundary
    }
}

internal enum CatalogFileIO {
    static let maximumBytes = 536_870_912
    static let stagingDirectoryName = "MetadataCatalogStaging"
    private static let lockName = "catalog-write.lock"
    struct Contents {
        let data: Data?
        let reference: MetadataCatalogFileReference
    }
    private struct FileStamp: Equatable {
        let device: Int64; let inode: UInt64; let size: Int64
        let modifiedSeconds: Int64; let modifiedNanoseconds: Int64
        let changedSeconds: Int64; let changedNanoseconds: Int64
        init(_ value: stat) {
            device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func readCatalog(directory: URL, beforeOpen: () throws -> Void = {}) throws -> Contents {
        guard directory.isFileURL else { throw CatalogRepositoryError.invalidCatalog("Kein lokales Datenverzeichnis.") }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if root < 0 && errno == ENOENT { return Contents(data: nil, reference: .absent) }
        guard root >= 0 else { throw posix("Katalogverzeichnis öffnen") }
        defer { close(root) }
        return try read(root: root, name: "catalog.json", missingAllowed: true, beforeOpen: beforeOpen)
    }

    static func stage(_ prepared: PreparedLibraryCatalog, directory: URL, id: UUID) throws -> StagedLibraryCatalog {
        guard directory.isFileURL else { throw CatalogRepositoryError.invalidStage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw posix("Katalogverzeichnis öffnen") }
        let root = CatalogDirectoryHandle(rootFD)
        if mkdirat(rootFD, stagingDirectoryName, 0o700) != 0 && errno != EEXIST { throw posix("Katalog-Staging anlegen") }
        let stageFD = openat(rootFD, stagingDirectoryName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stageFD >= 0 else { throw CatalogRepositoryError.invalidStage }
        let stage = CatalogDirectoryHandle(stageFD)
        let name = id.uuidString.lowercased() + ".catalog.json"
        let ownership = try EditingDatabaseAccess.reserveNativeFile()
        let file = openat(stageFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw CatalogRepositoryError.invalidStage }
        ownership.own(file)
        var completed = false
        defer {
            if !completed { removeOwnedPayload(file: file, root: stageFD, name: name); ownership.close() }
        }
        try prepared.bytes.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw posix("Katalog-Staging schreiben") }
                offset += amount
            }
        }
        guard fsync(file) == 0, fsync(stageFD) == 0, fsync(rootFD) == 0 else { throw posix("Katalog-Staging sichern") }
        completed = true
        return StagedLibraryCatalog(id: id, prepared: prepared, root: root, stage: stage, name: name,
                                    payload: CatalogDirectoryHandle(file, editingOwnership: ownership))
    }

    static func publish(_ stage: StagedLibraryCatalog, directory: URL, expected: MetadataCatalogFileReference) throws {
        let root = stage.root.descriptor
        let currentRoot = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentRoot >= 0 else { throw CatalogRepositoryError.concurrentModification }
        defer { close(currentRoot) }
        guard sameDirectory(root, currentRoot) else { throw CatalogRepositoryError.concurrentModification }
        try locked(root: root) { previous in
            let source = try read(root: stage.stage.descriptor, name: stage.name, missingAllowed: false, captureBytes: false)
            guard source.reference == stage.prepared.reference,
                  ownsPayload(file: stage.payload.descriptor, root: stage.stage.descriptor, name: stage.name) else { throw CatalogRepositoryError.invalidStage }
            guard previous == expected else { throw CatalogRepositoryError.concurrentModification }
            try stage.validateAdditionalBoundary()
            // The fixed leaf is replaced, never followed; cooperative publishers use
            // this same native lock. A missing catalog is distinct from empty bytes.
            guard renameat(stage.stage.descriptor, stage.name, root, "catalog.json") == 0 else { throw posix("Katalog veröffentlichen") }
            // Rename is the commit point; a later directory flush failure cannot
            // report that the newly visible catalog never became active.
            _ = fsync(root); _ = fsync(stage.stage.descriptor)
        }
    }

    static func withPublicationLock<Result>(directory: URL, beforeLockOpen: () throws -> Void = {},
        operation: (MetadataCatalogFileReference) throws -> Result) throws -> Result {
        guard directory.isFileURL else { throw CatalogRepositoryError.invalidStage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw posix("Katalogverzeichnis öffnen") }
        defer { close(root) }
        return try locked(root: root, beforeOpen: beforeLockOpen, operation: operation)
    }

    /// Read through the locked native root. The boundary check is used after
    /// source-path inspection and immediately before destructive maintenance.
    static func withSnapshotLock<Result>(directory: URL,
        operation: (Contents, () throws -> Void) throws -> Result) throws -> Result {
        guard directory.isFileURL else { throw CatalogRepositoryError.invalidStage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw posix("Katalogverzeichnis öffnen") }
        defer { close(root) }
        return try locked(root: root) { expected in
            let contents = try read(root: root, name: "catalog.json", missingAllowed: true)
            guard contents.reference == expected else { throw CatalogRepositoryError.concurrentModification }
            return try operation(contents) {
                let named = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard named >= 0 else { throw CatalogRepositoryError.concurrentModification }
                defer { close(named) }
                guard sameDirectory(root, named),
                      try read(root: root, name: "catalog.json", missingAllowed: true, captureBytes: false).reference == expected else {
                    throw CatalogRepositoryError.concurrentModification
                }
            }
        }
    }

    /// Shared by catalog publication and metadata JSON final publication. No
    /// async calls or callbacks into this repository are allowed while held.
    private static func locked<Result>(root: Int32, beforeOpen: () throws -> Void = {},
        operation: (MetadataCatalogFileReference) throws -> Result) throws -> Result {
        // Reject a stable alias without opening it, including SQLite stores
        // outside EditingDatabaseAccess. A raced replacement still needs the
        // reserved native owner before any post-open validation can throw.
        if let named = try entry(root: root, name: lockName) {
            guard named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1 else {
                throw CatalogRepositoryError.concurrentModification
            }
        }
        try beforeOpen()
        let ownership = try EditingDatabaseAccess.reserveNativeFile()
        let lock = openat(root, lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CatalogRepositoryError.concurrentModification }
        ownership.own(lock)
        defer { ownership.close() }
        var lockStat = stat()
        guard fstat(lock, &lockStat) == 0, lockStat.st_mode & S_IFMT == S_IFREG, lockStat.st_nlink == 1 else {
            throw CatalogRepositoryError.concurrentModification
        }
        while flock(lock, LOCK_EX) != 0 { if errno != EINTR { throw posix("Katalog sperren") } }
        defer { _ = flock(lock, LOCK_UN) }
        var namedLock = stat()
        guard fstatat(root, lockName, &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_mode & S_IFMT == S_IFREG, namedLock.st_nlink == 1,
              namedLock.st_dev == lockStat.st_dev, namedLock.st_ino == lockStat.st_ino else {
            throw CatalogRepositoryError.concurrentModification
        }
        let previous = try read(root: root, name: "catalog.json", missingAllowed: true, captureBytes: false)
        return try operation(previous.reference)
    }

    static func discard(_ stage: StagedLibraryCatalog) {
        removeOwnedPayload(file: stage.payload.descriptor, root: stage.stage.descriptor, name: stage.name)
    }

    private static func ownsPayload(file: Int32, root: Int32, name: String) -> Bool {
        var owned = stat(), named = stat()
        return fstat(file, &owned) == 0 && fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0
            && owned.st_mode & S_IFMT == S_IFREG && named.st_mode & S_IFMT == S_IFREG
            && owned.st_nlink == 1 && named.st_nlink == 1
            && owned.st_dev == named.st_dev && owned.st_ino == named.st_ino
    }

    private static func removeOwnedPayload(file: Int32, root: Int32, name: String) {
        if ownsPayload(file: file, root: root, name: name) { _ = unlinkat(root, name, 0) }
    }

    private static func read(root: Int32, name: String, missingAllowed: Bool, captureBytes: Bool = true,
                             beforeOpen: () throws -> Void = {}) throws -> Contents {
        if let named = try entry(root: root, name: name) {
            guard named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
                  named.st_size >= 0, named.st_size <= maximumBytes else { throw CatalogRepositoryError.sizeLimit }
        }
        // Internal, synchronous seam for deterministic namespace-race tests.
        // It holds no native file and introduces no mutable process-wide hook.
        try beforeOpen()
        let ownership = try EditingDatabaseAccess.reserveNativeFile()
        let file = openat(root, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if file < 0 && errno == ENOENT && missingAllowed { return Contents(data: nil, reference: .absent) }
        guard file >= 0 else { throw posix("Katalogdatei öffnen") }
        ownership.own(file)
        defer { ownership.close() }
        // FileHandle only borrows: closing any fd for an active SQLite inode
        // releases this process's fcntl locks, even when validation rejects it.
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        var initial = stat()
        guard fstat(file, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_nlink == 1,
              initial.st_size >= 0, initial.st_size <= maximumBytes else { throw CatalogRepositoryError.sizeLimit }
        var bytes = Data(); var byteCount = 0; var hasher = SHA256()
        while true {
            let count = try autoreleasepool { () throws -> Int in
                guard let data = try handle.read(upToCount: min(65_536, maximumBytes - byteCount + 1)), !data.isEmpty else { return 0 }
                guard data.count <= maximumBytes - byteCount else { throw CatalogRepositoryError.sizeLimit }
                if captureBytes { bytes.append(data) }; byteCount += data.count
                hasher.update(data: data); return data.count
            }
            if count == 0 { break }
        }
        var final = stat(), named = stat()
        guard fstat(file, &final) == 0, fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileStamp(initial) == FileStamp(final), FileStamp(final) == FileStamp(named),
              named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1, byteCount == initial.st_size else {
            throw CatalogRepositoryError.concurrentModification
        }
        return Contents(data: captureBytes ? bytes : nil, reference: .present(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: Int64(byteCount)))
    }
    private static func entry(root: Int32, name: String) throws -> stat? {
        var value = stat()
        if fstatat(root, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }
        throw posix("Katalogdatei prüfen")
    }
    private static func sameDirectory(_ a: Int32, _ b: Int32) -> Bool {
        var one = stat(), two = stat()
        return fstat(a, &one) == 0 && fstat(b, &two) == 0 && one.st_dev == two.st_dev && one.st_ino == two.st_ino
    }
    private static func posix(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: operation + ": " + String(cString: strerror(errno))])
    }
}
