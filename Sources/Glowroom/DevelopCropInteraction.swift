import CoreGraphics
import GlowroomCore

enum DevelopCropHandle: String, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func position(in box: CGRect) -> CGPoint {
        CGPoint(x: horizontal < 0 ? box.minX : horizontal > 0 ? box.maxX : box.midX,
                y: vertical < 0 ? box.minY : vertical > 0 ? box.maxY : box.midY)
    }

    fileprivate var horizontal: CGFloat {
        switch self {
        case .topLeft, .bottomLeft, .left: -1
        case .topRight, .bottomRight, .right: 1
        case .top, .bottom: 0
        }
    }

    fileprivate var vertical: CGFloat {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .left, .right: 0
        }
    }
}

/// Constant-size pointer geometry stays synchronous: scheduling workers for eight
/// handle checks would cost more than the arithmetic and delay pointer feedback.
enum DevelopCropInteraction {
    static let hitRadius: CGFloat = 14
    static let minimumDimension: CGFloat = 0.005

    static func box(crop: DevelopCropRect?, imageRect: CGRect) -> CGRect {
        let crop = normalizedBox(crop)
        return CGRect(x: imageRect.minX + crop.minX * imageRect.width,
                      y: imageRect.minY + crop.minY * imageRect.height,
                      width: crop.width * imageRect.width, height: crop.height * imageRect.height)
    }

    static func handle(at point: CGPoint, crop: DevelopCropRect?, imageRect: CGRect, hitRadius: CGFloat = Self.hitRadius) -> DevelopCropHandle? {
        guard hitRadius.isFinite, hitRadius > 0, point.x.isFinite, point.y.isFinite, imageRect.width.isFinite, imageRect.height.isFinite,
              imageRect.width > 0, imageRect.height > 0 else { return nil }
        let box = box(crop: crop, imageRect: imageRect)
        var closest: DevelopCropHandle?
        var distance = hitRadius * hitRadius
        for handle in DevelopCropHandle.allCases {
            let center = handle.position(in: box)
            let dx = point.x - center.x, dy = point.y - center.y
            let squared = dx * dx + dy * dy
            // Enumeration order resolves exact ties consistently; overlapping hit
            // targets otherwise select the handle nearest the pointer.
            if squared <= distance, closest == nil || squared < distance {
                closest = handle
                distance = squared
            }
        }
        return closest
    }

