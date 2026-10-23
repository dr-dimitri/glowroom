import CoreImage
import Foundation

/// V2 spatial filters must not acquire the native Gaussian filter's half-float
/// intermediates. Two separable custom kernels keep the context's RGBAf working
/// precision, preserve premultiplied alpha, and let Core Image choose CPU/GPU.
/// The discrete Gaussian is normalized and truncated at ceil(4 * sigma).
enum PreciseGaussianBlur {
    // 1024 positive taps exceeded two minutes in the measured MTL compiler.
    // Bound source/compile work to the previously exercised 512-tap geometry;
    // larger images fail explicitly rather than receiving an approximate blur.
    static let maximumRadius = 128.0
    private static let kernels = KernelCache()

    static func apply(image: CIImage, radius: Double, extent: CGRect) throws -> CIImage {
        try Task.checkCancellation()
        guard radius.isFinite, radius >= 0, radius <= maximumRadius,
              !extent.isEmpty, !extent.isInfinite,
              [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite) else {
            throw EditRenderError.unsupportedSpatialRadius
        }
        // Both passes cover the complete finite input. An arbitrary cropped
        // output would need a larger horizontal intermediate to preserve the
        // vertical pass's ROI and a correspondingly different memory admission.
        guard extent == image.extent else { throw EditRenderError.unavailable }
        guard radius > 0 else { return image }
        let support = Int(ceil(4 * radius))
        let weights = coefficients(sigma: radius, support: support)
        guard weights.contains(where: { $0 > 0 }) else { return image }
        let kernel = try kernels.kernel(tapCount: weights.count)
        var vectors: [Any] = []
        vectors.reserveCapacity((weights.count + 3) / 4)
        for index in stride(from: 0, to: weights.count, by: 4) {
            func weight(_ component: Int) -> Double { index + component < weights.count ? weights[index + component] : 0 }
            vectors.append(CIVector(x: weight(0), y: weight(1), z: weight(2), w: weight(3)))
        }
        // Integer taps avoid the hardware sampler's fractional-weight rounding:
        // bilinear pairing lost small tails despite Float source/destination.
        // No raster readback or independent worker pool separates these passes.
        let margin = CGFloat(support + 1)
        guard let horizontal = kernel.apply(extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -margin, dy: 0) },
            arguments: [image.clampedToExtent().samplingLinear(), CIVector(x: 1, y: 0)] + vectors) else {
            throw EditRenderError.unavailable
        }
        try Task.checkCancellation()
        guard let vertical = kernel.apply(extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: 0, dy: -margin) },
            arguments: [horizontal.clampedToExtent().samplingLinear(), CIVector(x: 0, y: 1)] + vectors) else {
            throw EditRenderError.unavailable
        }
        return vertical
    }

    /// Calculate one coefficient for every positive integer offset; the shader
    /// reflects each sample to the negative side. These bounded scalar weights
    /// cost less serially than another worker or an extra GPU reduction pass.
    private static func coefficients(sigma: Double, support: Int) -> [Double] {
        let weights = (1...support).map { index -> Double in
            let normalized = Double(index) / sigma
            return exp(-0.5 * normalized * normalized)
        }
        let normalization = 1 + 2 * weights.reduce(0, +)
        return weights.map { $0 / normalization }
    }

    /// Cache compiled geometry, rather than sigma-specific shader strings.
    /// Different radii with the same tap count reuse one kernel and only replace
    /// tiny uniforms. No source images or render graphs enter this bounded LRU.
    private final class KernelCache: @unchecked Sendable {
        private struct Entry {
            let kernel: CIKernel
            var lastAccess: UInt64
        }
        private let lock = NSLock()
        private var entries: [Int: Entry] = [:]
        private var sequence: UInt64 = 0

        func kernel(tapCount: Int) throws -> CIKernel {
            lock.lock()
            defer { lock.unlock() }
            try Task.checkCancellation()
            sequence &+= 1
            if var cached = entries[tapCount] {
                cached.lastAccess = sequence; entries[tapCount] = cached
                return cached.kernel
            }
            let vectorCount = (tapCount + 3) / 4
            let parameters = (0..<vectorCount).map { "vec4 taps\($0)" }.joined(separator: ", ")
            var program = "kernel vec4 preciseGaussian(sampler source, vec2 direction, \(parameters)) {\n"
            program += "vec2 point = destCoord();\n"
            program += "vec4 center = sample(source, samplerTransform(source, point));\n"
            program += "vec4 result = center;\n"
            for index in 0..<tapCount {
                let component = ["x", "y", "z", "w"][index % 4]
                program += "float weight\(index) = taps\(index / 4).\(component);\n"
                program += "vec2 delta\(index) = direction * \(index + 1).0;\n"
                program += "vec4 left\(index) = sample(source, samplerTransform(source, point - delta\(index)));\n"
                program += "vec4 right\(index) = sample(source, samplerTransform(source, point + delta\(index)));\n"
                // Algebraically identical to normalized Gaussian convolution;
                // difference form preserves constant fields exactly even after
                // Float rounding of the sum of normalized coefficients.
                program += "result += weight\(index) * ((left\(index) - center) + (right\(index) - center));\n"
            }
            program += "return result;\n}"
            guard let kernel = CIKernel(source: program) else { throw EditRenderError.unavailable }
            if entries.count >= 8, let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                entries.removeValue(forKey: oldest)
            }
            entries[tapCount] = Entry(kernel: kernel, lastAccess: sequence)
            return kernel
        }
    }
}
