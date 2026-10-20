import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FolderScanError: LocalizedError {
    case unavailableFolder(URL)
    case notDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .unavailableFolder(let url):
            return "Der Ordner „\(url.lastPathComponent)“ ist nicht verfügbar oder kann nicht gelesen werden."
        case .notDirectory(let url):
            return "„\(url.lastPathComponent)“ ist kein Ordner."
        }
    }
}

public struct FolderScanner: Sendable {
    typealias AssetReader = @Sendable (URL, UUID) async throws -> PhotoAsset?

    private let maximumConcurrentMetadataReads: Int
    private let assetReader: AssetReader

    public init(maximumConcurrentMetadataReads: Int = 4) {
        // Validation can decode camera RAW data even for a small thumbnail. Keep the
        // worker count modest, with at least 1 GiB of system memory per active reader.
        let memoryLimit = max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
        self.maximumConcurrentMetadataReads = max(1, min(
            maximumConcurrentMetadataReads, 4, ProcessInfo.processInfo.activeProcessorCount, memoryLimit
        ))
        self.assetReader = { url, folderID in
            try autoreleasepool { try Self.readAsset(at: url, folderID: folderID) }
        }
    }

    init(maximumConcurrentMetadataReads: Int, assetReader: @escaping AssetReader) {
        self.maximumConcurrentMetadataReads = max(1, maximumConcurrentMetadataReads)
        self.assetReader = assetReader
    }

    public func scan(folder: LibraryFolder) async throws -> ScanResult {
        try await scan(folder: folder, includeImages: true)
    }

    public func scanSubdirectories(folder: LibraryFolder) async throws -> [String] {
        try await scan(folder: folder, includeImages: false).subdirectoryPaths
    }

    private enum ReadResult: Sendable {
        case asset(PhotoAsset)
        case skipped(URL)
    }

