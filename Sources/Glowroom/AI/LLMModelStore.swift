import Darwin
import Foundation
import CryptoKit
import GlowroomCore

private struct LLMModelPointer: Codable {
    let schemaVersion: Int
    let modelID: String
    let revision: String
    let generation: String
}

/// One owner serializes publication/removal. Two file transfers overlap, while
/// hashing and filesystem access stay off MainActor. A filesystem lock also
/// protects a second running copy of Glowroom. Inference retains a read lease
/// until the actual native operation returns, even after observer cancellation.
actor LLMModelStore {
    static let shared = LLMModelStore(directory: CatalogManagedStoragePaths.applicationModelDirectory
        .appendingPathComponent("LLM/Qwen35-4B", isDirectory: true))
    typealias Downloader = @Sendable (URL, URL, Int64, @escaping @Sendable (Int64) -> Void) async throws -> Void
    typealias Capacity = @Sendable (URL) throws -> Int64
    private let directory: URL
    private let descriptor: LLMModelDescriptor
    private let downloader: Downloader
    private let capacity: Capacity
    private var changing = false
    private var readers = 0
    private var verified: (URL, [String])?

    init(directory: URL, descriptor: LLMModelDescriptor = .qwen35,
         downloader: @escaping Downloader = { source, destination, bytes, progress in
             try await LLMModelDownloader(destination: destination, maximumBytes: bytes, progress: progress).download(source)
         }, capacity: @escaping Capacity = {
             Int64(try $0.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0)
         }) {
        self.directory = directory; self.descriptor = descriptor
        self.downloader = downloader; self.capacity = capacity
    }

    func installation() throws -> LLMInstalledModel? {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        do {
            try validateDescriptor()
            try SemanticInstallationIO.requireDirectory(directory)
            // Only a lock owner may reap files left by a terminated download.
            if !changing, readers == 0, let lock = try? operationLock(exclusive: true) {
                defer { close(lock) }
                try cleanAbandonedStages()
                if let current = try pointedModel() { try cleanOrphanedGenerations(keeping: current.directory) }
            }
            guard let model = try pointedModel() else { return nil }
            let stamps = try fileStamps(model.directory)
            if verified?.0 != model.directory || verified?.1 != stamps {
                for file in descriptor.files {
                    try Task.checkCancellation()
                    let actual = try LLMModelIO.hashFile(model.directory.appendingPathComponent(file.path), maximumBytes: file.bytes)
                    guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw LLMModelError.invalidInstallation }
                }
                guard try fileStamps(model.directory) == stamps else { throw LLMModelError.invalidInstallation }
                verified = (model.directory, stamps)
            }
            return model
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw LLMModelError.invalidInstallation
        }
    }

    /// Logical payload bytes actually present, including incomplete downloads.
    /// Receipts, filesystem allocation rounding and URLSession temporary files
    /// are not part of the installed model size.
    func diskUsage() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        try SemanticInstallationIO.requireDirectory(directory)
        var roots = try ownedGenerations()
        if let pointed = try? pointedModel(), !roots.contains(pointed.directory) { roots.append(pointed.directory) }
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where isStageName(name) {
            let candidate = directory.appendingPathComponent(name, isDirectory: true)
            if (try? SemanticInstallationIO.requireDirectory(candidate)) != nil { roots.append(candidate) }
        }
        var total: Int64 = 0
        for root in roots {
            for file in descriptor.files {
                var info = stat()
                if lstat(root.appendingPathComponent(file.path).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                    let sum = total.addingReportingOverflow(max(0, info.st_size))
                    guard !sum.overflow else { throw LLMModelError.invalidInstallation }
                    total = sum.partialValue
                }
            }
        }
        return total
    }

    func withModel<T: Sendable>(_ operation: @Sendable (LLMInstalledModel) async throws -> T) async throws -> T {
        guard !changing else { throw LLMModelError.operationInProgress }
        guard let model = try installation() else { throw LLMModelError.modelNotInstalled }
        let lock = try operationLock(exclusive: false)
        readers += 1
        defer { readers -= 1; close(lock) }
        // A different process could replace the pointer between the initial
        // check and lock acquisition. Validate again under the retained lease.
        guard try installation() == model else { throw LLMModelError.invalidInstallation }
        try Task.checkCancellation()
        return try await operation(model)
    }

    @discardableResult
    func download(progress: @escaping @Sendable (LLMModelDownloadProgress) -> Void = { _ in }) async throws -> LLMInstalledModel {
        guard !changing else { throw LLMModelError.operationInProgress }
        guard readers == 0 else { throw LLMModelError.modelInUse }
        try Task.checkCancellation()
        try validateDescriptor()
        try prepareDirectory()
        let lock = try operationLock(exclusive: true)
        changing = true
        defer { changing = false; close(lock) }
        try cleanAbandonedStages()
        // URLSession may need a copy while moving its temporary download onto
        // the destination volume. Keep one additional payload plus headroom.
        let needed = descriptor.requiredDownloadFreeBytes
        guard try capacity(directory) >= needed else { throw LLMModelError.insufficientDiskSpace }
        let previous = try? pointedModel()
        let generation = UUID().uuidString.lowercased()
        let stage = directory.appendingPathComponent(".staging-" + generation, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? removePayload(in: stage) }
        let pointer = LLMModelPointer(schemaVersion: 1, modelID: descriptor.id, revision: descriptor.revision, generation: generation)
        try SemanticInstallationIO.json(pointer).write(to: stage.appendingPathComponent("receipt.json"), options: .atomic)
        let tracker = LLMModelProgressTracker(total: descriptor.downloadBytes, report: progress)
        let files = descriptor.files
        let downloader = downloader
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                func enqueue(_ index: Int) {
                    let file = files[index]
                    let source = descriptor.downloadURL(for: file)
                    group.addTask {
                        try Task.checkCancellation()
                        try await downloader(source, stage.appendingPathComponent(file.path), file.bytes) { count in
                            tracker.update(path: file.path, bytes: min(file.bytes, max(0, count)))
                        }
                    }
                }
                for _ in 0..<min(2, files.count) { enqueue(next); next += 1 }
                while try await group.next() != nil {
                    if next < files.count { enqueue(next); next += 1 }
                }
            }
            try Task.checkCancellation()
            progress(.init(text: "Modell wird geprüft …", fraction: nil, downloadedBytes: descriptor.downloadBytes, totalBytes: descriptor.downloadBytes))
            let stamps = try fileStamps(stage)
            for file in files {
                let actual = try LLMModelIO.hashFile(stage.appendingPathComponent(file.path), maximumBytes: file.bytes)
                guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw LLMModelError.invalidDownload }
            }
            guard try fileStamps(stage) == stamps else { throw LLMModelError.invalidDownload }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error is SemanticEmbeddingError || error as? LLMModelError == .invalidInstallation { throw LLMModelError.invalidDownload }
            throw error
        }
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent("generations/" + generation, isDirectory: true)
        try FileManager.default.moveItem(at: stage, to: destination)
        var published = false
        defer { if !published { try? removePayload(in: destination) } }
        try SemanticInstallationIO.replacePointer(try SemanticInstallationIO.json(pointer), in: directory)
        published = true
        verified = nil
        if let previous { try? removePayload(in: previous.directory) }
        try? cleanOrphanedGenerations(keeping: destination)
        progress(.init(text: "Modell heruntergeladen und geprüft.", fraction: 1, downloadedBytes: descriptor.downloadBytes, totalBytes: descriptor.downloadBytes))
        return LLMInstalledModel(directory: destination, descriptor: descriptor)
    }

    func remove() throws {
        guard !changing else { throw LLMModelError.operationInProgress }
        guard readers == 0 else { throw LLMModelError.modelInUse }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let lock = try operationLock(exclusive: true)
        defer { close(lock) }
        try cleanAbandonedStages()
        var owned = try ownedGenerations()
        if let previous = try? pointedModel(), !owned.contains(previous.directory) { owned.append(previous.directory) }
        // Deletion intentionally does not hash the payload: a damaged download
        // must remain removable. unlinkat never follows a model-file symlink;
        // unknown names and user files remain untouched. Once deletion begins,
        // finish this ordered mutation even if the observing task is cancelled.
        for root in owned { try removePayload(in: root) }
        try SemanticInstallationIO.removePointer(in: directory)
        verified = nil
    }

    private func validateDescriptor() throws {
        guard !descriptor.files.isEmpty, descriptor.files.count <= 64,
              Set(descriptor.files.map(\.path)).count == descriptor.files.count,
              descriptor.files.allSatisfy({ SemanticInstallationIO.validRelativePath($0.path) && !$0.path.contains("/") &&
                  $0.path != "receipt.json" && $0.bytes > 0 && $0.bytes <= 16_000_000_000 && SemanticInstallationIO.validHash($0.sha256) })
        else { throw LLMModelError.invalidInstallation }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(directory)
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(generations)
    }

    private func operationLock(exclusive: Bool) throws -> Int32 {
        try SemanticInstallationIO.requireDirectory(directory)
        let fd = open(directory.appendingPathComponent(".operation.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LLMModelError.invalidInstallation }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(fd); throw LLMModelError.invalidInstallation
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(fd); throw LLMModelError.modelInUse
        }
        return fd
    }

    private func pointedModel() throws -> LLMInstalledModel? {
        let pointerURL = directory.appendingPathComponent("current.json")
        var info = stat()
        guard lstat(pointerURL.path, &info) == 0 else {
            if errno == ENOENT { return nil }; throw LLMModelError.invalidInstallation
        }
        try SemanticInstallationIO.requireDirectory(directory)
        try SemanticInstallationIO.requireDirectory(directory.appendingPathComponent("generations"))
        let pointer = try SemanticInstallationIO.decode(LLMModelPointer.self, at: pointerURL, limit: 16_384)
        guard pointer.schemaVersion == 1, pointer.modelID == descriptor.id, pointer.revision == descriptor.revision,
              UUID(uuidString: pointer.generation) != nil else { throw LLMModelError.invalidInstallation }
        let root = directory.appendingPathComponent("generations/" + pointer.generation, isDirectory: true)
        try SemanticInstallationIO.requireDirectory(root)
        return LLMInstalledModel(directory: root, descriptor: descriptor)
    }

    private func fileStamps(_ root: URL) throws -> [String] {
        try SemanticInstallationIO.requireDirectory(root)
        let permitted = Set(descriptor.files.map(\.path)).union(["receipt.json", ".DS_Store"])
        // Native loaders can discover additional safetensors shards. Reject
        // unapproved entries rather than giving them access to extra weights.
        guard Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).isSubset(of: permitted) else {
            throw LLMModelError.invalidInstallation
        }
        return try descriptor.files.map { try SemanticInstallationIO.stamp(root.appendingPathComponent($0.path)) }
    }

    private func isStageName(_ name: String) -> Bool {
        name.hasPrefix(".staging-") && UUID(uuidString: String(name.dropFirst(9))) != nil
    }

    private func cleanAbandonedStages() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where isStageName(name) {
            let stage = directory.appendingPathComponent(name, isDirectory: true)
            guard (try? SemanticInstallationIO.requireDirectory(stage)) != nil else { continue }
            try removePayload(in: stage)
        }
    }

    private func ownedGenerations() throws -> [URL] {
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: generations.path) else { return [] }
        try SemanticInstallationIO.requireDirectory(generations)
        return try FileManager.default.contentsOfDirectory(atPath: generations.path).compactMap { name in
            guard UUID(uuidString: name) != nil else { return nil }
            let root = generations.appendingPathComponent(name, isDirectory: true)
            guard (try? SemanticInstallationIO.requireDirectory(root)) != nil,
                  let receipt = try? SemanticInstallationIO.decode(LLMModelPointer.self, at: root.appendingPathComponent("receipt.json"), limit: 16_384),
                  receipt.schemaVersion == 1, receipt.modelID == descriptor.id, receipt.revision == descriptor.revision,
                  receipt.generation == name else { return nil }
            return root
        }
    }

    private func cleanOrphanedGenerations(keeping current: URL) throws {
        for root in try ownedGenerations() where root != current { try removePayload(in: root) }
    }

    private func removePayload(in root: URL) throws {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return }; throw LLMModelError.invalidInstallation
        }
        defer { close(fd) }
        for name in descriptor.files.map(\.path) + ["receipt.json"] {
            guard unlinkat(fd, name, 0) == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        // Preserve any unrelated files, including Finder metadata.
        _ = rmdir(root.path)
    }
}

