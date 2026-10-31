import CoreImage
import Foundation
import GlowroomCore

/// Lazy Core Image graphs share the admitted preview/export worker and context.
/// No sampled patch performs a CPU readback or starts a nested worker pool.
enum DevelopGeometryRenderer {
    /// A candidate color graph processes the complete raw replacement ROI with
    /// the same global/local filters as its source. Apply the gesture coverage
    /// only once, later in the stored-order retouch pass.
    static func replacementInput(_ replacement: DevelopRetouchReplacement, original: CIImage, extent: CGRect) throws -> CIImage {
        try validateExtent(extent)
        let sampled = try DevelopRetouchMaskRenderer.replacement(replacement, extent: extent)
        let coverage = CIImage(color: .white).cropped(to: sampled.extent)
        guard let result = strokeKernel?.apply(extent: extent,
            arguments: [original, sampled, coverage, zero, 1.0, 0.0]) else { throw EditRenderError.unavailable }
        return result
    }

    static func replacementCount(in geometry: DevelopGeometry) -> Int {
        geometry.retouchStrokes.filter { $0.replacement != nil && $0.opacity > 0 }.count
    }

    static func outputSize(width: Int, height: Int, geometry: DevelopGeometry) throws -> (width: Int, height: Int) {
        try DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: width, height: height),
                                geometry: geometry).outputSize
    }

    static func apply(to input: CIImage, geometry: DevelopGeometry, extent: CGRect,
                      replacementImages: [UUID: CIImage] = [:]) throws -> CIImage {
        let geometry = geometry.normalized
        try geometry.validate()
        try validateExtent(extent)
        // Validate the whole spatial tail before building repair masks or
        // replacement graphs, including the radial allocation limits.
        let plan = try DevelopGeometryPlan(sourceExtent: extent, geometry: geometry)
        var image = input.cropped(to: extent)
        // Stored patch order is observable on overlapping targets. The immutable
        // pre-retouch input is the clone/heal source for every operation.
        let sampledSource = image.clampedToExtent()
        for patch in geometry.retouchStrokes where patch.opacity > 0 {
            try Task.checkCancellation()
            let source = point(patch.source, in: extent), target = point(patch.target, in: extent)
            let radius = CGFloat(patch.radius) * min(extent.width, extent.height)
            let shifted = sampledSource.transformed(by: CGAffineTransform(translationX: target.x - source.x, y: target.y - source.y))
            if !patch.path.isEmpty || patch.mask != nil || patch.replacement != nil {
                image = try applyStroke(patch, to: image, shiftedSource: shifted, radius: radius, extent: extent,
                                        replacementImage: replacementImages[patch.id])
                continue
            }
            // Old stored dabs retain their original coverage and color match.
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
        if let radial = plan.radial {
            // The inverse affine tail and radial warp share one resampling.
            // Never clamp the source: unconstrained outside samples are clear.
            let t = plan.outputToInput, crop = plan.cropRect
            guard let warped = radialWarpKernel?.apply(extent: plan.outputExtent,
                roiCallback: { _, _ in extent },
                arguments: [image, CIVector(x: t.a, y: t.b, z: t.c, w: t.d),
                    CIVector(x: t.tx, y: t.ty), CIVector(x: radial.centerX, y: radial.centerY),
                    radial.coefficient, radial.radiusSquared,
                    CIVector(x: crop.minX, y: crop.minY, z: crop.maxX, w: crop.maxY),
                    plan.clampsRotatedInput ? 1.0 : 0.0,
                    CIVector(x: extent.minX, y: extent.minY, z: extent.maxX, w: extent.maxY)]) else {
                throw EditRenderError.unavailable
            }
            try Task.checkCancellation()
            return warped
        }
        // Keep the established crop/clamp/transform order. The inverse picker
        // consumes these same planned matrices rather than recomputing angles.
        for step in plan.steps {
            if let crop = step.inputCrop { image = image.cropped(to: crop) }
            if step.clampsInput { image = image.clampedToExtent() }
            image = image.transformed(by: step.transform)
            if let crop = step.outputCrop { image = image.cropped(to: crop) }
        }
        try Task.checkCancellation()
        return image
    }

    /// Upper bound for patch graph inputs, not a measured GPU-memory claim.
    /// The budget planner can downsample a proxy before entering this graph.
    static func estimatedAdditionalBytes(geometry: DevelopGeometry, width: Int, height: Int,
                                         replacementColorBytesPerPixel: UInt64 = 0) -> UInt64? {
        guard width > 0, height > 0 else { return nil }
        let fullPixels = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        guard !fullPixels.overflow else { return nil }
        var planes: UInt64 = 0, maskBytes: UInt64 = 0
        func addPlanes(_ count: UInt64) -> Bool {
            let sum = planes.addingReportingOverflow(count)
            guard !sum.overflow else { return false }
            planes = sum.partialValue
            return true
        }
        for patch in geometry.retouchStrokes where patch.opacity > 0 {
            let extended = !patch.path.isEmpty || patch.mask != nil || patch.replacement != nil
            // Coverage, shifted source and final composition remain full-frame.
            // Only the explicitly cropped surroundings graph has ROI costs.
            let matchesSurroundings = patch.mode == .heal && patch.replacement == nil
            guard addPlanes(extended ? 48 : (patch.mode == .heal ? 48 : 32)) else { return nil }
            if extended && matchesSurroundings {
                guard let context = DevelopRetouchMaskRenderer.healingContextBounds(for: patch,
                    extent: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
                if !context.isNull && !context.isEmpty {
                    guard context.width < CGFloat(UInt64.max), context.height < CGFloat(UInt64.max) else { return nil }
                    let contextPixels = UInt64(ceil(context.width)).multipliedReportingOverflow(by: UInt64(ceil(context.height)))
                    guard !contextPixels.overflow else { return nil }
                    // Dilation, shifted selection, cropped source/target,
                    // two weighted colors, target position moments, their three
                    // blurs, normalized correction and a sampling reserve:
                    // twelve bounded float RGBA planes. The three fallback
                    // reductions/reserves are 1-pixel images.
                    let contextBytes = contextPixels.partialValue.multipliedReportingOverflow(by: 192)
                    guard !contextBytes.overflow else { return nil }
                    let withReductions = contextBytes.partialValue.addingReportingOverflow(192)
                    guard !withReductions.overflow else { return nil }
                    let sum = maskBytes.addingReportingOverflow(withReductions.partialValue)
                    guard !sum.overflow else { return nil }; maskBytes = sum.partialValue
                }
            }
            if patch.replacement != nil, !addPlanes(replacementColorBytesPerPixel) { return nil }
            if extended {
                let rasterBytes: UInt64
                if let mask = patch.mask { rasterBytes = UInt64(mask.bytes.count) }
                else {
                    guard let size = DevelopRetouchMaskRenderer.rasterSize(width: width, height: height) else { return nil }
                    rasterBytes = UInt64(size.width * size.height)
                }
                // CPU Gray8 backing + provider copy + potential scalar upload.
                let retained = rasterBytes.multipliedReportingOverflow(by: 3)
                guard !retained.overflow else { return nil }
                // Native path vertices and Core Graphics' stroked-path working
                // storage are bounded by points, rather than full image planes.
                let vectorBytes = patch.mask == nil ? UInt64(patch.path.count + 1) * 64 : 0
                let rasterAndVector = retained.partialValue.addingReportingOverflow(vectorBytes)
                guard !rasterAndVector.overflow else { return nil }
                let sum = maskBytes.addingReportingOverflow(rasterAndVector.partialValue)
                guard !sum.overflow else { return nil }; maskBytes = sum.partialValue
                if let replacement = patch.replacement {
                    // Encoded RGBA backing, CGImage/provider storage and native
                    // float conversion/upload for the model's bounded ROI.
                    let replacementBytes = UInt64(replacement.rgba.count).multipliedReportingOverflow(by: 6)
                    guard !replacementBytes.overflow else { return nil }
                    let sum = maskBytes.addingReportingOverflow(replacementBytes.partialValue)
                    guard !sum.overflow else { return nil }; maskBytes = sum.partialValue
                }
            }
        }
        for eye in geometry.redEyeCorrections where eye.strength > 0 {
            guard addPlanes(16) else { return nil }
        }
        if !geometry.optics.isNeutral {
            guard let plan = try? DevelopGeometryPlan(sourceExtent: CGRect(x: 0, y: 0, width: width, height: height), geometry: geometry),
                  addPlanes(16) else { return nil }
            let output = UInt64(plan.outputSize.width).multipliedReportingOverflow(by: UInt64(plan.outputSize.height))
            guard !output.overflow else { return nil }
            let outputBytes = output.partialValue.multipliedReportingOverflow(by: 16)
            guard !outputBytes.overflow else { return nil }
            let sum = maskBytes.addingReportingOverflow(outputBytes.partialValue)
            guard !sum.overflow else { return nil }; maskBytes = sum.partialValue
        }
        let planesBytes = fullPixels.partialValue.multipliedReportingOverflow(by: planes)
        guard !planesBytes.overflow else { return nil }
        let bytes = planesBytes.partialValue.addingReportingOverflow(maskBytes)
        guard !bytes.overflow else { return nil }
        guard geometry.straightenAngle != 0 else { return bytes.partialValue }
        // A narrow panorama's expanded rotation canvas can be many times the
        // source area. Admit resampling/output planes against the larger actual
        // raster, rather than assuming a fixed source-area expansion factor.
        guard let size = try? outputSize(width: width, height: height, geometry: geometry) else { return nil }
        let outputPixels = UInt64(size.width).multipliedReportingOverflow(by: UInt64(size.height))
        guard !outputPixels.overflow else { return nil }
        let rotationBytes = max(fullPixels.partialValue, outputPixels.partialValue).multipliedReportingOverflow(by: 32)
        guard !rotationBytes.overflow else { return nil }
        let total = bytes.partialValue.addingReportingOverflow(rotationBytes.partialValue)
        return total.overflow ? nil : total.partialValue
    }

    private static func validateExtent(_ extent: CGRect) throws {
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite,
              extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max),
              extent.minX.isFinite, extent.minY.isFinite else { throw EditRenderError.unavailable }
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

    private static func applyStroke(_ stroke: DevelopRetouchStroke, to image: CIImage,
                                    shiftedSource: CIImage, radius: CGFloat, extent: CGRect,
                                    replacementImage: CIImage? = nil) throws -> CIImage {
        let raster = try DevelopRetouchMaskRenderer.coverageResult(for: stroke, extent: extent)
        var coverage = raster.image
        let sampled: CIImage
        if let replacement = stroke.replacement {
            if let replacementImage { sampled = replacementImage }
            else { sampled = try DevelopRetouchMaskRenderer.replacement(replacement, extent: extent) }
            // A mask may extend beyond the model ROI. Pixels outside its
            // explicit bounds must never turn into transparent/black samples.
            coverage = coverage.cropped(to: DevelopRetouchMaskRenderer.replacementBounds(replacement, extent: extent))
        } else { sampled = shiftedSource }
        var correction = zero
        // A raster without zero coverage has no unselected comparison pixels,
        // whether it came from a path or a stored mask. Its correction is zero.
        // Avoid constructing an empty native reduction/blur graph in this case.
        if stroke.mode == .heal && stroke.replacement == nil && raster.hasUnselectedPixels {
            // Separate donor texture from its local illumination, then infer
            // replacement illumination from the clean target surroundings.
            // Comparing only the two outer rings would retain a broad bright
            // or dark feature at the donor's center inside the repaired area.
            guard let context = DevelopRetouchMaskRenderer.healingContextBounds(for: stroke, extent: extent) else {
                throw EditRenderError.unavailable
            }
            if !context.isNull && !context.isEmpty {
                // Keep the morphology sampler's original input domain: Core
                // Image's reconstruction at image edges changes if the scaled
                // mask is cropped before dilation. Only its output and the
                // following ring/color/reduction images are ROI-limited.
                let outside = coverage.applyingFilter("CIMorphologyMaximum", parameters: [
                    kCIInputRadiusKey: max(1, radius * 0.5)
                ]).cropped(to: context)
                // A nearby donor's exterior can reach back into the object.
                // Exclude that translated selection from donor tone samples,
                // including samples inside the copied area. Target tone uses
                // only its own clean exterior; both means normalize alpha.
                let shiftedCoverage = coverage.transformed(by: CGAffineTransform(
                    translationX: (stroke.target.x - stroke.source.x) * extent.width,
                    y: (stroke.source.y - stroke.target.y) * extent.height))
                let bounds = CIVector(x: context.minX, y: context.minY, z: context.maxX, w: context.maxY)
                guard let targetSamples = healingSamplesKernel?.apply(extent: context,
                    arguments: [image.cropped(to: context), coverage, outside, bounds]),
                      let donorSamples = healingSamplesKernel?.apply(extent: context,
                    arguments: [shiftedSource.cropped(to: context), shiftedCoverage, outside, bounds]) else {
                    throw EditRenderError.unavailable
                }
                // Target interpolation reaches across the selected object.
                // The narrower donor low-pass removes broad source lighting
                // while retaining fine texture. Both scales follow the stored
                // radius in source coordinates, including preview/export.
                let targetTone = targetSamples.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: max(1, radius * 0.6)
                ]).cropped(to: context)
                let donorTone = donorSamples.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: max(1, radius * 0.2)
                ]).cropped(to: context)
                guard let moments = healingMomentsKernel?.apply(extent: context,
                    arguments: [targetSamples, bounds]) else { throw EditRenderError.unavailable }
                let localMoments = moments.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: max(1, radius * 0.6)
                ]).cropped(to: context)
                let targetAverage = targetSamples.applyingFilter("CIAreaAverage", parameters: [
                    kCIInputExtentKey: CIVector(cgRect: context)
                ]).clampedToExtent()
                let donorAverage = donorSamples.applyingFilter("CIAreaAverage", parameters: [
                    kCIInputExtentKey: CIVector(cgRect: context)
                ]).clampedToExtent()
                let momentAverage = moments.applyingFilter("CIAreaAverage", parameters: [
                    kCIInputExtentKey: CIVector(cgRect: context)
                ]).clampedToExtent()
                let gradientStep = max(1, radius * 0.1)
                guard let local = healingCorrectionKernel?.apply(extent: context,
                    roiCallback: { _, rect in rect.insetBy(dx: -gradientStep, dy: -gradientStep) },
                    arguments: [targetTone, targetAverage, donorTone, donorAverage,
                        localMoments, momentAverage, bounds, gradientStep]) else { throw EditRenderError.unavailable }
                correction = local
            }
        }
        guard let result = strokeKernel?.apply(extent: extent, arguments: [image, sampled,
            coverage, correction, stroke.opacity, replacementImage == nil ? 0.0 : 1.0]) else { throw EditRenderError.unavailable }
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
    private static let healingSamplesKernel = CIColorKernel(source: """
        kernel vec4 retouchHealingSamples(__sample color, __sample excluded, __sample expanded, vec4 bounds) {
            // Extent metadata alone does not constrain a fused sampler's
            // reconstruction domain. A Gaussian may request surrounding pixels.
            vec2 p = destCoord();
            if (p.x < bounds.x || p.y < bounds.y || p.x >= bounds.z || p.y >= bounds.w) { return vec4(0.0); }
            // Selections include the feather, independently of opacity.
            // Use support, not the tiny antialiasing/feather value at the outer
            // edge. Sparse fractional weights would underflow a half-float
            // reduction and destabilize the normalized color correction.
            if (excluded.r > 0.000001 || expanded.r <= 0.000001 || color.a <= 0.0) { return vec4(0.0); }
            // Premultiplied RGB already carries exactly this alpha weight.
            return color;
        }
        """)
    private static let healingMomentsKernel = CIColorKernel(source: """
        kernel vec4 retouchHealingMoments(__sample weighted, vec4 bounds) {
            vec2 p = destCoord();
            if (p.x < bounds.x || p.y < bounds.y || p.x >= bounds.z || p.y >= bounds.w) { return vec4(0.0); }
            // Bounded 0...1 coordinates avoid large absolute image positions
            // in the half-float weighted moment/blur intermediates.
            vec2 relative = (p - bounds.xy) / (bounds.zw - bounds.xy);
            return vec4(relative * weighted.a, 0.0, weighted.a);
        }
        """)
    private static let healingCorrectionKernel = CIKernel(source: """
        vec3 normalizedTone(vec4 local, vec4 average) {
            vec3 fallback = average.rgb / average.a;
            // Never divide an unsupported sample. A later zero blend weight
            // would not make an infinite or undefined intermediate safe.
            if (local.a <= 0.00001) { return fallback; }
            vec3 tone = local.rgb / local.a;
            // Broad mask interiors can exceed the blur's support. Fade into
            // the clean mean for weights 1e-5...1e-4. This avoids division
            // noise and abrupt fallback boundaries.
            float support = smoothstep(0.00001, 0.0001, local.a);
            return mix(fallback, tone, support);
        }
        kernel vec4 retouchHealingCorrection(sampler target, sampler targetAverage,
            sampler donor, sampler donorAverage, sampler moments, sampler momentAverage, vec4 bounds, float gradientStep) {
            vec2 p = destCoord();
            if (p.x < bounds.x || p.y < bounds.y || p.x >= bounds.z || p.y >= bounds.w) { return vec4(0.0); }
            vec4 targetMean = sample(targetAverage, samplerTransform(targetAverage, p));
            vec4 donorMean = sample(donorAverage, samplerTransform(donorAverage, p));
            vec4 positionMean = sample(momentAverage, samplerTransform(momentAverage, p));
            // An empty exterior or completely invalid donor gives no reliable
            // color match. Keep the uncorrected donor, including full masks.
            if (targetMean.a <= 0.000001 || donorMean.a <= 0.000001 || positionMean.a <= 0.000001) { return vec4(0.0); }
            vec3 targetTone = normalizedTone(sample(target, samplerTransform(target, p)), targetMean);
            vec3 donorTone = normalizedTone(sample(donor, samplerTransform(donor, p)), donorMean);
            vec2 centroid = normalizedTone(sample(moments, samplerTransform(moments, p)), positionMean).xy;
            vec2 offset = bounds.xy + centroid * (bounds.zw - bounds.xy) - p;
            // The outer ring is asymmetric away from the brush center. Keep
            // the donor's first-order trend in that extrapolation, otherwise a
            // matching source/target gradient would bend into a bright halo.
            // Clamp differences at the image/context edge, never sample a zero
            // exterior as if it were a dark source pixel.
            vec2 lo = max(bounds.xy + vec2(0.5), p - vec2(gradientStep));
            vec2 hi = min(bounds.zw - vec2(0.5), p + vec2(gradientStep));
            vec3 left = normalizedTone(sample(donor, samplerTransform(donor, vec2(lo.x, p.y))), donorMean);
            vec3 right = normalizedTone(sample(donor, samplerTransform(donor, vec2(hi.x, p.y))), donorMean);
            vec3 bottom = normalizedTone(sample(donor, samplerTransform(donor, vec2(p.x, lo.y))), donorMean);
            vec3 top = normalizedTone(sample(donor, samplerTransform(donor, vec2(p.x, hi.y))), donorMean);
            vec3 slopeX = (right - left) / max(0.000001, hi.x - lo.x);
            vec3 slopeY = (top - bottom) / max(0.000001, hi.y - lo.y);
            return vec4(targetTone - donorTone - slopeX * offset.x - slopeY * offset.y, 1.0);
        }
        """)
    private static let strokeKernel = CIColorKernel(source: """
        kernel vec4 retouchStroke(__sample original, __sample sampled, __sample mask,
                                 __sample correction, float opacity, float preservesSampleRange) {
            vec4 base = unpremultiply(original);
            vec3 replacement = unpremultiply(sampled).rgb + correction.rgb;
            // A prepared color candidate already followed the source's gamut
            // policy. Keep negative working-space values needed for Display P3.
            if (preservesSampleRange < 0.5) { replacement = max(vec3(0.0), replacement); }
            vec3 color = mix(base.rgb, replacement, clamp(mask.r * opacity, 0.0, 1.0));
            return vec4(color * original.a, original.a);
        }
        """)
    private static let radialWarpKernel = CIKernel(source: """
        kernel vec4 radialGeometry(sampler original, vec4 matrix, vec2 translation, vec2 center,
                                  float k, float radiusSquared, vec4 crop, float constrainedRotation,
                                  vec4 sourceBounds) {
            vec2 p = destCoord();
            vec2 warped = vec2(matrix.x * p.x + matrix.z * p.y,
                               matrix.y * p.x + matrix.w * p.y) + translation;
            if (constrainedRotation > 0.5) {
                warped = clamp(warped, crop.xy + vec2(0.5), crop.zw - vec2(0.5));
            } else if (warped.x < crop.x || warped.y < crop.y || warped.x > crop.z || warped.y > crop.w) {
                return vec4(0.0);
            }
            vec2 delta = warped - center;
            vec2 source = center + delta * (1.0 + k * dot(delta, delta) / radiusSquared);
            // CIWarpKernel's implicit sampler extends edge pixels even when
            // its input is cropped. An explicit domain check must precede the
            // one and only color sample, including for analytic CIImage inputs.
            if (source.x < sourceBounds.x || source.y < sourceBounds.y ||
                source.x > sourceBounds.z || source.y > sourceBounds.w) return vec4(0.0);
            return sample(original, samplerTransform(original, source));
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
