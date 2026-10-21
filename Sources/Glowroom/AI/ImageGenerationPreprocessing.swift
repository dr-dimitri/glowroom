import CoreGraphics
import Foundation
import GlowroomCore

/// Versioned reference preprocessing for evaluation adapters. Coordinates are
/// top-left pixel edges, exactly like FrozenGenerationMask; there is no implicit
/// EXIF rotation, letterboxing, crop choice or aspect-ratio distortion here.
/// A model adapter must record its selected crop/model size before using this
/// helper and separately declare any model-specific normalization.
enum ImageGenerationPreprocessing {
    static let version = 1

    struct Prepared: Sendable {
        let input: ArtifactRasterInput
        let mask: MaskRaster
        let transform: MaskRasterTransform
    }

    static func prepare(_ request: GenerationRequest) throws -> Prepared {
        let transform = request.mask.binding.transform
        try validate(transform)
        let image = try resized(request.input.image, to: transform.modelSize, crop: transform.crop)
        return Prepared(input: .init(immutableImage: image), mask: try request.mask.modelRaster(), transform: transform)
    }

    /// Restores the chosen model crop onto an unchanged native raster. This is
    /// geometric reconstruction, not authorization to replace pixels: callers
    /// must still apply the immutable native mask with MaskCompositor.
    static func restore(_ model: ArtifactRasterInput, onto native: ArtifactRasterInput,
                        transform: MaskRasterTransform) throws -> ArtifactRasterInput {
        try validate(transform)
        guard model.image.width == transform.modelSize.width, model.image.height == transform.modelSize.height,
              native.image.width == transform.canvasSize.width, native.image.height == transform.canvasSize.height else {
            throw ArtifactContractError.invalidValue("image generation inverse geometry")
        }
        let base = try layout(native.image), candidate = try layout(model.image)
        guard base.bits == candidate.bits, base.profile == candidate.profile else {
            throw ArtifactContractError.unsupportedFormat
        }
        let resized = try resized(model.image, to: transform.crop.size, crop: nil)
        let samples = try packedBytes(resized)
        var bytes = try packedBytes(native.image)
        let pixelBytes = base.bits / 8 * 4
        let rowBytes = transform.crop.size.width * pixelBytes
        for row in 0..<transform.crop.size.height {
            if row.isMultiple(of: 16) { try Task.checkCancellation() }
            let start = ((row + transform.crop.y) * transform.canvasSize.width + transform.crop.x) * pixelBytes
            bytes.replaceSubrange(start..<start + rowBytes, with: samples[row * rowBytes..<(row + 1) * rowBytes])
        }
        return .init(immutableImage: try image(size: transform.canvasSize, bits: base.bits,
            colorSpace: base.colorSpace, bytes: bytes))
    }

    private static func validate(_ transform: MaskRasterTransform) throws {
        try transform.validate()
        guard transform.crop.size.width * transform.modelSize.height == transform.crop.size.height * transform.modelSize.width else {
            throw ArtifactContractError.invalidValue("image generation aspect ratio; select an explicit crop or padded canvas")
        }
    }