private final class LLMModelProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int64] = [:]
    private var lastPublished: ContinuousClock.Instant?
    private let total: Int64
    private let report: @Sendable (LLMModelDownloadProgress) -> Void
    init(total: Int64, report: @escaping @Sendable (LLMModelDownloadProgress) -> Void) { self.total = total; self.report = report }
    func update(path: String, bytes: Int64) {
        lock.lock()
        values[path] = max(values[path] ?? 0, bytes)
        let downloaded = values.values.reduce(0, +)
        let now = ContinuousClock.now
        if let lastPublished, downloaded < total, lastPublished.duration(to: now) < .milliseconds(100) {
            lock.unlock(); return
        }
        lastPublished = now
        // Multi-gigabyte transfers must not enqueue a main-actor task for every
        // network chunk. Keep at most ten updates/s, plus first/final progress.
        // Deliver while ordered so overlapping transfers cannot regress progress.
        report(.init(text: "Modell wird heruntergeladen …", fraction: Double(downloaded) / Double(total), downloadedBytes: downloaded, totalBytes: total))
        lock.unlock()
    }
}

/// The older semantic-model helper deliberately caps files at 1 GiB. LLM
/// weights need their own manifest-bounded streaming check, without weakening
/// the limits of existing model installers.
enum LLMModelIO {
    static func hashFile(_ source: URL, maximumBytes: Int64) throws -> (bytes: Int64, sha256: String) {
        let before = try SemanticInstallationIO.stamp(source)
        let fd = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LLMModelError.invalidInstallation }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximumBytes else { throw LLMModelError.invalidInstallation }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            let consumed = try autoreleasepool { () throws -> Int in
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return 0 }
                count += Int64(data.count)
                guard count <= info.st_size else { throw LLMModelError.invalidInstallation }
                hash.update(data: data)
                return data.count
            }
            if consumed == 0 { break }
        }
        guard count == info.st_size, try SemanticInstallationIO.stamp(source) == before else {
            throw LLMModelError.invalidInstallation
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
