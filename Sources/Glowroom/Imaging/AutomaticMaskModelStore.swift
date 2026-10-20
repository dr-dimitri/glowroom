import CoreML
import Foundation

struct SkyMaskInstalledModel: Equatable, Sendable {
    let directory: URL
    let receiptSHA256: String
}

struct SkyMaskSetupProgress: Sendable {
    let text: String
    let fraction: Double?
}

/// Source bytes are an immutable, publicly released Apple Core ML package.
/// Package filenames, sizes and SHA-256 are app-owned, never server-supplied.
enum SkyMaskApprovedPackage {
    static let revision = "bfcb6e4210d7289310082d7c93bf9a1417b3699f"
    static let modelCard = URL(string: "https://huggingface.co/apple/coreml-detr-semantic-segmentation")!
    static let baseURL = URL(string: "https://huggingface.co/apple/coreml-detr-semantic-segmentation/resolve/\(revision)/DETRResnet50SemanticSegmentationF16.mlpackage/")!
    static let files: [SemanticManifestFile] = [
        .init(path: "Manifest.json", bytes: 617, sha256: "0749549c6b11139e11a40aaab82add4843a9977010337e596cce3dbb35c98512"),
        .init(path: "Data/com.apple.CoreML/model.mlmodel", bytes: 309_817, sha256: "61e05678150bcae26deac589b998dffe13c2977a9ba6f802938a9f3a60bfdcce"),
        .init(path: "Data/com.apple.CoreML/weights/weight.bin", bytes: 85_158_176, sha256: "2f4de3dfed1aeced35ad7096d7c8721fcfb59571110a9e9138d73a7e56480408")
    ]
    static let totalBytes = files.reduce(Int64(0)) { $0 + $1.bytes }
}

private struct SkyMaskModelReceipt: Codable {
    let schemaVersion: Int
    let sourceRevision: String
    let files: [SemanticManifestFile]
}

private struct SkyMaskModelPointer: Codable {
    let schemaVersion: Int
    let generation: String
    let receiptSHA256: String
}