    /// Bilinear interpolation acts on the model's encoded straight components.
    /// The mask uses identical pixel centres and edge clamping. Color-correct
    /// final blending remains the separate linear-light MaskCompositor step.
    private static func resized(_ source: CGImage, to size: ArtifactPixelSize,
                                crop: ArtifactPixelRect?) throws -> CGImage {
        let format = try layout(source)
        let sourceSize = try ArtifactPixelSize(width: source.width, height: source.height)
        let region = try crop ?? ArtifactPixelRect(x: 0, y: 0, size: sourceSize)
        guard region.x <= source.width - region.size.width, region.y <= source.height - region.size.height else {
            throw ArtifactContractError.invalidValue("image generation crop")
        }
        if region.x == 0, region.y == 0, region.size == sourceSize, size == sourceSize { return source }
        // A bounded scalar loop is intentional: this reference transform is
        // deterministic across CPU/GPU implementations and creates no nested
        // worker pool inside an admitted generation job.
        let input = try packedBytes(source), componentBytes = format.bits / 8
        var output = Data(count: size.width * size.height * 4 * componentBytes)
        try output.withUnsafeMutableBytes { target in
            try input.withUnsafeBytes { data in
                let dst = target.bindMemory(to: UInt8.self), src = data.bindMemory(to: UInt8.self)
                func sample(_ x: Int, _ y: Int, _ channel: Int) -> Double {
                    let offset = ((y * source.width + x) * 4 + channel) * componentBytes
                    if componentBytes == 1 { return Double(src[offset]) }
                    return Double(UInt16(src[offset]) << 8 | UInt16(src[offset + 1]))
                }
                let scaleX = Double(region.size.width) / Double(size.width)
                let scaleY = Double(region.size.height) / Double(size.height)
                for y in 0..<size.height {
                    if y.isMultiple(of: 16) { try Task.checkCancellation() }
                    let sy = max(Double(region.y), min(Double(region.y + region.size.height - 1),
                        Double(region.y) + (Double(y) + 0.5) * scaleY - 0.5))
                    let y0 = Int(sy.rounded(.down)), y1 = min(y0 + 1, region.y + region.size.height - 1), fy = sy - Double(y0)
                    for x in 0..<size.width {
                        let sx = max(Double(region.x), min(Double(region.x + region.size.width - 1),
                            Double(region.x) + (Double(x) + 0.5) * scaleX - 0.5))
                        let x0 = Int(sx.rounded(.down)), x1 = min(x0 + 1, region.x + region.size.width - 1), fx = sx - Double(x0)
                        for channel in 0..<4 {
                            let top = sample(x0, y0, channel) * (1 - fx) + sample(x1, y0, channel) * fx
                            let bottom = sample(x0, y1, channel) * (1 - fx) + sample(x1, y1, channel) * fx
                            let value = UInt16((top * (1 - fy) + bottom * fy).rounded())
                            let offset = ((y * size.width + x) * 4 + channel) * componentBytes
                            if componentBytes == 1 { dst[offset] = UInt8(value) }
                            else { dst[offset] = UInt8(truncatingIfNeeded: value >> 8); dst[offset + 1] = UInt8(truncatingIfNeeded: value) }
                        }
                    }
                }
            }
        }
        return try image(size: size, bits: format.bits, colorSpace: format.colorSpace, bytes: output)
    }

    private struct Layout {
        let bits: Int
        let profile: Data
        let colorSpace: CGColorSpace
    }
    private static func layout(_ image: CGImage) throws -> Layout {
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard [8, 16].contains(image.bitsPerComponent), image.bitsPerPixel == image.bitsPerComponent * 4,
              image.alphaInfo == .last, !image.bitmapInfo.contains(.floatComponents), !image.isMask,
              image.decode == nil, let space = image.colorSpace, space.model == .rgb,
              let profile = space.copyICCData() as Data?,
              [CGColorSpace.sRGB, CGColorSpace.displayP3].contains(where: { name in
                  (CGColorSpace(name: name)?.copyICCData() as Data?) == profile
              }),
              image.bitsPerComponent == 8 ? (order == [] || order == .byteOrder32Big) : order == .byteOrder16Big,
              image.bytesPerRow >= image.width * 4 * (image.bitsPerComponent / 8),
              image.bytesPerRow <= 536_870_912 / max(1, image.height) else {
            throw ArtifactContractError.unsupportedFormat
        }
        _ = try ArtifactPixelSize(width: image.width, height: image.height)
        return Layout(bits: image.bitsPerComponent, profile: profile, colorSpace: space)
    }
    private static func packedBytes(_ image: CGImage) throws -> Data {
        _ = try layout(image)
        guard let data = image.dataProvider?.data else { throw ArtifactContractError.unsupportedFormat }
        let input = data as Data, rowBytes = image.width * 4 * (image.bitsPerComponent / 8)
        guard input.count >= image.bytesPerRow * image.height else { throw ArtifactContractError.corruptArtifact }
        var output = Data(capacity: rowBytes * image.height)
        for row in 0..<image.height {
            if row.isMultiple(of: 16) { try Task.checkCancellation() }
            output.append(input[row * image.bytesPerRow..<row * image.bytesPerRow + rowBytes])
        }
        return output
    }
    private static func image(size: ArtifactPixelSize, bits: Int, colorSpace: CGColorSpace, bytes: Data) throws -> CGImage {
        let order: CGBitmapInfo = bits == 16 ? .byteOrder16Big : []
        guard let provider = CGDataProvider(data: bytes as CFData), let image = CGImage(width: size.width,
            height: size.height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: size.width * 4 * (bits / 8), space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(order),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ArtifactContractError.unsupportedFormat
        }
        return image
    }
}