    private func scan(folder: LibraryFolder, includeImages: Bool) async throws -> ScanResult {
        try Task.checkCancellation()
        let manager = FileManager.default
        let root = folder.url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              manager.isReadableFile(atPath: root.path) else {
            throw FolderScanError.unavailableFolder(root)
        }
        guard isDirectory.boolValue else { throw FolderScanError.notDirectory(root) }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey
        ]
        var inaccessibleURL: URL?
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                inaccessibleURL = url
                return false
            }
        ) else { throw FolderScanError.unavailableFolder(root) }

        var assets: [PhotoAsset] = []
        var skippedURLs: [URL] = []
        var seenPaths: Set<String> = []
        var subdirectoryPaths: Set<String> = []
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let supportedExtensions = includeImages ? Self.supportedExtensions : []
        let assetReader = self.assetReader
        try await withThrowingTaskGroup(of: ReadResult.self) { group in
            var pendingReads = 0
            func collect(_ result: ReadResult) {
                switch result {
                case .asset(let asset): assets.append(asset)
                case .skipped(let url): skippedURLs.append(url)
                }
            }
            // The enumerator and its path sets have one owner. Independent metadata
            // reads overlap enumeration, with backpressure instead of a task per photo.
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let candidate: URL? = autoreleasepool {
                    guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
                        inaccessibleURL = url
                        return nil
                    }
                    // Following directory links may leave the chosen folder or create a cycle.
                    // File links are also excluded, so imports do not depend on external paths.
                    if values.isSymbolicLink == true {
                        enumerator.skipDescendants()
                        return nil
                    }
                    if values.isDirectory == true {
                        if values.isPackage == true {
                            enumerator.skipDescendants()
                            return nil
                        }
                        let path = url.standardizedFileURL.path
                        if path.hasPrefix(rootPrefix) {
                            let relativePath = String(path.dropFirst(rootPrefix.count))
                            if !relativePath.isEmpty { subdirectoryPaths.insert(relativePath) }
                        }
                        return nil
                    }
                    guard includeImages, values.isRegularFile == true else { return nil }
                    let ext = url.pathExtension.lowercased()
                    guard supportedExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .image) == true else {
                        return nil
                    }
                    let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
                    guard canonicalURL.path.hasPrefix(rootPrefix), seenPaths.insert(canonicalURL.path).inserted else {
                        return nil
                    }
                    return canonicalURL
                }
                if let inaccessibleURL { throw FolderScanError.unavailableFolder(inaccessibleURL) }
                guard let candidate else { continue }
                group.addTask {
                    try Task.checkCancellation()
                    let asset = try await assetReader(candidate, folder.id)
                    try Task.checkCancellation()
                    return asset.map(ReadResult.asset) ?? .skipped(candidate)
                }
                pendingReads += 1
                if pendingReads == maximumConcurrentMetadataReads, let result = try await group.next() {
                    collect(result)
                    pendingReads -= 1
                }
            }
            if let inaccessibleURL { throw FolderScanError.unavailableFolder(inaccessibleURL) }
            for try await result in group { collect(result) }
        }
        try Task.checkCancellation()
        guard manager.isReadableFile(atPath: root.path) else { throw FolderScanError.unavailableFolder(root) }
        // Completion order is deliberately ignored, including for corrupt-image reports.
        assets.sort { Self.pathPrecedes($0.fileURL.path, $1.fileURL.path) }
        skippedURLs.sort { Self.pathPrecedes($0.path, $1.path) }
        let sortedDirectories = subdirectoryPaths.sorted(by: Self.pathPrecedes)
        return ScanResult(assets: assets, skippedFiles: skippedURLs.count, skippedURLs: skippedURLs, subdirectoryPaths: sortedDirectories)
    }

    private static func pathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
    }

    private static let supportedExtensions: Set<String> = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        let registeredExtensions = Set(identifiers.flatMap { identifier in
            UTType(identifier)?.tags[.filenameExtension] ?? []
        }.map { $0.lowercased() })
        // Launch Services may not expose its type registry in helper processes or restricted
        // environments. Keep common raster and camera formats discoverable there as well;
        // ImageIO still validates actual support and image data before accepting a file.
        let commonExtensions: Set<String> = [
            "jpg", "jpeg", "jpe", "jfif", "png", "apng", "heic", "heif", "hif", "avif",
            "tif", "tiff", "gif", "bmp", "dib", "webp", "jp2", "j2k", "jpf", "jpx",
            "ico", "icns", "pict", "pct", "pic", "psd", "sgi", "tga", "exr", "hdr", "svg",
            "3fr", "arw", "bay", "cap", "cr2", "cr3", "crw", "dcs", "dcr", "dng", "drf",
            "eip", "erf", "fff", "gpr", "iiq", "k25", "kdc", "mdc", "mef", "mos", "mrw",
            "nef", "nrw", "obm", "orf", "pef", "ptx", "pxn", "raf", "raw", "rw2", "rwl",
            "rwz", "sr2", "srf", "srw", "x3f"
        ]
        return registeredExtensions.union(commonExtensions)
    }()

    private static func readAsset(at url: URL, folderID: UUID) throws -> PhotoAsset? {
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]) else {
            throw FolderScanError.unavailableFolder(url)
        }
        let asset = try readAsset(at: url, folderID: folderID, values: values)
        if asset == nil, !manager.fileExists(atPath: url.path) {
            throw FolderScanError.unavailableFolder(url)
        }
        return asset
    }

    private static func readAsset(at url: URL, folderID: UUID, values: URLResourceValues) throws -> PhotoAsset? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }

        try Task.checkCancellation()
        // A header can still be readable when pixel data is corrupt. A small decode validates it
        // without allocating the full resolution image (especially important for camera RAW).
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let rotatesDimensions = (5...8).contains(orientation)
        let modifiedAt = values.contentModificationDate ?? values.creationDate ?? .distantPast
        let createdAt = values.creationDate ?? modifiedAt
        let aperture = number(exif[kCGImagePropertyExifFNumber as String]).map { "ƒ/\(decimal($0))" }
        let focalLength = number(exif[kCGImagePropertyExifFocalLength as String]).map { "\(decimal($0)) mm" }
        let exposure = number(exif[kCGImagePropertyExifExposureTime as String]).flatMap(exposureDescription)
        let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
        let iso = isoValues?.first.map { $0.stringValue }
        let captureDate = parseDate(
            exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            offset: exif["OffsetTimeOriginal"] as? String
        ) ?? parseDate(exif[kCGImagePropertyExifDateTimeDigitized as String] as? String)
          ?? parseDate(tiff[kCGImagePropertyTIFFDateTime as String] as? String)

        return PhotoAsset(
            folderID: folderID,
            fileURL: url,
            fileSize: Int64(values.fileSize ?? 0),
            pixelWidth: rotatesDimensions ? height : width,
            pixelHeight: rotatesDimensions ? width : height,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            captureDate: captureDate,
            format: url.pathExtension.uppercased(),
            cameraModel: cleanString(tiff[kCGImagePropertyTIFFModel as String]),
            lensModel: cleanString(exif[kCGImagePropertyExifLensModel as String]),
            focalLength: focalLength,
            aperture: aperture,
            shutterSpeed: exposure,
            iso: iso
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func cleanString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func exposureDescription(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 1 {
            let reciprocal = (1 / seconds).rounded()
            // Allow one part per million for serialized EXIF fractions, without
            // turning decimal exposures such as 0.8 s or 0.3 s into other values.
            if reciprocal.isFinite, reciprocal > 1, reciprocal < Double(Int.max),
               abs(1 / reciprocal - seconds) <= seconds * 1e-6 {
                return "1/\(Int(reciprocal)) s"
            }
        }
        return String(format: "%.15g s", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    private static func decimal(_ number: Double) -> String {
        number.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...1)).grouping(.never))
    }

    private static func parseDate(_ value: String?, offset: String? = nil) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            return formatter.date(from: value + offset)
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: value)
    }
}
