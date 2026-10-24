import CoreImage
import Foundation
import GlowroomCore

enum LevelsRetouchSamplingError: Error, Equatable, LocalizedError {
    case ambiguousRetouch

    var errorDescription: String? {
        "Die Probe überlappt eine gemischte oder mehrdeutige Retusche. Wähle eine unberührte Stelle oder die vollständig deckende Mitte einer einzelnen Ersatzfläche."
    }
}

/// Resolve only the current 5×5 sample window. Existing coverage generation is
/// shared with the renderer; masks stay lazy and each readback is at most 25
/// pixels. The caller owns the already admitted background render session.
enum LevelsRetouchSampling {
    static func sample(bitmap: PreviewBitmap, settings: EditSettings, normalizedTopLeft point: CGPoint,
                       session: EditRenderer.Session, context: CIContext) throws -> LevelsSampleReport {
        let graph = try EditRenderer.globalLevelsInputGraph(bitmap, settings: settings, session: session)
        let original = try LevelsSampler.sample(graph: graph, normalizedTopLeft: point, context: context)
        let extent = CGRect(x: 0, y: 0, width: original.proxyWidth, height: original.proxyHeight)
        let window = CGRect(x: original.windowX,
            y: original.proxyHeight - original.windowY - original.windowHeight,
            width: original.windowWidth, height: original.windowHeight)
        var replacement: DevelopRetouchReplacement?
        // Stored-order composites have no unique inverse input to Levels. A
        // single fully opaque replacement is the only touched-window exception.
        for stroke in settings.developGeometry.retouchStrokes where stroke.opacity > 0 {
            try Task.checkCancellation()
            if stroke.path.isEmpty && stroke.mask == nil && stroke.replacement == nil {
                // Historical dabs use a private radial kernel. A conservative
                // radius rectangle avoids duplicating that coverage formula.
                let radius = CGFloat(stroke.radius) * min(extent.width, extent.height)
                let bounds = CGRect(x: CGFloat(stroke.target.x) * extent.width - radius,
                    y: (1 - CGFloat(stroke.target.y)) * extent.height - radius,
                    width: radius * 2, height: radius * 2)
                guard !bounds.intersects(window) else { throw LevelsRetouchSamplingError.ambiguousRetouch }
                continue
            }
            var coverage = try DevelopRetouchMaskRenderer.coverage(for: stroke, extent: extent)
            if let frozen = stroke.replacement {
                // The renderer applies coverage only inside the frozen ROI.
                coverage = coverage.cropped(to: DevelopRetouchMaskRenderer.replacementBounds(frozen, extent: extent))
            }
            var pixels = [Float](repeating: 0, count: original.windowPixelCount * 4)
            pixels.withUnsafeMutableBytes { bytes in
                context.render(coverage, toBitmap: bytes.baseAddress!,
                    rowBytes: original.windowWidth * 4 * MemoryLayout<Float>.stride,
                    bounds: window, format: .RGBAf, colorSpace: nil)
            }
            try Task.checkCancellation()
            let weights = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
            guard weights.allSatisfy(\.isFinite) else { throw LevelsRetouchSamplingError.ambiguousRetouch }
            guard weights.contains(where: { $0 > 0 }) else { continue }
            guard replacement == nil, let frozen = stroke.replacement, stroke.opacity == 1,
                  weights.allSatisfy({ $0 >= 1 }) else { throw LevelsRetouchSamplingError.ambiguousRetouch }
            replacement = frozen
        }
        guard let replacement else { return original }
        let replacementGraph = try EditRenderer.globalLevelsReplacementInputGraph(bitmap,
            settings: settings, session: session, replacement: replacement)
        return try LevelsSampler.sample(graph: replacementGraph, normalizedTopLeft: point, context: context)
    }
}
