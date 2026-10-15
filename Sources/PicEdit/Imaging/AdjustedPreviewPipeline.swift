import Foundation
import PicEditCore

/// Serial, cancellable rendering keeps rapid slider changes from starting many
/// concurrent GPU jobs. Original decoding is independent of slider changes.
actor AdjustedPreviewPipeline {
    static let shared = AdjustedPreviewPipeline()

    private struct Key: Hashable {
        let request: PreviewRequest
        let settings: EditSettings
        let width: Int
        let height: Int
    }
    private struct Entry {
        let bitmap: PreviewBitmap
        var access: UInt64
    }
    private var cache: [Key: Entry] = [:]
    private var bytes = 0
    private var sequence: UInt64 = 0
    private let limit = 32 * 1_024 * 1_024

    func image(_ source: PreviewBitmap, request: PreviewRequest, settings: EditSettings) throws -> PreviewBitmap {
        try Task.checkCancellation()
        let normalized = settings.normalized
        guard !normalized.isNeutral else { return source }
        let key = Key(request: request, settings: normalized, width: source.image.width, height: source.image.height)
        sequence &+= 1
        if var entry = cache[key] {
            entry.access = sequence
            cache[key] = entry
            return entry.bitmap
        }
        let result = try EditRenderer.render(source, settings: normalized)
        try Task.checkCancellation()
        if result.byteCost <= limit {
            while bytes + result.byteCost > limit || cache.count >= 32 {
                guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= oldest.value.bitmap.byteCost
                cache.removeValue(forKey: oldest.key)
            }
            cache[key] = Entry(bitmap: result, access: sequence)
            bytes += result.byteCost
        }
        return result
    }
}
