import Foundation
import CoreML
import CryptoKit
import Darwin
import GlowroomCore

struct SemanticManifestFile: Codable, Hashable, Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
}

struct SemanticPackageManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let descriptor: SemanticModelDescriptor
    let files: [SemanticManifestFile]

    static func approved(mainBundle: Bundle = .main) throws -> Self {
        let resources: Bundle
        if mainBundle.bundleURL.pathExtension.lowercased() == "app" {
            // Classic SwiftPM's generated accessor only checks the .app root
            // and an absolute development path. Packaged apps must use their
            // own signed Resources bundle, including after the build is removed.
            guard let root = mainBundle.resourceURL?.appendingPathComponent("Glowroom_Glowroom.bundle"),
                  let packaged = Bundle(url: root) else { throw SemanticEmbeddingError.invalidInstallation }
            resources = packaged
        } else { resources = .module }
        guard let url = resources.url(forResource: "SemanticApprovedPackage", withExtension: "json") else {
            throw SemanticEmbeddingError.invalidInstallation
        }
        return try SemanticInstallationIO.decode(Self.self, at: url, limit: 128 * 1_024)
    }

    func validate() throws {
        try descriptor.validate()
        guard schemaVersion == 1, !files.isEmpty, files.count <= 512,
              Set(files.map(\.path)).count == files.count else { throw SemanticEmbeddingError.invalidInstallation }
        var total: Int64 = 0
        for file in files {
            guard SemanticInstallationIO.validRelativePath(file.path), file.bytes > 0,
                  file.bytes <= SemanticModelInstaller.maximumInstalledBytes,
                  SemanticInstallationIO.validHash(file.sha256) else { throw SemanticEmbeddingError.invalidInstallation }
            let next = total.addingReportingOverflow(file.bytes)
            guard !next.overflow, next.partialValue <= SemanticModelInstaller.maximumInstalledBytes else {
                throw SemanticEmbeddingError.invalidInstallation
            }
            total = next.partialValue
        }
    }
}

private struct SemanticInstallationReceipt: Codable, Sendable {
    let schemaVersion: Int
    let sourceManifestSHA256: String
    let descriptor: SemanticModelDescriptor
    let files: [SemanticManifestFile]
}

private struct SemanticInstallationPointer: Codable, Sendable {
    let schemaVersion: Int
    let generation: String
    let receiptSHA256: String
    let installedBytes: Int64
}

