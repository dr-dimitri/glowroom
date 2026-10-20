import CoreGraphics
import CryptoKit
import Foundation
import PicEditCore
import ImageIO
import UniformTypeIdentifiers

/// Optional, disposable previews. All filesystem and codec work runs on this
/// actor, never on the main actor, and never opens or modifies an original.
actor PreviewDiskCache {
    nonisolated static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("PicEdit/Previews-v2", isDirectory: true)
    }

    private struct Entry {
        let url: URL
        let byteCount: Int
        var lastAccess: UInt64
    }

    // Increment when changing orientation, color handling, or preview rendering.
    private static let rendererVersion = "picedit-preview-renderer-4"
    private static let metadataNamespace = "https://picedit.app/ns/preview/1.0/"
    private static let sourceLongEdgePath = "picedit:sourceLongEdge"
    private static let prefix = "picedit-v2-"
    private static let suffix = ".preview"
    private let directory: URL
    private let byteLimit: Int
    private var entries: [String: Entry] = [:]
    private var diskBytes = 0
    private var accessCounter: UInt64 = 0
    private var indexLoaded = false

    init(directory: URL, byteLimit: Int = 512 * 1_024 * 1_024) {
        self.directory = directory.standardizedFileURL
        self.byteLimit = max(0, byteLimit)
    }

    func image(for request: PreviewRequest) -> PreviewBitmap? {
        guard byteLimit > 0, !request.allowsHDR, !Task.isCancelled else { return nil }
        loadIndexIfNeeded()
        let key = Self.key(for: request)
        guard var entry = entries[key] else { return nil }
        return autoreleasepool {
            var diskURL = entry.url
            diskURL.removeAllCachedResourceValues()
            guard let attributes = try? diskURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size > 0, size <= byteLimit,
                  let data = try? Data(contentsOf: diskURL),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let type = CGImageSourceGetType(source) as String?,
                  type == UTType.jpeg.identifier || type == UTType.png.identifier,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  max(width, height) <= request.pixelSize,
                  let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
                  let nativeSize = CGImageMetadataCopyStringValueWithPath(metadata, nil, Self.sourceLongEdgePath as CFString) as String?,
                  let sourceLongEdge = Int(nativeSize), sourceLongEdge > 0,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                removeEntry(key)
                return nil
            }
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            entries[key] = entry
            // Persist recency without maintaining a separate manifest that can
            // become inconsistent with an atomic image write or an interrupted app.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.url.path)
            return PreviewBitmap(image: image, sourceLongEdge: sourceLongEdge)
        }
    }

    func store(_ bitmap: PreviewBitmap, for request: PreviewRequest) {
        guard byteLimit > 0, !request.allowsHDR, !Task.isCancelled,
              bitmap.image.width > 0, bitmap.image.height > 0,
              max(bitmap.image.width, bitmap.image.height) <= request.pixelSize else { return }
        loadIndexIfNeeded()
        guard let data = Self.encode(bitmap, lossless: !request.allowsEmbeddedPreview), data.count <= byteLimit, !Task.isCancelled else { return }
        let key = Self.key(for: request)
        let destination = directory.appendingPathComponent(Self.prefix + key + Self.suffix)
        let existingSize = entries[key]?.byteCount ?? 0
        guard trim(to: byteLimit - data.count + existingSize, excluding: key) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let attributes = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               attributes.isRegularFile != true || attributes.isSymbolicLink == true { return }
            try data.write(to: destination, options: .atomic)
            diskBytes -= entries.removeValue(forKey: key)?.byteCount ?? 0
            accessCounter &+= 1
            entries[key] = Entry(url: destination, byteCount: data.count, lastAccess: accessCounter)
            diskBytes += data.count
        } catch {
            // A full, read-only, or removed cache directory must never prevent
            // viewing an image. The freshly decoded in-memory preview stays valid.
        }
    }

    private func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        var found: [(key: String, url: URL, size: Int, date: Date)] = []
        for file in files {
            guard let key = ownedKey(for: file),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size >= 0 else { continue }
            found.append((key, file, size, values.contentModificationDate ?? .distantPast))
        }
        found.sort { $0.date == $1.date ? $0.key < $1.key : $0.date < $1.date }
        for item in found {
            let (newTotal, overflow) = diskBytes.addingReportingOverflow(item.size)
            guard !overflow else { continue }
            accessCounter &+= 1
            entries[item.key] = Entry(url: item.url, byteCount: item.size, lastAccess: accessCounter)
            diskBytes = newTotal
        }
        _ = trim(to: byteLimit)
    }

    @discardableResult
    private func trim(to targetBytes: Int, excluding protectedKey: String? = nil) -> Bool {
        guard diskBytes > targetBytes else { return true }
        let candidates = entries.filter { $0.key != protectedKey }.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for candidate in candidates {
            removeEntry(candidate.key)
            if diskBytes <= targetBytes { return true }
        }
        return diskBytes <= targetBytes
    }

    private func removeEntry(_ key: String) {
        guard let entry = entries[key], ownedKey(for: entry.url) == key else { return }
        do {
            // Never delete directories or symlinks, even if someone placed one
            // inside our cache using a filename that otherwise looks valid.
            var diskURL = entry.url
            diskURL.removeAllCachedResourceValues()
            let values = try diskURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            try FileManager.default.removeItem(at: entry.url)
        } catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain,
                  error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError else { return }
        }
        entries.removeValue(forKey: key)
        diskBytes -= entry.byteCount
    }

    private func ownedKey(for url: URL) -> String? {
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.path else { return nil }
        let name = url.lastPathComponent
        guard name.hasPrefix(Self.prefix), name.hasSuffix(Self.suffix) else { return nil }
        let key = String(name.dropFirst(Self.prefix.count).dropLast(Self.suffix.count))
        guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return key
    }

    private nonisolated static func key(for request: PreviewRequest) -> String {
        // Length-prefixed UTF-8 prevents ambiguous concatenations. Date's exact
        // floating-point bits avoid locale/precision changes in formatted dates.
        if case .artifact(let fingerprint) = request.source {
            // Canonical identity includes store, manifest, payload and native format.
            // A preview is disposable; its key can never identify an original file.
            let encoded = (try? EditingContractJSON.encoder().encode(fingerprint)) ?? Data()
            var data = Data("PicEdit-artifact-preview-v1|\(rendererVersion)|\(request.pixelSize)|".utf8)
            data.append(encoded)
            if let revision = request.sourceRevision { data.append(Data(revision.utf8)) }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let path = request.url!.standardizedFileURL.path
        var input = "\(rendererVersion)\n\(path.utf8.count):\(path)\n\(request.modifiedAt.timeIntervalSince1970.bitPattern)\n\(request.fileSize)\n\(request.pixelSize)\n\(request.allowsEmbeddedPreview)"
        // Preserve every existing nil-revision disk key. Native revisions get
        // a disjoint suffix and can never reuse an older catalog-only entry.
        if let revision = request.sourceRevision { input += "\nrevision:\(revision.utf8.count):\(revision)" }
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func encode(_ bitmap: PreviewBitmap, lossless: Bool) -> Data? {
        autoreleasepool {
            let image = bitmap.image
            let hasAlpha: Bool
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
            default: hasAlpha = true
            }
            // Editing bases must survive restart without added JPEG artifacts,
            // especially when evaluating noise or local contrast adjustments.
            let usePNG = hasAlpha || lossless
            let type = usePNG ? UTType.png.identifier : UTType.jpeg.identifier
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
            var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
            if !usePNG { properties[kCGImageDestinationLossyCompressionQuality] = 0.88 }
            let metadata = CGImageMetadataCreateMutable()
            guard CGImageMetadataRegisterNamespaceForPrefix(metadata, metadataNamespace as CFString, "picedit" as CFString, nil),
                  CGImageMetadataSetValueWithPath(metadata, nil, sourceLongEdgePath as CFString, String(bitmap.sourceLongEdge) as CFString) else { return nil }
            // ImageIO takes the profile from the rendered CGImage color space.
            // Only app-owned scale metadata is persisted in the same atomic
            // image write; no camera, location, or original metadata is copied.
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }
}
