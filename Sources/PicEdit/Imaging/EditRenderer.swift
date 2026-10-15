import CoreImage
import Foundation
import PicEditCore

enum EditRenderError: LocalizedError {
    case unavailable
    case oversizedPreview

    var errorDescription: String? {
        switch self {
        case .unavailable: "Die Bildbearbeitung konnte nicht gerendert werden."
        case .oversizedPreview: "Die Vorschau ist für die Bildbearbeitung zu groß."
        }
    }
}

/// Synchronous, thread-safe rendering for a bounded background worker. CIContext
/// and kernels are reusable; the mutable filter objects are local to each call.
/// This is a preview renderer, not a full-resolution export or a RAW developer.
enum EditRenderer {
    private static let context: CIContext? = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .priorityRequestLow: true
    ])

    static func render(_ bitmap: PreviewBitmap, settings: EditSettings) throws -> PreviewBitmap {
        try Task.checkCancellation()
        let settings = settings.normalized
        guard !settings.isNeutral else { return bitmap }
        let original = bitmap.image
        guard original.width > 0, original.height > 0,
              original.width <= 4_096, original.height <= 4_096 else {
            throw EditRenderError.oversizedPreview
        }
        guard let context else { throw EditRenderError.unavailable }

        return try autoreleasepool {
            let extent = CGRect(x: 0, y: 0, width: original.width, height: original.height)
            var image = CIImage(cgImage: original)
            // Keep spatial effects comparable when the progressive preview is
            // replaced by the larger rendition, without excessive tiny-image blur.
            let scale = max(0.25, Double(max(original.width, original.height)) / 1_600)

            if settings.luminanceNoiseReduction > 0 || settings.colorNoiseReduction > 0 {
                let luminance = settings.luminanceNoiseReduction / 100
                let chroma = settings.colorNoiseReduction / 100
                let lumaBlur = luminance > 0 ? blur(image, radius: (1 + 2 * luminance) * scale, extent: extent) : image
                let chromaBlur = chroma > 0 ? blur(image, radius: (2 + 4 * chroma) * scale, extent: extent) : image
                guard let result = denoiseKernel?.apply(extent: extent, arguments: [image, lumaBlur, chromaBlur, luminance, chroma]) else {
                    throw EditRenderError.unavailable
                }
                image = result
            }
            try Task.checkCancellation()

            if settings.exposure != 0 || settings.contrast != 0 || settings.highlights != 0 || settings.shadows != 0 ||
                settings.whites != 0 || settings.blacks != 0 || settings.dehaze != 0 || settings.vibrance != 0 || settings.saturation != 0 {
                guard let result = toneKernel?.apply(extent: extent, arguments: [
                    image, settings.exposure, settings.contrast / 100,
                    settings.highlights / 100, settings.shadows / 100,
                    settings.whites / 100, settings.blacks / 100,
                    settings.dehaze / 100, settings.vibrance / 100, settings.saturation / 100
                ]) else { throw EditRenderError.unavailable }
                image = result
            }
            try Task.checkCancellation()

            if settings.texture != 0 || settings.clarity != 0 {
                let fine = settings.texture != 0 ? blur(image, radius: 2.5 * scale, extent: extent) : image
                let broad = settings.clarity != 0 ? blur(image, radius: 18 * scale, extent: extent) : image
                guard let result = presenceKernel?.apply(extent: extent, arguments: [
                    image, fine, broad, settings.texture / 100, settings.clarity / 100
                ]) else { throw EditRenderError.unavailable }
                image = result
            }
            try Task.checkCancellation()

            let colorSpace = original.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let highPrecision = original.bitsPerComponent > 8
            let format: CIFormat
            switch colorSpace.model {
            case .rgb: format = highPrecision ? .RGBA16 : .RGBA8
            case .monochrome: format = highPrecision ? .LA16 : .LA8
            default: throw EditRenderError.unavailable
            }
            guard let rendered = context.createCGImage(image.cropped(to: extent), from: extent, format: format, colorSpace: colorSpace) else {
                throw EditRenderError.unavailable
            }
            try Task.checkCancellation()
            return PreviewBitmap(image: rendered)
        }
    }

    private static func blur(_ image: CIImage, radius: Double, extent: CGRect) -> CIImage {
        image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    // The compact Core Image kernel language runs on Core Image's available
    // renderer, including older Intel Macs. No external Metal compiler, model,
    // network service, or GPU-generation-specific shader library is required.
    private static let denoiseKernel = CIColorKernel(source: """
        kernel vec4 separateNoise(__sample original, __sample lumaBlur, __sample chromaBlur, float lumaAmount, float chromaAmount) {
            vec4 o = unpremultiply(original);
            vec3 l = unpremultiply(lumaBlur).rgb;
            vec3 c = unpremultiply(chromaBlur).rgb;
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = dot(o.rgb, weights);
            float yl = dot(l, weights);
            float yc = dot(c, weights);
            // Preserve high-contrast edges while suppressing fine fluctuations.
            float lumaWeight = 0.90 * lumaAmount / (1.0 + 12.0 * abs(y - yl));
            float colorWeight = 0.98 * chromaAmount / (1.0 + 12.0 * abs(y - yc));
            float cleanY = mix(y, yl, lumaWeight);
            vec3 cleanChroma = mix(o.rgb - vec3(y), c - vec3(yc), colorWeight);
            return premultiply(vec4(clamp(vec3(cleanY) + cleanChroma, 0.0, 1.0), o.a));
        }
        """)

    private static let toneKernel = CIColorKernel(source: """
        kernel vec4 toneAndColor(__sample original, float exposure, float contrast, float highlights, float shadows, float whites, float blacks, float dehaze, float vibrance, float saturation) {
            vec4 o = unpremultiply(original);
            vec3 rgb = pow(max(o.rgb * exp2(exposure), vec3(0.0)), vec3(1.0 / 2.2));
            rgb = (rgb - vec3(0.5)) * (1.0 + contrast * 0.65) + vec3(0.5);
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = clamp(dot(rgb, weights), 0.0, 1.0);
            float shift = shadows * 0.22 * (1.0 - smoothstep(0.05, 0.65, y));
            shift += highlights * 0.22 * smoothstep(0.35, 0.95, y);
            // Limit endpoint strength so combining maximum shadow/black or
            // highlight/white changes does not reverse the tonal ordering.
            shift += blacks * 0.11 * (1.0 - smoothstep(0.0, 0.25, y));
            shift += whites * 0.11 * smoothstep(0.75, 1.0, y);
            rgb += vec3(shift);
            // A practical veil/black-point approximation, not scene-depth
            // recovery: positive removes a light veil; negative adds one.
            float removeVeil = max(dehaze, 0.0) * 0.12;
            rgb = (rgb - vec3(removeVeil)) / (1.0 - removeVeil);
            rgb = mix(rgb, vec3(0.85), max(-dehaze, 0.0) * 0.18);
            y = dot(rgb, weights);
            float spread = clamp(max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b), 0.0, 1.0);
            float colorScale = (1.0 + saturation) * (1.0 + vibrance * 0.85 * (1.0 - spread));
            rgb = mix(vec3(y), rgb, colorScale);
            return premultiply(vec4(pow(clamp(rgb, 0.0, 1.0), vec3(2.2)), o.a));
        }
        """)

    private static let presenceKernel = CIColorKernel(source: """
        kernel vec4 localPresence(__sample original, __sample fineBlur, __sample broadBlur, float texture, float clarity) {
            vec4 o = unpremultiply(original);
            vec3 rgb = pow(max(o.rgb, vec3(0.0)), vec3(1.0 / 2.2));
            vec3 fine = pow(max(unpremultiply(fineBlur).rgb, vec3(0.0)), vec3(1.0 / 2.2));
            vec3 broad = pow(max(unpremultiply(broadBlur).rgb, vec3(0.0)), vec3(1.0 / 2.2));
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float y = clamp(dot(rgb, weights), 0.0, 1.0);
            float midtones = 4.0 * y * (1.0 - y);
            float detail = texture * 0.90 * (y - dot(fine, weights));
            detail += clarity * 0.75 * midtones * (y - dot(broad, weights));
            rgb = pow(clamp(rgb + vec3(detail), 0.0, 1.0), vec3(2.2));
            return premultiply(vec4(rgb, o.a));
        }
        """)
}
