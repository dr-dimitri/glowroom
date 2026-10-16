import Darwin
import Foundation
import PicEditCore

/// Two bounded file-stat batches, not one task per photo or a new decoder pool.
enum MetadataCatalogSources {
    static func source(_ asset: PhotoAsset) -> MetadataSourceReference {
        let native = nativeStamp(asset.fileURL)
        var modifiedAt = asset.modifiedAt
        if let native {
            // Compare against stat's epoch without converting the persisted
            // Date through Unix seconds. Foundation file dates may differ by a
            // few submicroseconds; retain unchanged catalog Double bits.
            let observed = Double(native.modifiedAt.seconds) - Date.timeIntervalBetween1970AndReferenceDate
                + Double(native.modifiedAt.nanoseconds) / 1_000_000_000
            if abs(observed - modifiedAt.timeIntervalSinceReferenceDate) > 0.000_005 {
                modifiedAt = Date(timeIntervalSinceReferenceDate: observed)
            }
        }
        return MetadataSourceReference(original: MetadataSourceFingerprint(standardizedPath: asset.fileURL.standardizedFileURL.path,
            modifiedAt: modifiedAt, fileSize: native?.byteCount ?? asset.fileSize), nativeStamp: native)
    }
    static func nativeStamp(_ url: URL) -> MetadataNativeSourceStamp? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { return nil }
        let birth: MetadataTimestamp? = value.st_birthtimespec.tv_sec != 0 || value.st_birthtimespec.tv_nsec != 0
            ? .init(seconds: Int64(value.st_birthtimespec.tv_sec), nanoseconds: Int32(value.st_birthtimespec.tv_nsec)) : nil
        return MetadataNativeSourceStamp(identity: .init(device: Int64(value.st_dev), inode: UInt64(value.st_ino)),
            byteCount: value.st_size,
            modifiedAt: .init(seconds: Int64(value.st_mtimespec.tv_sec), nanoseconds: Int32(value.st_mtimespec.tv_nsec)),
            changedAt: .init(seconds: Int64(value.st_ctimespec.tv_sec), nanoseconds: Int32(value.st_ctimespec.tv_nsec)),
            birthTime: birth, fileGeneration: value.st_gen == 0 ? nil : UInt64(value.st_gen))
    }
    static func assets(_ assets: [PhotoAsset]) async -> [MetadataCatalogAsset] {
        await withTaskGroup(of: (Int, [MetadataCatalogAsset]).self) { group in
            var next = 0; var output: [(Int, [MetadataCatalogAsset])] = []
            func enqueue() {
                guard next < assets.count else { return }
                let start = next, end = min(next + 64, assets.count); next = end
                group.addTask { (start, assets[start..<end].map { MetadataCatalogAsset(assetID: $0.id, source: source($0)) }) }
            }
            for _ in 0..<min(2, (assets.count + 63) / 64) { enqueue() }
            while let value = await group.next() { output.append(value); enqueue() }
            return output.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        }
    }
    static func verification(before: MetadataSourceReference, after: MetadataSourceReference) -> MetadataRelocationVerification {
        guard let old = before.nativeStamp, let new = after.nativeStamp,
              old.identity == new.identity, old.byteCount == new.byteCount,
              old.modifiedAt == new.modifiedAt,
              old.byteCount == before.original.fileSize, new.byteCount == after.original.fileSize else { return .unresolved }
        let birthMatches = old.birthTime != nil && old.birthTime == new.birthTime
        let generationMatches = old.fileGeneration.map { $0 != 0 && $0 == new.fileGeneration } ?? false
        guard birthMatches || generationMatches else { return .unresolved }
        return .sameNativeIdentity(before: old, after: new)
    }
}