/// Imports only the package pinned in the application, never an arbitrary
/// user-provided self-signed manifest. Compilation is serial because its
/// transient memory/files cannot safely overlap another installation.
actor SemanticModelInstaller {
    static let maximumInstalledBytes: Int64 = 1_073_741_824
    static let stagingBytesRequired: Int64 = 3_221_225_472
    typealias Compiler = @Sendable (URL) throws -> URL
    typealias Capacity = @Sendable (URL) throws -> Int64

    private let directory: URL
    private let approved: SemanticPackageManifest?
    private let compiler: Compiler
    private let capacity: Capacity

    init(directory: URL) {
        self.directory = directory
        approved = nil
        compiler = { try MLModel.compileModel(at: $0) }
        capacity = { try Self.availableCapacity($0) }
    }

    /// Dependency injection is internal and exists only for small synthetic
    /// installation tests. The production initializer always uses the app's pinned resource manifest.
    init(directory: URL, approved: SemanticPackageManifest,
         compiler: @escaping Compiler, capacity: @escaping Capacity) {
        self.directory = directory
        self.approved = approved
        self.compiler = compiler
        self.capacity = capacity
    }

    private func approvedManifest() throws -> SemanticPackageManifest {
        let value = try approved ?? SemanticPackageManifest.approved()
        try value.validate()
        return value
    }

    func inspect(source: URL) async throws -> SemanticModelImportReview {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let manifest = try approvedManifest()
        let sourceBytes = try Self.verifyPackage(source, approved: manifest)
        let licenses = try manifest.files.filter { $0.path.hasPrefix("licenses/") }.sorted { $0.path < $1.path }.map { file in
            let url = source.appendingPathComponent(file.path)
            let data = try SemanticInstallationIO.read(url, limit: 128 * 1_024)
            guard let text = String(data: data, encoding: .utf8) else { throw SemanticEmbeddingError.invalidInstallation }
            return SemanticModelLicense(title: url.lastPathComponent, text: text)
        }
        return SemanticModelImportReview(id: UUID(), sourceURL: source, descriptor: manifest.descriptor,
                                         sourceBytes: sourceBytes, maximumInstalledBytes: Self.maximumInstalledBytes,
                                         stagingBytesRequired: Self.stagingBytesRequired, licenses: licenses)
    }

    func install(_ review: SemanticModelImportReview,
                 progress: @escaping @Sendable (SemanticInstallProgress) -> Void = { _ in }) async throws -> SemanticInstalledModel {
        let manifest = try approvedManifest()
        guard review.descriptor == manifest.descriptor else { throw SemanticEmbeddingError.unsupportedVersion }
        try Task.checkCancellation()
        let scoped = review.sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { review.sourceURL.stopAccessingSecurityScopedResource() } }
        progress(.init(phase: .verifying, completedBytes: 0, totalBytes: review.sourceBytes))
        // Repeat full verification after the review. A changed source cannot turn
        // an approved review into permission to import other bytes.
        guard try Self.verifyPackage(review.sourceURL, approved: manifest) == review.sourceBytes else {
            throw SemanticEmbeddingError.invalidInstallation
        }
        let previous = try? currentModel()
        try Task.checkCancellation()
        try prepareRoot()
        guard try capacity(directory) >= Self.stagingBytesRequired,
              try capacity(FileManager.default.temporaryDirectory) >= Self.stagingBytesRequired else {
            throw SemanticEmbeddingError.insufficientDiskSpace
        }
        let generation = UUID().uuidString.lowercased()
        let stage = directory.appendingPathComponent(".staging-" + generation, isDirectory: true)
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        let destination = generations.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let packages = stage.appendingPathComponent("packages", isDirectory: true)
        let runtime = stage.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        var completed: Int64 = 0
        for file in manifest.files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let targetRoot = file.path.hasPrefix("models/") ? packages : runtime
            let target = targetRoot.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SemanticInstallationIO.copyVerified(review.sourceURL.appendingPathComponent(file.path), to: target, expected: file)
            completed += file.bytes
            progress(.init(phase: .copying, completedBytes: completed, totalBytes: review.sourceBytes))
        }
        // Core ML compilation is synchronous and may ignore cancellation. This
        // actor retains its installation slot until it actually returns.
        for (offset, name) in ["text", "image"].enumerated() {
            try Task.checkCancellation()
            progress(.init(phase: .compiling, completedBytes: Int64(offset), totalBytes: 2))
            let compiled = try autoreleasepool { try compiler(packages.appendingPathComponent("models/\(name).mlpackage")) }
            defer { try? FileManager.default.removeItem(at: compiled) }
            try Task.checkCancellation()
            // Core ML may hardlink immutable compiler-cache weights. Materialize
            // private bytes instead of retaining those aliases in our runtime.
            let compiledFiles = try SemanticInstallationIO.inventory(compiled, maximumBytes: Self.maximumInstalledBytes,
                                                                      allowsHardLinks: true)
            let output = runtime.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            for file in compiledFiles {
                let target = output.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SemanticInstallationIO.copyVerified(compiled.appendingPathComponent(file.path), to: target,
                                                         expected: file, allowsHardLinks: true)
            }
        }
        try FileManager.default.removeItem(at: packages)
        let files = try SemanticInstallationIO.inventory(runtime, maximumBytes: Self.maximumInstalledBytes)
        let approvedHash = try SemanticInstallationIO.digestJSON(manifest)
        let receipt = SemanticInstallationReceipt(schemaVersion: 1, sourceManifestSHA256: approvedHash,
                                                   descriptor: manifest.descriptor, files: files)
        let receiptData = try SemanticInstallationIO.json(receipt)
        let receiptHash = SemanticInstallationIO.digest(receiptData)
        let bytes = files.reduce(Int64(receiptData.count)) { $0 + $1.bytes }
        guard bytes <= Self.maximumInstalledBytes else { throw SemanticEmbeddingError.invalidInstallation }
        try receiptData.write(to: runtime.appendingPathComponent("installation.json"), options: .atomic)
        try Task.checkCancellation()
        progress(.init(phase: .publishing, completedBytes: 0, totalBytes: 1))
        try FileManager.default.moveItem(at: runtime, to: destination)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        let pointer = SemanticInstallationPointer(schemaVersion: 1, generation: generation,
                                                  receiptSHA256: receiptHash, installedBytes: bytes)
        try SemanticInstallationIO.replacePointer(try SemanticInstallationIO.json(pointer), in: directory)
        published = true
        // Publication is the commit point. Do not report cancellation afterward:
        // the caller must receive the generation that became active.
        progress(.init(phase: .publishing, completedBytes: 1, totalBytes: 1))
        // Service quiesces/unloads the previous provider before calling install.
        // Keep it intact until the new pointer is atomically published.
        if let previous { try? Self.removeOwnedGeneration(previous, approved: manifest) }
        return SemanticInstalledModel(directory: destination, descriptor: manifest.descriptor,
                                      installationFingerprint: receiptHash, installedBytes: bytes)
    }

    /// Lightweight metadata only. Full file hashes are deferred until an
    /// explicit provider load under the service's shared resource lease.
    func installedModel() async throws -> SemanticInstalledModel? { try currentModel() }

    private func currentModel() throws -> SemanticInstalledModel? {
        let pointerURL = directory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        let pointer = try SemanticInstallationIO.decode(SemanticInstallationPointer.self, at: pointerURL, limit: 16 * 1_024)
        guard pointer.schemaVersion == 1, UUID(uuidString: pointer.generation) != nil,
              SemanticInstallationIO.validHash(pointer.receiptSHA256), pointer.installedBytes > 0,
              pointer.installedBytes <= Self.maximumInstalledBytes else { throw SemanticEmbeddingError.invalidInstallation }
        let model = SemanticInstalledModel(directory: directory.appendingPathComponent("generations/" + pointer.generation),
                                           descriptor: try approvedManifest().descriptor,
                                           installationFingerprint: pointer.receiptSHA256,
                                           installedBytes: pointer.installedBytes)
        _ = try Self.receipt(for: model, approved: approvedManifest())
        return model
    }

    /// Must be called after service cancellation, actual work completion and
    /// provider unload, so no model loses its backing files during inference.
    func remove() async throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try SemanticInstallationIO.requireDirectory(directory)
        let model = try? currentModel()
        try Task.checkCancellation()
        try SemanticInstallationIO.removePointer(in: directory)
        if let model { try Self.removeOwnedGeneration(model, approved: approvedManifest()) }
    }

    private static func removeOwnedGeneration(_ model: SemanticInstalledModel,
                                              approved: SemanticPackageManifest) throws {
        let receipt = try receipt(for: model, approved: approved)
        try SemanticInstallationIO.verifyMetadataTree(model.directory, files: receipt.files, extraFiles: ["installation.json"])
        try FileManager.default.removeItem(at: model.directory)
    }

    static func verifyInstallation(_ model: SemanticInstalledModel) throws -> [(URL, String)] {
        let approved = try SemanticPackageManifest.approved()
        let receipt = try receipt(for: model, approved: approved)
        let receiptBytes = model.installedBytes - receipt.files.reduce(Int64(0)) { $0 + $1.bytes }
        let files = receipt.files + [.init(path: "installation.json", bytes: receiptBytes,
                                           sha256: model.installationFingerprint)]
        return try SemanticInstallationIO.verifiedTree(model.directory, files: files)
    }

    private static func receipt(for model: SemanticInstalledModel,
                                approved: SemanticPackageManifest) throws -> SemanticInstallationReceipt {
        try approved.validate()
        try SemanticInstallationIO.requireDirectory(model.directory)
        let data = try SemanticInstallationIO.read(model.directory.appendingPathComponent("installation.json"), limit: 128 * 1_024)
        guard SemanticInstallationIO.digest(data) == model.installationFingerprint else { throw SemanticEmbeddingError.installationChanged }
        let receipt = try JSONDecoder().decode(SemanticInstallationReceipt.self, from: data)
        guard receipt.schemaVersion == 1, receipt.descriptor == approved.descriptor,
              receipt.descriptor == model.descriptor,
              receipt.sourceManifestSHA256 == (try SemanticInstallationIO.digestJSON(approved)) else {
            throw SemanticEmbeddingError.invalidInstallation
        }
        try SemanticPackageManifest(schemaVersion: 1, descriptor: receipt.descriptor, files: receipt.files).validate()
        let total = receipt.files.reduce(Int64(data.count)) { $0 + $1.bytes }
        guard total == model.installedBytes, total <= maximumInstalledBytes,
              receipt.files.contains(where: { $0.path.hasPrefix("text.mlmodelc/") }),
              receipt.files.contains(where: { $0.path.hasPrefix("image.mlmodelc/") }) else { throw SemanticEmbeddingError.invalidInstallation }
        // Configs/licenses stay exactly the approved source bytes. Compiled
        // graph/weights are represented by the locally generated receipt.
        for file in approved.files where !file.path.hasPrefix("models/") {
            guard receipt.files.contains(file) else { throw SemanticEmbeddingError.invalidInstallation }
        }
        return receipt
    }

    private static func verifyPackage(_ source: URL, approved: SemanticPackageManifest) throws -> Int64 {
        let manifestURL = source.appendingPathComponent("manifest.json")
        let data = try SemanticInstallationIO.read(manifestURL, limit: 128 * 1_024)
        let declared = try JSONDecoder().decode(SemanticPackageManifest.self, from: data)
        guard declared == approved else { throw SemanticEmbeddingError.invalidInstallation }
        try SemanticInstallationIO.verifyTree(source, files: approved.files, extraFiles: ["manifest.json"])
        return approved.files.reduce(Int64(data.count)) { $0 + $1.bytes }
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(directory)
        let generations = directory.appendingPathComponent("generations")
        try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(generations)
    }

    private static func availableCapacity(_ url: URL) throws -> Int64 {
        let value = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = value.volumeAvailableCapacityForImportantUsage else { throw SemanticEmbeddingError.insufficientDiskSpace }
        return bytes
    }
}

