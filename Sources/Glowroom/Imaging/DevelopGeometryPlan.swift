import CoreGraphics
import Foundation
import GlowroomCore

/// One scalar plan for the rendered spatial tail and its inverse. Build this
/// from the actual admitted input raster, not an asset's native dimensions or
/// the requested preview size. No pixels, sources or artifact owners are held.
/// At most seven scalar steps stay serial; worker startup would cost more here.
struct DevelopGeometryPlan: Hashable, Sendable {
    struct Step: Equatable, Sendable {
        let inputCrop: CGRect?
        let clampsInput: Bool
        let transform: CGAffineTransform
        let outputCrop: CGRect?
    }

    let sourceExtent: CGRect
    /// Absolute Core Image coordinates; its integer edges include the existing
    /// decimal-boundary tolerance used by preview and export alike.
    let cropRect: CGRect
    let outputExtent: CGRect
    let steps: [Step]
    /// Absolute bottom-left Core Image coordinates. Canvas consumers use the
    /// explicitly top-left point methods below instead of applying this matrix.
    let inputToOutput: CGAffineTransform
    private let outputToInput: CGAffineTransform
    private let clampsRotatedInput: Bool

    var outputSize: (width: Int, height: Int) {
        (Int(outputExtent.width), Int(outputExtent.height))
    }

