import AppKit
import Combine
import Foundation
import PicEditCore

/// Owns exports from captured edit settings through their final filesystem
/// results. Cancellation keeps this lifecycle open until the exporter returns.
@MainActor
final class JPEGExportModel: ObservableObject {
    typealias ExportOperation = @Sendable (JPEGExportRequest) async throws -> JPEGExportResult

    @Published private(set) var isPresented = false
    @Published private(set) var isExporting = false
    @Published private(set) var isCancelling = false
    @Published private(set) var result: JPEGExportResult?
    @Published private(set) var results: [JPEGExportResult] = []
    @Published private(set) var currentFilename = ""
    @Published private(set) var hasPausedBatch = false
    @Published private(set) var wasCancelled = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsOverwriteConfirmation = false
    @Published var destinationDirectory: URL
    @Published var filename = ""
    @Published var colorSpace: JPEGExportColorSpace = .sRGB
    @Published var qualityText = "90"
    @Published var sizeMode: JPEGExportSizeMode = .original
    @Published var longEdgeText = "2400"
    @Published var widthText = "2400"
    @Published var heightText = "1600"
    @Published var resolutionText = "300"
    @Published var allowUpscaling = false

    private struct Snapshot {
        let sourceURL: URL
        let name: String
        let width: Int
        let height: Int
        let settings: EditSettings
        let protectedSourceURLs: [URL]
        let protectedDirectoryFamilies: [ManagedDirectoryFamily]
        let exportFilename: String
    }
    private var snapshots: [Snapshot] = []
    private var operationID = UUID()
    private var exportTask: Task<Void, Never>?
    private var pendingOverwrite: JPEGExportRequest?
    private var remainingRequests: [JPEGExportRequest] = []
    private let exportOperation: ExportOperation
    private let preferences: UserDefaults?
    private let preferencePrefix = "JPEGExport."

    init(preferences: UserDefaults? = .standard, export: ExportOperation? = nil) {
        self.preferences = preferences
        exportOperation = export ?? { try await JPEGExporter.shared.export($0) }
        destinationDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures", isDirectory: true)
        if let preferences {
            let prefix = preferencePrefix
            if let path = preferences.string(forKey: prefix + "directory"), !path.isEmpty {
                destinationDirectory = URL(fileURLWithPath: path, isDirectory: true)
            }
            if let value = preferences.string(forKey: prefix + "colorSpace"), let stored = JPEGExportColorSpace(rawValue: value) {
                colorSpace = stored
            }
            if let value = preferences.string(forKey: prefix + "sizeMode"), let stored = JPEGExportSizeMode(rawValue: value) {
                sizeMode = stored
            }
            qualityText = Self.storedInteger(preferences, key: prefix + "quality", fallback: 90, range: 0...100)
            longEdgeText = Self.storedInteger(preferences, key: prefix + "longEdge", fallback: 2400, range: 1...65535)
            widthText = Self.storedInteger(preferences, key: prefix + "width", fallback: 2400, range: 1...65535)
            heightText = Self.storedInteger(preferences, key: prefix + "height", fallback: 1600, range: 1...65535)
            resolutionText = Self.storedInteger(preferences, key: prefix + "resolution", fallback: 300, range: 1...1200)
            allowUpscaling = preferences.bool(forKey: prefix + "allowUpscaling")
        }
    }

    deinit { exportTask?.cancel() }

