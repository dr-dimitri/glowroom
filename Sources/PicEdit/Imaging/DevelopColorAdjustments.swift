import CoreImage
import PicEditCore

/// One lazy, profile-aware Core Image graph for previews and full-size export.
/// Immutable matrices are tiny CPU work; Core Image schedules the image pixels.
enum DevelopColorAdjustments {
    static func input(_ input: CIImage, settings: DevelopColorSettings, extent: CGRect) throws -> CIImage {
        let settings = settings.normalized
        guard settings.temperature != 6_500 || settings.tint != 0 || settings.profile != .neutral else { return input }
        let matrix = DevelopWhiteBalance.matrix(temperature: settings.temperature, tint: settings.tint)
        let rows = stride(from: 0, to: 9, by: 3).map { CIVector(x: matrix[$0], y: matrix[$0 + 1], z: matrix[$0 + 2]) }
        let contrast: Double, saturation: Double
        switch settings.profile {
        case .neutral: contrast = 1; saturation = 1
        case .vivid: contrast = 1.08; saturation = 1.18
        case .portrait: contrast = 0.97; saturation = 0.94
        }
        guard let output = whiteBalanceKernel?.apply(extent: extent,
            arguments: [input] + rows + [contrast, saturation]) else { throw EditRenderError.unavailable }
        return output
    }

    static func output(_ input: CIImage, settings: DevelopColorSettings, extent: CGRect) throws -> CIImage {
        guard settings.isMonochrome else { return input }
        guard let output = monochromeKernel?.apply(extent: extent, arguments: [input]) else { throw EditRenderError.unavailable }
        return output
    }

    private static let whiteBalanceKernel = CIColorKernel(source: """
        kernel vec4 developWhiteBalance(__sample original, vec3 row0, vec3 row1, vec3 row2, float contrast, float saturation) {
            vec4 o = unpremultiply(original);
            vec3 rgb = vec3(dot(o.rgb, row0), dot(o.rgb, row1), dot(o.rgb, row2));
            float y = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            // A smooth exposure-independent profile keeps black at zero and
            // does not clip HDR highlight values to the SDR interval.
            float shapedY = y * (1.0 + (contrast - 1.0) * (y - 0.18) / (abs(y) + 0.18));
            rgb = vec3(shapedY) + (rgb - vec3(y)) * saturation;
            return premultiply(vec4(rgb, o.a));
        }
        """)

    private static let monochromeKernel = CIColorKernel(source: """
        kernel vec4 developMonochrome(__sample original) {
            vec4 o = unpremultiply(original);
            float y = dot(o.rgb, vec3(0.2126, 0.7152, 0.0722));
            return premultiply(vec4(vec3(y), o.a));
        }
        """)
}
