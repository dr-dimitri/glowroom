import Darwin
import Foundation

/// The original ONNX export, also used by the reproducible sky-model evaluation.
/// Model identity comes from the app, never from a mutable server manifest.
enum SkySegApprovedDownload {
    static let revision = "3ba8c6df1d9ba9ff26f637c7ba9568ac11a9aa7f"
    static let modelCard = URL(string: "https://huggingface.co/JianyuanWang/skyseg")!
    static let file = SemanticManifestFile(path: "skyseg.onnx", bytes: 175_997_079,
        sha256: "ab9c34c64c3d821220a2886a4a06da4642ffa14d5b30e8d5339056a089aa1d39")
    static let url = URL(string: "https://huggingface.co/JianyuanWang/skyseg/resolve/\(revision)/skyseg.onnx")!
}

enum SkySegDownloadError: Error, LocalizedError, Equatable {
    case invalidDownload, downloadInProgress, insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .invalidDownload: "Die Skyseg-Datei ist unvollständig oder verändert. Lade sie erneut herunter."
        case .downloadInProgress: "Ein Skyseg-Download wird bereits ausgeführt oder entfernt."
        case .insufficientDiskSpace: "Für den Skyseg-Download werden mindestens 384 MB freier Speicher benötigt."
        }
    }
}

private struct SkySegDownloadPointer: Codable {
    let schemaVersion: Int
    let sourceRevision: String
    let generation: String
}

/// Downloads model data only; publishing this file does not activate an inference
/// backend. A private generation and atomic pointer preserve the previous file
/// on cancellation, HTTP failure or checksum mismatch. All I/O is off MainActor.
actor SkySegModelDownloadStore {
    static let shared = SkySegModelDownloadStore(directory: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("Glowroom/Models/Skyseg", isDirectory: true))
    typealias Downloader = SkyMaskModelStore.Downloader
    private let directory: URL
    private let file: SemanticManifestFile
    private let downloader: Downloader
    private var changing = false

    init(directory: URL, file: SemanticManifestFile = SkySegApprovedDownload.file,
         downloader: @escaping Downloader = { source, destination, maximumBytes, progress in
             try await SkyMaskPackageDownloader(destination: destination, maximumBytes: maximumBytes,
                 progress: progress).download(source)
         }) {
        self.directory = directory
        self.file = file
        self.downloader = downloader
    }

    func downloadedFile() throws -> URL? {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("current.json").path) else { return nil }
        do {
            try SemanticInstallationIO.requireDirectory(directory)
            let generations = directory.appendingPathComponent("generations", isDirectory: true)
            try SemanticInstallationIO.requireDirectory(generations)
            let pointer = try SemanticInstallationIO.decode(SkySegDownloadPointer.self,
                at: directory.appendingPathComponent("current.json"), limit: 16_384)
            guard pointer.schemaVersion == 1, pointer.sourceRevision == SkySegApprovedDownload.revision,
                  UUID(uuidString: pointer.generation) != nil else { throw SkySegDownloadError.invalidDownload }
            let generation = generations.appendingPathComponent(pointer.generation, isDirectory: true)
            let model = generation.appendingPathComponent(file.path)
            try verifyFile(model)
            return model
        } catch is CancellationError { throw CancellationError() }
        catch {
            // The shared JSON decoder wraps read errors, including a canceled
            // read. Preserve cancellation instead of reporting corrupt data.
            if Task.isCancelled { throw CancellationError() }
            throw SkySegDownloadError.invalidDownload
        }
    }

    @discardableResult
    func download(progress: @escaping @Sendable (SkyMaskSetupProgress) -> Void = { _ in }) async throws -> URL {
        guard !changing else { throw SkySegDownloadError.downloadInProgress }
        changing = true
        defer { changing = false }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(directory)
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(generations)
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard available >= 384 * 1_024 * 1_024 else { throw SkySegDownloadError.insufficientDiskSpace }
        let previous = try? downloadedFile()
        let generation = UUID().uuidString.lowercased()
        let stage = directory.appendingPathComponent(".staging-" + generation, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        progress(.init(text: "Skyseg wird geladen …", fraction: 0))
        // This export is a single file. URLSession streams it to disk while the
        // app stays responsive; splitting it adds synchronization without gain.
        do {
            try await downloader(SkySegApprovedDownload.url, stage.appendingPathComponent(file.path), file.bytes) { [file] count in
                progress(.init(text: "Skyseg wird geladen …", fraction: min(1, max(0, Double(count) / Double(file.bytes)))))
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error as? AutomaticMaskError == .invalidModel { throw SkySegDownloadError.invalidDownload }
            throw error
        }
        try Task.checkCancellation()
        progress(.init(text: "Skyseg wird geprüft …", fraction: nil))
        do { try SemanticInstallationIO.verifyTree(stage, files: [file]) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SkySegDownloadError.invalidDownload }
        try Task.checkCancellation()
        let destination = generations.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.moveItem(at: stage, to: destination)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        let pointer = SkySegDownloadPointer(schemaVersion: 1, sourceRevision: SkySegApprovedDownload.revision, generation: generation)
        try SemanticInstallationIO.replacePointer(try SemanticInstallationIO.json(pointer), in: directory)
        published = true
        // Publication is the commit point. Later cancellation cannot turn this
        // successfully committed download into a reported failure.
        if let previous { try? removeOwned(previous) }
        progress(.init(text: "Skyseg wurde heruntergeladen und geprüft.", fraction: 1))
        return destination.appendingPathComponent(file.path)
    }

    func remove() throws {
        guard !changing else { throw SkySegDownloadError.downloadInProgress }
        // No suspension: removal and pointer publication remain actor-ordered.
        guard let previous = try downloadedFile() else { return }
        try Task.checkCancellation()
        try SemanticInstallationIO.removePointer(in: directory)
        // Pointer removal commits the operation. Do not perform another
        // cancellation-aware hash after this point and report a false failure.
        try removeVerifiedFile(previous)
    }

    private func removeOwned(_ model: URL) throws {
        try verifyFile(model)
        try removeVerifiedFile(model)
    }

    private func verifyFile(_ model: URL) throws {
        let generation = model.deletingLastPathComponent()
        try SemanticInstallationIO.requireDirectory(directory)
        try SemanticInstallationIO.requireDirectory(directory.appendingPathComponent("generations"))
        try SemanticInstallationIO.requireDirectory(generation)
        let actual = try SemanticInstallationIO.hashFile(model)
        guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw SkySegDownloadError.invalidDownload }
    }

    private func removeVerifiedFile(_ model: URL) throws {
        // unlink cannot recursively remove an unexpected directory even if the
        // final path changes after verification.
        guard unlink(model.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Finder may create .DS_Store beside a revealed file. Remove only the
        // verified model; rmdir preserves any unrelated metadata or user files.
        _ = rmdir(model.deletingLastPathComponent().path)
    }
}
