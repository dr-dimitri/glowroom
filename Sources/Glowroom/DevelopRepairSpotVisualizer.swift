import CoreGraphics
import Foundation

/// Diagnostic pixels stay separate from saved edits and export. One small
/// source plane is cached, so sensitivity changes need only a threshold pass.
actor DevelopRepairSpotVisualizer {
    static let shared = DevelopRepairSpotVisualizer()
    private var identity: ObjectIdentifier?
    private var retainedImage: CGImage?
    private var width = 0, height = 0
    private var differences: [Double] = []

    func image(_ bitmap: PreviewBitmap, sensitivity: Double) throws -> CGImage {
        try Task.checkCancellation()
        if identity != ObjectIdentifier(bitmap.image) {
            let size = AutomaticMaskRasterConverter.outputSize(width: bitmap.image.width, height: bitmap.image.height, maximumDimension: 768)
            guard let context = CGContext(data: nil, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let storage = context.data else {
                throw CocoaError(.coderInvalidValue)
            }
            context.interpolationQuality = .high
            context.draw(bitmap.image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            let bytes = storage.bindMemory(to: UInt8.self, capacity: size.width * size.height * 4)
            let stride = size.width + 1
            var integral = [Double](repeating: 0, count: stride * (size.height + 1))
            var luma = [Double](repeating: 0, count: size.width * size.height)
            for y in 0..<size.height {
                try Task.checkCancellation()
                var row = 0.0
                for x in 0..<size.width {
                    let offset = (y * size.width + x) * 4
                    let alpha = max(1, Double(bytes[offset + 3]))
                    let value = (0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.0722 * Double(bytes[offset + 2])) / alpha
                    luma[y * size.width + x] = value; row += value
                    integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row
                }
            }
            let radius = max(1, Int((Double(max(size.width, size.height)) * 0.006).rounded()))
            var highPass = [Double](repeating: 0, count: luma.count)
            for y in 0..<size.height {
                try Task.checkCancellation()
                for x in 0..<size.width {
                    let x0 = max(0, x - radius), x1 = min(size.width, x + radius + 1)
                    let y0 = max(0, y - radius), y1 = min(size.height, y + radius + 1)
                    let sum = integral[y1 * stride + x1] - integral[y1 * stride + x0]
                        - integral[y0 * stride + x1] + integral[y0 * stride + x0]
                    highPass[y * size.width + x] = abs(luma[y * size.width + x] - sum / Double((x1 - x0) * (y1 - y0)))
                }
            }
            width = size.width; height = size.height; differences = highPass
            retainedImage = bitmap.image; identity = ObjectIdentifier(bitmap.image)
        }
        let level = sensitivity.isFinite ? min(1, max(0, sensitivity)) : 0.5
        let threshold = 0.16 * pow(0.035, level)
        var pixels = Data(count: differences.count)
        pixels.withUnsafeMutableBytes { buffer in
            let out = buffer.bindMemory(to: UInt8.self)
            for index in differences.indices { out[index] = differences[index] > threshold ? 255 : 0 }
        }
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: pixels as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.coderInvalidValue)
        }
        return image
    }
}
