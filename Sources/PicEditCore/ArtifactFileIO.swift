import CryptoKit
import Darwin
import Foundation
import CoreGraphics

internal final class ArtifactNativeFD: @unchecked Sendable {
    let value: Int32
    private let editingOwnership: EditingNativeFileReservation?
    init(_ value: Int32, editingOwnership: EditingNativeFileReservation? = nil) {
        self.value = value; self.editingOwnership = editingOwnership
    }
    deinit {
        // Closing ANY FD of an active SQLite main inode drops that process's
        // fcntl locks. Foreign inputs may alias main even when validation fails.
        if let editingOwnership { editingOwnership.close() } else { close(value) }
    }
}
internal struct ArtifactNativeStamp: Equatable, Codable, Sendable {
    let device: Int64; let inode: UInt64; let bytes: Int64
    let mode: mode_t; let links: UInt16
    let modifiedSeconds: Int64; let modifiedNanos: Int64
    let changedSeconds: Int64; let changedNanos: Int64
    let birthSeconds: Int64; let birthNanos: Int64; let generation: UInt32
    init(_ v: stat) {
        device = Int64(v.st_dev); inode = UInt64(v.st_ino); bytes = v.st_size
        mode = v.st_mode; links = UInt16(v.st_nlink)
        modifiedSeconds = Int64(v.st_mtimespec.tv_sec); modifiedNanos = Int64(v.st_mtimespec.tv_nsec)
        changedSeconds = Int64(v.st_ctimespec.tv_sec); changedNanos = Int64(v.st_ctimespec.tv_nsec)
        birthSeconds = Int64(v.st_birthtimespec.tv_sec); birthNanos = Int64(v.st_birthtimespec.tv_nsec); generation = v.st_gen
    }
    var isRegular: Bool { mode & S_IFMT == S_IFREG && links == 1 }
    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode }
    func sameDirectoryIdentity(_ other: Self) -> Bool {
        isDirectory && other.isDirectory && sameObject(other) && birthSeconds == other.birthSeconds && birthNanos == other.birthNanos && generation == other.generation
    }
}
internal final class ArtifactDirectory: @unchecked Sendable {
    let fd: ArtifactNativeFD
    let parent: ArtifactDirectory?
    let leaf: String?
    let url: URL
    private let identity: ArtifactNativeStamp
    init(fd: Int32, url: URL, parent: ArtifactDirectory? = nil, leaf: String? = nil) throws {
        self.fd = ArtifactNativeFD(fd); self.url = url; self.parent = parent; self.leaf = leaf
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ArtifactFileIO.failure("Verzeichnis prüfen") }
        identity = ArtifactNativeStamp(value)
        guard identity.isDirectory else { throw ArtifactContractError.invalidCapability }
    }
    func validate() throws {
        var value = stat()
        guard fstat(fd.value, &value) == 0, identity.sameObject(ArtifactNativeStamp(value)) else { throw ArtifactContractError.invalidCapability }
        if let parent, let leaf {
            try parent.validate()
            guard fstatat(parent.fd.value, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  ArtifactNativeStamp(value).isDirectory, identity.sameObject(ArtifactNativeStamp(value)) else { throw ArtifactContractError.invalidCapability }
        } else {
            let current = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard current >= 0 else { throw ArtifactContractError.invalidCapability }
            defer { close(current) }
            guard fstat(current, &value) == 0, identity.sameObject(ArtifactNativeStamp(value)) else { throw ArtifactContractError.invalidCapability }
        }
    }
}
internal final class ArtifactPinnedFile: @unchecked Sendable {
    let fd: ArtifactNativeFD
    let directory: ArtifactDirectory
    let leaf: String
    let stamp: ArtifactNativeStamp
    init(fd: ArtifactNativeFD, directory: ArtifactDirectory, leaf: String) throws {
        self.fd = fd; self.directory = directory; self.leaf = leaf
        var value = stat(); guard fstat(fd.value, &value) == 0 else { throw ArtifactFileIO.failure("Datei prüfen") }
        stamp = ArtifactNativeStamp(value)
        guard stamp.isRegular, stamp.bytes >= 0 else { throw ArtifactContractError.corruptArtifact }
        try validate()
    }
    func validate() throws {
        try directory.validate()
        var value = stat()
        guard fstat(fd.value, &value) == 0, ArtifactNativeStamp(value) == stamp,
              fstatat(directory.fd.value, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0,
              ArtifactNativeStamp(value) == stamp else { throw ArtifactContractError.corruptArtifact }
    }
    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= stamp.bytes, count > 0, count <= 65_536 else { throw ArtifactContractError.invalidCapability }
        try validate()
        let n = min(count, Int(stamp.bytes - offset))
        var output = Data(count: n)
        let done = try output.withUnsafeMutableBytes { buffer -> Int in
            guard n > 0 else { return 0 }
            return try ArtifactFileIO.preadAll(fd.value, into: buffer.baseAddress!, count: n, offset: offset)
        }
        guard done == n else { throw ArtifactContractError.corruptArtifact }
        try validate(); return output
    }
    func digest() throws -> ArtifactDigest {
        var hash = SHA256(); var offset: Int64 = 0
        while offset < stamp.bytes {
            try Task.checkCancellation()
            let count = try autoreleasepool { () throws -> Int in
                let data = try read(offset: offset, count: 65_536); hash.update(data: data); return data.count
            }
            guard count > 0 else { throw ArtifactContractError.corruptArtifact }; offset += Int64(count)
        }
        try validate(); return try ArtifactFileIO.digest(hash.finalize())
    }
    func handle(ownership: ArtifactLease?, expected: ArtifactFileDescriptor? = nil) throws -> ArtifactFileReadHandle {
        let actual = try digest()
        if let expected { guard expected.bytes == stamp.bytes, expected.sha256 == actual else { throw ArtifactContractError.corruptArtifact } }
        return ArtifactFileReadHandle(bytes: stamp.bytes, sha256: actual, ownership: ownership) { [self] offset, count in
            try read(offset: offset, count: count)
        }
    }
    /// Only the Store's private successful-validation cache supplies this
    /// evidence. A fresh open must match the COMPLETE original native stamp;
    /// an expected digest from JSON alone never authorizes skipping hashing.
    /// The returned reader still validates its pinned inode before/after reads.
    func handle(ownership: ArtifactLease?, validatedStamp: ArtifactNativeStamp,
                descriptor: ArtifactFileDescriptor) throws -> ArtifactFileReadHandle {
        guard stamp == validatedStamp, descriptor.bytes == stamp.bytes else { throw ArtifactContractError.corruptArtifact }
        try validate()
        return ArtifactFileReadHandle(bytes: stamp.bytes, sha256: descriptor.sha256, ownership: ownership) { [self] offset, count in
            try read(offset: offset, count: count)
        }
    }
}

