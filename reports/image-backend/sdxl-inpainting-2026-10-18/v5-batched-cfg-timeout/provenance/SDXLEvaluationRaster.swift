import Foundation

/// Codec-independent transport for the separate 1024px SDXL evaluation.
/// Rows use top-left coordinates; the native raster is centred without scaling.
/// RGB remains straight, including hidden RGB at alpha zero. Original alpha is
/// held separately by the caller and restored before final mask composition.
struct SDXLEvaluationRaster: Sendable {
    static let edge = 1024

    enum Failure: Error, Equatable { case invalidDimensions, invalidLength }

    let width: Int
    let height: Int
    let offsetX: Int
    let offsetY: Int

    init(width: Int, height: Int) throws {
        // Validate before subtraction or multiplication, including Int.min/max.
        guard (1...Self.edge).contains(width), (1...Self.edge).contains(height) else {
            throw Failure.invalidDimensions
        }
        self.width = width
        self.height = height
        offsetX = (Self.edge - width) / 2
        offsetY = (Self.edge - height) / 2
    }

    func prepare(pixels: Data, mask: Data) throws -> (pixels: Data, mask: Data) {
        let nativeCount = width * height
        guard pixels.count == nativeCount * 4, mask.count == nativeCount else { throw Failure.invalidLength }
        var modelPixels = Data(count: Self.edge * Self.edge * 4)
        var modelMask = Data(count: Self.edge * Self.edge)
        try modelPixels.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            try modelMask.withUnsafeMutableBytes { (weights: UnsafeMutableRawBufferPointer) in
                try pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    try mask.withUnsafeBytes { (nativeMask: UnsafeRawBufferPointer) in
                        // This fixed, bounded copy stays on the admitted caller's
                        // worker; a nested pool would add scheduling and buffers.
                        for y in 0..<Self.edge {
                            if y.isMultiple(of: 16) { try Task.checkCancellation() }
                            let sourceY = min(height - 1, max(0, y - offsetY))
                            for x in 0..<Self.edge {
                                let sourceX = min(width - 1, max(0, x - offsetX))
                                let native = sourceY * width + sourceX
                                let model = y * Self.edge + x
                                for channel in 0..<3 { output[model * 4 + channel] = source[native * 4 + channel] }
                                output[model * 4 + 3] = 255
                                // The SAME edge clamp extends RGB and mask so
                                // marked border objects are not preserved in
                                // artificial context outside the returned crop.
                                weights[model] = nativeMask[native] >= 128 ? 255 : 0
                            }
                        }
                    }
                }
            }
        }
        return (pixels: modelPixels, mask: modelMask)
    }

    /// Returns the native rectangle as opaque RGBA. Model alpha is ignored;
    /// restoring source alpha remains an explicit operation of the caller.
    func crop(_ pixels: Data) throws -> Data {
        guard pixels.count == Self.edge * Self.edge * 4 else { throw Failure.invalidLength }
        var result = Data(count: width * height * 4)
        try result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            try pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    if y.isMultiple(of: 16) { try Task.checkCancellation() }
                    for x in 0..<width {
                        let model = ((y + offsetY) * Self.edge + x + offsetX) * 4
                        let native = (y * width + x) * 4
                        for channel in 0..<3 { output[native + channel] = source[model + channel] }
                        output[native + 3] = 255
                    }
                }
            }
        }
        return result
    }
}
