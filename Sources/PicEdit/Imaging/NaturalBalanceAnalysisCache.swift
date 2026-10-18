import CoreGraphics
import Foundation

/// A small identity cache shares the original's analysis across slider changes.
/// Weak source references avoid extending the decoded preview's lifetime and
/// prevent a reused object address from matching a different image. The caller's
/// bounded render workers provide concurrency; this cache creates no worker pool.
final class NaturalBalanceAnalysisCache: @unchecked Sendable {
    static let shared = NaturalBalanceAnalysisCache()

    private final class Entry {
        weak var image: CGImage?
        var analysis: NaturalBalanceAnalysis?
        var lastAccess: UInt64

        init(image: CGImage, lastAccess: UInt64) {
            self.image = image
            self.lastAccess = lastAccess
        }
    }

    private let condition = NSCondition()
    private let maximumEntries: Int
    private let analyzeImage: @Sendable (CGImage) throws -> NaturalBalanceAnalysis
    // All mutable state, including each entry, is protected by condition.
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var access: UInt64 = 0

    init(maximumEntries: Int = 8,
         analyze: @escaping @Sendable (CGImage) throws -> NaturalBalanceAnalysis = { try NaturalBalanceAnalysis.analyze($0) }) {
        self.maximumEntries = max(1, maximumEntries)
        self.analyzeImage = analyze
    }

    func analysis(for image: CGImage) throws -> NaturalBalanceAnalysis {
        let identity = ObjectIdentifier(image)
        while true {
            try Task.checkCancellation()
            condition.lock()
            entries = entries.filter { $0.value.image != nil }
            access &+= 1
            if let entry = entries[identity], entry.image === image {
                entry.lastAccess = access
                if let analysis = entry.analysis {
                    condition.unlock()
                    try Task.checkCancellation()
                    return analysis
                }
                // Joining the bounded scene analysis does not schedule another worker.
                // A timed wait lets a canceled preview leave promptly even while
                // the shared producer is inside a native bitmap draw or Vision request.
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
                condition.unlock()
                continue
            }
            if entries.count >= maximumEntries,
               let oldest = entries.filter({ $0.value.analysis != nil })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                entries.removeValue(forKey: oldest)
            }
            guard entries.count < maximumEntries else {
                // Never evict an in-flight producer or grow beyond the bound.
                // Normally unreachable with the render pipeline's worker limit.
                condition.unlock()
                let result = try analyzeImage(image)
                try Task.checkCancellation()
                return result
            }
            let entry = Entry(image: image, lastAccess: access)
            entries[identity] = entry
            condition.unlock()
            do {
                let analysis = try analyzeImage(image)
                try Task.checkCancellation()
                condition.lock()
                if entries[identity] === entry { entry.analysis = analysis }
                condition.broadcast()
                condition.unlock()
                return analysis
            } catch {
                condition.lock()
                if entries[identity] === entry { entries.removeValue(forKey: identity) }
                condition.broadcast()
                condition.unlock()
                // A canceled or failed producer must not poison future requests;
                // remaining waiters can retry with their own cancellation state.
                throw error
            }
        }
    }
}
