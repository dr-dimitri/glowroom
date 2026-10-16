import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PicEditCore

/// Reuses existing decoder/render admission. The final small, quantized bilinear
/// pass is CPU work to match Pillow's reference rounding, not another worker pool.
struct SemanticImagePreprocessor: SemanticImagePreprocessing {
    let imagePipeline: ImagePreviewPipeline
    let renderPipeline: AdjustedPreviewPipeline
    init(imagePipeline: ImagePreviewPipeline = .shared, renderPipeline: AdjustedPreviewPipeline = .shared) {
        self.imagePipeline = imagePipeline; self.renderPipeline = renderPipeline
    }

    func sourceStamp(source: AIOriginalSourceFingerprint) async throws -> String {
        try Task.checkCancellation()
        guard source.isFileURL, source.standardizedPath.hasPrefix("/"), !source.standardizedPath.contains("\0") else { throw SemanticEmbeddingError.invalidInput }
        let url = URL(fileURLWithPath: source.standardizedPath)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw SemanticEmbeddingError.staleSource }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_size == source.fileSize else { throw SemanticEmbeddingError.staleSource }
        let date = Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
        guard abs(date - source.modifiedAt.timeIntervalSince1970) <= 0.000_005 else { throw SemanticEmbeddingError.staleSource }
        return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    func prepare(source: AIOriginalSourceFingerprint, priority: PreviewPriority = .thumbnail) async throws -> SemanticImageInput {
        let before = try await sourceStamp(source: source)
        let request = PreviewRequest(url: URL(fileURLWithPath: source.standardizedPath), modifiedAt: source.modifiedAt,
            pixelSize: 1_024, fileSize: source.fileSize, allowsEmbeddedPreview: false, sourceRevision: before)
        let original = try await imagePipeline.image(for: request, priority: priority)
        let bounded = try await renderPipeline.image(original, request: request, settings: .neutral,
            priority: priority, maximumOutputPixelSize: 1_024)
        let input = try Self.tensor(from: bounded, sourceRevision: before)
        guard try await sourceStamp(source: source) == before else { throw SemanticEmbeddingError.staleSource }
        return input
    }

    static func tensor(from bitmap: PreviewBitmap, sourceRevision: String) throws -> SemanticImageInput {
        try Task.checkCancellation()
        let image = bitmap.image, width = image.width, height = image.height
        guard width > 0, height > 0, max(width, height) <= 1_024, bitmap.byteCost <= 16 * 1_024 * 1_024,
              let space = CGColorSpace(name: CGColorSpace.sRGB), image.colorSpace != nil,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw SemanticEmbeddingError.invalidInput
        }
        // ImageIO has already applied orientation. Untagged device RGB is
        // explicitly interpreted as sRGB; tagged RGB/gray/CMYK is converted.
        let deviceRGB = CGColorSpaceCreateDeviceRGB()
        let source: CGImage
        if image.colorSpace?.name == deviceRGB.name, image.colorSpace?.copyICCData() == nil,
           let tagged = image.copy(colorSpace: space) { source = tagged }
        else { source = image }
        context.setRenderingIntent(.relativeColorimetric)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw SemanticEmbeddingError.invalidInput }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for row in 0..<height {
            if row % 32 == 0 { try Task.checkCancellation() }
            for column in 0..<width {
                let pixel = row * width + column
                for channel in 0..<3 { rgb[pixel * 3 + channel] = bytes[pixel * 4 + channel] }
            }
        }
        let resized = try bilinear(rgb, width: width, height: height)
        var values = [Float](repeating: 0, count: 3 * 256 * 256)
        for pixel in 0..<(256 * 256) {
            for channel in 0..<3 { values[channel * 256 * 256 + pixel] = (Float(resized[pixel * 3 + channel]) / 255 - 0.5) / 0.5 }
        }
        var hasher = SHA256()
        hasher.update(data: Data("PicEdit-SigLIP2-v1|oriented-original-base1024|sRGB|white-alpha|pillow-bilinear|CHW256|f32le|mean0.5-std0.5|".utf8))
        values.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return SemanticImageInput(values: values, rasterSHA256: hash, sourceRevision: sourceRevision)
    }

    /// Pillow's separable bilinear filter uses antialias support for reduction,
    /// fixed22-bit positive coefficients and an8-bit intermediate between axes.
    private static func coefficients(input: Int, output: Int) -> [(Int, [Int64])] {
        let scale = Double(input) / Double(output), support = max(1, scale)
        return (0..<output).map { index in
            let center = (Double(index) + 0.5) * scale
            let start = max(0, Int(center - support + 0.5)), end = min(input, Int(center + support + 0.5))
            let weights = (start..<end).map { max(0, 1 - abs((Double($0) + 0.5 - center) / support)) }
            let sum = weights.reduce(0, +)
            return (start, weights.map { Int64(($0 / sum * Double(1 << 22) + 0.5).rounded(.towardZero)) })
        }
    }

    private static func bilinear(_ rgb: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        let x = coefficients(input: width, output: 256), y = coefficients(input: height, output: 256)
        var horizontal = [UInt8](repeating: 0, count: 256 * height * 3)
        for row in 0..<height {
            if row % 32 == 0 { try Task.checkCancellation() }
            for column in 0..<256 {
                let (start, weights) = x[column]
                for channel in 0..<3 {
                    var sum: Int64 = 1 << 21
                    for (offset, coefficient) in weights.enumerated() { sum += Int64(rgb[(row * width + start + offset) * 3 + channel]) * coefficient }
                    horizontal[(row * 256 + column) * 3 + channel] = UInt8(clamping: sum >> 22)
                }
            }
        }
        var output = [UInt8](repeating: 0, count: 256 * 256 * 3)
        for row in 0..<256 {
            if row % 32 == 0 { try Task.checkCancellation() }
            let (start, weights) = y[row]
            for column in 0..<256 {
                for channel in 0..<3 {
                    var sum: Int64 = 1 << 21
                    for (offset, coefficient) in weights.enumerated() { sum += Int64(horizontal[((start + offset) * 256 + column) * 3 + channel]) * coefficient }
                    output[(row * 256 + column) * 3 + channel] = UInt8(clamping: sum >> 22)
                }
            }
        }
        return output
    }
}
