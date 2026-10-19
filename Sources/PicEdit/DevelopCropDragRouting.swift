import CoreGraphics
import PicEditCore

enum DevelopCropDragAction: Equatable {
    case create
    case move
    case resize(DevelopCropHandle)
}

extension DevelopCropInteraction {
    /// macOS Accessibility's three-finger dragging emits an ordinary primary
    /// mouse drag. Moving an existing selection from its interior therefore
    /// supports that system setting without depending on private event fields.
    static func dragAction(at point: CGPoint, crop: DevelopCropRect?, imageRect: CGRect,
                           forceMove: Bool = false,
                           hitRadius: CGFloat = DevelopCropInteraction.hitRadius) -> DevelopCropDragAction {
        guard point.x.isFinite, point.y.isFinite, imageRect.width.isFinite, imageRect.height.isFinite,
              imageRect.minX.isFinite, imageRect.minY.isFinite,
              imageRect.width > 0, imageRect.height > 0 else { return .create }
        if forceMove { return .move }
        if let handle = handle(at: point, crop: crop, imageRect: imageRect, hitRadius: hitRadius) { return .resize(handle) }
        if let crop, box(crop: crop, imageRect: imageRect).contains(point) { return .move }
        return .create
    }

    /// Apply the total translation from gesture start, preserving dimensions and
    /// aspect ratio. Independent axes clamp at the source bounds without drift.
    static func moved(crop: DevelopCropRect?, translation: CGSize) -> DevelopCropRect? {
        guard let crop, translation.width.isFinite, translation.height.isFinite else { return crop }
        let x = min(1 - crop.width, max(0, crop.x + Double(translation.width)))
        let y = min(1 - crop.height, max(0, crop.y + Double(translation.height)))
        return (try? DevelopCropRect(x: x, y: y, width: crop.width, height: crop.height)) ?? crop
    }
}
