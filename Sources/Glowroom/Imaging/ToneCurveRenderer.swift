import CoreImage
import Foundation
import GlowroomCore

/// One versioned pixel node for the global preview/export graph. No per-channel
/// jobs, LUT quantization, readback of the source raster, or source decoding.
enum ToneCurveRenderer {
    static func apply(to image: CIImage, settings: ToneCurveSettings, extent: CGRect, context: CIContext,
                      inputRange: LevelsRenderer.InputRange? = nil) throws -> CIImage {
        try settings.validate()
        guard !settings.isNeutral else { return image }
        try Task.checkCancellation()
        // Every pixel, including isolated HDR outliers, participates in the
        // existing Float range proof. This reads back only eight Float values.
        let range = try inputRange ?? LevelsRenderer.inputRange(of: image, extent: extent, context: context)
        let output = try settings.validatedOutputRanges(red: range.red, green: range.green, blue: range.blue)
        for channel in [output.red, output.green, output.blue] {
            let magnitude = max(abs(channel.lowerBound), abs(channel.upperBound))
            // Shader pow and transfer constants have Float precision. Leave
            // headroom and reject before evaluating an overflowing lazy graph.
            guard SignedSRGB.decode(magnitude + 0.000_01).isFinite,
                  SignedSRGB.decode(magnitude + 0.000_01) < Double(Float.greatestFiniteMagnitude) / 1.0001 else {
                throw ToneCurveValidationError.unrepresentableValue
            }
        }
        let kernel = try cache.kernel(for: settings)
        guard let result = kernel.apply(extent: extent, arguments: [image]) else { throw EditRenderError.unavailable }
        return result
    }

    private final class KernelCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(ToneCurveSettings, CIColorKernel)] = []
        func kernel(for settings: ToneCurveSettings) throws -> CIColorKernel {
            lock.lock(); defer { lock.unlock() }
            if let index = entries.firstIndex(where: { $0.0 == settings }) {
                let hit = entries.remove(at: index); entries.append(hit)
                return hit.1
            }
            // At most 32 identities retain compiled kernels during rapid drags.
            // Serial compilation under this short cache lock coalesces equal
            // concurrent requests; all actual pixel work remains in Core Image.
            let source = try kernelSource(settings)
            guard let kernel = CIColorKernel(source: source) else { throw EditRenderError.unavailable }
            if entries.count == 32 { entries.removeFirst() }
            entries.append((settings, kernel))
            return kernel
        }
    }
    private static let cache = KernelCache()

    private static func kernelSource(_ settings: ToneCurveSettings) throws -> String {
        func literal(_ value: Double) -> String { String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value) + (value.rounded() == value ? ".0" : "") }
        func curve(_ name: String, _ curve: ToneCurve) throws -> String {
            if curve.isNeutral { return "float \(name)(float x) { return x; }\n" }
            var code = "float \(name)(float x) {\n"
            code += "if (x < 0.0) return x + \(literal(curve.points[0].y));\n"
            code += "if (x > 1.0) return (x - 1.0) + \(literal(curve.points.last!.y));\n"
            for segment in try curve.segments() {
                let c1 = segment.y0 + segment.tangent0 / 3, c2 = segment.y1 - segment.tangent1 / 3
                code += """
                if (x <= \(literal(segment.x1))) {
                    float t = (x - \(literal(segment.x0))) / (\(literal(segment.x1)) - \(literal(segment.x0)));
                    float u = 1.0 - t;
                    return u*u*u*\(literal(segment.y0)) + 3.0*u*u*t*\(literal(c1)) + 3.0*u*t*t*\(literal(c2)) + t*t*t*\(literal(segment.y1));
                }

                """
            }
            return code + "return \(literal(curve.points.last!.y));\n}\n"
        }
        return try transfer + curve("toneRed", settings.red) + curve("toneGreen", settings.green)
            + curve("toneBlue", settings.blue) + curve("toneMaster", settings.master) + """
            kernel vec4 glowroomToneCurves(__sample original) {
                if (original.a <= 0.0) return vec4(0.0);
                vec3 rgb = original.rgb / original.a;
                rgb = vec3(toneEncode(rgb.r), toneEncode(rgb.g), toneEncode(rgb.b));
                rgb = vec3(toneMaster(toneRed(rgb.r)), toneMaster(toneGreen(rgb.g)), toneMaster(toneBlue(rgb.b)));
                rgb = vec3(toneDecode(rgb.r), toneDecode(rgb.g), toneDecode(rgb.b));
                return vec4(rgb * original.a, original.a);
            }
            """
    }
    private static let transfer = """
        float toneEncode(float value) {
            float a = abs(value);
            float encoded = a <= 0.0031308 ? 12.92*a : 1.055*pow(a, 1.0/2.4)-0.055;
            return value < 0.0 ? -encoded : encoded;
        }
        float toneDecode(float value) {
            float a = abs(value);
            float linear = a <= 0.04045 ? a/12.92 : pow((a+0.055)/1.055, 2.4);
            return value < 0.0 ? -linear : linear;
        }

        """
}