    init(sourceExtent: CGRect, geometry: DevelopGeometry) throws {
        let geometry = geometry.normalized
        try geometry.validate()
        try Self.validateExtent(sourceExtent)
        self.sourceExtent = sourceExtent
        let localCrop = try Self.cropRect(width: Int(sourceExtent.width), height: Int(sourceExtent.height), crop: geometry.crop)
        let crop = localCrop.offsetBy(dx: sourceExtent.minX, dy: sourceExtent.minY)
        cropRect = crop
        var planned = [Step(inputCrop: crop, clampsInput: false,
            transform: CGAffineTransform(translationX: -crop.minX, y: -crop.minY), outputCrop: nil)]
        var extent = CGRect(origin: .zero, size: crop.size)
        clampsRotatedInput = geometry.straightenAngle != 0 && geometry.constrainToImage
        if geometry.straightenAngle != 0 {
            let size = try Self.straightenedSize(width: crop.width, height: crop.height, geometry: geometry)
            let radians = CGFloat(geometry.straightenAngle * .pi / 180)
            let cosine = cos(radians), sine = sin(radians)
            let transform = CGAffineTransform(a: cosine, b: -sine, c: sine, d: cosine,
                tx: CGFloat(size.width) / 2 - cosine * crop.width / 2 - sine * crop.height / 2,
                ty: CGFloat(size.height) / 2 + sine * crop.width / 2 - cosine * crop.height / 2)
            extent = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            planned.append(Step(inputCrop: nil, clampsInput: geometry.constrainToImage,
                                transform: transform, outputCrop: extent))
        }
        if geometry.flipHorizontal {
            planned.append(Step(inputCrop: nil, clampsInput: false,
                transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.width, ty: 0), outputCrop: nil))
        }
        if geometry.flipVertical {
            planned.append(Step(inputCrop: nil, clampsInput: false,
                transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height), outputCrop: nil))
        }
        for _ in 0..<geometry.quarterTurns {
            let transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: extent.width)
            extent = CGRect(x: 0, y: 0, width: extent.height, height: extent.width)
            planned.append(Step(inputCrop: nil, clampsInput: false, transform: transform, outputCrop: extent))
        }
        steps = planned
        outputExtent = extent
        let combined = planned.reduce(CGAffineTransform.identity) { $0.concatenating($1.transform) }
        let inverse = combined.inverted()
        guard [combined.a, combined.b, combined.c, combined.d, combined.tx, combined.ty,
               inverse.a, inverse.b, inverse.c, inverse.d, inverse.tx, inverse.ty].allSatisfy(\.isFinite) else {
            throw EditRenderError.unavailable
        }
        inputToOutput = combined
        outputToInput = inverse
    }

    /// Both arguments and results use top-left pixel-edge coordinates, relative
    /// to their raster origins. Pixel centers are (column + .5, row + .5).
    /// Unconstrained transparent rotation margins have no source and return nil.
    /// The constrained renderer extends crop-edge pixels; its inverse therefore
    /// clamps to its pixel centers for tiny/rounded canvases and edge footprints.
    func inputPoint(fromOutputTopLeft point: CGPoint) -> CGPoint? {
        guard let point = Self.bounded(point, in: CGRect(origin: .zero, size: outputExtent.size)) else { return nil }
        let output = CGPoint(x: outputExtent.minX + point.x, y: outputExtent.maxY - point.y)
        let input = output.applying(outputToInput)
        let source: CGPoint
        if clampsRotatedInput {
            guard input.x.isFinite, input.y.isFinite else { return nil }
            // CIClamp extends the last sampled pixel, whose center is half a
            // pixel inside the crop. Mapping to maxX/maxY instead would let a
            // subsequent floor select an adjacent, discarded source pixel.
            source = CGPoint(x: min(cropRect.maxX - 0.5, max(cropRect.minX + 0.5, input.x)),
                             y: min(cropRect.maxY - 0.5, max(cropRect.minY + 0.5, input.y)))
        } else {
            guard let bounded = Self.bounded(input, in: cropRect) else { return nil }
            source = bounded
        }
        return CGPoint(x: source.x - sourceExtent.minX, y: sourceExtent.maxY - source.y)
    }

    /// Forward counterpart for visible source points; discarded crop/rotation
    /// locations return nil. Display fitting, scrolling and Retina conversions
    /// belong to the existing canvas geometry, outside this pixel-only plan.
    func outputPoint(fromInputTopLeft point: CGPoint) -> CGPoint? {
        guard let point = Self.bounded(point, in: CGRect(origin: .zero, size: sourceExtent.size)) else { return nil }
        let input = CGPoint(x: sourceExtent.minX + point.x, y: sourceExtent.maxY - point.y)
        guard Self.bounded(input, in: cropRect) != nil,
              let output = Self.bounded(input.applying(inputToOutput), in: outputExtent) else { return nil }
        return CGPoint(x: output.x - outputExtent.minX, y: outputExtent.maxY - output.y)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceExtent == rhs.sourceExtent && lhs.cropRect == rhs.cropRect &&
            lhs.outputExtent == rhs.outputExtent && lhs.steps == rhs.steps
    }

    func hash(into hasher: inout Hasher) {
        func rect(_ rect: CGRect) {
            hasher.combine(rect.minX); hasher.combine(rect.minY)
            hasher.combine(rect.width); hasher.combine(rect.height)
        }
        rect(sourceExtent); rect(cropRect); rect(outputExtent)
        for step in steps {
            hasher.combine(step.inputCrop != nil)
            if let input = step.inputCrop { rect(input) }
            hasher.combine(step.clampsInput)
            let t = step.transform
            hasher.combine(t.a); hasher.combine(t.b); hasher.combine(t.c)
            hasher.combine(t.d); hasher.combine(t.tx); hasher.combine(t.ty)
            hasher.combine(step.outputCrop != nil)
            if let output = step.outputCrop { rect(output) }
        }
    }

    private static func bounded(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        let epsilon: CGFloat = 1e-9
        guard point.x.isFinite, point.y.isFinite,
              point.x >= rect.minX - epsilon, point.x <= rect.maxX + epsilon,
              point.y >= rect.minY - epsilon, point.y <= rect.maxY + epsilon else { return nil }
        return CGPoint(x: min(rect.maxX, max(rect.minX, point.x)), y: min(rect.maxY, max(rect.minY, point.y)))
    }

    private static func validateExtent(_ extent: CGRect) throws {
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite,
              extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max),
              extent.minX.isFinite, extent.minY.isFinite,
              extent.maxX.isFinite, extent.maxY.isFinite else { throw EditRenderError.unavailable }
    }

    // Preserve these established renderer rounding rules exactly. Sharing their
    // resulting matrices avoids another approximate crop/rotation formula in UI.
    private static func cropRect(width: Int, height: Int, crop: DevelopCropRect?) throws -> CGRect {
        guard width > 0, height > 0, Double(width) < Double(Int.max), Double(height) < Double(Int.max) else {
            throw EditRenderError.unavailable
        }
        guard let crop else { return CGRect(x: 0, y: 0, width: width, height: height) }
        let left = min(width - 1, max(0, Int((crop.x * Double(width) + 1e-9).rounded(.down))))
        let right = min(width, max(left + 1, Int((min(1, crop.x + crop.width) * Double(width) - 1e-9).rounded(.up))))
        let top = min(height - 1, max(0, Int((crop.y * Double(height) + 1e-9).rounded(.down))))
        let bottom = min(height, max(top + 1, Int((min(1, crop.y + crop.height) * Double(height) - 1e-9).rounded(.up))))
        return CGRect(x: left, y: height - bottom, width: right - left, height: bottom - top)
    }

    private static func straightenedSize(width: CGFloat, height: CGFloat, geometry: DevelopGeometry) throws -> (width: Int, height: Int) {
        guard geometry.straightenAngle != 0 else {
            return (try rasterDimension(width, rounding: .down), try rasterDimension(height, rounding: .down))
        }
        let radians = CGFloat(abs(geometry.straightenAngle) * .pi / 180)
        let cosine = cos(radians), sine = sin(radians)
        if geometry.constrainToImage {
            let scale = min(width / (width * cosine + height * sine), height / (width * sine + height * cosine))
            return (try rasterDimension(width * scale + 1e-9, rounding: .down),
                    try rasterDimension(height * scale + 1e-9, rounding: .down))
        }
        return (try rasterDimension(width * cosine + height * sine - 1e-9, rounding: .up),
                try rasterDimension(width * sine + height * cosine - 1e-9, rounding: .up))
    }

    private static func rasterDimension(_ value: CGFloat, rounding: FloatingPointRoundingRule) throws -> Int {
        let rounded = max(1, value.rounded(rounding))
        guard value.isFinite, value > 0, rounded < CGFloat(Int.max) else { throw EditRenderError.unavailable }
        return Int(rounded)
    }
}
