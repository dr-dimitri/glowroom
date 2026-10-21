import CoreML
import Foundation

struct SubjectMattingInstalledModel: Equatable, Sendable {
    let directory: URL
    let receiptSHA256: String
}

struct SubjectMattingSetupProgress: Sendable {
    let text: String
    let fraction: Double?
}

enum SubjectMattingError: Error, LocalizedError, Equatable, Sendable {
    case invalidModel, updateRequired, setupInProgress, insufficientDiskSpace, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidModel:
            "Das lokale Motivmodell ist unvollständig, verändert oder nicht kompatibel. Importiere das für Glowroom vorbereitete BiRefNet-HR-Matting-Modell mit 1920 × 1920 Pixeln erneut."
        case .updateRequired:
            "Das installierte Motivmodell verwendet noch 2048 Pixel. Ersetze es unter „Motivmodell einrichten …“ durch die aktuelle 1920-Pixel-Variante. Gespeicherte Masken bleiben erhalten."
        case .setupInProgress:
            "Das lokale Motivmodell wird bereits eingerichtet oder entfernt."
        case .unavailable:
            "Das lokale Motivmodell konnte diese Maske nicht berechnen."
        case .insufficientDiskSpace:
            "Für den Import des Motivmodells werden mindestens 3 GB freier Speicher benötigt."
        }
    }
}

enum SubjectMattingModelVersion: Equatable, Sendable {
    case current, legacy
}

private struct SubjectMattingModelReceipt: Codable {
    let schemaVersion: Int
    let sourceFiles: [SemanticManifestFile]
    let files: [SemanticManifestFile]
}

private struct SubjectMattingModelPointer: Codable {
    let schemaVersion: Int
    let generation: String
    let receiptSHA256: String
}

