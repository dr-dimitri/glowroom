import CoreGraphics
import Foundation

/// A small identity cache shares the original's analysis across slider changes.
/// Stable raster tokens share deterministic resizes without retaining pixels.
/// Calls without tokens use weak references plus verified object identity to
/// avoid extending source lifetimes or matching a reused address. The caller's
/// bounded render workers provide concurrency; this cache creates no worker pool.
final class NaturalBalanceAnalysisCache: @unchecked Sendable {
    static let shared = NaturalBalanceAnalysisCache()

    private enum Key: Hashable {
        case source(SourceAnalysisIdentity)
        case image(ObjectIdentifier)
        var isStable: Bool { if case .source = self { true } else { false } }
    }

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
    // Short test observation under condition; must not reenter the cache.
    private let didJoinInFlight: (@Sendable () -> Void)?
    // All mutable state, including each entry, is protected by condition.
    private var entries: [Key: Entry] = [:]
    private var access: UInt64 = 0

    init(maximumEntries: Int = 8,
         didJoinInFlight: (@Sendable () -> Void)? = nil,
         analyze: @escaping @Sendable (CGImage) throws -> NaturalBalanceAnalysis = { try NaturalBalanceAnalysis.analyze($0) }) {
        self.maximumEntries = max(1, maximumEntries)
        self.didJoinInFlight = didJoinInFlight
        self.analyzeImage = analyze
    }

    func analysis(for image: CGImage, identity: SourceAnalysisIdentity? = nil) throws -> NaturalBalanceAnalysis {
        let stable = identity.flatMap { $0.matches(image) ? $0 : nil }
        let key = stable.map(Key.source) ?? .image(ObjectIdentifier(image))
        var reportedJoin = false
        while true {
            try Task.checkCancellation()
            condition.lock()
            entries = entries.filter { $0.key.isStable || $0.value.image != nil }
            access &+= 1
            if let entry = entries[key], stable != nil || entry.image === image {
                entry.lastAccess = access
                if let analysis = entry.analysis {
                    condition.unlock()
                    try Task.checkCancellation()
                    return analysis
                }
                // Joining the bounded scene analysis does not schedule another worker.
                // A timed wait lets a canceled preview leave promptly even while
                // the shared producer is inside a native bitmap draw or Vision request.
                if !reportedJoin {
                    reportedJoin = true
                    didJoinInFlight?()
                }
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
            entries[key] = entry
            condition.unlock()
            do {
                let analysis = try analyzeImage(image)
                try Task.checkCancellation()
                condition.lock()
                if entries[key] === entry { entry.analysis = analysis }
                condition.broadcast()
                condition.unlock()
                return analysis
            } catch {
                condition.lock()
                if entries[key] === entry { entries.removeValue(forKey: key) }
                condition.broadcast()
                condition.unlock()
                // A canceled or failed producer must not poison future requests;
                // remaining waiters can retry with their own cancellation state.
                throw error
            }
        }
    }
}