internal enum ArtifactFileIO {
    static let maximumPayload: Int64 = 536_870_912
    static func failure(_ action: String) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: action]) }
    static func digest(_ hash: SHA256.Digest) throws -> ArtifactDigest { try .init(sha256: hash.map { String(format: "%02x", $0) }.joined()) }
    static func digest(_ bytes: Data) throws -> ArtifactDigest { try digest(SHA256.hash(data: bytes)) }
    static func root(_ url: URL, create: Bool) throws -> ArtifactDirectory {
        guard url.isFileURL else { throw ArtifactContractError.invalidValue("Lokales Datenverzeichnis erforderlich") }
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw failure("Datenverzeichnis öffnen") }
        return try ArtifactDirectory(fd: fd, url: url)
    }
    static func child(_ parent: ArtifactDirectory, _ name: String, create: Bool = false) throws -> ArtifactDirectory {
        try validLeaf(name); try parent.validate()
        if create && mkdirat(parent.fd.value, name, 0o700) != 0 && errno != EEXIST { throw failure("Artefaktverzeichnis erstellen") }
        let fd = openat(parent.fd.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw failure("Artefaktverzeichnis öffnen") }
        return try ArtifactDirectory(fd: fd, url: parent.url.appendingPathComponent(name, isDirectory: true), parent: parent, leaf: name)
    }
    static func validLeaf(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else { throw ArtifactContractError.invalidCapability }
    }
    static func names(_ directory: ArtifactDirectory, maximum: Int = 16_384) throws -> [String] {
        try directory.validate()
        let copied = openat(directory.fd.value, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard copied >= 0 else { throw failure("Verzeichnis lesen") }
        guard let stream = fdopendir(copied) else { close(copied); throw failure("Verzeichnis lesen") }
        defer { closedir(stream) }
        var result: [String] = []; errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { result.append(name); guard result.count <= maximum else { throw ArtifactContractError.limitExceeded } }
            errno = 0
        }
        guard errno == 0 else { throw failure("Verzeichnis vollständig lesen") }
        try directory.validate(); return result.sorted()
    }
    static func create(_ directory: ArtifactDirectory, _ leaf: String) throws -> ArtifactNativeFD {
        try validLeaf(leaf); try directory.validate()
        let fd = openat(directory.fd.value, leaf, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("Eigene Datei exklusiv erstellen") }; return ArtifactNativeFD(fd)
    }
    static func openFile(_ directory: ArtifactDirectory, _ leaf: String, limit: Int64 = maximumPayload) throws -> ArtifactPinnedFile {
        try validLeaf(leaf); try directory.validate()
        let reservation = try EditingDatabaseAccess.reserveNativeFile()
        let fd = openat(directory.fd.value, leaf, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { if errno == ENOENT { throw ArtifactContractError.missingArtifact }; throw failure("Artefaktdatei öffnen") }
        let ownership = reservation.own(fd)
        let file = try ArtifactPinnedFile(fd: ArtifactNativeFD(fd, editingOwnership: ownership), directory: directory, leaf: leaf)
        guard file.stamp.bytes <= limit else { throw ArtifactContractError.limitExceeded }; return file
    }
    static func readSmall(_ directory: ArtifactDirectory, _ leaf: String, limit: Int = 65_536) throws -> Data {
        let file = try openFile(directory, leaf, limit: Int64(limit))
        var result = Data(); var offset: Int64 = 0
        while offset < file.stamp.bytes { let data = try file.read(offset: offset, count: min(limit, 65_536)); result.append(data); offset += Int64(data.count) }
        try file.validate(); return result
    }
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let amount = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), min(65_536, bytes.count - written))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw failure("Artefakt schreiben") }; written += amount
            }
        }
    }
    static func preadAll(_ fd: Int32, into pointer: UnsafeMutableRawPointer, count: Int, offset: Int64) throws -> Int {
        var read = 0
        while read < count {
            let amount = pread(fd, pointer.advanced(by: read), min(65_536, count - read), offset + Int64(read))
            if amount < 0 && errno == EINTR { continue }
            guard amount >= 0 else { throw failure("Artefakt lesen") }; if amount == 0 { break }; read += amount
        }
        return read
    }
    @discardableResult
    static func writeSmall(_ directory: ArtifactDirectory, _ leaf: String, bytes: Data, limit: Int = 65_536,
                           ownership: ArtifactPrivateStageOwnership? = nil) throws -> ArtifactPinnedFile {
        guard bytes.count <= limit else { throw ArtifactContractError.limitExceeded }
        let file = try create(directory, leaf)
        do {
            try writeAll(file.value, bytes)
            guard fsync(file.value) == 0, fsync(directory.fd.value) == 0 else { throw failure("Artefakt synchronisieren") }
            let pinned = try ArtifactPinnedFile(fd: file, directory: directory, leaf: leaf)
            try ownership?.recordFile(pinned); return pinned
        }
        catch { removeOwnedFile(directory, leaf, fd: file); throw error }
    }
    static func removeOwnedFile(_ directory: ArtifactDirectory, _ name: String, fd: ArtifactNativeFD) {
        var opened = stat(); var named = stat()
        guard (try? directory.validate()) != nil, fstat(fd.value, &opened) == 0,
              fstatat(directory.fd.value, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              ArtifactNativeStamp(opened).isRegular, ArtifactNativeStamp(opened).sameObject(ArtifactNativeStamp(named)) else { return }
        _ = unlinkat(directory.fd.value, name, 0)
    }
    static func exclusiveMove(_ source: ArtifactDirectory, name: String, to destination: ArtifactDirectory, newName: String) throws {
        try source.validate(); try destination.validate(); try validLeaf(name); try validLeaf(newName)
        guard renameatx_np(source.fd.value, name, destination.fd.value, newName, UInt32(RENAME_EXCL)) == 0 else { throw failure("Artefakt exklusiv veröffentlichen") }
        // Rename is the commit point; post-publication directory sync failure
        // cannot report that the previous namespace still exists.
        _ = fsync(source.fd.value); _ = fsync(destination.fd.value)
    }
    static func copy(_ source: ArtifactFileReadHandle, into directory: ArtifactDirectory, leaf: String,
                     ownership: ArtifactPrivateStageOwnership? = nil) throws -> ArtifactFileDescriptor {
        guard source.bytes > 0, source.bytes <= maximumPayload else { throw ArtifactContractError.limitExceeded }
        let target = try create(directory, leaf); var hash = SHA256(); var offset: Int64 = 0
        do {
            while offset < source.bytes {
                try Task.checkCancellation()
                let count = try autoreleasepool { () throws -> Int in
                    let data = try source.read(offset: offset, maximumCount: 65_536)
                    guard !data.isEmpty else { throw ArtifactContractError.corruptArtifact }
                    try writeAll(target.value, data); hash.update(data: data); return data.count
                }; offset += Int64(count)
            }
            guard try digest(hash.finalize()) == source.sha256, fsync(target.value) == 0 else { throw ArtifactContractError.corruptArtifact }
            let pinned = try ArtifactPinnedFile(fd: target, directory: directory, leaf: leaf)
            guard pinned.stamp.bytes == source.bytes else { throw ArtifactContractError.corruptArtifact }
            try ownership?.recordFile(pinned)
            return try .init(sha256: source.sha256, bytes: source.bytes)
        } catch { removeOwnedFile(directory, leaf, fd: target); throw error }
    }
}

