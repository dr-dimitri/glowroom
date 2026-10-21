import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import GlowroomCore
import UniformTypeIdentifiers

struct JPEGExportRequest: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let settings: EditSettings
    let options: JPEGExportOptions
    let overwriteExisting: Bool
    let protectedSourceURLs: [URL]
    let protectedDirectoryFamilies: [ManagedDirectoryFamily]
    let catalogProtection: JPEGExportCatalogProtection?

    init(sourceURL: URL, destinationURL: URL, settings: EditSettings, options: JPEGExportOptions,
         overwriteExisting: Bool = false, protectedSourceURLs: [URL] = [],
         protectedDirectoryFamilies: [ManagedDirectoryFamily] = [],
         catalogProtection: JPEGExportCatalogProtection? = nil) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.settings = settings
        self.options = options
        self.overwriteExisting = overwriteExisting
        self.protectedSourceURLs = protectedSourceURLs
        self.protectedDirectoryFamilies = protectedDirectoryFamilies
        self.catalogProtection = catalogProtection
    }
}

struct JPEGExportResult: Equatable, Sendable {
    let url: URL
    let width: Int
    let height: Int
}

enum JPEGExportError: LocalizedError, Equatable {
    case unavailableOriginal
    case unsupportedOrDamaged
    case incompleteOriginal
    case destinationExists
    case protectedOriginal
    case catalogBusy
    case catalogChanged
    case catalogUnavailable
    case invalidDestination
    case insufficientMemory
    case renderingFailed
    case encodingFailed
    case fileSystem(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailableOriginal: "Das Original ist nicht verfügbar oder kann nicht gelesen werden."
        case .unsupportedOrDamaged: "Das Originalformat wird nicht unterstützt oder die Bilddatei ist beschädigt."
        case .incompleteOriginal: "Das Original konnte nicht in seiner vollständigen Auflösung decodiert werden."
        case .destinationExists: "Am gewählten Ziel existiert bereits eine Datei."
        case .protectedOriginal: "Originalbilder und geschützte Anwendungsdateien dürfen durch den Export nicht ersetzt werden. Wähle ein anderes Ziel."
        case .catalogBusy: "Die Bibliothek liest oder ordnet Originalbilder gerade neu. Warte bis zum Abschluss und versuche den Export erneut."
        case .catalogChanged: "Die Bibliothek wurde während der Exportprüfung geändert. Die Zieldatei bleibt erhalten. Versuche den Export erneut."
        case .catalogUnavailable: "Der Originalschutz ist derzeit nicht verfügbar. Behebe zuerst den Bibliotheksfehler und versuche den Export erneut."
        case .invalidDestination: "Das Exportziel muss eine reguläre Datei in einem vorhandenen Ordner sein. Symbolische Verknüpfungen sind nicht zulässig."
        case .insufficientMemory: "Original, Korrekturen und Ausgabe überschreiten das sichere Export-Speicherbudget. Reduziere Korrekturen oder verwende eine kleinere Bildquelle. Kleinere Ausgabemaße helfen nur, wenn Original und Korrekturen bereits in das Budget passen."
        case .renderingFailed: "Die Bildausgabe konnte nicht gerendert werden."
        case .encodingFailed: "Die Exportdatei konnte nicht vollständig geschrieben werden."
        case let .fileSystem(code): "Die Exportdatei konnte nicht gespeichert werden: \(String(cString: strerror(code)))"
        }
    }
}

