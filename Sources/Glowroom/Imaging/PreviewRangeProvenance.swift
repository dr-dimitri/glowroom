import CoreGraphics
import Foundation

/// Describes the decoded rendition, never the unobserved RAW sensor range.
/// Extended RGB gamut components alone do not classify a rendition as HDR.
enum PreviewRangeProvenance: Hashable, Sendable {
    case sdrDecoded
    case extended(nominalSDRWhite: Double)
    case unknown

    var nominalSDRWhite: Double? {
        switch self {
        case .sdrDecoded: return 1
        case .extended(let white): return white.isFinite && white > 0 ? white : nil
        case .unknown: return nil
        }
    }

    static func inferred(from image: CGImage) -> Self {
        guard let space = image.colorSpace, space.model == .rgb || space.model == .monochrome else { return .unknown }
        // PQ/HLG transfer functions require their own absolute-white contract.
        // They must not inherit the relative SDR-white definition used here.
        let name = (space.name as String?)?.lowercased() ?? ""
        guard !name.contains("pq"), !name.contains("hlg"), !name.contains("2100") else { return .unknown }
        if image.bitmapInfo.contains(.floatComponents) {
            guard CGColorSpaceCreateExtendedLinearized(space) != nil else { return .unknown }
            return .extended(nominalSDRWhite: 1)
        }
        return .sdrDecoded
    }
}
