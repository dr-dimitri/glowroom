import CoreImage
import Foundation
import GlowroomCore

/// Global levels are never repeated while constructing a local mask candidate.
enum LevelsScope { case global, local }

/// The input/output images remain premultiplied, extended-linear sRGB. Only
/// straight RGB inside this node uses the versioned signed-sRGB transfer.
enum LevelsRenderer {
    /// The scalar solution cannot predict native pow approximations or FMA
    /// contraction amplified by a narrow master interval. Probe the exact
    /// node on this backend before promising RGB gray at the sampled mean.
    /// This single Float pixel shares the existing admitted analysis context.
    static func validateNeutralGray(sample: LevelsPickerSample, settings: LevelsSettings,
                                    context: CIContext) throws {
        try sample.validate()
        let values: [Float] = [Float(SignedSRGB.decode(sample.red)), Float(SignedSRGB.decode(sample.green)),
                               Float(SignedSRGB.decode(sample.blue)), 1]
        guard values.allSatisfy(\.isFinite) else { throw LevelsPickerError.unreachableTarget }
        let data = values.withUnsafeBytes { Data($0) }
        let extent = CGRect(x: 0, y: 0, width: 1, height: 1)
        let input = CIImage(bitmapData: data, bytesPerRow: 16, size: extent.size,
                            format: .RGBAf, colorSpace: FloatAnalysis.workingSpace)
        let output = try apply(to: input, settings: settings, extent: extent, context: context)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            context.render(output, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: extent,
                           format: .RGBAf, colorSpace: FloatAnalysis.workingSpace)
        }
        try Task.checkCancellation()
        guard pixel.allSatisfy(\.isFinite), pixel[3] > 0 else { throw LevelsPickerError.unreachableTarget }
        let tolerance = Double(LevelsPickerProposal.neutralizationTargetTolerance)
        guard (0..<3).allSatisfy({
            abs(SignedSRGB.encode(Double(pixel[$0] / pixel[3])) - 0.5) <= tolerance
        }) else { throw LevelsPickerError.unreachableTarget }
    }
    struct InputRange: Equatable, Sendable {
        let red: ClosedRange<Double>
        let green: ClosedRange<Double>
        let blue: ClosedRange<Double>
    }

    /// Every source pixel participates, including isolated HDR outliers. The
    /// two GPU reductions read back eight Floats, never a full source raster.
    /// Invalid pixels carry an opaque finite sentinel in the same RGB plane:
    /// this is the invalid flag, independent of alpha/color conversion behavior
    /// in reduction filters. A valid signed encoding of any Float is < 1e17.
    static func inputRange(of image: CIImage, extent: CGRect, context: CIContext) throws -> InputRange {
        try Task.checkCancellation()
        guard !extent.isEmpty, !extent.isInfinite,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite),
              let plane = rangeKernel?.apply(extent: extent, arguments: [image]) else {
            throw EditRenderError.unavailable
        }
        let parameters: [String: Any] = [kCIInputExtentKey: CIVector(cgRect: extent)]
        let minimum = plane.applyingFilter("CIAreaMinimum", parameters: parameters)
        let maximum = plane.applyingFilter("CIAreaMaximum", parameters: parameters)
        func read(_ graph: CIImage) -> [Float] {
            var values = [Float](repeating: 0, count: 4)
            values.withUnsafeMutableBytes { bytes in
                context.render(graph, toBitmap: bytes.baseAddress!, rowBytes: 4 * MemoryLayout<Float>.stride,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            }
            return values
        }
        // The caller already occupies one bounded render lane. Do not create a
        // second worker pool for these dependent reductions of its lazy graph.
        let low = read(minimum), high = read(maximum)
        try Task.checkCancellation()
        guard low.allSatisfy(\.isFinite), high.allSatisfy(\.isFinite),
              high[0..<3].allSatisfy({ abs($0) < 1e29 }),
              (0..<3).allSatisfy({ low[$0] <= high[$0] }) else {
            throw EditRenderError.unrepresentableLevels
        }
        // The separate reduction/final graph evaluations may specialize pow
        // differently. A small outward margin makes their Float bounds robust.
        func bounds(_ channel: Int) -> ClosedRange<Double> {
            var lower = low[channel], upper = high[channel]
            for _ in 0..<8 { lower = lower.nextDown; upper = upper.nextUp }
            return Double(lower)...Double(upper)
        }
        return InputRange(red: bounds(0), green: bounds(1), blue: bounds(2))
    }

    /// Core certifies both curve sequences and every Float intermediate. The
    /// final signed transfer needs its own check: an encoded value can fit Float
    /// while its 2.4 power, on returning to linear light, does not.
    static func validate(settings: LevelsSettings, inputRange: InputRange) throws {
        do {
            let output = try settings.validatedOutputRanges(red: inputRange.red,
                green: inputRange.green, blue: inputRange.blue)
            // Native pow implementations may differ slightly from CPU libm.
            // Keep every power away from Float overflow, including a huge power
            // followed by equal output endpoints or an enabled output clamp.
            let safePower = Double(Float.greatestFiniteMagnitude) / 1.0001
            func powerHeadroom(_ curve: LevelsCurve, _ input: ClosedRange<Double>) throws {
                let span = Float(curve.inputWhite) - Float(curve.inputBlack)
                var upper = (Float(input.upperBound) - Float(curve.inputBlack)).nextUp
                upper = (upper / span).nextUp
                if curve.clampInput { upper = min(max(upper, 0), 1) }
                if upper > 0, pow(Double(upper), Double(1 / Float(curve.gamma))) > safePower {
                    throw LevelsValidationError.unrepresentableValue
                }
            }
            for (curve, input) in [(settings.red, inputRange.red),
                                    (settings.green, inputRange.green), (settings.blue, inputRange.blue)] {
                try powerHeadroom(curve, input)
                try powerHeadroom(settings.master, curve.validatedOutputRange(for: input))
            }
            for range in [output.red, output.green, output.blue] {
                let magnitude = max(abs(range.lowerBound), abs(range.upperBound))
                if magnitude <= Double(Float(0.04045)) { continue }
                func upperFloat(_ value: Double) throws -> Double {
                    guard value.isFinite, value <= Double(Float.greatestFiniteMagnitude) else {
                        throw LevelsValidationError.unrepresentableValue
                    }
                    var upper = Float(value)
                    if Double(upper) < value { upper = upper.nextUp }
                    guard upper.isFinite else { throw LevelsValidationError.unrepresentableValue }
                    return Double(upper)
                }
                let sum = try upperFloat(magnitude + Double(Float(0.055)))
                let base = try upperFloat(sum / Double(Float(1.055)))
                let linear = try upperFloat(pow(base, Double(Float(2.4))))
                guard linear <= safePower else { throw LevelsValidationError.unrepresentableValue }
            }
        } catch {
            throw EditRenderError.unrepresentableLevels
        }
    }

    static func apply(to image: CIImage, settings: LevelsSettings, extent: CGRect,
                      context: CIContext, inputRange: InputRange? = nil) throws -> CIImage {
        // Preserve the exact historical graph and skip all reduction work.
        guard !settings.isNeutral else { return image }
        let range = try inputRange ?? self.inputRange(of: image, extent: extent, context: context)
        try validate(settings: settings, inputRange: range)
        func parameters(_ curve: LevelsCurve) -> [Any] {
            [CIVector(x: curve.inputBlack, y: curve.inputWhite, z: curve.gamma, w: curve.outputBlack),
             CIVector(x: curve.outputWhite, y: curve.clampInput ? 1 : 0, z: curve.clampOutput ? 1 : 0, w: 0)]
        }
        let arguments: [Any] = [image] + parameters(settings.red) + parameters(settings.green)
            + parameters(settings.blue) + parameters(settings.master)
        guard let output = kernel?.apply(extent: extent, arguments: arguments) else {
            throw EditRenderError.unavailable
        }
        return output
    }

    /// A safe levels output can overflow in a later spatial/local correction.
    /// Validate the final lazy graph before publishing a preview or starting an
    /// export. Opaque 0/1 flags avoid NaN-reduction and premultiplication traps;
    /// only one RGBAf pixel crosses back to the existing bounded render lane.
    static func validateFiniteOutput(_ image: CIImage, context: CIContext) throws {
        try Task.checkCancellation()
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite),
              let flags = finiteKernel?.apply(extent: extent, arguments: [image]) else {
            throw EditRenderError.unavailable
        }
        let maximum = flags.applyingFilter("CIAreaMaximum", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { bytes in
            context.render(maximum, toBitmap: bytes.baseAddress!, rowBytes: 4 * MemoryLayout<Float>.stride,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        try Task.checkCancellation()
        guard values.allSatisfy(\.isFinite), values[0] == 0, values[3] == 1 else {
            throw EditRenderError.unrepresentableLevels
        }
    }

    private static let transfer = """
        float levelsEncode(float value) {
            float a = abs(value);
            float encoded = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
            return value < 0.0 ? -encoded : encoded;
        }
        float levelsDecode(float value) {
            float a = abs(value);
            float linear = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
            return value < 0.0 ? -linear : linear;
        }
        """

    private static let rangeKernel = CIColorKernel(source: transfer + """
        // CIKL supports scalar comparisons, but boolean-returning helper
        // functions are rejected by its stitchable-kernel compiler.
        float levelsFinite(float value) { return value == value && abs(value) <= 3.402823e38 ? 1.0 : 0.0; }
        kernel vec4 glowroomLevelsRange(__sample original) {
            // Alpha is validated even for an invisible sample. Hidden RGB is
            // deliberately ignored and fully transparent output is canonical.
            if (levelsFinite(original.a) < 0.5 || original.a < 0.0 || original.a > 1.0)
                return vec4(vec3(1.0e30), 1.0);
            if (original.a == 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
            vec3 rgb = original.rgb / original.a;
            if (levelsFinite(rgb.r) < 0.5 || levelsFinite(rgb.g) < 0.5 || levelsFinite(rgb.b) < 0.5)
                return vec4(vec3(1.0e30), 1.0);
            return vec4(levelsEncode(rgb.r), levelsEncode(rgb.g), levelsEncode(rgb.b), 1.0);
        }
        """)

    private static let finiteKernel = CIColorKernel(source: """
        float levelsOutputFinite(float value) { return value == value && abs(value) <= 3.402823e38 ? 1.0 : 0.0; }
        kernel vec4 glowroomLevelsFiniteOutput(__sample original) {
            if (levelsOutputFinite(original.a) < 0.5 || original.a < 0.0 || original.a > 1.0 ||
                levelsOutputFinite(original.r) < 0.5 || levelsOutputFinite(original.g) < 0.5 || levelsOutputFinite(original.b) < 0.5)
                return vec4(1.0, 0.0, 0.0, 1.0);
            if (original.a > 0.0) {
                vec3 rgb = original.rgb / original.a;
                if (levelsOutputFinite(rgb.r) < 0.5 || levelsOutputFinite(rgb.g) < 0.5 || levelsOutputFinite(rgb.b) < 0.5)
                    return vec4(1.0, 0.0, 0.0, 1.0);
            }
            return vec4(0.0, 0.0, 0.0, 1.0);
        }
        """)

    private static let kernel = CIColorKernel(source: transfer + """
        float levelsCurve(float x, vec4 a, vec4 b) {
            float u = (x - a.x) / (a.y - a.x);
            if (b.y > 0.5) u = clamp(u, 0.0, 1.0);
            float v = u > 0.0 ? pow(u, 1.0 / a.z) : u;
            float y = a.w + v * (b.x - a.w);
            return b.z > 0.5 ? clamp(y, 0.0, 1.0) : y;
        }
        kernel vec4 glowroomLevels(__sample original, vec4 redA, vec4 redB,
            vec4 greenA, vec4 greenB, vec4 blueA, vec4 blueB, vec4 masterA, vec4 masterB) {
            if (original.a <= 0.0) return vec4(0.0);
            vec3 rgb = original.rgb / original.a;
            rgb = vec3(levelsEncode(rgb.r), levelsEncode(rgb.g), levelsEncode(rgb.b));
            rgb = vec3(levelsCurve(rgb.r, redA, redB), levelsCurve(rgb.g, greenA, greenB),
                       levelsCurve(rgb.b, blueA, blueB));
            rgb = vec3(levelsCurve(rgb.r, masterA, masterB), levelsCurve(rgb.g, masterA, masterB),
                       levelsCurve(rgb.b, masterA, masterB));
            rgb = vec3(levelsDecode(rgb.r), levelsDecode(rgb.g), levelsDecode(rgb.b));
            return vec4(rgb * original.a, original.a);
        }
        """)
}