internal final class ArtifactNativeWriter: @unchecked Sendable {
    let fd: ArtifactNativeFD
    private let lock = NSLock()
    private var count: Int64 = 0
    private var failure: Error?
    init(_ fd: ArtifactNativeFD) { self.fd = fd }
    func put(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, count >= 0, Int64(count) <= ArtifactFileIO.maximumPayload - self.count else {
            failure = ArtifactContractError.limitExceeded; return 0
        }
        var offset = 0
        while offset < count {
            let amount = Darwin.write(fd.value, bytes.advanced(by: offset), min(65_536, count - offset))
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { failure = ArtifactFileIO.failure("PNG schreiben"); return 0 }; offset += amount
        }
        self.count += Int64(count); return count
    }
    func check() throws { lock.lock(); defer { lock.unlock() }; if let failure { throw failure } }
    func consumer() throws -> CGDataConsumer {
        let info = Unmanaged.passRetained(self).toOpaque()
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            return Unmanaged<ArtifactNativeWriter>.fromOpaque(info).takeUnretainedValue().put(bytes, count: count)
        }, releaseConsumer: { info in if let info { Unmanaged<ArtifactNativeWriter>.fromOpaque(info).release() } })
        guard let consumer = CGDataConsumer(info: info, cbks: &callbacks) else { Unmanaged<ArtifactNativeWriter>.fromOpaque(info).release(); throw ArtifactContractError.unsupportedFormat }
        return consumer
    }
}
internal extension ArtifactPinnedFile {
    func provider() throws -> CGDataProvider {
        let info = Unmanaged.passRetained(self).toOpaque()
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, target, offset, count in
                guard let info else { return 0 }
                let file = Unmanaged<ArtifactPinnedFile>.fromOpaque(info).takeUnretainedValue()
                guard offset >= 0, offset <= file.stamp.bytes else { return 0 }
                let amount = min(count, Int(file.stamp.bytes - offset)); var read = 0
                do {
                    while read < amount {
                        let bytes = try file.read(offset: offset + Int64(read), count: min(65_536, amount - read))
                        guard !bytes.isEmpty else { break }
                        bytes.withUnsafeBytes { source in target.advanced(by: read).copyMemory(from: source.baseAddress!, byteCount: source.count) }
                        read += bytes.count
                    }; return read
                } catch { return 0 }
            }, releaseInfo: { info in if let info { Unmanaged<ArtifactPinnedFile>.fromOpaque(info).release() } })
        guard let provider = CGDataProvider(directInfo: info, size: stamp.bytes, callbacks: &callbacks) else {
            Unmanaged<ArtifactPinnedFile>.fromOpaque(info).release(); throw ArtifactContractError.corruptArtifact
        }; return provider
    }
}

