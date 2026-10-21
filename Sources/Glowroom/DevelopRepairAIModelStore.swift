import CoreML
import CoreVideo
import Foundation

struct DevelopRepairAIInstallation: Equatable, Sendable {
    let directory: URL
    let displayName: String
    /// Hash of the complete private compiled-model inventory and import receipt.
    let identity: String
}

enum DevelopRepairAIError: Error, LocalizedError, Equatable, Sendable {
    case modelNotInstalled, invalidModel, importInProgress, invalidMask, selectionTooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: "Importiere zuerst ein kompatibles lokales LaMa-Core-ML-Modell."
        case .invalidModel: "Das Modell ist unvollständig, verändert oder nicht kompatibel. Erwartet werden image und mask mit 800 × 800 Pixeln und eine RGB-Bildausgabe."
        case .importInProgress: "Ein lokales Reparaturmodell wird bereits importiert."
        case .invalidMask: "Markiere einen gültigen kleinen Reparaturbereich."
        case .selectionTooLarge: "Der markierte Bereich ist für die lokale KI-Reparatur zu groß. Verkleinere die Auswahl; mit Kontext sind höchstens 800 × 800 Pixel möglich."
        case .unavailable: "Das lokale Reparaturmodell konnte diese Vorschau nicht berechnen."
        }
    }
}

private struct RepairAIReceipt: Codable {
    let schemaVersion: Int
    let displayName: String
    let sourceFiles: [SemanticManifestFile]
    let files: [SemanticManifestFile]
}

private struct RepairAIPointer: Codable {
    let schemaVersion: Int
    let generation: String
    let identity: String
}

