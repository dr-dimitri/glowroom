import CoreImage
import GlowroomCore

/// V2 is deliberately separate from the frozen Gamma-2.2 legacy kernels.
/// Values are extended-linear sRGB between stages; only the perceptual math
/// enters signed sRGB. The output raster bounds SDR after target conversion.
enum TonePipelineV2 {
    private static let transfer = """
        float encodeChannel(float x) {
            float a = abs(x);
            return sign(x) * (a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1.0 / 2.4) - 0.055);
        }
        float decodeChannel(float x) {
            float a = abs(x);
            return sign(x) * (a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4));
        }
        vec3 encodeRGB(vec3 x) { return vec3(encodeChannel(x.r), encodeChannel(x.g), encodeChannel(x.b)); }
        vec3 decodeRGB(vec3 x) { return vec3(decodeChannel(x.r), decodeChannel(x.g), decodeChannel(x.b)); }
        """

    static func tone(_ image: CIImage, settings: EditSettings, extent: CGRect) throws -> CIImage {
        guard let result = toneKernel?.apply(extent: extent, arguments: [image,
            settings.exposure, settings.contrast / 100, settings.highlights / 100, settings.shadows / 100,
            settings.whites / 100, settings.blacks / 100, settings.dehaze / 100,
            settings.vibrance / 100, settings.saturation / 100]) else { throw EditRenderError.unavailable }
        return result
    }

    static func presence(_ image: CIImage, fine: CIImage, broad: CIImage,
                         settings: EditSettings, extent: CGRect) throws -> CIImage {
        guard let result = presenceKernel?.apply(extent: extent,
            arguments: [image, fine, broad, settings.texture / 100, settings.clarity / 100]) else {
            throw EditRenderError.unavailable
        }
        return result
    }

    static func denoise(_ image: CIImage, luma: CIImage, chroma: CIImage,
                        luminance: Double, color: Double, extent: CGRect) throws -> CIImage {
        guard let result = denoiseKernel?.apply(extent: extent,
            arguments: [image, luma, chroma, luminance, color]) else { throw EditRenderError.unavailable }
        return result
    }

    private static let toneKernel = CIColorKernel(source: transfer + """
        kernel vec4 consistentTone(__sample original, float exposure, float contrast, float highlights,
            float shadows, float whites, float blacks, float dehaze, float vibrance, float saturation) {
            if (original.a <= 0.0) return vec4(0.0);
            vec4 o = unpremultiply(original);
            vec3 rgb = encodeRGB(o.rgb);
            vec3 u = clamp(rgb, 0.0, 1.0);
            rgb += contrast * u * (vec3(1.0) - u) * (2.0 * u - vec3(1.0));
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = clamp(dot(rgb, weights), 0.0, 1.0);
            float shift = shadows * 0.22 * (1.0 - smoothstep(0.05, 0.65, y));
            shift += highlights * 0.22 * smoothstep(0.35, 0.95, y);
            shift += blacks * 0.11 * (1.0 - smoothstep(0.0, 0.25, y));
            shift += whites * 0.11 * smoothstep(0.75, 1.0, y);
            rgb += vec3(shift);
            // Tone gates precede exposure. EV is exactly a linear-light gain,
            // including the signed transfer's toe and negative gamut channels.
            rgb = encodeRGB(decodeRGB(rgb) * exp2(exposure));
            float removeVeil = max(dehaze, 0.0) * 0.12;
            rgb = (rgb - vec3(removeVeil)) / (1.0 - removeVeil);
            rgb = mix(rgb, vec3(0.85), max(-dehaze, 0.0) * 0.18);
            y = dot(rgb, weights);
            float spread = clamp(max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b), 0.0, 1.0);
            float colorScale = (1.0 + saturation) * (1.0 + vibrance * 0.85 * (1.0 - spread));
            rgb = mix(vec3(y), rgb, colorScale);
            return premultiply(vec4(decodeRGB(rgb), o.a));
        }
        """)

    private static let presenceKernel = CIColorKernel(source: transfer + """
        kernel vec4 consistentPresence(__sample original, __sample fineBlur, __sample broadBlur,
                                       float texture, float clarity) {
            if (original.a <= 0.0) return vec4(0.0);
            vec4 o = unpremultiply(original);
            vec3 rgb = encodeRGB(o.rgb);
            vec3 fine = encodeRGB(unpremultiply(fineBlur).rgb);
            vec3 broad = encodeRGB(unpremultiply(broadBlur).rgb);
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = dot(rgb, weights);
            float gate = clamp(y, 0.0, 1.0);
            float midtones = 4.0 * gate * (1.0 - gate);
            float detail = texture * 0.90 * (y - dot(fine, weights));
            detail += clarity * 0.75 * midtones * (y - dot(broad, weights));
            return premultiply(vec4(decodeRGB(rgb + vec3(detail)), o.a));
        }
        """)

    private static let denoiseKernel = CIColorKernel(source: """
        kernel vec4 consistentNoise(__sample original, __sample lumaBlur, __sample chromaBlur,
                                   float lumaAmount, float chromaAmount) {
            if (original.a <= 0.0) return vec4(0.0);
            vec4 o = unpremultiply(original);
            vec3 l = unpremultiply(lumaBlur).rgb;
            vec3 c = unpremultiply(chromaBlur).rgb;
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = dot(o.rgb, weights);
            float yl = dot(l, weights);
            float yc = dot(c, weights);
            float lumaWeight = 0.90 * lumaAmount / (1.0 + 12.0 * abs(y - yl));
            float colorWeight = 0.98 * chromaAmount / (1.0 + 12.0 * abs(y - yc));
            float cleanY = mix(y, yl, lumaWeight);
            vec3 cleanChroma = mix(o.rgb - vec3(y), c - vec3(yc), colorWeight);
            return premultiply(vec4(vec3(cleanY) + cleanChroma, o.a));
        }
        """)
}