/// Only this process's exclusively created private package stage can mint this
/// owner. Stamps are registered while the original newly-created FD is open;
/// no payload FD per package file remains open afterwards.
internal final class ArtifactPrivateStageOwnership: @unchecked Sendable {
    private let stage: ArtifactDirectory
    private let lock = NSLock()
    private var files: [[String]: ArtifactNativeStamp] = [:]
    private var directories: [[String]: ArtifactNativeStamp] = [:]
    private var published = false
    private let onCleanup: @Sendable (Bool) -> Void
    init(stage: ArtifactDirectory, onCleanup: @escaping @Sendable (Bool) -> Void = { _ in }) throws {
        self.stage = stage; self.onCleanup = onCleanup
        directories[[]] = try ArtifactFileIO.nativeStamp(stage.fd.value)
        try stage.validate()
    }
    private func relative(_ directory: ArtifactDirectory) throws -> [String] {
        var current = directory; var reversed: [String] = []
        for _ in 0..<8 {
            if current === stage { return Array(reversed.reversed()) }
            guard let parent = current.parent, let leaf = current.leaf else { throw ArtifactContractError.invalidCapability }
            try ArtifactFileIO.validLeaf(leaf); reversed.append(leaf); current = parent
        }
        throw ArtifactContractError.invalidCapability
    }
    func recordDirectory(_ directory: ArtifactDirectory) throws {
        let path = try relative(directory); let stamp = try ArtifactFileIO.nativeStamp(directory.fd.value)
        try directory.validate()
        try lock.withLock {
            guard !published, directories.count < 4_098, directories[path] == nil else { throw ArtifactContractError.invalidCapability }
            directories[path] = stamp
        }
    }
    func recordFile(_ file: ArtifactPinnedFile) throws {
        let parent = try relative(file.directory); let path = parent + [file.leaf]
        try file.validate()
        try lock.withLock {
            guard !published, files.count < 16_384, directories[parent] != nil, files[path] == nil else { throw ArtifactContractError.invalidCapability }
            files[path] = file.stamp
        }
    }
    func inventory() throws -> ArtifactOwnershipInventory {
        try lock.withLock {
            guard !published else { throw ArtifactContractError.invalidCapability }
            return ArtifactOwnershipInventory(files: files, directories: directories)
        }
    }
    func disarmAfterPublication() { lock.withLock { published = true } }
    deinit {
        let job: ArtifactPrivateStageCleanupJob? = lock.withLock {
            published ? nil : ArtifactPrivateStageCleanupJob(stage: stage, files: files, directories: directories, onCleanup: onCleanup)
        }
        if let job { ArtifactPrivateStageCleanupQueue.shared.submit(job) }
    }
}
private struct ArtifactPrivateStageCleanupJob: Sendable {
    let stage: ArtifactDirectory
    let files: [[String]: ArtifactNativeStamp]
    let directories: [[String]: ArtifactNativeStamp]
    let onCleanup: @Sendable (Bool) -> Void
    func directory(_ path: [String]) throws -> ArtifactDirectory {
        var result = stage
        for component in path { result = try ArtifactFileIO.child(result, component) }
        guard let original = directories[path], try ArtifactFileIO.nativeStamp(result.fd.value).sameDirectoryIdentity(original) else { throw ArtifactContractError.invalidCapability }
        return result
    }
    func expectedChildren() -> [[String]: Set<String>] {
        var result: [[String]: Set<String>] = [:]
        for path in directories.keys { result[path] = [] }
        for path in files.keys { if let name = path.last { result[Array(path.dropLast()), default: []].insert(name) } }
        for path in directories.keys { if let name = path.last { result[Array(path.dropLast()), default: []].insert(name) } }
        return result
    }
    func preflight() throws { try preflight(expectedChildren()) }
    private func preflight(_ expected: [[String]: Set<String>]) throws {
        try stage.validate()
        // One linear child inventory, then O(1) expected-set lookup per native
        // directory. No repeated whole-tree union/filter for large packages.
        for path in directories.keys.sorted(by: { $0.count < $1.count }) {
            let current = try directory(path)
            guard Set(try ArtifactFileIO.names(current)) == expected[path] else { throw ArtifactContractError.invalidCapability }
        }
        for (path, stamp) in files {
            let current = try directory(Array(path.dropLast()))
            guard let leaf = path.last else { throw ArtifactContractError.invalidCapability }
            let opened = try ArtifactFileIO.openFile(current, leaf)
            guard opened.stamp == stamp else { throw ArtifactContractError.invalidCapability }
        }
    }
    func run() throws {
        var expected = expectedChildren()
        try preflight(expected)
        for path in files.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let parentPath = Array(path.dropLast()); let current = try directory(parentPath)
            guard Set(try ArtifactFileIO.names(current)) == expected[parentPath],
                  let leaf = path.last, let original = files[path] else { throw ArtifactContractError.invalidCapability }
            let opened = try ArtifactFileIO.openFile(current, leaf)
            guard opened.stamp == original else { throw ArtifactContractError.invalidCapability }
            try opened.validate() // Last named-FD equality check immediately before unlink.
            guard unlinkat(current.fd.value, leaf, 0) == 0 else { throw ArtifactFileIO.failure("Eigenen Paketstage bereinigen") }
            expected[parentPath]?.remove(leaf)
        }
        for path in directories.keys.sorted(by: { $0.count > $1.count }) {
            let current = try directory(path)
            guard expected[path]?.isEmpty == true, try ArtifactFileIO.names(current).isEmpty,
                  let parent = current.parent, let leaf = current.leaf else { throw ArtifactContractError.invalidCapability }
            try current.validate()
            guard unlinkat(parent.fd.value, leaf, AT_REMOVEDIR) == 0 else { throw ArtifactFileIO.failure("Leeres eigenes Stageverzeichnis bereinigen") }
            expected[Array(path.dropLast())]?.remove(leaf)
        }
    }
}
/// Serial administrative teardown only; no decoder/raster worker pool. A
/// synchronous registry bounds the total running+queued tasks to sixteen.
internal struct ArtifactStageCleanupDiagnostics: Equatable, Sendable {
    let pendingJobs: Int; let completedJobs: Int; let retainedJobs: Int; let rejectedJobs: Int
}
private final class ArtifactPrivateStageCleanupQueue: @unchecked Sendable {
    static let shared = ArtifactPrivateStageCleanupQueue()
    private let lock = NSLock()
    private let worker = ArtifactPrivateStageCleanup()
    private var pending = 0, completed = 0, retained = 0, rejected = 0
    func submit(_ job: ArtifactPrivateStageCleanupJob) {
        let accepted = lock.withLock { () -> Bool in
            guard pending < 16 else { rejected += 1; retained += 1; return false }
            pending += 1; return true
        }
        guard accepted else { job.onCleanup(false); return } // Preserve the complete stage; diagnostics count the refusal.
        Task { [self] in
            let cleaned = await worker.run(job)
            lock.withLock { pending -= 1; if cleaned { completed += 1 } else { retained += 1 } }
            job.onCleanup(cleaned)
        }
    }
    func diagnostics() -> ArtifactStageCleanupDiagnostics {
        lock.withLock { .init(pendingJobs: pending, completedJobs: completed, retainedJobs: retained, rejectedJobs: rejected) }
    }
}
private actor ArtifactPrivateStageCleanup {
    func run(_ job: ArtifactPrivateStageCleanupJob) -> Bool {
        do { try job.run(); return true } catch { return false }
    }
}
internal extension ArtifactPrivateStageOwnership {
    static func cleanupDiagnostics() -> ArtifactStageCleanupDiagnostics { ArtifactPrivateStageCleanupQueue.shared.diagnostics() }
}
internal extension ArtifactFileIO {
    static func nativeStamp(_ fd: Int32) throws -> ArtifactNativeStamp {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw failure("Native Dateibesitzidentität prüfen") }; return ArtifactNativeStamp(value)
    }
}