/// Bounded, no-follow file operations shared by installer and provider. File
/// bytes are hashed while copied; neither mmap nor whole-model Data is needed.
enum SemanticInstallationIO {
    /// renameat replaces the fixed directory entry itself. It never opens or
    /// writes through an existing symlink/hardlink named current.json.
    static func replacePointer(_ data: Data, in directory: URL) throws {
        guard data.count <= 16 * 1_024 else { throw SemanticEmbeddingError.invalidInstallation }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw SemanticEmbeddingError.invalidInstallation }
        defer { close(root) }
        let temporary = ".current-" + UUID().uuidString.lowercased() + ".tmp"
        let file = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw SemanticEmbeddingError.providerFailure }
        defer { close(file); unlinkat(root, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: completed), bytes.count - completed)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SemanticEmbeddingError.providerFailure }
                completed += count
            }
        }
        guard fsync(file) == 0, renameat(root, temporary, root, "current.json") == 0 else {
            throw SemanticEmbeddingError.providerFailure
        }
        // The rename is the commit. An inability to flush directory metadata
        // afterward must not report that publication never happened.
        _ = fsync(root)
    }
    static func removePointer(in directory: URL) throws {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw SemanticEmbeddingError.invalidInstallation }
        defer { close(root) }
        guard unlinkat(root, "current.json", 0) == 0 || errno == ENOENT else {
            throw SemanticEmbeddingError.providerFailure
        }
        _ = fsync(root)
    }
    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0") &&
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digestJSON<T: Encodable>(_ value: T) throws -> String { digest(try json(value)) }
    static func decode<T: Decodable>(_ type: T.Type, at url: URL, limit: Int) throws -> T {
        do { return try JSONDecoder().decode(type, from: read(url, limit: limit)) }
        catch let error as SemanticEmbeddingError { throw error }
        catch { throw SemanticEmbeddingError.invalidInstallation }
    }
    static func requireDirectory(_ url: URL) throws {
        var value = stat()
        guard url.isFileURL, lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw SemanticEmbeddingError.invalidInstallation }
    }
    static func stamp(_ url: URL, allowsHardLinks: Bool = false) throws -> String {
        var value = stat()
        guard url.isFileURL, lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              allowsHardLinks || value.st_nlink == 1 else { throw SemanticEmbeddingError.invalidInstallation }
        return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, limit >= 0 else { throw SemanticEmbeddingError.invalidInstallation }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SemanticEmbeddingError.invalidInstallation }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
              value.st_size >= 0, value.st_size <= limit else { throw SemanticEmbeddingError.invalidInstallation }
        var data = Data()
        while true {
            let consumed = try autoreleasepool { () throws -> Int in
                try Task.checkCancellation()
                let remaining = limit - data.count
                guard let chunk = try handle.read(upToCount: min(1_048_576, remaining + 1)), !chunk.isEmpty else { return 0 }
                guard chunk.count <= remaining else { throw SemanticEmbeddingError.invalidInstallation }
                data.append(chunk)
                return chunk.count
            }
            if consumed == 0 { break }
        }
        guard data.count == value.st_size else { throw SemanticEmbeddingError.installationChanged }
        return data
    }
    static func verifyTree(_ root: URL, files: [SemanticManifestFile], extraFiles: Set<String> = [],
                           afterHash: (URL) throws -> Void = { _ in }) throws {
        try verifyMetadataTree(root, files: files, extraFiles: extraFiles)
        for file in files {
            try Task.checkCancellation()
            let actual = try hashFile(root.appendingPathComponent(file.path))
            guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw SemanticEmbeddingError.invalidInstallation }
            try afterHash(root.appendingPathComponent(file.path))
        }
    }
    static func verifiedTree(_ root: URL, files: [SemanticManifestFile],
                             afterHash: (URL) throws -> Void = { _ in }) throws -> [(URL, String)] {
        let stamps = try files.map { file -> (URL, String) in
            let url = root.appendingPathComponent(file.path)
            return (url, try stamp(url))
        }
        try verifyTree(root, files: files, afterHash: afterHash)
        // Tie the entire hash set to one unchanged installation. A file checked
        // early may not change while another large weight file is still hashed.
        try verifyMetadataTree(root, files: files)
        for (url, expected) in stamps {
            guard try stamp(url) == expected else { throw SemanticEmbeddingError.installationChanged }
        }
        return stamps
    }
    static func verifyMetadataTree(_ root: URL, files: [SemanticManifestFile], extraFiles: Set<String> = []) throws {
        let expected = Set(files.map(\.path)).union(extraFiles)
        let metadata = try treeMetadata(root, maximumBytes: SemanticModelInstaller.maximumInstalledBytes + 128 * 1_024,
                                        allowedFiles: expected)
        guard Set(metadata.map(\.path)) == expected else { throw SemanticEmbeddingError.invalidInstallation }
        for file in files {
            guard metadata.contains(where: { $0.path == file.path && $0.bytes == file.bytes }) else {
                throw SemanticEmbeddingError.invalidInstallation
            }
        }
    }
    static func inventory(_ root: URL, maximumBytes: Int64, allowsHardLinks: Bool = false) throws -> [SemanticManifestFile] {
        try treeMetadata(root, maximumBytes: maximumBytes, allowsHardLinks: allowsHardLinks).map { file in
            let value = try hashFile(root.appendingPathComponent(file.path), allowsHardLinks: allowsHardLinks)
            return .init(path: file.path, bytes: value.bytes, sha256: value.sha256)
        }
    }
    private static func treeMetadata(_ root: URL, maximumBytes: Int64, allowedFiles: Set<String>? = nil,
                                     allowsHardLinks: Bool = false) throws -> [SemanticManifestFile] {
        try requireDirectory(root)
        // Foundation enumerators canonicalize system ancestor aliases such as
        // /var -> /private/var. Check the requested root itself before resolving
        // ancestors, then compare enumerated paths against that same base.
        guard let resolved = realpath(root.path, nil) else { throw SemanticEmbeddingError.invalidInstallation }
        let canonicalPath = String(cString: resolved)
        free(resolved)
        let enumerationRoot = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        try requireDirectory(enumerationRoot)
        let allowedDirectories = allowedFiles.map { paths in
            Set(paths.flatMap { path -> [String] in
                let parts = path.split(separator: "/")
                return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
            })
        }
        var traversalFailed = false
        guard let enumerator = FileManager.default.enumerator(at: enumerationRoot, includingPropertiesForKeys: nil,
                                                              options: [], errorHandler: { _, _ in traversalFailed = true; return false }) else {
            throw SemanticEmbeddingError.invalidInstallation
        }
        var files: [SemanticManifestFile] = []; var count = 0; var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation(); count += 1
            guard count <= 1_024, url.path.hasPrefix(canonicalPath + "/") else { throw SemanticEmbeddingError.invalidInstallation }
            let relative = String(url.path.dropFirst(canonicalPath.count + 1))
            guard validRelativePath(relative) else { throw SemanticEmbeddingError.invalidInstallation }
            var value = stat()
            guard lstat(url.path, &value) == 0 else { throw SemanticEmbeddingError.invalidInstallation }
            if value.st_mode & S_IFMT == S_IFDIR {
                guard allowedDirectories?.contains(relative) != false else { throw SemanticEmbeddingError.invalidInstallation }
                continue
            }
            guard value.st_mode & S_IFMT == S_IFREG, value.st_size > 0,
                  allowsHardLinks || value.st_nlink == 1 else { throw SemanticEmbeddingError.invalidInstallation }
            let next = total.addingReportingOverflow(Int64(value.st_size))
            guard !next.overflow, next.partialValue <= maximumBytes else { throw SemanticEmbeddingError.invalidInstallation }
            total = next.partialValue
            files.append(.init(path: relative, bytes: Int64(value.st_size), sha256: ""))
        }
        guard !traversalFailed else { throw SemanticEmbeddingError.invalidInstallation }
        return files.sorted { $0.path < $1.path }
    }
    static func hashFile(_ source: URL, allowsHardLinks: Bool = false) throws -> (bytes: Int64, sha256: String) {
        try transfer(source, destination: nil, allowsHardLinks: allowsHardLinks)
    }
    static func copyVerified(_ source: URL, to destination: URL, expected: SemanticManifestFile,
                             allowsHardLinks: Bool = false) throws {
        let value = try transfer(source, destination: destination, allowsHardLinks: allowsHardLinks)
        guard value.bytes == expected.bytes, value.sha256 == expected.sha256 else { throw SemanticEmbeddingError.invalidInstallation }
    }
    private static func transfer(_ source: URL, destination: URL?, allowsHardLinks: Bool) throws -> (bytes: Int64, sha256: String) {
        let before = try stamp(source, allowsHardLinks: allowsHardLinks)
        let fd = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SemanticEmbeddingError.invalidInstallation }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              allowsHardLinks || value.st_nlink == 1, value.st_size > 0, value.st_size <= SemanticModelInstaller.maximumInstalledBytes else {
            throw SemanticEmbeddingError.invalidInstallation
        }
        var output: FileHandle?
        if let destination {
            let out = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard out >= 0 else { throw SemanticEmbeddingError.invalidInstallation }
            output = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        }
        defer { try? output?.close() }
        var hasher = SHA256(); var count: Int64 = 0
        while true {
            // NSData/FileHandle bridging can defer temporary destruction until
            // an autoreleasepool drains. Do not retain a model-sized sequence
            // of one-MiB chunks while a full hash/copy is in progress.
            let consumed = try autoreleasepool { () throws -> Int in
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { return 0 }
                count += Int64(data.count)
                guard count <= value.st_size else { throw SemanticEmbeddingError.invalidInstallation }
                hasher.update(data: data); try output?.write(contentsOf: data)
                return data.count
            }
            if consumed == 0 { break }
        }
        guard count == value.st_size, try stamp(source, allowsHardLinks: allowsHardLinks) == before else { throw SemanticEmbeddingError.installationChanged }
        return (count, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
