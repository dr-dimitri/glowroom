import AppKit
import Combine
import Foundation
import PicEditCore

/// Owns one export from the captured edit settings through the final filesystem
/// result. Cancellation keeps this lifecycle open until the exporter returns.
@MainActor
final class JPEGExportModel: ObservableObject {
    typealias ExportOperation = @Sendable (JPEGExportRequest) async throws -> JPEGExportResult

    @Published private(set) var isPresented = false
    @Published private(set) var isExporting = false
    @Published private(set) var isCancelling = false
    @Published private(set) var result: JPEGExportResult?
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
    }
    private var snapshot: Snapshot?
    private var operationID = UUID()
    private var exportTask: Task<Void, Never>?
    private var pendingOverwrite: JPEGExportRequest?
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

    var sourceName: String { snapshot?.name ?? "" }
    var sourceDimensions: String {
        guard let snapshot, snapshot.width > 0, snapshot.height > 0 else { return "Originalgröße wird beim Export ermittelt" }
        return "\(snapshot.width) × \(snapshot.height) Pixel"
    }
    var estimatedSize: JPEGPixelSize? {
        guard let snapshot, snapshot.width > 0, snapshot.height > 0, let options = try? makeOptions() else { return nil }
        return try? options.outputSize(sourceWidth: snapshot.width, sourceHeight: snapshot.height)
    }
    var overwriteFilename: String { pendingOverwrite?.destinationURL.lastPathComponent ?? "" }
    var canExport: Bool {
        isPresented && snapshot != nil && !isExporting && pendingOverwrite == nil && !needsOverwriteConfirmation && result == nil && validationMessage == nil
    }
    var validationMessage: String? {
        guard snapshot != nil else { return "Wähle ein Foto für den Export aus." }
        do {
            _ = try validatedFilename()
            guard destinationDirectory.isFileURL else { throw InputError.message("Wähle einen lokalen Zielordner aus.") }
            let options = try makeOptions()
            if let snapshot, snapshot.width > 0, snapshot.height > 0 {
                _ = try options.outputSize(sourceWidth: snapshot.width, sourceHeight: snapshot.height)
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func present(asset: PhotoAsset, settings: EditSettings, protectedSourceURLs: [URL] = []) {
        guard !isExporting else { return }
        operationID = UUID()
        snapshot = Snapshot(sourceURL: asset.fileURL, name: asset.fileName,
                            width: asset.pixelWidth, height: asset.pixelHeight,
                            settings: settings.normalized, protectedSourceURLs: protectedSourceURLs)
        filename = asset.fileURL.deletingPathExtension().lastPathComponent + "-bearbeitet.jpg"
        result = nil
        errorMessage = nil
        pendingOverwrite = nil
        needsOverwriteConfirmation = false
        isCancelling = false
        isPresented = true
    }

    func chooseDirectory() {
        guard isPresented, !isExporting else { return }
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
        guard isPresented, !isExporting, pendingOverwrite == nil, !needsOverwriteConfirmation, result == nil, let snapshot else { return }
        do {
            if let message = validationMessage { throw InputError.message(message) }
            let request = JPEGExportRequest(sourceURL: snapshot.sourceURL,
                destinationURL: destinationDirectory.appendingPathComponent(try validatedFilename()),
                settings: snapshot.settings, options: try makeOptions(), protectedSourceURLs: snapshot.protectedSourceURLs)
            savePreferences(request.options)
            begin(request)
        } catch { errorMessage = error.localizedDescription }
    }

    func confirmOverwrite() {
        guard !isExporting, let request = pendingOverwrite else { return }
        pendingOverwrite = nil
        needsOverwriteConfirmation = false
        // Use the exact destination, options and edit snapshot shown in the
        // confirmation, even if another binding changed while it was displayed.
        begin(JPEGExportRequest(sourceURL: request.sourceURL, destinationURL: request.destinationURL,
            settings: request.settings, options: request.options, overwriteExisting: true,
            protectedSourceURLs: request.protectedSourceURLs))
    }

    // SwiftUI may dismiss the presentation binding before invoking a button.
    // Retain the frozen request until that button accepts or declines it.
    func dismissOverwritePrompt() { needsOverwriteConfirmation = false }

    func declineOverwrite() {
        guard !isExporting else { return }
        pendingOverwrite = nil
        needsOverwriteConfirmation = false
    }

    func cancel() {
        if isExporting {
            guard !isCancelling else { return }
            isCancelling = true
            exportTask?.cancel()
        } else {
            operationID = UUID()
            pendingOverwrite = nil
            needsOverwriteConfirmation = false
            isPresented = false
        }
    }

    func revealResult() {
        guard let result else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    private func begin(_ request: JPEGExportRequest) {
        guard isPresented, !isExporting else { return }
        let generation = operationID
        let export = exportOperation
        isExporting = true
        isCancelling = false
        errorMessage = nil
        exportTask = Task { [weak self] in
            let directory = request.destinationURL.deletingLastPathComponent()
            let access = directory.startAccessingSecurityScopedResource()
            defer { if access { directory.stopAccessingSecurityScopedResource() } }
            let completion: Result<JPEGExportResult, Error>
            do { completion = .success(try await export(request)) }
            catch { completion = .failure(error) }
            guard let self, self.operationID == generation else { return }
            self.exportTask = nil
            self.isExporting = false
            let cancellationRequested = self.isCancelling
            self.isCancelling = false
            switch completion {
            case let .success(result):
                // A cancellation arriving after the atomic commit may be too
                // late. Show the actual successful result rather than hide it.
                self.result = result
            case .failure(is CancellationError):
                self.isPresented = false
            case .failure(JPEGExportError.destinationExists):
                if cancellationRequested { self.isPresented = false }
                else {
                    self.pendingOverwrite = request
                    self.needsOverwriteConfirmation = true
                }
            case let .failure(error):
                self.errorMessage = error.localizedDescription
            }
        }
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