/// Persisted automatic-backup receipts contain ORIGINAL creation identities,
/// never a freshly blessed inventory of files found during rotation.
internal struct ArtifactOwnershipInventory: Codable, Sendable {
    struct Entry: Codable, Sendable { let path: [String]; let stamp: ArtifactNativeStamp }
    let files: [Entry]
    let directories: [Entry]
    init(files: [[String]: ArtifactNativeStamp], directories: [[String]: ArtifactNativeStamp]) {
        self.files = files.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { Entry(path: $0, stamp: files[$0]!) }
        self.directories = directories.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { Entry(path: $0, stamp: directories[$0]!) }
    }
    func validate() throws {
        guard files.count <= 16_384, directories.count <= 4_098,
              Set(files.map(\.path)).count == files.count, Set(directories.map(\.path)).count == directories.count,
              directories.contains(where: { $0.path.isEmpty }) else { throw ArtifactContractError.invalidCapability }
        for entry in files + directories {
            guard entry.path.count <= 3 else { throw ArtifactContractError.invalidCapability }
            for component in entry.path { try ArtifactFileIO.validLeaf(component) }
        }
        guard files.allSatisfy({ !$0.path.isEmpty && $0.stamp.isRegular && $0.stamp.bytes >= 0 && $0.stamp.bytes <= ArtifactFileIO.maximumPayload }),
              directories.allSatisfy({ $0.stamp.isDirectory }) else { throw ArtifactContractError.invalidCapability }
    }
    func preflight(stage: ArtifactDirectory) throws {
        try validate()
        try job(stage).preflight()
    }
    func removeOwnedTree(stage: ArtifactDirectory) throws {
        try validate()
        try job(stage).run()
    }
    private func job(_ stage: ArtifactDirectory) -> ArtifactPrivateStageCleanupJob {
        ArtifactPrivateStageCleanupJob(stage: stage, files: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.stamp) }),
            directories: Dictionary(uniqueKeysWithValues: directories.map { ($0.path, $0.stamp) }), onCleanup: { _ in })
    }
}
internal extension ArtifactFileIO {
    /// Only short synchronous metadata/publication work belongs under this lock.
    /// In particular neither codec admission nor full package validation awaits.
    static func withAutomaticBackupLock<T>(_ directory: ArtifactDirectory, _ operation: () throws -> T) throws -> T {
        try directory.validate()
        let name = ".automatic-backup.lock"
        let reservation = try EditingDatabaseAccess.reserveNativeFile()
        let fd = openat(directory.fd.value, name, O_RDWR | O_CREAT | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("Automatische Sicherungen sperren") }
        let owned = ArtifactNativeFD(fd, editingOwnership: reservation.own(fd))
        let file = try ArtifactPinnedFile(fd: owned, directory: directory, leaf: name)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw failure("Automatische Sicherungen sind beschäftigt") }
        defer { _ = flock(fd, LOCK_UN) }
        try file.validate()
        return try operation()
    }
}
