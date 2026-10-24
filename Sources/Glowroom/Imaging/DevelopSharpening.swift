import CoreImage
import GlowroomCore

/// Source-pixel luminance unsharp masking. All planes stay in the lazy Core
/// Image graph; the existing bounded preview/export workers own execution.
/// Radius is Gaussian sigma, Detail admits weaker texture, and Masking selects
/// edges independently. The thresholds are Glowroom choices, not Adobe parity.
enum DevelopSharpening {
    static func apply(to input: CIImage, settings: EditSettings, extent: CGRect,
                      sourcePixelScale: Double) throws -> CIImage {
        guard settings.sharpeningAmount > 0 else { return input }
        try Task.checkCancellation()
        let consistentV2 = settings.toneProcessingVersion == .consistentV2 ? 1.0 : 0.0
        guard sourcePixelScale.isFinite, sourcePixelScale > 0,
              let luminance = luminanceKernel?.apply(extent: extent, arguments: [input, consistentV2]) else {
            throw EditRenderError.unavailable
        }
        let scale = min(1, sourcePixelScale)
        let blurred = try blur(luminance, sigma: settings.sharpeningRadius * scale, extent: extent,
                               version: settings.toneProcessingVersion)
        var mask = CIImage(color: .white).cropped(to: extent)
        if settings.sharpeningMasking > 0 {
            // A lightly smoothed central gradient separates the edge mask from
            // the sharpening residual. Translations only sample, not read back.
            let guide = try blur(luminance, sigma: 0.5 * scale, extent: extent,
                                 version: settings.toneProcessingVersion).clampedToExtent()
            guard let edges = maskKernel?.apply(extent: extent, arguments: [
                guide.transformed(by: .init(translationX: scale, y: 0)),
                guide.transformed(by: .init(translationX: -scale, y: 0)),
                guide.transformed(by: .init(translationX: 0, y: scale)),
                guide.transformed(by: .init(translationX: 0, y: -scale)),
                settings.sharpeningMasking / 100
            ]) else { throw EditRenderError.unavailable }
            mask = edges
        }
        try Task.checkCancellation()
        guard let output = sharpenKernel?.apply(extent: extent, arguments: [
            input, luminance, blurred, mask, settings.sharpeningAmount / 100,
            settings.sharpeningDetail / 100, settings.developColor.hdrEnabled ? 1.0 : 0.0, consistentV2
        ]) else { throw EditRenderError.unavailable }
        return output
    }

    /// Conservative extra working planes, shared by admission and frozen ROIs.
    static func additionalBytesPerPixel(settings: EditSettings) -> UInt64 {
        guard settings.sharpeningAmount > 0 else { return 0 }
        let halfFloatBytes: UInt64 = settings.sharpeningMasking > 0 ? 64 : 48
        return settings.usesFloatWorkingGraph ? 2 * halfFloatBytes : halfFloatBytes
    }

    private static func blur(_ image: CIImage, sigma: Double, extent: CGRect,
                             version: GlowroomCore.ToneProcessingVersion) throws -> CIImage {
        if version == .consistentV2 { return try PreciseGaussianBlur.apply(image: image, radius: sigma, extent: extent) }
        return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: extent)
    }

    // Alpha-weighted log luminance prevents transparent boundaries from adding
    // dark fringes. Uniform RGB gain preserves channel ratios and HDR headroom.
    private static let luminanceKernel = CIColorKernel(source: """
        kernel vec4 sharpeningLuminance(__sample source, float consistentV2) {
            vec4 o = unpremultiply(source);
            float y = dot(max(o.rgb, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
            // Negative working channels can be valid SDR-P3 coordinates. V2
            // limits only the scalar log domain, never the input RGB gamut.
            if (consistentV2 > 0.5) { y = dot(o.rgb, vec3(0.2126, 0.7152, 0.0722)); }
            float l = log2(max(y, 0.0001));
            return premultiply(vec4(vec3(l), o.a));
        }
        """)

    private static let maskKernel = CIColorKernel(source: """
        kernel vec4 sharpeningMask(__sample left, __sample right, __sample top, __sample bottom, float masking) {
            float dx = unpremultiply(right).r - unpremultiply(left).r;
            float dy = unpremultiply(bottom).r - unpremultiply(top).r;
            float edge = 0.5 * sqrt(dx * dx + dy * dy);
            float threshold = masking * 0.8;
            float weight = smoothstep(threshold, threshold + 0.15, edge);
            return vec4(vec3(weight), 1.0);
        }
        """)

    private static let sharpenKernel = CIColorKernel(source: """
        kernel vec4 sharpening(__sample source, __sample luminance, __sample blurred, __sample mask, float amount, float detail, float hdr, float consistentV2) {
            if (consistentV2 > 0.5 && source.a <= 0.0) { return vec4(0.0); }
            vec4 o = unpremultiply(source);
            float residual = unpremultiply(luminance).r - unpremultiply(blurred).r;
            float threshold = 0.12 * (1.0 - detail) * (1.0 - detail);
            float textureWeight = smoothstep(0.0, max(threshold, 0.000001), abs(residual));
            float delta = clamp(amount * residual * textureWeight * mask.r, -0.5, 0.5);
            float gain = exp2(delta);
            // V2 leaves signed gamut coordinates and headroom intact until the
            // target-profile output boundary. Legacy retains its original gain
            // limiter and nonnegative RGB behavior for existing saved edits.
            if (consistentV2 > 0.5) { return premultiply(vec4(o.rgb * gain, o.a)); }
            // Limit SDR gain uniformly instead of clipping individual channels.
            float peak = max(o.r, max(o.g, o.b));
            gain = mix(min(gain, 1.0 / max(peak, 0.0001)), gain, hdr);
            return premultiply(vec4(max(o.rgb * gain, vec3(0.0)), o.a));
        }
        """)
}