    var sourceCount: Int { snapshots.count }
    var isBatch: Bool { sourceCount > 1 }
    var completedCount: Int { results.count }
    var sourceName: String { isBatch ? "\(sourceCount) Bilder ausgewählt" : snapshots.first?.name ?? "" }
    var sourceDimensions: String {
        guard !isBatch else { return "Individuelle Originalgrößen" }
        guard let snapshot = snapshots.first, snapshot.width > 0, snapshot.height > 0 else { return "Originalgröße wird beim Export ermittelt" }
        return "\(snapshot.width) × \(snapshot.height) Pixel"
    }
    var estimatedSize: JPEGPixelSize? {
        guard !isBatch, let snapshot = snapshots.first, snapshot.width > 0, snapshot.height > 0,
              let options = try? makeOptions() else { return nil }
        return try? options.outputSize(sourceWidth: snapshot.width, sourceHeight: snapshot.height)
    }
    var overwriteFilename: String { pendingOverwrite?.destinationURL.lastPathComponent ?? "" }
    var canExport: Bool {
        isPresented && !snapshots.isEmpty && !isExporting && pendingOverwrite == nil && !needsOverwriteConfirmation && result == nil && validationMessage == nil
    }
    var validationMessage: String? {
        guard !snapshots.isEmpty else { return "Wähle ein Foto für den Export aus." }
        // Retrying a paused batch uses its accepted options and destinations.
        guard !hasPausedBatch else { return nil }
        do {
            if !isBatch { _ = try validatedFilename() }
            guard destinationDirectory.isFileURL else { throw InputError.message("Wähle einen lokalen Zielordner aus.") }
            let options = try makeOptions()
            for snapshot in snapshots where snapshot.width > 0 && snapshot.height > 0 {
                _ = try options.outputSize(sourceWidth: snapshot.width, sourceHeight: snapshot.height)
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func present(asset: PhotoAsset, settings: EditSettings, protectedSourceURLs: [URL] = [],
                 protectedDirectoryFamilies: [ManagedDirectoryFamily] = []) {
        present(assets: [asset], settingsByAsset: [asset.id: settings], protectedSourceURLs: protectedSourceURLs,
                protectedDirectoryFamilies: protectedDirectoryFamilies)
    }

    func present(assets: [PhotoAsset], settingsByAsset: [String: EditSettings], protectedSourceURLs: [URL] = [],
                 protectedDirectoryFamilies: [ManagedDirectoryFamily] = []) {
        guard !isExporting, !assets.isEmpty else { return }
        operationID = UUID()
        var filenames = Set<String>()
        snapshots = assets.map { asset in
            let base = Self.exportBasename(for: asset.fileURL)
            var name = base + ".jpg"
            var suffix = 2
            // Reserve names case-insensitively, including Unicode normalization,
            // so different originals cannot replace each other on common volumes.
            while !filenames.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                name = "\(base)-\(suffix).jpg"
                suffix += 1
            }
            return Snapshot(sourceURL: asset.fileURL, name: asset.fileName,
                width: asset.pixelWidth, height: asset.pixelHeight,
                settings: (settingsByAsset[asset.id] ?? .neutral).normalized,
                protectedSourceURLs: protectedSourceURLs, protectedDirectoryFamilies: protectedDirectoryFamilies, exportFilename: name)
        }
        filename = snapshots[0].exportFilename
        result = nil
        results = []
        currentFilename = ""
        errorMessage = nil
        pendingOverwrite = nil
        remainingRequests = []
        needsOverwriteConfirmation = false
        hasPausedBatch = false
        wasCancelled = false
        isCancelling = false
        isPresented = true
    }

    func chooseDirectory() {
        guard isPresented, !isExporting, !hasPausedBatch, pendingOverwrite == nil else { return }
        let generation = operationID
        let panel = NSOpenPanel()
        panel.title = "Exportordner auswählen"
        panel.prompt = "Auswählen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationDirectory
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  self.isPresented, !self.isExporting, self.operationID == generation else { return }
            self.destinationDirectory = url
        }
    }

    func startExport() {
        guard isPresented, !isExporting, pendingOverwrite == nil, !needsOverwriteConfirmation,
              result == nil, !snapshots.isEmpty else { return }
        if hasPausedBatch {
            let requests = remainingRequests
            remainingRequests = []
            begin(requests)
            return
        }
        do {
            if let message = validationMessage { throw InputError.message(message) }
            let options = try makeOptions()
            let singleFilename = isBatch ? nil : try validatedFilename()
            let requests = snapshots.map { snapshot in
                JPEGExportRequest(sourceURL: snapshot.sourceURL,
                    destinationURL: destinationDirectory.appendingPathComponent(singleFilename ?? snapshot.exportFilename),
                    settings: snapshot.settings, options: options, protectedSourceURLs: snapshot.protectedSourceURLs,
                    protectedDirectoryFamilies: snapshot.protectedDirectoryFamilies)
            }
            savePreferences(options)
            results = []
            begin(requests)
        } catch { errorMessage = error.localizedDescription }
    }

    func confirmOverwrite() {
        guard !isExporting, let request = pendingOverwrite else { return }
        pendingOverwrite = nil
        needsOverwriteConfirmation = false
        // Use the exact destination, options and edits shown in the confirmation,
        // and retain the frozen remainder of a batch across each confirmation.
        let retry = JPEGExportRequest(sourceURL: request.sourceURL, destinationURL: request.destinationURL,
            settings: request.settings, options: request.options, overwriteExisting: true,
            protectedSourceURLs: request.protectedSourceURLs, protectedDirectoryFamilies: request.protectedDirectoryFamilies)
        let requests = [retry] + remainingRequests
        remainingRequests = []
        begin(requests)
    }

    // SwiftUI may dismiss the presentation binding before invoking a button.
    // Retain the frozen request until that button accepts or declines it.
    func dismissOverwritePrompt() { needsOverwriteConfirmation = false }

    func declineOverwrite() {
        guard !isExporting else { return }
        pendingOverwrite = nil
        remainingRequests = []
        needsOverwriteConfirmation = false
        hasPausedBatch = false
        if !results.isEmpty {
            wasCancelled = true
            result = results.last
        }
    }

    func cancel() {
        if isExporting {
            guard !isCancelling else { return }
            isCancelling = true
            exportTask?.cancel()
        } else {
            operationID = UUID()
            pendingOverwrite = nil
            remainingRequests = []
            needsOverwriteConfirmation = false
            hasPausedBatch = false
            if result == nil, !results.isEmpty {
                wasCancelled = true
                result = results.last
            } else {
                isPresented = false
            }
        }
    }

    func revealResult() {
        guard !results.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(results.map(\.url))
    }

    private func begin(_ requests: [JPEGExportRequest]) {
        guard isPresented, !isExporting, !requests.isEmpty else { return }
        let generation = operationID
        let export = exportOperation
        isExporting = true
        isCancelling = false
        hasPausedBatch = false
        errorMessage = nil
        currentFilename = requests[0].destinationURL.lastPathComponent
        exportTask = Task { [weak self] in
            let directory = requests[0].destinationURL.deletingLastPathComponent()
            let access = directory.startAccessingSecurityScopedResource()
            defer { if access { directory.stopAccessingSecurityScopedResource() } }
            // Full-size decode/render remains sequential to bound memory; the
            // exporter already serializes its reusable Core Image context.
            for (index, request) in requests.enumerated() {
                guard let self, self.operationID == generation else { return }
                self.currentFilename = request.destinationURL.lastPathComponent
                do {
                    try Task.checkCancellation()
                    let output = try await export(request)
                    // An atomic publication may win a cancellation race. Record
                    // the real file before stopping the remainder of the batch.
                    self.results.append(output)
                    if Task.isCancelled {
                        self.finishCancellation()
                        return
                    }
                } catch {
                    self.exportTask = nil
                    self.isExporting = false
                    let cancellationRequested = self.isCancelling || Task.isCancelled
                    self.isCancelling = false
                    if error is CancellationError || cancellationRequested {
                        self.finishCancellation()
                    } else if let exportError = error as? JPEGExportError, exportError == .destinationExists {
                        self.pendingOverwrite = request
                        self.remainingRequests = Array(requests.dropFirst(index + 1))
                        self.needsOverwriteConfirmation = true
                    } else {
                        self.errorMessage = error.localizedDescription
                        if self.isBatch {
                            self.remainingRequests = Array(requests.dropFirst(index))
                            self.hasPausedBatch = true
                        }
                    }
                    return
                }
            }
            guard let self, self.operationID == generation else { return }
            self.exportTask = nil
            self.isExporting = false
            self.isCancelling = false
            self.result = self.results.last
        }
    }

    private func finishCancellation() {
        exportTask = nil
        isExporting = false
        isCancelling = false
        pendingOverwrite = nil
        remainingRequests = []
        hasPausedBatch = false
        needsOverwriteConfirmation = false
        wasCancelled = completedCount < sourceCount
        if let last = results.last { result = last }
        else { isPresented = false }
    }

    private static func exportBasename(for url: URL) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let original = url.deletingPathExtension().lastPathComponent
        let safe = original.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Reserve space beneath common 255-byte filename limits for the edit
        // marker, JPEG extension and collision suffix; never split a character.
        var shortened = ""
        var byteCount = 0
        for character in safe {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= 220 else { break }
            shortened.append(character)
            byteCount += bytes
        }
        shortened = shortened.trimmingCharacters(in: .whitespacesAndNewlines)
        return (shortened.isEmpty ? "Bild" : shortened) + "-bearbeitet"
    }

