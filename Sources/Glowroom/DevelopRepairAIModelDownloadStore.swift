import Foundation
import GlowroomCore

/// The same immutable Core ML conversion inspected by the LaMa evaluation.
/// Download identity comes from the app, never from a server-supplied manifest.
enum DevelopRepairAIApprovedDownload {
    static let revision = LocalModelRegistry.repairRevision
    static let modelCard = URL(string: "https://huggingface.co/" + LocalModelRegistry.repairRepository)!
    static let baseURL = modelCard.appendingPathComponent("resolve/" + revision + "/" + LocalModelRegistry.repairFolder + "/")
    static let files = LocalModelRegistry.repairFiles
    static let totalBytes = files.reduce(Int64(0)) { $0 + $1.bytes }
    static let minimumFreeBytes: Int64 = 1_024 * 1_024 * 1_024
}

enum DevelopRepairAIDownloadError: Error, LocalizedError, Equatable {
    case invalidDownload, downloadInProgress, insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .invalidDownload: "Das LaMa-Modell ist unvollständig oder verändert. Lade es erneut herunter."
        case .downloadInProgress: "Das lokale Reparaturmodell wird bereits heruntergeladen oder eingerichtet."
        case .insufficientDiskSpace: "Für die LaMa-Einrichtung wird mindestens 1 GB freier Speicher benötigt."
        }
    }
}

/// A download is temporary until the existing importer compiles and atomically
/// publishes it. Failures/cancellation remove only this operation's staging
/// directory; a prior working model remains under the importer's ownership.
actor DevelopRepairAIModelDownloadStore {
    static let shared = DevelopRepairAIModelDownloadStore()
    typealias Downloader = SkyMaskModelStore.Downloader
    typealias Importer = @Sendable (URL) async throws -> DevelopRepairAIInstallation
    private let directory: URL
    private let files: [SemanticManifestFile]
    private let downloader: Downloader
    private let importer: Importer
    private var downloading = false

    init(directory: URL? = nil, files: [SemanticManifestFile] = DevelopRepairAIApprovedDownload.files,
         downloader: @escaping Downloader = { source, destination, maximumBytes, progress in
             try await SkyMaskPackageDownloader(destination: destination, maximumBytes: maximumBytes,
                 progress: progress).download(source)
         }, importer: @escaping Importer = { try await DevelopRepairAIModelStore.shared.importModel(from: $0) }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Glowroom/Models/Repair/Downloads", isDirectory: true)
        self.files = files; self.downloader = downloader; self.importer = importer
    }

    func downloadAndInstall(progress: @escaping @Sendable (SkyMaskSetupProgress) -> Void = { _ in }) async throws -> DevelopRepairAIInstallation {
        guard !downloading else { throw DevelopRepairAIDownloadError.downloadInProgress }
        downloading = true
        defer { downloading = false }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(directory)
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard available >= DevelopRepairAIApprovedDownload.minimumFreeBytes else {
            throw DevelopRepairAIDownloadError.insufficientDiskSpace
        }
        let stage = directory.appendingPathComponent(".staging-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let package = stage.appendingPathComponent("LaMa.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        for file in files {
            try FileManager.default.createDirectory(at: package.appendingPathComponent(file.path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        let transfers = RepairAIDownloadProgress(files: files, progress: progress)
        progress(.init(text: "LaMa wird heruntergeladen …", fraction: 0))
        do {
            let files = self.files, downloader = self.downloader
            // At most two independent transfers overlap. Compilation and model
            // publication remain ordered after the complete verified package.
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                for file in files.prefix(2) {
                    group.addTask { try await Self.download(file, package: package, downloader: downloader, progress: transfers) }
                    next += 1
                }
                while try await group.next() != nil {
                    if next < files.count {
                        let file = files[next]
                        group.addTask { try await Self.download(file, package: package, downloader: downloader, progress: transfers) }
                        next += 1
                    }
                }
            }
            try Task.checkCancellation()
            progress(.init(text: "LaMa wird geprüft …", fraction: nil))
            try SemanticInstallationIO.verifyTree(package, files: files)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error as? AutomaticMaskError == .invalidModel || error as? SemanticEmbeddingError != nil {
                throw DevelopRepairAIDownloadError.invalidDownload
            }
            throw error
        }
        try Task.checkCancellation()
        progress(.init(text: "LaMa wird lokal eingerichtet …", fraction: nil))
        let installation = try await importer(package)
        // The importer owns the commit point. Do not turn successful atomic
        // publication into a reported failure if cancellation arrives afterward.
        progress(.init(text: "LaMa ist für lokale Reparaturen bereit.", fraction: 1))
        return installation
    }

    private static func download(_ file: SemanticManifestFile, package: URL, downloader: Downloader,
                                 progress: RepairAIDownloadProgress) async throws {
        try Task.checkCancellation()
        let destination = package.appendingPathComponent(file.path)
        try await downloader(DevelopRepairAIApprovedDownload.baseURL.appendingPathComponent(file.path), destination, file.bytes) { count in
            progress.update(file: file, count: count)
        }
        try Task.checkCancellation()
        let actual = try SemanticInstallationIO.hashFile(destination)
        guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw DevelopRepairAIDownloadError.invalidDownload }
        progress.update(file: file, count: file.bytes)
    }
}

/// URLSession reports each concurrent file on its own delegate queue. A short
/// lock keeps aggregate progress monotonic without spawning a task per packet.
private final class RepairAIDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private var counts: [String: Int64] = [:]
    private let progress: @Sendable (SkyMaskSetupProgress) -> Void

    init(files: [SemanticManifestFile], progress: @escaping @Sendable (SkyMaskSetupProgress) -> Void) {
        total = files.reduce(Int64(0)) { $0 + $1.bytes }
        self.progress = progress
    }

    func update(file: SemanticManifestFile, count: Int64) {
        lock.lock()
        defer { lock.unlock() }
        counts[file.path] = max(counts[file.path] ?? 0, min(file.bytes, max(0, count)))
        let completed = counts.values.reduce(Int64(0), +)
        progress(.init(text: "LaMa wird heruntergeladen …", fraction: Double(completed) / Double(max(1, total))))
    }
}
