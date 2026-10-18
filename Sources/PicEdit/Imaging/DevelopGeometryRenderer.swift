import CoreImage
import Foundation
import PicEditCore

/// Lazy Core Image graphs share the admitted preview/export worker and context.
/// No sampled patch performs a CPU readback or starts a nested worker pool.
enum DevelopGeometryRenderer {
    static func outputSize(width: Int, height: Int, geometry: DevelopGeometry) throws -> (width: Int, height: Int) {
        let rect = try cropRect(width: width, height: height, crop: geometry.crop)
        return geometry.normalized.quarterTurns.isMultiple(of: 2)
            ? (Int(rect.width), Int(rect.height)) : (Int(rect.height), Int(rect.width))
    }

    static func apply(to input: CIImage, geometry: DevelopGeometry, extent: CGRect) throws -> CIImage {
        let geometry = geometry.normalized
        try geometry.validate()
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            throw EditRenderError.unavailable
        }
        var image = input.cropped(to: extent)
        // Stored patch order is observable on overlapping targets. The immutable
        // pre-retouch input is the clone/heal source for every operation.
        let sampledSource = image.clampedToExtent()
        for patch in geometry.retouchStrokes where patch.opacity > 0 {
            try Task.checkCancellation()
            let source = point(patch.source, in: extent), target = point(patch.target, in: extent)
            let radius = CGFloat(patch.radius) * min(extent.width, extent.height)
            let shifted = sampledSource.transformed(by: CGAffineTransform(translationX: target.x - source.x, y: target.y - source.y))
            let mask = try radialMask(center: target, radius: radius, feather: patch.feather,
                                      opacity: patch.opacity, extent: extent)
            let sourceMean: CIImage, targetMean: CIImage
            if patch.mode == .heal {
                sourceMean = mean(sampledSource, center: source, radius: radius)
                targetMean = mean(image.clampedToExtent(), center: target, radius: radius)
            } else {
                sourceMean = .empty(); targetMean = .empty()
            }
            guard let result = retouchKernel?.apply(extent: extent, arguments: [image, shifted, mask,
                patch.mode == .heal ? sourceMean : zero, patch.mode == .heal ? targetMean : zero]) else {
                throw EditRenderError.unavailable
            }
            image = result
        }
        for eye in geometry.redEyeCorrections where eye.strength > 0 {
            try Task.checkCancellation()
            let center = point(eye.center, in: extent)
            guard let result = redEyeKernel?.apply(extent: extent, arguments: [image,
                CIVector(x: center.x, y: center.y), CIVector(x: eye.radiusX * extent.width, y: eye.radiusY * extent.height), eye.strength]) else {
                throw EditRenderError.unavailable
            }
            image = result
        }
        let localCrop = try cropRect(width: Int(extent.width), height: Int(extent.height), crop: geometry.crop)
        let crop = localCrop.offsetBy(dx: extent.minX, dy: extent.minY)
        image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if geometry.flipHorizontal {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.width, ty: 0))
        }
        if geometry.flipVertical {
            image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: image.extent.height))
        }
        for _ in 0..<geometry.quarterTurns {
            let width = image.extent.width, height = image.extent.height
            image = image.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width))
                .cropped(to: CGRect(x: 0, y: 0, width: height, height: width))
        }
        try Task.checkCancellation()
        return image
    }

    /// Upper bound for patch graph inputs, not a measured GPU-memory claim.
    /// The budget planner can downsample a proxy before entering this graph.
    static func estimatedAdditionalBytes(geometry: DevelopGeometry, width: Int, height: Int) -> UInt64? {
        guard width > 0, height > 0 else { return nil }
        let fullPixels = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !fullPixels.overflow else { return nil }
        var planes: UInt64 = 0
        func addPlanes(_ count: UInt64) -> Bool {
            let sum = planes.addingReportingOverflow(count)
            guard !sum.overflow else { return false }
            planes = sum.partialValue
            return true
        }
        for patch in geometry.retouchStrokes where patch.opacity > 0 {
            // The current kernels cover the complete image. Even a tiny patch
            // therefore needs full-frame admission; do not pretend its circular
            // ROI bounds the lazy graph or backend's intermediate allocations.
            guard addPlanes(patch.mode == .heal ? 48 : 32) else { return nil }
        }
        for eye in geometry.redEyeCorrections where eye.strength > 0 {
            guard addPlanes(16) else { return nil }
        }
        let bytes = fullPixels.partialValue.multipliedReportingOverflow(by: planes)
        return bytes.overflow ? nil : bytes.partialValue
    }

    private static func cropRect(width: Int, height: Int, crop: DevelopCropRect?) throws -> CGRect {
        guard width > 0, height > 0 else { throw EditRenderError.unavailable }
        guard let crop else { return CGRect(x: 0, y: 0, width: width, height: height) }
        // Avoid an extra pixel when a decimal edge such as 0.2 + 0.4 is a few
        // floating-point ulps above its exact integer pixel boundary.
        let left = min(width - 1, max(0, Int((crop.x * Double(width) + 1e-9).rounded(.down))))
        let right = min(width, max(left + 1, Int(((crop.x + crop.width) * Double(width) - 1e-9).rounded(.up))))
        let top = min(height - 1, max(0, Int((crop.y * Double(height) + 1e-9).rounded(.down))))
        let bottom = min(height, max(top + 1, Int(((crop.y + crop.height) * Double(height) - 1e-9).rounded(.up))))
        return CGRect(x: left, y: height - bottom, width: right - left, height: bottom - top)
    }

    private static func point(_ point: LocalMaskPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + point.x * extent.width, y: extent.maxY - point.y * extent.height)
    }

    private static func mean(_ image: CIImage, center: CGPoint, radius: CGFloat) -> CIImage {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        return image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
            .clampedToExtent()
    }

    private static func radialMask(center: CGPoint, radius: CGFloat, feather: Double, opacity: Double, extent: CGRect) throws -> CIImage {
        guard let kernel = radialKernel,
              let result = kernel.apply(extent: extent, arguments: [CIVector(x: center.x, y: center.y),
                  radius, max(0.000_001, radius * feather), opacity]) else { throw EditRenderError.unavailable }
        return result
    }

    private static let zero = CIImage(color: .black)
    private static let radialKernel = CIColorKernel(source: """
        kernel vec4 patchMask(vec2 center, float radius, float feather, float opacity) {
            float weight = (1.0 - smoothstep(radius - feather, radius, distance(destCoord(), center))) * opacity;
            return vec4(weight, weight, weight, 1.0);
        }
        """)
    private static let retouchKernel = CIColorKernel(source: """
        kernel vec4 retouch(__sample original, __sample cloned, __sample mask, __sample sourceMean, __sample targetMean) {
            vec4 base = unpremultiply(original);
            vec3 sampled = unpremultiply(cloned).rgb;
            vec3 correction = unpremultiply(targetMean).rgb - unpremultiply(sourceMean).rgb;
            vec3 color = mix(base.rgb, max(vec3(0.0), sampled + correction), mask.r);
            return vec4(color * original.a, original.a);
        }
        """)
    private static let redEyeKernel = CIColorKernel(source: """
        kernel vec4 redEye(__sample original, vec2 center, vec2 radius, float strength) {
            vec4 color = unpremultiply(original);
            float coverage = 1.0 - smoothstep(0.65, 1.0, length((destCoord() - center) / radius));
            float redDominance = smoothstep(0.05, 0.25, color.r - max(color.g, color.b));
            color.r = mix(color.r, min(color.r, (color.g + color.b) * 0.5), coverage * redDominance * strength);
            return vec4(color.rgb * original.a, original.a);
        }
        """)
}