/// Imports an explicitly selected package; no model is shipped or downloaded.
/// Compilation and native validation share the inference admission. Only a
/// verified private runtime is published, so source changes never mutate a model
/// already in use and a failed replacement keeps the earlier installation.
actor DevelopRepairAIModelStore {
    static let shared = DevelopRepairAIModelStore()
    static let maximumInstalledBytes: Int64 = 512 * 1_024 * 1_024
    typealias Compiler = @Sendable (URL) throws -> URL
    typealias AsyncCompiler = @Sendable (URL) async throws -> URL
    typealias Validator = @Sendable (URL) throws -> Void
    private let directory: URL
    private let budget: AIResourceBudget
    private let compiler: Compiler
    private let asyncCompiler: AsyncCompiler?
    private let validator: Validator
    private var importing = false

    init(directory: URL? = nil, budget: AIResourceBudget = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Glowroom/Models/Repair", isDirectory: true)
        self.budget = budget
        compiler = { try MLModel.compileModel(at: $0) }
        asyncCompiler = nil
        validator = { _ = try DevelopRepairAIModelInterface.load($0) }
    }

    /// Synthetic compiler/validator hooks exercise publication and corruption
    /// without weights or Core ML in the ordinary test suite.
    init(directory: URL, budget: AIResourceBudget, compiler: @escaping Compiler, validator: @escaping Validator,
         asyncCompiler: AsyncCompiler? = nil) {
        self.directory = directory; self.budget = budget; self.compiler = compiler; self.validator = validator
        self.asyncCompiler = asyncCompiler
    }

    func installedModel() async throws -> DevelopRepairAIInstallation? {
        let pointerURL = directory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        do {
            try SemanticInstallationIO.requireDirectory(directory)
            try SemanticInstallationIO.requireDirectory(directory.appendingPathComponent("generations"))
            let pointer = try SemanticInstallationIO.decode(RepairAIPointer.self, at: pointerURL, limit: 16_384)
            guard pointer.schemaVersion == 1, UUID(uuidString: pointer.generation) != nil,
                  SemanticInstallationIO.validHash(pointer.identity) else { throw DevelopRepairAIError.invalidModel }
            let runtime = directory.appendingPathComponent("generations/" + pointer.generation, isDirectory: true)
            let receipt = try Self.receipt(at: runtime, identity: pointer.identity)
            return DevelopRepairAIInstallation(directory: runtime, displayName: receipt.displayName, identity: pointer.identity)
        } catch is CancellationError { throw CancellationError() }
        catch { throw DevelopRepairAIError.invalidModel }
    }

    @discardableResult
    func importModel(from source: URL) async throws -> DevelopRepairAIInstallation {
        guard !importing else { throw DevelopRepairAIError.importInProgress }
        importing = true
        defer { importing = false }
        let previous = try? await installedModel()
        let lease = try await budget.acquireLocalInference(residentBytes: 6 * 1_024 * 1_024 * 1_024)
        do {
            let result = try await importAdmitted(source)
            if let previous, previous.directory != result.directory {
                // Publication has committed. Delete only a still verified,
                // app-owned earlier generation; unfamiliar bytes are retained.
                if (try? Self.verifyInstallation(previous)) != nil {
                    try? FileManager.default.removeItem(at: previous.directory)
                }
            }
            await budget.release(lease)
            return result
        } catch {
            await budget.release(lease)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw (error as? DevelopRepairAIError) ?? .invalidModel
        }
    }

    private func importAdmitted(_ source: URL) async throws -> DevelopRepairAIInstallation {
        try Task.checkCancellation()
        guard source.isFileURL, source.pathExtension.lowercased() == "mlpackage" else {
            throw DevelopRepairAIError.invalidModel
        }
        let files = try SemanticInstallationIO.inventory(source, maximumBytes: Self.maximumInstalledBytes)
        guard !files.isEmpty, files.contains(where: { $0.path == "Manifest.json" }),
              files.contains(where: { $0.path.hasSuffix(".mlmodel") }) else { throw DevelopRepairAIError.invalidModel }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(directory)
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SemanticInstallationIO.requireDirectory(generations)
        let generation = UUID().uuidString.lowercased()
        let stage = directory.appendingPathComponent(".staging-" + generation, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let package = stage.appendingPathComponent("Imported.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        for file in files {
            try Task.checkCancellation()
            let destination = package.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SemanticInstallationIO.copyVerified(source.appendingPathComponent(file.path), to: destination, expected: file)
        }
        try SemanticInstallationIO.verifyTree(package, files: files)
        let compiled: URL
        if let asyncCompiler {
            // Test-native work suspends rather than occupying a cooperative
            // thread. The importing flag and lease remain held until return.
            compiled = try await asyncCompiler(package)
        } else {
            compiled = try autoreleasepool { try compiler(package) }
        }
        defer { try? FileManager.default.removeItem(at: compiled) }
        try Task.checkCancellation()
        let runtime = stage.appendingPathComponent("runtime", isDirectory: true)
        let model = runtime.appendingPathComponent("model.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let compiledFiles = try SemanticInstallationIO.inventory(compiled, maximumBytes: Self.maximumInstalledBytes, allowsHardLinks: true)
        guard !compiledFiles.isEmpty else { throw DevelopRepairAIError.invalidModel }
        for file in compiledFiles {
            let destination = model.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SemanticInstallationIO.copyVerified(compiled.appendingPathComponent(file.path), to: destination,
                                                    expected: file, allowsHardLinks: true)
        }
        let inventory = try SemanticInstallationIO.inventory(runtime, maximumBytes: Self.maximumInstalledBytes)
        try autoreleasepool { try validator(model) }
        // Native load must not silently rewrite the tree after its inventory.
        try SemanticInstallationIO.verifyTree(runtime, files: inventory)
        let importedName = String(source.deletingPathExtension().lastPathComponent.prefix(120))
        let displayName = importedName.isEmpty ? "Lokales Reparaturmodell" : importedName
        let receipt = RepairAIReceipt(schemaVersion: 1, displayName: displayName, sourceFiles: files, files: inventory)
        let receiptBytes = try SemanticInstallationIO.json(receipt)
        guard receiptBytes.count <= 256 * 1_024 else { throw DevelopRepairAIError.invalidModel }
        let identity = SemanticInstallationIO.digest(receiptBytes)
        try receiptBytes.write(to: runtime.appendingPathComponent("installation.json"), options: .atomic)
        try Task.checkCancellation()
        let destination = generations.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.moveItem(at: runtime, to: destination)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        try SemanticInstallationIO.replacePointer(try SemanticInstallationIO.json(RepairAIPointer(
            schemaVersion: 1, generation: generation, identity: identity)), in: directory)
        published = true
        return DevelopRepairAIInstallation(directory: destination, displayName: displayName, identity: identity)
    }

    func remove() async throws {
        guard !importing else { throw DevelopRepairAIError.importInProgress }
        importing = true
        defer { importing = false }
        let lease = try await budget.acquireLocalInference()
        do {
            if let installed = try await installedModel() {
                _ = try Self.receipt(at: installed.directory, identity: installed.identity)
                try SemanticInstallationIO.removePointer(in: directory)
                try FileManager.default.removeItem(at: installed.directory)
            }
            await budget.release(lease)
        } catch { await budget.release(lease); throw error }
    }

    static func verifyInstallation(_ installation: DevelopRepairAIInstallation) throws -> [(URL, String)] {
        do {
            let receipt = try receipt(at: installation.directory, identity: installation.identity)
            let receiptBytes = try SemanticInstallationIO.read(installation.directory.appendingPathComponent("installation.json"), limit: 256 * 1_024)
            return try SemanticInstallationIO.verifiedTree(installation.directory, files: receipt.files + [
                .init(path: "installation.json", bytes: Int64(receiptBytes.count), sha256: installation.identity)
            ])
        } catch is CancellationError { throw CancellationError() }
        catch { throw DevelopRepairAIError.invalidModel }
    }

    private static func receipt(at runtime: URL, identity: String) throws -> RepairAIReceipt {
        let generations = runtime.deletingLastPathComponent()
        guard UUID(uuidString: runtime.lastPathComponent) != nil, generations.lastPathComponent == "generations",
              SemanticInstallationIO.validHash(identity) else { throw DevelopRepairAIError.invalidModel }
        try SemanticInstallationIO.requireDirectory(generations.deletingLastPathComponent())
        try SemanticInstallationIO.requireDirectory(generations)
        try SemanticInstallationIO.requireDirectory(runtime)
        let bytes = try SemanticInstallationIO.read(runtime.appendingPathComponent("installation.json"), limit: 256 * 1_024)
        guard SemanticInstallationIO.digest(bytes) == identity else { throw DevelopRepairAIError.invalidModel }
        let receipt = try JSONDecoder().decode(RepairAIReceipt.self, from: bytes)
        func validFiles(_ files: [SemanticManifestFile]) -> Bool {
            !files.isEmpty && files.count <= 1_024 && Set(files.map(\.path)).count == files.count &&
            files.allSatisfy { SemanticInstallationIO.validRelativePath($0.path) && $0.bytes > 0 &&
                $0.bytes <= maximumInstalledBytes && SemanticInstallationIO.validHash($0.sha256) } &&
            files.reduce(Int64(0)) { $0 + $1.bytes } <= maximumInstalledBytes
        }
        guard receipt.schemaVersion == 1, !receipt.displayName.isEmpty, receipt.displayName.count <= 120,
              validFiles(receipt.files), validFiles(receipt.sourceFiles),
              receipt.files.allSatisfy({ $0.path.hasPrefix("model.mlmodelc/") }) else { throw DevelopRepairAIError.invalidModel }
        try SemanticInstallationIO.verifyMetadataTree(runtime, files: receipt.files, extraFiles: ["installation.json"])
        return receipt
    }
}

/// This is only an imported, fixed 800px repair interface. It does not advertise
/// the global image-generation, background or outpainting capabilities.
enum DevelopRepairAIModelInterface {
    struct Loaded {
        let model: MLModel
        let imageFormat: OSType
        let outputName: String
    }

    static func load(_ directory: URL) throws -> Loaded {
        do { return try load(directory, computeUnits: .all) }
        catch is CancellationError { throw CancellationError() }
        catch { return try load(directory, computeUnits: .cpuOnly) }
    }

    static func load(_ directory: URL, computeUnits: MLComputeUnits) throws -> Loaded {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = false
        let model = try MLModel(contentsOf: directory, configuration: configuration)
        try Task.checkCancellation()
        let description = model.modelDescription
        guard !description.isUpdatable, Set(description.inputDescriptionsByName.keys) == ["image", "mask"],
              description.outputDescriptionsByName.count == 1,
              let image = description.inputDescriptionsByName["image"]?.imageConstraint,
              let mask = description.inputDescriptionsByName["mask"]?.imageConstraint,
              let output = description.outputDescriptionsByName.values.first, let rgb = output.imageConstraint,
              [image, mask, rgb].allSatisfy({ $0.pixelsWide == 800 && $0.pixelsHigh == 800 }),
              mask.pixelFormatType == kCVPixelFormatType_OneComponent8,
              [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB].contains(image.pixelFormatType),
              [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB].contains(rgb.pixelFormatType) else {
            throw DevelopRepairAIError.invalidModel
        }
        return Loaded(model: model, imageFormat: image.pixelFormatType, outputName: output.name)
    }
}