/// Full-resolution exports run serially away from the MainActor; preview decode,
/// display, and database work remain independent. The lazy Core Image graph keeps
/// its image operations on the system's available GPU/CPU backend until readback.
actor JPEGExporter {
    static let shared = JPEGExporter()

    private let memoryBudget: UInt64
    private let beforePublication: @Sendable () throws -> Void
    private let beforeCatalogPublication: @Sendable () throws -> Void
    private lazy var context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .priorityRequestLow: true,
        .name: "Glowroom JPEG export"
    ])

    init(memoryBudget: UInt64? = nil, beforePublication: @escaping @Sendable () throws -> Void = {},
         beforeCatalogPublication: @escaping @Sendable () throws -> Void = {}) {
        // Planning bound for decoded pixels, spatial intermediates, and output.
        // Core Image/ImageIO manage their own internal allocations; this is not
        // an operating-system memory quota. No full-size image cache is retained.
        self.memoryBudget = memoryBudget ?? min(8 * 1_024 * 1_024 * 1_024,
                                               ProcessInfo.processInfo.physicalMemory / 4)
        self.beforePublication = beforePublication
        self.beforeCatalogPublication = beforeCatalogPublication
    }

    func export(_ request: JPEGExportRequest) throws -> JPEGExportResult {
        try Task.checkCancellation()
        try request.options.validate()
        guard request.sourceURL.isFileURL else { throw JPEGExportError.unavailableOriginal }
        guard request.destinationURL.isFileURL, !request.destinationURL.hasDirectoryPath else {
            throw JPEGExportError.invalidDestination
        }
        let sourceAccess = request.sourceURL.startAccessingSecurityScopedResource()
        let destinationAccess = request.destinationURL.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { request.sourceURL.stopAccessingSecurityScopedResource() }
            if destinationAccess { request.destinationURL.stopAccessingSecurityScopedResource() }
        }
        return try autoreleasepool {
            let destination = request.destinationURL.standardizedFileURL
            let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            let filename = destination.lastPathComponent
            guard !filename.isEmpty, filename != ".", filename != ".." else { throw JPEGExportError.invalidDestination }
            let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else { throw JPEGExportError.fileSystem(errno) }
            defer { close(directory) }

            // Edits remain frozen; protection includes the current durable
            // catalog on every attempt, including an overwrite confirmation.
            let targetURL = parent.appendingPathComponent(filename)
            do {
                let initialProtection = try request.catalogProtection?.snapshot()
                let initialCatalog = try request.catalogProtection?.repository.loadStored()
                let identities = try originalIdentities(request, destination: targetURL, catalog: initialCatalog,
                                                        extra: initialProtection?.protectedSourceURLs ?? [])
                try validateDestination(directory: directory, filename: filename,
                                        protectedIdentities: identities, overwrite: request.overwriteExisting)
            }
            try Task.checkCancellation()

            guard FileManager.default.isReadableFile(atPath: request.sourceURL.path) else {
                throw JPEGExportError.unavailableOriginal
            }
            guard let source = CGImageSourceCreateWithURL(request.sourceURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let sourceWidth = positiveDimension(properties[kCGImagePropertyPixelWidth]),
                let sourceHeight = positiveDimension(properties[kCGImagePropertyPixelHeight]) else {
                throw JPEGExportError.unsupportedOrDamaged
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let swapsAxes = (5...8).contains(orientation)
            let orientedWidth = swapsAxes ? sourceHeight : sourceWidth
            let orientedHeight = swapsAxes ? sourceWidth : sourceHeight
            let developedSize = try DevelopGeometryRenderer.outputSize(width: orientedWidth, height: orientedHeight,
                geometry: request.settings.developGeometry)
            let size = try request.options.outputSize(sourceWidth: developedSize.width, sourceHeight: developedSize.height)
            try validateMemory(sourceWidth: orientedWidth, sourceHeight: orientedHeight, output: size,
                settings: request.settings, format: request.options.format)
            try Task.checkCancellation()

            // Always develop the actual source image at its original dimensions.
            // In particular, ImageIO must not return an embedded RAW/EXIF preview.
            var decodeOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(sourceWidth, sourceHeight),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldAllowFloat: true
            ]
            if request.settings.developColor.hdrEnabled || request.options.format == .heif10HDR {
                decodeOptions[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
            }
            guard let original = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
                throw JPEGExportError.unsupportedOrDamaged
            }
            guard original.width == orientedWidth, original.height == orientedHeight else {
                throw JPEGExportError.incompleteOriginal
            }
            try Task.checkCancellation()
            defer { context.clearCaches() }
            var renderSettings = request.settings
            if request.options.format == .heif10HDR { renderSettings.developColor.hdrEnabled = true }
            var image = try EditRenderer.filterGraph(original, settings: renderSettings)
            if Int(image.extent.width) != size.width || Int(image.extent.height) != size.height {
                let horizontal = Double(size.width) / Double(image.extent.width)
                let vertical = Double(size.height) / Double(image.extent.height)
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: vertical, kCIInputAspectRatioKey: horizontal / vertical
                ])
            }
            let extent = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            image = image.cropped(to: extent)
                .composited(over: CIImage(color: .white).cropped(to: extent))
            try Task.checkCancellation()

            let temporaryName = ".glowroom-export-\(UUID().uuidString).\(request.options.format.fileExtension)"
            let outputFD = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard outputFD >= 0 else { throw JPEGExportError.fileSystem(errno) }
            let sink = JPEGFileSink(descriptor: outputFD)
            defer { unlinkat(directory, temporaryName, 0) }
            let dpi = request.options.pixelsPerInch
            let metadata: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: Double(request.options.quality) / 100,
                kCGImagePropertyOrientation: 1,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifColorSpace: request.options.colorSpace == .sRGB ? 1 : 65_535
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFXResolution: dpi,
                    kCGImagePropertyTIFFYResolution: dpi,
                    kCGImagePropertyTIFFResolutionUnit: 2,
                    kCGImagePropertyTIFFOrientation: 1
                ]
            ]
            switch request.options.format {
            case .jpeg:
                let colorSpaceName = request.options.colorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3
                guard let colorSpace = CGColorSpace(name: colorSpaceName),
                      let output = context.createCGImage(image, from: extent, format: .RGBA8,
                                                        colorSpace: colorSpace, deferred: false) else {
                    throw JPEGExportError.renderingFailed
                }
                let retainedSink = Unmanaged.passRetained(sink)
                var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
                    guard let info else { return 0 }
                    return Unmanaged<JPEGFileSink>.fromOpaque(info).takeUnretainedValue().write(bytes, count: count)
                }, releaseConsumer: { info in
                    if let info { Unmanaged<JPEGFileSink>.fromOpaque(info).release() }
                })
                guard let consumer = CGDataConsumer(info: retainedSink.toOpaque(), cbks: &callbacks) else {
                    retainedSink.release()
                    throw JPEGExportError.encodingFailed
                }
                guard let encoder = CGImageDestinationCreateWithDataConsumer(consumer, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw JPEGExportError.encodingFailed
                }
                // JPEG retains its established 8-bit SDR profile/metadata path.
                CGImageDestinationAddImage(encoder, output, metadata as CFDictionary)
                guard CGImageDestinationFinalize(encoder) else { throw JPEGExportError.encodingFailed }
            case .heif10HDR:
                guard let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else {
                    throw JPEGExportError.renderingFailed
                }
                let encoded: Data
                do {
                    encoded = try context.heif10Representation(of: image.settingProperties([
                        kCGImagePropertyOrientation as String: 1,
                        kCGImagePropertyDPIWidth as String: dpi,
                        kCGImagePropertyDPIHeight as String: dpi
                    ]), colorSpace: colorSpace, options: [
                        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Double(request.options.quality) / 100
                    ])
                } catch { throw JPEGExportError.encodingFailed }
                try Task.checkCancellation()
                // Core Image's 10-bit encoder returns Data. Write only through
                // the already-exclusive file descriptor, then use exactly the
                // same protected atomic publication as the streaming JPEG path.
                let count = encoded.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return 0 }
                    return sink.write(base, count: bytes.count)
                }
                guard !encoded.isEmpty, count == encoded.count else { throw JPEGExportError.encodingFailed }
            }
            guard fsync(sink.descriptor) == 0 else { throw JPEGExportError.fileSystem(errno) }
            try Task.checkCancellation()
            // An injected boundary permits deterministic cancellation/failure
            // tests after encoding. Production uses the default empty hook.
            try beforePublication()
            try Task.checkCancellation()
            // Refresh both catalog membership and original inode identities.
            // The native catalog lock excludes cooperative publishers through
            // rename; the tiny admission lock excludes an import accepted after
            // this snapshot. Neither lock spans decoding/rendering or an await.
            let finalProtection = try request.catalogProtection?.snapshot()
            let finalCatalog = try request.catalogProtection?.repository.loadStored()
            let finalIdentities = try originalIdentities(request, destination: targetURL, catalog: finalCatalog,
                                                         extra: finalProtection?.protectedSourceURLs ?? [])
            try beforeCatalogPublication()
            func publish() throws {
                try validateDestination(directory: directory, filename: filename,
                                        protectedIdentities: finalIdentities, overwrite: request.overwriteExisting)
                try Task.checkCancellation()
                let flags = request.overwriteExisting ? UInt32(0) : UInt32(RENAME_EXCL)
                guard renameatx_np(directory, temporaryName, directory, filename, flags) == 0 else {
                    if errno == EEXIST { throw JPEGExportError.destinationExists }
                    throw JPEGExportError.fileSystem(errno)
                }
            }
            if let protection = request.catalogProtection, let finalCatalog, let finalProtection {
                try protection.repository.withPublicationLock { actual in
                    guard actual == finalCatalog.reference else { throw JPEGExportError.catalogChanged }
                    try protection.withPublication(generation: finalProtection.generation, publish)
                }
            } else {
                try publish()
            }
            // Rename is the commit point, even if cancellation arrives now.
            return JPEGExportResult(url: destination, width: size.width, height: size.height)
        }
    }

    private func originalIdentities(_ request: JPEGExportRequest, destination: URL,
                                    catalog: StoredLibraryCatalog? = nil, extra: [URL] = []) throws -> Set<FileIdentity> {
        for family in request.protectedDirectoryFamilies {
            try Task.checkCancellation()
            if ManagedFileProtection.containsDestination(destination, in: family) { throw JPEGExportError.protectedOriginal }
        }
        let canonicalDestination = destination.resolvingSymlinksInPath()
        var identities = Set<FileIdentity>()
        var index = 0
        func include(_ original: URL) throws {
            if index % 64 == 0 { try Task.checkCancellation() }
            index += 1
            if original.hasDirectoryPath, ManagedFileProtection.containsDestination(destination, in: original) {
                throw JPEGExportError.protectedOriginal
            }
            let canonical = original.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical != canonicalDestination else { throw JPEGExportError.protectedOriginal }
            if let identity = FileIdentity.read(canonical) { identities.insert(identity) }
        }
        try include(request.sourceURL)
        for original in request.protectedSourceURLs { try include(original) }
        for original in extra { try include(original) }
        if let catalog { for asset in catalog.catalog.assets { try include(asset.fileURL) } }
        return identities
    }

    private func positiveDimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= Double(Int32.max), value.rounded() == value else { return nil }
        return Int(value)
    }

    private func validateMemory(sourceWidth: Int, sourceHeight: Int, output: JPEGPixelSize, settings: EditSettings,
                                format: JPEGExportFormat) throws {
        let source = UInt64(sourceWidth).multipliedReportingOverflow(by: UInt64(sourceHeight))
        let target = UInt64(output.width).multipliedReportingOverflow(by: UInt64(output.height))
        let decoded = source.partialValue.multipliedReportingOverflow(
            by: 48 + DevelopSharpening.additionalBytesPerPixel(settings: settings))
        // HEIF additionally retains the encoder's bounded returned Data buffer.
        let rendered = target.partialValue.multipliedReportingOverflow(by: format == .jpeg ? 12 : 32)
        let base = decoded.partialValue.addingReportingOverflow(rendered.partialValue)
        guard let local = LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: settings.localAdjustments,
            width: sourceWidth, height: sourceHeight,
            additionalRenderCount: DevelopGeometryRenderer.replacementCount(in: settings.developGeometry)) else { throw JPEGExportError.insufficientMemory }
        guard let geometry = DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: settings.developGeometry,
            width: sourceWidth, height: sourceHeight,
            replacementColorBytesPerPixel: EditRenderer.replacementColorBytesPerPixel(settings: settings)) else { throw JPEGExportError.insufficientMemory }
        let additional = local.addingReportingOverflow(geometry)
        let total = base.partialValue.addingReportingOverflow(additional.partialValue)
        guard !source.overflow, !target.overflow, !decoded.overflow, !rendered.overflow,
              !base.overflow, !additional.overflow, !total.overflow, total.partialValue <= memoryBudget else { throw JPEGExportError.insufficientMemory }
    }

    private func validateDestination(directory: Int32, filename: String, protectedIdentities: Set<FileIdentity>, overwrite: Bool) throws {
        var metadata = stat()
        if fstatat(directory, filename, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw JPEGExportError.fileSystem(errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw JPEGExportError.invalidDestination }
        guard !protectedIdentities.contains(FileIdentity(metadata)) else { throw JPEGExportError.protectedOriginal }
        guard overwrite else { throw JPEGExportError.destinationExists }
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ metadata: stat) { device = metadata.st_dev; inode = metadata.st_ino }
        static func read(_ url: URL) -> Self? {
            var metadata = stat()
            guard stat(url.path, &metadata) == 0 else { return nil }
            return Self(metadata)
        }
    }
}

/// A streaming ImageIO destination avoids retaining an additional JPEG-sized
/// Data buffer. Ownership follows the Core Graphics data consumer callbacks.
private final class JPEGFileSink {
    let descriptor: Int32
    private let lock = NSLock()
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    func write(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var written = 0
        while written < count {
            let result = Darwin.write(descriptor, bytes.advanced(by: written), count - written)
            if result < 0 {
                if errno == EINTR { continue }
                return written
            }
            if result == 0 { return written }
            written += result
        }
        return written
    }
}
