import CoreGraphics
import Foundation

/// Identity of one decoded raster or deterministic resize, independent of the
/// CGImage instance used for a render. Tokens include the complete resize chain
/// and format upstream. Metadata guards accidental use with a different raster.
/// This value owns neither decoded pixels nor an artifact resource reservation.
struct SourceAnalysisIdentity: Hashable, Sendable {
    private let revision: UUID
    private let width: Int
    private let height: Int
    private let bitsPerComponent: Int
    private let bitsPerPixel: Int
    private let bitmapInfo: UInt32
    private let colorSpaceName: String?

    init(bitmap: PreviewBitmap) {
        revision = bitmap.rangeSourceIdentity
        width = bitmap.image.width; height = bitmap.image.height
        bitsPerComponent = bitmap.image.bitsPerComponent
        bitsPerPixel = bitmap.image.bitsPerPixel
        bitmapInfo = bitmap.image.bitmapInfo.rawValue
        colorSpaceName = Self.profileName(bitmap.image)
    }

    func matches(_ image: CGImage) -> Bool {
        width == image.width && height == image.height &&
            bitsPerComponent == image.bitsPerComponent && bitsPerPixel == image.bitsPerPixel &&
            bitmapInfo == image.bitmapInfo.rawValue && colorSpaceName == Self.profileName(image)
    }

    private static func profileName(_ image: CGImage) -> String? {
        guard let name = image.colorSpace?.name else { return nil }
        return name as String
    }
}
