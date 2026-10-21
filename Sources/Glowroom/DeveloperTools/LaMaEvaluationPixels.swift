import CoreVideo
import Foundation

/// Shared pixel transport for fixed 800px local repairs and LaMa evaluation.
/// RGB stays unassociated;
/// source alpha belongs to the final compositor and is never baked into RGB.
/// This bridge has no model-loading or product-capability hook.
enum LaMaEvaluationPixels {
    enum Failure: Error, Equatable {
        case invalidFormat, invalidDimensions, invalidLength, invalidStride
        case allocationFailed, lockFailed, missingBaseAddress
    }

    private static let rgbFormats: [OSType] = [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB]

    static func buffer(format: OSType) throws -> CVPixelBuffer {
        guard rgbFormats.contains(format) || format == kCVPixelFormatType_OneComponent8 else {
            throw Failure.invalidFormat
        }
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, LaMaEvaluationMapping.edge,
            LaMaEvaluationMapping.edge, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let result else { throw Failure.allocationFailed }
        return result
    }

    static func fill(_ image: CVPixelBuffer, _ mask: CVPixelBuffer, pixels: Data, weights: Data,
                     mapping: LaMaEvaluationMapping) throws {
        let sourceCount = mapping.width * mapping.height
        guard pixels.count == sourceCount * 4, weights.count == sourceCount else { throw Failure.invalidLength }
        try locked(image, formats: rgbFormats, channels: 4, flags: []) { rgb, row in
            try locked(mask, formats: [kCVPixelFormatType_OneComponent8], channels: 1, flags: []) { gray, maskRow in
                let bgra = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA
                pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    weights.withUnsafeBytes { (replacement: UnsafeRawBufferPointer) in
                        // One fixed canvas remains on its caller's worker. A
                        // nested pool would multiply scheduling for 800px rows.
                        for y in 0..<LaMaEvaluationMapping.edge { for x in 0..<LaMaEvaluationMapping.edge {
                            let sample = mapping.sample(modelX: x, modelY: y)!
                            let native = sample.sourceY * mapping.width + sample.sourceX
                            let input = native * 4, output = y * row + x * 4
                            for channel in 0..<3 {
                                rgb[output + (bgra ? 2 - channel : channel + 1)] = source[input + channel]
                            }
                            rgb[output + (bgra ? 3 : 0)] = 255
                            // RGB and mask share the same clamp extension. A
                            // marked edge object must not reappear as preserved
                            // context outside the eventual native crop.
                            gray[y * maskRow + x] = replacement[native] >= 128 ? 255 : 0
                        } }
                    }
                }
            }
        }
    }

    /// A native model result is opaque RGB; callers restore the independent
    /// source alpha before passing it to the unchanged product compositor.
    static func crop(_ buffer: CVPixelBuffer, mapping: LaMaEvaluationMapping) throws -> Data {
        try locked(buffer, formats: rgbFormats, channels: 4, flags: .readOnly) { bytes, row in
            let bgra = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
            var data = Data(count: mapping.width * mapping.height * 4)
            data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for y in 0..<mapping.height { for x in 0..<mapping.width {
                    let point = mapping.modelPoint(sourceX: x, sourceY: y)!
                    let input = point.y * row + point.x * 4, destination = (y * mapping.width + x) * 4
                    output[destination] = bytes[input + (bgra ? 2 : 1)]
                    output[destination + 1] = bytes[input + (bgra ? 1 : 2)]
                    output[destination + 2] = bytes[input + (bgra ? 0 : 3)]
                    output[destination + 3] = 255
                } }
            }
            return data
        }
    }

    private static func locked<Result>(_ buffer: CVPixelBuffer, formats: [OSType], channels: Int,
                                       flags: CVPixelBufferLockFlags,
                                       body: (UnsafeMutablePointer<UInt8>, Int) throws -> Result) throws -> Result {
        let edge = LaMaEvaluationMapping.edge
        guard CVPixelBufferGetWidth(buffer) == edge, CVPixelBufferGetHeight(buffer) == edge else {
            throw Failure.invalidDimensions
        }
        guard !CVPixelBufferIsPlanar(buffer), formats.contains(CVPixelBufferGetPixelFormatType(buffer)) else {
            throw Failure.invalidFormat
        }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard row >= edge * channels, row <= Int.max / edge,
              CVPixelBufferGetDataSize(buffer) >= row * edge else { throw Failure.invalidStride }
        guard CVPixelBufferLockBaseAddress(buffer, flags) == kCVReturnSuccess else { throw Failure.lockFailed }
        defer { CVPixelBufferUnlockBaseAddress(buffer, flags) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.missingBaseAddress }
        return try body(address.assumingMemoryBound(to: UInt8.self), row)
    }
}