    /// Translation is measured from the initial pointer position in normalized
    /// source coordinates, so grabbing near a handle does not snap it to the mouse.
    static func resized(crop: DevelopCropRect?, handle: DevelopCropHandle, translation: CGSize,
                        sourceSize: CGSize, aspectRatio: Double?) -> DevelopCropRect? {
        guard valid(sourceSize), translation.width.isFinite, translation.height.isFinite else { return crop }
        guard translation != .zero else { return crop }
        let original = normalizedBox(crop)
        let sx = handle.horizontal, sy = handle.vertical
        let dx = translation.width, dy = translation.height
        guard let aspectRatio else {
            var left = original.minX, right = original.maxX
            var top = original.minY, bottom = original.maxY
            if sx < 0 { left = clamp(left + dx, 0, right - minimumDimension) }
            if sx > 0 { right = clamp(right + dx, left + minimumDimension, 1) }
            if sy < 0 { top = clamp(top + dy, 0, bottom - minimumDimension) }
            if sy > 0 { bottom = clamp(bottom + dy, top + minimumDimension, 1) }
            return makeCrop(CGRect(x: left, y: top, width: right - left, height: bottom - top)) ?? crop
        }
        guard let ratio = normalizedRatio(aspectRatio, sourceSize: sourceSize) else { return crop }
        let anchorX = sx < 0 ? original.maxX : original.minX
        let anchorY = sy < 0 ? original.maxY : original.minY
        if sx != 0, sy != 0 {
            let maximumWidth = min(sx < 0 ? anchorX : 1 - anchorX,
                                   (sy < 0 ? anchorY : 1 - anchorY) * ratio)
            let minimumWidth = max(minimumDimension, minimumDimension * ratio)
            guard maximumWidth >= minimumWidth else { return crop }
            // The dominant gesture axis drives corners, allowing shrinking even
            // when the pointer moves along just one axis.
            let requestedWidth = abs(dx) >= abs(dy * ratio)
                ? original.width + sx * dx : (original.height + sy * dy) * ratio
            let width = clamp(requestedWidth, minimumWidth, maximumWidth)
            let height = width / ratio
            return makeCrop(CGRect(x: sx < 0 ? anchorX - width : anchorX,
                                   y: sy < 0 ? anchorY - height : anchorY, width: width, height: height)) ?? crop
        }
        if sx != 0 {
            let center = original.midY
            let maximumWidth = min(sx < 0 ? anchorX : 1 - anchorX, 2 * min(center, 1 - center) * ratio)
            let minimumWidth = max(minimumDimension, minimumDimension * ratio)
            guard maximumWidth >= minimumWidth else { return crop }
            let width = clamp(original.width + sx * dx, minimumWidth, maximumWidth)
            let height = width / ratio
            return makeCrop(CGRect(x: sx < 0 ? anchorX - width : anchorX,
                                   y: center - height / 2, width: width, height: height)) ?? crop
        }
        let center = original.midX
        let maximumHeight = min(sy < 0 ? anchorY : 1 - anchorY, 2 * min(center, 1 - center) / ratio)
        let minimumHeight = max(minimumDimension, minimumDimension / ratio)
        guard maximumHeight >= minimumHeight else { return crop }
        let height = clamp(original.height + sy * dy, minimumHeight, maximumHeight)
        let width = height * ratio
        return makeCrop(CGRect(x: center - width / 2,
                               y: sy < 0 ? anchorY - height : anchorY, width: width, height: height)) ?? crop
    }

    static func created(from start: CGPoint, to end: CGPoint, sourceSize: CGSize,
                        aspectRatio: Double?) -> DevelopCropRect? {
        guard valid(sourceSize), start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return nil }
        let start = CGPoint(x: clamp(start.x, 0, 1), y: clamp(start.y, 0, 1))
        let end = CGPoint(x: clamp(end.x, 0, 1), y: clamp(end.y, 0, 1))
        let sx: CGFloat = end.x < start.x ? -1 : 1
        let sy: CGFloat = end.y < start.y ? -1 : 1
        var width = abs(end.x - start.x), height = abs(end.y - start.y)
        if let aspectRatio {
            guard let ratio = normalizedRatio(aspectRatio, sourceSize: sourceSize) else { return nil }
            let maximumWidth = min(sx < 0 ? start.x : 1 - start.x, (sy < 0 ? start.y : 1 - start.y) * ratio)
            width = min(max(width, height * ratio), maximumWidth)
            height = width / ratio
        }
        guard width >= minimumDimension, height >= minimumDimension else { return nil }
        return makeCrop(CGRect(x: sx < 0 ? start.x - width : start.x,
                               y: sy < 0 ? start.y - height : start.y, width: width, height: height))
    }

    private static func normalizedBox(_ crop: DevelopCropRect?) -> CGRect {
        CGRect(x: crop?.x ?? 0, y: crop?.y ?? 0, width: crop?.width ?? 1, height: crop?.height ?? 1)
    }

    private static func valid(_ source: CGSize) -> Bool {
        source.width.isFinite && source.height.isFinite && source.width > 0 && source.height > 0
    }

    private static func normalizedRatio(_ ratio: Double, sourceSize: CGSize) -> CGFloat? {
        let normalized = CGFloat(ratio) / (sourceSize.width / sourceSize.height)
        return normalized.isFinite && normalized > 0 ? normalized : nil
    }

    private static func makeCrop(_ box: CGRect) -> DevelopCropRect? {
        try? DevelopCropRect(x: Double(max(0, box.minX)), y: Double(max(0, box.minY)),
                             width: Double(min(1, box.width)), height: Double(min(1, box.height)))
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
