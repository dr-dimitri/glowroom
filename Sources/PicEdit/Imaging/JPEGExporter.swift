import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import PicEditCore
import UniformTypeIdentifiers

struct JPEGExportRequest: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let settings: EditSettings
    let options: JPEGExportOptions
    let overwriteExisting: Bool
    let protectedSourceURLs: [URL]
    let protectedDirectoryFamilies: [ManagedDirectoryFamily]

    init(sourceURL: URL, destinationURL: URL, settings: EditSettings, options: JPEGExportOptions,
         overwriteExisting: Bool = false, protectedSourceURLs: [URL] = [],
         protectedDirectoryFamilies: [ManagedDirectoryFamily] = []) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.settings = settings
        self.options = options
        self.overwriteExisting = overwriteExisting
        self.protectedSourceURLs = protectedSourceURLs
        self.protectedDirectoryFamilies = protectedDirectoryFamilies
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
        case .invalidDestination: "Das Exportziel muss eine reguläre Datei in einem vorhandenen Ordner sein. Symbolische Verknüpfungen sind nicht zulässig."
        case .insufficientMemory: "Für diese Original- und Ausgabeauflösung reicht das sichere Export-Speicherbudget nicht aus. Wähle kleinere Ausgabemaße oder einen Rechner mit mehr Arbeitsspeicher."
        case .renderingFailed: "Die JPEG-Ausgabe konnte nicht gerendert werden."
        case .encodingFailed: "Die JPEG-Datei konnte nicht vollständig geschrieben werden."
        case let .fileSystem(code): "Die JPEG-Datei konnte nicht gespeichert werden: \(String(cString: strerror(code)))"
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
    private lazy var context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .priorityRequestLow: true,
        .name: "PicEdit JPEG export"
    ])

    init(memoryBudget: UInt64? = nil, beforePublication: @escaping @Sendable () throws -> Void = {}) {
        // Planning bound for decoded pixels, spatial intermediates, and output.
        // Core Image/ImageIO manage their own internal allocations; this is not
        // an operating-system memory quota. No full-size image cache is retained.
        self.memoryBudget = memoryBudget ?? min(8 * 1_024 * 1_024 * 1_024,
                                               ProcessInfo.processInfo.physicalMemory / 4)
        self.beforePublication = beforePublication
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

            // Capture original inode identities once. A pathname, a symlinked
            // parent, or another hard link must never bypass original protection.
            let targetURL = parent.appendingPathComponent(filename)
            let protectedIdentities = try originalIdentities(request, destination: targetURL)
            try validateDestination(directory: directory, filename: filename,
                                    protectedIdentities: protectedIdentities, overwrite: request.overwriteExisting)
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
            let size = try request.options.outputSize(sourceWidth: orientedWidth, sourceHeight: orientedHeight)
            try validateMemory(sourceWidth: sourceWidth, sourceHeight: sourceHeight, output: size)
            try Task.checkCancellation()

            // Always develop the actual source image at its original dimensions.
            // In particular, ImageIO must not return an embedded RAW/EXIF preview.
            let decodeOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(sourceWidth, sourceHeight),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldAllowFloat: true
            ]
            guard let original = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
                throw JPEGExportError.unsupportedOrDamaged
            }
            guard original.width == orientedWidth, original.height == orientedHeight else {
                throw JPEGExportError.incompleteOriginal
            }
            try Task.checkCancellation()
            defer { context.clearCaches() }
            var image = try EditRenderer.filterGraph(original, settings: request.settings)
            if original.width != size.width || original.height != size.height {
                let horizontal = Double(size.width) / Double(original.width)
                let vertical = Double(size.height) / Double(original.height)
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: vertical, kCIInputAspectRatioKey: horizontal / vertical
                ])
            }
            let extent = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            image = image.cropped(to: extent)
                .composited(over: CIImage(color: .white).cropped(to: extent))
            let colorSpaceName = request.options.colorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3
            guard let colorSpace = CGColorSpace(name: colorSpaceName),
                  let output = context.createCGImage(image, from: extent, format: .RGBA8,
                                                    colorSpace: colorSpace, deferred: false) else {
                throw JPEGExportError.renderingFailed
            }
            try Task.checkCancellation()

            let temporaryName = ".picedit-export-\(UUID().uuidString).jpg"
            let outputFD = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard outputFD >= 0 else { throw JPEGExportError.fileSystem(errno) }
            let sink = JPEGFileSink(descriptor: outputFD)
            defer { unlinkat(directory, temporaryName, 0) }
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
            // Color conversion already happened in Core Image. ImageIO embeds
            // P3's ICC profile; sRGB has the standard EXIF ColorSpace=1 tag.
            CGImageDestinationAddImage(encoder, output, metadata as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { throw JPEGExportError.encodingFailed }
            guard fsync(sink.descriptor) == 0 else { throw JPEGExportError.fileSystem(errno) }
            try Task.checkCancellation()
            // An injected boundary permits deterministic cancellation/failure
            // tests after encoding. Production uses the default empty hook.
            try beforePublication()
            try Task.checkCancellation()
            // Another application may have atomically replaced an imported
            // original while RAW development was running. Refresh identities
            // before an approved replacement instead of trusting old inodes.
            let finalIdentities = request.overwriteExisting
                ? try originalIdentities(request, destination: targetURL) : protectedIdentities
            try validateDestination(directory: directory, filename: filename,
                                    protectedIdentities: finalIdentities, overwrite: request.overwriteExisting)
            try Task.checkCancellation()

            // The commit point is one rename in the pinned parent directory.
            // RENAME_EXCL remains race-safe if another process creates the target
            // after validation. After success, report success even if cancellation
            // arrives: the accepted atomic publication must not be misreported.
            let flags = request.overwriteExisting ? UInt32(0) : UInt32(RENAME_EXCL)
            guard renameatx_np(directory, temporaryName, directory, filename, flags) == 0 else {
                if errno == EEXIST { throw JPEGExportError.destinationExists }
                throw JPEGExportError.fileSystem(errno)
            }
            return JPEGExportResult(url: destination, width: size.width, height: size.height)
        }
    }

    private func originalIdentities(_ request: JPEGExportRequest, destination: URL) throws -> Set<FileIdentity> {
        for family in request.protectedDirectoryFamilies {
            try Task.checkCancellation()
            if ManagedFileProtection.containsDestination(destination, in: family) { throw JPEGExportError.protectedOriginal }
        }
        let canonicalDestination = destination.resolvingSymlinksInPath()
        var identities = Set<FileIdentity>()
        for (index, original) in ([request.sourceURL] + request.protectedSourceURLs).enumerated() {
            if index % 64 == 0 { try Task.checkCancellation() }
            if original.hasDirectoryPath, ManagedFileProtection.containsDestination(destination, in: original) {
                throw JPEGExportError.protectedOriginal
            }
            let canonical = original.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical != canonicalDestination else { throw JPEGExportError.protectedOriginal }
            if let identity = FileIdentity.read(canonical) { identities.insert(identity) }
        }
        return identities
    }

    private func positiveDimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= Double(Int32.max), value.rounded() == value else { return nil }
        return Int(value)
    }

    private func validateMemory(sourceWidth: Int, sourceHeight: Int, output: JPEGPixelSize) throws {
        let source = UInt64(sourceWidth).multipliedReportingOverflow(by: UInt64(sourceHeight))
        let target = UInt64(output.width).multipliedReportingOverflow(by: UInt64(output.height))
        let decoded = source.partialValue.multipliedReportingOverflow(by: 48)
        let rendered = target.partialValue.multipliedReportingOverflow(by: 12)
        let total = decoded.partialValue.addingReportingOverflow(rendered.partialValue)
        guard !source.overflow, !target.overflow, !decoded.overflow, !rendered.overflow,
              !total.overflow, total.partialValue <= memoryBudget else { throw JPEGExportError.insufficientMemory }
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