    private func validatedFilename() throws -> String {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (name as NSString).pathExtension.lowercased()
        guard !name.isEmpty, name != ".", name != "..", name != ".jpg", name != ".jpeg",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              ext == "jpg" || ext == "jpeg" else {
            throw InputError.message("Gib einen Dateinamen mit .jpg oder .jpeg ein, ohne Pfadangaben.")
        }
        return name
    }

    private func makeOptions() throws -> JPEGExportOptions {
        func integer(_ text: String, name: String, range: ClosedRange<Int>) throws -> Int {
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
                throw InputError.message("\(name): Gib eine ganze Zahl von \(range.lowerBound) bis \(range.upperBound) ein.")
            }
            return value
        }
        func inactive(_ text: String, fallback: Int) -> Int {
            guard let value = Int(text), (1...65535).contains(value) else { return fallback }
            return value
        }
        return JPEGExportOptions(colorSpace: colorSpace,
            quality: try integer(qualityText, name: "Qualität", range: 0...100), sizeMode: sizeMode,
            longEdge: sizeMode == .longEdge ? try integer(longEdgeText, name: "Lange Kante", range: 1...65535) : inactive(longEdgeText, fallback: 2400),
            width: sizeMode == .fit ? try integer(widthText, name: "Breite", range: 1...65535) : inactive(widthText, fallback: 2400),
            height: sizeMode == .fit ? try integer(heightText, name: "Höhe", range: 1...65535) : inactive(heightText, fallback: 1600),
            pixelsPerInch: try integer(resolutionText, name: "Auflösung", range: 1...1200), allowUpscaling: allowUpscaling)
    }

    private func savePreferences(_ options: JPEGExportOptions) {
        guard let preferences else { return }
        preferences.set(destinationDirectory.path, forKey: preferencePrefix + "directory")
        preferences.set(options.colorSpace.rawValue, forKey: preferencePrefix + "colorSpace")
        preferences.set(options.sizeMode.rawValue, forKey: preferencePrefix + "sizeMode")
        for (key, value) in [("quality", options.quality), ("longEdge", options.longEdge), ("width", options.width),
                             ("height", options.height), ("resolution", options.pixelsPerInch)] {
            preferences.set(value, forKey: preferencePrefix + key)
        }
        preferences.set(options.allowUpscaling, forKey: preferencePrefix + "allowUpscaling")
    }

    private static func storedInteger(_ preferences: UserDefaults, key: String, fallback: Int, range: ClosedRange<Int>) -> String {
        guard preferences.object(forKey: key) != nil else { return String(fallback) }
        let value = preferences.integer(forKey: key)
        return String(range.contains(value) ? value : fallback)
    }

    private enum InputError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}