/// Imports only the qualified local package. Private copies, native validation
/// and an atomic pointer keep a failed replacement from changing a usable model.
/// The shared inference admission also prevents removal during an actual native
/// prediction; cancellation cannot release that admission before compile returns.
actor SubjectMattingModelStore {
    static let shared = SubjectMattingModelStore()
    static let maximumInstalledBytes: Int64 = 1_024 * 1_024 * 1_024 - 256 * 1_024
    static let residentMemoryEstimate = SubjectMattingModelInterface.residentBytes
    typealias SourceValidator = @Sendable (URL) throws -> [SemanticManifestFile]
    typealias SourceClassifier = @Sendable ([SemanticManifestFile]) throws -> SubjectMattingModelVersion
    typealias Compiler = @Sendable (URL) throws -> URL
    typealias AsyncCompiler = @Sendable (URL) async throws -> URL
    typealias Validator = @Sendable (URL) throws -> Void
    private let directory: URL
    private let budget: AIResourceBudget
    private let sourceValidator: SourceValidator
    private let sourceClassifier: SourceClassifier
    private let compiler: Compiler
    private let asyncCompiler: AsyncCompiler?
    private let validator: Validator
    private var changing = false

    init(directory: URL? = nil, budget: AIResourceBudget = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Glowroom/Models/SubjectMatting", isDirectory: true)
        self.budget = budget
        sourceValidator = { try SubjectMattingModelInterface.validateSourcePackage($0) }
        sourceClassifier = { files in
            guard files.count == 3 else { throw SubjectMattingError.invalidModel }
            if Set(files) == Set(try SubjectMattingModelInterface.approvedFiles()) { return .current }
            if Set(files) == Set(try SubjectMattingModelInterface.legacyFiles()) { return .legacy }
            throw SubjectMattingError.invalidModel
        }
        compiler = { try MLModel.compileModel(at: $0) }
        asyncCompiler = nil
        validator = { try SubjectMattingModelInterface.validateModel($0) }
    }

    /// Synthetic packages exercise ownership, cancellation and publication
    /// without downloading weights or invoking the native compiler in tests.
    init(directory: URL, budget: AIResourceBudget, sourceValidator: @escaping SourceValidator,
         compiler: @escaping Compiler, validator: @escaping Validator,
         sourceClassifier: @escaping SourceClassifier = { _ in .current },
         asyncCompiler: AsyncCompiler? = nil) {
        self.directory = directory; self.budget = budget; self.sourceValidator = sourceValidator
        self.compiler = compiler; self.validator = validator
        self.asyncCompiler = asyncCompiler
        self.sourceClassifier = sourceClassifier
    }

    func installedModel() throws -> SubjectMattingInstalledModel? {
        guard let installation = try managedInstallation() else { return nil }
        if installation.version == .legacy {
            // An upgrade hint identifies the known, intact previous package;
            // changed or foreign bytes still report an invalid installation.
            _ = try Self.verifyInstallation(installation.model)
            throw SubjectMattingError.updateRequired
        }
        return installation.model
    }

    /// Management may replace/remove the pinned previous version, but runtime
    /// inference may use only the current version. Unknown sources never gain
    /// ownership merely because they resemble an app-generated receipt.
    private func managedInstallation() throws -> (model: SubjectMattingInstalledModel, version: SubjectMattingModelVersion)? {
        let pointerURL = directory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        do {
            try SemanticInstallationIO.requireDirectory(directory)
            try SemanticInstallationIO.requireDirectory(directory.appendingPathComponent("generations"))
            let pointer = try SemanticInstallationIO.decode(SubjectMattingModelPointer.self, at: pointerURL, limit: 16_384)
            guard pointer.schemaVersion == 1, UUID(uuidString: pointer.generation) != nil,
                  SemanticInstallationIO.validHash(pointer.receiptSHA256) else { throw SubjectMattingError.invalidModel }
            let installed = SubjectMattingInstalledModel(
                directory: directory.appendingPathComponent("generations/" + pointer.generation, isDirectory: true),
                receiptSHA256: pointer.receiptSHA256)
            let receipt = try Self.receipt(installed)
            return (installed, try sourceClassifier(receipt.sourceFiles))
        } catch is CancellationError { throw CancellationError() }
        catch let error as SubjectMattingError { throw error }
        catch { throw SubjectMattingError.invalidModel }
    }

    @discardableResult
    func install(from source: URL, progress: @escaping @Sendable (SubjectMattingSetupProgress) -> Void = { _ in }) async throws -> SubjectMattingInstalledModel {
        guard !changing else { throw SubjectMattingError.setupInProgress }
        changing = true
        defer { changing = false }
        let lease = try await budget.acquireLocalInference(priority: .interactive, residentBytes: Self.residentMemoryEstimate)
        do {
            let installed = try await installAdmitted(from: source, progress: progress)
            await budget.release(lease)
            return installed
        } catch {
            await budget.release(lease)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw (error as? SubjectMattingError) ?? .invalidModel
        }
    }

    private func installAdmitted(from source: URL, progress: @Sendable (SubjectMattingSetupProgress) -> Void) async throws -> SubjectMattingInstalledModel {
        try Task.checkCancellation()
        guard source.isFileURL, source.pathExtension.lowercased() == "mlpackage" else { throw SubjectMattingError.invalidModel }
        try SemanticInstallationIO.requireDirectory(source)
        progress(.init(text: "Modellpaket wird geprüft …", fraction: nil))
        let sourceFiles = try sourceValidator(source)
        guard Self.validFiles(sourceFiles), sourceFiles.contains(where: { $0.path == "Manifest.json" }),
              sourceFiles.contains(where: { $0.path.hasSuffix(".mlmodel") }) else { throw SubjectMattingError.invalidModel }
        try SemanticInstallationIO.verifyMetadataTree(source, files: sourceFiles)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(directory)
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(generations)
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard capacity >= 3 * 1_024 * 1_024 * 1_024 else { throw SubjectMattingError.insufficientDiskSpace }
        let previous = try? managedInstallation()?.model
        let generation = UUID().uuidString.lowercased()
        let stage = directory.appendingPathComponent(".staging-" + generation, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let package = stage.appendingPathComponent("SubjectMatting.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let total = sourceFiles.reduce(Int64(0)) { $0 + $1.bytes }
        var copied: Int64 = 0
        // A single large weight file dominates this private copy. Sequential
        // streaming bounds disk pressure and memory without another worker pool.
        for file in sourceFiles {
            try Task.checkCancellation()
            let destination = package.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SemanticInstallationIO.copyVerified(source.appendingPathComponent(file.path), to: destination, expected: file)
            copied += file.bytes
            progress(.init(text: "Modell wird privat kopiert …", fraction: Double(copied) / Double(total)))
        }
        try SemanticInstallationIO.verifyTree(package, files: sourceFiles)
        try Task.checkCancellation()
        progress(.init(text: "Modell wird lokal vorbereitet …", fraction: nil))
        let compiled: URL
        if let asyncCompiler {
            // Suspending test compilers keep the same setup guard and resource
            // lease until actual return, including after caller cancellation.
            compiled = try await asyncCompiler(package)
        } else { compiled = try autoreleasepool { try compiler(package) } }
        defer { try? FileManager.default.removeItem(at: compiled) }
        try Task.checkCancellation()
        let runtime = stage.appendingPathComponent("runtime", isDirectory: true)
        let model = runtime.appendingPathComponent("model.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let compiledFiles = try SemanticInstallationIO.inventory(compiled, maximumBytes: Self.maximumInstalledBytes, allowsHardLinks: true)
        guard !compiledFiles.isEmpty else { throw SubjectMattingError.invalidModel }
        for file in compiledFiles {
            let destination = model.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SemanticInstallationIO.copyVerified(compiled.appendingPathComponent(file.path), to: destination,
                                                    expected: file, allowsHardLinks: true)
        }
        let inventory = try SemanticInstallationIO.inventory(runtime, maximumBytes: Self.maximumInstalledBytes)
        progress(.init(text: "Modellschnittstelle wird geprüft …", fraction: nil))
        try autoreleasepool { try validator(model) }
        // Native loading may not mutate bytes after the private inventory.
        try SemanticInstallationIO.verifyTree(runtime, files: inventory)
        let receipt = SubjectMattingModelReceipt(schemaVersion: 1, sourceFiles: sourceFiles, files: inventory)
        let receiptData = try SemanticInstallationIO.json(receipt)
        guard receiptData.count <= 256 * 1_024 else { throw SubjectMattingError.invalidModel }
        let receiptHash = SemanticInstallationIO.digest(receiptData)
        try receiptData.write(to: runtime.appendingPathComponent("installation.json"), options: .atomic)
        try Task.checkCancellation()
        let destination = generations.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.moveItem(at: runtime, to: destination)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        try SemanticInstallationIO.replacePointer(try SemanticInstallationIO.json(SubjectMattingModelPointer(
            schemaVersion: 1, generation: generation, receiptSHA256: receiptHash)), in: directory)
        published = true
        // Pointer publication commits setup. Later cancellation must not report
        // that a replacement which is already visible failed to install.
        if let previous, (try? Self.verifyInstallation(previous)) != nil { try? FileManager.default.removeItem(at: previous.directory) }
        progress(.init(text: "Lokales Motivmodell ist bereit.", fraction: 1))
        return SubjectMattingInstalledModel(directory: destination, receiptSHA256: receiptHash)
    }

    func remove() async throws {
        guard !changing else { throw SubjectMattingError.setupInProgress }
        changing = true
        defer { changing = false }
        let lease = try await budget.acquireLocalInference(priority: .interactive)
        do {
            if let installed = try managedInstallation()?.model {
                _ = try Self.verifyInstallation(installed)
                try Task.checkCancellation()
                try SemanticInstallationIO.removePointer(in: directory)
                // The removal commit is complete; clean up only its verified
                // generation, leaving foreign or unidentified directories alone.
                try FileManager.default.removeItem(at: installed.directory)
            }
            await budget.release(lease)
        } catch {
            await budget.release(lease)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw (error as? SubjectMattingError) ?? .invalidModel
        }
    }

    static func verifyInstallation(_ installed: SubjectMattingInstalledModel) throws -> [(URL, String)] {
        do {
            let receipt = try receipt(installed)
            let bytes = try SemanticInstallationIO.read(installed.directory.appendingPathComponent("installation.json"), limit: 256 * 1_024)
            return try SemanticInstallationIO.verifiedTree(installed.directory, files: receipt.files + [
                .init(path: "installation.json", bytes: Int64(bytes.count), sha256: installed.receiptSHA256)
            ])
        } catch is CancellationError { throw CancellationError() }
        catch { throw SubjectMattingError.invalidModel }
    }

    private static func receipt(_ installed: SubjectMattingInstalledModel) throws -> SubjectMattingModelReceipt {
        let generations = installed.directory.deletingLastPathComponent()
        guard UUID(uuidString: installed.directory.lastPathComponent) != nil, generations.lastPathComponent == "generations",
              SemanticInstallationIO.validHash(installed.receiptSHA256) else { throw SubjectMattingError.invalidModel }
        try SemanticInstallationIO.requireDirectory(generations.deletingLastPathComponent())
        try SemanticInstallationIO.requireDirectory(generations)
        try SemanticInstallationIO.requireDirectory(installed.directory)
        let bytes = try SemanticInstallationIO.read(installed.directory.appendingPathComponent("installation.json"), limit: 256 * 1_024)
        guard SemanticInstallationIO.digest(bytes) == installed.receiptSHA256 else { throw SubjectMattingError.invalidModel }
        let receipt = try JSONDecoder().decode(SubjectMattingModelReceipt.self, from: bytes)
        guard receipt.schemaVersion == 1, validFiles(receipt.sourceFiles), validFiles(receipt.files),
              receipt.files.allSatisfy({ $0.path.hasPrefix("model.mlmodelc/") }) else { throw SubjectMattingError.invalidModel }
        try SemanticInstallationIO.verifyMetadataTree(installed.directory, files: receipt.files, extraFiles: ["installation.json"])
        return receipt
    }

    private static func validFiles(_ files: [SemanticManifestFile]) -> Bool {
        guard !files.isEmpty, files.count <= 1_024, Set(files.map(\.path)).count == files.count else { return false }
        var total: Int64 = 0
        for file in files {
            guard SemanticInstallationIO.validRelativePath(file.path), file.bytes > 0,
                  file.bytes <= maximumInstalledBytes, SemanticInstallationIO.validHash(file.sha256) else { return false }
            let next = total.addingReportingOverflow(file.bytes)
            guard !next.overflow, next.partialValue <= maximumInstalledBytes else { return false }
            total = next.partialValue
        }
        return true
    }
}
