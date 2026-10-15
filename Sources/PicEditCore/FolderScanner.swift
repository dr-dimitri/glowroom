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
    public init() {}

    public func scan(folder: LibraryFolder) async throws -> ScanResult {
        try scanSynchronously(folder: folder)
    }

    public func scanSubdirectories(folder: LibraryFolder) async throws -> [String] {
        try scanSynchronously(folder: folder, includeImages: false).subdirectoryPaths
    }

    private func scanSynchronously(folder: LibraryFolder, includeImages: Bool = true) throws -> ScanResult {
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
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .fileSizeKey, .creationDateKey, .contentModificationDateKey
        ]
        var skippedFiles = 0
        var skippedURLs: [URL] = []
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
        var seenPaths: Set<String> = []
        var subdirectoryPaths: Set<String> = []
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let supportedExtensions = includeImages ? Self.supportedExtensions : []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            autoreleasepool {
                guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
                    inaccessibleURL = url
                    return
                }
                // Following directory links may leave the chosen folder or create a cycle.
                // File links are also excluded, so imports do not silently depend on external paths.
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    return
                }
                if values.isDirectory == true {
                    if values.isPackage == true {
                        enumerator.skipDescendants()
                        return
                    }
                    let path = url.standardizedFileURL.path
                    if path.hasPrefix(rootPrefix) {
                        let relativePath = String(path.dropFirst(rootPrefix.count))
                        if !relativePath.isEmpty { subdirectoryPaths.insert(relativePath) }
                    }
                    return
                }
                guard includeImages, values.isRegularFile == true else { return }
                let ext = url.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .image) == true else {
                    return
                }
                let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
                guard !seenPaths.contains(canonicalURL.path) else { return }
                guard manager.isReadableFile(atPath: canonicalURL.path) else {
                    inaccessibleURL = canonicalURL
                    return
                }
                guard let asset = Self.readAsset(at: canonicalURL, folderID: folder.id, values: values) else {
                    if !manager.fileExists(atPath: canonicalURL.path) {
                        inaccessibleURL = canonicalURL
                        return
                    }
                    skippedFiles += 1
                    skippedURLs.append(canonicalURL)
                    return
                }
                seenPaths.insert(asset.id)
                assets.append(asset)
            }
            if let inaccessibleURL { throw FolderScanError.unavailableFolder(inaccessibleURL) }
        }
        try Task.checkCancellation()
        if let inaccessibleURL { throw FolderScanError.unavailableFolder(inaccessibleURL) }
        guard manager.isReadableFile(atPath: root.path) else { throw FolderScanError.unavailableFolder(root) }
        assets.sort { $0.fileURL.path.localizedStandardCompare($1.fileURL.path) == .orderedAscending }
        let sortedDirectories = subdirectoryPaths.sorted { lhs, rhs in
            let comparison = lhs.localizedStandardCompare(rhs)
            return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
        }
        return ScanResult(assets: assets, skippedFiles: skippedFiles, skippedURLs: skippedURLs, subdirectoryPaths: sortedDirectories)
    }

    private static var supportedExtensions: Set<String> {
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
    }

    private static func readAsset(at url: URL, folderID: UUID, values: URLResourceValues) -> PhotoAsset? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }

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
        let exposure = number(exif[kCGImagePropertyExifExposureTime as String]).flatMap { value -> String? in
            guard value > 0 else { return nil }
            if value < 1 {
                let reciprocal = (1 / value).rounded()
                guard reciprocal.isFinite, reciprocal < Double(Int.max) else {
                    return String(format: "%.3g s", locale: Locale(identifier: "en_US_POSIX"), value)
                }
                return "1/\(Int(reciprocal)) s"
            }
            return "\(decimal(value)) s"
        }
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