/// A model setup is independent of any catalog or selected photo. It publishes
/// one atomic pointer only after hash verification and native compilation. A
/// canceled/failed replacement leaves the prior installation usable.
actor SkyMaskModelStore {
    static let shared = SkyMaskModelStore(directory: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("Glowroom/Models/Sky", isDirectory: true))
    static let maximumInstalledBytes: Int64 = 384 * 1_024 * 1_024
    typealias Downloader = @Sendable (URL, URL, Int64, @escaping @Sendable (Int64) -> Void) async throws -> Void
    typealias Compiler = @Sendable (URL) throws -> URL
    private let directory: URL
    private let files: [SemanticManifestFile]
    private let downloader: Downloader
    private let compiler: Compiler
    private let budget: AIResourceBudget
    private var installing = false

    init(directory: URL, budget: AIResourceBudget = .shared) {
        self.directory = directory
        self.budget = budget
        files = SkyMaskApprovedPackage.files
        downloader = { source, destination, maximumBytes, progress in
            try await SkyMaskPackageDownloader(destination: destination, maximumBytes: maximumBytes, progress: progress).download(source)
        }
        compiler = { try MLModel.compileModel(at: $0) }
    }

    /// Small synthetic fixtures avoid downloads and Core ML in ordinary tests.
    init(directory: URL, files: [SemanticManifestFile], budget: AIResourceBudget,
         downloader: @escaping Downloader, compiler: @escaping Compiler) {
        self.directory = directory; self.files = files; self.budget = budget
        self.downloader = downloader; self.compiler = compiler
    }

    func installedModel() throws -> SkyMaskInstalledModel? {
        let pointerURL = directory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        do {
            try SemanticInstallationIO.requireDirectory(directory)
            try SemanticInstallationIO.requireDirectory(directory.appendingPathComponent("generations"))
            let pointer = try SemanticInstallationIO.decode(SkyMaskModelPointer.self, at: pointerURL, limit: 16_384)
            guard pointer.schemaVersion == 1, UUID(uuidString: pointer.generation) != nil,
                  SemanticInstallationIO.validHash(pointer.receiptSHA256) else { throw AutomaticMaskError.invalidModel }
            let installed = SkyMaskInstalledModel(directory: directory.appendingPathComponent("generations/" + pointer.generation, isDirectory: true),
                                                  receiptSHA256: pointer.receiptSHA256)
            _ = try Self.receipt(installed)
            return installed
        } catch { throw AutomaticMaskError.invalidModel }
    }

    func install(progress: @escaping @Sendable (SkyMaskSetupProgress) -> Void = { _ in }) async throws -> SkyMaskInstalledModel {
        guard !installing else { throw AutomaticMaskError.setupInProgress }
        installing = true
        defer { installing = false }
        let lease = try await budget.acquireLocalInference(priority: .interactive, residentBytes: Self.maximumInstalledBytes)
        do {
            let installed = try await installAdmitted(progress: progress)
            await budget.release(lease)
            return installed
        } catch {
            await budget.release(lease)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func installAdmitted(progress: @escaping @Sendable (SkyMaskSetupProgress) -> Void) async throws -> SkyMaskInstalledModel {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(directory)
        let generations = directory.appendingPathComponent("generations")
        try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(generations)
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard capacity >= 768 * 1_024 * 1_024 else {
            throw NSError(domain: "Glowroom.SkyMask", code: 1, userInfo: [NSLocalizedDescriptionKey: "Für die Einrichtung werden mindestens 768 MB freier Speicher benötigt."])
        }
        let previous = try? installedModel()
        let generation = UUID().uuidString.lowercased()
        let stage = directory.appendingPathComponent(".staging-" + generation)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let package = stage.appendingPathComponent("Sky.mlpackage")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        // Three dependent files have one large weight file. A serial download
        // bounds disk writes and uses one connection without another worker pool.
        for file in files {
            try Task.checkCancellation()
            let destination = package.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let prior = completed
            progress(.init(text: "Modell wird geladen …", fraction: Double(prior) / Double(total)))
            try await downloader(SkyMaskApprovedPackage.baseURL.appendingPathComponent(file.path), destination, file.bytes) { count in
                progress(.init(text: "Modell wird geladen …", fraction: Double(prior + count) / Double(total)))
            }
            let actual = try SemanticInstallationIO.hashFile(destination)
            guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw AutomaticMaskError.invalidModel }
            completed += file.bytes
        }
        try SemanticInstallationIO.verifyTree(package, files: files)
        try Task.checkCancellation()
        progress(.init(text: "Modell wird lokal vorbereitet …", fraction: nil))
        // The synchronous compiler remains on this background actor and owns the
        // shared lease until it really returns, even after UI cancellation.
        let compiled = try autoreleasepool { try compiler(package) }
        defer { try? FileManager.default.removeItem(at: compiled) }
        try Task.checkCancellation()
        let runtime = stage.appendingPathComponent("runtime")
        let model = runtime.appendingPathComponent("model.mlmodelc")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let inventory = try SemanticInstallationIO.inventory(compiled, maximumBytes: Self.maximumInstalledBytes, allowsHardLinks: true)
        for file in inventory {
            let destination = model.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Compiler caches may contain hardlinks. Materialize private files so
            // model removal cannot touch any other application's cache.
            try SemanticInstallationIO.copyVerified(compiled.appendingPathComponent(file.path), to: destination,
                                                    expected: file, allowsHardLinks: true)
        }
        let runtimeFiles = try SemanticInstallationIO.inventory(runtime, maximumBytes: Self.maximumInstalledBytes)
        guard !runtimeFiles.isEmpty else { throw AutomaticMaskError.invalidModel }
        let receipt = SkyMaskModelReceipt(schemaVersion: 1, sourceRevision: SkyMaskApprovedPackage.revision, files: runtimeFiles)
        let receiptData = try SemanticInstallationIO.json(receipt)
        let receiptHash = SemanticInstallationIO.digest(receiptData)
        try receiptData.write(to: runtime.appendingPathComponent("installation.json"), options: .atomic)
        try Task.checkCancellation()
        let destination = generations.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.moveItem(at: runtime, to: destination)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        let pointer = SkyMaskModelPointer(schemaVersion: 1, generation: generation, receiptSHA256: receiptHash)
        try SemanticInstallationIO.replacePointer(try SemanticInstallationIO.json(pointer), in: directory)
        published = true
        // Atomic pointer publication commits setup: cancellation after this point
        // returns the installed generation instead of reporting a failed setup.
        if let previous { try? Self.removeOwned(previous) }
        progress(.init(text: "Himmelserkennung ist bereit.", fraction: 1))
        return SkyMaskInstalledModel(directory: destination, receiptSHA256: receiptHash)
    }

    func remove() async throws {
        guard !installing else { throw AutomaticMaskError.setupInProgress }
        let lease = try await budget.acquireLocalInference(priority: .interactive)
        do {
            let previous = try installedModel()
            if FileManager.default.fileExists(atPath: directory.path) {
                try SemanticInstallationIO.requireDirectory(directory)
                try SemanticInstallationIO.removePointer(in: directory)
            }
            if let previous { try Self.removeOwned(previous) }
            await budget.release(lease)
        } catch {
            await budget.release(lease)
            throw error
        }
    }

    static func verifyInstallation(_ model: SkyMaskInstalledModel) throws -> [(URL, String)] {
        do {
            let receipt = try receipt(model)
            let receiptBytes = try SemanticInstallationIO.read(model.directory.appendingPathComponent("installation.json"), limit: 128 * 1_024)
            return try SemanticInstallationIO.verifiedTree(model.directory, files: receipt.files + [
                .init(path: "installation.json", bytes: Int64(receiptBytes.count), sha256: model.receiptSHA256)
            ])
        } catch { throw AutomaticMaskError.invalidModel }
    }

    private static func receipt(_ model: SkyMaskInstalledModel) throws -> SkyMaskModelReceipt {
        let generations = model.directory.deletingLastPathComponent()
        guard UUID(uuidString: model.directory.lastPathComponent) != nil,
              generations.lastPathComponent == "generations" else { throw AutomaticMaskError.invalidModel }
        try SemanticInstallationIO.requireDirectory(generations.deletingLastPathComponent())
        try SemanticInstallationIO.requireDirectory(generations)
        try SemanticInstallationIO.requireDirectory(model.directory)
        let data = try SemanticInstallationIO.read(model.directory.appendingPathComponent("installation.json"), limit: 128 * 1_024)
        guard SemanticInstallationIO.digest(data) == model.receiptSHA256 else { throw AutomaticMaskError.invalidModel }
        let receipt = try JSONDecoder().decode(SkyMaskModelReceipt.self, from: data)
        guard receipt.schemaVersion == 1, receipt.sourceRevision == SkyMaskApprovedPackage.revision,
              !receipt.files.isEmpty, receipt.files.count <= 512,
              receipt.files.allSatisfy({ SemanticInstallationIO.validRelativePath($0.path) && $0.path.hasPrefix("model.mlmodelc/") &&
                  $0.bytes > 0 && $0.bytes <= maximumInstalledBytes && SemanticInstallationIO.validHash($0.sha256) }),
              receipt.files.reduce(Int64(0), { $0 + $1.bytes }) <= maximumInstalledBytes else { throw AutomaticMaskError.invalidModel }
        try SemanticInstallationIO.verifyMetadataTree(model.directory, files: receipt.files, extraFiles: ["installation.json"])
        return receipt
    }

    private static func removeOwned(_ model: SkyMaskInstalledModel) throws {
        // Verify app-generated receipts and the exact tree before deleting only
        // this owned generation; unknown directories are left untouched.
        _ = try receipt(model)
        try FileManager.default.removeItem(at: model.directory)
    }
}

/// URLSession writes to its temporary file, bounded by the app-owned size. Only
/// a complete HTTP 200 response of the expected length reaches the private stage.
private final class SkyMaskPackageDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var cancelled = false

    init(destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination; self.maximumBytes = maximumBytes; self.progress = progress
    }

    func download(_ url: URL) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 300
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                lock.lock()
                self.continuation = continuation; self.session = session; self.task = task
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            result = .failure(AutomaticMaskError.invalidModel)
            downloadTask.cancel(); return
        }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
                  let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == maximumBytes else { throw AutomaticMaskError.invalidModel }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(())
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let wasCancelled = cancelled; self.task = nil; self.session = nil
        lock.unlock()
        let completed: Result<Void, Error> = wasCancelled ? .failure(CancellationError()) : result ?? error.map { .failure($0) } ?? .failure(AutomaticMaskError.unavailable)
        continuation?.resume(with: completed)
        session.finishTasksAndInvalidate()
    }
}
